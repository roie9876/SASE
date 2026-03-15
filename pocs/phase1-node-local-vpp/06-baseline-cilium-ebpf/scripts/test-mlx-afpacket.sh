#!/bin/bash
set -euo pipefail

# Quick af_packet TX test on Mellanox eth1
ip link set eth1 up
sleep 2
ip addr add 10.120.3.10/24 dev eth1 2>/dev/null || true

# Start VPP
pkill -9 -f "vpp -c" 2>/dev/null || true
rm -f /run/vpp/cli.sock
sleep 1
mkdir -p /etc/vpp /run/vpp

cat > /etc/vpp/startup.conf << 'CONF'
unix {
  nodaemon
  log /tmp/vpp-mlx.log
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
}
CONF

vpp -c /etc/vpp/startup.conf &
for i in $(seq 1 20); do
  vppctl show version >/dev/null 2>&1 && break
  sleep 1
done

ETH1_MAC=$(ip link show eth1 | awk '/ether/ {print $2}')
vppctl create host-interface name eth1 hw-addr "$ETH1_MAC"
vppctl set interface state host-eth1 up
vppctl set interface ip address host-eth1 10.120.3.10/24

echo "=== VPP interface ==="
vppctl show interface host-eth1
echo "=== Hardware ==="
vppctl show hardware host-eth1 verbose | head -20

echo "=== af_packet TX test: ping Azure gateway ==="
vppctl ping 10.120.3.1 source host-eth1 repeat 5

echo "=== tcpdump verify ==="
timeout 5 tcpdump -i eth1 -c 3 -nn icmp 2>&1 &
sleep 1
vppctl ping 10.120.3.1 source host-eth1 repeat 2
sleep 3
echo "=== RESULT ==="
vppctl show interface host-eth1
