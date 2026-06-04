# GPU Infrastructure Lab — Status

## Current State: Complete

All four GPU workloads validated. Policies enforced. Monitoring deployed.

---

## Completed

### Infrastructure
- Single-node g5.xlarge on AWS (ip-10-0-1-70)
- VPC, subnet, security group, EIP, EventBridge scheduler via Terraform
- AWS GPU quota approved (All G instances, limit 4, us-east-1)

### Cluster
- kubeadm 1.31.14 single-node cluster
- containerd 1.7.29 (pinned — 2.x breaks CRI with k8s 1.31)
- Calico v3.27 CNI
- Control-plane taint removed (single-node workload scheduling)

### GPU Stack
- NVIDIA GPU Operator installed
- Driver 580.126.20, CUDA 13.0
- Device plugin: nvidia.com/gpu: 1 (4 with time-slicing)
- DCGM Exporter running

### Workloads
- CUDA validation: nvidia-smi in pod, A10G confirmed
- PyTorch matmul 5000x5000: PASSED
- VRAM exhaustion: OOM at 21GB, postmortem documented
- Ollama + TinyLlama: inference working, 1019MiB at load

### Policy
- Kyverno installed and operational
- require-gpu-limits: enforced
- cap-gpu-per-pod: enforced
- GPU time-slicing: 1 physical GPU as 4 schedulable replicas
- team-alpha, team-beta, team-gamma namespaces with ResourceQuota

### Monitoring
- kube-prometheus-stack deployed
- Prometheus scraping DCGM Exporter via ServiceMonitor
- Grafana deployed (internal access confirmed)

---

## Postmortems

| # | Title |
|---|-------|
| 001 | containerd 2.x CRI incompatibility |
| 002 | Cilium route hijack breaking inter-node traffic |
| 003 | Single-node architectural pivot |
| 004 | CNI migration networking collapse |
| 005 | VRAM exhaustion OOM on A10G |

Full postmortems: [docs/postmortems/](docs/postmortems/)

---

## Open Items

- Terraform variables.tf not yet updated to match new single-node variable names
- Grafana external access deferred (NodePort routing issue, LoadBalancer recommended)
- Multi-node networking (Cilium ENI mode, Calico BGP) deferred to future session
- RHCSA certification — planned post-CKA

---

## Cost

$9.32 of $500 AWS Community Builder credits used.
All resources stopped or terminated. Zero ongoing cost.
