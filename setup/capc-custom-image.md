# CAPC Custom Image Building

If you need a custom OS, specific package versions, or specialized configurations for your CAPC nodes, you can build your own K8s-compatible images using the [kubernetes-sigs/image-builder](https://github.com/kubernetes-sigs/image-builder/tree/master/images/capi) project.

## What's Included in a CAPC-Compatible Image

Every image must have these prerequisites installed:
- **Container runtime** (containerd or Docker)
- **kubelet**
- **kubeadm**
- **kubectl**
- **cloud-init** for node bootstrapping

## Building Your Own Image

### Prerequisites

```bash
# Install mage (build tool used by image-builder)
go install github.com/magefile/mage@latest

# Clone the image-builder repo
git clone https://github.com/kubernetes-sigs/image-builder.git
cd image-builder/images/capi
```

### Build Commands by Hypervisor

#### KVM / QEMU (qcow2)

```bash
mage build-kube-qemu --os ubuntu-2404 --kubernetes-version 1.32
# Output: images/ubuntu-2404-kube-v1.32.3-qemu.qcow2.bz2
```

#### VMware (OVA)

```bash
mage build-kube-vsphere --os ubuntu-2404 --kubernetes-version 1.32
# Output: images/ubuntu-2404-kube-v1.32.3-vmware.ova
```

#### AWS (AMI)

```bash
mage build-kube-aws --os ubuntu-2404 --kubernetes-version 1.32
```

### Supported OS Versions

| OS | Versions |
|----|----------|
| Ubuntu | 20.04, 22.04, 24.04 |
| Rocky Linux | 8, 9 |
| CentOS | 7 (legacy) |
| RHEL | 8, 9 |

### Customizing the Build

You can modify build parameters:

```bash
# Specify custom K8s version and OS
mage build-kube-qemu \
  --os ubuntu-2404 \
  --kubernetes-version 1.32 \
  --extra-packages "cri-tools,conntrack"
```

## Registering the Image in CloudStack

After building your image, upload and register it as a template:

### Step 1: Upload to CloudStack Storage

```bash
# Compress if needed (for KVM)
bzip2 -9 images/ubuntu-2404-kube-v1.32.3-qemu.qcow2
```

### Step 2: Register as a Template

```bash
curl -X POST 'https://your-cloudstack-host.com/client/api' \
  --data-urlencode 'command=registerTemplate' \
  --data-urlencode 'url=http://path/to/your/image.qcow2.bz2' \
  --data-urlencode 'zoneid=<zone-id>' \
  --data-urlencode 'format=QCOW2' \
  --data-urlencode 'hypervisortype=KVM' \
  --data-urlencode 'ispublic=true' \
  --data-urlencode 'ostype=Ubuntu Linux (64-bit)' \
  --data-urlencode 'name=kube-v1.32/ubuntu-2404-custom'
```

### Step 3: Verify Registration

```bash
curl -X GET 'https://your-cloudstack-host.com/client/api' \
  --data-urlencode 'command=listTemplates&filter=unique&nameFilter=kube-v1.32/ubuntu-2404-custom'
```

## Using the Custom Template in CAPC

Set your template name as an environment variable:

```bash
export CLOUDSTACK_TEMPLATE_NAME=kube-v1.32/ubuntu-2404-custom
```

Then proceed with cluster generation as normal:

```bash
clusterctl generate cluster capc-cluster \
  --kubernetes-version v1.32 \
  --control-plane-machine-count=3 \
  --worker-machine-count=2 \
  > capc-cluster-spec.yaml
```

## Tips and Best Practices

- **Use prebuilt images when possible** — they're tested and maintained by the CAPC community
- **Match K8s version** — ensure your kubelet/kubeadm versions match the target Kubernetes version
- **Test cloud-init compatibility** — verify that cloud-init works correctly with your custom image
- **Verify container runtime** — CAPC expects either containerd or Docker to be running and accessible
- **Check network configuration** — ensure your image has proper networking setup for CloudStack (DHCP, DNS)

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Nodes fail to join cluster | Verify kubelet is running and cloud-init executed successfully |
| Container runtime errors | Ensure containerd/Docker is installed and the service is enabled |
| Network connectivity issues | Check that cloud-init properly configures networking for CloudStack |
| Template not found in CAPC | Verify template name matches exactly (case-sensitive) |

## References

- [kubernetes-sigs/image-builder](https://github.com/kubernetes-sigs/image-builder/tree/master/images/capi)
- [CAPC Getting Started Guide](https://cluster-api-cloudstack.sigs.k8s.io/getting-started)
- [CloudStack Template Management](https://cloudstack.apache.org/docs/api/latest/apidocs/operation_registerTemplate.html)
