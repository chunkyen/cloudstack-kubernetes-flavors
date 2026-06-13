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

## 6. Restrictive Default Firewall Rules (API + SSH)

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
| 6 | Restrictive default firewall rules (API + SSH) | 🔴 |

