# Create Clusters via CAPI + CAPC

This guide covers provisioning Kubernetes clusters on CloudStack using CAPI CRDs managed by Rancher Turtles + CAPC.

> **ℹ️ Rancher Turtles UI limitations**
>
> Rancher Turtles is designed as a **GitOps-first** integration — the intended workflow is to define clusters as YAML in a Git repo, let Fleet sync them into the management cluster, and have Turtles reconcile and import them into Rancher. The dashboard provides a read-only resource tree view, but almost every operation (creating clusters, scaling, upgrading, configuring providers) requires YAML or `kubectl`.
>
> This is by design, not a bug. If you need UI-driven cluster creation, consider using Rancher's built-in RKE2 provisioning instead. For Turtles, expect to work primarily with `kubectl` and YAML manifests.

## 1. Prerequisites

- Rancher + Turtles + CAPC deployed (see [Rancher](./rancher.md) and [Turtles](./turtles.md))
- CAPI-compatible images registered in CloudStack as templates
- `kubectl` configured with the management cluster

> **⚠️ What CAPC Creates Automatically**
>
> You do **not** need to pre-create the network. CAPC automatically provisions:
> - **Network** — If the specified network doesn't exist, CAPC creates a new isolated network
> - **Load Balancer** — For the Kubernetes API endpoint
> - **Firewall Rules** — For API server access
>
> **Not auto-created:** SSH port forwarding rules must be configured manually in the CloudStack UI (see [Section 4.2](#42-ssh-to-nodes)).
>
> You only need to pre-create: **CAPI-compatible template**, **service offerings**, and a **reserved public IP**.

## 2. Prepare CAPI-Compatible Images

CAPC requires pre-built images with container runtime + kubelet + kubeadm already installed. These are registered as templates in CloudStack.

### 2.1 CAPI-Compatible Images

CAPC requires pre-built images with container runtime + kubelet + kubeadm already installed. These are registered as templates in CloudStack. You can either download a pre-built image or build your own.

#### Pre-built Images (Recommended)

Pre-built CAPI-compatible images are available for multiple hypervisors and Kubernetes versions:

| Hypervisor | Format | Ubuntu 24.04 | Rocky Linux 9 |
|------------|--------|--------------|---------------|
| KVM | qcow2 | [v1.32.3](http://packages.shapeblue.com/cluster-api-provider-cloudstack/images/kvm/ubuntu-2404-kube-v1.32.3-kvm.qcow2.bz2) | [v1.32.3](http://packages.shapeblue.com/cluster-api-provider-cloudstack/images/kvm/rockylinux-9-kube-v1.32.3-kvm.qcow2.bz2) |
| VMware | ova | [v1.32.3](http://packages.shapeblue.com/cluster-api-provider-cloudstack/images/vmware/ubuntu-2404-kube-v1.32.3-vmware.ova) | [v1.32.3](http://packages.shapeblue.com/cluster-api-provider-cloudstack/images/vmware/rockylinux-9-kube-v1.32.3-vmware.ova) |
| XenServer | vhd | [v1.32.3](http://packages.shapeblue.com/cluster-api-provider-cloudstack/images/xen/ubuntu-2404-kube-v1.32.3-xen.vhd.bz2) | [v1.32.3](http://packages.shapeblue.com/cluster-api-provider-cloudstack/images/xen/rockylinux-9-kube-v1.32.3-xen.vhd.bz2) |

Full image list: [CAPC Images](http://packages.shapeblue.com/cluster-api-provider-cloudstack/images/)

#### Building Your Own Image

The steps for building a custom CAPI-compatible image are the same as for the standalone CAPC workflow. See the [CAPC Custom Image Guide](../capc/capc-custom-image.md) for the full build instructions. Once the image is built, register it as a CloudStack template exactly like a pre-built image (see [Section 2.2](#22-register-the-template)).

### 2.2 Register the Template

CloudStack's `register-template` API requires a URL that the management server can reach (HTTP/HTTPS). It does **not** support local file uploads via CloudMonkey. You have two options:

**Option A — Direct upload via CloudStack UI (Recommended for local files)**

1. Download the image locally:
   ```bash
   curl -L http://packages.shapeblue.com/cluster-api-provider-cloudstack/images/kvm/ubuntu-2404-kube-v1.32.3-kvm.qcow2.bz2 -o ubuntu-2404-kube-v1.32.3-kvm.qcow2.bz2
   ```
2. Log into CloudStack UI → **Images → Templates → Upload from Local**
3. Select the downloaded file, then fill in:
   - **Name:** `capc-ubuntu-2404-kube-v1.32.3`
   - **Hypervisor type:** KVM
   - **OS type:** Select the appropriate OS type for Ubuntu 24.04
   - **Is Public:** ✅ true
4. Click **Register**

**Option B — HTTP URL registration (no UI needed)**

If your management server can reach the image URL directly, register it without downloading locally:

```bash
# Register via CloudMonkey (management server downloads from shapeblue URL)
cmk register-template \
  name=capc-ubuntu-2404-kube-v1.32.3 \
  url=http://packages.shapeblue.com/cluster-api-provider-cloudstack/images/kvm/ubuntu-2404-kube-v1.32.3-kvm.qcow2.bz2 \
  hypervisor=KVM \
  ostypeid=<os-type-id> \
  ispublic=true
```

> **Note:** CAPC images are different from CKS ISOs. CKS ISOs are used for bootstrapping CKS clusters via the CloudStack Kubernetes Provider. CAPC images are used directly by CAPC to provision VMs with Kubernetes pre-installed.

### 2.3 Reserve a Public IP

CAPC requires an **available public IP** for the cluster API endpoint. This IP is used as the load balancer endpoint for the Kubernetes API server. CAPC will automatically create firewall rules and load balancer rules for this IP, but **you must provide the IP address** — CAPC does not auto-allocate it.

**To find available public IPs:**

```bash
# List free public IPs in a zone
cmk list publicipaddresses listall=true zoneid=<zone-id> forvirtualnetwork=true allocatedonly=false

# Filter for free IPs only
cmk list publicipaddresses listall=true zoneid=<zone-id> forvirtualnetwork=true allocatedonly=false | jq '.publicipaddress[] | select(.state == "Free" or .state == "Reserved") | .ipaddress'
```

**Important:** The IP must be from the network's public IP pool. If the IP is already allocated, CAPC will fail to create the cluster. Reserve it before creating the cluster.

> **Why is this required?** The Kubernetes API server needs a stable, externally accessible endpoint. CAPC uses CloudStack's built-in load balancer to expose the API server on this IP. Without a reserved public IP, the control plane cannot be reached from outside the management cluster.

## 3. Create a Cluster

### 3.0 Namespace Architecture — Critical

Rancher Turtles uses **multiple namespaces** for different purposes. Understanding this is critical to avoid deployment failures.

```bash
# cattle-capi-system     — CAPI providers (core, bootstrap, control-plane, CAPC) managed by Turtles
# <cluster-namespace>    — Your workload cluster resources (CloudStackCluster, KubeadmControlPlane, MachineDeployment, etc.)
# capc-cluster-1         — Example namespace for a specific cluster
```

**Where each resource lives:**

| Resource | Namespace | Purpose |
|----------|-----------|---------|
| `CAPIProvider` (core, kubeadm-bootstrap, kubeadm-control-plane, cloudstack) | `cattle-capi-system` | Infrastructure providers managed by Turtles |
| `Secret: cloudstack-credentials` | `<cluster-namespace>` | CloudStack API credentials — referenced by CAPC provider and cluster CRDs |
| `CloudStackCluster` | `<cluster-namespace>` | Cluster networking, load balancer, firewall config |
| `KubeadmControlPlane` | `<cluster-namespace>` | Control plane machines (etcd, API server) |
| `MachineDeployment` | `<cluster-namespace>` | Worker nodes |
| `Secret: <cluster-name>-kubeconfig` | `<cluster-namespace>` | Workload cluster kubeconfig (auto-generated by CAPC) |

**⚠️ Common mistake:** Deploying `cloudstack-credentials` to `cattle-capi-system` instead of the cluster's namespace. The secret must be in the **same namespace as your cluster CRDs**, not where Turtles manages providers.

```bash
# Correct: credentials in cluster namespace
kubectl apply -f cloudstack-secret.yaml -n capc-cluster-1

# WRONG: credentials in cattle-capi-system
# kubectl apply -f cloudstack-secret.yaml -n cattle-capi-system  ← don't do this
```

### 3.1 CAPI Resource Model: Machine, MachineSet, MachineDeployment

These objects appear in the Rancher Turtles UI and in `kubectl`. Understanding how they relate prevents confusion when scaling or troubleshooting.

| Object | What it represents | Do you edit it directly? |
|---|---|---|
| **Machine** | One VM / one Kubernetes node | Usually no |
| **MachineSet** | Controller that keeps N identical Machines running | No |
| **MachineDeployment** | User-facing declaration: "I want N workers" | Yes (for workers) |

> **Note on control plane:** `KubeadmControlPlane` is the control-plane equivalent of a `MachineDeployment`, but it is **not exposed as a separate UI element in Rancher Turtles**. You manage it through `kubectl` (or the cluster's YAML) rather than the Turtles resource tree.

#### Relationship

**Workers:**

```text
MachineDeployment (capc-cluster-1-md-0)
    └── MachineSet (capc-cluster-1-md-0-46xs6)
            ├── Machine → Node worker-1
            └── Machine → Node worker-2
```

**Control plane:**

```text
KubeadmControlPlane (capc-cluster-1-control-plane)
    ├── Machine → Node control-plane-1
    ├── Machine → Node control-plane-2
    └── Machine → Node control-plane-3
```

#### Key points

- **`Machine`** is the lowest-level object. CAPC creates one CloudStack VM for each Machine.
- **`MachineSet`** is owned by a `MachineDeployment`. It exists only to keep the right number of Machines. You normally ignore it.
- **`MachineDeployment`** is what you scale for workers. Change `spec.replicas` and CAPI reconciles the MachineSet/Machines for you.
- **`KubeadmControlPlane`** directly owns Machine objects for the control plane and also manages etcd / API-server membership. It has no dedicated Turtles UI element, so scaling the control plane is done via `kubectl patch kubeadmcontrolplane ...`.
- Control plane replica counts must be **odd** (`1`, `3`, `5`) because etcd needs quorum.

#### Common commands

```bash
# List machine resources (note: KubeadmControlPlane is kubectl-only in Turtles)
kubectl get machinedeployment,machinesets,machines -n capc-cluster-1

# Scale workers (works via Turtles UI or kubectl)
kubectl patch machinedeployment capc-cluster-1-md-0 -n capc-cluster-1 --type merge -p '{"spec":{"replicas":3}}'

# Scale control plane (kubectl only; no Turtles UI element for KCP)
kubectl patch kubeadmcontrolplane capc-cluster-1-control-plane -n capc-cluster-1 --type merge -p '{"spec":{"replicas":3}}'
```

### 3.2 Minimal Cluster (1 Control + 2 Workers)

The full cluster YAML is available in the manifests folder: [10-minimal-cluster.yaml](./manifests/10-minimal-cluster.yaml)

### Required Parameters — Replace All Before Applying

| Parameter | Description | How to Find |
|-----------|-------------|-------------|
| `<reserved-public-ip>` | Free public IP for API endpoint | `cmk list publicipaddresses listall=true zoneid=<zone-id> forvirtualnetwork=true allocatedonly=false` |
| `<network-name-or-id>` | Network name/ID — **CAPC creates a new isolated network if it doesn't exist** | Any name you choose (e.g. `capc-cluster-1-net`). To list existing: `cmk list networks listall=true zoneid=<zone-id>` |
| `<zone-name-or-id>` | CloudStack zone | `cmk list zones` |
| `capc-ubuntu-2404-kube-v1.32.3` | CAPI-compatible template name | Must be registered (see [Section 2.2](#22-register-the-template)) |
| `Medium` / `Large` | Service offering names | `cmk list serviceofferings listall=true` (control plane needs ≥2GB RAM, 2 vCPU) |

| `my-ssh-key` | CloudStack SSH keypair name | `cmk register-sshkeypair --name=my-ssh-key --publickey="$(cat ~/.ssh/id_ed25519.pub)"` |

> **SSH access:** This example uses the **CloudStack SSH KeyPair** method — the recommended approach. Register your key via `cmk register-sshkeypair`, then reference it via the `sshKey` field on `CloudStackMachine` resources. CloudStack injects the key into the default image user (`ubuntu` for Ubuntu images, `cloud-user` for Rocky). For advanced first-boot customization, see [Section 3.7](#37-advanced--inline-cloud-init-customization).

> **Namespace note:** The YAML uses `namespace: default`, which means all CAPI resources (CloudStackCluster, KubeadmControlPlane, MachineDeployment, etc.) are created in the `default` namespace of the **management cluster** (your Rancher cluster). The workload cluster itself is just VMs on CloudStack — it has no namespace. To apply to a different namespace without editing the file: `kubectl apply -f manifests/10-minimal-cluster.yaml -n my-clusters`

> **`syncWithACS: true`** — This setting (on the `CloudStackCluster` spec) tells CAPC to register the workload cluster as an `ExternalManaged` entry in CloudStack's **Compute → Kubernetes** UI. It works **only** when CAPC is deployed with the controller flag `--enable-cloudstack-cks-sync=true` (the default with plain `clusterctl`, but `false` in the Rancher Turtles manifests used by this guide). If that flag is left as `false`, the `CksClusterReconciler` is not registered, so `syncWithACS: true` does nothing and the cluster never appears in the CloudStack UI. See [Install CAPC via CAPIProvider](./turtles.md#install-capc-provider) for how to enable it.

```bash
kubectl apply -f manifests/10-minimal-cluster.yaml
```

### 3.3 Create Namespace + CloudStack Credentials Secret

All CAPI resources for this cluster must live in a dedicated namespace on the **management cluster** (your Rancher cluster). The workload cluster itself is just VMs on CloudStack — it has no namespace. But the CAPI CRDs (`Cluster`, `CloudStackCluster`, `KubeadmControlPlane`, etc.) are regular Kubernetes resources that need a namespace.

```bash
# Create the namespace (must match the namespace in your manifest)
kubectl create namespace capc-cluster-1

# Verify it exists
kubectl get namespace capc-cluster-1
```

**Create the CloudStack credentials secret in the same namespace:**

```yaml
# cloudstack-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: cloudstack-credentials
  namespace: capc-cluster-1    # ← must match cluster namespace, NOT cattle-capi-system
type: Opaque
stringData:
  api-url: "http://<management-server>:8080/client/api"
  api-key: "<your-api-key>"
  secret-key: "<your-secret-key>"
  verify-ssl: "false"
```

```bash
kubectl apply -f cloudstack-secret.yaml
```

> **⚠️ Critical:** The `cloudstack-credentials` secret must be in the **same namespace as your cluster CRDs** (`capc-cluster-1`), not in `cattle-capi-system` where Turtles manages providers. If you deploy it to the wrong namespace, CAPC won't find it and cluster creation will fail.

> **⚠️ Namespace must exist before applying:** Always create the namespace first, then the secret, then the cluster manifest.

### 3.4 Apply and Monitor

```bash
kubectl apply -f manifests/10-minimal-cluster.yaml

# Watch cluster creation
kubectl get clusters
kubectl get cloudstackclusters
kubectl get cloudstackmachines
kubectl get machinesets
kubectl get machinedeployments

# Check events
kubectl get events --sort-by='.lastTimestamp' -n default
```

> **⚠️ CNI Required:** After the control plane is provisioned, you **must** install a CNI plugin before workers become `Ready` and pods can be scheduled. See [Section 5.1](#51-calico-recommended) for installation instructions. Without a CNI, worker nodes report `NotReady`, the `MachineDeployment` shows zero available replicas, and CoreDNS pods remain `Pending`.

### 3.5 Verification Checklist

Run these commands after deployment to verify the cluster reaches a provisioned state. Then install a CNI (Section 5) and run the post-CNI checks.

#### Phase 1 — After Deployment, Before CNI

These checks confirm the management plane, control plane, and worker VMs exist. Do **not** expect workers to be `Ready` or `MachineDeployment` replicas to be available yet.

```bash
# Management plane
kubectl get pods -n cattle-capi-system | grep turtles
kubectl get capiproviders -A

# Cluster CRDs
kubectl get clusters
kubectl get cloudstackclusters
kubectl get kubeadmcontrolplanes
kubectl get machines
kubectl get machinesets
kubectl get machinedeployments
```

**Expected state before CNI:**
- `Cluster` → phase: `Provisioned`
- `CloudStackCluster` → `Ready`
- `KubeadmControlPlane` → initialized, API server reachable (e.g., `1/1` for minimal)
- `MachineDeployment` → desired replicas created, but **available: 0** until CNI
- `Machines` → phase: `Running`; control-plane `Machine` Ready: `true`; worker `Machines` Ready: `false` (expected)

If workers are `NotReady` at this stage, that is normal — proceed to install the CNI.

```bash
# Workload cluster — control plane only
kubectl get secret capc-cluster-1-kubeconfig -o jsonpath='{.data.value}' | base64 -d > kubeconfig

kubectl --kubeconfig=kubeconfig get nodes
# Expected: control-plane node(s) Ready, worker nodes NotReady

kubectl --kubeconfig=kubeconfig get pods -n kube-system
# Expected: CoreDNS pods Pending until CNI is installed

kubectl --kubeconfig=kubeconfig cluster-info
# Expected: API server reachable
```

#### Phase 2 — After CNI Installation

Install a CNI from [Section 5](#5-install-cni), then verify:

```bash
kubectl --kubeconfig=kubeconfig get nodes -o wide
# Expected: all nodes (control plane + workers) Ready

kubectl --kubeconfig=kubeconfig get pods -n kube-system
# Expected: CoreDNS and CNI pods Running

kubectl get machinedeployments
# Expected: available replicas equal to desired replicas

kubectl get machines
# Expected: all machines phase Running, Ready: true
```

#### Networking — Pod-to-Pod

```bash
# CNI pods running?
kubectl --kubeconfig=kubeconfig get pods -A | grep -E 'calico|cilium|flannel'

# Test pod-to-pod communication
kubectl --kubeconfig=kubeconfig apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ping-test-1
spec:
  containers:
  - name: ping
    image: nicolaka/netshoot
    command: ["sleep", "3600"]
---
apiVersion: v1
kind: Pod
metadata:
  name: ping-test-2
spec:
  containers:
  - name: ping
    image: nicolaka/netshoot
    command: ["sleep", "3600"]
EOF

kubectl --kubeconfig=kubeconfig exec ping-test-1 -- ping -c 3 <ping-test-2-ip>
# Expected: 3 packets transmitted, 3 received, 0% packet loss
```

#### Quick One-Liner Summary

```bash
# All-in-one health check (run after CNI is installed)
echo "=== Turtles ===" && \
kubectl get pods -n cattle-capi-system | grep turtles && echo "" && \
echo "=== CAPC ===" && \
kubectl get pods -n cattle-capi-system | grep capc && echo "" && \
echo "=== CAPI CRDs ===" && \
kubectl get clusters,cloudstackclusters,kubeadmcontrolplanes,machinesets,machinedeployments && echo "" && \
echo "=== Workload Nodes ===" && \
kubectl --kubeconfig=kubeconfig get nodes && echo "" && \
echo "=== System Pods ===" && \
kubectl --kubeconfig=kubeconfig get pods -n kube-system | grep -v Running || echo "All system pods running"
```

### 3.6 HA Cluster (3 Control + 3 Workers)

The full cluster YAML is available in the manifests folder: [11-ha-cluster.yaml](./manifests/11-ha-cluster.yaml)

### Required Parameters — Replace All Before Applying

Same parameters as the minimal cluster (see table above). The HA cluster uses:
- **Control plane:** `Large` service offering (recommended for HA)
- **Workers:** `Large` service offering


> **Namespace note:** Same as above — resources are created in the `default` namespace of the management cluster. To apply elsewhere: `kubectl apply -f manifests/11-ha-cluster.yaml -n my-clusters`

```bash
kubectl apply -f manifests/11-ha-cluster.yaml
```

### 3.7 Advanced — Inline Cloud-Init Customization

Use this only when you need first-boot customization beyond what CloudStack's SSH KeyPair can provide — for example, installing packages, loading kernel modules, setting `sysctl` parameters, creating custom systemd services, provisioning files, or defining users that do not match the image default.

See [12-custom-image-cluster.yaml](./manifests/12-custom-image-cluster.yaml) for an example.

This approach uses `KubeadmConfig.users` to create users and inject SSH keys via cloud-init, plus `preKubeadmCommands` and `postKubeadmCommands` for arbitrary setup. The `CloudStackMachine` resources omit the `sshKey` field — SSH is handled entirely by cloud-init.

> **⚠️ User name must match your image:** With inline cloud-init you explicitly define the user in `KubeadmConfig.users`. Make sure it matches the default user in your CAPI-compatible image:
> - **Ubuntu images** → `ubuntu`
> - **Rocky Linux images** → `cloud-user`
> - **Custom images** → whatever user is embedded in the image

```bash
kubectl apply -f manifests/12-custom-image-cluster.yaml
```

## 4. Access the Cluster

### 4.1 Get kubeconfig

```bash
# The cluster creates a Secret with kubeconfig
kubectl get secret capc-cluster-1-kubeconfig -o jsonpath='{.data.value}' | base64 -d > kubeconfig

# Use it
kubectl --kubeconfig=kubeconfig get nodes
kubectl --kubeconfig=kubeconfig get pods -n kube-system
```

### 4.2 SSH to Nodes

SSH access uses the **CloudStack SSH KeyPair** referenced by the `sshKey` field in the cluster manifest. Register your public key in CloudStack once with `cmk register-sshkeypair`, then CloudStack injects it into the default image user automatically.

```bash
# Example: register an SSH keypair
export CLOUDSTACK_KEYPAIR_NAME=my-ssh-key
cmk register-sshkeypair --name="$CLOUDSTACK_KEYPAIR_NAME" --publickey="$(cat ~/.ssh/id_ed25519.pub)"
```

CAPC auto-creates firewall rules and load balancer rules for the **API endpoint IP** (the public IP you specified in `controlPlaneEndpoint.host`), but **SSH access to individual nodes requires manual configuration**.

For each node you want to SSH into, configure these in the CloudStack UI:

1. **Select the Public IP** belonging to the cluster's network (either the API endpoint IP or a dedicated IP)
2. **Add a firewall rule** to allow access on the desired port (e.g. TCP port 22)
3. **Add a port forwarding rule** from the public IP to the VM's private IP on the desired port

> **Isolated networks only:** SSH port forwarding and firewall rules only work on isolated networks. For shared/routed networks, configure routes on the external network's management plane instead.

#### Using SSH After Cluster Creation

After the cluster is created, CNI is installed, and firewall/port-forwarding rules are configured:

```bash
# Control plane nodes (use the API endpoint IP or forwarded port)
ssh -i <private-key> <username>@<public-ip>

# Worker nodes (use the forwarded public IP)
ssh -i <private-key> <username>@<public-ip>
```

Replace `<username>` with the user embedded in your CAPI-compatible image:
- **Ubuntu images** → `ubuntu`
- **Rocky Linux images** → `cloud-user`
- **Custom images** → whatever user is embedded in the image

> **Advanced customization:** If you need per-cluster SSH users, package installation, or other first-boot setup, see [Section 3.7](#37-advanced--inline-cloud-init-customization) for inline cloud-init.

## 5. Install CNI

CAPC clusters do **not** include a CNI by default. You must install one after the cluster is created. Without a CNI, pods cannot communicate with each other.

### 5.1 Calico (Recommended)

```bash
kubectl --kubeconfig=kubeconfig apply -f https://raw.githubusercontent.com/projectcalico/calico/master/manifests/calico.yaml
```

### 5.2 Cilium

Install Cilium using Helm:

```bash
# Add the Cilium Helm repo
helm repo add cilium https://helm.cilium.io/
helm repo update

# Install Cilium in kube-system namespace
helm install cilium cilium/cilium --namespace kube-system \
  --set ipam.mode=kubernetes
```

### 5.3 Change CNI

If you installed the wrong CNI, uninstall it first, then install the correct one:

```bash
kubectl --kubeconfig=kubeconfig delete -f https://raw.githubusercontent.com/projectcalico/calico/master/manifests/calico.yaml
kubectl --kubeconfig=kubeconfig apply -f <new-cni-manifest>
```

## 6. Scale the Cluster

### 6.1 Scale Workers

```bash
# Via kubectl
kubectl scale machinedeployment capc-cluster-1-workers --replicas=5

# Or edit the MachineDeployment
kubectl edit machinedeployment capc-cluster-1-workers
```

### 6.2 Scale Control Plane

Control plane scaling uses the `KubeadmControlPlane` resource — a separate CR from worker `MachineDeployment`:

```bash
# Find your KubeadmControlPlane
kubectl get kubeadmcontrolplane -A

# Scale up (or down) by changing replicas
kubectl edit kubeadmcontrolplane capc-cluster-1-control-plane
```

In the editor, find `.spec.replicas` and change it:

```yaml
spec:
  replicas: 3    # ← change this (use odd number for HA: 1, 3, 5...)
```

**Key differences from worker scaling:**

| | Control Plane (`KubeadmControlPlane`) | Workers (`MachineDeployment`) |
|---|---|---|
| Resource | `kubectl edit kubeadmcontrolplane <name>` | `kubectl edit machinedeployment <name>` |
| Field | `.spec.replicas` | `.spec.replicas` |
| Safety | CAPC enforces odd ≥ 3 for etcd quorum | Any number (including 0) |
| Rolling | Yes — old VMs terminate, new ones provision | Same rolling update pattern |

**Important notes:**

- **Always use odd numbers** for control plane (1, 3, 5) — etcd needs quorum
- CAPC will do a **rolling update** — old control plane VMs are terminated and new ones provisioned from the same template
- If you're scaling down from 3 to 1, make sure your cluster can survive losing 2 control plane nodes (etcd quorum)
- Monitor progress: `kubectl get machines -A` and `kubectl get kubeadmcontrolplane <name> -o wide`

### 6.3 Verify Scaling Progress

```bash
# Watch machines come up
kubectl get machines -A -w

# Check KubeadmControlPlane status
kubectl get kubeadmcontrolplane capc-cluster-1-control-plane -o wide

# Check node readiness
kubectl --kubeconfig=kubeconfig get nodes -w
```

> **Note:** Rancher Turtles manages the CAPC controllers declaratively via `CAPIProvider` resources, but cluster scaling works exactly the same as traditional CAPC — you edit the workload cluster's CRDs directly.

## 7. Rancher Turtles Auto-Import

To have Rancher Turtles automatically register a CAPC workload cluster in Rancher Manager, the CAPI `Cluster` object (or its namespace) must carry the **Rancher Turtles auto-import label**:

```yaml
labels:
  cluster-api.cattle.io/rancher-auto-import: "true"
```

This label is already set in the example manifests (`10-minimal-cluster.yaml`, `11-ha-cluster.yaml`, `13-one-shot-full-stack.yaml`, `31-cluster-topology.yaml`). You can also apply it to the namespace once, so every cluster created in that namespace is auto-imported:

```bash
kubectl label namespace capc-cluster-1 cluster-api.cattle.io/rancher-auto-import=true
```

### 7.1 What Turtles Requires Before Importing

Turtles does **not** import the cluster immediately when the label is present. The import controller waits for the CAPI condition:

```text
ControlPlaneAvailable = True
```

You can watch for it with:

```bash
kubectl wait cluster -n capc-cluster-1 capc-cluster-1 \
  --for=condition=ControlPlaneAvailable=True --timeout=600s
```

`ControlPlaneAvailable` becomes `True` only when:

1. **The management cluster can reach the CAPC control-plane endpoint.**  
   Verify from a pod on the Rancher management cluster:
   ```bash
   kubectl run -it --rm debug --image=nicolaka/netshoot --restart=Never
   curl -k -m 10 https://<reserved-public-ip>:6443/healthz
   nc -zv <reserved-public-ip> 6443
   ```
2. **The CAPC control plane reports itself healthy.**  
   For a **single-node control plane with no workers**, the cluster can reach this state without a CNI because the API server is exposed directly via the CloudStack load balancer.  
   For a cluster with **workers (`MachineDeployment.replicas > 0`)**, a CNI is required: without it the worker nodes stay `NotReady`, CAPI reports the `MachineDeployment` as having zero available replicas, and the `ControlPlaneAvailable` condition stays `False` / `NotAvailable` even though the API endpoint itself is reachable.

### 7.2 Network and Certificate Requirements for Auto-Import

Once `ControlPlaneAvailable=True`, Turtles begins the auto-import handshake. Two additional requirements must be satisfied for the cluster to become `Connected` and `Ready` in Rancher:

| Requirement | Why it matters | Failure symptom |
|---|---|---|
| **Management cluster can resolve the Rancher `server-url` hostname** | Turtles downloads the agent import manifest from `https://<server-url>/v3/import/<token>_<cluster-id>.yaml`. | Turtles logs: `dial tcp: lookup rancher.cylab.lee ... no such host` |
| **Turtles trusts the Rancher server certificate** | The import manifest download uses HTTPS. With a self-signed/dynamiclistener Rancher cert, Turtles' system CA store does not trust it. | Turtles logs: `tls: failed to verify certificate: x509: certificate signed by unknown authority` |
| **Workload cluster nodes/pods can resolve the Rancher `server-url` hostname** | The deployed `cattle-cluster-agent` pod must reach Rancher to connect back. | Agent logs: `Could not resolve host: rancher.cylab.lee` |
| **Workload cluster trusts the Rancher CA** | The agent verifies Rancher's TLS certificate when registering. | Agent logs: `certificate signed by unknown authority` or registration TLS errors |

**For a self-signed Rancher certificate** (the default `dynamiclistener` CA generated by Rancher), ensure that:

1. The management cluster DNS (`kube-rancher-network`) resolves the Rancher `server-url` hostname to the Rancher server IP.
2. The workload cluster network (`capcnet1`) resolves the same hostname.
3. Turtles has access to the Rancher CA certificate, and the workload cluster agent has access to the Rancher CA certificate.  
   > **Note:** We patched the Turtles deployment with a ConfigMap containing the Rancher CA from `secret/tls-rancher-ingress` and mounted it via `SSL_CERT_FILE`. For production, use a properly trusted certificate or distribute the CA through the standard operating-system trust store on all nodes.

If your Rancher server uses the default self-signed `dynamiclistener` certificate (secret `tls-rancher-ingress` in the `cattle-system` namespace), Turtles will fail to download the import manifest with an `x509: certificate signed by unknown authority` error. The fix is to inject that CA into the Turtles controller pod.

#### Injecting the Rancher CA into Turtles

1. **Extract the Rancher CA certificate.**

   The CA is stored in the `ca.crt` field of the `tls-rancher-ingress` secret in the Rancher namespace (usually `cattle-system`):

   ```bash
   KUBECONFIG=~/.kube/kube-rancher-config
   RANCHER_NS=cattle-system

   kubectl get secret tls-rancher-ingress -n "$RANCHER_NS" -o jsonpath='{.data.ca\.crt}' | base64 -d > rancher-ca.crt
   ```

   If `ca.crt` is not present, extract it from `tls.crt` instead:

   ```bash
   kubectl get secret tls-rancher-ingress -n "$RANCHER_NS" -o jsonpath='{.data.tls\.crt}' | base64 -d > rancher-ca.crt
   ```

2. **Create a ConfigMap with the CA in the Turtles namespace.**

   ```bash
   kubectl create configmap rancher-turtles-ca \
     -n cattle-turtles-system \
     --from-file=ca.crt=rancher-ca.crt \
     --dry-run=client -o yaml | kubectl apply -f -
   ```

3. **Mount the CA into the Turtles controller via `SSL_CERT_FILE`.**

   Edit the Turtles controller Deployment:

   ```bash
   kubectl edit deployment rancher-turtles-controller-manager -n cattle-turtles-system
   ```

   Add or update the following items:

   - An environment variable in the `manager` container:

     ```yaml
     env:
       - name: SSL_CERT_FILE
         value: /etc/ssl/rancher/ca.crt
     ```

   - A volume mount in the same container:

     ```yaml
     volumeMounts:
       - name: rancher-ca
         mountPath: /etc/ssl/rancher
         readOnly: true
     ```

   - A new volume:

     ```yaml
     volumes:
       - name: rancher-ca
         configMap:
           name: rancher-turtles-ca
     ```

4. **Wait for the Deployment to roll out.**

   ```bash
   kubectl rollout status deployment/rancher-turtles-controller-manager -n cattle-turtles-system
   ```

5. **Verify the CA is loaded.**

   ```bash
   kubectl exec -n cattle-turtles-system \
     deploy/rancher-turtles-controller-manager -- \
     sh -c 'SSL_CERT_FILE=/etc/ssl/rancher/ca.crt openssl s_client -connect ${RANCHER_HOST}:443 -CAfile /etc/ssl/rancher/ca.crt </dev/null 2>/dev/null | grep Verify'
   ```

   Replace `${RANCHER_HOST}` with the hostname in your Rancher `server-url`. You should see `Verify return code: 0 (ok)`.

#### Workload cluster agent trust (self-signed Rancher)

For Turtles auto-import, you generally **do not need to manually distribute the Rancher CA to workload cluster nodes**. The import manifest that Turtles downloads from Rancher includes the Rancher server URL and a `CATTLE_CA_CHECKSUM` environment variable. The Rancher `cattle-cluster-agent` uses that checksum to validate/retrieve the CA during registration.

- **Self-signed Rancher (`dynamiclistener` CA):** Turtles downloads the import manifest, which embeds the CA checksum. The deployed `cattle-cluster-agent` pods trust the Rancher CA via `CATTLE_CA_CHECKSUM`; no node OS CA-store change is required for auto-import.
- **Publicly trusted or corporate PKI Rancher certificate:** The agent validates the certificate against the standard trust store or the chain provided by the server, again with no extra manual steps.

The only TLS prerequisite that usually needs manual intervention for a self-signed Rancher certificate is the **Turtles controller itself**, covered in the previous subsection.

Manual CA distribution (CRS, baked-into-image, or OS trust-store update) is only necessary if you run custom workloads or pipelines inside the workload cluster that directly call the Rancher API and cannot use `CATTLE_CA_CHECKSUM`. For Turtles auto-import, it is not required.

If the agent still shows TLS errors, check the `cattle-cluster-agent` pod logs:

```bash
kubectl --kubeconfig=~/.kube/capc-cluster-1-config logs -n cattle-system -l app=cattle-cluster-agent
```

Common issues:

| Symptom | Cause |
|---|---|
| `certificate signed by unknown authority` in Turtles logs | Turtles does not trust the Rancher CA; patch `SSL_CERT_FILE` as shown above. |
| `certificate signed by unknown authority` in `cattle-cluster-agent` logs | `CATTLE_CA_CHECKSUM` is missing or does not match the current Rancher CA. Ensure Turtles is downloading a fresh import manifest from Rancher. |

### 7.3 Control-Plane-Only Cluster vs. CNI

> **⚠️ Disclaimer — this is a theoretical demonstration.**  
> Running a CAPC cluster with zero worker nodes is **not a practical production or even development configuration**. In real usage you will always have workers, and for those workers to become `Ready`, the cluster **must have a CNI installed**. Therefore, for any practical CAPC workload cluster, **CNI installation is effectively required for Rancher Turtles auto-import**, because the CAPI availability gate depends on the worker `MachineDeployment` having available replicas.

A CAPC cluster *technically* can be auto-imported without CNI **only when it has no worker nodes**. This is useful only to understand the Turtles import predicate — it proves that the missing piece with workers is not API-server reachability, but worker node readiness.

A practical test is:

```bash
# Scale workers to 0
kubectl scale md.cluster.x-k8s.io -n capc-cluster-1 capc-cluster-1-md-0 --replicas=0

# Wait for ControlPlaneAvailable
kubectl wait cluster -n capc-cluster-1 capc-cluster-1 \
  --for=condition=ControlPlaneAvailable=True --timeout=600s
```

Once Turtles imports the cluster, scale the workers back up and **install the CNI immediately** to make the workload cluster fully operational.

### 7.4 Do Not Use the Bootstrap Label on Workload Clusters

The `turtles.cattle.io/bootstrap: "true"` label is intended for the **local/bootstrap cluster** (the cluster that runs Rancher itself), not for CAPC workload clusters. Applying it to workload clusters can cause Rancher/Turtles to misidentify the cluster. Remove it from all workload cluster manifests and use only `cluster-api.cattle.io/rancher-auto-import: "true"`.

### 7.5 If Auto-Import Does Not Happen

1. Confirm the label is present on the `Cluster` or namespace.
2. Confirm `ControlPlaneAvailable` is `True`.  
   If you have workers and no CNI, it will remain `NotAvailable` because the `MachineDeployment` has zero available replicas.
3. Confirm the management cluster can reach the CAPC API endpoint on port `6443`.
4. Confirm the management cluster **and** the workload cluster can resolve the Rancher `server-url` hostname.
5. Confirm Turtles and the workload `cattle-cluster-agent` trust the Rancher CA (for self-signed certificates).
6. Check Turtles controller logs for import predicate failures:
   ```bash
   kubectl logs -n cattle-turtles-system -l app=rancher-turtles-controller-manager
   ```
7. Check the workload cluster agent logs:
   ```bash
   kubectl --kubeconfig=~/.kube/capc-cluster-1-config logs -n cattle-system -l app=cattle-cluster-agent
   ```
8. If you manually imported the cluster first, Turtles may have already annotated it with `cluster-api.cattle.io/imported: "true"` and will skip auto-import. In that case the cluster is managed by Rancher anyway; for net-new clusters, ensure the steps above are met before applying the manifest.

## 8. Upgrade the Cluster

> **Full stack upgrade guide:** This section covers the K8s version upgrade for Rancher Turtles-managed clusters. For a complete end-to-end upgrade that also includes the CAPC controller, CNI, CSI, and CCM, see the [CAPC Cluster Upgrade — Full Stack Guide](../capc/capc-upgrade.md).

### 8.1 Upgrade Kubernetes Version

A Kubernetes upgrade in CAPC is a **rolling update**. CAPI creates new Machines from new `CloudStackMachineTemplate` objects, joins them to the cluster, and removes the old ones one at a time.

> **⚠️ CloudStackMachineTemplates are immutable.** You cannot patch an existing template — you must create **new** template objects with the updated image reference, then update `KubeadmControlPlane` and `MachineDeployment` to point to them.

#### Step 1 — Build or register the target image

Build a new CAPC image with the target Kubernetes version (see [Pre-built Images](#pre-built-images-recommended) for prebuilt images or [Building Your Own Image](../capc/capc-custom-image.md) for custom builds). Register it in CloudStack as a template.

Verify the template is available:

```bash
cmk listTemplates filter=unique nameFilter="capc-ubuntu24-1.36"
```

#### Step 2 — Create new CloudStackMachineTemplates

Export the existing templates, strip read-only metadata, rename them, and update the image reference:

```bash
# Export current templates
kubectl get cloudstackmachinetemplate capc-cluster-1-control-plane -n capc-cluster-1 -o yaml > /tmp/cp-template.yaml
kubectl get cloudstackmachinetemplate capc-cluster-1-md-0 -n capc-cluster-1 -o yaml > /tmp/md-template.yaml
```

Edit both files. For each file:

1. **Remove** these metadata fields (they are read-only on apply):
   - `metadata.uid`
   - `metadata.resourceVersion`
   - `metadata.creationTimestamp`
   - `metadata.ownerReferences`
   - `metadata.annotations`
2. **Change** `metadata.name` to a new name with the target version:
   - Control plane: `capc-cluster-1-control-plane-v1.36`
   - Workers: `capc-cluster-1-md-0-v1.36`
3. **Change** `spec.template.spec.template.name` to the new CloudStack template name (e.g., `capc-ubuntu24-1.36`)
4. **Keep** `offering`, `sshKey`, `diskOffering` unchanged.

Apply the new templates:

```bash
kubectl apply -f /tmp/cp-template.yaml -n capc-cluster-1
kubectl apply -f /tmp/md-template.yaml -n capc-cluster-1
```

#### Step 3 — Update KubeadmControlPlane (new template + version)

Point KCP to the new control-plane template and update the Kubernetes version in a single patch:

```bash
kubectl patch kubeadmcontrolplane capc-cluster-1-control-plane -n capc-cluster-1 --type merge -p '{
  "spec": {
    "machineTemplate": {
      "infrastructureRef": {
        "name": "capc-cluster-1-control-plane-v1.36"
      }
    },
    "version": "v1.36.0"
  }
}'
```

CAPI immediately starts replacing control-plane nodes one at a time (etcd quorum is maintained throughout).

#### Step 4 — Update MachineDeployment (new template + version)

Point the MachineDeployment to the new worker template and update the version:

```bash
kubectl patch machinedeployment capc-cluster-1-md-0 -n capc-cluster-1 --type merge -p '{
  "spec": {
    "template": {
      "spec": {
        "infrastructureRef": {
          "name": "capc-cluster-1-md-0-v1.36"
        },
        "version": "v1.36.0"
      }
    }
  }
}'
```

#### Step 5 — Monitor the rolling update

```bash
# Watch machines (control plane first, then workers)
kubectl get machines -n capc-cluster-1 -w

# Check KCP status
kubectl get kubeadmcontrolplane capc-cluster-1-control-plane -n capc-cluster-1

# Check MachineDeployment status
kubectl get machinedeployment capc-cluster-1-md-0 -n capc-cluster-1

# Verify workload cluster nodes
kubectl --kubeconfig=kubeconfig get nodes
```

CAPI upgrades the control plane first (one node at a time, waiting for etcd health), then rolls the workers. The entire process can take 10–30 minutes depending on VM provisioning time.

> **Order matters:** Create the new `CloudStackMachineTemplate` objects **before** patching KCP/MD. If you patch KCP/MD first, CAPI will try to reference a template that doesn't exist yet.

## 9. Troubleshooting

### 9.1 VM Deleted from CloudStack — Node Not Recreated

If you delete a VM directly from CloudStack (UI, cmk, API), CAPC **will not automatically recreate it**. Here's why and how to fix it:

**Why it doesn't work:** When the VM is deleted, the `CloudStackMachine` CR still exists with its `InstanceID` set. CAPC's controller looks up that InstanceID in CloudStack, gets "not found," and **doesn't automatically create a replacement** — it just requeues and waits. The CAPI MachineDeployment sees its replica count is met (the Machine CR still exists), so it doesn't generate a new one either.

**Fix — remove the finalizer and delete stale CAPI objects:**

```bash
# 1. Find the machines that are stuck
kubectl get machines -A

# 2. Remove the finalizer from the CloudStackMachine (VM is already gone, so cleanup will hang)
kubectl patch cloudstackmachine <name> -n <namespace> \
  --type merge -p '{"metadata":{"finalizers":null}}'

# 3. Also remove the finalizer from the Machine CR if it's stuck
kubectl patch machine <name> -n <namespace> \
  --type merge -p '{"metadata":{"finalizers":null}}'

# 4. Delete both CRs
kubectl delete cloudstackmachine <name> -n <namespace>
kubectl delete machine <name> -n <namespace>
```

Once the Machine CR is deleted, the `MachineDeployment` notices the replica count is below desired and creates a **new Machine + CloudStackMachine**, which CAPC provisions as a fresh VM.

**After the new node joins:** The old Kubernetes node object (orphaned) will still exist with taints. Clean it up:

```bash
# Drain the old node
kubectl drain <old-node-name> --ignore-daemonsets --delete-emptydir-data

# Remove it from the cluster
kubectl delete node <old-node-name>
```

**Alternative — scale down and back up:**

```bash
kubectl scale machinedeployment <name> --replicas=0 -n <namespace>
kubectl scale machinedeployment <name> --replicas=<desired-count> -n <namespace>
```

This forces the MachineSet to recreate all machines from scratch.

**Root cause:** CAPC's `GetOrCreateVMInstance()` only creates a VM if the CloudStackMachine has no InstanceID. Once the CR exists with an InstanceID (even pointing to a deleted VM), it won't recreate. This is a known gap in drift detection — manual cleanup of stale CAPI objects is required.

### 9.2 Cluster Stuck in "Provisioning"

```bash
# Check CloudStackCluster status
kubectl describe cloudstackcluster capc-cluster-1

# Check CloudStackMachine events
kubectl describe cloudstackmachine capc-cluster-1-workers-xxxxx

# Check CAPC controller logs
kubectl logs -n cattle-capi-system -l app=cloudstack -f
```

### 9.3 Nodes Not Joining

```bash
# Check kubeadm logs on nodes
ssh -i <key> -p 2222 cloud@<VR_PUBLIC_IP> "sudo journalctl -u kubelet -f"

# Check bootstrap token
kubectl get secret | grep bootstrap

# Check API server connectivity
kubectl --kubeconfig=kubeconfig get nodes
```

### 9.4 CloudStack VM Creation Failed

```bash
# Check CAPC logs for CloudStack API errors
kubectl logs -n cattle-capi-system -l app=cloudstack | grep -i error

# Verify CloudStack resources
# In CloudStack UI: Compute → VMs → check if VMs were created

# Verify template exists and is active
cmk list templates filter=featured id=<template-id>

# Verify service offering exists
cmk list serviceofferings id=<offering-id>
```

## 10. Next Steps

- [Fleet GitOps](./fleet.md) — Automate cluster management with Fleet
- [CAPC Upgrade Guide](../capc/capc-upgrade.md) — Upgrading CAPC and clusters
