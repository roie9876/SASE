# POC Experiment Index

This directory separates the major POC tracks that were previously mixed together in the main POC document.

Use this index when you want to answer four questions quickly for each scenario:

1. What topology was used?
2. What exactly was tested?
3. What worked?
4. What did not work?

## Experiment List

### 1. D4s_v5 Mellanox + VPP af-packet

File: [d4sv5-mellanox-afpacket.md](./d4sv5-mellanox-afpacket.md)

Use this page for the original functional SASE POC on `Standard_D4s_v5`.

- Main goal: prove the end-to-end SASE data path and multi-tenant routing logic.
- Data path used: **VPP af-packet**, not native DPDK dataplane.
- Proven results: VXLAN, SRv6-in-VXLAN, VRF isolation, ICMP, and UDP `iperf3` at 100 Mbps.
- Important limitation: this was a **functional topology demo**, not a high-throughput kernel-bypass dataplane success.

### 2. D4s_v6 MANA + Native DPDK

File: [d4sv6-mana-dpdk.md](./d4sv6-mana-dpdk.md)

Use this page for the Azure MANA kernel-bypass investigation.

- Main goal: prove native DPDK on AKS using Azure MANA.
- Proven results: Ubuntu 24.04 + kernel 6.8 + `rdma-core` v46 + DPDK `net_mana` + `dpdk-testpmd`.
- Important limitation: VPP over native MANA is still not working reliably.

### 3. Native SRv6 Through Azure Fabric

File: [native-srv6-azure-fabric.md](./native-srv6-azure-fabric.md)

Use this page for the test that checked whether Azure passes IPv6 SRH packets natively.

- Main goal: determine whether Azure SDN passes IPv6 packets with Segment Routing Header.
- Proven result: plain IPv6 works.
- Proven limitation: IPv6 packets carrying SRH were dropped by the Azure fabric in this test.

## Recommended Reading Order

1. Read [d4sv5-mellanox-afpacket.md](./d4sv5-mellanox-afpacket.md) to understand the working functional SASE topology.
2. Read [d4sv6-mana-dpdk.md](./d4sv6-mana-dpdk.md) to understand the kernel-bypass investigation.
3. Read [native-srv6-azure-fabric.md](./native-srv6-azure-fabric.md) to understand why VXLAN encapsulation was needed for SRv6 traffic.

## High-Level Status Matrix

| Scenario | Topology Goal | Data Plane | Status |
|---|---|---|---|
| D4s_v5 Mellanox functional POC | End-to-end SASE path demo | VPP af-packet | Works |
| D4s_v6 MANA native DPDK | Kernel-bypass validation on AKS | DPDK `net_mana` | DPDK works |
| D4s_v6 MANA native VPP | VPP on top of MANA DPDK | VPP DPDK plugin | Not working yet |
| Native SRv6 in Azure fabric | Pass IPv6 SRH without overlay | Azure fabric | Not working |