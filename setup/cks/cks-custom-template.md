# CKS Custom Template Build Guide

## Overview

From CloudStack 4.21+, you can register custom VM templates for CKS cluster nodes instead of relying on the default SystemVM template. This lets you:

- Use a modern Linux distro (Ubuntu 24.04, Rocky 9, etc.)
- Pre-install tools and drivers (helm, GPU drivers, monitoring agents)
- Assign different templates per node type (control, worker, etcd)

> **Note:** The template is the **base OS image**. Kubernetes binaries still come from the ISO registered as a supported K8s version. CKS handles kernel modules, sysctl settings, and CNI configuration during bootstrap — you only need to provide the minimal requirements listed below.

## Template Requirements (per CloudStack docs)

A CKS template needs very little — most setup is done by CKS at boot time from the binaries ISO:

| Requirement | Why |
|-------------|-----|
| **cloud-init** | Receives hostname, SSH keys, and user-data from CloudStack metadata service (Ubuntu cloud images include this) |
| **cloud user** | CKS runs scripts as `cloud` user; mgmt server SSHs in as `cloud` (Ubuntu cloud images include this) |
| **Management server SSH key** | Mgmt server must SSH into nodes to bootstrap the cluster — its public key goes in `/home/cloud/.ssh/authorized_keys` |
| **containerd** | Container runtime for Kubernetes pods (v1.7+) |
| **qemu-guest-agent** | Required on KVM hypervisors for ISO mount/detach and VM communication |
| **`/opt/bin` directory** | CKS expects this directory to exist on cluster nodes |

That's it. CKS installs kubelet, kubeadm, kubectl, CNI plugins, conntrack, ipset, socat, etc. from the binaries ISO during bootstrap.

## Step-by-Step: Ubuntu 24.04 CKS Template

### Step 1: Prepare a Build Environment

Use a machine with `virt-install` and `virt-customize` available:

```bash
sudo apt install -y libvirt-daemon-system libvirt-clients \
  virtinst libguestfs-tools qemu-utils
```

### Step 2: Download Ubuntu 24.04 Cloud Image

```bash
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

# Verify checksum
wget https://cloud-images.ubuntu.com/noble/current/SHA256SUMS
sha256sum -c SHA256SUMS 2>/dev/null | grep noble-server-cloudimg-amd64.img
```

### Step 3: Get the Management Server's SSH Public Key

CKS bootstraps nodes by SSHing from the management server as `cloud` user. The mgmt server's **public** key must be baked into the template — otherwise CKS cannot connect to VMs during provisioning.

```bash
# On your CloudStack management server:
cat /root/.ssh/id_rsa.pub
```

Copy the public key — you'll need it in Step 4.

### Step 4: Customize the Image

**Option A — Quick build with `virt-customize`:**

```bash
# Install containerd and qemu-guest-agent, then add the mgmt SSH key
MGMT_PUB_KEY="<paste_mgmt_server_public_key_here>"

virt-customize --verbose -a noble-server-cloudimg-amd64.img \
  --install qemu-guest-agent \
  --run 'mkdir -p /opt/bin' \
  --run 'apt-get update && apt-get install -y containerd.io'
  --run "mkdir -p /home/cloud/.ssh && echo '${MGMT_PUB_KEY}' > /home/cloud/.ssh/authorized_keys && chmod 700 /home/cloud/.ssh && chmod 600 /home/cloud/.ssh/authorized_keys && chown -R cloud:cloud /home/cloud/.ssh" \
  --run 'systemctl enable containerd && systemctl enable qemu-guest-agent' \
  --run 'apt-get clean && rm -rf /tmp/* /var/log/cloud-init.log /var/log/cloud-init-output.log && truncate -s 0 /var/log/auth.log && rm -f /etc/machine-id'
```

**Option B — Build inside a VM (more control):**

You can build the image using local KVM/libvirt, or directly inside CloudStack by deploying an instance from the Ubuntu cloud image.
The steps below are the same either way — just use whatever hypervisor is convenient.

Inside the VM:

```bash
# Create required directory (CKS expects this)
mkdir -p /opt/bin

# Install required packages
apt-get update && apt-get upgrade -y
apt-get install -y containerd.io qemu-guest-agent

# Enable services at boot
systemctl enable containerd
systemctl enable qemu-guest-agent

# Add management server's SSH public key to cloud user
mkdir -p /home/cloud/.ssh
cat >> /home/cloud/.ssh/authorized_keys <<'MGMT_KEY'
<REPLACE_WITH_MGMT_SERVER_PUBLIC_KEY>
MGMT_KEY
chmod 700 /home/cloud/.ssh
chmod 600 /home/cloud/.ssh/authorized_keys
chown -R cloud:cloud /home/cloud/.ssh

# (Optional) Inject trusted CA certificates
# If your private Docker registry uses an internal CA, add it here so containerd trusts it.
cp /path/to/internal-ca.crt /usr/local/share/ca-certificates/internal-ca.crt
update-ca-certificates

# Also tell containerd explicitly (some versions don't read system certs by default)
mkdir -p /etc/containerd/certs.d/<your-private-registry-hostname>
cp /path/to/internal-ca.crt /etc/containerd/certs.d/<your-private-registry-hostname>/ca.crt

# Clean up
apt-get clean
rm -rf /tmp/*
truncate -s 0 /var/log/auth.log
```

### Step 5: Convert to CloudStack Format

For KVM hypervisors, CloudStack expects QCOW2 (optionally compressed):

```bash
# Shut down the VM if you built inside one
virsh shutdown ubuntu24-cks-template

# Compress with bzip2 (CloudStack decompresses on-the-fly)
bzip2 -9 noble-server-cloudimg-amd64.img
```

For VMware: convert to OVA/vmdk. For Hyper-V: convert to VHD.

### Step 6: Upload and Register in CloudStack

#### Option A — UI

1. **Compute** → **Templates** → **Register Template**
2. Fill in:
   - **Name:** `Ubuntu 24.04 CKS Template`
   - **Zone:** your zone
   - **Format:** QCOW2
   - **Hypervisor:** KVM (or yours)
   - **OS Type:** Ubuntu Linux (64-bit)
3. ✅ **Check "For CKS"** — mandatory; without it, the template won't appear in CKS cluster creation
4. Set **Is Public** = true, **Is Extractable** = true
5. Click **Register**

#### Option B — cmk

```bash
cmk register template \
  name="Ubuntu 24.04 CKS Template" \
  url=http://<your-server>/cks-ubuntu-2404-kvm.qcow2.bz2 \
  zoneid=<zone-id> \
  format=QCOW2 \
  hypervisortype=KVM \
  ostypeid=<os-type-id> \
  ispublic=true \
  isextractable=true \
  forcks=true
```

### Step 7: Verify and Use

```bash
# Confirm registration
cmk list templates nameFilter="Ubuntu 24.04 CKS Template" filter=name,id,forcks
```

Then create a cluster via UI (Advanced Settings → select template per node type) or:

```bash
TEMPLATE_ID=$(cmk list templates nameFilter="Ubuntu 24.04 CKS Template" filter=id | grep -oP '(?<="id":"')[^"]+')

cmk create kubernetescluster \
  name=my-cks-cluster \
  zoneid=<zone-id> \
  kubernetesversionid=<version-id> \
  serviceofferingid=<offering-id> \
  controlnodes=1 size=2 \
  nodetemplates="{worker:$TEMPLATE_ID,control:$TEMPLATE_ID}"
```

## Pre-built CKS Templates

CloudStack provides pre-built templates for Ubuntu 22.04:

| Hypervisor | File |
|------------|------|
| KVM (QCOW2) | `cks-ubuntu-2204-kvm.qcow2.bz2` |
| VMware (OVA) | `cks-ubuntu-2204-vmware.ova` |
| Hyper-V (VHD) | `cks-ubuntu-2204-hyperv.vhd.zip` |
| OVM (RAW) | `cks-ubuntu-2204-ovm.raw.bz2` |

Location: http://download.cloudstack.org/testing/custom_templates/ubuntu/22.04/

> **Ubuntu 24.04 pre-built templates** are not yet available in official downloads.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Template not showing in CKS cluster creation | Ensure `forcks=true` was set during registration |
| `/mnt/k8sdisk/` timeout during boot | Check qemu-guest-agent is running; verify ISO on secondary storage |
| CKS can't SSH to nodes, provisioning hangs | Verify mgmt server's public key is in `/home/cloud/.ssh/authorized_keys` with correct permissions |
| Container runtime not found | Ensure containerd is installed and enabled (`systemctl enable containerd`) |

## References

- [CloudStack CKS Documentation](https://docs.cloudstack.apache.org/en/latest/plugins/cloudstack-kubernetes-service.html)
- [CKS Setup Guide](./cks.md)
- [CKS Custom ISO Build Guide](./cks-custom-iso.md)
- [CKS Upgrade Guide](./cks-upgrade.md)
