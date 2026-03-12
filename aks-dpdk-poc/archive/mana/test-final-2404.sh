#!/bin/bash
# MANA DPDK test on Ubuntu 24.04 / kernel 6.8
set -e

echo "[1] HugePages..."
echo 1024 | tee /sys/devices/system/node/node*/hugepages/hugepages-2048kB/nr_hugepages > /dev/null
grep HugePages_Total /proc/meminfo

echo "[2] MANA details..."
SECONDARY=$(ip -br link show master eth1 | awk '{ print $1 }')
MANA_MAC=$(ip -br link show master eth1 | awk '{ print $3 }')
BUS_INFO=$(ethtool -i $SECONDARY | grep bus-info | awk '{ print $2 }')
DEV_UUID=$(basename $(readlink /sys/class/net/eth1/device))
echo "    MAC=$MANA_MAC BUS=$BUS_INFO UUID=$DEV_UUID"

echo "[3] ibv_devices..."
ibv_devices 2>/dev/null || echo "(not in container path)"
ls /sys/class/infiniband/

echo "[4] Setting eth1 DOWN..."
ip link set eth1 down
ip link set $SECONDARY down

echo "[5] Binding eth1 to uio_hv_generic (via host modprobe)..."
NET_UUID="f8615163-df3e-46c5-913f-f2d2f965ed0e"
chroot /host modprobe uio_hv_generic
echo $NET_UUID > /sys/bus/vmbus/drivers/uio_hv_generic/new_id 2>/dev/null || true
echo $DEV_UUID > /sys/bus/vmbus/drivers/hv_netvsc/unbind
echo $DEV_UUID > /sys/bus/vmbus/drivers/uio_hv_generic/bind
echo "[OK]"

echo "[6] Running testpmd (--no-huge -m 512)..."
rm -rf /var/run/dpdk
timeout 25 dpdk-testpmd -l 0-1 \
  --no-huge -m 512 \
  --iova-mode va \
  --vdev="$BUS_INFO,mac=$MANA_MAC" \
  -- --forward-mode=txonly --auto-start \
  --txd=128 --rxd=128 \
  --stats 2 \
  --total-num-mbufs=2048 2>&1 || true

echo "[7] DONE"
