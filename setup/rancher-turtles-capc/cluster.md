# Create Clusters via CAPI + CAPC

This guide covers provisioning Kubernetes clusters on CloudStack using CAPI CRDs managed by Rancher Turtles + CAPC.

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

### 3.1 Minimal Cluster (1 Control + 2 Workers)

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

> **SSH Key Method:** This example uses **Method 1** (CloudStack SSH KeyPair) — the recommended approach. Register your key via `cmk register-sshkeypair`, then reference it via the `sshKey` field on `CloudStackMachine` resources. CloudStack injects the key into the default user (`ubuntu` for Ubuntu images, `cloud-user` for Rocky). See [Section 3.4](#34-advanced-inline-cloudinit) for Method 2 (inline cloud-init for custom image setup).

> **Namespace note:** The YAML uses `namespace: default`, which means all CAPI resources (CloudStackCluster, KubeadmControlPlane, MachineDeployment, etc.) are created in the `default` namespace of the **management cluster** (your Rancher cluster). The workload cluster itself is just VMs on CloudStack — it has no namespace. To apply to a different namespace without editing the file: `kubectl apply -f manifests/10-minimal-cluster.yaml -n my-clusters`

> **`syncWithACS: true`** — This setting (on the `CloudStackCluster` spec) tells CAPC to register the workload cluster as an `ExternalManaged` entry in CloudStack's **Compute → Kubernetes** UI. It works **only** when CAPC is deployed with the controller flag `--enable-cloudstack-cks-sync=true` (the default with plain `clusterctl`, but `false` in the Rancher Turtles manifests used by this guide). If that flag is left as `false`, the `CksClusterReconciler` is not registered, so `syncWithACS: true` does nothing and the cluster never appears in the CloudStack UI. See the note in [Section 1.3](#13-apply-the-capi-providers) for how to enable it.
>
> **Note:** The CloudStack Kubernetes UI offers extremely limited management features (just a cluster listing). For CAPC clusters managed by CAPI/Rancher Turtles, all real operations happen through `kubectl` anyway.

```bash
kubectl apply -f manifests/10-minimal-cluster.yaml
```

### 3.2 Create Namespace + CloudStack Credentials Secret

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

### 3.3 Apply and Monitor

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

> **⚠️ CNI Required:** After the cluster is created, you **must** install a CNI plugin before pods can communicate. See [Section 5.1](#51-calico-recommended) for installation instructions. Without a CNI, nodes will be `Ready` but pods will not be able to communicate.

### 3.4 Verification Checklist

Run these commands after deployment to verify the cluster is healthy end-to-end.

#### Management Plane — Rancher Turtles + CAPC

```bash
# Turtles controller running?
kubectl get pods -n cattle-capi-system | grep turtles

# CAPC provider deployed by Turtles?
kubectl get pods -n capc-system
# Expected: capc-controller-manager-xxx 1/1 Running

# CAPIProvider resources applied?
kubectl get capiproviders -A
# Expected: cloudstack provider with RECONCILING: false, READY: true
```

#### Cluster CRDs — All Resources

```bash
kubectl get clusters
kubectl get cloudstackclusters
kubectl get kubeadmcontrolplanes
kubectl get machines
kubectl get machinesets
kubectl get machinedeployments
```

**Expected state:**
- `Cluster` → phase: `Provisioned`
- `CloudStackCluster` → phase: `Ready`
- `KubeadmControlPlane` → replicas ready (e.g., 1/1 for minimal, 3/3 for HA)
- `MachineDeployment` → replicas ready (e.g., 2/2 for minimal, 3/3 for HA)
- All `Machines` → phase: `Running`, Ready: true

#### Workload Cluster — Kubernetes Layer

```bash
# Get kubeconfig from secret
kubectl get secret capc-cluster-1-kubeconfig -o jsonpath='{.data.value}' | base64 -d > kubeconfig

# Nodes ready?
kubectl --kubeconfig=kubeconfig get nodes -o wide
# Expected: all nodes show Ready status with internal IP

# Core system pods running?
kubectl --kubeconfig=kubeconfig get pods -n kube-system
# Expected: all pods in Running state (kube-apiserver, etcd, coredns, etc.)

# API server reachable?
kubectl --kubeconfig=kubeconfig cluster-info
```

#### Networking — CNI Layer

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
# All-in-one health check
echo "=== Turtles ===" && \
kubectl get pods -n cattle-capi-system | grep turtles && echo "" && \
echo "=== CAPC ===" && \
kubectl get pods -n capc-system && echo "" && \
echo "=== CAPI CRDs ===" && \
kubectl get clusters,cloudstackclusters,kubeadmcontrolplanes,machinesets,machinedeployments && echo "" && \
echo "=== Workload Nodes ===" && \
kubectl --kubeconfig=kubeconfig get nodes && echo "" && \
echo "=== System Pods ===" && \
kubectl --kubeconfig=kubeconfig get pods -n kube-system | grep -v Running || echo "All system pods running"
```

### 3.5 HA Cluster (3 Control + 3 Workers)

The full cluster YAML is available in the manifests folder: [11-ha-cluster.yaml](./manifests/11-ha-cluster.yaml)

### Required Parameters — Replace All Before Applying

Same parameters as the minimal cluster (see table above). The HA cluster uses:
- **Control plane:** `Large` service offering (recommended for HA)
- **Workers:** `Large` service offering


> **Namespace note:** Same as above — resources are created in the `default` namespace of the management cluster. To apply elsewhere: `kubectl apply -f manifests/11-ha-cluster.yaml -n my-clusters`

```bash
kubectl apply -f manifests/11-ha-cluster.yaml
```

### 3.6 Advanced — Inline Cloud-Init (Custom Image Setup)

For cases where you need more than just SSH key injection — custom users, package installation, kernel modules, systemd services, file provisioning — use **Method 2**: define everything inline in `KubeadmConfig`.

The full cluster YAML is available in the manifests folder: [12-custom-image-cluster.yaml](./manifests/12-custom-image-cluster.yaml)

This approach uses `KubeadmConfig.users` to create users and inject SSH keys via cloud-init, plus `preKubeadmCommands` and `postKubeadmCommands` for arbitrary setup. The `CloudStackMachine` resources omit the `sshKey` field — SSH is handled entirely by cloud-init.

**When to use Method 2:**
- Need to install packages (e.g., `nvidia-container-toolkit`, `docker`, `gpu-driver`)
- Need to load kernel modules or set sysctl parameters
- Need custom systemd services or file provisioning
- Need per-cluster SSH keys not registered in CloudStack
- Using a custom image where the default user differs from what CloudStack expects

**Key differences from Method 1:**

| | Method 1 (CloudStack SSH KeyPair) | Method 2 (Inline Cloud-Init) |
|---|---|---|
| SSH injection | CloudStack native (`deployVirtualMachine` API) | cloud-init via `KubeadmConfig` |
| User setup | CloudStack uses image default user | Explicitly defined in `KubeadmConfig.users` |
| Custom commands | No | `preKubeadmCommands` / `postKubeadmCommands` |
| Package install | No | Yes |
| File provisioning | No | Yes (via cloud-init `write_files`) |
| Portability | CloudStack-specific | Standard CAPI (works on any provider) |

> **⚠️ User name must match your image:** With Method 2, you explicitly define the user in `KubeadmConfig.users`. Make sure it matches the default user in your CAPI-compatible image:
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

SSH access is configured when you create the cluster (see [Section 3.1](#31-minimal-cluster-1-control--2-workers) for Method 1, or [Section 3.4](#34-advanced-inline-cloudinit) for Method 2).

**Method 1 (default)** — CloudStack SSH KeyPair: Register via `cmk register-sshkeypair`, then CloudStack injects the key into the default image user automatically.

**Method 2 (advanced)** — Inline cloud-init: Define the user and SSH key directly in `KubeadmConfig.users`. You must specify the correct user name for your image.

> **⚠️ User name depends on the image:**
> - **Ubuntu images** → `ubuntu`
> - **Rocky Linux images** → `cloud-user`
> - **Custom images** → whatever user is embedded in the image
>
> Check your image's user before applying. Using the wrong user means SSH will fail even with the correct key.

#### Configure Network Access for SSH

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

> **Note:** Method 1 and Method 2 are mutually exclusive — use one or the other, not both. Method 1 is recommended for production as it's managed in CloudStack and can be shared across clusters.

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

### 7.3 Worker-Only Cluster vs. CNI

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

### 8.1 Upgrade Kubernetes Version

```bash
# Update KubeadmControlPlane version
kubectl edit kubeadmcontrolplane capc-cluster-1-control-plane
# Change spec.version from "v1.32.0" to "v1.33.0"

# Update MachineDeployment version
kubectl edit machinedeployment capc-cluster-1-workers
# Change spec.template.spec.version
```

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
