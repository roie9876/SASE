#!/bin/bash
# ============================================================================
# Start VPP with MANA DPDK on AKS (Ubuntu 24.04 / kernel 6.8)
# Runs inside vpp-mana pod (hostNetwork, privileged)
#
# MANA DPDK uses bifurcated driver model:
#   - Kernel mana driver stays loaded (provides RDMA verbs)
#   - DPDK net_mana PMD probes PCI device via ibverbs
#   - No uio_hv_generic binding needed!
#
# Usage: bash /tmp/setup-vpp-dpdk.sh
# ============================================================================
set -e

echo "============================================"
echo " VPP + MANA DPDK Setup"
echo "============================================"

# --- 1. Kill any existing VPP ---
echo "[1] Cleanup..."
pkill -9 -f "vpp -c" 2>/dev/null || true
sleep 1
rm -rf /var/run/dpdk /run/vpp/cli.sock

# --- 2. Install VPP binaries ---
echo "[2] Installing VPP..."
VPP_DIR=/tmp/vpp/build-root/install-vpp-native/vpp
if [ -d "$VPP_DIR" ]; then
    cp -a $VPP_DIR/bin/* /usr/local/bin/ 2>/dev/null || true
    cp -a $VPP_DIR/lib/* /usr/local/lib/ 2>/dev/null || true
    ldconfig
    echo "  VPP: $(vpp --version 2>&1 | head -1)"
else
    echo "  Using pre-installed VPP: $(vpp --version 2>&1 | head -1)"
fi

# --- 3. Detect MANA NIC ---
echo "[3] Detecting MANA NIC..."

# Find the MANA VF for the secondary NIC (not eth0's VF)
# On dual-NIC AKS, enP30832s1 is eth0's VF, enP30832s1d1 is eth1's VF
if ip link show enP30832s1d1 > /dev/null 2>&1; then
    MANA_VF="enP30832s1d1"
elif ip link show eth1 > /dev/null 2>&1; then
    MANA_VF=$(ip -br link show master eth1 | awk '{ print $1 }')
fi

if [ -z "$MANA_VF" ]; then
    echo "  ERROR: No secondary MANA VF found!"
    exit 1
fi

MANA_MAC=$(ip -br link show $MANA_VF | awk '{ print $3 }')
BUS_INFO=$(ethtool -i $MANA_VF | grep bus-info | awk '{ print $2 }')
echo "  VF: $MANA_VF"
echo "  MAC: $MANA_MAC"
echo "  PCI: $BUS_INFO"

# --- 4. Bring down MANA VF ---
echo "[4] Setting $MANA_VF DOWN for DPDK..."
ip link set $MANA_VF down 2>/dev/null || true

# --- 5. Quick DPDK testpmd verification ---
echo "[5] Verifying DPDK MANA access..."
rm -rf /var/run/dpdk
timeout 15 dpdk-testpmd -l 0-1 \
    -a ${BUS_INFO},mac=${MANA_MAC} \
    --no-huge -m 256 --iova-mode va \
    -- --no-start --txd=128 --rxd=128 \
    > /tmp/testpmd-verify.log 2>&1 || true

if grep -Eq "Port [0-9]+" /tmp/testpmd-verify.log; then
  echo "  DPDK testpmd: PORT DETECTED (PCI mode)"
    DPDK_CONFIG="pci"
else
    # Fallback: try vdev mode
    pkill -9 -f testpmd 2>/dev/null || true; sleep 1
    rm -rf /var/run/dpdk
    timeout 15 dpdk-testpmd -l 0-1 \
        --vdev="${BUS_INFO},mac=${MANA_MAC}" \
        --no-pci --no-huge -m 256 --iova-mode va \
        -- --no-start --txd=128 --rxd=128 \
        > /tmp/testpmd-verify.log 2>&1 || true

    if grep -Eq "Port [0-9]+" /tmp/testpmd-verify.log; then
      echo "  DPDK testpmd: PORT DETECTED (vdev mode)"
        DPDK_CONFIG="vdev"
    else
      echo "  WARNING: testpmd did not detect any port!"
        echo "  Log:"
        cat /tmp/testpmd-verify.log | head -20 | sed 's/^/    /'
        DPDK_CONFIG="pci"  # Try PCI mode anyway
    fi
fi
pkill -9 -f testpmd 2>/dev/null || true; sleep 1
rm -rf /var/run/dpdk

# --- 6. Write VPP startup.conf ---
echo "[6] Writing VPP config (mode=$DPDK_CONFIG)..."
mkdir -p /etc/vpp /run/vpp

if [ "$DPDK_CONFIG" = "pci" ]; then
cat > /etc/vpp/startup.conf << EOF
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
  dev ${BUS_INFO} {
    name mana0
    devargs mac=${MANA_MAC}
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
cat > /etc/vpp/startup.conf << EOF
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
  vdev ${BUS_INFO},mac=${MANA_MAC}
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

echo "  Config written to /etc/vpp/startup.conf"

# --- 7. Start VPP ---
echo "[7] Starting VPP..."
rm -f /tmp/vpp-mana.log
export LD_LIBRARY_PATH=/usr/local/lib/x86_64-linux-gnu:/usr/local/lib:$LD_LIBRARY_PATH
vpp -c /etc/vpp/startup.conf &
VPP_PID=$!
echo "  PID: $VPP_PID"

# Wait for CLI socket
echo "  Waiting for CLI..."
for i in $(seq 1 30); do
    if vppctl show version > /dev/null 2>&1; then
        echo "  CLI ready (${i}s)"
        break
    fi
    sleep 1
    if ! kill -0 $VPP_PID 2>/dev/null; then
        echo "  VPP CRASHED after ${i}s!"
        echo "  === Log ==="
        cat /tmp/vpp-mana.log 2>/dev/null | sed 's/^/    /'
        exit 1
    fi
done

# --- 8. Show status ---
echo ""
echo "============================================"
echo " VPP Status"
echo "============================================"
echo "Version:"
vppctl show version 2>&1 | sed 's/^/  /'
echo ""
echo "Interfaces:"
vppctl show interface 2>&1 | sed 's/^/  /'
echo ""
echo "Hardware:"
vppctl show hardware-interfaces 2>&1 | sed 's/^/  /'
echo ""
echo "DPDK log:"
vppctl show log 2>&1 | grep -iE "dpdk|mana|eal" | head -10 | sed 's/^/  /'
echo ""
echo "Full log:"
cat /tmp/vpp-mana.log 2>/dev/null | sed 's/^/  /'

echo ""
echo "============================================"
echo " VPP PID: $VPP_PID — DONE"
echo "============================================"
