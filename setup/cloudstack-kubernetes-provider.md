# CloudStack Kubernetes Provider (CCM) — Setup Guide

## Prerequisites

- Kubernetes cluster running on CloudStack
- CloudStack management server accessible from cluster nodes
- `kube-system` namespace
- `kubectl` access with cluster-admin privileges

## Step 1: Create cloud-config

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

## Step 2: Create Kubernetes Secret

```bash
kubectl -n kube-system create secret generic cloudstack-secret --from-file=cloud-config
```

> If you also deploy the CloudStack CSI Driver, you can reuse the same secret for both.

## Step 3: Deploy the Controller

```bash
kubectl apply -f https://raw.githubusercontent.com/apache/cloudstack-kubernetes-provider/main/deployment.yaml
```

Verify deployment:
```bash
kubectl get pods -n kube-system -l app=cloudstack-ccm
kubectl logs -f -n kube-system <ccm-pod-name>
```

## Step 4: (Optional) Deploy Ingress Controller with Proxy Protocol

### Traefik
```bash
kubectl apply -f https://raw.githubusercontent.com/apache/cloudstack-kubernetes-provider/main/traefik-ingress-controller.yml
```

### Nginx
```bash
kubectl apply -f https://raw.githubusercontent.com/apache/cloudstack-kubernetes-provider/main/nginx-ingress-controller-patch.yml
```

## Step 5: Verify Load Balancer Provisioning

Create a test `LoadBalancer` service:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: test-lb
  annotations:
    service.beta.kubernetes.io/cloudstack-load-balancer-proxy-protocol: "true"
spec:
  type: LoadBalancer
  ports:
  - port: 80
    targetPort: 8080
    protocol: TCP
  selector:
    app: test-app
```

Check that a CloudStack load balancer rule was created:
```bash
# In CloudStack UI: Network → Load Balancers
# Or via API:
listLoadBalancers account=<account> domainid=<domain-id>
```

## Step 6: Verify Node Labels

```bash
kubectl get nodes --show-labels | grep -E "topology|instance-type"
```

Expected labels:
- `topology.kubernetes.io/zone`
- `topology.kubernetes.io/region`
- `node.kubernetes.io/instance-type`

If labels are missing, check the CCM logs for errors.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| CCM pod in `CrashLoopBackOff` | Check logs: `kubectl logs -n kube-system <ccm-pod>` — verify cloud-config secret exists and credentials are valid |
| Load balancer not created | Verify cloud-config has correct permissions; check CCM logs for API errors |
| Node labels missing | Ensure node name matches CloudStack instance name; check CCM logs |
| Duplicate LB rules | Remove old rules manually before migrating from in-tree provider |
| Proxy protocol not working | Verify CloudStack version ≥ 4.6; ensure ingress controller supports proxy protocol |

## Development & Debugging

```bash
# Build locally
go get github.com/apache/cloudstack-kubernetes-provider
cd ${GOPATH}/src/github.com/apache/cloudstack-kubernetes-provider
make

# Run locally (requires kubeconfig)
./cloudstack-ccm --cloud-provider external-cloudstack --cloud-config ./cloud-config --kubeconfig ~/.kube/config

# Test with CloudStack simulator
docker run -d cloudstack/simulator
```

## References

- [CloudStack Kubernetes Provider](https://github.com/apache/cloudstack-kubernetes-provider)
- [HAProxy Proxy Protocol](https://www.haproxy.org/download/1.8/doc/proxy-protocol.txt)
