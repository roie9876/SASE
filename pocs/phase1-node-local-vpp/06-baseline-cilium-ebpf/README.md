# Scenario 06: Baseline Cilium eBPF Performance

## Purpose

Measure **native AKS Cilium eBPF** east-west throughput between two pods on different nodes — no VPP, no VXLAN, no NAT, no overlay. This provides a baseline to compare against the VPP VXLAN overlay in Scenario 05.

## Environment

- Same AKS cluster: `sase-ubuntu2404-aks` in `swedencentral`
- Same VM SKU: **Standard_D4s_v6** (4 vCPUs, MANA NIC, 12.5 Gbps allocation)
- Same node pool: `nodepool1` (vmss000001, vmss000002)
- CNI: **Cilium** (Azure CNI overlay mode, eBPF datapath)
- Pods: plain Ubuntu 22.04 with iperf3, no Multus, no macvlan, standard eth0 only

## Results

### ICMP Ping

| Metric | Cilium eBPF | VPP VXLAN (Scenario 05) |
|--------|-------------|------------------------|
| Packets | 10/10 | 10/10 |
| Loss | 0% | 0% |
| Avg RTT | **6.1 ms** | **4.7 ms** |

VPP VXLAN has slightly lower latency (4.7 ms vs 6.1 ms). Both are stable.

### TCP Single Stream

| Metric | Cilium eBPF | VPP VXLAN |
|--------|-------------|-----------|
| Throughput (sender) | **9.08 Gbps** | **1.35 Mbps** |
| Throughput (receiver) | **9.05 Gbps** | **687 Kbps** |
| Retransmits | 1,679 | 346 |

**Cilium is ~6,700x faster for TCP** because it uses the kernel's native TCP stack with hardware checksum offload. VPP VXLAN's TCP is crippled by the inner checksum issue (Bug 4).

### TCP 4 Parallel Streams

| Metric | Cilium eBPF | VPP VXLAN |
|--------|-------------|-----------|
| Throughput (sender) | **11.8 Gbps** | **5.78 Mbps** |
| Throughput (receiver) | **11.7 Gbps** | **5.01 Mbps** |
| Retransmits | 251 | 1,866 |

Cilium scales almost linearly to the NIC limit with multiple streams.

### UDP (1200-byte packets)

| Target Rate | Cilium Received | Cilium Loss | VPP VXLAN Received | VPP VXLAN Loss |
|-------------|----------------|-------------|-------------------|----------------|
| 1 Gbps | **979 Mbps** | 1.2% | **986 Mbps** | 0.008% |
| 5 Gbps | **1.35 Gbps** | 32% | **606 Mbps** | 64% |

At 1 Gbps, VPP and Cilium are almost equal (~980 Mbps). At higher rates, Cilium handles 1.35 Gbps vs VPP's 606 Mbps.

## Summary Comparison

```
Throughput comparison (higher = better):

TCP 1-stream:
  Cilium eBPF  ████████████████████████████████████████ 9,050 Mbps
  VPP VXLAN    ▏                                            1 Mbps

TCP 4-stream:
  Cilium eBPF  ████████████████████████████████████████ 11,700 Mbps
  VPP VXLAN    ▏                                            5 Mbps

UDP 1G target:
  Cilium eBPF  ████████████████████████████████████████  979 Mbps
  VPP VXLAN    ████████████████████████████████████████  986 Mbps

UDP 5G target:
  Cilium eBPF  ██████████████████████████████████████   1,350 Mbps
  VPP VXLAN    ████████████████████████                   606 Mbps
```

## Key Takeaways

1. **Cilium eBPF delivers near-wire-speed TCP** (9-12 Gbps) because it uses the kernel's native networking with hardware checksum offload, TSO/GRO, and eBPF fast-path forwarding.

2. **VPP VXLAN TCP is crippled** (~1 Mbps) due to inner TCP checksum corruption through the af_packet + macvlan + VXLAN path. This is not a VPP forwarding capacity issue — VPP can forward ~1 Gbps of UDP data.

3. **For UDP, VPP and Cilium are comparable at 1 Gbps.** Both hit ~980 Mbps. Above 1 Gbps, Cilium's kernel path handles higher rates better.

4. **The VPP performance bottlenecks are:**
   - TCP: inner checksum not recomputed → ~50% packet drop → 1 Mbps
   - UDP: af_packet v2 per-frame syscall → ~1 Gbps ceiling
   - Neither is limited by VPP's forwarding engine itself

5. **To match Cilium's throughput, VPP would need:**
   - DPDK or SR-IOV (bypass af_packet, get hardware offloads)
   - Or memif for pod-to-VPP path (bypass macvlan)
   - Or fix af_packet v3 TX ring (batch processing)

## Files

| File | Purpose |
|------|---------|
| `manifests/iperf-pods.yaml` | Test pods (client on node1, server on node2) |
