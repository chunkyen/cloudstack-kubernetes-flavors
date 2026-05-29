# CloudStack CSI Driver (Container Storage Interface)

## Overview

The **CloudStack CSI Driver** provides persistent storage integration between Kubernetes and CloudStack. It enables dynamic provisioning, volume snapshots, and lifecycle management of CloudStack disk volumes from Kubernetes PersistentVolumeClaims.

**Repository:** [shapeblue/cloudstack-csi-driver](https://github.com/shapeblue/cloudstack-csi-driver) (fork of [cloudstack/cloudstack-csi-driver](https://github.com/cloudstack/cloudstack-csi-driver))
**Based on:** Original by Apalia SAS → forked by Leaseweb → ShapeBlue maintains
**Requires:** Kubernetes 1.25+, CloudStack zone (tested on KVM)

## Background

- Fork lineage: Apalia → Leaseweb → ShapeBlue
- Goal: Widen scope to work across hypervisors (KVM, VMware, XenServer/XCP-ng)
- Adds support for domains, projects, CKS, CAPC, and advanced storage operations (volume snapshots)
- Uses the same `cloud-config` format as the CloudStack Kubernetes Provider

## What It Does

The CSI Driver manages CloudStack disk volumes as Kubernetes PersistentVolumes:

1. **Dynamic provisioning** — Creates CloudStack volumes from PVCs
2. **Volume snapshots** — Takes and restores CloudStack volume snapshots
3. **Volume lifecycle** — Attach, mount, detach, delete volumes
4. **Storage classes** — Maps CloudStack disk offerings to Kubernetes StorageClasses

## Prerequisites

- **Kubernetes 1.25+** running in CloudStack
- **Disk offering** with type `shared` and custom size available
- **CloudStack account** credentials (same account that created the nodes)
- **Node naming** — Kubernetes node names must match CloudStack instance names (or use cloud-init metadata)
- **Root domain** — Kubernetes nodes must be in the Root domain
- **KVM snapshots** (optional) — Set `kvm.snapshot.enabled=true` global setting

## Deployment

### 1. Create cloud-config

```ini
[Global]
api-url = <CloudStack API URL>
api-key = <CloudStack API Key>
secret-key = <CloudStack API Secret>
ssl-no-verify = <true or false (optional)>
```

> Reuse the same secret as the CloudStack Kubernetes Provider if deployed.

### 2. Create Kubernetes Secret

```bash
kubectl create secret generic cloudstack-secret \
  --namespace kube-system \
  --from-file ./cloud-config \
  cloudstack-secret
```

### 3. Install VolumeSnapshot CRDs (optional)

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.3.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.3.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.3.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml
```

### 4. Deploy the CSI Driver

```bash
kubectl apply -f https://github.com/cloudstack/cloudstack-csi-driver/releases/latest/download/manifest.yaml
```

### 5. Create StorageClass

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: cloudstack-ssd
provisioner: csi.cloudstack.apache.org
parameters:
  csi.cloudstack.apache.org/disk-offering-id: <cloudstack-disk-offering-uuid>
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete  # or Retain
```

> **Important:** `volumeBindingMode: WaitForFirstConsumer` is required to respect topology constraints (volume in the right zone).

## StorageClass Parameters

| Parameter | Description |
|-----------|-------------|
| `csi.cloudstack.apache.org/disk-offering-id` | CloudStack disk offering UUID (required) |
| `volumeBindingMode` | Must be `WaitForFirstConsumer` |
| `reclaimPolicy` | `Delete` (default) or `Retain` |

### Reclaim Policy

| Policy | Behavior |
|--------|----------|
| **Delete** | PVC deletion → PV deletion → CloudStack volume deletion |
| **Retain** | PVC deletion → PV retained → CloudStack volume preserved (manual recovery) |

> When a CKS cluster is deleted, PVCs with `reclaimPolicy: Delete` will automatically remove their underlying CloudStack disks.

## Volume Snapshots

### Create Snapshot

```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: snapshot-1
spec:
  volumeSnapshotClassName: cloudstack-snapshot-class
  source:
    persistentVolumeClaimName: my-pvc
```

### Restore from Snapshot

```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotContent
# ... (auto-created from snapshot)

# Create PVC from snapshot
kubectl apply -f examples/k8s/snapshot/pvc-from-snapshot.yaml

# Create pod using restored PVC
kubectl apply -f examples/k8s/snapshot/restore-pod.yaml
```

### Delete Snapshot

```bash
kubectl delete volumesnapshot snapshot-1
```

**Troubleshooting stuck snapshots:**
```bash
# Check for finalizers
kubectl get volumesnapshot <snapshot-name> -o yaml

# Patch to remove finalizers (bypasses cleanup — use with caution)
kubectl patch volumesnapshot <snapshot-name> --type=merge \
  -p '{"metadata":{"finalizers":[]}}'
```

### Debugging Snapshot Operations

```bash
# Controller logs
kubectl logs -f <cloudstack-csi-controller-pod> -n kube-system -c csi-snapshotter
kubectl logs -f <cloudstack-csi-controller-pod> -n kube-system -c snapshot-controller

# Restore logs
kubectl logs -f <cloudstack-csi-controller-pod> -n kube-system -c external-provisioner
```

## Storage Class Syncer

The `cloudstack-csi-sc-syncer` tool synchronizes CloudStack disk offerings to Kubernetes StorageClasses automatically.

**More info:** [cloudstack-csi-sc-syncer README](https://github.com/cloudstack/cloudstack-csi-driver/blob/main/cmd/cloudstack-csi-sc-syncer/README.md)

## Build & Container Images

```bash
# Build driver binary
make build-cloudstack-csi-driver

# Build container images
make container
```

## Important Considerations

### Node Scheduling

**Use `nodeSelector` or `nodeAffinity`** instead of `nodeName`:
- `nodeName` bypasses the Kubernetes scheduler
- With `volumeBindingMode: WaitForFirstConsumer`, the CSI controller relies on scheduler decisions
- Using `nodeName` can cause PVC binding failures

### Network CIDR

**Avoid `10.0.0.0/16`** when deploying CKS clusters on pre-existing networks:
- Conflicts with Calico's default pod network configuration
- Can prevent CSI driver initialization
- May cause networking issues within the cluster

### Node-Instance Naming

Kubernetes node names must match CloudStack instance names for volume attachment. If using different names:
- Enable cloud-init on nodes
- Ensure `/run/cloud-init/` is mounted in the CSI node plugin
- Metadata available at `/run/cloud-init/instance-data.json`

## Applicability Across Flavors

| Flavor | How it applies |
|--------|---------------|
| **CKS** | Deployed manually or via CKS cluster creation; same cloud-config as CCM |
| **CAPC** | Deployed manually on CAPC-managed clusters; requires shared disk offerings in CloudStack |
| **Talos** | Deployed manually; Talos doesn't include CSI by default |
| **Rancher+CAPC** | Deployed via Rancher or manually; Rancher can manage CSI lifecycle |

## References

- [ShapeBlue CSI Driver](https://github.com/shapeblue/cloudstack-csi-driver)
- [CloudStack CSI Driver (main)](https://github.com/cloudstack/cloudstack-csi-driver)
- [CloudStack Storage Documentation](http://docs.cloudstack.apache.org/en/latest/adminguide/storage.html)
- [CSI Specification](https://github.com/container-storage-interface/spec)
- [CloudStack Kubernetes Provider](https://github.com/apache/cloudstack-kubernetes-provider)
