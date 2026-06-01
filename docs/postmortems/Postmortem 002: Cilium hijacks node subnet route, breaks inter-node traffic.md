# Postmortem 002: Cilium hijacks node subnet route, breaks inter-node traffic

**Date:** 2026-05-31  
**Severity:** Critical — worker node permanently NotReady, all inter-node traffic blocked  
**Duration:** ~6 hours across two sessions  
**Resolution:** Single-node architecture, Cilium tunnel mode with explicit route exclusion  
**Status:** Resolved via architectural change

---

## Summary

After a worker node successfully joined a two-node kubeadm cluster, all traffic between the control plane (10.0.1.48) and the worker (10.0.1.70) failed with 100% packet loss. Cilium on the worker entered CrashLoopBackOff. The root cause was Cilium injecting a host route that redirected the entire node subnet (10.0.1.0/24) through its internal `cilium_host` interface instead of the real VPC network interface (`ens5`). This caused a routing loop that made both nodes unreachable from each other at the OS level, before any Kubernetes or CNI logic was involved.

---

## Timeline

**Day 1**

- Worker joins cluster via kubeadm join. Join completes successfully.
- Cilium DaemonSet pod on worker enters CrashLoopBackOff.
- Logs show: `no route to host` to `10.0.1.48:6443`.
- Diagnosis begins at Kubernetes layer: SG rules, NACL, kubelet config.
- SGs verified fully open between both nodes (all protocols, all ports).
- NACL verified: rule 100 allows all inbound and outbound.
- iptables flushed. Cilium interfaces deleted. kubeadm reset run on worker.
- Ping still fails 100% both directions.
- tcpdump on worker: ICMP echo requests visible leaving `ens5`.
- tcpdump on control plane: zero ICMP packets arriving. Only ARP.
- Instances terminated and redeployed twice. Problem persists on fresh instances.

**Day 2**

- Fresh analysis from routing layer.
- `ip route show` on worker reveals:
  `10.0.1.0/24 via 10.0.1.60 dev cilium_host proto kernel src 10.0.1.60`
- Same route present on control plane:
  `10.0.1.0/24 via 192.168.0.157 dev cilium_host`
- `ip route get 10.0.1.48` on worker returns `dev cilium_host` not `dev ens5`.
- Cilium identified as route hijacker. Route deleted manually on worker.
- `ip route get 10.0.1.48` now returns `dev ens5`. Correct.
- Ping still fails. Control plane has the same hijacked route in the other direction.
- Both routes deleted. Cilium reinstalled with tunnel mode flags to prevent recurrence.
- Routes re-injected by Cilium on next startup. Manual deletion not persistent.
- Decision made to move to single-node architecture to eliminate the inter-node problem entirely.

---

## Root Cause

Cilium's default installation injects a kernel route for the node's subnet CIDR through `cilium_host`. The intent is to handle pod-to-node traffic routing. The side effect is that all traffic destined for any IP in the node subnet, including other nodes, gets routed through the Cilium overlay instead of the VPC network interface.

On a single-node cluster this causes no problems. On a multi-node cluster where nodes share a subnet (standard AWS VPC setup), this breaks node-to-node communication entirely because:

1. Node A routes traffic for Node B's IP through `cilium_host`
2. `cilium_host` is a virtual interface managed by Cilium
3. Cilium on Node A is not yet initialized (it cannot reach the API server because inter-node traffic is already broken)
4. Traffic is dropped

This is a circular dependency: Cilium breaks routing, which prevents Cilium from initializing, which means Cilium cannot fix the routing.

The specific route injected on the worker:

```
10.0.1.0/24 via 10.0.1.60 dev cilium_host proto kernel src 10.0.1.60
```

This route has no metric, meaning it takes priority over the DHCP-assigned kernel route:

```
10.0.1.0/24 dev ens5 proto kernel scope link src 10.0.1.70 metric 100
```

Linux prefers the lower metric (0 beats 100), so all subnet traffic goes to `cilium_host`.

---

## Why It Took So Long to Find

The symptoms looked like an AWS networking problem. tcpdump showed packets leaving the source NIC but never arriving at the destination. This is consistent with a cloud provider dropping packets at the hypervisor level, which does happen. Two full instance terminations and redeployments were done based on this theory.

What was missed: tcpdump was run on `ens5`, the real interface. But the packets were being routed to `cilium_host` before they reached `ens5`. They never left the machine through the real interface. The tcpdump output showing packets on `ens5` was from ARP traffic, not ICMP. The ICMP packets were being silently dropped by the broken `cilium_host` path.

The correct diagnostic would have been `ip route get <destination-ip>` earlier in the investigation. That single command shows which interface the kernel will use for a given destination. It would have revealed `dev cilium_host` immediately and saved hours.

---

## Cilium Reinstall Attempts

Three Cilium reinstalls were attempted with different flags before the single-node decision:

**Attempt 1:** Default install  
Result: Route hijack present

**Attempt 2:** `--set routingMode=tunnel --set tunnelProtocol=vxlan --set autoDirectNodeRoutes=false`  
Result: Route hijack still present. Tunnel mode prevents pod-to-pod route injection but does not prevent the node subnet route injection.

**Attempt 3:** Added `--set ipv4NativeRoutingCIDR=192.168.0.0/16`  
Result: Route still injected on restart. Stale routes from previous install also persisted across reinstall.

None of the reinstalls cleanly removed existing Cilium kernel routes. `cilium uninstall` does not flush kernel routes added by previous Cilium instances.

---

## Resolution

Single-node cluster on the g5.xlarge. The control plane taint was removed so GPU workloads schedule on the single node. No inter-node networking is required. Cilium operates normally in a single-node context because the route injection does not conflict with itself.

```bash
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

The two-node architecture is preserved in Terraform for future use. The inter-node networking issue remains unresolved and is documented as a known open item.

---

## Correct Diagnostic Commands (for next time)

Check which interface the kernel will use for a destination:
```bash
ip route get <destination-ip>
```

Check for Cilium route injection:
```bash
ip route show | grep cilium_host
```

Manually remove a hijacked route (not persistent across Cilium restart):
```bash
sudo ip route del 10.0.1.0/24 via <cilium_host_ip> dev cilium_host
```

Verify packet path with tcpdump on both ends simultaneously:
```bash
# On source
sudo tcpdump -i ens5 icmp and host <destination> -c 10

# On destination (separate terminal)
sudo tcpdump -i ens5 icmp and host <source> -c 10
```

If source shows packets leaving but destination shows nothing, check routing before assuming cloud provider is dropping packets.

---

## Open Items

| Item | Status |
|------|--------|
| Resolve Cilium node subnet route injection in two-node setup | Open |
| Test Cilium AWS ENI mode as alternative to tunnel mode | Open |
| Test Calico as CNI replacement for two-node setup | Open |
| Add `ip route get` to cluster health check runbook | Pending |

---

## Known-Good Configuration (single-node)

```bash
cilium install --version 1.19.3 \
  --set routingMode=tunnel \
  --set tunnelProtocol=vxlan \
  --set autoDirectNodeRoutes=false
```

Kernel route after install on single-node (expected, not harmful):
```
10.0.1.0/24 via 192.168.x.x dev cilium_host
```

This route is harmless on a single node because there are no other nodes to reach.
