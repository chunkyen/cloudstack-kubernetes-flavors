# CAPC + Rancher Turtles Improvements — Proposals & Ideas

> ⚠️ **WIP** — This is a living document tracking proposed improvements to CAPC (Cluster API Provider CloudStack) and Rancher Turtles integration. Contributions and feedback welcome.

---

## 1. CRS ConfigMap: Dynamic Credential Injection for CCM/CSI

### Problem

The CCM and CSI addon YAMLs in the base Kustomize templates contain **placeholder values** for CloudStack credentials:

```yaml
# manifests/kustomize/base/addons/ccm.yaml
stringData:
  cloud-config: |
    [Global]
    api-url = <cloudstack-api-url>
    api-key = "<api-key>"
    secret-key = "<secret-key>"
```

These are applied to the workload cluster via **ClusterResourceSet** (CRS), which applies the ConfigMap content verbatim — no variable substitution. The result: the workload cluster's `cloudstack-secret` and `cloudstack-ccm-secret` contain literal placeholder strings, causing CCM and CSI to fail with:

```
unsupported protocol scheme ""
```

### Current Workaround

After the cluster is provisioned, manually patch both secrets on the workload cluster:

```bash
kubectl create secret generic cloudstack-secret -n kube-system \
  --from-literal=cloud-config="[Global]
api-url = http://<mgmt-server>:8080/client/api
api-key = \"<key>\"
secret-key = \"<secret>\"
ssl-no-verify = \"false\""

kubectl create secret generic cloudstack-ccm-secret -n kube-system \
  --from-literal=cloud-config="[Global]
api-url = http://<mgmt-server>:8080/client/api
api-key = \"<key>\"
secret-key = \"<secret>\"
ssl-no-verify = \"false\""

kubectl delete pod -n kube-system -l app.kubernetes.io/name=cloudstack-csi-node
```

### Proposed Fix: CRS ConfigMap with Dynamic Reference

**Option A — CRS references the management cluster's `cloudstack-credentials` secret directly.**

The CRS ConfigMap would not embed the credentials inline. Instead, the CRS would be configured to copy the `cloudstack-credentials` secret from the management cluster namespace into the workload cluster's `kube-system` namespace, renaming it to `cloudstack-secret` and `cloudstack-ccm-secret`.

This could be done via a **post-deployment controller** or a **mutating webhook** that intercepts the CRS application and substitutes the credentials.

**Option B — Kustomize patches the CRS ConfigMap at apply time.**

Instead of embedding placeholders in the base addon YAMLs, the Kustomize overlay would patch the ConfigMap data with the real credentials at `kubectl apply` time. This is already partially done for the `cloudstack-credentials` secret in the management cluster namespace, but the CCM/CSI secrets in the addon ConfigMap are not patched because they're embedded in a multi-document YAML file that gets bundled into a ConfigMap via `configMapGenerator`.

The challenge: the addon YAMLs (`ccm.yaml`, `csi.yaml`) are loaded as files into a ConfigMap via `configMapGenerator.files`, then applied by the CRS. The credentials are inside those files. Kustomize's `configMapGenerator` doesn't support patching the content of files — only the ConfigMap metadata.

**Option C — Use a post-deployment Job (recommended).**

Add a **post-deployment Job** to the CRS that runs after the cluster is provisioned. The Job:

1. Reads the `cloudstack-credentials` secret from the management cluster (mounted via a sidecar or environment variable)
2. Creates/updates `cloudstack-secret` and `cloudstack-ccm-secret` in the workload cluster's `kube-system` namespace
3. Restarts the CSI node DaemonSet pods

This is the most robust approach because:
- No credentials are embedded in Git
- The Job runs automatically after every cluster creation
- It handles the timing correctly (secrets are created after the cluster is reachable)

### Implementation Notes

- The post-deployment Job would be part of the CRS `ClusterResourceSet` resources
- It needs a service account with permissions to read secrets in the management cluster namespace and create secrets in the workload cluster
- The Job image would need `kubectl` installed
- Consider making this a generic "post-deploy credential sync" controller rather than a one-off Job

---

## 2. Implement ClusterClass for CAPC

### Problem

Currently, every CAPC cluster deployment uses a **Kustomize overlay** pattern:

1. A base template with all resources (Cluster, CloudStackCluster, KubeadmControlPlane, MachineDeployment, etc.)
2. An overlay per cluster that patches names, IPs, network names, and other cluster-specific values
3. Applied via `kubectl apply -k overlays/<cluster-name>/`

This works but has several drawbacks:

- **No type safety** — Kustomize patches are string-based JSON patches; a typo in a path silently produces a broken resource
- **No validation** — There's no schema enforcement; you can set invalid combinations of fields
- **No topology** — Each cluster is a flat set of resources; there's no concept of a "cluster shape" (e.g., HA vs single-node, cilium vs calico)
- **No lifecycle management** — Upgrades require manual edits to the overlay; there's no versioned upgrade path
- **No GitOps-friendly diff** — The overlay diff shows patch operations, not meaningful cluster configuration changes

### What ClusterClass Provides

[ClusterClass](https://cluster-api.sigs.k8s.io/tasks/experimental-features/cluster-class/index.html) is a CAPI feature (GA since v1.7) that introduces:

| Concept | What It Does |
|---------|-------------|
| **ClusterClass** | A reusable "blueprint" defining the cluster topology — which control plane, infrastructure, and worker templates to use |
| **Topology** | The `Cluster` object references a `ClusterClass` and specifies only the variable values (e.g., replicas, version, network name) |
| **Variables** | Typed, validated variables that the ClusterClass defines and the Cluster topology fills in |
| **Patches** | Built-in and custom patches that transform the topology into concrete resources at reconciliation time |
| **Versioning** | ClusterClass can be versioned; clusters can be upgraded by changing the ClusterClass reference |

### Proposed Architecture

```
ClusterClass (global)
├── defines: control plane template (KubeadmControlPlaneTemplate)
├── defines: infrastructure template (CloudStackClusterTemplate)
├── defines: worker templates (MachineDeploymentTemplate)
├── defines: variables (typed, validated)
│   ├── clusterName: string
│   ├── controlPlaneEndpointIP: string (IP)
│   ├── networkName: string
│   ├── zoneName: string
│   ├── controlPlaneReplicas: integer (1, 3, 5)
│   ├── workerReplicas: integer
│   └── cni: enum (cilium, calico)
└── defines: patches
    ├── set controlPlaneEndpoint
    ├── set failureDomain zone/network
    ├── set syncWithACS
    └── inject CNI ConfigMap into CRS
```

```
Cluster (per-cluster)
├── spec.topology.class: "capc-default"  ← references ClusterClass
├── spec.topology.version: "v1.35.0"
├── spec.topology.variables:
│   ├── clusterName: "capc-cluster4"
│   ├── controlPlaneEndpointIP: "192.168.200.58"
│   ├── networkName: "capcnet4"
│   ├── zoneName: "cyz1"
│   ├── controlPlaneReplicas: 1
│   ├── workerReplicas: 2
│   └── cni: "cilium"
└── spec.topology.workers:
    └── machineDeployments:
        - name: "md-0"
          class: "default-worker"
          replicas: 2
```

### Benefits

| Benefit | Description |
|---------|-------------|
| **Declarative** | Cluster topology is a single `Cluster` object with variables — no Kustomize overlays |
| **Validated** | Variables are typed and validated at admission time; typos are caught immediately |
| **Upgradable** | Change `spec.topology.version` to trigger a rolling upgrade; no template edits needed |
| **GitOps-friendly** | The diff shows meaningful variable changes, not JSON patch operations |
| **Reusable** | A single ClusterClass serves all clusters; no per-cluster overlay maintenance |
| **Extensible** | New CNI options, worker profiles, or infrastructure variants are just new variables or patches |

### Migration Path

1. **Define the ClusterClass** — Create a `ClusterClass` resource with all the templates and variables
2. **Define the ClusterClass templates** — `CloudStackClusterTemplate`, `KubeadmControlPlaneTemplate`, `CloudStackMachineTemplate`, `MachineDeploymentTemplate`
3. **Define variables** — Typed variables for cluster name, IP, network, zone, replicas, CNI choice
4. **Define patches** — CAPI built-in patches for standard topology, custom patches for CAPC-specific fields (syncWithACS, offering removal)
5. **Migrate one cluster** — Convert `capc-cluster4` from Kustomize overlay to ClusterClass topology
6. **Validate** — Verify the cluster provisions correctly with all addons (Cilium, CCM, CSI)
7. **Migrate remaining clusters** — Convert `capc-cluster1`, `capc-cluster2`, `capc-cluster3`

### Example ClusterClass

```yaml
apiVersion: cluster.x-k8s.io/v1beta1
kind: ClusterClass
metadata:
  name: capc-default
  namespace: capc-system
spec:
  controlPlane:
    ref:
      apiVersion: controlplane.cluster.x-k8s.io/v1beta1
      kind: KubeadmControlPlaneTemplate
      name: capc-default-control-plane
    machineInfrastructure:
      ref:
        apiVersion: infrastructure.cluster.x-k8s.io/v1beta3
        kind: CloudStackMachineTemplate
        name: capc-default-control-plane
  infrastructure:
    ref:
      apiVersion: infrastructure.cluster.x-k8s.io/v1beta3
      kind: CloudStackClusterTemplate
      name: capc-default-cluster
  workers:
    machineDeployments:
    - class: default-worker
      template:
        bootstrap:
          ref:
            apiVersion: bootstrap.cluster.x-k8s.io/v1beta1
            kind: KubeadmConfigTemplate
            name: capc-default-worker
        infrastructure:
          ref:
            apiVersion: infrastructure.cluster.x-k8s.io/v1beta3
            kind: CloudStackMachineTemplate
            name: capc-default-worker
  variables:
    - name: clusterName
      required: true
      schema:
        openAPIV3Schema:
          type: string
          maxLength: 63
    - name: controlPlaneEndpointIP
      required: true
      schema:
        openAPIV3Schema:
          type: string
          format: ipv4
    - name: networkName
      required: true
      schema:
        openAPIV3Schema:
          type: string
    - name: zoneName
      required: true
      schema:
        openAPIV3Schema:
          type: string
          default: "cyz1"
    - name: cni
      required: true
      schema:
        openAPIV3Schema:
          type: string
          enum: ["cilium", "calico"]
          default: "cilium"
  patches:
    - name: controlPlaneEndpoint
      definitions:
        - selector:
            apiVersion: infrastructure.cluster.x-k8s.io/v1beta3
            kind: CloudStackClusterTemplate
            matchResources: infrastructure
          jsonPatches:
            - op: add
              path: /spec/template/spec/controlPlaneEndpoint/host
              valueFrom:
                variable: controlPlaneEndpointIP
    - name: failureDomain
      definitions:
        - selector:
            apiVersion: infrastructure.cluster.x-k8s.io/v1beta3
            kind: CloudStackClusterTemplate
            matchResources: infrastructure
          jsonPatches:
            - op: add
              path: /spec/template/spec/failureDomains/0/zone/name
              valueFrom:
                variable: zoneName
            - op: add
              path: /spec/template/spec/failureDomains/0/zone/network/name
              valueFrom:
                variable: networkName
            - op: add
              path: /spec/template/spec/failureDomains/0/name
              valueFrom:
                variable: networkName
            - op: add
              path: /spec/template/spec/syncWithACS
              value: true
```

### Example Cluster using ClusterClass

```yaml
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: capc-cluster4
  namespace: capc-cluster4
  labels:
    cluster-api.cattle.io/rancher-auto-import: "true"
spec:
  topology:
    class: capc-default
    version: v1.35.0
    variables:
      - name: clusterName
        value: "capc-cluster4"
      - name: controlPlaneEndpointIP
        value: "192.168.200.58"
      - name: networkName
        value: "capcnet4"
      - name: zoneName
        value: "cyz1"
      - name: cni
        value: "cilium"
    workers:
      machineDeployments:
        - class: default-worker
          name: md-0
          replicas: 2
```

### Challenges & Open Questions

| Challenge | Description |
|-----------|-------------|
| **CRS with ClusterClass** | ClusterResourceSet works with ClusterClass, but the addon ConfigMap (Cilium, CCM, CSI) must be referenced correctly. The CRS can be part of the ClusterClass or applied separately. |
| **Network auto-creation** | CAPC auto-creates the network. The ClusterClass must handle the case where the network doesn't exist yet. The `controlPlaneEndpointIP` is unknown until the network is created and a public IP is acquired. This creates a chicken-and-egg problem: the Cluster topology needs the IP, but the IP is only known after the network is created. |
| **Dynamic IP allocation** | The control plane endpoint IP is currently hardcoded in the overlay. With ClusterClass, it could be a variable, but it's not known at manifest-creation time. Options: (a) pre-allocate the IP and pass it as a variable, (b) use a mutating webhook to assign it after network creation, (c) use a post-creation patch. |
| **CNI ConfigMap injection** | The Cilium/Calico YAML is currently bundled into a ConfigMap and applied via CRS. With ClusterClass, this could be a built-in patch or a separate CRS that references the ClusterClass. |
| **CAPC v1beta3 compatibility** | CAPC uses `v1beta3` API version. ClusterClass requires the templates to use the same API version. Verify that `CloudStackClusterTemplate` and `CloudStackMachineTemplate` are available in CAPC v1beta3. |
| **Rancher Turtles compatibility** | Rancher Turtles auto-import works with ClusterClass-based clusters, but the import controller watches for `ControlPlaneAvailable` condition. Verify that ClusterClass topology doesn't change the condition semantics. |

### Implementation Notes

- Start with a single ClusterClass in a dedicated namespace (e.g., `capc-system`)
- Use CAPI's built-in `JSONPatch` patcher for standard patches
- For complex patches (e.g., removing `offering` from failure domain), use the `external` patcher or a custom patcher
- The ClusterClass should be created before any Cluster that references it
- Consider using `kubectl clusterclass` commands for validation:
  ```bash
  kubectl clusterclass validate capc-default -n capc-system
  ```

---

## 3. Power Cycle CAPC Clusters from the CloudStack UI

### Problem

When `syncWithACS: true` is set on a `CloudStackCluster`, CAPC registers the workload cluster as an `ExternalManaged` entry in CloudStack's **Compute → Kubernetes** UI. This makes the cluster visible alongside native CKS clusters.

However, the CloudStack Kubernetes UI exposes several lifecycle actions for each cluster:

| Action | Native CKS | CAPC (ExternalManaged) |
|--------|-----------|----------------------|
| **View** | ✅ | ✅ |
| **Delete** | ✅ | ✅ |
| **Stop** | ✅ | ❌ (not available) |
| **Start** | ✅ | ❌ (not available) |
| **Scale** | ✅ | ❌ (not available) |
| **Upgrade** | ✅ | ❌ (not available) |

For native CKS clusters, CloudStack's built-in `CksClusterReconciler` handles all lifecycle operations. For CAPC-managed clusters, only **Delete** is available because CAPC registers the cluster as `ExternalManaged` and doesn't implement the lifecycle hooks that CloudStack calls when a user clicks Stop, Start, Scale, or Upgrade.

The result: an operator who sees a CAPC cluster in the CloudStack UI can only **delete** it — they cannot stop it (e.g., to save resources overnight), start it back up, or scale it.

### Stop/Start via Native CloudStack VM Operations

For **stop** and **start**, no CAPC controller is needed. CAPC workload clusters are just CloudStack VMs — they can be stopped, started, and rebooted directly from **Compute → Instances** in the CloudStack UI, or via the CloudStack API:

```bash
# Stop all cluster VMs
cmk stop virtualmachine id=<cp-vm-id>
cmk stop virtualmachine id=<worker1-vm-id>
cmk stop virtualmachine id=<worker2-vm-id>

# Start them back up
cmk start virtualmachine id=<cp-vm-id>
cmk start virtualmachine id=<worker1-vm-id>
cmk start virtualmachine id=<worker2-vm-id>

# Reboot
cmk reboot virtualmachine id=<cp-vm-id>
```

When the VMs come back:
- **Control plane**: kubelet starts, etcd rejoins the quorum, API server comes back online. The control plane endpoint IP (reserved public IP) stays allocated, so `kubectl` access resumes transparently.
- **Workers**: kubelet starts, re-registers with the API server, pods are rescheduled.
- **CAPI state**: The `Cluster`, `KubeadmControlPlane`, and `MachineDeployment` resources remain unchanged — CAPI sees the Machines transition through `Running` → `Stopped` → `Running` as the underlying VMs change state. No CAPI resource mutations needed.

This is the simplest and most reliable approach because it uses CloudStack's battle-tested VM lifecycle rather than trying to orchestrate through CAPI scaling.

**Caveats:**
- Stop is **forceful** — VMs are powered off, not drained. Running workloads are terminated abruptly. For a graceful shutdown, drain nodes via `kubectl drain` first, then stop the VMs.
- If the control plane VM is stopped, the cluster's API server is unavailable until it's started again. Plan maintenance windows accordingly.
- CloudStack volumes (root disks, data disks) persist across stop/start — no data loss.

### Scale and Upgrade — Still Need a Controller

While stop/start are handled natively by CloudStack VM operations, **scale** and **upgrade** require CAPI resource mutations:

| Action | CAPI Operation |
|--------|----------------|
| **Scale** | Update `KubeadmControlPlane.spec.replicas` and/or `MachineDeployment.spec.replicas` |
| **Upgrade** | Update `KubeadmControlPlane.spec.version` and `MachineDeployment.spec.template.spec.version` |

These could be handled by a lightweight controller that watches the `CksCluster` CR for scale/upgrade actions initiated from the CloudStack UI and translates them to CAPI resource updates. But this is a lower priority — scale and upgrade are typically done via `kubectl` or GitOps, not the CloudStack UI.

### Recommendation

| Operation | Approach | Priority |
|-----------|----------|----------|
| **Stop** | Use CloudStack VM stop (Compute → Instances) | ✅ Already works |
| **Start** | Use CloudStack VM start (Compute → Instances) | ✅ Already works |
| **Reboot** | Use CloudStack VM reboot (Compute → Instances) | ✅ Already works |
| **Scale** | Lightweight CksCluster → CAPI controller | Low |
| **Upgrade** | Lightweight CksCluster → CAPI controller | Low |

The CloudStack Kubernetes UI won't show Stop/Start buttons for `ExternalManaged` clusters, but the underlying VM operations are fully functional. The practical workflow is:

1. Go to **Compute → Instances** in the CloudStack UI
2. Select the cluster's VMs (they're named after the CAPI Machine objects)
3. Stop, start, or reboot as needed
4. The cluster recovers automatically when VMs come back online
