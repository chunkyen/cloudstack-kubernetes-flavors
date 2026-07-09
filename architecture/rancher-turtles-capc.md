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
| **Cluster templates** | Manual YAML | Manual YAML (ClusterClass not available — see below) |
| **Bootstrap apps (CNI/CCM/CSI)** | Manual `kubectl apply` | ClusterResourceSet (CAPI-native) or Fleet GitOps |

## ClusterResourceSet — Bootstrap Application Injection

CAPC uses Kubeadm, which has no built-in CNI. The [Rancher Turtles documentation](https://turtles.docs.rancher.com/turtles/stable/en/user/applications.html) recommends using **ClusterResourceSet** (CRS) — a CAPI-native mechanism — to automatically install bootstrap applications (CNI, CCM, CSI) on workload clusters after they're created.

### How it works

```
1. Create a ConfigMap containing the manifests to apply (CNI, CCM, CSI YAML)
         │
         ▼
2. Create a ClusterResourceSet referencing the ConfigMap
   - clusterSelector: matches clusters by label
   - resources: references ConfigMap/Secret by name
   - strategy: ApplyOnce (default) or Reconcile
         │
         ▼
3. CRS controller detects matching cluster
         │
         ▼
4. Applies all manifests from the ConfigMap to the workload cluster's API server
```

### Key properties

| Property | Value | Notes |
|---|---|---|
| `apiVersion` | `addons.cluster.x-k8s.io/v1beta2` | CAPI addons API group |
| `strategy` | `ApplyOnce` (default) or `Reconcile` | `ApplyOnce` runs once; `Reconcile` re-applies on drift |
| `clusterSelector` | label selector | Selects clusters by label — must not be empty |
| `resources` | array of `{name, kind}` | References ConfigMaps/Secrets in the same namespace |
| Namespace scope | namespace-scoped | All resources and clusters must be in the same namespace as the CRS |

### Why CRS instead of ClusterClass

ClusterClass patches modify **template specs** (JSONPatch operations on `/spec/` paths) — they cannot inject arbitrary Kubernetes resources like DaemonSets, Deployments, or Secrets into a workload cluster. CRS is purpose-built for this: it applies any YAML manifest to the workload cluster's API server after creation.

### Alternatives

- **Fleet GitOps** — for ongoing reconciliation of application versions after initial deployment. CRS handles initial bootstrap; Fleet handles ongoing management.
- **Manual `kubectl apply`** — simplest but doesn't scale across multiple clusters.
- **HelmChart CRD** — Turtles docs also mention using `HelmChart` CRDs (`helm.cattle.io/v1`) inside the ConfigMap instead of raw YAML, which works well when a component has a Helm chart (e.g. Cilium, Azure CCM).

See [Full-Stack Onboarding](../setup/rancher-turtles-capc/full-stack-onboarding.md) for a complete CRS implementation guide.

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

## ClusterClass — Not Available for CAPC

CAPI ClusterClass is a feature that defines reusable cluster templates. A `Cluster` using topology mode references a ClusterClass, and the CAPI topology controller expands it into the full set of provider CRDs (`CloudStackCluster`, `KubeadmControlPlane`, `MachineDeployment`, `CloudStackMachineTemplate`, `KubeadmConfigTemplate`).

**ClusterClass cannot be used with CAPC today.** CAPC does not implement `CloudStackClusterTemplate`, the CRD that ClusterClass requires for its `infrastructure.templateRef` field.

For ClusterClass to work, each infrastructure provider must implement two template CRDs:

| CRD | Purpose | CAPC status |
|-----|---------|------------|
| `CloudStackMachineTemplate` | Machine-level template (offering, image, SSH key) | ✅ Implemented |
| `CloudStackClusterTemplate` | Cluster-level template (network, zone, endpoints) | ❌ Not implemented |

Without `CloudStackClusterTemplate`, the topology controller has nothing to expand the `Cluster` topology's infrastructure layer into — ClusterClass cannot function.

### What this means in practice

- **Cluster topology mode** (`spec.topology.class`) is not available for CAPC clusters
- Clusters must be created with **explicit CRD references** — `CloudStackCluster`, `KubeadmControlPlane`, `MachineDeployment`, `CloudStackMachineTemplate`, `KubeadmConfigTemplate`
- **ClusterResourceSet** (not ClusterClass) is the correct mechanism for auto-installing CNI/CCM/CSI — see [Full-Stack Onboarding](../setup/rancher-turtles-capc/full-stack-onboarding.md)
- Cluster upgrades are done by creating new `CloudStackMachineTemplate` objects and updating `KubeadmControlPlane`/`MachineDeployment` references — see [Upgrade Guide](../setup/rancher-turtles-capc/cluster.md#8-upgrade-the-cluster)

### What CAPC would need to support ClusterClass

1. Implement a `CloudStackClusterTemplate` CRD with a `spec.template.spec` mirroring `CloudStackCluster.spec`
2. Register it with the CAPI topology controller
3. The CAPC controller would reconcile `CloudStackCluster` objects created from the template (same as it does today for manually-created ones)

This is a provider-level implementation gap, not a configuration issue. It would need to be addressed in the [CAPC project](https://github.com/apache/cloudstack-kubernetes-provider).

### Comparison with other CAPI providers

| Provider | MachineTemplate | ClusterTemplate | ClusterClass support |
|----------|----------------|-----------------|---------------------|
| CAPA (AWS) | ✅ | ✅ | ✅ |
| CAPD (Docker) | ✅ | ✅ | ✅ |
| CAPV (vSphere) | ✅ | ✅ | ✅ |
| CAPZ (Azure) | ✅ | ✅ | ✅ |
| **CAPC (CloudStack)** | ✅ | ❌ | ❌ |

## References

- [CAPC Architecture](./capc.md)
- [Rancher Turtles Docs](https://turtles.docs.rancher.com)
- [Fleet Docs](https://fleet.rancher.io)
- [CAPC Book](https://cluster-api-cloudstack.sigs.k8s.io)
- [CAPI ClusterClass documentation](https://cluster-api.sigs.k8s.io/tasks/experimental-features/cluster-class)
- [Rancher Turtles — Installing applications](https://turtles.docs.rancher.com/turtles/stable/en/user/applications.html) — recommends ClusterResourceSet for Kubeadm-based clusters
