# Demo App — Bank of Anthos

A minimal demo app for testing CloudStack Kubernetes infrastructure, specifically:

- **CloudStack CSI driver** — persistent volume claims backed by CloudStack secondary storage (via `volumeClaimTemplates` on StatefulSets)
- **Cloud Controller Manager (CCM)** — LoadBalancer services that automatically provision a CloudStack public IP + load balancer rule pointing to the backend pods

## Source
Based on [google-samples/bank-of-anthos](https://github.com/google-samples/bank-of-anthos), adapted for non-GKE clusters.

### Changes from upstream
- Removed GKE-specific dependencies (Istio annotations, `iam.gke.io` workload identity)
- Database pods (`accounts-db`, `ledger-db`) use PVC-backed storage via CloudStack CSI instead of ephemeral volumes
- JWT secret moved to root folder alongside other manifests for simplicity
- All deployments use the default service account

## Quick Start

```bash
# Apply all manifests
cd demo-app
kubectl apply -f .

# Wait for pods to be ready
kubectl wait --for=condition=ready pod -l application=bank-of-anthos --timeout=300s

# Get the frontend LoadBalancer IP (provisioned by CCM)
kubectl get svc frontend
```

The `frontend` service is type **LoadBalancer** — after a few minutes, CloudStack CCM will assign a public IP and configure load balancing to the frontend pods.

## Manifests

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

## Cleanup

```bash
kubectl delete -f .
```
