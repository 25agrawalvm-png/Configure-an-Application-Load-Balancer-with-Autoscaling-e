#!/usr/bin/env bash
# =============================================================================
#  Lab OCBL105 - Configure an Application Load Balancer with Autoscaling
#
#  Builds every resource that the six lab checkpoints look for, using gcloud:
#
#    Task 1  (10)  Firewall rule  fw-allow-health-checks
#    Task 2  (10)  Cloud Router + Cloud NAT  (nat-router-us1 / nat-config)
#    Task 3  (20)  Custom image  mywebserver  (from disk "webserver")
#    Task 4  (20)  Instance template + health check + 2 managed instance groups
#    Task 5  (20)  Global external Application Load Balancer (http-lb)
#    Task 6  (20)  stress-test VM generating load against the load balancer
#
#  HOW TO RUN  (works for any student / any lab project)
#    1. Sign in to the Google Cloud console with the lab's own username and
#       password (incognito window), then open Cloud Shell (>_ icon, top right).
#       Cloud Shell is already authenticated and already points at the lab
#       project - nothing in this script is tied to one specific account.
#    2. Upload or paste this file, then run:
#           bash ocbl105_lab.sh
#    3. Wait for the final score table. Then click "Check my progress" for each
#       task on the lab page (the lab page itself cannot be clicked by a script).
#
#  The script is safe to re-run: every step checks whether the resource already
#  exists and skips it, so it resumes where it stopped after any failure.
# =============================================================================

set -uo pipefail

usage() {
  cat <<'USAGE'
Usage: bash ocbl105_lab.sh [options]

  -p, --project ID      Use this project (default: auto-detect qwiklabs-gcp-*)
      --eu-region R     Region for notus-1-mig (default: europe-west4; if the
                        project's location policy forbids it, the script tries
                        other regions automatically unless you pin one here)
      --stress-zone Z   Zone for the stress-test VM (default: us-east1-b, with
                        automatic fallback unless you pin one here)
      --stress-wait S   Seconds to watch the load test (default: 600)
      --verify-only     Create nothing; only print the checkpoint report
  -h, --help            Show this help

Environment variables:
  FORCE=1               Allow a project that is not named qwiklabs-gcp-*
  EU_REGION, STRESS_ZONE   Same as --eu-region / --stress-zone
USAGE
}

# ----------------------------- lab constants ---------------------------------
FW_NAME="fw-allow-health-checks"
HC_RANGES="130.211.0.0/22,35.191.0.0/16"
NET_TAG="allow-health-checks"
US_REGION="us-central1"
US_ZONE="us-central1-c"
# Second backend region: the lab says europe-west4, but some lab projects carry an
# org policy (constraints/gcp.resourceLocations) that forbids it. In that case the
# script falls back to another allowed region unless one was pinned explicitly.
EU_REGION_PINNED=0
[ -n "${EU_REGION:-}" ] && EU_REGION_PINNED=1
EU_REGION="${EU_REGION:-europe-west4}"
ROUTER="nat-router-us1"
NAT="nat-config"
WEB_VM="webserver"
IMAGE="mywebserver"
TEMPLATE="mywebserver-template"
HEALTH_CHECK="http-health-check"
US_MIG="us-1-mig"
EU_MIG="notus-1-mig"
BACKEND="http-backend"
LB_NAME="http-lb"
PROXY="http-lb-target-proxy"
FR4="http-lb-forwarding-rule"
FR6="http-lb-forwarding-rule-2"
STRESS_VM="stress-test"
STRESS_ZONE_PINNED=0
[ -n "${STRESS_ZONE:-}" ] && STRESS_ZONE_PINNED=1
STRESS_ZONE="${STRESS_ZONE:-us-east1-b}"
STRESS_WAIT="${STRESS_WAIT:-600}"

PROJECT_ID="${PROJECT_ID:-}"
VERIFY_ONLY=0
LB_IP_V4=""
LB_IP_V6=""
ACCOUNT=""

# ------------------------------- helpers -------------------------------------
ts()   { date '+%H:%M:%S'; }
log()  { printf '[%s] %s\n' "$(ts)" "$*"; }
step() { printf '\n[%s] ===== %s =====\n' "$(ts)" "$*"; }
warn() { printf '[%s] WARNING: %s\n' "$(ts)" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$(ts)" "$*" >&2
         printf '        The script is re-runnable: fix the problem (or just wait a minute) and run it again.\n' >&2
         exit 1; }

# exists <command...>  -> true when the command succeeds (used with "describe")
exists() { "$@" >/dev/null 2>&1; }
# must <command...>    -> run the command, abort the script if it fails
must()   { "$@" || die "Command failed: $*"; }

TMP_DIR="$(mktemp -d 2>/dev/null || echo "/tmp/ocbl105.$$")"
mkdir -p "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT

# ----------------------------- argument parsing ------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -p|--project)   [ $# -ge 2 ] || die "--project needs a value"; PROJECT_ID="$2"; shift 2 ;;
    --eu-region)    [ $# -ge 2 ] || die "--eu-region needs a value"; EU_REGION="$2"; EU_REGION_PINNED=1; shift 2 ;;
    --stress-zone)  [ $# -ge 2 ] || die "--stress-zone needs a value"; STRESS_ZONE="$2"; STRESS_ZONE_PINNED=1; shift 2 ;;
    --stress-wait)  [ $# -ge 2 ] || die "--stress-wait needs a value"; STRESS_WAIT="$2"; shift 2 ;;
    --verify-only)  VERIFY_ONLY=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)              usage; die "Unknown argument: $1" ;;
  esac
done

case "$STRESS_WAIT" in ''|*[!0-9]*) die "--stress-wait must be a number of seconds" ;; esac

LOG_FILE="ocbl105-run-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

# ------------------------------- preflight -----------------------------------
resolve_project() {
  [ -n "$PROJECT_ID" ] && return 0
  local cfg lab
  cfg="$(gcloud config get-value project 2>/dev/null | head -n1)"
  [ "$cfg" = "(unset)" ] && cfg=""
  case "$cfg" in
    qwiklabs-gcp-*) PROJECT_ID="$cfg"; return 0 ;;
  esac
  lab="$(gcloud projects list --filter='projectId ~ ^qwiklabs-gcp-' --format='value(projectId)' 2>/dev/null | head -n1)"
  if [ -n "$lab" ]; then PROJECT_ID="$lab"; return 0; fi
  PROJECT_ID="$cfg"
}

preflight() {
  step "Pre-flight checks"
  command -v gcloud >/dev/null 2>&1 || die "gcloud CLI not found. Open Cloud Shell (>_ icon in the console) and run the script there."
  command -v curl   >/dev/null 2>&1 || die "curl not found."

  ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n1)"
  [ -n "$ACCOUNT" ] || die "No active gcloud account. Run 'gcloud auth login' and sign in with the LAB username/password, or use Cloud Shell."

  resolve_project
  [ -n "$PROJECT_ID" ] || die "Could not detect the project. Re-run with:  bash $0 --project <your-qwiklabs-project-id>"

  case "$PROJECT_ID" in
    qwiklabs-gcp-*) ;;
    *) [ "${FORCE:-0}" = "1" ] || die "Project '$PROJECT_ID' is not a lab project (expected qwiklabs-gcp-*). Refusing to create billable resources there. Use the lab credentials, or re-run with FORCE=1 if you are sure." ;;
  esac
  case "$ACCOUNT" in
    *qwiklabs*) ;;
    *) warn "Active account '$ACCOUNT' does not look like a lab student account." ;;
  esac

  export CLOUDSDK_CORE_PROJECT="$PROJECT_ID"
  export CLOUDSDK_CORE_DISABLE_PROMPTS=1
  gcloud config set project "$PROJECT_ID" --quiet >/dev/null 2>&1

  gcloud compute zones describe "$US_ZONE" >/dev/null 2>&1 \
    || die "Cannot reach Compute Engine in project $PROJECT_ID with account $ACCOUNT. Check that you are signed in with the lab account."

  log "Account : $ACCOUNT"
  log "Project : $PROJECT_ID"
  log "Log file: $LOG_FILE"
}

# --------------------------- serial-console helpers --------------------------
serial_output() {   # serial_output <vm> <zone>
  gcloud compute instances get-serial-port-output "$1" --zone="$2" --port=1 2>/dev/null || true
}

# wait_serial <vm> <zone> <ok-pattern> <fail-pattern> <timeout-secs>
# returns 0 = ok pattern seen, 1 = timeout, 2 = fail pattern seen
wait_serial() {
  local vm="$1" zone="$2" okpat="$3" failpat="$4" timeout="$5" waited=0 out
  while [ "$waited" -lt "$timeout" ]; do
    out="$(serial_output "$vm" "$zone")"
    if [ -n "$failpat" ] && [[ "$out" == *"$failpat"* ]]; then return 2; fi
    if [[ "$out" == *"$okpat"* ]]; then return 0; fi
    sleep 15
    waited=$((waited + 15))
  done
  return 1
}

# ============================================================================
#  TASK 1 - health check firewall rule
# ============================================================================
task1_firewall() {
  step "Task 1 - Firewall rule $FW_NAME"
  if exists gcloud compute firewall-rules describe "$FW_NAME"; then
    log "$FW_NAME already exists - skipping"
    return 0
  fi
  must gcloud compute firewall-rules create "$FW_NAME" \
    --network=default \
    --direction=INGRESS \
    --priority=1000 \
    --action=ALLOW \
    --rules=tcp:80 \
    --source-ranges="$HC_RANGES" \
    --target-tags="$NET_TAG"
}

# ============================================================================
#  TASK 2 - Cloud Router + Cloud NAT
# ============================================================================
task2_nat() {
  step "Task 2 - Cloud Router $ROUTER and Cloud NAT $NAT"
  if exists gcloud compute routers describe "$ROUTER" --region="$US_REGION"; then
    log "Router $ROUTER already exists - skipping"
  else
    must gcloud compute routers create "$ROUTER" --network=default --region="$US_REGION"
  fi

  if exists gcloud compute routers nats describe "$NAT" --router="$ROUTER" --router-region="$US_REGION"; then
    log "NAT $NAT already exists - skipping"
  else
    must gcloud compute routers nats create "$NAT" \
      --router="$ROUTER" \
      --router-region="$US_REGION" \
      --auto-allocate-nat-external-ips \
      --nat-all-subnet-ip-ranges
    log "Giving the NAT gateway 45 seconds to become active..."
    sleep 45
  fi
}

# ============================================================================
#  TASK 3 - custom image from a prepared web server
# ============================================================================
write_webserver_startup_script() {
  cat > "$1" <<'EOF'
#!/bin/bash
# Lab helper: installs Apache2 on first boot, reports Apache state on later boots.
export DEBIAN_FRONTEND=noninteractive
if dpkg -s apache2 2>/dev/null | grep -q 'Status: install ok installed'; then
  sleep 20
  echo "LAB_BOOT_CHECK apache2=$(systemctl is-active apache2) enabled=$(systemctl is-enabled apache2)"
  exit 0
fi
ok=0
for i in $(seq 1 30); do
  if apt-get update -y && apt-get install -y apache2; then ok=1; break; fi
  sleep 10
done
if [ "$ok" = 1 ]; then
  systemctl enable apache2
  systemctl start apache2
  echo "LAB_INSTALL_DONE"
else
  echo "LAB_INSTALL_FAILED"
fi
EOF
}

task3_image() {
  step "Task 3 - Custom image $IMAGE"
  if exists gcloud compute images describe "$IMAGE"; then
    log "Image $IMAGE already exists - skipping"
    return 0
  fi

  local disk_present=0 vm_present=0 rc out
  exists gcloud compute disks describe "$WEB_VM" --zone="$US_ZONE" && disk_present=1
  exists gcloud compute instances describe "$WEB_VM" --zone="$US_ZONE" && vm_present=1

  if [ "$vm_present" = 0 ] && [ "$disk_present" = 1 ]; then
    log "VM already deleted and disk '$WEB_VM' exists - reusing the prepared disk"
  else
    if [ "$vm_present" = 0 ]; then
      log "Creating VM $WEB_VM (no external IP, tag $NET_TAG, boot disk kept on delete)"
      write_webserver_startup_script "$TMP_DIR/web-startup.sh"
      must gcloud compute instances create "$WEB_VM" \
        --zone="$US_ZONE" \
        --machine-type=e2-medium \
        --network=default \
        --no-address \
        --tags="$NET_TAG" \
        --image-family=debian-12 \
        --image-project=debian-cloud \
        --no-boot-disk-auto-delete \
        --metadata-from-file=startup-script="$TMP_DIR/web-startup.sh"
    else
      log "VM $WEB_VM already exists - reusing it"
    fi

    log "Waiting for Apache2 to be installed on $WEB_VM (up to 15 min)..."
    wait_serial "$WEB_VM" "$US_ZONE" "LAB_INSTALL_DONE" "LAB_INSTALL_FAILED" 900
    rc=$?
    case "$rc" in
      0) log "Apache2 installed, enabled and started." ;;
      2) die "Apache install failed on $WEB_VM (no internet via Cloud NAT?). Delete the VM '$WEB_VM' and re-run." ;;
      *) die "Timed out waiting for Apache2 on $WEB_VM. Delete the VM '$WEB_VM' and re-run." ;;
    esac

    log "Resetting $WEB_VM to prove Apache starts at boot..."
    must gcloud compute instances reset "$WEB_VM" --zone="$US_ZONE"
    wait_serial "$WEB_VM" "$US_ZONE" "LAB_BOOT_CHECK apache2=" "" 600
    rc=$?
    [ "$rc" = 0 ] || die "VM $WEB_VM did not report back after the reset."
    out="$(serial_output "$WEB_VM" "$US_ZONE")"
    if [[ "$out" == *"LAB_BOOT_CHECK apache2=active"* ]]; then
      log "Apache2 is active after reset - boot persistence confirmed."
    else
      die "Apache2 is NOT active after reset on $WEB_VM."
    fi

    log "Deleting VM $WEB_VM (the boot disk is kept)..."
    must gcloud compute instances delete "$WEB_VM" --zone="$US_ZONE" --keep-disks=boot --quiet
  fi

  exists gcloud compute disks describe "$WEB_VM" --zone="$US_ZONE" \
    || die "Boot disk '$WEB_VM' is missing - it must survive the VM deletion. Re-run the script."

  must gcloud compute images create "$IMAGE" \
    --source-disk="$WEB_VM" \
    --source-disk-zone="$US_ZONE"
}

# ============================================================================
#  TASK 4 - instance template, health check, managed instance groups
# ============================================================================
# Autoscalers created by gcloud get a random suffix (e.g. us-1-mig-eo0i), so they are
# looked up by target MIG, not by name. Prints "<min> <max>" or nothing.
_as_describe() {   # _as_describe <autoscaler-name> <region>
  gcloud compute autoscalers describe "$1" --region="$2" \
    --format='value(autoscalingPolicy.minNumReplicas,autoscalingPolicy.maxNumReplicas)' 2>/dev/null \
    | tr '\t' ' '
}

autoscaler_info() {   # autoscaler_info <mig> <region>
  local url name out
  # 1) the MIG itself reports the autoscaler that targets it
  url="$(gcloud compute instance-groups managed describe "$1" --region="$2" \
          --format='value(status.autoscaler)' 2>/dev/null)"
  if [ -n "$url" ]; then
    out="$(_as_describe "${url##*/}" "$2")"
    if [ -n "$out" ]; then printf '%s\n' "$out"; return 0; fi
  fi
  # 2) fall back to an autoscaler whose name starts with the MIG name
  name="$(gcloud compute autoscalers list --format='value(name)' 2>/dev/null \
          | awk -v m="$1" 'index($0, m) == 1 {print; exit}')"
  if [ -n "$name" ]; then
    out="$(_as_describe "$name" "$2")"
    if [ -n "$out" ]; then printf '%s\n' "$out"; return 0; fi
  fi
  return 0
}

configure_mig() {   # configure_mig <name> <region>   (named port + autoscaler; idempotent)
  local mig="$1" region="$2"

  # Named port used by the backend service (port name "http" -> 80)
  must gcloud compute instance-groups managed set-named-ports "$mig" \
    --named-ports=http:80 --region="$region"

  if [ -z "$(autoscaler_info "$mig" "$region")" ]; then
    # If an autoscaler already exists this simply updates it with the same values.
    must gcloud compute instance-groups managed set-autoscaling "$mig" \
      --region="$region" \
      --min-num-replicas=1 \
      --max-num-replicas=2 \
      --target-load-balancing-utilization=0.8 \
      --cool-down-period=60
  else
    log "Autoscaler for $mig already exists - skipping"
  fi
}

create_mig() {   # create_mig <name> <region>
  local mig="$1" region="$2"
  if exists gcloud compute instance-groups managed describe "$mig" --region="$region"; then
    log "$mig already exists - skipping create"
  else
    must gcloud compute instance-groups managed create "$mig" \
      --template="$TEMPLATE" \
      --size=1 \
      --region="$region" \
      --health-check="$HEALTH_CHECK" \
      --initial-delay=60
  fi
  configure_mig "$mig" "$region"
}

# ---- location-policy handling (constraints/gcp.resourceLocations) -------------
POLICY_SHOWN=0
show_location_policy() {   # read-only, best effort, printed once
  [ "$POLICY_SHOWN" = 1 ] && return 0
  POLICY_SHOWN=1
  local pol
  pol="$(gcloud org-policies describe gcp.resourceLocations --project="$PROJECT_ID" --effective 2>/dev/null)" \
    || pol="$(gcloud resource-manager org-policies describe gcp.resourceLocations --project="$PROJECT_ID" --effective 2>/dev/null)" \
    || pol=""
  if [ -n "$pol" ]; then
    log "Effective location policy of this project (allowed locations):"
    printf '%s\n' "$pol" | head -n 25
  fi
}

eu_region_candidates() {
  if [ "$EU_REGION_PINNED" = 1 ]; then echo "$EU_REGION"; return 0; fi
  echo "$EU_REGION europe-west1 europe-west2 europe-west3 europe-north1 asia-east1 asia-southeast1 us-east1 us-west1"
}

stress_zone_candidates() {
  if [ "$STRESS_ZONE_PINNED" = 1 ]; then echo "$STRESS_ZONE"; return 0; fi
  echo "$STRESS_ZONE us-east4-b us-west1-b us-west2-b us-east1-c us-central1-a"
}

detect_existing_locations() {   # re-runs / --verify-only: reuse where things were created
  local r z
  r="$(gcloud compute instance-groups managed list --filter="name=$EU_MIG" --format='value(region.basename())' 2>/dev/null | head -n1)"
  if [ -n "$r" ]; then EU_REGION="$r"; fi
  z="$(gcloud compute instances list --filter="name=$STRESS_VM" --format='value(zone.basename())' 2>/dev/null | head -n1)"
  if [ -n "$z" ]; then STRESS_ZONE="$z"; fi
  return 0
}

# Creates notus-1-mig in europe-west4, or - if the project's location policy forbids
# that region - in the first other candidate region the policy accepts.
create_eu_mig() {
  local cand out rc found
  found="$(gcloud compute instance-groups managed list --filter="name=$EU_MIG" --format='value(region.basename())' 2>/dev/null | head -n1)"
  if [ -n "$found" ]; then
    EU_REGION="$found"
    log "$EU_MIG already exists in $EU_REGION - skipping create"
    configure_mig "$EU_MIG" "$EU_REGION"
    return 0
  fi

  for cand in $(eu_region_candidates); do
    log "Creating $EU_MIG in $cand ..."
    out="$(gcloud compute instance-groups managed create "$EU_MIG" \
            --template="$TEMPLATE" \
            --size=1 \
            --region="$cand" \
            --health-check="$HEALTH_CHECK" \
            --initial-delay=60 2>&1)"
    rc=$?
    printf '%s\n' "$out"
    if [ "$rc" -eq 0 ]; then
      EU_REGION="$cand"
      if [ "$cand" != "europe-west4" ]; then
        warn "The lab text asks for europe-west4, but this project's location policy does not allow it."
        warn "$EU_MIG was created in $cand instead (the closest allowed region found)."
      fi
      configure_mig "$EU_MIG" "$EU_REGION"
      return 0
    fi
    if [[ "$out" == *"resourceLocations"* ]]; then
      warn "Region $cand is not allowed by this project's location policy."
      show_location_policy
      continue
    fi
    die "Creating $EU_MIG in $cand failed for a reason other than the location policy (see message above)."
  done
  die "None of the candidate regions is allowed by this project's location policy. Look at the policy printed above (or the lab panel) and re-run with: --eu-region <allowed-region>"
}

wait_mig_stable() {   # wait_mig_stable <name> <region>
  log "Waiting for $1 to become stable (instances running)..."
  gcloud compute instance-groups managed wait-until "$1" --stable --region="$2" --timeout=900 \
    || warn "$1 did not report 'stable' within 15 minutes; continuing (check the console)."
}

task4_template_and_migs() {
  step "Task 4 - Instance template, health check and managed instance groups"

  if exists gcloud compute instance-templates describe "$TEMPLATE"; then
    log "Template $TEMPLATE already exists - skipping"
  else
    must gcloud compute instance-templates create "$TEMPLATE" \
      --machine-type=e2-micro \
      --image="$IMAGE" \
      --image-project="$PROJECT_ID" \
      --network=default \
      --no-address \
      --tags="$NET_TAG"
  fi

  if exists gcloud compute health-checks describe "$HEALTH_CHECK"; then
    log "Health check $HEALTH_CHECK already exists - skipping"
  else
    must gcloud compute health-checks create http "$HEALTH_CHECK" --port=80
  fi

  create_mig "$US_MIG" "$US_REGION"
  create_eu_mig

  wait_mig_stable "$US_MIG" "$US_REGION"
  wait_mig_stable "$EU_MIG" "$EU_REGION"
}

# ============================================================================
#  TASK 5 - Global external Application Load Balancer (HTTP), IPv4 + IPv6
# ============================================================================
backend_has_group() {   # backend_has_group <mig-name>
  local out
  out="$(gcloud compute backend-services describe "$BACKEND" --global --format='value(backends[].group)' 2>/dev/null)" || return 1
  [[ "$out" == *"/instanceGroups/$1"* ]]
}

read_lb_ips() {
  LB_IP_V4="$(gcloud compute forwarding-rules describe "$FR4" --global --format='value(IPAddress)' 2>/dev/null)"
  LB_IP_V6="$(gcloud compute forwarding-rules describe "$FR6" --global --format='value(IPAddress)' 2>/dev/null)"
}

wait_lb_ready() {   # wait_lb_ready <ip> <timeout-secs>
  local ip="$1" timeout="$2" waited=0 body
  while [ "$waited" -lt "$timeout" ]; do
    body="$(curl -s -m 5 "http://$ip/" 2>/dev/null || true)"
    if [[ "$body" == *[Aa]pache* ]]; then return 0; fi
    log "Waiting for Load Balancer ($ip)..."
    sleep 10
    waited=$((waited + 10))
  done
  return 1
}

task5_load_balancer() {
  step "Task 5 - Application Load Balancer $LB_NAME"

  if exists gcloud compute backend-services describe "$BACKEND" --global; then
    log "Backend service $BACKEND already exists - skipping create"
  else
    must gcloud compute backend-services create "$BACKEND" \
      --global \
      --load-balancing-scheme=EXTERNAL_MANAGED \
      --protocol=HTTP \
      --port-name=http \
      --health-checks="$HEALTH_CHECK" \
      --enable-logging \
      --logging-sample-rate=1.0
  fi

  if backend_has_group "$US_MIG"; then
    log "Backend $US_MIG already attached - skipping"
  else
    must gcloud compute backend-services add-backend "$BACKEND" \
      --global \
      --instance-group="$US_MIG" \
      --instance-group-region="$US_REGION" \
      --balancing-mode=RATE \
      --max-rate-per-instance=50 \
      --capacity-scaler=1.0
  fi

  if backend_has_group "$EU_MIG"; then
    log "Backend $EU_MIG already attached - skipping"
  else
    must gcloud compute backend-services add-backend "$BACKEND" \
      --global \
      --instance-group="$EU_MIG" \
      --instance-group-region="$EU_REGION" \
      --balancing-mode=UTILIZATION \
      --max-utilization=0.8 \
      --capacity-scaler=1.0
  fi

  if exists gcloud compute url-maps describe "$LB_NAME"; then
    log "URL map $LB_NAME already exists - skipping"
  else
    must gcloud compute url-maps create "$LB_NAME" --default-service="$BACKEND"
  fi

  if exists gcloud compute target-http-proxies describe "$PROXY"; then
    log "Target proxy $PROXY already exists - skipping"
  else
    must gcloud compute target-http-proxies create "$PROXY" --url-map="$LB_NAME"
  fi

  if exists gcloud compute forwarding-rules describe "$FR4" --global; then
    log "Forwarding rule $FR4 already exists - skipping"
  else
    must gcloud compute forwarding-rules create "$FR4" \
      --global \
      --load-balancing-scheme=EXTERNAL_MANAGED \
      --network-tier=PREMIUM \
      --ip-version=IPV4 \
      --target-http-proxy="$PROXY" \
      --ports=80
  fi

  if exists gcloud compute forwarding-rules describe "$FR6" --global; then
    log "Forwarding rule $FR6 already exists - skipping"
  else
    must gcloud compute forwarding-rules create "$FR6" \
      --global \
      --load-balancing-scheme=EXTERNAL_MANAGED \
      --network-tier=PREMIUM \
      --ip-version=IPV6 \
      --target-http-proxy="$PROXY" \
      --ports=80
  fi

  read_lb_ips
  [ -n "$LB_IP_V4" ] || die "Could not read the load balancer IPv4 address."
  log "Load balancer IPv4: $LB_IP_V4"
  log "Load balancer IPv6: ${LB_IP_V6:-<none>}"

  log "Waiting for the load balancer to serve traffic (can take 5-10 min)..."
  if wait_lb_ready "$LB_IP_V4" 1200; then
    log "Load balancer is serving the Apache page."
  else
    warn "Load balancer did not answer within 20 minutes - continuing anyway."
  fi
}

# ============================================================================
#  TASK 6 - stress test
# ============================================================================
write_stress_startup_script() {   # write_stress_startup_script <file> <lb-ip>
  local file="$1" LB_IP_V4="$2"
  cat > "$file" <<EOF
#!/bin/bash
cat > /usr/local/bin/lab-stress.sh <<'EOS'
#!/bin/bash
ulimit -n 65535
if ! command -v ab >/dev/null 2>&1; then
  apt-get update -y && apt-get install -y apache2-utils
fi
for i in 1 2 3 4 5 6; do
  ab -r -n 500000 -c 1000 http://${LB_IP_V4}/
done
EOS
chmod +x /usr/local/bin/lab-stress.sh
setsid nohup /usr/local/bin/lab-stress.sh > /var/log/lab-stress.log 2>&1 < /dev/null &
EOF
}

create_stress_vm() {   # create_stress_vm <startup-script-file>
  local script="$1" cand out rc
  for cand in $(stress_zone_candidates); do
    log "Creating $STRESS_VM in $cand (runs: ab -n 500000 -c 1000 http://$LB_IP_V4/)"
    out="$(gcloud compute instances create "$STRESS_VM" \
            --zone="$cand" \
            --machine-type=e2-micro \
            --image="$IMAGE" \
            --image-project="$PROJECT_ID" \
            --metadata-from-file=startup-script="$script" 2>&1)"
    rc=$?
    printf '%s\n' "$out"
    if [ "$rc" -eq 0 ]; then
      STRESS_ZONE="$cand"
      return 0
    fi
    if [[ "$out" == *"resourceLocations"* ]]; then
      warn "Zone $cand is not allowed by this project's location policy."
      show_location_policy
      continue
    fi
    die "Creating $STRESS_VM in $cand failed for a reason other than the location policy (see message above)."
  done
  die "None of the candidate zones is allowed by the location policy. Re-run with: --stress-zone <allowed-zone>"
}

mig_size() {   # mig_size <name> <region>
  gcloud compute instance-groups managed describe "$1" --region="$2" --format='value(targetSize)' 2>/dev/null
}

task6_stress() {
  step "Task 6 - Stress test VM $STRESS_VM"
  [ -n "$LB_IP_V4" ] || read_lb_ips
  [ -n "$LB_IP_V4" ] || die "Load balancer IP not available - run Task 5 first."

  if exists gcloud compute instances describe "$STRESS_VM" --zone="$STRESS_ZONE"; then
    log "VM $STRESS_VM already exists - skipping create (its load generator started at boot)"
  else
    write_stress_startup_script "$TMP_DIR/stress-startup.sh" "$LB_IP_V4"
    create_stress_vm "$TMP_DIR/stress-startup.sh"
  fi

  log "Watching the load for up to ${STRESS_WAIT}s (autoscaling + traffic spill-over to $EU_MIG)..."
  local waited=0 us eu
  while [ "$waited" -lt "$STRESS_WAIT" ]; do
    sleep 30
    waited=$((waited + 30))
    us="$(mig_size "$US_MIG" "$US_REGION")"
    eu="$(mig_size "$EU_MIG" "$EU_REGION")"
    log "t+${waited}s  target size: $US_MIG=${us:-?}  $EU_MIG=${eu:-?}"
  done
  log "Load generator keeps running on $STRESS_VM in the background (up to 6 rounds)."
}

# ============================================================================
#  Verification / score report (mirrors the six lab checkpoints)
# ============================================================================
v_task1() {
  local out
  out="$(gcloud compute firewall-rules describe "$FW_NAME" --format=json 2>/dev/null)" || return 1
  [[ "$out" == *"130.211.0.0/22"* && "$out" == *"35.191.0.0/16"* \
     && "$out" == *"$NET_TAG"* && "$out" == *'"80"'* ]]
}

v_task2() {
  exists gcloud compute routers describe "$ROUTER" --region="$US_REGION" \
    && exists gcloud compute routers nats describe "$NAT" --router="$ROUTER" --router-region="$US_REGION"
}

v_task3() {
  local out
  out="$(gcloud compute images describe "$IMAGE" --format='value(status,sourceDisk)' 2>/dev/null)" || return 1
  [[ "$out" == READY* && "$out" == *"/disks/$WEB_VM" ]] \
    && exists gcloud compute disks describe "$WEB_VM" --zone="$US_ZONE"
}

v_task4() {
  local out a_us a_eu
  out="$(gcloud compute instance-templates describe "$TEMPLATE" --format=json 2>/dev/null)" || return 1
  [[ "$out" == *"$IMAGE"* && "$out" == *"$NET_TAG"* && "$out" == *"e2-micro"* ]] || return 1
  exists gcloud compute health-checks describe "$HEALTH_CHECK" || return 1
  exists gcloud compute instance-groups managed describe "$US_MIG" --region="$US_REGION" || return 1
  exists gcloud compute instance-groups managed describe "$EU_MIG" --region="$EU_REGION" || return 1
  a_us="$(autoscaler_info "$US_MIG" "$US_REGION")"
  a_eu="$(autoscaler_info "$EU_MIG" "$EU_REGION")"
  [ "$a_us" = "1 2" ] && [ "$a_eu" = "1 2" ]
}

v_task5() {
  exists gcloud compute url-maps describe "$LB_NAME" || return 1
  exists gcloud compute target-http-proxies describe "$PROXY" || return 1
  exists gcloud compute forwarding-rules describe "$FR4" --global || return 1
  exists gcloud compute forwarding-rules describe "$FR6" --global || return 1
  backend_has_group "$US_MIG" && backend_has_group "$EU_MIG"
}

v_task6() {
  local st
  st="$(gcloud compute instances describe "$STRESS_VM" --zone="$STRESS_ZONE" --format='value(status)' 2>/dev/null)" || return 1
  [ "$st" = "RUNNING" ]
}

SCORE=0
TOTAL=0
check() {   # check <points> <label> <function>
  local pts="$1" label="$2" fn="$3"
  TOTAL=$((TOTAL + pts))
  if "$fn"; then
    SCORE=$((SCORE + pts))
    printf '  [PASS] %3d / %-3d  %s\n' "$pts" "$pts" "$label"
  else
    printf '  [FAIL] %3d / %-3d  %s\n' 0 "$pts" "$label"
  fi
}

report() {
  step "Checkpoint report"
  SCORE=0; TOTAL=0
  check 10 "Configure HTTP and health check firewall rules"            v_task1
  check 10 "Create a NAT configuration using Cloud Router"             v_task2
  check 20 "Create a custom image for a web server"                    v_task3
  check 20 "Configure an instance template and create instance groups" v_task4
  check 20 "Configure the Application Load Balancer (HTTP)"            v_task5
  check 20 "Stress test the Application Load Balancer (HTTP)"          v_task6
  printf '\n  SCORE: %d / %d\n' "$SCORE" "$TOTAL"
  printf '  Regions used: %s=%s  %s=%s  %s zone=%s\n' "$US_MIG" "$US_REGION" "$EU_MIG" "$EU_REGION" "$STRESS_VM" "$STRESS_ZONE"
  [ -n "$LB_IP_V4" ] && printf '  Load balancer: http://%s/   (IPv6: %s)\n' "$LB_IP_V4" "${LB_IP_V6:-n/a}"
  if [ "$SCORE" -eq "$TOTAL" ]; then
    printf '\n  All resources are in place. Now click "Check my progress" on each task in the lab page.\n'
    return 0
  fi
  printf '\n  Some checks failed. Re-run the script (it resumes automatically) or look at the log: %s\n' "$LOG_FILE"
  return 1
}

# --------------------------------- main --------------------------------------
main() {
  preflight
  detect_existing_locations

  if [ "$VERIFY_ONLY" = 1 ]; then
    read_lb_ips
    report
    exit $?
  fi

  task1_firewall
  task2_nat
  task3_image
  task4_template_and_migs
  task5_load_balancer
  task6_stress

  report
  exit $?
}

main
