# Full-Stack Onboarding — CNI + CCM + CSI in One Shot

Deploy a CAPC cluster and get **CNI** (networking), **CCM** (CloudStack Kubernetes Provider for LoadBalancer services and node labels), and **CSI** (persistent storage) all installed automatically — no manual follow-up steps. This is the CAPC equivalent of CKS's "one ISO, everything works" experience.

This uses **ClusterResourceSet**, a CAPI-native mechanism that applies resources to a workload cluster after it's provisioned. This is the approach recommended by the [Rancher Turtles documentation](https://turtles.docs.rancher.com/turtles/stable/en/user/applications.html) for installing bootstrap applications (CNI, CCM, CSI) on Kubeadm-based CAPI clusters.

> **ℹ️ RKE2 vs Kubeadm**
>
> RKE2 clusters can specify CNI directly in the `RKE2ControlPlane` manifest (`serverConfig.cni: calico`). CAPC uses **Kubeadm**, which has no built-in CNI — so `ClusterResourceSet` is the recommended way to automate CNI/CCM/CSI installation.

> **⚠️ ClusterResourceSet is namespace-scoped.** All resources (ConfigMaps, Secrets) and clusters referenced in the `ClusterResourceSet` spec must be in the **same namespace** as the `ClusterResourceSet` itself.

## Architecture

```
Management Cluster (Rancher + Turtles)
│
├── ClusterResourceSet CRD — deployed by Turtles/core CAPI
│
├── ConfigMap: full-stack-manifests
│   ├── cni/calico.yaml          # CNI networking
│   ├── ccm/cloudstack-secret    # CloudStack credentials secret
│   ├── ccm/cloudstack-ccm.yaml  # CloudStack Kubernetes Provider
│   └── csi/
│       ├── cloudstack-secret    # CloudStack credentials secret (CSI uses same)
│       ├── snapshot-crd.yaml    # VolumeSnapshot CRDs
│       ├── csi-driver.yaml      # CSI driver controller + node
│       └── storageclass.yaml    # StorageClass
│
├── ClusterResourceSet: capc-cluster-1-full-stack
│   ├── clusterSelector: app=capc-cluster-1
│   └── resourceSelector: cluster.x-k8s.io/cluster-name = capc-cluster-1
│
└── Workload Cluster (VMs on CloudStack)
    ├── CNI pods running in kube-system
    ├── CCM pods running in kube-system
    └── CSI pods running in kube-system
```

## Prerequisites

- Rancher Turtles + CAPC deployed and healthy (Phase 1 complete)
- Workload cluster created via CAPI (Phase 2 — cluster exists and nodes are Ready)
- CloudStack disk offering available for CSI
- `kubectl` configured with the **management cluster** (Rancher), not the workload cluster

> **Note:** ClusterResourceSet CRDs ship with core CAPI. Turtles deploys them automatically, so no extra setup is needed.

## Step 1: Prepare the CloudStack Credentials Secret

Both the CCM and CSI driver need CloudStack API credentials. Create a single secret that both components will reference.

```yaml
# cloudstack-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: cloudstack-credentials
  namespace: capc-cluster-1    # must match your cluster namespace
type: Opaque
stringData:
  api-url: "http://<management-server>:8080/client/api"
  api-key: "***"
  secret-key: "<your-secret-key>"
  verify-ssl: "false"
```

```bash
kubectl apply -f cloudstack-secret.yaml -n capc-cluster-1
```

## Step 2: Create the Full-Stack ConfigMap

Package all three components (CNI + CCM + CSI) into a single ConfigMap. Each manifest is stored as a separate key so ClusterResourceSet can apply them in order.

> **ℹ️ Raw YAML vs HelmChart CRD**
>
> The [Turtles documentation](https://turtles.docs.rancher.com/turtles/stable/en/user/applications.html) shows an alternative approach using `HelmChart` CRDs (`helm.cattle.io/v1`) inside the ConfigMap instead of raw YAML. This works well when your component has a Helm chart (e.g. Azure CCM, Cilium). For CloudStack CCM/CSI which are distributed as raw YAML manifests, inline raw YAML is the practical approach. Both are valid — CRS applies whatever is in the ConfigMap.

```yaml
# full-stack-manifests.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: full-stack-manifests
  namespace: capc-cluster-1
  labels:
    cluster.x-k8s.io/cluster-name: capc-cluster-1
    full-stack: "true"
data:
  # ─── CNI: Calico ──────────────────────────────────────────────
  cni/calico.yaml: |
    apiVersion: policy/v1
    kind: PodDisruptionBudget
    metadata:
      name: calico-pdb
      namespace: kube-system
    spec:
      minAvailable: 75%
      selector:
        matchLabels:
          k8s-app: calico-node
    ---
    apiVersion: v1
    kind: ServiceAccount
    metadata:
      name: calico-node
      namespace: kube-system
      labels:
        k8s-app: calico-node
    ---
    # ... (see Appendix for full Calico manifest) ...
    # For brevity, use the full manifest from:
    # https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml

  # ─── CCM: CloudStack Kubernetes Provider ──────────────────────
  ccm/cloudstack-secret.yaml: |
    apiVersion: v1
    kind: Secret
    metadata:
      name: cloudstack-secret
      namespace: kube-system
    type: Opaque
    stringData:
      cloud-config: |
        [Global]
        api-url = http://<management-server>:8080/client/api
        api-key = "***"
        secret-key = "<your-secret-key>"
        ssl-no-verify = "false"
  ccm/cloudstack-ccm.yaml: |
    # Full CCM manifest from:
    # https://raw.githubusercontent.com/apache/cloudstack-kubernetes-provider/main/deployment.yaml
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: cloudstack-ccm
      namespace: kube-system
      labels:
        app: cloudstack-ccm
    spec:
      replicas: 1
      selector:
        matchLabels:
          app: cloudstack-ccm
      template:
        metadata:
          labels:
            app: cloudstack-ccm
        spec:
          serviceAccountName: cloudstack-ccm
          containers:
            - name: cloudstack-ccm
              image: apachecloudstack/cloudstack-kubernetes-provider:latest
              args:
                - --cloud-provider=external-cloudstack
                - --cloud-config=/etc/kubernetes/cloud-config/cloud-config
              volumeMounts:
                - name: cloud-config
                  mountPath: /etc/kubernetes/cloud-config
          volumes:
            - name: cloud-config
              secret:
                secretName: cloudstack-secret

  # ─── CSI: CloudStack CSI Driver ───────────────────────────────
  csi/cloudstack-secret.yaml: |
    apiVersion: v1
    kind: Secret
    metadata:
      name: cloudstack-secret
      namespace: kube-system
    type: Opaque
    stringData:
      cloud-config: |
        [Global]
        api-url = http://<management-server>:8080/client/api
        api-key = "***"
        secret-key = "<your-secret-key>"
        ssl-no-verify = "false"
  csi/snapshot-crd.yaml: |
    # VolumeSnapshot CRDs from:
    # https://github.com/kubernetes-csi/external-snapshotter/tree/v8.3.0/client/config/crd
  csi/driver.yaml: |
    # Full CSI manifest from:
    # https://github.com/cloudstack/cloudstack-csi-driver/releases/latest/download/manifest.yaml
  csi/storageclass.yaml: |
    apiVersion: storage.k8s.io/v1
    kind: StorageClass
    metadata:
      name: cloudstack-ssd
    provisioner: csi.cloudstack.apache.org
    parameters:
      csi.cloudstack.apache.org/disk-offering-id: "<cloudstack-disk-offering-uuid>"
    volumeBindingMode: WaitForFirstConsumer
    reclaimPolicy: Delete
```

> **⚠️ For production use:** Don't inline full manifests in a ConfigMap. Instead, download the real manifests and store them as separate files, then create the ConfigMap with `kubectl create configmap`:
>
> ```bash
> kubectl create configmap full-stack-manifests \
>   --from-file=cni/calico.yaml=./calico.yaml \
>   --from-file=ccm/cloudstack-secret.yaml=./ccm-secret.yaml \
>   --from-file=ccm/cloudstack-ccm.yaml=./ccm-deployment.yaml \
>   --from-file=csi/cloudstack-secret.yaml=./csi-secret.yaml \
>   --from-file=csi/snapshot-crd.yaml=./snapshot-crd.yaml \
>   --from-file=csi/driver.yaml=./csi-driver.yaml \
>   --from-file=csi/storageclass.yaml=./storageclass.yaml \
>   -n capc-cluster-1
> ```

## Step 3: Create the ClusterResourceSet

The ClusterResourceSet ties everything together — it watches for clusters with matching labels and applies all manifests from the ConfigMap.

```yaml
# full-stack-resource-set.yaml
apiVersion: addons.cluster.x-k8s.io/v1beta2
kind: ClusterResourceSet
metadata:
  name: capc-cluster-1-full-stack
  namespace: capc-cluster-1
spec:
  strategy: Reconcile
  clusterSelector:
    matchLabels:
      cluster.x-k8s.io/cluster-name: capc-cluster-1
  resources:
    - name: full-stack-manifests
      kind: ConfigMap
```

| Field | Value | Notes |
|---|---|---|
| `apiVersion` | `addons.cluster.x-k8s.io/v1beta2` | CAPI addons API group, not `cluster.x-k8s.io` |
| `strategy` | `Reconcile` | Re-applies if drift detected. `ApplyOnce` (default) applies only once. |
| `clusterSelector` | label selector | Selects clusters by label — must not be empty |
| `resources` | array of `{name, kind}` | References ConfigMaps/Secrets by name in the same namespace |

```bash
kubectl apply -f full-stack-resource-set.yaml
```

## Step 4: Label the Cluster

Add the label that triggers the ClusterResourceSet to fire:

```bash
kubectl label cluster capc-cluster-1 cluster.x-k8s.io/cluster-name=capc-cluster-1 --namespace=capc-cluster-1
```

## Step 5: Monitor Deployment

The ClusterResourceSet controller will detect the labeled cluster and apply all manifests. Watch the progress:

```bash
# Check ClusterResourceSet status
kubectl get clusterresourceset capc-cluster-1-full-stack -n capc-cluster-1 -o wide

# Check events
kubectl describe clusterresourceset capc-cluster-1-full-stack -n capc-cluster-1

# Check workload cluster resources
KUBECONFIG=$(kubectl get secret capc-cluster-1-kubeconfig -n capc-cluster-1 \
  -o jsonpath='{.data.value}' | base64 -d) kubectl get pods -n kube-system
```

**Expected output:**
```
NAME                                    READY   STATUS
calico-node-xxxxx                       1/1     Running
cloudstack-ccm-xxxxx                    1/1     Running
cloudstack-csi-controller-xxxxx         5/5     Running
cloudstack-csi-node-xxxxx               3/3     Running
```

## Step 6: Verify All Components

```bash
# Get workload kubeconfig
KUBECONFIG=$(kubectl get secret capc-cluster-1-kubeconfig -n capc-cluster-1 \
  -o jsonpath='{.data.value}' | base64 -d)

# Nodes ready?
kubectl --kubeconfig=$KUBECONFIG get nodes

# CNI running?
kubectl --kubeconfig=$KUBECONFIG get pods -A | grep -E 'calico|cilium'

# CCM running?
kubectl --kubeconfig=$KUBECONFIG get pods -n kube-system | grep cloudstack-ccm
kubectl --kubeconfig=$KUBECONFIG get nodes --show-labels | grep topology

# CSI running?
kubectl --kubeconfig=$KUBECONFIG get pods -A | grep cloudstack-csi
kubectl --kubeconfig=$KUBECONFIG get storageclass

# Test PVC provisioning
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

## Cilium Alternative

If you prefer Cilium over Calico, replace the CNI manifest in the ConfigMap:

```yaml
data:
  cni/cilium.yaml: |
    # Full Cilium manifest from:
    # https://raw.githubusercontent.com/cilium/cilium/main/install/kubernetes/quickstep.yaml
```

Or create a separate ConfigMap and ClusterResourceSet per CNI, then label your cluster accordingly (`cni=calico` vs `cni=cilium`).

## Quick Reference — All-in-One Apply Script

```bash
#!/bin/bash
set -euo pipefail

CLUSTER_NS="capc-cluster-1"
CLUSTER_NAME="capc-cluster-1"
MANAGEMENT_SERVER="http://<management-server>:8080/client/api"
API_KEY="***"
SECRET_KEY="<your-secret-key>"
DISK_OFFERING_UUID="<disk-offering-uuid>"

# 1. Create namespace
kubectl create namespace "$CLUSTER_NS" 2>/dev/null || true

# 2. Create CloudStack credentials secret
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cloudstack-credentials
  namespace: $CLUSTER_NS
type: Opaque
stringData:
  api-url: "$MANAGEMENT_SERVER"
  api-key: "$API_KEY"
  secret-key: "$SECRET_KEY"
  verify-ssl: "false"
EOF

# 3. Create CCM secret (for both CCM and CSI)
KUBECONFIG=$(kubectl get secret ${CLUSTER_NAME}-kubeconfig -n $CLUSTER_NS \
  -o jsonpath='{.data.value}' | base64 -d)

kubectl --kubeconfig=$KUBECONFIG apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cloudstack-secret
  namespace: kube-system
type: Opaque
stringData:
  cloud-config: |
    [Global]
    api-url = $MANAGEMENT_SERVER
    api-key = "$API_KEY"
    secret-key = "$SECRET_KEY"
    ssl-no-verify = "false"
EOF

# 4. Download and apply manifests
curl -sSL https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml \
  | kubectl --kubeconfig=$KUBECONFIG apply -f -

curl -sSL https://raw.githubusercontent.com/apache/cloudstack-kubernetes-provider/main/deployment.yaml \
  | kubectl --kubeconfig=$KUBECONFIG apply -f -

kubectl --kubeconfig=$KUBECONFIG apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: cloudstack-ssd
provisioner: csi.cloudstack.apache.org
parameters:
  csi.cloudstack.apache.org/disk-offering-id: "$DISK_OFFERING_UUID"
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
EOF

# 5. Apply CSI driver (patched for CAPC images)
curl -sSL https://github.com/cloudstack/cloudstack-csi-driver/releases/latest/download/manifest.yaml \
  | sed 's|/var/mnt/local-storage|/var/lib/kubelet|g' \
  | kubectl --kubeconfig=$KUBECONFIG apply -f -

# 6. Wait for everything to be ready
kubectl --kubeconfig=$KUBECONFIG wait --for=condition=ready pod -l k8s-app=calico-node -n kube-system --timeout=300s
kubectl --kubeconfig=$KUBECONFIG wait --for=condition=ready pod -l app=cloudstack-ccm -n kube-system --timeout=300s
kubectl --kubeconfig=$KUBECONFIG wait --for=condition=ready pod -l app=cloudstack-csi -n kube-system --timeout=300s

echo "✅ All components deployed successfully!"
```

## Troubleshooting

### ClusterResourceSet stuck in `Applying` state

```bash
# Check what's being applied
kubectl describe clusterresourceset capc-cluster-1-full-stack -n capc-cluster-1

# Check if the ConfigMap is readable by the controller
kubectl get configmap full-stack-manifests -n capc-cluster-1 -o yaml
```

### CCM not creating LoadBalancer services

```bash
# Verify CCM can reach CloudStack API
KUBECONFIG=$(kubectl get secret capc-cluster-1-kubeconfig -n capc-cluster-1 \
  -o jsonpath='{.data.value}' | base64 -d)
kubectl --kubeconfig=$KUBECONFIG logs -n kube-system -l app=cloudstack-ccm

# Test CloudStack API connectivity from CCM pod
kubectl --kubeconfig=$KUBECONFIG exec -it -n kube-system -l app=cloudstack-ccm -- \
  curl -v http://<management-server>:8080/client/api?command=listZones
```

### CSI driver DaemonSet failing on nodes

The CSI driver's hostPath for `/var/mnt/local-storage` doesn't exist on CAPC images. See the [CSI Driver Compatibility](../cloudstack-csi-driver.md#cks-vs-capccapm-image-compatibility) section for the fix.

### CNI pods not scheduling

```bash
# Check node readiness
KUBECONFIG=$(kubectl get secret capc-cluster-1-kubeconfig -n capc-cluster-1 \
  -o jsonpath='{.data.value}' | base64 -d)
kubectl --kubeconfig=$KUBECONFIG get nodes -o wide

# Check if CNI was applied (ClusterResourceSet runs once)
kubectl --kubeconfig=$KUBECONFIG get pods -A | grep calico
```

## Comparison: CKS vs CAPC Full-Stack Onboarding

| Component | CKS | CAPC (manual) | CAPC + ClusterResourceSet |
|-----------|-----|---------------|--------------------------|
| **CNI** | ✅ Baked into ISO | Manual `kubectl apply` | ✅ Automatic |
| **CCM** | ✅ Baked into ISO | Manual `kubectl apply` | ✅ Automatic |
| **CSI** | ✅ Baked into ISO | Manual `kubectl apply` | ✅ Automatic |
| **Dashboard** | ✅ Baked into ISO | Manual install | Optional (add to ConfigMap) |
| **Total steps after cluster creation** | 0 | 3+ | 1 (label the cluster) |

## Next Steps

- [Fleet GitOps](./fleet.md) — Automate cluster management with Fleet
- [CAPC Upgrade Guide](../capc/capc-upgrade.md) — Upgrading CAPC and clusters
- [CKS Setup Guide](../cks/cks.md) — For comparison, see how CKS handles this natively
