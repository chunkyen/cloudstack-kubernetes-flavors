# Install Turtles + CAPC

This guide covers configuring CAPC as a CAPI infrastructure provider on a Rancher-managed cluster.

## 1. Prerequisites

- Rancher v2.13+ deployed on a CKS cluster (see [Rancher Deployment](./rancher.md))
- `kubectl` configured with cluster access
- Helm v3.12+
- CloudStack management server accessible from the cluster

## 2. Turtles — Pre-installed with Rancher v2.13+

Starting with Rancher v2.13, **Rancher Turtles is bundled as a system chart** and is automatically deployed when Rancher starts. There is no separate Turtles installation step.

### 2.1 Verify Turtles is Running

```bash
kubectl get pods -n cattle-turtles-system
# Expected:
# NAME                                         READY   STATUS
# rancher-turtles-controller-manager-xxxxx     1/1     Running

kubectl get crds | grep turtles
# Expected: capiproviders.turtles-capi.cattle.io
#           clusterctlconfigs.turtles-capi.cattle.io
```

The core CAPI controller and CRDs are also deployed automatically as part of the system chart.

### 2.2 Migrating from Rancher < v2.13

If your Rancher installation is **older than v2.13**, Turtles was previously a standalone Helm chart or Rancher extension. See the official [Rancher Turtles migration guide](https://turtles.docs.rancher.com/turtles/stable/en/tutorials/migration.html) for upgrade instructions.

## 3. Install Core CAPI Providers

Turtles uses the `CAPIProvider` custom resource to manage CAPI providers. All providers live in the `cattle-capi-system` namespace.

### 3.1 Core Provider

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

### 3.2 Bootstrap Provider (Kubeadm)

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

### 3.3 Control Plane Provider (Kubeadm)

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

### 3.4 Apply All Core Providers

```bash
kubectl apply -f core-provider.yaml
kubectl apply -f bootstrap-provider.yaml
kubectl apply -f controlplane-provider.yaml
```

### 3.5 Verify Core Providers

```bash
kubectl get capiprovider -n cattle-capi-system
# Expected:
# NAME                  TYPE            PROVIDERNAME      INSTALLEDVERSION   PHASE
# core                  core            cluster-api       v1.12.x            Ready
# kubeadm-bootstrap     bootstrap       kubeadm           v1.13.x            Ready
# kubeadm-control-plane controlPlane    kubeadm           v1.13.x            Ready
```

## 4. Configure CAPC Provider

### 4.1 CloudStack Config Secret

Create the secret with CloudStack API credentials:

```yaml
# cloudstack-secret.yaml — CAPC v1beta3
# Deploy in the same namespace as your cluster (not cattle-capi-system)
apiVersion: v1
kind: Secret
metadata:
  name: cloudstack-credentials
  namespace: <cluster-namespace>  # e.g., capc-cluster2
type: Opaque
stringData:
  # CloudStack management server endpoint (full URL with scheme)
  api-url: "http://<management-server>:8080/client/api"
  # API key (from CloudStack UI → Account → API Key)
  api-key: "<your-api-key>"
  # Secret key
  secret-key: "<your-secret-key>"
  # Verify SSL certificate (set to "false" for self-signed)
  verify-ssl: "false"
```

```bash
kubectl apply -f cloudstack-secret.yaml
```

> **Where to find CloudStack API credentials:**
> 1. Log into CloudStack UI
> 2. Click your account (top-right) → API Key
> 3. Copy the API key and secret key

### 4.2 CAPIProvider for CloudStack

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
    name: cloudstack-credentials
  # Enable CKS sync so CAPC registers workload clusters with syncWithACS: true
  # in CloudStack's Compute -> Kubernetes UI as ExternalManaged clusters.
  # The default CAPC deployment (including the Turtles manifests in this repo)
  # sets --enable-cloudstack-cks-sync=false.
  patches:
    - patch: |-
        [{"op": "replace", "path": "/spec/template/spec/containers/0/args/5", "value": "--enable-cloudstack-cks-sync=true"}]
      target:
        kind: Deployment
        name: capc-controller-manager
        namespace: cattle-capi-system
```

**Important:** A patch is required because CAPC defaults this controller flag to `false`. `spec.manager.additionalArgs` cannot be used here — it appends a duplicate arg rather than replacing the existing one, leaving the deployment with both `--enable-cloudstack-cks-sync=false` and `--enable-cloudstack-cks-sync=true`. The RFC 6902 JSON patch above replaces the existing flag at index 5.

### 4.3 Verify CAPC Installation

```bash
# Check CAPIProvider status
kubectl get capiprovider -n cattle-capi-system
# Expected: cloudstack  infrastructure  cloudstack  v0.6.x  Ready

# Check CAPC pods
kubectl get pods -n cattle-capi-system | grep capc
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

### 5.1 Combined Manifest

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
    name: cloudstack-credentials
  # Enable CKS sync so CAPC registers workload clusters with syncWithACS: true
  # in CloudStack's Compute -> Kubernetes UI as ExternalManaged clusters.
  patches:
    - patch: |-
        [{"op": "replace", "path": "/spec/template/spec/containers/0/args/5", "value": "--enable-cloudstack-cks-sync=true"}]
      target:
        kind: Deployment
        name: capc-controller-manager
        namespace: cattle-capi-system
```

```bash
kubectl apply -f all-providers.yaml
kubectl get capiprovider -n cattle-capi-system
```

## 6. Provider Management

### 6.1 Update Provider Version

```bash
# Edit the CAPIProvider to change version
kubectl edit CAPIProvider cloudstack -n cattle-capi-system
# Change the version in the spec (if supported)
# Or delete and re-apply with new version
kubectl delete CAPIProvider cloudstack -n cattle-capi-system
kubectl apply -f cloudstack-provider.yaml  # with updated version
```

### 6.2 Remove a Provider

```bash
kubectl delete CAPIProvider cloudstack -n cattle-capi-system
# Turtles will garbage collect all generated provider resources
```

### 6.3 Check Provider Logs

```bash
# CAPC controller logs
kubectl logs -n capc-system -l app=cloudstack -f

# All CAPI provider logs
# Turtles deploys all providers into cattle-capi-system (v0.6.1):
#   cattle-capi-system              — core CAPI + kubeadm bootstrap + kubeadm control-plane + CAPC
kubectl get pods -n cattle-capi-system | grep -E 'capi-controller|kubeadm|cloudstack|capc'
```

## 7. Troubleshooting

### 7.1 Turtles Not Installing Providers

```bash
# Check Turtles controller logs
kubectl logs -n cattle-turtles-system deployment/rancher-turtles-controller-manager -f

# Check CAPIProvider status
kubectl describe CAPIProvider -n cattle-capi-system

# Check for CRD conflicts
kubectl get crds | grep cluster-api
```

### 7.2 Provider Stuck in "Installing" State

```bash
# Check the CAPIProvider status
kubectl describe CAPIProvider cloudstack -n cattle-capi-system

# Check for events
kubectl get events -n cattle-capi-system --sort-by='.lastTimestamp'

# Check CAPC controller logs
kubectl logs -n capc-system -l app=cloudstack -f
```

### 7.3 CloudStack API Connection Failed

```bash
# Test connectivity from CAPC pod
kubectl exec -it -n capc-system deploy/capc-controller-manager -- \
  curl -v http://<management-server>:8080/client/api?command=listZones&apikey=<api-key>

# Verify secret is correct
kubectl get secret cloudstack-credentials -n <cluster-namespace> -o yaml

# Check for network policies blocking API access
kubectl get networkpolicies -n cattle-capi-system
```

### 7.4 CRDs Not Created

```bash
# Verify CAPC is running
kubectl get pods -n capc-system

# Check CAPC logs for errors
kubectl logs -n capc-system -l app=cloudstack | tail -50

# Manually verify CRDs exist
kubectl get crds | grep cloudstack
```

### 7.5 CAPC Not Provisioning VMs

```bash
# Verify CloudStack API access from CAPC pod
kubectl exec -it -n capc-system deploy/capc-controller-manager -- \
  /bin/sh -c "echo test"

# Check CAPC logs
kubectl logs -n capc-system -l app=cloudstack -f

# Verify config secret
kubectl get secret cloudstack-credentials -n <cluster-namespace> -o yaml
```

## 8. Next Steps

- [Create Clusters](./cluster.md) — Provision CKS clusters via CAPI CRDs
- [Fleet GitOps](./fleet.md) — Automate cluster management with Fleet
