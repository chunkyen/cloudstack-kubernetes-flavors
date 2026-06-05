# Rancher Turtles + CAPC — Setup Guide

This guide walks through deploying Rancher on a CKS cluster to serve as the management plane, then using Rancher Turtles to manage CAPC for declarative Kubernetes cluster provisioning on CloudStack.

## Architecture

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

## Prerequisites

### CloudStack

| Resource | Details |
|----------|--------|
| **Zone** | A zone with available compute resources |
| **Network** | Isolated (recommended) or shared network |
| **Public IP** | Unused public IP for Rancher ingress (if exposing externally) |
| **SSH Key Pair** | For VM access |
| **Compute Offerings** | Control plane (2vCPU/2GB+), workers (as needed) |
| **CKS Plugin** | Enabled via `cloud.kubernetes.service.enabled` |

### Bootstrap Cluster

A CKS cluster on CloudStack to host Rancher. See the [CKS Setup Guide](../cks/cks.md) for creating one.

Minimum sizing for Rancher:
- **Control plane**: 3 nodes, 4vCPU/8GB each
- **Worker nodes**: 2 nodes, 4vCPU/8GB each (for Rancher + Turtles + CAPC)
- **Storage**: 100GB+ disk for container images and Rancher data

### Local Machine

- `kubectl` configured with bootstrap cluster access
- `helm` v3.12+
- `clusterctl` v1.1.5+
- Access to CloudStack management server API

## Overview

This guide covers:

1. **[Deploy Rancher on CKS](./rancher.md)** — Install Rancher server on the bootstrap CKS cluster
2. **[Install Turtles + CAPC](./turtles.md)** — Deploy Rancher Turtles and configure CAPC as a CAPI provider
3. **[Create Clusters](./cluster.md)** — Provision CKS clusters via CAPI CRDs
4. **[Fleet GitOps](./fleet.md)** — Automate cluster management with Fleet

## Quick Start

```bash
# 1. Deploy Rancher on CKS cluster
kubectl --kubeconfig=cks-kubeconfig apply -f https://releases.rancher.com/install/latest/rancher.yaml

# 2. Get Rancher admin password
kubectl --kubeconfig=cks-kubeconfig -n cattle-system get secret \
  $(kubectl --kubeconfig=cks-kubeconfig -n cattle-system get secret \
    -o name | grep 'bootstrap-secret') \
  -o jsonpath='{.data.bootstrapPassword}' | base64 -d

# 3. Install Turtles
helm install turtles oci://registry-1.docker.io/rancher/turtles \
  --version v0.20.0 \
  --namespace capi-system \
  --create-namespace

# 4. Deploy CAPC via CAPIProvider
kubectl --kubeconfig=cks-kubeconfig apply -f - <<EOF
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
EOF
```

See the detailed guides below for each step.

## References

- [Architecture](../../architecture/rancher-turtles-capc.md)
- [CAPC Architecture](../../architecture/capc.md)
- [Rancher Turtles Docs](https://turtles.docs.rancher.com)
- [CAPC Book](https://cluster-api-cloudstack.sigs.k8s.io)
