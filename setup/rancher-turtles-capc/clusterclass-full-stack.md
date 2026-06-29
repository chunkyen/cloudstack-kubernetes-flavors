# Full-Stack Onboarding with ClusterClass — CNI + CCM + CSI

Deploy a CAPC cluster and get **CNI** (networking), **CCM** (CloudStack Kubernetes Provider for LoadBalancer services and node labels), and **CSI** (persistent storage) all installed automatically through the ClusterClass topology. No manual post-creation steps, no ClusterResourceSet labeling, no drift — everything is part of the cluster template itself.

This is the ClusterClass equivalent of CKS's "one ISO, everything works" experience for CAPC clusters.

## Architecture

```
Management Cluster (Rancher + Turtles)
│
├── ClusterClass: capc-fullstack
│   ├── InfrastructureClusterTemplate  — CloudStackCluster template
│   ├── ControlPlaneMachineTemplate    — CP VM spec
│   ├── WorkerMachineTemplate          — Worker VM spec
│   ├── KubeadmConfigTemplate          — bootstrap config
│   │
│   └── Patches (injected at cluster lifecycle phases):
│       ├── Phase A: ControlPlaneInitialized
│       │   └── cni-calico             — Calico CNI deployed to kube-system
│       │
│       ├── Phase B: PostBootstrapInit
│       │   ├── secret-cloudstack-ccm  — CloudStack credentials secret
│       │   ├── rbac-cloudstack-ccm    — RBAC for CCM controller
│       │   ├── deployment-cloudstack-ccm — CCM controller deployment
│       │   └── csi-driver             — CSI driver + storage class
│       │
│       └── Phase C: ScaleUp (optional)
│           └── fleet-workspace        — Fleet workspace for GitOps reconciliation
│
├── Cluster (topology-based):
│     spec.topology.class = capc-fullstack
│     spec.topology.version = v1.35.0
│     spec.topology.controlPlane.replicas = 3
│     spec.topology.workers.machines[].replicas = 3
│
└── Workload Cluster (VMs on CloudStack)
    ├── Calico pods in kube-system (Phase A)
    ├── CCM controller in kube-system (Phase B)
    └── CSI driver + storage class (Phase B)
```

## Prerequisites

- Rancher Turtles v0.6.1+ with CAPC provider installed (Phase 1 of [Turtles guide](./turtles.md))
- CAPI-compatible image registered in CloudStack as template
- Reserved public IP for API endpoint
- `kubectl` configured with the management cluster (Rancher)

> **Note:** The `ClusterClass` CR itself lives on the **management cluster**. Its patches are automatically injected into each workload cluster during creation. No manual labeling, no ClusterResourceSet, no follow-up steps.

## Step 1: Define the ClusterClass

The complete ClusterClass with all three full-stack components is defined in a single file: [30-clusterclass-fullstack.yaml](./manifests/30-clusterclass-fullstack.yaml)

Apply it once — it's reusable for every cluster you create from this template:

```bash
kubectl apply -f manifests/30-clusterclass-fullstack.yaml
```

### Patch injection mechanism

All patches use `patchType: inline` — raw YAML resources are embedded directly in the ClusterClass CR. CAPI applies them as new objects to the workload cluster at each lifecycle phase. No RFC 6902 JSON patch operations, no merge logic.

> **Why `inline`?** Full Kubernetes resource definitions (Deployments, DaemonSets, Secrets, RBAC) can't be expressed as JSONPatch without complex path-based operations. Inline is simpler and more maintainable for complete resource injection.

### What the ClusterClass defines

| Component | Patch Name | Injection Phase | Purpose |
|-----------|-----------|-----------------|---------|
| **Calico CNI** | `cni-calico` | `ControlPlaneInitialized` | Pod networking — needed before any workload pods can schedule |
| **CloudStack K8s Provider (CCM)** | `secret-cloudstack-ccm`, `rbac-cloudstack-ccm`, `deployment-cloudstack-ccm` | `PostBootstrapInit` | LoadBalancer services + node labels from CloudStack |
| **CSI Driver** | `csi-snapshot-crds`, `csi-driver`, `storageclass` | `PostBootstrapInit` | Persistent volumes with CloudStack storage |

### Patch injection order explained

```
Cluster creation → Control plane nodes boot → ControlPlaneInitialized phase fires
    │
    ├── CNI patch applies (Calico) — pods can now communicate across CP nodes
    │
    ↓
Bootstrap completes on all workers → PostBootstrapInit phase fires
    │
    ├── CCM secret + RBAC + deployment apply
    │   ├── CSI snapshot CRDs, driver controller + node, storage class apply
    │
    └── Cluster is fully operational — zero manual steps remaining
```

### Key parameters to replace in the template

Before applying the ClusterClass, edit `30-clusterclass-fullstack.yaml` and replace:

| Parameter | Where it appears | How to find |
|-----------|-----------------|-------------|
| `<reserved-public-ip>` | InfrastructureClusterTemplate → controlPlaneEndpoint.host | `cmk list publicipaddresses listall=true zoneid=<zone-id> forvirtualnetwork=true allocatedonly=false` |
| `<network-name-or-id>` | InfrastructureClusterTemplate → failureDomains[].zone.network.name | `cmk list networks listall=true zoneid=<zone-id>` |
| `<zone-name-or-id>` | InfrastructureClusterTemplate → failureDomains[].zone.name | `cmk list zones` |
| `capc-ubuntu24-1.35` | All MachineTemplates → template.name | Must be registered in CloudStack |
| `kube control` / `kube worker1` | ControlPlane/Worker MachineTemplates → offering.name | `cmk list serviceofferings listall=true` |
| `cylabnb-k1` | All MachineTemplates → sshKey | `cmk register-sshkeypair --name=cylabnb-k1 --publickey="$(cat ~/.ssh/id_ed25519.pub)"` |

## Step 2: Create a Cluster from the Template

Create any number of clusters — each one gets CNI + CCM + CSI automatically:

```yaml
# manifests/31-cluster-topology.yaml
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: capc-cluster-2
  namespace: capc-cluster-2
spec:
  topology:
    class: capc-fullstack
    version: v1.35.0
    controlPlane:
      replicas: 3
    workers:
      machines:
        - name: default-worker
          replicas: 3
```

> **⚠️ Namespace:** The `Cluster` CR lives in a namespace on the management cluster (e.g., `capc-cluster-2`). All injected resources — Calico pods, CCM deployment, CSI driver — appear inside that same namespace on the *workload* cluster. Keep it consistent: use one namespace per workload cluster.

```bash
kubectl apply -f manifests/31-cluster-topology.yaml
```

That's it. No labeling, no CRS creation, no ConfigMap, no follow-up `kubectl apply`. The topology controller handles everything during cluster lifecycle phases.

## Step 3: Monitor Cluster Creation

Watch the cluster come up — patches inject automatically at each phase:

```bash
# Watch cluster progression
kubectl get clusters -n capc-cluster-2

# Check CloudStack resources being provisioned
kubectl get cloudstackclusters,cloudstackmachines -n capc-cluster-2

# Get workload kubeconfig once Ready
KUBECONFIG=$(kubectl get secret capc-cluster-2-kubeconfig \
  -n capc-cluster-2 -o jsonpath='{.data.value}' | base64 -d)

# Phase A: CNI should be running by now
kubectl --kubeconfig=$KUBECONFIG get pods -A | grep calico

# Phase B: CCM and CSI should be deployed
kubectl --kubeconfig=$KUBECONFIG get pods -n kube-system | grep cloudstack-ccm
kubectl --kubeconfig=$KUBECONFIG get pods -A | grep cloudstack-csi
kubectl --kubeconfig=$KUBECONFIG get storageclass

# Phase B: Storage class ready for PVCs
kubectl --kubeconfig=$KUBECONFIG apply -f - <<EOF
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
kubectl --kubeconfig=$KUBECONFIG get pvc test-pvc
# Expected: STATUS: Bound
```

## Step 4: Fleet GitOps for Ongoing Reconciliation (Optional)

ClusterClass patches handle initial deployment. For ongoing version management and drift reconciliation, add a Fleet workspace in Rancher UI:

1. **Rancher → Cluster Management → capc-cluster-2 → Tools → Fleet**
2. Create a `FleetWorkspace` pointing to your Git repo with updated CNI/CCM/CSI manifests
3. Fleet automatically reconciles — if Calico updates, it rolls; if CSI driver has a new image tag, it applies

This replaces the ClusterResourceSet's "one-shot apply" model with continuous reconciliation.

## Quick Reference — All-in-One Apply

```bash
#!/bin/bash
set -euo pipefail

# 1. Deploy the ClusterClass (one time)
kubectl apply -f manifests/30-clusterclass-fullstack.yaml

# 2. Create any number of clusters from it
for CLUSTER in capc-cluster-1 capc-cluster-2 capc-cluster-3; do
  cat <<EOF | kubectl apply -n "$CLUSTER" -f -
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: $CLUSTER
spec:
  topology:
    class: capc-fullstack
    version: v1.35.0
    controlPlane:
      replicas: 3
    workers:
      machines:
        - name: default-worker
          replicas: 3
EOF
done

# 3. Done. No more steps needed.
echo "✅ All clusters created with CNI + CCM + CSI injected automatically."
```

## Comparison — Old Approach vs ClusterClass

| Aspect | Old (ClusterResourceSet) | New (ClusterClass) |
|--------|-------------------------|--------------------|
| **Manifest delivery** | ConfigMap + CRS selector + manual label trigger | Embedded in template, auto-injected at lifecycle phases |
| **Manual steps after cluster creation** | 1 (label the cluster) + monitor | 0 |
| **Reusability** | One CRS per cluster or shared via labels | Single ClusterClass → any number of clusters |
| **Upgrade path** | Must update ConfigMap + trigger CRS again | Update template version, cluster follows on next reconcile |
| **Drift handling** | CRS only runs once; drift requires manual re-trigger | Topology patches reapplied automatically each reconcile cycle |
| **UI visibility** | CRS object visible in kubectl, not Rancher UI | ClusterClass appears as a managed cluster template in Rancher |
| **GitOps integration** | Manual ConfigMap versioning | Fleet Workspace for ongoing reconciliation on top of template |

## Cilium Alternative

If you prefer Cilium over Calico:

```bash
# Replace the CNI patch in 30-clusterclass-fullstack.yaml
# Change cni-calico → cni-cilium, update the manifest content
# Then add a selector label to your cluster for CNI choice:
kubectl apply -n capc-cluster-2 -f - <<EOF
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: capc-cluster-2
spec:
  topology:
    class: capc-fullstack-cilium   # separate ClusterClass for Cilium variant
```

Or use conditional patches within a single ClusterClass:

```yaml
patches:
  - name: cni-calico
    enabledIf: "{{ eq .topology.cni \"calico\" }}"
    ...
  - name: cni-cilium
    enabledIf: "{{ eq .topology.cni \"cilium\" }}"
    ...

# Usage:
spec:
  topology:
    class: capc-fullstack
    variables:
      - name: cni
        value: "calico"   # or "cilium"
```

## Troubleshooting

### Cluster stuck in Provisioning after ControlPlaneInitialized phase

```bash
# Check if CNI patch was applied
KUBECONFIG=$(kubectl get secret capc-cluster-2-kubeconfig \
  -n capc-cluster-2 -o jsonpath='{.data.value}' | base64 -d)
kubectl --kubeconfig=$KUBECONFIG get pods -A | grep calico

# Check ClusterClass patch status
kubectl describe cluster capc-cluster-2 -n capc-cluster-2 | grep -A 5 "patches"

# Check topology events
kubectl get events -n capc-cluster-2 --sort-by='.lastTimestamp'
```

### CCM not creating LoadBalancer services

Same as old approach — verify credentials reach the workload cluster:

```bash
KUBECONFIG=$(kubectl get secret capc-cluster-2-kubeconfig \
  -n capc-cluster-2 -o jsonpath='{.data.value}' | base64 -d)
kubectl --kubeconfig=$KUBECONFIG logs -n kube-system -l app=cloudstack-ccm
```

### CSI driver DaemonSet failing on nodes

The CSI hostPath `/var/mnt/local-storage` doesn't exist on CAPC images. Patch the `csi-driver` patch in `30-clusterclass-fullstack.yaml`:

```bash
# Fix: replace /var/mnt/local-storage with /var/lib/kubelet in the CSI node DaemonSet
sed -i 's|/var/mnt/local-storage|/var/lib/kubelet|g' manifests/30-clusterclass-fullstack.yaml
kubectl apply -f manifests/30-clusterclass-fullstack.yaml --force-conflicts
```

### Changing cluster size

No template edits needed — just change replicas in the Cluster YAML:

```bash
# Scale workers from 3 to 5
kubectl edit cluster capc-cluster-2 -n capc-cluster-2
# Change spec.topology.workers.machines[0].replicas: 5

# CAPC provisions new VMs automatically; patches don't need re-application
```

## Next Steps

- [Fleet GitOps](./fleet.md) — Automate ongoing cluster management with Fleet
- [CAPC Upgrade Guide](../capc/capc-upgrade.md) — Upgrading CAPC and clusters
- [Rancher Turtles Guide](./turtles.md) — Managing providers declaratively
