#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update >/dev/null
apt-get install -y iproute2 ethtool iputils-ping python3 libunwind8 >/dev/null

export LD_LIBRARY_PATH=/usr/local/lib/x86_64-linux-gnu:/usr/local/lib:${LD_LIBRARY_PATH:-}

pkill -9 -f "vpp -c" 2>/dev/null || true
rm -f /run/vpp/cli.sock /tmp/vpp-node2.log
mkdir -p /etc/vpp /run/vpp

ip link set eth1 up
ip link set eth1 mtu 3900
ip link del vxlan200 2>/dev/null || true
ip link del dp0 2>/dev/null || true

ip link add dp0 link eth1 type macvlan mode bridge
ip link set dp0 up

ip link add vxlan200 type vxlan id 200 remote 10.120.3.4 local 10.120.3.5 dstport 8472 dev eth1
ip link set vxlan200 mtu 1450
ip link set vxlan200 up

for dev in eth1 dp0 vxlan200; do
  ethtool -K "$dev" tso off gso off gro off tx off rx off >/dev/null 2>&1 || true
done

python3 << 'PYEOF'
conf = '''unix {
  nodaemon
  log /tmp/vpp-node2.log
  cli-listen /run/vpp/cli.sock
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
}
'''
with open('/etc/vpp/startup.conf', 'w') as f:
    f.write(conf)
PYEOF

vpp -c /etc/vpp/startup.conf &

for _ in $(seq 1 20); do
  if vppctl show version >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

DP0_MAC=$(ip link show dp0 | awk '/link\/ether/ {print $2}')
VX200_MAC=$(ip link show vxlan200 | awk '/link\/ether/ {print $2}')

vppctl create host-interface name dp0 hw-addr "$DP0_MAC" || true
vppctl create host-interface name vxlan200 hw-addr "$VX200_MAC" || true
vppctl set interface state host-dp0 up
vppctl set interface state host-vxlan200 up
vppctl set interface ip address host-dp0 10.21.0.254/16 || true
vppctl set interface ip address host-vxlan200 10.60.0.2/30 || true
vppctl ip route add 10.20.0.0/16 via 10.60.0.1 host-vxlan200 || true

echo "node2 baseline restored"
vppctl show interface address