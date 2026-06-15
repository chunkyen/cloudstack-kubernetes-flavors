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

## Scaling

Handled by `KubernetesClusterScaleWorker`:
1. **Scale up**: Capacity planning → create VMs with k8s-node.yml cloud-init → kubeadm join
2. **Scale down**: Select nodes to remove via round-robin, destroy them
3. **Service offering change**: Resize existing VMs (XenServer/VMware/Simulator only)
4. **Autoscaling enable/disable**: Sets min/max bounds on the cluster

---

## Related
- [CKS Upgrade Guide](../setup/cks/cks-upgrade.md) — upgrade procedures and troubleshooting
- [CKS Custom ISO Build Guide](./cks-custom-iso.md) — building CKS-compatible ISOs
