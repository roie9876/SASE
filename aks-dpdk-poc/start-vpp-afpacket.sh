#!/bin/bash
# Start VPP with af_packet on MANA VF (no DPDK needed)
# This is a working E2E test path while DPDK hugepage issue is resolved

pkill -9 -f "vpp -c" 2>/dev/null; sleep 1
rm -f /tmp/vpp-mana.log /run/vpp/cli.sock
rm -rf /var/run/dpdk
mkdir -p /etc/vpp /run/vpp

# Bring MANA VF up for af_packet
ip link set enP30832s1d1 up 2>/dev/null || true
ip addr add 10.120.3.10/24 dev enP30832s1d1 2>/dev/null || true

# Write config using python to avoid heredoc issues
python3 << 'PYEOF'
conf = """unix {
  nodaemon
  log /tmp/vpp-mana.log
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
"""
with open("/etc/vpp/startup.conf", "w") as f:
    f.write(conf)
print("Config written")
PYEOF

echo "Starting VPP..."
vpp -c /etc/vpp/startup.conf &
VPP_PID=$!
echo "VPP PID: $VPP_PID"

for i in $(seq 1 10); do
    if vppctl show version > /dev/null 2>&1; then
        echo "CLI ready (${i}s)"
        break
    fi
    sleep 1
    if ! kill -0 $VPP_PID 2>/dev/null; then
        echo "CRASHED at ${i}s"
        cat /tmp/vpp-mana.log
        exit 1
    fi
done

echo "=== Creating af_packet on enP30832s1d1 ==="
vppctl create host-interface name enP30832s1d1
vppctl set interface state host-enP30832s1d1 up
vppctl set interface ip address host-enP30832s1d1 10.120.3.10/24

echo "=== Interfaces ==="
vppctl show interface
echo "=== Hardware ==="
vppctl show hardware-interfaces
echo "=== IP fib ==="
vppctl show ip fib summary
echo "=== DONE, VPP PID: $VPP_PID ==="
