# CKS Setup Guide

## 📚 Guide Index

| File | Description |
|------|-------------|
| [cks.md](./cks.md) | Main setup guide: enabling CKS, registering ISOs/templates, creating clusters, scaling, and troubleshooting |
| [cks-custom-iso.md](./cks-custom-iso.md) | Build custom Kubernetes binaries ISOs (Calico, Cilium, offline-ready) |
| [cks-offline.md](./cks-offline.md) | Air-gapped / offline deployment workarounds, root cause analysis, and long-term solutions |
| [cks-upgrade.md](./cks-upgrade.md) | End-to-end CKS cluster upgrade guide (K8s version, CNI, CSI) |
| [cks-improvements.md](./cks-improvements.md) | WIP: Proposed upstream improvements for CKS (offline support, auth/IAM, node lifecycle, etc.) |

### Scripts

| Script | Description |
|--------|-------------|
| [scripts/create-kubernetes-binaries-iso.sh](./scripts/create-kubernetes-binaries-iso.sh) | Official Calico ISO builder script (archived from CloudStack source) |
| [scripts/create-cilium-offline-kubernetes-binaries-iso.sh](./scripts/create-cilium-offline-kubernetes-binaries-iso.sh) | Offline Cilium ISO builder — strips `@sha256:...` digest pins for air-gapped deployment |
| [scripts/create-cks-cluster.sh](./scripts/create-cks-cluster.sh) | Automates CKS cluster creation via cmk CLI |
| [scripts/cilium-cni-config.yaml](./scripts/cilium-cni-config.yaml) | User-data config for dynamic Cilium CNI injection at runtime |

---

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

### Via cmk
```bash
cmk update globalconfiguration name=cloud.kubernetes.service.enabled value=true
cmk update globalconfiguration name=endpoint.url value=http://<mgmt-server>:8080/client/api
```
Then restart the management server:
```bash
service cloudstack-management restart
```

After restart, the **Kubernetes** tab appears under **Compute** in the UI.

## Step 2: Register Network Offering

Ensure a default network offering is configured:
1. Go to **Network** → **Network Offerings**
2. Verify `DefaultNetworkOfferingforKubernetesService` exists (from ACS 4.14)
3. Set it as default:
   - Global setting: `cloud.kubernetes.cluster.network.offering`
   - Value: `DefaultNetworkOfferingforKubernetesService`

**Via cmk:**
```bash
cmk update globalconfiguration name=cloud.kubernetes.cluster.network.offering value=DefaultNetworkOfferingforKubernetesService
```

## Step 3: Register Kubernetes Binaries ISO

### Pre-built ISOs

Download from:
- [`download.cloudstack.org/cks/`](http://download.cloudstack.org/cks/)
- [`packages.shapeblue.com/cks/`](http://packages.shapeblue.com/cks/)

Register in CloudStack: **Storage** → **ISOs** → **Register ISO**

### Custom ISO Builds

For custom ISO builds (Calico or Cilium), see the dedicated guide:

- [**CKS Custom ISO Build Guide**](./cks-custom-iso.md)

### Register the ISO as a Supported K8s Version

After building or downloading an ISO, register it:

**Via UI:** **Infrastructure** → **Kubernetes** → **Supported Versions** → **Add Kubernetes Supported Version**

**Via cmk:**
```bash
cmk registeriso name=v1.33.1 url=http://<server>/setup-v1.33.1.iso zoneid=<zone-id> checksum=<iso-checksum> isextractable=true ispublic=true bootable=true
cmk add kubernetessupportedversion name=v1.33.1 semanticversion=1.33.1 iso=<iso-name-or-id> zoneid=<zone-id> mincpunumber=2 minmemory=2048
```

## Step 4: (Optional) Register CKS-Compatible Templates

From ACS 4.21+, you can register custom templates for CKS.

> **Note:** If no custom CKS template is registered, CloudStack will use the **SystemVM template** for all cluster nodes.

1. **Compute** → **Templates** → **Register Template**
2. Fill in template details
3. **Check the "For CKS" option**
4. Register (base image should have prerequisites installed)

**Via cmk:**
```bash
cmk register template name=cks-custom-template url=http://<server>/cks-template.qcow2 zoneid=<zone-id> ostypeid=<os-type-id> isextractable=true ispublic=true isfeatured=true forcks=true
```

**Prerequisites for CKS templates:**
- Minimum: 8GB root disk, 2 CPU, 2GB RAM
- SSH public key of `cloud` user — injected via cloud-init during deployment, **not** pre-registered in the template
- Required packages — see [official docs](https://docs.cloudstack.apache.org/en/latest/plugins/cloudstack-kubernetes-service.html#build-a-custom-template-to-use-for-kubernetes-clusters-nodes)

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
   - **Worker Nodes:** `1` or more
   - **Etcd Nodes:** `0` (or ≥1 for dedicated etcd)
3. Click **Create**

### Advanced Settings (ACS 4.21+)

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
- **⚠️ Critical Bug Warning:** In `cmk create kubernetescluster`, if both `serviceofferingid` and `nodeofferings` are provided, `nodeofferings` will override the `serviceofferingid` during deployment. However, **CKS still checks the `serviceoffering` during cluster upgrades** to verify minimum hardware requirements. To avoid upgrade failures, ensure the `serviceofferingid` matches the resource specifications (CPU/RAM) of your control plane `nodeofferings`.


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

**Note:** This approach pulls Cilium images from the internet during node bootstrap. If you need fully offline provisioning, use the Cilium ISO build in [CKS Custom ISO Build Guide](./cks-custom-iso.md#option-b-build-cilium-iso-community-script) (Option B).

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

> **Script:** A helper script is available in this repo to automate cluster creation: [create-cks-cluster.sh](https://github.com/chunkyen/cloudstack-kubernetes-flavors/blob/main/setup/cks/scripts/create-cks-cluster.sh). It wraps the UI flow into a parameterized shell script for repeatable deployments.

## Step 6: Access Your Cluster

### Get kubeconfig

**Via UI:**
1. Navigate to **Compute** → **Kubernetes**
2. Click on your cluster name
3. Click the **Access** tab — the **Download Kubernetes Cluster Config** button (⬇️) appears here
4. Save the file and apply locally:
```bash
kubectl --kubeconfig=<kubeconfig-file> get nodes
kubectl --kubeconfig=<kubeconfig-file> get pods -n kube-system
```

**Via cmk (CloudMonkey):**
```bash
cmk list kubernetescluster filter=name,id
```
Take note of the cluster `id`, then:
```bash
cmk get kubernetesclusterconfig id=<cluster-id>
```
The command outputs the kubeconfig directly. Save it and apply locally:
```bash
kubectl --kubeconfig=kubeconfig.yaml get nodes
kubectl --kubeconfig=kubeconfig.yaml get pods -n kube-system
```

### SSH to Nodes

> **Note:** SSH access is only needed for troubleshooting — it's not required for normal cluster operations.

SSH ports are redirected via port forwarding rules on the public IP assigned to the API server. The port numbers increment from **2222** for each node and can be found in the **Port Forwarding** section of the public IP address details.

```bash
# Port increments from 2222 for each node
ssh -i <key> -p 2222 cloud@<VR_PUBLIC_IP>   # node 1
ssh -i <key> -p 2223 cloud@<VR_PUBLIC_IP>   # node 2
ssh -i <key> -p 2224 cloud@<VR_PUBLIC_IP>   # node 3
```

## Step 7: Cluster Management

### Scale Cluster

> **Note:** Scaling handles both **vertical scaling** (changing compute offering/CPU/RAM) and **horizontal scaling** (adding/removing worker nodes). The **Add Node** icon (➕) is separate — it adds existing VMs to the cluster.

**UI:**
1. Hover over the cluster name and click the **three dots (⋮)** on the right
2. Click the **Scale** icon (📐)
3. Adjust worker or control node count, or select a new service offering (compute spec)
4. Click **OK**

**cmk:**
```bash
cmk scale kubernetescluster id=<cluster-id> workernodes=5
cmk scale kubernetescluster id=<cluster-id> controlnodes=5
```

### Upgrade Cluster

> **Full stack upgrade guide:** For a complete end-to-end upgrade covering K8s version, CNI, and CSI, see the [CKS Upgrade Guide](./cks-upgrade.md).

> **Note:** The **Upgrade** icon (🔄) only appears when:
> - The cluster is in a **running** state
> - An eligible upgrade version is available

**UI:**
1. Hover over the cluster name and click the **three dots (⋮)** on the right
2. Click the **Upgrade** icon (🔄)
3. Select the target Kubernetes version
4. Click **OK**

**cmk:**
```bash
cmk upgrade kubernetescluster id=<cluster-id> kubernetesversionid=<new-version-id>
```

### Add Pre-created Worker Nodes

> **Note:** The **Add Node** icon (➕) only appears when the cluster is in a **running** state.

**UI:**
1. Hover over the cluster name and click the **three dots (⋮)** on the right
2. Click the **Add Node** icon (➕)
3. Select VMs from the same network as the cluster
4. Click **OK**

**cmk:**
```bash
cmk add kubernetesclusternode id=<cluster-id> instanceids=<vm-id-1>,<vm-id-2>
```

### Remove Worker Nodes
```bash
cmk remove kubernetesclusternode id=<cluster-id> instanceids=<vm-id-1>
```

### Stop/Start Cluster

**UI:**
1. Hover over the cluster name and click the **three dots (⋮)** on the right
2. Click the **Stop** icon (⏹) or **Start** icon (▶)
   - **Stop** appears when the cluster is running
   - **Start** appears when the cluster is stopped

**cmk:**
```bash
cmk stop kubernetescluster id=<cluster-id>
cmk start kubernetescluster id=<cluster-id>
```

### Delete Cluster

**UI:**
1. Hover over the cluster name and click the **three dots (⋮)** on the right
2. Click the **Delete** icon (🗑)
3. Confirm deletion

**cmk:**
```bash
cmk delete kubernetescluster id=<cluster-id>
```

## Step 8: Create Storage Class

> **Note:** Even when the CloudStack CSI Driver is deployed automatically during cluster creation (via the **Enable CloudStack CSI Driver** toggle in Advanced Settings), you still need to create a StorageClass manually — the driver does not provision one by default.

### Prerequisite: Create a Disk Offering

Before creating the StorageClass, you need a **Disk Offering** that the CSI driver will use to provision volumes. For flexibility, use a **Custom Disk Offering** so PVs can be sized to any requirement.

**Via UI:**
1. Go to **Infrastructure** → **Disk Offerings**
2. Click **Add Disk Offering**
3. Configure:
   - **Name:** e.g. `custom-disk-offering`
   - **Display Text:** `Custom Disk Offering`
   - **Disk Size (MB):** Leave blank (do **not** enter a fixed size)
   - **Check "Custom Disk Size"** — this is essential; without it, PVs are locked to the disk offering's fixed size and cannot be resized
   - **IOPS Max / IOPS Min:** Leave default or set as needed
4. Click **Create**
5. Note the **ID** of the disk offering — you'll need it for the StorageClass

**Via cmk:**
```bash
cmk create diskoffering name=custom-disk-offering displaytext="Custom Disk Offering" disksize=0 issystem=false
cmk list diskoffering filter=name,id,displaytext
```

### Create the StorageClass

StorageClass is created via `kubectl` only — there is no UI or cmk equivalent.

1. **Get your kubeconfig** (see [Step 6](#get-kubeconfig))
2. **Find the Disk Offering ID:**
```bash
cmk list diskoffering name=custom-disk-offering filter=id
```
3. **Apply the StorageClass manifest:**
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: cloudstack-custom
provisioner: csi.cloudstack.apache.org
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
parameters:
  csi.cloudstack.apache.org/disk-offering-id: <disk-offering-id>
```

Replace `<disk-offering-id>` with the actual ID from your Disk Offering. Apply it:
```bash
kubectl apply -f storageclass.yaml
```

**Verify:**
```bash
kubectl get storageclass
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF
kubectl get pvc
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

### Common Issues

| Issue | Solution |
|-------|----------|
| CKS tab not visible | Verify `cloud.kubernetes.service.enabled=true` and restart management server |
| Node fails to join cluster | Check ISO URL accessibility, network connectivity, and kubeadm logs on node |
| Port forwarding not working | For shared networks, manually configure load balancer; isolated networks auto-provision |
| HA not working | Use ≥3 control nodes with Kubernetes 1.16+; configure external LB for shared networks |
| Custom template not showing | Ensure template is marked "For CKS" during registration |
| ISO build fails | Check internet connectivity; script needs to download K8s binaries and images |
| etcd nodes not working | Ensure ISO was built with etcd binaries (use `ETCD_VERSION` parameter) |

---

### Cluster Stuck in "Starting" with Kubeconfig Available

**Symptom:** The CKS UI shows the kubeconfig is available and downloadable, but the cluster remains in `Starting` state indefinitely. Core Kubernetes components (API server, etcd, CoreDNS, CNI) are running — but CCM, CSI driver, and dashboard are **not** deployed.

#### Root Cause: Dashboard Verification Blocking the Post-Bootstrap Pipeline

The management server verifies the dashboard is running **before** deploying CCM and CSI. If the dashboard check fails, the pipeline stalls:

```
Step 5: ✅ isKubernetesClusterKubeConfigAvailable()    ← Kubeconfig available
Step 6: ❌ isKubernetesClusterDashboardServiceRunning() ← STALLS HERE
Step 7:    taintControlNodes()                          ← NEVER REACHED
Step 8:    deployProvider()                             ← CCM NEVER DEPLOYED
Step 9:    deployCsiDriver()                            ← CSI NEVER DEPLOYED
Step 10:   stateTransitTo(OperationSucceeded)           ← STILL "STARTING"
```

#### Most Common Cause: Wrong Dashboard YAML on the ISO

In 4.22.1, the management server checks for **Kubernetes Dashboard** in the `kubernetes-dashboard` namespace. The cloud-init script applies `dashboard.yaml` from the ISO. If the ISO contains `headlamp.yaml` instead (from a `main`/4.23+ build script), `dashboard.yaml` doesn't exist and the `deploy-kube-system` service fails.

**Diagnose on the control node:**
```bash
# Check if dashboard.yaml exists
ls -la /tmp/k8sconfigscripts/dashboard.yaml 2>/dev/null || echo "MISSING — this is the problem"

# Check deploy-kube-system logs
sudo journalctl -u deploy-kube-system --no-pager -n 20

# Check if the success marker was created
cat /home/cloud/success 2>/dev/null || echo "Cloud-init never completed"
```

**Fix:** Use the correct ISO build script for your CloudStack version:
- **4.22.1:** Use `create-kubernetes-binaries-iso.sh` with `DASHBOARD_YAML_CONFIG` (6th param = full URL to Kubernetes Dashboard YAML)
- **4.23.0+ (main):** Use the `main` branch script with `HEADLAMP_DASHBOARD_VERSION`

See [CKS Custom ISO Build Guide](./cks-custom-iso.md) for details.

#### Other Dashboard Failure Causes

| Cause | Check |
|-------|-------|
| Dashboard image not in ISO | `crictl images \| grep dashboard` on control node |
| Dashboard URL 404 (HTML saved as YAML) | `head -3 /tmp/k8sconfigscripts/dashboard.yaml` — should be YAML, not HTML |
| Pod CrashLoopBackOff | `sudo /opt/bin/kubectl logs -n kubernetes-dashboard <pod> --previous` |
| Pod ContainerCreating/Pending | `sudo /opt/bin/kubectl describe pod -n kubernetes-dashboard <pod>` |
| deploy-kube-system infinite restart loop | `sudo systemctl status deploy-kube-system` + `journalctl -u deploy-kube-system` |

#### Manual Recovery (4.22.1)

If the cluster is otherwise healthy (nodes Ready, API server responding), manually deploy what the management server would have:

```bash
# 1. Deploy Kubernetes Dashboard (what 4.22.1 expects)
sudo /opt/bin/kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml

# 2. Deploy CloudStack Provider (CCM)
sudo /opt/bin/kubectl apply -f /opt/provider/provider.yaml

# 3. Deploy CSI driver
sudo /opt/bin/kubectl apply -f /opt/csi/snapshot-crds.yaml
sudo /opt/bin/kubectl apply -f /opt/csi/manifest.yaml

# 4. Taint control nodes
sudo /opt/bin/kubectl annotate node <control-node-name> \
  cluster-autoscaler.kubernetes.io/scale-down-disabled=true

# 5. Verify dashboard is running
sudo /opt/bin/kubectl get pods -n kubernetes-dashboard | grep kubernetes-dashboard
```

> **Note:** The management server already transitioned the cluster to `OperationFailed` — the state won't auto-recover. You'll need to destroy and recreate the cluster, or manually update the `kubernetes_cluster` state in the CloudStack database.

#### Prevention

1. **Match build script to CloudStack version** — 4.22.1 needs `dashboard.yaml`, 4.23+ uses `headlamp.yaml`
2. **Use `-f` flag on curl** so builds fail on 404 instead of saving HTML garbage
3. **Verify dashboard image is included** in the ISO image extraction loop
4. **Test ISO on a throwaway cluster** before using in production

See [CKS Custom ISO Build Guide](./cks-custom-iso.md) for build script details.

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
