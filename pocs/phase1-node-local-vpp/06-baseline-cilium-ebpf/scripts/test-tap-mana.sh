#!/bin/bash
set -e

# TAP performance test on MANA node
# TAP uses virtio between VPP and kernel — kernel handles TX via normal stack
# Use routing (not bridge) to avoid MAC collision issues

pkill -9 -f "vpp -c" 2>/dev/null || true
sleep 2
rm -f /run/vpp/cli.sock /tmp/vpp-tap.log

# Get eth1 info
ETH1_MAC=$(ip link show eth1 | awk '/ether/ {print $2}')
echo "eth1 MAC: $ETH1_MAC"

# eth1 up, remove IP (VPP will own it via TAP)
ip link set eth1 up
ip link set eth1 mtu 3900
ip addr flush dev eth1

# Linux forwarding
sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
sysctl -w net.netfilter.nf_conntrack_checksum=0 >/dev/null 2>/dev/null || true

NODE_IP=${1:-10.120.3.4}
REMOTE_IP=${2:-10.120.3.5}
REMOTE_MAC=${3:-7c:ed:8d:9d:9c:0c}

# Static ARP for remote node (eth1 has no IP)
ip neigh replace ${REMOTE_IP} lladdr ${REMOTE_MAC} dev eth1
ip route add ${REMOTE_IP}/32 dev eth1 2>/dev/null || true

# Remove Cilium BPF
tc filter del dev eth1 egress 2>/dev/null || true

# Start VPP with all plugins
cat > /etc/vpp/startup.conf << 'CONF'
unix {
  nodaemon
  log /tmp/vpp-tap.log
  cli-listen /run/vpp/cli.sock
  poll-sleep-usec 100
}
buffers {
  buffers-per-numa 16384
  page-size 4K
}
plugins {
  plugin dpdk_plugin.so { disable }
  plugin default { enable }
}
CONF

vpp -c /etc/vpp/startup.conf &
for i in $(seq 1 15); do
  vppctl show version >/dev/null 2>&1 && break
  sleep 1
done
echo "VPP: $(vppctl show version 2>/dev/null | head -1)"

# Create TAP with eth1's MAC so Azure SDN accepts our traffic
vppctl create tap id 0 host-if-name vpp-tap0 host-ip4-addr 172.16.100.1/30
vppctl set interface state tap0 up
vppctl set interface mac address tap0 ${ETH1_MAC}
vppctl set interface ip address tap0 172.16.100.2/30

# Wait for tap to come up
sleep 2
ip link set vpp-tap0 up

# Linux routing: remote node via tap → Linux forwards to eth1
ip route add ${REMOTE_IP}/32 via 172.16.100.2 dev vpp-tap0 2>/dev/null || true

# VPP route: remote node via tap's Linux peer (kernel will forward to eth1)
vppctl ip route add ${REMOTE_IP}/32 via 172.16.100.1 tap0

# SNAT for VXLAN (same as veth approach)
nft add table ip nat 2>/dev/null || true
nft 'add chain ip nat early-postrouting { type nat hook postrouting priority srcnat - 1 ; policy accept ; }' 2>/dev/null || true
nft flush chain ip nat early-postrouting 2>/dev/null || true
nft add rule ip nat early-postrouting oif eth1 udp dport 4789 counter snat to ${NODE_IP} 2>/dev/null || true

echo "=== TEST: VPP ping remote node via TAP ==="
vppctl set ip neighbor tap0 172.16.100.1 $(ip link show vpp-tap0 | awk '/ether/ {print $2}')
vppctl ping ${REMOTE_IP} source tap0 repeat 5 2>&1

echo "=== tcpdump on eth1 ==="
nohup timeout 6 tcpdump -i eth1 -c 5 -nn icmp -w /tmp/tap_eth1.pcap 2>/dev/null &
sleep 1
vppctl ping ${REMOTE_IP} source tap0 repeat 3 2>&1
sleep 4
echo "Packets on eth1:"
tcpdump -r /tmp/tap_eth1.pcap -nn 2>/dev/null
echo "Count: $(tcpdump -r /tmp/tap_eth1.pcap -nn 2>/dev/null | wc -l)"

echo "=== Counters ==="
vppctl show interface tap0
echo "=== DONE ==="
