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

UNDERLAY_DEV=${UNDERLAY_DEV:-eth1}
UNDERLAY_IP=${UNDERLAY_IP:-10.120.3.5}
UNDERLAY_MTU=${UNDERLAY_MTU:-3900}
EAST_WEST_REMOTE_UNDERLAY_IP=${EAST_WEST_REMOTE_UNDERLAY_IP:-10.120.3.4}
EAST_WEST_REMOTE_UNDERLAY_MAC=${EAST_WEST_REMOTE_UNDERLAY_MAC:-7c:ed:8d:25:e4:4d}
EAST_WEST_REMOTE_TUNNEL_IP=${EAST_WEST_REMOTE_TUNNEL_IP:-10.60.0.1}

pkill -9 -f "vpp -c" 2>/dev/null || true
rm -f /run/vpp/cli.sock /tmp/vpp-node2.log
mkdir -p /etc/vpp /run/vpp

ip link set "$UNDERLAY_DEV" up
ip link set "$UNDERLAY_DEV" mtu "$UNDERLAY_MTU"
ip link del vxlan200 2>/dev/null || true
ip link del dp0 2>/dev/null || true

ip link add dp0 link "$UNDERLAY_DEV" type macvlan mode bridge
ip link set dp0 up

for dev in "$UNDERLAY_DEV" dp0; do
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
  plugin vxlan_plugin.so { enable }
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

LINUX_DP0_MAC=$(ip link show dp0 | awk '/link\/ether/ {print $2}')
LINUX_ETH1_MAC=$(ip link show "$UNDERLAY_DEV" | awk '/link\/ether/ {print $2}')

vppctl create host-interface name eth1 hw-addr "$LINUX_ETH1_MAC" || true
vppctl create host-interface name dp0 hw-addr "$LINUX_DP0_MAC" || true

vppctl set interface state host-eth1 up
vppctl set interface state host-dp0 up

vppctl set interface ip address host-eth1 ${UNDERLAY_IP}/24 || true
vppctl set interface ip address host-dp0 10.21.0.254/16 || true
vppctl set ip neighbor host-eth1 ${EAST_WEST_REMOTE_UNDERLAY_IP} ${EAST_WEST_REMOTE_UNDERLAY_MAC}

vppctl create vxlan tunnel src ${UNDERLAY_IP} dst ${EAST_WEST_REMOTE_UNDERLAY_IP} vni 200 instance 200 encap-vrf-id 0 l3 || true
vppctl set interface state vxlan_tunnel200 up
vppctl set interface ip address vxlan_tunnel200 10.60.0.2/30 || true
vppctl ip route add 10.20.0.0/16 via ${EAST_WEST_REMOTE_TUNNEL_IP} vxlan_tunnel200 || true

echo "scenario05-node2 ready"
vppctl show interface address
echo ---
vppctl show ip fib 10.20.1.20
echo ---
vppctl show ip neighbors