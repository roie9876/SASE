#!/bin/bash
set -e

# Start VPP
vpp -c /etc/vpp/startup.conf &
sleep 3

# Configure VPP LAN/WAN
vppctl create host-interface name net1
vppctl set interface state host-net1 up
vppctl set interface ip address host-net1 10.20.0.254/16

vppctl create host-interface name net2
vppctl set interface state host-net2 up
vppctl set interface ip address host-net2 10.30.0.254/16

# Test LAN connectivity
vppctl ping 10.20.1.22 repeat 2

# Create Linux VXLAN on port 8472
POD_IP=$(ip -4 addr show eth0 | grep -oP '(?<=inet )\S+' | cut -d/ -f1)
echo "Pod IP: $POD_IP"
ip link add vxlan100 type vxlan id 100 remote 10.110.2.4 local $POD_IP dstport 8472 dev eth0
ip link set vxlan100 up
ip link set vxlan100 mtu 1400
ethtool -K vxlan100 rx off tx off 2>/dev/null || true

# VPP af-packet on VXLAN (VPP owns the IP, not Linux)
vppctl create host-interface name vxlan100
vppctl set interface state host-vxlan100 up
vppctl set interface ip address host-vxlan100 10.50.0.1/30

echo "=== DONE ==="
vppctl show interface addr
echo "=== ARP ==="
vppctl show ip neighbor
