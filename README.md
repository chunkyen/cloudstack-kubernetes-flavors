# CloudStack Kubernetes Flavors

A detailed exploration of various Kubernetes deployment options on CloudStack infrastructure, including architecture analysis, setup guides, and comparative evaluation.

## 1. Overview

This repository examines four primary approaches to running Kubernetes on CloudStack, plus two foundational components that apply across all flavors.

### 1.1 Four Flavors

1. **CKS (CloudStack Kubernetes Service)** — Native CloudStack Kubernetes integration
2. **CAPC (Cluster API Provider for CloudStack)** — Infrastructure-as-Code approach using Cluster API (with user-defined node OS)
3. **Rancher + CAPC** — Managed Kubernetes with Rancher as the management plane, CAPC as the CloudStack infrastructure provider. Supports two bootstrap providers:
   - **Kubeadm** — traditional kubeadm-based control plane and bootstrap
   - **RKE2** — Rancher's Kubernetes distribution with built-in CNI (Calico), embedded etcd, and native air-gap support via tarball
4. **Talos Linux** — Minimal, immutable Linux designed for Kubernetes. Can be managed standalone (via `cmk` or Terraform), or with **Sidero Omni** — a Kubernetes management platform that automates cluster lifecycle (self-hosted on CloudStack as a single Docker VM, or SaaS).

### 1.2 Cross-Cutting Components

These components are required or recommended for **every flavor**:

- **CloudStack Kubernetes Provider (CCM)** — External Cloud Controller Manager that replaces the deprecated in-tree provider (removed K8s 1.16). Handles node metadata labels, CloudStack load balancers for `LoadBalancer` services, and firewall rules. Auto-deployed on CKS 4.16+, must be manually deployed on all other flavors.
- **CloudStack CSI Driver** — Persistent storage plugin that maps CloudStack disk offerings to Kubernetes StorageClasses. Supports dynamic provisioning, volume snapshots, and lifecycle management. Deployed separately on each cluster.

## 2. Contents

### 2.1 Architecture

- [CloudStack Kubernetes Provider (external CCM)](architecture/cloudstack-kubernetes-provider.md) — applies to all flavors
- [CloudStack CSI Driver (persistent storage)](architecture/cloudstack-csi-driver.md) — applies to all flavors
- [CKS architecture](architecture/cks.md)
- [CAPC architecture](architecture/capc.md)
- [Rancher+CAPC architecture](architecture/rancher-turtles-capc.md)
- [Talos architecture](architecture/talos.md)

### 2.2 Setup Guides

#### 2.2.1 CKS (CloudStack Kubernetes Service)

CKS is Apache CloudStack's native Kubernetes integration — a fully managed service that provisions, scales, and manages Kubernetes clusters directly from the CloudStack UI and API. It uses kubeadm under the hood with pre-packaged ISOs containing all Kubernetes binaries and container images.

| Feature | Details |
|---------|---------|
| **Management** | Native CloudStack UI/API — no external management cluster needed |
| **Bootstrap** | kubeadm with pre-packaged ISOs (Calico CNI, Docker/containerd, Dashboard) |
| **Node OS** | User-defined via CKS-marked templates (Ubuntu, Rocky, custom) |
| **Control Plane HA** | Multi-control-node clusters with external LB (from 4.16+) |
| **Flexible node types** | Separate templates/offerings for control, worker, and dedicated etcd nodes (from 4.21) |
| **CNI** | Calico (default); Cilium via custom ISO |
| **CCM/CSI** | Auto-deployed (baked into the CKS provisioning flow) |
| **Upgrade** | Manual via UI or API (`upgradeKubernetesCluster`) |
| **Scaling** | UI/API buttons (`scaleKubernetesCluster`) |
| **GitOps** | Not supported — no declarative YAML model |
| **Offline** | Partial — ISOs bundle images, but kubeadm init requires internet |
| **Complexity** | Low — simplest path to a K8s cluster on CloudStack |

Guides:

- [Main deployment](setup/cks/cks.md)
- [Custom ISO build](setup/cks/cks-custom-iso.md)
- [Custom VM template](setup/cks/cks-custom-template.md)
- [Upgrade](setup/cks/cks-upgrade.md)
- [Offline / air-gapped deployment](setup/cks/cks-offline.md)
- [Improvements & notes](setup/cks/cks-improvements.md)

#### 2.2.2 CAPC (Cluster API Provider for CloudStack)

CAPC is the official Kubernetes SIGs infrastructure provider that brings declarative, Kubernetes-native cluster lifecycle management to CloudStack. It uses Cluster API (CAPI) controllers and CRDs to provision, scale, upgrade, and delete Kubernetes clusters — all managed from a separate management cluster via `kubectl`.

| Feature | Details |
|---------|---------|
| **Management** | External Kubernetes cluster running CAPI controllers — `clusterctl` + `kubectl` |
| **Bootstrap** | kubeadm (requires CAPI-compatible image with kubelet + kubeadm pre-installed) |
| **Node OS** | User-defined — any cloud-init-compatible image with K8s prereqs (Ubuntu, Rocky, custom) |
| **CNI** | Manual install post-deployment (Calico, Cilium, Flannel) |
| **CCM/CSI** | Manual install post-deployment (not auto-deployed) |
| **Upgrade** | Image-based rolling update — new template per K8s version |
| **Scaling** | Declarative — `replicas` field on `MachineDeployment` |
| **GitOps** | Yes — all resources are declarative YAML, version-controllable |
| **Multi-cluster** | Native — CAPI manages many clusters from one management cluster |
| **ClusterClass** | Not supported — CAPC lacks `CloudStackClusterTemplate` CRD |
| **Offline** | Requires pre-baked images or private registry |
| **Complexity** | Medium — requires a separate management cluster and CAPI-compatible images |

Guides:

- [Main deployment](setup/capc/capc.md)
- [Custom image build](setup/capc/capc-custom-image.md)
- [Move from bootstrap to self-managing](setup/capc/move-from-bootstrap.md)
- [Upgrade](setup/capc/capc-upgrade.md)
- [CNI automation options](setup/capc/cni-automation-options.md)

#### 2.2.3 Rancher Turtles + CAPC

The Rancher Turtles integration combines three layers — Rancher (management plane with UI, Fleet GitOps, RBAC), Turtles (CAPI operator for declarative provider management), and CAPC (CloudStack infrastructure provider). See [Rancher+CAPC architecture](architecture/rancher-turtles-capc.md) for the full architecture breakdown.

Two bootstrap providers are supported:

| | Kubeadm | RKE2 |
|---|---|---|
| **Bootstrap** | `kubeadm` | `rke2` |
| **Control plane** | `kubeadm` | `rke2` |
| **Image** | CAPI-compatible image (kubelet + kubeadm pre-installed) | Standard OS template |

See [architecture/rancher-turtles-capc.md#bootstrap-provider-choice-kubeadm-vs-rke2](architecture/rancher-turtles-capc.md#bootstrap-provider-choice-kubeadm-vs-rke2) for a detailed comparison.

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
- [Air-gapped / offline deployment](setup/rancher-turtles-capc-rke2/cluster.md#air-gapped--offline-deployment) — RKE2 tarball-based air-gap with internal HTTP server
- [Template-driven manifests with ytt](setup/rancher-turtles-capc-rke2/ytt.md) — reusable cluster templates with air-gap conditionals
- [Manifests](setup/rancher-turtles-capc-rke2/manifests/) — all YAML files including air-gap sample

RKE2 differs from kubeadm in several key ways:

| Aspect | Kubeadm | RKE2 |
|--------|---------|------|
| **Node image** | Requires a CAPI-compatible image with kubelet + kubeadm pre-installed | Standard OS template (Ubuntu, Rocky) — RKE2 installs via tarball |
| **CNI** | Manual install (Calico/Flannel/Cilium) | Built-in (Calico default; Canal, Cilium, Flannel, or none) |
| **Air-gap** | Pre-bake images into template or use private registry | Built-in `airGapped: true` — tarball contains all K8s + CNI + containerd images |
| **Upgrade** | Image-based (new template per version) | Version bump in manifest (rolling update via tarball) |
| **Control plane taint** | Manual `kubectl taint` or kubelet config | `register-with-taints` kubelet extraArg in manifest |
| **etcd** | External (stacked or external) | Embedded (built-in) |

#### 2.2.4 Talos Linux

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

**Sidero Omni** is a Kubernetes management platform that automates the full cluster lifecycle — creation, scaling, upgrades, teardown — without requiring SSH access to nodes (Talos is immutable, no SSH). It can run as a SaaS offering or be self-hosted on CloudStack as a single Docker VM.

Key capabilities:

| Feature | Details |
|---------|---------|
| **Cluster lifecycle** | Create, scale, upgrade, delete clusters via `omnictl` or UI |
| **Machine management** | Register bare Talos machines (VMs) — Omni discovers and manages them |
| **Upgrades** | Automatic rolling upgrades — Omni orchestrates node-by-node replacement |
| **Multi-cluster** | Native multi-cluster management from a single Omni instance |
| **GitOps** | Cluster templates stored in Git, applied via `omnictl` |
| **Air-gap** | Omni can operate fully offline — no internet dependency after initial setup |
| **Self-hosted** | Single Docker VM on CloudStack (~4 GB RAM, 2 vCPU) — no Kubernetes cluster needed to run it |

#### 2.2.5 Cross-Cutting Components

- [CloudStack Kubernetes Provider (CCM)](setup/cloudstack-kubernetes-provider.md)
- [CloudStack CSI Driver](setup/cloudstack-csi-driver.md)

### 2.3 Analysis

- Feature comparison matrix and analysis (not yet created)
- External references and documentation links (not yet created)

## 3. Quick Comparison

| **Feature** | CKS | CAPC | Rancher+CAPC | Rancher+CAPC+RKE2 | Talos (standalone) | Talos (Omni-managed) |
|---------|-----|------|-------------------|-------------------|-------------------|---------------------|
| **Management** | Native CloudStack UI/API | Cluster API controllers | Rancher UI/API | Rancher UI/API | Talos CLI / Terraform | Omni UI / `omnictl` |
| **Node OS** | User-defined | User-defined | User-defined | User-defined (RKE2 installs via tarball) | Talos Linux (immutable, no SSH) | Talos Linux (immutable, no SSH) |
| **GitOps** | No | Yes (CAPI native) | Yes (Rancher Fleet) | Yes (Rancher Fleet) | Yes (talosctl + Git) | Yes (Omni + Git) |
| **Multi-cluster** | Limited | Yes (CAPI native) | Yes (CAPI + Rancher Turtles) | Yes (CAPI + Rancher Turtles) | Manual | Yes (Omni native) |
| **Upgrade Strategy** | Manual | Image-based rolling update | Image-based rolling update | RKE2 version bump (rolling) | Image-based atomic (talosctl upgrade) | Automatic rolling (Omni-managed) |
| **Complexity** | Low | Medium | High | Medium | Medium | High (self-hosted) / Low (SaaS) |

## 4. Status

✅ **First Release** — All four Kubernetes flavors on CloudStack are documented with architecture analysis, setup guides, and comparative evaluation.
