# Deploy Rancher on CKS Cluster

This guide walks through deploying Rancher on a CKS cluster to serve as the management plane for Turtles + CAPC.

## Prerequisites

- A CKS cluster running on CloudStack (see [CKS Setup Guide](../cks/cks.md))
- `kubectl` configured with cluster access
- `helm` v3.12+
- Sufficient cluster resources (minimum 3 control plane + 2 workers, 4vCPU/8GB each)

## Step 1: Prepare Storage

Rancher needs persistent storage for etcd data. On CKS, you have two options:

### Option A: CloudStack CSI Driver (Recommended)

```bash
# Enable CSI during CKS cluster creation
# Or deploy CSI manually after cluster creation
kubectl apply -f https://raw.githubusercontent.com/cloudstack/cluster-api-provider-cloudstack/main/infrastructure-components.yaml
# Or use the CloudStack CSI driver manifest
kubectl apply -f https://raw.githubusercontent.com/apache/cloudstack-kubernetes-csi-driver/main/deploy/kubernetes/csi/cloudstack-csi.yaml
```

### Option B: Local Path Provisioner (Quick Start)

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

## Step 2: Install Rancher

### Via Helm (Recommended)

```bash
# Add the Rancher Helm repo
helm repo add rancher-stable https://releases.rancher.com/server-charts/stable
helm repo update

# Create namespace
kubectl create namespace cattle-system

# Install Rancher
# For production: use ingress with TLS
helm install rancher rancher-stable/rancher \
  --namespace cattle-system \
  --set hostname=rancher.<your-domain> \
  --set replicas=3

# For testing: use the built-in TLS
kubectl apply -f https://releases.rancher.com/install/latest/rancher.yaml
```

### Via kubectl (Quick Test)

```bash
# Creates a Deployment with 1 replica and a Service
kubectl apply -f https://releases.rancher.com/install/latest/rancher.yaml
```

## Step 3: Access Rancher

### Get Admin Password

```bash
kubectl -n cattle-system get secret \
  $(kubectl -n cattle-system get secret \
    -o name | grep bootstrap-secret) \
  -o jsonpath='{.data.bootstrapPassword}' | base64 -d
```

### Access UI

- **Local install**: `kubectl port-forward svc/rancher -n cattle-system 9443:443` → https://localhost:9443
- **With hostname**: https://rancher.<your-domain>

### First Login

1. Navigate to Rancher URL
2. Enter the bootstrap password
3. Set a new admin password
4. Set the Rancher server URL (hostname or IP)

## Step 4: Configure Local Cluster

Rancher automatically imports the bootstrap cluster as the "local" cluster. Verify:

```bash
# In Rancher UI: Clusters → local → should show as Active
# Or via kubectl:
kubectl cluster-info
# Should show Rancher API server
```

## Step 5: Install Turtles

### Via Helm

```bash
# Add Turtles Helm repo
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
# Expect: turtles-controller-xxxx running

kubectl get crds | grep turtles
# Expect: capiproviders.turtles-capi.cattle.io
```

## Step 6: Configure CAPC Provider

### Create CloudStack Config Secret

```yaml
# cloudstack-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: cloudstack-config
  namespace: capi-providers
type: Opaque
stringData:
  CLOUDSTACK_ENDPOINT: "http://<management-server>:8080/client/api"
  CLOUDSTACK_API_KEY: "<your-api-key>"
  CLOUDSTACK_SECRET_KEY: "<your-secret-key>"
  CLOUDSTACK_DEFAULT_ZONE: "<zone-id>"
  CLOUDSTACK_DEFAULT_NETWORK: "<network-id>"
```

```bash
kubectl create namespace capi-providers
kubectl apply -f cloudstack-secret.yaml
```

### Deploy CAPC via Turtles

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
  configSecret:
    name: cloudstack-config
  config:
    manager:
      args:
        - "--cloudstack-config-secret-name=cloudstack-config"
        - "--cloudstack-config-secret-namespace=capi-providers"
```

```bash
kubectl apply -f cloudstack-provider.yaml
```

### Verify CAPC

```bash
# Check provider status
kubectl get CAPIProvider -n capi-providers

# Check CAPC pods
kubectl get pods -n capi-system | grep cloudstack

# Check CRDs
kubectl get crds | grep cloudstack
# cloudstackclusters.infrastructure.cluster.x-k8s.io
# cloudstackmachines.infrastructure.cluster.x-k8s.io
# cloudstackmachinesets.infrastructure.cluster.x-k8s.io
```

## Troubleshooting

### Rancher Pods Not Starting

```bash
# Check Rancher logs
kubectl logs -n cattle-system deployment/rancher -f

# Check storage
kubectl get pvc -n cattle-system
kubectl get storageclass
```

### Turtles Not Installing Providers

```bash
# Check Turtles controller logs
kubectl logs -n capi-system deployment/turtles-controller -f

# Check CAPIProvider status
kubectl describe CAPIProvider -n capi-providers

# Check for CRD conflicts
kubectl get crds | grep cluster-api
```

### CAPC Not Provisioning VMs

```bash
# Verify CloudStack API access
kubectl exec -it deploy/capc-controller-manager -n capi-system -- \
  /bin/sh -c "echo test"

# Check CAPC logs
kubectl logs -n capi-system -l app=cloudstack -f

# Verify config secret
kubectl get secret cloudstack-config -n capi-providers -o yaml
```

## Next Steps

- [Install Turtles + CAPC](./turtles.md) — Detailed provider configuration
- [Create Clusters](./cluster.md) — Provision CKS clusters via CAPI
- [Fleet GitOps](./fleet.md) — Automate with Fleet
