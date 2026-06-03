# CKS Cluster Upgrade — Full Stack Guide

This guide covers upgrading a CKS-managed Kubernetes cluster **end-to-end**: the Kubernetes version (handled by CloudStack), CNI, and CSI driver.

## The Upgrade Model

CKS clusters are managed by CloudStack's management server. The Kubernetes version upgrade is a **native CloudStack operation** — you don't need to manually orchestrate node replacement or image updates. CloudStack handles the rolling update automatically.

Meanwhile, CNI and CSI are **workload deployments** — they run as pods inside the cluster. CNI is baked into the ISO at build time, and CSI is deployed as a separate manifest. You upgrade these the same way you would on any K8s cluster.

### What Gets Upgraded Where

| Component | Where | How Upgraded | Managed by CKS? |
|-----------|-------|-------------|------------------|
| **kubelet** | Workload nodes | CloudStack `upgradeKubernetesCluster` | ✅ Yes |
| **kubeadm** | Workload nodes | CloudStack `upgradeKubernetesCluster` | ✅ Yes |
| **containerd** | Workload nodes | CloudStack `upgradeKubernetesCluster` | ✅ Yes |
| **K8s API version** | Workload cluster | CloudStack `upgradeKubernetesCluster` | ✅ Yes |
| **CNI** (Calico/Cilium) | Workload cluster | Re-apply manifests / Helm upgrade | ❌ No |
| **CSI driver** | Workload cluster | Re-apply manifests | ❌ No |

> **Key point:** CKS handles the K8s version upgrade automatically — CloudStack provisions new nodes from the new ISO and performs a rolling update. CNI is baked into the ISO, so upgrading K8s does **not** upgrade CNI. CSI is a separate deployment. You handle CNI and CSI upgrades manually.

## Upgrade Sequence

The order matters:

1. **K8s version** — CloudStack handles the rolling update
2. **CNI** — apply to the now-ready cluster
3. **CSI** — apply to the now-ready cluster

### Why This Order?

- **K8s version first**: CloudStack performs a rolling node replacement. Wait for it to fully complete before upgrading anything else.
- **CNI/CSI last**: These are DaemonSets/Deployments that run on the new nodes automatically once the K8s upgrade finishes. Applying them before the K8s upgrade would cause the old CNI/CSI pods to be evicted when nodes are replaced.

## Step-by-Step Upgrade

### Prerequisites

- Access to the CloudStack management UI or API
- Target K8s version registered in CloudStack
- New CNI/CSI manifests (if upgrading those components)
- Access to the workload cluster kubeconfig

### Step 1: Register New K8s Version (If Not Already Done)

Before you can upgrade, the target K8s version must be registered in CloudStack.

**Via UI:**
1. **Infrastructure** → **Kubernetes** → **Supported Versions** → **Add Kubernetes Supported Version**
2. Fill in version details and upload the ISO

**Via API:**
```bash
addKubernetesSupportedVersion \
  name=v1.33.1 \
  semanticversion=1.33.1 \
  url=http://<server>/setup-v1.33.1.iso \
  zoneid=<zone-id> \
  mincpunumber=2 \
  minmemory=2048 \
  checksum=<iso-checksum>
```

**ISO sources:**
- [`download.cloudstack.org/cks/`](http://download.cloudstack.org/cks/)
- [`packages.shapeblue.com/cks/`](http://packages.shapeblue.com/cks/)

### Step 2: Upgrade K8s Version (CloudStack-Native)

#### Via UI

1. Navigate to **Compute** → **Kubernetes**
2. Hover over the cluster name and click the **three dots (⋮)** on the right
3. Click the **Upgrade** icon (🔄)
4. Select the target Kubernetes version from the dropdown
5. Click **OK**

> **Note:** The **Upgrade** icon only appears when:
> - The cluster is in a **running** state
> - An eligible upgrade version is registered in CloudStack

#### Via API

```bash
upgradeKubernetesCluster \
  id=<cluster-id> \
  kubernetesversionid=<new-version-id>
```

#### Via cmk CLI

```bash
upgradekubernetescluster \
  id=<cluster-id> \
  kubernetesversionid=<new-version-id>
```

### Step 3: Wait for Rolling Update to Complete

CloudStack performs a rolling node replacement. Monitor progress:

**Via UI:**
- Watch the cluster status indicator in the Kubernetes tab
- Status transitions: `Running` → `Upgrading` → `Running`

**Via API:**
```bash
# Check cluster state
listkubernetesclusters id=<cluster-id>
# Look for state: running (upgrade complete) or upgrading (in progress)
```

**Via kubectl (after upgrade completes):**
```bash
kubectl get nodes
# Expected: all nodes at new version, status Ready

kubectl version --short
# Expected: server version matches target
```

> **Estimated time:** Rolling update typically takes 5-15 minutes depending on cluster size. Control plane nodes are upgraded first, then workers.

### Step 4: Upgrade CNI

Now that the cluster is running the new K8s version, upgrade the CNI:

#### Calico

```bash
kubeconfig="<path-to-kubeconfig>"
calico_version="v3.29.0"

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

#### CNI Configuration (ACS 4.21+)

If you registered a CNI configuration during cluster creation, note that **CNI configurations are applied at cluster creation time only**. To change the CNI version after deployment, you must upgrade via manifest (as shown above) or rebuild the ISO with the new CNI baked in.

### Step 5: Upgrade CSI Driver

```bash
kubeconfig="<path-to-kubeconfig>"
csi_version="v2.0.0"

kubectl apply --kubeconfig=${kubeconfig} -f \
  "https://raw.githubusercontent.com/kubernetes-csi/csi-driver-smb/${csi_version}/deploy/csi-smb-controller-smb.yaml"

kubectl apply --kubeconfig=${kubeconfig} -f \
  "https://raw.githubusercontent.com/kubernetes-csi/csi-driver-smb/${csi_version}/deploy/csi-smb-node-smb.yaml"

# Wait for CSI pods to be ready
kubectl wait --kubeconfig=${kubeconfig} --for=condition=ready pod -l app.kubernetes.io/name=csi-smb-controller -n kube-system --timeout=300s
```

## Full Upgrade Script

Here's a complete script that strings all steps together:

```bash
#!/bin/bash
set -euo pipefail

# === Configuration ===
cluster_id="<cluster-id>"
kubeconfig="<path-to-kubeconfig>"
k8s_version="v1.33"
calico_version="v3.29.0"
csi_version="v2.0.0"

# === Step 1: Upgrade K8s Version (CloudStack-Native) ===
echo "=== Step 1: Upgrading K8s version to ${k8s_version} ==="

# Via API
cloudstack_url="https://<mgmt-server>/client/api"
api_key="<api-key>"
secret_key="<secret-key>"

# Generate signed request
# (Use your preferred CloudStack API client or the UI)
# Example:
# upgradeKubernetesCluster id=${cluster_id} kubernetesversionid=<new-version-id>

echo "Triggering CKS upgrade via CloudStack API..."
# Replace with actual API call
# curl -s "${cloudstack_url}/?command=upgradeKubernetesCluster&id=${cluster_id}&kubernetesversionid=<new-version-id>&apiKey=${api_key}&signature=<signature>"

echo "Waiting for rolling update to complete..."

# Poll until upgrade completes
while true; do
  state=$(curl -s "${cloudstack_url}/?command=listKubernetesClusters&id=${cluster_id}&apiKey=${api_key}&signature=<signature>" | jq -r '.kubernetesclusters[0].state')
  echo "Cluster state: ${state}"
  if [[ "${state}" == "Running" ]]; then
    echo "Upgrade complete."
    break
  fi
  sleep 30
done

# Verify nodes
kubectl --kubeconfig=${kubeconfig} get nodes
kubectl --kubeconfig=${kubeconfig} version --short

# === Step 2: Upgrade CNI ===
echo "=== Step 2: Upgrading CNI to Calico ${calico_version} ==="
kubectl apply --kubeconfig=${kubeconfig} -f \
  "https://raw.githubusercontent.com/projectcalico/calico/${calico_version}/manifests/calico.yaml"
kubectl wait --kubeconfig=${kubeconfig} --for=condition=ready pod -l k8s-app=calico-node -n kube-system --timeout=600s
echo "CNI upgraded."

# === Step 3: Upgrade CSI ===
echo "=== Step 3: Upgrading CSI to ${csi_version} ==="
kubectl apply --kubeconfig=${kubeconfig} -f \
  "https://raw.githubusercontent.com/kubernetes-csi/csi-driver-smb/${csi_version}/deploy/csi-smb-controller-smb.yaml"
kubectl apply --kubeconfig=${kubeconfig} -f \
  "https://raw.githubusercontent.com/kubernetes-csi/csi-driver-smb/${csi_version}/deploy/csi-smb-node-smb.yaml"
echo "CSI upgraded."

echo "=== Upgrade complete ==="
```

## Rollback

If something goes wrong during the upgrade, you can rollback:

### Rollback K8s Version

CKS does **not** have a built-in rollback mechanism. To rollback:

1. **Register the previous K8s version ISO** (if not already registered)
2. **Trigger another upgrade** to the previous version:

```bash
upgradeKubernetesCluster \
  id=<cluster-id> \
  kubernetesversionid=<previous-version-id>
```

> **Warning:** Rolling back the K8s version will replace nodes again. Applications may experience downtime during the rolling update.

### Rollback CNI/CSI

Simply re-apply the old manifests:

```bash
kubectl apply --kubeconfig=${kubeconfig} -f calico-v3.28.yaml
kubectl apply --kubeconfig=${kubeconfig} -f csi-v1.9.yaml
```

## Upgrade Checklist

Use this checklist to ensure a smooth upgrade:

- [ ] Document current versions (K8s, CNI, CSI)
- [ ] Test upgrade on a non-production cluster first
- [ ] Ensure target K8s ISO is registered in CloudStack
- [ ] Ensure new CNI/CSI manifests are compatible with target K8s version
- [ ] Schedule maintenance window (rolling update takes time)
- [ ] Have rollback plan ready
- [ ] Verify cluster health after each step
- [ ] Run application health checks after full upgrade
- [ ] Verify CNI connectivity between nodes
- [ ] Verify CSI volume provisioning works

## Troubleshooting

| Issue | Check |
|-------|-------|
| Upgrade icon not visible | Verify cluster is `Running` and target version is registered |
| Cluster stuck at `Upgrading` | Check CloudStack management server logs: `tail -f /var/log/cloudstack/management/management-server.log` |
| Nodes not reaching `Ready` | Check `kubectl get nodes` and `kubectl describe node <node-name>` |
| CNI pods not ready after upgrade | Check `kubectl get pods -n kube-system -l k8s-app=calico-node` |
| CSI pods not ready after upgrade | Check `kubectl get pods -n kube-system -l app.kubernetes.io/name=csi-smb-controller` |
| Old nodes still running | Check `kubectl get nodes` — old nodes should be replaced during rolling update |
| Port forwarding broken after upgrade | Re-configure firewall rules and port forwarding in CloudStack |

## CNI Upgrade Considerations

### CNI Is Baked Into the ISO

The CNI version is determined at ISO build time. When you upgrade the K8s version, CloudStack provisions new nodes from the new ISO — which has the **same CNI version** that was baked in.

This means:
- **K8s upgrade ≠ CNI upgrade** — they are independent
- To upgrade CNI, you must either:
  1. **Re-apply CNI manifests** (recommended for minor versions)
  2. **Build a new ISO** with the new CNI baked in (for major version changes)

### When to Rebuild the ISO for CNI

| Scenario | Approach |
|----------|----------|
| CNI minor version bump (e.g., Calico 3.28 → 3.29) | Re-apply manifests |
| CNI major version bump (e.g., Calico 3.x → 4.x) | Consider rebuilding ISO |
| Switching CNI (e.g., Calico → Cilium) | Re-apply manifests or rebuild ISO |
| Custom CNI parameters | Use CNI configuration (ACS 4.21+) or rebuild ISO |

## Related

- [CKS Setup Guide](./cks.md) — initial cluster deployment
- [CKS Custom ISO Build Guide](./cks-custom-iso.md) — building CKS-compatible ISOs
- [CAPC Upgrade Guide](../capc/capc-upgrade.md) — CAPC cluster upgrade procedures
- [CNI Automation Options](../capc/cni-automation-options.md) — automating CNI installation


