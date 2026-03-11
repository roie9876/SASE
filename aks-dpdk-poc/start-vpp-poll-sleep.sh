#!/bin/bash
# ============================================================================
# Start VPP with native MANA DPDK - with poll-sleep-usec to prevent CPU spin
# ============================================================================
set -e

echo "============================================"
echo " VPP MANA with poll-sleep-usec"
echo "============================================"

# Kill existing
for pid in $(pgrep -x vpp 2>/dev/null || true); do kill -9 "$pid" 2>/dev/null || true; done
for pid in $(pgrep -x dpdk-testpmd 2>/dev/null || true); do kill -9 "$pid" 2>/dev/null || true; done
sleep 2
rm -rf /var/run/dpdk /run/vpp/cli.sock /tmp/vpp-mana.log

# Cgroup escape
echo $$ > /sys/fs/cgroup/cgroup.procs

# Hugepages
echo 1024 | tee /sys/devices/system/node/node*/hugepages/hugepages-2048kB/nr_hugepages > /dev/null

# Bring VF down
ip link set enP30832s1d1 down 2>/dev/null || true

# Write config with poll-sleep-usec
mkdir -p /etc/vpp /run/vpp
cat > /etc/vpp/startup.conf << 'VPPEOF'
unix {
  nodaemon
  log /tmp/vpp-mana.log
  cli-listen /run/vpp/cli.sock
  full-coredump
  poll-sleep-usec 100
}
buffers {
  buffers-per-numa 16384
  default data-size 2048
}
dpdk {
  dev 7870:00:00.0 {
    name mana0
    devargs mac=60:45:bd:fd:d8:eb
    num-rx-queues 1
    num-tx-queues 1
  }
  iova-mode va
  uio-driver auto
}
plugins {
  plugin dpdk_plugin.so { enable }
  plugin default { disable }
  plugin ping_plugin.so { enable }
}
VPPEOF

# Start VPP
echo "Starting VPP..."
vpp -c /etc/vpp/startup.conf &
VPP_PID=$!
echo "PID=$VPP_PID"

# Wait for CLI
for i in $(seq 1 30); do
    if timeout 3 vppctl show version >/dev/null 2>&1; then
        echo "CLI ready (${i}s)"
        break
    fi
    sleep 1
done

# Configure interface
echo ""
echo "=== Bring up mana0 ==="
timeout 5 vppctl set interface state mana0 up 2>&1 || true
echo ""
echo "=== Assign IP 10.120.3.10/24 ==="
timeout 5 vppctl set interface ip address mana0 10.120.3.10/24 2>&1 || true

# Wait for settle
sleep 3

echo ""
echo "=== CPU check ==="
ps -p $VPP_PID -o pid=,pcpu=,stat= 2>/dev/null || echo "VPP not running"

echo ""
echo "=== Interface state ==="
timeout 5 vppctl show interface 2>&1 || echo "CLI timeout"

echo ""
echo "=== Interface address ==="
timeout 5 vppctl show interface addr 2>&1 || echo "CLI timeout"

echo ""
echo "=== Hardware ==="
timeout 5 vppctl show hardware-interfaces mana0 2>&1 || echo "CLI timeout"

echo ""
echo "=== IP FIB ==="
timeout 5 vppctl show ip fib 2>&1 | head -20 || echo "CLI timeout"

echo ""
echo "=== VPP Log ==="
cat /tmp/vpp-mana.log 2>/dev/null

echo ""
echo "============================================"
echo " VPP PID: $VPP_PID"
echo "============================================"
