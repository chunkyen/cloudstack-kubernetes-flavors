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
CKS is designed with an implicit assumption of internet connectivity. While [cks-offline.md](./cks-offline.md) documents workarounds, air-gapped deployments remain a second-class experience:
- Initial cluster creation works offline if the ISO is self-contained ✅
- Upgrades fail when new shared images (e.g., `pause:3.10.1`) are introduced ❌
- Custom Cilium ISOs break due to digest-pinned image references ❌
- No built-in tooling for validating ISOs offline before deployment ❌
- Documentation explicitly states "complete offline provisioning is not supported" 🚫

### Proposal: First-Class Air-Gapped Support
Make CKS fully functional in environments with zero outbound internet access, without manual workarounds.

**Key components:**
1. **Pre-import all images on all nodes during upgrades** (see §1) — eliminates the pause container mismatch issue natively
2. **Strip digest pins from generated manifests by default** (building on [offline Cilium script](./cks-custom-iso.md#option-c-build-cilium-offline-iso)) — prevents registry verification failures offline
3. **Offline ISO validation tooling** — automated pre-flight checks that verify:
   - All referenced images exist in the ISO's `docker/` directory
   - Image tags match manifest references (no digest-only refs)
   - No external URLs remain in bundled YAMLs
4. **Air-gapped deployment documentation & best practices** — official guide covering:
   - Building self-contained custom ISOs
   - Local registry mirroring setup
   - Pre-import workflows for upgrades
   - Testing methodology to validate offline readiness before production use
5. **Configuration flag: `cks.offlineMode=true`** — enables strict offline behavior (skip external registry lookups, enforce tag-only image refs, fail-fast on missing local images)

### Overlap with §1 (Pre-Import Images)
Section 1 is a prerequisite for this proposal — pre-importing images during upgrades solves the most common offline failure mode. This broader proposal wraps that fix into a complete air-gapped strategy.

### Implementation Notes
- Start with §1 as the highest-impact change (fixes upgrade failures)
- Make digest stripping opt-in via build script flag, then default to it
- Validation tooling can be a separate CLI utility or integrated into ISO build scripts
- Consider an official "Air-Gapped Deployment" certification test suite in CloudStack CI

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

