# Talos Linux Architecture

## Overview

[Talos Linux](https://www.talos.dev/) is a minimal, immutable, and security-hardened Linux distribution designed specifically for running Kubernetes. Unlike general-purpose Linux distributions (Ubuntu, Rocky Linux, etc.) that require manual package management, SSH access, and ongoing OS maintenance, Talos is purpose-built to be managed through a gRPC API — there is no shell, no SSH daemon, no package manager, and no writable root filesystem at runtime.

This architecture makes Talos fundamentally different from the other flavors in this repository (CKS, CAPC, Rancher+CAPC), which all use traditional Linux distributions with kubeadm-based Kubernetes bootstrapping.

## Core Design Principles

| Principle | Description |
|-----------|-------------|
| **Immutable** | The entire OS is a single, versioned, signed disk image. No package installation, no runtime modifications. |
| **API-driven** | All management happens through the Talos gRPC API (`talosctl`). No SSH, no shell access. |
| **Minimal** | Only the components needed to run Kubernetes are included. No init system, no cron, no package manager. |
| **Secure by default** | Hardened kernel parameters, read-only root filesystem, automatic TLS for all internal communication. |
| **Self-hosted control plane** | Talos runs its own control plane components (etcd, kube-apiserver, kube-controller-manager, kube-scheduler) as managed processes, not static pods. |

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                    Talos Linux Node                          │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                   Kernel (Linux)                       │  │
│  │  - Hardened config                                    │  │
│  │  - Minimal modules                                    │  │
│  └──────────────────────┬───────────────────────────────┘  │
│                         │                                    │
│  ┌──────────────────────▼───────────────────────────────┐  │
│  │                   machined                             │  │
│  │  (Talos daemon — manages all node-level operations)   │  │
│  │                                                       │  │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────────────┐   │  │
│  │  │ apid     │  │ trustd   │  │ kubelet          │   │  │
│  │  │ (gRPC    │  │ (cluster │  │ (Kubernetes      │   │  │
│  │  │  API)    │  │  trust)  │  │  node agent)     │   │  │
│  │  └──────────┘  └──────────┘  └────────┬─────────┘   │  │
│  │                                       │               │  │
│  │  ┌────────────────────────────────────▼──────────┐   │  │
│  │  │           containerd (CRI)                     │   │  │
│  │  │  - System containers (etcd, apiserver, etc.)   │   │  │
│  │  │  - Kubernetes pods                             │   │  │
│  │  └───────────────────────────────────────────────┘   │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Read-Only Root Filesystem                 │  │
│  │  /boot  /usr  /etc  (immutable at runtime)            │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Writable Partitions                      │  │
│  │  /var  — container images, pod data, logs            │  │
│  │  /etc/cni  — CNI configuration                       │  │
│  │  /system  — Talos internal state                     │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Core Components

| Component | Role |
|-----------|------|
| **machined** | The main Talos daemon — manages the node lifecycle, configuration, and all sub-components. Replaces init/systemd. |
| **apid** | gRPC API server — exposes the Talos API for `talosctl` communication. All management goes through this. |
| **trustd** | Cluster trust daemon — handles node identity, certificate signing, and cluster membership. |
| **kubelet** | Standard Kubernetes kubelet, managed by machined. |
| **containerd** | Container runtime interface (CRI) — runs all containers including Talos system services and Kubernetes pods. |
| **udevd** | Device management — handles hardware events and device nodes. |

## How Talos Runs Kubernetes

Unlike kubeadm-based clusters where control plane components run as static pods, Talos manages them as **system containers**:

```
Talos manages:
  ┌─ etcd (distributed key-value store)
  ├─ kube-apiserver (Kubernetes API server)
  ├─ kube-controller-manager (controllers)
  ├─ kube-scheduler (pod scheduling)
  └─ kube-proxy (network proxy)

User deploys:
  ┌─ CNI plugin (Calico, Cilium, Flannel)
  ├─ CCM (CloudStack Kubernetes Provider)
  ├─ CSI driver (CloudStack CSI)
  └─ Workloads (Deployments, StatefulSets, etc.)
```

### Control Plane Management

- **etcd** — Talos bootstraps etcd on the first control plane node. Additional control plane nodes join the etcd cluster automatically.
- **API Server** — Talos generates and manages TLS certificates for kube-apiserver. The API server endpoint is configured in the Talos machine config.
- **Upgrades** — `talosctl upgrade` performs a rolling upgrade of Talos OS and Kubernetes simultaneously. The node reboots into the new Talos image, and the kubelet reconnects to the cluster.

## Machine Configuration

Talos uses a YAML-based machine configuration instead of cloud-init or kubeadm config files:

```yaml
# controlplane.yaml — applied to control plane nodes
version: v1alpha1
machine:
  type: controlplane
  install:
    disk: /dev/sda
    image: factory.talos.dev/installer/...
  network:
    interfaces:
      - interface: eth0
        dhcp: true
  kubelet:
    extraArgs:
      node-labels: "topology.kubernetes.io/zone=cyz1"
cluster:
  network:
    cni:
      name: none  # CNI installed separately
  apiServer:
    extraArgs:
      service-node-port-range: 30000-32767
```

Key differences from kubeadm-based configs:
- **No SSH keys** — management is API-only via `talosctl`
- **No package lists** — the OS image is fixed and immutable
- **No cloud-init** — configuration is applied via `talosctl apply-config`
- **Single config per node type** — one `controlplane.yaml` and one `worker.yaml`

## Networking Model

### CloudStack Platform Support

Talos includes a built-in **CloudStack platform module** that:
- Detects it's running on CloudStack via DMI/hypervisor metadata
- Retrieves instance metadata (hostname, IP, network) from CloudStack's virtual router
- Configures networking automatically (DHCP by default)
- Supports user-data for machine configuration injection

### Kubernetes API Endpoint

The Kubernetes API server endpoint is exposed via a CloudStack **load balancer rule**:
- Public IP allocated from the CloudStack zone
- Load balancer rule forwards port 6443 → control plane node port 6443
- For HA clusters, multiple control plane nodes are added as load balancer members

### CNI

Talos does **not** include a default CNI. You must install one after cluster bootstrap:
- **Calico** — recommended for on-prem/CloudStack environments
- **Cilium** — advanced eBPF-based networking
- **Flannel** — simple overlay networking
- **kube-router** — integrated service proxy and network policy

## Security Model

| Feature | Detail |
|---------|--------|
| **No SSH** | No SSH daemon runs. All management via `talosctl` with mTLS. |
| **Read-only root** | Root filesystem is mounted read-only at runtime. |
| **Hardened kernel** | Kernel built with security-focused config (no unnecessary modules). |
| **Automatic TLS** | All internal communication (apid, trustd, kubelet) uses auto-generated TLS certs. |
| **Disk encryption** | Optional LUKS2 encryption for the ephemeral partition. |
| **Minimal attack surface** | No package manager, no compilers, no interpreters (no Python, Perl, etc.). |

## Upgrade Model

Talos upgrades are **image-based** and **atomic**:

1. `talosctl upgrade --image=factory.talos.dev/installer/<version>`
2. Talos pulls the new installer image
3. Writes the new OS image to the install disk
4. Reboots the node
5. Node comes up with the new Talos version
6. kubelet reconnects to the cluster
7. Kubernetes control plane components are updated automatically

This is fundamentally different from package-based upgrades (apt/yum upgrade) used by other flavors.

## Key Differences from Other Flavors

| Aspect | CKS / CAPC / Rancher+CAPC | Talos Linux |
|--------|--------------------------|-------------|
| **Node OS** | Ubuntu, Rocky Linux, etc. | Talos Linux (immutable) |
| **Management** | SSH + kubectl | `talosctl` (gRPC API) |
| **OS upgrades** | Package manager (apt/yum) | Image-based (atomic reboot) |
| **Configuration** | cloud-init + kubeadm | Talos machine config (YAML) |
| **Control plane** | Static pods (kubeadm) | System containers (Talos-managed) |
| **Security posture** | Traditional Linux hardening | Immutable, no shell, no SSH |
| **Kubernetes version** | Tied to image-builder | Tied to Talos release |
| **CNI** | Manual install | Manual install (no default) |
| **CCM/CSI** | Manual install | Manual install |
| **ClusterClass (CAPI)** | Not supported (CAPC) | Supported (CAPI with Talos provider) |

## When to Use Talos

### Good fit for Talos

- **Security-conscious environments** — immutable OS, no SSH, minimal attack surface
- **Standardized deployments** — all nodes run identical OS images
- **Automated lifecycle** — API-driven management fits GitOps workflows
- **Edge/IoT** — minimal footprint, automatic updates
- **Greenfield clusters** — no existing Linux management tooling to integrate with

### Less ideal for Talos

- **Existing Linux tooling** — if you rely on SSH-based management, custom agents, or OS-level packages
- **Legacy workloads** — applications that require direct host access or kernel modules
- **Hybrid OS environments** — if you need different OS configurations per node
- **Air-gapped without planning** — Talos images must be pre-staged; no apt/yum mirrors

## References

- [Talos Linux Documentation](https://www.talos.dev/)
- [Talos Architecture](https://docs.siderolabs.com/talos/v1.13/learn-more/architecture)
- [Talos Components](https://docs.siderolabs.com/talos/v1.13/learn-more/components)
- [Talos CloudStack Platform Guide](https://docs.siderolabs.com/talos/v1.13/platform-specific-installations/cloud-platforms/cloudstack)
- [Image Factory](https://factory.talos.dev)
- [Talos GitHub](https://github.com/siderolabs/talos)
