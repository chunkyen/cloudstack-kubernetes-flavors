# CloudStack CSI Driver (Container Storage Interface)

## Overview

The **CloudStack CSI Driver** provides persistent storage integration between Kubernetes and CloudStack. It enables dynamic provisioning, volume snapshots, and lifecycle management of CloudStack disk volumes from Kubernetes PersistentVolumeClaims.

**Canonical Repository:** [cloudstack/cloudstack-csi-driver](https://github.com/cloudstack/cloudstack-csi-driver) — CloudStack org (release artifacts, community-led project)
**Fork:** [shapeblue/cloudstack-csi-driver](https://github.com/shapeblue/cloudstack-csi-driver) — ShapeBlue maintains a fork with additional contributions
**Requires:** Kubernetes 1.25+, CloudStack zone (tested on KVM)

## Background

- Fork lineage: Apalia SAS → Leaseweb → ShapeBlue fork
- Goal: Widen scope to work across hypervisors (KVM, VMware, XenServer/XCP-ng)
- Adds support for domains, projects, CKS, CAPC, and advanced storage operations (volume snapshots)
- Uses the same `cloud-config` format as the CloudStack Kubernetes Provider

## What It Does

The CSI Driver manages CloudStack disk volumes as Kubernetes PersistentVolumes:

1. **Dynamic provisioning** — Creates CloudStack volumes from PVCs
2. **Volume snapshots** — Takes and restores CloudStack volume snapshots
3. **Volume lifecycle** — Attach, mount, detach, delete volumes
4. **Storage classes** — Maps CloudStack disk offerings to Kubernetes StorageClasses

## StorageClass Configuration

| Parameter | Description |
|-----------|-------------|
| `provisioner` | Must be `csi.cloudstack.apache.org` |
| `volumeBindingMode` | Must be `WaitForFirstConsumer` (respects topology constraints) |
| `csi.cloudstack.apache.org/disk-offering-id` | CloudStack disk offering UUID (required) |
| `reclaimPolicy` | `Delete` (default) or `Retain` |

### Reclaim Policy

| Policy | Behavior |
|--------|----------|
| **Delete** | PVC deletion → PV deletion → CloudStack volume deletion |
| **Retain** | PVC deletion → PV retained → CloudStack volume preserved (manual recovery) |

> When a CKS cluster is deleted, PVCs with `reclaimPolicy: Delete` will automatically remove their underlying CloudStack disks.

### Example StorageClass

An example StorageClass (also see [source](https://github.com/cloudstack/cloudstack-csi-driver/blob/main/examples/k8s/0-storageclass.yaml)):

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: cloudstack-csi
provisioner: csi.cloudstack.apache.org
parameters:
  csi.cloudstack.apache.org/disk-offering-id: "<disk-offering-uuid>"
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
```

Replace `<disk-offering-uuid>` with the UUID of a shared disk offering from your CloudStack zone.

> **Important:** The StorageClass must exist before any PVC referencing it is created, otherwise the PVC will fail to bind.

## Volume Snapshots

The driver supports CloudStack volume snapshots via CSI snapshot APIs:

- **CRDs:** VolumeSnapshotClass, VolumeSnapshotContent, VolumeSnapshot (from kubernetes-csi/external-snapshotter v8.3.0)
- **Controller pods:** `cloudstack-csi-controller`, `csi-snapshotter`, `snapshot-controller`
- **Restore flow:** Snapshot → PVC from snapshot → PV bound → Pod scheduled → volume attached and mounted

### KVM Snapshot Requirement

For volume snapshots on KVM zones, set:
```bash
updateGlobalConfiguration name=kvm.snapshot.enabled value=true
# Then restart management server
service cloudstack-management restart
```

## Important Considerations

### Node-Instance Naming

Kubernetes node names must match CloudStack instance names for volume attachment. If using different names:
- Enable cloud-init on nodes
- Mount `/run/cloud-init/` in the CSI node plugin
- Metadata available at `/run/cloud-init/instance-data.json`

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

## Storage Class Syncer

The `cloudstack-csi-sc-syncer` tool synchronizes CloudStack disk offerings to Kubernetes StorageClasses automatically.

**More info:** [cloudstack-csi-sc-syncer README](https://github.com/cloudstack/cloudstack-csi-driver/blob/main/cmd/cloudstack-csi-sc-syncer/README.md)

## Applicability Across Flavors

| Flavor | How it applies |
|--------|---------------|
| **CKS** | **Enable via CKS cluster creation** (Advanced Settings → Enable CloudStack CSI Driver, disabled by default); manual deploy only for pre-existing clusters |
| **CAPC** | Deployed manually on CAPC-managed clusters; requires shared disk offerings in CloudStack |
| **Talos** | Deployed manually; Talos doesn't include CSI by default |
| **Rancher+CAPC** | Deployed via Rancher or manually; Rancher can manage CSI lifecycle |

## Setup

For deployment instructions, see [setup/cloudstack-csi-driver.md](../setup/cloudstack-csi-driver.md).

## Build

```bash
# Build driver binary
make build-cloudstack-csi-driver

# Build container images
make container
```

## References

- [Canonical: cloudstack/cloudstack-csi-driver](https://github.com/cloudstack/cloudstack-csi-driver) (release artifacts)
- [ShapeBlue Fork](https://github.com/shapeblue/cloudstack-csi-driver)
- [CloudStack Storage Documentation](http://docs.cloudstack.apache.org/en/latest/adminguide/storage.html)
- [CSI Specification](https://github.com/container-storage-interface/spec)
- [CloudStack Kubernetes Provider](https://github.com/apache/cloudstack-kubernetes-provider)
