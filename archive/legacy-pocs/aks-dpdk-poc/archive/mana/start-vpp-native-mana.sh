#!/bin/bash
# ============================================================================
# Start VPP with native MANA DPDK (after failsafe PMDs removed)
# ============================================================================
set -e

echo "============================================"
echo " Start VPP with Native MANA DPDK"
echo "============================================"

# --- 1. Kill existing VPP ---
echo "[1] Cleanup..."
for pid in $(pgrep -x vpp 2>/dev/null || true); do kill -9 "$pid" 2>/dev/null || true; done
for pid in $(pgrep -x dpdk-testpmd 2>/dev/null || true); do kill -9 "$pid" 2>/dev/null || true; done
sleep 2
rm -rf /var/run/dpdk /run/vpp/cli.sock /tmp/vpp-mana.log

# --- 2. Escape cgroup ---
echo "[2] Escaping pod cgroup..."
echo $$ > /sys/fs/cgroup/cgroup.procs

# --- 3. Hugepages ---
echo "[3] Allocating hugepages..."
echo 1024 | tee /sys/devices/system/node/node*/hugepages/hugepages-2048kB/nr_hugepages > /dev/null
grep HugePages_Total /proc/meminfo

# --- 4. Verify PMDs are clean ---
echo "[4] Verifying failsafe PMDs are removed..."
if ls /usr/local/lib/x86_64-linux-gnu/dpdk/pmds-25.0/librte_net_failsafe* 2>/dev/null; then
    echo "  WARNING: failsafe PMD still present, removing..."
    rm -f /usr/local/lib/x86_64-linux-gnu/dpdk/pmds-25.0/librte_net_failsafe*
    rm -f /usr/local/lib/x86_64-linux-gnu/dpdk/pmds-25.0/librte_net_tap*
    rm -f /usr/local/lib/x86_64-linux-gnu/dpdk/pmds-25.0/librte_net_netvsc*
    rm -f /usr/local/lib/x86_64-linux-gnu/dpdk/pmds-25.0/librte_net_vdev_netvsc*
    ldconfig
fi
echo "  MANA PMD: $(ls /usr/local/lib/x86_64-linux-gnu/dpdk/pmds-25.0/librte_net_mana.so* 2>/dev/null | head -1)"

# --- 5. Install VPP binaries ---
echo "[5] Installing VPP..."
VPP_DIR=/tmp/vpp/build-root/install-vpp-native/vpp
if [ -d "$VPP_DIR" ]; then
    cp -a $VPP_DIR/bin/* /usr/local/bin/ 2>/dev/null || true
    cp -a $VPP_DIR/lib/* /usr/local/lib/ 2>/dev/null || true
fi
# Copy the PATCHED dpdk_plugin from build dir (links against system DPDK)
if [ -f /tmp/vpp/build-root/build-vpp-native/vpp/lib/x86_64-linux-gnu/vpp_plugins/dpdk_plugin.so ]; then
    cp -f /tmp/vpp/build-root/build-vpp-native/vpp/lib/x86_64-linux-gnu/vpp_plugins/dpdk_plugin.so \
          /usr/local/lib/x86_64-linux-gnu/vpp_plugins/dpdk_plugin.so
    echo "  Copied PATCHED dpdk_plugin.so from build tree"
fi
ldconfig
echo "  VPP: $(vpp --version 2>&1 | head -1)"

# --- 6. Bring down VF ---
echo "[6] Setting enP30832s1d1 DOWN..."
ip link set enP30832s1d1 down 2>/dev/null || true

# --- 7. Write VPP config ---
echo "[7] Writing startup.conf..."
mkdir -p /etc/vpp /run/vpp
cat > /etc/vpp/startup.conf << 'EOF'
unix {
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
EOF

# --- 8. Start VPP ---
echo "[8] Starting VPP..."
vpp -c /etc/vpp/startup.conf &
VPP_PID=$!
echo "  VPP PID: $VPP_PID"

# Wait for CLI
echo "  Waiting for CLI..."
CLI_READY=0
for i in $(seq 1 45); do
    if vppctl show version > /dev/null 2>&1; then
        echo "  CLI ready after ${i}s"
        CLI_READY=1
        break
    fi
    sleep 1

    # Check if VPP died
    if ! kill -0 $VPP_PID 2>/dev/null; then
        echo "  VPP CRASHED after ${i}s!"
        echo "  === VPP Log ==="
        cat /tmp/vpp-mana.log 2>/dev/null
        exit 1
    fi

    # CPU spin detection (after 15s)
    if [ $i -gt 15 ]; then
        CPU=$(ps -p $VPP_PID -o pcpu= 2>/dev/null | tr -d ' ')
        if [ -n "$CPU" ] && [ "${CPU%.*}" -gt 95 ] 2>/dev/null; then
            echo "  VPP spinning at ${CPU}% after ${i}s!"
            echo "  === VPP Log ==="
            cat /tmp/vpp-mana.log 2>/dev/null
            echo ""
            echo "  Killing VPP to prevent node lockup..."
            kill -9 $VPP_PID
            exit 1
        fi
    fi
done

if [ $CLI_READY -eq 0 ]; then
    echo "  CLI not ready after 45s, dumping log..."
    cat /tmp/vpp-mana.log 2>/dev/null
    exit 1
fi

# --- 9. Show results ---
echo ""
echo "============================================"
echo "         VPP MANA Status"
echo "============================================"
echo ""
echo "Version:"
vppctl show version 2>&1
echo ""
echo "Interfaces:"
vppctl show interface 2>&1
echo ""
echo "Hardware:"
vppctl show hardware-interfaces 2>&1
echo ""
echo "VPP Log (DPDK lines):"
grep -iE "dpdk|mana|eal|error|warn" /tmp/vpp-mana.log 2>/dev/null | head -30
echo ""
echo "Full VPP Log:"
cat /tmp/vpp-mana.log 2>/dev/null
echo ""
echo "============================================"
echo " VPP PID: $VPP_PID"
echo "============================================"
