#!/bin/bash
# ============================================================================
# MANA DPDK testpmd runner - call AFTER build-only.sh
# Uses prlimit to set memlock unlimited for DPDK
# ============================================================================
set -e

echo "=== Allocating HugePages ==="
echo 1024 | tee /sys/devices/system/node/node*/hugepages/hugepages-2048kB/nr_hugepages > /dev/null
grep HugePages_Total /proc/meminfo

echo "=== Identifying eth1 MANA details ==="
PRIMARY="eth1"
SECONDARY=$(ip -br link show master $PRIMARY | awk '{ print $1 }')
MANA_MAC=$(ip -br link show master $PRIMARY | awk '{ print $3 }')
BUS_INFO=$(ethtool -i $SECONDARY | grep bus-info | awk '{ print $2 }')
DEV_UUID=$(basename $(readlink /sys/class/net/$PRIMARY/device))

echo "PRIMARY=$PRIMARY SECONDARY=$SECONDARY"
echo "MAC=$MANA_MAC  BUS=$BUS_INFO  UUID=$DEV_UUID"

echo "=== Setting eth1 DOWN ==="
ip link set $PRIMARY down
ip link set $SECONDARY down

echo "=== Binding eth1 netvsc to uio_hv_generic ==="
chroot /host modprobe uio_hv_generic
NET_UUID="f8615163-df3e-46c5-913f-f2d2f965ed0e"
echo $NET_UUID > /sys/bus/vmbus/drivers/uio_hv_generic/new_id 2>/dev/null || true
echo $DEV_UUID > /sys/bus/vmbus/drivers/hv_netvsc/unbind
echo $DEV_UUID > /sys/bus/vmbus/drivers/uio_hv_generic/bind
echo "[OK] eth1 -> uio_hv_generic"

echo "=== Running dpdk-testpmd with prlimit ==="
rm -rf /var/run/dpdk

# Use prlimit to set unlimited memlock for the dpdk process
prlimit --memlock=unlimited:unlimited -- \
  dpdk-testpmd -l 0-1 \
    --huge-dir /dev/hugepages \
    --iova-mode va \
    --vdev="$BUS_INFO,mac=$MANA_MAC" \
    -- --forward-mode=txonly --auto-start \
    --txd=128 --rxd=128 \
    --stats 2 \
    --total-num-mbufs=2048 &
DPDK_PID=$!

echo "testpmd PID: $DPDK_PID"
sleep 20
kill $DPDK_PID 2>/dev/null || true
wait $DPDK_PID 2>/dev/null || true
echo "=== DONE ==="
