# Self-Hosted Sidero Omni on CloudStack

> **Reference:** [Omni Documentation](https://docs.siderolabs.com/omni/latest/) | [Run Omni On-Prem](https://docs.siderolabs.com/omni/self-hosted/run-omni-on-prem/) | [Hardware Requirements](https://docs.siderolabs.com/omni/self-hosted/omni-on-prem-hardware-requirements/)

## Overview

[Sidero Omni](https://www.siderolabs.com/platform/sidero-omni/) is a Kubernetes management platform by Sidero Labs that automates the creation, scaling, and lifecycle management of Talos Linux clusters. This guide covers deploying a **self-hosted** Omni instance on CloudStack and using it to manage Talos clusters — also running on CloudStack.

### How Omni Changes the Workflow

Compared to the manual ([talos.md](talos.md)) or Terraform ([talos-terraform.md](talos-terraform.md)) approaches, Omni eliminates most operational overhead:

| Aspect | Manual / Terraform | With Omni |
|--------|-------------------|-----------|
| Config generation | `talosctl gen config` | Automatic |
| Bootstrap | `talosctl bootstrap` | Automatic |
| etcd management | Manual join/remove | Automatic |
| Kubernetes API endpoint | Load balancer + port forwarding | SideroLink (WireGuard tunnel) |
| Node registration | Embedded userdata | Machines register with Omni |
| Upgrades | `talosctl upgrade` per node | Automatic rolling upgrades |
| Scaling | Terraform + manual etcd | `omnictl update` |
| Monitoring | Manual | Omni UI |

### Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                     CloudStack (cyz1)                            │
│                                                                  │
│  ┌──────────────────────┐    ┌──────────────────────────────┐   │
│  │  Omni VM              │    │  Talos Cluster Nodes          │   │
│  │  (self-hosted)        │    │                               │   │
│  │                       │    │  ┌──────────────────────┐    │   │
│  │  ┌─────────────────┐  │    │  │ CP-1  CP-2  CP-3     │    │   │
│  │  │ Omni container   │  │    │  │ (Talos Linux)        │    │   │
│  │  │ Dex (OIDC)        │  │    │  └──────────────────────┘    │   │
│  │  │ etcd (embedded)   │  │    │  ┌──────────────────────┐    │   │
│  │  │ Image Factory     │  │    │  │ Worker-1  Worker-2   │    │   │
│  │  │ Container Registry│  │    │  │ (Talos Linux)        │    │   │
│  │  └─────────────────┘  │    │  └──────────────────────┘    │   │
│  │         │              │    │         │                   │   │
│  │         │ SideroLink   │    │ SideroLink│                  │   │
│  │         │ (WireGuard)  │    │ (WireGuard)│                 │   │
│  │         └──────────────┼────┼───────────┘                 │   │
│  └──────────────────────┘    └──────────────────────────────┘   │
│                                                                  │
│  Public IP: 192.168.200.X (port forwarding to Omni VM)          │
└──────────────────────────────────────────────────────────────────┘
```

Key architectural points:

- **SideroLink** — Omni establishes a WireGuard-encrypted tunnel to each registered machine. No public load balancer or port forwarding rules needed for the cluster nodes.
- **No LB for cluster** — Omni provides the Kubernetes API endpoint through the SideroLink tunnel. You don't need a CloudStack load balancer rule for port 6443.
- **No port forwarding for talosctl** — `talosctl` communicates through Omni, not directly to nodes.
- **Omni VM needs public access** — the Omni VM itself must be reachable from the Talos nodes (via SideroLink/WireGuard) and from administrators (UI/CLI).

---

## Prerequisites

### Omni VM Hardware Requirements

For a single-VM Omni deployment (recommended for most self-hosted setups), the following is a reasonable baseline for up to ~200 managed nodes:

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| vCPUs | 2 | 4 |
| RAM | 4 GB | 8–16 GB |
| Disk | 200 GB SSD | 500 GB SSD |
| Network | 1 Gbps | 2.5 Gbps (for heavy WireGuard traffic) |

For fewer than 50 managed nodes, 2 vCPUs + 8 GB RAM + 200 GB SSD is sufficient.

### CloudStack Environment

Same prerequisites as [talos.md](talos.md#prerequisites):

- **Zone:** `cyz1` (`227f3c30-596d-43ca-b2a5-b03d18b02e1f`)
- **Network:** `DefaultNetworkOfferingforKubernetesService` (egress allowed by default)
- **Template:** `talos-v1.13.6` (`e0c83e0d-adc9-4d36-93cc-45024b73f36d`)
- **CP offering:** `kube control` (`2cc8d224-da47-4178-9d32-70a4d63d216c`)
- **Worker offering:** `kube worker1` (`c04878fc-4e7f-44a7-8bf5-83dde09a26d9`)
- **Guest CPU mode:** `host-passthrough` (required for Talos)
- **Management server:** SSH as `toor` to `192.168.200.1`

### Ports Required for Omni

The Omni VM needs these ports open (firewall rules on the public IP):

| Port | Protocol | Purpose |
|------|----------|---------|
| 443 | TCP | Omni UI and API |
| 8090 | TCP | SideroLink API |
| 8091 | TCP | Event sink |
| 8100 | TCP | Kubernetes proxy |
| 5556 | TCP | Dex OIDC |
| 50180 | UDP | WireGuard (SideroLink) |

---

## Part 1: Deploy the Omni VM on CloudStack

### Step 1: Create a VM for Omni

Deploy a Linux VM (Ubuntu 22.04/24.04 or Rocky Linux) on CloudStack:

```bash
# Find a suitable template (Ubuntu 22.04+)
cmk list templates templatefilter=executable zoneid=227f3c30-596d-43ca-b2a5-b03d18b02e1f

# Deploy the Omni VM
cmk deploy virtualmachine \
  zoneid=227f3c30-596d-43ca-b2a5-b03d18b02e1f \
  templateid=<ubuntu-template-id> \
  serviceofferingid=<offering-id> \
  networkids=<network-id> \
  name=omni-server \
  rootdisksize=500
```

### Step 2: Allocate a Public IP and Configure Firewall

```bash
# Allocate a public IP
cmk associate ipaddress networkid=<network-id> zoneid=227f3c30-596d-43ca-b2a5-b03d18b02e1f

# Note the IP address
PUBLIC_IP=<allocated-ip>

# Create firewall rules for Omni ports
for port in 443 8090 8091 8100 5556; do
  cmk create firewallrule ipaddressid=${PUBLIC_IP_ID} protocol=tcp startport=$port endport=$port cidrlist=0.0.0.0/0
done

# WireGuard UDP
cmk create firewallrule ipaddressid=${PUBLIC_IP_ID} protocol=udp startport=50180 endport=50180 cidrlist=0.0.0.0/0

# Create port forwarding for SSH and Omni ports
cmk create portforwardingrule \
  ipaddressid=${PUBLIC_IP_ID} \
  privateport=22 publicport=22 protocol=tcp \
  virtualmachineid=${OMNI_VM_ID} \
  openfirewall=true cidrlist=<your-admin-ip>/32

cmk create portforwardingrule \
  ipaddressid=${PUBLIC_IP_ID} \
  privateport=443 publicport=443 protocol=tcp \
  virtualmachineid=${OMNI_VM_ID}

# Repeat for ports 8090, 8091, 8100, 5556, 50180
```

### Step 3: SSH into the Omni VM and Install Docker

```bash
ssh toor@<public-ip>

# Install Docker
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker
```

---

## Part 2: Deploy Omni (Single VM)

This follows the [official Run Omni On-Prem guide](https://docs.siderolabs.com/omni/self-hosted/run-omni-on-prem/).

### Step 1: Install cfssl

```bash
CFSSL_VERSION=$(curl -sI https://github.com/cloudflare/cfssl/releases/latest \
  | grep -i location | awk -F '/' '{print $NF}' | tr -d '\r')

curl -L -o cfssl \
  https://github.com/cloudflare/cfssl/releases/download/${CFSSL_VERSION}/cfssl_${CFSSL_VERSION#v}_linux_amd64
curl -L -o cfssljson \
  https://github.com/cloudflare/cfssl/releases/download/${CFSSL_VERSION}/cfssljson_${CFSSL_VERSION#v}_linux_amd64

chmod +x cfssl cfssljson
sudo mv cfssl cfssljson /usr/local/bin/
```

### Step 2: Set Environment Variables

```bash
export HOST_PUBLIC_IP=<omni-public-ip>
export HOST_PRIVATE_IP=<omni-private-ip>
export OMNI_ENDPOINT=omni.internal
export AUTH_ENDPOINT=auth.internal
export OMNI_USER_EMAIL="admin@omni.internal"

echo "127.0.0.1 ${OMNI_ENDPOINT} ${AUTH_ENDPOINT}" | sudo tee -a /etc/hosts
```

### Step 3: Generate TLS Certificates

```bash
# Create root CA
cat <<EOF > ca-csr.json
{
  "CN": "Internal Root CA",
  "key": { "algo": "rsa", "size": 4096 },
  "names": [{ "C": "US", "O": "Internal Infrastructure", "OU": "Security" }]
}
EOF

cfssl gencert -initca ca-csr.json | cfssljson -bare ca

sudo cp ca.pem /usr/local/share/ca-certificates/ca.crt
sudo update-ca-certificates

# Create signing config
cat <<EOF > ca-config.json
{
  "signing": {
    "default": { "expiry": "8760h" },
    "profiles": {
      "web-server": {
        "usages": ["signing", "key encipherment", "server auth"],
        "expiry": "8760h"
      },
      "client": {
        "usages": ["signing", "key encipherment", "client auth"],
        "expiry": "8760h"
      }
    }
  }
}
EOF

# Generate server certificate
cat <<EOF > wildcard-csr.json
{
  "CN": "Internal Wildcard",
  "hosts": [
    "${OMNI_ENDPOINT}",
    "${AUTH_ENDPOINT}",
    "127.0.0.1",
    "${HOST_PUBLIC_IP}",
    "${HOST_PRIVATE_IP}"
  ],
  "key": { "algo": "rsa", "size": 4096 }
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=web-server wildcard-csr.json | cfssljson -bare server

cat server.pem ca.pem > server-chain.pem
chmod 644 server*.pem
```

### Step 4: Generate etcd Encryption Key

```bash
gpg --batch --passphrase '' \
  --quick-generate-key \
  "Omni (Used for etcd data encryption) omni@internal.local" \
  rsa4096 cert never

FINGERPRINT=$(gpg --with-colons --list-keys "omni@internal.local" \
  | awk -F: '$1 == "fpr" {print $10; exit}')

gpg --batch --passphrase '' \
  --quick-add-key ${FINGERPRINT} rsa4096 encr never

gpg --export-secret-key --armor omni@internal.local > omni.asc
```

### Step 5: Set Up Dex (OIDC Provider)

```bash
# Create password hash
export OMNI_USER_PASSWORD=$(docker run --rm httpd:2.4-alpine \
  htpasswd -BnC 15 admin | cut -d: -f2)

# Write Dex config
cat <<EOF > dex.yaml
issuer: https://${AUTH_ENDPOINT}:5556

storage:
  type: memory

web:
  https: 0.0.0.0:5556
  tlsCert: /etc/dex/tls/server-chain.pem
  tlsKey: /etc/dex/tls/server-key.pem

enablePasswordDB: true

staticClients:
  - name: Omni
    id: omni
    secret: omni-dex-secret
    redirectURIs:
      - https://${OMNI_ENDPOINT}/oidc/consume

staticPasswords:
  - email: "${OMNI_USER_EMAIL}"
    username: "admin"
    preferredUsername: "admin"
    hash: "${OMNI_USER_PASSWORD}"
EOF

# Run Dex
docker run -d \
  --name dex \
  --restart=unless-stopped \
  -p 5556:5556 \
  -v $(pwd)/dex.yaml:/etc/dex/dex.yaml:ro,Z \
  -v $(pwd)/server-key.pem:/etc/dex/tls/server-key.pem:ro,Z \
  -v $(pwd)/server-chain.pem:/etc/dex/tls/server-chain.pem:ro,Z \
  ghcr.io/dexidp/dex:v2.41.1 \
    dex serve /etc/dex/dex.yaml
```

### Step 6: Run Omni

```bash
# Get latest Omni version
export OMNI_VERSION=$(curl -sI https://github.com/siderolabs/omni/releases/latest \
  | grep -i location | awk -F '/' '{print $NF}' | tr -d '\r')

# Create SQLite directory
mkdir -p $HOME/sqlite

# Run Omni container
docker run -d \
  --name omni \
  --restart=unless-stopped \
  -p 443:443 \
  -p 8090:8090 \
  -p 8091:8091 \
  -p 8100:8100 \
  -p 50180:50180/udp \
  -v $(pwd)/server-key.pem:/etc/omni/tls/server-key.pem:ro,Z \
  -v $(pwd)/server-chain.pem:/etc/omni/tls/server-chain.pem:ro,Z \
  -v $(pwd)/omni.asc:/etc/omni/omni.asc:ro,Z \
  -v $HOME/sqlite:/etc/omni/sqlite:Z \
  ghcr.io/siderolabs/omni:${OMNI_VERSION} \
    --account-id=cloudstack-lab \
    --name=cloudstack-lab \
    --siderolink-api-advertised-url=https://${HOST_PUBLIC_IP}:8090 \
    --siderolink-wireguard-advertised-url=https://${HOST_PUBLIC_IP}:50180 \
    --event-sink-advertised-url=https://${HOST_PUBLIC_IP}:8091 \
    --advertised-api-url=https://${OMNI_ENDPOINT}:443 \
    --auth-auth0-domain=${AUTH_ENDPOINT}:5556 \
    --auth-auth0-client-id=omni \
    --auth-auth0-client-secret=omni-dex-secret \
    --etcd-encryption-key-file=/etc/omni/omni.asc \
    --sqlite-path=/etc/omni/sqlite/omni.db \
    --eula-accepted=true
```

> **Note:** The `--eula-accepted=true` flag accepts the EULA programmatically. If your organization has a separate agreement with Sidero Labs, that takes precedence.

### Step 7: Verify Omni is Running

```bash
docker logs omni --tail 20
# Look for: "Omni is ready" or similar startup message

# Check ports are listening
ss -tulpn | grep -E '443|8090|8091|8100|50180|5556'
```

---

## Part 3: Install and Configure Omnictl

On your admin machine (e.g., hermes1):

```bash
# Install omnictl
curl -sL https://github.com/siderolabs/omni/releases/latest/download/omnictl-linux-amd64 -o /usr/local/bin/omnictl
chmod +x /usr/local/bin/omnictl

# Add the CA cert to your trust store
# Copy ca.pem from the Omni VM to your admin machine
scp toor@<omni-public-ip>:~/ca.pem /usr/local/share/ca-certificates/omni-ca.crt
sudo update-ca-certificates

# Configure omnictl context
omnictl config context add cloudstack-lab \
  --url=https://<omni-public-ip> \
  --auth-mode=basic

# Log in
omnictl login --auth-mode=basic
# Username: admin
# Password: <the password you set in Dex>

# Verify
omnictl get contexts
```

---

## Part 4: Register Talos Machines with Omni

Since CloudStack may not have a built-in Omni infrastructure provider, we use the **Machine Registration** approach — provision VMs manually and have them register with Omni.

### Step 1: Create a Registration Token

```bash
# Generate a registration URL for control plane machines
omnictl create registration-url \
  --label 'type=control-plane' \
  --label 'region=cyz1'

# Generate a registration URL for worker machines
omnictl create registration-url \
  --label 'type=worker' \
  --label 'region=cyz1'
```

This outputs URLs like:
- `https://<omni-ip>/registration/<cp-token>`
- `https://<omni-ip>/registration/<worker-token>`

### Step 2: Deploy Talos VMs with Registration Config

On the CloudStack management server, create a minimal registration config and deploy VMs:

```bash
# Create registration config for control plane
cat > register-cp.yaml <<EOF
version: v1alpha1
kind: MachineConfig
registration:
  url: "https://<omni-ip>/registration/<cp-token>"
EOF

# Create registration config for workers
cat > register-worker.yaml <<EOF
version: v1alpha1
kind: MachineConfig
registration:
  url: "https://<omni-ip>/registration/<worker-token>"
EOF

# Deploy control plane VMs
for i in 1 2 3; do
  cmk deploy virtualmachine \
    zoneid=227f3c30-596d-43ca-b2a5-b03d18b02e1f \
    templateid=e0c83e0d-adc9-4d36-93cc-45024b73f36d \
    serviceofferingid=2cc8d224-da47-4178-9d32-70a4d63d216c \
    networkid=<network-id> \
    name=omni-cp-${i} \
    userdata=$(base64 register-cp.yaml | tr -d '\n')
done

# Deploy worker VMs
for i in 1 2; do
  cmk deploy virtualmachine \
    zoneid=227f3c30-596d-43ca-b2a5-b03d18b02e1f \
    templateid=e0c83e0d-adc9-4d36-93cc-45024b73f36d \
    serviceofferingid=c04878fc-4e7f-44a7-8bf5-83dde09a26d9 \
    networkid=<network-id> \
    name=omni-worker-${i} \
    userdata=$(base64 register-worker.yaml | tr -d '\n')
done
```

The VMs boot Talos, connect to Omni via SideroLink, and register themselves. You can monitor registration in the Omni UI or via:

```bash
omnictl get machines
```

### Step 3: Create a Machine Class

```bash
# Create machine classes based on labels
omnictl create machine-class cp-machines \
  --label-selector 'type=control-plane'

omnictl create machine-class worker-machines \
  --label-selector 'type=worker'
```

---

## Part 5: Create a Cluster

```bash
omnictl create cluster omni-cluster \
  --kubernetes-version 1.36.2 \
  --talos-version v1.13.6 \
  --control-plane-class cp-machines \
  --worker-class worker-machines \
  --control-plane-count 3 \
  --worker-count 2
```

Omni will:
1. Select registered machines matching the machine classes
2. Generate and apply Talos configs
3. Bootstrap the cluster
4. Set up the Kubernetes API endpoint via SideroLink
5. Install Flannel (default CNI)

### Access the Cluster

```bash
# Get kubeconfig
omnictl get kubeconfig omni-cluster > ~/.kube/config-omni

# Or use omnictl proxy
omnictl proxy omni-cluster

# In another terminal
kubectl get nodes
```

---

## Part 6: Post-Deployment — CCM and CSI

Omni manages the cluster lifecycle but does **not** install the CloudStack CCM or CSI driver. These must be installed manually:

### Install CCM

```bash
# Create the cloudstack-secret
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

## Part 7: Cluster Lifecycle with Omni

### Scaling

```bash
# Add workers
omnictl update cluster omni-cluster --worker-count 5

# Add control plane nodes
omnictl update cluster omni-cluster --control-plane-count 5

# Scale down
omnictl update cluster omni-cluster --worker-count 2
omnictl update cluster omni-cluster --control-plane-count 3
```

Omni handles VM provisioning (or machine selection), etcd membership, and Kubernetes node management automatically.

### Upgrades

```bash
# Upgrade Talos version
omnictl update cluster omni-cluster --talos-version v1.14.0

# Upgrade Kubernetes version
omnictl update cluster omni-cluster --kubernetes-version 1.37.0
```

Omni performs rolling upgrades — one node at a time, draining, upgrading, rebooting, and uncordoning.

### Import an Existing Talos Cluster

If you already have a Talos cluster (like `terra-talos`), you can import it into Omni:

```bash
# On the existing cluster, get the talosconfig
# Then register with Omni
omnictl import talosconfig --cluster-name terra-talos ./talosconfig
```

See [Import Talos Clusters](https://docs.siderolabs.com/omni/cluster-management/importing-talos-clusters/) for details.

---

## Comparison: Manual vs Terraform vs Self-Hosted Omni

| Aspect | Manual (`cmk`) | Terraform | Self-Hosted Omni |
|--------|---------------|-----------|-----------------|
| VM provisioning | Manual `cmk` commands | Terraform `apply` | Manual (registration) or automatic (provider) |
| Config generation | `talosctl gen config` | `talosctl gen config` | Automatic |
| Bootstrap | `talosctl bootstrap` | `talosctl bootstrap` | Automatic |
| etcd management | Manual | Manual (or auto-join) | Automatic |
| Kubernetes API endpoint | Load balancer (6443) | Load balancer (6443) | SideroLink tunnel |
| talosctl access | Port forwarding (50000) | Port forwarding (50000) | Via Omni |
| Scaling | Manual VMs + LB + etcd | Terraform apply + etcd | `omnictl update` |
| Upgrades | `talosctl upgrade` per node | `talosctl upgrade` per node | Automatic rolling |
| CCM/CSI install | Manual | Manual | Manual (same) |
| Monitoring | Manual | Manual | Omni UI |
| Infrastructure to manage | CloudStack only | CloudStack + Terraform | CloudStack + Omni VM |
| Complexity | High | Medium | Medium (Omni setup) / Low (daily ops) |

---

## Known Issues & Considerations

### Network Requirements

- Talos nodes need outbound access to the Omni VM (SideroLink uses WireGuard, UDP 50180)
- The CloudStack network offering `DefaultNetworkOfferingforKubernetesService` has `egressdefaultpolicy=true`, so this works out of the box
- For the Omni VM, ensure the public IP firewall allows all required ports (see [Ports Required for Omni](#ports-required-for-omni))

### Omni VM Availability

Omni is not part of the Kubernetes control plane. If the Omni VM goes down, your clusters continue running normally. Talos machines reconnect when Omni becomes available again. However, external access (`kubectl`, `omnictl`) won't work until Omni is recovered.

Omni offers a "break glass" configuration for emergency access when Omni is unavailable.

### Licensing

- **Omni Self-Hosted** — free for non-production use (home lab, development); requires a [commercial license](mailto:sales@siderolabs.com) for production use
- **Talos Linux** — open source (MPL 2.0), no license required

### CSI `cloud-init-dir` on Talos

The same CSI patching issue applies — see the [known issues in talos.md](talos.md#csi-node-pod-fails-with-cloud-init-dir-mount-error). The pre-patched DaemonSet at `manifests/csi-node-daemonset-talos.yaml` handles this.

### Backup

Back up the Omni VM regularly. VM snapshots are usually sufficient since Omni stores state in embedded etcd and SQLite on the local disk. See [Back Up Omni Database](https://docs.siderolabs.com/omni/self-hosted/back-up-omni-db/) for details.

---

## References

- [Run Omni On-Prem](https://docs.siderolabs.com/omni/self-hosted/run-omni-on-prem/) — official deployment guide
- [Omni On-Prem Hardware Requirements](https://docs.siderolabs.com/omni/self-hosted/omni-on-prem-hardware-requirements/)
- [Omni Configuration Examples](https://docs.siderolabs.com/omni/self-hosted/omni-configuration-example/)
- [Machine Registration](https://docs.siderolabs.com/omni/latest/infrastructure-and-extensions/machine-registration/)
- [Create a Cluster](https://docs.siderolabs.com/omni/latest/getting-started/create-a-cluster/)
- [Import Talos Clusters](https://docs.siderolabs.com/omni/cluster-management/importing-talos-clusters/)
- [Omni Firewall and Egress Requirements](https://docs.siderolabs.com/omni/omni-cluster-setup/omni-firewall-egress-requirement/)
- [Expose Omni with Nginx (HTTPS)](https://docs.siderolabs.com/omni/self-hosted/expose-omni-with-nginx-https/)
- [Configure Keycloak for Omni](https://docs.siderolabs.com/omni/self-hosted/configure-keycloak-for-omni/)
- [talos.md](talos.md) — manual Talos setup on CloudStack
- [talos-terraform.md](talos-terraform.md) — Terraform-based Talos setup on CloudStack
