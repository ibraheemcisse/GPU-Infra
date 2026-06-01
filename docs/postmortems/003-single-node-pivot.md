# Postmortem 003: Two-node cluster abandoned, pivot to single-node GPU topology

**Date:** 2026-06-01  
**Severity:** Low — architectural decision, no production impact  
**Duration:** N/A — deliberate pivot, not an incident  
**Resolution:** Single-node cluster on g5.xlarge, control-plane taint removed  
**Status:** Resolved

---

## Summary

After two days of debugging inter-node networking in a two-node kubeadm cluster on AWS, a decision was made to move to a single-node topology on the g5.xlarge GPU instance. The change eliminates the inter-node networking requirement entirely, unblocks the primary lab objective (running GPU workloads), and reflects a legitimate production topology for edge inference and single-GPU serving use cases.

---

## Context

The original lab design used two EC2 instances:

- `t3.medium` as control plane (10.0.1.48)
- `g5.xlarge` as GPU worker (10.0.1.70)

The intent was to build a realistic multi-node Kubernetes cluster with a dedicated GPU worker. This is the standard topology for GPU workloads in production clusters.

Two issues blocked this from working:

1. containerd 2.x CRI incompatibility with Kubernetes 1.31 (documented in Postmortem 001)
2. Cilium route hijack breaking all inter-node traffic (documented in Postmortem 002)

After resolving issue 1 and spending approximately six hours on issue 2 without a clean fix, the two-node architecture was evaluated against the lab's actual objectives.

---

## Decision Rationale

The lab objectives are:

1. Run CUDA validation inside a Kubernetes pod
2. Run PyTorch with GPU access
3. Trigger and observe VRAM exhaustion (OOM postmortem)
4. Run Ollama inference and observe VRAM behavior

None of these objectives require more than one node. All four workloads run on the GPU node. The control plane exists only to schedule them. The inter-node networking work was in service of the architecture, not the objectives.

Additionally, single-node GPU Kubernetes is a real production topology:

- Edge inference on factory floors, retail stores, hospitals
- Single-GPU model serving at early-stage companies
- Developer GPU environments that mirror production manifests
- CI/CD batch jobs (training runs, evaluation, fine-tuning)

The decision to move to single-node is not a compromise. It is a change in scope from "learn multi-node cluster operations" to "run GPU workloads on Kubernetes." Both are valid objectives. The multi-node networking work already produced two postmortems and significant diagnostic experience. The return on continued investment was diminishing.

---

## What Was Discarded

- `t3.medium` control plane instance (terminated)
- Two-node kubeadm join workflow
- Inter-node CNI configuration
- EventBridge scheduler (was configured to stop/start both instances — now only one instance remains)

The Terraform code still provisions two instances. This is intentional. The two-node architecture is preserved for a future session focused specifically on multi-node networking and CNI behavior.

---

## What Changed

**Removed:** t3.medium control plane  
**Kept:** g5.xlarge GPU instance  
**Added:** Control-plane taint removal so workloads schedule on the single node

```bash
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

**Cluster init on g5.xlarge:**

```bash
sudo kubeadm init \
  --pod-network-cidr=192.168.0.0/16 \
  --apiserver-advertise-address=10.0.1.70 \
  --control-plane-endpoint=10.0.1.70 \
  --skip-phases=addon/kube-proxy
```

**CNI:**

```bash
cilium install --version 1.19.3 \
  --set routingMode=tunnel \
  --set tunnelProtocol=vxlan \
  --set autoDirectNodeRoutes=false
```

**Result:** Single node Ready in under 10 minutes with no networking issues.

---

## Cost Impact

| Before | After |
|--------|-------|
| t3.medium + g5.xlarge running | g5.xlarge only |
| ~$1.10/hr running | ~$1.01/hr running |
| ~$0.015/hr stopped | ~$0.010/hr stopped |

Marginal cost difference. The real saving is operational — one less instance to manage, one less SG to maintain, one less bootstrap sequence.

---

## Lessons

**On architecture:** The right cluster topology is the one that serves the objective. A two-node cluster is not inherently better than a single-node cluster for a GPU workload lab. Complexity has a cost, and that cost should be justified by what it enables.

**On scope management:** The inter-node networking investigation was useful but it was not the goal. Recognizing when a problem has become a blocker to the actual objective, and making a deliberate architectural change instead of continuing to debug, is a real engineering skill. It is not giving up.

**On the two-node work:** The diagnostic work from the two-node sessions produced two postmortems documenting real failure modes (containerd version incompatibility, Cilium route injection). These are artifacts with standalone value regardless of whether the two-node cluster ever fully worked. The work was not wasted.

---

## Future Work

The two-node topology will be revisited in a dedicated session focused on:

- Cilium AWS ENI mode (native VPC routing, no overlay)
- Calico as an alternative CNI
- VPC Flow Logs to definitively diagnose the packet path
- Multi-node GPU scheduling (pod affinity, node selectors, resource quotas across nodes)

That session should be scoped specifically to networking, not to GPU workloads. Mixing the two objectives is what extended this session unnecessarily.
