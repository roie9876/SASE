#!/bin/bash
# Test DPDK MANA with hugepages after moving to root cgroup
# This script MUST move itself to the root cgroup for hugepage access

# Move to root cgroup (escape pod's cgroup restrictions)
echo $$ > /sys/fs/cgroup/cgroup.procs
echo "Moved PID $$ to root cgroup"
cat /proc/self/cgroup

# Clean up
pkill -9 testpmd 2>/dev/null; pkill -9 vpp 2>/dev/null
rm -rf /var/run/dpdk
sleep 1

# Set MANA VF down
ip link set enP30832s1d1 down 2>/dev/null

echo "=== Testing DPDK MANA with PCI mode + hugepages ==="
# Use -a (allow) with mac filter, MANA PCI address
# Remove --no-start (invalid for this version)
timeout 20 dpdk-testpmd -l 0-1 \
    -a 7870:00:00.0,mac=7c:ed:8d:25:e4:4d \
    --iova-mode va \
    -m 512 \
    -- --auto-start --txd=128 --rxd=128 \
    > /tmp/testpmd-mana.log 2>&1
echo "testpmd RC=$?"

echo "=== TESTPMD OUTPUT ==="
cat /tmp/testpmd-mana.log
echo "=== END ==="
