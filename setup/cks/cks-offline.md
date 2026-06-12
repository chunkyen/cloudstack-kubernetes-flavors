# CKS Offline Deployment — Workaround Guide

## What the Docs Say

The [CloudStack Kubernetes Service documentation](https://docs.cloudstack.apache.org/en/latest/plugins/cloudstack-kubernetes-service.html) states:

> "Using a pre-packaged ISO containing required binaries and docker images allows faster provisioning on the node Instances of a Kubernetes cluster. **Complete offline provisioning of the Kubernetes cluster is not supported at present as the kubeadm init command needs active Internet access.**"

This guide documents that it _is_ possible, with workarounds.

## 1. The Problem

The CloudStack documentation explicitly states that complete offline provisioning of Kubernetes clusters is not supported — `kubeadm init` allegedly requires active internet access. This means if your management server or zone has no outbound connectivity to the public internet, cluster creation is expected to fail.

This is a real barrier for air-gapped deployments, government/military environments, and any setup where management servers are intentionally disconnected from the internet. The documentation's stance makes it seem like there's no way around it — but as this guide demonstrates, it _is_ possible with some workarounds.

## 2. No Special Preparation Needed

- All K8s images are already baked into the ISO — no local registry or pre-download step required
- The ISO is self-contained for cluster creation
- Pre-built Calico ISOs are available from [download.cloudstack.org/cks/](https://download.cloudstack.org/cks/) (x86 and ARM variants)

## 3. What Works Offline

Initial testing with the **1.32.5 Calico ISO** shows that most CKS operations work without internet:

- ✅ **Cluster creation** — provisioning succeeds fully offline
- ✅ **Day 2 scaling** — adding/removing worker nodes works
- ✅ **Upgrade to 1.33.1** — upgrading from 1.32.5 to the next version works

## 4. What Fails Without Internet — The Root Cause

Upgrading beyond a certain point requires internet access:

- ❌ **Upgrade to 1.34.7 (and likely later versions)** — upgrade fails when disconnected
- As soon as internet is restored, the same upgrade succeeds

### Investigation

During an offline upgrade from 1.33.x to 1.34.7, the process stalls while creating **upgrade health check pods** — a Job that verifies control plane upgrade completion before moving on to worker nodes.

On a failed (offline) upgrade, the health check pod gets stuck in a **ContainerCreating → Terminated** loop:
- The pod attempts to start but is immediately terminated
- Kubernetes retries, and the cycle repeats until the overall upgrade times out

On a successful (online) upgrade, the same pod reaches **Completed** status without issue.

### The Pause Container Version Change

The health check pod uses the `pause` container as its base image. Comparing the CKS ISOs:

| K8s Version | ISO Pause Image |
|-------------|-----------------|
| 1.32.x      | `pause:3.10`    |
| 1.33.x      | `pause:3.10`    |
| 1.34.x      | `pause:3.10.1`  |

The pause container version changed in the 1.34 ISO — from `3.10` to `3.10.1`. This small change is the key.

### Why It Fails Offline

In a cluster with 1 control plane and 1 worker node:

1. The upgrade starts on the **control plane** first. During this phase, the management server imports all 1.34 images (including `pause:3.10.1`) from the ISO onto that node.
2. Once the control plane is upgraded, the **upgrade health check pod** needs to run — and Kubernetes schedules it on a node that is _not_ being actively upgraded (i.e., the worker node).
3. The worker node still runs 1.33.x and has only `pause:3.10` in its local image store (verified via `crictl images`).
4. The health check pod requests `pause:3.10.1`, but the worker node doesn't have it locally.
5. **With internet:** the worker pulls `pause:3.10.1` from an external registry → pod completes → upgrade proceeds.
6. **Without internet:** the pull fails silently, the container is terminated, Kubernetes retries → infinite loop → upgrade stalls and eventually times out.

### Summary

The root cause is that CKS upgrades only import new images onto the node currently being upgraded. When a health check pod (or any intermediate Job) gets scheduled on a _different_ node that hasn't been upgraded yet, that node lacks the newer images — including `pause:3.10.1`. Without internet to pull them, the pod can't start.

This explains why upgrades up to 1.33.x work offline (same pause version as before) but 1.34+ fails (new pause version required on non-upgraded nodes).

## 5. The Workaround — Manually Import Images on Non-Upgraded Nodes

To complete an offline upgrade beyond 1.33.x, you need to manually import the new images onto nodes that haven't been upgraded yet.

### Step-by-Step

**1. SSH into the worker node (non-upgraded node):**

```bash
sudo -i
```

**2. Attach the 1.34 CKS ISO to the worker node:**

From CloudStack UI or via API, attach the 1.34 CKS ISO as a secondary ISO to the worker VM.

**3. Mount the ISO on the worker node:**

The attached ISO will appear as `/dev/sr0`. Create a mount point and mount it:

```bash
mkdir -p /mnt/iso
mount /dev/sr0 /mnt/iso
```

**4. Import the pause container image:**

Use `ctr` (containerd) to import the tarball from the ISO:

```bash
ctr -n k8s.io images import /mnt/iso/docker/pause:3.10.1.tar
```

**5. Verify the image is imported:**

```bash
crictl images | grep pause
```

You should see `pause` with tag `3.10.1` in the output.

**6. Restart the upgrade from CloudStack Management:**

Trigger the upgrade again via UI or cmk:

```bash
cmk upgrade kubernetescluster id=<cluster-id> kubernetesversionid=<new-version-id>
```

The upgrade health check pod should now reach **Completed** status, and the upgrade to 1.34 proceeds successfully.

### Why This Works

By pre-loading `pause:3.10.1` onto the worker node before the health check Job runs, Kubernetes doesn't need to pull it from an external registry — the image is already local in containerd's store.

## 6. Caveats & Limitations

- Offline upgrades work only up to **1.33.x**; beyond that, the pause container version change breaks health check pods on non-upgraded nodes
- The root cause is that CKS imports images only onto the node currently being upgraded — intermediate Jobs scheduled on other nodes can't find their required images without internet
- This affects any upgrade where new image versions are introduced (pause container or otherwise) that must run on a node not yet upgraded

## 7. Verification

- How to confirm the cluster is functional without internet
- Test checklist (nodes join, pods schedule, CNI works, etc.)
