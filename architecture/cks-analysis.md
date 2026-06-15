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

| Step | Check |
|------|-------|
| **5** | Kubeconfig available via SSH → `/etc/kubernetes/admin.conf` |
| **6** | Dashboard service running (`kubectl get pods -n kubernetes-dashboard`) |
| **7** | Control nodes tainted (cluster-autoscaler scale-down-disabled) |
| **8** | CloudStack Provider deployed (CCM + secret) |
| **9** | CSI driver deployed (optional) |
| **10** | State → Running |

---

## Management Server ↔ Cluster Communication

### SSH Channel (Primary)
The management server SSHs into the control node using:
- Key: `~/.ssh/id_rsa` (or `id_rsa.cloud` in dev mode)
- User: `cloud` (injected via cloud-init `authorized_keys`)
- Port: 2222 for isolated/VPC networks (via port forwarding), 22 for shared/direct

All kubectl commands use `/opt/bin/kubectl` (from the ISO).

### HTTPS Channel (API Server Health Check Only)
Directly calls `https://<public-ip>:6443/version` using a TrustAll SSL context.

---

## Cloud-init Templates Summary

### `k8s-control-node.yml`
- **Purpose**: First control plane node with external etcd
- **Key files**: TLS certs, kubeadm-config.yaml, setup-kube-system, deploy-kube-system
- **runcmd**: Configure containerd → install binaries → kubeadm init + apply manifests

### `k8s-control-node-add.yml`
- **Purpose**: Additional HA control plane nodes
- **Key difference**: Uses `kubeadm join` with certificate key

### `k8s-node.yml`
- **Purpose**: Worker nodes
- **Key difference**: `kubeadm join`, VR ISO download fallback, API server wait check

### `etcd-node.yml`
- **Purpose**: External etcd nodes
- **Key difference**: Polls for ISO by filesystem type, installs only etcd binary

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
