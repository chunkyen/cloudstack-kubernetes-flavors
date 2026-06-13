# CKS Improvements — Proposals & Ideas

> ⚠️ **WIP** — This is a living document tracking proposed improvements to CloudStack Kubernetes Service (CKS). Contributions and feedback welcome.

---

## 1. Upgrade Logic: Pre-Import Images on All Nodes First

### Problem
Currently, CKS imports new container images only onto the node being actively upgraded. When intermediate Jobs (health checks, etc.) are scheduled on non-upgraded nodes, those nodes lack newer image versions — causing offline upgrades to fail with `ImagePullBackOff`.

See [cks-offline.md §4.1](./cks-offline.md#41-pre-built-calico-iso---pause-container-issue) for detailed analysis.

### Proposed Fix
Modify the CKS upgrade orchestration logic to **pre-import all required images from the target ISO onto every cluster node** before upgrading any single node.

This guarantees:
- Intermediate Jobs can be safely scheduled on any node without hitting `ImagePullBackOff`
- Offline/air-gapped upgrades work seamlessly across all K8s versions
- No manual workaround needed (#5 in cks-offline.md)

### Implementation Notes
- Requires changes to the `cloudstack-kubernetes-service` plugin code
- Should be backward-compatible with online deployments (no regression risk)
- Consider making this configurable via advanced settings (`cks.upgrade.preimportImages=true/false`)

---

## 2. Replace Kubernetes Dashboard with Headlamp

### Problem
The Kubernetes Dashboard is deprecated and has limited functionality. CKS currently bundles it by default, but the community has moved on to more modern alternatives.

### Proposal: Default to Headlamp
[Headlamp](https://github.com/kubernetes-sigs/headlamp) (Kubernetes SIG) is a modern, actively-maintained web UI for Kubernetes clusters with:
- Plugin ecosystem for extensibility
- Better resource management UX
- Multi-cluster support out of the box
- Active community and upstream SIG backing

### Implementation Notes
- Replace `dashboard.yaml` references in ISO build scripts with Headlamp manifests
- Update CKS deployment logic to install Headlamp instead of Dashboard by default
- Consider making it configurable (Dashboard as fallback for legacy deployments)
- May require changes to both the official Calico script and community Cilium scripts

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

## 4. Node Lifecycle Management: Remove/Replace Failed Nodes

### Problem
Currently, CKS supports **scale-up** (increasing vCPU/RAM via offering change) and **scale-out** (adding more nodes), but lacks a native mechanism to safely remove or replace failed nodes. When a node becomes `NotReady`, loses connectivity, or is permanently decommissioned, it remains in the cluster. Administrators must manually run `kubectl drain` and `kubectl delete node`, which falls outside CKS orchestration and can leave orphaned resources or inconsistent state.

### Proposal: Native Scale-In & Node Replacement
Add built-in workflows for safe node lifecycle management:
- **Remove/Scale-In:** Gracefully cordon, drain, and remove a specified node via UI/API (enhancing `removeVirtualMachinesFromKubernetesCluster`)
- **Replace Failed Node:** One-click workflow that detects `NotReady` nodes, provisions a replacement VM with matching labels/taints, imports required images, drains the old node, and decommissions it automatically

### Implementation Notes
- Leverage Kubernetes drain logic internally before terminating the CloudStack VM
- Expose node health status in the CKS UI (e.g., highlight `NotReady` or degraded nodes)
- Ensure stateful workloads (PVs, DaemonSets) are handled safely during removal
- Could integrate with a custom operator for auto-healing instead of manual intervention

---

## 5. Full Air-Gapped / Offline Deployment Support

### Problem
CKS currently assumes internet connectivity is available as a fallback. While [cks-offline.md](./cks-offline.md) documents workarounds, air-gapped deployments remain second-class citizens — upgrades fail silently without the manual pre-import workaround (§1), and documentation explicitly states "complete offline provisioning... is not supported".

### Proposal: First-Class Air-Gapped Support
Make CKS fully operational in environments with zero outbound internet connectivity. This builds directly on §1 (pre-import images) but extends further:
- **No fallback to external registries** — all image references must resolve from local ISO or internal registry
- **Manifest validation at build time** — verify that every `image:` reference in bundled YAMLs has a matching tarball in the ISO's `docker/` directory
- **Strict offline mode flag** — add `cks.offlineMode=true` advanced setting that:
  - Disables any attempt to reach external registries during cluster creation/upgrade
  - Fails fast with actionable error messages if required images are missing locally
  - Skips digest verification (requires tag-only refs, see §4.2 offline Cilium script)
- **Offline upgrade path** — combine §1's pre-import logic with automatic validation that all target-version images exist before starting the upgrade

### Overlap with §1 (Pre-Import Images)
Section 1 is a prerequisite for this proposal — pre-importing images during upgrades solves the most common offline failure mode. This broader proposal wraps that fix into a complete air-gapped strategy.

---

**Status Legend:**
- 🔴 Not started
- 🟡 In discussion / draft proposal
- 🟢 Implemented in upstream CloudStack

| # | Improvement | Status |
|---|-------------|--------|
| 1 | Pre-import images on all nodes during upgrade | 🔴 |
| 2 | Replace Dashboard with Headlamp | 🔴 |
| 3 | Dex/Pinniped + CloudStack IAM integration | 🔴 |
| 4 | Native scale-in & failed node replacement | 🔴 |
| 5 | Full air-gapped / offline deployment support | 🔴 |

