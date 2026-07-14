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

When `syncWithACS: true` is set on a `CloudStackCluster`, CAPC registers the workload cluster as an `ExternalManaged` entry in CloudStack's **Compute → Kubernetes** UI. This makes the cluster visible alongside native CKS clusters, which is useful for operators who manage infrastructure through the CloudStack UI.

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

The result: an operator who sees a CAPC cluster in the CloudStack UI can only **delete** it — they cannot stop it (e.g., to save resources overnight), start it back up, or scale it. This is a significant operational gap, especially in environments where CloudStack is the primary management plane.

### Proposed Solution: CAPC Lifecycle Controller

Introduce a **CAPC Lifecycle Controller** (either as a new controller in CAPC itself, or as a companion operator) that implements CloudStack's CKS lifecycle hooks for `ExternalManaged` clusters.

#### How CloudStack CKS Lifecycle Works

CloudStack's Kubernetes service exposes REST API endpoints for lifecycle operations. When a user clicks **Stop** in the UI, CloudStack calls the CKS provider's stop endpoint. For native CKS clusters, the built-in controller handles this. For `ExternalManaged` clusters, CloudStack expects the external provider (CAPC) to handle the operation.

The lifecycle operations map to CAPI operations as follows:

| CloudStack UI Action | CAPI Operation | CAPC Implementation |
|---------------------|----------------|---------------------|
| **Stop** | Scale control plane + workers to 0 | Set `KubeadmControlPlane.spec.replicas = 0` and `MachineDeployment.spec.replicas = 0` |
| **Start** | Restore original replica counts | Set `KubeadmControlPlane.spec.replicas` and `MachineDeployment.spec.replicas` back to their pre-stop values |
| **Scale** | Change replica counts | Update `KubeadmControlPlane.spec.replicas` and/or `MachineDeployment.spec.replicas` |
| **Upgrade** | Change Kubernetes version | Update `KubeadmControlPlane.spec.version` and `MachineDeployment.spec.template.spec.version` |

#### Architecture

```
┌─────────────────────┐     CloudStack API call      ┌──────────────────────┐
│  CloudStack UI      │ ──────────────────────────▶  │  CAPC Lifecycle      │
│  (Compute → K8s)    │     stop/start/scale/upgrade  │  Controller           │
└─────────────────────┘                               │                      │
                                                      │  Watches:            │
                                                      │  - CksCluster CR     │
                                                      │  - CloudStack API    │
                                                      │    lifecycle events  │
                                                      │                      │
                                                      │  Acts on:            │
                                                      │  - KubeadmControlPlane│
                                                      │  - MachineDeployment │
                                                      └──────────────────────┘
```

#### Option A — CAPC Controller Enhancement (Recommended)

Add a new reconciler to CAPC that:

1. **Registers lifecycle handlers** with CloudStack for the `ExternalManaged` cluster, so CloudStack knows CAPC can handle stop/start/scale/upgrade
2. **Watches the `CksCluster` CR** (created by CAPC's `CksClusterReconciler` when `syncWithACS: true`) for state changes initiated from the CloudStack UI
3. **Translates lifecycle events** to CAPI resource mutations:
   - **Stop**: Scales `KubeadmControlPlane` and `MachineDeployment` replicas to 0, stores original replica counts in an annotation (e.g., `capc.cluster.x-k8s.io/original-replicas`)
   - **Start**: Reads the stored replica counts from the annotation and restores them
   - **Scale**: Updates the relevant replica counts directly
   - **Upgrade**: Updates the Kubernetes version on both control plane and worker templates

4. **Reports status back** to CloudStack via the `CksCluster` CR status, so the UI shows the correct state (Running, Stopped, Scaling, etc.)

#### Option B — Standalone Companion Operator

A separate operator (e.g., `capc-lifecycle-operator`) deployed alongside CAPC that:

- Watches `CksCluster` CRs in the management cluster
- Implements the same lifecycle translation logic as Option A
- Is independent of CAPC release cycles — can be updated separately
- Can be installed only when `syncWithACS` lifecycle support is needed

#### Option C — CloudStack Webhook + CAPI Pause/Unpause

A lighter-weight approach that doesn't require a new controller:

1. **Stop**: A CloudStack plugin or webhook intercepts the stop request and calls the CAPI management cluster API to:
   - Pause the CAPC cluster (`Cluster.Spec.Paused = true`)
   - Scale down the `KubeadmControlPlane` and `MachineDeployment` to 0
2. **Start**: The webhook scales back up and unpauses the cluster
3. The webhook authenticates to the management cluster via a service account token stored in CloudStack

This avoids modifying CAPC but requires a CloudStack-side component.

### Key Design Decisions

| Decision | Consideration |
|----------|--------------|
| **Store original replica counts** | Must survive controller restarts. Use an annotation on the `CloudStackCluster` or `Cluster` resource (e.g., `capc.cluster.x-k8s.io/control-plane-replicas`, `capc.cluster.x-k8s.io/worker-replicas-<md-name>`). |
| **Graceful vs. forceful stop** | A graceful stop should `kubectl drain` nodes first, then scale down. A forceful stop just scales to 0. CloudStack's native CKS does a graceful stop. CAPC should match this behavior. |
| **Startup ordering** | On start, the control plane must come up first (KCP replicas restored), then workers (MachineDeployment replicas restored). CAPI handles this ordering naturally since KCP and MachineDeployment are independent resources. |
| **Concurrent operations** | If a user clicks Stop while an upgrade is in progress, the controller should either queue the operation or reject it with a clear error. Use CAPI's `Cluster.Status.Phase` to gate operations. |
| **Idempotency** | Stopping an already-stopped cluster should be a no-op. Starting an already-running cluster should be a no-op. |

### Implementation Notes

- The `CksCluster` CR is created by CAPC's `CksClusterReconciler` when `syncWithACS: true` and `--enable-cloudstack-cks-sync=true`. The lifecycle controller would watch this CR for state transitions.
- CloudStack's CKS API uses the `CksCluster` state to determine available actions. The controller must update `CksCluster.Status.State` to reflect the current cluster state (e.g., `Running`, `Stopped`, `Stopping`, `Starting`).
- The controller needs RBAC permissions to read/update `KubeadmControlPlane`, `MachineDeployment`, `Cluster`, and `CloudStackCluster` resources.
- For the **Upgrade** operation, the controller must also update the `MachineDeployment.spec.template.spec.version` field, not just the control plane version.
- Consider adding a `capc.cluster.x-k8s.io/lifecycle-enabled: "true"` annotation on the `CloudStackCluster` to opt in to lifecycle management, so existing clusters aren't affected.

### Open Questions

| Question | Notes |
|----------|-------|
| **Does CloudStack's CKS API expose lifecycle endpoints for `ExternalManaged` clusters?** | Need to verify. The `CksCluster` CRD may have a `spec.action` field or similar that CloudStack sets when a user clicks Stop/Start. If not, CAPC would need to poll CloudStack's API for pending actions. |
| **How does CloudStack authenticate the lifecycle request to CAPC?** | Native CKS uses CloudStack's internal API. For external providers, CloudStack may call a webhook URL registered by CAPC, or CAPC may poll the `CksCluster` CR status. |
| **What happens to running workloads on stop?** | A graceful stop should drain nodes. But if the cluster has PVCs backed by CloudStack volumes, stopping the control plane may leave volumes in an inconsistent state. Consider adding a pre-stop hook that checks for attached volumes. |
| **Should stop be allowed when the cluster has active workloads?** | CloudStack's native CKS allows stop regardless. CAPC could add a webhook that checks for non-system workloads and warns the user. |
| **How to handle the `controlPlaneEndpoint` IP on restart?** | The public IP is reserved and stays allocated. On start, the control plane nodes come back with the same IP. This should work transparently as long as the IP isn't released between stop and start. |

### Related

- [CAPI ClusterClass documentation](https://cluster-api.sigs.k8s.io/tasks/experimental-features/cluster-class/index.html)
- [CAPC ClusterClass examples](https://github.com/apache/cloudstack-cluster-api-provider/tree/main/config/crd)
- [Rancher Turtles + ClusterClass](https://turtles.docs.rancher.com/)
- [CAPC CKS Sync documentation](./cluster.md#syncwithacs-true)
