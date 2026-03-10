# SASE on AKS: VPP + VXLAN Operations Guide

## Table of Contents
1. [Architecture Overview](#architecture-overview)
2. [What This POC Proves](#what-this-poc-proves)
3. [Known Fragile Points & Root Causes](#known-fragile-points--root-causes)
4. [Complete Setup: From Zero to Working](#complete-setup-from-zero-to-working)
5. [Recovery Procedures](#recovery-procedures)
6. [Performance Testing (iperf3)](#performance-testing-iperf3)
7. [SRv6 Multi-Tenant Routing](#srv6-multi-tenant-routing)
8. [TCP Checksum Issue: Deep Dive](#tcp-checksum-issue-deep-dive)
9. [VPP Command Reference](#vpp-command-reference)
8. [af-packet vs DPDK: Why Production Needs DPDK](#af-packet-vs-dpdk-why-production-needs-dpdk)
9. [Lessons Learned from Azure AKS](#lessons-learned-from-azure-aks)

---

## Architecture Overview

```
branch-vm (10.110.2.4)                        AKS Node (aks-dpdkpool)
┌─────────────────────────┐                   ┌──────────────────────────────────┐
│  eth0: 10.110.2.4       │                   │  vpp-sriov pod (10.110.1.x)      │
│                         │                   │  ┌────────────────────────────┐  │
│  vxlan100 (Linux)       │   VXLAN VNI 100   │  │ Linux vxlan100 (no IP)     │  │
│  IP: 10.50.0.2/30       │ ═══UDP:8472═════> │  │    ↓ af-packet             │  │
│  route: 10.20.0.0/16    │                   │  │ VPP host-vxlan100          │  │
│    via 10.50.0.1        │                   │  │   IP: 10.50.0.1/30         │  │
│                         │                   │  │    ↓ L3 routing            │  │
│                         │                   │  │ VPP host-net1 (macvlan)    │  │
│                         │                   │  │   IP: 10.20.0.254/16       │  │
│                         │                   │  │   MAC: must match Linux!   │  │
└─────────────────────────┘                   │  └────────────┬───────────────┘  │
                                              │               │ macvlan bridge   │
                                              │  ┌────────────┴───────────────┐  │
                                              │  │ client-pod                  │  │
                                              │  │   net1: 10.20.1.24/16      │  │
                                              │  │   route: 10.50.0.0/30      │  │
                                              │  │     via 10.20.0.254        │  │
                                              │  │   iperf3 -s (port 5201)    │  │
                                              │  └────────────────────────────┘  │
                                              └──────────────────────────────────┘
```

### Why VXLAN Instead of Azure UDR?

Azure's SDN cannot deliver external packets into a pod's macvlan overlay. We discovered this through extensive testing:

1. **Azure UDR** points `10.20.0.0/16` to the AKS node IP as next-hop
2. The AKS node Linux kernel receives the packet
3. But the kernel has **no route** to the VPP pod's macvlan namespace
4. The packet is dropped — VPP never sees it

**Solution**: VXLAN tunnel between branch-vm and the VPP pod. Azure routes the outer UDP packet to the pod's CNI IP (which Azure knows about). Linux decapsulates the VXLAN. VPP picks up the inner packet via af-packet.

### Why Port 8472 Instead of 4789?

VPP registers a **global UDP listener on port 4789** for its built-in VXLAN support. Even if no VPP VXLAN tunnel is configured, this listener intercepts all UDP:4789 packets arriving on any VPP-managed interface, returning "no such tunnel" errors. The Linux vxlan100 interface never sees the packets.

**Port 8472** (used by Flannel/OVS) is not registered by VPP and works perfectly.

---

## What This POC Proves

| Test | Result | Significance |
|------|--------|-------------|
| ICMP ping: branch-vm → client-pod | **0% loss** | Full VXLAN + VPP + macvlan data path works |
| iperf3 UDP 100 Mbps | **0% loss, 0.338ms jitter** | VPP can forward real traffic at line rate (af-packet limited) |
| iperf3 UDP 500 Mbps | Works (test for max) | af-packet ceiling ~2-5 Gbps single core |
| iperf3 TCP | **Fails** (checksum issue) | Known af-packet limitation, solved by DPDK mode |

---

## Known Fragile Points & Root Causes

### 1. VPP Steals VXLAN Packets (Port 4789)

| | |
|---|---|
| **Symptom** | Linux vxlan100 receives 0 packets. VPP logs `vxlan4-input: no such tunnel packets` |
| **Root Cause** | VPP registers a global UDP listener on port 4789. Even after deleting VPP VXLAN tunnels, the listener persists (`vppctl show udp ports` shows `4789 ip4 vxlan4-input`) |
| **Fix** | Use **port 8472** for the Linux VXLAN tunnel instead of 4789 |
| **Prevention** | Never create VPP-native VXLAN tunnels when using Linux VXLAN + af-packet. Always use non-standard ports |

### 2. VPP af-packet MAC Mismatch (Macvlan ARP Failure)

| | |
|---|---|
| **Symptom** | `vppctl ping 10.20.1.x` = 100% loss, but `ping -I net1 10.20.1.x` from Linux works perfectly |
| **Root Cause** | VPP generates a random MAC for `host-net1` (e.g., `02:fe:xx:xx:xx:xx`), different from the Linux `net1` interface MAC (e.g., `42:bd:xx:xx:xx:xx`). Macvlan delivers ARP replies to the Linux MAC. VPP's raw socket never sees them |
| **Fix** | `vppctl set interface mac address host-net1 $(ip link show net1 \| grep ether \| awk '{print $2}')` |
| **Prevention** | Always run the MAC-match command immediately after creating the `host-net1` af-packet interface |

### 3. eth0 Offload Corruption (Pod Network Death)

| | |
|---|---|
| **Symptom** | Pod can't ping anything — not even the node IP or Azure gateway. Complete network isolation |
| **Root Cause** | Running `ethtool -K eth0 rx off tx off` disables Cilium CNI's checksum offload on the veth pair, breaking the entire CNI data path |
| **Fix** | Delete and recreate the pod: `kubectl delete pod vpp-sriov --force && kubectl apply -f vpp-sriov.yaml` |
| **Prevention** | **NEVER run `ethtool -K eth0 ...`** — only modify offload on `vxlan100`, never `eth0` |

### 4. VPP Pod Lands on Wrong Node

| | |
|---|---|
| **Symptom** | VPP and client-pod can't communicate via macvlan. Linux-level ping between pods also fails |
| **Root Cause** | Macvlan is L2 — it only works between interfaces on the **same physical node**. Without `nodeName` in the pod spec, Kubernetes may schedule the pod on a different node |
| **Fix** | Add `nodeName: aks-dpdkpool-11331723-vmss000000` to the pod spec |
| **Prevention** | Always pin VPP pod and client pod to the same node via `nodeName` or node affinity |

### 5. Linux IP Conflict on vxlan100

| | |
|---|---|
| **Symptom** | VPP's `host-vxlan100` af-packet sees 0 packets. Linux handles all VXLAN traffic directly |
| **Root Cause** | Both Linux and VPP have the same IP (`10.50.0.1/30`) on vxlan100. Linux kernel handles all ARP/routing before VPP's raw socket can capture frames |
| **Fix** | Remove Linux IP: `ip addr del 10.50.0.1/30 dev vxlan100`. Only VPP should own the IP via af-packet |
| **Prevention** | Never assign a Linux IP to vxlan100 when VPP af-packet will manage it |

### 6. UDP Flood Kills iperf3 Server

| | |
|---|---|
| **Symptom** | After `iperf3 -u -b 0`, all connectivity breaks. Ping returns "Destination Host Unreachable" |
| **Root Cause** | Unlimited UDP flood overwhelms af-packet ring buffer. iperf3 server crashes. VPP ARP cache becomes stale |
| **Fix** | See [Recovery Procedures](#recovery-procedures) below |
| **Prevention** | Always specify bandwidth cap: `iperf3 -u -b 500M`, never use `-b 0` |

---

## Complete Setup: From Zero to Working

### Prerequisites
- AKS cluster with Cilium CNI dataplane
- `dpdkpool` node pool (Standard_D4s_v5 with Accelerated Networking)
- Multus CNI installed
- `sriov-lan` and `sriov-wan` NetworkAttachmentDefinitions created
- `branch-vm` in the same VNet (subnet `10.110.2.0/24`)

### Step 1: Deploy Pods

```bash
# Deploy VPP pod (pinned to dpdkpool node)
kubectl apply -f vpp-sriov.yaml
kubectl wait --for=condition=Ready pod/vpp-sriov --timeout=120s

# Deploy client pod (same node)
kubectl apply -f client-pod-node.yaml
kubectl wait --for=condition=Ready pod/client-pod --timeout=60s

# Verify co-location
kubectl get pods -o wide | grep -E "vpp-sriov|client-pod"
# Both must show the SAME node (aks-dpdkpool-*)
```

### Step 2: Install Tools on VPP Pod

```bash
kubectl exec vpp-sriov -- bash -c '
  apt-get update > /dev/null 2>&1 &&
  apt-get install -y curl gnupg2 iputils-ping iproute2 tcpdump ethtool > /dev/null 2>&1 &&
  curl -s https://packagecloud.io/install/repositories/fdio/release/script.deb.sh | bash > /dev/null 2>&1 &&
  apt-get install -y vpp vpp-plugin-core > /dev/null 2>&1 &&
  echo "VPP INSTALLED"
'
```

### Step 3: Install Tools on Client Pod

```bash
kubectl exec client-pod -- bash -c '
  apt-get update > /dev/null 2>&1 &&
  apt-get install -y iproute2 iputils-ping iperf3 tcpdump > /dev/null 2>&1 &&
  echo "CLIENT READY"
'
```

### Step 4: Start VPP and Configure Interfaces

```bash
kubectl exec vpp-sriov -- bash -c '
  # Start VPP
  vpp -c /etc/vpp/startup.conf &
  sleep 3

  # Create LAN interface (macvlan to client-pod)
  vppctl create host-interface name net1
  vppctl set interface state host-net1 up
  vppctl set interface ip address host-net1 10.20.0.254/16

  # Create WAN interface
  vppctl create host-interface name net2
  vppctl set interface state host-net2 up
  vppctl set interface ip address host-net2 10.30.0.254/16

  # CRITICAL: Match VPP MAC to Linux MAC (fixes macvlan ARP)
  LINUX_MAC=$(ip link show net1 | grep ether | awk "{print \$2}")
  vppctl set interface mac address host-net1 $LINUX_MAC
  echo "VPP net1 MAC set to: $LINUX_MAC"
'
```

### Step 5: Verify VPP → Client-Pod Connectivity

```bash
kubectl exec vpp-sriov -- vppctl ping 10.20.1.24 repeat 3
# Must show replies. If 100% loss, check MAC match (Step 4)
```

### Step 6: Create Linux VXLAN Tunnel (Port 8472)

```bash
kubectl exec vpp-sriov -- bash -c '
  POD_IP=$(ip -4 addr show eth0 | grep -oP "(?<=inet )\S+" | cut -d/ -f1)
  echo "VPP Pod IP: $POD_IP"

  # Create VXLAN on port 8472 (NOT 4789 — VPP steals 4789!)
  ip link add vxlan100 type vxlan id 100 \
    remote 10.110.2.4 local $POD_IP dstport 8472 dev eth0
  ip link set vxlan100 up
  ip link set vxlan100 mtu 1400

  # Disable checksum offload on vxlan100 ONLY (never eth0!)
  ethtool -K vxlan100 rx off tx off 2>/dev/null

  # DO NOT assign Linux IP — VPP owns the IP via af-packet
'
```

### Step 7: Connect VPP to VXLAN Interface

```bash
kubectl exec vpp-sriov -- bash -c '
  vppctl create host-interface name vxlan100
  vppctl set interface state host-vxlan100 up
  vppctl set interface ip address host-vxlan100 10.50.0.1/30
'
```

### Step 8: Configure Client Pod Return Route

```bash
kubectl exec client-pod -- ip route add 10.50.0.0/30 via 10.20.0.254 dev net1
```

### Step 9: Start iperf3 Server on Client Pod

```bash
kubectl exec client-pod -- bash -c 'iperf3 -s -D && echo "iperf3 server started"'
```

### Step 10: Configure Branch VM

Get the VPP pod IP first:
```bash
VPP_POD_IP=$(kubectl get pod vpp-sriov -o jsonpath='{.status.podIP}')
echo "VPP Pod IP: $VPP_POD_IP"
```

Then on branch-vm (via SSH or `az vm run-command`):
```bash
# Replace $VPP_POD_IP with the actual pod IP (e.g., 10.110.1.49)
sudo ip link del vxlan100 2>/dev/null
sudo ip link add vxlan100 type vxlan id 100 \
  remote $VPP_POD_IP local 10.110.2.4 dstport 8472 dev eth0
sudo ip addr add 10.50.0.2/30 dev vxlan100
sudo ip link set vxlan100 up
sudo ethtool -K vxlan100 rx off tx off
sudo ip route add 10.20.0.0/16 via 10.50.0.1 dev vxlan100
```

### Step 11: Validate End-to-End

From branch-vm:
```bash
# Test tunnel endpoint
ping -c 2 10.50.0.1

# Test full path to client-pod
ping -c 4 10.20.1.24

# Test UDP throughput (safe bandwidth cap)
iperf3 -c 10.20.1.24 -t 5 -u -b 100M
```

Expected results:
```
PING 10.20.1.24: 4 packets transmitted, 4 received, 0% packet loss
iperf3 UDP: ~100 Mbits/sec, 0% loss, <1ms jitter
```

---

## Recovery Procedures

### Scenario A: Connectivity Lost After iperf3 Flood

```bash
# 1. On branch-vm: flush stale ARP
sudo ip neigh flush dev vxlan100

# 2. Restart iperf3 server on client-pod
kubectl exec client-pod -- bash -c 'pkill -9 iperf3; iperf3 -s -D'

# 3. Flush client-pod ARP
kubectl exec client-pod -- ip neigh flush dev net1

# 4. Test
# On branch-vm:
ping -c 2 10.20.1.24
```

### Scenario B: VPP Lost host-vxlan100 After VPP Restart

```bash
# Reconnect VPP to the Linux VXLAN interface
kubectl exec vpp-sriov -- bash -c '
  vppctl create host-interface name vxlan100
  vppctl set interface state host-vxlan100 up
  vppctl set interface ip address host-vxlan100 10.50.0.1/30
'
```

### Scenario C: VPP Lost MAC Match After Restart

```bash
kubectl exec vpp-sriov -- bash -c '
  LINUX_MAC=$(ip link show net1 | grep ether | awk "{print \$2}")
  vppctl set interface mac address host-net1 $LINUX_MAC
  echo "MAC set to $LINUX_MAC"
'
```

### Scenario D: VPP Completely Dead

```bash
kubectl exec vpp-sriov -- bash -c '
  pkill -9 vpp; sleep 2

  # Restart VPP
  vpp -c /etc/vpp/startup.conf &
  sleep 3

  # Reconfigure all interfaces
  vppctl create host-interface name net1
  vppctl set interface state host-net1 up
  vppctl set interface ip address host-net1 10.20.0.254/16

  vppctl create host-interface name net2
  vppctl set interface state host-net2 up
  vppctl set interface ip address host-net2 10.30.0.254/16

  # MAC match
  LINUX_MAC=$(ip link show net1 | grep ether | awk "{print \$2}")
  vppctl set interface mac address host-net1 $LINUX_MAC

  # Reconnect VXLAN (Linux vxlan100 survives VPP restart)
  vppctl create host-interface name vxlan100
  vppctl set interface state host-vxlan100 up
  vppctl set interface ip address host-vxlan100 10.50.0.1/30
'
```

### Scenario E: Pod Network Completely Broken (Can't Ping Node)

This happens if `ethtool -K eth0 rx off tx off` was accidentally run.

```bash
# Nuclear option: delete and recreate the pod
kubectl delete pod vpp-sriov --force --grace-period=0
kubectl apply -f vpp-sriov.yaml
kubectl wait --for=condition=Ready pod/vpp-sriov --timeout=120s

# Then redo Steps 2-10 from the setup guide
# IMPORTANT: Get the NEW pod IP for branch-vm VXLAN config
VPP_POD_IP=$(kubectl get pod vpp-sriov -o jsonpath='{.status.podIP}')
echo "New VPP Pod IP: $VPP_POD_IP"
# Update branch-vm vxlan100 remote to the new IP
```

### Scenario F: Client Pod Needs Recreation

```bash
kubectl delete pod client-pod --force --grace-period=0
kubectl apply -f client-pod-node.yaml
kubectl wait --for=condition=Ready pod/client-pod --timeout=60s

# Reinstall tools
kubectl exec client-pod -- bash -c '
  apt-get update > /dev/null 2>&1 &&
  apt-get install -y iproute2 iputils-ping iperf3 tcpdump > /dev/null 2>&1
'

# Re-add return route
kubectl exec client-pod -- ip route add 10.50.0.0/30 via 10.20.0.254 dev net1

# Restart iperf3
kubectl exec client-pod -- bash -c 'iperf3 -s -D'

# NOTE: Client-pod IP may change! Check with:
kubectl exec client-pod -- ip addr show net1 | grep "inet "
# Update iperf3 target IP on branch-vm accordingly
```

---

## Performance Testing (iperf3)

### Safe Test Commands (from branch-vm)

```bash
# UDP 100 Mbps (baseline)
iperf3 -c 10.20.1.24 -t 5 -u -b 100M

# UDP 500 Mbps
iperf3 -c 10.20.1.24 -t 5 -u -b 500M

# UDP 1 Gbps
iperf3 -c 10.20.1.24 -t 5 -u -b 1G

# Reverse direction (download)
iperf3 -c 10.20.1.24 -t 5 -u -b 100M -R

# Multiple parallel streams
iperf3 -c 10.20.1.24 -t 5 -u -b 100M -P 4
```

### ⚠️ NEVER Run These

```bash
# NEVER: unlimited bandwidth floods af-packet and crashes iperf3
iperf3 -c 10.20.1.24 -u -b 0

# NEVER: TCP mode fails due to checksum issue (see below)
iperf3 -c 10.20.1.24 -t 5
```

### Expected Bandwidth Limits

| Component | Max Bandwidth |
|-----------|--------------|
| Azure Standard_D4s_v5 NIC | ~12.5 Gbps |
| VXLAN encap/decap (Linux kernel) | ~8-10 Gbps |
| **VPP af-packet mode** | **~2-5 Gbps** (single core) |
| VPP DPDK mode (production) | ~10-40 Gbps |
| Macvlan bridge | ~10 Gbps |

**VPP af-packet is the bottleneck** in this POC. It copies every packet between kernel and userspace via `PACKET_MMAP`. Production deployments use DPDK mode for 10x+ throughput.

---

## TCP Checksum Issue: Deep Dive

### The Problem

TCP iperf3 tests show initial burst (~35 Mbps) then stall at 0 Bytes/sec with `Cwnd: 1.37 KBytes`:

```
[ ID] Interval           Transfer     Bitrate         Retr  Cwnd
[  5]   0.00-1.00   sec  4.18 MBytes  35.0 Mbits/sec    2   1.37 KBytes
[  5]   1.00-2.00   sec  0.00 Bytes   0.00 bits/sec     1   1.37 KBytes
[  5]   2.00-3.00   sec  0.00 Bytes   0.00 bits/sec     0   1.37 KBytes
```

### Root Cause: Hardware Checksum Offload vs af-packet

The packet flow when client-pod sends a TCP SYN-ACK back:

```
1. client-pod Linux kernel creates TCP SYN-ACK
2. Kernel enables hardware checksum offload on macvlan net1
3. Kernel writes a PARTIAL checksum (placeholder) into the TCP header
4. Kernel expects the physical NIC hardware to compute the final checksum
5. BUT: VPP's af-packet (raw socket) intercepts the packet BEFORE the NIC
6. VPP receives a packet with an INCOMPLETE/WRONG TCP checksum
7. VPP forwards this broken packet to host-vxlan100
8. Linux encapsulates it in VXLAN and sends to branch-vm
9. branch-vm kernel validates the TCP checksum → INVALID → DROPS
10. TCP window collapses → connection stalls
```

### Why UDP Works

UDP checksum is **optional** in IPv4 (RFC 768). Linux VXLAN computes a correct outer UDP checksum, and inner UDP datagrams from iperf3 can have zero checksums, which receivers accept without validation.

### Solutions for Production

| Approach | How | Performance Impact |
|----------|-----|-------------------|
| **VPP DPDK mode** | VPP directly controls the NIC. No kernel. VPP computes all checksums in software at wire speed | **10-40 Gbps**, TCP works |
| **VPP checksum feature** | Enable VPP's TCP checksum rewrite on the output interface | Same af-packet speed but TCP works |
| **Disable offload on client-pod** | `ethtool -K net1 tx off` inside client-pod | Kernel computes full checksums; slight CPU overhead |

For a production SASE deployment, **DPDK mode is required** — it solves checksums, gives 10x+ performance, and eliminates all kernel-path fragility.

---

## af-packet vs DPDK: Why Production Needs DPDK

### af-packet (What This POC Uses)

```
           ┌─────────────┐
           │   VPP       │  ← Userspace
           └──────┬──────┘
                  │ PACKET_MMAP (copy)
           ┌──────┴──────┐
           │ Linux Kernel │  ← Kernel processes every packet
           └──────┬──────┘
                  │
           ┌──────┴──────┐
           │   NIC       │
           └─────────────┘
```

- Every packet: NIC → Kernel → Copy to VPP → VPP processes → Copy to Kernel → NIC
- **2 memory copies per packet**
- Kernel overhead: interrupts, scheduling, socket buffers
- Max throughput: **2-5 Gbps** (single core)
- TCP checksums: **broken** (kernel offload conflict)

### DPDK (What Production Needs)

```
           ┌─────────────┐
           │   VPP       │  ← Userspace: direct NIC access
           └──────┬──────┘
                  │ DMA (zero-copy)
           ┌──────┴──────┐
           │   NIC       │  ← No kernel involvement
           └─────────────┘
```

- NIC → DMA → VPP userspace memory → VPP processes → DMA → NIC
- **Zero memory copies**
- No kernel: no interrupts, no scheduling overhead
- Max throughput: **10-40 Gbps** (single core, depending on packet size)
- TCP checksums: **VPP computes them in software** — always correct
- Requires: HugePages, IOMMU or VFIO, PCI device passthrough

### Why We Couldn't Use DPDK in This POC

Azure's Mellanox MANA/ConnectX SR-IOV VFs have specific DPDK driver requirements:
1. **IOMMU**: AKS nodes don't enable IOMMU by default → VFIO binding fails
2. **UIO driver**: Requires `uio_pci_generic` kernel module loaded. Works but has stability issues on Azure
3. **Bifurcated driver**: Mellanox uses a split driver model. The VF must be detached from `mlx5_core` and reattached to DPDK, but Azure's hypervisor sometimes blocks this
4. **No Microsoft documentation**: There is zero official documentation from Microsoft on running DPDK inside AKS pods. The SR-IOV device plugin, VFIO passthrough, and hugepage configuration on AKS are completely undocumented

---

## Lessons Learned from Azure AKS

### What Azure Supports Well
- Azure CNI + Cilium dataplane
- Macvlan via Multus on same-node pods
- VXLAN tunnels between pods and VMs (any UDP port)
- IP Forwarding on VMSS NICs
- User Defined Routes (but only for Azure-routable IPs)

### What Azure Does NOT Support
- ❌ Routing external traffic into pod macvlan overlays via UDR (Azure doesn't know about overlay IPs)
- ❌ Native DPDK on AKS without significant manual kernel/driver configuration
- ❌ L2 macvlan traffic between pods on different nodes (Azure hypervisor drops foreign MACs)
- ❌ Modifying `eth0` checksum offload on Cilium-managed veth pairs (breaks CNI completely)

### Critical Rules

1. **Always use port 8472** for VXLAN — never 4789 (VPP conflict)
2. **Always match VPP af-packet MAC** to the underlying Linux interface MAC
3. **Always pin pods to the same node** when using macvlan
4. **Never assign a Linux IP** to an interface that VPP af-packet manages
5. **Never run `ethtool -K eth0 ...`** — it breaks Cilium CNI
6. **Never run `iperf3 -u -b 0`** — unlimited flood crashes the pipeline
7. **Always set `nodeName`** in pod specs to prevent scheduling drift
8. **Always cap iperf3 bandwidth** — use `-b 500M` or similar

---

## Quick Reference: Current Lab IPs

| Resource | IP | Notes |
|----------|-----|-------|
| branch-vm eth0 | 10.110.2.4 | Azure VM in branch-subnet |
| branch-vm vxlan100 | 10.50.0.2/30 | VXLAN tunnel endpoint |
| vpp-sriov pod (CNI) | 10.110.1.x | Changes on pod restart — check with `kubectl get pod -o wide` |
| VPP host-vxlan100 | 10.50.0.1/30 | VXLAN tunnel endpoint (VPP side) |
| VPP host-net1 | 10.20.0.254/16 | LAN gateway |
| VPP host-net2 | 10.30.0.254/16 | WAN gateway |
| client-pod net1 | 10.20.1.x | Changes on pod restart — check with `kubectl exec client-pod -- ip addr show net1` |
| AKS dpdkpool node | 10.110.1.33 | Static VMSS IP |

> **Important**: Pod IPs change on every restart. Always verify with `kubectl get pod -o wide` and update branch-vm VXLAN `remote` accordingly.
