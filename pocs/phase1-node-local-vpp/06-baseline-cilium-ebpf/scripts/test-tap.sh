#!/bin/bash
set -e

echo "=== Kill old VPP ==="
pkill -9 vpp 2>/dev/null || true
sleep 1
rm -f /run/vpp/cli.sock

ip link set eth1 up
ip addr add 10.120.3.10/24 dev eth1 2>/dev/null || true

echo "=== Start VPP with tap plugin ==="
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
  plugin default { disable }
  plugin af_packet_plugin.so { enable }
  plugin ping_plugin.so { enable }
}
CONF

vpp -c /etc/vpp/startup.conf &
for i in $(seq 1 15); do
  vppctl show version >/dev/null 2>&1 && break
  sleep 1
done
echo "VPP: $(vppctl show version 2>/dev/null | head -1)"

echo "=== Create TAP interface ==="
vppctl create tap id 0 host-if-name vpp-tap0 host-bridge br-dp
vppctl set interface state tap0 up
vppctl set interface ip address tap0 10.120.3.10/24

echo "=== Setup Linux bridge: eth1 + vpp-tap0 ==="
ip link add br-dp type bridge 2>/dev/null || true
ip link set br-dp up
ip link set eth1 master br-dp
ip link set vpp-tap0 master br-dp
ip link set vpp-tap0 up

# Bridge needs no IP, eth1 and tap share L2
echo "=== Linux bridge ==="
bridge link show

echo "=== PING via TAP ==="
vppctl ping 10.120.3.1 source tap0 repeat 5

echo "=== tcpdump verify ==="
nohup timeout 6 tcpdump -i eth1 -c 5 -nn icmp -w /tmp/tap_tx.pcap 2>/dev/null &
sleep 1
vppctl ping 10.120.3.1 source tap0 repeat 3
sleep 4
echo "Packets on wire:"
tcpdump -r /tmp/tap_tx.pcap -nn 2>/dev/null
echo "Count: $(tcpdump -r /tmp/tap_tx.pcap -nn 2>/dev/null | wc -l)"

echo "=== VPP counters ==="
vppctl show interface tap0
