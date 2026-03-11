#!/bin/bash
# Start VPP with 128 descriptors (matching testpmd working config)
set -e

for pid in $(pgrep -x vpp 2>/dev/null || true); do kill -9 "$pid" 2>/dev/null || true; done
sleep 2
rm -rf /var/run/dpdk /run/vpp/cli.sock /tmp/vpp-mana.log /run/vpp/stats.sock /run/vpp/api.sock
echo $$ > /sys/fs/cgroup/cgroup.procs
echo 1024 | tee /sys/devices/system/node/node*/hugepages/hugepages-2048kB/nr_hugepages > /dev/null
ip link set enP30832s1d1 down 2>/dev/null || true
mkdir -p /etc/vpp /run/vpp

cat > /etc/vpp/startup.conf << 'EOF'
unix {
  nodaemon
  log /tmp/vpp-mana.log
  cli-listen /run/vpp/cli.sock
  full-coredump
  poll-sleep-usec 100
}
logging {
  default-log-level info
  class dpdk { level debug }
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
    num-rx-desc 128
    num-tx-desc 128
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

echo "Starting VPP with 128 descriptors..."
vpp -c /etc/vpp/startup.conf > /tmp/vpp-stdout.log 2>&1 &
VPP_PID=$!
echo "PID=$VPP_PID"

for i in $(seq 1 20); do
    if timeout 3 vppctl show version >/dev/null 2>&1; then echo "CLI ready (${i}s)"; break; fi
    sleep 1
    if ! kill -0 $VPP_PID 2>/dev/null; then echo "CRASHED"; cat /tmp/vpp-mana.log 2>/dev/null; exit 1; fi
done

echo "=== bring up mana0 ==="
timeout 10 vppctl set interface state mana0 up 2>&1 || true
echo "=== assign IP ==="
timeout 5 vppctl set interface ip address mana0 10.120.3.10/24 2>&1 || true
sleep 2

echo "=== interface ==="
timeout 5 vppctl show interface 2>&1
echo "=== address ==="
timeout 5 vppctl show interface addr 2>&1
echo "=== hardware ==="
timeout 5 vppctl show hardware-interfaces 2>&1 | head -30
echo "=== cpu ==="
ps -p $VPP_PID -o pid=,pcpu=,stat= 2>/dev/null
echo "=== dpdk log ==="
timeout 5 vppctl show log 2>&1 | grep -iE "dpdk|mana|error|queue|desc|configure" | head -20
echo "PID=$VPP_PID"
