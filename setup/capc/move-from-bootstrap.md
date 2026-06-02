# Move From Bootstrap — Self-Managed CAPC Clusters

This guide explains how to use a lightweight bootstrap cluster (e.g., `kind`) to provision a workload cluster on CloudStack, then transfer full management control to the workload cluster itself. After the move, the workload cluster manages its own lifecycle independently — no external management plane required.

## Why Move From Bootstrap?

When you create a CAPC cluster using a bootstrap cluster:
- The bootstrap runs all CAPI controllers (CAPI, KubeadmControlPlane, CAPC)
- It provisions VMs on CloudStack and bootstraps K8s
- But the workload cluster has **no CAPI controllers** — it's just a plain K8s cluster

After moving:
- The workload cluster runs its own CAPC controllers
- All Cluster API CRDs live inside the workload cluster
- Deleting the bootstrap cluster has zero impact on workloads
- The cluster is fully self-managing and portable

## Architecture Before and After Move

### Before Move (Bootstrap Mode)

```
┌─────────────────────┐         ┌──────────────────────────┐
│   Bootstrap Cluster  │         │    Workload Cluster       │
│   (e.g., kind)      │         │    (on CloudStack VMs)    │
│                     │         │                           │
│  ┌───────────────┐  │         │  kube-apiserver           │
│  │ CAPI Controller│  │         │  kubelet + coredns        │
│  │ CAPC Controller│  │         │  calico/weave/cilium      │
│  │ Kubeadm CP Ctrl│  │         │                           │
│  └───────┬───────┘  │         │  (no CAPI controllers)    │
│          │          │         │                           │
│  Cluster CRD            │         │                           │
│  CloudStackCluster      │         │                           │
│  KubeadmControlPlane    │         │                           │
│  MachineDeployment      │         │                           │
└──────────┼─────────────┘         └──────────────────────────┘
           │
           │ CloudStack API calls
           ▼
   ┌─────────────────┐
   │ Apache CloudStack│
   │ (VMs, Network)  │
   └─────────────────┘
```

### After Move (Self-Managed)

```
┌─────────────────────┐         ┌──────────────────────────┐
│   Bootstrap Cluster  │         │    Workload Cluster       │
│   (e.g., kind)      │         │    (on CloudStack VMs)    │
│                     │         │                           │
│  (empty or deleted) │         │  ┌───────────────┐        │
│                     │         │  │ CAPI Controller│        │
│                     │         │  │ CAPC Controller│        │
│                     │         │  │ Kubeadm CP Ctrl│        │
│                     │         │  └───────────────┘        │
│                     │         │                           │
│                     │         │  Cluster CRD              │
│                     │         │  CloudStackCluster        │
│                     │         │  KubeadmControlPlane      │
│                     │         │  MachineDeployment        │
└─────────────────────┘         └───────────┬──────────────┘
                                            │
                                            │ CloudStack API calls
                                            ▼
                                    ┌─────────────────┐
                                    │ Apache CloudStack│
                                    │ (VMs, Network)  │
                                    └─────────────────┘
```

## Prerequisites

- A bootstrap cluster with CAPC installed and a workload cluster already created
- `clusterctl` v1.1.5+ on your workstation
- Access to the workload cluster's kubeconfig
- The same CloudStack credentials available in both clusters (secrets are moved)

## Step 1: Prepare the Target Cluster

First, install CAPC into the workload cluster so it has the controllers needed to manage itself:

```bash
# Get the workload cluster kubeconfig
cclusterctl get kubeconfig capc-cluster > target.kubeconfig

# Install CAPI + CAPC providers into the workload cluster
clusterctl --kubeconfig target.kubeconfig init \
  --infrastructure cloudstack
```

This installs:
- **Cluster API core** (`capi-system`)
- **Kubeadm bootstrap** (`capi-kubeadm-bootstrap-system`)
- **Kubeadm control plane** (`capi-kubeadm-control-plane-system`)
- **CAPC infrastructure provider** (`capc-system`)
- **cert-manager** (for webhook TLS)

Verify the providers are running:

```bash
kubectl --kubeconfig target.kubeconfig get pods -A
# Expected namespaces: capc-system, capi-system,
#   capi-kubeadm-bootstrap-system, capi-kubeadm-control-plane-system,
#   cert-manager
```

## Step 2: Move Cluster API Objects

Run the move command to transfer all CAPI objects from bootstrap to target:

```bash
clusterctl move --to-kubeconfig target.kubeconfig -v 10
```

This performs a multi-step transfer:

| Phase | What Happens |
|-------|-------------|
| **Discover** | Scans bootstrap for all Cluster API objects (Clusters, Machines, CloudStackCluster, secrets, etc.) |
| **Pause source** | Sets `spec.paused: true` on the source cluster to prevent controller reconciliation during transfer |
| **Create target namespaces** | Creates matching namespaces in the target cluster |
| **Copy CRDs + objects** | Transfers all 20+ objects (CloudStackCluster, CloudStackMachine, KubeadmControlPlane, MachineDeployment, secrets, configmaps) |
| **Delete from source** | Removes all copied objects from the bootstrap cluster |
| **Resume target** | Sets `spec.paused: false` on the target cluster, allowing controllers to take over |

Example output:
```
Discovering Cluster API objects
Cluster Count=1
KubeadmConfigTemplate Count=1
KubeadmControlPlane Count=1
MachineDeployment Count=1
CloudStackCluster Count=1
CloudStackMachine Count=2
Secret Count=8
Total objects Count=23
Moving Cluster API objects Clusters=1
...
Deleting objects from the source cluster
Resuming the target cluster
```

## Step 3: Verify Self-Management

Confirm the workload cluster now manages itself:

```bash
# Describe the cluster from the workload's perspective
clusterctl --kubeconfig target.kubeconfig describe cluster capc-cluster

# Expected output:
# NAME READY SEVERITY REASON SINCE MESSAGE
# Cluster/cloudstack-capi True 9m31s
# ├─ClusterInfrastructure - CloudStackCluster/cloudstack-capi
# ├─ControlPlane - KubeadmControlPlane/cloudstack-capi-control-plane True
# │ └─Machine/cloudstack-capi-control-plane-xhgb9 True
# └─Workers
#   └─MachineDeployment/cloudstack-capi-md-0 True
#     └─Machine/cloudstack-capi-md-0-75499bbf6-zqktd True
```

Check that CAPC controllers are running in the workload cluster:

```bash
kubectl --kubeconfig target.kubeconfig get pods -A
# Expected: capc-system/capc-controller-manager-xxx 1/1 Running
#           capi-system/capi-controller-manager-xxx 1/1 Running
#           capi-kubeadm-control-plane-system/... 1/1 Running
```

Verify CloudStack resources are managed by the workload cluster:

```bash
kubectl --kubeconfig target.kubeconfig get cloudstackcluster -A
kubectl --kubeconfig target.kubeconfig get cloudstackmachine -A
# Expected: instances showing READY=true with cloudstack:/// instance IDs
```

## Step 4: Clean Up Bootstrap (Optional)

Once self-management is confirmed, you can delete the bootstrap cluster:

```bash
# Delete the workload cluster first (if needed) — this now works from the workload itself
clusterctl --kubeconfig target.kubeconfig delete cluster capc-cluster

# Or delete the bootstrap entirely
kind delete cluster
```

## Important Notes

### Secrets Are Moved, Not Copied
All secrets (CloudStack credentials, SSH keys, service account tokens) are **transferred** from bootstrap to target — they no longer exist on the bootstrap after a successful move.

### CloudStack Resources Remain Intact
The VMs, networks, and load balancers created in CloudStack are **not affected** by the move. Only the Kubernetes objects that manage them are transferred.

### Network Connectivity
The workload cluster must be reachable from your workstation (for `clusterctl move`) and from its own controllers (which talk to the CloudStack API). Ensure:
- The control plane endpoint IP is accessible
- Security groups allow CloudStack API access from the workload VMs
- DNS resolution works for the CloudStack API endpoint

### Multiple Clusters
If you manage multiple clusters from one bootstrap, move them **one at a time**. Each `clusterctl move` transfers all objects for a single cluster.

## Use Cases

| Scenario | Bootstrap | After Move |
|----------|-----------|------------|
| **Development / POC** | kind (ephemeral) | Self-managed on CloudStack — delete kind, keep cluster |
| **CI/CD pipeline** | Temporary runner VM | Cluster manages itself in production |
| **Multi-env provisioning** | Single bootstrap for dev/staging/prod | Each env self-manages independently |
| **Disaster recovery** | Bootstrap lost | Workload still runs and manages itself (no single point of failure) |

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `clusterctl move` fails with "provider not found" | Ensure CAPC is initialized in the target cluster before running move |
| Target cluster shows `NotReady` after move | Check CAPC controller logs: `kubectl --kubeconfig target.kubeconfig logs -n capc-system deploy/capc-controller-manager` |
| CloudStackMachine instances show errors | Verify CloudStack credentials were transferred correctly (secrets are moved, not copied) |
| Move hangs or times out | Use `-v 10` for verbose output; check network connectivity between bootstrap and target kube-apiservers |
| Bootstrap cluster still shows objects after move | The move should delete all objects from source. If they remain, the move may have failed partway — check logs and retry |

## References

- [Cluster API: Move Command](https://cluster-api.sigs.k8s.io/clusterctl/commands/move.html)
- [CAPC Book: Move From Bootstrap](https://cluster-api-cloudstack.sigs.k8s.io/topics/mover)
- [GitHub: kubernetes-sigs/cluster-api-provider-cloudstack](https://github.com/kubernetes-sigs/cluster-api-provider-cloudstack)
