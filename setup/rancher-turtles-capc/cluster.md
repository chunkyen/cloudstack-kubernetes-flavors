# Create Clusters via CAPI + CAPC

This guide covers provisioning Kubernetes clusters on CloudStack using CAPI CRDs managed by Rancher Turtles + CAPC.

## 1. Prerequisites

- Rancher + Turtles + CAPC deployed (see [Rancher](./rancher.md) and [Turtles](./turtles.md))
- CAPI-compatible images registered in CloudStack as templates
- `kubectl` configured with the management cluster

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

Download and register the image as a CloudStack template:

```bash
# Download the image
curl -L http://packages.shapeblue.com/cluster-api-provider-cloudstack/images/kvm/ubuntu-2404-kube-v1.32.3-kvm.qcow2.bz2 -o ubuntu-2404-kube-v1.32.3-kvm.qcow2.bz2

# Register as a template in CloudStack
cmk register-template \
  url=http://<your-server>/ubuntu-2404-kube-v1.32.3-kvm.qcow2.bz2 \
  name=capc-ubuntu-2404-kube-v1.32.3 \
  ispublic=true \
  hypervisor=KVM \
  ostypeid=<os-type-id>
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

```yaml
# cluster-minimal.yaml
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: capc-cluster-1
  namespace: default
spec:
  clusterNetwork:
    pods:
      cidrBlocks: ["10.244.0.0/16"]
    serviceDomain: cluster.local
  controlPlaneRef:
    apiVersion: controlplane.cluster.x-k8s.io/v1beta1
    kind: KubeadmControlPlane
    name: capc-cluster-1-control-plane
  infrastructureRef:
    apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
    kind: CloudStackCluster
    name: capc-cluster-1
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: CloudStackCluster
metadata:
  name: capc-cluster-1
  namespace: default
spec:
  controlPlaneEndpoint:
    host: "<reserved-public-ip>"  # Reserved public IP from CloudStack network
    port: 6443
  network:
    name: "<network-name-or-id>"
  zone:
    name: "<zone-name-or-id>"
---
apiVersion: controlplane.cluster.x-k8s.io/v1beta1
kind: KubeadmControlPlane
metadata:
  name: capc-cluster-1-control-plane
  namespace: default
spec:
  replicas: 1
  version: "v1.32.0"
  machineTemplate:
    infrastructureRef:
      apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
      kind: CloudStackMachine
      name: capc-cluster-1-control-plane
  kubeadmConfigSpec:
    clusterConfiguration:
      apiServer:
        certSANs:
          - "<reserved-public-ip>"  # Must match controlPlaneEndpoint.host
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: CloudStackMachine
metadata:
  name: capc-cluster-1-control-plane
  namespace: default
spec:
  serviceOffering: "Medium"
  template: "capc-ubuntu-2404-kube-v1.32.3"
  diskOffering: "Large"
---
apiVersion: cluster.x-k8s.io/v1beta1
kind: MachineDeployment
metadata:
  name: capc-cluster-1-workers
  namespace: default
spec:
  replicas: 2
  clusterName: capc-cluster-1
  selector:
    matchLabels:
      cluster.x-k8s.io/cluster-name: capc-cluster-1
  template:
    spec:
      version: "v1.32.0"
      bootstrap:
        configRef:
          apiVersion: bootstrap.cluster.x-k8s.io/v1beta1
          kind: KubeadmConfig
          name: capc-cluster-1-workers
      infrastructureRef:
        apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
        kind: CloudStackMachine
        name: capc-cluster-1-workers
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: CloudStackMachine
metadata:
  name: capc-cluster-1-workers
  namespace: default
spec:
  serviceOffering: "Medium"
  template: "capc-ubuntu-2404-kube-v1.32.3"
  diskOffering: "Large"
---
apiVersion: bootstrap.cluster.x-k8s.io/v1beta1
kind: KubeadmConfig
metadata:
  name: capc-cluster-1-workers
  namespace: default
spec: {}
```

### 3.2 Apply and Monitor

```bash
kubectl apply -f cluster-minimal.yaml

# Watch cluster creation
kubectl get clusters
kubectl get cloudstackclusters
kubectl get cloudstackmachines
kubectl get machinesets
kubectl get machinedeployments

# Check events
kubectl get events --sort-by='.lastTimestamp' -n default
```

### 3.3 HA Cluster (3 Control + 3 Workers)

```yaml
# cluster-ha.yaml
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: capc-cluster-ha
  namespace: default
spec:
  clusterNetwork:
    pods:
      cidrBlocks: ["10.244.0.0/16"]
    serviceDomain: cluster.local
  controlPlaneRef:
    apiVersion: controlplane.cluster.x-k8s.io/v1beta1
    kind: KubeadmControlPlane
    name: capc-cluster-ha-control-plane
  infrastructureRef:
    apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
    kind: CloudStackCluster
    name: capc-cluster-ha
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: CloudStackCluster
metadata:
  name: capc-cluster-ha
  namespace: default
spec:
  controlPlaneEndpoint:
    host: "<reserved-public-ip>"  # Reserved public IP from CloudStack network
    port: 6443
  network:
    name: "<network-name-or-id>"
  zone:
    name: "<zone-name-or-id>"
---
apiVersion: controlplane.cluster.x-k8s.io/v1beta1
kind: KubeadmControlPlane
metadata:
  name: capc-cluster-ha-control-plane
  namespace: default
spec:
  replicas: 3
  version: "v1.32.0"
  machineTemplate:
    infrastructureRef:
      apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
      kind: CloudStackMachine
      name: capc-cluster-ha-control-plane
  kubeadmConfigSpec:
    clusterConfiguration:
      apiServer:
        certSANs:
          - "<reserved-public-ip>"  # Must match controlPlaneEndpoint.host
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: CloudStackMachine
metadata:
  name: capc-cluster-ha-control-plane
  namespace: default
spec:
  serviceOffering: "Large"
  template: "capc-ubuntu-2404-kube-v1.32.3"
  diskOffering: "Large"
---
apiVersion: cluster.x-k8s.io/v1beta1
kind: MachineDeployment
metadata:
  name: capc-cluster-ha-workers
  namespace: default
spec:
  replicas: 3
  clusterName: capc-cluster-ha
  selector:
    matchLabels:
      cluster.x-k8s.io/cluster-name: capc-cluster-ha
  template:
    spec:
      version: "v1.32.0"
      bootstrap:
        configRef:
          apiVersion: bootstrap.cluster.x-k8s.io/v1beta1
          kind: KubeadmConfig
          name: capc-cluster-ha-workers
      infrastructureRef:
        apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
        kind: CloudStackMachine
        name: capc-cluster-ha-workers
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: CloudStackMachine
metadata:
  name: capc-cluster-ha-workers
  namespace: default
spec:
  serviceOffering: "Large"
  template: "capc-ubuntu-2404-kube-v1.32.3"
  diskOffering: "Large"
---
apiVersion: bootstrap.cluster.x-k8s.io/v1beta1
kind: KubeadmConfig
metadata:
  name: capc-cluster-ha-workers
  namespace: default
spec: {}
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

```bash
# Control node (port 2222 + node_index)
ssh -i <key> -p 2222 cloud@<VR_PUBLIC_IP>

# Worker node
ssh -i <key> -p 2223 cloud@<VR_PUBLIC_IP>
```

## 5. Scale the Cluster

### 5.1 Scale Workers

```bash
# Via kubectl
kubectl scale machinedeployment capc-cluster-1-workers --replicas=5

# Or edit the MachineDeployment
kubectl edit machinedeployment capc-cluster-1-workers
```

### 5.2 Scale Control Plane

```bash
# Edit KubeadmControlPlane replicas
kubectl edit kubeadmcontrolplane capc-cluster-1-control-plane
# Change spec.replicas from 1 to 3
```

## 6. Upgrade the Cluster

### 6.1 Upgrade Kubernetes Version

```bash
# Update KubeadmControlPlane version
kubectl edit kubeadmcontrolplane capc-cluster-1-control-plane
# Change spec.version from "v1.32.0" to "v1.33.0"

# Update MachineDeployment version
kubectl edit machinedeployment capc-cluster-1-workers
# Change spec.template.spec.version
```

### 6.2 Upgrade CNI

CAPC clusters use kubeadm to bootstrap Kubernetes, which installs a default CNI (usually Calico). To change the CNI:

1. Install a different CNI after cluster creation:
   ```bash
   kubectl --kubeconfig=kubeconfig apply -f https://raw.githubusercontent.com/projectcalico/calico/master/manifests/calico.yaml
   ```
2. Or customize the kubeadmConfigSpec in the cluster YAML to install a different CNI during bootstrap

## 7. Troubleshooting

### 7.1 Cluster Stuck in "Provisioning"

```bash
# Check CloudStackCluster status
kubectl describe cloudstackcluster capc-cluster-1

# Check CloudStackMachine events
kubectl describe cloudstackmachine capc-cluster-1-workers-xxxxx

# Check CAPC controller logs
kubectl logs -n capc-system -l app=cloudstack -f
```

### 7.2 Nodes Not Joining

```bash
# Check kubeadm logs on nodes
ssh -i <key> -p 2222 cloud@<VR_PUBLIC_IP> "sudo journalctl -u kubelet -f"

# Check bootstrap token
kubectl get secret | grep bootstrap

# Check API server connectivity
kubectl --kubeconfig=kubeconfig get nodes
```

### 7.3 CloudStack VM Creation Failed

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

## 8. Next Steps

- [Fleet GitOps](./fleet.md) — Automate cluster management with Fleet
- [CAPC Upgrade Guide](../capc/capc-upgrade.md) — Upgrading CAPC and clusters
