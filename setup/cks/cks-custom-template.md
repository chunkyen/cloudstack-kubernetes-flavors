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
| **cloud-guest-utils** | Provides qemu-guest-agent for KVM ISO mount/detach and VM communication |
| **containerd** | Container runtime for Kubernetes pods (v1.7+) |
| **conntrack** | Required for kube-proxy and CNI networking |
| **apt-transport-https, ca-certificates, curl, gnupg, software-properties-common, lsb-release** | Prerequisites for adding repos (e.g., containerd) |
| **python3-json-pointer, python3-jsonschema** | Used by CKS cloud-init data processing |
| **cloud user with nopasswd sudo** | CKS bootstrap scripts run as `cloud` user and need passwordless sudo. Ubuntu cloud images include this; verify if building custom base images. |
| **Management server SSH key** | Mgmt server must SSH into nodes to bootstrap the cluster — its public key goes in `/home/cloud/.ssh/authorized_keys` |
| **`/opt/bin` directory** | CKS expects this directory to exist on cluster nodes |

> All packages listed above come directly from the [official CloudStack CKS documentation](https://docs.cloudstack.apache.org/en/latest/plugins/cloudstack-kubernetes-service.html#build-a-custom-template-to-use-for-kubernetes-clusters-nodes).

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

**Option A — Quick build with virt-customize:**

```bash
# Install required packages per CloudStack docs, then add the mgmt SSH key
MGMT_PUB_KEY="<paste_mgmt_server_public_key_here>"

virt-customize --verbose -a noble-server-cloudimg-amd64.img \
  --run 'mkdir -p /opt/bin' \
  --run 'apt-get update && apt-get install -y cloud-guest-utils conntrack apt-transport-https ca-certificates curl gnupg gnupg-agent software-properties-common lsb-release python3-json-pointer python3-jsonschema containerd' \
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

# Install required packages per CloudStack docs
apt-get update && apt-get upgrade -y
apt-get install -y cloud-guest-utils conntrack apt-transport-https ca-certificates curl gnupg gnupg-agent software-properties-common lsb-release python3-json-pointer python3-jsonschema containerd

# Ensure 'cloud' user exists with passwordless sudo (CKS bootstrap runs as this user)
if ! id -u cloud &>/dev/null; then
  useradd -m -s /bin/bash -G sudo cloud
fi
echo '%sudo ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/cloud-user

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

### Step 4b: Prepare the VM for Templating (Sysprep Equivalent)

Before stopping the instance and registering it as a template, you must reset instance-specific data so every new clone boots clean. This is Ubuntu's equivalent of Windows Sysprep:

```bash
# Reset cloud-init state (so it re-runs on first boot like a fresh VM)
sudo cloud-init clean --logs

# Remove SSH host keys (each instance should generate its own)
rm -f /etc/ssh/ssh_host_*

# Clear network manager and DHCP state
rm -rf /var/lib/NetworkManager/
rm -f /var/lib/dhcp/*
rm -f /var/lib/cloud/data/dhcp.*

# Remove instance-specific IDs
truncate -s 0 /etc/machine-id
rm -f /etc/hostid

# Clear logs, history, and swap
journalctl --rotate && journalctl --vacuum-time=1s
history -c; history -w
swapoff -a && mkswap <your-swap-partition> && swapon <your-swap-partition>
```

After this, **stop the instance**. Each new cluster node will get fresh SSH keys, a new machine-id, clean DHCP state, and proper hostname from cloud-init.

### Step 5: Prepare the Image (local builds only)

> If you built natively inside CloudStack, skip this step — go straight to **Step 6**.

Stop the VM however your hypervisor requires, then navigate to the disk image location:

```bash
cd /path/to/vm/disks/
bzip2 -9 noble-server-cloudimg-amd64.img  # CloudStack decompresses on-the-fly
```

You can either upload the QCOW2 file to an HTTP-accessible server, or copy it directly to your management server for local registration. Both options are covered in Step 6.

### Step 6: Register as Template in CloudStack

**From a local build (QCOW2 file):**

Two options to get your image into CloudStack:

**Option 1 — HTTP URL registration:**
Upload the QCOW2 file to any web server accessible by your management server, then:
- **UI:** **Compute → Templates → Register Template**, paste the URL, fill in name/zone/format, ✅ check "For CKS", set Is Public = true.
- **cmk:**
```bash
cmk register template \
  name="Ubuntu 24.04 CKS Template" \
  url=http://<your-server>/cks-ubuntu-2404-kvm.qcow2.bz2 \
  zoneid=<zone-id> \
  format=QCOW2 \
  hypervisortype=KVM \
  ostypeid=<os-type-id> \
  ispublic=true \
  forcks=true
```

**Option 2 — Direct upload (no HTTP server needed):**
- **UI:** Same as above, but choose "Upload" instead of URL and select the QCOW2 file from your local machine.
- **cmk:** `cmk register template` with a local path or use the UI for large files.

**From a CloudStack-native build (root disk volume):**

**UI:** **Storage → Volumes** → find the root disk of your stopped VM → **Actions → Create Template From Volume** ✅ check "For CKS".

**cmk:**
```bash
VOLUME_ID=$(cmk list volumes virtualmachineid=<vm-id> type=root filter=id | grep -oP '(?<="id":"')[^"]+')
cmk create template \
  name="Ubuntu 24.04 CKS Template" \
  volumeid=$VOLUME_ID \
  forcks=true \
  ispublic=true
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

## Building CKS Templates with Packer (IaC)

For teams that want version-controlled, repeatable image builds, **HashiCorp Packer** can automate the entire process. This section shows how to build a CKS-compatible template using Packer's QEMU builder.

### Prerequisites

- Install [Packer](https://developer.hashicorp.com/packerc/install) on your build machine
- Access to a KVM host (for local builds) or CI runner with libvirt access

### Packer Template (`cks-template.pkr.hcl`)

```hcl
variable "mgmt_pub_key" {
  type    = string
  default = "<paste-management-server-public-key-here>"
}

source "qemu" "ubuntu24-cks" {
  iso_url        = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
  iso_checksum   = "sha256:9d1f8e3b7c0a3e1f..." # Check latest SHA256SUMS from Ubuntu cloud images
  output_directory = "output"
  format         = "qcow2"
  accelerator    = "kvm"
  ssh_username   = "ubuntu"
  http_directory = "files" # Optional: place CA certs or scripts here for upload
  memory         = 2048
  cores          = 2
}

build {
  sources = ["source.qemu.ubuntu24-cks"]

  provisioner "shell" {
    inline = [
      "apt-get update && apt-get upgrade -y",
      "mkdir -p /opt/bin",
      "apt-get install -y cloud-guest-utils conntrack apt-transport-https ca-certificates curl gnupg gnupg-agent software-properties-common lsb-release python3-json-pointer python3-jsonschema containerd",
      "systemctl enable containerd && systemctl enable qemu-guest-agent",
      "mkdir -p /home/cloud/.ssh",
      "echo '${var.mgmt_pub_key}' > /home/cloud/.ssh/authorized_keys",
      "chmod 700 /home/cloud/.ssh && chmod 600 /home/cloud/.ssh/authorized_keys && chown -R cloud:cloud /home/cloud/.ssh",
    ]
  }

  # Optional: Inject internal CA certs for private registry trust
  provisioner "file" {
    source      = "files/internal-ca.crt"
    destination = "/tmp/internal-ca.crt"
  }
  provisioner "shell" {
    inline = [
      "cp /tmp/internal-ca.crt /usr/local/share/ca-certificates/internal-ca.crt",
      "update-ca-certificates",
      "mkdir -p /etc/containerd/certs.d/<your-private-registry-hostname>",
      "cp /usr/local/share/ca-certificates/internal-ca.crt /etc/containerd/certs.d/<your-private-registry-hostname>/ca.crt",
    ]
  }

  # Sysprep-equivalent cleanup before image export
  provisioner "shell" {
    inline = [
      "cloud-init clean --logs",
      "rm -f /etc/ssh/ssh_host_*",
      "truncate -s 0 /etc/machine-id",
      "rm -f /etc/hostid",
      "apt-get clean && rm -rf /tmp/*",
    ]
  }

  post-processors {
    compress {
      format = "tar.gz"
    }
  }
}
```

### Build Workflow

```bash
# Initialize plugins and build the image
packer init .
packer build cks-template.pkr.hcl

# The output will be in output/ as a QCOW2 file (and compressed tar.gz)
ls -lh output/
```

### Register with CloudStack

After Packer finishes, upload the resulting `output/ubuntu24-cks.qcow2` to your HTTP server or secondary storage, then register it exactly like the manual method:

```bash
cmk register template \
  name="Ubuntu 24.04 CKS Template" \
  url=http://<your-server>/ubuntu24-cks.qcow2 \
  zoneid=<zone-id> \
  format=QCOW2 \
  hypervisortype=KVM \
  ostypeid=<os-type-id> \
  ispublic=true \
  forcks=true
```

### CI/CD Integration

This Packer template can be run in GitHub Actions, GitLab CI, or Jenkins to automatically rebuild and publish CKS templates whenever:
- Base Ubuntu cloud image updates release
- New containerd/qemu-guest-agent versions are available
- Internal CA certificates rotate

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
