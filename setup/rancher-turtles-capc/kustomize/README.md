# Kustomize — Composable CAPC Cluster Deployments

Instead of a 1600-line monolithic YAML, use Kustomize to compose clusters from
small, focused files. Each overlay is a cluster-specific configuration.

## Structure

```
kustomize/
├── base/                          # Shared cluster template
│   ├── kustomization.yaml         # Composes all base resources
│   ├── namespace.yaml              # Namespace
│   ├── cloudstack-credentials.yaml # CloudStack API credentials (placeholders)
│   ├── cluster-infra.yaml          # Cluster + CloudStackCluster
│   ├── control-plane.yaml          # KubeadmControlPlane + MachineTemplate
│   ├── workers.yaml                # MachineDeployment + KubeadmConfigTemplate
│   ├── cluster-resource-set.yaml   # ClusterResourceSet
│   └── addons/                     # Workload cluster addons (auto-bundled into ConfigMap)
│       ├── calico.yaml             # CNI: Calico v3.28.0
│       ├── ccm.yaml                # CCM: CloudStack Kubernetes Provider
│       └── csi.yaml                # CSI: CloudStack CSI Driver + StorageClass
└── overlays/
    └── cluster3/                   # Example: capc-cluster3
        └── kustomization.yaml      # Patches base with cluster3-specific values
```

## Usage

### Build (dry-run)

```bash
kubectl kustomize kustomize/overlays/cluster3
```

### Apply

```bash
kubectl kustomize kustomize/overlays/cluster3 | kubectl apply -f -
```

### Create a new cluster

```bash
cp -r overlays/cluster3 overlays/my-cluster
# Edit overlays/my-cluster/kustomization.yaml with your values
kubectl kustomize overlays/my-cluster | kubectl apply -f -
```

## How it works

1. **Base** defines the cluster template with placeholders (`<reserved-public-ip>`, `<zone-name-or-id>`, etc.)
2. **Overlay** patches the base with cluster-specific values (IP, network, zone, credentials)
3. **configMapGenerator** auto-bundles `addons/*.yaml` into a ConfigMap — no manual inlining
4. **ClusterResourceSet** applies the ConfigMap to the workload cluster after provisioning

## Compared to the one-shot YAML

| | One-shot (13-one-shot-full-stack.yaml) | Kustomize |
|---|---|---|
| Lines | ~1650 | ~150 (overlay) + shared base |
| Addons | Inlined in ConfigMap data | Separate files, auto-bundled |
| New cluster | Copy 1650 lines, find/replace | Copy 150-line overlay, edit values |
| Maintenance | Edit one giant file | Edit individual component files |
| Diff review | Hard to see what changed | Clear: only overlay values change |
