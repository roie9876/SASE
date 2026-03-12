#!/bin/bash
# ==========================================================
# Complete rebuild: rdma-core + DPDK + VPP with MANA patch
# THEN: start VPP with DPDK MANA kernel bypass
# ==========================================================
set -e

echo "===== [1/9] Move to root cgroup (hugepage access) ====="
echo $$ > /sys/fs/cgroup/cgroup.procs
echo "PID $$ in root cgroup"

echo "===== [2/9] Install ALL build deps ====="
DEBIAN_FRONTEND=noninteractive apt-get update > /dev/null 2>&1
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  build-essential libudev-dev libnl-3-dev libnl-route-3-dev \
  ninja-build libssl-dev libelf-dev python3-pip python3-venv meson libnuma-dev \
  rdma-core ibverbs-providers libibverbs-dev librdmacm-dev \
  curl gnupg2 git cmake iproute2 ethtool pciutils kmod \
  pkg-config python3-docutils util-linux sudo nasm uuid-dev \
  iputils-ping iperf3 binutils autoconf automake libtool \
  clang libpcap-dev libunwind-dev python3-ply > /dev/null 2>&1
pip3 install pyelftools ply > /dev/null 2>&1
echo "Deps OK"

echo "===== [3/9] Build rdma-core v46 ====="
cd /tmp
rm -rf /tmp/rdma-core
git clone https://github.com/linux-rdma/rdma-core.git -b v46.0 --depth 1 > /dev/null 2>&1
cd rdma-core && mkdir build && cd build
cmake -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=lib/x86_64-linux-gnu -DNO_MAN_PAGES=1 .. > /dev/null 2>&1
make -j4 > /dev/null 2>&1
cmake --install . > /dev/null 2>&1
ldconfig
echo "rdma-core v46: $(pkg-config --modversion libmana 2>/dev/null)"
echo "MLX5: $(objdump -p /lib/x86_64-linux-gnu/libmlx5.so.1 2>/dev/null | grep MLX5_1.24)"

echo "===== [4/9] Build DPDK v24.11 ====="
cd /tmp
rm -rf /tmp/dpdk-24
git clone https://github.com/DPDK/dpdk.git -b v24.11 --depth 1 dpdk-24 > /dev/null 2>&1
cd dpdk-24
meson setup build --default-library=shared -Dprefix=/usr/local > /dev/null 2>&1
cd build && ninja -j4 > /dev/null 2>&1
ninja install > /dev/null 2>&1
ldconfig
echo "DPDK MANA: $(find /usr/local/lib -name 'librte_net_mana.so*' | head -1)"
echo "testpmd: $(which dpdk-testpmd)"

# Remove failsafe/netvsc PMDs that hijack MANA device
rm -f /usr/local/lib/x86_64-linux-gnu/dpdk/pmds-25.0/librte_net_failsafe*
rm -f /usr/local/lib/x86_64-linux-gnu/dpdk/pmds-25.0/librte_net_tap*
rm -f /usr/local/lib/x86_64-linux-gnu/dpdk/pmds-25.0/librte_net_netvsc*
rm -f /usr/local/lib/x86_64-linux-gnu/dpdk/pmds-25.0/librte_net_vdev_netvsc*
ldconfig
echo "Failsafe PMDs removed"

echo "===== [5/9] Allocate hugepages ====="
echo 1024 | tee /sys/devices/system/node/node*/hugepages/hugepages-2048kB/nr_hugepages > /dev/null
grep HugePages_Total /proc/meminfo

MANA_PCI=7870:00:00.0
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

release_mana_pair() {
  local primary_if vf_if

  IFS=';' read -r primary_if vf_if <<EOF
$(find_mana_pair)
EOF

  echo "Releasing MANA pair: primary=${primary_if:-unknown} vf=${vf_if:-unknown}"
  if [ -n "$primary_if" ]; then
    ip link set "$primary_if" down 2>/dev/null || true
  fi
  if [ -n "$vf_if" ]; then
    ip link set "$vf_if" down 2>/dev/null || true
  fi
}

echo "===== [6/9] Verify DPDK MANA testpmd ====="
rm -rf /var/run/dpdk
release_mana_pair
timeout 15 dpdk-testpmd -l 0-1 \
    -a 7870:00:00.0,mac=7c:ed:8d:25:e4:4d \
    --iova-mode va -m 512 \
    -- --auto-start --txd=128 --rxd=128 \
    > /tmp/testpmd-check.log 2>&1
if grep -Eq "Port [0-9]+:" /tmp/testpmd-check.log; then
    echo "DPDK MANA testpmd: WORKS"
  grep -E "Port [0-9]+:" /tmp/testpmd-check.log | head -1
else
    echo "DPDK MANA testpmd: FAILED"
    cat /tmp/testpmd-check.log
fi
pkill -9 testpmd 2>/dev/null || true
rm -rf /var/run/dpdk
sleep 1

echo "===== [7/9] Clone & patch VPP v26.02 ====="
cd /tmp
rm -rf /tmp/vpp
git clone https://gerrit.fd.io/r/vpp -b v26.02 --depth 1 > /dev/null 2>&1
cd vpp

# Apply patches via python
python3 << 'PYEOF'
with open("src/plugins/dpdk/CMakeLists.txt", "r") as f:
    c = f.read()
c = c.replace(
    'option(VPP_USE_SYSTEM_DPDK "Use the system installation of DPDK." OFF)',
    'option(VPP_USE_SYSTEM_DPDK "Use system DPDK" ON)'
)
with open("src/plugins/dpdk/CMakeLists.txt", "w") as f:
    f.write(c)

with open("src/plugins/dpdk/device/init.c", "r") as f:
    c = f.read()

# Patch 1: MANA PCI whitelist (skip UIO bind)
if "0x1414" not in c:
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
    c = c.replace(old, new)
    old2 = "  vec_free (pci_addr);\n  vlib_pci_free_device_info (d);\n}"
    new2 = "next_device:\n  vec_free (pci_addr);\n  vlib_pci_free_device_info (d);\n}"
    c = c.replace(old2, new2, 1)
    print("  Applied MANA PCI whitelist patch")

# Patch 2: Remove --in-memory (blocks ibverbs DMA for MANA CQ creation)
if '--in-memory' in c and '/* MANA fix' not in c:
    c = c.replace(
        'vec_add1 (conf->eal_init_args, (u8 *) "--in-memory");',
        '/* MANA fix: --in-memory blocks ibverbs DMA registration */\n      /* vec_add1 (conf->eal_init_args, (u8 *) "--in-memory"); */'
    )
    print("  Removed --in-memory from EAL args")

# Patch 3: Skip DPDK xstats for MANA to avoid VPP counter crash during admin-up
mana_xstats = '  if (xd->if_desc && strstr (xd->if_desc, "Microsoft Azure MANA"))\n    return;\n'
if mana_xstats not in c:
  c = c.replace(
    '  int len, ret, i;\n  struct rte_eth_xstat_name *xstats_names = 0;\n',
    '  int len, ret, i;\n  struct rte_eth_xstat_name *xstats_names = 0;\n\n  if (xd->if_desc && strstr (xd->if_desc, "Microsoft Azure MANA"))\n    return;\n'
  )
  print("  Added MANA xstats bypass in init.c")

with open("src/plugins/dpdk/device/init.c", "w") as f:
    f.write(c)

with open("src/plugins/dpdk/device/dpdk_priv.h", "r") as f:
  p = f.read()
if mana_xstats not in p:
  p = p.replace(
    '  if (!(xd->flags & DPDK_DEVICE_FLAG_ADMIN_UP))\n    return;\n',
    '  if (!(xd->flags & DPDK_DEVICE_FLAG_ADMIN_UP))\n    return;\n\n  if (xd->if_desc && strstr (xd->if_desc, "Microsoft Azure MANA"))\n    return;\n'
  )
  with open("src/plugins/dpdk/device/dpdk_priv.h", "w") as f:
    f.write(p)
  print("  Added MANA xstats bypass in dpdk_priv.h")

# Patch 4: Add MANA to VPP driver classification table
with open("src/plugins/dpdk/device/driver.c", "r") as f:
    d = f.read()
if "net_mana" not in d:
    old_drv = '''  {
    .drivers = DPDK_DRIVERS ({ "net_gve", "Google vNIC" }),
    .interface_name_prefix = "VirtualFunctionEthernet",
  }'''
    new_drv = '''  {
    .drivers = DPDK_DRIVERS ({ "net_gve", "Google vNIC" }),
    .interface_name_prefix = "VirtualFunctionEthernet",
  },
  {
    .drivers = DPDK_DRIVERS ({ "net_mana", "Microsoft Azure MANA" }),
  }'''
    d = d.replace(old_drv, new_drv)
    with open("src/plugins/dpdk/device/driver.c", "w") as f:
        f.write(d)
    print("  Added net_mana to driver.c")

print("VPP patched: system DPDK + MANA whitelist + no --in-memory + xstats bypass + driver entry")
PYEOF

echo "===== [8/9] Build VPP ====="
touch build-root/.deps.ok
export PKG_CONFIG_PATH=/usr/local/lib/x86_64-linux-gnu/pkgconfig:$PKG_CONFIG_PATH
echo "Building VPP (this takes ~30 min)..."
make build-release CMAKE_ARGS="-DVPP_USE_SYSTEM_DPDK=ON" 2>&1 | tail -5
VPP_DIR=/tmp/vpp/build-root/install-vpp-native/vpp
cp -a $VPP_DIR/bin/* /usr/local/bin/ 2>/dev/null
cp -a $VPP_DIR/lib/* /usr/local/lib/ 2>/dev/null

# CRITICAL: copy the PATCHED dpdk_plugin from build dir (not install dir)
cp -f /tmp/vpp/build-root/build-vpp-native/vpp/lib/x86_64-linux-gnu/vpp_plugins/dpdk_plugin.so \
      /usr/local/lib/x86_64-linux-gnu/vpp_plugins/dpdk_plugin.so
ldconfig
echo "VPP: $(vpp --version 2>&1 | head -1)"

# Save to host /tmp for future restores
tar czf /host/tmp/vpp-dpdk-all.tar.gz \
  /usr/local/bin/vpp /usr/local/bin/vppctl /usr/local/bin/dpdk-testpmd \
  /usr/local/lib/x86_64-linux-gnu/ \
  /usr/lib/x86_64-linux-gnu/libmana* \
  /usr/lib/x86_64-linux-gnu/libibverbs/ \
  /lib/x86_64-linux-gnu/libmlx5* \
  2>/dev/null
echo "Backup saved: $(ls -lh /host/tmp/vpp-dpdk-all.tar.gz | awk '{print $5}')"

echo "===== [9/9] Start VPP with DPDK MANA ====="
pkill -9 -f "vpp -c" 2>/dev/null || true
sleep 1
rm -f /tmp/vpp-mana.log /run/vpp/cli.sock
rm -rf /var/run/dpdk
mkdir -p /etc/vpp /run/vpp

python3 -c "
conf = '''unix {
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
'''
with open('/etc/vpp/startup.conf', 'w') as f:
    f.write(conf)
"

release_mana_pair
echo "Starting VPP..."
vpp -c /etc/vpp/startup.conf &
VPP_PID=$!
echo "VPP PID: $VPP_PID"

for i in $(seq 1 30); do
    if vppctl show version > /dev/null 2>&1; then
        echo "VPP CLI ready (${i}s)"
        break
    fi
    sleep 1
    if ! kill -0 $VPP_PID 2>/dev/null; then
        echo "VPP CRASHED after ${i}s!"
        cat /tmp/vpp-mana.log 2>/dev/null
        exit 1
    fi
    CPU=$(ps -p $VPP_PID -o pcpu= 2>/dev/null | tr -d ' ')
    if [ -n "$CPU" ] && [ "${CPU%.*}" -gt 95 ] 2>/dev/null && [ $i -gt 10 ]; then
        echo "VPP spinning at ${CPU}% after ${i}s - killing to prevent node lockup"
        kill -9 $VPP_PID
        cat /tmp/vpp-mana.log 2>/dev/null
        exit 1
    fi
done

echo ""
echo "============================================"
echo "         VPP DPDK MANA - RESULTS"
echo "============================================"
vppctl show version 2>&1
echo ""
echo "Interfaces:"
vppctl show interface 2>&1
echo ""

echo "Bringing up mana0..."
vppctl set interface state mana0 up 2>&1 || true
vppctl set interface ip address mana0 10.120.3.10/24 2>&1 || true
sleep 2

echo ""
echo "Interface state after admin-up:"
vppctl show interface 2>&1
echo ""
echo "Address:"
vppctl show interface addr 2>&1
echo ""
echo "Hardware:"
vppctl show hardware-interfaces 2>&1 | head -25
echo ""
echo "Log:"
cat /tmp/vpp-mana.log 2>/dev/null
echo ""
echo "============================================"
echo "VPP PID: $VPP_PID"
echo "============================================"
