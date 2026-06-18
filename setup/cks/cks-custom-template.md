# CKS Custom Template Build Guide

## Overview

From CloudStack 4.21+, you can register custom VM templates for CKS cluster nodes instead of relying on the default SystemVM template. This lets you:

- Use a modern Linux distro (Ubuntu 24.04, Rocky 9, etc.)
- Pre-install tools (helm, monitoring agents, custom runtimes)
- Tune kernel parameters and sysctl settings
- Add GPU drivers, NVMe tools, or other workload-specific packages
- Assign different templates per node type (control, worker, etcd)

> **Note:** The template is the **base OS image**. Kubernetes binaries still come from the ISO registered as a supported K8s version. The template only provides the OS foundation — CKS mounts the binaries ISO at boot to install kubeadm, kubelet, CNI, etc.

## Prerequisites Checklist

Your template **must** have these installed and configured:

| Requirement | Why | Details |
|-------------|-----|---------|
| **cloud-init** | Receives hostname, SSH keys, CKS user-data from CloudStack metadata service | Must support `DataSourceCloudStack` |
| **cloud user** | CKS cloud-init scripts run as `cloud` user; SSH access uses `cloud` | `adduser cloud --disabled-password --gecos ""` |
| **containerd** | Container runtime for Kubernetes pods | v1.7+ recommended |
| **kubelet** | Node agent — must match or be newer than target K8s version | Installed by template OR pulled from ISO |
| **kubeadm** | Bootstrap tool used by CKS to init/join cluster | Installed by template OR pulled from ISO |
| **kubectl** | CLI tool used by CKS management scripts | Installed by template OR pulled from ISO |
| **qemu-guest-agent** | Required for ISO mount/detach on KVM hypervisors | `qemu-guest-agent` package; service must be enabled |
| **conntrack** | Required for kube-proxy and CNI | `conntrack` package |
| **ipset** | Required for Calico/CNI | `ipset` package |
| **Kernel modules** | `br_netfilter`, `overlay` | Must be loadable at boot |
| **Network setup** | DHCP client for primary interface | cloud-init handles this if configured correctly |

> **Important:** kubelet, kubeadm, and kubectl can be pre-installed in the template OR installed from the binaries ISO at boot. Pre-installing them speeds up boot and reduces ISO size. If pre-installed, versions must be compatible with the K8s version in the ISO.

## Step-by-Step: Ubuntu 24.04 CKS Template

### Step 1: Prepare a Build Environment

Use a KVM host or any machine with `virt-install` and `virt-customize` available:

```bash
sudo apt install -y libvirt-daemon-system libvirt-clients \
  virtinst libguestfs-tools genisoimage qemu-utils
```

### Step 2: Download Ubuntu 24.04 Cloud Image

```bash
# Download the official cloud image (server edition)
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

# Verify checksum
wget https://cloud-images.ubuntu.com/noble/current/SHA256SUMS
sha256sum -c SHA256SUMS 2>/dev/null | grep noble-server-cloudimg-amd64.img
```

### Step 3: Customize the Image

Use `virt-customize` to install required packages and configure the template:

```bash
virt-customize --verbose -a noble-server-cloudimg-amd64.img \
  --run 'dnf update -y' \
  --install containerd.io \
  --install conntrack \
  --install ipset \
  --install ipvsadm \
  --install qemu-guest-agent \
  --install kmod \
  --install curl \
  --install jq \
  --install git \
  --install nfs-common \
  --install socat \
  --install rsync \
  --install apt-transport-https \
  --install gnupg
```

> **Note:** `virt-customize` uses `dnf` internally via libguestfs. For Ubuntu images, use `--run` with `apt` commands instead:

```bash
virt-customize --verbose -a noble-server-cloudimg-amd64.img \
  --run 'apt-get update && apt-get upgrade -y' \
  --run 'apt-get install -y containerd.io conntrack ipset ipvsadm qemu-guest-agent kmod curl jq git nfs-common socat rsync apt-transport-https gnupg'
```

If `containerd.io` is not in the default Ubuntu repos, add the Docker repo first:

```bash
virt-customize --verbose -a noble-server-cloudimg-amd64.img \
  --run 'apt-get update && apt-get install -y apt-transport-https ca-certificates curl gnupg'
  --run 'curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg'
  --run 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_ID) stable" > /etc/apt/sources.list.d/docker.list'
  --run 'apt-get update && apt-get install -y containerd.io'
```

### Step 3b: Alternative — Build Inside a VM (More Control)

For complex customization, boot the image as a VM and configure it manually:

```bash
# Create the VM
virt-install \
  --name ubuntu24-cks-template \
  --memory 4096 \
  --vcpus 2 \
  --disk noble-server-cloudimg-amd64.img,bus=virtio,format=qcow2 \
  --network network=default,model=virtio \
  --import \
  --noautoconsole

# SSH in (cloud-init will set up the 'cloud' user with default credentials)
# For Ubuntu cloud images, use cloud-image-login or check serial console
sudo cloud-image-login noble-server-cloudimg-amd64.img
# Or: sudo virsh console ubuntu24-cks-template
```

Inside the VM:

```bash
# 1. Update and install packages
apt-get update
apt-get install -y containerd.io conntrack ipset ipvsadm \
  qemu-guest-agent kmod curl jq git nfs-common socat rsync

# 2. Enable and start containerd
systemctl enable containerd
systemctl start containerd

# 3. Configure containerd
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml

# Set systemd as the cgroup driver (required for kubelet)
sed -i 's|SystemdCgroup = false|SystemdCgroup = true|' /etc/containerd/config.toml

# 4. Enable and start qemu-guest-agent
systemctl enable qemu-guest-agent
systemctl start qemu-guest-agent

# 5. Load required kernel modules
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

# 6. Configure sysctl for Kubernetes
cat > /etc/sysctl.d/99-kubernetes.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system

# 7. Ensure 'cloud' user exists with sudo (Ubuntu cloud images have this by default)
id cloud

# 8. (Optional) Pre-install kubelet, kubeadm, kubectl
# Add Kubernetes apt repo
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable kubelet

# 9. Clean up
apt-get clean
rm -rf /tmp/* /var/log/cloud-init.log /var/log/cloud-init-output.log
truncate -s 0 /var/log/auth.log

# 10. Remove machine-id (so each clone gets a fresh one)
rm -f /etc/machine-id
```

### Step 4: Convert to CloudStack Format

For KVM hypervisors, CloudStack expects QCOW2 format (optionally compressed):

```bash
# If you built inside a VM, shut it down first
virsh shutdown ubuntu24-cks-template

# Convert to qcow2 if needed (cloud images are already qcow2)
qemu-img convert -f qcow2 -O qcow2 noble-server-cloudimg-amd64.img cks-ubuntu-2404-kvm.qcow2

# Compress with bzip2 (CloudStack supports bz2 on-the-fly decompression)
bzip2 -9 cks-ubuntu-2404-kvm.qcow2
```

For VMware: convert to OVA or vmdk. For Hyper-V: convert to VHD.

### Step 5: Upload and Register in CloudStack

#### Option A: Upload via CloudStack UI

1. Go to **Compute** → **Templates** → **Register Template**
2. Fill in:
   - **Name:** `Ubuntu 24.04 CKS Template`
   - **URL:** (upload the file directly, or host it on an HTTP server)
   - **Zone:** Select your zone
   - **Format:** QCOW2
   - **Hypervisor:** KVM (or your hypervisor)
   - **OS Type:** Ubuntu Linux (64-bit)
3. **✅ Check "For CKS"** — this is critical; without it, the template won't appear in CKS cluster creation
4. Set **Is Public** = true (so all accounts can use it)
5. Set **Is Extractable** = true
6. Click **Register**

#### Option B: Register via cmk

```bash
# First, upload the file to a web-accessible location or use the upload API
# Then register:
cmk register template \
  name="Ubuntu 24.04 CKS Template" \
  url=http://<your-server>/cks-ubuntu-2404-kvm.qcow2.bz2 \
  zoneid=<zone-id> \
  format=QCOW2 \
  hypervisortype=KVM \
  ostypeid=<os-type-id> \
  ispublic=true \
  isextractable=true \
  isfeatured=true \
  forcks=true

# Find OS type ID:
cmk list ostypes filter=name,id | grep -i ubuntu
```

> **The `forcks=true` flag is mandatory.** Without it, CloudStack won't list this template as available for CKS clusters.

### Step 6: Verify Template Registration

```bash
# List CKS-compatible templates
cmk list templates filter=name,id,forcks,isonetwork | grep -i ubuntu

# Should show:
# {"id": "...", "name": "Ubuntu 24.04 CKS Template", "forcks": true, ...}
```

### Step 7: Use the Template in CKS Cluster Creation

#### Via UI

1. **Compute** → **Kubernetes** → **Add Kubernetes Cluster**
2. Fill in basic fields (name, zone, network, K8s version, node counts)
3. **Toggle "Advanced Settings"**
4. Under **Worker Node Template**, select `Ubuntu 24.04 CKS Template`
5. (Optional) Select the same or different templates for control nodes and etcd nodes
6. Click **Create**

#### Via cmk

```bash
# Get template ID
TEMPLATE_ID=$(cmk list templates nameFilter="Ubuntu 24.04 CKS Template" filter=id | grep '"id"' | head -1 | grep -oP '(?<="id":"')[^"]+')

# Create cluster with custom template
cmk create kubernetescluster \
  name=my-cks-cluster \
  zoneid=<zone-id> \
  kubernetesversionid=<version-id> \
  serviceofferingid=<offering-id> \
  controlnodes=1 \
  size=2 \
  nodetemplates="{worker:$TEMPLATE_ID,control:$TEMPLATE_ID}"
```

## Pre-built CKS Templates

CloudStack provides pre-built CKS templates for Ubuntu 22.04:

| Hypervisor | File | Location |
|------------|------|----------|
| KVM (QCOW2) | `cks-ubuntu-2204-kvm.qcow2.bz2` | http://download.cloudstack.org/testing/custom_templates/ubuntu/22.04/ |
| VMware (OVA) | `cks-ubuntu-2204-vmware.ova` | Same |
| Hyper-V (VHD) | `cks-ubuntu-2204-hyperv.vhd.zip` | Same |
| OVM (RAW) | `cks-ubuntu-2204-ovm.raw.bz2` | Same |

These include: containerd, cloud-init, qemu-guest-agent, conntrack, ipset, and the `cloud` user.

> **Ubuntu 24.04 pre-built templates** are not yet available in the official downloads. The guide above covers building your own.

## Template Requirements Reference

### Minimum Hardware

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| Root disk | 8 GB | 16+ GB |
| CPU | 2 vCPU | 4+ vCPU (control nodes) |
| RAM | 2 GB | 4+ GB (control), 8+ GB (workers) |

### Required Packages (Ubuntu 24.04)

```bash
# Core
cloud-init          # CloudStack integration, user-data processing
qemu-guest-agent    # KVM: ISO mount/detach, VM communication
containerd.io       # Container runtime (v1.7+)

# Kubernetes dependencies
conntrack           # kube-proxy, CNI
ipset               # Calico/CNI
ipvsadm             # kube-proxy IPVS mode
kmod                # Kernel module loading
socat               # kubelet, kubeadm

# Optional but recommended
curl jq git         # General utilities
nfs-common          # NFS volumes
rsync               # File sync
```

### Required Kernel Modules

```bash
# /etc/modules-load.d/k8s.conf
overlay
br_netfilter
```

### Required sysctl Settings

```bash
# /etc/sysctl.d/99-kubernetes.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
```

### Required Services (enabled at boot)

```bash
systemctl enable containerd
systemctl enable qemu-guest-agent
systemctl enable kubelet    # if pre-installed
```

## cloud-init Configuration

CKS relies on cloud-init to:
1. Receive hostname and SSH keys from CloudStack metadata service
2. Process user-data (CNI configuration, custom scripts)
3. Wait for the binaries ISO to mount at `/mnt/k8sdisk/`
4. Install kubelet and run `kubeadm init`/`kubeadm join`

Ubuntu cloud images come with cloud-init pre-configured for CloudStack (`DataSourceCloudStack`). Do **not** disable or replace cloud-init — CKS depends on it.

> **Important:** The `cloud` user's SSH key is injected via cloud-init at deployment time, **not** pre-registered in the template. Do not add SSH keys to the template image.

## Using Different Templates Per Node Type

From ACS 4.21+, you can assign different templates to control, worker, and etcd nodes:

```bash
# Create templates for each role
CONTROL_TEMPLATE_ID=$(cmk list templates nameFilter="Ubuntu 24.04 CKS Control" filter=id | grep -oP '(?<="id":"')[^"]+')
WORKER_TEMPLATE_ID=$(cmk list templates nameFilter="Ubuntu 24.04 CKS Worker" filter=id | grep -oP '(?<="id":"')[^"]+')
ETCD_TEMPLATE_ID=$(cmk list templates nameFilter="Ubuntu 24.04 CKS Etcd" filter=id | grep -oP '(?<="id":"')[^"]+')

# Create cluster with per-role templates
cmk create kubernetescluster \
  name=production-cluster \
  zoneid=<zone-id> \
  kubernetesversionid=<version-id> \
  serviceofferingid=<offering-id> \
  controlnodes=3 \
  size=4 \
  etcdnodes=3 \
  nodetemplates="{control:$CONTROL_TEMPLATE_ID,worker:$WORKER_TEMPLATE_ID,etcd:$ETCD_TEMPLATE_ID}"
```

Common use cases:
- **Control nodes:** Pre-install monitoring agents (Prometheus node-exporter, etc.)
- **Worker nodes:** Pre-install GPU drivers, Docker, or custom runtimes
- **Etcd nodes:** Minimal image optimized for I/O performance

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Template not showing in CKS cluster creation | Ensure `forcks=true` was set during registration |
| `/mnt/k8sdisk/` timeout during boot | Check qemu-guest-agent is running; verify ISO is accessible on secondary storage |
| `Failed to enable unit: Unit file kubelet.service does not exist` | Pre-install kubelet in the template, or ensure the binaries ISO contains it |
| cloud-init fails with DataSourceCloudStack | Verify the template has cloud-init installed and the VM can reach the metadata service |
| Container runtime not found | Ensure containerd is installed, enabled, and running before CKS bootstraps |
| Bridge module not loaded | Add `br_netfilter` to `/etc/modules-load.d/k8s.conf` and run `sysctl --system` |
| Nodes fail to join cluster | Check kubelet version compatibility with the ISO's K8s version |
| qga not responding (KVM) | Ensure `qemu-guest-agent` service is enabled and running; check virtio-serial channel |
| Template registration stuck | Verify the URL is accessible from the CloudStack secondary storage |

## Common Customizations

### Pre-install Helm

```bash
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

### Pre-install NVIDIA GPU Drivers

```bash
# Add Graphics Drivers PPA
add-apt-repository ppa:graphics-drivers/ppa
apt-get update
apt-get install -y nvidia-driver-550
# Or use the NVIDIA container toolkit for GPU workloads
```

### Pre-install Monitoring Stack

```bash
# Node exporter
wget https://github.com/prometheus/node_exporter/releases/download/v1.8.2/node_exporter-1.8.2.linux-amd64.tar.gz
tar xzf node_exporter-*.tar.gz
cp node_exporter-*/node_exporter /usr/local/bin/

cat > /etc/systemd/system/node_exporter.service <<EOF
[Unit]
Description=Node Exporter
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/node_exporter
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl enable node_exporter
```

### Custom Kernel Parameters

```bash
# /etc/sysctl.d/99-custom.conf
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 32768
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 8192
```

## References

- [CloudStack CKS Documentation](https://docs.cloudstack.apache.org/en/latest/plugins/cloudstack-kubernetes-service.html)
- [CKS Custom ISO Build Guide](./cks-custom-iso.md)
- [CKS Setup Guide](./cks.md)
- [CKS Upgrade Guide](./cks-upgrade.md)
- [Pre-built CKS Templates](http://download.cloudstack.org/testing/custom_templates/ubuntu/22.04/)
- [Ubuntu Cloud Images](https://cloud-images.ubuntu.com/noble/current/)
- [kubernetes-sigs/image-builder](https://github.com/kubernetes-sigs/image-builder/tree/master/images/capi) (for CAPC-compatible images)
