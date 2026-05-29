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

## Deployment

### Automatic (CKS Clusters)
When a Kubernetes cluster is created on CloudStack 4.16+, the provider is **automatically deployed**.

### Manual Deployment

#### 1. Create cloud-config

```ini
[Global]
api-url = <CloudStack API URL>
api-key = <CloudStack API Key>
secret-key = <CloudStack API Secret>
project-id = <CloudStack Project UUID (optional)>
zone = <CloudStack Zone Name (optional)>
ssl-no-verify = <true or false (optional)>
```

> The access token needs permission to fetch VM information and deploy load balancers in the project/domain where the nodes reside.

#### 2. Create Kubernetes Secret

```bash
kubectl -n kube-system create secret generic cloudstack-secret --from-file=cloud-config
```

#### 3. Deploy the Controller

```bash
kubectl apply -f https://raw.githubusercontent.com/apache/cloudstack-kubernetes-provider/main/deployment.yaml
```

#### 4. (Optional) Deploy Ingress Controller with Proxy Protocol

For Traefik:
```bash
kubectl apply -f traefik-ingress-controller.yml
```

For Nginx:
```bash
kubectl apply -f nginx-ingress-controller-patch.yml
```

## Service Annotations

### Load Balancer Proxy Protocol
```yaml
service.beta.kubernetes.io/cloudstack-load-balancer-proxy-protocol: "true"
```
Enables HAProxy Proxy Protocol on the CloudStack load balancer. Preserves original client IP. Requires CloudStack 4.6+.

### Load Balancer Hostname
```yaml
service.beta.kubernetes.io/cloudstack-load-balancer-hostname: "lb.example.com"
```
Sets a hostname for the LoadBalancer ingress instead of an IP address. Workaround for [kubernetes#66607](https://github.com/kubernetes/kubernetes/issues/66607).

### Load Balancer Source CIDRs
```yaml
service.beta.kubernetes.io/cloudstack-load-balancer-source-cidrs: "10.0.0.0/8,192.168.1.0/24"
```
Restricts which IP ranges can access the load balancer. Default is `0.0.0.0/0`. Empty string blocks all traffic. CloudStack 4.22+ required for updating CIDR lists on existing rules.

## Node Labels

The CCM automatically applies CloudStack metadata labels to nodes.

### Kubernetes ≤ 1.16 (legacy)
| Label | Value |
|-------|-------|
| `kubernetes.io/hostname` | Instance name |
| `beta.kubernetes.io/instance-type` | Compute offering |
| `failure-domain.beta.kubernetes.io/zone` | CloudStack zone |
| `failure-domain.beta.kubernetes.io/region` | Region (or zone if not defined) |

### Kubernetes ≥ 1.17 (current)
| Label | Value |
|-------|---------|
| `kubernetes.io/hostname` | Instance name |
| `node.kubernetes.io/instance-type` | Compute offering |
| `topology.kubernetes.io/zone` | CloudStack zone |
| `topology.kubernetes.io/region` | Region (or zone if not defined) |

### Node Initialization

Recommended kubelet parameter:
```bash
--register-with-taints=node.cloudprovider.kubernetes.io/uninitialized=true:NoSchedule
```

This marks nodes as uninitialized and triggers the CCM to apply labels. Can also be triggered manually:
```bash
kubectl taint nodes <node-name> node.cloudprovider.kubernetes.io/uninitialized=true:NoSchedule
```

> ⚠️ **Important:** The node name must match the hostname for the controller to fetch and assign metadata from CloudStack.

## Key Differences from In-Tree Provider

| Aspect | In-Tree (removed) | External CCM |
|--------|-------------------|-------------|
| **Lifecycle** | Tied to K8s release cycle | Independent releases |
| **Deployment** | Bundled with kubelet | Runs as a separate pod |
| **Metadata source** | VM's DHCP server (VR) | CloudStack API |
| **LB rule naming** | Simple naming | Includes protocol (TCP/UDP/proxy) |
| **Migration note** | — | Remove old rules before migrating to avoid duplicates |

## Running Locally (Development)

```bash
# Build
go get github.com/apache/cloudstack-kubernetes-provider
cd ${GOPATH}/src/github.com/apache/cloudstack-kubernetes-provider
make

# Build container
make docker

# Run locally
./cloudstack-ccm --cloud-provider external-cloudstack --cloud-config ./cloud-config --kubeconfig ~/.kube/config
```

### Debugging with VSCode
Add to `.vscode/launch.json`:
```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Launch CloudStack CCM",
      "type": "go",
      "request": "launch",
      "mode": "auto",
      "program": "${workspaceFolder}/cmd/cloudstack-ccm",
      "args": [
        "--cloud-provider=external-cloudstack",
        "--cloud-config=${workspaceFolder}/cloud-config",
        "--kubeconfig=${env:HOME}/.kube/config",
        "--leader-elect=false",
        "--v=4"
      ]
    }
  ]
}
```

### Testing with CloudStack Simulator
```bash
docker run -d cloudstack/simulator
```
Point the CCM at the simulator for dry-run testing without a real CloudStack installation.

## Applicability Across Flavors

This provider is relevant to **all four Kubernetes flavors** on CloudStack:

| Flavor | How it applies |
|--------|---------------|
| **CKS** | Auto-deployed when CKS cluster is created (4.16+) |
| **CAPC** | Required for LoadBalancer services and node metadata on CAPC-managed clusters |
| **Talos** | Must be manually deployed; Talos doesn't include an in-tree CCM |
| **Rancher+CAPC** | Deployed by Rancher or manually for LoadBalancer support |

## References

- [GitHub Repository](https://github.com/apache/cloudstack-kubernetes-provider)
- [Docker Hub](https://hub.docker.com/r/apache/cloudstack-kubernetes-provider)
- [kubernetes/enhancements#672](https://github.com/kubernetes/enhancements/issues/672)
- [kubernetes/enhancements#88](https://github.com/kubernetes/enhancements/issues/88)
- [HAProxy Proxy Protocol](https://www.haproxy.org/download/1.8/doc/proxy-protocol.txt)
