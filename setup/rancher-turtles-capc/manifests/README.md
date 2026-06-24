# Rancher Turtles + CAPC Manifests

Pre-built manifests for deploying CAPI providers on a Rancher-managed cluster.

## Quick Start

### Option A: Individual files (recommended)

Apply in order:

```bash
kubectl apply -f 01-cloudstack-secret.yaml
kubectl apply -f 02-core-provider.yaml
kubectl apply -f 03-kubeadm-bootstrap-provider.yaml
kubectl apply -f 04-kubeadm-controlplane-provider.yaml
kubectl apply -f 05-cloudstack-provider.yaml
```

### Option B: All at once

```bash
kubectl apply -f 06-all-providers.yaml
```

## Verify

```bash
kubectl get capiprovider -n cattle-capi-system
# Expected: all 4 providers with PHASE=Ready
```

## Files

| File | Description |
|------|-------------|
| `01-cloudstack-secret.yaml` | CloudStack API credentials secret |
| `02-core-provider.yaml` | Core Cluster API controller |
| `03-kubeadm-bootstrap-provider.yaml` | Kubeadm bootstrap provider |
| `04-kubeadm-controlplane-provider.yaml` | Kubeadm control plane provider |
| `05-cloudstack-provider.yaml` | CloudStack infrastructure provider (CAPC) |
| `06-all-providers.yaml` | All providers combined |

## Namespace

All providers use `cattle-capi-system` — this is the namespace Rancher Turtles uses for CAPI provider management.
