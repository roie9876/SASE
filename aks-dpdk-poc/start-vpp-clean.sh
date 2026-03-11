#!/bin/bash
# ============================================================================
# Start VPP with native MANA DPDK - CLEAN START (no testpmd first!)
# The MANA ibverbs CQ can only be created once per process lifetime.
# Running testpmd before VPP leaves stale ibverbs state.
# ============================================================================
set -e

echo "============================================"
echo " VPP MANA - Clean Start"
echo "============================================"

# --- Kill everything ---
echo "[1] Killing all DPDK processes..."
for pid in $(pgrep -x vpp 2>/dev/null || true); do kill -9 "$pid" 2>/dev/null || true; done
for pid in $(pgrep -x dpdk-testpmd 2>/dev/null || true); do kill -9 "$pid" 2>/dev/null || true; done
sleep 3

# --- Clean ALL DPDK state ---
echo "[2] Cleaning ALL DPDK state..."
rm -rf /var/run/dpdk
rm -rf /run/vpp/cli.sock
rm -f /tmp/vpp-mana.log
rm -f /dev/shm/dpdk_*
rm -f /run/vpp/stats.sock

# --- Cgroup escape ---
echo "[3] Escaping pod cgroup..."
echo $$ > /sys/fs/cgroup/cgroup.procs

# --- Hugepages ---
echo "[4] Allocating hugepages..."
echo 1024 | tee /sys/devices/system/node/node*/hugepages/hugepages-2048kB/nr_hugepages > /dev/null
grep HugePages_Total /proc/meminfo

# --- Verify failsafe PMDs removed ---
echo "[5] Checking PMDs..."
if ls /usr/local/lib/x86_64-linux-gnu/dpdk/pmds-25.0/librte_net_failsafe* 2>/dev/null; then
    echo "  Removing leftover failsafe PMDs..."
    rm -f /usr/local/lib/x86_64-linux-gnu/dpdk/pmds-25.0/librte_net_failsafe*
    rm -f /usr/local/lib/x86_64-linux-gnu/dpdk/pmds-25.0/librte_net_tap*
    rm -f /usr/local/lib/x86_64-linux-gnu/dpdk/pmds-25.0/librte_net_netvsc*
    rm -f /usr/local/lib/x86_64-linux-gnu/dpdk/pmds-25.0/librte_net_vdev_netvsc*
    ldconfig
fi
echo "  MANA: $(ls /usr/local/lib/x86_64-linux-gnu/dpdk/pmds-25.0/librte_net_mana.so 2>/dev/null || echo MISSING)"

# --- Install VPP ---
echo "[6] Installing VPP binaries..."
VPP_DIR=/tmp/vpp/build-root/install-vpp-native/vpp
if [ -d "$VPP_DIR" ]; then
    cp -a $VPP_DIR/bin/* /usr/local/bin/ 2>/dev/null || true
    cp -a $VPP_DIR/lib/* /usr/local/lib/ 2>/dev/null || true
fi
if [ -f /tmp/vpp/build-root/build-vpp-native/vpp/lib/x86_64-linux-gnu/vpp_plugins/dpdk_plugin.so ]; then
    cp -f /tmp/vpp/build-root/build-vpp-native/vpp/lib/x86_64-linux-gnu/vpp_plugins/dpdk_plugin.so \
          /usr/local/lib/x86_64-linux-gnu/vpp_plugins/dpdk_plugin.so
fi
ldconfig
echo "  VPP: $(vpp --version 2>&1 | head -1)"

# --- VF down ---
echo "[7] Setting enP30832s1d1 DOWN..."
ip link set enP30832s1d1 down 2>/dev/null || true

# --- Write VPP config ---
echo "[8] Writing VPP config..."
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
    devargs mac=7c:ed:8d:25:e4:4d
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

# --- Start VPP (NO testpmd first!) ---
echo "[9] Starting VPP directly..."
vpp -c /etc/vpp/startup.conf &
VPP_PID=$!
echo "  PID=$VPP_PID"

# Wait for CLI
for i in $(seq 1 30); do
    if timeout 3 vppctl show version >/dev/null 2>&1; then
        echo "  CLI ready (${i}s)"
        break
    fi
    sleep 1
    if ! kill -0 $VPP_PID 2>/dev/null; then
        echo "  VPP CRASHED!"
        cat /tmp/vpp-mana.log 2>/dev/null
        exit 1
    fi
done

# --- Bring up interface ---
echo ""
echo "[10] Bringing up mana0..."
timeout 10 vppctl set interface state mana0 up 2>&1
UP_RC=$?
if [ $UP_RC -ne 0 ]; then
    echo "  WARNING: set state returned $UP_RC"
    echo "  VPP stderr:"
    cat /tmp/vpp-mana.log 2>/dev/null | grep -i "error\|fail\|warn" | tail -5
fi

echo ""
echo "[11] Assigning IP 10.120.3.10/24..."
timeout 5 vppctl set interface ip address mana0 10.120.3.10/24 2>&1 || true

sleep 2

# --- Show results ---
echo ""
echo "============================================"
echo "         RESULTS"
echo "============================================"
echo ""
echo "CPU:"
ps -p $VPP_PID -o pid=,pcpu=,stat= 2>/dev/null
echo ""
echo "Interfaces:"
timeout 5 vppctl show interface 2>&1
echo ""
echo "Address:"
timeout 5 vppctl show interface addr 2>&1
echo ""
echo "Hardware:"
timeout 5 vppctl show hardware-interfaces mana0 2>&1 | head -30
echo ""
echo "IP FIB:"
timeout 5 vppctl show ip fib 2>&1 | head -20
echo ""
echo "VPP Log:"
cat /tmp/vpp-mana.log 2>/dev/null
echo ""
echo "============================================"
echo " VPP PID: $VPP_PID"
echo "============================================"
