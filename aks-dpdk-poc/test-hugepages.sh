#!/bin/bash
# Test hugepage allocation and DPDK MANA
set -x

echo "=== Test 1: hugepage via /mnt/huge ==="
mkdir -p /mnt/huge
mount -t hugetlbfs nodev /mnt/huge 2>&1
dd if=/dev/zero of=/mnt/huge/test bs=2M count=1 2>&1
echo "dd rc=$?"
rm -f /mnt/huge/test

echo "=== Test 2: hugepage via /host/dev/hugepages ==="
dd if=/dev/zero of=/host/dev/hugepages/test bs=2M count=1 2>&1
echo "dd rc=$?"
rm -f /host/dev/hugepages/test

echo "=== Test 3: DPDK testpmd with hugedir=/mnt/huge ==="
pkill -9 testpmd 2>/dev/null; rm -rf /var/run/dpdk; sleep 1
ip link set enP30832s1d1 down 2>/dev/null
timeout 15 dpdk-testpmd -l 0-1 \
    --vdev="7870:00:00.0,mac=7c:ed:8d:25:e4:4d" \
    --no-pci --iova-mode va \
    --huge-dir=/mnt/huge -m 512 \
    -- --no-start --txd=128 --rxd=128 2>&1
echo "testpmd rc=$?"
pkill -9 testpmd 2>/dev/null; rm -rf /var/run/dpdk

echo "=== Test 4: DPDK testpmd with hugedir=/host/dev/hugepages ==="
sleep 1
timeout 15 dpdk-testpmd -l 0-1 \
    --vdev="7870:00:00.0,mac=7c:ed:8d:25:e4:4d" \
    --no-pci --iova-mode va \
    --huge-dir=/host/dev/hugepages -m 512 \
    -- --no-start --txd=128 --rxd=128 2>&1
echo "testpmd rc=$?"
pkill -9 testpmd 2>/dev/null

echo "=== DONE ==="
