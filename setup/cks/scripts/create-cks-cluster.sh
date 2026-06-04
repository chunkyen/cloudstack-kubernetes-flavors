#!/usr/bin/env bash
#
# create-cks-cluster.sh — Automate creating a CKS cluster on CloudStack.
#
# Usage:
#   ./create-cks-cluster.sh [OPTIONS]
#
# Options:
#   -p PROFILE        cmk profile name (default: localcloud)
#   -z ZONE           Zone ID or name
#   -n NETWORK        Network ID or name
#   -v K8S_VERSION    Kubernetes version (e.g., v1.32.0)
#   -c CONTROL_NODES  Control plane node count (default: 3)
#   -w WORKER_NODES   Worker node count (default: 2)
#   -k KEYPAIR        SSH keypair name
#   -s SERVICE_OFFERING  Service offering ID
#   -t TEMPLATE       Node template ID
#   --csi             Enable CloudStack CSI driver
#   --dry-run         Print commands without executing
#   -i                Interactive mode (prompt for all values)
#
# Prerequisites:
#   - cmk (CloudMonkey) installed and configured with a profile
#   - CKS-compatible ISO already registered in CloudStack
#   - Network offering for Kubernetes is enabled
#
# What this script does:
#   1. Detects available resources (zones, networks, templates, offerings)
#   2. Prompts interactively or uses CLI flags to select resources
#   3. Enables the CKS plugin via global configuration
#   4. Registers a K8s-supported version from an ISO (if needed)
#   5. Creates a CKS cluster with the specified parameters
#   6. Waits for the cluster to become ready
#   7. Downloads the kubeconfig
#
# Author: OpenClaw (based on CloudStack CKS documentation)
# License: MIT

set -euo pipefail

# ─── Defaults ───────────────────────────────────────────────────────────────
PROFILE="localcloud"
ZONE=""
NETWORK=""
K8S_VERSION=""
K8S_VERSION_ID=""
CONTROL_NODES=3
WORKER_NODES=2
KEYPAIR=""
SERVICE_OFFERING=""
TEMPLATE=""
CSI_ENABLED=false
DRY_RUN=false
INTERACTIVE=false
ISO_URL=""
ZONE_ID=""
ZONE_NAME=""
NETWORK_ID=""
NETWORK_NAME=""
TEMPLATE_NAME=""
OFFERING_NAME=""
KEYPAIR_NAME=""
CLUSTER_ID=""

# ─── Colors ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Helpers ────────────────────────────────────────────────────────────────
log()   { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# cmk wrapper — always returns 0, stores output in CMK_OUT.
# On failure, sets CMK_ERR and CMK_RC. Never kills the script.
CMK_OUT=""
CMK_ERR=""
CMK_RC=0

cmk() {
  if [[ "$DRY_RUN" == true ]]; then
    log "[DRY-RUN] cmk -p $PROFILE $*"
    CMK_OUT='{}'
    CMK_ERR=""
    CMK_RC=0
    return 0
  fi
  CMK_OUT=$(cmk -p "$PROFILE" "$@" 2>&1) || CMK_RC=$?
  if [[ $CMK_RC -ne 0 ]]; then
    CMK_ERR="$CMK_OUT"
    CMK_OUT='{}'
  fi
  return 0
}

cmk_ok() { [[ $CMK_RC -eq 0 ]]; }

# ─── Interactive Menu Helper ────────────────────────────────────────────────
# Usage: show_menu "Title" "Header1|Header2|..." "id1|name1|desc1,id2|name2|desc2,..."
# Sets SELECTED_ID and SELECTED_NAME
show_menu() {
  local title="$1"
  local headers="$2"
  local items="$3"
  local IFS='|'
  local cols
  read -ra cols <<< "$headers"

  echo -e "\n${BOLD}${CYAN}═══ $title ═══${NC}"

  # Calculate column widths
  local widths=()
  for col in "${cols[@]}"; do
    widths+=( ${#col} )
  done
  IFS=','
  for item in $items; do
    IFS='|' read -ra fields <<< "$item"
    local idx=0
    for field in "${fields[@]}"; do
      if [[ ${#field} -gt ${widths[$idx]} ]]; then
        widths[$idx]=${#field}
      fi
      ((idx++)) || true
    done
  done

  # Print header
  local header_fmt=""
  local line=""
  for w in "${widths[@]}"; do
    header_fmt+="%-${w}s  "
    line+=$(printf '%*s' "$w" '' | tr ' ' '-')
    line+="--"
  done
  printf "${header_fmt}\n" "${cols[@]}"
  echo "$line"

  # Print items with numbers
  local idx=1
  IFS=','
  for item in $items; do
    IFS='|' read -ra fields <<< "$item"
    printf "  ${BOLD}%d${NC}. " "$idx"
    printf "${header_fmt}\n" "${fields[@]}"
    ((idx++)) || true
  done

  # Prompt
  local prompt="Select option (1-${idx-1}, or enter ID directly): "
  local choice
  read -p "${prompt}" choice

  if [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -lt $idx ]]; then
    local selected_item
    IFS=','
    local count=0
    for item in $items; do
      ((count++)) || true
      if [[ $count -eq $choice ]]; then
        selected_item="$item"
        break
      fi
    done
    IFS='|' read -ra fields <<< "$selected_item"
    SELECTED_ID="${fields[0]}"
    SELECTED_NAME="${fields[1]}"
  elif [[ "$choice" =~ ^[a-f0-9-]{36}$ ]]; then
    SELECTED_ID="$choice"
    SELECTED_NAME="(by ID)"
  else
    echo -e "${RED}Invalid choice: $choice${NC}"
    return 1
  fi
  return 0
}

# ─── Parse Arguments ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    -p|--profile)          PROFILE="$2"; shift 2 ;;
    -z|--zone)             ZONE="$2"; shift 2 ;;
    -n|--network)          NETWORK="$2"; shift 2 ;;
    -v|--k8s-version)      K8S_VERSION="$2"; shift 2 ;;
    -c|--control-nodes)    CONTROL_NODES="$2"; shift 2 ;;
    -w|--worker-nodes)     WORKER_NODES="$2"; shift 2 ;;
    -k|--keypair)          KEYPAIR="$2"; shift 2 ;;
    -s|--service-offering) SERVICE_OFFERING="$2"; shift 2 ;;
    -t|--template)         TEMPLATE="$2"; shift 2 ;;
    --csi)                 CSI_ENABLED=true; shift ;;
    --dry-run)             DRY_RUN=true; shift ;;
    -i|--interactive)      INTERACTIVE=true; shift ;;
    *)                     error "Unknown option: $1"; exit 1 ;;
  esac
done

# ─── Pre-flight Checks ──────────────────────────────────────────────────────
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "CloudStack CKS Cluster Creator"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if ! command -v cmk &>/dev/null; then
  error "cmk (CloudMonkey) not found in PATH. Install it first."
  exit 1
fi

if ! command -v jq &>/dev/null; then
  error "jq not found in PATH. Install it first."
  exit 1
fi

# ─── Step 0: Detect Zone ────────────────────────────────────────────────────
log "Detecting zones..."

if [[ -z "$ZONE" ]] || [[ "$INTERACTIVE" == true ]]; then
  cmk list zones pagesize=50
  if ! cmk_ok; then
    error "Failed to list zones: $(cmk_err)"
    error "Is CloudStack management server reachable? (Profile: $PROFILE)"
    exit 1
  fi
  ZONE_COUNT=$(echo "$CMK_OUT" | jq '.zone | length // 0' 2>/dev/null || echo 0)

  if [[ $ZONE_COUNT -eq 0 ]]; then
    error "No zones found."
    exit 1
  fi

  if [[ $ZONE_COUNT -eq 1 ]] && [[ -z "$ZONE" ]]; then
    ZONE_ID=$(echo "$CMK_OUT" | jq -r '.zone[0].id // empty')
    ZONE_NAME=$(echo "$CMK_OUT" | jq -r '.zone[0].name // empty')
    log "Auto-selected zone: $ZONE_NAME ($ZONE_ID)"
  else
    ZONE_ITEMS=""
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      [[ -n "$ZONE_ITEMS" ]] && ZONE_ITEMS+=","
      ZONE_ITEMS+="$line"
    done < <(echo "$CMK_OUT" | jq -r '.zone[] | [.id, .name, .state] | @csv' 2>/dev/null | sed 's/"//g' | sed 's/,/|/g')

    if [[ -z "$ZONE_ITEMS" ]]; then
      error "Failed to parse zone data. Raw output:"
      echo "$CMK_OUT" | head -20
      exit 1
    fi

    if ! show_menu "Available Zones" "ID|Name|State" "$ZONE_ITEMS"; then
      error "Failed to select a zone."
      exit 1
    fi
    ZONE_ID="$SELECTED_ID"
    ZONE_NAME="$SELECTED_NAME"
    log "Selected zone: $ZONE_NAME ($ZONE_ID)"
  fi
else
  cmk list zones id="$ZONE" pagesize=1
  ZONE_ID=$(echo "$CMK_OUT" | jq -r '.zone[0].id // empty' 2>/dev/null || true)
  if [[ -z "$ZONE_ID" ]]; then
    cmk list zones namepattern="^${ZONE}$" pagesize=1
    ZONE_ID=$(echo "$CMK_OUT" | jq -r '.zone[0].id // empty' 2>/dev/null || true)
  fi
  if [[ -z "$ZONE_ID" ]]; then
    error "Zone not found: $ZONE"
    exit 1
  fi
  ZONE_NAME=$(echo "$CMK_OUT" | jq -r '.zone[0].name // empty')
  log "Zone: $ZONE_NAME ($ZONE_ID)"
fi

# ─── Step 1: Detect Isolated Networks ───────────────────────────────────────
log "Detecting isolated networks in zone..."

if [[ -z "$NETWORK" ]] || [[ "$INTERACTIVE" == true ]]; then
  cmk list networks zoneid="$ZONE_ID" ispublic=false pagesize=50
  if ! cmk_ok; then
    error "Failed to list networks: $(cmk_err)"
    exit 1
  fi
  NET_COUNT=$(echo "$CMK_OUT" | jq '.network | length // 0' 2>/dev/null || echo 0)

  if [[ $NET_COUNT -eq 0 ]]; then
    error "No isolated networks found in zone $ZONE_NAME. Create one first."
    exit 1
  fi

  if [[ $NET_COUNT -eq 1 ]] && [[ -z "$NETWORK" ]]; then
    NETWORK_ID=$(echo "$CMK_OUT" | jq -r '.network[0].id // empty')
    NETWORK_NAME=$(echo "$CMK_OUT" | jq -r '.network[0].name // empty')
    log "Auto-selected network: $NETWORK_NAME ($NETWORK_ID)"
  else
    NET_ITEMS=""
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      [[ -n "$NET_ITEMS" ]] && NET_ITEMS+=","
      NET_ITEMS+="$line"
    done < <(echo "$CMK_OUT" | jq -r '.network[] | [.id, .name, .state, .traffictype] | @csv' 2>/dev/null | sed 's/"//g' | sed 's/,/|/g')

    if [[ -z "$NET_ITEMS" ]]; then
      error "Failed to parse network data."
      exit 1
    fi

    if ! show_menu "Available Networks" "ID|Name|State|Traffic" "$NET_ITEMS"; then
      error "Failed to select a network."
      exit 1
    fi
    NETWORK_ID="$SELECTED_ID"
    NETWORK_NAME="$SELECTED_NAME"
    log "Selected network: $NETWORK_NAME ($NETWORK_ID)"
  fi
else
  cmk list networks id="$NETWORK" pagesize=1
  NETWORK_ID=$(echo "$CMK_OUT" | jq -r '.network[0].id // empty' 2>/dev/null || true)
  if [[ -z "$NETWORK_ID" ]]; then
    cmk list networks namepattern="^${NETWORK}$" zoneid="$ZONE_ID" pagesize=1
    NETWORK_ID=$(echo "$CMK_OUT" | jq -r '.network[0].id // empty' 2>/dev/null || true)
  fi
  if [[ -z "$NETWORK_ID" ]]; then
    error "Network not found: $NETWORK"
    exit 1
  fi
  NETWORK_NAME=$(echo "$CMK_OUT" | jq -r '.network[0].name // empty')
  log "Network: $NETWORK_NAME ($NETWORK_ID)"
fi

# ─── Step 2: Detect Templates ───────────────────────────────────────────────
log "Detecting available templates..."

if [[ -z "$TEMPLATE" ]] || [[ "$INTERACTIVE" == true ]]; then
  cmk list templates zoneid="$ZONE_ID" type=user pagesize=50
  if ! cmk_ok; then
    warn "Failed to list templates: $(cmk_err)"
    warn "Will use default template from K8s version."
    TEMPLATE="default"
    TEMPLATE_NAME="(default from K8s version)"
  else
    TPL_COUNT=$(echo "$CMK_OUT" | jq '.template | length // 0' 2>/dev/null || echo 0)

    if [[ $TPL_COUNT -eq 0 ]]; then
      warn "No user templates found. Will use default template from K8s version."
      TEMPLATE="default"
      TEMPLATE_NAME="(default from K8s version)"
    else
      if [[ $TPL_COUNT -eq 1 ]] && [[ -z "$TEMPLATE" ]]; then
        TEMPLATE=$(echo "$CMK_OUT" | jq -r '.template[0].id // empty')
        TEMPLATE_NAME=$(echo "$CMK_OUT" | jq -r '.template[0].name // empty')
        log "Auto-selected template: $TEMPLATE_NAME ($TEMPLATE)"
      else
        TPL_ITEMS=""
        while IFS= read -r line; do
          [[ -z "$line" ]] && continue
          [[ -n "$TPL_ITEMS" ]] && TPL_ITEMS+=","
          TPL_ITEMS+="$line"
        done < <(echo "$CMK_OUT" | jq -r '.template[] | [.id, .name, .ostypename, .hypervisor] | @csv' 2>/dev/null | sed 's/"//g' | sed 's/,/|/g')

        if [[ -z "$TPL_ITEMS" ]]; then
          error "Failed to parse template data."
          exit 1
        fi

        if ! show_menu "Available Templates" "ID|Name|OS|Hypervisor" "$TPL_ITEMS"; then
          error "Failed to select a template."
          exit 1
        fi
        TEMPLATE="$SELECTED_ID"
        TEMPLATE_NAME="$SELECTED_NAME"
        log "Selected template: $TEMPLATE_NAME ($TEMPLATE)"
      fi
    fi
  fi
else
  TEMPLATE_NAME="(by ID)"
  log "Template: ID $TEMPLATE"
fi

# ─── Step 3: Detect Service Offerings ───────────────────────────────────────
log "Detecting service offerings..."

if [[ -z "$SERVICE_OFFERING" ]] || [[ "$INTERACTIVE" == true ]]; then
  cmk list serviceofferings pagesize=50
  if ! cmk_ok; then
    error "Failed to list service offerings: $(cmk_err)"
    exit 1
  fi
  OFF_COUNT=$(echo "$CMK_OUT" | jq '.serviceoffering | length // 0' 2>/dev/null || echo 0)

  if [[ $OFF_COUNT -eq 0 ]]; then
    error "No service offerings found."
    exit 1
  fi

  if [[ $OFF_COUNT -eq 1 ]] && [[ -z "$SERVICE_OFFERING" ]]; then
    SERVICE_OFFERING=$(echo "$CMK_OUT" | jq -r '.serviceoffering[0].id // empty')
    OFFERING_NAME=$(echo "$CMK_OUT" | jq -r '.serviceoffering[0].name // empty')
    log "Auto-selected offering: $OFFERING_NAME ($SERVICE_OFFERING)"
  else
    OFF_ITEMS=""
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      [[ -n "$OFF_ITEMS" ]] && OFF_ITEMS+=","
      OFF_ITEMS+="$line"
    done < <(echo "$CMK_OUT" | jq -r '.serviceoffering[] | [.id, .name, (.cpunumber|tostring), (.memory|tostring), (.servicetype // "")] | @csv' 2>/dev/null | sed 's/"//g' | sed 's/,/|/g')

    if [[ -z "$OFF_ITEMS" ]]; then
      error "Failed to parse service offering data."
      exit 1
    fi

    if ! show_menu "Available Service Offerings" "ID|Name|CPU|Mem(MB)|Type" "$OFF_ITEMS"; then
      error "Failed to select a service offering."
      exit 1
    fi
    SERVICE_OFFERING="$SELECTED_ID"
    OFFERING_NAME="$SELECTED_NAME"
    log "Selected offering: $OFFERING_NAME ($SERVICE_OFFERING)"
  fi
else
  OFFERING_NAME="(by ID)"
  log "Service offering: ID $SERVICE_OFFERING"
fi

# ─── Step 4: Detect K8s Supported Versions ──────────────────────────────────
log "Detecting registered K8s versions..."

if [[ -z "$K8S_VERSION" ]] || [[ "$INTERACTIVE" == true ]]; then
  cmk listKubernetesSupportedVersions pagesize=50
  if ! cmk_ok; then
    error "Failed to list K8s versions: $(cmk_err)"
    error "Is CKS plugin enabled?"
    exit 1
  fi
  K8S_COUNT=$(echo "$CMK_OUT" | jq '.kubernetessupportedversion | length // 0' 2>/dev/null || echo 0)

  if [[ $K8S_COUNT -eq 0 ]]; then
    warn "No K8s versions registered. You'll need to register one first."
    echo "  See: docs/setup/cks/upgrade.md for ISO registration steps."
    exit 1
  fi

  if [[ $K8S_COUNT -eq 1 ]] && [[ -z "$K8S_VERSION" ]]; then
    K8S_VERSION_ID=$(echo "$CMK_OUT" | jq -r '.kubernetessupportedversion[0].id // empty')
    K8S_VERSION=$(echo "$CMK_OUT" | jq -r '.kubernetessupportedversion[0].name // empty')
    log "Auto-selected K8s version: $K8S_VERSION ($K8S_VERSION_ID)"
  else
    K8S_ITEMS=""
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      [[ -n "$K8S_ITEMS" ]] && K8S_ITEMS+=","
      K8S_ITEMS+="$line"
    done < <(echo "$CMK_OUT" | jq -r '.kubernetessupportedversion[] | [.id, .name, (.semanticversion // ""), (.state // "")] | @csv' 2>/dev/null | sed 's/"//g' | sed 's/,/|/g')

    if [[ -z "$K8S_ITEMS" ]]; then
      error "Failed to parse K8s version data."
      exit 1
    fi

    if ! show_menu "Registered K8s Versions" "ID|Name|Semantic|State" "$K8S_ITEMS"; then
      error "Failed to select a K8s version."
      exit 1
    fi
    K8S_VERSION_ID="$SELECTED_ID"
    K8S_VERSION="$SELECTED_NAME"
    log "Selected K8s version: $K8S_VERSION ($K8S_VERSION_ID)"
  fi
else
  cmk listKubernetesSupportedVersions keyword="$K8S_VERSION" pagesize=1
  K8S_VERSION_ID=$(echo "$CMK_OUT" | jq -r '.kubernetessupportedversion[0].id // empty' 2>/dev/null || true)
  if [[ -z "$K8S_VERSION_ID" ]]; then
    error "K8s version not found: $K8S_VERSION"
    exit 1
  fi
  log "K8s version: $K8S_VERSION ($K8S_VERSION_ID)"
fi

# ─── Step 5: Detect Keypairs ────────────────────────────────────────────────
log "Detecting SSH keypairs..."

if [[ -z "$KEYPAIR" ]] || [[ "$INTERACTIVE" == true ]]; then
  cmk list sshkeypairs pagesize=50
  if ! cmk_ok; then
    warn "Failed to list SSH keypairs (API may not be available). Skipping."
    KEYPAIR=""
    KEYPAIR_NAME="(none)"
  else
    KEY_COUNT=$(echo "$CMK_OUT" | jq '.sshkeypair | length // 0' 2>/dev/null || echo 0)

    if [[ $KEY_COUNT -eq 0 ]]; then
      warn "No SSH keypairs found. Cluster will be created without SSH keypair."
      KEYPAIR=""
      KEYPAIR_NAME="(none)"
    else
      if [[ $KEY_COUNT -eq 1 ]] && [[ -z "$KEYPAIR" ]]; then
        KEYPAIR=$(echo "$CMK_OUT" | jq -r '.sshkeypair[0].name // empty')
        KEYPAIR_NAME="$KEYPAIR"
        log "Auto-selected keypair: $KEYPAIR"
      else
        KEY_ITEMS=""
        while IFS= read -r line; do
          [[ -z "$line" ]] && continue
          [[ -n "$KEY_ITEMS" ]] && KEY_ITEMS+=","
          KEY_ITEMS+="$line"
        done < <(echo "$CMK_OUT" | jq -r '.sshkeypair[] | [.name, .fingerprint, .hypervisor] | @csv' 2>/dev/null | sed 's/"//g' | sed 's/,/|/g')

        if [[ -z "$KEY_ITEMS" ]]; then
          warn "Failed to parse keypair data. Skipping."
          KEYPAIR=""
          KEYPAIR_NAME="(none)"
        else
          if ! show_menu "SSH Keypairs" "Name|Fingerprint|Hypervisor" "$KEY_ITEMS"; then
            error "Failed to select a keypair."
            exit 1
          fi
          KEYPAIR="$SELECTED_ID"
          KEYPAIR_NAME="$KEYPAIR"
          log "Selected keypair: $KEYPAIR"
        fi
      fi
    fi
  fi
else
  KEYPAIR_NAME="$KEYPAIR"
  log "Keypair: $KEYPAIR"
fi

# ─── Step 6: Interactive Node Counts ────────────────────────────────────────
if [[ "$INTERACTIVE" == true ]]; then
  echo -e "\n${BOLD}${CYAN}═══ Cluster Sizing ═══${NC}"
  read -p "Control plane nodes (default 3): " input
  CONTROL_NODES=${input:-3}
  read -p "Worker nodes (default 2): " input
  WORKER_NODES=${input:-2}
  read -p "Enable CSI driver? [y/N]: " input
  [[ "$input" == "y" || "$input" == "Y" ]] && CSI_ENABLED=true
fi

# ─── Summary ────────────────────────────────────────────────────────────────
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "Configuration Summary"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "  Profile:       $PROFILE"
log "  Zone:          $ZONE_NAME ($ZONE_ID)"
log "  Network:       $NETWORK_NAME ($NETWORK_ID)"
log "  Template:      $TEMPLATE_NAME ($TEMPLATE)"
log "  Service Offer: $OFFERING_NAME ($SERVICE_OFFERING)"
log "  K8s Version:   $K8S_VERSION ($K8S_VERSION_ID)"
log "  Control Nodes: $CONTROL_NODES"
log "  Worker Nodes:  $WORKER_NODES"
log "  Keypair:       ${KEYPAIR:-none}"
log "  CSI Driver:    $(if $CSI_ENABLED; then echo 'enabled'; else echo 'disabled'; fi)"
log "  Dry Run:       $DRY_RUN"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ "$DRY_RUN" != true ]]; then
  read -p "Proceed with cluster creation? [y/N]: " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    log "Aborted."
    exit 0
  fi
fi

# ─── Step 7: Enable CKS Plugin ──────────────────────────────────────────────
log "Enabling CKS plugin..."

cmk listConfigurations name="cloud.kubernetes.service.enabled"
CKS_ENABLED=$(echo "$CMK_OUT" | jq -r '.configuration[0].value // empty' 2>/dev/null || true)
if [[ "$CKS_ENABLED" != "true" ]]; then
  log "Enabling cloud.kubernetes.service.enabled=true..."
  cmk updateConfiguration name=cloud.kubernetes.service.enabled value=true
  if ! cmk_ok; then
    error "Failed to enable CKS plugin: $(cmk_err)"
    exit 1
  fi
else
  log "CKS plugin already enabled."
fi

cmk listConfigurations name="endpoint.url"
ENDPOINT_URL=$(echo "$CMK_OUT" | jq -r '.configuration[0].value // empty' 2>/dev/null || true)
if [[ -z "$ENDPOINT_URL" ]]; then
  cmk listConfigurations category="Management Server"
  MGMT_SERVER=$(echo "$CMK_OUT" | jq -r '.configuration[] | select(.name == "management.server") | .value' 2>/dev/null || echo "localhost")
  ENDPOINT_URL="http://${MGMT_SERVER}:8080/client/api"
  log "Setting endpoint.url=$ENDPOINT_URL..."
  cmk updateConfiguration name=endpoint.url value="$ENDPOINT_URL"
  if ! cmk_ok; then
    error "Failed to set endpoint URL: $(cmk_err)"
    exit 1
  fi
else
  log "Endpoint URL already set: $ENDPOINT_URL"
fi

if [[ "$DRY_RUN" != true ]]; then
  log "⚠️  Management server restart required for changes to take effect."
  warn "Run: service cloudstack-management restart (or reboot the management host)"
  read -p "Continue after restart? [y/N]: " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    log "Aborted. Restart the management server and re-run this script."
    exit 0
  fi
fi

# ─── Step 8: Create CKS Cluster ─────────────────────────────────────────────
log "Creating CKS cluster..."

CLUSTER_NAME="cks-$(date +%Y%m%d-%H%M%S)"
log "Cluster name: $CLUSTER_NAME"

CREATE_ARGS=(
  --name "$CLUSTER_NAME"
  --zoneid "$ZONE_ID"
  --networkid "$NETWORK_ID"
  --kubernetesversionid "$K8S_VERSION_ID"
  --controlnodes "$CONTROL_NODES"
  --size "$WORKER_NODES"
)

[[ -n "$KEYPAIR" ]] && CREATE_ARGS+=(--keypair "$KEYPAIR")
[[ -n "$SERVICE_OFFERING" ]] && CREATE_ARGS+=(--serviceofferingid "$SERVICE_OFFERING")
[[ -n "$TEMPLATE" && "$TEMPLATE" != "default" ]] && CREATE_ARGS+=(--nodetemplates "$TEMPLATE")
$CSI_ENABLED && CREATE_ARGS+=(--enablecsi true)

log "Creating cluster with args: ${CREATE_ARGS[*]}"
cmk createKubernetesCluster "${CREATE_ARGS[@]}"
if ! cmk_ok; then
  error "Failed to create cluster: $(cmk_err)"
  exit 1
fi

CLUSTER_ID=$(echo "$CMK_OUT" | jq -r '.kubernetescluster.id // empty')
CLUSTER_STATE=$(echo "$CMK_OUT" | jq -r '.kubernetescluster.state // empty')
log "Cluster created: $CLUSTER_NAME (ID: $CLUSTER_ID, State: $CLUSTER_STATE)"

# ─── Step 9: Wait for Cluster Ready ─────────────────────────────────────────
log "Waiting for cluster to become ready..."

MAX_WAIT=600
INTERVAL=30
ELAPSED=0

while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  cmk listKubernetesClusters id="$CLUSTER_ID"
  if cmk_ok; then
    STATE=$(echo "$CMK_OUT" | jq -r '.kubernetescluster[0].state // empty')
  else
    STATE="(unknown)"
  fi
  log "  State: $STATE (${ELAPSED}s elapsed)"

  if [[ "$STATE" == "Running" ]]; then
    log "✅ Cluster is Running!"
    break
  elif [[ "$STATE" == "Error" || "$STATE" == "Stopped" ]]; then
    error "Cluster state: $STATE. Check CloudStack UI for details."
    exit 1
  fi

  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done

if [[ $ELAPSED -ge $MAX_WAIT ]]; then
  warn "Cluster didn't reach Running state within ${MAX_WAIT}s. It may still be provisioning."
fi

# ─── Step 10: Get kubeconfig ────────────────────────────────────────────────
log "Retrieving kubeconfig..."

KUBECONFIG_FILE="${CLUSTER_NAME}.kubeconfig"
cmk getKubernetesClusterConfig id="$CLUSTER_ID"
if ! cmk_ok; then
  warn "Failed to get kubeconfig: $(cmk_err)"
else
  echo "$CMK_OUT" | jq -r '.kubernetesclusterconfig.kubeconfig // .kubeconfig // empty' > "$KUBECONFIG_FILE" 2>/dev/null || true
  if [[ -s "$KUBECONFIG_FILE" ]]; then
    chmod 600 "$KUBECONFIG_FILE"
    log "kubeconfig saved to: $KUBECONFIG_FILE"
  else
    warn "kubeconfig is empty. Check cluster state in CloudStack UI."
  fi
fi

# ─── Step 11: Verify Cluster ────────────────────────────────────────────────
if [[ -s "$KUBECONFIG_FILE" ]] && command -v kubectl &>/dev/null; then
  log "Verifying cluster..."
  NODE_COUNT=$(kubectl --kubeconfig="$KUBECONFIG_FILE" get nodes --no-headers 2>/dev/null | wc -l || echo "0")
  log "Nodes visible: $NODE_COUNT (expected: $((CONTROL_NODES + WORKER_NODES)))"

  if [[ "$NODE_COUNT" -gt 0 ]]; then
    log "Node status:"
    kubectl --kubeconfig="$KUBECONFIG_FILE" get nodes -o wide 2>/dev/null || true
  else
    warn "No nodes visible yet. Wait a few minutes and retry."
  fi
fi

# ─── Final Summary ──────────────────────────────────────────────────────────
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "✅ CKS Cluster Created!"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "  Cluster:    $CLUSTER_NAME ($CLUSTER_ID)"
log "  kubeconfig: $KUBECONFIG_FILE"
log "  Zone:       $ZONE_NAME ($ZONE_ID)"
log "  Network:    $NETWORK_NAME ($NETWORK_ID)"
log "  K8s Ver:    $K8S_VERSION ($K8S_VERSION_ID)"
log "  Nodes:      ${CONTROL_NODES} control + ${WORKER_NODES} worker"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log ""
log "Next steps:"
log "  export KUBECONFIG=$KUBECONFIG_FILE"
log "  kubectl get nodes"
log ""
log "  To install CAPC on this cluster:"
log "    cd ../capc/scripts/"
log "    ./install-capc-on-cluster.sh -k $KUBECONFIG_FILE"
log ""
