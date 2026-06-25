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
| `my-ssh-key` | CloudStack SSH keypair name | `cmk register-sshkeypair --name=my-ssh-key --publickey="$(cat ~/.ssh/id_ed25519.pub)"` |

> **SSH Key Method:** This example uses **Method 1** (CloudStack SSH KeyPair) — the recommended approach. Register your key via `cmk register-sshkeypair`, then reference it via the `sshKey` field on `CloudStackMachine` resources. CloudStack injects the key into the default user (`ubuntu` for Ubuntu images, `cloud-user` for Rocky). See [Section 3.4](#34-advanced-inline-cloudinit) for Method 2 (inline cloud-init for custom image setup).

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

### 3.4 Advanced — Inline Cloud-Init (Custom Image Setup)

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
