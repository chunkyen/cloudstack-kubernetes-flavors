# CKS Custom ISO Build Guide

## Overview

This guide covers building custom Kubernetes binaries ISOs for CloudStack Kubernetes Service (CKS). Use this when you need:
- A specific Kubernetes version not available in pre-built ISOs
- A different CNI plugin (Cilium instead of Calico)
- Bundled components (CCM, CSI Driver, Cluster Autoscaler)
- Dedicated etcd binaries
- Architecture-specific builds (ARM64)

> **Run all build commands on the CloudStack management server.**

## Option A: Build Calico ISO (Official Script)

### Prerequisites
```bash
sudo apt install -y wget curl genisoimage containerd.io
```

### Script Location

The script is provided by the `cloudstack-common` package:
```bash
# Official location (may vary by distribution)
/usr/share/cloudstack-common/scripts/util/create-kubernetes-binaries-iso.sh
# Alternative location:
/usr/share/cloudstack-common/scripts/cks/create-kubernetes-binaries-iso.sh
```

### Example: Kubernetes 1.33.1 with Calico

```bash
OUTPUT_PATH=/tmp/
KUBERNETES_VERSION="1.33.1"
CNI_VERSION="1.7.1"
CRICTL_VERSION="1.33.0"
CALICO_NETWORK_YAML="https://raw.githubusercontent.com/projectcalico/calico/v3.30.0/manifests/calico.yaml"
DASHBOARD_YAML="https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml"
BUILD_NAME="v${KUBERNETES_VERSION}-cks-calico"
ARCH="amd64"
ETCD_VERSION="3.5.0"

sudo /usr/share/cloudstack-common/scripts/util/create-kubernetes-binaries-iso.sh \
  $OUTPUT_PATH \
  $KUBERNETES_VERSION \
  $CNI_VERSION \
  $CRICTL_VERSION \
  $CALICO_NETWORK_YAML \
  $DASHBOARD_YAML \
  $BUILD_NAME \
  $ARCH \
  $ETCD_VERSION
```

### Parameters

| Parameter | Description |
|-----------|-------------|
| `OUTPUT_PATH` | Directory to write the ISO |
| `KUBERNETES_VERSION` | Kubernetes version (e.g., `1.33.1`) |
| `CNI_VERSION` | CNI plugins version (e.g., `1.7.1`) |
| `CRICTL_VERSION` | cri-tools version (e.g., `1.33.0`) |
| `CALICO_NETWORK_YAML` | Raw URL to Calico manifest YAML |
| `DASHBOARD_YAML` | Raw URL to Kubernetes Dashboard manifest YAML |
| `BUILD_NAME` | Output filename prefix |
| `ARCH` | Architecture: `amd64`, `arm64`, or `aarch64` |
| `ETCD_VERSION` | (Optional) etcd version for dedicated etcd nodes |

### For ARM64

```bash
ARCH="arm64"  # or aarch64
# ... same command with ARCH=arm64
```

### For Dedicated Etcd Nodes

Add the `ETCD_VERSION` parameter (9th positional arg):
```bash
# ... previous params ...
$BUILD_NAME \
$ARCH \
3.5.0  # <-- etcd version
```

> **Note:** Dedicated etcd nodes require an ISO built with etcd binaries. Available pre-built ISOs: `https://download.cloudstack.org/testing/cks/custom_templates/iso-etcd/`

## Option B: Build Cilium ISO (Community Script)

### Prerequisites
```bash
sudo apt install -y wget curl genisoimage containerd.io helm
```

For a Cilium-based ISO that also bundles CCM, CSI, and Cluster Autoscaler.

**Source:** [nulcell/homecloud](https://github.com/nulcell/homecloud/blob/3f5a40a3332084a4ff7bd5ae13fc3c70dce28d96/cloudstack/compute/cks/create-cilium-kubernetes-binaries-iso.sh)

**Archived in this repo:** `setup/cks/scripts/create-cilium-kubernetes-binaries-iso.sh`

### Example Build

```bash
OUTPUT_PATH=/tmp/
KUBERNETES_VERSION="1.33.1"
CNI_VERSION="1.8.0"
CRICTL_VERSION="1.33.0"
CILIUM_VERSION="1.18.2"
DASHBOARD_YAML="https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml"
BUILD_NAME="v${KUBERNETES_VERSION}-cks-cilium"
ARCH="amd64"
ETCD_VERSION="3.5.0"

# Using the archived script in this repo:
./setup/cks/scripts/create-cilium-kubernetes-binaries-iso.sh \
  $OUTPUT_PATH \
  $KUBERNETES_VERSION \
  $CNI_VERSION \
  $CRICTL_VERSION \
  $CILIUM_VERSION \
  $DASHBOARD_YAML \
  $BUILD_NAME \
  $ARCH \
  $ETCD_VERSION
```

### Cilium ISO vs Official Calico ISO

| Component | Official (Calico) | Community (Cilium) |
|-----------|-------------------|-------------------|
| **CNI** | Calico (raw YAML) | Cilium + Hubble (relay + UI) via Helm |
| **CCM** | Manual deploy | Auto-bundled |
| **CSI Driver** | Manual deploy | Auto-bundled (v3.0.0) |
| **Cluster Autoscaler** | Not included | Auto-bundled (CloudStack provider) |
| **Kubernetes Dashboard** | Included | Included |
| **ImagePullPolicy** | Default | Set to `IfNotPresent` |
| **Pre-pulled images** | No (via ISO) | Yes (containerd) |
| **Dedicated etcd** | Optional (9th param) | Optional (9th param) |

### Key Cilium Features

- Uses `helm template` to generate Cilium manifests with `kubeProxyReplacement=true` (eBPF-based)
- Hubble observability (relay + UI) enabled by default
- Pre-pulls all container images into containerd at build time and exports them to the ISO
- Sets `imagePullPolicy: IfNotPresent` across all YAML files
- Uses shapeblue's `kubelet.service` and `10-kubeadm.conf` for newer K8s versions
- Includes Cluster Autoscaler manifest for CloudStack

### Post-Deployment: Helm Management

After the cluster is up, switch Cilium to Helm-managed mode:

```bash
CILIUM_VERSION="1.18.2"
helm repo add cilium https://helm.cilium.io/
helm upgrade --install cilium cilium/cilium --version ${CILIUM_VERSION} \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  --take-ownership
```

## Register the ISO as a Supported K8s Version

### Via CloudStack UI

1. **Infrastructure** → **Kubernetes** → **Supported Versions**
2. Click **Add Kubernetes Supported Version**
3. Fill in:
   - **Name:** `v1.33.1`
   - **Semantic Version:** `1.33.1`
   - **Zone:** Select your zone
   - **URL:** Path to the ISO (HTTP/HTTPS accessible by management server)
   - **Checksum:** MD5/SHA of the ISO
   - **Min CPU:** `2`
   - **Min Memory:** `2048` MB

### Via API

```bash
addKubernetesSupportedVersion \
  name=v1.33.1 \
  semanticversion=1.33.1 \
  url=http://<server>/setup-v1.33.1.iso \
  zoneid=<zone-id> \
  mincpunumber=2 \
  minmemory=2048 \
  checksum=<iso-checksum>
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `ctr not found` error | Ensure `containerd` is installed on the build server |
| Helm errors | Ensure Helm sources are configured properly (`sudo apt install -y helm`) |
| ISO build fails | Check internet connectivity; script needs to download K8s binaries and images |
| ARM64 ISO fails | Ensure `ARCH` is set to `arm64` or `aarch64` |
| etcd nodes not working | Ensure ISO was built with etcd binaries (use `ETCD_VERSION` parameter) |

## References

- [Official CKS Documentation](http://docs.cloudstack.apache.org/en/latest/plugins/cloudstack-kubernetes-service.html)
- [CKS Binaries ISOs](http://download.cloudstack.org/cks/)
- [Community Cilium ISO Script](https://github.com/nulcell/homecloud/blob/3f5a40a3332084a4ff7bd5ae13fc3c70dce28d96/cloudstack/compute/cks/create-cilium-kubernetes-binaries-iso.sh)
- [Cilium Documentation](https://docs.cilium.io/)
