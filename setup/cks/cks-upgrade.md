# CKS Cluster Upgrade — Full Stack Guide

This guide covers upgrading a CKS-managed Kubernetes cluster **end-to-end**: the Kubernetes version (handled by CloudStack), CNI, and CSI driver.

## The Upgrade Model

CKS clusters are managed by CloudStack's management server. The Kubernetes version upgrade is an **in-place ISO-based upgrade** — CloudStack applies the new ISO to existing nodes and upgrades them in place, without replacing the VMs.

This is fundamentally different from CAPC, which uses node replacement (new VMs from new images). CKS upgrades the existing nodes in place.

Meanwhile, CNI and CSI are **workload deployments** — they run as pods inside the cluster. CNI and CSI are baked into the ISO at build time and upgrade together with the K8s version during the in-place upgrade.

### What Gets Upgraded Where

| Component | Where | How Upgraded | Managed by CKS? |
|-----------|-------|-------------|------------------|
| **kubelet** | Workload nodes | In-place ISO upgrade via `upgradeKubernetesCluster` | ✅ Yes |
| **kubeadm** | Workload nodes | In-place ISO upgrade via `upgradeKubernetesCluster` | ✅ Yes |
| **containerd** | Workload nodes | In-place ISO upgrade via `upgradeKubernetesCluster` | ✅ Yes |
| **K8s API version** | Workload cluster | In-place ISO upgrade via `upgradeKubernetesCluster` | ✅ Yes |
| **CNI** (Calico/Cilium) | Workload nodes | Baked into ISO — upgrades with K8s version | ✅ Yes |
| **CSI driver** | Workload nodes | Baked into ISO — upgrades with K8s version | ✅ Yes |
| **CCM** (CloudStack K8s Provider) | Workload nodes | Baked into ISO — upgrades with K8s version | ✅ Yes |

> **Key point:** CKS performs an **in-place ISO upgrade** — CloudStack applies the new ISO to existing nodes and upgrades them in place, without replacing the VMs. The ISO contains kubelet, kubeadm, containerd, CNI, CSI driver, and CCM. Upgrading the K8s version upgrades **all of these together** in a single operation. No separate CNI, CSI, or CCM upgrade steps are needed.

## Upgrade Sequence

For CKS, the upgrade is a single step:

1. **K8s version** — CloudStack performs an in-place ISO upgrade (this upgrades K8s, CNI, CSI, and CCM together)

That's it. No separate CNI, CSI, or CCM upgrade steps are needed.

### Why It's Simple

- **In-place upgrade**: CloudStack applies the new ISO to existing nodes — no VM replacement, no new infrastructure.
- **All components together**: The ISO contains kubelet, kubeadm, containerd, CNI, CSI driver, and CCM. They all upgrade together.
- **No manual orchestration**: Just trigger the upgrade via UI, API, or CLI and CloudStack handles the rest.

## Step-by-Step Upgrade

### Prerequisites

- Access to the CloudStack management UI or API
- Target K8s version registered in CloudStack
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

### Step 3: Wait for In-Place Upgrade to Complete

CloudStack performs an in-place upgrade on existing nodes. Monitor progress:

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

> **Estimated time:** In-place upgrade typically takes 10-30 minutes depending on cluster size and node count. Control plane nodes are upgraded first, then workers. The ISO is streamed to each node and applied in place.

### Step 4: Verify the Upgrade

After the in-place ISO upgrade completes, verify all components are at the expected versions:

```bash
kubeconfig="<path-to-kubeconfig>"

# Check node versions
kubectl --kubeconfig=${kubeconfig} get nodes

# Check K8s version
kubectl --kubeconfig=${kubeconfig} version --short

# Check CNI pods (should be running with new version)
kubectl --kubeconfig=${kubeconfig} get pods -n kube-system -l k8s-app=calico-node

# Check CSI pods (should be running with new version)
kubectl --kubeconfig=${kubeconfig} get pods -n kube-system -l app.kubernetes.io/name=csi-smb-controller

# Check CCM pods (should be running with new version)
kubectl --kubeconfig=${kubeconfig} get pods -n kube-system -l k8s-app=cloudstack-ccm
```

> **Note:** CNI, CSI, and CCM are all baked into the ISO and upgrade together with the K8s version. No separate upgrade steps are needed.

## Full Upgrade Script

Here's a complete script that performs the CKS in-place upgrade:

```bash
#!/bin/bash
set -euo pipefail

# === Configuration ===
cluster_id="<cluster-id>"
kubeconfig="<path-to-kubeconfig>"
k8s_version="v1.33"
cloudstack_url="https://<mgmt-server>/client/api"
api_key="<api-key>"
secret_key="<secret-key>"

# === Step 1: Upgrade K8s Version (In-Place ISO Upgrade) ===
echo "=== Step 1: Upgrading K8s version to ${k8s_version} ==="

# Trigger CKS upgrade via CloudStack API
# Note: Replace with actual signed API call using your CloudStack API client
echo "Triggering CKS in-place upgrade via CloudStack API..."
# Example:
# curl -s "${cloudstack_url}/?command=upgradeKubernetesCluster&id=${cluster_id}&kubernetesversionid=<new-version-id>&apiKey=${api_key}&signature=<signature>"

echo "Waiting for in-place upgrade to complete..."

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

# === Step 2: Verify the Upgrade ===
echo "=== Step 2: Verifying upgrade ==="
kubectl --kubeconfig=${kubeconfig} get nodes
kubectl --kubeconfig=${kubeconfig} version --short
kubectl --kubeconfig=${kubeconfig} get pods -n kube-system -l k8s-app=calico-node
kubectl --kubeconfig=${kubeconfig} get pods -n kube-system -l app.kubernetes.io/name=csi-smb-controller
kubectl --kubeconfig=${kubeconfig} get pods -n kube-system -l k8s-app=cloudstack-ccm

echo "=== Upgrade complete ==="
echo "All components (K8s, CNI, CSI, CCM) upgraded together via ISO in-place upgrade."
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

> **Warning:** Rolling back the K8s version will perform another in-place upgrade. Applications may experience downtime during the upgrade.

### Rollback CNI

If you separately re-applied CNI manifests after the ISO upgrade, you can rollback by re-applying the old CNI manifests:

```bash
kubectl apply --kubeconfig=${kubeconfig} -f calico-v3.28.yaml
```

CSI and CCM rollback is handled by rolling back the K8s version (re-apply the previous ISO).

## Upgrade Checklist

Use this checklist to ensure a smooth upgrade:

- [ ] Document current versions (K8s, CNI, CSI, CCM)
- [ ] Test upgrade on a non-production cluster first
- [ ] Ensure target K8s ISO is registered in CloudStack
- [ ] Schedule maintenance window (in-place upgrade takes time)
- [ ] Have rollback plan ready
- [ ] Verify cluster health after each step
- [ ] Run application health checks after full upgrade
- [ ] Verify CNI connectivity between nodes
- [ ] Verify CSI volume provisioning works
- [ ] Verify CCM LoadBalancer services work

## Troubleshooting

| Issue | Check |
|-------|-------|
| Upgrade icon not visible | Verify cluster is `Running` and target version is registered |
| Cluster stuck at `Upgrading` | Check CloudStack management server logs: `tail -f /var/log/cloudstack/management/management-server.log` |
| Nodes not reaching `Ready` | Check `kubectl get nodes` and `kubectl describe node <node-name>` |
| CNI pods not ready after upgrade | Check `kubectl get pods -n kube-system -l k8s-app=calico-node` |
| CSI pods not ready after upgrade | Check `kubectl get pods -n kube-system -l app.kubernetes.io/name=csi-smb-controller` |
| CCM pods not ready after upgrade | Check `kubectl get pods -n kube-system -l k8s-app=cloudstack-ccm` |
| Port forwarding broken after upgrade | Re-configure firewall rules and port forwarding in CloudStack |

## ISO-Baked Components

### What's Baked Into the CKS ISO

The CKS ISO contains all the following components, which upgrade together when you upgrade the K8s version:

| Component | Upgraded with ISO? |
|-----------|-------------------|
| kubelet | ✅ Yes |
| kubeadm | ✅ Yes |
| containerd | ✅ Yes |
| CNI (Calico/Cilium) | ✅ Yes |
| CSI driver | ✅ Yes |
| CCM (CloudStack K8s Provider) | ✅ Yes |

### When You Need to Re-apply Manifests

The only component you might need to upgrade separately is **CNI** — if you need a CNI version different from what's baked into the ISO. In that case:

1. Upgrade K8s version via CloudStack (upgrades everything else automatically)
2. Re-apply CNI manifests to get the desired CNI version

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


