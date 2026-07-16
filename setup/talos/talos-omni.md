# Self-Hosted Sidero Omni on CloudStack

> **Reference:** [Omni Documentation](https://docs.siderolabs.com/omni/latest/) | [Run Omni On-Prem](https://docs.siderolabs.com/omni/self-hosted/run-omni-on-prem/) | [Hardware Requirements](https://docs.siderolabs.com/omni/self-hosted/omni-on-prem-hardware-requirements/)

## Overview

[Sidero Omni](https://www.siderolabs.com/platform/sidero-omni/) is a Kubernetes management platform by Sidero Labs that automates the creation, scaling, and lifecycle management of Talos Linux clusters. This guide covers deploying a **self-hosted** Omni instance on CloudStack and using it to manage Talos clusters — also running on CloudStack.

### Omni Deployment Options

| Option | Description | Complexity | Best For |
|--------|-------------|------------|----------|
| **Omni SaaS** | Fully managed by Sidero Labs. No infrastructure to manage. | None | Most users; quick start, no ops overhead |
| **Self-hosted (Docker)** | Single VM running Omni as a Docker container with embedded etcd. | Low | Most self-hosted environments; home labs, dev, production up to ~200 nodes |
| **Self-hosted (Kubernetes)** | Omni deployed on a separate Kubernetes cluster (not managed by Omni). | Medium | Environments needing faster pod recovery or standardized K8s operations |
| **Self-hosted (HA)** | Multiple Omni instances backed by external etcd, HA registry, HA Image Factory, HA auth. | Very high | Strict uptime requirements (~99.99%); mature ops teams |

**This guide focuses on the self-hosted Docker (single VM) approach** for the following reasons:

- **Simple and dependable** — Omni runs as a single Docker container with embedded etcd. No Kubernetes cluster to maintain, no external database to manage.
- **VM snapshots are sufficient for backup** — since all state is stored locally (embedded etcd + SQLite), a VM-level snapshot is usually enough for recovery.
- **Downtime has no effect on your clusters** — Omni is not part of the Kubernetes control plane. If the Omni VM goes offline, your Talos clusters continue running normally. Talos machines reconnect automatically when Omni comes back. Only external access (`kubectl`, `omnictl`) is temporarily unavailable.
- **No circular dependency** — deploying Omni on Kubernetes requires a separate K8s cluster that is *not* managed by Omni. The Docker approach avoids this entirely.
- **Proven at scale** — a single VM handles up to ~200 managed nodes with modest resources (4 vCPUs, 8–16 GB RAM, 500 GB SSD).
- **Recommended by Sidero Labs** — the official documentation recommends the single VM deployment as the preferred on-premises setup for most environments.

### How Omni Changes the Workflow

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
│                     CloudStack (shared L2 network)               │
│                                                                  │
│  ┌──────────────────────┐    ┌──────────────────────────────┐   │
│  │  Omni VM              │    │  Talos Cluster Nodes          │   │
│  │  192.168.188.204      │    │                               │   │
│  │                       │    │  ┌──────────────────────┐    │   │
│  │  ┌─────────────────┐  │    │  │ CP-1  CP-2  CP-3     │    │   │
│  │  │ Omni container   │  │    │  │ (Talos Linux)        │    │   │
│  │  │ port 443 (HTTPS)  │  │    │  └──────────────────────┘    │   │
│  │  │ port 8090 (gRPC)  │  │    │  ┌──────────────────────┐    │   │
│  │  │ port 50180/UDP   │  │    │  │ Worker-1  Worker-2   │    │   │
│  │  │ (WireGuard)       │  │    │  │ (Talos Linux)        │    │   │
│  │  ├─────────────────┤  │    │  └──────────────────────┘    │   │
│  │  │ Dex (OIDC)       │  │    │         │                   │   │
│  │  │ port 5556 (HTTPS)│  │    │ SideroLink│                  │   │
│  │  └─────────────────┘  │    │ (WireGuard)│                 │   │
│  │         │              │    │         │                   │   │
│  │         └──────────────┼────┼───────────┘                 │   │
│  └──────────────────────┘    └──────────────────────────────┘   │
│                                                                  │
│  All VMs on same L2 network — no public IP needed                │
└──────────────────────────────────────────────────────────────────┘
```

Key architectural points:

- **SideroLink** — Omni establishes a WireGuard-encrypted tunnel to each registered machine. No public load balancer or port forwarding rules needed for the cluster nodes.
- **No LB for cluster** — Omni provides the Kubernetes API endpoint through the SideroLink tunnel. You don't need a CloudStack load balancer rule for port 6443.
- **No port forwarding for talosctl** — `talosctl` communicates through Omni, not directly to nodes.
- **Private IP only** — on a shared CloudStack network, all VMs (Omni + Talos nodes) are on the same L2 segment. No public IP or port forwarding is required for Omni to function. The Omni UI is accessed directly at the private IP.
- **Full HTTPS** — both Omni (port 443) and Dex (port 5556) serve HTTPS using the same self-signed CA. Install the CA certificate in your browser's trust store to avoid TLS warnings.

---

## Prerequisites

### Omni VM Hardware Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| vCPUs | 2 | 4 |
| RAM | 4 GB | 8–16 GB |
| Disk | 200 GB SSD | 500 GB SSD |
| Network | 1 Gbps | Same L2 segment as Talos nodes |

### CloudStack Environment

Same prerequisites as [talos.md](talos.md#prerequisites):

- **Zone:** `cyz1`
- **Network:** Shared L2 network (e.g., `s1net`) — all VMs must be on the same network
- **Template:** Any Linux distribution (Debian, Ubuntu, Rocky Linux) for the Omni VM
- **Talos template:** `talos-v1.13.6` (for the managed cluster nodes)
- **Management server:** SSH access to CloudStack management server

### Ports Required on the Omni VM

| Port | Protocol | Purpose |
|------|----------|---------|
| 443 | TCP | Omni UI and API (HTTPS, self-signed cert) |
| 8090 | TCP | SideroLink gRPC API |
| 8091 | TCP | Event sink |
| 8100 | TCP | Kubernetes proxy |
| 5556 | TCP | Dex OIDC (HTTPS, same self-signed cert) |
| 50180 | UDP | WireGuard (SideroLink) |

---

## Part 1: Deploy the Omni VM on CloudStack

### Step 1: Create a VM for Omni

```bash
# Find a suitable Linux template
cmk list templates templatefilter=executable zoneid=<zone-id>

# Deploy the Omni VM
cmk deploy virtualmachine \
  zoneid=<zone-id> \
  templateid=<linux-template-id> \
  serviceofferingid=<offering-id> \
  networkids=<network-id> \
  name=omni \
  rootdisksize=200
```

### Step 2: SSH into the Omni VM and Install Docker

```bash
ssh toor@<omni-private-ip>

# Install Docker
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker
```

---

## Part 2: Deploy Omni (Single VM)

All commands below run on the Omni VM. Both Omni and Dex serve HTTPS using the same self-signed CA. Install the CA certificate in your browser's trust store to avoid TLS warnings (see [Step 7](#step-7-access-the-omni-ui)).

### Step 1: Install cfssl

```bash
mkdir -p ~/omni-setup && cd ~/omni-setup

CFSSL_VERSION=$(curl -sI https://github.com/cloudflare/cfssl/releases/latest \
  | grep -i location | awk -F '/' '{print $NF}' | tr -d '\r')

curl -L -o cfssl \
  https://github.com/cloudflare/cfssl/releases/download/${CFSSL_VERSION}/cfssl_${CFSSL_VERSION#v}_linux_amd64
curl -L -o cfssljson \
  https://github.com/cloudflare/cfssl/releases/download/${CFSSL_VERSION}/cfssljson_${CFSSL_VERSION#v}_linux_amd64

chmod +x cfssl cfssljson
sudo mv cfssl cfssljson /usr/local/bin/
```

### Step 2: Generate TLS Certificates

```bash
cd ~/omni-setup

# Create root CA
cat > ca-csr.json <<EOF
{
  "CN": "Internal Root CA",
  "key": { "algo": "rsa", "size": 4096 },
  "names": [{ "C": "US", "O": "Internal Infrastructure", "OU": "Security" }]
}
EOF

cfssl gencert -initca ca-csr.json | cfssljson -bare ca

# Add CA to system trust store (so Omni container trusts Dex's certs)
sudo cp ca.pem /usr/local/share/ca-certificates/ca.crt
sudo update-ca-certificates

# Create signing config
cat > ca-config.json <<EOF
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

# Generate server certificate with the Omni VM's private IP in SANs
OMNI_IP=<omni-private-ip>  # e.g. 192.168.188.204

cat > wildcard-csr.json <<EOF
{
  "CN": "Omni Server",
  "hosts": [
    "${OMNI_IP}",
    "127.0.0.1"
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

### Step 3: Generate etcd Encryption Key

```bash
cd ~/omni-setup

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

### Step 4: Set Up Dex (OIDC Provider)

Dex serves over **HTTPS** using the same self-signed CA and certificate as Omni. The OIDC flow works like this:

```
Browser ──HTTPS──→ Omni (port 443, self-signed cert)
Browser ──HTTPS──→ Dex  (port 5556, same self-signed cert)
Dex     ──HTTPS──→ Browser (redirect back to Omni)
Browser ──HTTPS──→ Omni (port 443, /oidc/consume)
```

Both services use the same CA, so installing the CA cert in your browser's trust store eliminates all TLS warnings.

```bash
cd ~/omni-setup

# Generate bcrypt password hash (cost 10 required by Dex)
python3 -c "
import bcrypt
password = b'omni-admin-password'
salt = bcrypt.gensalt(rounds=10)
hashed = bcrypt.hashpw(password, salt).decode()
# Go's bcrypt expects \$2a\$ prefix
hashed = hashed.replace('\$2b\$', '\$2a\$')
print(hashed)
" > /tmp/dex-hash.txt

# Write Dex config
python3 -c "
import yaml

with open('/tmp/dex-hash.txt') as f:
    hashed = f.read().strip()

config = {
    'issuer': 'https://${OMNI_IP}:5556',
    'storage': {'type': 'memory'},
    'web': {
        'https': '0.0.0.0:5556',
        'tlsCert': '/etc/dex/tls/server-chain.pem',
        'tlsKey': '/etc/dex/tls/server-key.pem'
    },
    'enablePasswordDB': True,
    'staticClients': [{
        'name': 'Omni',
        'id': 'omni',
        'secret': 'omni-dex-secret',
        'redirectURIs': ['https://${OMNI_IP}:443/oidc/consume']
    }],
    'staticPasswords': [{
        'email': 'admin@omni.internal',
        'username': 'admin',
        'preferredUsername': 'admin',
        'hash': hashed
    }]
}
with open('dex.yaml', 'w') as f:
    yaml.dump(config, f, default_flow_style=False)
"

# Run Dex with TLS certs mounted
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

> **Note:** The bcrypt hash must have cost >= 10. The `htpasswd` command defaults to cost 5, which Dex rejects. Use Python's `bcrypt` library or explicitly set `-C 10` with `htpasswd`.

### Step 5: Run Omni

Omni runs with `--network=host` so it can reach Dex on localhost. It uses embedded etcd and stores data in a SQLite database.

```bash
cd ~/omni-setup

# Get latest Omni version
export OMNI_VERSION=$(curl -sI https://github.com/siderolabs/omni/releases/latest \
  | grep -i location | awk -F '/' '{print $NF}' | tr -d '\r')

# Create data directory
mkdir -p $HOME/sqlite

# Run Omni container
docker run -d \
  --name omni \
  --restart=unless-stopped \
  --network=host \
  --cap-add=NET_ADMIN \
  --device /dev/net/tun:/dev/net/tun \
  -v $(pwd)/ca.pem:/etc/ssl/certs/ca-certificates.crt:ro \
  -v $(pwd)/server-chain.pem:/etc/omni/tls/server-chain.pem:ro,Z \
  -v $(pwd)/server-key.pem:/etc/omni/tls/server-key.pem:ro,Z \
  -v $(pwd)/omni.asc:/etc/omni/omni.asc:ro,Z \
  -v $HOME/sqlite:/etc/omni/sqlite:Z \
  ghcr.io/siderolabs/omni:${OMNI_VERSION} \
    --account-id=cloudstack-lab \
    --name=cloudstack-lab \
    --bind-addr=0.0.0.0:443 \
    --cert=/etc/omni/tls/server-chain.pem \
    --key=/etc/omni/tls/server-key.pem \
    --siderolink-wireguard-advertised-addr=${OMNI_IP}:50180 \
    --siderolink-wireguard-bind-addr=0.0.0.0:50180 \
    --advertised-api-url=https://${OMNI_IP}:443 \
    --auth-oidc-enabled \
    --auth-oidc-provider-url=https://${OMNI_IP}:5556 \
    --auth-oidc-client-id=omni \
    --auth-oidc-client-secret=omni-dex-secret \
    --auth-oidc-scopes=openid,profile,email \
    --initial-users=admin@omni.internal \
    --etcd-embedded \
    --etcd-embedded-db-path=/etc/omni/sqlite/etcd \
    --private-key-source=file:///etc/omni/omni.asc \
    --sqlite-storage-path=/etc/omni/sqlite/omni.db \
    --eula-accept-email=admin@omni.internal \
    --eula-accept-name=admin \
    --create-initial-service-account \
    --initial-service-account-key-path=/etc/omni/sqlite/service-account-key.pem
```

> **Important flags explained:**
> - `--network=host` — required so Omni can reach Dex on localhost:5556
> - `--cap-add=NET_ADMIN --device /dev/net/tun` — required for WireGuard (SideroLink)
> - `--auth-oidc-scopes=openid,profile,email` — Dex requires the `openid` scope or it rejects the request
> - `--initial-users=admin@omni.internal` — authorizes this user on first start. Must match the email in Dex's `staticPasswords`
> - `--private-key-source=file:///etc/omni/omni.asc` — the GPG key for etcd encryption (note the `file://` prefix)
> - `--etcd-embedded` — uses embedded etcd (no external database needed)

### Step 6: Verify Omni is Running

```bash
# Check logs
docker logs omni --tail 20

# Check ports
ss -tulpn | grep -E '443|8090|8091|8100|50180|5556'

# Test the UI
curl -sk https://${OMNI_IP}:443/ | head -5
# Should return HTML (Omni UI)

# Test Dex OIDC endpoint
curl -sk https://${OMNI_IP}:5556/.well-known/openid-configuration | head -5
```

### Step 7: Access the Omni UI

Open `https://<omni-private-ip>:443` in your browser. You'll see a TLS warning because the certificate is self-signed — accept the risk and proceed. You'll see a second TLS warning when redirected to Dex on port 5556 — accept that too.

**To eliminate both warnings**, install the self-signed CA certificate in your browser's trust store:

```bash
# On your admin machine, copy ca.pem from the Omni VM
scp toor@<omni-ip>:~/omni-setup/ca.pem /tmp/omni-ca.crt

# On Linux (system-wide trust store)
sudo cp /tmp/omni-ca.crt /usr/local/share/ca-certificates/omni-ca.crt
sudo update-ca-certificates

# On Firefox: Settings → Privacy & Security → Certificates → View Certificates
#   → Authorities → Import → select /tmp/omni-ca.crt
#   → Check "Trust this CA to identify websites" → OK

# On Chrome/Edge: uses the system trust store (update-ca-certificates above covers it)
# Restart your browser after installing
```

**Login flow:**
1. Omni redirects to `https://<omni-ip>:5556/auth?...` (Dex login page, HTTPS)
2. Enter **Email:** `admin@omni.internal` / **Password:** `omni-admin-password`
3. Click "Grant Access" on the approval page
4. On the "authenticate UI access" page, click to confirm — your browser's public key is registered
5. You are logged into the Omni dashboard

> **Troubleshooting:** If you get "identity is not authorized", ensure `--initial-users=admin@omni.internal` was set on the **first** start. If Omni already initialized without it, wipe the data directory (`~/sqlite/etcd`, `~/sqlite/omni.db`) and restart.

---

## Part 3: Install and Configure Omnictl

On your admin machine (must have network access to the Omni VM):

```bash
# Install omnictl
curl -sL https://github.com/siderolabs/omni/releases/latest/download/omnictl-linux-amd64 -o /usr/local/bin/omnictl
chmod +x /usr/local/bin/omnictl

# Configure context
omnictl config context add cloudstack-lab \
  --url=https://<omni-ip> \
  --auth-mode=basic

# Log in
omnictl login --auth-mode=basic
# Username: admin@omni.internal
# Password: omni-admin-password

# Verify
omnictl get contexts
```

---

## Part 4: Register Talos Machines with Omni

Since CloudStack does not have a built-in Omni infrastructure provider, we use the **Machine Registration** approach — provision VMs manually and have them register with Omni.

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
    zoneid=<zone-id> \
    templateid=<talos-template-id> \
    serviceofferingid=<cp-offering-id> \
    networkid=<network-id> \
    name=omni-cp-${i} \
    userdata=$(base64 register-cp.yaml | tr -d '\n')
done

# Deploy worker VMs
for i in 1 2; do
  cmk deploy virtualmachine \
    zoneid=<zone-id> \
    templateid=<talos-template-id> \
    serviceofferingid=<worker-offering-id> \
    networkid=<network-id> \
    name=omni-worker-${i} \
    userdata=$(base64 register-worker.yaml | tr -d '\n')
done
```

The VMs boot Talos, connect to Omni via SideroLink, and register themselves. Monitor registration:

```bash
omnictl get machines
```

### Step 3: Create a Machine Class

```bash
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

### Upgrades

```bash
# Upgrade Talos version
omnictl update cluster omni-cluster --talos-version v1.14.0

# Upgrade Kubernetes version
omnictl update cluster omni-cluster --kubernetes-version 1.37.0
```

### Import an Existing Talos Cluster

```bash
omnictl import talosconfig --cluster-name terra-talos ./talosconfig
```

---

## Known Issues & Pitfalls

### 1. Self-Signed TLS and Browser Trust

Both Omni (port 443) and Dex (port 5556) use the same self-signed CA certificate. Your browser will show TLS warnings for both. Install the CA certificate in your browser's trust store to eliminate all warnings (see [Step 7](#step-7-access-the-omni-ui) for instructions).

### 2. Dex Bcrypt Hash Cost

Dex requires bcrypt password hash cost >= 10. The `htpasswd` command defaults to cost 5. Either:
- Use `htpasswd -nbBC 10 admin <password>` (explicit cost 10)
- Or generate the hash with Python's `bcrypt` library

### 3. Omni Must Use `--network=host`

Omni needs `--network=host` to reach Dex on localhost:5556. Without this, the OIDC provider URL lookup fails.

### 4. `--initial-users` Must Be Set on First Start

If Omni initializes without `--initial-users`, the user won't be authorized. You must wipe the etcd data directory and restart fresh.

### 5. Missing `openid` Scope

Dex requires the `openid` scope. Omni must be started with `--auth-oidc-scopes=openid,profile,email` or Dex will reject the authorization request.

### 6. WireGuard Requires `--cap-add=NET_ADMIN` and `/dev/net/tun`

Without these, SideroLink (WireGuard) will fail to start. The container will still run but Talos machines won't be able to connect.

### 7. CSI `cloud-init-dir` on Talos

The same CSI patching issue applies — see the [known issues in talos.md](talos.md#csi-node-pod-fails-with-cloud-init-dir-mount-error). The pre-patched DaemonSet at `manifests/csi-node-daemonset-talos.yaml` handles this.

### 8. Backup

Back up the Omni VM regularly. VM snapshots are sufficient since Omni stores state in embedded etcd and SQLite on the local disk. See [Back Up Omni Database](https://docs.siderolabs.com/omni/self-hosted/back-up-omni-db/).

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
| Complexity | High | Medium | Medium (setup) / Low (daily ops) |

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
- [talos.md](talos.md) — manual Talos setup on CloudStack
- [talos-terraform.md](talos-terraform.md) — Terraform-based Talos setup on CloudStack
