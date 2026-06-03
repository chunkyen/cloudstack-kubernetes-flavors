# CNI Automation Options for CAPC Clusters

CAPC does not install a CNI plugin automatically — this is a deliberate design choice. The CNI is a separate concern from cluster provisioning. However, you can automate it as part of the deployment workflow. This document covers three approaches, from most idiomatic to simplest.

## Overview

| Approach | How It Works | Complexity | CNI Customization | Survives `clusterctl move` |
|----------|-------------|------------|-------------------|--------------------------|
| **1. ClusterResourceSet** | CAPI-native CRD applies CNI manifests after cluster creation | Medium | High (ConfigMap-based) | ✅ Yes |
| **2. Kustomize Overlay** | Patches generated cluster spec with CNI manifests | Low | Medium (static manifests) | ❌ No (needs re-apply) |
| **3. postKubeadmCommands** | Injects CNI install into node bootstrap script | Low | Low (inline script) | ✅ Yes (baked into nodes) |

---

## Option 1: ClusterResourceSet (CAPI-Native, Recommended)

### Concept

`ClusterResourceSet` is a built-in Cluster API component that applies a set of Kubernetes resources to a workload cluster after it is provisioned. It runs once per cluster, tracks applied resources, and survives `clusterctl move` operations.

### Architecture

```
Management Cluster
├── ClusterResourceSet (CRD) — "apply CNI to capc-cluster"
│   └── ResourceSelector: cluster.name = "capc-cluster"
├── ConfigMap — contains CNI YAML (Calico/Cilium)
│   └── data.cni-manifest.yaml: |-
│       apiVersion: policy/v1
│         kind: PodDisruptionBudget
│         ...
└── CAPC Controllers → create VMs → CNI applied automatically
```

### Setup

#### Step 1: Install ClusterResourceSet CRDs

The `ClusterResourceSet` CRDs ship with CAPI core. Deploy them to your management cluster:

```bash
# From the CAPI repository
kubectl apply -f https://github.com/kubernetes-sigs/cluster-api/releases/download/v1.8.6/core-components.yaml
```

Or if you're building CAPI from source:

```bash
make generate
kubectl apply -f config/crd/bases/
```

#### Step 2: Create the CNI ConfigMap

Package your CNI manifest into a ConfigMap:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cni-manifests
  namespace: capc-cluster-system
  labels:
    cluster.x-k8s.io/cluster-name: capc-cluster
data:
  calico.yaml: |
    apiVersion: policy/v1
    kind: PodDisruptionBudget
    metadata:
      name: calico-pdb
      namespace: kube-system
    spec:
      minAvailable: 75%
      selector:
        matchLabels:
          k8s-app: calico-node
    ---
    # ... rest of Calico manifest ...
```

For Cilium:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cni-manifests
  namespace: capc-cluster-system
  labels:
    cluster.x-k8s.io/cluster-name: capc-cluster
data:
  cilium.yaml: |
    apiVersion: v1
    kind: Namespace
    metadata:
      name: cilium
    ---
    # ... Cilium operator + hubble + agent manifests ...
```

#### Step 3: Create the ClusterResourceSet

```yaml
apiVersion: cluster.x-k8s.io/v1alpha4
kind: ClusterResourceSet
metadata:
  name: capc-cluster-cni
  namespace: capc-cluster-system
spec:
  clusterSelector:
    matchLabels:
      cni: calico          # or cilium
  resourceSelector:
    matchLabels:
      cluster.x-k8s.io/cluster-name: capc-cluster
```

#### Step 4: Label Your Cluster

Add the matching label to your workload cluster:

```bash
kubectl label cluster capc-cluster cni=calico --namespace=capc-cluster-system
```

### How It Works

1. CAPC creates the cluster VMs and the control plane becomes `Ready`
2. The `ClusterResourceSet` controller detects the cluster has the matching label
3. It applies all resources from the referenced ConfigMap to the workload cluster
4. Resources are tracked — if updated, only changed resources are reapplied
5. On `clusterctl move`, the `ClusterResourceSet` moves with the cluster

### Pros

- **CAPI-native** — the canonical way to do this in the Cluster API ecosystem
- **Declarative** — manifests are stored as ConfigMaps, version-controlled
- **Selective** — use labels to target specific clusters
- **Idempotent** — tracks applied resources, only reapplies on change
- **Survives clusterctl move** — moves with the cluster
- **Multiple CNIs** — use different labels for different clusters (Calico on prod, Cilium on staging)

### Cons

- Requires `ClusterResourceSet` CRDs to be deployed on the management cluster
- Adds a dependency on CAPI core components
- CNI manifests are static (harder to parameterize per-cluster)
- Debugging: if CNI fails to apply, you need to check the `ClusterResourceSet` status

### Debugging

```bash
# Check ClusterResourceSet status
kubectl get clustersetresource capc-cluster-cni -n capc-cluster-system -o yaml

# Check applied resources
kubectl get clustersetresource -n capc-cluster-system

# View events
kubectl describe clustersetresource capc-cluster-cni -n capc-cluster-system

# Check if resources were applied to workload cluster
KUBECONFIG=capc-cluster.kubeconfig kubectl get pods -n kube-system
KUBECONFIG=capc-cluster.kubeconfig kubectl get pods -n cilium
```

---

## Option 2: Kustomize Overlay

### Concept

Use Kustomize to patch the cluster spec generated by `clusterctl generate` with CNI manifests. The overlay produces a single output directory containing both the cluster spec and CNI manifests, which you apply together.

### Directory Structure

```
cni-overlay/
├── kustomization.yaml    # Kustomize config
├── patches/
│   └── cluster.yaml      # (optional) cluster patches
└── cni-manifests/
    ├── calico.yaml       # Calico manifest
    └── cilium.yaml       # Cilium manifest
```

### Kustomize Configuration

```yaml
# cni-overlay/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# Base: the cluster spec generated by clusterctl generate
resources:
  - ../base-cluster-spec   # directory containing capc-cluster-spec.yaml

# Add CNI manifests
resources:
  - cni-manifests/calico.yaml

# Optional: patch the cluster spec
patches:
  - path: patches/cluster.yaml
```

### Usage

```bash
# Generate base cluster spec
clusterctl generate cluster capc-cluster \
  --kubernetes-version v1.32 \
  --control-plane-machine-count=3 \
  --worker-machine-count=2 \
  > base-cluster-spec/cluster.yaml

# Apply with CNI overlay
kubectl apply -k cni-overlay/
```

### Parameterized Overlay (Advanced)

For more flexibility, create separate overlays for each CNI:

```
cni-overlays/
├── calico/
│   ├── kustomization.yaml
│   └── cni-manifests/calico.yaml
├── cilium/
│   ├── kustomization.yaml
│   └── cni-manifests/cilium.yaml
└── base/
    └── cluster.yaml
```

```yaml
# cni-overlays/calico/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base/cluster.yaml
  - cni-manifests/calico.yaml
```

```bash
kubectl apply -k cni-overlays/calico/
```

### Pros

- **Simple** — no extra CRDs or components needed
- **Transparent** — you see exactly what gets applied
- **Flexible** — mix any manifests, not just CNI
- **No CAPI dependency** — works with any cluster provisioning tool
- **Easy to debug** — standard `kubectl apply -k` output

### Cons

- **Not idiomatic CAPI** — doesn't use Cluster API's built-in mechanisms
- **Static manifests** — CNI configs are baked in, harder to customize per-cluster
- **No tracking** — doesn't track what was applied; re-applying is a no-op but not declarative
- **Doesn't survive `clusterctl move`** — you need to re-apply CNI after moving the cluster
- **Timing** — CNI is applied immediately, not after the cluster is ready (may race with node join)

### Timing Consideration

Unlike `ClusterResourceSet`, Kustomize applies CNI immediately — before the cluster is necessarily ready. This is usually fine since CNI manifests are idempotent, but you may see transient errors if nodes aren't joined yet.

To mitigate, you can add a small delay or use `kubectl wait`:

```bash
kubectl apply -k cni-overlay/
KUBECONFIG=capc-cluster.kubeconfig kubectl wait --for=condition=ready pod -l k8s-app=calico-node -n kube-system --timeout=300s
```

---

## Option 3: postKubeadmCommands (Bootstrap Script)

### Concept

Inject CNI installation into the node bootstrap process via `postKubeadmCommands` in `KubeadmConfigSpec`. This runs as a shell script on every node after `kubeadm join` completes.

### How It Works

```
Node Bootstrap Flow:
┌─────────────────────────────────────────────────┐
│ 1. cloud-init runs on VM boot                   │
│ 2. kubeadm init/join executes                   │
│ 3. postKubeadmCommands runs (CNI install)       │
│ 4. Node becomes Ready                           │
└─────────────────────────────────────────────────┘
```

### Implementation

Add `postKubeadmCommands` to your cluster spec:

```yaml
apiVersion: controlplane.cluster.x-k8s.io/v1beta1
kind: KubeadmControlPlane
metadata:
  name: capc-cluster-control-plane
spec:
  kubeadmConfigSpec:
    joinConfiguration:
      postKubeadmCommands:
        - |2
          # Install Calico
          kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
          # Wait for Calico pods
          kubectl wait --for=condition=ready pod -l k8s-app=calico-node -n kube-system --timeout=300s
    users:
      - name: ubuntu
        sshAuthorizedKeys:
          - ssh-rsa AAAA...
```

For worker nodes (MachineDeployment):

```yaml
apiVersion: cluster.x-k8s.io/v1beta1
kind: MachineDeployment
metadata:
  name: capc-cluster-md-0
spec:
  template:
    spec:
      bootstrap:
        kubeadmConfigSpec:
          joinConfiguration:
            postKubeadmCommands:
              - |2
                # Install Calico on worker nodes
                kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
                kubectl wait --for=condition=ready pod -l k8s-app=calico-node -n kube-system --timeout=300s
```

### Parameterized Version

For more control, use a script that fetches the CNI manifest:

```yaml
postKubeadmCommands:
  - |
    #!/bin/bash
    set -ex

    # Download CNI manifest
    curl -sSL https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml \
      -o /tmp/calico.yaml

    # Apply CNI
    kubectl apply -f /tmp/calico.yaml

    # Wait for CNI to be ready
    kubectl wait --for=condition=ready pod -l k8s-app=calico-node -n kube-system --timeout=300s
```

### Pros

- **Simple** — no extra CRDs, components, or tooling
- **Guaranteed timing** — CNI installs after the node joins, so `kubectl` works
- **Works everywhere** — no CAPI-specific features needed
- **Survives clusterctl move** — CNI is baked into the node image/bootstrap
- **Per-node** — each node gets CNI independently

### Cons

- **Runs on every node** — wasteful; every node downloads and applies the same CNI manifest
- **Slower bootstrap** — adds CNI install time to each node's join process
- **Hard to customize** — inline scripts in YAML are hard to maintain and version
- **No central tracking** — no way to know if CNI was applied across all nodes
- **Fragile** — if the CNI manifest URL changes or goes down, nodes fail to join
- **Not declarative** — this is imperative scripting, not a Kubernetes-native approach
- **Control plane + workers** — you need to add it to both `KubeadmControlPlane` and `MachineDeployment`

### When to Use

This approach is best for:
- **Quick prototypes** — you need CNI working fast and don't care about elegance
- **Simple single-CNI setups** — you always use the same CNI across all clusters
- **No CAPI experience** — you're not familiar with ClusterResourceSet or Kustomize

---

## Comparison Summary

### Decision Matrix

| Criteria | ClusterResourceSet | Kustomize Overlay | postKubeadmCommands |
|----------|-------------------|-------------------|---------------------|
| **CAPI idiomatic** | ✅ Yes | ❌ No | ❌ No |
| **Declarative** | ✅ Yes | ⚠️ Partial | ❌ No |
| **Idempotent** | ✅ Yes | ⚠️ Partial | ❌ No |
| **Per-cluster CNI** | ✅ Yes | ⚠️ Manual | ❌ No |
| **Survives clusterctl move** | ✅ Yes | ❌ No | ✅ Yes |
| **Easy to debug** | ⚠️ Moderate | ✅ Easy | ⚠️ Moderate |
| **Performance** | ✅ Fast (once) | ✅ Fast (once) | ❌ Slow (per node) |
| **Extra dependencies** | ⚠️ CRDs needed | ❌ None | ❌ None |
| **Maintenance** | ✅ Good | ✅ Good | ❌ Poor |

### Recommendation

**For production CAPC deployments:** Use **ClusterResourceSet**. It's the idiomatic CAPI way, survives cluster lifecycle operations, and gives you clean separation between cluster provisioning and CNI configuration.

**For quick demos or simple setups:** Use **Kustomize Overlay**. It's the simplest to set up and works well when you have a small number of clusters with static CNI configs.

**Avoid in production:** `postKubeadmCommands` is fine for prototyping but doesn't scale well. The per-node overhead and lack of declarative tracking make it unsuitable for multi-cluster environments.

---

## Appendix: CNI Manifest Sources

### Calico

```bash
# Latest stable version
CALICO_VERSION=$(curl -s https://api.github.com/repos/projectcalico/calico/releases/latest | grep tag_name | cut -d'"' -f4)
echo "Calico version: $CALICO_VERSION"

# Download manifest
curl -sSL "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml" -o calico.yaml
```

### Cilium

```bash
# Latest stable version
CILIUM_VERSION=$(curl -s https://api.github.com/repos/cilium/cilium/releases/latest | grep tag_name | cut -d'"' -f4)
echo "Cilium version: $CILIUM_VERSION"

# Download manifest
curl -sSL "https://raw.githubusercontent.com/cilium/cilium/${CILIUM_VERSION}/install/kubernetes/quickstep.yaml" -o cilium.yaml
```

### Weave Net

```bash
curl -sSL "https://raw.githubusercontent.com/weaveworks/weave/master/prog/weave-kube/weave-daemonset-k8s-1.11.yaml" -o weave.yaml
```

## Appendix: ClusterResourceSet vs Kustomize — When to Choose What

### Choose ClusterResourceSet when:

- You manage multiple clusters with different CNIs
- You use `clusterctl move` to migrate clusters
- You want declarative, tracked resource application
- You need CNI to apply after cluster is ready (not during provisioning)
- You want to separate CNI configuration from cluster spec

### Choose Kustomize Overlay when:

- You have a small number of clusters
- CNI configuration is static and uniform
- You don't use `clusterctl move`
- You want the simplest possible setup
- You're already using Kustomize for other cluster patches

### Choose postKubeadmCommands when:

- You need CNI working immediately and don't want extra components
- You're prototyping or doing a quick demo
- You don't have access to the management cluster's CRD namespace
- You want CNI baked into the node bootstrap process

---

## Next Steps

After choosing an approach:

1. **Test locally** — deploy a small cluster and verify CNI installation
2. **Verify networking** — test pod-to-pod communication across nodes
3. **Check CNI health** — ensure all CNI pods are running and healthy
4. **Document your choice** — add the selected approach to your deployment runbook
5. **Consider Helm** — for Cilium specifically, Helm is the recommended installation method and can be integrated into any of the above approaches

See [Step 5: Deploy the Cluster](./capc.md#step-5-deploy-the-cluster) for the base cluster deployment workflow.
See [Step 6: Install CNI](./capc.md#step-6-install-cni) for the current manual CNI installation instructions.


