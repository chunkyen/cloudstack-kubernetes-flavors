# CloudStack Kubernetes Flavors

A detailed exploration of various Kubernetes deployment options on CloudStack infrastructure, including architecture analysis, setup guides, and comparative evaluation.

## Overview

This repository examines four primary approaches to running Kubernetes on CloudStack, plus two foundational components that apply across all flavors.

### Four Flavors

1. **CKS (CloudStack Kubernetes Service)** — Native CloudStack Kubernetes integration
2. **CAPC (Cluster API Provider for CloudStack)** — Infrastructure-as-Code approach using Cluster API (with user-defined node OS)
3. **Rancher + CAPC** — Managed Kubernetes with Rancher as the management plane, CAPC as the CloudStack infrastructure provider (with user-defined nodes)
4. **Talos Linux** — Minimal, immutable Linux designed for Kubernetes. Can be managed standalone (via `cmk` or Terraform), or with **Sidero Omni** — a Kubernetes management platform that automates cluster lifecycle (self-hosted on CloudStack as a single Docker VM).

### Cross-Cutting Components

These components are required or recommended for **every flavor**:

- **CloudStack Kubernetes Provider (CCM)** — External Cloud Controller Manager that replaces the deprecated in-tree provider (removed K8s 1.16). Handles node metadata labels, CloudStack load balancers for `LoadBalancer` services, and firewall rules. Auto-deployed on CKS 4.16+, must be manually deployed on all other flavors.
- **CloudStack CSI Driver** — Persistent storage plugin that maps CloudStack disk offerings to Kubernetes StorageClasses. Supports dynamic provisioning, volume snapshots, and lifecycle management. Deployed separately on each cluster.

## Contents

### Architecture

- [CloudStack Kubernetes Provider (external CCM)](architecture/cloudstack-kubernetes-provider.md) — applies to all flavors
- [CloudStack CSI Driver (persistent storage)](architecture/cloudstack-csi-driver.md) — applies to all flavors
- [CKS architecture](architecture/cks.md)
- [CAPC architecture](architecture/capc.md)
- [Rancher+CAPC architecture](architecture/rancher-turtles-capc.md)
- [Talos architecture](architecture/talos.md)

### Setup Guides

#### CKS (CloudStack Kubernetes Service)

- [Main deployment](setup/cks/cks.md)
- [Custom ISO build](setup/cks/cks-custom-iso.md)
- [Custom VM template](setup/cks/cks-custom-template.md)
- [Upgrade](setup/cks/cks-upgrade.md)
- [Offline / air-gapped deployment](setup/cks/cks-offline.md)
- [Improvements & notes](setup/cks/cks-improvements.md)

#### CAPC (Cluster API Provider for CloudStack)

- [Main deployment](setup/capc/capc.md)
- [Custom image build](setup/capc/capc-custom-image.md)
- [Move from bootstrap to self-managing](setup/capc/move-from-bootstrap.md)
- [Upgrade](setup/capc/capc-upgrade.md)
- [CNI automation options](setup/capc/cni-automation-options.md)

#### Rancher Turtles + CAPC

The Rancher Turtles integration combines three layers — Rancher (management plane with UI, Fleet GitOps, RBAC), Turtles (CAPI operator for declarative provider management), and CAPC (CloudStack infrastructure provider). See [Rancher+CAPC architecture](architecture/rancher-turtles-capc.md) for the full architecture breakdown.

Two bootstrap providers are supported:

| | Kubeadm | RKE2 |
|---|---|---|
| **Bootstrap** | `kubeadm` | `rke2` |
| **Control plane** | `kubeadm` | `rke2` |
| **CNI** | Manual install (Calico/Flannel/Cilium) | Built-in (Calico default; Canal, Cilium, Flannel, or none configurable) |
| **Image** | CAPI-compatible image (kubelet + kubeadm pre-installed) | Standard OS template |

See [architecture/rancher-turtles-capc.md#bootstrap-provider-choice-kubeadm-vs-rke2](architecture/rancher-turtles-capc.md#bootstrap-provider-choice-kubeadm-vs-rke2) for a detailed comparison of why to choose RKE2 over kubeadm.

**Phase 1 — Deploy Management Plane:**

- [Deploy Rancher on CKS](setup/rancher-turtles-capc/rancher.md)
- [Install CAPI providers with Turtles](setup/rancher-turtles-capc/turtles.md)

**Phase 2 — Create & Manage Workload Clusters:**

**Kubeadm-based:**
- [Create workload clusters](setup/rancher-turtles-capc/cluster.md) — minimal/HA cluster creation, scaling, upgrade, troubleshooting
- [Full-stack onboarding (CNI + CCM + CSI)](setup/rancher-turtles-capc/full-stack-onboarding.md) — auto-install all components via ClusterResourceSet
- [Fleet GitOps](setup/rancher-turtles-capc/fleet.md) — automate cluster management with Fleet
- [Manifests README](setup/rancher-turtles-capc/manifests/README.md) — all YAML manifests with descriptions

**RKE2-based:**
- [Cluster creation](setup/rancher-turtles-capc-rke2/cluster.md) — RKE2 cluster provisioning with automatic CCM + CSI deployment
- [Manifests](setup/rancher-turtles-capc-rke2/manifests/) — all YAML files

> **ClusterClass note:** CAPI ClusterClass (topology-based clusters) is **not available** for CAPC because CAPC does not implement `CloudStackClusterTemplate`, the CRD required by ClusterClass's `infrastructure.templateRef`. Clusters must use explicit CRD references. See [Rancher+CAPC architecture](architecture/rancher-turtles-capc.md#clusterclass--not-available-for-capc) for details.
>
> **CNI/CCM/CSI:** For Kubeadm-based CAPC clusters (no built-in CNI), use [ClusterResourceSet](https://turtles.docs.rancher.com/turtles/stable/en/user/applications.html) — the approach recommended by the Rancher Turtles documentation — to auto-install bootstrap applications. See [Full-stack onboarding](setup/rancher-turtles-capc/full-stack-onboarding.md).
>
> For RKE2-based CAPC clusters, CNI is built-in (Calico). CCM + CSI are deployed automatically via ClusterResourceSet as part of the cluster provisioning in [`cluster.md`](setup/rancher-turtles-capc-rke2/cluster.md).

#### Talos Linux

Talos Linux is a minimal, immutable OS designed specifically for Kubernetes. It can be managed through three approaches, each documented here:

| Approach | Description | Complexity |
|----------|-------------|------------|
| **Manual (`cmk`)** | Deploy VMs via CloudStack CLI, generate configs with `talosctl`, bootstrap manually | High |
| **Terraform** | One-shot deployment with Terraform managing all CloudStack resources (network, IP, LB, firewall, VMs) | Medium |
| **Sidero Omni** | Kubernetes management platform that automates cluster creation, scaling, upgrades, and lifecycle. Self-hosted on CloudStack as a single Docker VM. | High (self-hosted) / Low (SaaS) |

Guides:

- [Talos architecture](architecture/talos.md) — architecture overview
- [Manual setup](setup/talos/talos.md) — deploy a Talos cluster on CloudStack via `cmk` CLI
- [Terraform deployment](setup/talos/talos-terraform.md) — one-shot deployment with Terraform (network, IP, LB, firewall, VMs)
- [Terraform manifests](setup/talos/manifests/terraform/) — Terraform configs for the above
- [Sidero Omni](setup/talos/talos-omni.md) — self-hosted Omni on CloudStack: deploy the Omni VM, register Talos machines, and manage clusters via `omnictl`

#### Cross-Cutting Components

- [CloudStack Kubernetes Provider (CCM)](setup/cloudstack-kubernetes-provider.md)
- [CloudStack CSI Driver](setup/cloudstack-csi-driver.md)

### Analysis

- Feature comparison matrix and analysis (not yet created)
- External references and documentation links (not yet created)

## Quick Comparison

| **Feature** | CKS | CAPC | Rancher+CAPC | Rancher+CAPC+RKE2 | Talos (standalone) | Talos (Omni-managed) |
|---------|-----|------|-------------------|-------------------|-------------------|---------------------|
| **Management** | Native CloudStack UI/API | Cluster API controllers | Rancher UI/API | Rancher UI/API | Talos CLI / Terraform | Omni UI / `omnictl` |
| **Node OS** | User-defined | User-defined | User-defined | User-defined (RKE2 installs via tarball) | Talos Linux (immutable, no SSH) | Talos Linux (immutable, no SSH) |
| **GitOps** | No | Yes (CAPI native) | Yes (Rancher Fleet) | Yes (Rancher Fleet) | Yes (talosctl + Git) | Yes (Omni + Git) |
| **Multi-cluster** | Limited | Yes (CAPI native) | Yes (CAPI + Rancher Turtles) | Yes (CAPI + Rancher Turtles) | Manual | Yes (Omni native) |
| **Upgrade Strategy** | Manual | Image-based rolling update | Image-based rolling update | RKE2 version bump (rolling) | Image-based atomic (talosctl upgrade) | Automatic rolling (Omni-managed) |
| **CNI/CCM/CSI** | Baked into ISO | Manual or CRS | Manual or CRS | Built-in (Calico) + CRS for CCM/CSI | Manual install | Manual install (same) |
| **ClusterClass** | N/A | Not supported (no CloudStackClusterTemplate) | Not supported (no CloudStackClusterTemplate) | Not supported (no CloudStackClusterTemplate) | N/A (manual config) | N/A (Omni manages configs) |
| **Complexity** | Low | Medium | High | Medium | Medium | High (self-hosted) / Low (SaaS) |

## Status

✅ **First Release** — All four Kubernetes flavors on CloudStack are documented with architecture analysis, setup guides, and comparative evaluation.
