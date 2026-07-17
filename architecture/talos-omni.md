# Talos Omni Architecture

## What is SideroLink?

SideroLink is the **management overlay network** that connects Talos nodes to Omni. It's a WireGuard-based tunnel that replaces the need for direct network access to each node.

**Without Omni**, you need:
- Port forwarding (50000) to each node for `talosctl`
- A load balancer (6443) for the Kubernetes API
- Direct network access to every node's IP

**With Omni**, SideroLink handles all of this:
- `talosctl` talks to Omni, which proxies through the tunnel
- The Kubernetes API is exposed through Omni's workload proxy (no LB needed)
- Nodes register themselves — you don't need to know their IPs

## Architecture Diagram

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
│  All VMs need L3 reachability — routing between networks works fine  │
└──────────────────────────────────────────────────────────────────┘
```

## Key Points

- **SideroLink** — Omni establishes a WireGuard-encrypted tunnel to each registered machine. See [What is SideroLink?](#what-is-siderolink) for a detailed explanation of how the connection works.
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

## TLS Requirement

The initial gRPC connection uses HTTPS by default. If you use a self-signed CA, the Talos nodes will reject the connection. Use `grpc://` scheme in the machine API URL to skip TLS, or use a publicly trusted certificate (see [TLS Certificate Trust](#2-tls-certificate-trust-the-real-blocker) in the main guide).

## Ports

| Port | Protocol | Purpose |
|------|----------|---------|
| 443 | TCP | Omni UI and API (HTTPS, self-signed cert) |
| 8090 | TCP | SideroLink gRPC API |
| 8091 | TCP | Event sink |
| 8100 | TCP | Kubernetes proxy |
| 5556 | TCP | Dex OIDC (HTTPS, same self-signed cert) |
| 50180 | UDP | WireGuard (SideroLink) |
