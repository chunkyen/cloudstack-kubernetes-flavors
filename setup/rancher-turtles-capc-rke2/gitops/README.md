# GitOps Manifests for CAPC Cluster Creation

These manifests are designed for use with [Fleet GitOps](../gitops.md). Copy them to your GitOps repo (e.g., Gitea), replace placeholder values with real ones, and push.

## Files

| File | Purpose | Contains Secrets? |
|------|---------|-------------------|
| `fleet-gitrepo.yaml` | Fleet GitRepo + Gitea auth secret (apply on mgmt cluster) | **Yes** — replace `<GITEA_TOKEN>` |
| `00-namespace-credentials.yaml` | Namespace + CloudStack API credentials (pushed to Gitea) | **Yes** — replace placeholders |
| `10-cluster.yaml` | Cluster, CloudStackCluster, control plane, workers | No |
| `20-ccm-csi-configmap.yaml` | CCM + CSI manifests as ConfigMap data | **Yes** — embedded workload secret has placeholders |
| `21-clusterresourceset.yaml` | ClusterResourceSet for CCM/CSI | No |

> **Note:** `fleet-gitrepo.yaml` is applied directly on the management cluster with `kubectl apply` — it is NOT pushed to the Gitea repo. It tells Fleet which repo to watch and how to authenticate.

## Usage

```bash
# 1. Copy to your GitOps repo
cp gitops/*.yaml /path/to/your-gitea-repo/

# 2. Replace placeholders
#    <CLOUDSTACK_API_URL>     → CloudStack API endpoint
#    <CLOUDSTACK_API_KEY>     → CloudStack API key
#    <CLOUDSTACK_SECRET_KEY>  → CloudStack secret key
#    <DISK_OFFERING_ID>       → CloudStack disk offering UUID for StorageClass
#    192.168.200.63           → Free public IP for control plane endpoint
#    Other values (zone, offerings, template, SSH key) as needed

# 3. Commit and push
cd /path/to/your-gitea-repo
git add -A
git commit -m "Create cluster"
git push origin main
```

## Important

- **Do NOT commit real API keys to a public Git repo.** These manifests use `<PLACEHOLDER>` values. Only commit real keys to a private, access-controlled Gitea instance.
- **Do NOT include `rke2-providers.yaml`** in the GitOps repo — the RKE2 providers are already installed on the management cluster by Rancher Turtles. Including them causes Fleet ownership conflicts.
- Keep `00-namespace-credentials.yaml` in the repo during cluster deletion — CAPC needs the credentials to destroy VMs. See [deletion guide](../gitops.md#5-deleting-clusters-via-gitops).