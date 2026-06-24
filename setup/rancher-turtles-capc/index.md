# Rancher Turtles + CAPC — Setup Guide

This guide walks through deploying Rancher on a CKS cluster to serve as the management plane, then using Rancher Turtles to manage CAPC for declarative Kubernetes cluster provisioning on CloudStack.

## 1. Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Bootstrap Cluster                             │
│              (CKS cluster on CloudStack)                         │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                    Rancher                                │   │
│  │                                                           │   │
│  │  ┌──────────────┐  ┌──────────────────────────────────┐  │   │
│  │  │ Rancher      │  │ Turtles Controller               │  │   │
│  │  │ Server       │  │                                  │  │   │
│  │  │              │  │  CAPIProvider: core              │  │   │
│  │  │  Fleet       │◄─┼─ CAPIProvider: kubeadm-bootstrap │  │   │
│  │  │  (GitOps)    │  │  CAPIProvider: kubeadm-cp        │  │   │
│  │  │              │  │  CAPIProvider: cloudstack        │  │   │
│  │  │  Cluster UI  │  │                                  │  │   │
│  │  │  + RBAC      │  └──────────────┬───────────────────┘  │   │
│  │  └──────────────┘                 │                       │   │
│  └───────────────────────────────────┼───────────────────────┘   │
│                                      │ clusterctl                │
│                                      │ generate cluster          │
│                                      ▼                           │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │              Management Cluster (CAPC)                    │   │
│  │         (CKS cluster on CloudStack via CAPC)              │   │
│  └───────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

## 2. Prerequisites

### 2.1 CloudStack

| Resource | Details |
|----------|--------|
| **Zone** | A zone with available compute resources |
| **Network** | Isolated (recommended) or shared network |
| **Public IP** | Unused public IP for Rancher ingress (if exposing externally) |
| **SSH Key Pair** | For VM access |
| **Compute Offerings** | Control plane (2vCPU/2GB+), workers (as needed) |
| **CKS Plugin** | Enabled via `cloud.kubernetes.service.enabled` |

### 2.2 Bootstrap Cluster

A CKS cluster on CloudStack to host Rancher. See the [CKS Setup Guide](../cks/cks.md) for creating one.

Minimum sizing for Rancher:
- **Control plane**: 3 nodes, 4vCPU/8GB each
- **Worker nodes**: 2 nodes, 4vCPU/8GB each (for Rancher + Turtles + CAPC)
- **Storage**: 100GB+ disk for container images and Rancher data

### 2.3 Local Machine

- `kubectl` configured with bootstrap cluster access
- `helm` v3.12+
- `clusterctl` v1.1.5+
- Access to CloudStack management server API

## 3. Rancher Turtles vs Traditional CAPC Setup

**This is the key difference that trips people up.**

### 3.1 Traditional CAPC Setup

```bash
# 1. Bootstrap a management cluster (kind, k3s, etc.)
# 2. Install CAPC via clusterctl
clusterctl init --infrastructure cloudstack
# 3. Generate cluster spec
clusterctl generate cluster my-cluster --kubernetes-version v1.28.0 > cluster.yaml
# 4. Apply cluster spec
kubectl apply -f cluster.yaml
```

`clusterctl init` fetches CAPC manifests, deploys the `capc-controller-manager`, and registers CRDs.

### 3.2 Rancher Turtles + CAPC Setup

```bash
# 1. Install Rancher (Turtles is bundled in v2.13+)
# 2. Deploy providers declaratively via CAPIProvider resources
kubectl apply -f cloudstack-provider.yaml
# 3. Generate cluster spec (same as traditional)
clusterctl generate cluster my-cluster --kubernetes-version v1.28.0 > cluster.yaml
# 4. Apply cluster spec
kubectl apply -f cluster.yaml
```

**Turtles replaces `clusterctl init`.** The `CAPIProvider` resource *is* the install command — Turtles watches it, fetches the provider manifests, and deploys them automatically.

### 3.3 Side-by-Side Comparison

| Step | Traditional CAPC | Rancher Turtles + CAPC |
|------|-----------------|----------------------|
| Management cluster | kind / k3s / existing cluster | Rancher on CKS cluster |
| Install CAPC | `clusterctl init --infrastructure cloudstack` | Apply `CAPIProvider` YAML |
| Provider lifecycle | `clusterctl` manages it | Turtles controller manages it |
| Provider namespace | `capi-system`, `capc-system` | `cattle-capi-system`, `capc-system` |
| Core CAPI | Installed by `clusterctl init` | Installed by Turtles automatically |
| Cluster creation | `clusterctl generate cluster` + `kubectl apply` | Same (no change) |
| Multi-provider | Manual `clusterctl init` for each | Single `CAPIProvider` per provider |

### 3.4 Why Turtles?

- **Declarative**: No imperative `clusterctl init` commands — providers are managed as Kubernetes resources
- **Integrated**: Turtles is a Rancher system chart, no separate installation needed
- **Multi-provider**: Add providers by applying YAML, not running commands
- **GitOps-friendly**: Provider manifests are version-controlled YAML, easy to track in Git

## 4. Overview

This guide covers:

1. **[Deploy Rancher on CKS](./rancher.md)** — Install Rancher server on the bootstrap CKS cluster
2. **[Install Turtles + CAPC](./turtles.md)** — Deploy Rancher Turtles and configure CAPC as a CAPI provider
3. **[Create Clusters](./cluster.md)** — Provision CKS clusters via CAPI CRDs
4. **[Fleet GitOps](./fleet.md)** — Automate cluster management with Fleet

## 5. References

- [Architecture](../../architecture/rancher-turtles-capc.md)
- [CAPC Architecture](../../architecture/capc.md)
- [Rancher Turtles Docs](https://turtles.docs.rancher.com)
- [CAPC Book](https://cluster-api-cloudstack.sigs.k8s.io)
