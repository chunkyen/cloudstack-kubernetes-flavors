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
  ├─ CCM (CloudStack Kubernetes Provider) — required
  ├─ CSI driver (CloudStack CSI) — required
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

## CloudStack Integration

Talos has first-class support for Apache CloudStack as a deployment platform. The integration covers image provisioning, metadata retrieval, networking, and configuration injection — all without requiring SSH or cloud-init.

### Platform Module

Talos includes a built-in **CloudStack platform module** that activates when the kernel detects it is running on CloudStack (via DMI/hypervisor metadata). This module:

| Capability | How it works |
|------------|-------------|
| **Platform detection** | Reads DMI system product/manufacturer info to identify CloudStack as the hypervisor |
| **Metadata retrieval** | Queries the CloudStack virtual router (metadata server at `http://<gateway>/latest/`) for instance metadata |
| **Hostname** | Sets the node hostname from CloudStack VM name |
| **IP addressing** | Configures the primary NIC via DHCP (CloudStack virtual router provides DHCP) |
| **User-data** | Fetches base64-encoded user-data from the metadata server and applies it as the Talos machine configuration |
| **DNS** | Inherits DNS settings from the CloudStack network offering |

### Deployment Flow on CloudStack

```
┌─────────────────────────────────────────────────────────────────┐
│                    CloudStack Zone                                │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  Virtual Router (per isolated network)                    │   │
│  │  - DHCP server                                           │   │
│  │  - Metadata server (http://<gateway>/latest/)            │   │
│  │  - Port forwarding (SSH, etc.)                           │   │
│  └────────────────────┬────────────────────────────────────┘   │
│                       │                                          │
│  ┌────────────────────▼────────────────────────────────────┐   │
│  │  Talos VM (control plane / worker)                       │   │
│  │                                                          │   │
│  │  1. VM boots from Talos CloudStack image (.raw)          │   │
│  │  2. Kernel detects CloudStack platform                   │   │
│  │  3. machined starts, activates cloudstack platform       │   │
│  │  4. Fetches metadata + user-data from virtual router     │   │
│  │  5. Applies Talos machine config from user-data          │   │
│  │  6. Configures networking via DHCP                       │   │
│  │  7. Starts kubelet, joins cluster                        │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  Load Balancer Rule (port 6443)                         │   │
│  │  - Public IP → control plane node(s)                    │   │
│  │  - Kubernetes API endpoint                              │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

### Image Format

Talos provides a CloudStack-specific image format:

| Detail | Value |
|--------|-------|
| **Image format** | `cloudstack-amd64.raw` (or `.raw.gz` compressed) |
| **Source** | [Image Factory](https://factory.talos.dev) |
| **Minimum version** | Talos v1.8.0 |
| **Registration type** | RAW format in CloudStack |
| **Hypervisor** | KVM (primary), VMware, XenServer |

The image is a raw disk image containing the complete Talos OS — kernel, initramfs, and read-only root filesystem. No additional packages or updates are needed after deployment.

### User-Data Configuration

Unlike traditional Linux distributions that use cloud-init YAML, Talos uses its own machine configuration format passed as base64-encoded user-data:

```yaml
# This is Talos machine config, NOT cloud-init
# Passed as: userdata=$(base64 controlplane.yaml | tr -d '\n')
machine:
  type: controlplane
  install:
    disk: /dev/sda
    image: factory.talos.dev/installer/<version>
  network:
    interfaces:
      - interface: eth0
        dhcp: true
cluster:
  network:
    dnsDomain: cluster.local
    podSubnets:
      - 10.244.0.0/16
    serviceSubnets:
      - 10.96.0.0/12
```

The user-data is injected at VM creation time via the `cmk deploy virtualmachine` command's `userdata` parameter. Talos fetches it from the CloudStack metadata server on first boot.

### Networking on CloudStack

| Aspect | Detail |
|--------|--------|
| **Network types** | Isolated (default), Shared, VPC |
| **IP assignment** | DHCP from CloudStack virtual router |
| **DNS** | From network offering (can be overridden in machine config) |
| **API endpoint** | CloudStack load balancer rule (port 6443 → control plane) |
| **Node-to-node** | Internal network IPs (CloudStack isolated network) |
| **External access** | Via CloudStack port forwarding rules or load balancer |

### Load Balancer for API Endpoint

The Kubernetes API server is exposed through a CloudStack load balancer rule:

1. Allocate a public IP from the zone
2. Associate it with the cluster's network
3. Create a load balancer rule: public port 6443 → private port 6443 (round-robin)
4. Assign control plane VMs as load balancer members
5. The `talosctl gen config` command uses this public IP as the API server endpoint

For HA clusters, all control plane nodes are added to the same load balancer rule. Talos handles etcd cluster formation automatically — no manual etcd configuration is needed.

### Comparison: Talos on CloudStack vs Other Platforms

| Aspect | CloudStack | AWS | Bare Metal |
|--------|-----------|-----|------------|
| **Image format** | RAW disk image | AMI | ISO / PXE |
| **Metadata** | Virtual router metadata server | EC2 metadata API | No metadata (static config) |
| **User-data** | Base64-encoded in deploy API | cloud-init user-data | Kernel cmdline / config URL |
| **Networking** | DHCP from virtual router | DHCP + ENI | Static or DHCP |
| **API endpoint** | Load balancer rule | ELB/NLB | Keepalived VIP or external LB |
| **Storage** | CloudStack CSI driver | EBS CSI driver | Local or external CSI |
| **Platform module** | `cloudstack` | `aws` | `metal` (no platform) |

### CNI

Talos does **not** include a default CNI. You must install one after cluster bootstrap:

| CNI | Recommendation | Notes |
|-----|---------------|-------|
| **Calico** | Recommended for CloudStack | BGP or VXLAN overlay, network policies |
| **Cilium** | Advanced eBPF | Hubble observability, L7 policies |
| **Flannel** | Simple overlay | Minimal configuration, no network policies |
| **kube-router** | All-in-one | Service proxy + network policy + CNI |

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

| Aspect | CKS | CAPC | Rancher+CAPC | Talos Linux |
|--------|-----|------|-------------------|-------------|
| **Node OS** | Ubuntu, Rocky Linux, etc. (user-defined) | Ubuntu, Rocky Linux, etc. (pre-built image) | Ubuntu, Rocky Linux, etc. (pre-built image) | Talos Linux (immutable) |
| **Management** | CloudStack UI/API | `clusterctl` + `kubectl` (CAPI controllers) | Rancher UI + Fleet GitOps | `talosctl` / Terraform / Omni |
| **OS upgrades** | Package manager (apt/yum) on running VMs | Image-based — new CAPC template with updated OS baked into the K8s image | Image-based — new CAPC template with updated OS baked into the K8s image | Image-based atomic reboot (`talosctl upgrade`) |
| **K8s bootstrap** | kubeadm (managed by CKS plugin) | kubeadm (via CAPI KubeadmBootstrap provider) | kubeadm (via CAPI KubeadmBootstrap provider) | Talos-managed system containers |
| **Configuration** | cloud-init + CKS ISO | cloud-init + kubeadm config (via CAPI) | cloud-init + kubeadm config (via CAPI) | Talos machine config (YAML) |
| **Control plane** | kubeadm static pods | kubeadm static pods (managed by KubeadmControlPlane) | kubeadm static pods (managed by KubeadmControlPlane) | Talos-managed system containers |
| **Security posture** | Traditional Linux hardening | Traditional Linux hardening | Traditional Linux hardening | Immutable, no shell, no SSH |
| **Kubernetes version** | Tied to CKS ISO upload | Tied to image-builder template | Tied to image-builder template | Tied to Talos release |
| **CNI** | Baked into CKS ISO (Calico) | Manual or ClusterResourceSet | Manual or ClusterResourceSet | Manual install (no default) |
| **CCM/CSI** | Auto-deployed (CKS 4.16+) | Manual install (required on CloudStack) | Manual install or ClusterResourceSet (required on CloudStack) | Manual install (required on CloudStack) |
| **ClusterClass (CAPI)** | N/A | Not supported (no CloudStackClusterTemplate) | Not supported (no CloudStackClusterTemplate) | Supported (CAPI with Talos provider) |
| **GitOps** | No | Yes (CAPI native YAML) | Yes (Rancher Fleet) | Yes (talosctl + Git) |
| **Multi-cluster** | Limited (per-account) | Yes (CAPI native) | Yes (CAPI + Rancher Turtles) | Manual / CAPI with Talos provider |

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
