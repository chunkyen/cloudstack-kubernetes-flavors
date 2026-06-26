# CAPC Setup — Deploying Kubernetes on CloudStack with Cluster API

This guide walks through deploying a Kubernetes cluster on Apache CloudStack using the [Cluster API Provider for CloudStack (CAPC)](https://github.com/kubernetes-sigs/cluster-api-provider-cloudstack).

> **Note:** CAPC is one provider within the broader [Cluster API](https://cluster-api.sigs.k8s.io/introduction) project — a declarative, Kubernetes-native approach to cluster lifecycle management. Cluster API supports multiple infrastructure providers (AWS, Azure, GCP, vSphere, etc.) with a shared control plane model. See the [CAPI Introduction](https://cluster-api.sigs.k8s.io/introduction) for an overview of the project and its architecture.

## Prerequisites

### CloudStack Resources

> **⚠️ Important: What CAPC Creates Automatically**
>
> CAPC does **not** require you to pre-create everything. It automatically provisions:
> - **Network** — If the specified network doesn't exist, CAPC creates a new isolated network
> - **Load Balancer** — For the Kubernetes API endpoint
> - **Firewall Rules** — For API server access
>
> **Not auto-created:** SSH port forwarding rules must be configured manually in the CloudStack UI (see [Section 4.2](../rancher-turtles-capc/cluster.md#42-ssh-to-nodes)).
>
> You only need to pre-create the items listed below. Everything else is handled by CAPC.

Ensure these exist in your CloudStack environment:

| Resource | Details |
|----------|---------|
| **Zone** | A zone with available compute resources |
| **Cluster/Pod** | Within the zone, with KVM/XenServer/VMware hypervisor |
| **Network** | Specify name/ID — CAPC creates a new isolated network if it doesn't exist |
| **Public IP** | An unused public IP for the cluster API endpoint load balancer |
| **SSH Key Pair** | Optional — for SSH access to VMs (used with `--flavor managed-ssh`) |
| **Compute Offerings** | At least two: control plane (>2GB RAM, 2vCPU) and worker nodes |
| **K8s-compatible Template** | A prebuilt image with container runtime + kubelet + kubeadm installed |

### Compute Offering Sizing

- **Control plane**: Minimum 2 vCPU, 2 GB RAM (recommend larger for production)
- **Worker nodes**: As needed — match your workload requirements

### K8s-Compatible Templates

CAPC requires pre-built images with Kubernetes prerequisites already installed:
- **Container runtime** (containerd or Docker)
- **kubelet**
- **kubeadm**
- **kubectl**
- **cloud-init** for node bootstrapping

Reference image definitions are maintained in the [kubernetes-sigs/image-builder](https://github.com/kubernetes-sigs/image-builder/tree/master/images/capi) project.

#### Prebuilt Images (Recommended)

Prebuilt images are available from [shapeblue packages](http://packages.shapeblue.com/cluster-api-provider-cloudstack/images/) for all supported hypervisors and Kubernetes versions:

**Current Releases:**

| Hypervisor | Format | K8s v1.28 | K8s v1.29 | K8s v1.30 | K8s v1.31 | K8s v1.32 |
|------------|--------|-----------|-----------|-----------|-----------|-----------|
| **KVM** | qcow2 (bz2) | Rocky 9, Ubuntu 22.04, Ubuntu 24.04 | Rocky 9, Ubuntu 22.04, Ubuntu 24.04 | Rocky 9, Ubuntu 22.04, Ubuntu 24.04 | Rocky 9, Ubuntu 22.04, Ubuntu 24.04 | Rocky 9, Ubuntu 22.04, Ubuntu 24.04 |
| **VMware** | ova | Rocky 9, Ubuntu 22.04, Ubuntu 24.04 | Rocky 9, Ubuntu 22.04, Ubuntu 24.04 | Rocky 9, Ubuntu 22.04, Ubuntu 24.04 | Rocky 9, Ubuntu 22.04, Ubuntu 24.04 | Rocky 9, Ubuntu 22.04, Ubuntu 24.04 |
| **XenServer** | vhd (bz2) | Rocky 9, Ubuntu 22.04, Ubuntu 24.04 | Rocky 9, Ubuntu 22.04, Ubuntu 24.04 | Rocky 9, Ubuntu 22.04, Ubuntu 24.04 | Rocky 9, Ubuntu 22.04, Ubuntu 24.04 | Rocky 9, Ubuntu 22.04, Ubuntu 24.04 |

Each image is available with an MD5 checksum file for verification.

#### Building Your Own Image

See [CAPC Custom Image Guide](./capc-custom-image.md) for full instructions.

### Local Tooling

Install these on your workstation:

```bash
# Docker (for local registry)
docker --version

# kind (optional, for management cluster)
kubectl version --client
clusterctl version   # requires v1.1.5+
```

## Step 1: Set Up Management Cluster

CAPC requires an existing Kubernetes cluster as the **management cluster** — this is where CAPC controllers run and manage workload clusters. You have two options:

### Option A: CKS on CloudStack (Recommended for Production)

Use a CKS-managed Kubernetes cluster deployed on your CloudStack infrastructure. This gives you a production-grade management plane with proper HA, persistent storage, and real networking.

See the [CKS setup guide](../cks/cks.md) for deployment instructions.

**Advantages:**
- Production-ready with HA control plane
- Runs on your CloudStack infrastructure (no external dependency)
- Persistent storage available for etcd
- Proper networking and security groups
- Can manage multiple workload clusters from one management cluster

### Option B: kind Cluster (Development / Testing Only)

For local development or proof-of-concept, create a `kind` cluster with a local Docker registry:

```bash
wget https://raw.githubusercontent.com/kubernetes-sigs/cluster-api/main/hack/kind-install-for-capd.sh
chmod +x ./kind-install-for-capd.sh
./kind-install-for-capd.sh
```

This creates a kind cluster and configures it to use a local Docker registry for image builds.

> **Warning:** `kind` is ephemeral — all state is lost when the cluster is deleted. Do not use this for production CAPC deployments.

### Option C: Self-Managed Clusters (Move From Bootstrap)

Use an ephemeral bootstrap cluster (e.g., `kind`) to provision your workload, then transfer full lifecycle management to the target cluster itself. After the move, the workload cluster runs its own CAPC controllers and manages CloudStack resources directly — no external management plane required.

**How it works:**
- Bootstrap cluster provisions VMs on CloudStack via CAPC controllers
- Workload cluster comes up with K8s but no CAPI controllers
- Install CAPC providers into the workload, then move all Cluster API objects from bootstrap to target
- The workload cluster becomes fully self-managing; delete the bootstrap with zero impact

**Use cases:**
- **Dev/POC workflows** — ephemeral kind for provisioning, keep self-managing clusters afterward
- **CI/CD pipelines** — temporary runners create clusters that outlive the pipeline
- **Disaster recovery** — no single point of failure if your management plane goes down
- **Multi-env provisioning** — one bootstrap creates dev/staging/prod, each manages itself independently

See **[Move From Bootstrap](./move-from-bootstrap.md)** for a complete walkthrough with architecture diagrams and step-by-step instructions.

## Step 2: Configure CloudStack Credentials

Create a `cloud-config` file in the CAPC repo root:

```ini
[Global]
api-url = https://your-cloudstack-host.com/client/api
api-key = your-api-key-here
secret-key = your-secret-key-here
```

Base64-encode it and export as an environment variable:

```bash
export CLOUDSTACK_B64ENCODED_SECRET=$(base64 -w0 -i cloud-config)
```

## Step 3: Build and Deploy CAPC Controller

### Option A: Use Prebuilt Image (Recommended)

Skip building — use the official image from the [GitHub releases](https://github.com/kubernetes-sigs/cluster-api-provider-cloudstack/releases).

```bash
# Set release directory for clusterctl overrides
export RELEASE_DIR=${HOME}/.cluster-api/overrides/infrastructure-cloudstack/v0.6.0/
mkdir -p "$RELEASE_DIR"
```

### Option B: Build from Source

```bash
# Set image registry (local or remote)
export IMG=localhost:5000/cluster-api-provider-capc

# Build and push the controller image
make docker-build
make docker-push

# Generate manifests to release directory
make build   # outputs infrastructure-components.yaml + metadata.yaml to ./out/
```

### Deploy CAPC to Management Cluster

Create a `cloudstack.yaml` provider config:

```yaml
cat > ~/.cluster-api/cloudstack.yaml <<EOF
providers:
- name: "cloudstack"
  type: "InfrastructureProvider"
  url: ${RELEASE_DIR}/infrastructure-components.yaml
EOF
```

Initialize the management cluster with CAPC:

```bash
clusterctl init --infrastructure cloudstack --config ~/.cluster-api/cloudstack.yaml
```

Verify CAPC is running:

```bash
kubectl get pods -n capc-system
# Expected: capc-controller-manager-xxx 1/1 Running
```

## Step 4: Generate Cluster Spec

Set environment variables for your CloudStack resources:

```bash
# CloudStack zone
export CLOUDSTACK_ZONE_NAME=zone1

# Network (if it doesn't exist, CAPC creates an isolated network)
export CLOUDSTACK_NETWORK_NAME=GuestNet1

# Public IP for cluster API endpoint (must be available in the network)
export CLUSTER_ENDPOINT_IP=192.168.1.161
export CLUSTER_ENDPOINT_PORT=6443

# Compute offerings (must exist in CloudStack)
export CLOUDSTACK_CONTROL_PLANE_MACHINE_OFFERING="Large Instance"
export CLOUDSTACK_WORKER_MACHINE_OFFERING="Small Instance"

# K8s-compatible template name (registered in CloudStack)
export CLOUDSTACK_TEMPLATE_NAME=kube-v1.32/ubuntu-2404

# SSH key pair (optional — use with --flavor managed-ssh)
export CLOUDSTACK_SSH_KEY_NAME=CAPCKeyPair
```

### Public IP — Critical Requirement

The `CLUSTER_ENDPOINT_IP` is the **most common cause of cluster creation failure**. Here's what you need to know:

**Why it's required:** The Kubernetes API server needs a stable, externally accessible endpoint. CAPC uses CloudStack's built-in load balancer to expose the API server on this IP. Without a reserved public IP, the control plane cannot be reached from outside the management cluster.

**CAPC does NOT auto-allocate the IP.** You must provide an IP that is already in the `Free` or `Reserved` state in CloudStack's public IP pool.

**How to find available IPs:**

```bash
# List all public IPs in a zone
cmk list publicipaddresses listall=true zoneid=<zone-id> forvirtualnetwork=true

# Filter for free (unallocated) IPs only
cmk list publicipaddresses listall=true zoneid=<zone-id> forvirtualnetwork=true allocatedonly=false | jq '.publicipaddress[] | select(.state == "Free" or .state == "Reserved") | .ipaddress'
```

**What happens if you use an allocated IP:** CAPC will fail to create the cluster. The CloudStackCluster will stay in `Provisioning` state and you'll see errors in the CAPC controller logs:

```bash
kubectl logs -n capc-system -l app=cloudstack -f | grep -i error
```

**Where it's used:** The IP appears in two places in the generated cluster spec:
1. `CloudStackCluster.spec.controlPlaneEndpoint.host` — the load balancer endpoint
2. `KubeadmControlPlane.spec.kubeadmConfigSpec.clusterConfiguration.apiServer.certSANs` — the API server certificate

Both must use the same IP.

**Shared networks:** If using a shared or routed network (not isolated), you must use [kube-vip](https://kube-vip.io/) as the VIP instead of CloudStack's load balancer. Generate with the `with-kube-vip` flavor:

```bash
clusterctl generate cluster capc-cluster \
  --flavor with-kube-vip \
  --kubernetes-version v1.32 \
  --control-plane-machine-count=3 \
  --worker-machine-count=2 \
  > capc-cluster-spec.yaml
```

Generate the cluster spec YAML:

```bash
clusterctl generate cluster capc-cluster \
  --kubernetes-version v1.32 \
  --control-plane-machine-count=3 \
  --worker-machine-count=2 \
  > capc-cluster-spec.yaml
```

> **Note:** Use an odd number (≥3) of control plane nodes for HA. Single-node control planes are supported but not recommended for production.

## Step 5: Deploy the Cluster

Apply the generated spec to your management cluster:

```bash
kubectl apply -f capc-cluster-spec.yaml
```

Monitor progress:

```bash
clusterctl describe cluster capc-cluster
```

Watch for these stages:
1. `CloudStackCluster` → provisioning networking and load balancer
2. `KubeadmControlPlane` → creating control plane VMs
3. Control plane nodes reach `Ready` status
4. `MachineDeployment` → creating worker VMs
5. Workers join the cluster via kubeadm

> **Note:** Worker `MachineDeployment` won't show fully ready until CNI is installed (next step).

## Step 6: Install CNI

CAPC does not install a CNI plugin — you must do this manually. Choose one:

> **💡 Automate CNI installation:** Instead of manual installation, see the [CNI Automation Options](./cni-automation-options.md) guide for three approaches to automate CNI as part of the cluster deployment workflow — including the CAPI-native `ClusterResourceSet` approach that integrates CNI installation into Step 5.

### Calico (Recommended)

```bash
KUBECONFIG=$(clusterctl get kubeconfig capc-cluster) kubectl apply -f \
  https://raw.githubusercontent.com/projectcalico/calico/master/manifests/calico.yaml
```

### Cilium

Cilium provides eBPF-based networking, built-in Hubble observability, and native Kubernetes NetworkPolicy support:

```bash
# Install Cilium via Helm (recommended)
kubectl create namespace cilium
helm install cilium cilium/cilium --namespace cilium \
  --set ipam.mode=kubernetes \
  --set operator.replicas=1
```

Or install via manifest:

```bash
KUBECONFIG=$(clusterctl get kubeconfig capc-cluster) kubectl apply -f \
  https://raw.githubusercontent.com/cilium/cilium/main/install/kubernetes/quickstep.yaml
```

> **Note:** Cilium requires kernel 4.9+ with eBPF support. On Ubuntu 22.04+/Rocky 9+, this is available by default.

### Weave Net (Alternative)

```bash
KUBECONFIG=$(clusterctl get kubeconfig capc-cluster) kubectl apply -f \
  https://raw.githubusercontent.com/weaveworks/weave/master/prog/weave-kube/weave-daemonset-k8s-1.11.yaml
```

### CNI Comparison for CAPC

| Feature | Calico | Cilium | Weave Net |
|---------|--------|--------|-----------|
| **Data plane** | iptables/IPIP/VXLAN | eBPF | VXLAN/overlay |
| **NetworkPolicy** | Yes (Calico-native) | Yes (native K8s + Calico-compatible) | Basic |
| **Observability** | Tigera Enterprise (paid) | Hubble (free, built-in) | Limited |
| **Encryption** | BGP/IPsec (Tigera) | Native eBPF encryption | Optional |
| **Service mesh** | No (integrates with Istio/Linkerd) | Native (Helm chart includes Envoy sidecar option) | No |
| **Resource overhead** | Low | Moderate (eBPF maps) | Moderate |
| **Best for** | General-purpose, wide compatibility | Security-focused, observability needs | Simple setups |

> **Recommendation:** Use Calico for simplicity and broad compatibility. Choose Cilium if you need eBPF features, Hubble observability, or a built-in service mesh path.

## Step 7: Verify the Cluster

Save the kubeconfig:

```bash
clusterctl get kubeconfig capc-cluster > capc-cluster.kubeconfig
```

Check nodes:

```bash
KUBECONFIG=capc-cluster.kubeconfig kubectl get nodes
# Expected output:
# NAME                                    STATUS   ROLES           AGE   VERSION
# capc-cluster-control-plane-xxxxx        Ready    control-plane   5m    v1.32.x
# capc-cluster-md-0-xxxxx-x              Ready    <none>          3m    v1.32.x
```

Run a test pod:

```bash
KUBECONFIG=capc-cluster.kubeconfig kubectl run test-thing \
  --image=rockylinux/rockylinux:8 --restart=Never \
  -- /bin/bash -c 'echo Hello, World!'

KUBECONFIG=capc-cluster.kubeconfig kubectl logs test-thing
# Expected: "Hello, World!"
```

## Step 8: Install Cross-Cutting Components

CAPC clusters don't auto-deploy the CloudStack Kubernetes Provider (CCM) or CSI driver. Install them manually:

### CloudStack Kubernetes Provider (CCM)

```bash
# Deploy CCM for LoadBalancer services and node labels
KUBECONFIG=capc-cluster.kubeconfig kubectl apply -f \
  https://raw.githubusercontent.com/kubernetes-sigs/cluster-api-provider-cloudstack/main/config/components/capc-ccm.yaml
```

### CloudStack CSI Driver

```bash
# Deploy CSI driver for persistent storage
KUBECONFIG=capc-cluster.kubeconfig kubectl apply -f \
  <csi-driver-deployment-manifest>
```

See [CloudStack Kubernetes Provider](../architecture/cloudstack-kubernetes-provider.md) and [CloudStack CSI Driver](../setup/cloudstack-csi-driver.md) for detailed deployment instructions.

## Verification Checklist

After deploying a CAPC cluster, run these commands to verify each layer is healthy. Work from top (management plane) down (workload cluster).

### Management Plane — CAPC Controllers

```bash
# CAPC controller running?
kubectl get pods -n capc-system
# Expected: capc-controller-manager-xxx 1/1 Running

# CAPC CRDs registered?
kubectl api-resources | grep cloudstack
# Expected: cloudstackclusters, cloudstackmachineconfigs, cloudstackmachinetemplates, etc.
```

### Cluster Resources — All CAPI CRDs

```bash
# List all cluster resources
kubectl get clusters -A
kubectl get cloudstackclusters -A
kubectl get kubeadmcontrolplanes -A
kubectl get machines -A
kubectl get machinesets -A
kubectl get machinedeployments -A
```

**Expected state:**
- `Cluster` → phase: `Provisioned`
- `CloudStackCluster` → phase: `Ready`
- `KubeadmControlPlane` → replicas ready (e.g., 3/3)
- `MachineDeployment` → replicas ready (e.g., 2/2)
- All `Machines` → phase: `Running`, Ready: true

### CloudStack VMs — Infrastructure Layer

```bash
# Verify VMs exist in CloudStack via cmk
cmk list virtualmachines templatefilter=explicittags filter=customizedid | grep kube

# Check compute offerings used
cmk list serviceofferings listall=true
```

### Workload Cluster — Kubernetes Layer

```bash
# Get kubeconfig
clusterctl get kubeconfig capc-cluster > capc-cluster.kubeconfig

# Nodes ready?
kubectl --kubeconfig=capc-cluster.kubeconfig get nodes -o wide
# Expected: all nodes show Ready status with internal IP

# Core system pods running?
kubectl --kubeconfig=capc-cluster.kubeconfig get pods -n kube-system
# Expected: all pods in Running state (kube-apiserver, etcd, coredns, etc.)

# API server reachable?
kubectl --kubeconfig=capc-cluster.kubeconfig cluster-info

# Cluster version?
kubectl --kubeconfig=capc-cluster.kubeconfig version --short
```

### Networking — CNI Layer

```bash
# CNI pods running?
kubectl --kubeconfig=capc-cluster.kubeconfig get pods -A | grep -E 'calico|cilium|flannel'

# Node networking functional?
kubectl --kubeconfig=capc-cluster.kubeconfig get nodes -o wide
# Expected: Ready status, network plugin column populated

# Test pod-to-pod communication
kubectl --kubeconfig=capc-cluster.kubeconfig apply -f - <<EOF
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

kubectl --kubeconfig=capc-cluster.kubeconfig exec ping-test-1 -- ping -c 3 <ping-test-2-ip>
# Expected: 3 packets transmitted, 3 received, 0% packet loss
```

### Storage — CSI Layer

```bash
# CSI driver pods running?
kubectl --kubeconfig=capc-cluster.kubeconfig get pods -A | grep cloudstack-csi

# StorageClass available?
kubectl --kubeconfig=capc-cluster.kubeconfig get storageclass
# Expected: cloudstack-ssd (or your configured name)

# Create and verify a test PVC
kubectl --kubeconfig=capc-cluster.kubeconfig apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes:
  - ReadWriteOnce
  storageClassName: cloudstack-ssd
  resources:
    requests:
      storage: 5Gi
EOF

kubectl --kubeconfig=capc-cluster.kubeconfig get pvc test-pvc
# Expected: STATUS: Bound
```

### Quick One-Liner Summary

```bash
# All-in-one health check (management plane + workload)
echo "=== Management Plane ===" && \
kubectl get pods -n capc-system && echo "" && \
echo "=== Cluster CRDs ===" && \
kubectl get clusters,cloudstackclusters,kubeadmcontrolplanes,machinesets,machinedeployments -A && echo "" && \
echo "=== Workload Nodes ===" && \
kubectl --kubeconfig=$(clusterctl get kubeconfig capc-cluster) get nodes && echo "" && \
echo "=== System Pods ===" && \
kubectl --kubeconfig=$(clusterctl get kubeconfig capc-cluster) get pods -n kube-system | grep -v Running || echo "All system pods running"
```

## Troubleshooting

### VM Deleted from CloudStack — Node Not Recreated

If you delete a VM directly from CloudStack (UI, cmk, API), CAPC **will not automatically recreate it**. Here's why and how to fix it:

**Why it doesn't work:** When the VM is deleted, the `CloudStackMachine` CR still exists with its `InstanceID` set. CAPC's controller looks up that InstanceID in CloudStack, gets "not found," and **doesn't automatically create a replacement** — it just requeues and waits. The CAPI MachineDeployment sees its replica count is met (the Machine CR still exists), so it doesn't generate a new one either.

**Fix — delete the stale CAPI objects:**

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

### Scaling Workers

```bash
# Edit MachineDeployment replicas
kubectl edit machinedeployment capc-cluster-md-0
# Change .spec.replicas, save — CAPC rolls out new nodes
```

### Scaling Control Plane

Control plane scaling uses the `KubeadmControlPlane` resource — a separate CR from worker `MachineDeployment`:

```bash
# Find your KubeadmControlPlane
kubectl get kubeadmcontrolplane -A

# Scale up (or down) by changing replicas
kubectl edit kubeadmcontrolplane capc-cluster-control-plane
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

### Upgrading Kubernetes Version

> **Full stack upgrade guide:** For a complete end-to-end upgrade covering CAPC controller, K8s version, CNI, CSI, and CCM, see the [CAPC Upgrade Guide](./capc-upgrade.md).

> **Note:** The CAPC controller upgrade (covered in the full guide) applies **only to the management cluster**. The workload cluster has no CAPC controllers — it's just a plain Kubernetes cluster managed from the outside.

Upgrading a CAPC cluster requires a new image with the target K8s version baked in — kubelet, kubeadm, and containerd are installed at image build time, not managed by kubeadm upgrades.

#### Step 1: Build or Obtain New Image

Build a custom image for the target Kubernetes version (see [CAPC Custom Image Guide](./capc-custom-image.md)), or download a prebuilt one matching your hypervisor. Upload it to CloudStack as a template using the GUI, `cmk` CLI, or API.

#### Step 2: Create New CloudStackMachineTemplates

Copy the existing templates and update their `image` references:

```bash
# Get current templates
kubectl get cloudstackmachinetemplate -o yaml > machine-templates.yaml

# Edit: change image to new template name, increment version
# (e.g., kube-v1.32/ubuntu-2404 → kube-v1.33/ubuntu-2404)
```

Apply the updated templates:

```bash
kubectl apply -f machine-templates.yaml
```

#### Step 3: Update KubeadmControlPlane and MachineDeployment

Point them to the new templates and update the version field:

```yaml
# KubeadmControlPlane.spec.machineTemplate.infrastructureRef.name → new template name
# KubeadmControlPlane.spec.version → v1.33
---
# MachineDeployment.spec.template.spec.infrastructureRef.name → new worker template name
# MachineDeployment.spec.template.spec.version → v1.33
```

```bash
kubectl edit kubeadmcontrolplane capc-cluster-control-plane
kubectl edit machinedeployment capc-cluster-md-0
```

CAPC performs a rolling update — old VMs are terminated and new ones provisioned from the updated image.

> **Note:** If using prebuilt images, you can skip Step 1 entirely. See [Prebuilt Images](#prebuilt-images) for available versions.

### Deleting the Cluster

```bash
kubectl delete cluster capc-cluster
# This cascades: deletes MachineDeployments → Machines → CloudStack VMs
```

## Troubleshooting

| Issue | Check |
|-------|-------|
| Control plane fails to create | Verify public IP is available in the network; check compute offering has enough RAM (≥2GB) |
| Worker nodes stuck at `Provisioning` | Check CloudStack template exists and is compatible; verify network/DHCP settings |
| Nodes not reaching `Ready` | CNI may not be installed yet; check `kubectl get pods -A` on the workload cluster |
| CAPC controller crashes | Check logs: `kubectl logs -n capc-system deploy/capc-controller-manager` |
| CloudStack API errors | Verify credentials in `cloud-config`; test connectivity to CloudStack API endpoint |
| SSH access to nodes | See [SSH Access to Nodes](#ssh-access-to-nodes) below |

### SSH Access to Nodes

To SSH into CAPC-managed nodes, configure network access in CloudStack and use the appropriate credentials:

**Prerequisites:**
- An SSH keypair matching one of the node's `authorized_keys` (pass via `--flavor managed-ssh` or `CLOUDSTACK_SSH_KEY_NAME`)
- Isolated network (VPC also works with additional routing configuration)

**Step 1: Configure Network Access in CloudStack**

Using the **CloudStack UI** (recommended — CLI syntax varies by version):

1. Navigate to **Networking → Public IPs** and select the public IP assigned to your cluster's control plane endpoint
2. Click **Add Firewall Rule**:   - Protocol: `TCP`
   - Start Port: `22`
   - End Port: `22`
3. Click **Add Port Forwarding Rule** on the firewall rule you just created:
   - Private IP: `<control-plane-vm-private-ip>`
   - Private Port: `22`
   - Public Port: `22`

Or using the **`cmk` CLI** (verified against CloudStack API cache):

```bash
# Add a firewall rule allowing SSH (port 22)
cmk create firewallrule \
  --ipaddressid <public-ip-id> \
  --protocol TCP \
  --startport 22 \
  --endport 22

# Add port forwarding to forward traffic to the control plane VM
cmk create portforwardingrule \
  --ipaddressid <public-ip-id> \
  --virtualmachineid <control-plane-vm-id> \
  --protocol TCP \
  --privateport 22 \
  --publicport 22
```

> **Note:** For worker nodes, repeat steps 2–3 for each VM. The control plane endpoint IP forwards to one of the control plane nodes (round-robin via CloudStack LB).

**Step 2: SSH into the Node**

```bash
# Ubuntu images use 'ubuntu' as username
ssh ubuntu@<public-ip> -i path/to/private/key

# Rocky Linux images use 'cloud-user' as username
ssh cloud-user@<public-ip> -i path/to/private/key
```

> **Note:** For worker nodes, you'll need to create separate port forwarding rules for each VM. The control plane endpoint IP forwards to one of the control plane nodes (round-robin via CloudStack LB).

## Next Steps

- See the [CAPC Upgrade Guide](./capc-upgrade.md) for end-to-end upgrade procedures
- Explore [Tilt-based development](https://cluster-api-cloudstack.sigs.k8s.io/development/tilt) for CAPC contribution
- Check out the [CKS setup guide](../cks/cks.md) for native CloudStack Kubernetes integration
- Compare all flavors in the [comparison analysis](../comparison/)
