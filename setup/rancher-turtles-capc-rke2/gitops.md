# GitOps Cluster Lifecycle with Fleet + Gitea

This guide covers using **Rancher Fleet** with a **self-hosted Git platform** (Gitea) to manage the **full lifecycle of CAPC clusters** — from creation through deletion — entirely via Git pushes. No `kubectl apply` needed after initial Fleet setup.

> **Scope:** Cluster creation and deletion via GitOps. For workload management on existing clusters (Bundles, drift detection, multi-cluster deployment), see [`../rancher-turtles-capc/fleet.md`](../rancher-turtles-capc/fleet.md).
>
> **Applies to:** Both RKE2 and Kubeadm bootstrap flows. The GitOps mechanism is identical — only the bootstrap/control-plane provider CRDs differ (`RKE2ControlPlane` vs `KubeadmControlPlane`, `RKE2ConfigTemplate` vs `KubeadmConfigTemplate`).

## Architecture

```
Git push → Gitea → webhook → Rancher Fleet → apply manifests to management cluster
                                                      │
                                                      ├─ CAPI detects Cluster CR
                                                      ├─ CAPC provisions CloudStack VMs
                                                      ├─ RKE2/Kubeadm bootstrap joins nodes
                                                      ├─ ClusterResourceSet applies CCM + CSI
                                                      └─ Rancher Turtles auto-imports cluster
```

**Key components:**

| Component | Role |
|-----------|------|
| Gitea | Self-hosted Git server holding cluster manifests |
| Fleet GitRepo | Watches Gitea repo, syncs manifests to management cluster |
| Fleet webhook | Gitea pushes trigger instant Fleet sync (no polling delay) |
| CAPI + CAPC | Provisions CloudStack VMs, creates Kubernetes cluster |
| Turtles | Auto-imports CAPI clusters into Rancher (`cluster-api.cattle.io/rancher-auto-import: "true"` label) |
| ClusterResourceSet | Applies CCM/CSI manifests to workload cluster post-creation |

## Prerequisites

- Rancher + Turtles + CAPC deployed on management cluster
- RKE2 bootstrap + control-plane providers installed (or Kubeadm providers for kubeadm flow)
- `kubectl` configured with management cluster kubeconfig
- CloudStack zone, network offering, service offerings, SSH keypair, and VM template ready

## 1. Deploy Gitea

> **Security note:** This guide uses **HTTP** for Gitea (no TLS) for testing convenience. In production, Gitea should be configured with **HTTPS** — either by terminating TLS at an ingress controller with a valid certificate, or by configuring Gitea's built-in TLS. The GitOps workflow is identical either way; only the URL scheme changes (`https://` instead of `http://`).

### 1.1 Install Gitea on Management Cluster

```yaml
# gitea.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gitea
  namespace: gitea
spec:
  replicas: 1
  selector:
    matchLabels:
      app: gitea
  template:
    metadata:
      labels:
        app: gitea
    spec:
      containers:
        - name: gitea
          image: gitea/gitea:1.21
          ports:
            - containerPort: 3000
            - containerPort: 22
          volumeMounts:
            - name: gitea-data
              mountPath: /data
      volumes:
        - name: gitea-data
          persistentVolumeClaim:
            claimName: gitea-data
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: gitea-data
  namespace: gitea
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 10Gi
---
apiVersion: v1
kind: Service
metadata:
  name: gitea
  namespace: gitea
spec:
  type: ClusterIP
  ports:
    - name: http
      port: 3000
      targetPort: 3000
    - name: ssh
      port: 22
      targetPort: 22
  selector:
    app: gitea
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: gitea
  namespace: gitea
spec:
  rules:
    - host: gitea.<management-cluster-ip>.sslip.io
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: gitea
                port:
                  number: 3000
```

```bash
kubectl apply -f gitea.yaml
# Wait for pod to be ready, then access Gitea via ingress URL
# Complete initial setup (database: SQLite, admin user)
```

### 1.2 Create API Token

In Gitea UI: **Settings → Applications → Generate New Token**

Save the token — it's used for:
- Fleet GitRepo authentication (embedded in repo URL)
- Gitea API calls (webhook creation)

### 1.3 Create Git Repo

In Gitea UI: **New Repository** → name it (e.g., `capc-rke2-git`)

```bash
# Clone locally
git clone http://<gitea-url>/<user>/capc-rke2-git.git
cd capc-rke2-git
git config user.email "admin@gitea.local"
git config user.name "admin"
```

## 2. Configure Fleet GitRepo

### 2.1 The `tls-ca-additional` Secret (Fleet 0.15.x Bug Workaround)

Fleet 0.15.x requires a `tls-ca-additional` secret with a `ca-additional.pem` key to exist, even when using HTTP (no TLS). **If this secret is missing or has the wrong key name, Fleet silently fails to sync** with no error in controller logs.

```bash
# Check if the secret exists in cattle-system (pre-existing from Rancher install)
kubectl get secret tls-ca-additional -n cattle-system -o jsonpath='{.data}' | jq keys

# If ca-additional.pem is missing, patch it in:
kubectl patch secret tls-ca-additional -n cattle-system \
  --type='json' -p='[{"op":"add","path":"/data/ca-additional.pem","value":""}]'

# Also create in fleet-local and cattle-fleet-system:
kubectl create secret generic tls-ca-additional -n fleet-local \
  --from-literal=ca-additional.pem=""
kubectl create secret generic tls-ca-additional -n cattle-fleet-system \
  --from-literal=ca-additional.pem=""
```

### 2.2 Create the GitRepo with Secret-Based Authentication

**Do NOT embed credentials in the repo URL** — the token would be visible in `kubectl get gitrepo -o yaml` and in Fleet controller logs. Instead, use a Kubernetes Secret:

```yaml
# gitea-credentials.yaml
apiVersion: v1
kind: Secret
metadata:
  name: gitea-credentials
  namespace: fleet-local
type: kubernetes.io/basic-auth
stringData:
  username: admin
  password: <gitea-token>
---
apiVersion: fleet.cattle.io/v1alpha1
kind: GitRepo
metadata:
  name: capc-rke2-git
  namespace: fleet-local
spec:
  repo: http://<gitea-url>/<user>/capc-rke2-git.git
  branch: main
  clientSecretName: gitea-credentials
  paths:
    - .
  targets:
    - clusterSelector:
        matchLabels:
          name: local
```

```bash
kubectl apply -f gitea-credentials.yaml
```

> **Security:** The `clientSecretName` field references a Kubernetes Secret of type `kubernetes.io/basic-auth`. The Gitea token is stored only in the Secret (base64-encoded, not encrypted at rest unless etcd encryption is enabled). The GitRepo `repo` field contains only the URL without credentials.
>
> **Important:** The `clusterSelector` must match the **local (management) cluster** labels.
> Check with: `kubectl get clusters.fleet.cattle.io -A -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.labels}{"\n"}{end}'`
>
> The local cluster has label `name: local` — use that. Do **not** use `provider.cattle.io/name: local` (that label doesn't exist on the local cluster).

### 2.3 Verify Fleet Sync

```bash
kubectl get gitrepo -n fleet-local capc-rke2-git -o wide
# Should show COMMIT hash and no errors

kubectl get bundles -n fleet-local
# Should show capc-rke2-git bundle
```

### 2.4 Configure Gitea Webhook (Optional — Instant Sync)

Without a webhook, Fleet polls the repo every ~60s. With a webhook, pushes trigger instant sync.

```bash
# Create webhook via Gitea API
curl -s -X POST \
  "http://<gitea-url>/api/v1/repos/<user>/capc-rke2-git/hooks" \
  -H "Authorization: token <gitea-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "gitea",
    "active": true,
    "events": ["push"],
    "config": {
      "url": "https://<rancher-url>/v1/fleet/git/fleet-local/capc-rke2-git",
      "content_type": "json"
    }
  }'
```

## 3. Cluster Manifest Structure

The repo should contain numbered manifest files applied in order:

```
capc-rke2-git/
├── 00-namespace-credentials.yaml   # Namespace + CloudStack API credentials
├── 10-cluster.yaml                  # Cluster, CloudStackCluster, control plane, workers
├── 20-ccm-csi-configmap.yaml        # CCM + CSI manifests as ConfigMap data
└── 21-clusterresourceset.yaml       # ClusterResourceSet referencing the ConfigMap
```

### 3.1 `00-namespace-credentials.yaml` — Namespace + Credentials

This file creates the namespace and the `cloudstack-credentials` secret that CAPC uses to talk to CloudStack. **Keep this file separate** — it must persist during cluster deletion (see [Deletion](#5-deleting-clusters-via-gitops)).

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: capc-rke2-cluster-1
---
apiVersion: v1
kind: Secret
metadata:
  name: cloudstack-credentials
  namespace: capc-rke2-cluster-1
type: Opaque
stringData:
  api-url: http://<cloudstack-management-server>:8080/client/api
  api-key: <cloudstack-api-key>
  secret-key: <cloudstack-secret-key>
  verify-ssl: "false"
```

> **Security:** Real API keys should **not** be committed to a public Git repo. For GitHub/public repos, use placeholder values and replace them in a pre-push hook or use SealedSecrets/External Secrets. For self-hosted Gitea on a private network, committing real keys is acceptable but should be access-controlled.

### 3.2 `10-cluster.yaml` — Cluster Definition

**For RKE2:**

```yaml
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: capc-rke2-cluster-1
  namespace: capc-rke2-cluster-1
  labels:
    cluster-api.cattle.io/rancher-auto-import: "true"  # Turtles auto-import
    capc-rke2-ccm-csi: "true"                          # CRS selector
spec:
  clusterNetwork:
    pods:
      cidrBlocks: ["10.168.0.0/16"]
    serviceDomain: cluster.local
  controlPlaneRef:
    apiVersion: controlplane.cluster.x-k8s.io/v1beta2
    kind: RKE2ControlPlane
    name: capc-rke2-cluster-1-control-plane
  infrastructureRef:
    apiVersion: infrastructure.cluster.x-k8s.io/v1beta3
    kind: CloudStackCluster
    name: capc-rke2-cluster-1
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta3
kind: CloudStackCluster
metadata:
  name: capc-rke2-cluster-1
  namespace: capc-rke2-cluster-1
spec:
  controlPlaneEndpoint:
    host: 192.168.200.63       # Must be a free public IP in CloudStack
    port: 6443
  failureDomains:
  - acsEndpoint:
      name: cloudstack-credentials
      namespace: capc-rke2-cluster-1
    name: cyz1
    zone:
      name: cyz1
      network:
        name: capc-rke2-cluster-1-net
        offering: DefaultNetworkOfferingforKubernetesService
  syncWithACS: true             # See "syncWithACS" section below
---
apiVersion: controlplane.cluster.x-k8s.io/v1beta2
kind: RKE2ControlPlane
metadata:
  name: capc-rke2-cluster-1-control-plane
  namespace: capc-rke2-cluster-1
spec:
  replicas: 1
  version: v1.36.2+rke2r1
  agentConfig:
    kubelet:
      extraArgs:
        - provider-id=cloudstack:///{{ ds.meta_data.instance_id }}
        - register-with-taints=node-role.kubernetes.io/control-plane=:NoSchedule
    nodeName: '{{ ds.meta_data.local_hostname }}'
  serverConfig:
    cni: calico
  registrationMethod: internal-first
  machineTemplate:
    spec:
      infrastructureRef:
        apiGroup: infrastructure.cluster.x-k8s.io
        kind: CloudStackMachineTemplate
        name: capc-rke2-cluster-1-control-plane
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta3
kind: CloudStackMachineTemplate
metadata:
  name: capc-rke2-cluster-1-control-plane
  namespace: capc-rke2-cluster-1
spec:
  template:
    spec:
      offering:
        name: "kube control"
      sshKey: "cylabnb-k1"
      template:
        name: "ubuntu 26 server"
      details:
        guest.cpu.mode: host-passthrough
---
apiVersion: cluster.x-k8s.io/v1beta1
kind: MachineDeployment
metadata:
  name: capc-rke2-cluster-1-md-0
  namespace: capc-rke2-cluster-1
spec:
  clusterName: capc-rke2-cluster-1
  replicas: 2
  selector:
    matchLabels: null
  template:
    spec:
      bootstrap:
        configRef:
          apiVersion: bootstrap.cluster.x-k8s.io/v1beta2
          kind: RKE2ConfigTemplate
          name: capc-rke2-cluster-1-md-0
      clusterName: capc-rke2-cluster-1
      infrastructureRef:
        apiVersion: infrastructure.cluster.x-k8s.io/v1beta3
        kind: CloudStackMachineTemplate
        name: capc-rke2-cluster-1-md-0
      version: v1.36.2+rke2r1
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta3
kind: CloudStackMachineTemplate
metadata:
  name: capc-rke2-cluster-1-md-0
  namespace: capc-rke2-cluster-1
spec:
  template:
    spec:
      offering:
        name: "kube worker1"
      sshKey: "cylabnb-k1"
      template:
        name: "ubuntu 26 server"
      details:
        guest.cpu.mode: host-passthrough
---
apiVersion: bootstrap.cluster.x-k8s.io/v1beta2
kind: RKE2ConfigTemplate
metadata:
  name: capc-rke2-cluster-1-md-0
  namespace: capc-rke2-cluster-1
spec:
  template:
    spec:
      agentConfig:
        kubelet:
          extraArgs:
            - provider-id=cloudstack:///{{ ds.meta_data.instance_id }}
        nodeName: '{{ ds.meta_data.local_hostname }}'
```

**For Kubeadm:** Replace `RKE2ControlPlane` with `KubeadmControlPlane` and `RKE2ConfigTemplate` with `KubeadmConfigTemplate`. The `CloudStackCluster`, `CloudStackMachineTemplate`, `MachineDeployment`, and `Cluster` objects remain the same.

### 3.3 `20-ccm-csi-configmap.yaml` — CCM + CSI

A ConfigMap containing CCM and CSI manifests as data entries. This is applied to the workload cluster via ClusterResourceSet. See the [manifest in the repo](manifests/20-ccm-csi-configmap.yaml) for the full content.

**Critical additions for GitOps:** The ConfigMap must also include:
- `cloudstack-secret.yaml` — the `cloudstack-secret` in `kube-system` with CloudStack API credentials for CCM/CSI
- `storageclass.yaml` — the `cloudstack-standard` StorageClass

These were separate files when applying manually. In a GitOps/CRS flow, they must be embedded as ConfigMap data entries so CRS can apply them to the workload cluster.

### 3.4 `21-clusterresourceset.yaml` — CRS

```yaml
apiVersion: addons.cluster.x-k8s.io/v1beta2
kind: ClusterResourceSet
metadata:
  name: capc-rke2-cluster-1-ccm-csi
  namespace: capc-rke2-cluster-1
spec:
  clusterSelector:
    matchLabels:
      capc-rke2-ccm-csi: "true"
  resources:
    - kind: ConfigMap
      name: capc-rke2-cluster-1-post-deploy
  strategy: Reconcile
```

### 3.5 What NOT to Include

**Do not include `rke2-providers.yaml`** (CAPIProvider resources) in the GitOps repo. The RKE2 bootstrap and control-plane providers are already installed on the management cluster by Rancher Turtles. Fleet tries to adopt them as Helm-managed resources, causing:

```
CAPIProvider "rke2-bootstrap" in namespace "cattle-capi-system" exists and cannot be imported
into the current release: invalid ownership metadata
```

## 4. Creating a Cluster via GitOps

```bash
# 1. Copy manifests to the Gitea repo working directory
cp 00-namespace-credentials.yaml 10-cluster.yaml 20-ccm-csi-configmap.yaml 21-clusterresourceset.yaml /path/to/capc-rke2-git/

# 2. Commit and push
cd /path/to/capc-rke2-git
git add -A
git commit -m "Create cluster-1"
git push origin main

# 3. Fleet syncs automatically (instant if webhook configured, ~60s otherwise)

# 4. Monitor provisioning
kubectl get cluster capc-rke2-cluster-1 -n capc-rke2-cluster-1
kubectl get machines -n capc-rke2-cluster-1
```

### Provisioning Timeline

| Step | Time | What Happens |
|------|------|-------------|
| Fleet sync | ~15s | Manifests applied to management cluster |
| Network creation | ~30s | CAPC creates isolated network in CloudStack, acquires SourceNAT public IP |
| CP VM deploy | ~1-2min | CloudStack provisions VM, RKE2 installs via tarball |
| Worker VMs | ~2-3min | MachineDeployment scales up, workers join cluster |
| CCM/CSI | ~3-4min | ClusterResourceSet applies CCM/CSI to workload cluster |
| Rancher import | ~4-5min | Turtles auto-imports cluster into Rancher UI |

### Public IP Requirements

CAPC requires **two** public IPs per cluster:
1. **SourceNAT IP** — acquired automatically by CAPC for the isolated network
2. **ControlPlaneEndpoint IP** — specified in `CloudStackCluster.spec.controlPlaneEndpoint.host`

The CP endpoint IP must be **free** (not allocated to another network). If it's already in use, CAPC fails with:

```
CloudStack API error 533: Insufficient address capacity
```

Check available IPs:
```bash
ssh <cloudstack-management-server> "cmk list publicipaddresses filter=ipaddress,state,associatednetworkname"
```

## 5. Deleting Clusters via GitOps

### 5.1 The Ordering Problem

**Fleet deletes all resources simultaneously** when manifests are removed from Git. This causes a problem:

1. Fleet removes `Cluster`, `CloudStackCluster`, `RKE2ControlPlane`, `MachineDeployment`, **and** `cloudstack-credentials` secret all at once
2. CAPC tries to destroy VMs but can't — the `cloudstack-credentials` secret is already gone
3. Machines get stuck in `Deleting` with `secrets "cloudstack-credentials" not found`

**Manual `kubectl delete cluster`** doesn't hit this because you delete only the `Cluster` object — CAPI cascades the deletion in order, and the `CloudStackCluster` stays alive until all machines are cleaned up.

### 5.2 Graceful Deletion: Two-Phase Approach

**Phase 1 — Remove cluster manifests, keep credentials:**

```bash
cd /path/to/capc-rke2-git
git rm 10-cluster.yaml 20-ccm-csi-configmap.yaml 21-clusterresourceset.yaml
git commit -m "Delete cluster-1 (keep credentials for CAPC cleanup)"
git push origin main
```

This triggers Cluster deletion while `cloudstack-credentials` remains available for CAPC to destroy VMs.

**Phase 2 — Remove credentials after machines are gone:**

```bash
# Wait for all machines to be deleted
kubectl get machines -n capc-rke2-cluster-1
# Should show: No resources found

# Then remove credentials
git rm 00-namespace-credentials.yaml
git commit -m "Remove credentials, full cleanup complete"
git push origin main
```

### 5.3 Optional Pre-Step: Scale Workers to 0 First

For even smoother deletion, scale workers to zero before removing cluster manifests:

```bash
# Edit 10-cluster.yaml: change MachineDeployment replicas from 2 to 0
sed -i 's/  replicas: 2/  replicas: 0/' 10-cluster.yaml
git commit -am "Scale workers to 0"
git push origin main

# Wait for worker VMs to be destroyed
kubectl get machines -n capc-rke2-cluster-1
# Should show only control-plane machine

# Then proceed with Phase 1 (remove cluster manifests)
```

> **Note:** RKE2ControlPlane does **not** accept `replicas: 0` — the webhook rejects it with `cannot be less than or equal to 0`. Only MachineDeployment can be scaled to zero.

### 5.4 Known Issue: CKS Controller Stuck During Deletion

**Symptom:** During GitOps deletion, the control plane machine gets stuck in `Deleting` with CAPC controller logging:

```
"CloudStackClusterID is not set Requeuing." controller="cks-machine-controller"
```

**Cause:** The CKS (CloudStack Kubernetes Service) controller inside CAPC tries to reconcile machine deletion but can't find the `CloudStackClusterID` because Fleet already deleted the `CloudStackCluster`. The CKS finalizer (`cksMachine.infrastructure.cluster.x-k8s.io`) blocks the `cloudstackmachine` finalizer from running, so the VM never gets destroyed.

This is a **CAPC bug** — the CKS controller should not block machine deletion when the parent CloudStackCluster is already gone.

**Why manual deletion doesn't hit this:** `kubectl delete cluster` cascades deletion through CAPI — the `CloudStackCluster` stays alive until all machines are cleaned up, so the CKS controller always finds the cluster ID.

### 5.5 The `syncWithACS` Setting

The `syncWithACS` field on `CloudStackCluster` controls whether CAPC creates a CKS entry in CloudStack:

```yaml
spec:
  syncWithACS: true   # Creates CKS cluster entry in CloudStack (visible in CloudStack UI)
```

- **`true` (default):** CAPC registers the cluster with CloudStack's CKS service. The cluster appears in CloudStack UI under Kubernetes. The CKS controller manages this sync and adds a `cksMachine` finalizer to each machine.
- **`false`:** No CKS entry created. The CKS controller doesn't add finalizers. Cluster still works — CCM, CSI, and all Kubernetes functionality are unaffected. The cluster just doesn't appear in CloudStack UI.

**Setting `syncWithACS: false` may avoid the CKS deletion bug** since the CKS controller won't add its finalizer to machines. This is the simplest workaround until the CAPC bug is fixed upstream.

### 5.6 Manual Finalizer Removal (Workaround)

If a machine is stuck in `Deleting` due to the CKS bug, remove the finalizers manually:

```bash
# Remove CKS finalizer from CloudStackMachine
kubectl patch cloudstackmachine <machine-name> -n <namespace> \
  --type='json' -p='[{"op":"remove","path":"/metadata/finalizers"}]'

# Remove finalizer from Machine
kubectl patch machine <machine-name> -n <namespace> \
  --type='json' -p='[{"op":"remove","path":"/metadata/finalizers"}]'

# If CloudStack VM is still running, destroy it manually
ssh <cloudstack-management-server> "cmk destroyVirtualMachine id=<vm-id>"
```

## 6. Manifest Reuse

### 6.1 Retaining Manifests for Future Use

Before deleting cluster manifests from Git, save a copy:

```bash
cp -r /path/to/capc-rke2-git /path/to/capc-rke2-cluster1-backup
```

To recreate the cluster later, simply copy the files back and push:

```bash
cp /path/to/capc-rke2-cluster1-backup/*.yaml /path/to/capc-rke2-git/
cd /path/to/capc-rke2-git
git add -A
git commit -m "Recreate cluster-1"
git push origin main
```

### 6.2 Parameterizing for Multiple Clusters

To create multiple clusters from the same manifest set, change these values:

| Field | Example |
|-------|---------|
| Namespace name | `capc-rke2-cluster-2` |
| Cluster name | `capc-rke2-cluster-2` |
| `controlPlaneEndpoint.host` | A free public IP |
| `network.name` | `capc-rke2-cluster-2-net` |
| All resource names | Replace `cluster-1` with `cluster-2` |
| ConfigMap name | `capc-rke2-cluster-2-post-deploy` |
| CRS name | `capc-rke2-cluster-2-ccm-csi` |

### 6.3 Templating with ytt or Kustomize

For managing multiple clusters without copy-paste, the repo already includes both ytt templates and Kustomize overlays that can be adapted for the GitOps workflow. See [`ytt.md`](ytt.md) and [`../rancher-turtles-capc/kustomize.md`](../rancher-turtles-capc/kustomize.md) for full documentation.

| Approach | How it works with Fleet | Pros | Cons |
|----------|------------------------|------|------|
| **ytt** | Pre-render locally → push rendered YAML to Gitea | Powerful templating, conditionals (e.g., air-gap toggle), data values | Extra step (ytt render before push) |
| **Kustomize** | Fleet renders `kustomization.yaml` natively — no pre-rendering needed | No pre-rendering, simple YAML patches | Limited to patch overlays, no logic |
| **Helm** | Fleet supports HelmCharts natively | Versioning, sharing, ecosystem | More complex to set up |

## 7. Upgrading and Scaling via GitOps

Upgrading RKE2 versions and scaling workers follow the same procedure as manual clusters — the only difference is you edit the YAML in your Gitea repo and push, instead of using `kubectl` directly.

### 7.1 Upgrade RKE2 Version

Edit `10-cluster.yaml` in the Gitea repo, change the `version` field in both `RKE2ControlPlane` and `MachineDeployment`, then commit and push:

```bash
# Edit version in 10-cluster.yaml
# RKE2ControlPlane.spec.version
# MachineDeployment.spec.template.spec.version
git add 10-cluster.yaml
git commit -m "Upgrade cluster-1 to v1.36.3+rke2r1"
git push origin main
```

Fleet syncs the change, CAPI performs a rolling upgrade — same process as manual. See [`cluster.md`](cluster.md#upgrading-rke2-version) for details on the rolling upgrade flow, monitoring, and etcd leadership transfer troubleshooting.

### 7.2 Scale Workers

Edit `10-cluster.yaml`, change `MachineDeployment.spec.replicas`, commit, and push:

```bash
# Edit 10-cluster.yaml: change replicas from 2 to 3
git add 10-cluster.yaml
git commit -m "Scale cluster-1 workers to 3"
git push origin main
```

Fleet syncs, CAPI creates or deletes Machines accordingly. See [`cluster.md`](cluster.md#scaling-workers) for scale-up/down behavior and how CAPI selects which Machine to delete during scale-down.

> **Note:** `RKE2ControlPlane` does **not** accept `replicas: 0` — the webhook rejects it. Only `MachineDeployment` can be scaled to zero (useful as a pre-deletion step — see [§5.3](#53-optional-pre-step-scale-workers-to-0-first)).

## 8. Troubleshooting

### Fleet Not Syncing

```bash
# Check GitRepo status
kubectl get gitrepo -n fleet-local capc-rke2-git -o yaml | grep -A5 conditions

# Check for tls-ca-additional error (Fleet 0.15.x bug)
kubectl get secret tls-ca-additional -n cattle-system -o jsonpath='{.data}' | jq keys
# Must contain "ca-additional.pem"

# Check Fleet controller logs
kubectl logs -n cattle-fleet-system deployment/fleet-controller --tail=100

# Check bundle deployment status
kubectl get bundledeployment -A | grep capc
```

### BundleDeployment Errors

```bash
# Common error: CAPIProvider ownership conflict
# Solution: Remove rke2-providers.yaml from the repo

# Common error: clusterSelector doesn't match
# Check local cluster labels:
kubectl get clusters.fleet.cattle.io -A -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.labels}{"\n"}{end}'
```

### VMs Not Provisioning

```bash
# Check CAPC controller logs
kubectl logs -n cattle-capi-system deployment/capc-controller-manager --tail=50 | grep <cluster-name>

# Common issues:
# - "Insufficient address capacity" → CP endpoint IP already in use, change to a free IP
# - "Isolated network dependency not ready" → Network needs SourceNAT IP, may need manual acquire
# - "secrets cloudstack-credentials not found" → 00-namespace-credentials.yaml not applied or already deleted
```

### Cluster Stuck in Deleting

**Symptom:** Cluster stuck in `Deleting` phase. CAPC controller logs show:

```
"CloudStackClusterID is not set Requeuing." controller="cks-machine-controller"
```

**Root cause:** Fleet deletes all resources simultaneously, including the `CloudStackCluster`. The CKS controller (CloudStack Kubernetes Service) inside CAPC tries to reconcile machine deletion but can't find the `CloudStackClusterID` because the parent `CloudStackCluster` is already gone. The CKS finalizer (`cksMachine.infrastructure.cluster.x-k8s.io`) blocks the `cloudstackmachine` finalizer from running, so the VM never gets destroyed.

This only happens with GitOps deletion — manual `kubectl delete cluster` cascades deletion through CAPI and the `CloudStackCluster` stays alive until all machines are cleaned up.

**Workaround 1 — Set `syncWithACS: false` (prevents CKS finalizer):**

The `syncWithACS` field on `CloudStackCluster` controls whether CAPC registers the cluster with CloudStack's CKS service. When `false`, the CKS controller doesn't add its finalizer to machines, eliminating the "CloudStackClusterID is not set" stuck loop. The cluster still works — CCM, CSI, and all Kubernetes functionality are unaffected. The cluster just won't appear in CloudStack UI.

```yaml
# In 10-cluster.yaml, CloudStackCluster spec:
spec:
  syncWithACS: false   # Prevents CKS finalizer from blocking deletion
```

> **Note:** `syncWithACS: false` eliminates the CKS finalizer issue but **does not** solve the credentials problem — Fleet still deletes `cloudstack-credentials` at the same time as everything else, preventing CAPC from destroying VMs. Use this **together with** the two-phase deletion below for fully clean GitOps deletion.

**Workaround 2 — Remove finalizers manually:**

If a machine is already stuck, remove the finalizers to unblock deletion:

```bash
# Remove finalizers from CloudStackMachine
kubectl patch cloudstackmachine <machine-name> -n <namespace> \
  --type='json' -p='[{"op":"remove","path":"/metadata/finalizers"}]'

# Remove finalizer from Machine
kubectl patch machine <machine-name> -n <namespace> \
  --type='json' -p='[{"op":"remove","path":"/metadata/finalizers"}]'

# If CloudStack VM is still running, destroy it manually
ssh <cloudstack-management-server> "cmk destroyVirtualMachine id=<vm-id>"

# If cluster-level resources are stuck, remove their finalizers too
kubectl patch cloudstackcluster <name> -n <namespace> \
  --type='json' -p='[{"op":"remove","path":"/metadata/finalizers"}]'
kubectl patch cloudstackfailuredomain <name> -n <namespace> \
  --type='json' -p='[{"op":"remove","path":"/metadata/finalizers"}]'
kubectl patch cloudstackisolatednetwork <name> -n <namespace> \
  --type='json' -p='[{"op":"remove","path":"/metadata/finalizers"}]'
kubectl patch cluster <name> -n <namespace> \
  --type='json' -p='[{"op":"remove","path":"/metadata/finalizers"}]'
```

**Workaround 3 — Two-phase deletion (prevents the issue):**

Delete in phases to keep `cloudstack-credentials` available during VM cleanup:

```bash
# Phase 1: Remove cluster manifests only, keep 00-namespace-credentials.yaml
git rm 10-cluster.yaml 20-ccm-csi-configmap.yaml 21-clusterresourceset.yaml
git commit -m "Delete cluster (keep credentials for CAPC cleanup)"
git push origin main

# Wait for all machines to be deleted
kubectl get machines -n <namespace>
# Should show: No resources found

# Phase 2: Remove credentials
git rm 00-namespace-credentials.yaml
git commit -m "Remove credentials, full cleanup complete"
git push origin main
```

**Diagnosis commands:**

```bash
# Check if CKS controller is blocking
kubectl logs -n cattle-capi-system deployment/capc-controller-manager --tail=20 | grep "CloudStackClusterID is not set"

# Check finalizers on stuck machines
kubectl get cloudstackmachine -n <namespace> -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.finalizers}{"\n"}{end}'

# Check if VM is already destroyed in CloudStack
ssh <cloudstack-management-server> "cmk list virtualmachines keyword=<cluster-name> filter=name,state"
```