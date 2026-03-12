#!/bin/bash
set -euo pipefail

NODE_IP=${1:?usage: setup-branch-vxlan.sh <node-ip>}

sudo ip link del vxlan100 2>/dev/null || true
sudo ip -6 route del fc00::1/128 dev vxlan100 2>/dev/null || true
sudo ip route del 10.20.0.0/16 dev vxlan100 2>/dev/null || true

LOCAL_IP=$(ip -4 addr show eth0 | awk '/inet / {print $2}' | cut -d/ -f1 | head -1)

sudo ip link add vxlan100 type vxlan id 100 remote "$NODE_IP" local "$LOCAL_IP" dstport 8472 dev eth0
sudo ip addr add 10.50.0.2/30 dev vxlan100
sudo ip -6 addr add fc00::2/64 dev vxlan100
sudo ip link set vxlan100 mtu 1400
sudo ip link set vxlan100 up
sudo ethtool -K vxlan100 rx off tx off >/dev/null 2>&1 || true

sudo ip route add 10.20.0.0/16 via 10.50.0.1 dev vxlan100
sudo ip -6 route add fc00::1/128 dev vxlan100

echo "branch vxlan ready"
ip -br addr show vxlan100