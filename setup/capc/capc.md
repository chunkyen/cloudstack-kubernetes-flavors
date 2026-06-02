# CAPC Setup — Deploying Kubernetes on CloudStack with Cluster API

This guide walks through deploying a Kubernetes cluster on Apache CloudStack using the [Cluster API Provider for CloudStack (CAPC)](https://github.com/kubernetes-sigs/cluster-api-provider-cloudstack).

## Prerequisites

### CloudStack Resources

Ensure these exist in your CloudStack environment:

| Resource | Details |
|----------|---------|
| **Zone** | A zone with available compute resources |
| **Cluster/Pod** | Within the zone, with KVM/XenServer/VMware hypervisor |
| **Network** | An isolated or shared guest network (or CAPC will create one) |
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

> **Note:** `kind` is ephemeral — all state is lost when deleted. However, you can use it as a temporary bootstrap: provision your workload cluster, then transfer CAPI management to the target so it runs independently. See **[Move From Bootstrap](./move-from-bootstrap.md)** for details.

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

## Managing the Cluster

### Scaling Workers

```bash
# Edit MachineDeployment replicas
kubectl edit machinedeployment capc-cluster-md-0
# Change .spec.replicas, save — CAPC rolls out new nodes
```

### Upgrading Kubernetes Version

```bash
# Update both KubeadmControlPlane and MachineDeployment versions
clusterctl generate cluster capc-cluster \
  --kubernetes-version v1.33 \
  --control-plane-machine-count=3 \
  --worker-machine-count=2 \
  > capc-cluster-upgraded.yaml

kubectl apply -f capc-cluster-upgraded.yaml
```

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

## Next Steps

- Explore [Tilt-based development](https://cluster-api-cloudstack.sigs.k8s.io/development/tilt) for CAPC contribution
- Check out the [CKS setup guide](../cks/cks.md) for native CloudStack Kubernetes integration
- Compare all flavors in the [comparison analysis](../comparison/)
