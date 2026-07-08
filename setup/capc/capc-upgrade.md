# CAPC Cluster Upgrade — Full Stack Guide

This guide covers upgrading a CAPC-managed Kubernetes cluster **end-to-end**: the CAPC controller (management plane), the K8s version (image-based rolling update), CNI, CSI, and CCM (workload layer).

## The Upgrade Problem

CAPC clusters use **prebuilt images** where kubelet, kubeadm, and containerd are baked in at build time. The upgrade process is fundamentally different from kubeadm-based clusters — you don't run `kubeadm upgrade`. Instead, you replace the VM image and let CAPC roll out new nodes.

Meanwhile, CNI, CSI, and CCM are **workload deployments** — they run as pods inside the cluster, managed by their own Deployments/DaemonSets. They have nothing to do with CAPC's cluster provisioning. You upgrade them the same way you would on any K8s cluster, regardless of how the cluster was created.

### What Gets Upgraded Where

| Component | Where | How Upgraded | Managed by CAPC? |
|-----------|-------|-------------|------------------|
| **CAPC controller** | Management cluster | `clusterctl upgrade` | N/A (management plane) |
| **kubelet** | Workload nodes | New image → rolling update | ✅ Yes |
| **kubeadm** | Workload nodes | New image → rolling update | ✅ Yes |
| **containerd** | Workload nodes | New image → rolling update | ✅ Yes |
| **K8s API version** | Workload cluster | `.spec.version` field | ✅ Yes |
| **CNI** (Calico/Cilium) | Workload cluster | Re-apply manifests / Helm upgrade | ❌ No |
| **CSI driver** | Workload cluster | Re-apply manifests | ❌ No |
| **CCM** (CloudStack K8s Provider) | Workload cluster | Re-apply manifests | ❌ No |

> **Key point:** The CAPC controller is the only component that runs on the management cluster. Everything else — kubelet, kubeadm, CNI, CSI, CCM — runs on the workload cluster. The workload cluster is just a plain Kubernetes cluster; CAPC manages it from the outside.

## Upgrade Sequence

The order matters. You can't just `kubectl apply` everything at once.

1. **CAPC controller** — upgrade the management plane first
2. **K8s version** — rolling node replacement (longest step)
3. **CNI** — apply to the now-ready cluster
4. **CSI** — apply to the now-ready cluster
5. **CCM** — apply to the now-ready cluster

### Why This Order?

- **CAPC controller first**: New CAPC versions may have updated CRD schemas or controller logic. Upgrade the management plane before touching workload clusters. This only affects the management cluster — workload clusters are unaffected.
- **K8s version second**: This is the longest step — CAPC replaces VMs one by one (rolling update). Wait for it to fully complete before upgrading anything else.
- **CNI/CSI/CCM last**: These are DaemonSets/Deployments that run on the new nodes automatically once the K8s upgrade finishes. Applying them before the K8s upgrade would cause the old CNI/CSI pods to be evicted when nodes are replaced.

## Step-by-Step Upgrade

### Prerequisites

- Access to the management cluster (kubeconfig)
- Access to the workload cluster (kubeconfig)
- New CAPC release version
- New K8s-compatible image (prebuilt or custom-built)
- New CNI/CSI/CCM manifests

### Step 1: Upgrade CAPC Controller (Management Cluster Only)

> **Important:** This step applies **only to the management cluster**. The CAPC controller is a set of Kubernetes controllers (Deployments) that run on your management cluster — it watches workload cluster objects and talks to the CloudStack API. The workload cluster has **no CAPC controllers running inside it**. It's just a plain Kubernetes cluster managed from the outside.

```bash
# Upgrade CAPC controller to the latest version
capc_version="v0.6.2"
clusterctl upgrade --to ${capc_version}

# Wait for the controller to be ready
kubectl wait --for=condition=available deployment/capc-controller-manager -n capc-system --timeout=300s
```

The workload cluster is completely unaffected during this step. You could have multiple workload clusters managed by the same CAPC controller, and upgrading the controller affects all of them (or none, depending on compatibility).

### Step 2: Upgrade K8s Version (Image-Based Rolling Update)

> **CloudStackMachineTemplates are immutable.** You cannot patch an existing template. You must create **new** template objects with the updated image reference, then update `KubeadmControlPlane` and `MachineDeployment` to point to them.

#### Step 2a: Build or Obtain New Image

Build a custom image for the target Kubernetes version, or download a prebuilt one matching your hypervisor.

**Prebuilt images** are available from [shapeblue packages](http://packages.shapeblue.com/cluster-api-provider-cloudstack/images/):

| Hypervisor | Format | K8s v1.33 |
|------------|--------|-----------|
| **KVM** | qcow2 (bz2) | Rocky 9, Ubuntu 22.04, Ubuntu 24.04 |
| **VMware** | ova | Rocky 9, Ubuntu 22.04, Ubuntu 24.04 |
| **XenServer** | vhd (bz2) | Rocky 9, Ubuntu 22.04, Ubuntu 24.04 |

Upload the new image to CloudStack as a template. See [Building Your Own Image](./capc-custom-image.md#registering-the-image-in-cloudstack) for registration instructions.

#### Step 2b: Create New CloudStackMachineTemplates

Export the existing templates, strip read-only metadata, rename them, and update the image reference:

```bash
# Export current templates
kubectl get cloudstackmachinetemplate capc-cluster-control-plane -o yaml > /tmp/cp-template.yaml
kubectl get cloudstackmachinetemplate capc-cluster-md-0 -o yaml > /tmp/md-template.yaml
```

Edit both files. For each file:

1. **Remove** these metadata fields (they are read-only on apply):
   - `metadata.uid`
   - `metadata.resourceVersion`
   - `metadata.creationTimestamp`
   - `metadata.ownerReferences`
   - `metadata.annotations`
2. **Change** `metadata.name` to a new name with the target version:
   - Control plane: `capc-cluster-control-plane-v1.33`
   - Workers: `capc-cluster-md-0-v1.33`
3. **Change** `spec.template.spec.template.name` to the new CloudStack template name (e.g., `kube-v1.33/ubuntu-2404`)
4. **Keep** `offering`, `sshKey`, `diskOffering` unchanged.

Apply the new templates:

```bash
kubectl apply -f /tmp/cp-template.yaml
kubectl apply -f /tmp/md-template.yaml
```

#### Step 2c: Update KubeadmControlPlane and MachineDeployment

Point KCP and MachineDeployment to the new templates and update the version field in a single patch:

```bash
# Control plane — new template + version
kubectl patch kubeadmcontrolplane capc-cluster-control-plane --type merge -p '{
  "spec": {
    "machineTemplate": {
      "infrastructureRef": {
        "name": "capc-cluster-control-plane-v1.33"
      }
    },
    "version": "v1.33.0"
  }
}'

# Workers — new template + version
kubectl patch machinedeployment capc-cluster-md-0 --type merge -p '{
  "spec": {
    "template": {
      "spec": {
        "infrastructureRef": {
          "name": "capc-cluster-md-0-v1.33"
        },
        "version": "v1.33.0"
      }
    }
  }
}'
```

CAPC performs a rolling update — old VMs are terminated and new ones provisioned from the new image.

#### Step 2d: Wait for Rolling Update to Complete

```bash
# Wait for control plane to be ready
clusterctl wait cluster capc-cluster --for=condition=ControlPlaneReady --timeout=1200s

# Wait for worker nodes to be ready
clusterctl wait cluster capc-cluster --for=condition=WorkersReady --timeout=1200s

# Verify nodes
KUBECONFIG=capc-cluster.kubeconfig kubectl get nodes
# Expected: all nodes at v1.33, status Ready
```

### Step 3: Upgrade CNI

Now that the cluster is running the new K8s version, upgrade the CNI:

#### Calico

```bash
k8s_version="v1.33"
calico_version="v3.29.0"

kubeconfig="${HOME}/.kube/capc/capc-cluster.kubeconfig"

kubectl apply --kubeconfig=${kubeconfig} -f \
  "https://raw.githubusercontent.com/projectcalico/calico/${calico_version}/manifests/calico.yaml"

# Wait for Calico pods to be ready
kubectl wait --kubeconfig=${kubeconfig} --for=condition=ready pod -l k8s-app=calico-node -n kube-system --timeout=600s
```

#### Cilium

```bash
cilium_version="1.16.0"

kubectl --kubeconfig=${kubeconfig} apply -f \
  "https://raw.githubusercontent.com/cilium/cilium/${cilium_version}/install/kubernetes/quickstep.yaml"

# Wait for Cilium pods to be ready
kubectl wait --kubeconfig=${kubeconfig} --for=condition=ready pod -l k8s-app=cilium -n cilium --timeout=600s
```

### Step 4: Upgrade CSI Driver

```bash
csi_version="v2.0.0"

kubectl --kubeconfig=${kubeconfig} apply -f \
  "https://raw.githubusercontent.com/kubernetes-csi/csi-driver-smb/${csi_version}/deploy/csi-smb-controller-smb.yaml"

kubectl --kubeconfig=${kubeconfig} apply -f \
  "https://raw.githubusercontent.com/kubernetes-csi/csi-driver-smb/${csi_version}/deploy/csi-smb-node-smb.yaml"

# Wait for CSI pods to be ready
kubectl wait --kubeconfig=${kubeconfig} --for=condition=ready pod -l app.kubernetes.io/name=csi-smb-controller -n kube-system --timeout=300s
```

### Step 5: Upgrade CCM (CloudStack Kubernetes Provider)

```bash
kubectl --kubeconfig=${kubeconfig} apply -f \
  "https://raw.githubusercontent.com/kubernetes-sigs/cluster-api-provider-cloudstack/main/config/components/capc-ccm.yaml"

# Wait for CCM pods to be ready
kubectl wait --kubeconfig=${kubeconfig} --for=condition=available deployment/capc-ccm -n kube-system --timeout=300s
```

## Full Upgrade Script

Here's a complete script that strings all steps together:

```bash
#!/bin/bash
set -euo pipefail

# === Configuration ===
cluster_name="capc-cluster"
kubeconfig_dir="${HOME}/.kube/capc"
kubeconfig="${kubeconfig_dir}/${cluster_name}.kubeconfig"

# Versions
capc_version="v0.6.2"
k8s_version="v1.33"
calico_version="v3.29.0"
csi_version="v2.0.0"

# === Step 1: Upgrade CAPC Controller (Management Plane) ===
echo "=== Step 1: Upgrading CAPC controller to ${capc_version} ==="
clusterctl upgrade --to ${capc_version}
kubectl wait --for=condition=available deployment/capc-controller-manager -n capc-system --timeout=300s
echo "CAPC controller upgraded."

# === Step 2: Upgrade K8s Version (Image-Based Rolling Update) ===
echo "=== Step 2: Upgrading K8s version to ${k8s_version} ==="

# Build new image or get prebuilt template
# ... (your image build / template upload logic)

# Create new CloudStackMachineTemplates (templates are immutable — cannot be patched)
kubectl get cloudstackmachinetemplate capc-cluster-control-plane -o yaml > /tmp/cp-template.yaml
kubectl get cloudstackmachinetemplate capc-cluster-md-0 -o yaml > /tmp/md-template.yaml
# Edit both files:
#   - Remove metadata.uid, metadata.resourceVersion, metadata.creationTimestamp,
#     metadata.ownerReferences, metadata.annotations
#   - Rename: capc-cluster-control-plane-v1.33, capc-cluster-md-0-v1.33
#   - Update spec.template.spec.template.name to new CloudStack template
kubectl apply -f /tmp/cp-template.yaml
kubectl apply -f /tmp/md-template.yaml

# Update KCP and MachineDeployment — new template + version
kubectl patch kubeadmcontrolplane capc-cluster-control-plane \
  -p '{"spec":{"machineTemplate":{"infrastructureRef":{"name":"capc-cluster-control-plane-v1.33"}},"version":"'${k8s_version}'"}}' \
  --type=merge

kubectl patch machinedeployment capc-cluster-md-0 \
  -p '{"spec":{"template":{"spec":{"infrastructureRef":{"name":"capc-cluster-md-0-v1.33"},"version":"'${k8s_version}'"}}}}' \
  --type=merge

# Wait for rolling update to complete
clusterctl wait cluster ${cluster_name} --for=condition=ControlPlaneReady --timeout=1200s
clusterctl wait cluster ${cluster_name} --for=condition=WorkersReady --timeout=1200s

# Verify nodes
KUBECONFIG=${kubeconfig} kubectl get nodes
echo "K8s version upgraded."

# === Step 3: Upgrade CNI ===
echo "=== Step 3: Upgrading CNI to Calico ${calico_version} ==="
kubectl apply --kubeconfig=${kubeconfig} -f \
  "https://raw.githubusercontent.com/projectcalico/calico/${calico_version}/manifests/calico.yaml"
kubectl wait --kubeconfig=${kubeconfig} --for=condition=ready pod -l k8s-app=calico-node -n kube-system --timeout=600s
echo "CNI upgraded."

# === Step 4: Upgrade CSI ===
echo "=== Step 4: Upgrading CSI to ${csi_version} ==="
kubectl apply --kubeconfig=${kubeconfig} -f \
  "https://raw.githubusercontent.com/kubernetes-csi/csi-driver-smb/${csi_version}/deploy/csi-smb-controller-smb.yaml"
kubectl apply --kubeconfig=${kubeconfig} -f \
  "https://raw.githubusercontent.com/kubernetes-csi/csi-driver-smb/${csi_version}/deploy/csi-smb-node-smb.yaml"
echo "CSI upgraded."

# === Step 5: Upgrade CCM ===
echo "=== Step 5: Upgrading CCM ==="
kubectl apply --kubeconfig=${kubeconfig} -f \
  "https://raw.githubusercontent.com/kubernetes-sigs/cluster-api-provider-cloudstack/main/config/components/capc-ccm.yaml"
echo "CCM upgraded."

echo "=== Upgrade complete ==="
```

## Rollback

If something goes wrong during the upgrade, you can rollback:

### Rollback K8s Version

```bash
# Create new CloudStackMachineTemplates pointing to the old image
kubectl get cloudstackmachinetemplate capc-cluster-control-plane-v1.33 -o yaml > /tmp/cp-rollback.yaml
kubectl get cloudstackmachinetemplate capc-cluster-md-0-v1.33 -o yaml > /tmp/md-rollback.yaml
# Edit: strip metadata, rename to -v1.32, update template.name to old image
kubectl apply -f /tmp/cp-rollback.yaml
kubectl apply -f /tmp/md-rollback.yaml

# Revert KCP — point to old template + old version
kubectl patch kubeadmcontrolplane capc-cluster-control-plane \
  -p '{"spec":{"machineTemplate":{"infrastructureRef":{"name":"capc-cluster-control-plane-v1.32"}},"version":"v1.32"}}' \
  --type=merge

# Revert MachineDeployment — point to old template + old version
kubectl patch machinedeployment capc-cluster-md-0 \
  -p '{"spec":{"template":{"spec":{"infrastructureRef":{"name":"capc-cluster-md-0-v1.32"},"version":"v1.32"}}}}' \
  --type=merge

# Wait for rollback to complete
clusterctl wait cluster capc-cluster --for=condition=ControlPlaneReady --timeout=1200s
clusterctl wait cluster capc-cluster --for=condition=WorkersReady --timeout=1200s
```

### Rollback CNI/CSI/CCM

Simply re-apply the old manifests:

```bash
kubectl apply --kubeconfig=${kubeconfig} -f calico-v3.28.yaml
kubectl apply --kubeconfig=${kubeconfig} -f csi-v1.9.yaml
kubectl apply --kubeconfig=${kubeconfig} -f capc-ccm-v0.6.1.yaml
```

### Rollback CAPC Controller

```bash
clusterctl upgrade --to v0.6.1
```

## Upgrade Checklist

Use this checklist to ensure a smooth upgrade:

- [ ] Backup etcd on management cluster
- [ ] Backup workload cluster kubeconfig
- [ ] Document current versions (CAPC, K8s, CNI, CSI, CCM)
- [ ] Test upgrade on a non-production cluster first
- [ ] Ensure new K8s-compatible image is available in CloudStack
- [ ] Ensure new CNI/CSI/CCM manifests are compatible with target K8s version
- [ ] Schedule maintenance window (rolling update takes time)
- [ ] Have rollback plan ready
- [ ] Verify cluster health after each step
- [ ] Run application health checks after full upgrade

## Troubleshooting

| Issue | Check |
|-------|-------|
| Control plane fails to upgrade | Check `kubectl describe kubeadmcontrolplane capc-cluster-control-plane` |
| Worker nodes stuck at `Provisioning` | Check `kubectl describe machine capc-cluster-md-0-xxxxx` |
| CNI pods not ready after upgrade | Check `kubectl get pods -n kube-system -l k8s-app=calico-node` |
| CSI pods not ready after upgrade | Check `kubectl get pods -n kube-system -l app.kubernetes.io/name=csi-smb-controller` |
| CAPC controller crashes after upgrade | Check `kubectl logs -n capc-system deploy/capc-controller-manager` |
| Nodes not reaching `Ready` | Check `kubectl get nodes` and `kubectl describe node <node-name>` |

## Related

- [CAPC Setup Guide](./capc.md) — initial cluster deployment
- [CAPC Custom Image Guide](./capc-custom-image.md) — building K8s-compatible images
- [CNI Automation Options](./cni-automation-options.md) — automating CNI installation
- [CKS Setup Guide](../cks/cks.md) — native CloudStack Kubernetes integration


