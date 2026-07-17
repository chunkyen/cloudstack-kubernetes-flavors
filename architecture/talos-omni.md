# Talos Omni Architecture

## Overview

[Sidero Omni](https://www.siderolabs.com/platform/sidero-omni/) is a Kubernetes management platform by Sidero Labs that automates the creation, scaling, and lifecycle management of Talos Linux clusters. It provides a central control plane for managing multiple Talos clusters through a web UI, CLI (`omnictl`), and API.

Key capabilities:
- **Cluster lifecycle** — create, scale, upgrade, and delete clusters
- **Machine management** — register, label, and organize nodes into machine classes
- **OIDC authentication** — users authenticate via Dex (built-in OIDC provider)
- **SideroLink** — secure overlay network for management traffic (see below)
- **Workload proxy** — exposes Kubernetes API through the Omni server (no load balancer needed)

### SaaS vs Self-Hosted

| Factor | SaaS Omni | Self-Hosted Omni |
|--------|-----------|-----------------|
| **Network requirements** | None (uses relay/proxy) | Outbound connectivity from nodes to Omni |
| **TLS** | Handled by Sidero | You must manage certificates (use `grpc://` or Let's Encrypt) |
| **Setup time** | Minutes | Hours |
| **Maintenance** | None | You manage updates, backups |

For CloudStack environments, **SaaS Omni is simpler** but self-hosted is viable with the `grpc://` scheme for TLS.

## SideroLink

SideroLink is the **management overlay network** that connects Talos nodes to Omni. It's a WireGuard-based tunnel that replaces the need for direct network access to each node.

**Without Omni**, you need:
- Port forwarding (50000) to each node for `talosctl`
- A load balancer (6443) for the Kubernetes API
- Direct network access to every node's IP

**With Omni**, SideroLink handles all of this:
- `talosctl` talks to Omni, which proxies through the tunnel
- The Kubernetes API is exposed through Omni's workload proxy (no LB needed)
- Nodes register themselves — you don't need to know their IPs

## Dex (OIDC Provider)

Dex is the built-in OIDC identity provider that ships alongside Omni. It handles user authentication for both the Omni web UI and `kubectl` access to managed clusters.

**Authentication flow:**

```
User Browser              Omni (port 443)           Dex (port 5556)
     │                         │                         │
     │  1. Access Omni UI      │                         │
     │  ─────────────────────►│                         │
     │                         │  2. Redirect to Dex     │
     │  ◄─────────────────────│                         │
     │                         │                         │
     │  3. Login page          │                         │
     │  ───────────────────────────────────────────────►│
     │  4. Credentials         │                         │
     │  ───────────────────────────────────────────────►│
     │                         │                         │
     │  5. Auth code           │                         │
     │  ◄───────────────────────────────────────────────│
     │                         │  6. Consume auth code   │
     │  ─────────────────────►│                         │
     │  7. Session cookie      │                         │
     │  ◄─────────────────────│                         │
```

**Key details:**
- Dex runs as a separate Docker container on the Omni VM, serving HTTPS on port 5556
- Both Omni and Dex use the same self-signed CA certificate
- Dex supports multiple authentication backends: local password database, LDAP/Active Directory, GitHub, SAML, and other OIDC providers
- For `kubectl` access, the OIDC flow goes through `kubelogin` which opens a browser to Dex, then caches the token locally
- The Omni server validates tokens by calling Dex's OIDC discovery endpoint

## Architecture Diagram

```
┌──────────────────────────────────────────────────────────────────┐
│                     CloudStack Network                             │
│                                                                  │
│  ┌──────────────────────┐    ┌──────────────────────────────┐   │
│  │  Omni VM              │    │  Talos Cluster Nodes          │   │
│  │  192.168.188.204      │    │                               │   │
│  │                       │    │  ┌──────────────────────┐    │   │
│  │  ┌─────────────────┐  │    │  │ CP-1  CP-2  CP-3     │    │   │
│  │  │ Omni container   │  │    │  │ (Talos Linux)        │    │   │
│  │  │ port 443 (HTTPS)  │  │    │  └──────────────────────┘    │   │
│  │  │ port 8090 (gRPC)  │◄─┼────┼──┤ SideroLink           │    │   │
│  │  │ port 50180/UDP   │◄─┼────┼──┤ (WireGuard tunnel)   │    │   │
│  │  │ (WireGuard)       │  │    │  └──────────────────────┘    │   │
│  │  ├─────────────────┤  │    │  ┌──────────────────────┐    │   │
│  │  │ Dex (OIDC)       │  │    │  │ Worker-1  Worker-2   │    │   │
│  │  │ port 5556 (HTTPS)│  │    │  │ (Talos Linux)        │    │   │
│  │  └─────────────────┘  │    │  └──────────────────────┘    │   │
│  │         │              │    │         │                   │   │
│  │         └──────────────┼────┼───────────┘                 │   │
│  └──────────────────────┘    └──────────────────────────────┘   │
│                                                                  │
│  ⚠️ Nodes need L3 reachability to Omni — routing between networks works │
│  ⚠️ NAT / port forwarding does NOT work for SideroLink           │
└──────────────────────────────────────────────────────────────────┘
```

## Key Points

- **SideroLink** — Omni establishes a WireGuard-encrypted tunnel to each registered machine.
- **No LB for cluster** — Omni provides the Kubernetes API endpoint through the SideroLink tunnel. You don't need a CloudStack load balancer rule for port 6443.
- **No port forwarding for talosctl** — `talosctl` communicates through Omni, not directly to nodes.
- **Private IP only** — on a shared CloudStack network, all VMs (Omni + Talos nodes) can be on the same L2 segment, but they don't have to be. The Talos nodes just need L3 reachability to the Omni VM (routing between networks works fine). No public IP or port forwarding is required for Omni to function. The Omni UI is accessed directly at the private IP.
- **IP vs hostname** — the official Sidero guide uses hostnames like `omni.internal` and `auth.internal` with entries in `/etc/hosts`. This guide uses the private IP directly instead, which works without any DNS or hosts file configuration. If you prefer hostnames, you can substitute the IP with your chosen FQDN throughout — just ensure DNS (or `/etc/hosts` on every client) resolves it to the Omni VM's IP.
- **Full HTTPS** — both Omni (port 443) and Dex (port 5556) serve HTTPS using the same self-signed CA. Install the CA certificate in your browser's trust store to avoid TLS warnings.

## SideroLink Connection Flow

```
Talos Node                    Omni VM
    │                            │
    │  1. gRPC connect (8090)    │
    │  ─────────────────────────►│
    │  (sends WireGuard pub key  │
    │   + join token)            │
    │                            │
    │  2. Omni responds          │
    │  ◄─────────────────────────│
    │  (sends its WireGuard key  │
    │   + overlay IPv6 addrs)    │
    │                            │
    │  3. WireGuard tunnel up    │
    │  ◄═══════ encrypted ═════►│
    │  (all management traffic   │
    │   flows through tunnel)    │
    │                            │
```

## Transport Modes

| Mode | How | When to Use |
|------|-----|-------------|
| **Direct WireGuard (UDP)** | WireGuard over UDP (port 50180) | Nodes can send/receive UDP directly to Omni |
| **gRPC tunnel** | WireGuard tunneled over the same gRPC connection (port 8090) | UDP is restricted or nodes are behind NAT |

Enable gRPC tunnel mode with `--siderolink-use-grpc-tunnel` on Omni. This adds overhead but works through NAT.

## Critical Network Requirement

**Self-hosted Omni requires the Talos nodes to be able to initiate outbound connections to the Omni VM.** The connection is **initiated by the Talos node** — it reaches out to the Omni VM's SideroLink API endpoint and establishes the tunnel. This means:

- The Talos node must be able to **initiate a TCP connection** to the Omni VM's IP (port 8090)
- The Talos node must be able to **send/receive UDP packets** to/from the Omni VM's IP (port 50180)
- NAT, port forwarding, or proxy-based access **does not work** for the SideroLink connection

**On CloudStack, the Omni VM and Talos nodes should ideally be on the same network.** However, if the nodes can reach Omni outbound through existing routing (e.g., via a virtual router that bridges networks), the network is not the blocker — TLS certificate trust is.

## TLS Requirement

The SideroLink connection from Talos nodes to Omni uses HTTPS. If you use a **self-signed CA**, the Talos nodes will reject the connection because they don't trust the CA. There is no `--insecure-skip-tls-verify` equivalent for SideroLink, and the system trust store in Talos is immutable at runtime — `machine.acceptedCAs` only affects the node's own certificate identity, not outbound TLS connections.

**Two solutions:**

1. **Public trusted certificate** (recommended) — Use Let's Encrypt. Talos trusts public CAs by default.
2. **gRPC scheme** (air-gapped) — Use `grpc://` instead of `https://` in the machine API URL. The SideroLink controller interprets `grpc://` as "skip TLS" and connects without encryption. The WireGuard tunnel still encrypts the data plane. **This was verified working in our lab.**

## Import vs Create

When you import an existing Talos cluster into Omni, the cluster is initially **locked** as a safety measure. Once you verify the import, unlock it with `omnictl cluster unlock <cluster-name>` — after that, Omni takes over full lifecycle management (scaling, upgrades, config changes). The lock is not a permanent limitation; it's a safety step before handing over control.

**Note:** During import, Omni performs a health check that tries to reach the Kubernetes API through the SideroLink tunnel. If the Kubernetes API is exposed through a public IP (port forwarding), use `--skip-health-check` to avoid a timeout.

## Further Reading

- [Omni Documentation](https://docs.siderolabs.com/omni/latest/) — official docs
- [Run Omni On-Prem](https://docs.siderolabs.com/omni/self-hosted/run-omni-on-prem/) — deployment guide
- [Omni On-Prem Hardware Requirements](https://docs.siderolabs.com/omni/self-hosted/omni-on-prem-hardware-requirements/)
- [SideroLink Overview](https://www.siderolabs.com/platform/sidero-omni/)
- [Machine Registration](https://docs.siderolabs.com/omni/latest/infrastructure-and-extensions/machine-registration/)
- [Create a Cluster](https://docs.siderolabs.com/omni/latest/getting-started/create-a-cluster/)
- [Import Talos Clusters](https://docs.siderolabs.com/omni/cluster-management/importing-talos-clusters/)
- [Omni Firewall and Egress Requirements](https://docs.siderolabs.com/omni/omni-cluster-setup/omni-firewall-egress-requirement/)
- [Expose Omni with Nginx (HTTPS)](https://docs.siderolabs.com/omni/self-hosted/expose-omni-with-nginx-https/)
