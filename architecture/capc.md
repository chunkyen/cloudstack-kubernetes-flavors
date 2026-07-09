# CAPC Architecture — Cluster API Provider for CloudStack

## Overview

CAPC (Cluster API Provider for CloudStack) is the official Kubernetes SIGs provider that brings declarative, Kubernetes-style APIs to cluster lifecycle management on Apache CloudStack infrastructure. It follows the [Cluster API](https://sigs.k8s.io/cluster-api) design pattern: a set of controllers and CRDs that manage the full lifecycle of Kubernetes clusters.

## How It Works

```
┌─────────────────────────────────────────────────────┐
│              Management Cluster                      │
│  (any K8s cluster — kind, EKS, GKE, or existing)    │
│                                                      │
│  ┌──────────┐  ┌──────────────┐  ┌───────────────┐  │
│  │ CAPI     │  │ Kubeadm      │  │ CAPC          │  │
│  │ Controller│  │ Bootstrap    │  │ Controller    │  │
│  │ (core)   │  │ Controller   │  │ (infrastructure│  │
│  └────┬─────┘  └──────┬───────┘  │ provider)     │  │
│       │               │          └───────┬───────┘  │
│       │    Cluster CRD │                  │          │
│       └───────────────┼──────────────────┘          │
│                       ▼                             │
│              Workload Clusters                      │
│         (created on CloudStack VMs)                 │
└─────────────────────────────────────────────────────┘

User workflow:
  clusterctl init --infrastructure cloudstack   ← installs CAPC providers
  clusterctl generate cluster my-cluster         ← generates Cluster CRDs
  kubectl apply -f cluster.yaml                 ← creates the cluster
```

### Core Components

| Component | Role |
|-----------|------|
| **CAPI Controller** (`capi-controller-manager`) | Core Cluster API controllers — orchestrates cluster lifecycle, manages `Cluster`, `Machine`, and `MachineSet` CRDs |
| **Kubeadm Bootstrap Controller** (`capi-kubeadm-bootstrap-system`) | Generates kubeadm join commands and bootstrap data for worker nodes |
| **Kubeadm Control Plane Controller** (`capi-kubeadm-control-plane-system`) | Manages control plane `Machine` lifecycle — creates, updates, deletes control plane VMs on CloudStack |
| **CAPC Controller** (`capc-controller-manager`) | CloudStack-specific infrastructure provider — translates Cluster API objects into CloudStack API calls (VM creation, networking, LB, disk) |
| **cert-manager** | TLS certificate management for webhook endpoints |

### CRD Model

```yaml
# Cluster — the top-level resource
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
spec:
  infrastructureRef:          # points to CloudStackCluster
    name: my-cluster
  controlPlaneRef:            # points to KubeadmControlPlane
    name: my-cluster-control-plane
---
# CloudStackCluster — infrastructure resource
apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
kind: CloudStackCluster
spec:
  network:                    # CloudStack network reference
    name: GuestNet1
  controlPlaneEndpointIP:     # Public IP for API server
    "192.168.1.161"
---
# KubeadmControlPlane — control plane machines
apiVersion: controlplane.cluster.x-k8s.io/v1beta1
kind: KubeadmControlPlane
spec:
  machineTemplate:
    infrastructureRef:        # points to CloudStackMachine (control plane)
      name: my-cluster-cp
---
# MachineDeployment — worker nodes
apiVersion: cluster.x-k8s.io/v1beta1
kind: MachineDeployment
spec:
  replicas: 3
  machineTemplate:
    infrastructureRef:        # points to CloudStackMachine (worker)
      name: my-cluster-md
```

### Lifecycle Flow

1. **User creates** a `Cluster` CRD via `clusterctl generate cluster`
2. **CAPI controller** sees the new Cluster and creates `CloudStackCluster` + `KubeadmControlPlane` resources
3. **CAPC controller** provisions CloudStack VMs for control plane nodes using the specified template and compute offering
4. **Kubeadm Bootstrap Controller** generates kubeadm init/join commands as cloud-init user-data
5. **VMs boot**, run cloud-init, join the cluster via kubeadm
6. **Worker nodes**: `MachineDeployment` creates additional `CloudStackMachine` resources → CAPC provisions VMs → cloud-init runs kubeadm join
7. **CNI installed** separately (Calico/Weave) — not part of CAPC itself

### Networking Model

- **Control plane endpoint**: A public IP allocated from the CloudStack network, assigned to a load balancer rule that forwards traffic to control plane VMs on port 6443
- **Isolated networks**: CAPC can create new isolated networks or use existing ones. Each isolated network gets its own gateway and DHCP.
- **Shared networks**: Supported — uses the shared guest network without creating additional networking resources
- **Security groups**: Applied via CloudStack security group rules for cluster communication

### Image Requirements

CAPC requires pre-built images with Kubernetes prerequisites installed (container runtime, kubelet, kubeadm). Prebuilt images are available from [shapeblue packages](http://packages.shapeblue.com/cluster-api-provider-cloudstack/images/) for:

| Hypervisor | Formats | OS Versions |
|------------|---------|-------------|
| KVM | qcow2 (bz2) | Rocky 9, Ubuntu 22.04, Ubuntu 24.04 |
| VMware | ova | Rocky 9, Ubuntu 22.04, Ubuntu 24.04 |
| XenServer | vhd (bz2) | Rocky 9, Ubuntu 22.04, Ubuntu 24.04 |

Supported Kubernetes versions: **v1.28 through v1.32** (tested). Prebuilt images available for all supported K8s versions.

### CloudStack Compatibility

| Provider Version | Supported CloudStack Versions |
|-----------------|------------------------------|
| v0.4 | 4.14 – 4.19 |
| v0.6 | 4.15 – 4.20 |

Supported Kubernetes versions (tested):

| Provider Version | K8s Versions |
|-----------------|-------------|
| v0.4 | v1.22 – v1.27 |
| v0.6 | v1.23 – v1.32 |

### Cross-Cutting: CCM and CSI

CAPC clusters **do not** auto-deploy the CloudStack Kubernetes Provider (CCM) or CSI driver — these must be installed manually after cluster creation, unlike CKS which handles them natively.

- **CloudStack Kubernetes Provider (CCM)**: Deploy as a Helm chart or manifest to enable `LoadBalancer` service type and node metadata labels
- **CloudStack CSI Driver**: Deploy separately for persistent storage with dynamic provisioning

See [CloudStack Kubernetes Provider](./cloudstack-kubernetes-provider.md) and [CloudStack CSI Driver](./cloudstack-csi-driver.md) for details.

### CKS Sync Mode (Optional)

CAPC can optionally sync machine resources back to CloudStack's native CKS integration by setting `CLOUDSTACK_SYNC_WITH_ACS=true`. This requires:
- Setting the environment variable before initializing CAPC, OR
- Setting `enable-cloudstack-cks-sync: true` in the CAPC controller deployment

This is useful when you want CAPC-managed clusters to also appear in CloudStack's native Kubernetes service UI.

## Key Differences from CKS

| Aspect | CKS (Native) | CAPC |
|--------|-------------|------|
| **Cluster model** | CloudStack-native `Kubernetes` domain object | K8s CRDs (`Cluster`, `CloudStackCluster`) |
| **Management API** | CloudStack API / UI | Kubernetes API via `clusterctl` |
| **GitOps ready** | No | Yes — declarative YAML, version-controllable |
| **Multi-cluster** | Limited (per-CCS account) | Native (CAPI manages many clusters from one mgmt cluster) |
| **Node OS flexibility** | Custom ISO via CKS template | Any cloud-init-compatible image with K8s prereqs |
| **Scaling model** | UI/API buttons | `replicas` field on MachineDeployment |
| **Upgrade path** | Manual (UI or API) | Rolling update via KubeadmControlPlane spec change |
| **Terraform support** | No | Yes — CAPI Terraform provider exists |

## References

- [GitHub: kubernetes-sigs/cluster-api-provider-cloudstack](https://github.com/kubernetes-sigs/cluster-api-provider-cloudstack)
- [CAPC Book: Building CAPC](https://cluster-api-cloudstack.sigs.k8s.io/development/building)
- [Cluster API Overview](https://cluster-api.sigs.k8s.io/overview)
- [Prebuilt Images](http://packages.shapeblue.com/cluster-api-provider-cloudstack/images/)
