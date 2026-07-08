# CAPC Custom Image Building

If you need a custom OS, specific package versions, or specialized configurations for your CAPC nodes, you can build your own Kubernetes-compatible images using the [kubernetes-sigs/image-builder](https://github.com/kubernetes-sigs/image-builder/tree/master/images/capi) project.

The authoritative instructions for CloudStack images are in the [Image Builder book — Building Images for CloudStack](https://image-builder.sigs.k8s.io/capi/providers/cloudstack.html).

## What's Included in a CAPC-Compatible Image

Every image must have these prerequisites installed:

- **Container runtime** (containerd)
- **kubelet**
- **kubeadm**
- **kubectl**
- **cloud-init** for node bootstrapping

## Building Your Own Image

### Prerequisites

Image-builder for CloudStack produces `qcow2` images using the **KVM/QEMU** hypervisor, so the build host must be Linux with KVM support.

1. **Install system packages:**

   ```bash
   sudo apt update
   sudo apt install -y qemu-system-x86 libvirt-daemon-system libvirt-clients qemu-utils ovmf
   ```

   > **Note:** On Ubuntu 18.04+, `libvirt-bin` was split into `libvirt-daemon-system` and `libvirt-clients`. On Ubuntu 16.04, use `libvirt-bin` instead. `qemu-kvm` is a transitional package that resolves to `qemu-system-x86`.

2. **Add your user to the `kvm` group and fix `/dev/kvm` ownership:**

   ```bash
   sudo usermod -a -G kvm "$USER"
   sudo chown root:kvm /dev/kvm
   ```

   Log out and back in for the group change to take effect.

3. **Clone the image-builder repo:**

   ```bash
   cd /home/toor/workspace
   git clone https://github.com/kubernetes-sigs/image-builder.git
   cd image-builder/images/capi
   ```

4. **Install image-builder dependencies:**

   ```bash
   make deps-qemu
   ```

### Build a CloudStack-Ready QCOW2 Image

CloudStack images need the `provider=cloudstack` Ansible variable. The standard way to pass this is via a Packer var file.

Image-builder ships with default Kubernetes version values in `packer/config/kubernetes.json`. You override them by adding the relevant keys to your `extra_vars.json` — Packer merges your file on top of the defaults.

#### Key variables

| Variable | Example | Description |
|---|---|---|
| `kubernetes_semver` | `"v1.36.1"` | Full semantic version (with `v` prefix) |
| `kubernetes_series` | `"v1.36"` | Minor series (used for APT/YUM repo paths) |
| `kubernetes_deb_version` | `"1.36.1-1.1"` | Exact DEB package version |
| `kubernetes_rpm_version` | `"1.36.1"` | Exact RPM package version |
| `crictl_version` | `"1.36.0"` | CRI-tools version (should match K8s series) |

> **Where to find current defaults:** Check `packer/config/kubernetes.json` in your cloned repo. It contains all the `kubernetes_*` keys and their current values. Copy the ones you want to override into `extra_vars.json`.

#### Example 1 — Build with default K8s version (whatever image-builder ships)

```bash
cat > extra_vars.json <<EOF
{
  "ansible_user_vars": "provider=cloudstack"
}
EOF

PACKER_VAR_FILES=extra_vars.json make clean build-qemu-ubuntu-2404
```

The output directory is created under `images/capi/output/` in your cloned image-builder repo, for example:

```text
image-builder/images/capi/output/ubuntu-2404-kube-v1.36.1/
```

#### Example 2 — Build with a specific K8s version

Override `kubernetes_semver` and `kubernetes_series` (and the deb/rpm versions if they differ from the defaults):

```bash
cat > extra_vars.json <<EOF
{
  "ansible_user_vars": "provider=cloudstack",
  "kubernetes_semver": "v1.35.0",
  "kubernetes_series": "v1.35",
  "kubernetes_deb_version": "1.35.0-1.1",
  "kubernetes_rpm_version": "1.35.0"
}
EOF

PACKER_VAR_FILES=extra_vars.json make clean build-qemu-ubuntu-2404
```

Output:

```text
image-builder/images/capi/output/ubuntu-2404-kube-v1.35.0/
```

Inside that directory you will find the raw `qcow2` image.

### Supported OS Versions

The upstream image-builder project adds and removes OS targets over time. Check the current targets in your cloned repo:

```bash
make help
# or
grep "^build-qemu" Makefile | head -20
```

As of recent image-builder releases, Ubuntu targets include:

| OS | Typical versions |
|---|---|
| Ubuntu | 20.04, 22.04, 24.04 |
| Rocky Linux | 8, 9 |
| RHEL | 8, 9 |

> **Ubuntu 26.04:** Upstream image-builder `main` has a `build-qemu-ubuntu-2604` target, so you can build it with `PACKER_VAR_FILES=extra_vars.json make build-qemu-ubuntu-2604`. Make sure your local clone is recent; older image-builder releases may not include it.

### Convert for Other Hypervisors

The KVM build produces a `qcow2` for CloudStack with KVM. For XenServer or VMware you must convert the image.

#### XenServer (`vhd`)

```bash
./hack/ensure-vhdutil.sh
./hack/convert-cloudstack-image.sh ./output/<build-name>/<build-name> x
# Output: <build-name>-xen.vhd.bz2
```

#### VMware (`ova`)

```bash
./hack/ensure-ovftool.sh
./hack/convert-cloudstack-image.sh ./output/<build-name>/<build-name> v
# Output: <build-name>-vmware.ova
```

### Prebuilt Images

For convenience, prebuilt CAPC images are available from [packages.shapeblue.com/cluster-api-provider-cloudstack/images/](http://packages.shapeblue.com/cluster-api-provider-cloudstack/images/).

## Registering the Image in CloudStack

After building (and optionally converting) your image, upload and register it as a CloudStack template.

### Option 1: Upload via CloudStack UI

1. Go to **Templates** → **Register template**.
2. Set:
   - **Name**: e.g. `kube-v1.36/ubuntu-2404-custom`
   - **Format**: `QCOW2` (KVM), `VHD` (XenServer), or `OVA` (VMware)
   - **Hypervisor**: matching the format
   - **URL**: HTTP/HTTPS URL where the image is hosted
   - **OS Type**: `Ubuntu Linux (64-bit)`
   - **Zone**: the zone where the template should be available

### Option 2: Register via `cmk` CLI

```bash
export CLOUDSTACK_ZONE_ID=<zone-id>

# KVM qcow2 example
cmk registerTemplate \
  name="kube-v1.36/ubuntu-2404-custom" \
  displayText="CAPC Ubuntu 24.04 K8s 1.36" \
  url="http://your-web-server/images/ubuntu-2404-kube-v1.36.0.qcow2.bz2" \
  zoneid="$CLOUDSTACK_ZONE_ID" \
  format=QCOW2 \
  hypervisor=KVM \
  ispublic=true \
  ostypeid="<ubuntu-linux-64-bit-os-type-id>"
```

### Verify Registration

```bash
cmk listTemplates filter=unique nameFilter="kube-v1.36/ubuntu-2404-custom"
```

## Using the Custom Template in CAPC

Reference the template name in your cluster manifest:

```yaml
apiVersion: infrastructure.cluster.x-k8s.io/v1beta3
kind: CloudStackMachineTemplate
metadata:
  name: capc-cluster-control-plane
spec:
  template:
    spec:
      template: kube-v1.36/ubuntu-2404-custom
      offering:
        name: kube control
      sshKey: my-ssh-key
```

Or, with `clusterctl generate cluster`:

```bash
export CLOUDSTACK_TEMPLATE_NAME=kube-v1.36/ubuntu-2404-custom

clusterctl generate cluster capc-cluster \
  --kubernetes-version v1.36.0 \
  --control-plane-machine-count=3 \
  --worker-machine-count=2 \
  > capc-cluster-spec.yaml
```

## Tips and Best Practices

- **Use prebuilt images when possible** — they're tested and maintained by the CAPC community.
- **Match K8s version** — ensure your kubelet/kubeadm versions match the target Kubernetes version.
- **Test cloud-init compatibility** — verify that cloud-init works correctly with your custom image.
- **Verify container runtime** — CAPC expects containerd to be running and accessible.
- **Check network configuration** — ensure your image has proper networking setup for CloudStack (DHCP, DNS).

## Troubleshooting

| Issue | Solution |
|---|---|
| `mage` not found | CloudStack builds use `make`, not `mage`. Run `make deps-qemu` and `make build-qemu-ubuntu-2404`. |
| Build fails with "provider=cloudstack" missing | Add `"ansible_user_vars": "provider=cloudstack"` to your `extra_vars.json` and pass it via `PACKER_VAR_FILES`. |
| Nodes fail to join cluster | Verify kubelet is running and cloud-init executed successfully. |
| Container runtime errors | Ensure containerd is installed and the service is enabled. |
| Network connectivity issues | Check that cloud-init properly configures networking for CloudStack. |
| Template not found in CAPC | Verify template name matches exactly (case-sensitive). |

## References

- [kubernetes-sigs/image-builder](https://github.com/kubernetes-sigs/image-builder/tree/master/images/capi)
- [Image Builder Book — Building Images for CloudStack](https://image-builder.sigs.k8s.io/capi/providers/cloudstack.html)
- [CAPC Getting Started Guide](https://cluster-api-cloudstack.sigs.k8s.io/getting-started)
- [CloudStack `registerTemplate` API](https://cloudstack.apache.org/docs/api/latest/apidocs/operation_registerTemplate.html)
