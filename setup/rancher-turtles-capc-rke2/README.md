# Rancher Turtles + CAPC + RKE2

This directory contains everything needed to deploy **RKE2 clusters on CloudStack** using Cluster API with Rancher Turtles.

| Document | What it covers |
|---|---|
| [cluster.md](./cluster.md) | RKE2 cluster provisioning on CloudStack (prerequisites, providers, cluster YAML, verification, cleanup) |
| [ccm-csi.md](./ccm-csi.md) | Deploy CloudStack CCM and CSI on the RKE2 workload cluster — standalone manifests or ClusterResourceSet |

## Manifests

All YAML files are in [`manifests/`](./manifests/):

| File | Description |
|---|---|
| `rke2-providers.yaml` | CAPIProvider CRDs for RKE2 bootstrap + control-plane |
| `10-minimal-cluster.yaml` | Complete cluster manifest (Cluster, CloudStackCluster, RKE2ControlPlane, MachineDeployment, etc.) |
| `20-ccm-csi-configmap.yaml` | ConfigMap with upstream CCM + CSI YAML for ClusterResourceSet deployment |
| `21-clusterresourceset.yaml` | ClusterResourceSet to auto-deploy CCM + CSI |
| `cloudstack-ccm.yaml` | Exact upstream CCM manifest |
| `cloudstack-csi-rbac.yaml` | Exact upstream CSI RBAC |
| `cloudstack-csi-snapshot-crds.yaml` | Exact upstream VolumeSnapshot CRDs |
| `cloudstack-csi-volume-snapshot-class.yaml` | Exact upstream VolumeSnapshotClass |
| `cloudstack-csi-driver.yaml` | Exact upstream CSIDriver |
| `cloudstack-csi-controller-deployment-rke2.yaml` | **RKE2-patched** CSI controller (replicas: 1, podAntiAffinity removed) |
| `cloudstack-csi-node-daemonset-rke2.yaml` | **RKE2-patched** CSI node DaemonSet (`/run/cloud-init/` mount removed) |
