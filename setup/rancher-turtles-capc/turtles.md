# Install Turtles + CAPC

This guide covers installing Rancher Turtles and configuring CAPC as a CAPI infrastructure provider on your Rancher-managed cluster.

## Prerequisites

- Rancher deployed on a CKS cluster (see [Rancher Deployment](./rancher.md))
- `kubectl` configured with cluster access
- Helm v3.12+
- CloudStack management server accessible from the cluster

## Step 1: Install Rancher Turtles

### Via Helm (Recommended)

```bash
# Add the Turtles Helm repo
helm repo add turtles https://rancher.github.io/turtles-helm-chart/
helm repo update

# Install Turtles
helm install turtles turtles/turtles \
  --namespace capi-system \
  --create-namespace \
  --set turtlesVersion=v0.20.0
```

### Verify Installation

```bash
kubectl get pods -n capi-system
# Expected output:
# NAME                                READY   STATUS
# turtles-controller-xxxxx            1/1     Running

kubectl get crds | grep turtles
# Expected: capiproviders.turtles-capi.cattle.io
```

## Step 2: Install Core CAPI Providers

Turtles needs the core CAPI controllers before installing infrastructure providers.

### Core Provider

```yaml
# core-provider.yaml
apiVersion: turtles-capi.cattle.io/v1alpha1
kind: CAPIProvider
metadata:
  name: core
  namespace: capi-providers
spec:
  name: cluster-api
  type: core
  config:
    manager:
      args: ["--leader-elect"]
```

### Bootstrap Provider (Kubeadm)

```yaml
# bootstrap-provider.yaml
apiVersion: turtles-capi.cattle.io/v1alpha1
kind: CAPIProvider
metadata:
  name: kubeadm-bootstrap
  namespace: capi-providers
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
  namespace: capi-providers
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
kubectl get CAPIProvider -n capi-providers
# Expected:
# NAME                  TYPE            STATE
# core                  core            Deployed
# kubeadm-bootstrap     bootstrap       Deployed
# kubeadm-control-plane controlPlane    Deployed

kubectl get pods -n capi-system | grep -E 'capi-controller|kubeadm'
# Expected: capi-controller-manager, capi-kubeadm-bootstrap, capi-kubeadm-control-plane
```

## Step 3: Configure CAPC Provider

### CloudStack Config Secret

Create the secret with CloudStack API credentials:

```yaml
# cloudstack-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: cloudstack-config
  namespace: capi-providers
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
kubectl create namespace capi-providers
kubectl apply -f cloudstack-secret.yaml
```

### CAPIProvider for CloudStack

```yaml
# cloudstack-provider.yaml
apiVersion: turtles-capi.cattle.io/v1alpha1
kind: CAPIProvider
metadata:
  name: cloudstack
  namespace: capi-providers
spec:
  name: cloudstack
  type: infrastructure
  # CAPC doesn't use Rancher cloud credentials
  # Use configSecret for CloudStack API credentials
  configSecret:
    name: cloudstack-config
  # Provider-specific configuration
  config:
    manager:
      args:
        - "--cloudstack-config-secret-name=cloudstack-config"
        - "--cloudstack-config-secret-namespace=capi-providers"
```

```bash
kubectl apply -f cloudstack-provider.yaml
```

### Verify CAPC Installation

```bash
# Check CAPIProvider status
kubectl get CAPIProvider -n capi-providers
# Expected: cloudstack  infrastructure  Deployed

# Check CAPC pods
kubectl get pods -n capi-system | grep cloudstack
# Expected: capc-controller-manager-xxxx running

# Check CRDs
kubectl get crds | grep cloudstack
# cloudstackclusters.infrastructure.cluster.x-k8s.io
# cloudstackclusters.infrastructure.cluster.x-k8s.io
# cloudstackmachines.infrastructure.cluster.x-k8s.io
# cloudstackmachinesets.infrastructure.cluster.x-k8s.io

# Check CAPC logs
kubectl logs -n capi-system -l app=cloudstack
# Should show successful CloudStack API connection
```

## Step 4: Provider Status Reference

### All Providers Together

```yaml
# All CAPI providers (apply all at once)
apiVersion: turtles-capi.cattle.io/v1alpha1
kind: CAPIProvider
metadata:
  name: core
  namespace: capi-providers
spec:
  name: cluster-api
  type: core
---
apiVersion: turtles-capi.cattle.io/v1alpha1
kind: CAPIProvider
metadata:
  name: kubeadm-bootstrap
  namespace: capi-providers
spec:
  name: kubeadm
  type: bootstrap
---
apiVersion: turtles-capi.cattle.io/v1alpha1
kind: CAPIProvider
metadata:
  name: kubeadm-control-plane
  namespace: capi-providers
spec:
  name: kubeadm
  type: controlPlane
---
apiVersion: turtles-capi.cattle.io/v1alpha1
kind: CAPIProvider
metadata:
  name: cloudstack
  namespace: capi-providers
spec:
  name: cloudstack
  type: infrastructure
  configSecret:
    name: cloudstack-config
```

```bash
kubectl apply -f all-providers.yaml
kubectl get CAPIProvider -n capi-providers
```

## Step 5: Provider Management

### Update Provider Version

```bash
# Edit the CAPIProvider to change version
kubectl edit CAPIProvider cloudstack -n capi-providers
# Change the version in the spec (if supported)
# Or delete and re-apply with new version
kubectl delete CAPIProvider cloudstack -n capi-providers
kubectl apply -f cloudstack-provider.yaml  # with updated version
```

### Remove a Provider

```bash
kubectl delete CAPIProvider cloudstack -n capi-providers
# Turtles will garbage collect all generated provider resources
```

### Check Provider Logs

```bash
# CAPC controller logs
kubectl logs -n capi-system -l app=cloudstack -f

# All CAPI provider logs
kubectl get pods -n capi-system -o wide
kubectl logs -n capi-system <pod-name> -f
```

## Troubleshooting

### Turtles Not Installing Providers

```bash
# Check Turtles controller logs
kubectl logs -n capi-system deployment/turtles-controller -f

# Check CAPIProvider status
kubectl describe CAPIProvider -n capi-providers

# Check for CRD conflicts
kubectl get crds | grep cluster-api
```

### Provider Stuck in "Installing" State

```bash
# Check the CAPIProvider status
kubectl describe CAPIProvider cloudstack -n capi-providers

# Check for events
kubectl get events -n capi-providers --sort-by='.lastTimestamp'

# Check CAPC controller logs
kubectl logs -n capi-system -l app=cloudstack -f
```

### CloudStack API Connection Failed

```bash
# Test connectivity from CAPC pod
kubectl exec -it -n capi-system deploy/capc-controller-manager -- \
  curl -v http://<management-server>:8080/client/api?command=listZones&apikey=<api-key>

# Verify secret is correct
kubectl get secret cloudstack-config -n capi-providers -o yaml

# Check for network policies blocking API access
kubectl get networkpolicies -n capi-providers
```

### CRDs Not Created

```bash
# Verify CAPC is running
kubectl get pods -n capi-system | grep cloudstack

# Check CAPC logs for errors
kubectl logs -n capi-system -l app=cloudstack | tail -50

# Manually verify CRDs exist
kubectl get crds | grep cloudstack
```

### CAPC Not Provisioning VMs

```bash
# Verify CloudStack API access from CAPC pod
kubectl exec -it -n capi-system deploy/capc-controller-manager -- \
  /bin/sh -c "echo test"

# Check CAPC logs
kubectl logs -n capi-system -l app=cloudstack -f

# Verify config secret
kubectl get secret cloudstack-config -n capi-providers -o yaml
```

## Next Steps

- [Create Clusters](./cluster.md) — Provision CKS clusters via CAPI CRDs
- [Fleet GitOps](./fleet.md) — Automate cluster management with Fleet
