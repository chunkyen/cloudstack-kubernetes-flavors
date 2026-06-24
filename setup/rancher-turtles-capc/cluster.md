# Create Clusters via CAPI

This guide covers provisioning CKS clusters on CloudStack using CAPI CRDs managed by Turtles + CAPC.

## Prerequisites

- Rancher + Turtles + CAPC deployed (see [Rancher](./rancher.md) and [Turtles](./turtles.md))
- CKS-compatible templates registered in CloudStack
- CKS binaries ISO registered in CloudStack
- `kubectl` configured with the management cluster

## Step 1: Prepare Templates

CAPC requires CKS-compatible templates. Register them in CloudStack:

```bash
# Via cmk
# Register the CKS ISO as a template (if not already done)
cmk register-iso \
  url=http://download.cloudstack.org/cks/setup-v1.32.0-calico.iso \
  name=cks-v1.32.0-calico \
  hypervisor=KVM \
  ostype=Generic
cmk register-template \
  url=http://download.cloudstack.org/cks/setup-v1.32.0-calico.iso \
  name=cks-v1.32.0-calico \
  ispublic=true \
  ostypeid=<os-type-id>
```

## Step 2: Create a Cluster

### Minimal Cluster (1 Control + 2 Workers)

```yaml
# cluster-minimal.yaml
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: cks-cluster-1
  namespace: default
spec:
  clusterNetwork:
    pods:
      cidrBlocks: ["10.244.0.0/16"]
    serviceDomain: cluster.local
  controlPlaneRef:
    apiVersion: controlplane.cluster.x-k8s.io/v1beta1
    kind: KubeadmControlPlane
    name: cks-cluster-1-control-plane
  infrastructureRef:
    apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
    kind: CloudStackCluster
    name: cks-cluster-1
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: CloudStackCluster
metadata:
  name: cks-cluster-1
  namespace: default
spec:
  controlPlaneEndpoint:
    host: "<load-balancer-ip>"
    port: 6443
  network:
    name: "<network-name-or-id>"
  zone:
    name: "<zone-name-or-id>"
---
apiVersion: controlplane.cluster.x-k8s.io/v1beta1
kind: KubeadmControlPlane
metadata:
  name: cks-cluster-1-control-plane
  namespace: default
spec:
  replicas: 1
  version: "v1.32.0"
  machineTemplate:
    infrastructureRef:
      apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
      kind: CloudStackMachine
      name: cks-cluster-1-control-plane
  kubeadmConfigSpec:
    clusterConfiguration:
      apiServer:
        certSANs:
          - "<load-balancer-ip>"
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: CloudStackMachine
metadata:
  name: cks-cluster-1-control-plane
  namespace: default
spec:
  serviceOffering: "Medium"
  template: "cks-v1.32.0-calico"
  diskOffering: "Large"
---
apiVersion: cluster.x-k8s.io/v1beta1
kind: MachineDeployment
metadata:
  name: cks-cluster-1-workers
  namespace: default
spec:
  replicas: 2
  clusterName: cks-cluster-1
  selector:
    matchLabels:
      cluster.x-k8s.io/cluster-name: cks-cluster-1
  template:
    spec:
      version: "v1.32.0"
      bootstrap:
        configRef:
          apiVersion: bootstrap.cluster.x-k8s.io/v1beta1
          kind: KubeadmConfig
          name: cks-cluster-1-workers
      infrastructureRef:
        apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
        kind: CloudStackMachine
        name: cks-cluster-1-workers
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: CloudStackMachine
metadata:
  name: cks-cluster-1-workers
  namespace: default
spec:
  serviceOffering: "Medium"
  template: "cks-v1.32.0-calico"
  diskOffering: "Large"
---
apiVersion: bootstrap.cluster.x-k8s.io/v1beta1
kind: KubeadmConfig
metadata:
  name: cks-cluster-1-workers
  namespace: default
spec: {}
```

### Apply and Monitor

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

### HA Cluster (3 Control + 3 Workers + Etcd)

```yaml
# cluster-ha.yaml
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: cks-cluster-ha
  namespace: default
spec:
  clusterNetwork:
    pods:
      cidrBlocks: ["10.244.0.0/16"]
    serviceDomain: cluster.local
  controlPlaneRef:
    apiVersion: controlplane.cluster.x-k8s.io/v1beta1
    kind: KubeadmControlPlane
    name: cks-cluster-ha-control-plane
  infrastructureRef:
    apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
    kind: CloudStackCluster
    name: cks-cluster-ha
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: CloudStackCluster
metadata:
  name: cks-cluster-ha
  namespace: default
spec:
  controlPlaneEndpoint:
    host: "<load-balancer-ip>"
    port: 6443
  network:
    name: "<network-name-or-id>"
  zone:
    name: "<zone-name-or-id>"
  # Dedicated etcd nodes
  etcd:
    replicas: 3
    serviceOffering: "Medium"
    template: "cks-etcd-template"
---
apiVersion: controlplane.cluster.x-k8s.io/v1beta1
kind: KubeadmControlPlane
metadata:
  name: cks-cluster-ha-control-plane
  namespace: default
spec:
  replicas: 3
  version: "v1.32.0"
  machineTemplate:
    infrastructureRef:
      apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
      kind: CloudStackMachine
      name: cks-cluster-ha-control-plane
  kubeadmConfigSpec:
    clusterConfiguration:
      apiServer:
        certSANs:
          - "<load-balancer-ip>"
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: CloudStackMachine
metadata:
  name: cks-cluster-ha-control-plane
  namespace: default
spec:
  serviceOffering: "Large"
  template: "cks-v1.32.0-calico"
  diskOffering: "Large"
---
apiVersion: cluster.x-k8s.io/v1beta1
kind: MachineDeployment
metadata:
  name: cks-cluster-ha-workers
  namespace: default
spec:
  replicas: 3
  clusterName: cks-cluster-ha
  selector:
    matchLabels:
      cluster.x-k8s.io/cluster-name: cks-cluster-ha
  template:
    spec:
      version: "v1.32.0"
      bootstrap:
        configRef:
          apiVersion: bootstrap.cluster.x-k8s.io/v1beta1
          kind: KubeadmConfig
          name: cks-cluster-ha-workers
      infrastructureRef:
        apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
        kind: CloudStackMachine
        name: cks-cluster-ha-workers
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: CloudStackMachine
metadata:
  name: cks-cluster-ha-workers
  namespace: default
spec:
  serviceOffering: "Large"
  template: "cks-v1.32.0-calico"
  diskOffering: "Large"
---
apiVersion: bootstrap.cluster.x-k8s.io/v1beta1
kind: KubeadmConfig
metadata:
  name: cks-cluster-ha-workers
  namespace: default
spec: {}
```

## Step 3: Access the Cluster

### Get kubeconfig

```bash
# The cluster creates a Secret with kubeconfig
kubectl get secret cks-cluster-1-kubeconfig -o jsonpath='{.data.value}' | base64 -d > kubeconfig

# Use it
kubectl --kubeconfig=kubeconfig get nodes
kubectl --kubeconfig=kubeconfig get pods -n kube-system
```

### SSH to Nodes

```bash
# Control node (port 2222 + node_index)
ssh -i <key> -p 2222 cloud@<VR_PUBLIC_IP>

# Worker node
ssh -i <key> -p 2223 cloud@<VR_PUBLIC_IP>
```

## Step 4: Scale the Cluster

### Scale Workers

```bash
# Via kubectl
kubectl scale machinedeployment cks-cluster-1-workers --replicas=5

# Or edit the MachineDeployment
kubectl edit machinedeployment cks-cluster-1-workers
```

### Scale Control Plane

```bash
# Edit KubeadmControlPlane replicas
kubectl edit kubeadmcontrolplane cks-cluster-1-control-plane
# Change spec.replicas from 1 to 3
```

## Step 5: Upgrade the Cluster

### Upgrade Kubernetes Version

```bash
# Update KubeadmControlPlane version
kubectl edit kubeadmcontrolplane cks-cluster-1-control-plane
# Change spec.version from "v1.32.0" to "v1.33.0"

# Update MachineDeployment version
kubectl edit machinedeployment cks-cluster-1-workers
# Change spec.template.spec.version
```

### Upgrade CNI

The CNI is baked into the CKS ISO. To change CNI version:

1. Build a new CKS ISO with the desired CNI version
2. Register the new ISO as a template
3. Update the template reference in CloudStackMachine resources

## Troubleshooting

### Cluster Stuck in "Provisioning"

```bash
# Check CloudStackCluster status
kubectl describe cloudstackcluster cks-cluster-1

# Check CloudStackMachine events
kubectl describe cloudstackmachine cks-cluster-1-workers-xxxxx

# Check CAPC controller logs
kubectl logs -n capc-system -l app=cloudstack -f
```

### Nodes Not Joining

```bash
# Check kubeadm logs on nodes
ssh -i <key> -p 2222 cloud@<VR_PUBLIC_IP> "sudo journalctl -u kubelet -f"

# Check bootstrap token
kubectl get secret | grep bootstrap

# Check API server connectivity
kubectl --kubeconfig=kubeconfig get nodes
```

### CloudStack VM Creation Failed

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

## Next Steps

- [Fleet GitOps](./fleet.md) — Automate cluster management with Fleet
- [CKS Upgrade Guide](../cks/cks-upgrade.md) — Upgrading CKS clusters
