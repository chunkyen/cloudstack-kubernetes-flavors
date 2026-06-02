# CloudStack Kubernetes Flavors

A detailed exploration of various Kubernetes deployment options on CloudStack infrastructure, including architecture analysis, setup guides, and comparative evaluation.

## Overview

This repository examines four primary approaches to running Kubernetes on CloudStack, plus two foundational components that apply across all flavors.

### Four Flavors

1. **CKS (CloudStack Kubernetes Service)** - Native CloudStack Kubernetes integration
2. **CAPC (Cluster API Provider for CloudStack)** - Infrastructure-as-Code approach using Cluster API (with user-defined node OS)
3. **Talos Linux** - Minimal, immutable Linux designed for Kubernetes (can be used standalone with CAPI, with Rancher, or independently)
4. **Rancher + CAPC** - Managed Kubernetes with Rancher as the management plane, CAPC as the CloudStack infrastructure provider (with user-defined or Talos nodes)

### Cross-Cutting Components

These components are required or recommended for **every flavor**:

- **CloudStack Kubernetes Provider (CCM)** — External Cloud Controller Manager that replaces the deprecated in-tree provider (removed K8s 1.16). Handles node metadata labels, CloudStack load balancers for `LoadBalancer` services, and firewall rules. Auto-deployed on CKS 4.16+, must be manually deployed on all other flavors.
- **CloudStack CSI Driver** — Persistent storage plugin that maps CloudStack disk offerings to Kubernetes StorageClasses. Supports dynamic provisioning, volume snapshots, and lifecycle management. Deployed separately on each cluster.

See the [Architecture](#architecture) section for details on each.

## Contents

### Architecture

- [CloudStack Kubernetes Provider (external CCM)](architecture/cloudstack-kubernetes-provider.md) — applies to all flavors
- [CloudStack CSI Driver (persistent storage)](architecture/cloudstack-csi-driver.md) — applies to all flavors
- [CKS architecture](architecture/cks.md)
- [CAPC architecture](architecture/capc.md)
- [Talos architecture](architecture/talos.md)
- [Rancher+CAPC architecture](architecture/rancher-capc.md)

### Setup Guides

- [CKS deployment](setup/cks/cks.md)
- [CAPC deployment (with user-defined OS)](setup/capc/capc.md)
- [CAPC custom image building](setup/capc/capc-custom-image.md) — build your own K8s-compatible images for CAPC
- [Move From Bootstrap](setup/capc/move-from-bootstrap.md) — make CAPC clusters self-managing by transferring CAPI objects from a bootstrap cluster
- [Talos Linux standalone (with CAPI or bare-metal)](setup/talos.md)
- [Rancher with CAPC](setup/rancher-capc.md)

### Analysis

- [Feature comparison matrix and analysis](comparison/)
- [External references and documentation links](references/)

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
