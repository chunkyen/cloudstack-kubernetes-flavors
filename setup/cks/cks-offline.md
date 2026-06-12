# CKS Offline Deployment — Workaround Guide

> Official CloudStack docs say internet is required during cluster creation. This documents what happens when you disconnect, and how to make it work anyway.

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

## 4. What Fails Without Internet

Upgrading beyond a certain point requires internet access:

- ❌ **Upgrade to 1.34.7 (and likely later versions)** — upgrade fails when disconnected
- As soon as internet is restored, the same upgrade succeeds

This suggests that something changed in CKS between 1.33.x and 1.34.x — either `kubeadm` started pulling additional images from external registries at init time, or some component now references a remote URL that wasn't previously needed.

## 5. The Workaround(s)

- Specific workaround(s) — what was done differently
- Step-by-step walkthrough

## 6. Caveats & Limitations

- Offline upgrades work only up to a certain version (currently **1.33.1**); beyond that, internet is required
- The exact breaking change between 1.33.x and 1.34.x has not yet been identified
- Things that broke or had unexpected behavior
- Known gaps vs online deployment

## 7. Verification

- How to confirm the cluster is functional without internet
- Test checklist (nodes join, pods schedule, CNI works, etc.)
