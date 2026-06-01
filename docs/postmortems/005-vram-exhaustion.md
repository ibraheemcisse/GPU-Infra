# Postmortem 005: VRAM Exhaustion OOM on NVIDIA A10G

**Date:** 2026-06-01  
**Severity:** Medium — deliberate fault injection, no production impact  
**Duration:** ~30 seconds from pod start to OOM crash  
**Resolution:** Kyverno policy enforcing GPU resource limits, ResourceQuota per namespace  
**Status:** Resolved with preventive controls

---

## Summary

A PyTorch workload was deliberately run inside a Kubernetes pod with no VRAM limit, allocating GPU memory in 1GB increments until the NVIDIA A10G ran out of memory. The pod crashed with `torch.cuda.OutOfMemoryError` at iteration 21 after consuming 21GB of the available 22.06GB. Kubernetes recorded the failure with exit code Error and did not restart the pod (`restartPolicy: Never`). The GPU recovered immediately after the pod exited. The incident exposed the absence of GPU resource limits as a gap in cluster policy, which was subsequently closed with Kyverno admission controls and ResourceQuota enforcement.

---

## Environment

- Node: g5.xlarge, NVIDIA A10G, 23028MiB total VRAM
- Kubernetes: 1.31.14, single-node
- GPU Operator: active, device plugin running
- Workload image: pytorch/pytorch:2.1.0-cuda12.1-cudnn8-runtime
- restartPolicy: Never

---

## What Happened

A pod was submitted with `nvidia.com/gpu: 1` in resource requests but no explicit memory constraints. The workload allocated torch tensors of 1GB each in a loop with no upper bound.

Allocation progression:

```
Iteration 1:  VRAM used 1.00 GB
Iteration 2:  VRAM used 2.00 GB
Iteration 3:  VRAM used 3.00 GB
...
Iteration 21: VRAM used 21.00 GB
```

At iteration 22, the allocation attempt failed:

```
torch.cuda.OutOfMemoryError: CUDA out of memory. Tried to allocate 1024.00 MiB.
GPU 0 has a total capacity of 22.06 GiB of which 823.44 MiB is free.
Including non-PyTorch memory, this process has 21.25 GiB memory in use.
Of the allocated memory 21.00 GiB is allocated by PyTorch.
```

Pod exit status: Error. No restart attempted. GPU returned to idle state immediately.

---

## Why It Got to 21GB, Not 22GB

The A10G has 23028MiB of total VRAM. The device plugin reports 22.06GiB as usable. The remaining ~1GB is reserved by the NVIDIA driver for system processes, context overhead, and the GPU Operator's own components (DCGM exporter, device plugin). This overhead is always present and is why production workloads should never assume they can use 100% of advertised VRAM.

Practical ceiling for user workloads on a 24GB A10G: approximately 21-22GB depending on driver version and GPU Operator components running.

---

## Kubernetes Behavior

The pod exited with a non-zero code. Because `restartPolicy: Never` was set, Kubernetes recorded the failure and stopped. No retry storm occurred. The GPU resource was released immediately and became available for the next pod.

If `restartPolicy: OnFailure` had been set, the pod would have entered CrashLoopBackOff, repeatedly attempting to allocate GPU memory and failing, holding the `nvidia.com/gpu` resource slot and preventing other pods from scheduling.

This is the starvation scenario relevant to multi-tenant clusters: one runaway job in CrashLoopBackOff with no memory limit occupies a GPU slice indefinitely while other teams wait.

---

## Impact in a Multi-Tenant Context

In the three-team simulation running on this cluster, this workload would have:

- Consumed one of the four time-sliced GPU replicas
- If in CrashLoopBackOff: held that replica indefinitely
- Starved one team of their allocated GPU access
- Caused cascading Pending state for downstream inference workloads

The severity scales with cluster size. On a shared cluster with real teams, an unconstrained fine-tuning job that repeatedly OOMs can degrade inference SLAs for unrelated workloads.

---

## Root Cause

No GPU memory limit was set on the pod. The NVIDIA device plugin enforces `nvidia.com/gpu` count limits but does not enforce VRAM byte limits. A pod can request 1 GPU and use all available VRAM without restriction at the Kubernetes scheduler level. VRAM exhaustion is enforced only at the CUDA driver level, which raises an exception inside the process rather than preventing allocation at admission.

---

## Remediation

Two controls were implemented after this incident:

### Control 1: Kyverno admission policy

Any pod requesting `nvidia.com/gpu` must set an explicit `limits.nvidia.com/gpu` value. Pods without limits are rejected at admission by the Kyverno webhook before they reach the scheduler.

Policy: `require-gpu-limits` (ClusterPolicy, Enforce mode)

Tested: non-compliant pod rejected with message:
```
admission webhook "validate.kyverno.svc-fail" denied the request:
Pods requesting nvidia.com/gpu must set explicit resource limits.
```

### Control 2: ResourceQuota per namespace

Each team namespace has a hard quota on `requests.nvidia.com/gpu` and `limits.nvidia.com/gpu`. A team cannot exceed their allocation regardless of how many pods they submit.

```
team-alpha: 2 GPUs
team-beta:  1 GPU
team-gamma: 1 GPU
```

Tested: second pod in team-beta rejected with:
```
pods "beta-overflow" is forbidden: exceeded quota: gpu-quota,
requested: requests.nvidia.com/gpu=1,
used: requests.nvidia.com/gpu=1,
limited: requests.nvidia.com/gpu=1
```

---

## What These Controls Do Not Cover

VRAM byte allocation is still uncontrolled within a pod's GPU slice. A pod with `nvidia.com/gpu: 1` can still attempt to allocate all available VRAM. The controls prevent:

- Pods without explicit GPU count limits
- Teams exceeding their GPU count quota

They do not prevent:

- A single pod with a valid GPU limit from exhausting VRAM within its slice
- VRAM fragmentation across time-sliced replicas
- GPU compute starvation (time-slicing shares compute cycles but does not guarantee QoS)

True VRAM isolation requires MIG (Multi-Instance GPU), available on A100 and H100. The A10G does not support MIG.

---

## Lessons

GPU resource management in Kubernetes requires defense in depth. The device plugin enforces GPU count. ResourceQuota enforces namespace-level count limits. Kyverno enforces admission-time policy. None of these alone is sufficient. All three together provide reasonable protection for a shared cluster.

`restartPolicy: Never` is the correct setting for GPU batch jobs. `OnFailure` should be used only for workloads that are designed to be idempotent and have explicit memory guards in the application code.

Document the practical VRAM ceiling for each GPU type in your cluster. For the A10G, the usable ceiling is approximately 21GB, not 23GB. Workloads designed to use the full 23GB will OOM in production.

---

## GPU State After OOM

```
nvidia-smi output immediately after pod exit:
Memory-Usage: 0MiB / 23028MiB
GPU-Util: 0%
Temperature: 32C
Power: 26W / 300W
Processes: No running processes found
```

Full recovery confirmed. No driver restart required. No node impact.
