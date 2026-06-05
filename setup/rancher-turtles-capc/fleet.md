# Fleet GitOps Integration

This guide covers using Rancher Fleet to manage CKS clusters provisioned via CAPC in a GitOps workflow.

## Overview

Fleet enables:
- **GitOps cluster management** — cluster configs stored in Git, auto-synced
- **Multi-cluster deployment** — deploy workloads across many clusters from one source
- **Drift detection** — detect and remediate config drift
- **Bundle tracking** — track which clusters have which workloads

## Prerequisites

- Rancher + Turtles + CAPC deployed
- At least one CKS cluster provisioned via CAPI
- Git repository with cluster configs and workload manifests
- `kubectl` configured with the Rancher local cluster

## Step 1: Configure Fleet

### Enable Fleet in Rancher

Fleet is included with Rancher. Enable it:

1. In Rancher UI: **Global → Fleet** — should show as Active
2. If not active, check Fleet system charts in **Local Cluster → System Project**

### Create a Cluster Group

```yaml
# fleet/cluster-group.yaml
apiVersion: fleet.cattle.io/v1alpha1
kind: ClusterGroup
metadata:
  name: cks-clusters
  namespace: fleet-default
spec:
  selector:
    matchExpressions:
      - key: fleet.cattle.io/cluster-name
        operator: Exists
```

```bash
kubectl apply -f fleet/cluster-group.yaml
```

## Step 2: GitOps Cluster Config

### Repository Resource

```yaml
# fleet/repo.yaml
apiVersion: fleet.cattle.io/v1alpha1
kind: GitRepo
metadata:
  name: cks-cluster-configs
  namespace: fleet-default
spec:
  repo: https://github.com/<your-org>/cks-cluster-configs
  branch: main
  paths:
    - clusters
  clusterSelector:
    matchExpressions:
      - key: fleet.cattle.io/cluster-name
        operator: Exists
  targetNamespace: cks-clusters
```

### Cluster Config in Git

```yaml
# clusters/cks-cluster-1.yaml
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: cks-cluster-1
  namespace: default
spec:
  clusterNetwork:
    pods:
      cidrBlocks: ["10.244.0.0/16"]
    serviceDomain: cluster.local
  controlPlaneRef:
    apiVersion: controlplane.cluster.x-k8s.io/v1beta1
    kind: KubeadmControlPlane
    name: cks-cluster-1-control-plane
  infrastructureRef:
    apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
    kind: CloudStackCluster
    name: cks-cluster-1
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: CloudStackCluster
metadata:
  name: cks-cluster-1
  namespace: default
spec:
  controlPlaneEndpoint:
    host: "<load-balancer-ip>"
    port: 6443
  network:
    name: "<network-name-or-id>"
  zone:
    name: "<zone-name-or-id>"
```

### Apply and Sync

```bash
# Push config to Git repo
# Fleet will auto-detect and apply changes

# Monitor sync status
kubectl get gitrepo cks-cluster-configs -n fleet-default
kubectl get bundles -n fleet-default
```

## Step 3: Deploy Workloads via Fleet

### Bundle Resource

```yaml
# fleet/bundle.yaml
apiVersion: fleet.cattle.io/v1alpha1
kind: Bundle
metadata:
  name: cks-apps
  namespace: fleet-default
spec:
  clusters:
    - groupBy: metadata.labels.environment
      selector:
        matchExpressions:
          - key: fleet.cattle.io/cluster-name
            operator: Exists
  images:
    - name: nginx
      image: nginx:1.25
  resources:
    - name: nginx-deployment.yaml
      content: |
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: nginx
          namespace: default
        spec:
          replicas: 2
          selector:
            matchLabels:
              app: nginx
          template:
            metadata:
              labels:
                app: nginx
            spec:
              containers:
                - name: nginx
                  image: nginx:1.25
                  ports:
                    - containerPort: 80
```

### Deploy via GitRepo

```yaml
# fleet/workload-repo.yaml
apiVersion: fleet.cattle.io/v1alpha1
kind: GitRepo
metadata:
  name: cks-workloads
  namespace: fleet-default
spec:
  repo: https://github.com/<your-org>/cks-workloads
  branch: main
  paths:
    - apps
  clusterGroup: cks-clusters
  targetNamespace: apps
```

## Step 4: Multi-Cluster Management

### Cluster Labels

Label clusters for targeted deployments:

```yaml
# Label a cluster
kubectl label cluster cks-cluster-1 environment=production
kubectl label cluster cks-cluster-1 region=us-east
```

### Targeted Deployments

```yaml
# fleet/prod-only.yaml
apiVersion: fleet.cattle.io/v1alpha1
kind: GitRepo
metadata:
  name: prod-only
  namespace: fleet-default
spec:
  repo: https://github.com/<your-org>/cks-workloads
  branch: main
  paths:
    - prod-apps
  clusterSelector:
    matchExpressions:
      - key: environment
        operator: In
        values: [production]
```

## Step 5: Drift Detection

### Enable Drift Detection

```yaml
# Enable drift detection on a GitRepo
apiVersion: fleet.cattle.io/v1alpha1
kind: GitRepo
metadata:
  name: cks-cluster-configs
  namespace: fleet-default
spec:
  repo: https://github.com/<your-org>/cks-cluster-configs
  branch: main
  paths:
    - clusters
  driftDetection:
    mode: warn  # warn, remediate, or disable
    ignore:
      - resources:
          - kind: Secret
            name: "*-kubeconfig"
        namespaces:
          - default
```

### Check Drift Status

```bash
# See drifted resources
kubectl get drift -n fleet-default

# View drift details
kubectl describe drift <name> -n fleet-default
```

## Step 6: Fleet + CAPI Integration

### Auto-Import Clusters

Fleet can auto-import CAPI-managed clusters:

```yaml
# fleet/auto-import.yaml
apiVersion: fleet.cattle.io/v1alpha1
kind: GitRepo
metadata:
  name: capi-auto-import
  namespace: fleet-default
spec:
  repo: https://github.com/<your-org>/capi-cluster-import
  branch: main
  paths:
    - import
  clusterSelector:
    matchExpressions:
      - key: capi.cluster.x-k8s.io/managed
        operator: Exists
```

### Cluster API + Fleet Workflow

```
1. Git push → Fleet detects CAPI Cluster CRD
2. CAPC provisions CloudStack VMs
3. Cluster becomes Ready
4. Fleet auto-imports cluster
5. Workloads deploy via Fleet Bundles
```

## Troubleshooting

### Fleet Not Syncing

```bash
# Check GitRepo status
kubectl get gitrepo -n fleet-default

# Check Fleet controller logs
kubectl logs -n cattle-fleet-system deployment/fleet-controller -f

# Check for Git auth issues
kubectl describe gitrepo cks-cluster-configs -n fleet-default
```

### Cluster Not Imported

```bash
# Check Fleet cluster registration
kubectl get fleet.cattle.io.cluster -A

# Check if cluster has required labels
kubectl get cluster -A --show-labels

# Check Fleet agent on cluster
kubectl get pods -n cattle-fleet-system -A
```

### Bundle Not Deploying

```bash
# Check bundle status
kubectl get bundle -n fleet-default

# Check bundle deployment
kubectl get bundlenamespacemapping -n fleet-default

# Check workload events
kubectl get events -n apps --sort-by='.lastTimestamp'
```

## Best Practices

1. **One repo per concern** — separate cluster configs from workload manifests
2. **Label clusters** — use labels for targeting (environment, region, team)
3. **Pin versions** — pin Fleet and CAPI versions in Git
4. **Use drift detection** — enable `warn` mode at minimum
5. **Secret management** — use external-secrets for sensitive data
6. **Review before merge** — use PR reviews for cluster config changes
7. **Backup before bulk changes** — snapshot clusters before mass updates

## Next Steps

- [CKS Upgrade Guide](../cks/cks-upgrade.md) — Upgrading CKS clusters
- [CAPC Upgrade Guide](../capc/capc-upgrade.md) — Upgrading CAPC and clusters
