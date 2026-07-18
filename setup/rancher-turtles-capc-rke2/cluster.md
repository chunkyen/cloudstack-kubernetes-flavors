# Deploy RKE2 Clusters on CloudStack via Rancher Turtles + CAPC

This guide covers provisioning **RKE2** clusters on **CloudStack** using **Cluster API** with **Rancher Turtles** — combining the CloudStack infrastructure provider (CAPC) with the RKE2 bootstrap/control-plane provider (CAPRKE2).

> **Prerequisites assumed:** Rancher + Turtles + CAPC already deployed.
> See [`rancher.md`](../rancher-turtles-capc/rancher.md) for Rancher deployment and [`turtles.md`](../rancher-turtles-capc/turtles.md) for Turtles + CAPC provider installation.

## Architecture

For the full Rancher Turtles + CAPC architecture breakdown — including layer-by-layer explanation, data flow, namespace layout, credential model, and ClusterResourceSet mechanics — see [Rancher+CAPC architecture](../../architecture/rancher-turtles-capc.md).

This guide focuses on the **RKE2-specific components** within that architecture:

```
Management Cluster (Rancher + Turtles + CAPC already running)
  │
  └─ CAPIProvider: rke2-bootstrap        ← you add this
  └─ CAPIProvider: rke2-control-plane    ← you add this
       │
       └─ RKE2ControlPlane (replaces KubeadmControlPlane)
            │
            ├─ CloudStackMachineTemplate (control-plane VM spec)
            │      └─ CloudStack VM → RKE2 tarball auto-installs → Calico
            │
            └─ RKE2ConfigTemplate (worker bootstrap config)
                   │
                   └─ MachineDeployment
                        └─ CloudStackMachineTemplate (worker VM spec)
                               └─ CloudStack VM → RKE2 agent joins → ready

Post-creation:
  └─ ClusterResourceSet applies CCM + CSI manifests to workload cluster
```

**Key architectural difference:**
- **Kubeadm CAPC:** VMs boot with a pre-baked CAPI image → cloud-init runs `kubeadm init/join` → you manually install CNI via CRS
- **RKE2 CAPC:** VMs boot with a standard OS template → CAPRKE2 pushes RKE2 tarball → RKE2 auto-installs containerd, etcd, CNI (Calico), CoreDNS, ingress → CCM + CSI applied via CRS

## What This Adds vs. Kubeadm-Based CAPC

| | Kubeadm (existing) | RKE2 (this guide) |
|---|---|---|
| Bootstrap provider | `kubeadm` | `rke2` |
| Control plane provider | `kubeadm` | `rke2` |
| **CNI** | Manual (Calico/Flannel/Cilium) | Built-in (Calico default; Canal, Cilium, Flannel, or none configurable) |
| CNI install | Helm chart or manifest | RKE2 auto-installs at bootstrap |
| `preKubeadmCommands` / `preRKE2Commands` | Available | Available |
| Provider ID | Same `cloudstack:///{{ ds.meta_data.instance_id }}` | Same |
| `guest.cpu.mode: host-passthrough` | Required for Calico x86-64-v2 | Required for Calico x86-64-v2 |
| CCM/CSI deployment | ClusterResourceSet or manual | Same |

Everything else — Rancher, Turtles, CAPC, CloudStack credentials, networking, ClusterResourceSet mechanics — is identical. See [Rancher+CAPC architecture](../../architecture/rancher-turtles-capc.md#bootstrap-provider-choice-kubeadm-vs-rke2) for a detailed comparison of why to choose RKE2 over kubeadm.

## Step 1: Install CAPRKE2 Providers

Create the `CAPIProvider` resources for the RKE2 bootstrap and control-plane providers:

```yaml
# rke2-providers.yaml
apiVersion: turtles-capi.cattle.io/v1alpha1
kind: CAPIProvider
metadata:
  name: rke2-bootstrap
spec:
  name: rke2
  type: bootstrap
---
apiVersion: turtles-capi.cattle.io/v1alpha1
kind: CAPIProvider
metadata:
  name: rke2-control-plane
spec:
  name: rke2
  type: control-plane
```

```bash
kubectl apply -f rke2-providers.yaml
```

Wait for both providers to become `Ready`:

```bash
kubectl get capiproviders
```

## Step 2: Create the Cluster Namespace and Credentials

Identical to the kubeadm-based CAPC workflow:

```bash
kubectl create namespace capc-rke2-cluster-1
```

Create the CloudStack credentials secret:

```bash
kubectl create secret generic cloudstack-credentials \
  -n capc-rke2-cluster-1 \
  --from-literal=api-key="<your-api-key>" \
  --from-literal=secret-key="<your-secret-key>" \
  --from-literal=api-url="http://<cloudstack-host>:8080/client/api"
```

## Step 3: Deploy the Cluster (with CCM + CSI via ClusterResourceSet)

This step deploys three resources together — the cluster itself plus the ClusterResourceSet that automatically installs CCM and CSI after the cluster comes up.

```bash
# Deploy cluster + ConfigMap + ClusterResourceSet together
kubectl apply -f manifests/10-minimal-cluster.yaml \
  -f manifests/20-ccm-csi-configmap.yaml \
  -f manifests/21-clusterresourceset.yaml
```

Wait for the cluster to become ready:

```bash
kubectl get cluster -n capc-rke2-cluster-1 -w
kubectl get machines -n capc-rke2-cluster-1 -w
```

The `Cluster` manifest includes the label `capc-rke2-ccm-csi: "true"` which matches the `ClusterResourceSet` selector. Once the cluster's API server is reachable, the ClusterResourceSet controller automatically applies CCM and CSI to the workload cluster — no manual post-step required.

### Key details in the manifest

| Field | Value | Why |
|---|---|---|
| `provider-id` | `cloudstack:///{{ ds.meta_data.instance_id }}` | Must match CAPC's provider ID format. No quotes around the template expression. |
| `guest.cpu.mode` | `host-passthrough` | Required because Calico (bundled with RKE2 ≥v1.30) needs x86-64-v2 CPU instructions. Without this, `tigera-operator` crashes with `Fatal glibc error: CPU does not support x86-64-v2`. |
| `cni` | `calico` | RKE2's built-in CNI. Calico is installed as a Helm chart by RKE2 automatically. |
| `registrationMethod` | `internal-first` | Nodes register via internal IP first, falling back to external. |
| `preRKE2Commands` | `sleep 30` | Gives CloudStack time to fully provision the VM before RKE2 bootstrap starts. |
| `capc-rke2-ccm-csi: "true"` | Cluster label | Matches the `ClusterResourceSet` selector so CCM + CSI are auto-deployed. |

## Step 4: Create the CloudStack Secret (required for CCM + CSI)

The upstream CCM and CSI manifests reference a secret named `cloudstack-secret` in `kube-system`. Create this on the workload cluster **after** the control plane is reachable:

```bash
# First, get the workload kubeconfig
kubectl get secret capc-rke2-cluster-1-kubeconfig -n capc-rke2-cluster-1 \
  -o jsonpath='{.data.value}' | base64 -d > workload-kubeconfig

# Create the cloudstack-secret in kube-system on the workload cluster
KUBECONFIG=workload-kubeconfig kubectl create secret generic cloudstack-secret -n kube-system \
  --from-literal=cloud-config="[Global]
api-url = http://<cloudstack-host>:8080/client/api
api-key = <your-api-key>
secret-key = <your-secret-key>"
```

The ClusterResourceSet controller detects the cluster is ready and automatically applies CCM + CSI to the workload cluster. Once the secret exists, the CCM and CSI pods can authenticate with CloudStack.

## Verification

```bash
# Get the workload kubeconfig
kubectl get secret capc-rke2-cluster-1-kubeconfig -n capc-rke2-cluster-1 \
  -o jsonpath='{.data.value}' | base64 -d > workload-kubeconfig

# Check nodes
KUBECONFIG=workload-kubeconfig kubectl get nodes -o wide

# Check all pods
KUBECONFIG=workload-kubeconfig kubectl get pods -A
```

Expected result: 3 nodes (1 control-plane + 2 workers), all `Ready`, with Calico, CoreDNS, CCM, and CSI running.

## Troubleshooting

### Calico crashes with `Fatal glibc error: CPU does not support x86-64-v2`

**Cause:** The Calico version bundled with RKE2 ≥v1.30 requires x86-64-v2 CPU instructions, but CloudStack VMs default to QEMU's virtual CPU model which may not expose these features.

**Fix:** Add `details: guest.cpu.mode: host-passthrough` to both `CloudStackMachineTemplate` resources (control-plane and worker). This passes the host CPU features through to the guest.

### Workers not created

The `MachineSet` shows `desired: 2, current: 0`. CAPRKE2 waits for the control plane to be fully healthy before provisioning workers. Check:

```bash
kubectl get rke2controlplane -n capc-rke2-cluster-1 -o yaml
```

If the control plane is `NotReady` due to Calico, apply the host-passthrough fix above, delete the cluster, and recreate.

### Provider ID format

The `provider-id` must be `cloudstack:///{{ ds.meta_data.instance_id }}` — no quotes around the template expression. If quotes are present, the literal string `{{ ds.meta_data.instance_id }}` is used instead of the resolved value.

## Cleanup

```bash
# Let CAPI/CAPC handle deletion gracefully
kubectl delete cluster capc-rke2-cluster-1 -n capc-rke2-cluster-1

# If the cluster gets stuck in Deleting, remove the turtles-capi finalizer:
kubectl patch cluster capc-rke2-cluster-1 -n capc-rke2-cluster-1 \
  --type merge -p '{"metadata":{"finalizers":[]}}'
```

Do **not** use `--force` or manually destroy VMs — let CAPI/CAPC orchestrate the teardown.

## References

- [CAPC Documentation](https://github.com/apache/cluster-api-provider-cloudstack)
- [CAPRKE2 Documentation](https://caprke2.docs.rancher.com/)
- [Rancher Turtles](https://turtles.docs.rancher.com/)
- [CloudStack CCM](https://github.com/apache/cloudstack-kubernetes-provider)
- [CloudStack CSI Driver](https://github.com/cloudstack/cloudstack-csi-driver)
