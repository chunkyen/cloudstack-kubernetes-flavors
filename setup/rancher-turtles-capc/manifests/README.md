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

# Custom image setup with inline cloud-init (advanced)
kubectl apply -f 12-custom-image-cluster.yaml
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
| `10-minimal-cluster.yaml` | Minimal cluster — 1 control plane + 2 workers (Method 1: CloudStack SSH KeyPair) |
| `11-ha-cluster.yaml` | HA cluster — 3 control planes + 3 workers (Method 1: CloudStack SSH KeyPair) |
| `12-custom-image-cluster.yaml` | Custom image setup — inline cloud-init for packages, kernel modules, etc. (Method 2) |

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
| `my-ssh-key` | Your CloudStack SSH keypair name — register via `cmk register-sshkeypair` |
| `<YOUR_SSH_PUBLIC_KEY>` | Your SSH public key — for Method 2 only (12-custom-image-cluster.yaml), embedded via cloud-init |

## SSH Key Methods

- **Method 1** (default, 10-minimal / 11-ha): Register SSH keypair in CloudStack via `cmk register-sshkeypair`, reference via `sshKey` field on `CloudStackMachine`. CloudStack injects the key into the image's default user.
- **Method 2** (advanced, 12-custom): Define user and SSH key inline in `KubeadmConfig.users` + cloud-init commands. Use for custom image setup beyond SSH (packages, kernel modules, systemd, etc.).

See [cluster.md](../cluster.md#34-advanced-inline-cloudinit) for full comparison.
