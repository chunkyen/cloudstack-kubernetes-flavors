# CKS Custom ISO Build Guide

## Overview

This guide covers building custom Kubernetes binaries ISOs for CloudStack Kubernetes Service (CKS).

**First check the pre-built ISOs:** [http://download.cloudstack.org/cks/](http://download.cloudstack.org/cks/) — many common versions and configurations are already available.

Build your own only when you need:
- A specific Kubernetes version not in the pre-built set
- A different CNI plugin (Cilium instead of Calico)
- Bundled components (CCM, CSI Driver, Cluster Autoscaler)
- Dedicated etcd binaries
- Architecture-specific builds (ARM64)

> ⚠️ **Security best practice:** Do NOT run these build commands on your CloudStack management server. The build process installs extra packages, downloads binaries/images from the internet, and runs container operations — all unnecessary attack surface on a production mgmt node.
>
> **Recommended approach:** Build on an isolated worker/build machine (Ubuntu 22.04+), then register the ISO directly via `cmk` or the CloudStack UI.

## Recommended: Isolated Build Machine

Set up a clean Ubuntu 22.04+ VM or container:

```bash
sudo apt install -y wget curl genisoimage containerd.io
```

For Cilium builds (Option B), also install Helm:
```bash
sudo apt install -y helm
```

### Getting the Build Scripts

**Option A (Official Calico):** The script ships with `cloudstack-common` as a convenience, but it has no CloudStack dependencies — just standard Linux tools.

Copy from your management server:
```bash
scp root@<mgmt-server>:/usr/share/cloudstack-common/scripts/util/create-kubernetes-binaries-iso.sh ./
chmod +x create-kubernetes-binaries-iso.sh
```

Alternatively, an archived copy is available in this repo at [`setup/cks/scripts/create-kubernetes-binaries-iso.sh`](setup/cks/scripts/create-kubernetes-binaries-iso.sh), or grab the latest from the [CloudStack source](https://github.com/apache/cloudstack/blob/main/scripts/util/create-kubernetes-binaries-iso.sh).

**Option B (Community Cilium):** Already archived in this repo — see below.

### Uploading the ISO (after build)

CKS has a dedicated upload flow — no need to host the ISO on a public URL first.

**Step 1: Get an upload URL from CloudStack:**
```bash
cmk -p <profile> get uploadparamsfor kubernetessupportedversion \
  name=kubernetes-binaries-v1.33.1-calico \
  semanticversion=1.33.1 \
  format=ISO \
  zoneid=<zone-uuid> \
  mincpunumber=2 \
  minmemory=4096
```

This returns a `postURL` (and other metadata) for uploading the ISO.

**Step 2: Upload the ISO directly:**
```bash
curl -X POST \
  -F "file=@/path/to/kubernetes-binaries.iso" \
  <postURL-from-step-1>
```

CloudStack will process and make it available for CKS cluster creation.

**Via CloudStack UI:** Navigate to **Images → Kubernetes ISOs**. The **Add Kubernetes Version** form lets you specify a remote URL for download. For direct local upload, click the **upload icon** (📤) beside it.

### Example: Kubernetes 1.33.1 with Calico

All commands run on your isolated build machine:

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

sudo ./create-kubernetes-binaries-iso.sh \
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

For a Cilium-based ISO that also bundles CCM, CSI, and Cluster Autoscaler.

**Source:** [nulcell/homecloud](https://github.com/nulcell/homecloud/blob/3f5a40a3332084a4ff7bd5ae13fc3c70dce28d96/cloudstack/compute/cks/create-cilium-kubernetes-binaries-iso.sh)

**Archived in this repo:** [`create-cilium-kubernetes-binaries-iso.sh`](setup/cks/scripts/create-cilium-kubernetes-binaries-iso.sh)

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
