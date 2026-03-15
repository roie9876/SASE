#!/bin/bash
set -e

pkill -9 vpp 2>/dev/null || true
sleep 2
rm -f /run/vpp/cli.sock

ip link set eth1 up
ip addr flush dev eth1
ip link del br-dp 2>/dev/null || true

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

echo "=== TAP help ==="
vppctl help create tap 2>&1

echo "=== Create TAP ==="
vppctl create tap id 0 host-if-name vpp-tap0 2>&1
echo "=== Interfaces ==="
vppctl show interface 2>&1

echo "=== Setup Linux bridge ==="
ip link add br-dp type bridge 2>/dev/null || true
ip link set br-dp up
ip link set eth1 master br-dp 2>&1 || echo "eth1 bridge failed"
ip link set vpp-tap0 up 2>&1 || echo "tap up failed"
ip link set vpp-tap0 master br-dp 2>&1 || echo "tap bridge failed"
ip addr add 10.120.3.10/24 dev br-dp 2>/dev/null || true

echo "=== Bridge ==="
bridge link show 2>&1

echo "=== Configure VPP tap ==="
vppctl set interface state tap0 up
vppctl set interface ip address tap0 10.120.3.10/24

echo "=== Test: VPP ping via TAP ==="
vppctl ping 10.120.3.1 source tap0 repeat 5 2>&1

echo "=== tcpdump on eth1 ==="
nohup timeout 6 tcpdump -i eth1 -c 5 -nn icmp -w /tmp/tap_cap.pcap 2>/dev/null &
sleep 1
vppctl ping 10.120.3.1 source tap0 repeat 3 2>&1
sleep 4
echo "Packets:"
tcpdump -r /tmp/tap_cap.pcap -nn 2>/dev/null
echo "Count: $(tcpdump -r /tmp/tap_cap.pcap -nn 2>/dev/null | wc -l)"

echo "=== VPP counters ==="
vppctl show interface tap0
