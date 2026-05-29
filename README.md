# CloudStack Kubernetes Flavors

A detailed exploration of various Kubernetes deployment options on CloudStack infrastructure, including architecture analysis, setup guides, and comparative evaluation.

## Overview

This repository examines four primary approaches to running Kubernetes on CloudStack:

1. **CKS (CloudStack Kubernetes Service)** - Native CloudStack Kubernetes integration
2. **CAPC (Cluster API Provider for CloudStack)** - Infrastructure-as-Code approach using Cluster API (with user-defined node OS)
3. **Talos Linux** - Minimal, immutable Linux designed for Kubernetes (can be used standalone with CAPI, with Rancher, or independently)
4. **Rancher + CAPC** - Managed Kubernetes with Rancher as the management plane, CAPC as the CloudStack infrastructure provider (with user-defined or Talos nodes)

## Contents

### Architecture

- [`architecture/cloudstack-kubernetes-provider.md`](./architecture/cloudstack-kubernetes-provider.md) — **CloudStack Kubernetes Provider** (external CCM) — applies to all flavors
- [`architecture/cloudstack-csi-driver.md`](./architecture/cloudstack-csi-driver.md) — **CloudStack CSI Driver** (persistent storage) — applies to all flavors
- [`architecture/cks.md`](./architecture/cks.md) — CKS architecture
- [`architecture/capc.md`](./architecture/capc.md) — CAPC architecture
- [`architecture/talos.md`](./architecture/talos.md) — Talos architecture
- [`architecture/rancher-capc.md`](./architecture/rancher-capc.md) — Rancher+CAPC architecture

### Setup Guides

- [`setup/`](./setup/) - Step-by-step setup guides for each flavor
  - [`cks/`](./setup/cks/) - CKS deployment
  - [`capc/`](./setup/capc/) - CAPC deployment (with user-defined OS)
  - [`talos/`](./setup/talos/) - Talos Linux standalone (with CAPI or bare-metal)
  - [`rancher-capc/`](./setup/rancher-capc/) - Rancher with CAPC

### Analysis

- [`comparison/`](./comparison/) - Feature comparison matrix and analysis
- [`references/`](./references/) - External references and documentation links

## Quick Comparison

| Feature | CKS | CAPC | Talos (standalone) | Rancher+CAPC |
|---------|-----|------|-------------------|-------------------|
| **Management** | Native CloudStack UI/API | Cluster API controllers | Talos CLI / Tinkerbell | Rancher UI/API |
| **Node OS** | User-defined | User-defined | Talos Linux (immutable) | User-defined / Talos |
| **GitOps** | No | Yes (CAPI native) | Yes (Terraform/Talos) | Yes (Rancher Fleet) |
| **Multi-cluster** | Limited | Yes (CAPI native) | Manual/CAPI | Yes (Rancher native) |
| **Upgrade Strategy** | Manual | Automated | Automated (Talos) | Automated |
| **Complexity** | Low | Medium | Medium | High |
| **Terraform** | No | Yes (CAPI provider) | Yes | Yes |

## Status

🚧 **Work in Progress** - This repository is being actively developed.
