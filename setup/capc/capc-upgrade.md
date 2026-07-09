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

> **CloudStackMachineTemplates are immutable.** You cannot modify an existing template's `spec.template` — the admission webhook will reject it. Instead, you edit your source cluster manifest to create **new** template objects with the updated image, then update `KubeadmControlPlane` and `MachineDeployment` to reference them.

#### Step 2a: Build or Obtain New Image

Build a custom image for the target Kubernetes version, or download a prebuilt one matching your hypervisor.

**Prebuilt images** are available from [shapeblue packages](http://packages.shapeblue.com/cluster-api-provider-cloudstack/images/):

| Hypervisor | Format | K8s v1.33 |
|------------|--------|-----------|
| **KVM** | qcow2 (bz2) | Rocky 9, Ubuntu 22.04, Ubuntu 24.04 |
| **VMware** | ova | Rocky 9, Ubuntu 22.04, Ubuntu 24.04 |
| **XenServer** | vhd (bz2) | Rocky 9, Ubuntu 22.04, Ubuntu 24.04 |

Upload the new image to CloudStack as a template. See [Building Your Own Image](./capc-custom-image.md#registering-the-image-in-cloudstack) for registration instructions.

#### Step 2b: Edit the cluster manifest

Edit your source cluster manifest. Make **two changes**:

**2a.** Create new `CloudStackMachineTemplate` objects with updated names and image references (templates are immutable, so you cannot edit the existing ones — you create new ones):

```yaml
# Control plane — new CloudStackMachineTemplate
apiVersion: infrastructure.cluster.x-k8s.io/v1beta3
kind: CloudStackMachineTemplate
metadata:
  name: capc-cluster-control-plane-v1.33
  namespace: capc-cluster
spec:
  template:
    spec:
      offering:
        name: <control-plane-offering>
      sshKey: <ssh-key>
      template:
        name: <new-image-name>
```

```yaml
# Workers — new CloudStackMachineTemplate
apiVersion: infrastructure.cluster.x-k8s.io/v1beta3
kind: CloudStackMachineTemplate
metadata:
  name: capc-cluster-md-0-v1.33
  namespace: capc-cluster
spec:
  template:
    spec:
      offering:
        name: <worker-offering>
      sshKey: <ssh-key>
      template:
        name: <new-image-name>
```

**2b.** Update the `infrastructureRef` references in `KubeadmControlPlane` and `MachineDeployment` to point to the new template names, and update `spec.version`:

```yaml
# KubeadmControlPlane
spec:
  machineTemplate:
    infrastructureRef:
      apiVersion: infrastructure.cluster.x-k8s.io/v1beta3
      kind: CloudStackMachineTemplate
      name: capc-cluster-control-plane-v1.33   # ← new template name
  version: v1.33.0                              # ← new K8s version
```

```yaml
# MachineDeployment
spec:
  template:
    spec:
      infrastructureRef:
        apiVersion: infrastructure.cluster.x-k8s.io/v1beta3
        kind: CloudStackMachineTemplate
        name: capc-cluster-md-0-v1.33           # ← new template name
      version: v1.33.0                            # ← new K8s version
```

#### Step 2c: Apply the updated manifest

```bash
kubectl apply -f cluster-manifest.yaml
```

`kubectl apply` creates the new `CloudStackMachineTemplate` objects (new names) and updates `KubeadmControlPlane`/`MachineDeployment` in a single transaction. CAPI immediately starts the rolling update — control plane first, then workers.

> **GitOps:** If you manage clusters via Fleet or another GitOps tool, commit the manifest changes to your Git repo and let the sync tool apply them. No `kubectl` needed.

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

# Edit cluster-manifest.yaml:
#   - Create new CloudStackMachineTemplate objects (new name + new image, templates are immutable)
#   - Update infrastructureRef.name in KubeadmControlPlane and MachineDeployment
#   - Update spec.version in KubeadmControlPlane and MachineDeployment
# Then apply:
kubectl apply -f cluster-manifest.yaml

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

Edit your cluster manifest to revert the template names, image reference, and version back to the previous values, then apply:

```bash
# Revert manifest changes:
#   - Point infrastructureRef back to old CloudStackMachineTemplate objects (or create old ones again)
#   - Revert spec.version in KubeadmControlPlane and MachineDeployment
kubectl apply -f cluster-manifest.yaml

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


