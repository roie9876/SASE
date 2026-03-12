# Experiment: D4s_v5 Mellanox + VPP af-packet

## Summary

This was the original **working functional POC**.

Its purpose was to prove the SASE traffic flow and tenant-isolation design in AKS, not to prove production-grade DPDK throughput.

The key point is:

- **This scenario worked using VPP af-packet**.
- **This scenario did not prove native DPDK kernel bypass**.

## Topology

### Platform

- AKS node type: `Standard_D4s_v5`
- NIC family: Mellanox ConnectX VF in Azure Accelerated Networking
- Pod model: privileged VPP pod + client pod pinned to the same node
- Branch side: external Azure VM acting as branch / SD-WAN edge

### Packet Path

Branch VM -> VXLAN over Azure underlay -> Linux `vxlan100` in VPP pod -> VPP `af-packet` host interface -> SRv6 localsid / VRF routing in VPP -> macvlan-attached client pod

### Why af-packet Was Used

The Mellanox path in AKS ran into structural blockers for native DPDK in pods:

- no practical second VF allocation for a dedicated DPDK interface
- conflict between the primary pod NIC and Mellanox bifurcated driver expectations
- no clean AKS-supported SR-IOV device-plugin path for this use case

So the working configuration used Linux interfaces plus `af-packet` into VPP.

## What Was Tested

1. Same-node Multus macvlan connectivity between VPP and client pod
2. Linux VXLAN tunnel between branch VM and VPP pod
3. SRv6 encapsulation inside VXLAN
4. VPP `End.DT4` localsid processing for multi-tenant routing
5. End-to-end ICMP
6. UDP `iperf3`

## What Worked

### Functional Routing and Overlay

- VXLAN overlay with UDP port `8472`
- SRv6 traffic carried inside VXLAN
- VPP VRF isolation using different SIDs per tenant
- End-to-end ICMP through the full path

### Proven Results

- ICMP over VXLAN: working
- ICMP over SRv6-in-VXLAN: working
- UDP `iperf3` at `100 Mbps`: working
- VPP SRv6 localsid counters: incrementing correctly

## What Did Not Work

- Native DPDK dataplane on Mellanox in this AKS setup
- TCP `iperf3` in the af-packet topology due to checksum/offload limitations
- Native SRv6 through Azure fabric without encapsulation
- L2 macvlan across different nodes

## Performance Interpretation

This scenario demonstrated **correctness**, not peak performance.

The measured throughput that was cleanly demonstrated was around:

- UDP `iperf3`: `100 Mbps`

That result is useful as proof that the topology and routing logic work, but it should **not** be presented as the target performance of a production SASE dataplane.

## What This Scenario Proves

This scenario proves:

- AKS can host the SASE control/data-path logic in a functional form
- VXLAN can be used as the Azure-friendly underlay wrapper
- SRv6 logic in VPP can still be demonstrated when SRH is encapsulated
- tenant separation by SID -> VRF mapping works

It does **not** prove:

- carrier-grade packet rate
- native kernel-bypass forwarding in AKS pods
- production throughput numbers for Check Point's target architecture

## Current Status

Status: **working as a functional POC**

Best way to describe it:

"The D4s_v5 Mellanox scenario validated the SASE topology and routing behavior using VPP af-packet, but it was not a native DPDK dataplane success."