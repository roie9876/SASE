#!/bin/bash
set -e

# Start VPP with the built MANA DPDK artifacts, then bring the dataplane
# interface up with a test IP for branch-vm reachability validation.

echo $$ > /sys/fs/cgroup/cgroup.procs
echo "[cgroup] Moved PID $$ to root cgroup: $(cat /proc/self/cgroup)"

pkill -9 -f "vpp -c" 2>/dev/null || true
sleep 1
rm -f /tmp/vpp-mana.log /run/vpp/cli.sock
rm -rf /var/run/dpdk
mkdir -p /etc/vpp /run/vpp

ip link set enP30832s1d1 down 2>/dev/null || true
echo "[nic] enP30832s1d1 set DOWN"

python3 << 'PYEOF'
conf = """unix {
  nodaemon
  log /tmp/vpp-mana.log
  cli-listen /run/vpp/cli.sock
  full-coredump
}
buffers {
  buffers-per-numa 16384
  default data-size 2048
}
dpdk {
  dev 7870:00:00.0 {
    name mana0
    devargs mac=60:45:bd:fd:d8:eb
  }
  iova-mode va
  uio-driver auto
}
plugins {
  plugin dpdk_plugin.so { enable }
  plugin default { disable }
  plugin ping_plugin.so { enable }
}
"""
with open("/etc/vpp/startup.conf", "w") as f:
    f.write(conf)
print("[config] VPP startup.conf written")
PYEOF

echo "[vpp] Starting VPP..."
vpp -c /etc/vpp/startup.conf &
VPP_PID=$!
echo "[vpp] PID: $VPP_PID"

for i in $(seq 1 30); do
    if vppctl show version > /dev/null 2>&1; then
        echo "[vpp] CLI ready (${i}s)"
        break
    fi
    sleep 1
    if ! kill -0 $VPP_PID 2>/dev/null; then
        echo "[vpp] CRASHED after ${i}s!"
        cat /tmp/vpp-mana.log 2>/dev/null
        exit 1
    fi
done

DPDK_IF=$(vppctl show interface | awk 'NR > 1 && $1 != "local0" { print $1; exit }')
if [ -z "$DPDK_IF" ]; then
    echo "[vpp] No dataplane interface found"
    vppctl show interface
    exit 1
fi

echo "[vpp] Detected dataplane interface: $DPDK_IF"
vppctl set interface state "$DPDK_IF" up
vppctl set interface ip address "$DPDK_IF" 10.120.3.10/24

echo ""
echo "============================================"
echo " VPP MANA L3 Validation"
echo "============================================"
vppctl show version 2>&1
echo ""
echo "Interface addresses:"
vppctl show interface addr 2>&1
echo ""
echo "Interfaces:"
vppctl show interface 2>&1
echo ""
echo "Hardware:"
vppctl show hardware-interfaces 2>&1
echo ""
echo "Neighbors:"
vppctl show ip neighbor 2>&1 || true
echo ""
echo "VPP PID: $VPP_PID"
echo "============================================"