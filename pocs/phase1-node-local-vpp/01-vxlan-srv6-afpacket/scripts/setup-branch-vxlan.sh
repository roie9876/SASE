#!/bin/bash
set -euo pipefail

NODE_IP=${1:?usage: setup-branch-vxlan.sh <node-ip>}
UNDERLAY_DEV=${UNDERLAY_DEV:-eth0}
UNDERLAY_MTU=${UNDERLAY_MTU:-3900}
VXLAN_MTU=${VXLAN_MTU:-1450}
ROUTE_MTU=${ROUTE_MTU:-1386}
ROUTE_ADVMSS=${ROUTE_ADVMSS:-1346}

sudo ip link del vxlan100 2>/dev/null || true
sudo ip -6 route del fc00::a:1:e004/128 dev vxlan100 2>/dev/null || true
sudo ip route del 10.20.0.0/16 dev vxlan100 2>/dev/null || true

LOCAL_IP=$(ip -4 addr show "$UNDERLAY_DEV" | awk '/inet / {print $2}' | cut -d/ -f1 | head -1)

sudo ip link set "$UNDERLAY_DEV" mtu "$UNDERLAY_MTU"
sudo ip link add vxlan100 type vxlan id 100 remote "$NODE_IP" local "$LOCAL_IP" dstport 8472 dev "$UNDERLAY_DEV"
sudo ip addr add 10.50.0.2/30 dev vxlan100
sudo ip -6 addr add fc00::2/64 dev vxlan100
sudo ip link set vxlan100 mtu "$VXLAN_MTU"
sudo ip link set vxlan100 up
for dev in "$UNDERLAY_DEV" vxlan100; do
	sudo ethtool -K "$dev" tso off gso off gro off tx off rx off >/dev/null 2>&1 || true
done

sudo ip -6 route add fc00::a:1:e004/128 via fc00::1 dev vxlan100
sudo ip route add 10.20.0.0/16 encap seg6 mode encap segs fc00::a:1:e004 dev vxlan100 mtu "$ROUTE_MTU" advmss "$ROUTE_ADVMSS"
sudo sysctl -w net.ipv4.tcp_mtu_probing=1 >/dev/null

echo "branch vxlan ready"
ip -br addr show "$UNDERLAY_DEV" vxlan100