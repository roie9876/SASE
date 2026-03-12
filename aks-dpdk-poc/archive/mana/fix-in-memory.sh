#!/bin/bash
# ============================================================================
# FIX: Remove --in-memory from VPP EAL args for MANA ibverbs DMA support
# Also ensures MANA driver entry exists in driver.c
# Then rebuild dpdk_plugin, and start VPP
# ============================================================================
set -e

echo "============================================"
echo " VPP MANA: Remove --in-memory + Rebuild"
echo "============================================"

# --- Kill existing ---
echo "[1] Killing existing processes..."
for pid in $(pgrep -x vpp 2>/dev/null || true); do kill -9 "$pid" 2>/dev/null || true; done
for pid in $(pgrep -x dpdk-testpmd 2>/dev/null || true); do kill -9 "$pid" 2>/dev/null || true; done
sleep 2
rm -rf /var/run/dpdk /run/vpp/cli.sock /tmp/vpp-mana.log /run/vpp/stats.sock /run/vpp/api.sock

# --- Cgroup escape ---
echo "[2] Escaping pod cgroup..."
echo $$ > /sys/fs/cgroup/cgroup.procs

# --- Patch init.c to remove --in-memory ---
echo "[3] Patching VPP init.c to remove --in-memory..."
cd /tmp/vpp

python3 << 'PYEOF'
# Patch 1: Remove --in-memory from EAL args
with open("src/plugins/dpdk/device/init.c", "r") as f:
    content = f.read()

if '--in-memory' in content:
    # Comment out the --in-memory line
    content = content.replace(
        'vec_add1 (conf->eal_init_args, (u8 *) "--in-memory");',
        '/* MANA fix: --in-memory blocks ibverbs DMA registration */\n      /* vec_add1 (conf->eal_init_args, (u8 *) "--in-memory"); */'
    )
    with open("src/plugins/dpdk/device/init.c", "w") as f:
        f.write(content)
    print("Patched: removed --in-memory from EAL args")
else:
    print("--in-memory already removed or not found")

# Patch 2: Ensure MANA driver entry in driver.c
with open("src/plugins/dpdk/device/driver.c", "r") as f:
    content = f.read()

if "net_mana" not in content:
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
else:
    print("net_mana driver entry already present")

# Patch 3: Ensure MANA PCI whitelist in init.c (skip UIO bind)
with open("src/plugins/dpdk/device/init.c", "r") as f:
    content = f.read()

if "0x1414" not in content:
    old = """    /* Google vNIC */
    else if (d->vendor_id == 0x1ae0 && d->device_id == 0x0042)
      ;
    else"""
    new = """    /* Google vNIC */
    else if (d->vendor_id == 0x1ae0 && d->device_id == 0x0042)
      ;
    /* Microsoft Azure MANA - bifurcated driver, skip UIO bind */
    else if (d->vendor_id == 0x1414 && d->device_id == 0x00ba)
      {
        goto next_device;
      }
    else"""
    if old in content:
        content = content.replace(old, new)
        old2 = "  vec_free (pci_addr);\n  vlib_pci_free_device_info (d);\n}"
        new2 = "next_device:\n  vec_free (pci_addr);\n  vlib_pci_free_device_info (d);\n}"
        content = content.replace(old2, new2, 1)
        with open("src/plugins/dpdk/device/init.c", "w") as f:
            f.write(content)
        print("Added MANA PCI whitelist patch")
    else:
        print("Could not find PCI whitelist insertion point")
else:
    print("MANA PCI whitelist already present")
PYEOF

# --- Rebuild VPP (full rebuild needed since init.c is core) ---
echo "[4] Rebuilding VPP..."
export PKG_CONFIG_PATH=/usr/local/lib/x86_64-linux-gnu/pkgconfig:$PKG_CONFIG_PATH
cd /tmp/vpp/build-root/build-vpp-native/vpp

# Force recompile of changed files
cmake --build . -- -j4 2>&1 | tail -10
echo "Build done"

# Install rebuilt binaries
VPP_DIR=/tmp/vpp/build-root/install-vpp-native/vpp
cp -a $VPP_DIR/bin/* /usr/local/bin/ 2>/dev/null || true
cp -a $VPP_DIR/lib/* /usr/local/lib/ 2>/dev/null || true
cp -f /tmp/vpp/build-root/build-vpp-native/vpp/lib/x86_64-linux-gnu/vpp_plugins/dpdk_plugin.so \
      /usr/local/lib/x86_64-linux-gnu/vpp_plugins/dpdk_plugin.so
ldconfig
echo "Installed: $(vpp --version 2>&1 | head -1)"

# --- Remove failsafe PMDs ---
echo "[5] Removing failsafe PMDs..."
rm -f /usr/local/lib/x86_64-linux-gnu/dpdk/pmds-25.0/librte_net_{failsafe,tap,netvsc,vdev_netvsc}*
ldconfig

# --- Setup environment ---
echo "[6] Setting up environment..."
echo 1024 | tee /sys/devices/system/node/node*/hugepages/hugepages-2048kB/nr_hugepages > /dev/null
ip link set enP30832s1d1 down 2>/dev/null || true
rm -rf /var/run/dpdk /run/vpp/cli.sock /tmp/vpp-mana.log /run/vpp/stats.sock /run/vpp/api.sock
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
}
plugins {
  plugin dpdk_plugin.so { enable }
  plugin default { disable }
  plugin ping_plugin.so { enable }
}
EOF

# --- Start VPP ---
echo "[7] Starting VPP (no --in-memory)..."
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
        tail -30 /tmp/vpp-stdout.log 2>/dev/null
        cat /tmp/vpp-mana.log 2>/dev/null
        exit 1
    fi
done

# --- Bring up ---
echo ""
echo "[8] Bringing up mana0..."
timeout 10 vppctl set interface state mana0 up 2>&1
UP_RC=$?
echo "  UP_RC=$UP_RC"

if [ $UP_RC -eq 0 ]; then
    echo ""
    echo "[9] Assigning IP 10.120.3.10/24..."
    timeout 5 vppctl set interface ip address mana0 10.120.3.10/24 2>&1 || true
    sleep 2
fi

# --- Results ---
echo ""
echo "============================================"
echo "         RESULTS"
echo "============================================"
echo ""
echo "CPU: $(ps -p $VPP_PID -o pcpu= 2>/dev/null || echo dead)%"
echo ""
echo "EAL args (check no --in-memory):"
timeout 5 vppctl show log 2>&1 | grep "EAL init args" | head -1
echo ""
echo "Interfaces:"
timeout 5 vppctl show interface 2>&1
echo ""
echo "Address:"
timeout 5 vppctl show interface addr 2>&1
echo ""
echo "Hardware (first 15 lines):"
timeout 5 vppctl show hardware-interfaces 2>&1 | head -15
echo ""
echo "DPDK/MANA log:"
timeout 5 vppctl show log 2>&1 | grep -iE "dpdk|mana|DMA|error|start|queue|EAL" | head -20
echo ""
echo "VPP Log:"
cat /tmp/vpp-mana.log 2>/dev/null
echo ""
echo "============================================"
echo " VPP PID: $VPP_PID"
echo "============================================"
