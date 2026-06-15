# CloudStack Kubernetes Service (CKS) — Bootstrap Process Analysis

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

### 4.5 External etcd Cluster Provisioning (if requested)
```
provisionEtcdCluster()
```

For each etcd node (sequentially):
1. Acquires a guest IP in the cluster network
2. Generates hostname: `<prefix>-etcd-<index>-<timestamp_suffix>`
3. Reads `etcd-node.yml` cloud-init template, substitutes:
   - `{{ etcd.node_name }}` — hostname
   - `{{ etcd.node_ip }}` — acquired guest IP
   - `{{ etcd.initial_cluster_nodes }}` — `host0=http://ip0:2380,host1=http://ip1:2380,...`
   - `{{ k8s.ssh.pub.key }}` — management server SSH key + user keypair
   - `{{ k8s.install.wait.time }}` / `{{ k8s.install.reattempts.count }}` — retry settings
4. Creates VM via `userVmService.createAdvancedVirtualMachine()` with base64-encoded cloud-init
5. Resizes root disk if needed
6. Starts VM via `userVmManager.startVirtualMachine()`
7. Records in `KubernetesClusterVmMapVO` (marks `isEtcdNode=true`, `markForManualUpgrade=true`)

**Inside the etcd VM (cloud-init):**
- `setup-etcd-node` script polls for ISO via `blkid -o device -t TYPE=iso9660`
- Mounts ISO, extracts `etcd/etcd-linux-amd64.tar.gz` → `/opt/bin/`
- `systemctl enable --now etcd` starts etcd with:
  ```
  --initial-cluster <all-peers> --initial-cluster-state new
  ```

### 4.6 Control Plane Node Provisioning
```
provisionKubernetesClusterControlVm()
  → createKubernetesControlNode()
```

#### TLS Certificate Generation
CloudStack's CA Manager issues certificates with SANs:
- `kubernetes`, `kubernetes.default`, `kubernetes.default.svc`, `kubernetes.default.svc.cluster`, `kubernetes.default.svc.cluster.local`
- Control node IP, public IP, hostname

#### Cloud-init Template (`k8s-control-node.yml`)

Placeholder substitution:

| Placeholder | Source |
|-------------|--------|
| `{{ k8s_control_node.apiserver.crt }}` | CA Manager → PEM-encoded client cert |
| `{{ k8s_control_node.apiserver.key }}` | CA Manager → PEM-encoded private key |
| `{{ k8s_control_node.ca.crt }}` | CA Manager → PEM-encoded CA cert chain |
| `{{ k8s.ssh.pub.key }}` | Management server SSH public key + user keypair |
| `{{ k8s_control_node.cluster.token }}` | `KubernetesClusterUtil.generateClusterToken()` — random token |
| `{{ k8s_control_node.cluster.initargs }}` | HA: `--control-plane-endpoint <ip>:6443 --upload-certs --certificate-key <key>` + `--apiserver-cert-extra-sans=<ip> --kubernetes-version=<version>` |
| `{{ k8s_control_node.cluster.ha.certificate.key }}` | `KubernetesClusterUtil.generateClusterHACertificateKey()` |
| `{{ k8s_control.server_ip }}` | Public IP address |
| `{{ k8s.api_server_port }}` | 6443 |
| `{{ etcd.unstacked_etcd }}` | `true` if external etcd, `false` otherwise |
| `{{ etcd.etcd_endpoint_list }}` | YAML list: `- http://<ip0>:2379\n - http://<ip1>:2379` |
| `{{ k8s.eject.iso }}` | `true` for VMware (ejects ISO from OS), `false` otherwise |
| `{{ k8s.external.cni.plugin }}` | `true` if CNI config userdata provided, `false` otherwise |
| `{{ k8s.setup.csi.driver }}` | `true` if CSI enabled on cluster |
| `{{ k8s.install.wait.time }}` | 15 (seconds) for control nodes |
| `{{ k8s.install.reattempts.count }}` | 100 for control nodes |

#### VM Creation
- Created as `CKS_NODE` type via `userVmService.createAdvancedVirtualMachine()`
- cloud-init passed as base64-encoded userdata
- If CNI config userdata provided, it's concatenated with the main userdata
- Uses security groups if the zone is security-group-enabled
- Records in `KubernetesClusterVmMapVO` (marks `isControlNode=true`)

### 4.7 Additional Control Nodes (HA, k8s ≥ 1.16.0)
```
provisionKubernetesClusterAdditionalControlVms()
  → createKubernetesAdditionalControlNode()
```

For each additional control node:
1. Reads `k8s-control-node-add.yml` template
2. Substitutes join IP, cluster token, HA certificate key
3. Creates & starts VM (same pattern as first control node)
4. Inside VM: `kubeadm join <first-control-ip>:6443 --token <token> --discovery-token-unsafe-skip-ca-verification --control-plane --certificate-key <ha-key>`

### 4.8 Worker Node Provisioning
```
provisionKubernetesClusterNodeVms()
  → createKubernetesNode()
```

For each worker node (sequentially):
1. Reads `k8s-node.yml` template
2. Substitutes join IP, cluster token, SSH keys
3. Creates & starts VM
4. Inside VM: `kubeadm join <control-ip>:6443 --token <token> --discovery-token-unsafe-skip-ca-verification`

### 4.9 Network Rules Setup
```
setupKubernetesClusterNetworkRules()
```

**Isolated networks:**
- Opens firewall port range 2222–(2222+N-1) on SourceNAT IP for SSH access
- Creates port forwarding: `publicIP:2222 → VM:22`, `publicIP:2223 → VM:22`, etc.
- Port 6443 is already open for API access

**VPC tiers:**
- Adds ACL rules to allow port 6443
- Port forwarding via the VPC tier's public IP

**Shared/Direct networks:** Skipped (VMs are directly reachable)

### 4.10 etcd Network Rules
```
setupKubernetesEtcdNetworkRules()
```
- Opens firewall ports 50000+ for etcd SSH access
- Creates port forwarding: `publicIP:50000 → etcdVM:22`, `publicIP:50001 → etcdVM:22`, etc.
- For VPC tiers: adds ACL rules for etcd client port (2379)

---

## Phase 5: ISO Attachment

```
attachIsoKubernetesVMs(etcdVms)
attachIsoKubernetesVMs(clusterVMs)
```

**This is the critical timing-sensitive step.** The ISO is attached **after** all VMs are already running. The cloud-init scripts inside the VMs are designed to poll-wait for it.

The ISO is identified by:
- Looking up the `KubernetesSupportedVersionVO` for the cluster
- Getting the `isoId` field (the binaries ISO template ID)
- Validating the template is an ISO format in Active state
- Attaching it to each VM via `templateService.attachIso(iso.getId(), vm.getId(), true)`

### ISO Attachment is Sequential, Not Parallel

The `attachIsoKubernetesVMs` method iterates through VMs **one at a time** in a plain `for` loop — each `templateService.attachIso()` call is synchronous and blocks until the hypervisor completes the ISO attachment for that specific VM:

```java
// KubernetesClusterActionWorker.java
protected void attachIsoKubernetesVMs(List<UserVm> clusterVMs, ...) {
    // ... validation ...
    for (UserVm vm : clusterVMs) {
        CallContext vmContext = CallContext.register(...);
        try {
            templateService.attachIso(iso.getId(), vm.getId(), true);  // BLOCKING
            // log success
        } catch (CloudRuntimeException ex) {
            // log and throw
        } finally {
            CallContext.unregister();
        }
    }
}
```

And in `startKubernetesClusterOnCreate()` it's called in two batches:

```java
attachIsoKubernetesVMs(etcdVms);       // batch 1: etcd nodes, sequentially one-by-one
attachIsoKubernetesVMs(clusterVMs);     // batch 2: control + workers, sequentially one-by-one
```

**Actual attachment order:**

```
etcd node 0 → wait for hypervisor → etcd node 1 → wait → ...
  ↓ (all etcd nodes get ISO)
control node 0 → wait → control node 1 (HA) → wait → ...
  ↓ (all control nodes)
worker node 0 → wait → worker node 1 → wait → worker node 2 → wait → ...
```

This means the first VM in the list gets a significant head start on bootstrapping before the last VM even sees the ISO. This is one reason the cloud-init polling timeouts are so generous (~25 min for control/etcd nodes, ~20 min for workers) — they must accommodate the cumulative sequential attachment delay, especially for large clusters where the last worker might not get its ISO until all preceding VMs have been processed.

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
        # mount the ISO device, check for binaries directory
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

### 6.2 Worker Node ISO Fallback

Worker nodes on isolated networks have an additional fallback: if `blkid` doesn't find a local ISO device, they attempt to download the contents from the Virtual Router:

```bash
ROUTER_IP="{{ k8s.vr.iso.mounted.ip }}"
wget -r $ROUTER_IP/cks-iso -P /aux-dwnld
mv /aux-dwnld/$ROUTER_IP/cks-iso/* $ISO_MOUNT_DIR
```

This requires the VR to serve the ISO contents at `/cks-iso/`.

### 6.3 Binary Installation (`setup-kube-system` script)

Once the ISO is mounted at `/mnt/k8sdisk/`:

```
/mnt/k8sdisk/
├── cni/
│   └── cni-plugins-<arch>.tgz
├── cri-tools/
│   └── crictl-linux-<arch>.tar.gz
├── k8s/
│   ├── kubeadm
│   ├── kubelet
│   └── kubectl
├── docker/
│   ├── <image1>.tar
│   ├── <image2>.tar
│   └── ...
├── etcd/
│   └── etcd-linux-amd64.tar.gz
├── kubelet.service
├── 10-kubeadm.conf
├── network.yaml          (CNI manifest, e.g. Calico)
├── dashboard.yaml        (Kubernetes Dashboard manifest - 4.22.1)
├── headlamp.yaml          (Headlamp dashboard manifest - 4.23.0+)
├── autoscaler.yaml
├── provider.yaml           (CloudStack Kubernetes Provider)
├── snapshot-crds.yaml      (CSI snapshot CRDs)
└── manifest.yaml            (CSI driver manifest)
```

Installation steps:

1. **CNI plugins**: `tar -xf cni/cni-plugins-*.tgz -C /opt/cni/bin/`
2. **crictl**: `tar -xf cri-tools/crictl-linux-*.tar.gz -C /opt/bin/`
3. **Kubernetes binaries**: `cp k8s/{kubeadm,kubelet,kubectl} /opt/bin/ && chmod +x`
4. **kubelet service**: `sed s:/usr/bin:/opt/bin:g kubelet.service > /etc/systemd/system/kubelet.service`
5. **kubeadm config**: `sed s:/usr/bin:/opt/bin:g 10-kubeadm.conf > /etc/systemd/system/kubelet.service.d/10-kubeadm.conf`
6. **Container images**: `ctr -n k8s.io image import docker/<image>.tar` for each image
7. **Update containerd**: set `sandbox_image` to the imported pause image
8. **Preserve YAML manifests**: copy `*.yaml` to `/tmp/k8sconfigscripts/`
9. **Eject ISO** (VMware only): `eject <iso_device>`
10. **Start kubelet**: `systemctl enable kubelet && systemctl start kubelet`
11. **Load kernel modules**: `modprobe overlay && modprobe br_netfilter`

### 6.4 Control Node Bootstrap (`deploy-kube-system` service)

A systemd oneshot service runs after `setup-kube-system`:

```bash
# With external etcd:
kubeadm init --config /etc/kubernetes/kubeadm-config.yaml --upload-certs

# With stacked etcd:
kubeadm init --token <token> --token-ttl 0 \
  --control-plane-endpoint <ip>:6443 \
  --upload-certs --certificate-key <key> \
  --apiserver-cert-extra-sans=<ip> \
  --kubernetes-version=<version> \
  --cri-socket /run/containerd/containerd.sock
```

Then:

1. Sets `KUBECONFIG=/etc/kubernetes/admin.conf`
2. Copies admin.conf to `/root/.kube/config`
3. **Applies CNI**: `kubectl apply -f /tmp/k8sconfigscripts/network.yaml` (e.g., Calico)
4. **Installs dashboard**: `kubectl apply -f /tmp/k8sconfigscripts/dashboard.yaml` (4.22.1: Kubernetes Dashboard; 4.23.0+: Headlamp via `headlamp.yaml`)
5. **Creates RBAC bindings**: `cluster-admin` role bindings for `admin` user
6. **Marks completion**: `touch /home/cloud/success`

If the ISO is not available (online mode, rarely used):
- Downloads binaries from `storage.googleapis.com` and `github.com`
- Applies Weave Net CNI from `cloud.weave.works`
- Installs Kubernetes Dashboard from `raw.githubusercontent.com`

### 6.5 Worker Node Bootstrap (`deploy-kube-system` service)

A systemd oneshot service that:
1. Waits for the API server to be reachable: `curl -k https://<control-ip>:6443/version`
2. Runs: `kubeadm join <control-ip>:6443 --token <token> --discovery-token-unsafe-skip-ca-verification`
3. Marks completion: `touch /home/cloud/success`

---

## Phase 7: Post-Bootstrap Verification

Back on the management server, the following checks run sequentially:

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
- Checks `kubectl get pods -n kube-system` for dashboard pod in Running state

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

## Troubleshooting: Cluster Stuck in "Starting" with Kubeconfig Available

A common failure mode: the CKS UI shows the kubeconfig is available and downloadable, but the cluster remains in `Starting` state indefinitely. Only the core Kubernetes components (kube-apiserver, etcd, controller-manager, scheduler, CoreDNS, CNI) are deployed — CCM, CSI driver, and dashboard are **not** deployed.

### Root Cause: Dashboard Verification Blocking the Post-Bootstrap Pipeline

The issue is a **ordering dependency** in the post-bootstrap verification sequence. Look at the exact order in `startKubernetesClusterOnCreate()`:

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
| Headlamp/Dashboard | `kubectl apply -f headlamp.yaml` (cloud-init) | Before step 5 | ⚠️ Applied but **pod not Running** |
| **CloudStack Provider (CCM)** | `deployProvider()` (management server via SSH+SCP) | **Step 8** | ❌ Never reached |
| **CSI Driver** | `deployCsiDriver()` (management server via SSH+SCP) | **Step 9** | ❌ Never reached |
| Control node taints | `taintControlNodes()` (management server via SSH) | **Step 7** | ❌ Never reached |

The dashboard is applied by cloud-init (`deploy-kube-system` service) during VM bootstrap (Phase 6.4). CCM and CSI are deployed later by the management server via SSH+SCP. If the flow stalls at step 6, CCM and CSI **cannot possibly** be deployed.

### How the Dashboard Check Works (4.22.1 vs main/4.23.0)

**In 4.22.1** (your version), the check is hardcoded to Kubernetes Dashboard only:

```java
// KubernetesClusterUtil.java (4.22.1)
public static boolean isKubernetesClusterDashboardServiceRunning(...) {
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

The Headlamp 404 problem (below) is a secondary issue that would cause the same symptoms if you were running 4.23.0. On 4.22.1, even a valid `headlamp.yaml` wouldn't help because the cloud-init never looks at it.

### Common Reasons the Dashboard Pod Isn't Running (4.22.1)

#### 1. ISO Build Script Produces headlamp.yaml Instead of dashboard.yaml (MOST LIKELY)

This is the primary issue when using a build script from the `main` branch with a 4.22.1 management server. See the **Version Mismatch** section above for full details.

In short: 4.22.1's cloud-init applies `dashboard.yaml`, but your ISO only has `headlamp.yaml` (which may also be 404 garbage HTML). The `kubectl apply -f dashboard.yaml` command fails because the file doesn't exist.

**Diagnose on the control node:**
```bash
# Confirm dashboard.yaml is missing
ls -la /tmp/k8sconfigscripts/dashboard.yaml 2>/dev/null || echo "MISSING - this is why the cluster fails"

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

This is harmless on 4.22.1 (since the cloud-init ignores `headlamp.yaml`), but would cause a failure on 4.23.0 where Headlamp is the primary dashboard.#### 2. Image Reference Mismatch

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

#### 3. Pod in ContainerCreating or Pending

The pod might be waiting for a PV to bind, or a volume to mount. Check:
```bash
sudo /opt/bin/kubectl describe pod -n kube-system <headlamp-pod-name>
```

Look for `Warning` events about volumes, scheduling, or network.

#### 4. CrashLoopBackOff

The pod starts but crashes immediately. Causes could be:
- RBAC issues (service account permissions)
- Config errors in the deployment manifest
- Resource limits too low

Check logs:
```bash
sudo /opt/bin/kubectl logs -n kube-system <headlamp-pod-name> --previous
```

#### 4. deploy-kube-system Service Failed Silently

The `deploy-kube-system` systemd service has `Restart=on-failure`. If it fails (e.g., `kubeadm init` fails on restart because the cluster is already initialized), it restarts, but `kubeadm init` fails again, creating a loop. The `kubectl apply -f headlamp.yaml` line is never reached.

**Check on the control node:**
```bash
sudo systemctl status deploy-kube-system
sudo journalctl -u deploy-kube-system --no-pager | tail -50
cat /home/cloud/success   # if this file exists and contains "true", cloud-init completed
```

#### 5. 

The timing of the check matters. When step 6 runs, the headlamp pod was just applied (by cloud-init during Phase 6.4). If the pod takes longer than usual to pull images, start containers, and pass health checks, the management server's polling will fail until the pod reaches `Running`.

### The Exact Error Message You'll See

When the dashboard check times out, `KubernetesClusterManagerImpl.createManagedKubernetesCluster()` catches the exception and throws:

```java
// KubernetesClusterStartWorker.java (4.22.1) — startKubernetesClusterOnCreate()
if (!isKubernetesClusterDashboardServiceRunning(true, startTimeoutTime)) {
    logTransitStateAndThrow(Level.ERROR,
        String.format("Failed to setup Kubernetes cluster : %s in usable state as unable to get Dashboard service running for the cluster",
            kubernetesCluster.getName()),
        kubernetesCluster.getId(), KubernetesCluster.Event.OperationFailed);
}
```

And in `KubernetesClusterManagerImpl.createManagedKubernetesCluster()`:

```java
} catch (CloudRuntimeException e) {
    throw new CloudRuntimeException(
        String.format("Failed to setup Kubernetes cluster : %s in usable state as %s",
            kubernetesClusterName, e.getMessage()), e);
}
```

The combined error (exactly what you see):

```
Failed to setup Kubernetes cluster : kk1 in usable state as unable to get Dashboard service running for the cluster
```

This is 100% confirmation that:
1. The control VM booted, kubeadm initialized the cluster, kubeconfig is available (step 7.5 passed)
2. The dashboard pod never reached `Running` state within 3600 seconds (step 7.6 failed)
3. CCM, CSI, and control node taints were never executed (steps 7.7–7.9)
4. The cluster state transitioned to `Error` (not `Running`)

### Diagnostic Commands on the Stuck Cluster (4.22.1)

Run these on the control node (or via SSH from the management server):

```bash
# 1. Check if deploy-kube-system is in a restart loop
sudo systemctl status deploy-kube-system
sudo journalctl -u deploy-kube-system --no-pager -n 30

# 2. Check what YAML files are available
ls -la /tmp/k8sconfigscripts/ 2>/dev/null || echo "directory not found"

# 3. THE KEY CHECK: Does dashboard.yaml exist? (4.22.1 requires this)
ls -la /tmp/k8sconfigscripts/dashboard.yaml 2>/dev/null || echo "dashboard.yaml NOT FOUND — THIS IS THE PROBLEM"

# 4. Check what's in headlamp.yaml (if present — likely garbage HTML)
head -5 /tmp/k8sconfigscripts/headlamp.yaml 2>/dev/null || echo "headlamp.yaml not found"

# 5. Check if cloud-init finished successfully
cat /home/cloud/success

# 6. Check the Kubernetes Dashboard namespace (should be empty/not found)
sudo /opt/bin/kubectl get pods -n kubernetes-dashboard 2>&1

# 7. Verify images are loaded on the node
sudo crictl images | grep -E "dashboard|headlamp"
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

---

## Cloud-init Templates Summary

### `k8s-control-node.yml`
- **Purpose**: First control plane node
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
  sudo: ALL=(ALL) NOPASSWD:ALL
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

Key events:
- `CreateRequested` → `Created`: Cluster DB record persisted
- `StartRequested` → `Starting`: Bootstrap begins (Phase 4)
- `OperationSucceeded` → `Running`: All checks passed (Phase 7)
- `CreateFailed` → Error state, ISOs detached: Bootstrap failed during create
- `OperationFailed` → Error state: Operation failed after cluster was running

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

## Suggestions for Robustness & Security Improvements

Based on the analysis above, the following are recommendations for making the CKS lifecycle more robust and secure, organized by impact.

### Robustness Improvements

#### 1. Fix the ISO Build Script's Brittle Download Logic

**Problem**: `curl -sSL` without `-f` silently produces garbage files on 404. No checksums. No fallback.

**Fix**:
- Add `-f` flag to all `curl` commands in `create-kubernetes-binaries-iso.sh` so the build **fails** if a URL returns an error
- Add SHA256 checksum verification for downloaded binaries where checksums are available
- Add a retry mechanism: `curl --retry 3 --retry-delay 5`
- Validate downloaded YAML files with `python3 -c "import yaml; yaml.safe_load(open('file.yaml'))"` before packaging

#### 2. Decouple Dashboard Verification from CCM/CSI Deployment

**Problem**: The post-bootstrap pipeline in `startKubernetesClusterOnCreate()` blocks CCM, CSI, and control node tainting behind the dashboard pod being `Running`. If the dashboard pod fails, the cluster never reaches `Running` state — even though the cluster is functionally complete.

**Fix** (reorder in `KubernetesClusterStartWorker.startKubernetesClusterOnCreate()`):
```java
// Current order:
//   5. kubeconfig -> 6. dashboard check -> 7. taint -> 8. CCM -> 9. CSI
// Proposed order:
//   5. kubeconfig -> 6. taint -> 7. CCM -> 8. CSI -> 9. dashboard check (non-blocking)
```
- Move `deployProvider()` and `deployCsiDriver()` **before** the dashboard check
- Make the dashboard check non-blocking: log a warning instead of throwing, or transition to a `Running (Dashboard Pending)` sub-state
- Reduce the dashboard poll interval from 15s to lower values early on (exponential backoff)

#### 3. Reorder ISO Attachment for Faster Bootstrap

**Problem**: Sequential ISO attachment means the last worker VM in a large cluster waits minutes before receiving its ISO, extending total bootstrap time unnecessarily.

**Fix**:
- Parallelize ISO attachment where the hypervisor supports it (e.g., issue all `attachIso` calls without waiting for each to complete, then poll all)
- Alternatively: batch-attach ISOs per node type (all workers in parallel)
- For very large clusters: consider pre-seeding the ISO in the VM template so cloud-init doesn't need to poll-wait at all

#### 4. Add Timeout Checkpoints During Upgrade

**Problem**: The upgrade timeout is checked only between major steps, not within long-running operations like `kubeadm upgrade apply`.

**Fix**:
- Add a background watchdog thread that kills the upgrade script if the overall timeout is exceeded
- Add per-step sub-timeouts: the upgrade script itself should have an internal timeout
- Implement a "best-effort rollback" — after a partial upgrade failure, cordon all already-upgraded nodes to prevent scheduling surprises

#### 5. Validate YAML Manifests Before Including in ISO

**Problem**: The build script blindly packs any downloaded file as `*.yaml`. Invalid YAML (HTML error pages, truncated files) causes cloud-init failures.

**Fix**:
```bash
# In create-kubernetes-binaries-iso.sh, after downloading each YAML:
if ! python3 -c "import yaml; yaml.safe_load(open('${file}'))"; then
    echo "ERROR: ${file} is not valid YAML"
    exit 1
fi
```

#### 6. Verify All Container Images Exist Before Finalizing ISO

**Problem**: The ISO is built even if some container images failed to pull or export.

**Fix**:
- Count expected images from YAML manifests
- Count actual `*.tar` files in `docker/`
- If counts don't match, fail the build with a list of missing images
- For each `ctr image pull`, check exit code explicitly (the build script currently doesn't)

#### 7. Add Retry Logic to cloud-init Scripts

**Problem**: The `deploy-kube-system` systemd service restarts on failure, but `kubeadm init` fails on restart because the cluster is already initialized — creating an infinite loop.

**Fix**:
- In `deploy-kube-system`, check if the cluster is already initialized before attempting `kubeadm init`:
  ```bash
  if /opt/bin/kubectl get nodes &>/dev/null; then
      echo "Cluster already initialized, skipping kubeadm init"
  else
      kubeadm init ...
  fi
  ```
- Use systemd `RestartSec` to add a delay between restarts (currently 0)
- Add `StartLimitBurst` to prevent infinite restarts (e.g., max 5 restarts then stop)

#### 8. Add Health Checks Between Cluster Lifecycle Phases

**Problem**: After bootstrap, there's no ongoing health monitoring. A cluster could degrade silently.

**Fix**:
- Add a periodic health check scanner in the management server that:
  - Verifies the API server is reachable
  - Checks node count matches expected
  - Reports degraded clusters via CloudStack events/alerts
- Expose cluster health as a new field on `KubernetesClusterResponse`

### Security Improvements

#### 9. Use Short-Lived Bootstrap Tokens with Rotation

**Problem**: The kubeadm bootstrap token is derived from the cluster UUID (`generateClusterToken()`) and set with `--token-ttl 0` (never expires). It's embedded in every node's cloud-init userdata and the kubeadm config on disk.

**Fix**:
- Use `--token-ttl 1h` (or the duration of the start timeout) instead of `0`
- Delete the bootstrap token via `kubeadm token delete <token>` after all nodes join
- Generate tokens with `crypto.random()` instead of deriving from cluster UUID
- Store tokens in `KubernetesClusterDetailsVO` with encryption at rest

#### 10. Issue Short-Lived TLS Certificates

**Problem**: The API server TLS certificate is issued with a **3650-day (10-year)** validity via CloudStack CA Manager.

```java
// KubernetesClusterStartWorker.java
final Certificate certificate = caManager.issueCertificate(
    null, addresses, 3650,  // ← 10 years
    null);
```

**Fix**:
- Reduce to 1 year (365 days) or less
- Implement automatic certificate renewal before expiry (kubeadm supports `kubeadm certs renew`)
- Consider using `kubeadm init --cert-dir` with pre-generated short-lived certs managed by cert-manager

#### 11. Protect CloudStack API Credentials

**Problem**: The CloudStack API key and secret are passed as command-line arguments to the `deploy-cloudstack-secret` script:

```bash
sudo /opt/bin/deploy-cloudstack-secret -u '<api-url>' -k '<key>' -s '<secret>'
```

This exposes API credentials in:
- Process listings (`ps aux`)
- Shell history
- systemd journal
- SSH command logs

**Fix**:
- Write credentials to a temp file with restricted permissions (`0600`), pass the file path instead:
  ```bash
  echo "[Global]\napi-url = $URL\napi-key = $KEY\nsecret-key = $SECRET" > /tmp/cloud-config.$$ && chmod 600 /tmp/cloud-config.$$
  sudo /opt/bin/deploy-cloudstack-secret --config-file /tmp/cloud-config.$$
  shred -u /tmp/cloud-config.$$
  ```
- Use Kubernetes secrets with restricted RBAC for the provider instead of a generic `cloudstack-secret`
- Rotate API keys periodically

#### 12. Restrict SSH Access Scope

**Problem**: The management server's SSH key is injected into **every** cluster node (`{{ k8s.ssh.pub.key }}`), granting passwordless root-equivalent access (user `cloud` has `NOPASSWD:ALL`).

**Fix**:
- Inject the management server key only on the control node (workers don't need it for normal operation)
- Create a dedicated, restricted CKS management user instead of using the general `cloud` user
- Use SSH certificates with short lifetimes instead of permanent authorized_keys
- Add audit logging for all SSH sessions originating from the management server

#### 13. Secure the Kubeconfig Stored in the Database

**Problem**: The cluster's admin kubeconfig is stored as base64 (not encrypted) in `KubernetesClusterDetailsVO` with key `kubeConfigData`.

**Fix**:
- Encrypt the kubeconfig at rest using CloudStack's existing encryption framework
- Create a dedicated, scoped service account + kubeconfig instead of storing the full `cluster-admin` kubeconfig
- Rotate kubeconfigs on a schedule (re-generate from the control node)

#### 14. Validate cloud-init Userdata Signatures

**Problem**: cloud-init userdata is generated by the management server and injected into VMs. There's no integrity check — if the management server is compromised, arbitrary cloud-init could be injected.

**Fix**:
- Sign cloud-init userdata with the CloudStack CA or an HMAC
- Have the VM validate the signature before executing
- This is especially important for the `NOPASSWD:ALL` sudo access granted to the `cloud` user

#### 15. Network Isolation for the Cluster Management Traffic

**Problem**: The management server communicates with cluster VMs over the same public/guest network. SSH (port 2222) and API (port 6443) are exposed via port forwarding.

**Fix**:
- Use a dedicated management network (not the guest network) for SSH access to cluster VMs
- Firewall rules should restrict SSH access to only the management server's IP, not `0.0.0.0/0`
- Current code opens SSH to the world:
  ```java
  sourceCidrList.add("0.0.0.0/0");  // ← should be restricted
  ```

#### 16. Implement kubeadm Token Cleanup After Bootstrap

**Problem**: The bootstrap token persists indefinitely (`--token-ttl 0`), allowing anyone with network access to join nodes to the cluster.

**Fix**:
- After `validateKubernetesClusterReadyNodesCount()` succeeds, SSH in and run:
  ```bash
  sudo /opt/bin/kubeadm token delete <token>
  ```
- This should happen before `stateTransitTo(OperationSucceeded)`

### Prioritized Implementation Order

| Priority | Item | Impact |
|----------|------|--------|
| 🔴 Critical | #1 - Fix ISO build script (add `-f` to curl, validate YAML) | Prevents silent ISO corruption |
| 🔴 Critical | #2 - Decouple dashboard verification from CCM/CSI | Fixes the "stuck in Starting" problem entirely |
| 🔴 Critical | #9 - Use short-lived bootstrap tokens, delete after join | Security: tokens never expire today |
| 🟠 High | #11 - Don't pass API credentials as CLI args | Security: they're in `ps aux` and logs |
| 🟠 High | #15 - Restrict firewall to management server IP only | Security: `0.0.0.0/0` SSH access |
| 🟠 High | #7 - Fix deploy-kube-system restart loop | Robustness: prevents infinite restart on failure |
| 🟡 Medium | #3 - Parallelize ISO attachment | Performance: faster bootstrap for large clusters |
| 🟡 Medium | #10 - Shorten TLS cert validity | Security: 10-year certs |
| 🟡 Medium | #13 - Encrypt kubeconfig at rest | Security: plaintext admin kubeconfig in DB |
| 🟢 Lower | #4 - Upgrade timeout watchdogs | Robustness: prevents hung upgrades |
| 🟢 Lower | #6 - Verify image counts in ISO build | Robustness: build-time checking |
| 🟢 Lower | #12 - Restrict SSH to control node only | Security: reduce attack surface |

This script builds the binaries ISO from internet sources. Usage:

```bash
./create-kubernetes-binaries-iso.sh \
  <OUTPUT_PATH> \
  <KUBERNETES_VERSION> \
  <CNI_VERSION> \
  <CRICTL_VERSION> \
  <NETWORK_YAML_URL> \
  <HEADLAMP_DASHBOARD_VERSION> \
  <BUILD_NAME> \
  [ARCH] \
  [ETCD_VERSION]
```

Example:
```bash
./create-kubernetes-binaries-iso.sh \
  ./output \
  1.29.0 \
  1.4.0 \
  1.29.0 \
  https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml \
  0.22.1 \
  cks-1.29-calico \
  amd64 \
  3.5.12
```

It downloads:
- Kubernetes binaries (kubeadm, kubelet, kubectl) from `dl.k8s.io`
- CNI plugins from GitHub releases
- crictl from GitHub releases
- Network manifest (Calico, Weave, etc.)
- Headlamp dashboard manifest
- Cluster autoscaler manifest (CloudStack provider variant)
- CloudStack Kubernetes Provider manifest
- CloudStack CSI Driver manifests (CRDs + driver)
- All container images referenced in the above YAMLs (pulled via `ctr image pull`, exported as tar)
- Optional: etcd binary

All are packaged into an ISO with `mkisofs -J -R -l`, which is then registered as a CloudStack template.
