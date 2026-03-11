#!/bin/bash
set -e

# Fix the cgroup hugetlb limits for this container
CGROUP=$(cat /proc/self/cgroup | grep "^0::" | cut -d: -f3)
PARENT=$(dirname $CGROUP)
echo "max" > /sys/fs/cgroup${PARENT}/hugetlb.2MB.max 2>/dev/null || true
echo "max" > /sys/fs/cgroup${PARENT}/hugetlb.2MB.rsvd.max 2>/dev/null || true
echo "max" > /sys/fs/cgroup${CGROUP}/hugetlb.2MB.max 2>/dev/null || true
echo "max" > /sys/fs/cgroup${CGROUP}/hugetlb.2MB.rsvd.max 2>/dev/null || true
echo "max" > /sys/fs/cgroup/kubepods.slice/kubepods-besteffort.slice/hugetlb.2MB.max 2>/dev/null || true
echo "max" > /sys/fs/cgroup/kubepods.slice/kubepods-besteffort.slice/hugetlb.2MB.rsvd.max 2>/dev/null || true
echo "[1] Cgroup hugetlb limits set to max"

# Allocate hugepages
echo 1024 | tee /sys/devices/system/node/node*/hugepages/hugepages-2048kB/nr_hugepages > /dev/null
echo "[2] HugePages: $(grep HugePages_Total /proc/meminfo | awk '{print $2}') x 2MB"

# Remount hugetlbfs to pick up new cgroup limits
umount /dev/hugepages 2>/dev/null || true
mount -t hugetlbfs -o pagesize=2M nodev /dev/hugepages
echo "[3] Remounted hugetlbfs"

# Test hugepage write
dd if=/dev/zero of=/dev/hugepages/testfile bs=2M count=1 2>&1 && echo "[4] HUGEPAGE WRITE SUCCESS!" && rm /dev/hugepages/testfile || echo "[4] HUGEPAGE WRITE FAILED"

# Get MANA details
echo "[5] MANA details:"
SECONDARY=$(ip -br link show master eth1 | awk '{ print $1 }')
MANA_MAC=$(ip -br link show master eth1 | awk '{ print $3 }')
BUS_INFO=$(ethtool -i $SECONDARY | grep bus-info | awk '{ print $2 }')
echo "    MAC=$MANA_MAC BUS=$BUS_INFO"

# Set eth1 DOWN and bind to uio_hv_generic
ip link set eth1 down
ip link set $SECONDARY down
DEV_UUID=$(basename $(readlink /sys/class/net/eth1/device))
NET_UUID="f8615163-df3e-46c5-913f-f2d2f965ed0e"
modprobe uio_hv_generic
echo $NET_UUID > /sys/bus/vmbus/drivers/uio_hv_generic/new_id 2>/dev/null || true
echo $DEV_UUID > /sys/bus/vmbus/drivers/hv_netvsc/unbind
echo $DEV_UUID > /sys/bus/vmbus/drivers/uio_hv_generic/bind
echo "[6] eth1 -> uio_hv_generic"

# Run testpmd
rm -rf /var/run/dpdk
echo "[7] Starting dpdk-testpmd..."
timeout 25 dpdk-testpmd -l 0-1 \
  --huge-dir /dev/hugepages \
  --iova-mode va \
  --vdev="$BUS_INFO,mac=$MANA_MAC" \
  -- --forward-mode=txonly --auto-start \
  --txd=128 --rxd=128 \
  --stats 2 \
  --total-num-mbufs=2048 2>&1 || true

echo "[8] DONE"
