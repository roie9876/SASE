# East-West Debug Report

This note captures the worker-to-worker east-west debugging for Phase 1B.

It is intentionally separate from the main scenario README so the validated same-node baseline and the blocked cross-node path do not get mixed together.

## Scope

Test goal:

- send traffic from `phase1-service-a` on Node 1 to `phase1-service-b` on Node 2
- keep Azure-visible traffic on `eth1` as outer VXLAN
- use VPP as the forwarding point on both nodes

Test nodes:

- Node 1: `aks-nodepool1-38799324-vmss000001`
- Node 2: `aks-nodepool1-38799324-vmss000002`

## Addressing

Azure underlay addresses:

- Node 1 `eth0`: `10.120.2.4`
- Node 1 `eth1`: `10.120.3.4`
- Node 2 `eth0`: `10.120.2.5`
- Node 2 `eth1`: `10.120.3.5`
- branch VM `eth0`: `10.120.4.4`

Service dataplane addresses:

- Node 1 VPP gateway `host-dp0`: `10.20.0.254/16`
- Node 1 service pod `net1`: `10.20.1.20/16`
- Node 2 VPP gateway `host-dp0`: `10.21.0.254/16`
- Node 2 service pod `net1`: `10.21.1.20/16`

Inter-node overlay addresses used during debugging:

- Node 1 `host-vxlan200`: `10.60.0.1/30`
- Node 2 `host-vxlan200`: `10.60.0.2/30`

## What Was Proven

Working pieces:

- two-worker AKS cluster is healthy
- second forwarding NIC exists on the new worker
- underlay reachability over forwarding NICs `10.120.3.4 <-> 10.120.3.5` is good
- Node 1 local pod to local VPP gateway is good
- Node 2 local pod to local VPP gateway is good
- service pods route remote subnet traffic toward local VPP gateway on `net1`

Validated local checks:

- `phase1-service-a -> 10.20.0.254`: pass
- `phase1-service-b -> 10.21.0.254`: pass

## Host-Interface VXLAN Attempt

Initial worker-to-worker approach:

- Linux `vxlan200` created on top of node `eth1`
- VPP connected to Linux `vxlan200` using `host-vxlan200`
- remote service subnet routed through `host-vxlan200`

Key findings:

1. Without a static VPP neighbor for `10.60.0.2`, the packet died in `ip4-arp` on Node 1.
2. After adding the static VPP neighbor, the packet progressed much further inside VPP.
3. Node 1 VPP packet trace showed this path:
   - `af-packet-input`
   - `ethernet-input`
   - `ip4-input`
   - `ip4-lookup`
   - `ip4-rewrite`
   - `host-vxlan200-output`
   - `host-vxlan200-tx`
4. Even after that, Linux never observed the packet.

Observed evidence after static neighbor fix:

- VPP `host-vxlan200` TX counter increased on Node 1
- VPP packet trace reached `host-vxlan200-tx`
- Linux `tcpdump` on Node 1 `vxlan200`: `0 packets`
- Linux `tcpdump` on Node 1 `eth1`: `0 packets`
- Linux `tcpdump` on Node 2 `vxlan200`: `0 packets`
- Linux `tcpdump` on Node 2 `eth1`: `0 packets`
- Linux counters on `vxlan200` and `eth1` did not move during the east-west ping burst

Conclusion for this path:

- the packet dies after VPP `host-vxlan200-tx`
- the packet never becomes a Linux `vxlan200` packet
- nothing is emitted on `eth1`
- this is not currently an Azure routing or Azure NIC forwarding problem
- this is a broken boundary between VPP `af_packet` host-interface transmit and the Linux `vxlan` device path

## Native VPP VXLAN Attempt

Follow-up approach:

- enable `vxlan_plugin.so`
- create native `vxlan_tunnel200` in VPP using `host-eth1` as the underlay-facing interface
- route remote service subnet through the native VPP tunnel

What worked:

- native VPP VXLAN CLI became available
- `create vxlan tunnel src 10.120.3.4 dst 10.120.3.5 vni 200 ... l3` succeeded
- `show vxlan tunnel` confirmed tunnel objects on both nodes

What failed:

- first `VPP1 -> VPP2` ping over the native tunnel caused Node 1 VPP to crash
- crash was `SIGSEGV` in `ip4_glean_node_fn`
- `tcpdump` still showed `0` UDP packets on `eth1` during the failed attempt

Conclusion for this path:

- moving VXLAN ownership into VPP is architecturally more correct than the Linux `vxlan200` handoff
- but in this runtime and host-interface combination, the native VPP VXLAN path is not stable enough to use

## Current Engineering Conclusion

The current evidence points to the following:

- same-node north-south path is valid and measured
- cross-node east-west is blocked by the current node-local dataplane integration model
- the broken point is not service pod routing, not Azure underlay reachability, and not the existence of the second NIC
- the weak point is the current VPP-to-host-network integration used for worker-to-worker transport on `eth1`

## Options Before Adopting A CNI On `eth1`

These are the realistic non-CNI options to try before introducing a full VPP-oriented CNI on the forwarding NIC.

### Option 1: Fix The Current Host-Interface Model

Keep:

- Multus or macvlan for pod dataplane attachment
- Linux `vxlan200` on `eth1`
- VPP `host-vxlan200`

Needed work:

- root-cause why `host-vxlan200-tx` never appears on Linux `vxlan200`
- verify whether this is a VPP `af_packet` limitation or bug with Linux `vxlan`
- potentially reduce the model to a minimal reproducer outside AKS

Why it may not be worth it:

- strong evidence already shows the boundary is broken
- further effort may only prove a VPP or kernel integration bug without moving the POC forward

### Option 2: Use Native VPP Transport Without A New CNI

Keep the current pod model for now, but move inter-node transport fully into VPP.

Examples:

- native VPP VXLAN once the current crash is understood or avoided
- another VPP-native tunnel mechanism that can use `host-eth1` more safely

Why it is attractive:

- VPP owns the transport instead of Linux
- closer to the intended architecture

Current risk:

- native VPP VXLAN already crashed in this build

### Option 3: Move The Pod-Facing Side Closer To VPP Without A Full CNI

Instead of only changing transport, change how pods connect to VPP.

Examples:

- TAP between VPP and pod namespaces
- veth or memif-style lab wiring for a smaller proof

Why it may help:

- reduces dependence on the current `macvlan + host-interface` combination
- gives VPP clearer ownership of ingress and egress

Tradeoff:

- more custom plumbing than the current simple Multus path

### Option 4: Put The Data NIC More Directly Under VPP Control

Keep AKS and keep the separate management NIC, but reduce Linux ownership of `eth1`.

Examples:

- dedicate `eth1` to VPP or DPDK more directly
- keep host management only on `eth0`

Why it may help:

- closer to the Contiv/VPP multi-NIC node model
- fewer host-network translation points in the dataplane

Tradeoff:

- more invasive node handling
- more operational risk on managed AKS workers

## Most Practical Next Step

Before adopting a full CNI on `eth1`, the best next technical step is likely:

1. build a smaller VPP-owned inter-node transport experiment on `eth1`
2. keep `eth0` as the AKS management path
3. avoid the current Linux `vxlan200` handoff entirely
4. only move to a Contiv/VPP-like CNI track if that smaller VPP-owned transport still proves too fragile

If that smaller experiment still fails, the case for a Contiv/VPP-style node model becomes much stronger.