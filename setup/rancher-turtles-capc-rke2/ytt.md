# ytt — Template-Driven RKE2 Cluster Manifests

[ClusterClass](https://cluster-api.sigs.k8s.io/tasks/experimental/clusterclass/) is the
preferred way to manage multiple CAPI clusters from a single template. It lets you define
a reusable cluster shape and instantiate it with different variable values — no copy-paste,
no find-and-replace.

**However, ClusterClass is not currently usable with CAPC + CAPRKE2.** CAPC is missing
`CloudStackClusterTemplate` (the infrastructure cluster template type required by
ClusterClass). Until that's added upstream, you need an alternative.

## Alternatives to ClusterClass

| Tool | Approach | Best for |
|------|----------|----------|
| **Kustomize** | Patch-based overlays | Small variations, GitOps workflows |
| **ytt** (Carvel) | Data values + YAML overlays | Complex templating, reusable libraries |
| **Helm** | Go templates + chart packaging | Sharing, versioning, ecosystem |
| **envsubst / sed** | String replacement | Quick one-offs (fragile) |

The repo already has a [Kustomize-based approach](../capc/kustomize.md) for the CAPC +
kubeadm flavor. This document covers **ytt** for the CAPRKE2 flavor.

## What is ytt?

[ytt](https://carvel.dev/ytt/) is a YAML templating tool from the Carvel toolchain. Unlike
text-based templaters (Helm, envsubst), ytt operates on YAML **structure** — it understands
the document tree, so it never breaks indentation or produces invalid YAML.

Key concepts:

- **Data values** — variables defined in a separate YAML file
- **Templates** — YAML files with `#@` annotations for logic and substitution
- **Overlays** — surgical patches applied after templating (like Kustomize but more powerful)
- **Validation** — schema checking at compile time

## Example: ytt for CAPRKE2

### 1. Install ytt

```bash
# Via Carvel's installer
wget -O- https://carvel.dev/install.sh | bash

# Or direct download
curl -sL https://github.com/carvel-dev/ytt/releases/latest/download/ytt-linux-amd64 -o /usr/local/bin/ytt
chmod +x /usr/local/bin/ytt
```

### 2. Define data values

**`values.yaml`** — the variables that change per cluster:

```yaml
#@data/values
---
# Cluster identity
cluster_name: capc-rke2-cluster-1
namespace: capc-rke2-cluster-1

# RKE2
rke2_version: v1.36.2+rke2r1
control_plane_ip: 192.168.200.61
worker_count: 1

# CloudStack
zone_name: cyz1
network_name: capc-rke2-cluster-1-net
network_offering: DefaultNetworkOfferingforKubernetesService
control_plane_offering: "kube control"
worker_offering: "kube worker1"
ssh_key: cylabnb-k1
template_name: "ubuntu 24.04"

# Air-gap (optional — set to "" to skip)
artifact_server: ""

# CloudStack API credentials (used by CCM and CSI on the workload cluster)
cloudstack_api_url: http://YOUR_CLOUDSTACK_API_URL:8080/client/api
cloudstack_api_key: YOUR_API_KEY
cloudstack_secret_key: YOUR_SECRET_KEY
cloudstack_verify_ssl: "false"
```

### 3. Write the templates

The repo includes three ytt templates in `manifests/`:

| Template | Generates | Purpose |
|----------|-----------|---------|
| `cluster-template.yaml` | `10-cluster.yaml` | Cluster, CloudStackCluster, RKE2ControlPlane, MachineDeployment |
| `credentials-template.yaml` | `00-cloudstack-credentials.yaml` | Management cluster secret for CAPC |
| `cloudstack-secret-template.yaml` | `01-workload-secret.yaml` | Workload cluster secret for CCM/CSI |
| `storageclass-template.yaml` | `02-storageclass.yaml` | CSI StorageClass with disk offering UUID |

**`cluster-template.yaml`** — the reusable cluster definition (7 YAML documents):

```yaml
#@ load("@ytt:data", "data")
---
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: #@ data.values.cluster_name
  namespace: #@ data.values.namespace
  labels:
    cluster-api.cattle.io/rancher-auto-import: "true"
    capc-rke2-ccm-csi: "true"
spec:
  clusterNetwork:
    pods:
      cidrBlocks:
        - "10.168.0.0/16"
    serviceDomain: cluster.local
  controlPlaneRef:
    apiVersion: controlplane.cluster.x-k8s.io/v1beta2
    kind: RKE2ControlPlane
    name: #@ data.values.cluster_name + "-control-plane"
  infrastructureRef:
    apiVersion: infrastructure.cluster.x-k8s.io/v1beta3
    kind: CloudStackCluster
    name: #@ data.values.cluster_name
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta3
kind: CloudStackCluster
metadata:
  name: #@ data.values.cluster_name
  namespace: #@ data.values.namespace
spec:
  controlPlaneEndpoint:
    host: #@ data.values.control_plane_ip
    port: 6443
  failureDomains:
  - acsEndpoint:
      name: cloudstack-credentials
      namespace: #@ data.values.namespace
    name: #@ data.values.zone_name
    zone:
      name: #@ data.values.zone_name
      network:
        name: #@ data.values.network_name
        offering: #@ data.values.network_offering
  syncWithACS: true
---
apiVersion: controlplane.cluster.x-k8s.io/v1beta2
kind: RKE2ControlPlane
metadata:
  name: #@ data.values.cluster_name + "-control-plane"
  namespace: #@ data.values.namespace
spec:
  replicas: 1
  version: #@ data.values.rke2_version
  agentConfig:
    kubelet:
      extraArgs:
        - provider-id=cloudstack:///{{ ds.meta_data.instance_id }}
        - register-with-taints=node-role.kubernetes.io/control-plane=:NoSchedule
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
        name: #@ data.values.cluster_name + "-control-plane"
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta3
kind: CloudStackMachineTemplate
metadata:
  name: #@ data.values.cluster_name + "-control-plane"
  namespace: #@ data.values.namespace
spec:
  template:
    spec:
      offering:
        name: #@ data.values.control_plane_offering
      sshKey: #@ data.values.ssh_key
      template:
        name: #@ data.values.template_name
      details:
        guest.cpu.mode: host-passthrough
---
apiVersion: cluster.x-k8s.io/v1beta1
kind: MachineDeployment
metadata:
  name: #@ data.values.cluster_name + "-md-0"
  namespace: #@ data.values.namespace
spec:
  clusterName: #@ data.values.cluster_name
  replicas: #@ data.values.worker_count
  selector:
    matchLabels: null
  template:
    spec:
      bootstrap:
        configRef:
          apiVersion: bootstrap.cluster.x-k8s.io/v1beta2
          kind: RKE2ConfigTemplate
          name: #@ data.values.cluster_name + "-md-0"
      clusterName: #@ data.values.cluster_name
      infrastructureRef:
        apiVersion: infrastructure.cluster.x-k8s.io/v1beta3
        kind: CloudStackMachineTemplate
        name: #@ data.values.cluster_name + "-md-0"
      version: #@ data.values.rke2_version
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta3
kind: CloudStackMachineTemplate
metadata:
  name: #@ data.values.cluster_name + "-md-0"
  namespace: #@ data.values.namespace
spec:
  template:
    spec:
      offering:
        name: #@ data.values.worker_offering
      sshKey: #@ data.values.ssh_key
      template:
        name: #@ data.values.template_name
      details:
        guest.cpu.mode: host-passthrough
---
apiVersion: bootstrap.cluster.x-k8s.io/v1beta2
kind: RKE2ConfigTemplate
metadata:
  name: #@ data.values.cluster_name + "-md-0"
  namespace: #@ data.values.namespace
spec:
  template:
    spec:
      agentConfig:
        kubelet:
          extraArgs:
            - provider-id=cloudstack:///{{ ds.meta_data.instance_id }}
        nodeName: '{{ ds.meta_data.local_hostname }}'
```

**`credentials-template.yaml`** — management cluster secret for CAPC:

```yaml
#@ load("@ytt:data", "data")
---
apiVersion: v1
kind: Secret
metadata:
  name: cloudstack-credentials
  namespace: #@ data.values.namespace
type: Opaque
stringData:
  api-url: #@ data.values.cloudstack_api_url
  api-key: #@ data.values.cloudstack_api_key
  secret-key: #@ data.values.cloudstack_secret_key
  verify-ssl: #@ data.values.cloudstack_verify_ssl
```

**`cloudstack-secret-template.yaml`** — workload cluster secret for CCM/CSI:

```yaml
#@ load("@ytt:data", "data")
---
apiVersion: v1
kind: Secret
metadata:
  name: cloudstack-secret
  namespace: kube-system
type: Opaque
stringData:
  cloud-config: #@ "[Global]\napi-url = " + data.values.cloudstack_api_url + "\napi-key = " + data.values.cloudstack_api_key + "\nsecret-key = " + data.values.cloudstack_secret_key + "\nssl-no-verify = " + data.values.cloudstack_verify_ssl + "\n"
```

**`storageclass-template.yaml`** — CSI StorageClass with disk offering UUID:

```yaml
#@ load("@ytt:data", "data")
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: cloudstack-standard
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: csi.cloudstack.apache.org
parameters:
  csi.cloudstack.apache.org/disk-offering-id: #@ data.values.disk_offering_id
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
```

### 4. Generate the final manifests

```bash
# Cluster resources
ytt -f cluster-template.yaml -f values.yaml > 10-cluster.yaml

# Management cluster credentials
ytt -f credentials-template.yaml -f values.yaml > 00-cloudstack-credentials.yaml

# Workload cluster secret (for CCM/CSI)
ytt -f cloudstack-secret-template.yaml -f values.yaml > 01-workload-secret.yaml

# CSI StorageClass
ytt -f storageclass-template.yaml -f values.yaml > 02-storageclass.yaml
```

### 5. Deploy

```bash
# Create namespace and credentials
kubectl create namespace capc-rke2-cluster-1
kubectl apply -f 00-cloudstack-credentials.yaml

# Deploy cluster + CCM/CSI ConfigMap + CRS
kubectl apply -f 10-cluster.yaml \
  -f 20-ccm-csi-configmap.yaml \
  -f 21-clusterresourceset.yaml

# After the cluster is up, apply the workload secret and storage class
kubectl get secret capc-rke2-cluster-1-kubeconfig -n capc-rke2-cluster-1 \
  -o jsonpath='{.data.value}' | base64 -d > kubeconfig
KUBECONFIG=kubeconfig kubectl apply -f 01-workload-secret.yaml
KUBECONFIG=kubeconfig kubectl apply -f 02-storageclass.yaml
```

### 6. Create a second cluster

Just copy `values.yaml`, edit the variables, and re-run:

```bash
cp values.yaml values-cluster2.yaml
# Edit values-cluster2.yaml: change cluster_name, control_plane_ip, etc.

ytt -f cluster-template.yaml -f values-cluster2.yaml > 10-cluster2.yaml
ytt -f credentials-template.yaml -f values-cluster2.yaml > 00-creds2.yaml
ytt -f cloudstack-secret-template.yaml -f values-cluster2.yaml > 01-workload-secret2.yaml

kubectl create namespace capc-rke2-cluster-2
kubectl apply -f 00-creds2.yaml
kubectl apply -f 10-cluster2.yaml \
  -f 20-ccm-csi-configmap.yaml \
  -f 21-clusterresourceset.yaml
```

## Why ClusterClass is preferred (and why it doesn't work here)

**ClusterClass** is the native CAPI mechanism for template-driven clusters. It offers:

- **Server-side templating** — the management cluster holds the template; no client-side
  tool needed
- **Variable validation** — schemas are defined in the ClusterClass CRD, caught at admission
- **Topology-aware updates** — changing a variable triggers a controlled rollout
- **No generated files** — no intermediate YAML to store or diff

**Why it doesn't work with CAPC + CAPRKE2 today:**

| Required template type | Status |
|---|---|
| `RKE2ControlPlaneTemplate` | ✅ Exists in CAPRKE2 |
| `RKE2ConfigTemplate` | ✅ Exists in CAPRKE2 |
| `CloudStackMachineTemplate` | ✅ Exists in CAPC |
| `CloudStackClusterTemplate` | ❌ **Missing** — not defined in CAPC API types |

Without `CloudStackClusterTemplate`, you cannot define a complete ClusterClass. The
infrastructure cluster resource (`CloudStackCluster`) has no template variant, so
ClusterClass has nothing to reference for the infrastructure section.

Until CAPC adds this type, tools like **ytt** (or Kustomize) fill the gap with
client-side templating.

## ytt vs Kustomize

| | ytt | Kustomize |
|---|---|---|
| **Templating** | Data values + `#@` expressions | Patch overlays only |
| **Logic** | Conditionals, loops, functions | No logic (pure YAML merge) |
| **Learning curve** | Steeper (new syntax) | Shallow (just YAML patches) |
| **Validation** | Schema checking built-in | None (relies on kubectl) |
| **Best for** | Complex, multi-variant clusters | Simple overlay variations |

For the CAPRKE2 flavor, ytt is particularly useful because of the **air-gap conditional**
— you can toggle `artifact_server` on/off without maintaining two separate manifest sets.
