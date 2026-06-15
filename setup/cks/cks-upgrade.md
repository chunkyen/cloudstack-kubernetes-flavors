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

#### Why the Health Check Job Fails

The upgrade health check job is created by kubeadm during the upgrade process to verify cluster health. It runs on the control plane and checks if **all nodes are Ready** and at the correct version.

When the control plane upgrade succeeds but worker nodes fail to upgrade, the health check job will keep failing because:

1. The health check job was created when worker nodes were still at the old version
2. Kubernetes enforces version skew policies — the API server (new version) and kubelet (old version) are incompatible
3. The health check job will never pass until all worker nodes are upgraded to match the control plane

This is why manual recovery on worker nodes is necessary — you're bringing the worker nodes to the same version as the control plane, which allows the health check job to eventually pass (or be recreated by the next upgrade attempt).

## Troubleshooting: Cluster Stuck in "Starting" with Kubeconfig Available

A common failure mode: the CKS UI shows the kubeconfig is available and downloadable, but the cluster remains in `Starting` state indefinitely. Only the core Kubernetes components (kube-apiserver, etcd, controller-manager, scheduler, CoreDNS, CNI) are deployed — CCM, CSI driver, and dashboard are **not** deployed.

### Root Cause: Dashboard Verification Blocking the Post-Bootstrap Pipeline

The issue is an **ordering dependency** in the post-bootstrap verification sequence. Look at the exact order in `startKubernetesClusterOnCreate()`:

```
Step 5: ✅ isKubernetesClusterKubeConfigAvailable()    ← KUBECONFIG IS AVAILABLE HERE
Step 6: ❌ isKubernetesClusterDashboardServiceRunning() ← STALLS HERE
Step 7:    taintControlNodes()                          ← NEVER REACHED
Step 8:    deployProvider()                             ← CCM NEVER DEPLOYED
Step 9:    deployCsiDriver()                            ← CSI NEVER DEPLOYED
Step 10:   stateTransitTo(OperationSucceeded)           ← STILL "STARTING"
```

### Why CCM, CSI, and Dashboard Are Missing

**The dashboard, CCM, and CSI come from different deployers at different times:**

| Component | Who deploys it | When | Deployed? |
|-----------|---------------|------|-----------|
| kube-apiserver, etcd, scheduler, controller-manager | `kubeadm init` (cloud-init) | Before step 5 | ✅ Yes |
| CoreDNS | `kubeadm init` (built-in addon) | Before step 5 | ✅ Yes |
| Calico CNI | `kubectl apply -f network.yaml` (cloud-init) | Before step 5 | ✅ Yes |
| Headlamp/Dashboard | `kubectl apply -f headlamp.yaml` or `dashboard.yaml` (cloud-init) | Before step 5 | ⚠️ Applied but **pod not Running** |
| **CloudStack Provider (CCM)** | `deployProvider()` (management server via SSH+SCP) | **Step 8** | ❌ Never reached |
| **CSI Driver** | `deployCsiDriver()` (management server via SSH+SCP) | **Step 9** | ❌ Never reached |
| Control node taints | `taintControlNodes()` (management server via SSH) | **Step 7** | ❌ Never reached |

The dashboard is applied by cloud-init (`deploy-kube-system` service) during VM bootstrap. CCM and CSI are deployed later by the management server via SSH+SCP. If the flow stalls at step 6, CCM and CSI **cannot possibly** be deployed.

### How the Dashboard Check Works (4.22.1 vs main/4.23.0)

**In 4.22.1** (your version), the check is hardcoded to Kubernetes Dashboard only:

```java
// KubernetesClusterUtil.java (4.22.1)
public static boolean isKubernetesClusterDashboardServiceRunning(..., String ipAddress, int sshPort, String loginUser, File sshKeyFile, long timeoutTime, long waitDuration) {
    while (System.currentTimeMillis() < timeoutTime) {
        if (isKubernetesClusterAddOnServiceRunning(..., "kubernetes-dashboard", "kubernetes-dashboard")) {
            running = true;
            break;
        }
        Thread.sleep(waitDuration);  // 15 seconds
    }
    return running;
}
```

Where `isKubernetesClusterAddOnServiceRunning` does:

```java
// SSH into control node:
String cmd = "sudo /opt/bin/kubectl get pods --namespace=kubernetes-dashboard";
// Parse output: find a line containing BOTH "kubernetes-dashboard" AND "Running"
if (line.contains("kubernetes-dashboard") && line.contains("Running")) {
    return true;
}
```

There is **no Headlamp fallback** in 4.22.1. The namespace is `kubernetes-dashboard` (not `kube-system`).

**In main branch (unreleased 4.23.0)**, the check was changed to try Headlamp first (`kube-system` namespace, service name `"headlamp"`), then fall back to Kubernetes Dashboard. This is the PR #12776 change — not yet released.

### ⚠️ Critical: Version Mismatch Between ISO Build Script and Management Server

| Component | 4.22.1 (stable — what you run) | main branch (unreleased 4.23.0) |
|-----------|-------------------------------|----------------------------------|
| Cloud-init deploys | `dashboard.yaml` | `headlamp.yaml` (fallback: `dashboard.yaml`) |
| Dashboard namespace | `kubernetes-dashboard` | `kube-system` → `kubernetes-dashboard` |
| Service name check | `kubernetes-dashboard` | `headlamp` → `kubernetes-dashboard` |
| ISO expected file | `dashboard.yaml` | `headlamp.yaml` (primary) |

Your ISO build script (`create-kubernetes-binaries-iso.sh`) matches the **main branch** — it downloads `headlamp.yaml` but **never downloads `dashboard.yaml`**. However, 4.22.1's cloud-init only applies:

```bash
/opt/bin/kubectl apply -f ${K8S_CONFIG_SCRIPTS_COPY_DIR}/dashboard.yaml
```

**`dashboard.yaml` does not exist on your ISO.** The failure chain:

1. `setup-kube-system` copies all `*.yaml` from ISO → `/tmp/k8sconfigscripts/` (success: `network.yaml`, `headlamp.yaml` garbage, `provider.yaml`, etc.)
2. `deploy-kube-system` takes the offline path (directory exists) and runs: `kubectl apply -f dashboard.yaml`
3. **Fails**: `error: the path "/tmp/k8sconfigscripts/dashboard.yaml" does not exist`
4. `#!/bin/bash -e` → script exits immediately
5. systemd `Restart=on-failure` → restarts, `kubeadm init` fails (cluster already initialized) → exits
6. **Infinite restart loop** — `touch /home/cloud/success` never reached

The Headlamp 404 problem below is a secondary issue that would cause the same symptoms if you were running 4.23.0. On 4.22.1, even a valid `headlamp.yaml` wouldn't help because the cloud-init never looks at it.

### Common Reasons the Dashboard Pod Isn't Running (4.22.1)

#### 1. ISO Build Script Produces headlamp.yaml Instead of dashboard.yaml (MOST LIKELY)

This is the primary issue when using a build script from the `main` branch with a 4.22.1 management server. See the **Version Mismatch** section above for full details.

In short: 4.22.1's cloud-init applies `dashboard.yaml`, but your ISO only has `headlamp.yaml` (which may also be 404 garbage HTML). The `kubectl apply -f dashboard.yaml` command fails because the file doesn't exist.

**Diagnose on the control node:**
```bash
# Confirm dashboard.yaml is missing
ls -la /tmp/k8sconfigscripts/dashboard.yaml 2>/dev/null || echo "MISSING — this is why the cluster fails"

# Check what's in headlamp.yaml (likely HTML garbage from 404)
head -3 /tmp/k8sconfigscripts/headlamp.yaml 2>/dev/null

# Check deploy-kube-system logs for the exact failure
sudo journalctl -u deploy-kube-system --no-pager -n 20
```

**Fix**: Add `dashboard.yaml` download to your build script (see Prevention section below).

#### 2. Headlamp URL Returns 404 (Secondary — only affects 4.23.0+)

Even if you match your build script to 4.22.1 by adding `dashboard.yaml`, the current build script still downloads Headlamp from a URL that no longer exists:

```bash
HEADLAMP_DASHBOARD_URL="https://raw.githubusercontent.com/kubernetes-sigs/headlamp/v${HEADLAMP_DASHBOARD_VERSION}/kubernetes-headlamp.yaml"
curl -sSL ${HEADLAMP_DASHBOARD_URL} -o ${headlamp_conf_file}
```

Headlamp removed standalone `kubernetes-headlamp.yaml` from their releases. The URL returns 404. Because `curl -sSL` (without `-f`) returns exit code 0 even on 404, the HTML error page is saved as `headlamp.yaml` — garbage. The build script also tries to extract images from this garbage file via `grep "image:"`, which finds nothing, so **no Headlamp images are downloaded**.

This is harmless on 4.22.1 (since the cloud-init ignores `headlamp.yaml`), but would cause a failure on 4.23.0 where Headlamp is the primary dashboard.

#### 3. Image Reference Mismatch

For cases where a valid headlamp.yaml IS obtained but the pod doesn't start: the ISO build script extracts images from YAML manifests with:

```bash
images=`grep "image:" $i | cut -d ':' -f2- | tr -d ' ' | tr -d "'"`
```

If the Headlamp manifest has init containers or multi-line image references not matching this simple grep, those images won't be in the ISO.

**Diagnose on the control node:**
```bash
sudo /opt/bin/kubectl get pods -n kube-system | grep headlamp
sudo /opt/bin/kubectl describe pod -n kube-system <headlamp-pod-name> | grep -A5 "Events:"
```

If you see `Failed to pull image` or `ErrImagePull`, use `crictl images` on the node to verify the image is actually loaded.

#### 4. Pod in ContainerCreating or Pending

The pod might be waiting for a PV to bind, or a volume to mount. Check:
```bash
sudo /opt/bin/kubectl describe pod -n kube-system <headlamp-pod-name>
```

Look for `Warning` events about volumes, scheduling, or network.

#### 5. CrashLoopBackOff

The pod starts but crashes immediately. Causes could be:
- RBAC issues (service account permissions)
- Config errors in the deployment manifest
- Resource limits too low

Check logs:
```bash
sudo /opt/bin/kubectl logs -n kube-system <headlamp-pod-name> --previous
```

#### 6. deploy-kube-system Service Failed Silently

The `deploy-kube-system` systemd service has `Restart=on-failure`. If it fails (e.g., `kubeadm init` fails on restart because the cluster is already initialized), it restarts, but `kubeadm init` fails again, creating a loop. The `kubectl apply -f headlamp.yaml` line is never reached.

**Check on the control node:**
```bash
sudo systemctl status deploy-kube-system
sudo journalctl -u deploy-kube-system --no-pager | tail -50
cat /home/cloud/success   # if this file exists and contains "true", cloud-init completed
```

### Manual Recovery (4.22.1)

If the cluster is otherwise healthy (all nodes Ready, API server responding), you can manually deploy the dashboard and everything else the management server would have:

```bash
# 1. Deploy Kubernetes Dashboard (what 4.22.1 expects)
sudo /opt/bin/kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml

# 2. Deploy CloudStack Provider (CCM)
sudo /opt/bin/kubectl apply -f /opt/provider/provider.yaml

# 3. Create cloudstack-secret if needed
# (the deploy-cloudstack-secret script should be at /opt/bin/)

# 4. Deploy CSI driver
sudo /opt/bin/kubectl apply -f /opt/csi/snapshot-crds.yaml
sudo /opt/bin/kubectl apply -f /opt/csi/manifest.yaml

# 5. Taint control nodes
sudo /opt/bin/kubectl annotate node <control-node-name> \
  cluster-autoscaler.kubernetes.io/scale-down-disabled=true

# 6. Verify dashboard is running (what the management server checks)
sudo /opt/bin/kubectl get pods -n kubernetes-dashboard | grep kubernetes-dashboard
```

Note: The management server already transitioned the cluster to `OperationFailed` — the state won't auto-recover. You'd need to destroy and recreate the cluster, or manually update the DB.

### Prevention (Build Script Fixes for 4.22.1)

1. **Add `dashboard.yaml` download** to your ISO build script:
   ```bash
   DASHBOARD_URL="https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml"
   dashboard_conf_file="${working_dir}/dashboard.yaml"
   curl -fsSL ${DASHBOARD_URL} -o ${dashboard_conf_file}
   ```

2. **Add `-f` flag to all curl commands** so the build fails on 404:
   ```bash
   curl -fsSL ${URL} -o ${output_file}  # -f = fail on HTTP errors
   ```

3. **Validate downloaded YAML** before packaging:
   ```bash
   python3 -c "import yaml; yaml.safe_load(open('${file}'))" || { echo "Invalid YAML: ${file}"; exit 1; }
   ```

4. **Match the build script to your CloudStack version** — if you're on 4.22.1, use a build script that produces `dashboard.yaml` (not `headlamp.yaml`)

5. **Include dashboard images** in the image extraction loop:
   ```bash
   for i in ${network_conf_file} ${dashboard_conf_file}
   do
     images=`grep "image:" $i | cut -d ':' -f2- | tr -d ' ' | tr -d "'"`
     output=`printf "%s\n" ${output} ${images}`
   done
   ```

6. **Verify expected files exist** before creating the ISO:
   ```bash
   for required_file in network.yaml dashboard.yaml provider.yaml; do
       [ -f "${required_file}" ] || { echo "Missing: ${required_file}"; exit 1; }
   done
   ```

## CNI Management

CNI is bundled into the CKS ISO and upgrades automatically with the K8s version. You only need to manage CNI separately when you want to **upgrade CNI independently** of the CKS upgrade (e.g., testing a newer CNI version before the next CKS release).

### Re-apply Manifests

For minor version bumps or switching CNI versions without rebuilding the ISO:

1. Upgrade K8s version via CloudStack (upgrades everything else automatically)
2. Re-apply CNI manifests to get the desired CNI version

### Rebuild the ISO

| Scenario | Approach |
|----------|----------|
| CNI minor version bump (e.g., Calico 3.28 → 3.29) | Re-apply manifests |
| CNI major version bump (e.g., Calico 3.x → 4.x) | Rebuild ISO |
| Switching CNI (e.g., Calico → Cilium) | Rebuild ISO |
| Custom CNI parameters | Use CNI configuration (ACS 4.21+) or rebuild ISO |

## OS Upgrades

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

## Related

- [CKS Setup Guide](./cks.md) — initial cluster deployment
- [CKS Custom ISO Build Guide](./cks-custom-iso.md) — building CKS-compatible ISOs
- [CAPC Upgrade Guide](../capc/capc-upgrade.md) — CAPC cluster upgrade procedures
- [CNI Automation Options](../capc/cni-automation-options.md) — automating CNI installation
