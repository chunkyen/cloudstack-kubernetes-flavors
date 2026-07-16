# Managing Talos Clusters on CloudStack with Sidero Omni

> **Reference:** [Omni Documentation](https://docs.siderolabs.com/omni/latest/) | [Infrastructure Providers](https://docs.siderolabs.com/omni/latest/infrastructure-and-extensions/infrastructure-providers/) | [Getting Started with Omni](https://docs.siderolabs.com/omni/latest/getting-started/getting-started-with-omni/)

## Overview

[Sidero Omni](https://www.siderolabs.com/platform/sidero-omni/) is a Kubernetes management platform by Sidero Labs that simplifies the creation and management of Talos Linux clusters. It automates cluster creation, management, and upgrades, and integrates Kubernetes and Omni access into enterprise identity providers.

Omni is available in two modes:

- **Omni SaaS** — hosted by Sidero Labs (free 2-week trial available)
- **Omni Self-Hosted** — on-premises installation (requires a commercial license for production use)

### How Omni Changes the Workflow

Compared to the manual approach ([talos.md](talos.md)) or Terraform approach ([talos-terraform.md](talos-terraform.md)), Omni abstracts away most of the operational overhead:

| Aspect | Manual / Terraform | With Omni |
|--------|-------------------|-----------|
| Config generation | `talosctl gen config` | Automatic (Omni generates configs) |
| Bootstrap | `talosctl bootstrap` | Automatic |
| etcd management | Manual join/remove | Automatic |
| Kubernetes API endpoint | Load balancer + port forwarding | Omni provides a stable endpoint via SideroLink |
| Node registration | Embedded userdata at deploy time | Machines register with Omni via agent |
| Upgrades | `talosctl upgrade` per node | Omni manages rolling upgrades |
| Scaling | Terraform apply + manual etcd | Omni handles automatically |
| Monitoring | Manual | Omni UI provides cluster overview |

### Architecture on CloudStack

```
┌─────────────────────────────────────────────────────────────┐
│                    CloudStack (cyz1)                        │
│                                                             │
│  ┌──────────────────────┐   ┌──────────────────────────┐   │
│  │  Omni Instance        │   │  Talos Cluster Nodes     │   │
│  │  (self-hosted or      │   │                          │   │
│  │   SaaS agent)         │   │  ┌──────────────────┐    │   │
│  │                       │   │  │ CP-1  CP-2  CP-3 │    │   │
│  │  Omni SaaS → cloud    │   │  │ (Talos Linux)    │    │   │
│  │  Self-hosted → VM     │   │  └──────────────────┘    │   │
│  │                       │   │  ┌──────────────────┐    │   │
│  │  SideroLink tunnel ◄──┼──┼──┤ Worker-1 Worker-2│    │   │
│  │  (WireGuard)          │   │  │ (Talos Linux)    │    │   │
│  └──────────────────────┘   │  └──────────────────┘    │   │
│                              └──────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

Key architectural points:

- **SideroLink** — Omni establishes a WireGuard-encrypted tunnel (SideroLink) to each registered machine. This provides a secure control plane without needing a public load balancer or port forwarding rules.
- **KubeSpan** — optionally encrypts inter-node traffic, allowing clusters to span insecure networks.
- **No load balancer needed** — Omni provides the Kubernetes API endpoint through the SideroLink tunnel. You don't need a CloudStack load balancer rule for port 6443.
- **No port forwarding needed** — `talosctl` communicates through Omni, not directly to nodes. No need for port 50000 forwarding.

---

## Option 1: Omni SaaS (Simplest)

### Prerequisites

1. **Sign up** at [https://omni.siderolabs.com/](https://omni.siderolabs.com/) — free 2-week trial
2. **Install `omnictl`** — the Omni CLI tool:
   ```bash
   curl -sL https://github.com/siderolabs/omni/releases/latest/download/omnictl-linux-amd64 -o /usr/local/bin/omnictl
   chmod +x /usr/local/bin/omnictl
   ```
3. **Install `talosctl`** — see [talos.md](talos.md#step-1-install-talosctl)
4. **CloudStack environment** — same prerequisites as [talos.md](talos.md#prerequisites): network, template, service offerings, etc.

### Step 1: Configure Omni CLI

```bash
# Log in to Omni SaaS
omnictl login --sso

# Verify connection
omnictl get contexts
```

### Step 2: Create a CloudStack Infrastructure Provider

Omni uses **Infrastructure Providers** to manage machines. CloudStack is supported as a cloud platform.

Create a provider configuration file `cloudstack-provider.yaml`:

```yaml
apiVersion: omni.sidero.dev/v1alpha1
kind: InfrastructureProvider
metadata:
  name: cloudstack-cyz1
spec:
  type: CloudStack
  config:
    apiUrl: "http://192.168.200.1:8080/client/api"
    apiKey: "<your-api-key>"
    secretKey: "<your-secret-key>"
    zone: "cyz1"
    network: "DefaultNetworkOfferingforKubernetesService"
    template: "talos-v1.13.6"
    controlPlaneOffering: "kube control"
    workerOffering: "kube worker1"
    guestCpuMode: "host-passthrough"
```

Apply it:

```bash
omnictl apply -f cloudstack-provider.yaml
```

> **Note:** As of this writing, CloudStack support in Omni's infrastructure provider system may require a custom infrastructure provider. See [Write an Infrastructure Provider](https://docs.siderolabs.com/omni/latest/infrastructure-and-extensions/writing-infrastructure-providers/) if the built-in CloudStack provider is not yet available. Alternatively, use the **Machine Registration** approach (Option 2 below).

### Step 3: Create a Machine Class

Machine classes group machines by their capabilities:

```bash
omnictl create machine-class cloudstack-cp \
  --label-selector 'type=control-plane'

omnictl create machine-class cloudstack-worker \
  --label-selector 'type=worker'
```

### Step 4: Create a Cluster

```bash
omnictl create cluster terra-omni \
  --kubernetes-version 1.36.2 \
  --talos-version v1.13.6 \
  --control-plane-class cloudstack-cp \
  --worker-class cloudstack-worker \
  --control-plane-count 3 \
  --worker-count 2
```

Omni will:
1. Provision VMs on CloudStack via the infrastructure provider
2. Generate and apply Talos configs
3. Bootstrap the cluster
4. Set up the Kubernetes API endpoint via SideroLink
5. Install Flannel (default CNI)

### Step 5: Access the Cluster

```bash
# Get kubeconfig from Omni
omnictl get kubeconfig terra-omni > ~/.kube/config-omni

# Or use omnictl to proxy
omnictl proxy terra-omni

# In another terminal
kubectl get nodes
```

---

## Option 2: Machine Registration (Manual VM Provisioning)

If you prefer to provision VMs manually (via `cmk` or Terraform) and have them register with Omni, use the machine registration approach.

### Step 1: Create a Registration Token

```bash
# Generate a registration URL/token
omnictl create registration-url \
  --label 'type=control-plane' \
  --label 'region=cyz1'
```

This outputs a URL like: `https://<omni-instance>/registration/<token>`

### Step 2: Deploy VMs with the Registration URL

When deploying VMs on CloudStack, embed the registration URL in the userdata instead of a full Talos config:

```bash
# Create a minimal registration config
cat > register.yaml <<EOF
version: v1alpha1
kind: MachineConfig
registration:
  url: "https://<omni-instance>/registration/<token>"
EOF

# Deploy VM with this config
cmk deploy virtualmachine \
  zoneid=${ZONE_ID} \
  templateid=${TEMPLATE_ID} \
  serviceofferingid=${SERVICEOFFERING_ID} \
  networkids=${NETWORK_ID} \
  name=omni-cp-1 \
  userdata=$(base64 register.yaml | tr -d '\n')
```

The VM boots Talos, connects to Omni, and registers itself. Omni then pushes the full machine config to it.

### Step 3: Create a Cluster from Registered Machines

Once machines are registered and labeled, create the cluster:

```bash
omnictl create cluster terra-omni \
  --kubernetes-version 1.36.2 \
  --talos-version v1.13.6 \
  --control-plane-count 3 \
  --worker-count 2
```

Omni automatically selects registered machines with matching labels.

---

## Post-Deployment: CCM and CSI

Omni manages the cluster lifecycle but does **not** install the CloudStack CCM or CSI driver. These must be installed manually, same as the manual approach:

### Install CCM

```bash
# Create the cloudstack-secret (same as talos.md Step 13)
cat > cloud-config << 'EOF'
[Global]
api-url = <CloudStack API URL>
api-key = <CloudStack API Key>
secret-key = <CloudStack API Secret>
ssl-no-verify = true
EOF

kubectl -n kube-system create secret generic cloudstack-secret --from-file=cloud-config

# Deploy the CCM
kubectl apply -f https://raw.githubusercontent.com/apache/cloudstack-kubernetes-provider/main/deployment.yaml
```

### Install CSI Driver

```bash
# Deploy the CSI driver (includes snapshot CRDs + controller)
kubectl apply -f https://github.com/cloudstack/cloudstack-csi-driver/releases/latest/download/manifest.yaml

# ⚠️ Apply the Talos-patched node DaemonSet
kubectl apply -f manifests/csi-node-daemonset-talos.yaml
```

### Create StorageClass

```bash
cat > cloudstack-ssd.yaml <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: cloudstack-ssd
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: csi.cloudstack.apache.org
parameters:
  type: SSD
  csi.storage.k8s.io/fstype: ext4
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF

kubectl apply -f cloudstack-ssd.yaml
```

---

## Scaling with Omni

### Scale Up

```bash
# Add workers
omnictl update cluster terra-omni --worker-count 3

# Add control plane nodes
omnictl update cluster terra-omni --control-plane-count 5
```

Omni provisions new VMs (via infrastructure provider) or selects registered machines, joins them to etcd and Kubernetes automatically.

### Scale Down

```bash
# Reduce worker count
omnictl update cluster terra-omni --worker-count 1

# Reduce control plane count
omnictl update cluster terra-omni --control-plane-count 1
```

Omni drains the nodes, removes them from etcd, and destroys the VMs (or releases registered machines).

---

## Upgrades with Omni

```bash
# Upgrade Talos version on all nodes
omnictl update cluster terra-omni --talos-version v1.14.0

# Upgrade Kubernetes version
omnictl update cluster terra-omni --kubernetes-version 1.37.0
```

Omni performs rolling upgrades automatically — one node at a time, draining, upgrading, rebooting, and uncordoning.

---

## Comparison: Manual vs Terraform vs Omni

| Aspect | Manual (`cmk`) | Terraform | Omni |
|--------|---------------|-----------|------|
| VM provisioning | Manual `cmk` commands | Terraform `apply` | Automatic via provider |
| Config generation | `talosctl gen config` | `talosctl gen config` | Automatic |
| Bootstrap | `talosctl bootstrap` | `talosctl bootstrap` | Automatic |
| etcd management | Manual | Manual (or auto-join) | Automatic |
| Kubernetes API endpoint | Load balancer (6443) | Load balancer (6443) | SideroLink tunnel |
| talosctl access | Port forwarding (50000) | Port forwarding (50000) | Via Omni |
| Scaling | Manual VMs + LB + etcd | Terraform apply + etcd | `omnictl update` |
| Upgrades | `talosctl upgrade` per node | `talosctl upgrade` per node | Automatic rolling |
| CCM/CSI install | Manual | Manual | Manual (same) |
| Monitoring | Manual | Manual | Omni UI |
| Complexity | High | Medium | Low |
| CloudStack resources | Manual | Terraform-managed | Omni-managed |

---

## Known Issues & Considerations

### CloudStack Infrastructure Provider Availability

As of this writing, CloudStack may not have a built-in infrastructure provider in Omni. If the `type: CloudStack` provider is not available, you have two options:

1. **Use Machine Registration** (Option 2 above) — provision VMs manually and register them with Omni
2. **Write a custom infrastructure provider** — see the [Omni documentation](https://docs.siderolabs.com/omni/latest/infrastructure-and-extensions/writing-infrastructure-providers/)

### Network Requirements

Omni requires outbound internet access from the Talos nodes to reach the Omni endpoint (SaaS or self-hosted). The CloudStack network offering `DefaultNetworkOfferingforKubernetesService` has `egressdefaultpolicy=true`, so this should work out of the box.

For self-hosted Omni, ensure the Omni instance is reachable from the CloudStack isolated network (or use a public IP + port forwarding).

### Licensing

- **Omni SaaS** — free 2-week trial, then requires a paid plan
- **Omni Self-Hosted** — free for non-production use (home lab, development); requires a commercial license for production use
- **Talos Linux** — open source (MPL 2.0), no license required

### CSI `cloud-init-dir` on Talos

The same CSI patching issue applies — see the [known issues in talos.md](talos.md#csi-node-pod-fails-with-cloud-init-dir-mount-error). The pre-patched DaemonSet at `manifests/csi-node-daemonset-talos.yaml` handles this.

---

## References

- [Omni Documentation](https://docs.siderolabs.com/omni/latest/)
- [Getting Started with Omni](https://docs.siderolabs.com/omni/latest/getting-started/getting-started-with-omni/)
- [Infrastructure Providers](https://docs.siderolabs.com/omni/latest/infrastructure-and-extensions/infrastructure-providers/)
- [Machine Registration](https://docs.siderolabs.com/omni/latest/infrastructure-and-extensions/machine-registration/)
- [Create a Cluster](https://docs.siderolabs.com/omni/latest/getting-started/create-a-cluster/)
- [Omni Support Matrix](https://docs.siderolabs.com/omni/latest/getting-started/omni-support-matrix/)
- [Talos CloudStack Installation](https://docs.siderolabs.com/talos/v1.13/platform-specific-installations/cloud-platforms/cloudstack/)
- [talos.md](talos.md) — manual Talos setup on CloudStack
- [talos-terraform.md](talos-terraform.md) — Terraform-based Talos setup on CloudStack
