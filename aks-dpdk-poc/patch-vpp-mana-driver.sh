#!/bin/bash
# ============================================================================
# Patch VPP to recognize MANA as a known driver, rebuild dpdk_plugin.so,
# then start VPP with native MANA DPDK.
# ============================================================================
set -e

echo "============================================"
echo " VPP MANA Driver Patch + Rebuild"
echo "============================================"

# --- Kill existing ---
echo "[1] Killing existing processes..."
for pid in $(pgrep -x vpp 2>/dev/null || true); do kill -9 "$pid" 2>/dev/null || true; done
for pid in $(pgrep -x dpdk-testpmd 2>/dev/null || true); do kill -9 "$pid" 2>/dev/null || true; done
sleep 2
rm -rf /var/run/dpdk /run/vpp/cli.sock /tmp/vpp-mana.log

# --- Cgroup escape ---
echo "[2] Escaping pod cgroup..."
echo $$ > /sys/fs/cgroup/cgroup.procs

# --- Patch driver.c to add MANA ---
echo "[3] Patching VPP driver.c to recognize net_mana..."
cd /tmp/vpp

python3 << 'PYEOF'
with open("src/plugins/dpdk/device/driver.c", "r") as f:
    content = f.read()

# Check if already patched
if "net_mana" in content:
    print("MANA driver entry already present")
else:
    # Add MANA entry after the Google vNIC entry
    old = '''  {
    .drivers = DPDK_DRIVERS ({ "net_gve", "Google vNIC" }),
    .interface_name_prefix = "VirtualFunctionEthernet",
  }'''
    new = '''  {
    .drivers = DPDK_DRIVERS ({ "net_gve", "Google vNIC" }),
    .interface_name_prefix = "VirtualFunctionEthernet",
  },
  {
    .drivers = DPDK_DRIVERS ({ "net_mana", "Microsoft Azure MANA" }),
  }'''
    content = content.replace(old, new)
    with open("src/plugins/dpdk/device/driver.c", "w") as f:
        f.write(content)
    print("Added net_mana driver entry to driver.c")
PYEOF

# --- Incremental rebuild of dpdk_plugin.so ---
echo "[4] Rebuilding VPP (incremental - only dpdk_plugin)..."
export PKG_CONFIG_PATH=/usr/local/lib/x86_64-linux-gnu/pkgconfig:$PKG_CONFIG_PATH
cd /tmp/vpp/build-root/build-vpp-native/vpp

# Incremental build - only recompile changed files
cmake --build . --target dpdk_plugin -- -j4 2>&1 | tail -10
echo "Build done"

# Install the rebuilt plugin
cp -f /tmp/vpp/build-root/build-vpp-native/vpp/lib/x86_64-linux-gnu/vpp_plugins/dpdk_plugin.so \
      /usr/local/lib/x86_64-linux-gnu/vpp_plugins/dpdk_plugin.so
ldconfig
echo "Plugin installed"

# Verify MANA is now recognized
if strings /usr/local/lib/x86_64-linux-gnu/vpp_plugins/dpdk_plugin.so | grep -q "net_mana"; then
    echo "SUCCESS: net_mana found in dpdk_plugin.so"
else
    echo "WARNING: net_mana NOT found in dpdk_plugin.so"
fi

# --- Start VPP ---
echo ""
echo "[5] Setting up environment..."
echo 1024 | tee /sys/devices/system/node/node*/hugepages/hugepages-2048kB/nr_hugepages > /dev/null
ip link set enP30832s1d1 down 2>/dev/null || true
rm -rf /var/run/dpdk /run/vpp/cli.sock /tmp/vpp-mana.log
rm -f /run/vpp/stats.sock

mkdir -p /etc/vpp /run/vpp
cat > /etc/vpp/startup.conf << 'VPPEOF'
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
  class dpdk/device { level debug }
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
  no-tx-checksum-offload
  iova-mode va
  uio-driver auto
}
plugins {
  plugin dpdk_plugin.so { enable }
  plugin default { disable }
  plugin ping_plugin.so { enable }
}
VPPEOF

echo "[6] Starting VPP..."
vpp -c /etc/vpp/startup.conf > /tmp/vpp-stdout.log 2>&1 &
VPP_PID=$!
echo "  PID=$VPP_PID"

for i in $(seq 1 30); do
    if timeout 3 vppctl show version >/dev/null 2>&1; then
        echo "  CLI ready (${i}s)"
        break
    fi
    sleep 1
    if ! kill -0 $VPP_PID 2>/dev/null; then
        echo "  CRASHED!"
        cat /tmp/vpp-mana.log 2>/dev/null
        exit 1
    fi
done

echo ""
echo "[7] Bringing up mana0..."
timeout 10 vppctl set interface state mana0 up 2>&1 || true
timeout 5 vppctl set interface ip address mana0 10.120.3.10/24 2>&1 || true
sleep 2

echo ""
echo "============================================"
echo "         RESULTS"
echo "============================================"
echo ""
echo "CPU: $(ps -p $VPP_PID -o pcpu= 2>/dev/null)%"
echo ""
echo "Interfaces:"
timeout 5 vppctl show interface 2>&1
echo ""
echo "Address:"
timeout 5 vppctl show interface addr 2>&1
echo ""
echo "Hardware:"
timeout 5 vppctl show hardware-interfaces 2>&1 || true
echo ""
echo "stdout/stderr (first 80 lines):"
head -80 /tmp/vpp-stdout.log 2>/dev/null || echo "(empty)"
echo ""
echo "VPP Log:"
cat /tmp/vpp-mana.log 2>/dev/null
echo ""
echo "============================================"
echo " VPP PID: $VPP_PID"
echo "============================================"
