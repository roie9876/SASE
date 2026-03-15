#!/bin/bash
set -e

pkill -9 vpp 2>/dev/null || true
sleep 1
rm -f /run/vpp/cli.sock

# Find Mellanox VF device name
MLX_DEV=$(ls /sys/class/net/ | grep enP | head -1)
echo "Mellanox VF: $MLX_DEV"

# Check XDP stats
echo "=== eth1 XDP stats ==="
ethtool -S eth1 2>/dev/null | grep -i xdp | head -5 || echo "none"

echo "=== $MLX_DEV XDP stats ==="
ethtool -S $MLX_DEV 2>/dev/null | grep -i xdp | head -5 || echo "none"

# VPP with af_xdp enabled
cat > /etc/vpp/startup.conf << 'CONF'
unix {
  nodaemon
  log /tmp/vpp-xdp.log
  cli-listen /run/vpp/cli.sock
  poll-sleep-usec 100
}
buffers {
  buffers-per-numa 16384
  page-size 4K
}
plugins {
  plugin default { disable }
  plugin af_xdp_plugin.so { enable }
  plugin af_packet_plugin.so { enable }
  plugin ping_plugin.so { enable }
}
CONF

ip link set eth1 up
ip addr add 10.120.3.10/24 dev eth1 2>/dev/null || true

vpp -c /etc/vpp/startup.conf &
for i in $(seq 1 15); do
  vppctl show version >/dev/null 2>&1 && break
  sleep 1
done
echo "VPP started"

# Try af_xdp on eth1 (hv_netvsc)
echo "=== TRY: af_xdp on eth1 ==="
vppctl create interface af_xdp name eth1 2>&1
echo "exit: $?"

# Try af_xdp on the mlx5 VF directly
echo "=== TRY: af_xdp on $MLX_DEV ==="
vppctl create interface af_xdp name $MLX_DEV 2>&1
echo "exit: $?"

# Show what we got
echo "=== VPP interfaces ==="
vppctl show interface
