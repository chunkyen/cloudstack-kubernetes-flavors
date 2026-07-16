# Terraform: One-Shot Talos Cluster on CloudStack

This guide shows how to deploy a complete Talos Kubernetes cluster on CloudStack using **Terraform** — network, public IP, load balancer, port forwarding, firewall rules, and all VMs in a single `terraform apply`.

## Prerequisites

| Tool | Purpose | Install |
|------|---------|---------|
| **Terraform** | Infrastructure as Code | See below |
| **talosctl** | Talos management CLI | [Install guide](https://docs.siderolabs.com/talos/v1.13/getting-started/talosctl) |
| **CloudStack API credentials** | API key + secret | CloudStack UI → Accounts → API Keys |

## Terraform Setup

### Install Terraform

```bash
# Linux (amd64) — download the latest binary
wget https://releases.hashicorp.com/terraform/1.11.3/terraform_1.11.3_linux_amd64.zip
unzip terraform_1.11.3_linux_amd64.zip
sudo mv terraform /usr/local/bin/
rm terraform_1.11.3_linux_amd64.zip

# Verify
terraform --version
```

> For other platforms, see [terraform.io/downloads](https://www.terraform.io/downloads).

### Get CloudStack API Credentials

1. Log in to the CloudStack UI
2. Go to **Accounts** → find your account → **API Keys**
3. Click **Generate API Key** (or copy existing ones)
4. You'll get an **API Key** and **Secret Key**

Also note your **CloudStack API URL**. This is typically:

```
http://<management-server-ip>:8080/client/api
```

### Set Environment Variables

The Terraform provider reads credentials from environment variables. Set them before running any `terraform` command:

```bash
export CLOUDSTACK_API_URL=http://192.168.200.1:8080/client/api
export CLOUDSTACK_API_KEY=your-api-key
export CLOUDSTACK_SECRET_KEY=your-secret-key
```

> **Security tip:** Add these to a `.env` file or your shell profile so you don't have to type them every time. Never commit them to version control.

### Initialize the Working Directory

```bash
cd setup/talos/manifests/terraform
terraform init
```

This downloads the `cloudstack/cloudstack` provider plugin. Run this once per working directory.

## Provider: `cloudstack/cloudstack` v0.6.0

The Terraform provider for CloudStack is published at `cloudstack/cloudstack` (not `apache/cloudstack`). The latest version is **0.6.0**. Key differences from the older `apache/cloudstack` provider:

- Resource names use `cloudstack_loadbalancer_rule` (not `cloudstack_lb_rule`)
- No separate `cloudstack_lb_rule_member` — members are set via `member_ids` on the rule itself
- Port forwarding uses a nested `forward { ... }` block, not flat arguments
- Firewall rules use a nested `rule { ... }` block with `ports` as a set of strings
- Network uses `zone` (not `zone_id`), `network_offering` (not `network_offering_id`)
- Instance uses `zone` (not `zone_id`), `service_offering` (not `service_offering_id`)
- No `openfirewall` parameter — firewall rules must be created as separate `cloudstack_firewall` resources

## Step 1: Gather CloudStack Resource IDs

```bash
# Zone
cmk list zones | jq -r '.zone[] | [.id, .name] | @tsv'
export ZONE_ID=<zone-uuid>

# Talos template
cmk list templates templatefilter=self | jq -r '.template[] | [.id, .name] | @tsv'
export TEMPLATE_ID=<talos-template-uuid>

# Network offering (must be Kubernetes service offering)
cmk list networkofferings | jq -r '.networkoffering[] | select(.name | test("KubernetesService")) | [.id, .name] | @tsv'
export NETWORK_OFFERING_ID=<kubernetes-offering-uuid>

# Service offerings
cmk list serviceofferings | jq -r '.serviceoffering[] | [.id, .memory, .cpunumber, .name] | @tsv' | sort -k4
export CP_OFFERING_ID=<kube-control-uuid>
export WORKER_OFFERING_ID=<kube-worker-uuid>
```

## Step 2: Pre-Allocate a Public IP

Terraform needs to know the public IP to generate Talos configs, but the IP is created by Terraform. The simplest solution is to **pre-allocate a free IP** with `cmk` first, then pass its ID to Terraform. This avoids the circular dependency and keeps it a single `terraform apply`.

```bash
# Find a free public IP
cmk list publicipaddresses zoneid=${ZONE_ID} state=free forvirtualnetwork=true | \
  jq -r '.publicipaddress[] | [.id, .ipaddress] | @tsv' | sort -k2

# Pick one and note its IP address
export PUBLIC_IP=<ip-address>
export PUBLIC_IP_ID=<ip-id>
```

## Step 3: Generate Talos Configs

```bash
talosctl gen config <cluster-name> https://${PUBLIC_IP}:6443 \
  --with-docs=false --with-examples=false --force
```

### Base64-encode for Terraform

```bash
export CP_USERDATA=$(base64 controlplane.yaml | tr -d '\n')
export WORKER_USERDATA=$(base64 worker.yaml | tr -d '\n')
```

## Step 4: Configure Terraform

```bash
cd setup/talos/manifests/terraform

# Copy the example vars file
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with your resource IDs, the base64-encoded userdata, and the pre-allocated IP:

```hcl
zone_id                    = "<zone-uuid>"
template_id                = "<talos-template-uuid>"
network_offering_id        = "<kubernetes-offering-uuid>"
control_plane_offering_id  = "<kube-control-uuid>"
worker_offering_id         = "<kube-worker-uuid>"
control_plane_userdata     = "<base64-controlplane.yaml>"
worker_userdata            = "<base64-worker.yaml>"
cluster_name               = "<cluster-name>"
public_ip_id               = "<pre-allocated-ip-id>"
```

Set CloudStack API credentials as environment variables:

```bash
export CLOUDSTACK_API_URL=http://192.168.200.1:8080/client/api
export CLOUDSTACK_API_KEY=your-api-key
export CLOUDSTACK_SECRET_KEY=your-secret-key
```

## Step 5: Deploy (Single Apply)

```bash
terraform init
terraform plan   # review what will be created
terraform apply  # type "yes" to confirm
```

This single command creates: network, load balancer, port forwarding, firewall rules, control plane VM, and worker VM — all in one shot.

After apply completes, note the outputs:

```bash
terraform output public_ip          # e.g., 192.168.200.49
terraform output control_plane_ips  # e.g., ["10.22.2.182"]
terraform output worker_ips         # e.g., ["10.22.2.40"]
terraform output k8s_api_endpoint   # e.g., 192.168.200.49:6443
```

## Step 6: Bootstrap the Cluster

```bash
# Configure talosctl
talosctl --talosconfig talosconfig config endpoint $(terraform output -raw public_ip)
talosctl --talosconfig talosconfig config node $(terraform output -json control_plane_ips | jq -r '.[0]')

# Bootstrap etcd
talosctl --talosconfig talosconfig bootstrap

# Wait for bootstrap to complete, then get kubeconfig
talosctl --talosconfig talosconfig kubeconfig .
```

## Step 4: Install Addons

### CNI

Talos ships with **Flannel** as the default CNI. No action needed — it installs automatically during bootstrap.

If you want a different CNI (Cilium, Calico), you must disable Flannel **before** deploying VMs by adding `cni: name: none` to both `controlplane.yaml` and `worker.yaml`, then install your CNI post-bootstrap.

### CCM (CloudStack Kubernetes Provider)

```bash
kubectl -n kube-system create secret generic cloudstack-secret \
  --from-literal=cloud-config="[Global]\napi-url=${CLOUDSTACK_API_URL}\napi-key=${CLOUDSTACK_API_KEY}\nsecret-key=${CLOUDSTACK_SECRET_KEY}\nzone=cyz1\nssl-no-verify=true"

kubectl apply -f https://raw.githubusercontent.com/apache/cloudstack-kubernetes-provider/main/deployment.yaml
```

### CSI Driver

Use the raw manifest (same approach as CKS/CAPC) — this includes the VolumeSnapshot CRDs and controller that the Helm chart skips. The secret was already created in the CCM step above:

```bash
# Deploy the CSI driver (includes snapshot CRDs + controller)
kubectl apply -f https://github.com/cloudstack/cloudstack-csi-driver/releases/latest/download/manifest.yaml

# ⚠️ Apply the Talos-patched node DaemonSet (replaces hostPath with emptyDir
#    for cloud-init-dir — Talos immutable root doesn't have /run/cloud-init/)
kubectl apply -f manifests/csi-node-daemonset-talos.yaml
```

### StorageClass

```bash
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: cloudstack-ssd
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: csi.cloudstack.apache.org
parameters:
  csi.cloudstack.apache.org/disk-offering-id: "<custom-disk-offering-uuid>"
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
allowVolumeExpansion: true
EOF
```

## What Terraform Creates

| Resource | Count | Purpose |
|----------|-------|---------|
| `cloudstack_network` | 1 | Isolated network with Kubernetes offering |
| `cloudstack_ipaddress` | 1 | Public IP for API endpoints |
| `cloudstack_loadbalancer_rule` | 1 | Load balancer for K8s API (6443) with `cidrlist` |
| `cloudstack_port_forward` | N | Port forwarding for talosctl (50000+) |
| `cloudstack_firewall` | 2 | Firewall rules for 6443 and 50000 |
| `cloudstack_instance` (CP) | N | Control plane VMs with `host-passthrough` |
| `cloudstack_instance` (worker) | N | Worker VMs with `host-passthrough` |

## What Terraform Does NOT Do

- **Generate Talos configs** — `talosctl gen config` must be run between Phase 1 and Phase 2
- **Bootstrap etcd** — `talosctl bootstrap` is manual
- **Install CNI, CCM, CSI** — these are post-bootstrap steps
- **Create the Talos template** — the image must already exist in CloudStack
- **Patch CSI ignition-dir** — the DaemonSet patch is still manual (Talos immutable root issue)

## Multi-Node Clusters

For a 3 control plane + 2 worker cluster:

```hcl
control_plane_count = 3
worker_count        = 2
```

Terraform will create 3 CP VMs, assign all 3 to the load balancer, and create port forwarding rules on ports 50000, 50001, 50002 for talosctl access to each CP node.

## Cleanup

```bash
terraform destroy
```

This removes all VMs, the load balancer, port forwarding rules, firewall rules, the public IP, and the network — everything Terraform created.

## Known Issues & Workarounds

### CSI `cloud-init-dir` on Talos Immutable Root

Talos Linux has an immutable root filesystem — directories like `/run/cloud-init/` do not exist. The upstream CSI node DaemonSet includes a `hostPath` volume for `cloud-init-dir` that references `/run/cloud-init/`, causing pods to fail with:

```
MountVolume.SetUp failed for volume "cloud-init-dir" : hostPath type check failed: /run/cloud-init/ is not a directory
```

> **Why this happens:** The `cloud-init-dir` volume is a **legacy remnant** from the CSI driver's cloud-init origins. On Ubuntu/CoreOS, `/run/cloud-init/` is populated by cloud-init at boot and contains metadata the CSI driver uses. Talos has no cloud-init system and no `/run/cloud-init/` — the CSI driver doesn't actually need it because it reads metadata from the CloudStack API directly. The volume is vestigial.

**Fix:** A pre-patched DaemonSet manifest is included in this repo at `manifests/csi-node-daemonset-talos.yaml`. Apply it after the upstream manifest:

```bash
kubectl apply -f manifests/csi-node-daemonset-talos.yaml
```

This replaces the `hostPath` volumes with `emptyDir` so the pods start on Talos without errors.

### Firewall Rules

The `cloudstack_loadbalancer_rule` and `cloudstack_port_forward` resources in provider v0.6.0 do **not** auto-create firewall rules, even with `cidrlist` set. You must create separate `cloudstack_firewall` resources for each port.

### Config Generation Ordering

The Talos configs must be generated **before** `terraform apply` because the VMs need the configs embedded as userdata. Pre-allocating a free IP with `cmk` solves this — you know the IP upfront, generate configs, then a single `terraform apply` creates everything.

## Scaling the Cluster

### Add Workers (Simple)

```hcl
# terraform.tfvars
worker_count = 3  # was 1
```

```bash
terraform apply
```

Terraform creates new VMs with the existing `worker.yaml` config. The bootstrap token in that config is valid indefinitely, so new nodes join the cluster automatically. No manual steps needed.

### Add Control Plane Nodes (Requires etcd Recovery)

```hcl
# terraform.tfvars
control_plane_count = 3  # was 1
```

```bash
terraform apply
```

Terraform creates new CP VMs and adds them to the load balancer automatically — `member_ids = cloudstack_instance.control_plane[*].id` ensures all CP nodes are behind the single LB rule on port 6443. Port forwarding for talosctl (50000+) also scales automatically via `count = var.control_plane_count`.

However, etcd membership is **not** managed by Terraform. After apply, join the new CP nodes to the existing etcd cluster:

```bash
# Get the existing CP node IP
export EXISTING_CP=<existing-cp-ip>

# Join each new CP node to etcd
talosctl --talosconfig talosconfig -n <new-cp-ip> bootstrap --recover-from=${EXISTING_CP}
```

> **Note:** For production multi-CP clusters, generate the initial configs with `--with-secrets` and save the secrets file. When scaling CP nodes later, regenerate configs using the same secrets so all nodes share the same etcd identity:
> ```bash
> talosctl gen config <cluster> https://<ip>:6443 \
>   --with-secrets=secrets.yaml \
>   --with-docs=false --with-examples=false --force
> ```

### Remove Nodes

Terraform can destroy the VM, but you must drain and remove the node from Kubernetes first:

```bash
# Before terraform apply
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
kubectl delete node <node>
talosctl --talosconfig talosconfig -n <node> reset

# Then reduce count and apply
terraform apply
```

Terraform destroys the VM, but the Kubernetes node object and etcd member are already cleaned up.

## Upgrading Talos

Terraform **cannot** perform in-place upgrades — the Talos version is baked into the template/image at deploy time. Use `talosctl upgrade` instead.

See the [Upgrading Talos section in talos.md](talos.md#upgrading-talos) for the full guide, including standard online upgrades and air-gapped options (local registry, pre-pull tarball, registry mirror).

In short:

```bash
# Upgrade each node in place
talosctl --talosconfig talosconfig -n <node> upgrade \
  --image ghcr.io/siderolabs/installer:v1.14.0
```

Terraform state stays unchanged. No infrastructure changes needed.

### Summary

| Operation | Terraform handles | Manual steps needed |
|-----------|------------------|---------------------|
| Add workers | ✅ VM creation | None (auto-joins) |
| Add CP nodes | ✅ VM creation + LB | `talosctl bootstrap --recover-from` for etcd |
| Remove nodes | ✅ VM destruction | `kubectl drain/delete`, `talosctl reset` first |
| Upgrade Talos | ❌ | `talosctl upgrade` per node |
