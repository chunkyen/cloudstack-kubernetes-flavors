# Terraform: One-Shot Talos Cluster on CloudStack

This guide shows how to deploy a complete Talos Kubernetes cluster on CloudStack using **Terraform** — network, public IP, load balancer, port forwarding, and all VMs in a single `terraform apply`.

## Prerequisites

| Tool | Purpose | Install |
|------|---------|---------|
| **Terraform** | Infrastructure as Code | [terraform.io/downloads](https://www.terraform.io/downloads) |
| **talosctl** | Talos management CLI | [Install guide](https://docs.siderolabs.com/talos/v1.13/getting-started/talosctl) |
| **CloudStack API credentials** | API key + secret | CloudStack UI → Accounts → API Keys |

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

## Step 2: Generate Talos Configs

```bash
# Use the public IP that will be allocated (or a placeholder — you'll update later)
export PUBLIC_IP="10.22.2.1"  # placeholder, will be replaced after apply

talosctl gen config talos-cluster https://${PUBLIC_IP}:6443 \
  --with-docs=false --with-examples=false --force
```

### Disable Default CNI

Edit both `controlplane.yaml` and `worker.yaml` to add `cni: name: none`:

```yaml
cluster:
  network:
    cni:
      name: none  # <-- add this line
    dnsDomain: cluster.local
    podSubnets:
      - 10.244.0.0/16
    serviceSubnets:
      - 10.96.0.0/12
```

### Base64-encode for Terraform

```bash
export CP_USERDATA=$(base64 controlplane.yaml | tr -d '\n')
export WORKER_USERDATA=$(base64 worker.yaml | tr -d '\n')
```

## Step 3: Configure Terraform

```bash
cd setup/talos/manifests/terraform

# Copy the example vars file
cp terraform.tfvars.example terraform.tfvars
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
```

Set CloudStack API credentials as environment variables:

```bash
export CLOUDSTACK_API_URL=http://192.168.200.1:8080/client/api
export CLOUDSTACK_API_KEY=your-api-key
export CLOUDSTACK_SECRET_KEY=your-secret-key
```

## Step 4: Deploy

```bash
terraform init
terraform plan   # review what will be created
terraform apply  # type "yes" to confirm
```

After apply completes, note the outputs:

```bash
terraform output public_ip          # e.g., 192.168.200.49
terraform output control_plane_ips # e.g., ["10.22.2.197"]
terraform output worker_ips        # e.g., ["10.22.2.52"]
terraform output k8s_api_endpoint  # e.g., 192.168.200.49:6443
terraform output talos_api_endpoints # e.g., ["192.168.200.49:50000"]
```

## Step 5: Bootstrap the Cluster

```bash
# Configure talosctl
talosctl --talosconfig talosconfig config endpoint $(terraform output -raw public_ip)
talosctl --talosconfig talosconfig config node $(terraform output -json control_plane_ips | jq -r '.[0]')

# Bootstrap etcd
talosctl --talosconfig talosconfig bootstrap

# Wait for bootstrap to complete, then get kubeconfig
talosctl --talosconfig talosconfig kubeconfig .
```

## Step 6: Install Addons

### CNI (Cilium)

```bash
kubectl create ns cilium
kubectl label ns cilium pod-security.kubernetes.io/enforce=privileged --overwrite

helm install cilium cilium/cilium \
  --namespace cilium \
  --set ipam.mode=kubernetes \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=$(terraform output -raw public_ip) \
  --set k8sServicePort=6443
```

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

## What Terraform Creates

| Resource | Count | Purpose |
|----------|-------|---------|
| `cloudstack_network` | 1 | Isolated network with Kubernetes offering |
| `cloudstack_ipaddress` | 1 | Public IP for API endpoints |
| `cloudstack_lb_rule` | 1 | Load balancer for K8s API (6443) |
| `cloudstack_lb_rule_member` | N | Assigns CP VMs to the load balancer |
| `cloudstack_port_forward` | N | Port forwarding for talosctl (50000+) |
| `cloudstack_instance` (CP) | N | Control plane VMs with `host-passthrough` |
| `cloudstack_instance` (worker) | N | Worker VMs with `host-passthrough` |

## What Terraform Does NOT Do

- **Generate Talos configs** — `talosctl gen config` must be run first
- **Bootstrap etcd** — `talosctl bootstrap` is manual
- **Install CNI, CCM, CSI** — these are post-bootstrap steps
- **Create the Talos template** — the image must already exist in CloudStack

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

This removes all VMs, the load balancer, port forwarding rules, the public IP, and the network — everything Terraform created.
