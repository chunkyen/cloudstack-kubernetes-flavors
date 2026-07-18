# Deploy CloudStack CCM and CSI on RKE2

The CloudStack **Cloud Controller Manager (CCM)** and **CSI Driver** are deployed automatically as part of cluster provisioning via **ClusterResourceSet** (see [`cluster.md` Step 3](./cluster.md)).

This document details the manifests, upstream sources, and RKE2-specific patches. You only need this if you are:
- **Debugging** the auto-deployed components
- **Deploying manually** to an existing cluster (not via `cluster.md`)
- **Modifying** the ClusterResourceSet ConfigMap

## Architecture

```
ClusterResourceSet (CAPI addon)
  └─ ConfigMap: capc-rke2-cluster-1-post-deploy
       ├─ ccm.yaml       → cloud-controller-manager Deployment
       ├─ csi-rbac.yaml  → RBAC for controller + node
       ├─ csi-controller.yaml → CSI controller Deployment
       ├─ csi-node.yaml  → CSI node DaemonSet (RKE2-patched)
       └─ csidriver.yaml → CSIDriver resource
```

> **Default path:** The `Cluster` manifest at `manifests/10-minimal-cluster.yaml` already includes the `capc-rke2-ccm-csi: "true"` label. When you apply `10-minimal-cluster.yaml` + `20-ccm-csi-configmap.yaml` + `21-clusterresourceset.yaml` together, CCM + CSI are installed automatically. No post-step needed.

## Standalone manifests (for existing clusters or debugging)

If you need to apply CCM + CSI manually to a cluster that was not created with the ClusterResourceSet label:

```bash
# CCM — exact upstream, no modifications
kubectl apply -f manifests/cloudstack-ccm.yaml

# CSI — apply in order
kubectl apply -f manifests/cloudstack-csi-rbac.yaml
kubectl apply -f manifests/cloudstack-csi-snapshot-crds.yaml
kubectl apply -f manifests/cloudstack-csi-volume-snapshot-class.yaml
kubectl apply -f manifests/cloudstack-csi-driver.yaml
kubectl apply -f manifests/cloudstack-csi-controller-deployment-rke2.yaml  # RKE2-patched
kubectl apply -f manifests/cloudstack-csi-node-daemonset-rke2.yaml         # RKE2-patched
```

| File | Source | Image | Notes |
|---|---|---|---|
| `cloudstack-ccm.yaml` | [upstream deployment.yaml](https://github.com/apache/cloudstack-kubernetes-provider/blob/main/deployment.yaml) | `apache/cloudstack-kubernetes-provider:v1.2.0` | Exact upstream — no changes |
| `cloudstack-csi-rbac.yaml` | [upstream rbac.yaml](https://github.com/cloudstack/cloudstack-csi-driver/tree/main/deploy/k8s) | — | Exact upstream |
| `cloudstack-csi-controller-deployment-rke2.yaml` | [upstream controller-deployment.yaml](https://github.com/cloudstack/cloudstack-csi-driver/tree/main/deploy/k8s) | `ghcr.io/cloudstack/cloudstack-csi-driver:main` | **RKE2 patch:** `replicas: 1` (was 2), removed `podAntiAffinity` (conflicts with single-node control plane) |
| `cloudstack-csi-driver.yaml` | [upstream csidriver.yaml](https://github.com/cloudstack/cloudstack-csi-driver/tree/main/deploy/k8s) | — | Exact upstream |
| `cloudstack-csi-snapshot-crds.yaml` | [upstream 00-snapshot-crds.yaml](https://github.com/cloudstack/cloudstack-csi-driver/tree/main/deploy/k8s) | — | Exact upstream |
| `cloudstack-csi-volume-snapshot-class.yaml` | [upstream volume-snapshot-class.yaml](https://github.com/cloudstack/cloudstack-csi-driver/tree/main/deploy/k8s) | — | Exact upstream |
| `cloudstack-csi-node-daemonset-rke2.yaml` | [upstream node-daemonset.yaml](https://github.com/cloudstack/cloudstack-csi-driver/tree/main/deploy/k8s) | `ghcr.io/cloudstack/cloudstack-csi-driver:main` | **RKE2 patch:** removed `/run/cloud-init/` mount (RKE2 doesn't use cloud-init, directory absent) |

### RKE2-specific patches explained

**`cloudstack-csi-controller-deployment-rke2.yaml`**

- **Replicas:** Changed from `2` → `1`. The upstream sets `replicas: 2` with `podAntiAffinity` requiring deployment across different hosts. With a single RKE2 control-plane node, only 1 replica can schedule — the second pod stays `Pending` forever.
- **podAntiAffinity:** Removed entirely. The upstream uses `preferredDuringSchedulingIgnoredDuringExecution` podAntiAffinity to spread replicas. On a single-node control plane this is unnecessary and causes scheduler confusion. The deployment still tolerates control-plane taints and targets control-plane nodes via `nodeAffinity`.

**`cloudstack-csi-node-daemonset-rke2.yaml`**

- **`/run/cloud-init/` mount removed:** The upstream CSI node DaemonSet mounts `/run/cloud-init/` to read instance metadata. RKE2 nodes do **not** use cloud-init — RKE2 installs itself via tarball at bootstrap — so this directory does not exist. Without removing this mount, the CSI node container crashes with **exit code 2**.

The exact changes are documented as inline YAML comments in both files.

## ClusterResourceSet (default — used by cluster.md)

The ClusterResourceSet at `manifests/21-clusterresourceset.yaml` automatically applies CCM + CSI to any cluster matching the label selector `capc-rke2-ccm-csi: "true"`.

### How it works

1. The `Cluster` manifest (`10-minimal-cluster.yaml`) includes the label `capc-rke2-ccm-csi: "true"` — this is already set; no extra step needed.
2. The ConfigMap (`20-ccm-csi-configmap.yaml`) contains the bundled CCM + CSI YAML.
3. The ClusterResourceSet (`21-clusterresourceset.yaml`) watches for clusters with the matching label and applies the ConfigMap contents to the workload cluster's API server.
4. Once the workload cluster's control plane is reachable, CCM and CSI are installed automatically.

### Apply all three resources together

```bash
kubectl apply -f manifests/10-minimal-cluster.yaml \
  -f manifests/20-ccm-csi-configmap.yaml \
  -f manifests/21-clusterresourceset.yaml
```

### 1. Create the CloudStack secret in the workload cluster

The official manifests expect a secret named `cloudstack-secret` in `kube-system`:

```bash
kubectl create secret generic cloudstack-secret -n kube-system \
  --from-literal=cloud-config="[Global]
api-url = http://<cloudstack-host>:8080/client/api
api-key = <your-api-key>
secret-key = <your-secret-key>
ssl-no-verify = false"
```

### 2. Verify the ClusterResourceSet applied

```bash
kubectl get clusterresourceset -n capc-rke2-cluster-1
# Expected: capc-rke2-cluster-1-ccm-csi   strategy: Reconcile

# Check resources were applied to workload cluster
KUBECONFIG=workload-kubeconfig kubectl get pods -n kube-system
# Expected: cloudstack-ccm-xxx Running, cloudstack-csi-controller-xxx Running, cloudstack-csi-node-xxx Running
```

The ConfigMap contains the **exact upstream YAML** — no modifications to the CCM RBAC or CSI controller. The only change from upstream is the removal of the `/run/cloud-init/` hostPath mount from the CSI node DaemonSet, since RKE2 nodes use RKE2's own bootstrap (not cloud-init) and that directory doesn't exist.

### Troubleshooting CRS

If the ClusterResourceSet doesn't apply, check:

```bash
# Is the label on the cluster?
kubectl get cluster capc-rke2-cluster-1 -n capc-rke2-cluster-1 --show-labels
# Should include: capc-rke2-ccm-csi=true

# Did the CRS controller see the cluster?
kubectl get clusterresourcesetbinding -n capc-rke2-cluster-1
# → resources[0].applied: true when successful
```

> **RKE2-specific change:** The `/run/cloud-init/` hostPath mount was removed from the CSI node DaemonSet because RKE2 nodes use RKE2's own bootstrap (not cloud-init) and that directory doesn't exist. Without this removal, the CSI node container crashes with exit code 2 on RKE2 nodes.

## Troubleshooting

### CSI node container crashes with exit code 2

**Cause:** The upstream CSI node DaemonSet mounts `/run/cloud-init/` which doesn't exist on RKE2 nodes.

**Fix:** Use `cloudstack-csi-node-daemonset-rke2.yaml` instead of the upstream `node-daemonset.yaml`. The RKE2-patched version has the `cloud-init-dir` volumeMount and volume removed.

### CSI controller pod stays Pending

**Cause:** The upstream CSI controller Deployment sets `replicas: 2` with `podAntiAffinity` requiring different hosts. On a single-node control plane, the second replica can never schedule.

**Fix:** Use `cloudstack-csi-controller-deployment-rke2.yaml` instead of the upstream `controller-deployment.yaml`. The RKE2-patched version sets `replicas: 1` and removes `podAntiAffinity`.

### CCM fails with `configmaps "extension-apiserver-authentication" is forbidden`

**Cause:** Hand-rolled CCM manifest missing the `extension-apiserver-authentication-reader` RoleBinding.

**Fix:** The ConfigMap in this repo uses the **exact upstream YAML** which includes both the RoleBinding and the correct ClusterRole — so this error should not occur. If it does, verify the CCM manifest matches the [upstream deployment.yaml](https://github.com/apache/cloudstack-kubernetes-provider/blob/main/deployment.yaml).

## References

- [CloudStack CCM](https://github.com/apache/cloudstack-kubernetes-provider)
- [CloudStack CSI Driver](https://github.com/cloudstack/cloudstack-csi-driver)
- [Cluster API ClusterResourceSet](https://cluster-api.sigs.k8s.io/tasks/experimental-features/cluster-resource-set.html)
