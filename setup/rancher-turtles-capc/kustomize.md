# Kustomize — Composable CAPC Cluster Deployments

Instead of a 1600-line monolithic YAML, use Kustomize to compose clusters from
small, focused files. Each overlay is a cluster-specific configuration.

## Structure

```
manifests/kustomize/
├── base/                          # Shared cluster template (CCM + CSI, no CNI)
│   ├── kustomization.yaml         # Composes all base resources
│   ├── namespace.yaml              # Namespace
│   ├── cloudstack-credentials.yaml # CloudStack API credentials (placeholders)
│   ├── cluster-infra.yaml          # Cluster + CloudStackCluster
│   ├── control-plane.yaml          # KubeadmControlPlane + MachineTemplate
│   ├── workers.yaml                # MachineDeployment + KubeadmConfigTemplate
│   ├── cluster-resource-set.yaml   # ClusterResourceSet
│   └── addons/                     # CCM + CSI (CNI is per-overlay)
│       ├── ccm.yaml                # CCM: CloudStack Kubernetes Provider
│       └── csi.yaml                # CSI: CloudStack CSI Driver + StorageClass
└── overlays/
    ├── generic-cluster/                   # Example: capc-generic-cluster (Calico CNI)
    │   ├── kustomization.yaml      # Patches base + merges Calico
    │   └── calico.yaml             # Calico v3.28.0 manifest
    └── generic-cluster-cilium/            # Example: capc-generic-cluster (Cilium CNI)
        ├── kustomization.yaml      # Patches base + merges Cilium
        └── cilium.yaml             # Cilium v1.16.0 manifest
```

## CNI Choice

The base includes **CCM + CSI only** — no CNI. Each overlay picks its CNI:

| Overlay | CNI | File |
|---------|-----|------|
| `overlays/generic-cluster/` | Calico v3.28.0 | `calico.yaml` |
| `overlays/generic-cluster-cilium/` | Cilium v1.16.0 | `cilium.yaml` |

To switch CNI, copy the overlay and change the `configMapGenerator` file reference.

## Usage

### Build (dry-run)

```bash
# Calico
kubectl kustomize manifests/kustomize/overlays/generic-cluster

# Cilium
kubectl kustomize manifests/kustomize/overlays/generic-cluster-cilium
```

### Apply

```bash
kubectl kustomize manifests/kustomize/overlays/generic-cluster | kubectl apply -f -
```

### Create a new cluster

```bash
cp -r manifests/kustomize/overlays/generic-cluster manifests/kustomize/overlays/my-cluster
# Edit manifests/kustomize/overlays/my-cluster/kustomization.yaml with your values
kubectl kustomize manifests/kustomize/overlays/my-cluster | kubectl apply -f -
```

## How it works

1. **Base** defines the cluster template with placeholders (`<reserved-public-ip>`, `<zone-name-or-id>`, etc.)
2. **Overlay** patches the base with cluster-specific values (IP, network, zone, credentials)
3. **configMapGenerator** auto-bundles `addons/*.yaml` into a ConfigMap — no manual inlining
4. **ClusterResourceSet** applies the ConfigMap to the workload cluster after provisioning

## Compared to the one-shot YAML

| | One-shot | Kustomize |
|---|---|---|
| Lines | ~1650 (Calico) / ~2740 (Cilium) | ~150 (overlay) + shared base |
| Addons | Inlined in ConfigMap data | Separate files, auto-bundled |
| New cluster | Copy 1650+ lines, find/replace | Copy 150-line overlay, edit values |
| CNI switch | Copy entire file, replace CNI section | Change one line in overlay |
| Maintenance | Edit one giant file | Edit individual component files |
| Diff review | Hard to see what changed | Clear: only overlay values change |
