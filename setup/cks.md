# CKS Setup Guide

## Prerequisites

- Apache CloudStack management server (ACS 4.14+ for basic CKS, 4.21+ for flexible features)
- At least one CloudStack zone with hosts (KVM recommended)
- Root admin access to CloudStack
- Network connectivity from management server to zone

## Step 1: Enable CKS Plugin

### Via CloudStack UI
1. Go to **Account & Domains** → **Global Settings**
2. Search for `cloud.kubernetes.service.enabled`
3. Set to `true`
4. Search for `endpoint.url`
5. Set to `http://<management-server-ip>:8080/client/api`
6. **Restart management server:**
   ```bash
   service cloudstack-management restart
   ```

### Via API
```bash
updateGlobalConfiguration name=cloud.kubernetes.service.enabled value=true
updateGlobalConfiguration name=endpoint.url value=http://<mgmt-server>:8080/client/api
```

After restart, the **Kubernetes** tab appears under **Compute** in the UI.

## Step 2: Register Network Offering

Ensure a default network offering is configured:
1. Go to **Network** → **Network Offerings**
2. Verify `DefaultNetworkOfferingforKubernetesService` exists (from ACS 4.14)
3. Set it as default:
   - Global setting: `cloud.kubernetes.cluster.network.offering`
   - Value: `DefaultNetworkOfferingforKubernetesService`

## Step 3: Register Kubernetes Binaries ISO

### Pre-built ISOs

Download from:
- [`download.cloudstack.org/cks/`](http://download.cloudstack.org/cks/)
- [`packages.shapeblue.com/cks/`](http://packages.shapeblue.com/cks/)

Register in CloudStack: **Storage** → **ISOs** → **Register ISO**

### Custom ISO Builds

For custom ISO builds (Calico or Cilium), see the dedicated guide:

- [**CKS Custom ISO Build Guide**](cks-custom-iso.md)

### Register the ISO as a Supported K8s Version

After building or downloading an ISO, register it:

**Via UI:** **Infrastructure** → **Kubernetes** → **Supported Versions** → **Add Kubernetes Supported Version**

**Via API:**
```bash
addKubernetesSupportedVersion \
  name=v1.33.1 \
  semanticversion=1.33.1 \
  url=http://<server>/setup-v1.33.1.iso \
  zoneid=<zone-id> \
  mincpunumber=2 \
  minmemory=2048 \
  checksum=<iso-checksum>
```

## Step 4: (Optional) Register CKS-Compatible Templates

From ACS 4.21+, you can register custom templates for CKS:

1. **Compute** → **Templates** → **Register Template**
2. Fill in template details
3. **Check the "For CKS" option**
4. Register (base image should have prerequisites installed)

**Prerequisites for CKS templates:**
- Minimum: 8GB root disk, 2 CPU, 2GB RAM
- SSH public key of `cloud` user at `~/.ssh/authorized_keys`
- Pre-installed packages (see [official docs](http://docs.cloudstack.apache.org/en/latest/plugins/cloudstack-kubernetes-service.html))

## Step 5: Create a Kubernetes Cluster

### Basic Cluster (Default Settings)

Via UI:
1. **Compute** → **Kubernetes** → **Add Kubernetes Cluster**
2. Fill in:
   - **Name:** `my-cks-cluster`
   - **Domain:** (select domain)
   - **Zone:** Select zone
   - **Network:** Select network (or use default)
   - **Kubernetes Version:** Select from registered versions
   - **Control Nodes:** `1` (or `3` for HA)
   - **Worker Nodes:** `2` (or more)
   - **Etcd Nodes:** `0` (or ≥1 for dedicated etcd)
3. Click **Create**

Via API:
```bash
createKubernetesCluster \
  name=my-cks-cluster \
  domainid=<domain-id> \
  zoneid=<zone-id> \
  networkid=<network-id> \
  kubernetesversionid=<version-id> \
  controlnodes=3 \
  workernodes=2 \
  etcdnodes=0
```

## Step 6: Advanced Settings (ACS 4.21+)

From CloudStack 4.21+, the cluster creation form includes an **Advanced Settings** toggle that unlocks granular control over each node type. This enables heterogeneous clusters where control, worker, and etcd nodes can use different templates, service offerings, and even hypervisor types.

#### When to Use Advanced Settings

| Use Case | Why Advanced Settings |
|----------|----------------------|
| **Production HA** | Control nodes need more RAM/CPU than workers; dedicated etcd nodes for performance |
| **Dedicated etcd** | Separate etcd from control plane for fault isolation and I/O performance |
| **GPU workloads** | Workers on GPU-enabled templates/service offerings, control plane on standard |
| **Hypervisor affinity** | Deploy nodes only on specific hypervisor types (e.g., KVM only, no VMware) |
| **Custom base images** | Pre-bake control nodes with monitoring agents, workers with runtime tools |
| **Persistent storage** | Enable CloudStack CSI Driver for dynamic provisioning and volume snapshots |


#### Advanced Settings Breakdown

##### 1. Hypervisor Type Selection
- **What:** Restricts node deployment to a specific hypervisor (KVM, VMware, etc.)
- **Why:** Ensures consistent performance, enables hypervisor-specific features (e.g., GPU passthrough)
- **Effect:** CloudStack only provisions CKS nodes on hosts matching the selected hypervisor

##### 2. Control Node Template & Service Offering
- **Template:** CKS-marked template for control plane nodes (e.g., with pre-installed monitoring agents)
- **Service Offering:** CPU/RAM profile for control nodes (e.g., 4 CPU / 8 GB RAM)
- **Default:** Uses the last registered SystemVM template with the global K8s service offering
- **Note:** Registering custom templates is optional — only needed if you want templates per node type. See [Step 4](#step-4-optional-register-cks-compatible-templates) for details.

##### 3. Worker Node Template & Service Offering
- **Template:** CKS-marked template for worker nodes (e.g., GPU-enabled, or with specific runtime tools)
- **Service Offering:** CPU/RAM profile for workers (e.g., 8 CPU / 16 GB RAM for compute-heavy workloads)
- **Default:** Uses the last registered SystemVM template with the global K8s service offering

##### 4. Etcd Node Template & Service Offering (dedicated etcd)
- **When:** Set `etcdnodes ≥ 1` during cluster creation
- **Template:** CKS-marked template — **must be from an ISO built with etcd binaries** (use the `ETCD_VERSION` parameter in `create-kubernetes-binaries-iso.sh`)
- **Service Offering:** CPU/RAM profile for etcd nodes (e.g., 2 CPU / 4 GB RAM with fast disk)
- **Why:** Separating etcd from the control plane improves fault isolation and etcd performance
- **Available ISOs:** `https://download.cloudstack.org/testing/cks/custom_templates/iso-etcd/`

##### 5. CNI Configuration Selection
- **What:** Pre-registered CNI user-data configuration (from 4.21+)
- **How to register:** **Instances** → **CNI Configuration** → **Add CNI Configuration**
- **Why:** Allows dynamic CNI parameter injection without rebuilding ISOs
- **Alternative:** Build ISO with CNI baked in (Step 3)

###### How CNI Configuration Works

When you register a CNI configuration, CloudStack injects it as **user-data** into the CKS cluster nodes during provisioning. This runs as a shell script (`runcmd:`) after the base Kubernetes installation, allowing you to install or replace the CNI plugin at runtime.

###### Example 1: BGP CNI Configuration

For BGP peering (e.g., with Calico or Cilium):

```json
{
  "peer_ip_address": "10.0.0.1",
  "peer_as_number": "64512",
  "bgp_router_id": "10.0.0.2"
}
```

###### Example 2: Cilium CNI via User-Data

Install Cilium on a cluster that was provisioned with the default Calico ISO — no custom ISO needed.

**Note:** This approach pulls Cilium images from the internet during node bootstrap. If you need fully offline provisioning, use the Cilium ISO build in [CKS Custom ISO Build Guide](cks-custom-iso.md#option-b-build-cilium-iso-community-script) (Option B).

**The Cilium CNI config** is archived in this repo at:
[`cilium-cni-config.yaml`](setup/cks/scripts/cilium-cni-config.yaml)

> **Credit:** Adapted from [nulcell/homecloud](https://github.com/nulcell/homecloud/blob/3f5a40a3332084a4ff7bd5ae13fc3c70dce28d96/cloudstack/compute/cni-config/cilium.yaml) by [nulcell](https://github.com/nulcell). Archived for preservation.

**Usage:**
1. **Instances** → **CNI Configuration** → **Add CNI Configuration**
2. Paste the YAML content from the archived script
3. **Important:** Replace `{{ ds.meta_data.cilium_version }}` with your desired version (e.g., `1.18.2`) before saving
4. Select this CNI configuration during cluster creation under Advanced Settings

**What the Cilium config does:**

| Setting | Purpose |
|---------|---------|
| `kubeProxyReplacement=true` | eBPF-based kube-proxy replacement (performance) |
| `bgpControlPlane.enabled=true` | BGP control plane for external routing |
| `encryption.enabled=true` | Pod-to-pod encryption enabled |
| `encryption.type=wireguard` | WireGuard encryption |
| `encryption.nodeEncryption=true` | Node-to-node encryption |
| `gatewayAPI.enabled=true` | Kubernetes Gateway API support |
| `ingressController.enabled=true` | Built-in ingress controller |
| `l2announcements.enabled=true` | L2 announcements for load balancers |
| `ipam.mode=cluster-pool` | Cluster-pool IPAM |
| `clusterPoolIPv4PodCIDRList={10.168.0.0/16}` | Pod CIDR range (change to avoid conflicts) |
| `clusterPoolIPv4MaskSize=24` | /24 subnets per node |

**Pod CIDR Warning:** Avoid `10.0.0.0/16` if deploying on pre-existing CKS networks — it conflicts with Calico's default pod network. Use a different range like `10.168.0.0/16` or `192.168.0.0/16`.

**Verification after deployment:**
```bash
kubectl get pods -n kube-system -l k8s-app=cilium
kubectl -n kube-system exec -it daemonset/cilium -- cilium status
```

###### Example 3: Custom CNI Parameters

You can also inject arbitrary shell commands to run on node bootstrap. For example, to install a custom CNI plugin:

```yaml
runcmd:
  - |
    cat >/home/cloud/custom-cni.sh <<'EOF'
    #!/bin/bash
    set -ex
    export KUBECONFIG=/etc/kubernetes/admin.conf
    # Your custom CNI installation commands here
    kubectl apply -f /path/to/your-cni.yaml
    EOF
  - chmod +x /home/cloud/custom-cni.sh
  - /home/cloud/custom-cni.sh
```

##### 6. CloudStack CSI Driver Toggle
- **What:** Enable/disable the CloudStack CSI Driver deployment on cluster creation
- **Default:** Disabled
- **Why:** When enabled, the CSI driver is automatically deployed to the cluster — no manual setup needed
- **Benefit:** Eliminates manual CSI deployment steps (secret creation, manifest deployment) for new CKS clusters
- **Manual deploy still needed for:** Pre-existing clusters, or clusters where this was not enabled during creation
- **See also:** [CloudStack CSI Driver architecture](../../architecture/cloudstack-csi-driver.md) · [CSI setup guide](../../setup/cloudstack-csi-driver.md)

#### UI Flow
1. **Compute** → **Kubernetes** → **Add Kubernetes Cluster**
2. Fill in basic fields (name, zone, network, version, node counts)
3. **Toggle "Advanced Settings"** to reveal the granular options
4. Select templates/service offerings per node type
5. Select hypervisor type if needed
6. Select CNI configuration if needed
7. **Enable CloudStack CSI Driver** if persistent storage is needed (disabled by default)
8. Click **Create**

#### API Equivalent
The `createKubernetesCluster` API accepts additional parameters when advanced settings are used:
- `controltemplateid` — Template ID for control nodes
- `controlserviceofferingid` — Service offering for control nodes
- `workertemplateid` — Template ID for worker nodes
- `workerserviceofferingid` — Service offering for worker nodes
- `etcdtemplateid` — Template ID for etcd nodes (if etcdnodes ≥ 1)
- `etcdserviceofferingid` — Service offering for etcd nodes
- `hypervisortype` — Hypervisor type filter
- `cniconfigurationid` — CNI configuration ID
- `enablecloudstackcsidriver` — Enable CloudStack CSI Driver deployment (disabled by default)

See the [official API docs](http://docs.cloudstack.apache.org/en/latest/plugins/cloudstack-kubernetes-service.html) for the complete parameter list.

## Step 7: Access Your Cluster

### Get kubeconfig
```bash
# Via API
# The createKubernetesCluster response includes kubeconfig data
# Or use the UI to download the kubeconfig file

# Apply locally
kubectl --kubeconfig=<kubeconfig-file> get nodes
kubectl --kubeconfig=<kubeconfig-file> get pods -n kube-system
```

### SSH to Nodes
```bash
# Control node (port 2222 + node_index)
ssh -i <key> -p 2222 cloud@<VR_PUBLIC_IP>

# Worker node
ssh -i <key> -p 2223 cloud@<VR_PUBLIC_IP>
```

## Step 8: Cluster Management

### Scale Cluster

**UI:**
1. Select the cluster
2. Click **Scale**
3. Adjust worker or control node count
4. Click **OK**

**API:**
```bash
# Scale workers
scaleKubernetesCluster id=<cluster-id> workernodes=5

# Scale control nodes (requires HA setup)
scaleKubernetesCluster id=<cluster-id> controlnodes=5
```

### Upgrade Cluster

**UI:**
1. Select the cluster
2. Click **Upgrade**
3. Select the target Kubernetes version
4. Click **OK**

**API:**
```bash
upgradeKubernetesCluster id=<cluster-id> kubernetesversionid=<new-version-id>
```

### Add Pre-created Worker Nodes
```bash
# From UI: Select cluster → Nodes → Add Nodes → Select VMs from same network
# From API:
addKubernetesClusterNode \
  id=<cluster-id> \
  instanceids=<vm-id-1>,<vm-id-2>
```

### Remove Worker Nodes
```bash
removeKubernetesClusterNode id=<cluster-id> instanceids=<vm-id-1>
```

### Stop/Start Cluster

**UI:**
1. Select the cluster
2. Click **Stop** or **Start** from the action menu

**API:**
```bash
stopKubernetesCluster id=<cluster-id>
startKubernetesCluster id=<cluster-id>
```

### Delete Cluster

**UI:**
1. Select the cluster
2. Click **Delete** from the action menu
3. Confirm deletion

**API:**
```bash
deleteKubernetesCluster id=<cluster-id>
```

## Step 9: Monitoring & Verification

```bash
# Check node status
kubectl get nodes

# Check system pods
kubectl get pods -n kube-system

# Check CNI (Calico)
kubectl get pods -n calico-system

# View events
kubectl get events --sort-by='.lastTimestamp'
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| CKS tab not visible | Verify `cloud.kubernetes.service.enabled=true` and restart management server |
| Node fails to join cluster | Check ISO URL accessibility, network connectivity, and kubeadm logs on node |
| Port forwarding not working | For shared networks, manually configure load balancer; isolated networks auto-provision | HA not working | Use ≥3 control nodes with Kubernetes 1.16+; configure external LB for shared networks |
| Custom template not showing | Ensure template is marked "For CKS" during registration |
| ISO build fails | Check internet connectivity; script needs to download K8s binaries and images |
| etcd nodes not working | Ensure ISO was built with etcd binaries (use `ETCD_VERSION` parameter) |

## Best Practices

1. **Use dedicated etcd nodes** for production clusters (from 4.21+)
2. **Register CKS templates** pre-baked with required tools (helm, monitoring agents, etc.)
3. **Use HA control plane** (3 or 5 nodes) for production
4. **Version pinning:** Register only the K8s versions you need; disable unused ones
5. **Network isolation:** Use isolated networks for better security
6. **Hypervisor affinity:** Select specific hypervisor types for consistent performance
7. **Host dedication:** Dedicate hosts to domains/accounts for resource isolation

## References

- [CloudStack CKS Documentation](http://docs.cloudstack.apache.org/en/latest/plugins/cloudstack-kubernetes-service.html)
- [Flexible CKS Clusters (ShapeBlue)](https://www.shapeblue.com/flexible-cks-clusters-in-cloudstack-4-21/)
- [CKS Binaries ISOs](http://download.cloudstack.org/cks/)
- [kubeadm Reference](https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm/)
