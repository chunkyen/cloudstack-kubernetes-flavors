# CloudStack Kubernetes Provider (Cloud Controller Manager)

## Overview

The **CloudStack Kubernetes Provider** is an external Cloud Controller Manager (CCM) that facilitates Kubernetes deployments on CloudStack infrastructure. It replaced the deprecated in-tree CloudStack provider that was removed from Kubernetes at version 1.16.

**Repository:** [apache/cloudstack-kubernetes-provider](https://github.com/apache/cloudstack-kubernetes-provider)
**Container:** [hub.docker.com/r/apache/cloudstack-kubernetes-provider](https://hub.docker.com/r/apache/cloudstack-kubernetes-provider)
**Requires:** Go 1.23+ to build

## Background

- The old in-tree CloudStack provider lived at `kubernetes/kubernetes/pkg/cloudprovider/providers/cloudstack` (removed in Kubernetes 1.16)
- [kubernetes/enhancements#672](https://github.com/kubernetes/enhancements/issues/672) and [#88](https://github.com/kubernetes/enhancements/issues/88) drove the move to an external CCM
- The external CCM can run independently of the Kubernetes version, unlike the in-tree provider which was tied to K8s release cycles

## What It Does

The CloudStack K8s Provider serves as the bridge between Kubernetes and CloudStack, managing:

1. **Cloud provider integration** — Labels and taints nodes with CloudStack metadata (instance type, zone, region, hostname)
2. **Load Balancer provisioning** — Creates and manages CloudStack load balancer rules for `LoadBalancer` type Services
3. **Firewall rule management** — Manages source CIDR firewall rules on CloudStack
4. **Node metadata** — Applies topology labels automatically to uninitialized nodes

## Service Annotations

| Annotation | Purpose |
|------------|---------|
| `service.beta.kubernetes.io/cloudstack-load-balancer-proxy-protocol: "true"` | Enables HAProxy Proxy Protocol on CloudStack LB. Preserves original client IP. Requires CloudStack 4.6+. |
| `service.beta.kubernetes.io/cloudstack-load-balancer-hostname: "lb.example.com"` | Sets a hostname for the LoadBalancer ingress instead of an IP. Workaround for [kubernetes#66607](https://github.com/kubernetes/kubernetes/issues/66607). |
| `service.beta.kubernetes.io/cloudstack-load-balancer-source-cidrs: "10.0.0.0/8"` | Restricts which IP ranges can access the LB. Default `0.0.0.0/0`. CloudStack 4.22+ for updating on existing rules. |

## Node Labels

The CCM automatically applies CloudStack metadata labels to nodes.

### Kubernetes ≥ 1.17 (current)
| Label | Value |
|-------|-------|
| `kubernetes.io/hostname` | Instance name |
| `node.kubernetes.io/instance-type` | Compute offering |
| `topology.kubernetes.io/zone` | CloudStack zone |
| `topology.kubernetes.io/region` | Region (or zone if not defined) |

### Kubernetes ≤ 1.16 (legacy)
| Label | Value |
|-------|-------|
| `kubernetes.io/hostname` | Instance name |
| `beta.kubernetes.io/instance-type` | Compute offering |
| `failure-domain.beta.kubernetes.io/zone` | CloudStack zone |
| `failure-domain.beta.kubernetes.io/region` | Region (or zone if not defined) |

### Node Initialization

Recommended kubelet parameter:
```bash
--register-with-taints=node.cloudprovider.kubernetes.io/uninitialized=true:NoSchedule
```
This marks nodes as uninitialized and triggers the CCM to apply labels.

> ⚠️ The node name must match the hostname for the controller to fetch and assign metadata from CloudStack.

## Key Differences from In-Tree Provider

| Aspect | In-Tree (removed) | External CCM |
|--------|-------------------|-------------|
| **Lifecycle** | Tied to K8s release cycle | Independent releases |
| **Deployment** | Bundled with kubelet | Runs as a separate pod |
| **Metadata source** | VM's DHCP server (VR) | CloudStack API |
| **LB rule naming** | Simple naming | Includes protocol (TCP/UDP/proxy) |
| **Migration** | — | Remove old rules before migrating to avoid duplicates |

## Applicability Across Flavors

This provider is relevant to **all four Kubernetes flavors** on CloudStack:

| Flavor | How it applies |
|--------|---------------|
| **CKS** | Auto-deployed when CKS cluster is created (4.16+) |
| **CAPC** | Required for LoadBalancer services and node metadata on CAPC-managed clusters |
| **Talos** | Must be manually deployed; Talos doesn't include an in-tree CCM |
| **Rancher+CAPC** | Deployed by Rancher or manually for LoadBalancer support |

## Setup

For deployment instructions, see [setup/cloudstack-kubernetes-provider.md](../../setup/cloudstack-kubernetes-provider.md).

## References

- [GitHub Repository](https://github.com/apache/cloudstack-kubernetes-provider)
- [Docker Hub](https://hub.docker.com/r/apache/cloudstack-kubernetes-provider)
- [kubernetes/enhancements#672](https://github.com/kubernetes/enhancements/issues/672)
- [kubernetes/enhancements#88](https://github.com/kubernetes/enhancements/issues/88)
- [HAProxy Proxy Protocol](https://www.haproxy.org/download/1.8/doc/proxy-protocol.txt)
