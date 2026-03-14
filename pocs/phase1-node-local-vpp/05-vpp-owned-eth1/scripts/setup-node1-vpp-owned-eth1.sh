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
UNDERLAY_IP=${UNDERLAY_IP:-10.120.3.4}
UNDERLAY_GW=${UNDERLAY_GW:-10.120.3.1}
UNDERLAY_MTU=${UNDERLAY_MTU:-3900}
BRANCH_IP=${BRANCH_IP:-10.120.4.4}
BRANCH_VXLAN_MTU=${BRANCH_VXLAN_MTU:-1450}
EAST_WEST_REMOTE_UNDERLAY_IP=${EAST_WEST_REMOTE_UNDERLAY_IP:-10.120.3.5}
EAST_WEST_REMOTE_UNDERLAY_MAC=${EAST_WEST_REMOTE_UNDERLAY_MAC:-7c:ed:8d:9d:9c:0c}
EAST_WEST_REMOTE_TUNNEL_IP=${EAST_WEST_REMOTE_TUNNEL_IP:-10.60.0.2}

pkill -9 -f "vpp -c" 2>/dev/null || true
rm -f /run/vpp/cli.sock /tmp/vpp-phase1.log
mkdir -p /etc/vpp /run/vpp

ip link set "$UNDERLAY_DEV" up
ip link set "$UNDERLAY_DEV" mtu "$UNDERLAY_MTU"
ip link del vxlan200 2>/dev/null || true
ip link del dp0 2>/dev/null || true

ip rule add from "$UNDERLAY_IP"/32 table 100 2>/dev/null || true
ip route add ${UNDERLAY_IP%.*}.0/24 dev "$UNDERLAY_DEV" src "$UNDERLAY_IP" table 100 2>/dev/null || true
ip route add default via "$UNDERLAY_GW" dev "$UNDERLAY_DEV" table 100 2>/dev/null || true

ip link add dp0 link "$UNDERLAY_DEV" type macvlan mode bridge
ip link set dp0 up

ip link del vxlan100 2>/dev/null || true
ip link add vxlan100 type vxlan id 100 remote "$BRANCH_IP" local "$UNDERLAY_IP" dstport 8472 dev "$UNDERLAY_DEV"
ip link set vxlan100 mtu "$BRANCH_VXLAN_MTU"
ip link set vxlan100 up

for dev in "$UNDERLAY_DEV" dp0 vxlan100; do
  ethtool -K "$dev" tso off gso off gro off tx off rx off >/dev/null 2>&1 || true
done

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
LINUX_VXLAN100_MAC=$(ip link show vxlan100 | awk '/link\/ether/ {print $2}')

vppctl create host-interface name eth1 hw-addr "$LINUX_ETH1_MAC" || true
vppctl create host-interface name dp0 hw-addr "$LINUX_DP0_MAC" || true
vppctl create host-interface name vxlan100 hw-addr "$LINUX_VXLAN100_MAC" || true

vppctl set interface state host-eth1 up
vppctl set interface state host-dp0 up
vppctl set interface state host-vxlan100 up

vppctl set interface ip address host-eth1 ${UNDERLAY_IP}/24 || true
vppctl set interface ip address host-dp0 10.20.0.254/16 || true
vppctl set interface ip address host-vxlan100 10.50.0.1/30 || true
vppctl enable ip6 interface host-vxlan100
vppctl set interface ip address host-vxlan100 fc00::1/64 || true
vppctl sr localsid address fc00::a:1:e004 behavior end.dt4 0 || true

vppctl set ip neighbor host-eth1 ${EAST_WEST_REMOTE_UNDERLAY_IP} ${EAST_WEST_REMOTE_UNDERLAY_MAC}

vppctl create vxlan tunnel src ${UNDERLAY_IP} dst ${EAST_WEST_REMOTE_UNDERLAY_IP} vni 200 instance 200 encap-vrf-id 0 l3 || true
vppctl set interface state vxlan_tunnel200 up
vppctl set interface ip address vxlan_tunnel200 10.60.0.1/30 || true
vppctl ip route add 10.21.0.0/16 via ${EAST_WEST_REMOTE_TUNNEL_IP} vxlan_tunnel200 || true

echo "scenario05-node1 ready"
vppctl show interface address
echo ---
vppctl show ip fib 10.21.1.20
echo ---
vppctl show ip neighbors