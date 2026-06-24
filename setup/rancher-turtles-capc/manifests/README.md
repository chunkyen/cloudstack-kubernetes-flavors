# Rancher Turtles + CAPC Manifests

Pre-built manifests for deploying CAPI providers and clusters on a Rancher-managed cluster.

## Quick Start

### Deploy CAPI Providers

Apply in order:

```bash
kubectl apply -f 01-cloudstack-secret.yaml
kubectl apply -f 06-all-providers.yaml
kubectl get capiprovider -n cattle-capi-system
# Expected: all 4 providers with PHASE=Ready
```

### Deploy a Cluster

Replace placeholders in the YAML, then apply:

```bash
# Minimal (1 control + 2 workers)
kubectl apply -f 10-minimal-cluster.yaml

# HA (3 control + 3 workers)
kubectl apply -f 11-ha-cluster.yaml
```

## Files

### CAPI Providers

| File | Description |
|------|-------------|
| `01-cloudstack-secret.yaml` | CloudStack API credentials secret |
| `02-core-provider.yaml` | Core CAPI controller |
| `03-kubeadm-bootstrap-provider.yaml` | Kubeadm bootstrap provider |
| `04-kubeadm-controlplane-provider.yaml` | Kubeadm control plane provider |
| `05-cloudstack-provider.yaml` | CloudStack infrastructure provider (CAPC) |
| `06-all-providers.yaml` | All providers combined |

### Cluster Specs

| File | Description |
|------|-------------|
| `10-minimal-cluster.yaml` | Minimal cluster — 1 control plane + 2 workers |
| `11-ha-cluster.yaml` | HA cluster — 3 control planes + 3 workers |

## Namespace

All providers use `cattle-capi-system` — this is the namespace Rancher Turtles uses for CAPI provider management.

## Placeholders

Replace these before applying cluster manifests:

| Placeholder | Description |
|-------------|-------------|
| `<reserved-public-ip>` | A free public IP from CloudStack network |
| `<network-name-or-id>` | CloudStack network name or ID — CAPC creates it if it doesn't exist |
| `<zone-name-or-id>` | CloudStack zone name or ID |
| `capc-ubuntu-2404-kube-v1.32.3` | Your registered CAPI-compatible template name |
| `Medium` / `Large` | Your CloudStack service offering names |
| `Large` (diskOffering) | Your CloudStack disk offering name |
| `<YOUR_SSH_PUBLIC_KEY>` | Your SSH public key — embedded directly into KubeadmConfig, no CloudStack registration needed |
