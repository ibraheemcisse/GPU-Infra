# gpu-infra

Kubernetes cluster on AWS with GPU infrastructure.

**Goal:** Operational depth, not demos. Real workloads, real failures, real postmortems.

## Stack

- Control plane: t3.medium (us-east-1a, running)
- GPU worker: g5.xlarge (NVIDIA A10G, pending GPU quota approval)
- Runtime: containerd
- CNI: Cilium (eBPF-ready)
- Orchestration: kubeadm 1.31

## Status

See [STATUS.md](STATUS.md)

## What's here
terraform/          Infrastructure as code (VPC, security groups, EC2)
docs/
bootstrap.md      Full kubeadm bootstrap sequence
postmortems/      Incident postmortems (populated as GPU work begins)
workloads/
cuda-samples/     CUDA validation
pytorch-test/     Framework integration
vram-exhaustion/  Deliberate OOM postmortem
ollama/           Real operational load

## Key learnings

- Cluster bootstrap from plain Ubuntu 22.04 (no pre-baked AMIs)
- Private IP vs EIP for `--control-plane-endpoint` (gotcha documented)
- CNI selection: Calico → Flannel → Cilium (reasoning in docs)
- Kernel pinning + driver management (GPU-specific considerations)

## Running the lab

```bash
# Provision infrastructure
cd terraform
terraform init
terraform apply

# Bootstrap control plane (see docs/bootstrap.md)
ssh -i ~/.ssh/gpu-infra.pem ubuntu@<control-plane-eip>
# Run bootstrap script

# kubeadm init, install CNI, verify cluster Ready
```

Once GPU worker quota is approved, provision and join it (same bootstrap process).

## Next: GPU workloads

CUDA samples → PyTorch → VRAM exhaustion → Ollama (in sequence)

Each workload documents its operational behavior and failure modes.
