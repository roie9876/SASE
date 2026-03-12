#!/bin/bash
# ============================================================================
# Debug and start VPP with MANA DPDK
# Run inside vpp-mana pod: bash /tmp/debug-vpp-mana.sh
# ============================================================================

echo "============================================"
echo " MANA DPDK Debug & VPP Start Script"
echo "============================================"

# Clean slate
echo "[1] Cleanup..."
pkill -9 -f "vpp -c" 2>/dev/null
pkill -9 -f "dpdk-testpmd" 2>/dev/null
sleep 1
rm -rf /var/run/dpdk /run/vpp/cli.sock

echo "[2] Environment check..."
echo "  DPDK version: $(dpdk-testpmd --version 2>&1 | head -1)"
echo "  VPP version: $(vpp --version 2>&1 | head -1)"
echo "  Hugepages:"
grep HugePages /proc/meminfo | sed 's/^/    /'
echo "  ulimit -l: $(ulimit -l)"
echo "  Hugepage mount:"
mount | grep huge | sed 's/^/    /'
echo "  MANA VF (enP30832s1d1):"
ip -br link show enP30832s1d1 2>&1 | sed 's/^/    /'
echo "  IB devices:"
ls /dev/infiniband/ 2>&1 | sed 's/^/    /'

MANA_MAC=7c:ed:8d:25:e4:4d

find_mana_pair() {
  local vf_if primary_if

  vf_if=$(ip -o link | awk -v mac="$MANA_MAC" '$0 ~ mac && $2 ~ /^enP/ { gsub(":", "", $2); print $2; exit }')
  if [ -z "$vf_if" ]; then
    vf_if=$(ip -o link | awk -v mac="$MANA_MAC" '$0 ~ mac { gsub(":", "", $2); print $2; exit }')
  fi

  if [ -n "$vf_if" ]; then
    primary_if=$(ip -o link show "$vf_if" 2>/dev/null | sed -n 's/.* master \([^ ]*\) .*/\1/p')
  fi

  echo "$primary_if;$vf_if"
}

echo ""
echo "[3] Prepare MANA VF..."
IFS=';' read -r MANA_PRIMARY_IF MANA_VF_IF <<EOF
$(find_mana_pair)
EOF
echo "  primary=${MANA_PRIMARY_IF:-unknown} vf=${MANA_VF_IF:-unknown}"
if [ -n "$MANA_PRIMARY_IF" ]; then
  ip link set "$MANA_PRIMARY_IF" down 2>/dev/null || true
fi
if [ -n "$MANA_VF_IF" ]; then
  ip link set "$MANA_VF_IF" down 2>/dev/null || true
fi
echo "  MANA synthetic/VF pair set DOWN"

echo ""
echo "[4] Test DPDK with PCI scan (allow-list MANA)..."
# The MANA PMD is a PCI driver: vendor 0x1414, device 0x00BA
# Use -a (allow) with PCI address and MAC to select the right VF
rm -rf /var/run/dpdk
timeout 15 dpdk-testpmd -l 0-1 --no-huge -m 256 \
  -a 7870:00:00.0,mac=7c:ed:8d:25:e4:4d \
  --iova-mode va \
  -- --no-start --txd=128 --rxd=128 2>&1 | tee /tmp/testpmd-pci.log
TESTPMD_RC=$?
echo "  testpmd (PCI mode) exit: $TESTPMD_RC"

if [ $TESTPMD_RC -ne 0 ]; then
    echo ""
    echo "[4b] PCI mode failed, trying legacy vdev mode..."
    pkill -9 -f testpmd 2>/dev/null; sleep 1
    rm -rf /var/run/dpdk
    timeout 15 dpdk-testpmd -l 0-1 --no-huge -m 256 \
      --vdev="7870:00:00.0,mac=7c:ed:8d:25:e4:4d" \
      --no-pci --iova-mode va \
      -- --no-start --txd=128 --rxd=128 2>&1 | tee /tmp/testpmd-vdev.log
    TESTPMD_RC=$?
    echo "  testpmd (vdev mode) exit: $TESTPMD_RC"
fi

pkill -9 -f testpmd 2>/dev/null; sleep 1
rm -rf /var/run/dpdk

# Determine which mode worked
if grep -Eq "Port [0-9]+" /tmp/testpmd-pci.log 2>/dev/null; then
    DPDK_MODE="pci"
    echo "  >>> PCI mode WORKS"
elif grep -Eq "Port [0-9]+" /tmp/testpmd-vdev.log 2>/dev/null; then
    DPDK_MODE="vdev"
    echo "  >>> vdev mode WORKS"
else
    echo "  >>> NEITHER mode detected a port!"
    echo "  PCI log:"
    cat /tmp/testpmd-pci.log 2>/dev/null | sed 's/^/    /'
    echo "  vdev log:"
    cat /tmp/testpmd-vdev.log 2>/dev/null | sed 's/^/    /'
    echo ""
    echo "ABORTING - fix DPDK access first!"
    exit 1
fi

echo ""
echo "[5] Writing VPP startup.conf (mode=$DPDK_MODE)..."
mkdir -p /etc/vpp /run/vpp

if [ "$DPDK_MODE" = "pci" ]; then
cat > /etc/vpp/startup.conf << 'EOF'
unix {
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
    devargs mac=7c:ed:8d:25:e4:4d
  }
  no-hugetlb
  iova-mode va
}
plugins {
  plugin dpdk_plugin.so { enable }
  plugin default { disable }
  plugin ping_plugin.so { enable }
}
logging {
  default-log-level info
  class dpdk { level debug }
}
EOF
else
cat > /etc/vpp/startup.conf << 'EOF'
unix {
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
  no-pci
  no-hugetlb
  vdev 7870:00:00.0,mac=7c:ed:8d:25:e4:4d
  iova-mode va
}
plugins {
  plugin dpdk_plugin.so { enable }
  plugin default { disable }
  plugin ping_plugin.so { enable }
}
logging {
  default-log-level info
  class dpdk { level debug }
}
EOF
fi

echo "  Config:"
cat /etc/vpp/startup.conf | sed 's/^/    /'

echo ""
echo "[6] Starting VPP..."
rm -f /tmp/vpp-mana.log
vpp -c /etc/vpp/startup.conf &
VPP_PID=$!
echo "  VPP PID: $VPP_PID"

# Wait for CLI socket
echo "  Waiting for CLI socket..."
for i in $(seq 1 30); do
    if [ -S /run/vpp/cli.sock ] && vppctl show version > /dev/null 2>&1; then
        echo "  CLI ready after ${i}s"
        break
    fi
    sleep 1
    # Check if VPP died
    if ! kill -0 $VPP_PID 2>/dev/null; then
        echo "  VPP DIED after ${i}s!"
        echo "  Log:"
        cat /tmp/vpp-mana.log 2>/dev/null | sed 's/^/    /'
        exit 1
    fi
done

echo ""
echo "[7] VPP Status..."
echo "  Version:"
vppctl show version 2>&1 | sed 's/^/    /'
echo "  Interfaces:"
vppctl show interface 2>&1 | sed 's/^/    /'
echo "  Hardware:"
vppctl show hardware-interfaces 2>&1 | sed 's/^/    /'
echo "  DPDK log entries:"
vppctl show log 2>&1 | grep -iE "dpdk|mana|eal" | head -10 | sed 's/^/    /'

echo ""
echo "  Full VPP log:"
cat /tmp/vpp-mana.log 2>/dev/null | sed 's/^/    /'

echo ""
echo "============================================"
echo " DONE - VPP PID: $VPP_PID"
echo "============================================"
