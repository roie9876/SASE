#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export LD_LIBRARY_PATH=/usr/local/lib/x86_64-linux-gnu:/usr/local/lib:${LD_LIBRARY_PATH:-}

pkill -9 -f "vpp -c" 2>/dev/null || true
rm -f /run/vpp/cli.sock /tmp/vpp-phase1.log
sleep 1
mkdir -p /etc/vpp /run/vpp

ip link del vpp-ul0 2>/dev/null || true
ip link del linux-ul0 2>/dev/null || true
ip link del dp0 2>/dev/null || true
ip link del vxlan100 2>/dev/null || true
ip link del ul0 2>/dev/null || true

ip link set eth1 up
ip link set eth1 mtu 3900

# Macvlan for underlay - uses kernel TX path, not raw socket
ip link add ul0 link eth1 type macvlan mode bridge
ip link set ul0 up

# Macvlan for pod dataplane
ip link add dp0 link eth1 type macvlan mode bridge
ip link set dp0 up

# Branch VXLAN
ip link add vxlan100 type vxlan id 100 remote 10.120.4.4 local 10.120.3.4 dstport 8472 dev eth1
ip link set vxlan100 mtu 1450
ip link set vxlan100 up

ip rule add from 10.120.3.4/32 table 100 2>/dev/null || true
ip route add 10.120.3.0/24 dev eth1 src 10.120.3.4 table 100 2>/dev/null || true
ip route add default via 10.120.3.1 dev eth1 table 100 2>/dev/null || true

for dev in eth1 ul0 dp0 vxlan100; do
  ethtool -K "$dev" tso off gso off gro off tx off rx off >/dev/null 2>&1 || true
done

python3 << 'PYEOF'
conf = '''unix {
  nodaemon
  log /tmp/vpp-phase1.log
  cli-listen /run/vpp/cli.sock
  poll-sleep-usec 100
}
buffers {
  buffers-per-numa 16384
  page-size 4K
}
plugins {
  plugin dpdk_plugin.so { disable }
  plugin default { disable }
  plugin af_packet_plugin.so { enable }
  plugin ping_plugin.so { enable }
  plugin vxlan_plugin.so { enable }
}
'''
with open('/etc/vpp/startup.conf', 'w') as f:
    f.write(conf)
PYEOF

vpp -c /etc/vpp/startup.conf &
for _ in $(seq 1 20); do
  if vppctl show version >/dev/null 2>&1; then break; fi
  sleep 1
done

UL0_MAC=$(ip link show ul0 | awk '/link\/ether/ {print $2}')
DP0_MAC=$(ip link show dp0 | awk '/link\/ether/ {print $2}')
VX100_MAC=$(ip link show vxlan100 | awk '/link\/ether/ {print $2}')

vppctl create host-interface name ul0 hw-addr "$UL0_MAC"
vppctl create host-interface name dp0 hw-addr "$DP0_MAC"
vppctl create host-interface name vxlan100 hw-addr "$VX100_MAC"

vppctl set interface state host-ul0 up
vppctl set interface state host-dp0 up
vppctl set interface state host-vxlan100 up

vppctl set interface ip address host-ul0 10.120.3.4/24
vppctl set interface ip address host-dp0 10.20.0.254/16
vppctl set interface ip address host-vxlan100 10.50.0.1/30
vppctl enable ip6 interface host-vxlan100
vppctl set interface ip address host-vxlan100 fc00::1/64
vppctl sr localsid address fc00::a:1:e004 behavior end.dt4 0

vppctl set ip neighbor host-ul0 10.120.3.5 7c:ed:8d:9d:9c:0c

vppctl create vxlan tunnel src 10.120.3.4 dst 10.120.3.5 vni 200 instance 200 encap-vrf-id 0 l3
vppctl set interface state vxlan_tunnel200 up
vppctl set interface ip address vxlan_tunnel200 10.60.0.1/30
vppctl ip route add 10.21.0.0/16 via 10.60.0.2 vxlan_tunnel200

echo "=== NODE1 MACVLAN UNDERLAY ==="
vppctl show interface address
echo "---tunnel---"
vppctl show vxlan tunnel

echo "=== TX TEST ==="
timeout 8 tcpdump -ni eth1 icmp -c 10 &
sleep 1
vppctl ping 10.120.3.5 source host-ul0 repeat 3 verbose
sleep 4
wait
