# GPU Infrastructure Lab — Status

## Completed

✅ Phase 1: AWS infrastructure provisioning
- VPC, security groups, EC2 instances via AWS CLI

- Control plane (t3.medium) running, Cilium CNI operational

✅ Phase 2: Control plane bootstrap
- kubeadm 1.31 cluster initialized and Ready

## Blocked

❌ Phase 3: GPU worker
- AWS vCPU quota denied (on-demand + spot)
- Case #178003097100094: no approval after appeal

## Next

Evaluate alternative GPU providers (RunPod) or pivot to other operational labs.

- Control plane (t3.medium) running in us-east-1a
- Cluster operational and Ready with Cilium CNI

✅ Phase 2: Control plane bootstrap
- containerd runtime
- kubeadm 1.31, kubelet, kubectl
- kubeadm init with Cilium CNI
- Kubernetes cluster operational

## Blocked

❌ Phase 3: GPU worker provisioning
- AWS vCPU quota denied (on-demand g5.xlarge)
- AWS spot quota also denied (spot g5.xlarge)
- Case #178003097100094: no approval after appeal

## Decision

Moving forward with alternative approach (RunPod or other GPU provider) for workload sequence, keeping control plane as-is in AWS.

## Documents

- [Bootstrap sequence](docs/bootstrap.md) — kubeadm walkthrough
- [Terraform](terraform/) — Infrastructure definitions
- [Workloads](workloads/) — Kubernetes manifests (staged, awaiting GPU)

---

**Learning achieved:** Full Kubernetes cluster bootstrap on AWS from scratch. GPU workload validation pending GPU quota approval.
