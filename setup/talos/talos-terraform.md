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

## Step 2: Two-Phase Terraform Apply

Terraform needs to know the public IP to generate Talos configs, but the IP is created by Terraform. This creates a circular dependency. The solution is a **two-phase apply**:

### Phase 1: Create Network + IP

```bash
cd setup/talos/manifests/terraform

# Set CloudStack API credentials
export CLOUDSTACK_API_URL=http://192.168.200.1:8080/client/api
export CLOUDSTACK_API_KEY=your-api-key
export CLOUDSTACK_SECRET_KEY=your-secret-key

terraform init
terraform apply -target=cloudstack_network.talos -target=cloudstack_ipaddress.talos
```

Note the public IP from the output:

```bash
terraform output public_ip   # e.g., 192.168.200.49
```

### Phase 2: Generate Configs + Apply Everything

```bash
# Generate Talos configs with the real IP
talosctl gen config <cluster-name> https://$(terraform output -raw public_ip):6443 \
  --with-docs=false --with-examples=false --force

# Base64-encode for Terraform
export CP_USERDATA=$(base64 controlplane.yaml | tr -d '\n')
export WORKER_USERDATA=$(base64 worker.yaml | tr -d '\n')
```

Edit `terraform.tfvars` with your resource IDs and the base64-encoded userdata:

```hcl
zone_id                    = "<zone-uuid>"
template_id                = "<talos-template-uuid>"
network_offering_id        = "<kubernetes-offering-uuid>"
control_plane_offering_id  = "<kube-control-uuid>"
worker_offering_id         = "<kube-worker-uuid>"
control_plane_userdata     = "<base64-controlplane.yaml>"
worker_userdata            = "<base64-worker.yaml>"
cluster_name               = "<cluster-name>"
control_plane_count        = 1
worker_count               = 1
```

Then apply the rest:

```bash
terraform apply
```

This creates: VMs, load balancer rule, port forwarding, and firewall rules.

## Step 3: Bootstrap the Cluster

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

```bash
helm install cloudstack-csi https://github.com/cloudstack/cloudstack-csi-driver/releases/download/cloudstack-csi-3.0.1/cloudstack-csi-3.0.1.tgz \
  --namespace kube-system \
  --set secret.create=false \
  --set secret.name=cloudstack-secret

# ⚠️ Fix ignition-dir for Talos immutable root
kubectl patch daemonset -n kube-system cloudstack-csi-node --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/volumes/5", "value": {"name": "ignition-dir", "emptyDir": {}}}
]'
kubectl delete pods -n kube-system -l app=cloudstack-csi-node
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

### CSI `ignition-dir` on Talos Immutable Root

Talos Linux has an immutable root filesystem — `/run/metadata` does not exist. The CSI node DaemonSet includes a `hostPath` volume for `ignition-dir` that references `/run/metadata`, causing pods to fail with:

```
MountVolume.SetUp failed for volume "ignition-dir" : hostPath type check failed: /run/metadata is not a directory
```

**Fix:** Patch the DaemonSet to replace `hostPath` with `emptyDir`:

```bash
kubectl patch daemonset -n kube-system cloudstack-csi-node --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/volumes/5", "value": {"name": "ignition-dir", "emptyDir": {}}}
]'
kubectl delete pods -n kube-system -l app=cloudstack-csi-node
```

The volume index (`5` in the path above) may vary by CSI driver version. To find the correct index:

```bash
kubectl get daemonset -n kube-system cloudstack-csi-node -o yaml | grep -n 'ignition-dir'
```

### Firewall Rules

The `cloudstack_loadbalancer_rule` and `cloudstack_port_forward` resources in provider v0.6.0 do **not** auto-create firewall rules, even with `cidrlist` set. You must create separate `cloudstack_firewall` resources for each port.

### Config Generation Ordering

The Talos configs must be generated **after** the public IP is known but **before** the VMs are deployed. This is why a two-phase apply is required. There is no way to do this in a single `terraform apply` because `talosctl gen config` is not a Terraform resource.
