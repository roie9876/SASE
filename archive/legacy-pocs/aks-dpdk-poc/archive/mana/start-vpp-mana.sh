#!/bin/bash
# ============================================================================
# Start VPP with MANA DPDK on Ubuntu 24.04 / kernel 6.8
# Prerequisite: build-all-mana.sh already ran (rdma-core + DPDK + VPP built)
# ============================================================================
set -e

VPP_DIR=/tmp/vpp/build-root/install-vpp-native/vpp

echo "=== [1] Install VPP binaries ==="
cp -a $VPP_DIR/bin/* /usr/local/bin/ 2>/dev/null || true
cp -a $VPP_DIR/lib/* /usr/local/lib/ 2>/dev/null || true
ldconfig
echo "  VPP: $(vpp --version 2>&1)"

echo "=== [2] Allocate HugePages ==="
echo 1024 | tee /sys/devices/system/node/node*/hugepages/hugepages-2048kB/nr_hugepages > /dev/null
echo "  HugePages: $(grep HugePages_Total /proc/meminfo | awk '{print $2}')"

echo "=== [3] Get MANA eth1 details ==="
SECONDARY=$(ip -br link show master eth1 | awk '{ print $1 }')
MANA_MAC=$(ip -br link show master eth1 | awk '{ print $3 }')
BUS_INFO=$(ethtool -i $SECONDARY | grep bus-info | awk '{ print $2 }')
DEV_UUID=$(basename $(readlink /sys/class/net/eth1/device))
echo "  MAC=$MANA_MAC BUS=$BUS_INFO UUID=$DEV_UUID"

echo "=== [4] Bind eth1 to uio_hv_generic ==="
ip link set eth1 down
ip link set $SECONDARY down
chroot /host modprobe uio_hv_generic
NET_UUID="f8615163-df3e-46c5-913f-f2d2f965ed0e"
echo $NET_UUID > /sys/bus/vmbus/drivers/uio_hv_generic/new_id 2>/dev/null || true
echo $DEV_UUID > /sys/bus/vmbus/drivers/hv_netvsc/unbind
echo $DEV_UUID > /sys/bus/vmbus/drivers/uio_hv_generic/bind
echo "  [OK] eth1 -> uio_hv_generic"

echo "=== [5] Write VPP startup.conf ==="
mkdir -p /etc/vpp /run/vpp
cat > /etc/vpp/startup.conf << VPPEOF
unix {
  nodaemon
  log /tmp/vpp.log
  cli-listen /run/vpp/cli.sock
  full-coredump
}

dpdk {
  no-pci
  no-hugetlb
  vdev $BUS_INFO,mac=$MANA_MAC
  iova-mode va
}

plugins {
  plugin dpdk_plugin.so { enable }
  plugin default { disable }
  plugin af_packet_plugin.so { enable }
  plugin ping_plugin.so { enable }
}
VPPEOF
echo "  startup.conf written"
cat /etc/vpp/startup.conf

echo "=== [6] Start VPP ==="
# Set library path for our custom VPP
export LD_LIBRARY_PATH=/usr/local/lib/x86_64-linux-gnu:/usr/local/lib:$LD_LIBRARY_PATH
vpp -c /etc/vpp/startup.conf &
VPP_PID=$!
echo "  VPP PID: $VPP_PID"
sleep 5

echo "=== [7] Check VPP interfaces ==="
vppctl show version
vppctl show interface
vppctl show hardware-interfaces
vppctl show log | grep -iE "dpdk|mana|error" | head -10

echo "=== DONE ==="
echo "VPP running as PID $VPP_PID"
