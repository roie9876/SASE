#!/bin/bash
# Debug VPP MANA dev_start failure
# Capture full EAL + MANA driver debug output
set -e

for pid in $(pgrep -x vpp 2>/dev/null || true); do kill -9 "$pid" 2>/dev/null || true; done
for pid in $(pgrep -x dpdk-testpmd 2>/dev/null || true); do kill -9 "$pid" 2>/dev/null || true; done
sleep 2
rm -rf /var/run/dpdk /run/vpp/cli.sock /tmp/vpp-mana.log /run/vpp/stats.sock /run/vpp/api.sock
echo $$ > /sys/fs/cgroup/cgroup.procs
echo 1024 | tee /sys/devices/system/node/node*/hugepages/hugepages-2048kB/nr_hugepages > /dev/null
ip link set enP30832s1d1 down 2>/dev/null || true

# Remove failsafe PMDs if they snuck back
rm -f /usr/local/lib/x86_64-linux-gnu/dpdk/pmds-25.0/librte_net_failsafe*
rm -f /usr/local/lib/x86_64-linux-gnu/dpdk/pmds-25.0/librte_net_tap*
rm -f /usr/local/lib/x86_64-linux-gnu/dpdk/pmds-25.0/librte_net_netvsc*
rm -f /usr/local/lib/x86_64-linux-gnu/dpdk/pmds-25.0/librte_net_vdev_netvsc*
ldconfig

mkdir -p /etc/vpp /run/vpp

# EAL --log-level to get MANA driver debug output
cat > /etc/vpp/startup.conf << 'EOF'
unix {
  nodaemon
  log /tmp/vpp-mana.log
  cli-listen /run/vpp/cli.sock
  full-coredump
  poll-sleep-usec 100
}
logging {
  default-log-level debug
  class dpdk { level debug }
}
buffers {
  buffers-per-numa 16384
  default data-size 2048
}
dpdk {
  dev 7870:00:00.0 {
    name mana0
    devargs mac=7c:ed:8d:25:e4:4d
    num-rx-queues 1
    num-tx-queues 1
  }
  no-tx-checksum-offload
  iova-mode va
  uio-driver auto
}
plugins {
  plugin dpdk_plugin.so { enable }
  plugin default { disable }
  plugin ping_plugin.so { enable }
}
EOF

echo "=== Starting VPP with full debug ==="
# Set EAL log level for MANA driver
export DPDK_LOG_LEVEL=8
vpp -c /etc/vpp/startup.conf > /tmp/vpp-stdout.log 2>&1 &
VPP_PID=$!
echo "PID=$VPP_PID"

for i in $(seq 1 20); do
    if timeout 3 vppctl show version >/dev/null 2>&1; then
        echo "CLI ready (${i}s)"
        break
    fi
    sleep 1
    if ! kill -0 $VPP_PID 2>/dev/null; then
        echo "CRASHED"
        cat /tmp/vpp-stdout.log 2>/dev/null
        exit 1
    fi
done

echo ""
echo "=== VPP show log (dpdk/mana lines) ==="
timeout 5 vppctl show log 2>&1 | grep -iE "dpdk|mana|queue|desc|configure|error|start|EAL" | head -40

echo ""
echo "=== Attempting admin up ==="
timeout 10 vppctl set interface state mana0 up 2>&1 || true

echo ""
echo "=== Post admin-up log ==="
timeout 5 vppctl show log 2>&1 | grep -iE "dpdk|mana|error|start|queue" | tail -20

echo ""
echo "=== Interface state ==="
timeout 5 vppctl show interface 2>&1 || true

echo ""
echo "=== stdout/EAL log ==="
grep -iE "MANA_DRIVER|EAL|mana_|create_cq|queue|error|fail|configure|start|desc" /tmp/vpp-stdout.log 2>/dev/null | head -40

echo ""
echo "=== Full VPP show log ==="
timeout 5 vppctl show log 2>&1 | head -80

echo ""
echo "=== CPU ==="
ps -p $VPP_PID -o pid=,pcpu=,stat= 2>/dev/null || echo "VPP died"
echo "PID=$VPP_PID"
