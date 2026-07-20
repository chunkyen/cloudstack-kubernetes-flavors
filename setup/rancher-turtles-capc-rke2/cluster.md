# Deploy RKE2 Clusters on CloudStack via Rancher Turtles + CAPC

This guide covers provisioning **RKE2** clusters on **CloudStack** using **Cluster API** with **Rancher Turtles** — combining the CloudStack infrastructure provider (CAPC) with the RKE2 bootstrap/control-plane provider (CAPRKE2).

> **Prerequisites assumed:** Rancher + Turtles + CAPC already deployed.
> See [`rancher.md`](../rancher-turtles-capc/rancher.md) for Rancher deployment and [`turtles.md`](../rancher-turtles-capc/turtles.md) for Turtles + CAPC provider installation.

## Architecture

For the full Rancher Turtles + CAPC architecture breakdown — including layer-by-layer explanation, data flow, namespace layout, credential model, and ClusterResourceSet mechanics — see [Rancher+CAPC architecture](../../architecture/rancher-turtles-capc.md).

This guide focuses on the **RKE2-specific components** within that architecture:

```
Management Cluster (Rancher + Turtles + CAPC already running)
  │
  └─ CAPIProvider: rke2-bootstrap        ← you add this
  └─ CAPIProvider: rke2-control-plane    ← you add this
       │
       └─ RKE2ControlPlane (replaces KubeadmControlPlane)
            │
            ├─ CloudStackMachineTemplate (control-plane VM spec)
            │      └─ CloudStack VM → RKE2 tarball auto-installs → Calico
            │
            └─ RKE2ConfigTemplate (worker bootstrap config)
                   │
                   └─ MachineDeployment
                        └─ CloudStackMachineTemplate (worker VM spec)
                               └─ CloudStack VM → RKE2 agent joins → ready

Post-creation:
  └─ ClusterResourceSet applies CCM + CSI manifests to workload cluster
```

**Key architectural difference:**
- **Kubeadm CAPC:** VMs boot with a pre-baked CAPI image → cloud-init runs `kubeadm init/join` → you manually install CNI via CRS
- **RKE2 CAPC:** VMs boot with a standard OS template → CAPRKE2 pushes RKE2 tarball → RKE2 auto-installs containerd, etcd, CNI (Calico), CoreDNS, ingress → CCM + CSI applied via CRS

## What This Adds vs. Kubeadm-Based CAPC

|| | Kubeadm (existing) | RKE2 (this guide) |
|---|---|---|---|
|| Bootstrap provider | `kubeadm` | `rke2` |
|| Control plane provider | `kubeadm` | `rke2` |
|| **CNI** | Manual (Calico/Flannel/Cilium) | Built-in (Calico default; Canal, Cilium, Flannel, or none configurable) |
|| CNI install | Helm chart or manifest | RKE2 auto-installs at bootstrap |
|| `preKubeadmCommands` / `preRKE2Commands` | Available | Available |
|| Provider ID | Same `cloudstack:///{{ ds.meta_data.instance_id }}` | Same |
|| `guest.cpu.mode: host-passthrough` | Required for Calico x86-64-v2 | Required for Calico x86-64-v2 |
|| **CloudStack template** | CAPI image (containerd, kubelet, kubeadm, cloud-init pre-installed) | Generic Linux OS (RKE2 installs itself via tarball) |
|| CCM/CSI deployment | ClusterResourceSet or manual | Same |

Everything else — Rancher, Turtles, CAPC, CloudStack credentials, networking, ClusterResourceSet mechanics — is identical. See [Rancher+CAPC architecture](../../architecture/rancher-turtles-capc.md#bootstrap-provider-choice-kubeadm-vs-rke2) for a detailed comparison of why to choose RKE2 over kubeadm.

> **Tip:** RKE2's CNI is not limited to Calico. You can switch to [Cilium](#switching-cni-from-calico-to-cilium) or other CNIs by changing a single field.

> **CloudStack fundamentals are the same:** The CloudStack-specific parts of the cluster manifest — template selection, service offering, zone, network, reserved public IP, `syncWithACS`, `host-passthrough` — work identically for both kubeadm and RKE2. For details on creating/uploading templates, reserving public IPs, network options, and manifest field reference, see the [CAPC setup guide](../capc/capc.md).

## Template Requirements

### Generic OS vs. CAPI image

RKE2 CAPC uses a **generic Linux OS template** — not a CAPI-specific image.

| | Kubeadm CAPC | RKE2 CAPC |
|---|---|---|
| **Template type** | CAPI image (containerd, kubelet, kubeadm, kubectl, cloud-init pre-installed) | Generic Linux OS (Ubuntu, Rocky, Debian, etc.) |
| **Kubernetes binaries** | Pre-installed in template | Installed by RKE2 at bootstrap |
| **Container runtime** | Pre-installed (containerd) | Installed by RKE2 at bootstrap |
| **CNI** | Installed post-bootstrap | Installed by RKE2 at bootstrap |
| **Bootstrap mechanism** | cloud-init runs `kubeadm init/join` | CAPRKE2 pushes RKE2 tarball; cloud-init executes the install script |

### What the generic template needs

| Requirement | Why | Checked by |
|---|---|---|
| **cloud-init installed** | CAPRKE2 generates a cloud-init `userData` script that downloads and installs RKE2. CloudStack injects this userData into the VM at first boot. | `cloud-init --version` |
| **SSH server running** | For **human admin troubleshooting only** — not used by CAPRKE2 for bootstrap. | `systemctl status ssh` |
| **SSH access** (optional) | Admin SSH login to debug boot issues. Use the `sshKey` field in `CloudStackMachineTemplate` — CloudStack injects this keypair. | CloudStack UI / `cmk list sshkeypairs` |

### How CAPRKE2 bootstraps (no SSH needed)

CAPRKE2 does **not** use the `sshKey` from `CloudStackMachineTemplate` for bootstrap. The key is purely for human admin access.

The actual bootstrap flow:

1. **CAPRKE2 generates bootstrap data** — creates a cloud-init `userData` script with RKE2 config
2. **CAPC passes userData to CloudStack** — CloudStack injects it into the VM at boot
3. **cloud-init runs on first boot** — executes the CAPRKE2-generated script
4. **RKE2 tarball downloaded** — from the internet (default) or pre-staged internal source (air-gap)
5. **RKE2 installs itself** — containerd, kubelet, etcd, CNI all from the tarball

### Common template choices

| OS | Notes |
|---|---|
| **Ubuntu 24.04 cloud image** | Most tested. cloud-init pre-installed. Good for both Calico and Cilium. |
| **Ubuntu 26.04 cloud image** ([cloud-images.ubuntu.com/resolute/](https://cloud-images.ubuntu.com/resolute/)) | Validated. cloud-init pre-installed. Works with RKE2 v1.35+ and v1.36+. |
| **Rocky Linux 9** | RHEL-compatible. cloud-init pre-installed. |
| **Debian 12** | Lightweight. cloud-init pre-installed. |

> **Recommendation:** Use a **generic OS cloud image** for RKE2. RKE2 installs containerd, kubelet, etcd, and CNI itself during bootstrap, so a pre-built CAPI image is unnecessary. A generic image is simpler to maintain, smaller, and avoids version conflicts. CAPI images work too, but they contain pre-installed kubeadm/kubelet that RKE2 will overlay anyway.
>
> **Validated:** Ubuntu 24.04 and Ubuntu 26.04 cloud images — `ubuntu 24.04` and `ubuntu 26 server` templates on CloudStack — both successfully provisioned control plane and workers. CCM and CSI deployed and healthy. No CAPI-specific image required.

## Step 1: Install CAPRKE2 Providers

Create the `CAPIProvider` resources for the RKE2 bootstrap and control-plane providers:

```yaml
# rke2-providers.yaml
apiVersion: turtles-capi.cattle.io/v1alpha1
kind: CAPIProvider
metadata:
  name: rke2-bootstrap
spec:
  name: rke2
  type: bootstrap
---
apiVersion: turtles-capi.cattle.io/v1alpha1
kind: CAPIProvider
metadata:
  name: rke2-control-plane
spec:
  name: rke2
  type: control-plane
```

```bash
kubectl apply -f rke2-providers.yaml
```

Wait for both providers to become `Ready`:

```bash
kubectl get capiproviders
```

## Step 2: Create the Cluster Namespace and Credentials

Identical to the kubeadm-based CAPC workflow:

```bash
kubectl create namespace capc-rke2-cluster-1
```

Create the CloudStack credentials secret:

```bash
kubectl create secret generic cloudstack-credentials \
  -n capc-rke2-cluster-1 \
  --from-literal=api-key="<your-api-key>" \
  --from-literal=secret-key="<your-secret-key>" \
  --from-literal=api-url="http://<cloudstack-host>:8080/client/api"
```

> 💡 **Network auto-creation:** CAPC automatically creates the isolated network specified in `failureDomains.zone.network.name` and handles IP association. Manually creating the network beforehand also works, but is redundant — CAPC handles it.

## Step 3: Deploy the Cluster (with CCM + CSI via ClusterResourceSet)

This step deploys three resources together — the cluster itself plus the ClusterResourceSet that automatically installs CCM and CSI after the cluster comes up.

```bash
# Deploy cluster + ConfigMap + ClusterResourceSet together
kubectl apply -f manifests/10-minimal-cluster.yaml \
  -f manifests/20-ccm-csi-configmap.yaml \
  -f manifests/21-clusterresourceset.yaml
```

Wait for the cluster to become ready:

```bash
kubectl get cluster -n capc-rke2-cluster-1 -w
kubectl get machines -n capc-rke2-cluster-1 -w
```

The `Cluster` manifest includes the label `capc-rke2-ccm-csi: "true"` which matches the `ClusterResourceSet` selector. Once the cluster's API server is reachable, the ClusterResourceSet controller automatically applies CCM and CSI to the workload cluster — no manual post-step required.

> **Alternative:** If you prefer not to use ClusterResourceSet, skip the `20-ccm-csi-configmap.yaml` and `21-clusterresourceset.yaml` files. After the cluster is ready, apply the standalone CCM + CSI manifests directly to the workload cluster. See the [Standalone Manifests](#standalone-manifests-optional--without-clusterresourceset) section below.

### Key details in the manifest

| Field | Value | Why |
|---|---|---|
| `controlPlaneEndpoint.host` | `"192.168.200.60"` | **Pick a free public IP** from your CloudStack public IP pool. CAPC uses this as the Kubernetes API endpoint. It must not be already allocated to another network. |
| `failureDomains.zone.network.name` | `"capc-rke2-net"` | CAPC **auto-creates** this isolated network in CloudStack. Do not create it manually. |
| `provider-id` | `cloudstack:///{{ ds.meta_data.instance_id }}` | Must match CAPC's provider ID format. No quotes around the template expression. |
| `guest.cpu.mode` | `host-passthrough` | Required because Calico (bundled with RKE2 ≥v1.30) needs x86-64-v2 CPU instructions. Without this, `tigera-operator` crashes with `Fatal glibc error: CPU does not support x86-64-v2`. |
| `cni` | `cilium` | RKE2's built-in CNI. RKE2 installs CNI automatically as a Helm chart during bootstrap. Valid values: `calico`, `cilium`, `canal`, `flannel`, or `none`. **Note:** If you use Cilium or another CNI, the `guest.cpu.mode: host-passthrough` requirement still applies because Cilium's eBPF stack also benefits from modern CPU instructions. |
| `registrationMethod` | `internal-first` | Nodes register via internal IP first, falling back to external. |
| `preRKE2Commands` | `sleep 30` | Gives CloudStack time to fully provision the VM before RKE2 bootstrap starts. |
| `kubelet extraArgs` | `register-with-taints=node-role.kubernetes.io/control-plane=:NoSchedule` | Applies the control-plane taint via kubelet flag instead of the `nodeTaints` object field (which causes a strict decoding error on `RKE2ControlPlane`). This prevents workload pods from scheduling on control-plane nodes. |
| `capc-rke2-ccm-csi: "true"` | Cluster label | Matches the `ClusterResourceSet` selector so CCM + CSI are auto-deployed. |

> **Note:** The `cloudstack-secret` containing CloudStack API credentials is embedded in the ConfigMap (`20-ccm-csi-configmap.yaml`) and is created automatically on the workload cluster by ClusterResourceSet — no separate manual step needed. Replace the placeholder values (`api-url`, `api-key`, `secret-key`) in the ConfigMap before applying. The ConfigMap also includes a StorageClass with a `REPLACE_WITH_YOUR_DISK_OFFERING_UUID` placeholder — update this to match your CloudStack disk offering UUID (not the name).

## Verification

```bash
# Get the workload kubeconfig
kubectl get secret capc-rke2-cluster-1-kubeconfig -n capc-rke2-cluster-1 \
  -o jsonpath='{.data.value}' | base64 -d > workload-kubeconfig

# Check nodes
KUBECONFIG=workload-kubeconfig kubectl get nodes -o wide

# Check all pods
KUBECONFIG=workload-kubeconfig kubectl get pods -A
```

Expected result: 3 nodes (1 control-plane + 2 workers), all `Ready`, with Calico, CoreDNS, CCM, and CSI running.

### Verify CCM and CSI specifically

```bash
# CCM
KUBECONFIG=workload-kubeconfig kubectl get deployment -n kube-system cloud-controller-manager

# CSI controller and node daemonset
KUBECONFIG=workload-kubeconfig kubectl get deployment -n kube-system cloudstack-csi-controller
KUBECONFIG=workload-kubeconfig kubectl get daemonset -n kube-system cloudstack-csi-node

# CSIDriver registered
KUBECONFIG=workload-kubeconfig kubectl get csidriver

# ClusterResourceSet applied successfully
kubectl get clusterresourcesetbinding -n capc-rke2-cluster-1
# → resources[0].applied: true
```

## Scaling Workers

Use the CAPI `MachineDeployment` on the **management cluster** to scale workers. Do not edit the underlying `MachineSet` directly.

### Scale up (add workers)

```bash
# KUBECONFIG points at the management cluster (not the workload cluster)
KUBECONFIG=~/.kube/kube-rancher-config \
  kubectl scale machinedeployment \
  <cluster-name>-md-0 \
  --replicas=<desired-worker-count> \
  -n <cluster-namespace>
```

**Example — add 1 worker to the default setup:**

```bash
KUBECONFIG=~/.kube/kube-rancher-config \
  kubectl scale machinedeployment \
  capc-rke2-cluster-1-md-0 \
  --replicas=3 \
  -n capc-rke2-cluster-1
```

CAPI provisions a new VM, bootstraps RKE2, and joins the node automatically. The CSI node DaemonSet will also be scheduled on the new node automatically.

### Scale down (remove workers)

**CAPI decides which Machine to delete** during scale-down. If you need to remove a specific node, cordon + drain it first, then delete its **Machine** object directly.

**Generic scale-down (CAPI picks the machine):**

```bash
KUBECONFIG=~/.kube/kube-rancher-config \
  kubectl scale machinedeployment \
  capc-rke2-cluster-1-md-0 \
  --replicas=2 \
  -n capc-rke2-cluster-1
```

**Remove a specific node:**

```bash
# 1. Cordon + drain the node on the workload cluster
KUBECONFIG=/tmp/capc-rke2-cluster-1-kubeconfig \
  kubectl cordon   <node-name>

KUBECONFIG=/tmp/capc-rke2-cluster-1-kubeconfig \
  kubectl drain    <node-name> \
  --ignore-daemonsets --delete-emptydir-data --force --timeout=300s

# 2. Delete the Machine object on the management cluster
KUBECONFIG=~/.kube/kube-rancher-config \
  kubectl delete machine <machine-name> -n capc-rke2-cluster-1

# 3. CAPI cleans up the VM automatically
```

> ⚠️ Do **not** use `kubectl delete node` directly on the workload cluster — this leaves the CAPI `Machine` and CloudStack VM in place. Always delete the `Machine` object on the management cluster so CAPI handles the full lifecycle.

## Upgrading RKE2 Version

CAPI + CAPRKE2 supports **rolling upgrades** by changing the `version` field in the `RKE2ControlPlane` and `MachineDeployment` objects. CAPI then creates new VMs with the new RKE2 version, joins them to the cluster, migrates etcd leadership (for control plane), and deletes the old machines.

### 1. Check current version

```bash
# Nodes
KUBECONFIG=/tmp/capc-rke2-cluster-1-kubeconfig kubectl get nodes -o wide

# Machines
KUBECONFIG=~/.kube/kube-rancher-config \
  kubectl get machines -n capc-rke2-cluster-1
```

### 2. Patch to new version

```bash
# Upgrade control plane
KUBECONFIG=~/.kube/kube-rancher-config \
  kubectl patch rke2controlplane capc-rke2-cluster-1-control-plane \
  -n capc-rke2-cluster-1 --type='merge' \
  -p '{"spec":{"version":"v1.36.2+rke2r1"}}'

# Upgrade workers
KUBECONFIG=~/.kube/kube-rancher-config \
  kubectl patch machinedeployment capc-rke2-cluster-1-md-0 \
  -n capc-rke2-cluster-1 --type='merge' \
  -p '{"spec":{"template":{"spec":{"version":"v1.36.2+rke2r1"}}}}'
```

### 3. Monitor the rolling upgrade

```bash
# Watch machines — new ones appear with new version, old ones transition to Deleting
KUBECONFIG=~/.kube/kube-rancher-config \
  kubectl get machines -n capc-rke2-cluster-1 -w

# Watch nodes
KUBECONFIG=/tmp/capc-rke2-cluster-1-kubeconfig kubectl get nodes -w
```

**Expected phases:**

| Phase | Meaning |
|-------|---------|
| `Provisioning` | New VM is being created in CloudStack |
| `Running` | VM is booted and joined the cluster |
| `Deleting` | Old VM is being drained and removed |

Control plane upgrades first (1 replica at a time by default). Workers upgrade after the control plane is stable. The `Cluster` object shows `RollingOut` during the process.

### 4. Verify completion

```bash
# All nodes on new version
KUBECONFIG=/tmp/capc-rke2-cluster-1-kubeconfig kubectl get nodes

# All machines Running and Up-to-date
KUBECONFIG=~/.kube/kube-rancher-config \
  kubectl get machines -n capc-rke2-cluster-1

# Cluster stable
KUBECONFIG=~/.kube/kube-rancher-config \
  kubectl get cluster -n capc-rke2-cluster-1
```

### Troubleshooting: etcd leadership transfer stuck

If the control plane upgrade stalls with the new node stuck in `Provisioned` and the old node never deleted, check the `rke2-control-plane-controller-manager` logs:

```bash
KUBECONFIG=~/.kube/kube-rancher-config \
  kubectl logs -n cattle-capi-system \
  deployment/rke2-control-plane-controller-manager | grep -i "etcd\\|leadership\\|failed"
```

**Symptom:** Repeated errors like:

```
Failed to move leadership to candidate machine
tls: unknown certificate authority
```

**Root cause:** This is a [known bug](https://github.com/rancher/cluster-api-provider-rke2/issues/919) in the `rke2-control-plane-controller-manager`. The controller's in-memory etcd client becomes stale and can no longer connect to etcd, even though the TLS certificates on the nodes are valid. Restarting the pod clears the in-memory state.

**Fix:** Restart the controller manager pod:

```bash
KUBECONFIG=~/.kube/kube-rancher-config \
  kubectl rollout restart deployment rke2-control-plane-controller-manager \
  -n cattle-capi-system
```

After restart, the controller should successfully move etcd leadership to the new node, then delete the old control plane machine. Worker upgrades will proceed automatically.

## Upgrading Node OS Using a New Template

CAPI supports **rolling OS upgrades** by creating new `CloudStackMachineTemplate` objects with the updated template name and switching the `RKE2ControlPlane` and `MachineDeployment` references to point at them. CAPI then provisions new VMs with the new OS, joins them to the cluster, and deletes the old machines.

> **Tip:** You can combine an OS template upgrade with an RKE2 version upgrade in a single rolling update. When you patch both `version` and `infrastructureRef` at the same time, each new VM boots with the new OS **and** installs the new RKE2 version — one rolling update, one drain per node. See [Upgrading RKE2 Version](#upgrading-rke2-version) for the version patch commands, then apply them together with the template ref changes below.

### 1. Create new CloudStackMachineTemplates

```bash
# Export existing templates
kubectl get cloudstackmachinetemplate -n capc-rke2-cluster-1 \
  capc-rke2-cluster-1-control-plane -o yaml > /tmp/cp-template.yaml
kubectl get cloudstackmachinetemplate -n capc-rke2-cluster-1 \
  capc-rke2-cluster-1-md-0 -o yaml > /tmp/worker-template.yaml
```

Edit the copies: change `metadata.name` to a new name (e.g. append `-ubuntu26`) and update `spec.template.spec.template.name` to the new OS template (e.g. `ubuntu 26 server`). Remove `uid`, `resourceVersion`, `generation`, `creationTimestamp`, and `managedFields` from `metadata`.

```bash
# Apply the new templates
kubectl apply -f /tmp/cp-template-ubuntu26.yaml
kubectl apply -f /tmp/worker-template-ubuntu26.yaml
```

### 2. Switch references to the new templates

```bash
# Update control plane
kubectl patch rke2controlplane capc-rke2-cluster-1-control-plane \
  -n capc-rke2-cluster-1 --type='json' \
  -p='[{"op": "replace", "path": "/spec/machineTemplate/spec/infrastructureRef/name", "value": "capc-rke2-cluster-1-control-plane-ubuntu26"}]'

# Update workers
kubectl patch machinedeployment capc-rke2-cluster-1-md-0 \
  -n capc-rke2-cluster-1 --type='json' \
  -p='[{"op": "replace", "path": "/spec/template/spec/infrastructureRef/name", "value": "capc-rke2-cluster-1-md-0-ubuntu26"}]'
```

### 3. Monitor the rolling upgrade

```bash
# Watch machines — new ones appear with the new OS, old ones transition to Deleting
kubectl get machines -n capc-rke2-cluster-1 -w

# Watch nodes
KUBECONFIG=/tmp/capc-rke2-cluster-1-kubeconfig kubectl get nodes -w
```

**Expected phases:**

| Phase | Meaning |
|-------|---------|
| `Provisioning` | New VM is being created in CloudStack with the new OS template |
| `Running` | VM is booted and joined the cluster |
| `Deleting` | Old VM is being drained and removed |

Workers roll first (the `MachineDeployment` creates a new machine, waits for it to be Ready, then deletes the old one). The control plane rolls next — with 1 replica, CAPI creates the new CP, transfers etcd leadership, then deletes the old CP.

### 4. Verify completion

```bash
# All nodes on new OS
KUBECONFIG=/tmp/capc-rke2-cluster-1-kubeconfig kubectl get nodes -o wide

# All machines Running and Up-to-date
kubectl get machines -n capc-rke2-cluster-1

# Cluster stable
kubectl get cluster -n capc-rke2-cluster-1
```

### Combined upgrade: RKE2 version + OS template at the same time

To upgrade both the RKE2 version and the OS template in a single rolling update, create the new `CloudStackMachineTemplates` first, then patch `version` and `infrastructureRef` together:

```bash
# Patch control plane — version + template ref in one call
kubectl patch rke2controlplane capc-rke2-cluster-1-control-plane \
  -n capc-rke2-cluster-1 --type='json' \
  -p='[
    {"op": "replace", "path": "/spec/version", "value": "v1.36.2+rke2r1"},
    {"op": "replace", "path": "/spec/machineTemplate/spec/infrastructureRef/name", "value": "capc-rke2-cluster-1-control-plane-ubuntu26"}
  ]'

# Patch workers — version + template ref in one call
kubectl patch machinedeployment capc-rke2-cluster-1-md-0 \
  -n capc-rke2-cluster-1 --type='json' \
  -p='[
    {"op": "replace", "path": "/spec/template/spec/version", "value": "v1.36.2+rke2r1"},
    {"op": "replace", "path": "/spec/template/spec/infrastructureRef/name", "value": "capc-rke2-cluster-1-md-0-ubuntu26"}
  ]'
```

Each new VM boots with the new OS template and installs the new RKE2 version — one rolling update, one drain per node.

### Troubleshooting: etcd leadership transfer stuck

Same [known bug](https://github.com/rancher/cluster-api-provider-rke2/issues/919) as RKE2 version upgrades — the controller's in-memory etcd client becomes stale. Restart it:

```bash
kubectl rollout restart deployment rke2-control-plane-controller-manager \
  -n cattle-capi-system
```

### Java apps crash with `NullPointerException` in `ProcessorMetrics` (JDK 17 + Ubuntu 26 cgroup v2)

On **Ubuntu 26** (cgroup v2), bank-of-anthos Java services using JDK 17.0.4.1 may crash with a `NullPointerException` in `ProcessorMetrics`. See [`demo-app/README.md`](../../demo-app/README.md#ubuntu-26--cgroup-v2-compatibility) for details and the patched manifests in `demo-app/manifests/cgroupv2-jdk17-compat/`.

## Switching CNI from Calico to Cilium

RKE2 supports multiple CNI plugins out of the box: `calico` (default), `canal`, `cilium`, `flannel`, or `none`. To use **Cilium**, simply change the `cni` field in `10-minimal-cluster.yaml` before applying.

### Option A: Deploy with Cilium from the start

Change the `cni` field in `10-minimal-cluster.yaml`:

```yaml
# In 10-minimal-cluster.yaml, RKE2ControlPlane spec:
    cni: cilium          # ← RKE2 installs Cilium automatically during bootstrap
```

That's it — RKE2 handles Cilium installation as part of the control plane bootstrap. No manual Helm install or ClusterResourceSet needed.

> **Note:** Cilium requires kernel 4.9+ with eBPF support. Ubuntu 24.04 (the template used in `10-minimal-cluster.yaml`) satisfies this.

### Option B: Switch an existing Calico cluster to Cilium

If the cluster is already running with Calico, migration requires draining and rebooting nodes — this is disruptive. The recommended path is to **delete and recreate** the cluster with `cni: cilium` (Option A).

### Cilium + CloudStack considerations

| Concern | Guidance |
|---|---|
| **IPAM** | Cilium defaults to Kubernetes host-scope IPAM mode (pod IPs from Node CIDR). This works with CloudStack's isolated network model. |
| **Host firewall** | Cilium's eBPF-based host firewall is compatible with CloudStack isolated networks. No special rules needed. |
| **CCM + CSI** | Cilium operates independently of CCM and CSI. All three coexist without conflict. |

### Verification (Cilium)

```bash
KUBECONFIG=workload-kubeconfig kubectl get pods -n kube-system -l app.kubernetes.io/name=cilium
KUBECONFIG=workload-kubeconfig kubectl get pods -n kube-system -l app.kubernetes.io/name=cilium-operator
```

Expected: all Cilium pods Running and Cilium operator 1/1.

The StorageClass is defined in the ConfigMap with a `REPLACE_WITH_YOUR_DISK_OFFERING_UUID` placeholder — run `cmk list diskofferings | grep -E "id|name"` to find the correct UUID for your CloudStack zone.

## Air-Gapped / Offline Deployment

RKE2 is designed for air-gapped environments — all core components (containerd, etcd, CNI, CoreDNS, ingress) ship in a single tarball. CAPC + Rancher Turtles adds a few extra pieces that need addressing.

### What's already offline-capable

| Component | Offline support | Notes |
|---|---|---|
| RKE2 bootstrap tarball | ✅ Built-in | Single tarball contains all Kubernetes, CNI, and containerd images |
| Cilium CNI | ✅ Built-in | RKE2's `cni: cilium` installs from the embedded tarball |
| Calico CNI | ✅ Built-in | Same — embedded in RKE2 tarball |
| CAPRKE2 providers | ✅ No internet needed | Providers run on the management cluster; cluster provisioning is orchestrated from there |

### What needs preparation

| Component | Action needed |
|---|---|
| **OS template** | Upload a CloudStack template with RKE2-compatible OS (Ubuntu 24.04 / Rocky 9) pre-baked |
| **CloudStack API** | Management server must be reachable from the management cluster (private IP or VPN) |
| **CCM image** | Host `apache/cloudstack-kubernetes-provider` image in a private registry |
| **CSI driver image** | Host `apache/cloudstack-csi-driver` image in a private registry |
| **CSI sidecar images** | Host `csi-provisioner`, `csi-attacher`, `csi-resizer`, `csi-node-driver-registrar`, `livenessprobe` in a private registry |
| **ClusterResourceSet manifests** | The CRS ConfigMap (`20-ccm-csi-configmap.yaml`) references images by upstream tag. In air-gap, update image references to your private registry |

### Required image list for air-gapped CCM + CSI

Pull these on an internet-connected machine, save to a tarball, and import to your private registry:

```bash
# CCM
apache/cloudstack-kubernetes-provider:v1.2.0

# CSI driver
ghcr.io/cloudstack/cloudstack-csi-driver:3.0.0

# CSI sidecars (versions may vary — match what's in your CRS ConfigMap)
registry.k8s.io/sig-storage/csi-provisioner:v5.0.1
registry.k8s.io/sig-storage/csi-attacher:v4.6.1
registry.k8s.io/sig-storage/csi-resizer:v1.11.1
registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.11.1
registry.k8s.io/sig-storage/livenessprobe:v2.13.1
```

Save and transfer:

```bash
# On internet-connected machine
for img in \
  apache/cloudstack-kubernetes-provider:v1.2.0 \
  ghcr.io/cloudstack/cloudstack-csi-driver:3.0.0 \
  registry.k8s.io/sig-storage/csi-provisioner:v5.0.1 \
  registry.k8s.io/sig-storage/csi-attacher:v4.6.1 \
  registry.k8s.io/sig-storage/csi-resizer:v1.11.1 \
  registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.11.1 \
  registry.k8s.io/sig-storage/livenessprobe:v2.13.1; do
  docker pull $img
done

docker save -o cloudstack-ccm-csi-images.tar \
  apache/cloudstack-kubernetes-provider:v1.2.0 \
  ghcr.io/cloudstack/cloudstack-csi-driver:3.0.0 \
  registry.k8s.io/sig-storage/csi-provisioner:v5.0.1 \
  registry.k8s.io/sig-storage/csi-attacher:v4.6.1 \
  registry.k8s.io/sig-storage/csi-resizer:v1.11.1 \
  registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.11.1 \
  registry.k8s.io/sig-storage/livenessprobe:v2.13.1
```

Import on each workload node (or push to private registry):

```bash
# On air-gapped nodes
ctr -n k8s.io images import cloudstack-ccm-csi-images.tar
```

### Using a private registry

If you have a private registry (e.g. `registry.internal:5000`), update all image references in the CRS ConfigMap (`20-ccm-csi-configmap.yaml`) before applying:

```yaml
# In 20-ccm-csi-configmap.yaml — replace all image: lines
image: registry.internal:5000/apache/cloudstack-kubernetes-provider:v1.2.0
image: registry.internal:5000/ghcr.io/cloudstack/cloudstack-csi-driver:3.0.0
image: registry.internal:5000/sig-storage/csi-provisioner:v5.0.1
# ... etc for all sidecars
```

Also set the RKE2 `system-default-registry` so all RKE2 core images pull from your registry:

```yaml
# In 10-minimal-cluster.yaml, RKE2ControlPlane spec:
    systemDefaultRegistry: registry.internal:5000
```

### RKE2 air-gapped bootstrap (tarball)

CAPRKE2 supports air-gapped RKE2 installation via the `agentConfig.airGapped` field. When set to `true`, the install script uses `INSTALL_RKE2_ARTIFACT_PATH=/opt/rke2-artifacts` instead of downloading from the public internet.

**What you need:**

| Artifact | Size | Source |
|---|---|---|
| `rke2.linux-amd64.tar.gz` | ~40 MB | RKE2 release (the RKE2 binary + systemd units) |
| `rke2-images.linux-amd64.tar.zst` | ~580 MB | RKE2 release (all container images: containerd, etcd, CNI, CoreDNS, ingress) |
| `sha256sum-amd64.txt` | ~3.5 KB | RKE2 release (checksums for verification) |
| `install.sh` | ~27 KB | `https://get.rke2.io` (the RKE2 install script) |

**Step 1: Download artifacts on an internet-connected machine**

```bash
VERSION=v1.36.2+rke2r1
mkdir -p rke2-artifacts && cd rke2-artifacts

curl -sLO "https://github.com/rancher/rke2/releases/download/${VERSION}/rke2.linux-amd64.tar.gz"
curl -sLO "https://github.com/rancher/rke2/releases/download/${VERSION}/rke2-images.linux-amd64.tar.zst"
curl -sLO "https://github.com/rancher/rke2/releases/download/${VERSION}/sha256sum-amd64.txt"
curl -sLo install.sh "https://get.rke2.io"
```

**Step 2: Host the artifacts on an internal HTTP server**

Serve the directory from any machine reachable by the workload VMs:

```bash
cd rke2-artifacts
python3 -m http.server 8080
```

**Step 3: Configure the cluster manifest**

Set `agentConfig.airGapped: true` and add `preRKE2Commands` to download the artifacts before RKE2 installs:

```yaml
apiVersion: controlplane.cluster.x-k8s.io/v1beta2
kind: RKE2ControlPlane
metadata:
  name: capc-rke2-cluster-1-control-plane
  namespace: capc-rke2-cluster-1
spec:
  version: v1.36.2+rke2r1
  agentConfig:
    airGapped: true
    kubelet:
      extraArgs:
        - provider-id=cloudstack:///{{ ds.meta_data.instance_id }}
        - register-with-taints=node-role.kubernetes.io/control-plane=:NoSchedule
    nodeName: '{{ ds.meta_data.local_hostname }}'
  preRKE2Commands:
    - sleep 30
    - mkdir -p /opt/rke2-artifacts
    - curl -sL -o /opt/rke2-artifacts/rke2.linux-amd64.tar.gz http://192.168.200.1:8080/rke2.linux-amd64.tar.gz
    - curl -sL -o /opt/rke2-artifacts/rke2-images.linux-amd64.tar.zst http://192.168.200.1:8080/rke2-images.linux-amd64.tar.zst
    - curl -sL -o /opt/rke2-artifacts/sha256sum-amd64.txt http://192.168.200.1:8080/sha256sum-amd64.txt
    - curl -sL -o /opt/install.sh http://192.168.200.1:8080/install.sh
```

The same `preRKE2Commands` and `agentConfig.airGapped: true` must be set in the `RKE2ConfigTemplate` for worker nodes.

> **Note:** The `agentConfig.airGappedChecksum` field exists in the CAPRKE2 CRD but generates a cloud-init `runcmd` line containing `awk '{print $1}'`. The curly braces `{}` break YAML parsing, causing cloud-init to skip the entire `runcmd` section. Omit this field and rely on the install script's built-in checksum verification instead.

**Step 4: Apply and verify**

```bash
kubectl apply -f 10-airgap-cluster.yaml
```

Monitor the control plane's cloud-init logs to confirm artifacts download and RKE2 installs:

```bash
# Expected cloud-init output
[INFO]  staging local checksums from /opt/rke2-artifacts/sha256sum-amd64.txt
[INFO]  staging zst airgap image tarball from /opt/rke2-artifacts/rke2-images.linux-amd64.tar.zst
[INFO]  staging tarball from /opt/rke2-artifacts/rke2.linux-amd64.tar.gz
[INFO]  verifying airgap tarball
[INFO]  installing airgap tarball to /var/lib/rancher/rke2/agent/images
[INFO]  verifying tarball
[INFO]  unpacking tarball file to /usr/local
Created symlink /etc/systemd/system/multi-user.target.wants/rke2-server.service
```

A complete working example is available at [`manifests/10-airgap-cluster.yaml`](./manifests/10-airgap-cluster.yaml).

> **Template-driven deployments:** For managing multiple clusters from a single template, see [`ytt.md`](./ytt.md) — covers ytt-based templating with air-gap conditionals, and explains why ClusterClass is not yet available for CAPC + CAPRKE2.

> **Important:** The above covers RKE2 itself. CCM and CSI images are **not** included in the RKE2 tarball — they must be hosted in a private registry and the image paths in `20-ccm-csi-configmap.yaml` updated to point to that registry. See [Required image list for air-gapped CCM + CSI](#required-image-list-for-air-gapped-ccm--csi) and [Using a private registry](#using-a-private-registry) below.

### CAPC-specific considerations

| Concern | Guidance |
|---|---|
| **CloudStack credentials secret** | The `cloudstack-credentials` secret on the management cluster references the CloudStack API. This API must be reachable from the management cluster — use private IP or VPN if needed. |
| **CAPC controller image** | The CAPC controller runs on the management cluster. Ensure the management cluster's nodes can reach your private registry (if pulling CAPC via Rancher Turtles). |
| **RKE2 tarball download** | CAPRKE2 downloads the RKE2 tarball from the public internet by default. In air-gap, use `agentConfig.airGapped: true` with `preRKE2Commands` to fetch artifacts from an internal HTTP server (see [RKE2 air-gapped bootstrap](#rke2-air-gapped-bootstrap-tarball) above). |

### Simplified approach (no private registry)

If you don't have a private registry, you can:

1. Pre-pull the CCM + CSI images into the OS template (as part of the CloudStack template build).
2. Update the CRS ConfigMap to use the pre-loaded image names (same tags, just already present on the node).
3. Ensure containerd's `imagePullPolicy` handles the already-present images correctly.

This avoids registry setup but requires maintaining a custom template per image release.

## Troubleshooting

### Calico crashes with `Fatal glibc error: CPU does not support x86-64-v2`

**Cause:** The Calico version bundled with RKE2 ≥v1.30 requires x86-64-v2 CPU instructions, but CloudStack VMs default to QEMU's virtual CPU model which may not expose these features.

**Fix:** Add `details: guest.cpu.mode: host-passthrough` to both `CloudStackMachineTemplate` resources (control-plane and worker). This passes the host CPU features through to the guest.

### Workers not created

The `MachineSet` shows `desired: 2, current: 0`. CAPRKE2 waits for the control plane to be fully healthy before provisioning workers. Check:

```bash
kubectl get rke2controlplane -n capc-rke2-cluster-1 -o yaml
```

If the control plane is `NotReady` due to Calico, apply the host-passthrough fix above, delete the cluster, and recreate.

### Provider ID format

The `provider-id` must be `cloudstack:///{{ ds.meta_data.instance_id }}` — no quotes around the template expression. If quotes are present, the literal string `{{ ds.meta_data.instance_id }}` is used instead of the resolved value.

### CSI node container crashes with exit code 2

**Cause:** The upstream CSI node DaemonSet mounts `/run/cloud-init/` to read instance metadata, but RKE2 nodes do **not** use cloud-init — RKE2 installs itself via tarball at bootstrap — so this directory does not exist.

**Fix:** The ConfigMap (`20-ccm-csi-configmap.yaml`) has this mount removed in the `cloudstack-csi-node-daemonset-rke2.yaml` key. If you are using your own upstream manifests, remove the `cloud-init-dir` volumeMount and volume:

```yaml
# Remove this from the CSI node DaemonSet container:
- name: cloud-init-dir
  mountPath: /run/cloud-init

# Remove this from the CSI node DaemonSet volumes:
- name: cloud-init-dir
  hostPath:
    path: /run/cloud-init
```

### CSI controller pod stays Pending

**Cause:** The upstream CSI controller Deployment sets `replicas: 2` with `podAntiAffinity` requiring deployment across different hosts. On a single-node RKE2 control plane, the second replica can never schedule.

**Fix:** The ConfigMap (`20-ccm-csi-configmap.yaml`) sets `replicas: 1` and removes `podAntiAffinity` in the `cloudstack-csi-controller-deployment-rke2.yaml` key. If you are using your own upstream manifests, change to `replicas: 1` and remove the `podAntiAffinity` block.

## Cleanup

```bash
# Let CAPI/CAPC handle deletion gracefully
kubectl delete cluster capc-rke2-cluster-1 -n capc-rke2-cluster-1

# If the cluster gets stuck in Deleting, remove the turtles-capi finalizer:
kubectl patch cluster capc-rke2-cluster-1 -n capc-rke2-cluster-1 \
  --type merge -p '{"metadata":{"finalizers":[]}}'
```

Do **not** use `--force` or manually destroy VMs — let CAPI/CAPC orchestrate the teardown.

## References

- [CAPC Documentation](https://github.com/apache/cluster-api-provider-cloudstack)
- [CAPRKE2 Documentation](https://caprke2.docs.rancher.com/)
- [Rancher Turtles](https://turtles.docs.rancher.com/)
- [CloudStack CCM](https://github.com/apache/cloudstack-kubernetes-provider)
- [CloudStack CSI Driver](https://github.com/cloudstack/cloudstack-csi-driver)
