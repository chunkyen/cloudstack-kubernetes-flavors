
# CKS Improvements — Suggested Robustness & Security Enhancements

Recommendations for making the CloudStack Kubernetes Service (CKS) lifecycle more robust and secure, based on [detailed bootstrap & upgrade analysis](../../architecture/cks-analysis.md). Organized by priority.

### Robustness Improvements

#### 1. Fix the ISO Build Script's Brittle Download Logic

**Problem**: `curl -sSL` without `-f` silently produces garbage files on 404. No checksums. No fallback.

**Fix**:
- Add `-f` flag to all `curl` commands in `create-kubernetes-binaries-iso.sh` so the build **fails** if a URL returns an error
- Add SHA256 checksum verification for downloaded binaries where checksums are available
- Add a retry mechanism: `curl --retry 3 --retry-delay 5`
- Validate downloaded YAML files with `python3 -c "import yaml; yaml.safe_load(open('file.yaml'))"` before packaging

#### 2. Decouple Dashboard Verification from CCM/CSI Deployment

**Problem**: The post-bootstrap pipeline in `startKubernetesClusterOnCreate()` blocks CCM, CSI, and control node tainting behind the dashboard pod being `Running`. If the dashboard pod fails, the cluster never reaches `Running` state — even though the cluster is functionally complete.

**Fix** (reorder in `KubernetesClusterStartWorker.startKubernetesClusterOnCreate()`):
```java
// Current order:
//   5. kubeconfig -> 6. dashboard check -> 7. taint -> 8. CCM -> 9. CSI
// Proposed order:
//   5. kubeconfig -> 6. taint -> 7. CCM -> 8. CSI -> 9. dashboard check (non-blocking)
```
- Move `deployProvider()` and `deployCsiDriver()` **before** the dashboard check
- Make the dashboard check non-blocking: log a warning instead of throwing, or transition to a `Running (Dashboard Pending)` sub-state
- Reduce the dashboard poll interval from 15s to lower values early on (exponential backoff)

#### 3. Reorder ISO Attachment for Faster Bootstrap

**Problem**: Sequential ISO attachment means the last worker VM in a large cluster waits minutes before receiving its ISO, extending total bootstrap time unnecessarily.

**Fix**:
- Parallelize ISO attachment where the hypervisor supports it (e.g., issue all `attachIso` calls without waiting for each to complete, then poll all)
- Alternatively: batch-attach ISOs per node type (all workers in parallel)
- For very large clusters: consider pre-seeding the ISO in the VM template so cloud-init doesn't need to poll-wait at all

#### 4. Add Timeout Checkpoints During Upgrade

**Problem**: The upgrade timeout is checked only between major steps, not within long-running operations like `kubeadm upgrade apply`.

**Fix**:
- Add a background watchdog thread that kills the upgrade script if the overall timeout is exceeded
- Add per-step sub-timeouts: the upgrade script itself should have an internal timeout
- Implement a "best-effort rollback" — after a partial upgrade failure, cordon all already-upgraded nodes to prevent scheduling surprises

#### 5. Validate YAML Manifests Before Including in ISO

**Problem**: The build script blindly packs any downloaded file as `*.yaml`. Invalid YAML (HTML error pages, truncated files) causes cloud-init failures.

**Fix**:
```bash
# In create-kubernetes-binaries-iso.sh, after downloading each YAML:
if ! python3 -c "import yaml; yaml.safe_load(open('${file}'))"; then
    echo "ERROR: ${file} is not valid YAML"
    exit 1
fi
```

#### 6. Verify All Container Images Exist Before Finalizing ISO

**Problem**: The ISO is built even if some container images failed to pull or export.

**Fix**:
- Count expected images from YAML manifests
- Count actual `*.tar` files in `docker/`
- If counts don't match, fail the build with a list of missing images
- For each `ctr image pull`, check exit code explicitly (the build script currently doesn't)

#### 7. Add Retry Logic to cloud-init Scripts

**Problem**: The `deploy-kube-system` systemd service restarts on failure, but `kubeadm init` fails on restart because the cluster is already initialized — creating an infinite loop.

**Fix**:
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

#### 8. Add Health Checks Between Cluster Lifecycle Phases

**Problem**: After bootstrap, there's no ongoing health monitoring. A cluster could degrade silently.

**Fix**:
- Add a periodic health check scanner in the management server that:
  - Verifies the API server is reachable
  - Checks node count matches expected
  - Reports degraded clusters via CloudStack events/alerts
- Expose cluster health as a new field on `KubernetesClusterResponse`

### Security Improvements

#### 9. Use Short-Lived Bootstrap Tokens with Rotation

**Problem**: The kubeadm bootstrap token is derived from the cluster UUID (`generateClusterToken()`) and set with `--token-ttl 0` (never expires). It's embedded in every node's cloud-init userdata and the kubeadm config on disk.

**Fix**:
- Use `--token-ttl 1h` (or the duration of the start timeout) instead of `0`
- Delete the bootstrap token via `kubeadm token delete <token>` after all nodes join
- Generate tokens with `crypto.random()` instead of deriving from cluster UUID
- Store tokens in `KubernetesClusterDetailsVO` with encryption at rest

#### 10. Issue Short-Lived TLS Certificates

**Problem**: The API server TLS certificate is issued with a **3650-day (10-year)** validity via CloudStack CA Manager.

```java
// KubernetesClusterStartWorker.java
final Certificate certificate = caManager.issueCertificate(
    null, addresses, 3650,  // ← 10 years
    null);
```

**Fix**:
- Reduce to 1 year (365 days) or less
- Implement automatic certificate renewal before expiry (kubeadm supports `kubeadm certs renew`)
- Consider using `kubeadm init --cert-dir` with pre-generated short-lived certs managed by cert-manager

#### 11. Protect CloudStack API Credentials

**Problem**: The CloudStack API key and secret are passed as command-line arguments to the `deploy-cloudstack-secret` script:

```bash
sudo /opt/bin/deploy-cloudstack-secret -u '<api-url>' -k '<key>' -s '<secret>'
```

This exposes API credentials in:
- Process listings (`ps aux`)
- Shell history
- systemd journal
- SSH command logs

**Fix**:
- Write credentials to a temp file with restricted permissions (`0600`), pass the file path instead:
  ```bash
  echo "[Global]\napi-url = $URL\napi-key = $KEY\nsecret-key = $SECRET" > /tmp/cloud-config.$$ && chmod 600 /tmp/cloud-config.$$
  sudo /opt/bin/deploy-cloudstack-secret --config-file /tmp/cloud-config.$$
  shred -u /tmp/cloud-config.$$
  ```
- Use Kubernetes secrets with restricted RBAC for the provider instead of a generic `cloudstack-secret`
- Rotate API keys periodically

#### 12. Restrict SSH Access Scope

**Problem**: The management server's SSH key is injected into **every** cluster node (`{{ k8s.ssh.pub.key }}`), granting passwordless root-equivalent access (user `cloud` has `NOPASSWD:ALL`).

**Fix**:
- Inject the management server key only on the control node (workers don't need it for normal operation)
- Create a dedicated, restricted CKS management user instead of using the general `cloud` user
- Use SSH certificates with short lifetimes instead of permanent authorized_keys
- Add audit logging for all SSH sessions originating from the management server

#### 13. Secure the Kubeconfig Stored in the Database

**Problem**: The cluster's admin kubeconfig is stored as base64 (not encrypted) in `KubernetesClusterDetailsVO` with key `kubeConfigData`.

**Fix**:
- Encrypt the kubeconfig at rest using CloudStack's existing encryption framework
- Create a dedicated, scoped service account + kubeconfig instead of storing the full `cluster-admin` kubeconfig
- Rotate kubeconfigs on a schedule (re-generate from the control node)

#### 14. Validate cloud-init Userdata Signatures

**Problem**: cloud-init userdata is generated by the management server and injected into VMs. There's no integrity check — if the management server is compromised, arbitrary cloud-init could be injected.

**Fix**:
- Sign cloud-init userdata with the CloudStack CA or an HMAC
- Have the VM validate the signature before executing
- This is especially important for the `NOPASSWD:ALL` sudo access granted to the `cloud` user

#### 15. Network Isolation for the Cluster Management Traffic

**Problem**: The management server communicates with cluster VMs over the same public/guest network. SSH (port 2222) and API (port 6443) are exposed via port forwarding.

**Fix**:
- Use a dedicated management network (not the guest network) for SSH access to cluster VMs
- Firewall rules should restrict SSH access to only the management server's IP, not `0.0.0.0/0`
- Current code opens SSH to the world:
  ```java
  sourceCidrList.add("0.0.0.0/0");  // ← should be restricted
  ```

#### 16. Implement kubeadm Token Cleanup After Bootstrap

**Problem**: The bootstrap token persists indefinitely (`--token-ttl 0`), allowing anyone with network access to join nodes to the cluster.

**Fix**:
- After `validateKubernetesClusterReadyNodesCount()` succeeds, SSH in and run:
  ```bash
  sudo /opt/bin/kubeadm token delete <token>
  ```
- This should happen before `stateTransitTo(OperationSucceeded)`

### Prioritized Implementation Order

| Priority | Item | Impact |
|----------|------|--------|
| 🔴 Critical | #1 - Fix ISO build script (add `-f` to curl, validate YAML) | Prevents silent ISO corruption |
| 🔴 Critical | #2 - Decouple dashboard verification from CCM/CSI | Fixes the "stuck in Starting" problem entirely |
| 🔴 Critical | #9 - Use short-lived bootstrap tokens, delete after join | Security: tokens never expire today |
| 🟠 High | #11 - Don't pass API credentials as CLI args | Security: they're in `ps aux` and logs |
| 🟠 High | #15 - Restrict firewall to management server IP only | Security: `0.0.0.0/0` SSH access |
| 🟠 High | #7 - Fix deploy-kube-system restart loop | Robustness: prevents infinite restart on failure |
| 🟡 Medium | #3 - Parallelize ISO attachment | Performance: faster bootstrap for large clusters |
| 🟡 Medium | #10 - Shorten TLS cert validity | Security: 10-year certs |
| 🟡 Medium | #13 - Encrypt kubeconfig at rest | Security: plaintext admin kubeconfig in DB |
| 🟢 Lower | #4 - Upgrade timeout watchdogs | Robustness: prevents hung upgrades |
| 🟢 Lower | #6 - Verify image counts in ISO build | Robustness: build-time checking |
| 🟢 Lower | #12 - Restrict SSH to control node only | Security: reduce attack surface |

---

## See Also

- [CKS Detailed Analysis — Bootstrap & Upgrade](../../architecture/cks-analysis.md)
