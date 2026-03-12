#!/bin/bash
# Start VPP with patched MANA DPDK support
# The patched dpdk_plugin.so must already be installed at:
#   /usr/local/lib/x86_64-linux-gnu/vpp_plugins/dpdk_plugin.so

echo "[1] Stopping old VPP..."
pkill -9 -f "vpp -c" 2>/dev/null || true
sleep 1
rm -f /tmp/vpp-mana.log /run/vpp/cli.sock
rm -rf /var/run/dpdk

echo "[2] VPP version: $(vpp --version 2>&1 | head -1)"

echo "[3] Setting MANA VF down..."
ip link set enP30832s1d1 down 2>/dev/null || true

echo "[4] Writing VPP config..."
mkdir -p /etc/vpp /run/vpp
python3 -c "
conf = '''unix {
  nodaemon
  log /tmp/vpp-mana.log
  cli-listen /run/vpp/cli.sock
  full-coredump
}
buffers {
  buffers-per-numa 16384
  page-size 4K
}
dpdk {
  dev 7870:00:00.0 {
    name mana0
  }
  no-hugetlb
  iova-mode va
  uio-driver auto
}
plugins {
  plugin dpdk_plugin.so { enable }
  plugin default { disable }
  plugin ping_plugin.so { enable }
}
'''
with open('/etc/vpp/startup.conf', 'w') as f:
    f.write(conf)
print('  Config written')
"

echo "[5] Starting VPP..."
vpp -c /etc/vpp/startup.conf &
VPP_PID=$!
echo "  PID: $VPP_PID"

echo "[6] Waiting for CLI..."
for i in $(seq 1 20); do
    if vppctl show version > /dev/null 2>&1; then
        echo "  CLI ready (${i}s)"
        break
    fi
    sleep 1
    if ! kill -0 $VPP_PID 2>/dev/null; then
        echo "  VPP CRASHED after ${i}s!"
        echo "=== LOG ==="
        cat /tmp/vpp-mana.log 2>/dev/null
        exit 1
    fi
done

echo ""
echo "=== VPP Interfaces ==="
vppctl show interface 2>&1
echo ""
echo "=== VPP Hardware ==="
vppctl show hardware-interfaces 2>&1
echo ""
echo "=== VPP Log ==="
cat /tmp/vpp-mana.log 2>/dev/null | head -20
echo ""
echo "=== DONE, VPP PID: $VPP_PID ==="
