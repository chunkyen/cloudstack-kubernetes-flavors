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
> - **Port Forwarding** — For SSH access to control plane nodes
>
> You only need to pre-create: **CAPI-compatible template**, **service offerings**, **disk offerings**, and a **reserved public IP**.

## 2. Prepare CAPI-Compatible Images

CAPC requires pre-built images with container runtime + kubelet + kubeadm already installed. These are registered as templates in CloudStack.

### 2.1 Pre-built Images

Pre-built CAPI-compatible images are available for multiple hypervisors and Kubernetes versions:

| Hypervisor | Format | Ubuntu 24.04 | Rocky Linux 9 |
|------------|--------|--------------|---------------|
| KVM | qcow2 | [v1.32.3](http://packages.shapeblue.com/cluster-api-provider-cloudstack/images/kvm/ubuntu-2404-kube-v1.32.3-kvm.qcow2.bz2) | [v1.32.3](http://packages.shapeblue.com/cluster-api-provider-cloudstack/images/kvm/rockylinux-9-kube-v1.32.3-kvm.qcow2.bz2) |
| VMware | ova | [v1.32.3](http://packages.shapeblue.com/cluster-api-provider-cloudstack/images/vmware/ubuntu-2404-kube-v1.32.3-vmware.ova) | [v1.32.3](http://packages.shapeblue.com/cluster-api-provider-cloudstack/images/vmware/rockylinux-9-kube-v1.32.3-vmware.ova) |
| XenServer | vhd | [v1.32.3](http://packages.shapeblue.com/cluster-api-provider-cloudstack/images/xen/ubuntu-2404-kube-v1.32.3-xen.vhd.bz2) | [v1.32.3](http://packages.shapeblue.com/cluster-api-provider-cloudstack/images/xen/rockylinux-9-kube-v1.32.3-xen.vhd.bz2) |

Full image list: [CAPC Images](http://packages.shapeblue.com/cluster-api-provider-cloudstack/images/)

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
| `Large` (diskOffering) | Disk offering name | `cmk list diskofferings listall=true` |
| `<YOUR_SSH_PUBLIC_KEY>` | SSH public key for node access | **Method 1:** Register in CloudStack (`cmk register-sshkeypair`), reference via `sshKey` in CloudStackMachine. **Method 2:** Paste full key — embedded directly into KubeadmConfig |

> **Namespace note:** The YAML uses `namespace: default`, which means all CAPI resources (CloudStackCluster, KubeadmControlPlane, MachineDeployment, etc.) are created in the `default` namespace of the **management cluster** (your Rancher cluster). The workload cluster itself is just VMs on CloudStack — it has no namespace. To apply to a different namespace without editing the file: `kubectl apply -f manifests/10-minimal-cluster.yaml -n my-clusters`

```bash
kubectl apply -f manifests/10-minimal-cluster.yaml
```

### 3.2 Apply and Monitor

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

> **⚠️ CNI Required:** After the cluster is created, you **must** install a CNI plugin before pods can communicate. See [Section 6.2](#62-install-cni) for installation instructions. Without a CNI, nodes will be `Ready` but pods will not be able to communicate.

### 3.3 HA Cluster (3 Control + 3 Workers)

The full cluster YAML is available in the manifests folder: [11-ha-cluster.yaml](./manifests/11-ha-cluster.yaml)

### Required Parameters — Replace All Before Applying

Same parameters as the minimal cluster (see table above). The HA cluster uses:
- **Control plane:** `Large` service offering (recommended for HA)
- **Workers:** `Large` service offering
- **Disk:** `Large` disk offering

> **Namespace note:** Same as above — resources are created in the `default` namespace of the management cluster. To apply elsewhere: `kubectl apply -f manifests/11-ha-cluster.yaml -n my-clusters`

```bash
kubectl apply -f manifests/11-ha-cluster.yaml
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

Two methods for SSH access — both are configured in the cluster YAML before applying.

#### Method 1: CloudStack SSH KeyPair (Recommended)

Register your public key in CloudStack, then reference it via `sshKey` in `CloudStackMachine` resources:

```bash
# Register your SSH public key in CloudStack
cmk register-sshkeypair --name=mykey --publickey="$(cat ~/.ssh/id_ed25519.pub)"
```

Then set `sshKey: "mykey"` in both `CloudStackMachine` resources in the YAML.

To list existing keypairs: `cmk list sshkeypairs listall=true`

#### Method 2: Inline SSH Key (No CloudStack Registration)

Paste your full public key directly into the `KubeadmConfig` `users` section in the YAML:

```yaml
apiVersion: bootstrap.cluster.x-k8s.io/v1beta1
kind: KubeadmConfig
metadata:
  name: capc-cluster-1-workers
  namespace: default
spec:
  users:
    - name: cloud
      sshAuthorizedKeys:
        - "ssh-ed25519 AAAA..."  # Your full public key
      sudo: ALL=(ALL) NOPASSWD:ALL
```

#### Using SSH After Cluster Creation

After the cluster is created and CNI is installed:

```bash
ssh -i <private-key> cloud@<node-ip>
```

The `cloud` user is pre-created in CAPI-compatible images with passwordless sudo.

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

```bash
# Edit KubeadmControlPlane replicas
kubectl edit kubeadmcontrolplane capc-cluster-1-control-plane
# Change spec.replicas from 1 to 3
```

## 7. Upgrade the Cluster

### 7.1 Upgrade Kubernetes Version

```bash
# Update KubeadmControlPlane version
kubectl edit kubeadmcontrolplane capc-cluster-1-control-plane
# Change spec.version from "v1.32.0" to "v1.33.0"

# Update MachineDeployment version
kubectl edit machinedeployment capc-cluster-1-workers
# Change spec.template.spec.version
```

## 8. Troubleshooting

### 8.1 Cluster Stuck in "Provisioning"

```bash
# Check CloudStackCluster status
kubectl describe cloudstackcluster capc-cluster-1

# Check CloudStackMachine events
kubectl describe cloudstackmachine capc-cluster-1-workers-xxxxx

# Check CAPC controller logs
kubectl logs -n capc-system -l app=cloudstack -f
```

### 8.2 Nodes Not Joining

```bash
# Check kubeadm logs on nodes
ssh -i <key> -p 2222 cloud@<VR_PUBLIC_IP> "sudo journalctl -u kubelet -f"

# Check bootstrap token
kubectl get secret | grep bootstrap

# Check API server connectivity
kubectl --kubeconfig=kubeconfig get nodes
```

### 8.3 CloudStack VM Creation Failed

```bash
# Check CAPC logs for CloudStack API errors
kubectl logs -n capc-system -l app=cloudstack | grep -i error

# Verify CloudStack resources
# In CloudStack UI: Compute → VMs → check if VMs were created

# Verify template exists and is active
cmk list templates filter=featured id=<template-id>

# Verify service offering exists
cmk list serviceofferings id=<offering-id>
```

## 9. Next Steps

- [Fleet GitOps](./fleet.md) — Automate cluster management with Fleet
- [CAPC Upgrade Guide](../capc/capc-upgrade.md) — Upgrading CAPC and clusters
