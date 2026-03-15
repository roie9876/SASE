#!/bin/bash
set -e

echo "=== Check RDMA devices ==="
ls /dev/infiniband/ 2>/dev/null || echo "no /dev/infiniband"
ls /sys/class/infiniband/ 2>/dev/null || echo "no infiniband class"

echo "=== Install RDMA tools ==="
apt-get install -y -qq ibverbs-utils rdma-core libibverbs-dev 2>&1 | tail -3

echo "=== RDMA devices ==="
ibv_devices 2>&1
echo "=== RDMA device info ==="
ibv_devinfo 2>&1 | head -30

echo "=== Find mlx5 VF ==="
MLX=$(ls /sys/class/net/ | grep enP | head -1)
echo "MLX VF: $MLX"
echo "PCI: $(readlink /sys/class/net/$MLX/device 2>/dev/null)"
echo "Driver: $(cat /sys/class/net/$MLX/device/driver/module/drivers 2>/dev/null | head -1)"

echo "=== Kill old VPP ==="
pkill -9 vpp 2>/dev/null || true
sleep 1
rm -f /run/vpp/cli.sock

echo "=== Start VPP with rdma plugin ==="
cat > /etc/vpp/startup.conf << 'CONF'
unix {
  nodaemon
  log /tmp/vpp-rdma.log
  cli-listen /run/vpp/cli.sock
  poll-sleep-usec 100
}
buffers {
  buffers-per-numa 16384
  page-size 4K
}
plugins {
  plugin default { disable }
  plugin rdma_plugin.so { enable }
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
echo "VPP started: $(vppctl show version 2>/dev/null | head -1)"

echo "=== Create RDMA interface on mlx5 VF ==="
vppctl create interface rdma host-if $MLX 2>&1
echo "exit: $?"

echo "=== VPP interfaces ==="
vppctl show interface 2>&1

echo "=== Configure and test ==="
# The rdma interface name will be the MLX device name
vppctl set interface state $MLX up 2>&1
vppctl set interface ip address $MLX 10.120.3.10/24 2>&1

echo "=== PING via RDMA ==="
vppctl ping 10.120.3.1 source $MLX repeat 5 2>&1

echo "=== tcpdump verify ==="
nohup timeout 6 tcpdump -i eth1 -c 5 -nn icmp -w /tmp/rdma_tx.pcap 2>/dev/null &
sleep 1
vppctl ping 10.120.3.1 source $MLX repeat 3 2>&1
sleep 4
echo "Packets on wire:"
tcpdump -r /tmp/rdma_tx.pcap -nn 2>/dev/null
echo "Count: $(tcpdump -r /tmp/rdma_tx.pcap -nn 2>/dev/null | wc -l)"

echo "=== VPP counters ==="
vppctl show interface $MLX 2>&1
vppctl show hardware $MLX verbose 2>&1 | head -20
