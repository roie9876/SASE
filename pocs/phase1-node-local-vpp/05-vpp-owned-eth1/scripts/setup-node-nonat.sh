#!/bin/bash
# setup-node-nonat.sh — E-W without NAT on MANA AKS nodes
# Both node1 and node2 are Standard_D4s_v6 with MANA NICs.
# MANA af_packet TX is broken (TX counter increments, 0 packets on wire).
# Fix: veth for TX, host-eth1 for RX, ip4-vxlan-bypass to skip uRPF on decap.
#
# Three bugs fixed:
#  1. VPP VXLAN hash key includes encap_fib_index → must use encap-vrf-id 0
#  2. Cilium eBPF on eth1 egress masquerades src IP → tc filter del + nft SNAT
#  3. /32 route via veth poisons uRPF for host-eth1 → ip4-vxlan-bypass skips uRPF
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export LD_LIBRARY_PATH=/usr/local/lib/x86_64-linux-gnu:/usr/local/lib:${LD_LIBRARY_PATH:-}

NODE_UNDERLAY_IP=${1:-10.120.3.4}
REMOTE_UNDERLAY_IP=${2:-10.120.3.5}
REMOTE_UNDERLAY_MAC=${3:-7c:ed:8d:9d:9c:0c}
LOCAL_DP_SUBNET=${4:-10.20.0.0/16}
LOCAL_DP_GW=${5:-10.20.0.254}
REMOTE_DP_SUBNET=${6:-10.21.0.0/16}
BRANCH_IP=${7:-10.120.4.4}
VETH_LOCAL_IP=${8:-172.16.200}
IS_NODE1=${9:-yes}

if [ "$IS_NODE1" = "yes" ]; then
  LOCAL_OVERLAY_IP=10.60.0.1
  REMOTE_OVERLAY_IP=10.60.0.2
else
  LOCAL_OVERLAY_IP=10.60.0.2
  REMOTE_OVERLAY_IP=10.60.0.1
fi

pkill -9 -f "vpp -c" 2>/dev/null || true
rm -f /run/vpp/cli.sock /tmp/vpp-phase1.log
sleep 1
mkdir -p /etc/vpp /run/vpp

# Clean
ip link del vpp-ul0 2>/dev/null || true
ip link del linux-ul0 2>/dev/null || true
ip link del dp0 2>/dev/null || true
ip link del vxlan100 2>/dev/null || true
ip link del ul0 2>/dev/null || true

# eth1 up, remove IP (VPP will own it)
ip link set eth1 up
ip link set eth1 mtu 3900
ip addr del ${NODE_UNDERLAY_IP}/24 dev eth1 2>/dev/null || true

# Veth for TX (af_packet TX on MANA broken, veth TX works)
ip link add vpp-ul0 type veth peer name linux-ul0
ip link set vpp-ul0 up mtu 3900
ip link set linux-ul0 up mtu 3900
ip addr add ${VETH_LOCAL_IP}.1/30 dev linux-ul0

# Pod dataplane macvlan
ip link add dp0 link eth1 type macvlan mode bridge
ip link set dp0 up

# Disable offloads — CRITICAL for TCP: checksumming and segmentation must be
# OFF on underlay interfaces. BUT veth MUST keep defaults (tx-checksum, gso, sg on)
# because VPP af_packet v3 requires PACKET_VNET_HDR and qdisc-bypass for TX ring
# flush to work. Without these, af_packet TX writes to the ring but kernel never
# sends the frames (request increments, sending stays 0).
for dev in eth1 dp0; do
  ethtool -K "$dev" tso off gso off gro off tx off rx off sg off >/dev/null 2>&1 || true
done
# Veth: only disable TSO (not tx/gso/sg — those are required for af_packet TX)
for dev in vpp-ul0 linux-ul0; do
  ethtool -K "$dev" tso off gro off rx off >/dev/null 2>&1 || true
done

# Linux forwarding + rp_filter off
sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
sysctl -w net.ipv4.conf.linux-ul0.rp_filter=0 >/dev/null
sysctl -w net.ipv4.conf.eth1.rp_filter=0 >/dev/null
# Disable conntrack checksum validation — VPP af_packet may produce
# packets with partial/bad checksums that conntrack would reject
sysctl -w net.netfilter.nf_conntrack_checksum=0 >/dev/null 2>/dev/null || true

# Static ARP for remote node on eth1 (eth1 has no IP, can't ARP)
ip neigh replace ${REMOTE_UNDERLAY_IP} lladdr ${REMOTE_UNDERLAY_MAC} dev eth1
ip route add ${REMOTE_UNDERLAY_IP}/32 dev eth1 2>/dev/null || true

# BUG 2 FIX: Remove Cilium eBPF masquerade from eth1 egress
tc filter del dev eth1 egress 2>/dev/null || true

# BUG 2 FIX: Explicit SNAT at high priority to preserve correct source IP
# (Kube IP-MASQ-AGENT periodically overwrites nft rules, so use a separate chain
# at priority srcnat-1 which runs before the Kube/Cilium chains)
nft add table ip nat 2>/dev/null || true
nft 'add chain ip nat early-postrouting { type nat hook postrouting priority srcnat - 1 ; policy accept ; }' 2>/dev/null || true
nft flush chain ip nat early-postrouting 2>/dev/null || true
nft add rule ip nat early-postrouting oif eth1 udp dport 4789 counter snat to ${NODE_UNDERLAY_IP} 2>/dev/null || true
nft add rule ip nat early-postrouting ip saddr 10.120.3.0/24 counter accept 2>/dev/null || true

# Linux policy routing table 100 for branch VXLAN (Node 1 only)
# Routes must be added WITHOUT src= (pruned when eth1 IP is removed)
if [ "$IS_NODE1" = "yes" ]; then
  # Clean accumulated ip rules
  while ip rule del from ${NODE_UNDERLAY_IP}/32 table 100 2>/dev/null; do :; done
  ip rule add from ${NODE_UNDERLAY_IP}/32 table 100 2>/dev/null || true
  ip route add ${REMOTE_UNDERLAY_IP}/32 dev eth1 table 100 2>/dev/null || true
  ip route add 10.120.3.0/24 dev eth1 table 100 2>/dev/null || true
  ip route add default via 10.120.3.1 dev eth1 table 100 2>/dev/null || true

  ip link add vxlan100 type vxlan id 100 remote ${BRANCH_IP} local ${NODE_UNDERLAY_IP} dstport 8472 dev eth1
  ip link set vxlan100 mtu 1450
  ip link set vxlan100 up
  ethtool -K vxlan100 tso off gso off gro off tx off rx off >/dev/null 2>&1 || true
fi

# VPP startup
python3 << 'PYEOF'
conf = '''unix {
  nodaemon
  log /tmp/vpp-phase1.log
  cli-listen /run/vpp/cli.sock
  poll-sleep-usec 100
}
buffers {
  buffers-per-numa 16384
  page-size 4K
}
plugins {
  plugin dpdk_plugin.so { disable }
  plugin default { disable }
  plugin af_packet_plugin.so { enable }
  plugin ping_plugin.so { enable }
  plugin vxlan_plugin.so { enable }
}
'''
with open('/etc/vpp/startup.conf', 'w') as f:
    f.write(conf)
PYEOF

vpp -c /etc/vpp/startup.conf &
for _ in $(seq 1 20); do
  if vppctl show version >/dev/null 2>&1; then break; fi
  sleep 1
done

ETH1_MAC=$(ip link show eth1 | awk '/link\/ether/ {print $2}')
DP0_MAC=$(ip link show dp0 | awk '/link\/ether/ {print $2}')
UL_MAC=$(ip link show vpp-ul0 | awk '/link\/ether/ {print $2}')
LINUX_UL_MAC=$(ip link show linux-ul0 | awk '/link\/ether/ {print $2}')

# host-eth1 for RX only (VXLAN decap - af_packet RX works on MANA)
vppctl create host-interface name eth1 hw-addr "$ETH1_MAC"
# host-dp0 for pod dataplane
vppctl create host-interface name dp0 hw-addr "$DP0_MAC"
# host-vpp-ul0 for TX via veth — MUST use v2 (TPACKET_V2) because
# TPACKET_V3 TX ring flush is broken: request increments but sending stays 0.
# v2 uses sendto() per-frame and reliably delivers to the veth peer.
vppctl create host-interface v2 name vpp-ul0 hw-addr "$UL_MAC"

# All interfaces in VRF 0 — BUG 1 FIX: VXLAN decap hash key includes
# encap_fib_index, so tunnel MUST use encap-vrf-id 0 to match incoming VRF
vppctl set interface state host-eth1 up
vppctl set interface state host-dp0 up
vppctl set interface state host-vpp-ul0 up

# eth1 gets its real IP for RX/decap matching
vppctl set interface ip address host-eth1 ${NODE_UNDERLAY_IP}/24
# dp0 is pod gateway
vppctl set interface ip address host-dp0 ${LOCAL_DP_GW}/16
# vpp-ul0 is on a different subnet (avoids /24 conflict with host-eth1)
vppctl set interface ip address host-vpp-ul0 ${VETH_LOCAL_IP}.2/30

# BUG 3 FIX: Enable ip4-vxlan-bypass on host-eth1.
# This makes VPP's ip4 feature arc on host-eth1 shortcut directly to
# vxlan4-input for UDP/4789 packets, completely bypassing ip4-local and
# its uRPF source-lookup check. Safe because Azure fabric already filters.
vppctl set interface ip vxlan-bypass host-eth1

# BUG 4 FIX: Enable GSO feature on veth and dp0 interfaces.
# af_packet v2 doesn't set VIRTIO_NET_HDR checksum offload flag, so VPP must
# compute correct checksums. VPP's ip4-rewrite decrements TTL without updating
# the outer IP checksum. GSO feature arc fixes checksums before TX.
# Without this, remote kernel drops VXLAN packets due to bad outer IP checksum.
vppctl set interface feature gso host-vpp-ul0 enable
vppctl set interface feature gso host-dp0 enable

# TX path: neighbor + route for remote node via veth only
vppctl set ip neighbor host-vpp-ul0 ${VETH_LOCAL_IP}.1 "$LINUX_UL_MAC"
vppctl ip route add ${REMOTE_UNDERLAY_IP}/32 via ${VETH_LOCAL_IP}.1 host-vpp-ul0

# RX path: static neighbor on host-eth1 (needed for /24 adjacency)
vppctl set ip neighbor host-eth1 ${REMOTE_UNDERLAY_IP} ${REMOTE_UNDERLAY_MAC}

# VXLAN tunnel: encap-vrf-id 0 so decap hash fib_index matches incoming VRF 0
vppctl create vxlan tunnel src ${NODE_UNDERLAY_IP} dst ${REMOTE_UNDERLAY_IP} vni 200 instance 200 encap-vrf-id 0 l3
vppctl set interface state vxlan_tunnel200 up
vppctl set interface ip address vxlan_tunnel200 ${LOCAL_OVERLAY_IP}/30
vppctl ip route add ${REMOTE_DP_SUBNET} via ${REMOTE_OVERLAY_IP} vxlan_tunnel200

# Node 1: SRv6 + branch VXLAN
if [ "$IS_NODE1" = "yes" ]; then
  VX100_MAC=$(ip link show vxlan100 | awk '/link\/ether/ {print $2}')
  vppctl create host-interface name vxlan100 hw-addr "$VX100_MAC"
  vppctl set interface state host-vxlan100 up
  vppctl set interface ip address host-vxlan100 10.50.0.1/30
  vppctl enable ip6 interface host-vxlan100
  vppctl set interface ip address host-vxlan100 fc00::1/64
  vppctl sr localsid address fc00::a:1:e004 behavior end.dt4 0
fi

echo "=== READY ==="
vppctl show interface address
echo "---tunnel---"
vppctl show vxlan tunnel
