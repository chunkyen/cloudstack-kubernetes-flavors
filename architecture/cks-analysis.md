# CKS Detailed Analysis — Bootstrap & Upgrade

## Overview

The CKS (CloudStack Kubernetes Service) bootstrap process provisions and configures a fully operational Kubernetes cluster on CloudStack-managed infrastructure. It orchestrates VM creation, networking, and Kubernetes installation using cloud-init and a pre-built binaries ISO.

**Source:** [`plugins/integrations/kubernetes-service/`](https://github.com/apache/cloudstack/tree/main/plugins/integrations/kubernetes-service)

---

## High-Level Architecture

```
User API Call → CreateKubernetesClusterCmd
  → KubernetesClusterManagerImpl.createManagedKubernetesCluster()
    → Validates & creates DB record
    → KubernetesClusterStartWorker.startKubernetesClusterOnCreate()
      → [Network Setup → VM Provisioning → Network Rules → ISO Attach → cloud-init boots k8s → Verify → Done]
```

### Key Classes

| Class | File | Role |
|-------|------|------|
| `KubernetesClusterService` | `KubernetesClusterService.java` | Interface defining all CKS operations and ConfigKeys |
| `KubernetesClusterManagerImpl` | `KubernetesClusterManagerImpl.java` | Orchestrator: validates params, creates DB records, dispatches to workers |
| `KubernetesClusterActionWorker` | `actionworkers/KubernetesClusterActionWorker.java` | Base class: SSH execution, script management, ISO attach/detach, state machine |
| `KubernetesClusterResourceModifierActionWorker` | `actionworkers/KubernetesClusterResourceModifierActionWorker.java` | Capacity planning, VM creation/start/resize |
| `KubernetesClusterStartWorker` | `actionworkers/KubernetesClusterStartWorker.java` | Provisions VMs, network rules, ISO, and verifies cluster |
| `KubernetesClusterUtil` | `utils/KubernetesClusterUtil.java` | Utilities: kubeconfig retrieval, API server checks, SSH execution, token generation |

---

## Phase 1: Prerequisites & Configuration

### Required Global Settings (ConfigKeys)

Defined in `KubernetesClusterService.java`:

| ConfigKey | Default | Description |
|-----------|---------|-------------|
| `cloud.kubernetes.service.enabled` | `true` | Master switch for CKS plugin |
| `cloud.kubernetes.cluster.network.offering` | `DefaultNetworkOfferingforKubernetesService` | Name of the network offering for cluster isolated networks |
| `cloud.kubernetes.cluster.start.timeout` | `3600` | Timeout (seconds) for cluster start operation |
| `cloud.kubernetes.control.node.install.attempt.wait.duration` | `15` | Seconds between re-attempts for offline install on control nodes |
| `cloud.kubernetes.control.node.install.reattempt.count` | `100` | Max re-attempts for offline install on control nodes |
| `cloud.kubernetes.worker.node.install.attempt.wait.duration` | `30` | Seconds between re-attempts for offline install on worker nodes |
| `cloud.kubernetes.worker.node.install.reattempt.count` | `40` | Max re-attempts for offline install on worker nodes |
| `cloud.kubernetes.cluster.max.size` | `10` | Maximum cluster size (per-account scope) |
| `cloud.kubernetes.cluster.experimental.features.enabled` | `false` | Enables docker private registry support |
| `cloud.kubernetes.etcd.node.start.port` | `50000` | Start port for etcd node port forwarding rules |

### Required Infrastructure

1. **Binaries ISO**: Created by `create-kubernetes-binaries-iso.sh`, registered as a CloudStack template
2. **Kubernetes Supported Version**: A `KubernetesSupportedVersionVO` record linking a semantic version to an ISO template ID
3. **Network Offering**: Must support SourceNat, DHCP, UserData, Firewall, PortForwarding
4. **Service Offering**: Per-node-type compute specs (min 2 CPU, 2048 MB RAM, non-dynamic)
5. **System VM Template**: Base OS image for cluster VMs

---

## Phase 2: API Validation

When `CreateKubernetesClusterCmd` is received, the following validations run:

### Zone Validation
- Zone must exist and be in `Enabled` allocation state
- Edge zones require a pre-existing network (cannot auto-create)

### Network Validation
- Must support `UserData` and `DHCP` services
- Must support `Firewall` (for non-VPC) and `PortForwarding`
- VPC tiers must not use `Default Deny` ACL
- Isolated networks require SourceNAT IP
- Pre-existing firewall/port-forwarding rules must not conflict with CKS ports (6443 API, 2222-2222+N SSH)

### Service Offering Validation
- Must be non-dynamic (fixed-size)
- Must meet minimums: 2 vCPU, 2048 MB RAM
- Must meet Kubernetes version-specific minimums

### Other Validations
- SSH keypair must exist for the account (if specified)
- Docker registry params must be all-or-nothing (username + password + URL)
- External load balancer IP must be valid IPv4 or IPv6

---

## Phase 3: Cluster DB Record Creation

Creates a `KubernetesClusterVO` with:
- **Identity**: name, zone, account, domain
- **Topology**: control node count, worker node count, etcd node count
- **Templates**: default template + per-node-type overrides (control, worker, etcd)
- **Service Offerings**: default offering + per-node-type overrides
- **Kubernetes Version**: linked `KubernetesSupportedVersionVO` (which references the binaries ISO)
- **Network**: network ID, CNI config, CSI enabled flag
- **Security**: SSH keypair name, docker registry credentials
- **State**: `Created`

### Two Initial Paths

- `createManagedKubernetesCluster()` → immediately calls `startKubernetesClusterOnCreate()`
- `createUnmanagedKubernetesCluster()` → creates the DB record only, cluster is externally managed

---

## Phase 4: Actual Bootstrap Sequence

The method `KubernetesClusterStartWorker.startKubernetesClusterOnCreate()` executes the following steps **in order**:

### 4.1 State Transition
```
Created → StartRequested
```

### 4.2 Capacity Planning
`planKubernetesCluster()` evaluates each node type separately:

1. Lists all routing hosts in the zone, filtered by hypervisor type and CPU architecture
2. Checks dedicated host / explicit dedication affinity groups
3. For each host, checks:
   - Host tags match service offering tags
   - CPU and RAM capacity (with overcommit ratios)
   - Anti-affinity constraints (no two nodes of same type on same host if configured)
4. Returns `Map<NodeType, DeployDestination>` per node type

### 4.3 Network Startup
```
startKubernetesClusterNetwork()
  → networkMgr.startNetwork(network.getId(), destination, context)
```
- Starts the isolated network or VPC tier
- Virtual Router (VR) comes up and provides DHCP, DNS, SourceNAT

### 4.4 Public IP Acquisition
```
getKubernetesClusterServerIpSshPort(null, acquireNew=true)
```

**Isolated network**: Uses the SourceNAT IP already assigned to the network

**VPC tier**: 
1. Allocates a new public IP via `networkService.allocateIP()`
2. Associates it to the VPC via `vpcService.associateIPToVpc()`
3. Associates it to the guest network via `ipAddressManager.associateIPToGuestNetwork()`

**Shared network / Direct access**: Uses the VM's private IP directly

---

## Phase 5: ISO Attachment

```
attachIsoKubernetesVMs(etcdVms)
attachIsoKubernetesVMs(clusterVMs)
```

The ISO is attached **after** all VMs are already running. The cloud-init scripts inside the VMs poll-wait for it.

### Sequential Attachment Order

The `attachIsoKubernetesVMs` method iterates through VMs one at a time — each call blocks until the hypervisor completes the attachment:

```
etcd node 0 → wait → etcd node 1 → wait → ...
  ↓ (all etcd nodes)
control node 0 → wait → control node 1 (HA) → wait → ...
  ↓ (all control nodes)
worker node 0 → wait → worker node 1 → wait → ...
```

This is why the cloud-init polling timeouts are so generous (~25 min for control/etcd nodes, ~20 min for workers).

---

## Phase 6: In-VM Bootstrap (cloud-init)

### 6.1 The Polling Wait
All node types run a polling loop looking for the ISO:

```bash
offline_attempts=1
while true; do
    if (( "$offline_attempts" > "$MAX_OFFLINE_INSTALL_ATTEMPTS" )); then
        echo "Warning: Offline install timed out!"
        break
    fi
    output=`blkid -o device -t LABEL=CDROM`
    if [ "$output" != "" ]; then
        mount -o ro "${line}" "${ISO_MOUNT_DIR}"
        if [ -d "$BINARIES_DIR" ]; then
            break   # ISO found and mounted!
        fi
    fi
    sleep $OFFLINE_INSTALL_ATTEMPT_SLEEP
    offline_attempts=$((offline_attempts + 1))
done
```

**Timing windows:**
| Node Type | Max Attempts | Sleep (s) | Total Wait |
|-----------|-------------|-----------|------------|
| Control   | 100         | 15        | ~25 minutes |
| Worker    | 40          | 30        | ~20 minutes |
| etcd      | 100         | 15        | ~25 minutes |

### 6.2 Binary Installation (`setup-kube-system` script)
Once the ISO is mounted at `/mnt/k8sdisk/`, it installs:
- CNI plugins → `/opt/cni/bin/`
- crictl → `/opt/bin/`
- Kubernetes binaries (kubeadm, kubelet, kubectl) → `/opt/bin/`
- Container images via `ctr image import`

### 6.3 Control Node Bootstrap (`deploy-kube-system` service)
A systemd oneshot that:
1. Runs `kubeadm init --config /etc/kubernetes/kubeadm-config.yaml --upload-certs`
2. Sets `KUBECONFIG=/etc/kubernetes/admin.conf`
3. Applies CNI: `kubectl apply -f /tmp/k8sconfigscripts/network.yaml`
4. Installs dashboard (4.22.1): `kubectl apply -f /tmp/k8sconfigscripts/dashboard.yaml`
5. Creates RBAC bindings
6. Marks completion: `touch /home/cloud/success`

### 6.4 Worker Node Bootstrap (`deploy-kube-system` service)
A systemd oneshot that:
1. Waits for API server: `curl -k https://<control-ip>:6443/version`
2. Runs: `kubeadm join <control-ip>:6443 --token *** --discovery-token-unsafe-skip-ca-verification`
3. Marks completion: `touch /home/cloud/success`

---

## Phase 7: Post-Bootstrap Verification (Management Server)

The management server performs the following verification steps sequentially after cloud-init reports success:

### 7.1 Control VM Accessibility
```java
KubernetesClusterUtil.isKubernetesClusterControlVmRunning(
    kubernetesCluster, publicIpAddress, sshPort, startTimeoutTime)
```
- SSHs into the control VM to verify it's running and reachable
- For HA + direct-access networks: requires external load balancer with port forwarding configured

### 7.2 API Server Health
```java
KubernetesClusterUtil.isKubernetesClusterServerRunning(
    kubernetesCluster, publicIpAddress, 6443, startTimeoutTime, 15000)
```
- Polls `https://<public-ip>:6443` with 15-second connect timeout
- Retries until the API server responds or the start timeout expires

### 7.3 Node Readiness
```java
KubernetesClusterUtil.validateKubernetesClusterReadyNodesCount(
    kubernetesCluster, publicIpAddress, sshPort, loginUser, sshKeyFile,
    startTimeoutTime, 15000)
```
- Runs `kubectl get nodes` via SSH
- Verifies all expected nodes are in `Ready` state

### 7.4 ISO Detachment
```
detachIsoKubernetesVMs(clusterVMs)
```
- Removes the binaries ISO from all cluster VMs

### 7.5 Kubeconfig Retrieval
```java
isKubernetesClusterKubeConfigAvailable(startTimeoutTime)
```
- Fetches `/etc/kubernetes/admin.conf` from the control node via SSH
- Replaces private IP with public IP in the server URL
- Stores base64-encoded in `KubernetesClusterDetailsVO` with key `kubeConfigData`

### 7.6 Dashboard Verification
```java
isKubernetesClusterDashboardServiceRunning(onCreate=true, startTimeoutTime)
```
- Checks `kubectl get pods -n kubernetes-dashboard` for dashboard pod in Running state (4.22.1)
- For unreleased 4.23.0+: tries Headlamp first (`kube-system` namespace), then falls back to Kubernetes Dashboard

### 7.7 Control Node Tainting
```
taintControlNodes()
```
- Runs on each control node: 
  ```
  kubectl annotate node <name> cluster-autoscaler.kubernetes.io/scale-down-disabled=true
  ```
- Retries up to 3 times with 5s delay

### 7.8 CloudStack Provider Deployment
```
deployProvider()
```
- SCPs `deploy-cloudstack-secret`, `deploy-provider`, `deploy-csi-driver`, `autoscale-kube-cluster`, `delete-pv-reclaimpolicy-delete` scripts to `/opt/bin/` on the control node
- Creates `cloudstack-secret` in `kube-system` namespace:
  ```bash
  kubectl -n kube-system create secret generic cloudstack-secret \
    --from-file=/tmp/cloud-config
  ```
  where `cloud-config` contains:
  ```ini
  [Global]
  api-url = <CloudStack API URL>
  api-key = <API key>
  secret-key = <Secret key>
  project-id = <Project UUID>  # if project account
  ```
- Applies the provider manifest from `provider.yaml` (imported from ISO)
- For isolated networks only (provider manages CloudStack IPs)

### 7.9 CSI Driver Deployment (optional)
```
deployCsiDriver()
```
- Applies CSI snapshot CRDs and driver manifest from ISO
- Creates CloudStack secret if not already present

### 7.10 Login User Detail Update
```
updateLoginUserDetails(clusterVMs)
```
- Adds VM detail `CKS_CONTROL_NODE_LOGIN_USER = "cloud"` for each VM

### 7.11 Final State Transition
```
StartRequested → Running (via OperationSucceeded event)
```

### 7.12 Cluster Endpoint Update
```
updateKubernetesClusterEntryEndpoint()
```
- Sets `kubernetesCluster.setEndpoint("https://<publicIp>:6443/")`

---

## Management Server ↔ Cluster Communication

The CloudStack management server communicates with the CKS cluster through **two channels**: SSH (primary) and HTTPS (API health check only).

### Channel 1: SSH (Primary — All kubectl Operations)

All post-bootstrap verification, configuration, and ongoing management is done by SSHing into the control node and running `kubectl` commands remotely.

#### How SSH Access is Established

**1. SSH key injection via cloud-init**

Every node's cloud-init template writes the management server's SSH public key into the `cloud` user's authorized_keys:

```yaml
# From k8s-control-node.yml, k8s-node.yml, etcd-node.yml
users:
- name: cloud
  sudo: ALL=(ALL) NOPASSWD:***
  shell: /bin/bash
  ssh_authorized_keys:
  {{ k8s.ssh.pub.key }}     # ← Management server key + optional user keypair
```

The `{{ k8s.ssh.pub.key }}` placeholder is replaced at template rendering time with:

```java
String pubKey = "- \"" + configurationDao.getValue("ssh.publickey") + "\"";
// If the user specified an SSH keypair for the cluster:
if (StringUtils.isNotEmpty(sshKeyPair)) {
    SSHKeyPairVO sshkp = sshKeyPairDao.findByName(owner.getAccountId(), owner.getDomainId(), sshKeyPair);
    pubKey += "\n - \"" + sshkp.getPublicKey() + "\"";
}
```

**2. Management server's private key**

```java
// KubernetesClusterActionWorker.java
protected File getManagementServerSshPublicKeyFile() {
    boolean devel = Boolean.parseBoolean(configurationDao.getValue("developer"));
    String keyFile = String.format("%s/.ssh/id_rsa", System.getProperty("user.home"));
    if (devel) {
        keyFile += ".cloud";  // uses id_rsa.cloud in developer mode
    }
    return new File(keyFile);
}
```

So the management server authenticates with its own `~/.ssh/id_rsa` (or `id_rsa.cloud` in dev mode).

**3. How the IP and port are resolved**

The `getKubernetesClusterServerIpSshPort()` method determines the connection target based on network type:

| Network Type | IP Source | SSH Port | Path |
|-------------|-----------|----------|------|
| **Isolated** | SourceNAT public IP | 2222 | Via port forwarding `publicIP:2222 → VM:22` |
| **VPC tier** | VPC-tier public IP | 2222 | Via port forwarding `publicIP:2222 → VM:22` |
| **Shared / Direct** | VM private IP | 22 | Directly reachable, no NAT |
| **External LB** | `EXTERNAL_LOAD_BALANCER_IP_ADDRESS` detail | 2222 | User-provided load balancer |

### Channel 2: HTTPS (API Server Health Check Only)

For checking if the kube-apiserver is up, the management server directly calls the API server endpoint — no SSH needed:

```java
// KubernetesClusterUtil.java
public static boolean isKubernetesClusterServerRunning(...) {
    SSLContext sslContext = SSLUtils.getSSLContext();
    sslContext.init(null, new TrustManager[]{new TrustAllManager()}, new SecureRandom());
    URL url = new URL(String.format("https://%s:%d/version", ipAddress, port));
    HttpsURLConnection con = (HttpsURLConnection)url.openConnection();
    con.setSSLSocketFactory(sslContext.getSocketFactory());
    // read /version response...
}
```

Key details:
- URL: `https://<public-ip>:6443/version`
- Uses `TrustAllManager` — accepts the self-signed kube-apiserver certificate
- Polls every 15 seconds until the API server responds

### All Communication Operations (in order)

| Step | Method | Transport | What runs on the control node |
|------|--------|-----------|-------------------------------|
| **7.1** Control VM reachability | `isKubernetesClusterControlVmRunning()` | Raw TCP socket | `new Socket().connect(ip, port)` — just a TCP handshake |
| **7.2** API server health | `isKubernetesClusterServerRunning()` | HTTPS (TrustAll) | `GET https://<ip>:6443/version` |
| **7.3** Node readiness | `validateKubernetesClusterReadyNodesCount()` | SSH → kubectl | `sudo /opt/bin/kubectl get nodes \| grep -w 'Ready' \| wc -l` |
| **7.5** Kubeconfig retrieval | `getKubernetesClusterConfig()` | SSH → cat | `sudo cat /etc/kubernetes/user.conf 2>/dev/null \|\| sudo cat /etc/kubernetes/admin.conf` |
| **7.6** Dashboard check | `isKubernetesClusterDashboardServiceRunning()` | SSH → kubectl | `sudo /opt/bin/kubectl get pods --namespace=kube-system` (searches for "headlamp" or "kubernetes-dashboard") |
| **7.7** Control node taint | `taintControlNodes()` | SSH → kubectl | `sudo /opt/bin/kubectl annotate node <name> cluster-autoscaler.kubernetes.io/scale-down-disabled=true` |
| **7.8** Provider deployment | `deployProvider()` | SCP + SSH | SCP scripts to `/opt/bin/`, then `sudo /opt/bin/deploy-cloudstack-secret` → `kubectl create secret` → `kubectl apply -f provider.yaml` |
| **7.9** CSI deployment | `deployCsiDriver()` | SCP + SSH | SCP scripts, then `kubectl apply -f` CSI manifests |

### How Kubeconfig is Retrieved and Stored

The kubeconfig is fetched via SSH and stored in the CloudStack database for the user to download later:

```java
// Step 1: Fetch via SSH
Pair<Boolean, String> result = SshHelper.sshExecute(ipAddress, port, user,
    sshKeyFile, null,
    "sudo cat /etc/kubernetes/user.conf 2>/dev/null || sudo cat /etc/kubernetes/admin.conf",
    10000, 10000, 10000);

// Step 2: Replace private IP with public IP in the server URL
kubeConfig = kubeConfig.replace(
    String.format("server: https://%s:%d", controlVMPrivateIpAddress, CLUSTER_API_PORT),
    String.format("server: https://%s:%d", publicIpAddress, CLUSTER_API_PORT));

// Step 3: Store base64-encoded in DB
kubernetesClusterDetailsDao.addDetail(kubernetesCluster.getId(), "kubeConfigData",
    Base64.encodeBase64String(kubeConfig.getBytes()...), false);
```

After bootstrap, the user retrieves the kubeconfig via `GetKubernetesClusterConfigCmd` which:
1. Looks up the `kubeConfigData` detail from the DB
2. Base64-decodes it
3. Returns it to the user

### SSH Execution Details

All SSH operations use `SshHelper.sshExecute()` with these parameters:

| Parameter | Value |
|-----------|-------|
| User | `cloud` (retrieved via `getControlNodeLoginUser()`) |
| Key file | `~/.ssh/id_rsa` (or `id_rsa.cloud` in dev mode) |
| Connect timeout | 10,000 ms |
| KEX timeout | 10,000 ms |
| Command timeout | Varies (10,000–60,000 ms depending on operation) |

All kubectl commands use the absolute path `/opt/bin/kubectl` (not the system-installed one), since the binaries ISO installs everything to `/opt/bin/`.

---

## Cloud-init Templates Summary

### `k8s-control-node.yml`
- **Purpose**: First control plane node with external etcd
- **Key files written**:
  - `/etc/kubernetes/pki/cloudstack/{ca.crt, apiserver.crt, apiserver.key}` — TLS certs
  - `/etc/kubernetes/kubeadm-config.yaml` — kubeadm config with external etcd endpoints
  - `/opt/bin/setup-kube-system` — binary installation & containerd setup
  - `/opt/bin/deploy-kube-system` — `kubeadm init` + CNI + dashboard
  - `/opt/bin/setup-containerd` — (optional) private registry config
  - `/etc/systemd/system/deploy-kube-system.service` — oneshot service
- **runcmd**:
  - Configure containerd (`SystemdCgroup = true`)
  - Run setup-kube-system (poll-for-ISO + install binaries)
  - Run deploy-kube-system (kubeadm init + apply manifests)

### `k8s-control-node-add.yml`
- **Purpose**: Additional HA control plane nodes
- **Key difference**: Uses `kubeadm join` instead of `kubeadm init`, includes certificate key for `--control-plane --certificate-key`

### `k8s-node.yml`
- **Purpose**: Worker nodes
- **Key difference**: 
  - `deploy-kube-system` runs `kubeadm join` instead of `kubeadm init`
  - Has VR ISO download fallback (`wget` from `{{ k8s.vr.iso.mounted.ip }}`)
  - Includes `ExecStartPre=curl -k https://<control-ip>:6443/version` to wait for API server

### `etcd-node.yml`
- **Purpose**: External etcd nodes
- **Key differences**:
  - Polls for ISO by filesystem type (`TYPE=iso9660`) not label
  - Installs only etcd binary from ISO
  - Configures etcd as systemd service with `--initial-cluster` for peer discovery

---

## State Machine

```
                           CreateRequested
                                 │
                                 ▼
                             Created ──→ DestroyRequested → Destroyed
                                 │
                                 ▼
                          StartRequested
                                 │
                                 ▼
                              Starting
                              /      \
                             ▼        ▼
                    CreateFailed    Running
                                 /    │    \
                      UpgradeRequested │  ScaleUpRequested / ScaleDownRequested
                           │          │           │
                           ▼          │           ▼
                       Upgrading      │        Scaling
                        /    \        │       /      \
                       ▼      ▼       │      ▼        ▼
             OperationFailed  ────────┘  OperationFailed
                       \                /
                        ▼              ▼
                     OperationSucceeded
                            │
                            ▼
                          Running
                            │
                            ▼
                      StopRequested
                            │
                            ▼
                         Stopping
                         /      \
                        ▼        ▼
                OperationFailed  Stopped
```

**Key events:**
- `CreateRequested` → `Created`: Cluster DB record persisted
- `StartRequested` → `Starting`: Bootstrap begins (Phase 4)
- `OperationSucceeded` → `Running`: All checks passed (Phase 7)
- `CreateFailed` → Error state, ISOs detached: Bootstrap failed during create
- `OperationFailed` → Error state: Operation failed after cluster was running

### Scale State Machine

```
Running → ScaleUpRequested   / ScaleDownRequested   → Scaling
                                                        │
                                           OperationSucceeded → Running
                                           OperationFailed    → Error
```

### Scale Errors and Rollback

- **Scale-up failure**: `cleanupNewlyCreatedVms()` finds VMs that weren't in the original set and destroys/expunges them, removes their DB records
- **Scale-down failure**: If `kubectl drain` or `kubectl delete node` fails (retried 3 times), the operation fails but doesn't undo already-removed nodes
- **Offering scale failure**: If `upgradeVirtualMachine` fails for any VM, the operation aborts — already-scaled VMs keep their new offering
- **Timeout**: All scale operations are bounded by `cloud.kubernetes.cluster.scale.timeout` (default 3600s)

---

## Scaling

Scaling is handled by `KubernetesClusterScaleWorker`, which supports three operations in a single API call (`ScaleKubernetesClusterCmd`):

1. **Change worker node count** (scale up or down)
2. **Change service offering** for any node type (control, worker, etcd) — upgrades/downgrades existing VMs
3. **Enable/disable autoscaling** (set min/max size)

### Scale Entry Point: `scaleCluster()`

```
ScaleKubernetesClusterCmd
  → KubernetesClusterManagerImpl.scaleKubernetesCluster()
    → KubernetesClusterScaleWorker.scaleCluster()
      → [init → autoscale? → offering scaling? → size scaling? → OperationSucceeded]
```

### Scale Up (Adding Worker Nodes)

**Pre-flight validations:**
- Only XenServer, VMware, and Simulator hypervisors support scaling with running VMs (KVM does not)
- Capacity planning via `plan()` — same host capacity check as during creation
- Must find hosts with enough CPU/RAM for `newVmRequiredCount` additional VMs

**Provisioning flow (`scaleUpKubernetesClusterSize`):**

1. **State transition**: `Running → Scaling` (via `ScaleUpRequested`)
2. **Grant template access**: If using default system template, add launch permission for the account
3. **Create VMs**: `provisionKubernetesClusterNodeVMs(newTotalCount, offset=currentCount, ...)`
   - Creates VMs with `k8s-node.yml` cloud-init (same as initial creation)
   - Cloud-init does `kubeadm join` with the same cluster token
4. **Scale network rules**: Removes old firewall/port-forwarding rules, recreates with expanded range
   - Isolated: removes SSH firewall rule, removes all port forwarding rules, recreates both
   - VPC tier: removes and recreates port forwarding rules only
5. **Attach binaries ISO**: `attachIsoKubernetesVMs(newVMs)` — sequential, one VM at a time
6. **Wait for Ready nodes**: `validateKubernetesClusterReadyNodesCount()` — polls `kubectl get nodes` via SSH every 15s
7. **Detach ISO**: `detachIsoKubernetesVMs(newVMs)`
8. **Rollback on failure**: If node count doesn't match, `cleanupNewlyCreatedVms()` destroys and expunges all newly created VMs

### Scale Down (Removing Worker Nodes)

**Selecting which nodes to remove (`getWorkerNodesToRemove`):**
- Gets all non-external, non-control, non-etcd VMs
- Selects the **last N** VMs (sorted by creation order, reverse)
- User can also pass explicit node IDs to remove via `nodeIds` parameter

**Removal flow (`removeNodesFromCluster`):**

For each targeted node VM (in reverse order):

1. **Drain node**: SSH → `sudo /opt/bin/kubectl drain <hostname> --ignore-daemonsets --delete-emptydir-data`
   - Retries up to 3 times with 30-second wait between attempts
2. **Delete node**: SSH → `sudo /opt/bin/kubectl delete node <hostname>`
3. **Destroy VM**: `userVmService.destroyVm(vmId, true)` then `userVmManager.expunge(vm)`
4. **Remove DB record**: `kubernetesClusterVmMapDao.expunge(vmMapId)`
5. **Update network rules**: Recalculate firewall port range and port forwarding rules

### Service Offering Scaling

Scales existing VMs of a given node type to a new compute offering:

1. Validates that the new offering is different from the existing one
2. For each VM of the target node type:
   - Calls `userVmManager.upgradeVirtualMachine(vmId, newOfferingId, customParams)`
   - This is a CloudStack VM upgrade — changes CPU/RAM allocation
3. Updates the cluster DB record with new core/memory totals

**Capacity recalculation**: If only one node type is being scaled, it calculates the delta:
- `newCores = oldClusterCores - oldNodeTypeCores + newNodeTypeCores`
- `newMemory = oldClusterMemory - oldNodeTypeMemory + newNodeTypeMemory`

### Network Rule Scaling

Network rules must be rebuilt on every scale operation:

**Isolated networks:**
1. Remove existing SSH firewall rule on the SourceNAT IP
2. Remove all port forwarding rules across the port range
3. Recreate firewall rule opening `2222–(2222 + newClusterSize - etcdCount - 1)`
4. Recreate port forwarding: `publicIP:2222 → worker0:22`, `publicIP:2223 → worker1:22`, etc.

**VPC tiers:**
1. Remove all port forwarding rules
2. Recreate port forwarding rules for the new VM count
3. External nodes get ports after the default nodes (e.g., if 3 default nodes + 1 external: ports 2222-2224 for defaults, 2225 for external)

### Autoscaling

Autoscaling is configured via the same `ScaleKubernetesClusterCmd` API:

```java
if (isAutoscalingChanged) {
    autoscaleCluster(this.isAutoscalingEnabled, minSize, maxSize);
}
```

The `autoscaleCluster` method runs the `autoscale-kube-cluster` script on the control node:

**Enable:**
```bash
./autoscale-kube-cluster -e -M <max-size> -m <min-size>
```
- Substitutes `<cluster-id>`, `<min>`, `<max>` in the autoscaler template (`autoscaler_tmpl.yaml`)
- Applies the rendered manifest: `kubectl apply -f /opt/autoscaler/autoscaler_now.yaml`
- This deploys the Kubernetes [cluster-autoscaler](https://github.com/kubernetes/autoscaler) with the CloudStack cloud provider

**Disable:**
```bash
./autoscale-kube-cluster -d
```
- Runs: `kubectl delete deployment -n kube-system cluster-autoscaler`

---

## Upgrade

Upgrade is handled by `KubernetesClusterUpgradeWorker`. It upgrades all cluster nodes to a new Kubernetes version using a new binaries ISO.

### Upgrade Entry Point

```
UpgradeKubernetesClusterCmd
  → KubernetesClusterManagerImpl.upgradeKubernetesCluster()
    → KubernetesClusterUpgradeWorker.upgradeCluster()
      → [init → attach new ISO → drain → upgrade → uncordon → verify → detach ISO → update DB]
```

### Prerequisites

- A new `KubernetesSupportedVersion` must be registered with a new binaries ISO containing the target version's kubeadm, kubelet, kubectl, and container images
- The upgrade version ISO must be different from the current cluster version
- Nodes marked with `markForManualUpgrade=true` (etcd nodes) are skipped via `filterOutManualUpgradeNodesFromClusterUpgrade()`

### Upgrade Flow (`upgradeCluster()`)

#### 1. Init

- Resolves public IP and SSH port for cluster access
- Loads all cluster VMs, filters out manual-upgrade nodes (etcd)
- Retrieves scripts (upgrade script, provider scripts)
- State transition: `Running → UpgradeRequested`

#### 2. Attach New Binaries ISO

```java
attachIsoKubernetesVMs(clusterVMs, upgradeVersion);
```
- Attaches the **new version's ISO** (not the original) to all VMs sequentially
- This ISO contains the target version's kubeadm, kubelet, kubectl binaries and container images

#### 3. Per-Node Upgrade Loop (`upgradeKubernetesClusterNodes()`)

For each node (control nodes first, then workers):

**a) Drain the node:**
```bash
sudo /opt/bin/kubectl drain <hostname> --ignore-daemonsets --delete-emptydir-data
```
- SSH from management server to control node, runs kubectl
- Retries up to `cloud.kubernetes.cluster.upgrade.retries` times (default 3)
- On final failure: detaches ISOs and throws `OperationFailed`
- Checks timeout after each operation

**b) Deploy provider** (in case it was lost):
```java
deployProvider();
```

**c) Run upgrade script on the node:**

SCPs `upgrade-kubernetes.sh` to the node, then SSH-executes it:

```bash
./upgrade-kubernetes.sh <version> <isControlNode> <isOldVersion> <ejectIso> <externalCni>
```

The upgrade script does:

1. **Polls for ISO**: `blkid -o device -t LABEL=CDROM` (up to 10 attempts × 5s = 50s)
2. **Installs new kubeadm**: `cp <ISO>/k8s/kubeadm /opt/bin && chmod +x`
3. **Imports new container images**: `ctr -n k8s.io image import <ISO>/docker/*.tar`
4. **Updates CNI plugins and crictl** from ISO
5. **kubeadm upgrade**:
   - **First control node**: `kubeadm upgrade apply <version> -y`
     - Fallback for CoreDNS plugin issues: `--ignore-preflight-errors=CoreDNSUnsupportedPlugins`
   - **Other nodes**: 
     - If old version (< 1.15): `kubeadm upgrade node config --kubelet-version <version>`
     - Otherwise: `kubeadm upgrade node`
6. **Installs new kubelet + kubectl**: `cp <ISO>/k8s/{kubelet,kubectl} /opt/bin`
7. **Restarts kubelet**: `systemctl stop kubelet → daemon-reload → restart containerd → restart kubelet`
8. **First control node only**: Re-applies CNI and dashboard manifests from the new ISO
9. **Unmounts and ejects ISO**

**d) Uncordon the node:**
```bash
sudo /opt/bin/kubectl uncordon <hostname>
```
- Polls every 15s until success or timeout

**e) Wait for control node Ready** (first node only):
```java
isKubernetesClusterNodeReady(hostName, upgradeTimeoutTime, 15000)
```
- Polls `kubectl get nodes` every 15s until the control node shows `Ready`

**f) Verify node version:**
```java
clusterNodeVersionMatches(upgradeVersion.getSemanticVersion(), ...)
```
- Runs `kubectl get nodes | awk '{if ($1 == "<hostname>") print $5}'`
- Checks the reported version matches the target
- Updates `KubernetesClusterVmMapVO.nodeVersion` in DB

#### 4. Detach ISO and Update DB

- Detaches the new ISO from all VMs
- Updates `KubernetesClusterVO.kubernetesVersionId` to the new version
- State transition: `UpgradeRequested → Running` (via `OperationSucceeded`)

### Upgrade Timeline per Node

| Step | Time |
|------|------|
| ISO poll (max) | 50s (10 attempts × 5s) |
| Binary install + image import | ~30-120s |
| kubeadm upgrade | ~60-120s |
| kubelet restart | ~10s |
| Uncordon wait | up to timeout |
| Node Ready wait (control only) | up to timeout |

Total per node: typically 2-5 minutes. For a 3-control + 5-worker cluster: ~16-40 minutes.

### Upgrade Retries

- **Drain**: retries `cloud.kubernetes.cluster.upgrade.retries` (default 3)
- **Upgrade script**: retries `cloud.kubernetes.cluster.upgrade.retries` (default 3)
- **Uncordon**: polls until `cloud.kubernetes.cluster.upgrade.timeout` (default 3600s)
- **Node Ready**: polls until timeout
- **Version match**: polls up to 10 retries with `waitDuration` (15s) between

### Upgrade Error Handling

- On any failure during a node upgrade: `logTransitStateDetachIsoAndThrow()` — detaches ISOs from all nodes and throws
- The `upgradeTimeoutTime` is checked after each major step; if exceeded, ISOs are detached and operation fails
- Already-upgraded nodes are NOT rolled back — they remain at the new version
- The cluster version in the DB is only updated after ALL nodes succeed

---

## Error Handling

The bootstrap process has robust error handling at each stage:

1. **State transitions on failure**: Every failure triggers a state transition (e.g., `CreateFailed`, `OperationFailed`)
2. **ISO detach on failure**: `logTransitStateDetachIsoAndThrow()` detaches ISOs before throwing
3. **Template launch permission cleanup**: `deleteTemplateLaunchPermission()` revokes template access on failure
4. **Resource cleanup**: `KubernetesClusterDestroyWorker` handles full teardown of VMs, network rules, volumes

---

## Key Source Files Reference

All paths relative to `plugins/integrations/kubernetes-service/src/main/`:

### Java Sources
```
java/com/cloud/kubernetes/cluster/
├── KubernetesClusterService.java              — Service interface + ConfigKeys
├── KubernetesClusterManagerImpl.java           — Main orchestrator
├── actionworkers/
│   ├── KubernetesClusterActionWorker.java      — Base worker (SSH, ISO, state, scripts)
│   ├── KubernetesClusterResourceModifierActionWorker.java — Capacity, VM create/start
│   ├── KubernetesClusterStartWorker.java       — Bootstrap implementation
│   ├── KubernetesClusterDestroyWorker.java     — Teardown
│   ├── KubernetesClusterScaleWorker.java       — Scale up/down
│   ├── KubernetesClusterUpgradeWorker.java     — Version upgrades
│   ├── KubernetesClusterStopWorker.java        — Stop cluster
│   ├── KubernetesClusterAddWorker.java         — Add external nodes
│   └── KubernetesClusterRemoveWorker.java      — Remove nodes
├── utils/
│   └── KubernetesClusterUtil.java              — kubectl, SSH, token generation
└── dao/
    ├── KubernetesClusterDao.java
    ├── KubernetesClusterVmMapDao.java
    └── KubernetesClusterDetailsDao.java
```

### Cloud-init Templates
```
resources/conf/
├── k8s-control-node.yml          — Control plane node cloud-init
├── k8s-control-node-add.yml      — Additional HA control node cloud-init
├── k8s-node.yml                  — Worker node cloud-init
└── etcd-node.yml                 — External etcd node cloud-init
```

### Shell Scripts (embedded in Java resources)
```
resources/script/
├── deploy-cloudstack-secret      — Creates cloudstack-secret in kube-system
├── deploy-provider               — Deploys CloudStack Kubernetes Provider
├── deploy-csi-driver             — Deploys CloudStack CSI Driver
├── autoscale-kube-cluster        — Cluster autoscaler setup
├── delete-pv-reclaimpolicy-delete — PersistentVolume cleanup
├── validate-cks-node             — Node validation
└── remove-node-from-cluster      — Node removal
```

### Binaries ISO Builder
```
create-kubernetes-binaries-iso.sh
```
(Found in `cloudstack-common` package, builds `/mnt/k8sdisk/` structure described in Phase 6.3)

---

## ConfigKeys Reference

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `cloud.kubernetes.service.enabled` | Boolean | `true` | Master enable/disable |
| `cloud.kubernetes.cluster.network.offering` | String | `DefaultNetworkOfferingforKubernetesService` | Network offering name |
| `cloud.kubernetes.cluster.start.timeout` | Long | `3600` | Start timeout (seconds) |
| `cloud.kubernetes.cluster.scale.timeout` | Long | `3600` | Scale timeout (seconds) |
| `cloud.kubernetes.cluster.upgrade.timeout` | Long | `3600` | Upgrade timeout (seconds) |
| `cloud.kubernetes.cluster.upgrade.retries` | Integer | `3` | Upgrade retry count |
| `cloud.kubernetes.cluster.add.node.timeout` | Long | `3600` | Add node timeout |
| `cloud.kubernetes.cluster.remove.node.timeout` | Long | `900` | Remove node timeout |
| `cloud.kubernetes.cluster.experimental.features.enabled` | Boolean | `false` | Docker private registry |
| `cloud.kubernetes.cluster.max.size` | Integer | `10` | Max cluster size (per account) |
| `cloud.kubernetes.control.node.install.attempt.wait.duration` | Long | `15` | Control node install retry wait |
| `cloud.kubernetes.control.node.install.reattempt.count` | Long | `100` | Control node install retries |
| `cloud.kubernetes.worker.node.install.attempt.wait.duration` | Long | `30` | Worker node install retry wait |
| `cloud.kubernetes.worker.node.install.reattempt.count` | Long | `40` | Worker node install retries |
| `cloud.kubernetes.etcd.node.start.port` | Integer | `50000` | etcd SSH port forwarding start |

---

## Related
- [CKS Upgrade Guide](../setup/cks/cks-upgrade.md) — upgrade procedures and troubleshooting
- [CKS Custom ISO Build Guide](./cks-custom-iso.md) — building CKS-compatible ISOs
- [CKS Improvements](./cks-improvements.md) — detailed suggestions for robustness & security improvements
- [CAPC Architecture](./capc-analysis.md) — CloudStack API Provider for Cluster API
- [CAPC Upgrade Guide](../setup/capc/capc-upgrade.md) — CAPC cluster upgrade procedures
- [CNI Automation Options](../setup/capc/cni-automation-options.md) — automating CNI installation for CAPC clusters
- [CKS Setup Guide](../setup/cks/cks.md) — initial CKS cluster deployment

> **Note:** The full list of robustness & security improvement suggestions (ISO build script fixes, dashboard decoupling, token lifecycle, TLS cert validity, credential protection, SSH access restrictions, etc.) has been moved to [cks-improvements.md](./cks-improvements.md) to keep this file focused on operational analysis.
