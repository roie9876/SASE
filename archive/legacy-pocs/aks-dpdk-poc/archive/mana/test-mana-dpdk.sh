#!/bin/bash
# MANA DPDK testpmd setup - following Microsoft docs
# https://learn.microsoft.com/en-us/azure/virtual-network/setup-dpdk-mana

set -e

PRIMARY="eth0"
SECONDARY=$(ip -br link show master $PRIMARY | awk '{ print $1 }')
MANA_MAC=$(ip -br link show master $PRIMARY | awk '{ print $3 }')
BUS_INFO=$(ethtool -i $SECONDARY | grep bus-info | awk '{ print $2 }')

echo "PRIMARY: $PRIMARY"
echo "SECONDARY: $SECONDARY"
echo "MANA_MAC: $MANA_MAC"
echo "BUS_INFO: $BUS_INFO"

# Set interfaces DOWN
echo "Setting interfaces DOWN..."
ip link set $PRIMARY down
ip link set $SECONDARY down
echo "Interfaces DOWN"

# Move synthetic channel to user mode (uio_hv_generic)
DEV_UUID=$(basename $(readlink /sys/class/net/$PRIMARY/device))
NET_UUID="f8615163-df3e-46c5-913f-f2d2f965ed0e"
echo "DEV_UUID: $DEV_UUID"

modprobe uio_hv_generic
echo $NET_UUID > /sys/bus/vmbus/drivers/uio_hv_generic/new_id
echo $DEV_UUID > /sys/bus/vmbus/drivers/hv_netvsc/unbind
echo $DEV_UUID > /sys/bus/vmbus/drivers/uio_hv_generic/bind
echo "netvsc moved to uio_hv_generic"

# Run testpmd
echo ""
echo "=== Starting dpdk-testpmd ==="
timeout 15 dpdk-testpmd -l 0-1 --vdev="$BUS_INFO,mac=$MANA_MAC" -- --forward-mode=txonly --auto-start --txd=128 --rxd=128 --stats 2 2>&1 || true
echo "=== testpmd finished ==="
