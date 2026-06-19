# CKS Cluster Upgrade — Full Stack Guide

This guide covers upgrading a CKS-managed Kubernetes cluster **end-to-end**: the Kubernetes version (handled by CloudStack), CNI, and CSI driver.

## 1. The Upgrade Model

CKS clusters are managed by CloudStack's management server. The Kubernetes version upgrade is an **in-place ISO-based upgrade** — CloudStack applies the new ISO to existing nodes and upgrades them in place, without replacing the VMs.

Meanwhile, CNI and CSI are **workload deployments** — they run as pods inside the cluster. CNI and CSI are baked into the ISO at build time and upgrade together with the K8s version during the in-place upgrade.

### 1.1 What Gets Upgraded Where

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

## 2. Upgrade Sequence

For CKS, the upgrade follows this sequence:

1. **Create instance snapshots** of all K8s nodes (preferably at shutdown state) — for rollback safety
2. **K8s version** — CloudStack performs an in-place ISO upgrade (this upgrades K8s, CNI, CSI, and CCM together)
3. **Verify** all components are at the expected versions

### 2.1 Why Snapshot First?

- **Rollback safety**: If the upgrade fails, you can revert to the snapshots
- **Shutdown state preferred**: Snapshots taken at shutdown are consistent and faster to restore
- **Rollback safety**: Snapshots provide a clean revert point if the upgrade fails

## 3. Step-by-Step Upgrade

### 3.1 Prerequisites

- Access to the CloudStack management UI or cmk CLI
- Target K8s version registered in CloudStack
- Access to the workload cluster kubeconfig
- Sufficient compute resources to provision new nodes alongside existing ones

### 3.2 Register New K8s Version (If Not Already Done)

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

### 3.3 Create Instance Snapshots (Rollback Safety)

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

### 3.4 Upgrade K8s Version (CloudStack-Native)

#### 3.4.1 Via UI

1. Navigate to **Compute** → **Kubernetes**
2. Hover over the cluster name and click the **three dots (⋮)** on the right
3. Click the **Upgrade** icon (🔄)
4. Select the target Kubernetes version from the dropdown
5. Click **OK**

> **Note:** The **Upgrade** icon only appears when:
> - The cluster is in a **running** state
> - An eligible upgrade version is registered in CloudStack

#### 3.4.2 Via cmk CLI

```bash
cmk upgrade kubernetescluster id=<cluster-id> kubernetesversionid=<new-version-id>
```

### 3.5 Wait for In-Place Upgrade to Complete

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

### 3.6 Verify the Upgrade

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

## 4. Rollback

If something goes wrong during the upgrade, you can rollback using the snapshots created in Section 3.3.

### 4.1 Rollback via Snapshot Revert

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

## 5. Upgrade Checklist

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

## 6. Troubleshooting

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
| Cilium daemonset stuck in CrashLoopBackOff after upgrade to 1.19.x | See [Cilium can't reach API server](#cilium-cant-reach-api-server-after-upgrade-to-119x) below |

### 6.1 Upgrade Stuck — Manual Recovery

If the upgrade process reports **failed** and gets stuck (e.g., control plane node completed successfully but worker nodes never transition), it's suspected that the upgrade health check job never completed. The control plane node may be at the new version but **cordoned**. You can manually complete the upgrade on each remaining node.

> **Note:** If the upgrade is truly broken and manual recovery doesn't work, revert to your pre-upgrade snapshots (see [Rollback](#rollback-via-snapshot-revert)).

#### 6.1.1 Manual Recovery Steps

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

5. **Replace binaries and upgrade the node:**
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

> **⚠️ Critical:** After manual recovery, CloudStack will still show the old K8s version in the UI. This is because CloudStack's internal state tracking only updates when it performs the upgrade itself — it has no way to detect that you manually upgraded the nodes. The actual node versions (confirmed via `kubectl`) are the source of truth.
>
> This stale state is a **blocker for future upgrades**. Kubernetes enforces a 2-version skew policy — if CloudStack thinks your cluster is at v1.34 but nodes are at v1.35, the next upgrade to v1.36 will be blocked.
>
> **Resolution:** After manual recovery completes successfully, trigger another upgrade via CloudStack to the **current** version (the one the nodes are already at). CloudStack should detect that nodes are already at the target version and either skip the upgrade or complete it instantly, which will sync CloudStack's internal state to the correct version. After this sync, you'll be able to upgrade to the next version normally.

> **⚠️ Last Resort — Manual Database Update:**
>
> If triggering another upgrade to the current version also fails to sync CloudStack's internal state (this can happen if CloudStack refuses to "upgrade" to the same version), the **only remaining option** is to manually update the cluster version in the CloudStack database.
>
> **WARNING: This is a nuclear option. Incorrect database changes can corrupt your CloudStack deployment. Always take a full database backup first.**
>
> **Steps:**
>
> 1. **Gather information using cmk (management server must still be running):**
>
>    Find the version ID that CloudStack currently thinks the cluster is at:
>    ```bash
>    cmk list kubernetescluster name=<cluster-name> filter=id,name,kubernetesversionid
>    ```
>
>    Look up the available versions to find the one you want to update to:
>    ```bash
>    cmk set output table
>    cmk list kubernetessupportedversions filter=id,name,semanticversion
>    ```
>    Example output:
>    ```
>    +--------------------------------------+--------------------+-----------------+
>    | ID                                   | NAME               | SEMANTICVERSION |
>    +--------------------------------------+--------------------+-----------------+
>    | 8db73535-2608-4dbc-8a92-83d56a269794 | Kube 1.33.1 calico | 1.33.1          |
>    | 0b76a439-4ce0-4b5b-a33d-ba4d5a72c83a | Kube 1.32.5 calico | 1.32.5          |
>    | af72f314-862d-4d45-9bdd-ba1d15230834 | kube-cilium-1.34.2 | 1.34.2          |
>    | 31074064-17fe-49f2-a840-2e80165e749d | kube cilium 1.35   | 1.35.0          |
>    +--------------------------------------+--------------------+-----------------+
>    ```
>    Note the `name` and `semanticversion` of the correct version (e.g., `kube cilium 1.35` and `1.35.0`).
>
>    > **Important:** The `ID` shown in cmk is a UUID and is **not** the same as the MySQL table `id`. You need the `name` and `semanticversion` to find the correct `id` in the database.
>
> 2. **Stop the CloudStack management server:**
>    ```bash
>    service cloudstack-management stop
>    ```
>
> 3. **Backup the database:**
>    ```bash
>    mysqldump -u root -p cloud > cloudstack_backup_$(date +%Y%m%d_%H%M%S).sql
>    ```
>
> 4. **Connect to the CloudStack database:**
>    ```bash
>    mysql -u root -p cloud
>    ```
>
> 5. **Find the MySQL `id` for the version you want:**
>
>    Query the `kubernetes_supported_version` table to find the row matching the `name` and `semantic_version` from step 1. The `id` column is an auto-increment integer (e.g., `1`, `2`, `3`, `4`), **not** a UUID:
>    ```sql
>    SELECT id, name, semantic_version FROM kubernetes_supported_version WHERE name = 'kube cilium 1.35' AND semantic_version = '1.35.0';
>    ```
>    Example output:
>    ```
>    +----+------------------------+------------------+
>    | id | name                   | semantic_version |
>    +----+------------------------+------------------+
>    |  4 | kube cilium 1.35       | 1.35.0           |
>    +----+------------------------+------------------+
>    ```
>    Note the MySQL `id` (e.g., `4`).
>
> 6. **Update the cluster to reference the correct version:**
>    ```sql
>    UPDATE kubernetes_cluster SET kubernetes_version_id = <mysql-id> WHERE name = '<cluster-name>';
>    ```
>    Replace `<mysql-id>` with the MySQL `id` from step 5 (e.g., `4`) and `<cluster-name>` with your cluster name (e.g., `kubetest`).
>
> 7. **Verify the change:**
>    ```sql
>    SELECT id, name, kubernetes_version_id FROM kubernetes_cluster WHERE name = '<cluster-name>';
>    ```
>
> 8. **Restart CloudStack management server:**
>    ```bash
>    service cloudstack-management start
>    ```
>
> 9. **Verify the UI shows the correct version** and you can now upgrade to the next version.
>
> > **Note:** This approach bypasses all of CloudStack's safety checks. Use only when all other methods have failed and you have a verified database backup.

#### 6.1.2 Why the Upgrade Gets Stuck After Control Plane Completion

When the control plane node completes the in-place upgrade but worker nodes never transition, the upgrade process reports **failed** and gets stuck. Two distinct layers are involved:

1. **CloudStack's orchestration** — `KubernetesClusterUpgradeWorker` runs the per-node upgrade loop (drain → `upgrade-kubernetes.sh` → uncordon → verify) via SSH from the management server. It knows exactly which step failed on which node.
2. **kubeadm's health check** — After the control plane upgrade, kubeadm creates a temporary **upgrade health check Job** to verify cluster health before proceeding to worker nodes. This Job runs on a non-upgraded worker node and requires images (like `pause`) that may not yet exist on that node.

Both layers can cause the upgrade to stall.

#### 6.1.2.1 How CloudStack's Upgrade Flow Actually Works

The upgrade follows a **per-node sequential loop** (control nodes first, then workers):

1. **Drain** the node via `kubectl drain` (executed from management server → control node)
2. **Deploy provider** (in case it was lost)
3. **SCP + execute `upgrade-kubernetes.sh`** on the target node:
   - Poll for ISO (`blkid -o device -t LABEL=CDROM`, 10 attempts × 5s)
   - Copy new kubeadm from ISO → `/opt/bin`
   - Import new container images from ISO
   - Update CNI plugins and crictl from ISO
   - Run `kubeadm upgrade apply` (first control) or `kubeadm upgrade node` (others)
   - Copy new kubelet + kubectl from ISO → `/opt/bin`
   - Restart kubelet
   - Re-apply CNI and dashboard manifests (first control only)
   - Unmount and eject ISO
4. **Uncordon** the node via `kubectl uncordon`
5. **Wait for node Ready** (control nodes only)
6. **Verify version** — run `kubectl get nodes` and check the reported version matches the target; update `KubernetesClusterVmMapVO.nodeVersion` in DB

After all nodes complete: detach ISO, update `KubernetesClusterVO.kubernetesVersionId`, transition to `Running`.

On failure: detach ISOs from all nodes, throw `OperationFailed`. **Already-upgraded nodes are NOT rolled back.**

#### 6.1.2.2 Most Likely Failure Points

Since the flow is sequential and CloudStack has full visibility, the most likely causes are:

**1. `kubectl drain` fails on a worker**

The worker node has pods that can't be evicted (e.g., pods with `emptyDir` volumes, missing tolerations, or resource pressure). The drain is retried up to 3 times with 30-second waits. If it still fails, the upgrade aborts.

**2. ISO attachment fails for a worker**

CloudStack attaches the new ISO to each VM sequentially. If the hypervisor fails to attach the ISO to a worker (timeout, storage issue, or VM state problem), the `upgrade-kubernetes.sh` script on that node can't find the ISO and fails.

**3. `upgrade-kubernetes.sh` fails on a worker**

Possible sub-cases:
- **ISO not found** — the `blkid` poll times out (ISO not attached or wrong label)
- **Binary copy fails** — insufficient disk space on `/opt/bin`, permission denied
- **Image import fails** — containerd is not running, or the ISO's image tar files are corrupted
- **`kubeadm upgrade node` fails** — preflight checks fail, kubelet can't start with new config, or the node's existing kubeadm config is incompatible
- **kubelet restart fails** — containerd fails to restart, or the new kubelet can't connect to the API server

**4. Health check pod fails — pause container version mismatch**

After the control plane completes its upgrade, kubeadm creates a temporary **upgrade health check Job** to verify the cluster is healthy before proceeding to worker nodes. This Job gets scheduled on a non-upgraded worker node.

The health check pod uses the `pause` container as its base image. If the target K8s version introduces a new pause container version (e.g., `pause:3.10` → `pause:3.10.1` in K8s 1.34.x), the worker node still running the old K8s version only has the old pause image in its local containerd store. CKS only imports new images onto the node currently being upgraded, so the worker node lacks the new pause image.

- **With internet:** the worker pulls the new pause image from an external registry → health check passes → upgrade proceeds.
- **Without internet:** the pull fails, the container is terminated, Kubernetes retries → infinite loop → upgrade stalls and eventually times out.

This is the root cause of offline upgrade failures when a new pause container version is introduced. See [CKS Offline Guide → Pause Container Issue](./cks-offline.md#pre-built-calico-iso---pause-container-issue) for details and workarounds.

**5. Uncordon fails — node never becomes Ready**

After the upgrade script completes, CloudStack runs `kubectl uncordon` and polls for the node to reach `Ready` state. If the node is stuck (e.g., kubelet is running but can't register, or the node has `NotReady` conditions), the poll eventually times out.

**6. Version verification fails**

CloudStack runs `kubectl get nodes` and checks the reported version against the target. If the node reports a different version (e.g., the upgrade script partially succeeded but kubelet is still on the old version), the verification fails.

#### 6.1.2.3 What Partial Upgrades Mean

If the control plane upgrade succeeds but worker upgrades fail, the cluster is in a **partially upgraded state**. This doesn't violate Kubernetes version skew policy — workers are allowed to remain temporarily on an older supported version. However:

- Already-upgraded control plane nodes are at the new version
- Un-upgraded worker nodes are still on the old version
- The cluster may have missing system components (new CNI, new CSI) on workers
- CloudStack's DB still shows the old version (upgrade failed before the final DB update)

#### 6.1.2.4 What to Do

The practical approach is **manual recovery** (see [Section 6.1.1](#611-manual-recovery-steps)). This bypasses CloudStack's upgrade flow entirely and brings each worker node to the target version directly. After manual recovery, the cluster is healthy and functional — the only remaining issue is CloudStack's stale version tracking, which can be resolved by triggering a no-op upgrade or (as a last resort) updating the database.

> **Note:** For clusters stuck in "Starting" during bootstrap (dashboard verification failures, CCM/CSI not deployed), see [CKS Setup Guide → Troubleshooting: Cluster Stuck in "Starting"](./cks.md#cluster-stuck-in-starting-with-kubeconfig-available).

### 6.2 Cilium Can't Reach API Server After Upgrade to 1.19.x

Upgrading Cilium from **1.18.x** (e.g., 1.18.10) to **1.19.x** (e.g., 1.19.4) can cause the Cilium DaemonSet pods to crash-loop with `Init:Error`. The logs show repeated attempts to connect to the Kubernetes API server at `https://10.96.0.1:443` that fail with:

```
level=error msg="Unable to contact k8s api-server" subsys=cilium-dbg module=k8s-client ipAddr=[https://10.96.0.1:443](https://10.96.0.1/)
    error="Get \"https://10.96.0.1:443/api/v1/namespaces/kube-system\": dial tcp 10.96.0.1:443: connect: operation not permitted"
level=error msg="Start hook failed" ... error="Get \"https://10.96.0.1:443/api/v1/namespaces/kube-system\": dial tcp 10.96.0.1:443: connect: operation not permitted"
```

**Root cause:** Cilium 1.19+ changed how it resolves the API server endpoint. The default `ClusterIP` address (`10.96.0.1`) may become unreachable due to network policy changes or kernel restrictions, especially when Cilium itself is responsible for that traffic (chicken-and-egg problem during init).

**Solution:** Ensure Cilium is managed by Helm, then explicitly set the API server endpoint to a publicly reachable IP and port instead of the default ClusterIP.

1. **Take ownership with Helm** (if Cilium was not originally installed via Helm):
   ```bash
   CILIUM_VERSION="1.18.2"
   helm repo add cilium https://helm.cilium.io/
   helm upgrade --install cilium cilium/cilium --version ${CILIUM_VERSION} \
     --namespace kube-system \
     --set kubeProxyReplacement=true \
     --take-ownership
   ```
2. **Upgrade to the target Cilium version, pointing at a reachable API server:**
   ```bash
   helm upgrade cilium cilium/cilium \
     -n kube-system \
     --version 1.19.4 \
     --reuse-values \
     --set k8sServiceHost=192.168.1.10 \
     --set k8sServicePort=6443
   ```

> **Notes:**
> - Replace `192.168.1.10` with your CloudStack management server's (or K8s API endpoint's) reachable IP.
> - Replace `6443` if your API server listens on a different port.
> - The `--take-ownership` flag is only needed the first time you bring Cilium under Helm management. Subsequent upgrades use `--reuse-values` alone.

## 7. CNI Management

CNI is bundled into the CKS ISO and upgrades automatically with the K8s version. You only need to manage CNI separately when you want to **upgrade CNI independently** of the CKS upgrade (e.g., testing a newer CNI version before the next CKS release).

### 7.1 Re-apply Manifests

For minor version bumps or switching CNI versions without rebuilding the ISO:

1. Upgrade K8s version via CloudStack (upgrades everything else automatically)
2. Re-apply CNI manifests to get the desired CNI version

### 7.2 Rebuild the ISO

| Scenario | Approach |
|----------|----------|
| CNI minor version bump (e.g., Calico 3.28 → 3.29) | Re-apply manifests |
| CNI major version bump (e.g., Calico 3.x → 4.x) | Rebuild ISO |
| Switching CNI (e.g., Calico → Cilium) | Rebuild ISO |
| Custom CNI parameters | Use CNI configuration (ACS 4.21+) or rebuild ISO |

## 8. OS Upgrades

The CKS ISO upgrade updates Kubernetes components (kubelet, kubeadm, containerd, CNI, CSI, CCM) but does **not** update the underlying operating system. OS-level updates must be managed separately.

Since CKS manages nodes in-place, OS upgrades are also performed **in-place** on existing nodes:

1. **Stop the kubelet** on the node:
   ```bash
   ssh -i <key> -p <port> cloud@<node-ip>
   sudo -i
   systemctl stop kubelet
   ```

2. **Perform the OS upgrade** (e.g., `yum update` or `apt upgrade`)

3. **Reboot the node** if the kernel or core libraries were updated

4. **Start the kubelet** after reboot:
   ```bash
   systemctl start kubelet
   ```

5. **Verify the node** is back online and healthy:
   ```bash
   kubectl get nodes
   ```

> **Note:** OS security updates can generally be applied independently of CKS upgrades. The Kubernetes [version skew policy](https://kubernetes.io/releases/version-skew-policy/) governs K8s component compatibility (kubelet ↔ API server), not OS versions. The main operational concern is that kernel updates require a reboot, which briefly impacts the node. Creating snapshots before OS upgrades is recommended as a safety measure.

## 9. Related

- [CKS Setup Guide](./cks.md) — initial cluster deployment
- [CKS Custom ISO Build Guide](./cks-custom-iso.md) — building CKS-compatible ISOs
- [CAPC Upgrade Guide](../capc/capc-upgrade.md) — CAPC cluster upgrade procedures
- [CNI Automation Options](../capc/cni-automation-options.md) — automating CNI installation
