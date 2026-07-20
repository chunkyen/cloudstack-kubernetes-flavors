# Demo App — Bank of Anthos

A minimal demo app for testing CloudStack Kubernetes infrastructure, specifically:

- **CloudStack CSI driver** — persistent volume claims backed by CloudStack primary storage (via `volumeClaimTemplates` on StatefulSets)
- **Cloud Controller Manager (CCM)** — LoadBalancer services that automatically provision a CloudStack public IP + load balancer rule pointing to the backend pods

## Source
Based on [GoogleCloudPlatform/bank-of-anthos](https://github.com/GoogleCloudPlatform/bank-of-anthos), adapted for non-GKE clusters.

### Changes from upstream
- Removed GKE-specific dependencies (Istio annotations, `iam.gke.io` workload identity)
- Database pods (`accounts-db`, `ledger-db`) use PVC-backed storage via CloudStack CSI instead of ephemeral volumes
- JWT secret moved to root folder alongside other manifests for simplicity
- All deployments use the default service account
- `ENABLE_METRICS` and `ENABLE_TRACING` set to `false` in all applicable deployments, disabling Google Cloud Operations telemetry as described in the [upstream environments docs](https://github.com/GoogleCloudPlatform/bank-of-anthos/blob/main/docs/environments.md)

## Prerequisites

A **CloudStack StorageClass** must exist before applying the manifests, otherwise PVCs for `accounts-db` and `ledger-db` will fail to bind. See the [example StorageClass](https://github.com/cloudstack/cloudstack-csi-driver/blob/main/examples/k8s/0-storageclass.yaml) from the CSI driver repository.

## Quick Start

```bash
# Apply all manifests
cd demo-app
kubectl apply -f manifests/

# Wait for pods to be ready
kubectl wait --for=condition=ready pod -l application=bank-of-anthos --timeout=300s

# Get the frontend LoadBalancer IP (provisioned by CCM)
kubectl get svc frontend
```

The `frontend` service is type **LoadBalancer** — after a few minutes, CloudStack CCM will assign a public IP and configure load balancing to the frontend pods.

## Manifests

All manifests are in the `manifests/` directory:

| File | Description |
|------|-------------|
| `config.yaml` | Shared ConfigMaps (env vars, API endpoints, demo data) |
| `accounts-db.yaml` | PostgreSQL for accounts — StatefulSet with PVC via CloudStack CSI |
| `ledger-db.yaml` | PostgreSQL for ledger — StatefulSet with PVC via CloudStack CSI |
| `frontend.yaml` | Web UI + LoadBalancer service (tests CCM) |
| `balance-reader.yaml` | Balance reader microservice |
| `contacts.yaml` | Contacts microservice |
| `ledger-writer.yaml` | Ledger writer microservice |
| `transaction-history.yaml` | Transaction history microservice |
| `userservice.yaml` | User service (login) |
| `loadgenerator.yaml` | Optional load generator |
| `jwt-secret.yaml` | JWT signing keypair (Secret) |

### Ubuntu 26 / cgroup v2 compatibility

The Java services (`balance-reader`, `ledger-writer`, `transaction-history`) use a container image with **JDK 17.0.4.1**, which has a known incompatibility with cgroup v2 on **Ubuntu 26**. The Spring Boot `ProcessorMetrics` bean triggers a `NullPointerException` when the JDK attempts to read cgroup v2 info.

**Symptom:** Pods crash-loop with:
```
Cannot invoke "jdk.internal.platform.CgroupInfo.getMountPoint()" because "<parameter1>" is null
```

**Fix:** Use the patched manifests in `manifests/cgroupv2-jdk17-compat/` instead of the upstream versions. These add the `SPRING_AUTOCONFIGURE_EXCLUDE` environment variable to skip the problematic auto-configuration:

```bash
kubectl apply -f manifests/cgroupv2-jdk17-compat/
```

This applies to **any Kubernetes flavor** (RKE2, kubeadm CAPC, CKS) running on Ubuntu 26 hosts — it's an OS-level cgroup v2 layout issue with JDK 17.0.4.1, not specific to a particular Kubernetes distribution. While only tested on RKE2 so far, the same JDK limitation would theoretically affect CKS and kubeadm CAPC clusters on Ubuntu 26 as well.

## Cleanup

```bash
kubectl delete -f manifests/
```
