#!/bin/bash
# MANA DPDK testpmd on eth1 (secondary NIC)
# eth0 stays UP for Kubernetes management
set -x

PRIMARY="eth1"
SECONDARY=$(ip -br link show master $PRIMARY | awk '{ print $1 }')
MANA_MAC=$(ip -br link show master $PRIMARY | awk '{ print $3 }')
BUS_INFO=$(ethtool -i $SECONDARY | grep bus-info | awk '{ print $2 }')

echo "PRIMARY: $PRIMARY"
echo "SECONDARY: $SECONDARY"
echo "MANA_MAC: $MANA_MAC"
echo "BUS_INFO: $BUS_INFO"

# Set eth1 interfaces DOWN (eth0 stays UP for K8s)
ip link set $PRIMARY down
ip link set $SECONDARY down
echo "eth1 interfaces DOWN"

# Move eth1 synthetic channel to uio_hv_generic
DEV_UUID=$(basename $(readlink /sys/class/net/$PRIMARY/device))
NET_UUID="f8615163-df3e-46c5-913f-f2d2f965ed0e"
echo "DEV_UUID: $DEV_UUID"

# Load uio_hv_generic from host kernel
chroot /host modprobe uio_hv_generic
echo $NET_UUID > /sys/bus/vmbus/drivers/uio_hv_generic/new_id 2>/dev/null || true
echo $DEV_UUID > /sys/bus/vmbus/drivers/hv_netvsc/unbind 2>/dev/null
echo $DEV_UUID > /sys/bus/vmbus/drivers/uio_hv_generic/bind 2>/dev/null
echo "netvsc for eth1 moved to uio_hv_generic"

# Ensure hugepages are allocated
echo 1024 | tee /sys/devices/system/node/node*/hugepages/hugepages-2048kB/nr_hugepages > /dev/null
echo "HugePages: $(grep HugePages_Total /proc/meminfo)"

# Run testpmd on MANA eth1
echo ""
echo "=== Starting dpdk-testpmd on eth1 ==="
timeout 20 dpdk-testpmd -l 0-1 --vdev="$BUS_INFO,mac=$MANA_MAC" -- --forward-mode=txonly --auto-start --txd=128 --rxd=128 --stats 2 2>&1
echo "=== testpmd finished ==="
