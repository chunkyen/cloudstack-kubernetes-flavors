# Rancher Turtles + CAPC Architecture

## Overview

This architecture combines three layers:

1. **Rancher** — management plane with UI, Fleet GitOps, and cluster lifecycle
2. **Rancher Turtles** — CAPI operator that manages infrastructure providers declaratively
3. **CAPC** — CloudStack infrastructure provider for Cluster API

The result: declarative, GitOps-driven Kubernetes cluster provisioning on CloudStack infrastructure, managed through the Rancher UI.

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
│  │  │  + Project   │  └──────────────┬───────────────────┘  │   │
│  │  │  + RBAC      │                 │                       │   │
│  │  └──────────────┘                 │                       │   │
│  └───────────────────────────────────┼───────────────────────┘   │
│                                      │ clusterctl                │
│                                      │ generate cluster          │
│                                      ▼                           │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │              Management Cluster (CAPC)                    │   │
│  │         (CKS cluster on CloudStack via CAPC)              │   │
│  │                                                           │   │
│  │  ┌──────────────────────────────────────────────────┐    │   │
│  │  │ CAPC Controllers                                 │    │   │
│  │  │                                                  │    │   │
│  │  │  CloudStackCluster  ──► CloudStack VMs (CP)     │    │   │
│  │  │  CloudStackMachineSet ──► CKS Worker Nodes      │    │   │
│  │  │  CloudStackMachine ──► CKS Etcd Nodes           │    │   │
│  │  └──────────────────────────────────────────────────┘    │   │
│  └───────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

## Layer Breakdown

### Layer 1: Bootstrap Cluster

The bootstrap cluster is where Rancher and Turtles run. It can be:
- A CKS cluster on CloudStack (recommended — same infrastructure)
- Any existing K8s cluster (kind, EKS, GKE, on-prem)
- A dedicated management cluster

**Purpose:** Runs the control plane that manages workload cluster creation.

### Layer 2: Rancher + Turtles

**Rancher** provides:
- Web UI for cluster lifecycle
- Fleet for GitOps (declarative cluster config in Git)
- RBAC, project isolation, multi-tenancy
- Monitoring, logging, and cert management

**Turtles** provides:
- Declarative CAPI provider management via `CAPIProvider` CRDs
- Automatic provider manifest generation and lifecycle
- Integration with Rancher's cluster model
- Support for ClusterClass (topology-based cluster templates)

**Provider stack installed by Turtles:**

| Provider | Type | Role |
|----------|------|------|
| `cluster-api` | core | CAPI core controllers |
| `kubeadm` | bootstrap | Kubeadm bootstrap data generation |
| `kubeadm` | controlPlane | Control plane machine lifecycle |
| `cloudstack` | infrastructure | CloudStack VM provisioning (CAPC) |

### Layer 3: CAPC (Workload Clusters)

CAPC runs inside the management cluster and:
- Watches `CloudStackCluster`, `CloudStackMachine`, `CloudStackMachineSet` CRDs
- Translates them into CloudStack API calls
- Provisions VMs, networking, load balancers, security groups
- Manages node lifecycle (scale, upgrade, delete)

## Data Flow

```
1. User declares cluster in Git (Fleet) or Rancher UI
         │
         ▼
2. Fleet/Rancher applies CAPI CRDs to bootstrap cluster
         │
         ▼
3. Turtles ensures CAPC provider is running
         │
         ▼
4. CAPI controller creates CloudStackCluster + KubeadmControlPlane
         │
         ▼
5. CAPC controller provisions CloudStack VMs
         │
         ▼
6. VMs boot with cloud-init → kubeadm init/join
         │
         ▼
7. Cluster becomes Ready — Fleet imports kubeconfig
         │
         ▼
8. Workload manifests deployed via Fleet GitOps
```

## Key Differences from Standalone CAPC

| Aspect | Standalone CAPC | Rancher Turtles + CAPC |
|--------|----------------|------------------------|
| **Management** | `clusterctl` CLI | Rancher UI + Fleet GitOps |
| **Provider lifecycle** | Manual install | Declarative `CAPIProvider` CRD (all providers deployed into `cattle-capi-system` by Turtles v0.6.1) |
| **Multi-cluster** | Manual kubeconfig management | CAPI creates clusters via CAPC, Rancher Turtles imports them into Rancher for management |
| **RBAC** | K8s RBAC only | Rancher RBAC + projects |
| **GitOps** | Manual (argocd etc.) | Fleet built-in |
| **Monitoring** | Manual setup | Rancher monitoring built-in |
| **Cert management** | Manual | Rancher cert-manager integration |
| **Upgrade path** | Manual provider + cluster | Helm upgrade + CAPI rolling update |
| **Cluster templates** | Manual YAML | ClusterClass (topology templates) |

## Namespace Layout

Turtles v0.6.1 deploys all CAPI providers into a single namespace:

| Component | Namespace |
|---|---|
| Turtles controller | `cattle-turtles-system` |
| Core CAPI + all providers (kubeadm, cloudstack) | `cattle-capi-system` |

Each provider runs as a separate deployment within `cattle-capi-system` (e.g., `capc-controller-manager`, `capi-kubeadm-bootstrap-controller-manager`). CRDs are cluster-scoped.

## Credential Model

Certified providers (vSphere, AWS, Azure) use Rancher's built-in `rancherCloudCredential` type. CloudStack does not have a native Rancher cloud credential, so CAPC uses a custom `configSecret`:

```yaml
# CAPC uses configSecret instead of rancherCloudCredential
apiVersion: turtles-capi.cattle.io/v1alpha1
kind: CAPIProvider
metadata:
  name: cloudstack
  namespace: cattle-capi-system
spec:
  name: cloudstack
  type: infrastructure
  configSecret:
    name: cloudstack-credentials  # custom secret, not Rancher cloud credential
```

The secret contains CloudStack API credentials and configuration:
- `api-url` — management server URL (full URL with scheme)
- `api-key` / `secret-key` — API credentials
- `verify-ssl` — set to `"false"` for self-signed certificates

## Node Drivers vs CAPI Infrastructure Providers

Rancher supports two different cluster provisioning models that are often confused:

### Node Drivers (Legacy)

Node drivers use the Docker Machine interface to provision infrastructure hosts. They are used by Rancher's node driver cluster provisioning path (the old v2prov model for K3s/RKE2):

- **Built-in drivers** (AWS, DigitalOcean, Azure, etc.) — still work in v2.13
- **Custom drivers** — **broken in v2.13** due to the Rancher Provisioning → Turtles migration ([known issue](https://forums.suse.com/t/rancher-release-v2-13-0/46038))
- **Direction** — deprecated; Rancher is moving away from Docker Machine

### CAPI Infrastructure Providers (Modern)

CAPI providers like CAPC use the Cluster API framework — a completely separate provisioning path:

- **CAPC** — CloudStack infrastructure provider for Cluster API
- **Not a node driver** — uses its own CRDs (`CloudStackCluster`, `CloudStackMachine`, etc.)
- **Independent of node drivers** — runs in the `capc-system` namespace, managed by Turtles via `CAPIProvider` CRD
- **Direction** — actively developed, officially supported

### Side-by-Side

| | Node Drivers | CAPC (CAPI Provider) |
|---|---|---|
| **Provisioning model** | Docker Machine | Cluster API |
| **Built-in drivers** | ✅ still work | N/A |
| **Custom drivers** | ⚠️ broken in v2.13 | N/A |
| **Rancher UI** | Cluster Management → Node Pools | Cluster Management → Machines/MachineSets/MachineDeployments |
| **Status** | Legacy | Active |
| **CAPC relevance** | ❌ not applicable | ✅ works independently |

Node drivers and Turtles/CAPC are parallel, non-competing systems. Turtles replaced the Rancher Provisioning component (K3s/RKE2 v2prov engine), not node drivers. CAPC does not go through the node driver mechanism — it's a full CAPI infrastructure provider with its own lifecycle managed by Turtles.

## References

- [CAPC Architecture](./capc.md)
- [Rancher Turtles Docs](https://turtles.docs.rancher.com)
- [Fleet Docs](https://fleet.rancher.io)
- [CAPC Book](https://cluster-api-cloudstack.sigs.k8s.io)
