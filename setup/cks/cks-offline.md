# CKS Offline Deployment — Workaround Guide

> Official CloudStack docs say internet is required during cluster creation. This documents what happens when you disconnect, and how to make it work anyway.

## 1. The Problem

- What official docs say about network requirements
- Why CKS needs internet (what components pull from the web during provisioning)
- When offline deployment matters (air-gapped, restricted environments)

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
