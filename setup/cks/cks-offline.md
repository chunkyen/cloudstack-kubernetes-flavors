# CKS Offline Deployment — Workaround Guide

> Official CloudStack docs say internet is required during cluster creation. This documents what happens when you disconnect, and how to make it work anyway.

## What the Docs Say

The [CloudStack Kubernetes Service documentation](https://docs.cloudstack.apache.org/en/latest/plugins/cloudstack-kubernetes-service.html) states:

> "Using a pre-packaged ISO containing required binaries and docker images allows faster provisioning on the node Instances of a Kubernetes cluster. **Complete offline provisioning of the Kubernetes cluster is not supported at present as the kubeadm init command needs active Internet access.**"

This guide documents that it _is_ possible, with workarounds.

## 1. The Problem

The CloudStack documentation explicitly states that complete offline provisioning of Kubernetes clusters is not supported — `kubeadm init` allegedly requires active internet access. This means if your management server or zone has no outbound connectivity to the public internet, cluster creation is expected to fail.

In practice, CKS needs internet during node provisioning for several reasons:

- **CNI plugin manifests** are pulled from the web (e.g., Calico YAML from GitHub) and applied after `kubeadm init` completes.
- **Additional components** like the Kubernetes dashboard or CSI driver may be deployed via remote URLs baked into the ISO build scripts.
- Any custom CNI configuration registered in CloudStack that references external image registries will also fail without connectivity.

This is a real barrier for air-gapped deployments, government/military environments, and any setup where management servers are intentionally disconnected from the internet. The documentation's stance makes it seem like there's no way around it — but as this guide demonstrates, it _is_ possible with some workarounds.

## 2. No Special Preparation Needed

- All K8s images are already baked into the ISO — no local registry or pre-download step required
- The ISO is self-contained for cluster creation

## 3. What Fails Without Internet

- Breakdown of which steps fail and why:
  - CNI plugin installation (Calico/Cilium manifests pulled from web)
  - CSI driver deployment
  - Anything else observed failing

## 4. The Workaround(s)

- Specific workaround(s) — what was done differently
- Step-by-step walkthrough

## 5. Caveats & Limitations

- What still doesn't work fully offline
- Things that broke or had unexpected behavior
- Known gaps vs online deployment

## 6. Verification

- How to confirm the cluster is functional without internet
- Test checklist (nodes join, pods schedule, CNI works, etc.)
