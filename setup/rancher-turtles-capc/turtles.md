# Install Turtles + CAPC

This guide covers installing Rancher Turtles and configuring CAPC as a CAPI infrastructure provider on your Rancher-managed cluster.

## 1. Prerequisites

- Rancher deployed on a CKS cluster (see [Rancher Deployment](./rancher.md))
- `kubectl` configured with cluster access
- Helm v3.12+
- CloudStack management server accessible from the cluster

## 2. Install Rancher Turtles

### Via Helm (Recommended)

```bash
# Add the Turtles Helm repo
helm repo add turtles https://rancher.github.io/turtles-helm-chart/
helm repo update

# Install Turtles
helm install turtles turtles/turtles \
  --namespace cattle-turtles-system \
  --create-namespace \
  --set turtlesVersion=v0.24.0
```

### Verify Turtles Installation

```bash
kubectl get pods -n cattle-turtles-system
# Expected output:
# NAME                                         READY   STATUS
# rancher-turtles-controller-manager-xxxxx     1/1     Running

kubectl get crds | grep turtles
# Expected: capiproviders.turtles-capi.cattle.io
#           clusterctlconfigs.turtles-capi.cattle.io
```

> **Note:** Rancher v2.13+ ships Turtles as a system chart, so it may already be installed. Check with `helm list -n cattle-turtles-system`.

## 3. Install Core CAPI Providers

Turtles uses the `CAPIProvider` custom resource to manage CAPI providers. All providers live in the `cattle-capi-system` namespace.

### Core Provider

```yaml
# core-provider.yaml
apiVersion: turtles-capi.cattle.io/v1alpha1
kind: CAPIProvider
metadata:
  name: core
  namespace: cattle-capi-system
spec:
  name: cluster-api
  type: core
```

### Bootstrap Provider (Kubeadm)

```yaml
# bootstrap-provider.yaml
apiVersion: turtles-capi.cattle.io/v1alpha1
kind: CAPIProvider
metadata:
  name: kubeadm-bootstrap
  namespace: cattle-capi-system
spec:
  name: kubeadm
  type: bootstrap
```

### Control Plane Provider (Kubeadm)

```yaml
# controlplane-provider.yaml
apiVersion: turtles-capi.cattle.io/v1alpha1
kind: CAPIProvider
metadata:
  name: kubeadm-control-plane
  namespace: cattle-capi-system
spec:
  name: kubeadm
  type: controlPlane
```

### Apply All Core Providers

```bash
kubectl apply -f core-provider.yaml
kubectl apply -f bootstrap-provider.yaml
kubectl apply -f controlplane-provider.yaml
```

### Verify Core Providers

```bash
kubectl get capiprovider -n cattle-capi-system
# Expected:
# NAME                  TYPE            PROVIDERNAME      INSTALLEDVERSION   PHASE
# core                  core            cluster-api       v1.12.x            Ready
# kubeadm-bootstrap     bootstrap       kubeadm           v1.13.x            Ready
# kubeadm-control-plane controlPlane    kubeadm           v1.13.x            Ready
```

## 4. Configure CAPC Provider

### CloudStack Config Secret

Create the secret with CloudStack API credentials:

```yaml
# cloudstack-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: cloudstack-config
  namespace: cattle-capi-system
type: Opaque
stringData:
  # CloudStack API endpoint
  CLOUDSTACK_ENDPOINT: "http://<management-server>:8080/client/api"
  # API key (from CloudStack UI → Account → API Key)
  CLOUDSTACK_API_KEY: "<your-api-key>"
  # Secret key
  CLOUDSTACK_SECRET_KEY: "<your-secret-key>"
  # Zone ID (optional — can be specified per-cluster)
  CLOUDSTACK_DEFAULT_ZONE: "<zone-id>"
  # Network ID (optional — can be specified per-cluster)
  CLOUDSTACK_DEFAULT_NETWORK: "<network-id>"
  # Region (optional — for multi-region setups)
  CLOUDSTACK_REGION: "<region-name>"
```

```bash
kubectl apply -f cloudstack-secret.yaml
```

> **Where to find CloudStack API credentials:**
> 1. Log into CloudStack UI
> 2. Click your account (top-right) → API Key
> 3. Copy the API key and secret key

### CAPIProvider for CloudStack

```yaml
# cloudstack-provider.yaml
apiVersion: turtles-capi.cattle.io/v1alpha1
kind: CAPIProvider
metadata:
  name: cloudstack
  namespace: cattle-capi-system
spec:
  name: cloudstack
  type: infrastructure
  configSecret:
    name: cloudstack-config
```

```bash
kubectl apply -f cloudstack-provider.yaml
```

### Verify CAPC Installation

```bash
# Check CAPIProvider status
kubectl get capiprovider -n cattle-capi-system
# Expected: cloudstack  infrastructure  cloudstack  v0.6.x  Ready

# Check CAPC pods
kubectl get pods -n capc-system
# Expected: capc-controller-manager-xxxx  1/1  Running

# Check CRDs
kubectl get crds | grep cloudstack
# cloudstackclusters.infrastructure.cluster.x-k8s.io
# cloudstackclusterresourcesets.infrastructure.cluster.x-k8s.io
# cloudstackmachines.infrastructure.cluster.x-k8s.io
# cloudstackmachinesets.infrastructure.cluster.x-k8s.io

# Check CAPC logs
kubectl logs -n capc-system -l app=cloudstack
# Should show successful CloudStack API connection
```

## 5. All Providers Together

### Combined Manifest

```yaml
# all-providers.yaml
apiVersion: turtles-capi.cattle.io/v1alpha1
kind: CAPIProvider
metadata:
  name: core
  namespace: cattle-capi-system
spec:
  name: cluster-api
  type: core
---
apiVersion: turtles-capi.cattle.io/v1alpha1
kind: CAPIProvider
metadata:
  name: kubeadm-bootstrap
  namespace: cattle-capi-system
spec:
  name: kubeadm
  type: bootstrap
---
apiVersion: turtles-capi.cattle.io/v1alpha1
kind: CAPIProvider
metadata:
  name: kubeadm-control-plane
  namespace: cattle-capi-system
spec:
  name: kubeadm
  type: controlPlane
---
apiVersion: turtles-capi.cattle.io/v1alpha1
kind: CAPIProvider
metadata:
  name: cloudstack
  namespace: cattle-capi-system
spec:
  name: cloudstack
  type: infrastructure
  configSecret:
    name: cloudstack-config
```

```bash
kubectl apply -f all-providers.yaml
kubectl get capiprovider -n cattle-capi-system
```

## 6. Provider Management

### Update Provider Version

```bash
# Edit the CAPIProvider to change version
kubectl edit CAPIProvider cloudstack -n cattle-capi-system
# Change the version in the spec (if supported)
# Or delete and re-apply with new version
kubectl delete CAPIProvider cloudstack -n cattle-capi-system
kubectl apply -f cloudstack-provider.yaml  # with updated version
```

### Remove a Provider

```bash
kubectl delete CAPIProvider cloudstack -n cattle-capi-system
# Turtles will garbage collect all generated provider resources
```

### Check Provider Logs

```bash
# CAPC controller logs
kubectl logs -n capc-system -l app=cloudstack -f

# All CAPI provider logs
# Turtles installs providers into separate namespaces:
#   cattle-capi-system              — core CAPI controller
#   capi-kubeadm-bootstrap-system   — kubeadm bootstrap
#   capi-kubeadm-control-plane-system — kubeadm control-plane
#   capc-system                     — CloudStack infrastructure
kubectl get pods -A | grep -E 'capi-controller|kubeadm|cloudstack'
```

## 7. Troubleshooting

### Turtles Not Installing Providers

```bash
# Check Turtles controller logs
kubectl logs -n cattle-turtles-system deployment/rancher-turtles-controller-manager -f

# Check CAPIProvider status
kubectl describe CAPIProvider -n cattle-capi-system

# Check for CRD conflicts
kubectl get crds | grep cluster-api
```

### Provider Stuck in "Installing" State

```bash
# Check the CAPIProvider status
kubectl describe CAPIProvider cloudstack -n cattle-capi-system

# Check for events
kubectl get events -n cattle-capi-system --sort-by='.lastTimestamp'

# Check CAPC controller logs
kubectl logs -n capc-system -l app=cloudstack -f
```

### CloudStack API Connection Failed

```bash
# Test connectivity from CAPC pod
kubectl exec -it -n capc-system deploy/capc-controller-manager -- \
  curl -v http://<management-server>:8080/client/api?command=listZones&apikey=<api-key>

# Verify secret is correct
kubectl get secret cloudstack-config -n cattle-capi-system -o yaml

# Check for network policies blocking API access
kubectl get networkpolicies -n cattle-capi-system
```

### CRDs Not Created

```bash
# Verify CAPC is running
kubectl get pods -n capc-system

# Check CAPC logs for errors
kubectl logs -n capc-system -l app=cloudstack | tail -50

# Manually verify CRDs exist
kubectl get crds | grep cloudstack
```

### CAPC Not Provisioning VMs

```bash
# Verify CloudStack API access from CAPC pod
kubectl exec -it -n capc-system deploy/capc-controller-manager -- \
  /bin/sh -c "echo test"

# Check CAPC logs
kubectl logs -n capc-system -l app=cloudstack -f

# Verify config secret
kubectl get secret cloudstack-config -n cattle-capi-system -o yaml
```

## 8. Next Steps

- [Create Clusters](./cluster.md) — Provision CKS clusters via CAPI CRDs
- [Fleet GitOps](./fleet.md) — Automate cluster management with Fleet
