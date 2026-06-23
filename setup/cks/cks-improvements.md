# CKS Improvements — Proposals & Ideas

> ⚠️ **WIP** — This is a living document tracking proposed improvements to CloudStack Kubernetes Service (CKS). Contributions and feedback welcome.

---

## 1. Upgrade Logic: Pre-Import Images on All Nodes First

### Problem
Currently, CKS imports new container images only onto the node being actively upgraded. When intermediate Jobs (health checks, etc.) are scheduled on non-upgraded nodes, those nodes lack newer image versions — causing offline upgrades to fail with `ImagePullBackOff`.

See [cks-offline.md #4.1](./cks-offline.md#41-pre-built-calico-iso---pause-container-issue) for detailed analysis.

### Proposed Fix
Modify the CKS upgrade orchestration logic to **pre-import all required images from the target ISO onto every cluster node** before upgrading any single node.

This guarantees:
- Intermediate Jobs can be safely scheduled on any node without hitting `ImagePullBackOff`
- Offline/air-gapped upgrades work seamlessly across all K8s versions
- No manual workaround needed (Section 5 in cks-offline.md)

### Implementation Notes
- Requires changes to the `cloudstack-kubernetes-service` plugin code
- Should be backward-compatible with online deployments (no regression risk)
- Consider making this configurable via advanced settings (`cks.upgrade.preimportImages=true/false`)

---

## 2. Replace Kubernetes Dashboard with Headlamp

### Problem
The Kubernetes Dashboard is deprecated and has limited functionality. CKS previously bundled it by default.

### Status: ✅ Implemented — PR #12776 (Merged Mar 30, 2026)

PR [#12776](https://github.com/apache/cloudstack/pull/12776) by **Pearl1594** — "Add support for Headlamp dashboard for kubernetes; deprecate legacy kubernetes dashboard" — has been merged into `main`.

### What the PR Does

- **ISO build script** (`create-kubernetes-binaries-iso.sh`): Fetches the Headlamp manifest by version and bundles `headlamp.yaml` into the ISO alongside (or instead of) `dashboard.yaml`
- **Cloud-init** (`k8s-control-node.yml`): Installs `headlamp.yaml` when present, with fallback to `dashboard.yaml` for older clusters
- **Readiness check** (`KubernetesClusterUtil.java`): Detects Headlamp first, then falls back to legacy Dashboard during post-bootstrap verification
- **UI** (`KubernetesServiceTab.vue`): Updated cluster dashboard instructions to show Headlamp access steps (new clusters) while preserving legacy Dashboard steps for older clusters

### Implementation Details

| File Changed | What It Does |
|---|---|
| `ui/src/views/compute/KubernetesServiceTab.vue` | Adds Headlamp + legacy Dashboard access/token guidance in the cluster UI tab |
| `scripts/util/create-kubernetes-binaries-iso.sh` | Switches ISO dashboard asset from Dashboard YAML URL to Headlamp manifest version |
| `k8s-control-node.yml` | Installs `headlamp.yaml` when present (fallback to `dashboard.yaml`) |
| `KubernetesClusterUtil.java` | Extends dashboard readiness checks to detect Headlamp first, then legacy Dashboard |

### Backward Compatibility

- **New clusters** (4.23+): Headlamp is deployed by default
- **Legacy clusters** (pre-4.23): Kubernetes Dashboard continues to work unchanged
- The UI shows both access methods depending on which dashboard is present

### Related
- GitHub issue: [#12728](https://github.com/apache/cloudstack/issues/12728) (original feature request)
- PR: [#12776](https://github.com/apache/cloudstack/pull/12776) (merged Mar 30, 2026)

---

## 3. Authentication & IAM Integration

### Problem
CKS clusters currently lack built-in authentication mechanisms integrated with CloudStack's identity model. Cluster access relies on basic kubeconfig tokens without fine-grained RBAC tied to CloudStack accounts/projects.

### Proposal: Integrate Dex or Pinniped for OIDC/AuthN
Implement an authentication layer using either:

**Option A — [Dex](https://dexidp.io/):**
- Lightweight OIDC provider
- Can integrate with multiple identity backends
- Easy to deploy as a CKS add-on
- Supports SSO and password-based auth

**Option B — [Pinniped](https://pinniped.dev/) (Supervisor mode):**
- Kubernetes-native authentication solution (Graduated SIG)
- Designed for multi-cluster auth scenarios
- Stronger security model with JWT-based token exchange

### Integration Points
| CloudStack Concept | K8s Mapping |
|---|---|
| Account → Admin | `system:masters` group / cluster-admin role |
| Project Members | Namespace-level RBAC (admin/edit/view) |
| Domain Hierarchy | Optional LDAP/OIDC upstream provider |

### Implementation Notes
- Deploy Dex/Pinniped as a system add-on during CKS cluster creation
- Generate initial kubeconfigs that use OIDC token exchange instead of static tokens
- Expose advanced settings for auth configuration (`cks.auth.provider`, `cks.auth.issuer`, etc.)
- Consider CloudStack API integration for dynamic user sync (account changes → K8s RBAC updates)
- This would be a significant feature addition — best approached as an optional plugin rather than default behavior

---

## 4. Full Air-Gapped / Offline Deployment Support

### Problem
CKS currently assumes internet connectivity is available as a fallback. While [cks-offline.md](./cks-offline.md) documents workarounds, air-gapped deployments remain second-class citizens — upgrades fail silently without the manual pre-import workaround (Section 1), and documentation explicitly states "complete offline provisioning... is not supported".

### Proposal: Just Make It Work Offline
CKS should function identically whether or not internet access is available. There should be no special "offline mode" — air-gapped deployment should simply work.

**Key changes:**
- **No implicit internet fallbacks** — CKS should never attempt to reach external registries by default. All image references resolve from the local ISO (or internal registry) out of the box.
- **Manifest validation at build time** — verify that every `image:` reference in bundled YAMLs has a matching tarball in the ISO's `docker/` directory before the ISO is finalized.
- **Fail-fast with actionable errors** — if required images are missing locally, report exactly what's missing rather than hanging on a registry timeout.
- **Tag-only image references by default** — strip digest pins (`@sha256:...`) from generated manifests during build (see offline Cilium script for the pattern), so no external registry verification is ever needed.

### Relationship to other improvements
This section builds on several of the proposals above as key steps:
- **Section 1 (Pre-Import Images):** One of the essential steps — eliminates the primary upgrade failure mode in offline environments.
- **Offline Cilium script (cks-offline.md #4.2):** Stripping digest pins from manifests is required for air-gapped CNI deployment.

---

## 5. Restrictive Default Firewall Rules (API + SSH)

### Problem
By default, CKS creates firewall rules that open:
- **Kube API (6443)** — sourced from `0.0.0.0/0` on the SNAT public IP
- **SSH port-forwarded ports** (2222→node1:22, 2223→node2:22, etc.) — also sourced from `0.0.0.0/0`

This exposes the API and SSH to the entire internet from cluster creation time, which is a significant security concern for production deployments.

### Proposal: Allow Source IP Restriction at Cluster Creation
Add an advanced setting (or UI/API parameter) during CKS cluster creation that lets administrators specify allowed source CIDR(s):
- `cks.firewall.apiSourceCidr` — controls the source range on port 6443 firewall rule (default remains `0.0.0.0/0` for backward compatibility)
- `cks.firewall.sshSourceCidr` — controls the source range on all SSH forwarded ports

**Defaults:** Keep `0.0.0.0/0` as default to maintain backward compatibility, but strongly document that restricting these is recommended.

**Better long-term default:** Consider flipping the default in a future major release to use a restrictive CIDR (e.g., `127.0.0.1/32` or the management server's IP range) and require explicit opt-in for open access.

### Implementation Notes
- Map new advanced settings to firewall rule creation logic in the CKS plugin (`createFirewallRule` calls)
- Support comma-separated CIDRs if multiple ranges are needed (e.g., `10.0.0.0/8,203.0.113.5/32`)
- Update `cks.md` documentation to call out these settings prominently
- Consider a post-creation API/UI action to modify firewall rules without requiring cluster recreation
- Could also support per-node SSH CIDR granularity in the future (e.g., restrict node 1 SSH to admin IP, node 2+ to bastion)

---

## 6. Fix the ISO Build Script's Brittle Download Logic

### Problem
`curl -sSL` without `-f` silently produces garbage files on 404. No checksums, no fallback.

### Proposed Fix
- Add `-f` flag to all `curl` commands in `create-kubernetes-binaries-iso.sh` so the build **fails** if a URL returns an error
- Add SHA256 checksum verification for downloaded binaries where checksums are available
- Add a retry mechanism: `curl --retry 3 --retry-delay 5`
- Validate downloaded YAML files with `python3 -c "import yaml; yaml.safe_load(open('file.yaml'))"` before packaging

### Implementation Notes
- Also validate manifest integrity after download (see §7)
- Consider making the build script fail-fast rather than silently producing a corrupt ISO

---

## 7. Validate YAML Manifests Before Including in ISO

### Problem
The build script blindly packs any downloaded file as `*.yaml`. Invalid YAML (HTML error pages, truncated files) causes cloud-init failures.

### Proposed Fix
```bash
# In create-kubernetes-binaries-iso.sh, after downloading each YAML:
if ! python3 -c "import yaml; yaml.safe_load(open('${file}'))"; then
    echo "ERROR: ${file} is not valid YAML"
    exit 1
fi
```

### Implementation Notes
- Validate all `*.yaml` files before the ISO is finalized with `mkisofs`
- Include both syntax and basic structure validation (e.g., check for required `kind`, `apiVersion` fields)

---

## 8. Verify All Container Images Exist Before Finalizing ISO

### Problem
The ISO is built even if some container images failed to pull or export.

### Proposed Fix
- Count expected images from YAML manifests
- Count actual `*.tar` files in `docker/`
- If counts don't match, fail the build with a list of missing images
- For each `ctr image pull`, check exit code explicitly (the build script currently doesn't)

### Implementation Notes
- This complements §4 — ensures the ISO is self-consistent regardless of deployment environment

---

## 9. Decouple Dashboard Verification from CCM/CSI Deployment

### Problem
The post-bootstrap pipeline in `startKubernetesClusterOnCreate()` blocks CCM, CSI, and control node tainting behind the dashboard pod being `Running`. If the dashboard pod fails, the cluster never reaches `Running` state — even though the cluster is functionally complete.

### Proposed Fix
Reorder in `KubernetesClusterStartWorker.startKubernetesClusterOnCreate()`:
```java
// Current order:
//   5. kubeconfig -> 6. dashboard check -> 7. taint -> 8. CCM -> 9. CSI
// Proposed order:
//   5. kubeconfig -> 6. taint -> 7. CCM -> 8. CSI -> 9. dashboard check (non-blocking)
```
- Move `deployProvider()` and `deployCsiDriver()` **before** the dashboard check
- Make the dashboard check non-blocking: log a warning instead of throwing, or transition to a `Running (Dashboard Pending)` sub-state
- Reduce the dashboard poll interval from 15s to lower values early on (exponential backoff)

### Implementation Notes
- This is one of the most impactful fixes — it prevents the "stuck in Starting" problem entirely when dashboard fails but CCM/CSI should still deploy

---

## 10. Reorder ISO Attachment for Faster Bootstrap

### Problem
Sequential ISO attachment means the last worker VM in a large cluster waits minutes before receiving its ISO, extending total bootstrap time unnecessarily.

### Proposed Fix
- Parallelize ISO attachment where the hypervisor supports it (e.g., issue all `attachIso` calls without waiting for each to complete, then poll all)
- Alternatively: batch-attach ISOs per node type (all workers in parallel)
- For very large clusters: consider pre-seeding the ISO in the VM template so cloud-init doesn't need to poll-wait at all

### Implementation Notes
- Hypervisor-dependent — test XenServer, VMware, and KVM separately
- Consider a configuration flag to enable parallel attachment per hypervisor type

---

## 11. Add Timeout Checkpoints During Upgrade

### Problem
The upgrade timeout is checked only between major steps, not within long-running operations like `kubeadm upgrade apply`.

### Proposed Fix
- Add a background watchdog thread that kills the upgrade script if the overall timeout is exceeded
- Add per-step sub-timeouts: the upgrade script itself should have an internal timeout
- Implement a "best-effort rollback" — after a partial upgrade failure, cordon all already-upgraded nodes to prevent scheduling surprises

### Implementation Notes
- Related to §1 (Pre-import images) — reducing image import time reduces overall upgrade window

---

## 12. Add Retry Logic to cloud-init Scripts

### Problem
The `deploy-kube-system` systemd service restarts on failure, but `kubeadm init` fails on restart because the cluster is already initialized — creating an infinite loop.

### Proposed Fix
- In `deploy-kube-system`, check if the cluster is already initialized before attempting `kubeadm init`:
  ```bash
  if /opt/bin/kubectl get nodes &>/dev/null; then
      echo "Cluster already initialized, skipping kubeadm init"
  else
      kubeadm init ...
  fi
  ```
- Use systemd `RestartSec` to add a delay between restarts (currently 0)
- Add `StartLimitBurst` to prevent infinite restarts (e.g., max 5 restarts then stop)

### Implementation Notes
- This is a simple, high-impact fix that prevents a common failure mode during cluster bootstrap

---

## 13. Add Health Checks Between Cluster Lifecycle Phases

### Problem
After bootstrap, there's no ongoing health monitoring. A cluster could degrade silently.

### Proposed Fix
- Add a periodic health check scanner in the management server that:
  - Verifies the API server is reachable
  - Checks node count matches expected
  - Reports degraded clusters via CloudStack events/alerts
- Expose cluster health as a new field on `KubernetesClusterResponse`

### Implementation Notes
- Could be implemented as a scheduled job or integrated into existing heartbeat mechanisms

---

## 14. Use Short-Lived Bootstrap Tokens with Rotation

### Problem
The kubeadm bootstrap token is derived from the cluster UUID (`generateClusterToken()`) and set with `--token-ttl 0` (never expires). It's embedded in every node's cloud-init userdata and the kubeadm config on disk.

### Proposed Fix
- Use `--token-ttl 1h` (or the duration of the start timeout) instead of `0`
- Delete the bootstrap token via `kubeadm token delete <token>` after all nodes join
- Generate tokens with `crypto.random()` instead of deriving from cluster UUID
- Store tokens in `KubernetesClusterDetailsVO` with encryption at rest

### Implementation Notes
- High security impact — tokens never expire today, meaning any leaked token grants permanent node-join access

---

## 15. Issue Short-Lived TLS Certificates

### Problem
The API server TLS certificate is issued with a **3650-day (10-year)** validity via CloudStack CA Manager.

```java
// KubernetesClusterStartWorker.java
final Certificate certificate = caManager.issueCertificate(
    null, addresses, 3650,  // ← 10 years
    null);
```

### Proposed Fix
- Reduce to 1 year (365 days) or less
- Implement automatic certificate renewal before expiry (kubeadm supports `kubeadm certs renew`)
- Consider using `kubeadm init --cert-dir` with pre-generated short-lived certs managed by cert-manager

### Implementation Notes
- Reduces the blast radius of a compromised API server certificate

---

## 16. Protect CloudStack API Credentials

### Problem
The CloudStack API key and secret are passed as command-line arguments to the `deploy-cloudstack-secret` script:

```bash
sudo /opt/bin/deploy-cloudstack-secret -u '<api-url>' -k '<key>' -s '<secret>'
```

This exposes API credentials in process listings (`ps aux`), shell history, systemd journal, and SSH command logs.

### Proposed Fix
- Write credentials to a temp file with restricted permissions (`0600`), pass the file path instead:
  ```bash
  echo "[Global]\napi-url = $URL\napi-key = $KEY\nsecret-key = $SECRET" > /tmp/cloud-config.$$ && chmod 600 /tmp/cloud-config.$$
  sudo /opt/bin/deploy-cloudstack-secret --config-file /tmp/cloud-config.$$
  shred -u /tmp/cloud-config.$$
  ```
- Use Kubernetes secrets with restricted RBAC for the provider instead of a generic `cloudstack-secret`
- Rotate API keys periodically

### Implementation Notes
- High security impact — API credentials currently visible in process listings and logs

---

## 17. Restrict SSH Access Scope

### Problem
The management server's SSH key is injected into **every** cluster node, granting passwordless root-equivalent access (user `cloud` has `NOPASSWD:***`).

### Proposed Fix
- Inject the management server key only on the control node (workers don't need it for normal operation)
- Create a dedicated, restricted CKS management user instead of using the general `cloud` user
- Use SSH certificates with short lifetimes instead of permanent authorized_keys
- Add audit logging for all SSH sessions originating from the management server

### Implementation Notes
- Complements §5 (Restrictive firewall rules) — reduces both network exposure and SSH key blast radius

---

## 18. Secure the Kubeconfig Stored in the Database

### Problem
The cluster's admin kubeconfig is stored as base64 (not encrypted) in `KubernetesClusterDetailsVO` with key `kubeConfigData`.

### Proposed Fix
- Encrypt the kubeconfig at rest using CloudStack's existing encryption framework
- Create a dedicated, scoped service account + kubeconfig instead of storing the full `cluster-admin` kubeconfig
- Rotate kubeconfigs on a schedule (re-generate from the control node)

### Implementation Notes
- The current base64 encoding provides zero confidentiality — it's effectively plaintext

---

## 19. Validate cloud-init Userdata Signatures

### Problem
cloud-init userdata is generated by the management server and injected into VMs. There's no integrity check — if the management server is compromised, arbitrary cloud-init could be injected.

### Proposed Fix
- Sign cloud-init userdata with the CloudStack CA or an HMAC
- Have the VM validate the signature before executing

### Implementation Notes
- Defense-in-depth: protects against a compromised management server injecting malicious bootstrap instructions

---

## 20. Network Isolation for Cluster Management Traffic

### Problem
The management server communicates with cluster VMs over the same public/guest network. SSH (port 2222) and API (port 6443) are exposed via port forwarding.

### Proposed Fix
- Use a dedicated management network (not the guest network) for SSH access to cluster VMs
- Firewall rules should restrict SSH access to only the management server's IP, not `0.0.0.0/0`
- Current code opens SSH to the world:
  ```java
  sourceCidrList.add("0.0.0.0/0");  // ← should be restricted
  ```

### Implementation Notes
- Complements §5 (Restrictive firewall rules) — this is a longer-term architectural improvement rather than just parameterizing the CIDR

---

## 21. Implement kubeadm Token Cleanup After Bootstrap

### Problem
The bootstrap token persists indefinitely (`--token-ttl 0`), allowing anyone with network access to join nodes to the cluster.

### Proposed Fix
- After `validateKubernetesClusterReadyNodesCount()` succeeds, SSH in and run:
  ```bash
  sudo /opt/bin/kubeadm token delete <token>
  ```
- This should happen before `stateTransitTo(OperationSucceeded)`

### Implementation Notes
- Direct complement of §14 (Short-lived tokens) — removes the token entirely after bootstrap completes rather than just expiring it

---

## 22. Make Dashboard Deployment Optional During Bootstrap

### Problem
CKS deploys a dashboard (Kubernetes Dashboard or Headlamp) as part of the cluster bootstrap process, and blocks completion until it's running (§9). This adds unnecessary time to cluster creation for users who don't need a web UI, and can cause failures when image pulls fail.

### Proposed Fix
- Make dashboard deployment opt-in via an advanced setting (e.g., `cks.deploy.dashboard=true/false`, default `false`)
- When disabled: skip the dashboard manifest apply in cloud-init **and** remove the blocking verification step entirely
- Allow dashboard to be installed later as a post-bootstrap add-on via UI/API or manual `kubectl apply`
- Keep pre-deployed components to the bare minimum required for a functional Kubernetes cluster:
  - ✅ kube-apiserver, etcd, controller-manager, scheduler (via kubeadm)
  - ✅ CoreDNS
  - ✅ CNI plugin
  - ❌ Dashboard (optional)
  - ❌ Headlamp (optional)

### Implementation Notes
- Simplest change: add a flag in cloud-init templates to conditionally apply dashboard manifests
- Removes the most common bootstrap failure point (§9) when disabled
- Aligns with Kubernetes best practices — cluster addons should be installed separately from control plane bootstrap
- Consider exposing as a UI checkbox during cluster creation for discoverability

---

## 23. Force-Remove Failed / Unreachable Nodes

### Problem
The current scale-down path (`KubernetesClusterScaleWorker.scaleDownKubernetesClusterSize()` → `removeNodesFromCluster()`) relies on a healthy node to execute:

1. `kubectl drain <hostname> --ignore-daemonsets --delete-emptydir-data` (retries 3×)
2. `kubectl delete node <hostname>`
3. `userVmService.destroyVm()` + `userVmManager.expunge()`
4. `kubernetesClusterVmMapDao.expunge()`
5. Recalculate network rules

If a node is in a failed state — frozen, unresponsive, disk full, kubelet dead — steps 1 and 2 fail. The scale-down operation hangs or fails, and the user is stuck with a broken node that cannot be removed through the normal API.

There is no mechanism to bypass the Kubernetes-level drain/delete and force-remove the node at the CloudStack infrastructure level.

### Proposal: Force-Remove Node via CloudStack API

Add a new API command `forceRemoveKubernetesClusterNode` (or extend `scaleKubernetesCluster` with a `forceRemove` flag) that bypasses the Kubernetes-level drain/delete and removes the node directly from CloudStack:

**Force-remove flow:**

1. **Identify the node** — by hostname or VM ID
2. **Force-delete from Kubernetes** — SSH to control node, run:
   ```bash
   sudo /opt/bin/kubectl delete node <hostname> --force --grace-period=0
   ```
   This bypasses the drain step and immediately removes the node object from the API server. If the node is completely unresponsive and even `delete --force` hangs, fall back to:
   ```bash
   sudo /opt/bin/kubectl get nodes -o json | jq '.items[] | select(.metadata.name=="<hostname>") | .metadata.resourceVersion'  # get resource version
   sudo /opt/bin/kubectl delete node <hostname> --raw="/api/v1/nodes/<hostname>/finalizers" -X DELETE
   ```
   Or as an absolute last resort, edit the node directly:
   ```bash
   sudo /opt/bin/kubectl patch node <hostname> -p '{"metadata":{"finalizers":null}}'
   sudo /opt/bin/kubectl delete node <hostname>
   ```
3. **Destroy VM at CloudStack level** — `userVmService.destroyVm(vmId, true)` + `userVmManager.expunge(vm)`
4. **Remove DB record** — `kubernetesClusterVmMapDao.expunge(vmMapId)`
5. **Recalculate network rules** — same as normal scale-down (firewall rules, port forwarding)
6. **Log a warning** — force-removal is a destructive operation; log it prominently in CloudStack event logs

**API signature:**
```json
POST /cloudstack/api/forceRemoveKubernetesClusterNode
{
  "id": "<cluster-id>",
  "nodeId": "<node-vm-id>"   // or nodeName: "<hostname>"
}
```

Or extend the existing scale API:
```json
POST /cloudstack/api/scaleKubernetesCluster
{
  "id": "<cluster-id>",
  "nodeIds": ["<node-vm-id>"],
  "forceRemove": true   // bypass drain/delete, force at CloudStack level
}
```

### Implementation Notes

**Safety considerations:**
- Force-removal skips pod eviction — running workloads on the node will be disrupted. Document this clearly.
- The node's PersistentVolumes may be left in `Released` state if not using dynamic provisioning with reclaim policy `Delete`.
- Consider adding a `--dry-run` mode that shows what would happen without actually removing anything.
- Require explicit confirmation (e.g., type the node name) for the API to prevent accidental force-removal.

**UI considerations:**
- Add a "Force Remove Node" action in the cluster node list (next to the normal scale-down button).
- Show a warning dialog: "This will bypass Kubernetes drain and forcefully remove the node. Running workloads will be disrupted."
- Grey out the button for nodes that are already in `NotReady` state for > X minutes (suggest force-remove as an option).

**Alternative: dedicated remove worker**
Instead of extending `scaleKubernetesCluster`, create a new `KubernetesClusterForceRemoveNodeWorker` (similar to `KubernetesClusterRemoveWorker` but with the force path). This keeps the normal scale-down flow clean and adds the force-remove as a separate operation.

**Related to:**
- §23 (Node Pool Support) — force-remove would be essential for node pools where a single broken node shouldn't block pool management
- §13 (Health checks) — health checks could detect stuck nodes and suggest force-remove

---

## 24. Node Pool Support

### Problem
CKS currently supports a single flat set of worker nodes — all workers share the same service offering (CPU/RAM/disk), labels, and taints. This is insufficient for real-world workloads that require heterogeneous node types:

- **GPU workloads** — need large VMs with GPU passthrough
- **High-memory workloads** — need memory-optimized node types
- **Spot/preemptible instances** — need a separate, cheaper node pool for fault-tolerant workloads
- **Different disk types** — SSD for stateful workloads, standard for stateless
- **Geographic placement** — nodes across different host racks or availability zones with different characteristics

Currently, users must create multiple separate CKS clusters to achieve this, which fragments their workload and makes cross-pool networking and scheduling complex.

### Proposal: Multiple Worker Node Pools
Allow CKS clusters to define multiple **worker node pools**, each with its own:

| Attribute | Description |
|-----------|-------------|
| **Service offering** | CPU, RAM, disk — different per pool |
| **Node count** | Min/max or fixed count per pool |
| **Labels** | Key-value pairs applied to all nodes in the pool |
| **Taints** | Applied to all nodes in the pool |
| **Disk offering** | Storage type (SSD, standard, etc.) |
| **Host affinity** | Dedicated host or explicit dedication affinity group |
| **Template override** | Per-pool OS template (e.g., different base images) |

**Example cluster definition:**
```
Cluster: my-cks-cluster
  Control nodes: 3 × Standard (2 vCPU, 4 GB)
  Worker pools:
    - name: general
      count: 5
      offering: Standard (2 vCPU, 4 GB)
      labels: { workload-type: general }
      taints: []
    - name: gpu
      count: 2
      offering: GPU (8 vCPU, 32 GB, GPU)
      labels: { workload-type: gpu, accelerator: nvidia-a10 }
      taints: [{ key: nvidia.com/gpu, effect: NoSchedule }]
    - name: spot
      count: { min: 0, max: 10 }
      offering: Spot (2 vCPU, 2 GB)
      labels: { workload-type: spot, preemptible: "true" }
      taints: [{ key: node.kubernetes.io/lifecycle, effect: NoSchedule }]
```

### How It Maps to Existing CKS Architecture

The existing CKS code already has a `NodeType` enum (`CONTROL`, `WORKER`, `ETCD`) and per-node-type service offering overrides. Node pools extend the `WORKER` type into a structured collection:

| Current CKS | Node Pools |
|-------------|------------|
| Single worker count | Multiple pools, each with own count |
| Single worker service offering | Per-pool service offering |
| `KubernetesClusterVmMapVO` (one row per VM) | Unchanged — each pool node still gets its own row |
| `KubernetesClusterScaleWorker` (single count) | Extended to accept pool-level scale operations |
| `KubernetesClusterResourceModifierActionWorker` (single offering) | Extended to accept per-pool offering changes |

### API Changes

**Create cluster:**
```json
POST /cloudstack/api/createKubernetesCluster
{
  "name": "my-cluster",
  "kubernetesversionid": "...",
  "controlnodenumber": 3,
  "workernodetypes": [
    {
      "name": "general",
      "count": 5,
      "serviceofferingid": "...",
      "labels": [{"key": "workload-type", "value": "general"}],
      "taints": [],
      "discofferingid": "..."
    },
    {
      "name": "gpu",
      "count": 2,
      "serviceofferingid": "...",
      "labels": [{"key": "workload-type", "value": "gpu"}],
      "taints": [{"key": "nvidia.com/gpu", "effect": "NoSchedule"}]
    }
  ]
}
```

**Scale pool:**
```json
POST /cloudstack/api/scaleKubernetesCluster
{
  "id": "<cluster-id>",
  "workernodetypes": [
    { "name": "general", "count": 8 },
    { "name": "gpu", "count": 2 }
  ]
}
```

**Change pool offering:**
```json
POST /cloudstack/api/scaleKubernetesCluster
{
  "id": "<cluster-id>",
  "workernodetypes": [
    { "name": "general", "serviceofferingid": "..." }
  ]
}
```

### Implementation Notes

**Database changes:**
- New table `kubernetes_worker_pool` (or extend `kubernetes_cluster_vm_map`):
  - `id` (auto-increment)
  - `kubernetes_cluster_id` (FK)
  - `name` (pool name, unique per cluster)
  - `service_offering_id` (FK)
  - `disk_offering_id` (FK, nullable)
  - `count` (current count)
  - `min_count` (for autoscaling pools, nullable)
  - `max_count` (for autoscaling pools, nullable)
  - `labels` (JSON blob)
  - `taints` (JSON blob)
  - `template_id` (per-pool template override, nullable)
  - `host_affinity_group_id` (per-pool dedicated host, nullable)

**Worker changes:**
- `KubernetesClusterScaleWorker` — extend `scaleCluster()` to accept per-pool scale requests. Each pool is scaled independently (new VMs provisioned, old VMs drained and destroyed).
- `KubernetesClusterResourceModifierActionWorker` — extend offering change to work per-pool.
- `KubernetesClusterStartWorker` — during bootstrap, iterate over pools and create VMs per pool specification.

**Cloud-init changes:**
- Worker cloud-init template already supports joining any cluster — no changes needed for the join flow.
- Labels and taints are applied via `kubeadm join` `--node-name` + `kubectl label/taint` after join, or via cloud-init `runcmd`.

**UI changes:**
- Add a "Worker Pools" section during cluster creation with a dynamic table (add/remove pools).
- Show pool details in the cluster view with per-pool scale controls.
- Display labels and taints per pool.

**Scaling considerations:**
- Pool scale-up: provision new VMs with the pool's offering, attach ISO, wait for Ready.
- Pool scale-down: drain and destroy VMs from the targeted pool only (respecting pool name).
- Offering change: for each VM in the pool, call `upgradeVirtualMachine` with the new offering. This is a live resize on supported hypervisors.
- Per-pool autoscaling: extend the existing autoscaler to support pool-scoped scaling (current autoscaler is cluster-wide).

**Backward compatibility:**
- Existing clusters with a single worker type continue to work unchanged.
- The `workernodetypeid` parameter (single worker type) remains supported as a convenience alias for a single pool called `default`.
- `createKubernetesCluster` with the legacy single-worker parameters automatically creates a single `default` pool.

### Relationship to Other Improvements
- **§10 (Reorder ISO attachment):** Parallel ISO attachment benefits are amplified with multiple pools.
- **§13 (Health checks):** Per-pool health monitoring would be valuable — different pools may have different failure modes (e.g., spot nodes evicting more frequently).
- **§3 (IAM integration):** RBAC could be scoped per-pool or per-label set for fine-grained access control.

---

## 25. Scale Control Plane Nodes (Add/Remove HA Control Plane Nodes)

### Why This Is Necessary

CKS currently allows scaling worker nodes up and down via `scaleKubernetesCluster`, but **control plane node count is immutable after cluster creation**. This creates several critical failure scenarios:

**1. Failed control plane node recovery**
When a control plane node fails (disk full, kernel panic, hardware failure, kubelet crash-loop), the cluster loses quorum if it drops below the minimum required for etcd consensus. With 3 control nodes, losing 1 still leaves quorum (2/3). But if a second fails, the cluster becomes **completely unresponsive** — API server rejects requests, no new workloads can be scheduled, and the management server cannot manage the cluster because it communicates through the API.

The user has no way to recover by adding a replacement control plane node through the API. They would need to manually rebuild the node and join it via `kubeadm join --control-plane`, which is error-prone and requires access to the certificate key (stored on the remaining healthy control nodes).

**2. Scaling up for increased workload**
As workloads grow, control plane resources (CPU, RAM) may need to scale. Currently the only option is to change the service offering (CPU/RAM) of existing control nodes — but you cannot add a 4th or 5th control plane node to distribute the load. This is a hard limit.

**3. Disaster recovery and maintenance**
If the management server needs to perform maintenance that requires stopping all control nodes temporarily, there is no way to spin up temporary replacement control nodes to maintain cluster availability during the outage window.

**4. Multi-zone / availability zone distribution**
For production deployments, control plane nodes should be distributed across availability zones for fault tolerance. Currently, if a zone goes down, all control plane nodes in that zone are lost simultaneously. There is no way to add control plane nodes in a different zone without recreating the entire cluster.

### Current State

The infrastructure is partially in place:

| Component | Status | Notes |
|-----------|--------|-------|
| `k8s-control-node-add.yml` cloud-init template | ✅ Exists | Supports `kubeadm join --control-plane --certificate-key` |
| `KubernetesClusterAddWorker.java` | ✅ Exists | Listed in source reference, but appears to be for external node addition, not control plane scaling |
| `ScaleKubernetesClusterCmd` API | ✅ Exists | Only scales worker count, not control/etcd count |
| `controlnodenumber` parameter | ✅ Exists in create | Only used during cluster creation, not in scale API |
| Certificate key management | ❌ Missing | No mechanism to generate/retrieve certificate keys for new control plane joins |
| API/UI for control plane scaling | ❌ Missing | No way to add/remove control plane nodes post-creation |

### Proposal: `scaleControlPlane` API

Add a new API command `scaleKubernetesClusterControlPlane` (or extend `scaleKubernetesCluster` with a `controlNodeCount` parameter) that supports adding and removing HA control plane nodes:

**Scale up — add control plane node:**

1. **Generate certificate key** — if no existing key is available, generate one:
   ```bash
   sudo /opt/bin/kubeadm init phase upload-certs --upload-certs
   ```
   This returns a certificate key used for secure control plane node joins.

2. **Provision VM** — create a new VM with the control plane service offering and `k8s-control-node-add.yml` cloud-init

3. **Attach binaries ISO** — attach the current version's ISO (same as existing nodes)

4. **Join control plane** — cloud-init runs:
   ```bash
   sudo /opt/bin/kubeadm join <control-ip>:6443 \
     --token <token> \
     --certificate-key <cert-key> \
     --control-plane \
     --discovery-token-unsafe-skip-ca-verification
   ```

5. **Wait for Ready** — poll `kubectl get nodes` until the new node shows `Ready`

6. **Detach ISO** — remove the ISO from the new VM

7. **Update DB record** — increment `controlnodenumber` in `KubernetesClusterVO`

**Scale down — remove control plane node:**

⚠️ **Critical safety requirement:** Control plane scale-down must respect etcd quorum. The cluster must always maintain a majority of control nodes.

1. **Validate quorum** — ensure the resulting node count is > total/2 (e.g., 3→2 is OK, 2→1 is blocked)
2. **Select node to remove** — prefer nodes with the lowest workload pressure, or let user specify
3. **Cordon the node:**
   ```bash
   sudo /opt/bin/kubectl cordon <hostname>
   ```
4. **Drain workloads** (if any non-control workloads are on the node):
   ```bash
   sudo /opt/bin/kubectl drain <hostname> --ignore-daemonsets --delete-emptydir-data
   ```
5. **Remove from Kubernetes:**
   ```bash
   sudo /opt/bin/kubectl delete node <hostname>
   ```
6. **Remove from etcd** — if this is the last node being removed or if etcd membership needs cleanup:
   ```bash
   sudo /opt/bin/etcdctl member remove <member-id>
   ```
7. **Destroy VM** — `userVmService.destroyVm()` + `userVmManager.expunge()`
8. **Remove DB record** — `kubernetesClusterVmMapDao.expunge()`
9. **Update network rules** — recalculate SSH port forwarding range
10. **Update DB record** — decrement `controlnodenumber`

**API signature:**
```json
POST /cloudstack/api/scaleKubernetesCluster
{
  "id": "<cluster-id>",
  "controlNodeCount": 4,        // scale to 4 control nodes
  "workernodetypeid": "...",    // existing worker scaling (unchanged)
  "workernodenumbers": 5        // existing worker count (unchanged)
}
```

Or as a dedicated API:
```json
POST /cloudstack/api/scaleKubernetesClusterControlPlane
{
  "id": "<cluster-id>",
  "controlNodeCount": 4
}
```

### Implementation Notes

**Certificate key management:**
- Store the certificate key in `KubernetesClusterDetailsVO` after bootstrap (similar to how `kubeConfigData` is stored)
- If the key is lost (e.g., after a full cluster restart where all control nodes were stopped), regenerate it from any remaining healthy control node
- If ALL control nodes are down and the key is lost, the cluster cannot scale control plane — this is a known limitation that requires manual recovery

**Quorum safety:**
- Minimum control plane count: 1 (single-node cluster, no HA)
- For HA clusters: minimum 3, and scale-down must never reduce below `(total + 1) / 2`
- Add validation in the API layer: `if (newCount <= currentCount / 2) throw new InvalidParameterValueException("Cannot reduce control plane below quorum")`

**Service offering changes:**
- The existing `scaleKubernetesCluster` already supports changing service offering for any node type via `controlServiceOfferingId`
- This improvement focuses on **count** changes, not offering changes
- Offering changes for control nodes already work — they call `upgradeVirtualMachine` on the VM

**Cloud-init template reuse:**
- The existing `k8s-control-node-add.yml` template already supports HA control plane join
- It uses `kubeadm join --control-plane --certificate-key` which is the standard kubeadm pattern
- No template changes needed — just wire it up in the worker

**Network rules:**
- Adding control nodes does NOT change the SSH port forwarding range (control nodes don't get SSH port forwards — only workers do)
- Adding control nodes DOES change the etcd port forwarding range if etcd is co-located on control nodes
- If external etcd is used (separate etcd nodes), no network rule changes are needed for control plane scaling

**UI considerations:**
- Add a "Control Plane" section in the cluster view showing current count and a +/- control
- Show individual control node status (Ready/NotReady) with health indicators
- Grey out the "+" button if the cluster is at its maximum (configurable, default 5)
- Grey out the "-" button if the cluster is at minimum quorum
- Show a warning when the cluster has only 1 control node (no HA)

**Error handling:**
- If `kubeadm join --control-plane` fails, the new VM should be destroyed and the operation rolled back
- If the certificate key is invalid or expired, regenerate it and retry once
- If etcd membership is corrupted, log a clear error message suggesting manual etcdctl recovery

### Relationship to Other Improvements
- **§23 (Force-remove failed nodes):** Force-remove is complementary — if a control plane node is frozen, force-remove can recover it, but you still need the ability to add a replacement
- **§13 (Health checks):** Health checks should detect degraded control plane (lost quorum, missing nodes) and alert the user to scale up
- **§17 (Restrict SSH access):** Control plane nodes should have restricted SSH access (management server key only)
- **§24 (Node pool support):** Node pools could extend to control plane pools with per-zone placement

---

**Status Legend:**
- 🔴 Not started
- 🟡 In discussion / draft proposal
- 🟢 Implemented in upstream CloudStack

| # | Improvement | Status |
|---|-------------|--------|
| 1 | Pre-import images on all nodes during upgrade | 🔴 |
| 2 | Replace Dashboard with Headlamp | 🟢 (PR #12776 merged Mar 2026) |
| 3 | Dex/Pinniped + CloudStack IAM integration | 🔴 |
| 4 | Full air-gapped / offline deployment support | 🔴 |
| 5 | Restrictive default firewall rules (API + SSH) | 🔴 |
| 6 | Fix ISO build script download logic | 🔴 |
| 7 | Validate YAML manifests before including in ISO | 🔴 |
| 8 | Verify all container images exist before finalizing ISO | 🔴 |
| 9 | Decouple dashboard verification from CCM/CSI deployment | 🔴 |
| 10 | Reorder ISO attachment for faster bootstrap | 🔴 |
| 11 | Add timeout checkpoints during upgrade | 🔴 |
| 12 | Add retry logic to cloud-init scripts | 🔴 |
| 13 | Add health checks between cluster lifecycle phases | 🔴 |
| 14 | Use short-lived bootstrap tokens with rotation | 🔴 |
| 15 | Issue short-lived TLS certificates | 🔴 |
| 16 | Protect CloudStack API credentials from CLI exposure | 🔴 |
| 17 | Restrict SSH access scope to control node only | 🔴 |
| 18 | Secure kubeconfig stored in the database | 🔴 |
| 19 | Validate cloud-init userdata signatures | 🔴 |
| 20 | Network isolation for cluster management traffic | 🔴 |
| 21 | Implement kubeadm token cleanup after bootstrap | 🔴 |
| 22 | Make dashboard deployment optional during bootstrap | 🔴 |
| 23 | Force-remove failed/unreachable nodes | 🔴 |
| 24 | Node pool support | 🔴 |
| 25 | Scale control plane nodes (add/remove HA control plane) | 🔴 |

> Items #6–#21 sourced from [CKS Detailed Analysis — Bootstrap & Upgrade](../../architecture/cks-analysis.md).

---

## See Also

