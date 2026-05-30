# gpu-infra

Kubernetes infrastructure lab on AWS with GPU support. Built from scratch using kubeadm, Terraform, and manual operations to understand the full stack.

**Goal:** Operational depth on GPU infrastructure — not tutorials, not managed services, not abstractions. Real bootstrapping, real failures, real postmortems.

## What's here
terraform/              Complete infrastructure-as-code (VPC, security groups, EC2, scheduler)
main.tf              12 AWS resources (VPC, subnets, instances, EIPs, auto-stop)
variables.tf         Configuration (region, SSH CIDR, instance types, schedules)
outputs.tf           Quick reference (IPs, SSH commands)
bootstrap-*.sh       kubeadm bootstrap scripts for control plane + GPU worker
docs/
bootstrap.md         Full manual walkthrough (for learning)
postmortems/         Incident analysis (populated when GPU workloads run)
workloads/
cuda-samples/        CUDA validation
pytorch-test/        Framework integration test
vram-exhaustion/     Deliberate OOM postmortem
ollama/              Real inference workload

## Stack

| Component | Details |
|-----------|---------|
| **Control plane** | t3.medium (4 vCPU, 4GB RAM, 30GB disk) |
| **GPU worker** | g5.xlarge (4 vCPU, 16GB RAM, 50GB disk, NVIDIA A10G 24GB VRAM) |
| **Runtime** | containerd 2.x |
| **Orchestrator** | kubeadm 1.31 |
| **CNI** | Cilium (eBPF-ready) |
| **Networking** | Private VPC (10.0.0.0/16), EIPs for stable SSH |
| **Auto-stop** | EventBridge Scheduler (GPU worker stops after hours) |

## Quick start

### Prerequisites

```bash
# AWS credentials configured
aws sts get-caller-identity

# Terraform >= 1.5
terraform version

# SSH key pair created in AWS
aws ec2 describe-key-pairs --key-names your-key-name
```

### Provision infrastructure

```bash
cd terraform

# Get your public IP
YOUR_IP=$(curl -s ifconfig.me)

# Initialize and plan
terraform init
terraform plan \
  -var="allowed_ssh_cidr=${YOUR_IP}/32" \
  -var="key_name=your-key-name"

# Apply
terraform apply \
  -var="allowed_ssh_cidr=${YOUR_IP}/32" \
  -var="key_name=your-key-name"

# Wait 2 minutes for instances to boot, then:
terraform output
```

### Bootstrap cluster

```bash
# SSH to control plane
ssh -i ~/.ssh/your-key-name.pem ubuntu@<control-plane-public-ip>

# kubeadm init (already run by user_data, verify it worked)
kubectl get nodes

# Install Cilium CNI
kubectl apply -f https://github.com/cilium/cilium-cli/releases/latest/download/cilium-linux-amd64.tar.gz
cilium install --version 1.15.0

# Verify cluster is Ready
kubectl get nodes
```

### Join GPU worker

Once the control plane is ready:

```bash
# On control plane, get the join command
kubeadm token create --print-join-command

# SSH to GPU worker
ssh -i ~/.ssh/your-key-name.pem ubuntu@<gpu-worker-public-ip>

# Run the join command
sudo kubeadm join <control-plane-ip>:6443 --token ... --discovery-token-ca-cert-hash ...

# Back on control plane, verify
kubectl get nodes
# Both nodes should show Ready
```

### Run GPU workloads

Once GPU worker is Ready:

```bash
# 1. Validate GPU access
kubectl apply -f workloads/cuda-samples/validate.yaml
kubectl logs -f -l job-name=cuda-validate

# 2. Run PyTorch test
kubectl apply -f workloads/pytorch-test/job.yaml
kubectl logs -f -l job-name=pytorch-test

# 3. VRAM exhaustion (deliberate OOM)
kubectl apply -f workloads/vram-exhaustion/job.yaml
# Watch it fail, document the postmortem

# 4. Ollama inference
kubectl apply -f workloads/ollama/deployment.yaml
kubectl port-forward svc/ollama 11434:11434
curl -X POST http://localhost:11434/api/generate -d '{"model":"llama2","prompt":"hello"}'
```

## Key decisions

**Why kubeadm, not managed (EKS)?**
- Operational depth: understand every component initialization
- Bootstrap from first principles
- See the full failure surface

**Why Terraform, not Console?**
- Infrastructure as code (repeatable, reviewable)
- Documented decisions (VPC sizing, security group rules)
- Fast teardown + replay

**Why Cilium CNI?**
- eBPF-ready for future observability labs
- Stable in single-node scenarios (unlike Flannel)
- Production patterns

**Why private IP for --control-plane-endpoint?**
- EIP works externally, breaks internal kubelet → API connectivity
- Private IP is stable within VPC (EIP is for external SSH only)

**Why GPU worker has 50GB root volume?**
- NVIDIA drivers compile at GPU Operator install
- CUDA runtime + kernels + model weights
- 30GB is too tight

## GPU quota constraint

**Status:** AWS denied vCPU quota increase twice (on-demand + spot).

This is a **real operational lesson**, not a failure:
- AWS quota is a hard wall for new accounts
- GPU quota approval takes days or requires detailed justification
- Alternatives exist (RunPod, Lambda Labs, bare metal)

**Workloads are staged and ready** — GPU access is the only blocker.

When GPU is available:
1. Uncomment `gpu_worker` instance in `main.tf`
2. `terraform apply`
3. Join it to cluster (kubeadm join)
4. Install NVIDIA GPU Operator
5. Run workload sequence

## Cost

| Resource | Cost/hr | Running | Stopped |
|----------|---------|---------|---------|
| Control plane (t3.medium) | $0.042 | $0.042 | $0 |
| GPU worker (g5.xlarge) | $1.006 | $1.006 | $0 |
| EIPs (2x) | $0.015 | $0.015 | $0.015 |
| **Total** | | **~$1.06/hr** | **$0.015/hr** |

GPU worker auto-stops after business hours (see `bootstrap-gpu-worker.sh`).

## Next steps

1. Provision infrastructure (`terraform apply`)
2. Bootstrap control plane and GPU worker
3. Run CUDA samples (validation)
4. Run PyTorch test (framework integration)
5. Run VRAM exhaustion (postmortem learning)
6. Deploy Ollama (real operational load)
7. Document failures and learnings

## References

- [kubeadm docs](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/)
- [Cilium CNI](https://docs.cilium.io/)
- [NVIDIA GPU Operator](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/)
- [The GPU Challenge at Scale](https://www.ebook-collection.com/) (operational fundamentals)

---

**Status:** See [STATUS.md](STATUS.md) for current lab state and blockers.

**Questions?** Open an issue or check [docs/bootstrap.md](docs/bootstrap.md) for manual walkthrough.
