# ClusterClass and CAPC — Current Limitation

## Summary

**ClusterClass cannot be used with CAPC today.** CAPC does not implement `CloudStackClusterTemplate`, the CRD that ClusterClass requires for its `infrastructure.templateRef` field.

## What ClusterClass needs

ClusterClass is a CAPI feature that defines a reusable cluster template. A `Cluster` using topology mode references a ClusterClass, and the CAPI topology controller expands it into the full set of provider CRDs (`CloudStackCluster`, `KubeadmControlPlane`, `MachineDeployment`, `CloudStackMachineTemplate`, `KubeadmConfigTemplate`).

For this to work, each infrastructure provider must implement two template CRDs:

| CRD | Purpose | CAPC status |
|-----|---------|------------|
| `CloudStackMachineTemplate` | Machine-level template (offering, image, SSH key) | ✅ Implemented |
| `CloudStackClusterTemplate` | Cluster-level template (network, zone, endpoints) | ❌ Not implemented |

Without `CloudStackClusterTemplate`, the topology controller has nothing to expand the `Cluster` topology's infrastructure layer into — ClusterClass cannot function.

## Verification

```bash
# Check for CloudStackClusterTemplate CRD — it does not exist
kubectl get crd | grep cloudstackclustertemplate
# (no output)

# ClusterClass infrastructure field requires a template ref
kubectl explain clusterclasses.cluster.x-k8s.io.spec.infrastructure.templateRef
# apiVersion: <string> -required-
# kind: <string> -required-       ← would need "CloudStackClusterTemplate"
# name: <string> -required-       ← would need a named template object
```

## What this means in practice

- **Cluster topology mode** (`spec.topology.class`) is not available for CAPC clusters
- Clusters must be created with **explicit CRD references** — `CloudStackCluster`, `KubeadmControlPlane`, `MachineDeployment`, `CloudStackMachineTemplate`, `KubeadmConfigTemplate` — as shown in [`10-minimal-cluster.yaml`](./manifests/10-minimal-cluster.yaml) and [`11-ha-cluster.yaml`](./manifests/11-ha-cluster.yaml)
- **ClusterResourceSet** (not ClusterClass) is the correct mechanism for auto-installing CNI/CCM/CSI — see [Full-Stack Onboarding](./full-stack-onboarding.md)
- Cluster upgrades are done by creating new `CloudStackMachineTemplate` objects and updating `KubeadmControlPlane`/`MachineDeployment` references — see [Upgrade Guide](./cluster.md#8-upgrade-the-cluster)

## What CAPC would need to support ClusterClass

1. Implement a `CloudStackClusterTemplate` CRD with a `spec.template.spec` mirroring `CloudStackCluster.spec`
2. Register it with the CAPI topology controller
3. The CAPC controller would reconcile `CloudStackCluster` objects created from the template (same as it does today for manually-created ones)

This is a provider-level implementation gap, not a configuration issue. It would need to be addressed in the [CAPC project](https://github.com/apache/cloudstack-kubernetes-provider).

## Comparison with other CAPI providers

| Provider | MachineTemplate | ClusterTemplate | ClusterClass support |
|----------|----------------|-----------------|---------------------|
| CAPA (AWS) | ✅ | ✅ | ✅ |
| CAPD (Docker) | ✅ | ✅ | ✅ |
| CAPV (vSphere) | ✅ | ✅ | ✅ |
| CAPZ (Azure) | ✅ | ✅ | ✅ |
| **CAPC (CloudStack)** | ✅ | ❌ | ❌ |

## References

- [CAPI ClusterClass documentation](https://cluster-api.sigs.k8s.io/tasks/experimental-features/cluster-class)
- [Rancher Turtles — Installing applications](https://turtles.docs.rancher.com/turtles/stable/en/user/applications.html) — recommends ClusterResourceSet for Kubeadm-based clusters
- [CAPC project](https://github.com/apache/cloudstack-kubernetes-provider)