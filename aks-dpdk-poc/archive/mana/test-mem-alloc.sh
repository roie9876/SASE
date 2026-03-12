#!/bin/bash
# Test VPP with mem-alloc-request 512 (equivalent to testpmd's -m 512)
# This pre-allocates 512MB of EAL hugepage memory for MANA ibverbs DMA
set -e

for pid in $(pgrep -x vpp 2>/dev/null || true); do kill -9 "$pid" 2>/dev/null || true; done
sleep 2
rm -rf /var/run/dpdk /run/vpp/cli.sock /tmp/vpp-mana.log /run/vpp/stats.sock /run/vpp/api.sock
echo $$ > /sys/fs/cgroup/cgroup.procs
echo 1024 | tee /sys/devices/system/node/node*/hugepages/hugepages-2048kB/nr_hugepages > /dev/null
ip link set enP30832s1d1 down 2>/dev/null || true

rm -f /usr/local/lib/x86_64-linux-gnu/dpdk/pmds-25.0/librte_net_{failsafe,tap,netvsc,vdev_netvsc}*
ldconfig

mkdir -p /etc/vpp /run/vpp

cat > /etc/vpp/startup.conf << 'EOF'
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
    devargs mac=7c:ed:8d:25:e4:4d
    num-rx-queues 1
    num-tx-queues 1
  }
  no-tx-checksum-offload
  iova-mode va
  uio-driver auto
  mem-alloc-request 512
}
plugins {
  plugin dpdk_plugin.so { enable }
  plugin default { disable }
  plugin ping_plugin.so { enable }
}
EOF

echo "Starting VPP with mem-alloc-request 512..."
vpp -c /etc/vpp/startup.conf > /tmp/vpp-stdout.log 2>&1 &
VPP_PID=$!
echo "PID=$VPP_PID"

for i in $(seq 1 30); do
    if timeout 3 vppctl show version >/dev/null 2>&1; then
        echo "CLI ready (${i}s)"
        break
    fi
    sleep 1
    if ! kill -0 $VPP_PID 2>/dev/null; then
        echo "CRASHED - stdout:"
        tail -20 /tmp/vpp-stdout.log 2>/dev/null
        echo "---log:"
        cat /tmp/vpp-mana.log 2>/dev/null
        exit 1
    fi
done

echo ""
echo "=== admin up ==="
timeout 10 vppctl set interface state mana0 up 2>&1
echo "RC=$?"

timeout 5 vppctl set interface ip address mana0 10.120.3.10/24 2>&1 || true
sleep 2

echo ""
echo "=== interface ==="
timeout 5 vppctl show interface 2>&1

echo ""
echo "=== address ==="
timeout 5 vppctl show interface addr 2>&1

echo ""
echo "=== DPDK/MANA log ==="
timeout 5 vppctl show log 2>&1 | grep -iE "dpdk|mana|DMA|error|start|queue|EAL|memory" | head -30

echo ""
echo "=== CPU ==="
ps -p $VPP_PID -o pid=,pcpu=,stat= 2>/dev/null || echo "VPP died"
echo "PID=$VPP_PID"
