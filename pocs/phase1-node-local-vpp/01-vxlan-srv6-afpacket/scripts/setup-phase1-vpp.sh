#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update >/dev/null
apt-get install -y iproute2 ethtool iputils-ping python3 libunwind8 >/dev/null

if [ -f /host/tmp/vpp-dpdk-all.tar.gz ]; then
  tar xzf /host/tmp/vpp-dpdk-all.tar.gz -C /
  ldconfig
fi

export LD_LIBRARY_PATH=/usr/local/lib/x86_64-linux-gnu:/usr/local/lib:${LD_LIBRARY_PATH:-}

pkill -9 -f "vpp -c" 2>/dev/null || true
rm -f /run/vpp/cli.sock /tmp/vpp-phase1.log
mkdir -p /etc/vpp /run/vpp

ip link del vxlan100 2>/dev/null || true
ip link del dp0 2>/dev/null || true

ip link set eth1 up
ip link add dp0 link eth1 type macvlan mode bridge
ip link set dp0 up

python3 << 'PYEOF'
conf = '''unix {
  nodaemon
  log /tmp/vpp-phase1.log
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

for _ in $(seq 1 15); do
  if vppctl show version >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

POD_IP=$(ip -4 addr show eth0 | awk '/inet / {print $2}' | cut -d/ -f1 | head -1)
BRANCH_IP=${BRANCH_IP:-10.120.4.4}

ip link add vxlan100 type vxlan id 100 remote "$BRANCH_IP" local "$POD_IP" dstport 8472 dev eth0
ip link set vxlan100 mtu 1400
ip link set vxlan100 up
ethtool -K vxlan100 rx off tx off >/dev/null 2>&1 || true

vppctl create host-interface name vxlan100
vppctl set interface state host-vxlan100 up
vppctl set interface ip address host-vxlan100 10.50.0.1/30
vppctl enable ip6 interface host-vxlan100
vppctl set interface ip address host-vxlan100 fc00::1/64
vppctl sr localsid address fc00::a:1:e004 behavior end.dt4 0

vppctl create host-interface name dp0
vppctl set interface state host-dp0 up
vppctl set interface ip address host-dp0 10.20.0.254/16

LINUX_MAC=$(ip link show dp0 | awk '/link\/ether/ {print $2}')
vppctl set interface mac address host-dp0 "$LINUX_MAC"

echo "phase1-vpp ready"
vppctl show interface