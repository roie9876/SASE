#!/bin/bash
# ============================================================================
# Fix MANA DPDK: Remove Azure failsafe/netvsc/tap PMDs that hijack MANA
# Then verify testpmd works with native net_mana driver
# ============================================================================
set -e

echo "============================================"
echo " MANA DPDK Fix: Remove Failsafe PMDs"
echo "============================================"

# --- 1. Clean slate ---
echo "[1] Killing all VPP/DPDK processes..."
for pid in $(pgrep -x vpp 2>/dev/null || true); do kill -9 "$pid" 2>/dev/null || true; done
for pid in $(pgrep -x dpdk-testpmd 2>/dev/null || true); do kill -9 "$pid" 2>/dev/null || true; done
sleep 2
rm -rf /var/run/dpdk /run/vpp/cli.sock

# --- 2. Escape cgroup ---
echo "[2] Escaping pod cgroup..."
echo $$ > /sys/fs/cgroup/cgroup.procs

# --- 3. Show BEFORE state ---
echo "[3] Current net PMD plugins:"
ls -1 /usr/local/lib/x86_64-linux-gnu/dpdk/pmds-25.0/librte_net_* 2>/dev/null || echo "  (none)"

# --- 4. Remove failsafe/tap/netvsc PMDs ---
echo "[4] Removing failsafe/tap/netvsc/vdev_netvsc PMD .so files..."
rm -fv /usr/local/lib/x86_64-linux-gnu/dpdk/pmds-25.0/librte_net_failsafe*
rm -fv /usr/local/lib/x86_64-linux-gnu/dpdk/pmds-25.0/librte_net_tap*
rm -fv /usr/local/lib/x86_64-linux-gnu/dpdk/pmds-25.0/librte_net_netvsc*
rm -fv /usr/local/lib/x86_64-linux-gnu/dpdk/pmds-25.0/librte_net_vdev_netvsc*
# Also static
rm -f /usr/local/lib/x86_64-linux-gnu/librte_net_failsafe*
rm -f /usr/local/lib/x86_64-linux-gnu/librte_net_tap*
rm -f /usr/local/lib/x86_64-linux-gnu/librte_net_netvsc*
rm -f /usr/local/lib/x86_64-linux-gnu/librte_net_vdev_netvsc*
ldconfig

# --- 5. Show AFTER state ---
echo ""
echo "[5] Remaining net PMDs:"
ls -1 /usr/local/lib/x86_64-linux-gnu/dpdk/pmds-25.0/librte_net_* 2>/dev/null || echo "  (none)"
echo ""
echo "MANA PMD present:"
ls -la /usr/local/lib/x86_64-linux-gnu/dpdk/pmds-25.0/librte_net_mana* 2>/dev/null || echo "  MISSING!"

# --- 6. Verify hugepages ---
echo ""
echo "[6] Hugepages:"
echo 1024 | tee /sys/devices/system/node/node*/hugepages/hugepages-2048kB/nr_hugepages > /dev/null
grep HugePages /proc/meminfo

# --- 7. Bring down VF ---
echo ""
echo "[7] Setting enP30832s1d1 DOWN for DPDK..."
ip link set enP30832s1d1 down 2>/dev/null || true

# --- 8. Test with the EXACT command that worked before ---
echo ""
echo "[8] Testing DPDK MANA with original working command..."
rm -rf /var/run/dpdk
timeout 20 dpdk-testpmd -l 0-1 \
    -a 7870:00:00.0,mac=60:45:bd:fd:d8:eb \
    --iova-mode va -m 512 \
    -- --auto-start --txd=128 --rxd=128 \
    > /tmp/testpmd-native.log 2>&1 || true

echo ""
echo "=== testpmd output ==="
cat /tmp/testpmd-native.log
echo ""

# Check results
if grep -q "net_mana" /tmp/testpmd-native.log; then
    echo ">>> SUCCESS: net_mana driver detected!"
elif grep -q "net_failsafe" /tmp/testpmd-native.log; then
    echo ">>> STILL FAILSAFE - failsafe PMD still active somehow"
elif grep -qE "Port [0-9]+:" /tmp/testpmd-native.log; then
    echo ">>> PORT FOUND - checking driver..."
    grep -iE "driver|mana|failsafe|port" /tmp/testpmd-native.log | head -20
else
    echo ">>> NO PORT DETECTED"
fi

# --- 9. Interactive test for driver detail ---
echo ""
echo "[9] Interactive testpmd for driver info..."
for pid in $(pgrep -x dpdk-testpmd 2>/dev/null || true); do kill -9 "$pid" 2>/dev/null || true; done
sleep 2
rm -rf /var/run/dpdk

printf "show port info all\nquit\n" > /tmp/tp-info.cmd
timeout 20 dpdk-testpmd -l 0-1 \
    -a 7870:00:00.0,mac=60:45:bd:fd:d8:eb \
    --iova-mode va -m 512 \
    -- -i --txd=128 --rxd=128 --cmdline-file=/tmp/tp-info.cmd \
    > /tmp/testpmd-info.log 2>&1 || true

echo ""
echo "=== Port info ==="
grep -A 30 "Infos for port" /tmp/testpmd-info.log || cat /tmp/testpmd-info.log

# Cleanup
for pid in $(pgrep -x dpdk-testpmd 2>/dev/null || true); do kill -9 "$pid" 2>/dev/null || true; done
rm -rf /var/run/dpdk

echo ""
echo "============================================"
echo " DONE"
echo "============================================"
