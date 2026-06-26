# CloudStack CSI Driver — Setup Guide

## Prerequisites

- Kubernetes 1.25+ running in CloudStack
- At least one **shared** disk offering with custom size available
- CloudStack account credentials (same account that created the nodes)
- Kubernetes nodes in the **Root domain**, created by the CloudStack account whose credentials are used
- Node names match CloudStack instance names (or cloud-init enabled with metadata mounted)
- **KVM zones:** `kvm.snapshot.enabled=true` (for volume snapshots)

## Step 1: Create cloud-config

```ini
[Global]
api-url = <CloudStack API URL>
api-key = <CloudStack API Key>
secret-key = <CloudStack API Secret>
ssl-no-verify = <true or false (optional)>
```

> If you also deployed the CloudStack Kubernetes Provider (CCM), you can reuse the same secret for both.

## Step 2: Create Kubernetes Secret

```bash
kubectl create secret generic cloudstack-secret \
  --namespace kube-system \
  --from-file ./cloud-config \
  cloudstack-secret
```

## Step 3: Install VolumeSnapshot CRDs (optional)

Required for volume snapshot support:

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.3.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.3.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.3.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml
```

## Step 4: Deploy the CSI Driver

```bash
kubectl apply -f https://github.com/cloudstack/cloudstack-csi-driver/releases/latest/download/manifest.yaml
```

Verify deployment:
```bash
kubectl get pods -n kube-system -l app=cloudstack-csi
kubectl logs -f -n kube-system <csi-controller-pod>
```

## Step 5: Create StorageClass

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

> **Critical:** `volumeBindingMode` must be `WaitForFirstConsumer` to respect topology constraints (volume in the right zone).

## Step 6: Create Volume SnapshotClass (optional)

```yaml
kubectl apply -f https://raw.githubusercontent.com/cloudstack/cloudstack-csi-driver/main/deploy/k8s/volume-snapshot-class.yaml
```

## Step 7: Test with PVC and Pod

### Create PVC

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes:
  - ReadWriteOnce
  storageClassName: cloudstack-ssd
  resources:
    requests:
      storage: 10Gi
```

```bash
kubectl apply -f pvc.yaml
kubectl get pvc test-pvc
```

### Create Pod Using PVC

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
spec:
  containers:
  - name: test
    image: nginx
    volumeMounts:
    - name: storage
      mountPath: /data
  volumes:
  - name: storage
    persistentVolumeClaim:
      claimName: test-pvc
```

```bash
kubectl apply -f pod.yaml
kubectl exec test-pod -- df -h /data
```

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
    persistentVolumeClaimName: test-pvc
```

```bash
kubectl apply -f snapshot.yaml
kubectl get volumesnapshot
```

### Restore from Snapshot

```bash
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

## Debugging

### Controller Logs
```bash
kubectl logs -f <cloudstack-csi-controller-pod> -n kube-system
cubectl logs -f <cloudstack-csi-controller-pod> -n kube-system -c csi-snapshotter
cubectl logs -f <cloudstack-csi-controller-pod> -n kube-system -c snapshot-controller
cubectl logs -f <cloudstack-csi-controller-pod> -n kube-system -c external-provisioner
```

### Check Volume Attachment
```bash
kubectl get pv
kubectl describe pv <pv-name>
```

### Check CloudStack Volumes
```bash
# In CloudStack UI: Storage → Volumes
# Or via API:
listVolumes id=<volume-id> zoneid=<zone-id>
```

## Storage Class Syncer

The `cloudstack-csi-sc-syncer` tool syncs CloudStack disk offerings to Kubernetes StorageClasses automatically.

```bash
# Build and run
make build-cloudstack-csi-sc-syncer
./cloudstack-csi-sc-syncer --cloud-config ./cloud-config
```

More info: [cloudstack-csi-sc-syncer README](https://github.com/cloudstack/cloudstack-csi-driver/blob/main/cmd/cloudstack-csi-sc-syncer/README.md)

## Build & Container Images

```bash
# Build driver binary
make build-cloudstack-csi-driver

# Build container images
make container
```

## CKS vs CAPC/CAPM Image Compatibility

The CloudStack CSI driver's node DaemonSet references a `hostPath` volume at `/var/mnt/local-storage` with `type: Directory`. This works on **CKS custom ISO images** because the ISO includes a pre-partitioned disk layout where this path exists by default.

**CAPC and other CAPI provider machine images** (standard Ubuntu/Debian templates) do **not** have `/var/mnt/local-storage` — they're bare OS images with no custom partitioning. Changing `type: Directory` to `type: DirectoryOrCreate` is not enough because the parent directory doesn't exist at all on these images.

### Fix for CAPC/CAPM Images

Patch the CSI node DaemonSet to use `/var/lib/kubelet` instead:

```bash
# Find the CSI node DaemonSet
kubectl get daemonset -A | grep cloudstack

# Edit it (or apply a patch)
kubectl edit daemonset <csi-node-ds-name> -n kube-system
```

Change the `cloud-init-dir` volume definition:

```yaml
# Before (CKS-specific, fails on CAPC images):
- name: cloud-init-dir
  hostPath:
    path: /var/mnt/local-storage
    type: Directory

# After (works on all images):
- name: cloud-init-dir
  hostPath:
    path: /var/lib/kubelet
    type: DirectoryOrCreate
```

> **Note:** This is a known limitation of the CloudStack CSI driver when deployed on non-CKS machine images. Consider filing an upstream issue to make the default path configurable or use `DirectoryOrCreate` with a path that exists on all standard Kubernetes node images.

## References

- [Canonical: cloudstack/cloudstack-csi-driver](https://github.com/cloudstack/cloudstack-csi-driver)
- [ShapeBlue Fork](https://github.com/shapeblue/cloudstack-csi-driver)
- [CloudStack Storage Documentation](http://docs.cloudstack.apache.org/en/latest/adminguide/storage.html)
- [CSI Specification](https://github.com/container-storage-interface/spec)
- [CloudStack Kubernetes Provider](https://github.com/apache/cloudstack-kubernetes-provider)
