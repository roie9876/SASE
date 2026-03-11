#!/bin/bash
# Start VPP with MANA DPDK kernel bypass
# Requirements:
#   1. Patched dpdk_plugin.so with MANA PCI whitelist
#   2. rdma-core v46 installed (MLX5_1.24 symbols)
#   3. Process moved to root cgroup for hugepage access

# Move to root cgroup FIRST (critical for hugepage access)
echo $$ > /sys/fs/cgroup/cgroup.procs
echo "[cgroup] Moved PID $$ to root cgroup: $(cat /proc/self/cgroup)"

# Kill old VPP/testpmd
pkill -9 -f "vpp -c" 2>/dev/null; pkill -9 testpmd 2>/dev/null
sleep 1
rm -f /tmp/vpp-mana.log /run/vpp/cli.sock
rm -rf /var/run/dpdk
mkdir -p /etc/vpp /run/vpp

# Set MANA VF down for DPDK
ip link set enP30832s1d1 down 2>/dev/null || true
echo "[nic] enP30832s1d1 set DOWN"

# Write VPP config
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
    devargs mac=7c:ed:8d:25:e4:4d
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

# Start VPP
echo "[vpp] Starting VPP..."
vpp -c /etc/vpp/startup.conf &
VPP_PID=$!
echo "[vpp] PID: $VPP_PID"

# Wait for CLI
for i in $(seq 1 30); do
    if vppctl show version > /dev/null 2>&1; then
        echo "[vpp] CLI ready (${i}s)"
        break
    fi
    sleep 1
    if ! kill -0 $VPP_PID 2>/dev/null; then
        echo "[vpp] CRASHED after ${i}s!"
        echo "=== VPP LOG ==="
        cat /tmp/vpp-mana.log 2>/dev/null
        exit 1
    fi
done

echo ""
echo "============================================"
echo " VPP with MANA DPDK - Status"
echo "============================================"
echo "Version:"
vppctl show version 2>&1 | sed 's/^/  /'
echo ""
echo "Interfaces:"
vppctl show interface 2>&1 | sed 's/^/  /'
echo ""
echo "Hardware:"
vppctl show hardware-interfaces 2>&1 | sed 's/^/  /'
echo ""
echo "VPP Log (last 10 lines):"
tail -10 /tmp/vpp-mana.log 2>/dev/null | sed 's/^/  /'
echo ""
echo "============================================"
echo " VPP PID: $VPP_PID"
echo "============================================"
