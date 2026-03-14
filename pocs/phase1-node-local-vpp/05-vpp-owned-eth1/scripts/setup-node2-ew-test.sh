#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export LD_LIBRARY_PATH=/usr/local/lib/x86_64-linux-gnu:/usr/local/lib:${LD_LIBRARY_PATH:-}

# Kill existing VPP
pkill -9 -f "vpp -c" 2>/dev/null || true
rm -f /run/vpp/cli.sock /tmp/vpp-node2.log
sleep 1
mkdir -p /etc/vpp /run/vpp

# Linux interfaces
ip link set eth1 up
ip link set eth1 mtu 3900
ip link del vxlan200 2>/dev/null || true
ip link del dp0 2>/dev/null || true
ip link del vpp-ew0 2>/dev/null || true
ip link del linux-ew0 2>/dev/null || true

ip link add dp0 link eth1 type macvlan mode bridge
ip link set dp0 up

# Disable offloads
for dev in eth1 dp0; do
  ethtool -K "$dev" tso off gso off gro off tx off rx off >/dev/null 2>&1 || true
done

# Enable Linux IP forwarding
sysctl -w net.ipv4.ip_forward=1 >/dev/null

# VPP startup config with vxlan plugin
python3 << 'PYEOF'
conf = '''unix {
  nodaemon
  log /tmp/vpp-node2.log
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

# Get Linux MACs
ETH1_MAC=$(ip link show eth1 | awk '/link\/ether/ {print $2}')
DP0_MAC=$(ip link show dp0 | awk '/link\/ether/ {print $2}')

# Create host interfaces with real MACs
vppctl create host-interface name eth1 hw-addr "$ETH1_MAC"
vppctl create host-interface name dp0 hw-addr "$DP0_MAC"

# Bring up interfaces
vppctl set interface state host-eth1 up
vppctl set interface state host-dp0 up

# Addresses
vppctl set interface ip address host-eth1 10.120.3.5/24
vppctl set interface ip address host-dp0 10.21.0.254/16

# Static neighbor for Node 1 on underlay
vppctl set ip neighbor host-eth1 10.120.3.4 7c:ed:8d:25:e4:4d

# Native VPP VXLAN tunnel to Node 1
vppctl create vxlan tunnel src 10.120.3.5 dst 10.120.3.4 vni 200 instance 200 encap-vrf-id 0 l3
vppctl set interface state vxlan_tunnel200 up
vppctl set interface ip address vxlan_tunnel200 10.60.0.2/30

# Route to Node 1 service subnet via the native VXLAN tunnel
vppctl ip route add 10.20.0.0/16 via 10.60.0.1 vxlan_tunnel200

echo "=== NODE2 READY ==="
vppctl show interface address
echo "---neighbors---"
vppctl show ip neighbors
echo "---plugins---"
vppctl show plugins
