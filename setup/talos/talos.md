# Talos Linux Setup — Deploying Kubernetes on CloudStack with Talos

This guide walks through deploying a Kubernetes cluster on Apache CloudStack using [Talos Linux](https://www.talos.dev/) — a minimal, immutable, and security-hardened Linux distribution designed specifically for running Kubernetes.

> **Note:** Unlike the other flavors in this repository (CKS, CAPC, Rancher+CAPC) which use traditional Linux distributions with kubeadm, Talos is managed entirely through its gRPC API (`talosctl`). There is no SSH, no package manager, and no writable root filesystem at runtime. See the [Talos architecture](../architecture/talos.md) for a detailed comparison.

## Prerequisites

### CloudStack Resources

Ensure these exist in your CloudStack environment:

| Resource | Details |
|----------|---------|
| **Zone** | A zone with available compute resources |
| **Network** | An isolated or shared network for the cluster VMs |
| **Public IP** | An unused public IP for the Kubernetes API endpoint load balancer |
| **Compute Offering** | At least 2 vCPU, 2 GB RAM (minimum for control plane) |

### Local Tools

Install these on the machine where you'll manage the cluster:

| Tool | Purpose | Install |
|------|---------|---------|
| **cmk** (CloudMonkey) | CloudStack CLI | `pip install cloudmonkey` or package manager |
| **talosctl** | Talos management CLI | [Install guide](https://docs.siderolabs.com/talos/v1.13/getting-started/talosctl) |
| **jq** | JSON processing | `apt install jq` / `yum install jq` |
| **base64** | Config encoding | Usually pre-installed |

## Step 1: Obtain the Talos CloudStack Image

Download the Talos CloudStack image from the [Image Factory](https://factory.talos.dev).

> **Minimum version:** Talos v1.8.0 or later is required for CloudStack support.

```bash
# Option A: Direct download (if CloudStack can fetch from URL)
# Register template in CloudStack UI with URL:
# https://factory.talos.dev/image/<channel>/<version>/cloudstack-amd64.raw.gz

# Option B: Download locally, decompress, host on a web server
curl -LO https://factory.talos.dev/image/<channel>/<version>/cloudstack-amd64.raw.gz
gunzip cloudstack-amd64.raw.gz
# Host the .raw file on a local web server, then register template from that URL
```

> **Note:** CloudStack may not handle compressed images well. If the direct URL fails, download the image, decompress it, host it on a local web server, and register the template from there. Alternatively, try removing `.gz` from the URL to fetch an uncompressed image.

### Register the Template

In the CloudStack UI, register a new template:
- **Name:** `talos-<version>` (e.g., `talos-1.8.0`)
- **URL:** Point to the image (compressed or uncompressed)
- **Zone:** Your target zone
- **Format:** RAW
- **Hypervisor:** KVM (or your hypervisor)
- **Checksum:** SHA256 of the image (optional but recommended)

Or via cmk:

```bash
cmk register template \
  name=talos-1.8.0 \
  url=https://your-server/talos/cloudstack-amd64.raw \
  zoneid=${ZONE_ID} \
  format=RAW \
  hypervisor=KVM
```

## Step 2: Gather CloudStack Resource IDs

Export the required CloudStack resource IDs as environment variables for use in subsequent commands.

### Get Zone ID

```bash
cmk list zones | jq -r '.zone[] | [.id, .name] | @tsv' | sort -k2
export ZONE_ID=<your-zone-id>
```

### Get Image Template ID

```bash
cmk list templates templatefilter=self | jq -r '.template[] | [.id, .name] | @tsv' | sort -k2
export IMAGE_ID=<your-talos-template-id>
```

### Get Service Offering ID

```bash
cmk list serviceofferings | jq -r '.serviceoffering[] | [.id, .memory, .cpunumber, .name] | @tsv' | sort -k4
export SERVICEOFFERING_ID=<your-offering-id>
```

### Get Network ID

```bash
cmk list networks zoneid=${ZONE_ID} | jq -r '.network[] | [.id, .type, .name] | @tsv' | sort -k3
export NETWORK_ID=<your-network-id>
```

### Get a Free Public IP

```bash
cmk list publicipaddresses zoneid=${ZONE_ID} state=free forvirtualnetwork=true | \
  jq -r '.publicipaddress[] | [.id, .ipaddress] | @tsv' | sort -k2
export PUBLIC_IPADDRESS=<ip-address>
export PUBLIC_IPADDRESS_ID=<ip-id>
```

## Step 3: Set Up the API Endpoint Load Balancer

### Associate the Public IP with Your Network

```bash
cmk associateIpAddress ipaddress=${PUBLIC_IPADDRESS} networkid=${NETWORK_ID}
```

### Create Load Balancer Rule

Create a load balancer rule for the Kubernetes API endpoint (port 6443). This also creates the corresponding firewall rule.

```bash
cmk create loadbalancerrule \
  algorithm=roundrobin \
  name="k8s-api" \
  privateport=6443 \
  publicport=6443 \
  openfirewall=true \
  publicipid=${PUBLIC_IPADDRESS_ID} \
  cidrlist=0.0.0.0/0
```

## Step 4: Generate Talos Configuration

Generate the Talos machine configuration files. The API server endpoint is the public IP address of the load balancer.

```bash
talosctl gen config talos-cloudstack https://${PUBLIC_IPADDRESS}:6443 \
  --with-docs=false \
  --with-examples=false
```

This creates three files:

| File | Purpose |
|------|---------|
| `controlplane.yaml` | Configuration for control plane nodes |
| `worker.yaml` | Configuration for worker nodes |
| `talosconfig` | Local `talosctl` configuration for cluster management |

### Customize the Configuration (Optional)

Edit `controlplane.yaml` and `worker.yaml` as needed. Common customizations:

```yaml
# Example: Set node labels, disable default CNI, configure network
machine:
  network:
    hostname: talos-cp-1  # optional — Talos auto-detects from CloudStack metadata
  kubelet:
    extraArgs:
      node-labels: "topology.kubernetes.io/zone=cyz1"
cluster:
  network:
    cni:
      name: none  # disable default CNI if installing Calico/Cilium separately
```

> **Important:** Always validate your configuration after editing:
> ```bash
> talosctl validate --config controlplane.yaml --mode cloud
> talosctl validate --config worker.yaml --mode cloud
> ```

## Step 5: Deploy the Control Plane VM

Create the control plane VM with the Talos configuration as base64-encoded user-data.

```bash
cmk deploy virtualmachine \
  zoneid=${ZONE_ID} \
  templateid=${IMAGE_ID} \
  serviceofferingid=${SERVICEOFFERING_ID} \
  networkids=${NETWORK_ID} \
  name=talos-cp-1 \
  userdata=$(base64 controlplane.yaml | tr -d '\n')
```

## Step 6: Get VM Details

```bash
cmk list virtualmachines | jq -r '.virtualmachine[] | [.id, .ipaddress, .name] | @tsv' | sort -k3
export VM_ID=<talos-cp-1-vm-id>
export VM_IP=<talos-cp-1-ip-address>
```

## Step 7: Assign VM to Load Balancer

```bash
cmk list loadbalancerrules | jq -r '.loadbalancerrule[] | [.id, .publicip, .name] | @tsv' | sort -k2
export LB_RULE_ID=<k8s-api-lb-rule-id>

cmk assigntoloadbalancerrule id=${LB_RULE_ID} virtualmachineids=${VM_ID}
```

## Step 8: Bootstrap the Cluster

### Configure talosctl

```bash
talosctl --talosconfig talosconfig config endpoint ${VM_IP}
talosctl --talosconfig talosconfig config node ${VM_IP}
```

### Bootstrap etcd

```bash
talosctl --talosconfig talosconfig bootstrap
```

### Monitor Bootstrap Progress

```bash
talosctl --talosconfig talosconfig dashboard
```

## Step 9: Retrieve kubeconfig

```bash
talosctl --talosconfig talosconfig kubeconfig .
```

## Step 10: Verify the Cluster

```bash
# Check cluster health
talosctl --talosconfig talosconfig health

# Check nodes
kubectl get nodes

# Check pods
kubectl get pods -A
```

## Step 11: Install CNI

Talos does **not** include a default CNI. Install one after cluster bootstrap:

### Calico

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28/manifests/calico.yaml
```

### Cilium

```bash
cilium install
```

### Flannel

```bash
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

## Step 12: Install CloudStack Kubernetes Provider (CCM)

The CloudStack external cloud controller manager is **required** for any Kubernetes cluster running on CloudStack. It provides:

- `LoadBalancer` service type support via CloudStack load balancer rules
- Node metadata labels (zone, region, instance type)
- Firewall rule management for NodePort services

```bash
# See setup/cloudstack-kubernetes-provider.md for detailed configuration
kubectl apply -f https://raw.githubusercontent.com/apache/cloudstack-kubernetes-provider/main/deployment.yaml
```

> **Note:** Unlike CKS which auto-deploys the CCM, Talos requires manual installation. The CCM must be configured with your CloudStack API credentials (api-url, api-key, secret-key).

## Step 13: Install CloudStack CSI Driver

The CloudStack CSI driver is **required** for persistent storage on CloudStack. It provides:

- Dynamic provisioning of CloudStack volumes via StorageClasses
- Volume lifecycle management (create, attach, detach, delete)
- Volume snapshots and cloning

```bash
# See setup/cloudstack-csi-driver.md for detailed configuration
kubectl apply -f https://raw.githubusercontent.com/apache/cloudstack-csi-driver/main/deploy/kubernetes/csi.yaml
```

> **Note:** The CSI driver requires CloudStack API credentials and must be configured with the appropriate disk offering for your workloads.

## Adding Worker Nodes

### Generate Worker Configuration

If you didn't generate `worker.yaml` earlier, or need to regenerate it:

```bash
talosctl gen config talos-cloudstack https://${PUBLIC_IPADDRESS}:6443 \
  --with-docs=false --with-examples=false
```

### Deploy Worker VM

```bash
cmk deploy virtualmachine \
  zoneid=${ZONE_ID} \
  templateid=${IMAGE_ID} \
  serviceofferingid=${WORKER_OFFERING_ID} \
  networkids=${NETWORK_ID} \
  name=talos-worker-1 \
  userdata=$(base64 worker.yaml | tr -d '\n')
```

### Join Worker to Cluster

```bash
export WORKER_IP=<worker-vm-ip>
talosctl --talosconfig talosconfig config node ${WORKER_IP}
talosctl --talosconfig talosconfig apply-config --file worker.yaml
```

## Scaling to HA (Multi-Node Control Plane)

For a highly available control plane, deploy additional control plane VMs with the same `controlplane.yaml`:

```bash
# Deploy additional control plane VMs
cmk deploy virtualmachine \
  zoneid=${ZONE_ID} \
  templateid=${IMAGE_ID} \
  serviceofferingid=${SERVICEOFFERING_ID} \
  networkids=${NETWORK_ID} \
  name=talos-cp-2 \
  userdata=$(base64 controlplane.yaml | tr -d '\n')

cmk deploy virtualmachine \
  zoneid=${ZONE_ID} \
  templateid=${IMAGE_ID} \
  serviceofferingid=${SERVICEOFFERING_ID} \
  networkids=${NETWORK_ID} \
  name=talos-cp-3 \
  userdata=$(base64 controlplane.yaml | tr -d '\n')
```

Then add them to the load balancer:

```bash
cmk assigntoloadbalancerrule id=${LB_RULE_ID} virtualmachineids=${CP2_ID},${CP3_ID}
```

Talos automatically discovers and joins additional control plane nodes to the etcd cluster.

## Upgrading Talos

Talos upgrades are image-based and atomic:

```bash
# Check current version
talosctl --talosconfig talosconfig version

# Upgrade to a specific version
talosctl --talosconfig talosconfig upgrade \
  --image=factory.talos.dev/installer/<new-version>

# For multi-node clusters, upgrade one node at a time
talosctl --talosconfig talosconfig upgrade \
  --image=factory.talos.dev/installer/<new-version> \
  --nodes <node-ip>
```

## Troubleshooting

### VM fails to boot

- Verify the template was registered correctly (format=RAW)
- Check CloudStack system logs for VM creation errors
- Ensure the compute offering has sufficient resources

### talosctl can't connect

- Verify the VM is running: `cmk list virtualmachines id=${VM_ID}`
- Check the load balancer rule is correctly configured
- Ensure firewall rules allow port 6443
- Try `talosctl --talosconfig talosconfig health`

### Cluster bootstrap fails

- Check `talosctl --talosconfig talosconfig dashboard` for errors
- Verify etcd bootstrap: `talosctl --talosconfig talosconfig etcd status`
- Check kubelet logs: `talosctl --talosconfig talosconfig logs kubelet`

## References

- [Talos CloudStack Platform Guide](https://docs.siderolabs.com/talos/v1.13/platform-specific-installations/cloud-platforms/cloudstack) — official Sidero documentation
- [Talos Architecture](../architecture/talos.md) — detailed architecture overview
- [Image Factory](https://factory.talos.dev) — download Talos images
- [talosctl Reference](https://www.talos.dev/v1.13/reference/cli/)
- [Talos GitHub](https://github.com/siderolabs/talos)
