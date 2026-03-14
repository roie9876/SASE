# Phase 1 POC: East-West VXLAN Without NAT on MANA AKS

## Overview

This POC demonstrates **east-west service-to-service traffic** across two AKS worker nodes, forwarded entirely through **VPP native VXLAN tunnels** — no Linux VXLAN, no NAT (SNAT is only applied to the outer underlay header to fix Cilium masquerade, inner packets are untouched).

**Proven result:** ICMP ping works bidirectionally, 0% loss, ~5ms RTT.  
**Known gap:** TCP bulk transfer (iperf3) stalls after handshake — under investigation.

---

## Lab Environment

| Resource | Value |
|----------|-------|
| AKS Cluster | `sase-ubuntu2404-aks` |
| Region | `swedencentral` |
| Resource Group | `SASE-POC-LAB-RG` |
| Node Pool `nodepool1` | 2× Standard_D4s_v6 (MANA NIC) |
| Node Pool `mellanoxpool` | 1× Standard_D4s_v5 (Mellanox NIC, not used for E-W) |
| CNI | Cilium (Azure CNI overlay) |
| VPP Version | v26.02-release |

### Nodes

| Name | Role | VM Size | NIC Type | eth0 (mgmt) | eth1 (dataplane) |
|------|------|---------|----------|-------------|-----------------|
| vmss000001 (node1) | VPP worker | D4s_v6 | MANA | 10.120.2.4 | 10.120.3.4 |
| vmss000002 (node2) | VPP worker | D4s_v6 | MANA | 10.120.2.5 | 10.120.3.5 |

### Pods

| Pod | Node | Type | eth0 IP (AKS mgmt) | net1 IP (dataplane) |
|-----|------|------|---------------------|---------------------|
| phase1-vpp | node1 | hostNetwork, privileged | 10.120.2.4 | — |
| phase1-vpp-node2 | node2 | hostNetwork, privileged | 10.120.2.5 | — |
| phase1-service-a | node1 | normal + Multus net1 | 10.246.0.95 | 10.20.1.20 |
| phase1-service-b | node2 | normal + Multus net1 | 10.246.1.223 | 10.21.1.20 |

---

## Architecture

### The Problem

VPP's `af_packet` TX on **MANA virtual NICs does not transmit frames**. VPP increments its TX counter, but tcpdump on the Linux side shows zero packets. af_packet RX works fine on MANA. This is a MANA-specific driver limitation.

### The Solution: Hybrid TX/RX Model

```
┌──────────────────────────────── KUBERNETES NODE (D4s_v6 / MANA) ─────────────────────────────────┐
│                                                                                                   │
│  ┌─── SASE Service Pod ────┐         ┌──── Management Pods ────┐                                 │
│  │                          │         │  CoreDNS, kube-proxy,   │                                 │
│  │  eth0 ─── AKS mgmt      │         │  Cilium agent, etc.     │                                 │
│  │  (10.246.0.95)           │         └──────────┬──────────────┘                                 │
│  │                          │                    │                                                │
│  │  net1 ─── dataplane      │                    │ eth0 (AKS CNI)                                │
│  │  (10.20.1.20/16)         │                    │                                                │
│  │  macvlan child on eth1   │                    ▼                                                │
│  └──────────┬───────────────┘         ┌──── Cilium CNI ─────────┐                                │
│             │ L2 frames               │  BPF on eth0            │                                │
│             ▼                         │  BPF REMOVED from eth1  │                                │
│  ┌──── dp0 (macvlan bridge) ───┐      └──────────┬──────────────┘                                │
│  │  parent on eth1             │                 │                                                │
│  │  MTU 3900                   │                 │                                                │
│  │  offloads: tx/rx OFF        │                 │                                                │
│  └──────────┬──────────────────┘                 │                                                │
│             │ af_packet RX/TX (v3)               │                                                │
│  ╔══════════╪══════════════════════════════ VPP POD (hostNetwork) ═══╗                            │
│  ║          ▼                                                        ║                            │
│  ║  ┌─ host-dp0 ──────────┐     ┌─ vxlan_tunnel200 ──────────────┐  ║                            │
│  ║  │  af_packet on dp0    │     │  VPP native VXLAN              │  ║                            │
│  ║  │  10.20.0.254/16      │     │  VNI 200, encap-vrf-id 0      │  ║                            │
│  ║  │  pod gateway         │────►│  src=10.120.3.4                │  ║                            │
│  ║  │  GSO feature ON      │     │  dst=10.120.3.5                │  ║                            │
│  ║  └──────────────────────┘     │  10.60.0.1/30                 │  ║                            │
│  ║          ▲ decapped           └──────────┬────────────────────┘  ║                            │
│  ║          │ inner pkts                    │ VXLAN encap           ║                            │
│  ║          │                               ▼                       ║                            │
│  ║  ┌─ host-eth1 ─────────┐     ┌─ host-vpp-ul0 ────────────────┐  ║  ┌─ host-vxlan100 ──────┐ ║
│  ║  │  af_packet on eth1   │     │  af_packet V2 on vpp-ul0      │  ║  │  af_packet on vxlan100│ ║
│  ║  │  10.120.3.4/24       │     │  172.16.200.2/30              │  ║  │  10.50.0.1/30         │ ║
│  ║  │  RX only (TX broken) │     │  TX path (sendto per-frame)   │  ║  │  fc00::1/64           │ ║
│  ║  │  ip4-vxlan-bypass ON │     │  GSO feature ON               │  ║  │  SRv6 localsid        │ ║
│  ║  └──────────┬───────────┘     └──────────┬────────────────────┘  ║  │  (N-S branch only)    │ ║
│  ╚═════════════╪════════════════════════════╪════════════════════════╝  └──────────┬────────────┘ │
│                │ af_packet RX               │ af_packet v2 TX                     │              │
│  ┌─────────────┼────────────────────────────┼─────────────── Linux Kernel ────────┼──────────┐   │
│  │             │                            ▼                                     │          │   │
│  │             │                 ┌── vpp-ul0 ◄══veth══► linux-ul0 ──┐             │          │   │
│  │             │                 │  (VPP side)          (Linux side) │             │          │   │
│  │             │                 │  MTU 3900            172.16.200.1 │             │          │   │
│  │             │                 │  tx-checksum ON      ip_forward=1│             │          │   │
│  │             │                 └──────────────────────────┬───────┘             │          │   │
│  │             │                                            │                     │          │   │
│  │             │                          Linux ip_forward  │ route → table 100   │          │   │
│  │             │                                            ▼                     │          │   │
│  │             │                            ┌── nft early-postrouting ──┐          │          │   │
│  │             │                            │  priority: srcnat - 1     │          │          │   │
│  │             │                            │  SNAT UDP/4789            │          │          │   │
│  │             │                            │  → src 10.120.3.4        │          │          │   │
│  │             │                            │  conntrack_checksum=0     │          │          │   │
│  │             │                            └────────────┬─────────────┘          │          │   │
│  │             │                                         │                        │          │   │
│  └─────────────┼─────────────────────────────────────────┼────────────────────────┼──────────┘   │
│                │                                         │                        │              │
│  ┌─────────────▼─────────────────────────────────────────▼────────────────────────▼──────────┐   │
│  │                                                                                           │   │
│  │  eth1 (dpdk-nic / MANA)                              eth0 (primary / MANA)               │   │
│  │  IP removed from Linux (VPP owns)                    10.120.2.4                           │   │
│  │  MTU 3900                                            MTU 1500                             │   │
│  │  Static ARP: 10.120.3.5 → 7c:ed:8d:9d:9c:0c        AKS management                      │   │
│  │  ⚠ af_packet TX broken on MANA                      Cilium BPF active                    │   │
│  │  ✓ af_packet RX works                                                                     │   │
│  └──────────┬───────────────────────────────────────────────────────────────────┬────────────┘   │
│             │                                                                   │                │
└─────────────┼───────────────────────────────────────────────────────────────────┼────────────────┘
              │ Data Interface                                                    │ Mgmt Interface
              ▼                                                                   ▼
┌─────────────────────────────────── Azure SDN ──────────────────────────────────────────────┐
│  10.120.3.0/24 (dataplane subnet)              10.120.2.0/24 (management subnet)          │
│  → Remote node eth1: 10.120.3.5                → Remote node eth0: 10.120.2.5             │
│  → Branch VM: 10.120.4.4                       → AKS API server                           │
│  MTU up to 4000                                                                            │
└────────────────────────────────────────────────────────────────────────────────────────────┘
```

### Data Path — East-West Packet Flow

**Outbound (service-a → service-b):**

1. `service-a` sends ICMP to `10.21.1.20` via `net1` (macvlan on eth1)
2. Packet arrives at `host-dp0` in VPP (gateway `10.20.0.254`)
3. VPP `ip4-lookup`: destination `10.21.0.0/16` → via `vxlan_tunnel200`
4. `vxlan4-encap`: wraps inner packet in VXLAN (VNI 200), outer src=`10.120.3.4`, dst=`10.120.3.5`
5. VPP resolves dst `10.120.3.5` via `/32` route → next-hop `172.16.200.1` on `host-vpp-ul0`
6. `af_packet` TX on `host-vpp-ul0` → delivered to Linux `linux-ul0` (veth peer)
7. Linux `ip_forward` routes to `10.120.3.5` via `eth1` (static ARP entry)
8. `nft early-postrouting`: SNAT rewrites outer src from `172.16.200.2` → `10.120.3.4`
9. Frame exits `eth1` with correct source IP

**Inbound (node2 → service-b):**

1. VXLAN frame arrives on `eth1` (dst MAC matches)
2. `af_packet` RX delivers to VPP `host-eth1`
3. `ip4-vxlan-bypass` intercepts UDP/4789, sends directly to `vxlan4-input`
4. `vxlan4-input`: hash lookup matches (src=`10.120.3.4`, dst=`10.120.3.5`, VNI=200, fib-idx=0)
5. Inner ICMP extracted, forwarded via `host-dp0` → `service-b` on `10.21.1.20`

---

## Every Interface Explained

### Linux Interfaces (created by setup script)

| Interface | Type | IP | MTU | Purpose |
|-----------|------|-----|-----|---------|
| `eth0` | Azure primary NIC | 10.120.2.x | 1500 | AKS management. **Never touch.** |
| `eth1` | Azure secondary NIC (dpdk-nic) | *removed* | 3900 | Dataplane underlay. IP removed so VPP owns it. |
| `vpp-ul0` | veth (VPP side) | — | 3900 | VPP af_packet TX endpoint. VPP sends VXLAN here. |
| `linux-ul0` | veth (Linux side) | 172.16.x00.1/30 | 3900 | Linux receives from VPP, forwards to eth1. |
| `dp0` | macvlan (bridge) on eth1 | — | 3900 | Service pod's net1 parent. VPP attaches via af_packet. |
| `vxlan100` | Linux VXLAN (node1 only) | — | 1450 | Branch-facing VXLAN (N-S path, not E-W). |

### VPP Interfaces

| Interface | VPP Name | IP | Purpose |
|-----------|----------|-----|---------|
| `host-eth1` | af_packet on eth1 | 10.120.3.x/24 | **RX only.** Receives incoming VXLAN from remote node. af_packet TX is broken on MANA. |
| `host-dp0` | af_packet on dp0 | 10.20.0.254/16 or 10.21.0.254/16 | Pod dataplane gateway. Service pods route via this. |
| `host-vpp-ul0` | af_packet on vpp-ul0 | 172.16.x00.2/30 | **TX only.** Sends VXLAN-encapped frames to Linux for forwarding. |
| `host-vxlan100` | af_packet on vxlan100 (node1) | 10.50.0.1/30 + fc00::1/64 | Branch N-S tunnel (SRv6 localsid). |
| `vxlan_tunnel200` | VPP native VXLAN | 10.60.0.x/30 | E-W overlay tunnel between node1 and node2. |

### Why Each Interface Exists

- **`host-eth1` (RX only):** af_packet RX works on MANA. This catches incoming VXLAN frames from the wire. `ip4-vxlan-bypass` is enabled so VXLAN frames skip `ip4-local` (which would fail uRPF check).

- **`host-vpp-ul0` (TX via veth):** af_packet TX is broken on MANA eth1, but works on veth. VPP sends VXLAN-encapped frames here. Linux kernel forwards them from `linux-ul0` → `eth1`.

- **`host-dp0` (pod dataplane):** macvlan on eth1 in bridge mode. Service pods with Multus `net1` get a child macvlan that shares this parent. VPP acts as the gateway (10.20.0.254 or 10.21.0.254).

- **`vxlan_tunnel200` (native VPP VXLAN):** E-W overlay. Uses real underlay IPs (10.120.3.x) as src/dst. `encap-vrf-id 0` is critical — VPP's decap hash includes fib_index, so encap VRF must match the incoming interface's VRF.

---

## Every Route Explained

### VPP Routes (node1)

| Destination | Via | Interface | Purpose |
|-------------|-----|-----------|---------|
| 10.120.3.5/32 | 172.16.200.1 | host-vpp-ul0 | TX path to remote node via veth |
| 10.21.0.0/16 | 10.60.0.2 | vxlan_tunnel200 | Remote pod subnet via VXLAN overlay |
| 10.20.0.0/16 | connected | host-dp0 | Local pod subnet |
| 10.120.3.0/24 | connected | host-eth1 | Underlay subnet |
| 172.16.200.0/30 | connected | host-vpp-ul0 | Veth link subnet |
| 10.60.0.0/30 | connected | vxlan_tunnel200 | Overlay p2p |

### Linux Routes (node1)

| Destination | Via | Device | Table | Purpose |
|-------------|-----|--------|-------|---------|
| 10.120.3.5/32 | — | eth1 | main | Static route for forwarding VXLAN to remote node |
| 10.120.3.x/32 | — | eth1 | 100 | Policy routing for branch VXLAN (node1 only) |
| default | 10.120.3.1 | eth1 | 100 | Default route in policy table (node1 only) |

### Linux Policy Rules (node1)

| Rule | Purpose |
|------|---------|
| `from 10.120.3.4/32 table 100` | Routes branch VXLAN return traffic via eth1 |

---

## Four Bugs Fixed

### Bug 1: VPP VXLAN decap hash includes `encap_fib_index`

**Problem:** VPP v26.02's VXLAN decap lookup uses a hash key that includes `fib_index` from the incoming packet's interface. If you create the tunnel with `encap-vrf-id 1`, the hash stores `fib_index=1`, but incoming packets arrive on `host-eth1` which is in VRF 0 → hash lookup fails → "no such tunnel" error.

**Root cause code:** `vxlan.c` line: `key4.key[1] = ((u64)a->encap_fib_index << 32) | ...`  
`decap.c` line: `u32 fi = vlib_buffer_get_ip_fib_index(b, is_ip4)` — returns the incoming interface's VRF.

**Fix:** Always use `encap-vrf-id 0`.

### Bug 2: Cilium eBPF masquerades VXLAN source IP

**Problem:** Cilium attaches `cil_to_netdev-eth1` BPF program on eth1's TC egress. This rewrites the VXLAN outer source IP from `10.120.3.4` (eth1) to `10.120.2.4` (eth0/mgmt). The remote node can't match the incoming packet to its tunnel.

**Fix:**
1. `tc filter del dev eth1 egress` — removes the Cilium BPF
2. `nft add chain ip nat early-postrouting { type nat hook postrouting priority srcnat - 1 }` — adds a pre-Cilium SNAT chain
3. `nft add rule ... oif eth1 udp dport 4789 snat to 10.120.3.x` — explicitly preserves the correct source IP

*Note: Kube IP-MASQ-AGENT periodically rewrites nft chains, so our chain must be at a separate priority.*

### Bug 3: uRPF fails for incoming VXLAN on host-eth1

**Problem:** VPP's `ip4-local` node performs a uRPF (unicast Reverse Path Forwarding) check. The `/32` route to the remote node goes via `host-vpp-ul0` (veth), so when VXLAN arrives on `host-eth1`, the source IP `10.120.3.5` resolves to the wrong interface → "ip4 source lookup miss" → packet dropped.

**Fix:** `set interface ip vxlan-bypass host-eth1` — this enables the `ip4-vxlan-bypass` feature on host-eth1. For UDP/4789 packets, VPP shortcuts directly to `vxlan4-input`, completely bypassing `ip4-local` and its uRPF check. This is safe because Azure's fabric already filters spoofed packets.

### Bug 4: VPP outer IP checksum wrong with af_packet v2

**Problem:** VPP VXLAN encap computes the outer IP header checksum. Then `ip4-rewrite` decrements the TTL from 254→253 but does **not** recompute the checksum — it relies on hardware checksum offload. However, af_packet v2 does not set the `VIRTIO_NET_HDR_F_NEEDS_CSUM` flag, so the kernel doesn't fix it either. The packet arrives at the remote node with a **bad IP header checksum** and gets silently dropped.

Additionally, af_packet **v3** (TPACKET_V3) has a TX ring flush bug in VPP v26.02 — the `request` counter increments but `sending` stays at 0. Frames are written to the ring but the kernel never sends them.

**Fix:**
1. Use af_packet v2: `create host-interface v2 name vpp-ul0` — v2 uses `sendto()` per-frame which works reliably
2. Enable GSO feature: `set interface feature gso host-vpp-ul0 enable` — the GSO feature arc fixes IP checksums before TX
3. Also enable on dp0: `set interface feature gso host-dp0 enable` — fixes inner checksums too

---

## Manual Step-by-Step Deployment

### Prerequisites

- AKS cluster with 2 nodes in `nodepool1` (Standard_D4s_v6, MANA NICs)
- Secondary NIC (`dpdk-nic` / eth1) attached to both nodes on subnet `10.120.3.0/24`
- IP forwarding enabled on the secondary NIC: `az vmss update --set networkInterfaceConfigurations[1].enableIPForwarding=true`
- VPP v26.02 built and available in the pod image
- Service pods with Multus `net1` macvlan + static IPs
- VPP pods: `hostNetwork: true`, `privileged: true`

### Step 1: Deploy VPP Pods and Service Pods

Deploy the manifests (hostNetwork VPP pods + Multus-attached service pods). Verify all pods are Running.

### Step 2: Run Setup Script

**Node 1:**
```bash
kubectl cp setup-node-nonat.sh phase1-vpp:/tmp/setup-node-nonat.sh
kubectl exec phase1-vpp -- bash /tmp/setup-node-nonat.sh
```

**Node 2:**
```bash
kubectl cp setup-node-nonat.sh phase1-vpp-node2:/tmp/setup-node-nonat.sh
kubectl exec phase1-vpp-node2 -- bash /tmp/setup-node-nonat.sh \
  10.120.3.5 10.120.3.4 7c:ed:8d:25:e4:4d \
  10.21.0.0/16 10.21.0.254 10.20.0.0/16 \
  10.120.4.4 172.16.201 no
```

### Step 3: Verify

```bash
# Ping test
kubectl exec phase1-service-a -- ping -c 5 -W 3 -I net1 10.21.1.20
kubectl exec phase1-service-b -- ping -c 5 -W 3 -I net1 10.20.1.20

# Check VPP
kubectl exec phase1-vpp -- vppctl show interface address
kubectl exec phase1-vpp -- vppctl show vxlan tunnel
kubectl exec phase1-vpp -- vppctl show error | grep -v "^ *0 "
```

---

## What the Setup Script Does (Line by Line)

### Phase 1: Linux Preparation

1. **Kill existing VPP** — `pkill -9 -f "vpp -c"`
2. **Clean old interfaces** — delete vpp-ul0, linux-ul0, dp0, vxlan100
3. **Configure eth1** — set MTU 3900, remove IP (VPP will own it)
4. **Create veth pair** — `vpp-ul0 <-> linux-ul0`, MTU 3900. VPP TX goes through veth because af_packet TX is broken on MANA eth1.
5. **Create macvlan** — `dp0` on eth1 in bridge mode. Service pods' `net1` is a child macvlan.
6. **Disable offloads** — TSO/GSO/GRO off on eth1 and dp0 (required for af_packet correctness)
7. **Enable forwarding** — `ip_forward=1`, `rp_filter=0` on linux-ul0 and eth1
8. **Static ARP** — `ip neigh replace` for remote node on eth1 (eth1 has no IP, can't ARP)
9. **Remove Cilium BPF** — `tc filter del dev eth1 egress`
10. **Add SNAT chain** — nft `early-postrouting` at priority `srcnat - 1`; rewrites outer src IP for VXLAN
11. **Policy routing** (node1 only) — `ip rule` + table 100 for branch VXLAN return traffic
12. **Branch VXLAN** (node1 only) — Linux vxlan100 for branch VM connection

### Phase 2: VPP Configuration

13. **Write startup.conf** — af_packet, ping, vxlan plugins enabled; DPDK disabled
14. **Start VPP** — background process, wait for CLI socket
15. **Create af_packet interfaces** — host-eth1, host-dp0, host-vpp-ul0
16. **Assign IPs** — eth1 gets underlay IP, dp0 gets pod gateway, vpp-ul0 gets veth IP
17. **Enable vxlan-bypass** — `set interface ip vxlan-bypass host-eth1` (Bug 3 fix)
18. **Add routes** — `/32` to remote node via veth, `/16` to remote pod subnet via VXLAN
19. **Create VXLAN tunnel** — `encap-vrf-id 0` (Bug 1 fix), VNI 200
20. **SRv6 localsid** (node1 only) — `end.dt4` for branch N-S traffic

---

## Throughput Testing

### Test Environment

- **VM Size:** Standard_D4s_v6 (4 vCPUs, MANA NIC)
- **Azure NIC bandwidth allocation:** 12,500 Mbps (12.5 Gbps)
- **VPP:** v26.02-release, af_packet v2, VXLAN native
- **Inner MTU:** 1400 on net1 (macvlan), 3900 on eth1/veth
- **iperf3 UDP packet size:** 1200 bytes

### Baseline: Raw NIC Capacity (no VPP)

Linux TCP between node1 eth0 and node2 eth0 — direct kernel networking, no VPP, no VXLAN.

| Metric | Value |
|--------|-------|
| Throughput | **12.2 Gbps** |
| Retransmits | 0 |
| Protocol | TCP, single stream |

This is the full Azure VM bandwidth allocation for D4s_v6.

### ICMP Ping (VPP VXLAN)

| Direction | Packets | Loss | Avg RTT |
|-----------|---------|------|---------|
| service-a → service-b | 10/10 | 0% | 4.7 ms |
| service-b → service-a | 10/10 | 0% | 4.4 ms |

### UDP Throughput (VPP VXLAN) — Single Flow

| Target Rate | Sent | Received | Loss | Notes |
|-------------|------|----------|------|-------|
| 1 Gbps | 990 Mbps | **986 Mbps** | 0.008% | Clean — under the ceiling |
| 2 Gbps | 1.27 Gbps | **927 Mbps** | 26% | Ceiling hit at ~1 Gbps |
| 5 Gbps | 1.75 Gbps | **606 Mbps** | 64% | Heavy loss above ceiling |

**Maximum single-flow UDP throughput: ~1 Gbps**

### UDP Throughput (VPP VXLAN) — Multiple Parallel Flows

| Flows | Per-flow Target | Total Sent | Total Received | Avg Loss |
|-------|----------------|------------|----------------|----------|
| 1 × 1G | 1 Gbps | 990 Mbps | **986 Mbps** | 0.008% |
| 2 × 500M | 500 Mbps each | 1 Gbps | **602 Mbps** | 39% |
| 4 × 200M | 200 Mbps each | 800 Mbps | **727 Mbps** | 8.5% |
| 4 × 500M | 500 Mbps each | 2 Gbps | **609 Mbps** | 66% |

**Key finding: multiple flows make it WORSE.** Adding parallel flows increases contention on the shared af_packet socket and veth path. 1 flow at 1 Gbps (986 Mbps received) outperforms 4 flows at 200 Mbps each (727 Mbps total).

Multiple sender/receiver pods would NOT help because all macvlans on the same node share the same parent eth1 → same `host-dp0` af_packet socket inside VPP.

### TCP Throughput (VPP VXLAN)

| Streams | Throughput (sender) | Throughput (receiver) | Retransmits | Notes |
|---------|--------------------|-----------------------|-------------|-------|
| 1 | 1.35 Mbps | **687 Kbps** | 346 | Inner TCP checksum issue |
| 4 | 5.78 Mbps | **5.01 Mbps** | 1,866 | Scales linearly with streams |

TCP is severely limited by the inner TCP checksum problem. The macvlan passes packets with partial (offloaded) checksums. VPP forwards them through the VXLAN tunnel without recomputing, and the receiving kernel drops packets with bad checksums. The GSO feature (`set interface feature gso`) helps with the outer IP checksum but doesn't fully fix the inner TCP checksum.

### Bottleneck Analysis

```
12.2 Gbps  ── Azure NIC capacity (D4s_v6 MANA)
                │
                │  NOT the bottleneck
                ▼
~1 Gbps    ── af_packet v2 + veth + Linux ip_forward
                │
                │  af_packet v2 sendto() per-frame syscall overhead
                │  each packet = 1 kernel call (~800K pps max)
                │  veth forwarding is single-threaded
                │  nftables SNAT adds per-packet processing
                ▼
~1.3 Mbps  ── TCP with inner checksum issue
                │
                │  macvlan partial checksums not recomputed by VPP
                │  ~50% of TCP data segments dropped by receiver kernel
                │  Cwnd collapses to 1 MSS, retransmit storm
                ▼
```

### How to Improve Throughput

| Approach | Expected Gain | Complexity | Status |
|----------|--------------|------------|--------|
| **Fix inner TCP checksum** | TCP: 1 Mbps → ~1 Gbps | Medium | Needs VPP checksum computation in forwarding path |
| **Fix af_packet v3 TX ring** | UDP: 1 Gbps → 3-5 Gbps | Hard | VPP bug: TPACKET_V3 ring flush broken |
| **SR-IOV** | 5-10 Gbps | Medium | Bypasses af_packet entirely; needs Azure SRIOV NIC + VPP DPDK |
| **DPDK on MANA** | 10+ Gbps | Hard | Blocked by `ibv_create_cq` error in MANA queue setup |
| **memif (pod↔VPP)** | Pod overhead: ~0 | Medium | Pods use VPP memif instead of macvlan; zero-copy |
| **Larger VM (D16s_v6)** | NIC: 16 Gbps | Easy | More vCPUs = more NIC bandwidth allocation |

---

## Key IPs Reference

| Item | Node 1 | Node 2 |
|------|--------|--------|
| eth1 underlay | 10.120.3.4 | 10.120.3.5 |
| eth1 MAC | 7c:ed:8d:25:e4:4d | 7c:ed:8d:9d:9c:0c |
| veth (VPP side) | 172.16.200.2 | 172.16.201.2 |
| veth (Linux side) | 172.16.200.1 | 172.16.201.1 |
| pod gateway | 10.20.0.254 | 10.21.0.254 |
| service pod net1 | 10.20.1.20 | 10.21.1.20 |
| overlay p2p | 10.60.0.1 | 10.60.0.2 |
| branch VM | 10.120.4.4 / 20.240.44.74 | — |

---

## Files

| File | Purpose |
|------|---------|
| `scripts/setup-node-nonat.sh` | Main setup script — parametric, works for both nodes |
| `scripts/setup-node1-hybrid.sh` | Earlier SNAT-based approach (kept for reference) |
| `scripts/setup-node2-hybrid.sh` | Earlier SNAT-based approach (kept for reference) |
