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

### Option A: Use Pre-built ISOs
Download from:
- `http://download.cloudstack.org/cks/`
- `http://packages.shapeblue.com/cks/`

Register in CloudStack:
1. **Storage** → **ISOs** → **Register ISO**
2. Select the downloaded ISO
3. Mark as `Bootable` and `For CKS` if applicable

### Option B: Build Your Own ISO (Calico)

```bash
# Install cloudstack-common package for the script
# The script is at: /usr/share/cloudstack-common/scripts/cks/create-kubernetes-binaries-iso.sh

# Example: Build ISO for Kubernetes 1.33.1 with Calico
cd /tmp
./create-kubernetes-binaries-iso.sh \
  . \
  1.33.1 \
  1.7.1 \
  1.33.0 \
  https://raw.githubusercontent.com/projectcalico/calico/v3.30.0/manifests/calico.yaml \
  https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml \
  setup-v1.33.1-calico

# For ARM64:
./create-kubernetes-binaries-iso.sh \
  . \
  1.33.1 \
  1.7.1 \
  1.33.0 \
  https://raw.githubusercontent.com/projectcalico/calico/v3.30.0/manifests/calico.yaml \
  https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml \
  aarch64 \
  setup-v1.33.1-calico-arm64

# With dedicated etcd (optional):
./create-kubernetes-binaries-iso.sh \
  . \
  1.33.1 \
  1.7.1 \
  1.33.0 \
  https://raw.githubusercontent.com/projectcalico/calico/v3.30.0/manifests/calico.yaml \
  https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml \
  setup-v1.33.1-calico-etcd \
  3.5.1
```

### Option C: Build Your Own ISO (Cilium) — Community Alternative

For a Cilium-based ISO that also bundles CCM, CSI, and Cluster Autoscaler, use the community script from [nulcell/homecloud](https://github.com/nulcell/homecloud/blob/3f5a40a3332084a4ff7bd5ae13fc3c70dce28d96/cloudstack/compute/cks/create-cilium-kubernetes-binaries-iso.sh):

```bash
git clone https://github.com/nulcell/homecloud.git
cd homecloud/cloudstack/compute/cks

# Example: Build ISO with Cilium, Hubble, CCM, CSI, Cluster Autoscaler
./create-cilium-kubernetes-binaries-iso.sh \
  . \
  1.33.1 \
  1.8.0 \
  1.33.0 \
  1.18.2 \
  7.14.0 \
  cks-v1.33.1-cilium

# For ARM64:
./create-cilium-kubernetes-binaries-iso.sh \
  . \
  1.33.1 \
  1.8.0 \
  1.33.0 \
  1.18.2 \
  7.14.0 \
  cks-v1.33.1-cilium \
  arm64

# With dedicated etcd:
./create-cilium-kubernetes-binaries-iso.sh \
  . \
  1.33.1 \
  1.8.0 \
  1.33.0 \
  1.18.2 \
  7.14.0 \
  cks-v1.33.1-cilium-etcd \
  amd64 \
  3.5.0
```

**What the Cilium ISO includes (vs. official Calico ISO):**

| Component | Official (Calico) | Community (Cilium) |
|-----------|-------------------|-------------------|
| **CNI** | Calico | Cilium + Hubble (relay + UI) |
| **CCM** | Manual deploy | Auto-bundled |
| **CSI Driver** | Manual deploy | Auto-bundled (v3.0.0) |
| **Cluster Autoscaler** | Not included | Auto-bundled (CloudStack provider) |
| **Kubernetes Dashboard** | Included | Included |
| **ImagePullPolicy** | Default | Set to `IfNotPresent` |
| **Pre-pulled images** | No (via ISO) | Yes (containerd) |
| **Dedicated etcd** | Optional (9th param) | Optional (9th param) |

**Key differences in the Cilium approach:**
- Uses `helm template` to generate Cilium manifests with `kubeProxyReplacement=true` (eBPF-based)
- Hubble observability (relay + UI) enabled by default
- Pre-pulls all container images into containerd at build time and exports them to the ISO
- Sets `imagePullPolicy: IfNotPresent` across all YAML files
- Uses shapeblue's `kubelet.service` and `10-kubeadm.conf` for newer K8s versions
- Includes Cluster Autoscaler manifest for CloudStack

### Register the ISO as a Supported K8s Version

Via UI:
1. **Infrastructure** → **Kubernetes** → **Supported Versions**
2. Click **Add Kubernetes Supported Version**
3. Fill in:
   - **Name:** `v1.33.1`
   - **Semantic Version:** `1.33.1`
   - **Zone:** Select your zone
   - **URL:** Path to the ISO (HTTP/HTTPS accessible by management server)
   - **Checksum:** MD5/SHA of the ISO
   - **Min CPU:** `2`
   - **Min Memory:** `2048` MB

Via API:
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

## Step 5: (Optional) Configure CNI

From ACS 4.21+, CNI can be configured via user data:

1. **Instances** → **CNI Configuration** → **Add CNI Configuration**
2. Define CNI parameters (e.g., `peer_ip_address`, `peer_as_number` for BGP)
3. Select during cluster creation under Advanced Settings

## Step 6: Create a Kubernetes Cluster

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

### Flexible Cluster (ACS 4.21+)

Enable **Advanced Settings** in the UI to configure:
- **Control Node Template** and **Service Offering**
- **Worker Node Template** and **Service Offering**
- **Etcd Node Template** and **Service Offering** (if etcdnodes ≥ 1)
- **Hypervisor Type** filter
- **CNI Configuration** selection

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

### Access Kubernetes Dashboard
```bash
kubectl --kubeconfig=<kubeconfig-file> proxy --address=0.0.0.0 --port=8001
# Visit: http://localhost:8001/api/v1/namespaces/kube-system/services/https:kubernetes-dashboard:/proxy/
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
```bash
# Scale workers
scaleKubernetesCluster id=<cluster-id> workernodes=5

# Scale control nodes (requires HA setup)
scaleKubernetesCluster id=<cluster-id> controlnodes=5
```

### Upgrade Cluster
```bash
# Upgrade to a newer registered version
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
```bash
stopKubernetesCluster id=<cluster-id>
startKubernetesCluster id=<cluster-id>
```

### Delete Cluster
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

# Check dashboard
kubectl get pods -n kubernetes-dashboard

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
