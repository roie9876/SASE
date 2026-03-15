# Scenario 06: Baseline Cilium eBPF Performance

## Purpose

Measure **native AKS Cilium eBPF** east-west throughput between two pods on different nodes — no VPP, no VXLAN, no NAT, no overlay. This provides a baseline to compare against the VPP VXLAN overlay in Scenario 05.

## Environment

- Same AKS cluster: `sase-ubuntu2404-aks` in `swedencentral`
- Same VM SKU: **Standard_D4s_v6** (4 vCPUs, MANA NIC, 12.5 Gbps allocation)
- Same node pool: `nodepool1` (vmss000001, vmss000002)
- CNI: **Cilium** (Azure CNI overlay mode, eBPF datapath)
- Pods: plain Ubuntu 22.04 with iperf3, no Multus, no macvlan, standard eth0 only

## Results — MANA (D4s_v6) vs Mellanox (D4s_v5) vs VPP VXLAN

### ICMP Ping

| Metric | MANA Cilium | Mellanox Cilium | VPP VXLAN (MANA) |
|--------|-------------|-----------------|------------------|
| Packets | 10/10 | 10/10 | 10/10 |
| Loss | 0% | 0% | 0% |
| Avg RTT | 6.1 ms | **2.95 ms** | 4.7 ms |

Mellanox has the lowest latency at ~3 ms.

### TCP Single Stream

| Metric | MANA Cilium | Mellanox Cilium | VPP VXLAN (MANA) |
|--------|-------------|-----------------|------------------|
| Throughput (sender) | 9.08 Gbps | **9.80 Gbps** | 1.35 Mbps |
| Throughput (receiver) | 9.05 Gbps | **9.80 Gbps** | 687 Kbps |
| Retransmits | 1,679 | 2,501 | 346 |

Both MANA and Mellanox deliver ~10 Gbps for native Cilium TCP.

### TCP 4 Parallel Streams

| Metric | MANA Cilium | Mellanox Cilium | VPP VXLAN (MANA) |
|--------|-------------|-----------------|------------------|
| Throughput (sender) | **11.8 Gbps** | 11.2 Gbps | 5.78 Mbps |
| Throughput (receiver) | **11.7 Gbps** | **11.1 Gbps** | 5.01 Mbps |
| Retransmits | 251 | 16,776 | 1,866 |

Both NICs hit ~11-12 Gbps with 4 streams. Mellanox has more retransmits but same throughput.

### UDP (1200-byte packets)

| Target Rate | MANA Cilium Recv | MANA Loss | Mellanox Cilium Recv | Mellanox Loss | VPP VXLAN Recv | VPP Loss |
|-------------|-----------------|-----------|---------------------|---------------|----------------|----------|
| 1 Gbps | 979 Mbps | 1.2% | **996 Mbps** | 0.008% | 986 Mbps | 0.008% |
| 5 Gbps | 1.35 Gbps | 32% | — | — | 606 Mbps | 64% |
| 1 Gbps | **979 Mbps** | 1.2% | **986 Mbps** | 0.008% |
| 5 Gbps | **1.35 Gbps** | 32% | **606 Mbps** | 64% |

At 1 Gbps, VPP and Cilium are almost equal (~980 Mbps). At higher rates, Cilium handles 1.35 Gbps vs VPP's 606 Mbps.

## Summary Comparison

```
TCP 1-stream throughput (higher = better):

  Mellanox Cilium  ████████████████████████████████████████  9,800 Mbps
  MANA Cilium      ████████████████████████████████████████  9,050 Mbps
  VPP VXLAN (MANA) ▏                                            1 Mbps

TCP 4-stream throughput:

  MANA Cilium      ████████████████████████████████████████ 11,700 Mbps
  Mellanox Cilium  ████████████████████████████████████████ 11,100 Mbps
  VPP VXLAN (MANA) ▏                                            5 Mbps

UDP 1G (received):

  Mellanox Cilium  ████████████████████████████████████████    996 Mbps
  VPP VXLAN (MANA) ████████████████████████████████████████    986 Mbps
  MANA Cilium      ████████████████████████████████████████    979 Mbps

Ping latency (lower = better):

  Mellanox Cilium  ██████                                    2.95 ms
  VPP VXLAN (MANA) █████████                                4.70 ms
  MANA Cilium      ████████████                             6.10 ms
```

### MANA vs Mellanox — For Cilium (No VPP)

Both NICs deliver **comparable throughput** (~10-12 Gbps TCP). Mellanox has:
- **2x lower latency** (2.95 ms vs 6.1 ms)
- **Better UDP delivery** (0.008% vs 1.2% loss at 1 Gbps)
- **More retransmits at high load** (16K vs 251 for 4-stream TCP — but same throughput)

For native Cilium eBPF workloads, both NICs are equally capable. The latency difference may matter for real-time traffic.

### MANA vs Mellanox — For VPP

This is where Mellanox wins decisively:
- **af_packet TX works on Mellanox** (broken on MANA)
- **SR-IOV VF passthrough** available for DPDK (not available on MANA v6)
- **DPDK mlx5 driver** is mature and battle-tested (MANA DPDK driver fails at `ibv_create_cq`)

For a VPP-based SASE deployment, **D4s_v5 (Mellanox) is the right choice**.

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
