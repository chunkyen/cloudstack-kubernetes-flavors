# CAPC + RKE2 on CloudStack via Rancher Turtles

Deploy **RKE2** clusters on **CloudStack** using **Cluster API** with **Rancher Turtles** — combining the CloudStack infrastructure provider (CAPC) with the RKE2 bootstrap/control-plane provider (CAPRKE2).

## Architecture

```
Rancher Manager
  └─ Turtles (CAPI operator)
       ├─ CAPC (infrastructure) — provisions CloudStack VMs
       ├─ CAPRKE2 bootstrap — installs RKE2 on VMs
       └─ CAPRKE2 control-plane — manages RKE2 control plane
            └─ ClusterResourceSet — deploys CCM + CSI post-creation
```

## Prerequisites

- **Rancher Manager** with **Turtles** installed and configured
- **CAPC provider** already installed via `CAPIProvider` CRD
- CloudStack credentials secret in the target namespace
- A CloudStack network with `DefaultNetworkOfferingforKubernetesService`
- Standard Ubuntu/Rocky Linux template (e.g. `capc-ubuntu24-1.35`)
- Compute offerings for control plane and worker nodes

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

```bash
kubectl create namespace capc-rke2-cluster-1
```

Create the CloudStack credentials secret (used by CAPC to provision VMs):

```bash
kubectl create secret generic cloudstack-credentials \
  -n capc-rke2-cluster-1 \
  --from-literal=api-key="<your-api-key>" \
  --from-literal=secret-key="<your-secret-key>" \
  --from-literal=api-url="http://<cloudstack-host>:8080/client/api"
```

## Step 3: Deploy the Cluster

```yaml
# 10-minimal-cluster.yaml
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: capc-rke2-cluster-1
  namespace: capc-rke2-cluster-1
  labels:
    cluster-api.cattle.io/rancher-auto-import: "true"
spec:
  clusterNetwork:
    pods:
      cidrBlocks:
        - "10.168.0.0/16"
    serviceDomain: cluster.local
  controlPlaneRef:
    apiVersion: controlplane.cluster.x-k8s.io/v1beta2
    kind: RKE2ControlPlane
    name: capc-rke2-cluster-1-control-plane
  infrastructureRef:
    apiVersion: infrastructure.cluster.x-k8s.io/v1beta3
    kind: CloudStackCluster
    name: capc-rke2-cluster-1
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta3
kind: CloudStackCluster
metadata:
  name: capc-rke2-cluster-1
  namespace: capc-rke2-cluster-1
spec:
  controlPlaneEndpoint:
    host: "192.168.200.60"   # <-- static IP for the control plane
    port: 6443
  failureDomains:
    - name: "cyz1"
      zone:
        name: "cyz1"
        network:
          name: "capc-rke2-net"
          offering: DefaultNetworkOfferingforKubernetesService
      acsEndpoint:
        name: cloudstack-credentials
        namespace: capc-rke2-cluster-1
  syncWithACS: true
---
apiVersion: controlplane.cluster.x-k8s.io/v1beta2
kind: RKE2ControlPlane
metadata:
  name: capc-rke2-cluster-1-control-plane
  namespace: capc-rke2-cluster-1
spec:
  replicas: 1
  version: v1.36.2+rke2r1
  agentConfig:
    kubelet:
      extraArgs:
        - provider-id=cloudstack:///{{ ds.meta_data.instance_id }}
    nodeName: '{{ ds.meta_data.local_hostname }}'
  serverConfig:
    cni: calico
  registrationMethod: internal-first
  rolloutStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
  machineTemplate:
    spec:
      infrastructureRef:
        apiGroup: infrastructure.cluster.x-k8s.io
        kind: CloudStackMachineTemplate
        name: capc-rke2-cluster-1-control-plane
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta3
kind: CloudStackMachineTemplate
metadata:
  name: capc-rke2-cluster-1-control-plane
  namespace: capc-rke2-cluster-1
spec:
  template:
    spec:
      offering:
        name: "kube control"
      sshKey: "cylabnb-k1"
      template:
        name: "capc-ubuntu24-1.35"
      details:
        guest.cpu.mode: host-passthrough   # ⚠️ Required for Calico x86-64-v2
---
apiVersion: cluster.x-k8s.io/v1beta1
kind: MachineDeployment
metadata:
  name: capc-rke2-cluster-1-md-0
  namespace: capc-rke2-cluster-1
spec:
  clusterName: capc-rke2-cluster-1
  replicas: 2
  selector:
    matchLabels: null
  template:
    spec:
      bootstrap:
        configRef:
          apiVersion: bootstrap.cluster.x-k8s.io/v1beta2
          kind: RKE2ConfigTemplate
          name: capc-rke2-cluster-1-md-0
      clusterName: capc-rke2-cluster-1
      infrastructureRef:
        apiVersion: infrastructure.cluster.x-k8s.io/v1beta3
        kind: CloudStackMachineTemplate
        name: capc-rke2-cluster-1-md-0
      version: v1.36.2+rke2r1
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta3
kind: CloudStackMachineTemplate
metadata:
  name: capc-rke2-cluster-1-md-0
  namespace: capc-rke2-cluster-1
spec:
  template:
    spec:
      offering:
        name: "kube worker1"
      sshKey: "cylabnb-k1"
      template:
        name: "capc-ubuntu24-1.35"
      details:
        guest.cpu.mode: host-passthrough   # ⚠️ Required for Calico x86-64-v2
---
apiVersion: bootstrap.cluster.x-k8s.io/v1beta2
kind: RKE2ConfigTemplate
metadata:
  name: capc-rke2-cluster-1-md-0
  namespace: capc-rke2-cluster-1
spec:
  template:
    spec:
      preRKE2Commands:
        - sleep 30
      agentConfig:
        kubelet:
          extraArgs:
            - provider-id=cloudstack:///{{ ds.meta_data.instance_id }}
        nodeName: '{{ ds.meta_data.local_hostname }}'
```

Apply:

```bash
kubectl apply -f 10-minimal-cluster.yaml
```

### Key details in the manifest

| Field | Value | Why |
|---|---|---|
| `provider-id` | `cloudstack:///{{ ds.meta_data.instance_id }}` | Must match CAPC's provider ID format. No quotes around the template expression. |
| `guest.cpu.mode` | `host-passthrough` | Required because Calico (bundled with RKE2 ≥v1.30) needs x86-64-v2 CPU instructions. Without this, `tigera-operator` crashes with `Fatal glibc error: CPU does not support x86-64-v2`. |
| `cni` | `calico` | RKE2's built-in CNI. Calico is installed as a Helm chart by RKE2 automatically. |
| `registrationMethod` | `internal-first` | Nodes register via internal IP first, falling back to external. |
| `preRKE2Commands` | `sleep 30` | Gives CloudStack time to fully provision the VM before RKE2 bootstrap starts. |

## Step 4: Deploy CCM and CSI via ClusterResourceSet

The official upstream manifests are at:
- **CCM:** https://github.com/apache/cloudstack-kubernetes-provider (image: `apache/cloudstack-kubernetes-provider:v1.2.0`)
- **CSI:** https://github.com/cloudstack/cloudstack-csi-driver (image: `ghcr.io/cloudstack/cloudstack-csi-driver:main`)

### 4a. Create the CloudStack secret in the workload cluster

The official manifests expect a secret named `cloudstack-secret` in `kube-system`:

```bash
kubectl create secret generic cloudstack-secret -n kube-system \
  --from-literal=cloud-config="[Global]
api-url = http://<cloudstack-host>:8080/client/api
api-key = <your-api-key>
secret-key = <your-secret-key>
ssl-no-verify = false"
```

### 4b. Create the ConfigMap with all manifests

```yaml
# 20-ccm-csi-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: capc-rke2-cluster-1-post-deploy
  namespace: capc-rke2-cluster-1
data:
  ccm.yaml: |
    # Full CCM manifest from upstream deployment.yaml
    # (ServiceAccount, ClusterRole, ClusterRoleBinding, RoleBinding, Deployment)
    # Image: apache/cloudstack-kubernetes-provider:v1.2.0
    # Secret: cloudstack-secret (in kube-system)
    ...
  csi-rbac.yaml: |
    # CSI RBAC (ServiceAccounts, ClusterRoles, ClusterRoleBindings)
    ...
  csi-controller.yaml: |
    # CSI controller Deployment with sidecars
    # Image: ghcr.io/cloudstack/cloudstack-csi-driver:main
    ...
  csi-node.yaml: |
    # CSI node DaemonSet
    # Image: ghcr.io/cloudstack/cloudstack-csi-driver:main
    ...
  csidriver.yaml: |
    # CSIDriver resource
    ...
```

> **Note:** The full content of each file is the exact YAML from the upstream repos. See the [official CCM deployment.yaml](https://github.com/apache/cloudstack-kubernetes-provider/blob/main/deployment.yaml) and [CSI deploy/k8s/](https://github.com/cloudstack/cloudstack-csi-driver/tree/main/deploy/k8s) for the complete manifests.

### 4c. Create the ClusterResourceSet

```yaml
# 21-clusterresourceset.yaml
apiVersion: addons.cluster.x-k8s.io/v1beta2
kind: ClusterResourceSet
metadata:
  name: capc-rke2-cluster-1-ccm-csi
  namespace: capc-rke2-cluster-1
spec:
  clusterSelector:
    matchLabels:
      capc-rke2-ccm-csi: "true"
  resources:
    - kind: ConfigMap
      name: capc-rke2-cluster-1-post-deploy
  strategy: Reconcile
```

### 4d. Label the cluster and apply

```bash
kubectl label cluster capc-rke2-cluster-1 -n capc-rke2-cluster-1 capc-rke2-ccm-csi=true --overwrite
kubectl apply -f 20-ccm-csi-configmap.yaml
kubectl apply -f 21-clusterresourceset.yaml
```

The CRS controller will apply all manifests to the workload cluster automatically. Verify:

```bash
kubectl get clusterresourcesetbinding -n capc-rke2-cluster-1
# → resources[0].applied: true

# On the workload cluster:
kubectl get deployment -n kube-system cloud-controller-manager
kubectl get deployment -n kube-system cloudstack-csi-controller
kubectl get daemonset -n kube-system cloudstack-csi-node
kubectl get sc
```

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

### CCM fails with `configmaps "extension-apiserver-authentication" is forbidden`

The CCM needs the `extension-apiserver-authentication-reader` RoleBinding in `kube-system`. The official upstream `deployment.yaml` includes this — use the exact upstream manifest rather than a custom one.

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
