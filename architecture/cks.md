# CloudStack Kubernetes Service (CKS) — Architecture

## Overview

CKS is Apache CloudStack's native Kubernetes integration, available since ACS 4.14. It provides a fully managed container orchestration service that simplifies deployment, scaling, and management of Kubernetes clusters on CloudStack infrastructure.

## Core Components

### 1. Management Server Integration
- **Plugin:** Kubernetes Service plugin (disabled by default)
- **Global Config:** `cloud.kubernetes.service.enabled`
- **Endpoint:** `endpoint.url` → `<management-server-ip>:8080/client/api`
- **UI:** Kubernetes tab under Compute section (visible after enabling)

### 2. Provisioning Engine
- Uses **kubeadm** under the hood for cluster bootstrapping
- **Control nodes:** `kubeadm init` with custom tokens
- **Worker nodes:** `kubeadm join` with matching tokens
- **Pre-packaged ISOs** containing Kubernetes binaries and Docker images for fast, offline-ish provisioning

### 3. Node Infrastructure
- Kubernetes nodes run as standard CloudStack VM instances
- Uses CloudStack SystemVM template by default (or custom CKS-marked templates from 4.21+)
- Nodes are provisioned within CloudStack zones (KVM, VMware, etc.)
- Supports hypervisor type selection (from 4.21+)

### 4. Networking
- **CNI:** Calico (default from ACS 4.21)
- **Network types:** Shared, Isolated, and VPC networks supported
- **Default Network Offering:** `DefaultNetworkOfferingforKubernetesService` (from 4.14)
- **Global Config:** `cloud.kubernetes.cluster.network.offering`
- Port forwarding rules auto-provisioned for isolated networks
- SSH access via virtual router: `2222 + node_index`

### 5. Control Plane HA (from 4.16+)
- Multi-control node clusters for HA (Kubernetes 1.16+)
- External load balancer required for shared networks (manual setup)
- Load balancer forwards:
  - SSH: port 2222 → 2222 + node_count - 1
  - API Server: port 6443 → control nodes

### 6. Flexible Node Types (from 4.21)
- Separate templates and service offerings per node type:
  - **Control nodes** — custom template + service offering
  - **Worker nodes** — custom template + service offering
  - **Etcd nodes** — dedicated (unstacked), custom template + service offering
- Templates marked with "For CKS" flag during registration

### 7. Cluster API Integration (from 4.21)
- Enhanced visibility for CAPC clusters alongside CKS clusters
- ExternalManaged cluster support (from 4.19)
- View non-CKS clusters centrally via `createKubernetesCluster` API with `externalManaged=true`

## Data Flow

```
User/Admin
    │
    ▼
┌─────────────────────┐
│  CloudStack UI/API  │
│  (Kubernetes Tab)   │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│ Management Server   │
│ (CKS Plugin)        │
│                     │
│ - Provisions VMs    │
│ - Distributes ISO   │
│ - Runs kubeadm      │
│ - Manages lifecycle │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  CloudStack Zone    │
│                     │
│  ┌───────────────┐  │
│  │ Control Node(s)│  │
│  │ (kubeadm init) │  │
│  └───────┬───────┘  │
│          │           │
│  ┌───────┴───────┐  │
│  │ Worker Node(s) │  │
│  │ (kubeadm join) │  │
│  └───────────────┘  │
│                     │
│  ┌───────────────┐  │
│  │ Etcd Node(s)   │  │ (optional, from 4.21)
│  │ (dedicated)    │  │
│  └───────────────┘  │
└─────────────────────┘
```

## Supported Kubernetes Versions

- Multiple versions supported simultaneously via uploaded ISOs
- Pre-built ISOs available at:
  - `http://download.cloudstack.org/cks/`
  - `http://packages.shapeblue.com/cks/`
- ISOs contain:
  - Kubernetes binaries
  - Docker/containerd images
  - CNI plugins (Calico)
  - Kubernetes Dashboard
  - etcd binaries (optional, from 4.21)
- ISO creation script: `create-kubernetes-binaries-iso.sh` (in cloudstack-common package)

## Key APIs

### Admin APIs
| API | Purpose |
|-----|---------|
| `addKubernetesSupportedVersion` | Register a new K8s version (ISO) |
| `updateKubernetesSupportedVersion` | Enable/disable a version |
| `deleteKubernetesSupportedVersion` | Remove a version |

### Cluster APIs
| API | Purpose |
|-----|---------|
| `createKubernetesCluster` | Create a new cluster |
| `listKubernetesCluster` | List all clusters |
| `stopKubernetesCluster` | Stop a cluster |
| `startKubernetesCluster` | Start a stopped cluster |
| `scaleKubernetesCluster` | Scale worker node count |
| `upgradeKubernetesCluster` | Upgrade K8s version |
| `deleteKubernetesCluster` | Delete a cluster |
| `addKubernetesClusterNode` | Add pre-created VMs as workers |
| `removeKubernetesClusterNode` | Remove worker nodes |

## Accessing the Cluster

- **kubeconfig:** Provided via API/UI
- **Dashboard:** Access via `kubectl proxy` (no direct external exposure)
- **SSH:** Via virtual router port forwarding (`ssh -p 222X cloud@<VR_IP>`)

## Limitations

- Complete offline provisioning not supported (kubeadm init requires internet access)
- etcd binaries must be bundled in ISO for dedicated etcd nodes
- Shared network HA requires manual load balancer setup
- Node upgrade marking available, but full node-level upgrades are manual

## References

- [Official CloudStack CKS Documentation](http://docs.cloudstack.apache.org/en/latest/plugins/cloudstack-kubernetes-service.html)
- [Flexible CKS Clusters in CloudStack 4.21](https://www.shapeblue.com/flexible-cks-clusters-in-cloudstack-4-21/)
- [Kubeadm Documentation](https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm/)
- [Calico CNI](https://docs.projectcalico.org/getting-started/kubernetes/)
