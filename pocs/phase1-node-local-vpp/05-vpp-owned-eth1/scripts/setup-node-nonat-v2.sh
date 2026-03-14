#!/bin/bash
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















































































































































vppctl show vxlan tunnelecho "---tunnel---"vppctl show interface addressecho "=== READY ==="fi  vppctl sr localsid address fc00::a:1:e004 behavior end.dt4 0  vppctl set interface ip address host-vxlan100 fc00::1/64  vppctl enable ip6 interface host-vxlan100  vppctl set interface ip address host-vxlan100 10.50.0.1/30  vppctl set interface state host-vxlan100 up  vppctl create host-interface name vxlan100 hw-addr "$VX100_MAC"  VX100_MAC=$(ip link show vxlan100 | awk '/link\/ether/ {print $2}')if [ "$IS_NODE1" = "yes" ]; thenvppctl ip route add ${REMOTE_DP_SUBNET} via ${REMOTE_OVERLAY_IP} vxlan_tunnel200sleep 1vppctl set ip neighbor vxlan_tunnel200 ${REMOTE_OVERLAY_IP} de:ad:00:00:00:02vppctl set interface ip address vxlan_tunnel200 ${LOCAL_OVERLAY_IP}/30vppctl set interface state vxlan_tunnel200 upvppctl create vxlan tunnel src ${NODE_UNDERLAY_IP} dst ${REMOTE_UNDERLAY_IP} vni 200 instance 200 encap-vrf-id 0 l3# VXLAN tunnel: encap-vrf-id 0 so decap hash fib_index matches incoming VRFvppctl ip route add ${REMOTE_UNDERLAY_IP}/32 via ${REMOTE_UNDERLAY_IP} host-eth1vppctl ip route add ${REMOTE_UNDERLAY_IP}/32 via ${VETH_LOCAL_IP}.1 host-vpp-ul0# Multipath /32: veth for TX, host-eth1 for uRPF (ECMP but both in uRPF list)vppctl set ip neighbor host-vpp-ul0 ${VETH_LOCAL_IP}.1 "$LINUX_UL_MAC"vppctl set ip neighbor host-eth1 ${REMOTE_UNDERLAY_IP} ${REMOTE_UNDERLAY_MAC}vppctl set interface ip address host-vpp-ul0 ${VETH_LOCAL_IP}.2/30vppctl set interface ip address host-dp0 ${LOCAL_DP_GW}/16vppctl set interface ip address host-eth1 ${NODE_UNDERLAY_IP}/24vppctl set interface state host-vpp-ul0 upvppctl set interface state host-dp0 upvppctl set interface state host-eth1 upvppctl create host-interface name vpp-ul0 hw-addr "$UL_MAC"vppctl create host-interface name dp0 hw-addr "$DP0_MAC"vppctl create host-interface name eth1 hw-addr "$ETH1_MAC"LINUX_UL_MAC=$(ip link show linux-ul0 | awk '/link\/ether/ {print $2}')UL_MAC=$(ip link show vpp-ul0 | awk '/link\/ether/ {print $2}')DP0_MAC=$(ip link show dp0 | awk '/link\/ether/ {print $2}')ETH1_MAC=$(ip link show eth1 | awk '/link\/ether/ {print $2}')done  sleep 1  if vppctl show version >/dev/null 2>&1; then break; fifor _ in $(seq 1 20); dovpp -c /etc/vpp/startup.conf &PYEOF    f.write(conf)with open('/etc/vpp/startup.conf', 'w') as f:'''}  plugin vxlan_plugin.so { enable }  plugin ping_plugin.so { enable }  plugin af_packet_plugin.so { enable }  plugin default { disable }  plugin dpdk_plugin.so { disable }plugins {}  page-size 4K  buffers-per-numa 16384buffers {}  poll-sleep-usec 100  cli-listen /run/vpp/cli.sock  log /tmp/vpp-phase1.log  nodaemonconf = '''unix {python3 << 'PYEOF'fi  ethtool -K vxlan100 tso off gso off gro off tx off rx off >/dev/null 2>&1 || true  ip link set vxlan100 up  ip link set vxlan100 mtu 1450  ip link add vxlan100 type vxlan id 100 remote ${BRANCH_IP} local ${NODE_UNDERLAY_IP} dstport 8472 dev eth1  ip route add default via 10.120.3.1 dev eth1 table 100 2>/dev/null || true  ip route add 10.120.3.0/24 dev eth1 table 100 2>/dev/null || true  ip route add ${REMOTE_UNDERLAY_IP}/32 dev eth1 table 100 2>/dev/null || true  ip rule add from ${NODE_UNDERLAY_IP}/32 table 100 2>/dev/null || true  while ip rule del from ${NODE_UNDERLAY_IP}/32 table 100 2>/dev/null; do :; doneif [ "$IS_NODE1" = "yes" ]; thennft add rule ip nat early-postrouting ip saddr 10.120.3.0/24 counter accept 2>/dev/null || truenft add rule ip nat early-postrouting oif eth1 udp dport 4789 counter snat to ${NODE_UNDERLAY_IP} 2>/dev/null || truenft flush chain ip nat early-postrouting 2>/dev/null || truenft 'add chain ip nat early-postrouting { type nat hook postrouting priority srcnat - 1 ; policy accept ; }' 2>/dev/null || truenft add table ip nat 2>/dev/null || truetc filter del dev eth1 egress 2>/dev/null || trueip route add ${REMOTE_UNDERLAY_IP}/32 dev eth1 2>/dev/null || trueip neigh replace ${REMOTE_UNDERLAY_IP} lladdr ${REMOTE_UNDERLAY_MAC} dev eth1sysctl -w net.ipv4.conf.eth1.rp_filter=0 >/dev/nullsysctl -w net.ipv4.conf.linux-ul0.rp_filter=0 >/dev/nullsysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/nullsysctl -w net.ipv4.ip_forward=1 >/dev/nulldone  ethtool -K "$dev" tso off gso off gro off tx off rx off >/dev/null 2>&1 || truefor dev in eth1 dp0; doip link set dp0 upip link add dp0 link eth1 type macvlan mode bridgeip addr add ${VETH_LOCAL_IP}.1/30 dev linux-ul0ip link set linux-ul0 upip link set vpp-ul0 upip link add vpp-ul0 type veth peer name linux-ul0ip addr del ${NODE_UNDERLAY_IP}/24 dev eth1 2>/dev/null || trueip link set eth1 mtu 3900ip link set eth1 upip link del ul0 2>/dev/null || trueip link del vxlan100 2>/dev/null || trueip link del dp0 2>/dev/null || trueip link del linux-ul0 2>/dev/null || trueip link del vpp-ul0 2>/dev/null || truemkdir -p /etc/vpp /run/vppsleep 1rm -f /run/vpp/cli.sock /tmp/vpp-phase1.logpkill -9 -f "vpp -c" 2>/dev/null || truefi  REMOTE_OVERLAY_IP=10.60.0.1  LOCAL_OVERLAY_IP=10.60.0.2else  REMOTE_OVERLAY_IP=10.60.0.2  LOCAL_OVERLAY_IP=10.60.0.1if [ "$IS_NODE1" = "yes" ]; thenIS_NODE1=${9:-yes}VETH_LOCAL_IP=${8:-172.16.200}VETH_LOCAL_IP=${8:-172.16.200}
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
ip link set vpp-ul0 up
ip link set linux-ul0 up
ip addr add ${VETH_LOCAL_IP}.1/30 dev linux-ul0

# Pod dataplane macvlan
ip link add dp0 link eth1 type macvlan mode bridge
ip link set dp0 up

# Disable offloads
for dev in eth1 dp0; do
  ethtool -K "$dev" tso off gso off gro off tx off rx off >/dev/null 2>&1 || true
done

# Linux forwarding + rp_filter off
sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
sysctl -w net.ipv4.conf.linux-ul0.rp_filter=0 >/dev/null
sysctl -w net.ipv4.conf.eth1.rp_filter=0 >/dev/null

# Static ARP for remote node on eth1 (eth1 has no IP, can't ARP)
ip neigh replace ${REMOTE_UNDERLAY_IP} lladdr ${REMOTE_UNDERLAY_MAC} dev eth1
ip route add ${REMOTE_UNDERLAY_IP}/32 dev eth1 2>/dev/null || true

# Remove Cilium BPF from eth1 egress (prevents masquerade)
tc filter del dev eth1 egress 2>/dev/null || true

# Explicit SNAT for VXLAN to preserve correct source IP
nft add table ip nat 2>/dev/null || true
nft add chain ip nat early-postrouting '{ type nat hook postrouting priority srcnat - 1; policy accept; }' 2>/dev/null || true
nft flush chain ip nat early-postrouting 2>/dev/null || true
nft add rule ip nat early-postrouting oif eth1 udp dport 4789 counter snat to ${NODE_UNDERLAY_IP}
nft add rule ip nat early-postrouting ip saddr 10.120.3.0/24 counter accept

# Policy routing table 100 (for branch VXLAN, Node 1 only)
if [ "$IS_NODE1" = "yes" ]; then
  # Clean duplicate ip rules
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

# Create af_packet interfaces
vppctl create host-interface name eth1 hw-addr "$ETH1_MAC"
vppctl create host-interface name dp0 hw-addr "$DP0_MAC"
vppctl create host-interface name vpp-ul0 hw-addr "$UL_MAC"

# All interfaces in VRF 0 (no separate encap VRF — VXLAN hash needs matching fib_index)
vppctl set interface state host-eth1 up
vppctl set interface state host-dp0 up
vppctl set interface state host-vpp-ul0 up

vppctl set interface ip address host-eth1 ${NODE_UNDERLAY_IP}/24
vppctl set interface ip address host-dp0 ${LOCAL_DP_GW}/16
vppctl set interface ip address host-vpp-ul0 ${VETH_LOCAL_IP}.2/30

# Static neighbors
vppctl set ip neighbor host-eth1 ${REMOTE_UNDERLAY_IP} ${REMOTE_UNDERLAY_MAC}
vppctl set ip neighbor host-vpp-ul0 ${VETH_LOCAL_IP}.1 "$LINUX_UL_MAC"

# Multipath /32 route: primary via veth for TX, host-eth1 as second path for uRPF
# Both interfaces appear in the uRPF list so incoming VXLAN on host-eth1 passes source check
vppctl ip route add ${REMOTE_UNDERLAY_IP}/32 via ${VETH_LOCAL_IP}.1 host-vpp-ul0
vppctl ip route add ${REMOTE_UNDERLAY_IP}/32 via ${REMOTE_UNDERLAY_IP} host-eth1

# VXLAN tunnel — encap-vrf-id 0 so decap hash fib_index matches incoming interface
vppctl create vxlan tunnel src ${NODE_UNDERLAY_IP} dst ${REMOTE_UNDERLAY_IP} vni 200 instance 200 encap-vrf-id 0 l3
vppctl set interface state vxlan_tunnel200 up
vppctl set interface ip address vxlan_tunnel200 ${LOCAL_OVERLAY_IP}/30
vppctl set ip neighbor vxlan_tunnel200 ${REMOTE_OVERLAY_IP} de:ad:00:00:00:02
sleep 1
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
echo "---uRPF---"
vppctl show ip fib ${REMOTE_UNDERLAY_IP}/32 2>/dev/null | grep -E "uPRF|itfs|forwarding" | head -5
echo "---tunnel---"
vppctl show vxlan tunnel
echo "---route---"
vppctl show ip fib ${REMOTE_DP_SUBNET} 2>/dev/null | grep forwarding -A3 | head -5
