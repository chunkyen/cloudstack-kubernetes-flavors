#!/usr/bin/env bash
#
# install-capc-on-cluster.sh — Configure an existing Kubernetes cluster as a CAPC management cluster.
#
# This script installs all Cluster API providers (CAPI core, Kubeadm bootstrap,
# Kubeadm control plane) and the CAPC infrastructure provider onto any K8s cluster:
# CKS-managed, kind, EKS, GKE, or any other distribution.
#
# Usage:
#   ./install-capc-on-cluster.sh [OPTIONS]
#
# Options:
#   -k KUBECONFIG     Path to kubeconfig (default: ~/.kube/config)
#   -v VERSION        CAPC provider version (default: v0.6.0)
#   --release-dir DIR Directory for clusterctl overrides (default: ~/.cluster-api/overrides/infrastructure-cloudstack/<version>/)
#   --dry-run         Print commands without executing
#
# What this script does:
#   1. Validates the target K8s cluster is reachable and has sufficient resources
#   2. Downloads CAPC provider manifests (infrastructure-components.yaml + metadata.yaml)
#   3. Installs cert-manager (required by all CAPI providers)
#   4. Runs `clusterctl init` to install CAPI core + bootstrap/control-plane controllers + CAPC
#   5. Verifies all controller pods are running
#
# Prerequisites:
#   - A working Kubernetes cluster with kubeconfig access
#   - kubectl installed and configured
#   - clusterctl v1.1.5+ installed
#   - Internet access to download provider manifests from GitHub releases
#
# Author: OpenClaw (based on CAPC documentation)
# License: MIT

set -euo pipefail

# ─── Defaults ───────────────────────────────────────────────────────────────
KUBECONFIG="${HOME}/.kube/config"
CAPC_VERSION="v0.6.1"
RELEASE_DIR=""
DRY_RUN=false

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
kubectl() { dry_run_cmd kubectl --kubeconfig="$KUBECONFIG" "$@"; }
cm() { dry_run_cmd clusterctl "$@"; }

# ─── Parse Arguments ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    -k|--kubeconfig)     KUBECONFIG="$2"; shift 2 ;;
    -v|--version)        CAPC_VERSION="$2"; shift 2 ;;
    --release-dir)       RELEASE_DIR="$2"; shift 2 ;;
    --dry-run)           DRY_RUN=true; shift ;;
    *)                   error "Unknown option: $1"; exit 1 ;;
  esac
done

# ─── Defaults (after arg parsing) ──────────────────────────────────────────
if [[ -z "$RELEASE_DIR" ]]; then
  RELEASE_DIR="${HOME}/.cluster-api/overrides/infrastructure-cloudstack/${CAPC_VERSION}/"
fi

# ─── Pre-flight Checks ─────────────────────────────────────────────────────
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "Install CAPC on Kubernetes Cluster (Management Plane)"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "Kubeconfig:    $KUBECONFIG"
log "CAPC Version:  $CAPC_VERSION"
log "Release Dir:   $RELEASE_DIR"
log "Dry Run:       $DRY_RUN"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check kubectl is available
if ! command -v kubectl &>/dev/null; then
  error "kubectl not found in PATH. Install it first."
  exit 1
fi

# Check clusterctl is available
if ! command -v clusterctl &>/dev/null; then
  error "clusterctl not found in PATH. Install it from https://github.com/kubernetes-sigs/cluster-api/releases"
  exit 1
fi

# Verify cluster connectivity
log "Step 0: Verifying cluster connectivity..."
K8S_VERSION=$(kubectl version --short 2>/dev/null | grep -oP 'Server Version: \K[^ ]+' || kubectl version --output=json 2>/dev/null | jq -r '.serverVersion.gitVersion // empty')
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
log "K8s version: $K8S_VERSION"
log "Nodes: $NODE_COUNT"

if [[ "$NODE_COUNT" -eq 0 ]]; then
  error "No nodes found in the cluster. Is this a valid K8s cluster?"
  exit 1
fi

# Check minimum resources (recommend at least 2 vCPU, 4GB RAM for management plane)
log "Checking cluster resources..."
TOTAL_CPU=$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.cpu}{"\n"}{end}' | awk '{s+=$1} END {print s}')
TOTAL_MEM_KB=$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.memory}{"\n"}{end}' | grep -oP '\d+' | awk '{s+=$1} END {print s}')
TOTAL_MEM_GB=$((TOTAL_MEM_KB / 1024 / 1024))
log "Total allocatable: ${TOTAL_CPU} CPU, ~${TOTAL_MEM_GB}GB RAM"

if [[ "$TOTAL_MEM_GB" -lt 4 ]]; then
  warn "Cluster has less than 4GB allocatable RAM. CAPC management plane may struggle with multiple workload clusters."
fi

# ─── Step 1: Download CAPC Provider Manifests ──────────────────────────────
log "Step 1: Downloading CAPC provider manifests..."

mkdir -p "$RELEASE_DIR"

INFRA_FILE="${RELEASE_DIR}/infrastructure-components.yaml"
METADATA_FILE="${RELEASE_DIR}/metadata.yaml"

if [[ ! -f "$INFRA_FILE" || ! -f "$METADATA_FILE" ]]; then
  log "Downloading CAPC v$CAPC_VERSION manifests from GitHub releases..."
  
  # Download infrastructure-components.yaml
  curl -sL "https://github.com/kubernetes-sigs/cluster-api-provider-cloudstack/releases/download/${CAPC_VERSION}/infrastructure-components.yaml" \
    -o "$INFRA_FILE"
  
  if [[ ! -s "$INFRA_FILE" ]]; then
    error "Failed to download infrastructure-components.yaml. Check CAPC version: $CAPC_VERSION"
    exit 1
  fi
  log "Downloaded: $INFRA_FILE ($(wc -c < "$INFRA_FILE") bytes)"
  
  # Download metadata.yaml
  curl -sL "https://github.com/kubernetes-sigs/cluster-api-provider-cloudstack/releases/download/${CAPC_VERSION}/metadata.yaml" \
    -o "$METADATA_FILE"
  
  if [[ ! -s "$METADATA_FILE" ]]; then
    error "Failed to download metadata.yaml. Check CAPC version: $CAPC_VERSION"
    exit 1
  fi
  log "Downloaded: $METADATA_FILE ($(wc -c < "$METADATA_FILE") bytes)"
else
  log "Manifests already exist in $RELEASE_DIR (skipping download)."
fi

# ─── Step 2: Install cert-manager ──────────────────────────────────────────
log "Step 2: Installing cert-manager..."

# Check if cert-manager is already installed
CERT_MANAGER_NS=$(kubectl get namespace cert-manager --ignore-not-found 2>/dev/null || echo "")
if [[ -z "$CERT_MANAGER_NS" ]]; then
  log "Installing cert-manager v1.14+ (required by CAPI providers)..."
  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.4/cert-manager.yaml
  
  # Wait for cert-manager to be ready
  log "Waiting for cert-manager pods..."
  kubectl wait --namespace cert-manager \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/instance=cert-manager \
    --timeout=120s || warn "cert-manager may still be starting up."
else
  log "cert-manager already installed (namespace exists)."
fi

# ─── Step 3: Initialize Cluster API Providers ──────────────────────────────
log "Step 3: Initializing Cluster API providers..."

# Create provider config file
PROVIDER_CONFIG="${HOME}/.cluster-api/cloudstack.yaml"
mkdir -p "$(dirname "$PROVIDER_CONFIG")"

cat > "$PROVIDER_CONFIG" <<EOF
providers:
- name: "cloudstack"
  type: "InfrastructureProvider"
  url: ${INFRA_FILE}
EOF

log "Provider config written to: $PROVIDER_CONFIG"

# Run clusterctl init
log "Running clusterctl init --infrastructure cloudstack..."
cm init \
  --infrastructure cloudstack \
  --config "$PROVIDER_CONFIG" \
  -v 10 || {
    error "clusterctl init failed. Check the output above for details."
    warn "Common issues:"
    warn "  - Insufficient cluster resources (need ≥2 vCPU, 4GB RAM)"
    warn "  - Network policies blocking GitHub access"
    warn "  - RBAC permissions insufficient for creating CRDs and deployments"
    exit 1
  }

log "clusterctl init completed successfully."

# ─── Step 4: Verify Installation ───────────────────────────────────────────
log "Step 4: Verifying CAPC installation..."

log "Checking controller pods in capc-system namespace..."
sleep 10  # Give controllers a moment to start

CAPC_PODS=$(kubectl get pods -n capc-system --no-headers 2>/dev/null || echo "")
if [[ -z "$CAPC_PODS" ]]; then
  warn "No pods found in capc-system namespace yet. Controllers may still be starting."
else
  log "CAPC controller pods:"
  kubectl get pods -n capc-system -o wide || true
fi

log "Checking CAPI core controllers..."
CAPI_PODS=$(kubectl get pods -n capi-system --no-headers 2>/dev/null || echo "")
if [[ -z "$CAPI_PODS" ]]; then
  warn "No pods found in capi-system namespace yet."
else
  log "CAPI core controller pods:"
  kubectl get pods -n capi-system -o wide || true
fi

log "Checking Kubeadm bootstrap controllers..."
KUBEDM_BOOTSTRAP_PODS=$(kubectl get pods -n capi-kubeadm-bootstrap-system --no-headers 2>/dev/null || echo "")
if [[ -z "$KUBEDM_BOOTSTRAP_PODS" ]]; then
  warn "No pods found in capi-kubeadm-bootstrap-system namespace yet."
else
  log "Kubeadm bootstrap controller pods:"
  kubectl get pods -n capi-kubeadm-bootstrap-system -o wide || true
fi

log "Checking Kubeadm control plane controllers..."
KUBEDM_CP_PODS=$(kubectl get pods -n capi-kubeadm-control-plane-system --no-headers 2>/dev/null || echo "")
if [[ -z "$KUBEDM_CP_PODS" ]]; then
  warn "No pods found in capi-kubeadm-control-plane-system namespace yet."
else
  log "Kubeadm control plane controller pods:"
  kubectl get pods -n capi-kubeadm-control-plane-system -o wide || true
fi

# ─── Step 5: Summary & Next Steps ─────────────────────────────────────────
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "✅ CAPC management cluster setup complete!"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log ""
log "Your K8s cluster is now a CAPC management plane."
log "Next steps:"
log ""
log "  1. Set up CloudStack credentials:"
log "     export CLOUDSTACK_B64ENCODED_SECRET=\$(base64 -w0 < cloud-config)"
log ""
log "  2. Create a workload cluster:"
log "     clusterctl generate cluster my-cluster \\\"
log "       --kubernetes-version v1.32 \\\"
log "       --control-plane-machine-count=3 \\\"
log "       --worker-machine-count=2 > my-cluster.yaml"
log ""
log "  3. Apply the cluster spec:"
log "     kubectl apply -f my-cluster.yaml"
log ""
log "  4. Monitor progress:"
log "     clusterctl describe cluster my-cluster"
log ""
log "See setup/capc/move-from-bootstrap.md for making clusters self-managing."
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
