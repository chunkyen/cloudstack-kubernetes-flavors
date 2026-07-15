# Talos Linux Setup — Deploying Kubernetes on CloudStack with Talos

This guide walks through deploying a Kubernetes cluster on Apache CloudStack using [Talos Linux](https://www.talos.dev/) — a minimal, immutable, and security-hardened Linux distribution designed specifically for running Kubernetes.

> **Note:** Unlike the other flavors in this repository (CKS, CAPC, Rancher+CAPC) which use traditional Linux distributions with kubeadm, Talos is managed entirely through its gRPC API (`talosctl`). There is no SSH, no package manager, and no writable root filesystem at runtime. See the [Talos architecture](../architecture/talos.md) for a detailed comparison.

## Prerequisites

### CloudStack Resources

Ensure these exist in your CloudStack environment:

| Resource | Details |
|----------|---------|
| **Zone** | A zone with available compute resources |
| **Network** | An isolated network using the **Kubernetes network offering** (see below) |
| **Public IP** | An unused public IP for the Kubernetes API endpoint load balancer |
| **Compute Offering (Control Plane)** | At least 2 vCPU, 2 GB RAM (e.g., `kube control`) |
| **Compute Offering (Worker)** | At least 2 vCPU, 4 GB RAM (e.g., `kube worker1`) |

### Network Offering: Use the Kubernetes Service Offering

Talos clusters on CloudStack **must** use the `DefaultNetworkOfferingforKubernetesService` (or equivalent) for the isolated network. This offering provides:

- **Source NAT** — outbound internet access for the VMs (NTP, image pulls, etc.)
- **Load Balancer** — for the Kubernetes API endpoint
- **Port Forwarding** — for `talosctl` API access (port 50000)
- **Egress default allow** (`egressdefaultpolicy=true`) — outbound traffic is allowed without explicit firewall rules

> **⚠️ Critical: Egress policy differs between offerings.** The standard `DefaultIsolatedNetworkOfferingWithSourceNatService` has `egressdefaultpolicy=false`, meaning **all outbound traffic is blocked by default** and every protocol/port needs an explicit egress firewall rule. The Kubernetes offering (`DefaultNetworkOfferingforKubernetesService`) has `egressdefaultpolicy=true`, so outbound traffic flows freely. This matters because Talos VMs need NTP (UDP 123) for time sync before etcd bootstrap, and need to pull container images from the internet. Using the wrong offering means you must add egress rules for NTP, HTTP/HTTPS, DNS, and anything else the cluster needs.

To find the offering ID:

```bash
cmk list networkofferings | jq -r '.networkoffering[] | select(.name | test("KubernetesService")) | [.id, .name] | @tsv'
export NETWORK_OFFERING_ID=<kubernetes-offering-id>
```

### Local Tools

Install these on the machine where you'll manage the cluster:

| Tool | Purpose | Install |
|------|---------|---------|
| **cmk** (CloudMonkey) | CloudStack CLI | `pip install cloudmonkey` or package manager |
| **talosctl** | Talos management CLI | [Install guide](https://docs.siderolabs.com/talos/v1.13/getting-started/talosctl) |
| **jq** | JSON processing | `apt install jq` / `yum install jq` |
| **base64** | Config encoding | Usually pre-installed |
| **terraform** | Infrastructure as Code (optional) | [terraform.io/downloads](https://www.terraform.io/downloads) |

> **One-shot deployment with Terraform:** See [talos-terraform.md](talos-terraform.md) for a Terraform-based approach that creates the network, public IP, load balancer, port forwarding, and all VMs in a single `terraform apply`.

## Step 1: Obtain the Talos CloudStack Image

Talos provides CloudStack-specific images via the [Image Factory](https://factory.talos.dev) — a service that generates boot assets on demand. You can download images entirely via CLI, no browser needed.

> **Minimum version:** Talos v1.8.0 or later is required for CloudStack support.

### Option A: Download via CLI (Recommended)

The Image Factory serves images at predictable URLs. The "vanilla" schematic (no custom extensions) has a well-known ID:

```bash
# Set variables
SCHEMATIC_ID="376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba"
TALOS_VERSION="v1.8.0"

# Download the CloudStack image
curl -LO "https://factory.talos.dev/image/${SCHEMATIC_ID}/${TALOS_VERSION}/cloudstack-amd64.raw.gz"

# Verify checksum
curl -LO "https://factory.talos.dev/image/${SCHEMATIC_ID}/${TALOS_VERSION}/cloudstack-amd64.raw.gz.sha256"
sha256sum -c cloudstack-amd64.raw.gz.sha256

# Decompress
gunzip cloudstack-amd64.raw.gz
```

### Option B: With Custom Extensions (via Schematic)

If you need system extensions (e.g. GPU drivers, custom kernel modules, Intel/AMD microcode), create a schematic and upload it to the Image Factory:

```bash
# 1. Create schematic YAML
cat > schematic.yaml << 'EOF'
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/gvisor
      - siderolabs/intel-ucode
EOF

# 2. Upload to Image Factory — returns a content-addressable schematic ID
SCHEMATIC_ID=$(curl -s -X POST \
  --data-binary @schematic.yaml \
  https://factory.talos.dev/schematics | jq -r '.id')

echo "Schematic ID: $SCHEMATIC_ID"

# 3. Download the custom CloudStack image
curl -LO "https://factory.talos.dev/image/${SCHEMATIC_ID}/v1.8.0/cloudstack-amd64.raw.gz"

# 4. Verify and decompress
sha256sum -c cloudstack-amd64.raw.gz.sha256
gunzip cloudstack-amd64.raw.gz
```

### Option C: Direct URL Registration

If your CloudStack environment can fetch images directly from URLs, register the template using the Image Factory URL:

```
https://factory.talos.dev/image/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba/v1.8.0/cloudstack-amd64.raw.gz
```

> **Note:** CloudStack may not handle compressed images well. If the direct URL fails, download the image locally, decompress it, host it on a local web server, and register the template from there. Alternatively, try removing `.gz` from the URL to fetch an uncompressed image.

### List Available Versions

```bash
curl -s https://factory.talos.dev/versions | jq
```

### Image Factory URL Structure

```
https://factory.talos.dev/image/<schematic-id>/<version>/cloudstack-amd64.raw.gz
```

| Component | Description |
|-----------|-------------|
| `schematic-id` | Content-addressable hash of customizations. Vanilla: `376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba` |
| `version` | Talos version, e.g. `v1.8.0`, `v1.9.0` |
| `cloudstack-amd64.raw.gz` | CloudStack-specific RAW disk image (gzip compressed) |

### Build Locally with imager (Advanced)

If you need to build images entirely offline without the Image Factory service, run the `imager` container directly:

```bash
docker run --rm -v $(pwd)/_out:/out ghcr.io/siderolabs/imager:v1.8.0 \
  image --platform cloudstack --arch amd64
```

This produces the raw disk image locally using the same engine the Image Factory uses under the hood.

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

### Create the Isolated Network

Create a new isolated network using the Kubernetes network offering:

```bash
cmk create network \
  name=talosnet \
  displaytext="Talos cluster network" \
  networkofferingid=${NETWORK_OFFERING_ID} \
  zoneid=${ZONE_ID} \
  gateway=10.22.2.1 \
  netmask=255.255.255.0 \
  startip=10.22.2.2 \
  endip=10.22.2.200

export NETWORK_ID=<network-id-from-output>
```

> **Note:** The `DefaultNetworkOfferingforKubernetesService` has `egressdefaultpolicy=true`, meaning outbound traffic is allowed by default. No explicit egress firewall rules are needed.

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

### Get Service Offering IDs

```bash
cmk list serviceofferings | jq -r '.serviceoffering[] | [.id, .memory, .cpunumber, .name] | @tsv' | sort -k4
export SERVICEOFFERING_ID=<kube-control-offering-id>
export WORKER_OFFERING_ID=<kube-worker-offering-id>
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

> **⚠️ Critical: Guest CPU mode must be `host-passthrough`.** Talos requires CPU features (e.g., AMD64 v2 instruction set) that QEMU's default virtual CPU model may not expose. Without this setting, the VM will boot-loop. Set it via the `details` parameter:

```bash
cmk deploy virtualmachine \
  zoneid=${ZONE_ID} \
  templateid=${IMAGE_ID} \
  serviceofferingid=${SERVICEOFFERING_ID} \
  networkids=${NETWORK_ID} \
  name=talos-cp-1 \
  'details[0].guest.cpu.mode=host-passthrough' \
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

## Step 8: Create Port Forwarding for talosctl API

Talos uses port 50000 for its gRPC API. Create a port forwarding rule so `talosctl` can reach the control plane from outside the isolated network:

```bash
cmk create portforwardingrule \
  ipaddressid=${PUBLIC_IPADDRESS_ID} \
  privateport=50000 \
  publicport=50000 \
  protocol=tcp \
  virtualmachineid=${VM_ID} \
  openfirewall=true \
  cidrlist=0.0.0.0/0
```

> **Note:** The Talos API endpoint (`192.168.200.49:50000` in this example) is separate from the Kubernetes API endpoint (`192.168.200.49:6443`). The load balancer handles 6443; port forwarding handles 50000.

## Step 9: Bootstrap the Cluster

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

## Step 10: Retrieve kubeconfig

```bash
talosctl --talosconfig talosconfig kubeconfig .
```

## Step 11: Verify the Cluster

```bash
# Check cluster health
talosctl --talosconfig talosconfig health

# Check nodes
kubectl get nodes

# Check pods
kubectl get pods -A
```

## Step 12: CNI (Container Network Interface)

Talos ships with **Flannel** as the default CNI. You have two options:

### Option A: Use Flannel (Default — No Action Required)

Flannel is installed automatically during bootstrap. No configuration changes or manual steps needed. The cluster will have pod networking working out of the box.

If you want to verify:

```bash
kubectl get pods -n kube-system -l app=flannel
```

### Option B: Use a Different CNI (Calico, Cilium, etc.)

To use a non-default CNI, you must **disable Flannel** in the Talos config **before** deploying VMs. Edit both `controlplane.yaml` and `worker.yaml`:

```yaml
cluster:
  network:
    cni:
      name: none  # disable default Flannel
    dnsDomain: cluster.local
    podSubnets:
      - 10.244.0.0/16
    serviceSubnets:
      - 10.96.0.0/12
```

Then deploy VMs and bootstrap as normal. After bootstrap, install your chosen CNI:

#### Calico

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28/manifests/calico.yaml
```

#### Cilium

```bash
# Create namespace with privileged PodSecurity label (required for Cilium)
kubectl create ns cilium
kubectl label ns cilium pod-security.kubernetes.io/enforce=privileged --overwrite
kubectl label ns cilium pod-security.kubernetes.io/audit=privileged --overwrite
kubectl label ns cilium pod-security.kubernetes.io/warn=privileged --overwrite

# Install Cilium via Helm
helm install cilium cilium/cilium \
  --namespace cilium \
  --set ipam.mode=kubernetes \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=${PUBLIC_IPADDRESS} \
  --set k8sServicePort=6443
```

> **⚠️ PodSecurity:** Talos v1.13 ships with PodSecurity admission at `baseline` by default. Cilium requires `privileged` because it uses hostNetwork, hostPort, and privileged containers. The namespace labels above are required before Cilium pods can start.

## Step 13: Install CloudStack Kubernetes Provider (CCM)

The CloudStack external cloud controller manager is **required** for any Kubernetes cluster running on CloudStack. It provides:

- `LoadBalancer` service type support via CloudStack load balancer rules
- Node metadata labels (zone, region, instance type)
- Firewall rule management for NodePort services

```bash
# See setup/cloudstack-kubernetes-provider.md for detailed configuration
kubectl apply -f https://raw.githubusercontent.com/apache/cloudstack-kubernetes-provider/main/deployment.yaml
```

> **Note:** Unlike CKS which auto-deploys the CCM, Talos requires manual installation. The CCM must be configured with your CloudStack API credentials (api-url, api-key, secret-key).

## Step 14: Install CloudStack CSI Driver

The CloudStack CSI driver is **required** for persistent storage on CloudStack. It provides:

- Dynamic provisioning of CloudStack volumes via StorageClasses
- Volume lifecycle management (create, attach, detach, delete)
- Volume snapshots and cloning

### Create cloud-config

```ini
[Global]
api-url = <CloudStack API URL>
api-key = <CloudStack API Key>
secret-key = <CloudStack API Secret>
zone = <CloudStack Zone Name>
ssl-no-verify = true
```

### Create Kubernetes Secret

If you already deployed the CCM, you can reuse the same `cloudstack-secret` in `kube-system`. Otherwise:

```bash
kubectl -n kube-system create secret generic cloudstack-secret --from-file=cloud-config
```

### Install via Helm

The CSI chart can reuse the existing `cloudstack-secret` that the CCM already created. No need to pass API keys again:

```bash
helm install cloudstack-csi https://github.com/cloudstack/cloudstack-csi-driver/releases/download/cloudstack-csi-3.0.1/cloudstack-csi-3.0.1.tgz \
  --namespace kube-system \
  --set secret.create=false \
  --set secret.name=cloudstack-secret
```

> **Note:** `secret.create=false` and `secret.name=cloudstack-secret` are the chart defaults, so the above is equivalent to just `helm install ... --namespace kube-system`. The chart will use the same secret that the CCM created in the previous step.

### ⚠️ Critical: Fix CSI Mount Path on Talos Immutable Root

Talos Linux uses an **immutable root filesystem** — directories like `/run/metadata` do not exist at runtime. The CSI node DaemonSet includes a hostPath volume for `ignition-dir` that references `/run/metadata`, which causes the pod to fail with:

```
MountVolume.SetUp failed for volume "ignition-dir" : hostPath type check failed: /run/metadata is not a directory
```

> **Why this happens:** The `ignition-dir` volume is a **legacy remnant** from the CSI driver's CoreOS/Ignition origins. On CoreOS, `/run/metadata` is populated by Ignition at boot and contains metadata the CSI driver uses. Talos has no Ignition system and no `/run/metadata` — the CSI driver doesn't actually need it because it reads metadata from the CloudStack API directly. The volume is vestigial.

**Fix:** Patch the DaemonSet to replace the hostPath volume with an `emptyDir`:

```bash
kubectl patch daemonset -n kube-system cloudstack-csi-node --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/volumes/5", "value": {"name": "ignition-dir", "emptyDir": {}}}
]'
```

Then delete the existing pods to restart them with the fix:

```bash
kubectl delete pods -n kube-system -l app=cloudstack-csi-node
```

> **Note:** The volume index (`5` in the path above) may vary by CSI driver version. To find the correct index:
> ```bash
> kubectl get daemonset -n kube-system cloudstack-csi-node -o yaml | grep -n 'ignition-dir'
> ```

### Verify

```bash
kubectl get pods -n kube-system -l app=cloudstack-csi
kubectl get sc
```

## Adding Worker Nodes

### Generate Worker Configuration

If you didn't generate `worker.yaml` earlier, or need to regenerate it:

```bash
talosctl gen config talos-cloudstack https://${PUBLIC_IPADDRESS}:6443 \
  --with-docs=false --with-examples=false
```

### Deploy Worker VM

Use the **worker-specific compute offering** (e.g., `kube worker1`) and apply the same `guest.cpu.mode=host-passthrough` setting:

```bash
# Get the worker offering ID
cmk list serviceofferings | jq -r '.serviceoffering[] | select(.name | test("kube worker")) | [.id, .name] | @tsv'
export WORKER_OFFERING_ID=<kube-worker-offering-id>

cmk deploy virtualmachine \
  zoneid=${ZONE_ID} \
  templateid=${IMAGE_ID} \
  serviceofferingid=${WORKER_OFFERING_ID} \
  networkids=${NETWORK_ID} \
  name=talos-worker-1 \
  'details[0].guest.cpu.mode=host-passthrough' \
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

Talos upgrades are image-based and atomic. The upgrade replaces the installer image on each node and reboots into the new version.

### Standard Upgrade (Online)

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

### Air-Gapped Upgrade

In an air-gapped environment, nodes cannot reach `ghcr.io` or `factory.talos.dev`. There are three approaches:

#### Option 1: Local Container Registry (Recommended)

Set up a local registry (Harbor, Nexus, or plain Docker registry) accessible from the Talos nodes.

**On an internet-connected machine:**
```bash
docker pull ghcr.io/siderolabs/installer:v1.14.0
docker tag ghcr.io/siderolabs/installer:v1.14.0 registry.internal:5000/siderolabs/installer:v1.14.0
docker push registry.internal:5000/siderolabs/installer:v1.14.0
```

**On the air-gapped management machine:**
```bash
talosctl --talosconfig talosconfig -n <node> upgrade \
  --image registry.internal:5000/siderolabs/installer:v1.14.0
```

#### Option 2: Pre-Pull Image Tarball

If you can transfer files to the Talos nodes:

**On an internet-connected machine:**
```bash
docker pull ghcr.io/siderolabs/installer:v1.14.0
docker save ghcr.io/siderolabs/installer:v1.14.0 | gzip > talos-installer-v1.14.0.tar.gz
```

**Transfer the tarball to a Talos node and import:**
```bash
scp talos-installer-v1.14.0.tar.gz <node-ip>:/tmp/
talosctl -n <node> image pull /tmp/talos-installer-v1.14.0.tar.gz
```

**Then upgrade — the image is already cached locally:**
```bash
talosctl --talosconfig talosconfig -n <node> upgrade \
  --image ghcr.io/siderolabs/installer:v1.14.0
```

#### Option 3: Registry Mirror in Talos Machine Config (Best for Ongoing)

For long-term air-gapped operations, configure Talos to use a registry mirror at bootstrap time. Add this to both `controlplane.yaml` and `worker.yaml` **before** deploying VMs:

```yaml
machine:
  registries:
    mirrors:
      ghcr.io:
        endpoints:
          - https://registry.internal:5000
      registry-1.docker.io:
        endpoints:
          - https://registry.internal:5000
```

Then all image pulls (including the installer during upgrade) resolve through your local registry. No special upgrade commands needed — just:

```bash
talosctl --talosconfig talosconfig upgrade \
  --image ghcr.io/siderolabs/installer:v1.14.0
```

The node pulls the image from the local mirror automatically.

#### Summary

| Method | Setup effort | Ongoing ease |
|--------|-------------|-------------|
| Local registry + mirror config | Medium (registry setup + config change) | ✅ Easiest — just `talosctl upgrade` |
| Local registry (no mirror) | Medium (registry setup) | ✅ Easy — just change `--image` URL |
| Pre-pull tarball per node | Low (one-time scp) | ❌ Tedious per-node per-upgrade |

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

### Bootstrap fails with "time is not in sync yet"

Talos requires accurate time before etcd can bootstrap. If the VM cannot reach NTP servers (e.g., in an isolated network without internet access):

```bash
# Check NTP status
talosctl --talosconfig talosconfig time

# Add an egress firewall rule for NTP (UDP 123)
cmk create egressfirewallrule networkid=${NETWORK_ID} protocol=udp startport=123 endport=123 cidrlist=0.0.0.0/0

# Wait ~30 seconds for NTP sync, then retry bootstrap
talosctl --talosconfig talosconfig bootstrap
```

> **Note:** The `DefaultNetworkOfferingforKubernetesService` has `egressdefaultpolicy=true`, so NTP should work without explicit rules. If using a different network offering (e.g., `DefaultIsolatedNetworkOfferingWithSourceNatService` which has `egressdefaultpolicy=false`), you **must** add the NTP rule above, plus rules for DNS (UDP 53), HTTP/HTTPS (TCP 80, 443), and any other outbound traffic the cluster needs.

### CSI node pod fails with "ignition-dir" mount error

```
MountVolume.SetUp failed for volume "ignition-dir" : hostPath type check failed: /run/metadata is not a directory
```

This is a **legacy remnant** from the CSI driver's CoreOS/Ignition origins — Talos has no `/run/metadata` and the CSI driver doesn't actually need it. See [Step 14](#step-14-install-cloudstack-csi-driver) for the fix and explanation.

## References

- [Talos CloudStack Platform Guide](https://docs.siderolabs.com/talos/v1.13/platform-specific-installations/cloud-platforms/cloudstack) — official Sidero documentation
- [Talos Architecture](../architecture/talos.md) — detailed architecture overview
- [Image Factory](https://factory.talos.dev) — download Talos images
- [talosctl Reference](https://www.talos.dev/v1.13/reference/cli/)
- [Talos GitHub](https://github.com/siderolabs/talos)
