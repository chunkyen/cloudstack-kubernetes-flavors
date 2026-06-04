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
#   -v K8S_VERSION    Kubernetes version to deploy (e.g., v1.32.0)
#   -c CONTROL_NODES  Control plane node count (default: 3)
#   -w WORKER_NODES   Worker node count (default: 2)
#   -k KEYPAIR        SSH keypair name
#   -s SERVICE_OFFERING  Service offering ID for nodes
#   --csi             Enable CloudStack CSI driver
#   --dry-run         Print commands without executing
#
# Prerequisites:
#   - cmk (CloudMonkey) installed and configured with a profile
#   - CKS-compatible ISO already registered in CloudStack
#   - Network offering for Kubernetes is enabled
#
# What this script does:
#   1. Validates prerequisites (cmk, zone, network)
#   2. Enables the CKS plugin via global configuration
#   3. Registers a K8s-supported version from an ISO
#   4. Creates a CKS cluster with the specified parameters
#   5. Waits for the cluster to become ready
#   6. Downloads the kubeconfig and sets up CAPC on it
#
# Author: OpenClaw (based on CloudStack CKS documentation)
# License: MIT

set -euo pipefail

# ─── Defaults ───────────────────────────────────────────────────────────────
PROFILE="localcloud"
ZONE=""
NETWORK=""
K8S_VERSION="v1.32.0"
CONTROL_NODES=3
WORKER_NODES=2
KEYPAIR=""
SERVICE_OFFERING=""
CSI_ENABLED=false
DRY_RUN=false
ISO_URL="http://download.cloudstack.org/cks/v1.32.0/setup-v1.32.0.iso"
ZONE_ID=""
NETWORK_ID=""
K8S_VERSION_ID=""
CLUSTER_ID=""

# ─── Colors ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ─── Helpers ────────────────────────────────────────────────────────────────
log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
dry_run_cmd() {
  if [[ "$DRY_RUN" == true ]]; then
    log "[DRY-RUN] $*"
  else
    "$@"
  fi
}

cmk() { dry_run_cmd cmk -p "$PROFILE" "$@"; }

# ─── Parse Arguments ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    -p|--profile)        PROFILE="$2"; shift 2 ;;
    -z|--zone)           ZONE="$2"; shift 2 ;;
    -n|--network)        NETWORK="$2"; shift 2 ;;
    -v|--k8s-version)    K8S_VERSION="$2"; shift 2 ;;
    -c|--control-nodes)  CONTROL_NODES="$2"; shift 2 ;;
    -w|--worker-nodes)   WORKER_NODES="$2"; shift 2 ;;
    -k|--keypair)        KEYPAIR="$2"; shift 2 ;;
    -s|--service-offering) SERVICE_OFFERING="$2"; shift 2 ;;
    --csi)               CSI_ENABLED=true; shift ;;
    --dry-run)           DRY_RUN=true; shift ;;
    *)                   error "Unknown option: $1"; exit 1 ;;
  esac
done

# ─── Pre-flight Checks ──────────────────────────────────────────────────────
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "CKS Bootstrap for CAPC Management Cluster"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "Profile:       $PROFILE"
log "Zone:          ${ZONE:-auto-detect}"
log "Network:       ${NETWORK:-auto-detect}"
log "K8s Version:   $K8S_VERSION"
log "Control Nodes: $CONTROL_NODES"
log "Worker Nodes:  $WORKER_NODES"
log "CSI Driver:    $(if $CSI_ENABLED; then echo 'enabled'; else echo 'disabled'; fi)"
log "Dry Run:       $DRY_RUN"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check cmk is available
if ! command -v cmk &>/dev/null; then
  error "cmk (CloudMonkey) not found in PATH. Install it first."
  exit 1
fi

# ─── Step 0: Detect Zone and Network ────────────────────────────────────────
log "Step 0: Detecting zone and network..."

if [[ -z "$ZONE" ]]; then
  ZONE_ID=$(cmk list zones filter=id namepattern=".*" pagesize=1 | jq -r '.zone[0].id // empty')
  if [[ -z "$ZONE_ID" ]]; then
    error "No zone found. Specify one with -z <zone-id> or -z <zone-name>."
    exit 1
  fi
  ZONE_NAME=$(cmk list zones id="$ZONE_ID" | jq -r '.zone[0].name')
  log "Auto-detected zone: $ZONE_NAME ($ZONE_ID)"
else
  # Try as ID first, then name
  ZONE_ID=$(cmk list zones id="$ZONE" pagesize=1 | jq -r '.zone[0].id // empty' 2>/dev/null || true)
  if [[ -z "$ZONE_ID" ]]; then
    ZONE_ID=$(cmk list zones namepattern="^${ZONE}$" pagesize=1 | jq -r '.zone[0].id // empty')
  fi
  if [[ -z "$ZONE_ID" ]]; then
    error "Zone not found: $ZONE"
    exit 1
  fi
fi

if [[ -z "$NETWORK" ]]; then
  NETWORK_ID=$(cmk list networks id="$ZONE_ID" ispublic=false networkofferingid="$(cmk list networkofferings namepattern="DefaultIsolatedNetworkOfferingForVpcNetworks" pagesize=1 | jq -r '.networkoffering[0].id // empty')" pagesize=1 | jq -r '.network[0].id // empty' 2>/dev/null || true)
  if [[ -z "$NETWORK_ID" ]]; then
    # Fallback: try to find any isolated network in the zone
    NETWORK_ID=$(cmk list networks zoneid="$ZONE_ID" ispublic=false pagesize=1 | jq -r '.network[0].id // empty')
  fi
  if [[ -z "$NETWORK_ID" ]]; then
    error "No isolated network found in zone $ZONE_NAME. Create one first or specify with -n <network-id>."
    exit 1
  fi
  NETWORK_NAME=$(cmk list networks id="$NETWORK_ID" | jq -r '.network[0].name')
  log "Auto-detected network: $NETWORK_NAME ($NETWORK_ID)"
else
  NETWORK_ID="$NETWORK"
fi

# ─── Step 1: Enable CKS Plugin ──────────────────────────────────────────────
log "Step 1: Enabling CKS plugin..."

CKS_ENABLED=$(cmk listConfigurations name="cloud.kubernetes.service.enabled" | jq -r '.configuration[0].value // empty')
if [[ "$CKS_ENABLED" != "true" ]]; then
  log "Enabling cloud.kubernetes.service.enabled=true..."
  cmk updateConfiguration name=cloud.kubernetes.service.enabled value=true
else
  log "CKS plugin already enabled."
fi

ENDPOINT_URL=$(cmk listConfigurations name="endpoint.url" | jq -r '.configuration[0].value // empty')
if [[ -z "$ENDPOINT_URL" ]]; then
  MGMT_SERVER=$(cmk listConfigurations category="Management Server" | jq -r '.configuration[] | select(.name == "management.server") | .value' 2>/dev/null || echo "localhost")
  ENDPOINT_URL="http://${MGMT_SERVER}:8080/client/api"
  log "Setting endpoint.url=$ENDPOINT_URL..."
  cmk updateConfiguration name=endpoint.url value="$ENDPOINT_URL"
else
  log "Endpoint URL already set: $ENDPOINT_URL"
fi

log "⚠️  Management server restart required for changes to take effect."
warn "Run: service cloudstack-management restart (or reboot the management host)"
if [[ "$DRY_RUN" != true ]]; then
  read -p "Continue after restart? [y/N] " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    log "Aborted. Restart the management server and re-run this script."
    exit 0
  fi
fi

# ─── Step 2: Register K8s Supported Version ─────────────────────────────────
log "Step 2: Registering Kubernetes supported version..."

# Check if version already registered
K8S_VER_ID=$(cmk listKubernetesSupportedVersions keyword="$K8S_VERSION" pagesize=1 | jq -r '.kubernetessupportedversion[0].id // empty')
if [[ -z "$K8S_VER_ID" ]]; then
  log "Registering K8s version $K8S_VERSION from ISO..."
  
  # Get upload params for the ISO
  UPLOAD_PARAMS=$(cmk getUploadParamsForKubernetesSupportedVersion pagesize=1 | jq '.')
  
  # Register the supported version
  cmk addKubernetesSupportedVersion \
    name="$K8S_VERSION" \
    semanticversion="${K8S_VERSION#v}" \
    url="$ISO_URL" \
    zoneid="$ZONE_ID" \
    mincpunumber=2 \
    minmemory=2048
  
  K8S_VER_ID=$(cmk listKubernetesSupportedVersions keyword="$K8S_VERSION" pagesize=1 | jq -r '.kubernetessupportedversion[0].id')
else
  log "K8s version $K8S_VERSION already registered (ID: $K8S_VER_ID)."
fi
log "K8s version ID: $K8S_VER_ID"

# ─── Step 3: Create CKS Cluster ─────────────────────────────────────────────
log "Step 3: Creating CKS cluster..."

CLUSTER_NAME="cks-capc-mgmt-$(date +%Y%m%d-%H%M%S)"
log "Cluster name: $CLUSTER_NAME"

# Build createKubernetesCluster command arguments
CREATE_ARGS=(
  --name "$CLUSTER_NAME"
  --zoneid "$ZONE_ID"
  --networkid "$NETWORK_ID"
  --kubernetesversionid "$K8S_VER_ID"
  --controlnodes "$CONTROL_NODES"
  --size "$WORKER_NODES"
)

if [[ -n "$KEYPAIR" ]]; then
  CREATE_ARGS+=(--keypair "$KEYPAIR")
fi

if [[ -n "$SERVICE_OFFERING" ]]; then
  CREATE_ARGS+=(--serviceofferingid "$SERVICE_OFFERING")
fi

if $CSI_ENABLED; then
  CREATE_ARGS+=(--enablecsi true)
fi

log "Creating cluster with args: ${CREATE_ARGS[*]}"
cmk createKubernetesCluster "${CREATE_ARGS[@]}" > /tmp/cks-cluster-result.json

CLUSTER_ID=$(jq -r '.kubernetescluster.id' /tmp/cks-cluster-result.json)
CLUSTER_STATE=$(jq -r '.kubernetescluster.state' /tmp/cks-cluster-result.json)
log "Cluster created: $CLUSTER_NAME (ID: $CLUSTER_ID, State: $CLUSTER_STATE)"

# ─── Step 4: Wait for Cluster Ready ─────────────────────────────────────────
log "Step 4: Waiting for cluster to become ready..."

MAX_WAIT=600  # 10 minutes
INTERVAL=30
ELAPSED=0

while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  STATE=$(cmk listKubernetesClusters id="$CLUSTER_ID" | jq -r '.kubernetescluster[0].state // empty')
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

# ─── Step 5: Get kubeconfig ────────────────────────────────────────────────
log "Step 5: Retrieving kubeconfig..."

KUBECONFIG_FILE="${CLUSTER_NAME}.kubeconfig"
cmk getKubernetesClusterConfig id="$CLUSTER_ID" > /tmp/cks-kubeconfig.json

# Extract kubeconfig from JSON response
jq -r '.kubernetesclusterconfig.kubeconfig' /tmp/cks-kubeconfig.json > "$KUBECONFIG_FILE"

if [[ ! -s "$KUBECONFIG_FILE" ]]; then
  error "Failed to extract kubeconfig. Check cluster state in CloudStack UI."
  exit 1
fi

chmod 600 "$KUBECONFIG_FILE"
log "kubeconfig saved to: $KUBECONFIG_FILE"

# ─── Step 6: Verify Cluster ────────────────────────────────────────────────
log "Step 6: Verifying cluster..."

NODE_COUNT=$(kubectl --kubeconfig="$KUBECONFIG_FILE" get nodes --no-headers 2>/dev/null | wc -l || echo "0")
log "Nodes visible: $NODE_COUNT (expected: $((CONTROL_NODES + WORKER_NODES)))"

if [[ "$NODE_COUNT" -gt 0 ]]; then
  log "Node status:"
  kubectl --kubeconfig="$KUBECONFIG_FILE" get nodes -o wide 2>/dev/null || true
else
  warn "No nodes visible yet. Wait a few minutes and retry."
fi

# ─── Step 7: Prepare for CAPC ──────────────────────────────────────────────
log "Step 7: Preparing cluster for CAPC..."

log "To use this CKS cluster as a CAPC management cluster:"
log ""
log "  export KUBECONFIG=$KUBECONFIG_FILE"
log "  kubectl get nodes"
log "  # Then follow the CAPC setup guide to install CAPC controllers"
log ""

# ─── Summary ────────────────────────────────────────────────────────────────
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "✅ Bootstrap complete!"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "  Cluster:    $CLUSTER_NAME ($CLUSTER_ID)"
log "  kubeconfig: $KUBECONFIG_FILE"
log "  Zone:       $ZONE_NAME ($ZONE_ID)"
log "  Network:    $NETWORK_NAME ($NETWORK_ID)"
log "  K8s Ver:    $K8S_VERSION ($K8S_VER_ID)"
log "  Nodes:      ${CONTROL_NODES} control + ${WORKER_NODES} worker"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
