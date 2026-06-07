# Deploy Rancher on CKS Cluster

This guide walks through deploying Rancher on a CKS cluster to serve as the management plane for Turtles + CAPC.

## Prerequisites

- A CKS cluster running on CloudStack (see [CKS Setup Guide](../cks/cks.md))
- `kubectl` configured with cluster access
- `helm` v3.12+
- Sufficient cluster resources (minimum 3 control plane + 2 workers, 4vCPU/8GB each)
- **FQDN + DNS**: Rancher requires FQDN access. The CloudStack Kubernetes Provider will create a LoadBalancer service — map its VIP to your FQDN via DNS.

## Step 1: Prepare Storage

Rancher needs persistent storage for etcd data. On CKS, you have two options:

### Option A: CloudStack CSI Driver (Recommended)

```bash
# Enable CSI during CKS cluster creation
# Or deploy CSI manually after cluster creation
kubectl apply -f https://raw.githubusercontent.com/cloudstack/cluster-api-provider-cloudstack/main/infrastructure-components.yaml
# Or use the CloudStack CSI driver manifest
kubectl apply -f https://raw.githubusercontent.com/apache/cloudstack-kubernetes-csi-driver/main/deploy/kubernetes/csi/cloudstack-csi.yaml
```

### Option B: Local Path Provisioner (Quick Start)

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

## Step 2: Install Rancher

### Via Helm (Recommended)

```bash
# Add the Rancher Helm repo
helm repo add rancher-stable https://releases.rancher.com/server-charts/stable
helm repo update

# Create namespace
kubectl create namespace cattle-system

# Install Rancher with your FQDN
helm install rancher rancher-stable/rancher \
  --namespace cattle-system \
  --set hostname=rancher.<your-domain> \
  --set replicas=3
```

> **Note:** The CloudStack Kubernetes Provider automatically provisions a LoadBalancer service for Rancher. No ingress controller or port-forwarding needed.

## Step 3: Access Rancher

### Get Admin Password

```bash
kubectl -n cattle-system get secret \
  $(kubectl -n cattle-system get secret \
    -o name | grep bootstrap-secret) \
  -o jsonpath='{.data.bootstrapPassword}' | base64 -d
```

### Access UI

Rancher **must be accessed via the FQDN** set in the `--set hostname=` helm parameter — it will not function correctly when accessed by IP address.

**Step 1: Get the LoadBalancer VIP**

```bash
kubectl get svc rancher -n cattle-system
# Look at the EXTERNAL-IP column — this is the VIP
```

**Step 2: Register the VIP in DNS (recommended)**

Create a DNS `A` record pointing your FQDN to the VIP:

```
# Example: add an A record to your DNS zone
rancher.<your-domain>   A   <EXTERNAL-IP>
```

> **DNS is recommended** for production use. If you don't have a DNS server, you can use `/etc/hosts` on your local machine as a quick alternative:
>
> ```bash
> echo "<EXTERNAL-IP>  rancher.<your-domain>" | sudo tee -a /etc/hosts
> ```
>
> **Note:** Replace `<your-domain>` with your actual domain (e.g., `example.com`). The full FQDN will be `rancher.example.com`.

**Step 3: Open the UI**

Navigate to **`https://rancher.<your-domain>`** — this must match the hostname you passed to `helm install --set hostname=`.

> **No port-forwarding needed** — the CloudStack Kubernetes Provider automatically creates a LoadBalancer service that exposes Rancher on a public VIP.

### First Login

1. Navigate to **`https://rancher.<your-domain>`** (use the FQDN, not the IP)
2. Enter the bootstrap password
3. Set a new admin password
4. Set the Rancher server URL to your FQDN (`https://rancher.<your-domain>`)

## Step 4: Configure Local Cluster

Rancher automatically imports the bootstrap cluster as the "local" cluster. Verify:

```bash
# In Rancher UI: Clusters → local → should show as Active
# Or via kubectl:
kubectl cluster-info
# Should show Rancher API server
```

## Troubleshooting

### Rancher Not Accessible

```bash
# Verify LoadBalancer service was created by CloudStack Kubernetes Provider
kubectl get svc rancher -n cattle-system
# EXTERNAL-IP should show the VIP, not <pending>

# If EXTERNAL-IP is pending, check CloudStack Kubernetes Provider logs
kubectl logs -n cattle-system -l app=rancher | grep -i loadbalancer

# Verify DNS record points to the correct VIP
nslookup rancher.<your-domain>
```

### Rancher Pods Not Starting

```bash
# Check Rancher logs
kubectl logs -n cattle-system deployment/rancher -f

# Check storage
kubectl get pvc -n cattle-system
kubectl get storageclass
```

## Next Steps

- [Install Turtles + CAPC](./turtles.md) — Core CAPI providers, CAPC configuration, and management
- [Create Clusters](./cluster.md) — Provision CKS clusters via CAPI
- [Fleet GitOps](./fleet.md) — Automate with Fleet
