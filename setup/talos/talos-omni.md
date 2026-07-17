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
| Scaling | Terraform + manual etcd | `omnictl apply` (YAML) |
| Monitoring | Manual | Omni UI |
| talosctl access | Direct to node IPs | Via Omni through SideroLink |

---

> **SideroLink explanation, architecture diagram, connection flow, transport modes, TLS requirements, and port reference are documented in [architecture/talos-omni.md](../architecture/talos-omni.md).**

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
- **Network:** Any network that provides outbound connectivity to the Omni VM. The Omni VM and Talos nodes do **not** need to be on the same network — they just need L3 reachability (routing between networks, or the Talos nodes must be able to reach the Omni VM's IP). In our lab, the Omni VM was on a shared network (`s1net`, 192.168.188.0/24) while the Talos cluster was on an isolated network (`terra-talos-net`, 10.22.2.0/24) — the nodes could reach Omni through the virtual router.
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

> **If using a public CA (e.g., Let's Encrypt):** The cert generation steps below can be skipped. See [Step 2](#step-2-generate-tls-certificates) for what changes.

> **Hostname vs IP:** The official Sidero guide uses `omni.internal` and `auth.internal` hostnames with `/etc/hosts` entries. This guide uses the private IP (`${OMNI_IP}`) directly — no DNS or hosts file needed. If you prefer hostnames, replace `${OMNI_IP}` with your FQDN throughout and ensure DNS (or `/etc/hosts` on every client) resolves it to the Omni VM's IP.

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

> **If using a public CA (e.g., Let's Encrypt):** Skip this step and the CA trust steps below. Instead, obtain a certificate for your Omni VM's FQDN (e.g., `omni.example.com`) via certbot or your preferred ACME client. You'll need a public IP and DNS record pointing to the Omni VM. The resulting `fullchain.pem` and `privkey.pem` replace the `server-chain.pem` and `server-key.pem` used in the Docker run command. You also won't need to install a CA in your browser or on Talos nodes — public CAs are trusted by default. The `grpc://` workaround for SideroLink is also unnecessary; use `https://` with the FQDN.

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
    --machine-api-advertised-url=grpc://${OMNI_IP}:8090/ \
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
> - `--machine-api-advertised-url=grpc://${OMNI_IP}:8090/` — uses `grpc://` to skip TLS for self-signed certs. **If using a public CA**, change this to `https://<fqdn>:8090/` and the Talos nodes will trust the connection automatically
> - `-v $(pwd)/ca.pem:/etc/ssl/certs/ca-certificates.crt:ro` — mounts the self-signed CA so the Omni container trusts Dex's certs. **If using a public CA**, this volume mount is not needed

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

> **If using a public CA:** No TLS warnings will appear. Access Omni at `https://<fqdn>:443` instead of the private IP.

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

## Part 4: Create a New Cluster from Scratch

This section covers creating a **new** Talos cluster via Omni (not importing an existing one). VMs are deployed on CloudStack with a SideroLinkConfig that tells them to connect to Omni on boot.

### Step 1: Create an Isolated Network (Optional)

If you want the cluster on its own network:

```bash
# Create a network
cmk create network \
  zoneid=<zone-id> \
  networkofferingid=<network-offering-id> \
  name=omni-cluster-net \
  displaytext=omni-cluster-net

# Note the network ID for later steps
```

### Step 2: Generate a Join Token

```bash
# Generate kernel args with join token (use --use-grpc-tunnel if UDP is restricted)
omnictl jointoken kernel-args --use-grpc-tunnel
```

This outputs kernel args like:
```
talos.electronjs.org/join-token=<token> siderolink.api=grpc://<omni-ip>:8090
```

### Step 3: Create SideroLink Userdata

Create a userdata YAML that tells Talos to connect to Omni on boot:

```bash
cat > omni-userdata.yaml <<EOF
version: v1alpha1
kind: SideroLinkConfig
apiUrl: grpc://<omni-ip>:8090/?jointoken=<token>
EOF
```

> **Note:** Use `grpc://` scheme to skip TLS verification (for self-signed certs). Use `https://` if you have a publicly trusted cert.

### Step 4: Deploy Talos VMs

On the CloudStack management server:

```bash
# Deploy control plane VM
cmk deploy virtualmachine \
  zoneid=<zone-id> \
  templateid=<talos-template-id> \
  serviceofferingid=<cp-offering-id> \
  networkids=<network-id> \
  name=omni-cluster-cp-1 \
  rootdisksize=20 \
  userdata=$(base64 -w0 omni-userdata.yaml) \
  details[0].guest.cpu.mode=host-passthrough

# Deploy worker VM
cmk deploy virtualmachine \
  zoneid=<zone-id> \
  templateid=<talos-template-id> \
  serviceofferingid=<worker-offering-id> \
  networkids=<network-id> \
  name=omni-cluster-worker-1 \
  rootdisksize=20 \
  userdata=$(base64 -w0 omni-userdata.yaml) \
  details[0].guest.cpu.mode=host-passthrough
```

### Step 5: Verify Machines Connect

Wait 60-90 seconds for the VMs to boot and connect:

```bash
omnictl get machines
```

Look for your new machines — they should show `connected=true` and be in maintenance mode.

### Step 6: Label the Machines

Labels tell Omni which machines are control planes vs workers. Set them from the **Omni UI**:

1. Go to the machine's detail page
2. Add a label: `type=control-plane` (for CP) or `type=worker` (for worker)

> **Note:** The `omnictl apply` command for `MachineLabels.omni.sidero.dev` may not persist labels correctly in v1.9.x. Use the UI for reliability.

### Step 7: Create Machine Classes

Machine classes group machines by label. Create them from the **Omni UI**:

1. Go to **Machine Classes**
2. Create `omni-cluster-cp` with label selector `type = control-plane`
3. Create `omni-cluster-worker` with label selector `type = worker`

### Step 8: Create the Cluster

```bash
cat > omni-cluster.yaml <<EOF
metadata:
    namespace: default
    type: Clusters.omni.sidero.dev
    id: omni-cluster
spec:
    kubernetesversion: 1.36.2
    talosversion: 1.13.6
    machineclasses:
        controlplane:
            - omni-cluster-cp
        workers:
            - omni-cluster-worker
    machineallocation:
        controlplanecount: 1
        workercount: 1
EOF

omnictl apply -f omni-cluster.yaml
```

> **Note:** The `talosversion` field must be without the `v` prefix (e.g., `1.13.6`, not `v1.13.6`).

### Step 9: Monitor Cluster Creation

```bash
omnictl cluster status omni-cluster
```

Omni will:
1. Select machines matching the machine classes
2. Generate and apply Talos configs
3. Bootstrap the cluster
4. Set up the Kubernetes API endpoint via SideroLink
5. Install Flannel (default CNI)

The cluster transitions through: `UNKNOWN` → `PROVISIONING` → `RUNNING Ready`.

---

## Part 5: Access the Cluster

### Step 1: Install kubelogin

The kubeconfig from Omni uses OIDC authentication via `kubelogin`. Install it on any machine that needs cluster access:

```bash
curl -sL 'https://github.com/int128/kubelogin/releases/latest/download/kubelogin_linux_amd64.zip' \
  -o /tmp/kubelogin.zip
unzip -o /tmp/kubelogin.zip -d /tmp/kubelogin
sudo cp /tmp/kubelogin/kubelogin /usr/local/bin/kubelogin
sudo ln -sf /usr/local/bin/kubelogin /usr/local/bin/kubectl-oidc-login
```

### Step 2: Download the Kubeconfig

```bash
omnictl kubeconfig --cluster omni-cluster \
  --force --merge=false /tmp/omni-cluster-kubeconfig
```

### Step 3: Fix the Server Address

The generated kubeconfig points to `localhost:8095` (the Omni workload proxy). Change it to the Omni server's IP:

```bash
sed 's/localhost:8095/<omni-ip>:8095/' /tmp/omni-cluster-kubeconfig \
  > /tmp/omni-cluster-kubeconfig-fixed
```

### Step 4: Access the Cluster

```bash
kubectl --kubeconfig /tmp/omni-cluster-kubeconfig-fixed get nodes
```

This will:
1. `kubelogin` detects no cached token
2. A browser window opens to the Dex OIDC login page at `https://<omni-ip>:5556`
3. Log in with your Omni credentials (e.g., `admin@omni.internal`)
4. Grant access on the consent page
5. The token is cached locally, and `kubectl` returns node information

Subsequent commands reuse the cached token until it expires.

### Headless Machines (No Browser)

On servers or machines without a browser, use the device-code flow:

```bash
kubectl --kubeconfig /tmp/omni-cluster-kubeconfig-fixed \
  get nodes --oidc-grant-type=authcode-keyboard
```

This prints a URL and code. Visit the URL on any device with a browser, enter the code, and authenticate. The token is then cached on the headless machine.

### Alternative: Service Account (Static Token, No OIDC)

For automation or CI/CD where interactive login is not possible, generate a kubeconfig with a long-lived static token:

```bash
omnictl kubeconfig --cluster omni-cluster \
  --service-account --user admin \
  --force --merge=false /tmp/omni-cluster-kubeconfig-sa

sed 's/localhost:8095/<omni-ip>:8095/' /tmp/omni-cluster-kubeconfig-sa \
  > /tmp/omni-cluster-kubeconfig-sa-fixed

kubectl --kubeconfig /tmp/omni-cluster-kubeconfig-sa-fixed get nodes
```

### How the Proxy Works

The kubeconfig's `server: https://<omni-ip>:8095` points to Omni's **workload proxy** — a built-in component on the Omni server that tunnels Kubernetes API traffic through SideroLink. This means:

- **No load balancer needed** — the Kubernetes API is accessed through the proxy, not directly
- **No port forwarding needed** — `talosctl` also works through Omni, not directly to nodes
- **Works from anywhere** — as long as you can reach the Omni server, you can access the cluster

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

Manual scaling is done through the **Omni UI**:

1. Go to **Clusters → `<cluster-name>` → Cluster Scaling**
2. Select the machine you want to add from the list of available machines
3. Choose the target MachineSet (e.g., `omni-test-workers`)
4. Confirm

> **Note:** Labels and Machine Classes are used for **automatic** scaling (machines auto-join when they match a Machine Class). For manual scaling, use the Cluster Scaling page in the UI. See [Labels Do Not Auto-Assign Machines to Clusters](#14-labels-do-not-auto-assign-machines-to-clusters) in Lessons Learned.

If you have a service account with write access, you can also scale via `omnictl` by creating a `ClusterMachine` resource:

```bash
cat > add-machine.yaml <<EOF
metadata:
    namespace: default
    type: ClusterMachines.omni.sidero.dev
    id: <machine-id>
    labels:
        omni.sidero.dev/cluster: omni-cluster
        omni.sidero.dev/machine-set: omni-cluster-workers
        omni.sidero.dev/role-worker: ""
spec:
    kubernetes_version: 1.36.2
EOF

omnictl apply -f add-machine.yaml
```

However, most service account keys are read-only (see [Service Account Keys Are Read-Only Despite Admin Role](#15-service-account-keys-are-read-only-despite-admin-role)), so the UI method is the reliable approach.

### Upgrades

```bash
cat > omni-cluster-upgrade.yaml <<EOF
metadata:
    namespace: default
    type: Clusters.omni.sidero.dev
    id: omni-cluster
spec:
    talosversion: 1.14.0
    kubernetesversion: 1.37.0
EOF

omnictl apply -f omni-cluster-upgrade.yaml
```

> **Note:** The `talosversion` field must be without the `v` prefix (e.g., `1.14.0`, not `v1.14.0`).

### Import an Existing Talos Cluster

```bash
omnictl cluster import <cluster-name> \
  --talosconfig ~/.talos/config \
  --talos-context <context> \
  --nodes <node-ip-1>,<node-ip-2>,<node-ip-3> \
  --skip-health-check
```

> **Prerequisite:** The machine running `omnictl cluster import` must be able to reach each node's **Talos API (port 50000)**. The import command uses `talosctl` under the hood to read cluster state (machine configs, secrets, node identities) from each node. If port 50000 is behind a firewall or port forwarding, ensure it's accessible from where you run the import. After import succeeds and SideroLink is established, port 50000 is no longer needed — Omni manages everything through the tunnel.

> **Note on cluster access:** After import, the cluster has **two working kubeconfigs**:
> 1. **Original kubeconfig** — still works through the CloudStack LB (e.g., `192.168.200.49:6443`). No changes needed for existing users or automation.
> 2. **Omni-proxied kubeconfig** — `omnictl kubeconfig --cluster <name>` gives a config pointing to the Omni workload proxy (`<omni-ip>:8095`). This works through SideroLink and requires kubelogin for OIDC auth.
>
> Both can coexist. The original kubeconfig is useful for users who already have it configured, while the Omni-proxied one provides access through the SideroLink tunnel without needing the LB or port forwarding rules.

---

## Part 8: Adding Users and LDAP/AD Integration

### Adding More Users

The easiest way is through the **Omni UI**:

1. Log in as admin
2. Go to **Settings → Users**
3. Click **Add User** and set their email/username/password

This automatically configures both Dex and Omni — no need to edit files or restart containers.

> **To change the admin password:** Generate a new bcrypt hash (see below), edit `~/omni-setup/dex.yaml` and replace the `hash` value under `admin@omni.internal`, then run `docker restart dex`. Dex uses `storage: type: memory` so the config file is the source of truth — no Omni changes needed.

Alternatively, you can add users manually via the Dex config and omnictl:

```bash
cd ~/omni-setup

# Generate a bcrypt hash for the new user's password
python3 -c "
import bcrypt
password = b'user2-password'  # change this
salt = bcrypt.gensalt(rounds=10)
hashed = bcrypt.hashpw(password, salt).decode()
hashed = hashed.replace('\$2b\$', '\$2a\$')
print(hashed)
"
```

Then edit `dex.yaml` and add the new user under `staticPasswords`:

```yaml
staticPasswords:
  - email: "admin@omni.internal"
    username: "admin"
    preferredUsername: "admin"
    hash: "$2a$10$..."
  - email: "user2@omni.internal"
    username: "user2"
    preferredUsername: "user2"
    hash: "$2a$10$..."  # paste the hash generated above
```

Restart Dex and add the user to Omni:

```bash
docker restart dex

# Add the user to Omni (run from the admin machine)
omnictl user create --email user2@omni.internal --name user2
```

### Integrating with Active Directory via LDAP

Dex supports LDAP as a connector, which means you can authenticate users against Active Directory (or any LDAP-compatible directory like FreeIPA, OpenLDAP). Users log in with their AD credentials, and Omni receives their identity via OIDC — no changes needed on the Omni side.

#### Dex LDAP Configuration for Active Directory

Replace the `staticPasswords` section in `dex.yaml` with an LDAP connector:

```yaml
# dex.yaml
issuer: https://192.168.188.204:5556

storage:
  type: memory

web:
  https: 0.0.0.0:5556
  tlsCert: /etc/dex/tls/server-chain.pem
  tlsKey: /etc/dex/tls/server-key.pem

enablePasswordDB: false  # disable local password auth

connectors:
  - type: ldap
    id: ad
    name: ActiveDirectory
    config:
      # AD server with LDAPS (port 636) — never use plain LDAP (389)
      host: ad.example.com:636

      # ⚠️ For testing only — remove in production
      insecureSkipVerify: true

      # Read-only service account for searching AD
      bindDN: cn=Administrator,cn=users,dc=example,dc=com
      bindPW: <ad-service-account-password>

      usernamePrompt: Email Address

      userSearch:
        baseDN: cn=Users,dc=example,dc=com
        filter: "(objectClass=person)"
        username: userPrincipalName
        idAttr: DN
        emailAttr: userPrincipalName
        nameAttr: cn

      groupSearch:
        baseDN: cn=Users,dc=example,dc=com
        filter: "(objectClass=group)"
        userMatchers:
          - userAttr: DN
            groupAttr: member
        nameAttr: cn

staticClients:
  - name: Omni
    id: omni
    secret: omni-dex-secret
    redirectURIs:
      - https://192.168.188.204:443/oidc/consume
```

> **Security note:** Dex binds with the end user's plaintext password to verify credentials. Always use LDAPS (port 636) — never port 389. Dex may remove insecure connection support in future releases.

#### Apply the LDAP Config

```bash
cd ~/omni-setup
# Edit dex.yaml with the LDAP config above
docker rm -f dex
docker run -d --name dex --restart=unless-stopped \
  -p 5556:5556 \
  -v $(pwd)/dex.yaml:/etc/dex/dex.yaml:ro,Z \
  -v $(pwd)/server-key.pem:/etc/dex/tls/server-key.pem:ro,Z \
  -v $(pwd)/server-chain.pem:/etc/dex/tls/server-chain.pem:ro,Z \
  ghcr.io/dexidp/dex:v2.41.1 \
    dex serve /etc/dex/dex.yaml
```

Users now authenticate with their AD email/password through Dex. Omni receives their identity via OIDC and authorizes them based on the `--initial-users` list or via `omnictl create user`.

#### LDAP Configuration for FreeIPA

```yaml
connectors:
  - type: ldap
    id: freeipa
    name: FreeIPA
    config:
      host: freeipa.example.com:636
      rootCA: /etc/dex/ca.crt  # FreeIPA server's CA
      userSearch:
        baseDN: cn=users,dc=freeipa,dc=example,dc=com
        filter: "(objectClass=posixAccount)"
        username: uid
        idAttr: uid
        emailAttr: mail
      groupSearch:
        baseDN: cn=groups,dc=freeipa,dc=example,dc=com
        filter: "(objectClass=group)"
        userMatchers:
          - userAttr: uid
            groupAttr: member
        nameAttr: name
```

#### Nested Groups (Recursive Group Lookup)

If your LDAP schema supports group nesting (groups containing other groups), enable recursive lookup with `recursionGroupAttr`:

```yaml
groupSearch:
  baseDN: cn=groups,dc=example,dc=com
  filter: "(objectClass=group)"
  userMatchers:
    - userAttr: DN
      groupAttr: member
      recursionGroupAttr: member  # follow nested group references
  nameAttr: cn
```

Dex includes built-in cycle detection to prevent infinite loops.

#### Reference

- [Dex LDAP Connector Documentation](https://dexidp.io/docs/connectors/ldap/) — full config reference with examples for AD, FreeIPA, and nested groups
- [Dex Connector Overview](https://dexidp.io/docs/connectors/) — other supported connectors (GitHub, SAML, OIDC, Google, etc.)

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
| Scaling | Manual VMs + LB + etcd | Terraform apply + etcd | `omnictl apply` (YAML) |
| Upgrades | `talosctl upgrade` per node | `talosctl upgrade` per node | Automatic rolling |
| CCM/CSI install | Manual | Manual | Manual (same) |
| Monitoring | Manual | Manual | Omni UI |
| Infrastructure to manage | CloudStack only | CloudStack + Terraform | CloudStack + Omni VM |
| Complexity | High | Medium | Medium (setup) / Low (daily ops) |

---

## Lessons Learned & Recommendations

This section documents real difficulties encountered during the self-hosted Omni deployment on CloudStack, along with practical recommendations.

### 1. Dex Bcrypt Hash Cost

Dex requires bcrypt password hash cost >= 10. The `htpasswd` command defaults to cost 5. Either:
- Use `htpasswd -nbBC 10 admin <password>` (explicit cost 10)
- Or generate the hash with Python's `bcrypt` library

### 2. Omni Must Use `--network=host`

Omni needs `--network=host` to reach Dex on localhost:5556. Without this, the OIDC provider URL lookup fails.

### 3. CA Certificate Must Be Mounted for HTTPS Dex

Omni v1.9+ is scratch-based with no `ca-certificates` package. It uses Go's system cert pool which is empty in scratch containers. When the OIDC provider (Dex) uses HTTPS with a self-signed CA, Omni can't verify:

```
Error: failed to run server: Get "https://192.168.188.204:5556/..."
  tls: failed to verify certificate: x509: certificate signed by unknown authority
```

**Fix:** Mount the CA certificate into the container as the system cert bundle:

```bash
-v $(pwd)/ca.pem:/etc/ssl/certs/ca-certificates.crt:ro
```

This is already included in the `docker run` command in [Step 5](#step-5-run-omni), but is easy to forget when modifying the command.

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

### 9. Network Topology: Important but Not the Blocker

#### The Problem

Talos nodes connect to Omni via **SideroLink**, which establishes a WireGuard tunnel. The connection is **initiated by the Talos node** — it reaches out to the Omni VM's SideroLink API endpoint and establishes the tunnel. This means:

- The Talos node must be able to **initiate a TCP connection** to the Omni VM's IP (port 8090 by default)
- The Talos node must be able to **send/receive UDP packets** to/from the Omni VM's IP (port 50180 for WireGuard)
- NAT, port forwarding, or proxy-based access **does not work** for the SideroLink connection

#### What We Encountered

In our lab, the Omni VM was on a shared network (`s1net`, 192.168.188.0/24) while the Talos cluster was on an isolated network (`terra-talos-net`, 10.22.2.0/24). However, the Talos nodes **could reach the Omni VM outbound** through the virtual router — a ping test from a pod on the cluster to 192.168.188.204 succeeded at 1.8ms. The routing existed through the management server.

The real blocker was **TLS certificate trust**, not network connectivity.

#### Solutions

| Approach | How | Works? |
|----------|-----|--------|
| **Same network** | Deploy Omni VM and Talos nodes on the same CloudStack network (shared or isolated) | ✅ Best |
| **Static route** | Add a route on the virtual router to bridge the two networks | ✅ Works if you control the router |
| **Public IP on Omni VM** | Give the Omni VM a public IP and configure port forwarding | ✅ Works but exposes Omni |
| **SaaS Omni** | Use Sidero's hosted Omni service | ✅ No network issues (uses relay) |
| **Port forwarding / NAT** | Try to reach Omni through NAT | ❌ Does not work |

#### Recommendation

**Deploy the Omni VM on the same CloudStack network as your Talos nodes.** If you use an isolated network for your cluster, put the Omni VM on that same isolated network. If you use a shared network, put everything on the shared network.

However, if the nodes can reach Omni outbound through existing routing (e.g., via a virtual router), the network is not the blocker — TLS is.

### 10. TLS Certificate Trust (The Real Blocker)

#### The Problem

Omni serves its API over HTTPS. The SideroLink connection from Talos nodes to Omni also uses HTTPS. If you use a **self-signed CA** (as this guide does), the Talos nodes will reject the connection with:

```
tls: failed to verify certificate: x509: certificate signed by unknown authority
```

This is a **hard blocker** — there is no `--insecure-skip-tls-verify` flag for the SideroLink connection. The Talos node **must** trust the Omni CA.

#### What We Tried (and Why It Didn't Work)

| Attempt | Result |
|---------|--------|
| `machine.acceptedCAs` in Talos config | ❌ This field is for the **node's own certificate identity**, not for trusting external server connections. The SideroLink controller uses the system trust store, which is baked into the Talos image. |
| Injecting CA via config patch | ❌ Same reason — the system trust store is immutable at runtime |
| `--siderolink-use-grpc-tunnel` alone | ❌ Doesn't bypass TLS verification, only tunnels WireGuard over TCP |

#### Solution 1: Public Trusted Certificate (Recommended)

**Use a publicly trusted certificate** (e.g., Let's Encrypt) for the Omni VM. Talos Linux trusts public CA roots by default, so this eliminates the TLS trust issue entirely.

To use Let's Encrypt:
1. Give the Omni VM a public IP (or use DNS-01 challenge with a private IP)
2. Set up a DNS A record pointing to the Omni VM's IP
3. Use `certbot` or `acme.sh` to obtain a certificate
4. Pass the Let's Encrypt cert and key to the Omni container instead of the self-signed cert

> See [Step 2](#step-2-generate-tls-certificates) for a summary of what changes when using a public CA vs self-signed certs throughout the guide.

If a public IP is not available, use the **DNS-01 challenge** with a DNS provider that supports it (e.g., Cloudflare, AWS Route53). This works with private IPs.

#### Solution 2: gRPC Scheme (Air-Gapped / Custom CA) ✅ Verified

For air-gapped environments where a public CA is not an option, you can use the **`grpc://` scheme** for the machine API URL. The SideroLink controller interprets `grpc://` as "skip TLS" and connects without encryption:

```bash
# Instead of:
--machine-api-advertised-url=https://192.168.188.204:8090/

# Use:
--machine-api-advertised-url=grpc://192.168.188.204:8090/
```

This tells the SideroLink controller to use `insecure.NewCredentials()` — no TLS verification at all. The WireGuard tunnel (SideroLink) still provides encryption for the data plane, so the control plane connection is the only unencrypted part.

**This was verified in our lab** — after switching to `grpc://`, all 3 Talos nodes connected to Omni successfully with no TLS errors:

```
NODE          NAMESPACE   TYPE               ID           VERSION   API ENDPOINT                                                                         TUNNEL
10.22.2.224   config      SiderolinkConfig   siderolink   1         grpc://192.168.188.204:8090/?jointoken=...   false
```

The machined logs showed successful provisioning with no TLS errors:
```
[talos] siderolink connection configured
[talos] opened client
[talos] reconfigured wireguard link
```

**Trade-off:** The machine API connection is unencrypted. In an air-gapped environment where the network is isolated, this is acceptable — the WireGuard tunnel handles data encryption.

**Note:** This only affects the SideroLink connection. The main Omni API (port 443) still uses HTTPS with your self-signed cert for `omnictl` and UI access.

### 11. Importing Existing Clusters

#### How It Works

When you import an existing Talos cluster into Omni, the cluster is initially **locked** as a safety measure:

```
cluster "terra-talos" is imported successfully but marked as 'locked' to prevent changes done by Omni
```

This prevents Omni from making any changes until you explicitly unlock it. Once you've verified the import was successful, unlock the cluster:

```bash
omnictl cluster unlock <cluster-name>
```

After unlocking, Omni takes over full lifecycle management — scaling, upgrades, and configuration changes all work through Omni.

#### What We Encountered

We successfully imported the cluster but hit two blockers:

1. **TLS cert issue** — The SideroLink connection failed because the Talos nodes didn't trust the self-signed CA. Solved by using `grpc://` scheme for the machine API URL (see [TLS Certificate Trust](#10-tls-certificate-trust-the-real-blocker)).

2. **Health check timeout** — During import, Omni tries to reach the Kubernetes API through the SideroLink tunnel to verify cluster health. If the Kubernetes API is exposed through a public IP (port forwarding) rather than through the tunnel, this health check will time out:

   ```
   > waiting for all k8s nodes to report: Get "https://[fdae:41e4:649b:9303::1]:10000/api/v1/nodes": context deadline exceeded
   ```

   **Solution:** Use `--skip-health-check` during import:

   ```bash
   omnictl cluster import terra-talos \
     --talosconfig ~/.talos/config \
     --talos-context terra-talos \
     --nodes 10.22.2.224,10.22.2.40,10.22.2.107 \
     --skip-health-check
   ```

   After import, Omni can still manage the cluster through the SideroLink tunnel — the health check is only needed during import to validate the cluster state.

   **Note:** Both the Omni VM and your admin machine have direct access to the port forwarding (public IP), so no socat tunnels or other workarounds are needed for the import step. The `--skip-health-check` flag is the only adjustment required.

3. **Talos API access (port 50000)** — The `omnictl cluster import` command connects to each node's Talos API to read machine configs, cluster secrets, and node identities. If port 50000 is not reachable from where you run the import (e.g., behind a firewall or NAT), the import will fail. Ensure port forwarding rules for the Talos API are in place before importing. After import succeeds and SideroLink is established, these rules can be removed.

#### Recommendation

The import → unlock workflow works as designed. The lock is a safety feature, not a limitation. The real blockers are:
- Getting the SideroLink connection working first (see [Network Topology](#9-network-topology-important-but-not-the-blocker) and [TLS Certificate Trust](#10-tls-certificate-trust-the-real-blocker))
- Using `--skip-health-check` if the Kubernetes API is not reachable through the SideroLink tunnel

### 12. Omni Flag Drift Between Versions

#### The Problem

Omni flags change between versions. We encountered several breaking changes:

| Flag (old) | Flag (new) | Version |
|------------|------------|---------|
| `--auth-oidc-issuer` | `--auth-oidc-provider-url` | v1.9.x |
| `--eula-accept` | `--eula-accept-email` + `--eula-accept-name` | v1.9.x |
| `--auth-oidc-insecure-skip-verify` | Removed (no replacement) | v1.9.x |
| `--skip-tls-verify` | Removed (no replacement) | v1.9.x |

When you restart the container with stale flags, Omni **exits silently** with no visible error. You only see the error in `docker logs omni`.

#### Recommendation

Always check the current flag names before restarting:
```bash
docker run --rm ghcr.io/siderolabs/omni:latest --help | grep <flag-name>
```

Pin your Omni version and test flag changes in a non-production environment first.

### 13. Userdata Injection Is Required (Kernel Args Alone Not Enough)

SideroLink requires the `SideroLinkConfig` userdata to be injected into the VM at deployment time. Passing kernel args via `extrakernelsargs` alone is **not sufficient** — Talos needs the full userdata YAML to configure the SideroLink connection.

**Correct approach:**
```bash
# Create the userdata YAML
cat > omni-userdata.yaml <<EOF
apiVersion: v1alpha1
kind: SideroLinkConfig
apiUrl: grpc://<omni-ip>:8090/?jointoken=<token>
EOF

# Base64-encode and pass to cmk deploy
cmk deploy virtualmachine \
  name=omni-cluster-worker-1 \
  templateid=<template-id> \
  serviceofferingid=<offering-id> \
  networkids=<network-id> \
  zoneid=<zone-id> \
  account=admin \
  domainid=<domain-id> \
  keypair=<keypair> \
  details[0].guest.cpu.mode=host-passthrough \
  userdata=$(base64 -w0 omni-userdata.yaml) \
  extrakernelsargs="siderolink.api=grpc://<omni-ip>:8090/?jointoken=<token>"
```

Both `userdata` and `extrakernelsargs` should be provided — the userdata carries the full config, while the kernel args provide a fallback for early boot stages.

### 14. Labels Do Not Auto-Assign Machines to Clusters

Setting a label (e.g., `type: worker`) on a machine in the Omni UI does **not** automatically add it to a cluster. Labels are used for Machine Class matching (automatic scaling), but for manual scaling you must explicitly add the machine to the cluster.

**The correct workflow for manual scaling:**
1. Deploy the VM with SideroLink userdata
2. Wait for it to connect to Omni (appears in Machines list)
3. Go to **Clusters → `<cluster-name>` → Cluster Scaling**
4. Select the machine and add it to the appropriate MachineSet

This is the documented manual scaling workflow per the [official Omni blog](https://www.siderolabs.com/blog/automatic-cluster-scaling-with-omni/). The Machine Class + label approach is for **automatic** scaling (e.g., when machines are dynamically provisioned by an auto-scaling group).

### 15. Service Account Keys Are Read-Only Despite Admin Role

A service account created via the Omni UI with the **Admin** role may still have **read-only scope** on the API. This means `omnictl apply` and `omnictl create` will fail with:

```
Error: rpc error: code = PermissionDenied desc = only read access is permitted
```

This is a limitation of how the service account key is generated — the key itself encodes the access scope, and the Admin role in the UI does not guarantee write access via the key.

**Workarounds:**
- Use the **Omni UI** for write operations (scaling, creating resources)
- Use **OIDC authentication** as `admin@omni.internal` for full write access
- If you need CLI write access, create the service account with explicit write scope (if the UI supports it in your version)

### 16. Summary: What We'd Do Differently

If we were to deploy self-hosted Omni on CloudStack again:

1. **Use `grpc://` scheme for the machine API** — avoids the self-signed CA trust issue entirely (or use Let's Encrypt if a public IP is available)
2. **Use `--skip-health-check` during import** — the Kubernetes API is typically exposed through a public IP, not through the SideroLink tunnel
3. **Create new clusters through Omni** — avoids the import complexity entirely
4. **Pin the Omni version** and test flag changes before restarting
5. **Consider SaaS Omni** if the operational complexity of self-hosted is not justified for your use case

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
