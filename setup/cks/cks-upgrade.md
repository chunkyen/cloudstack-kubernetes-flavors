# CKS Cluster Upgrade — Full Stack Guide

This guide covers upgrading a CKS-managed Kubernetes cluster **end-to-end**: the Kubernetes version (handled by CloudStack), CNI, and CSI driver.

## The Upgrade Model

CKS clusters are managed by CloudStack's management server. The Kubernetes version upgrade is an **in-place ISO-based upgrade** — CloudStack applies the new ISO to existing nodes and upgrades them in place, without replacing the VMs.

Meanwhile, CNI and CSI are **workload deployments** — they run as pods inside the cluster. CNI and CSI are baked into the ISO at build time and upgrade together with the K8s version during the in-place upgrade.

### What Gets Upgraded Where

| Component | Where | How Upgraded | Managed by CKS? |
|-----------|-------|-------------|------------------|
| **kubelet** | Workload nodes | In-place ISO upgrade | ✅ Yes |
| **kubeadm** | Workload nodes | In-place ISO upgrade | ✅ Yes |
| **containerd** | Workload nodes | In-place ISO upgrade | ✅ Yes |
| **K8s API version** | Workload cluster | In-place ISO upgrade | ✅ Yes |
| **CNI** (Calico/Cilium) | Workload nodes | Baked into ISO — upgrades with K8s version | ✅ Yes |
| **CSI driver** | Workload nodes | Baked into ISO — upgrades with K8s version | ✅ Yes |
| **CCM** (CloudStack K8s Provider) | Workload nodes | Baked into ISO — upgrades with K8s version | ✅ Yes |

> **Key point:** CKS performs an **in-place ISO upgrade** — CloudStack applies the new ISO to existing nodes and upgrades them in place, without replacing the VMs. The ISO contains kubelet, kubeadm, containerd, CNI, CSI driver, and CCM. Upgrading the K8s version upgrades **all of these together** in a single operation. No separate CNI, CSI, or CCM upgrade steps are needed.

## Upgrade Sequence

For CKS, the upgrade follows this sequence:

1. **Create instance snapshots** of all K8s nodes (preferably at shutdown state) — for rollback safety
2. **K8s version** — CloudStack performs an in-place ISO upgrade (this upgrades K8s, CNI, CSI, and CCM together)
3. **Verify** all components are at the expected versions

### Why Snapshot First?

- **Rollback safety**: If the upgrade fails, you can revert to the snapshots
- **Shutdown state preferred**: Snapshots taken at shutdown are consistent and faster to restore
- **Rollback safety**: Snapshots provide a clean revert point if the upgrade fails

## Step-by-Step Upgrade

### Prerequisites

- Access to the CloudStack management UI or cmk CLI
- Target K8s version registered in CloudStack
- Access to the workload cluster kubeconfig
- Sufficient compute resources to provision new nodes alongside existing ones

### Step 1: Register New K8s Version (If Not Already Done)

Before you can upgrade, the target K8s version must be registered in CloudStack.

**Via UI:**
1. **Infrastructure** → **Kubernetes** → **Supported Versions** → **Add Kubernetes Supported Version**
2. Fill in version details and upload the ISO

**Via cmk:**
```bash
cmk registeriso name=v1.33.1 url=http://<server>/setup-v1.33.1.iso zoneid=<zone-id> checksum=<iso-checksum> isextractable=true ispublic=true bootable=true
cmk add kubernetessupportedversion name=v1.33.1 semanticversion=1.33.1 iso=<iso-name-or-id> zoneid=<zone-id> mincpunumber=2 minmemory=2048
```

**ISO sources:**
- [`download.cloudstack.org/cks/`](http://download.cloudstack.org/cks/)
- [`packages.shapeblue.com/cks/`](http://packages.shapeblue.com/cks/)

### Step 2: Create Instance Snapshots (Rollback Safety)

> **Note:** This step is optional but recommended. Creating instance snapshots of all K8s nodes before an upgrade provides a rollback mechanism if something goes wrong.

**Via UI:**
1. Navigate to **Compute** → **Instances**
2. For each K8s node:
   - Select the instance
   - Click **Snapshot** → **Create Snapshot**
   - **Stop the instance first** (highly recommended — shutdown state snapshots are more consistent and restore faster)
   - Name the snapshot clearly (e.g., `cks-cluster-pre-upgrade-node-1`)
3. Verify all snapshots are created

**Via cmk:**
```bash
# List all K8s nodes (filter by name or tag)
cmk list instances filter=id,name,state,templatename

# Stop each node (highly recommended for consistent snapshots)
cmk stop instance id=<node-id>

# Create snapshot for each node
cmk createsnapshot name=cks-pre-upgrade-node-1 instanceid=<node-id>
cmk createsnapshot name=cks-pre-upgrade-node-2 instanceid=<node-id>
# ... repeat for all nodes

# Start nodes again (if stopped)
cmk start instance id=<node-id>
```

### Step 3: Upgrade K8s Version (CloudStack-Native)

#### Via UI

1. Navigate to **Compute** → **Kubernetes**
2. Hover over the cluster name and click the **three dots (⋮)** on the right
3. Click the **Upgrade** icon (🔄)
4. Select the target Kubernetes version from the dropdown
5. Click **OK**

> **Note:** The **Upgrade** icon only appears when:
> - The cluster is in a **running** state
> - An eligible upgrade version is registered in CloudStack

#### Via cmk CLI

```bash
cmk upgrade kubernetescluster id=<cluster-id> kubernetesversionid=<new-version-id>
```

### Step 4: Wait for In-Place Upgrade to Complete

CloudStack performs an in-place upgrade on existing nodes. Monitor progress:

**Via UI:**
- Watch the cluster status indicator in the Kubernetes tab
- Status transitions: `Running` → `Upgrading` → `Running`
- Old nodes are removed as new nodes join

**Via cmk:**
```bash
# Check cluster state
cmk list kubernetescluster id=<cluster-id>
# Look for state: running (upgrade complete) or upgrading (in progress)
```

**Via kubectl (after upgrade completes):**
```bash
kubectl get nodes
# Expected: all nodes at new version, status Ready

kubectl version --short
# Expected: server version matches target
```

> **Estimated time:** In-place upgrade typically takes 10-30 minutes depending on cluster size and node count. Control plane nodes are upgraded first, then workers. The ISO is streamed to each node and applied in place.

### Step 5: Verify the Upgrade

After the in-place ISO upgrade completes, verify all components are at the expected versions:

```bash
kubeconfig="<path-to-kubeconfig>"

# Check node versions
kubectl --kubeconfig=${kubeconfig} get nodes

# Check K8s version
kubectl --kubeconfig=${kubeconfig} version --short

# Check CNI pods (should be running with new version)
kubectl --kubeconfig=${kubeconfig} get pods -n kube-system -l k8s-app=calico-node

# Check CSI pods (should be running with new version)
kubectl --kubeconfig=${kubeconfig} get pods -n kube-system -l app.kubernetes.io/name=csi-smb-controller

# Check CCM pods (should be running with new version)
kubectl --kubeconfig=${kubeconfig} get pods -n kube-system -l k8s-app=cloudstack-ccm
```

> **Note:** CNI, CSI, and CCM are all baked into the ISO and upgrade together with the K8s version. No separate upgrade steps are needed.

## Rollback

If something goes wrong during the upgrade, you can rollback using the snapshots created in Step 2.

### Rollback via Snapshot Revert

1. **Stop the failing cluster** (if still running):
   ```bash
   cmk stop kubernetescluster id=<cluster-id>
   ```

2. **Revert each node to its snapshot:**
   ```bash
   # List snapshots to find the pre-upgrade ones
   cmk list snapshot name=cks-pre-upgrade-*
   
   # For each node, stop the current instance and revert to snapshot
   cmk stop instance id=<current-node-id>
   cmk revert snapshot id=<snapshot-id>
   
   # Start the reverted instance
   cmk start instance id=<reverted-node-id>
   ```

3. **Restart the cluster:**
   ```bash
   cmk start kubernetescluster id=<cluster-id>
   ```

4. **Verify rollback:**
   ```bash
   kubectl --kubeconfig=${kubeconfig} get nodes
   kubectl --kubeconfig=${kubeconfig} version --short
   ```

> **Warning:** Rolling back via snapshot revert restores the exact state of each node at the time of the snapshot. Applications may experience downtime during the revert process.

## Upgrade Checklist

Use this checklist to ensure a smooth upgrade:

- [ ] Document current versions (K8s, CNI, CSI, CCM)
- [ ] Test upgrade on a non-production cluster first
- [ ] Ensure target K8s ISO is registered in CloudStack
- [ ] **Create instance snapshots of all K8s nodes (shutdown state preferred)**
- [ ] Schedule maintenance window (in-place upgrade takes time)
- [ ] Have rollback plan ready (snapshots are your rollback mechanism)
- [ ] Verify cluster health after each step
- [ ] Run application health checks after full upgrade
- [ ] Verify CNI connectivity between nodes
- [ ] Verify CSI volume provisioning works
- [ ] Verify CCM LoadBalancer services work

## Troubleshooting

| Issue | Check |
|-------|-------|
| Upgrade icon not visible | Verify cluster is `Running` and target version is registered |
| Cluster stuck at `Upgrading` | Check CloudStack management server logs: `tail -f /var/log/cloudstack/management/management-server.log` |
| Nodes not reaching `Ready` | Check `kubectl get nodes` and `kubectl describe node <node-name>` |
| CNI pods not ready after upgrade | Check `kubectl get pods -n kube-system -l k8s-app=calico-node` |
| CSI pods not ready after upgrade | Check `kubectl get pods -n kube-system -l app.kubernetes.io/name=csi-smb-controller` |
| CCM pods not ready after upgrade | Check `kubectl get pods -n kube-system -l k8s-app=cloudstack-ccm` |
| Port forwarding broken after upgrade | Re-configure firewall rules and port forwarding in CloudStack |
| Upgrade failed — need to rollback | Revert nodes to pre-upgrade snapshots (see Rollback section) |
| Upgrade stuck on first node (control plane upgraded, workers never transition) | See manual recovery below |

### Upgrade Stuck — Manual Recovery

If the upgrade process reports **failed** and gets stuck (e.g., control plane node completed successfully but worker nodes never transition), it's suspected that the upgrade health check job never completed. The control plane node may be at the new version but **cordoned**. You can manually complete the upgrade on each remaining node.

> **Note:** If the upgrade is truly broken and manual recovery doesn't work, revert to your pre-upgrade snapshots (see [Rollback](#rollback-via-snapshot-revert)).

#### Manual Recovery Steps

1. **Uncordon the control plane node** (if still cordoned):
   ```bash
   kubectl uncordon <control-plane-node-name>
   ```

2. **Cordon the worker node** to be upgraded (to prevent scheduling during upgrade):
   ```bash
   kubectl cordon <worker-node-name>
   ```

3. **Re-attach the upgrade ISO to the worker node** (the ISO is detached after a failed upgrade):

   **Via UI:**
   1. Go to **Compute** → **Instances**
   2. Select the worker node
   3. Click **ISO** → **Attach ISO**
   4. Select the upgrade ISO and click **Attach**

   **Via cmk:**
   ```bash
   cmk attachiso instanceid=<worker-node-id> iso=<iso-name-or-id>
   ```

4. **SSH to the worker node and mount the ISO:**
   ```bash
   ssh -i <key> -p <port> cloud@<worker-node-ip>
   sudo -i
   lsblk          # find the ISO device (e.g., sr0)
   mkdir -p /mnt/iso && mount /dev/sr0 /mnt/iso
   ```

4. **Replace binaries and upgrade the node:**
   ```bash
   # Stop kubelet, replace binaries from ISO, make executable
   systemctl stop kubelet
   cp /mnt/iso/k8s/{kubeadm,kubectl,kubelet} /opt/bin/ && chmod +x /opt/bin/{kubeadm,kubectl,kubelet}

   # Reload systemd, upgrade node, start kubelet
   systemctl daemon-reload
   kubeadm upgrade node
   systemctl start kubelet
   ```

6. **Verify and clean up:**
   ```bash
   # Verify the node is upgraded
   kubectl get nodes

   # Unmount the ISO
   umount /mnt/iso
   exit
   ```

7. **Repeat steps 3–6** for each remaining worker node, then uncordon them:
   ```bash
   kubectl uncordon <worker-node-name>
   ```

8. **Verify the full cluster:**
   ```bash
   kubectl get nodes
   kubectl version --short
   kubectl get pods -n kube-system
   ```

## ISO-Baked Components

### What's Baked Into the CKS ISO

The CKS ISO contains all the following components, which upgrade together when you upgrade the K8s version:

| Component | Upgraded with ISO? |
|-----------|-------------------|
| kubelet | ✅ Yes |
| kubeadm | ✅ Yes |
| containerd | ✅ Yes |
| CNI (Calico/Cilium) | ✅ Yes |
| CSI driver | ✅ Yes |
| CCM (CloudStack K8s Provider) | ✅ Yes |

### When You Need to Re-apply Manifests

The only component you might need to upgrade separately is **CNI** — if you need a CNI version different from what's baked into the ISO. In that case:

1. Upgrade K8s version via CloudStack (upgrades everything else automatically)
2. Re-apply CNI manifests to get the desired CNI version

### When to Rebuild the ISO for CNI

| Scenario | Approach |
|----------|----------|
| CNI minor version bump (e.g., Calico 3.28 → 3.29) | Re-apply manifests |
| CNI major version bump (e.g., Calico 3.x → 4.x) | Consider rebuilding ISO |
| Switching CNI (e.g., Calico → Cilium) | Re-apply manifests or rebuild ISO |
| Custom CNI parameters | Use CNI configuration (ACS 4.21+) or rebuild ISO |

## Related

- [CKS Setup Guide](./cks.md) — initial cluster deployment
- [CKS Custom ISO Build Guide](./cks-custom-iso.md) — building CKS-compatible ISOs
- [CAPC Upgrade Guide](../capc/capc-upgrade.md) — CAPC cluster upgrade procedures
- [CNI Automation Options](../capc/cni-automation-options.md) — automating CNI installation
