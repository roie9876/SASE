#!/bin/bash
# ==========================================================
# Full restore + VPP DPDK MANA startup
# Run inside vpp-mana pod after fresh pod creation
# ==========================================================
set -e

echo "===== [1/8] Move to root cgroup ====="
echo $$ > /sys/fs/cgroup/cgroup.procs
echo "PID $$ in cgroup: $(cat /proc/self/cgroup)"

echo "===== [2/8] Install base deps ====="
DEBIAN_FRONTEND=noninteractive apt-get update > /dev/null 2>&1
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  iproute2 ethtool pciutils kmod iputils-ping iperf3 \
  libnuma1 libnl-3-200 libnl-route-3-200 libssl3 \
  rdma-core ibverbs-providers libibverbs1 librdmacm1 \
  build-essential cmake git python3-pip libunwind-dev \
  libnuma-dev pkg-config > /dev/null 2>&1
echo "Deps installed"

echo "===== [3/8] Restore VPP+DPDK binaries ====="
if [ -f /host/tmp/vpp-dpdk-all.tar.gz ]; then
    tar xzf /host/tmp/vpp-dpdk-all.tar.gz -C /
    ldconfig
    echo "VPP: $(vpp --version 2>&1 | head -1)"
    echo "testpmd: $(which dpdk-testpmd)"
else
    echo "ERROR: /host/tmp/vpp-dpdk-all.tar.gz not found!"
    exit 1
fi

echo "===== [4/8] Rebuild rdma-core v46 (for MLX5_1.24) ====="
cd /tmp
rm -rf /tmp/rdma-core
git clone https://github.com/linux-rdma/rdma-core.git -b v46.0 --depth 1 > /dev/null 2>&1
cd rdma-core && mkdir build && cd build
cmake -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=lib/x86_64-linux-gnu -DNO_MAN_PAGES=1 .. > /dev/null 2>&1
make -j4 > /dev/null 2>&1
cmake --install . > /dev/null 2>&1
ldconfig
echo "rdma-core v46 installed"
echo "MLX5 symbols: $(objdump -p /lib/x86_64-linux-gnu/libmlx5.so.1 2>/dev/null | grep MLX5 | tail -2)"

echo "===== [5/8] Allocate hugepages ====="
echo 1024 | tee /sys/devices/system/node/node*/hugepages/hugepages-2048kB/nr_hugepages > /dev/null
grep HugePages_Total /proc/meminfo

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

echo "===== [6/8] Re-apply MANA VPP patch + rebuild ====="
if [ -d /host/tmp/vpp-source-backup ]; then
    echo "Using backed up VPP source"
    cp -r /host/tmp/vpp-source-backup /tmp/vpp
else
    echo "Cloning VPP source..."
    cd /tmp
    git clone https://gerrit.fd.io/r/vpp -b v26.02 --depth 1 > /dev/null 2>&1
fi

# Apply MANA whitelist patch
cd /tmp/vpp
python3 << 'PYEOF'
with open("src/plugins/dpdk/CMakeLists.txt", "r") as f:
  cmake_content = f.read()

cmake_content = cmake_content.replace(
  'option(VPP_USE_SYSTEM_DPDK "Use the system installation of DPDK." OFF)',
  'option(VPP_USE_SYSTEM_DPDK "Use system DPDK" ON)'
)

with open("src/plugins/dpdk/CMakeLists.txt", "w") as f:
  f.write(cmake_content)

with open("src/plugins/dpdk/device/init.c", "r") as f:
  content = f.read()

# Check if MANA already patched
if "0x1414" not in content:
    # Add MANA after Google vNIC
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
    content = content.replace(old, new)

    # Add goto label
    old2 = "  vec_free (pci_addr);\n  vlib_pci_free_device_info (d);\n}"
    new2 = "next_device:\n  vec_free (pci_addr);\n  vlib_pci_free_device_info (d);\n}"
    content = content.replace(old2, new2, 1)
    
    with open("src/plugins/dpdk/device/init.c", "w") as f:
        f.write(content)
    print("MANA patch applied")
else:
    print("MANA patch already present")

  mana_xstats = '  if (xd->if_desc && strstr (xd->if_desc, "Microsoft Azure MANA"))\n    return;\n'
  if mana_xstats not in content:
    content = content.replace(
      '  int len, ret, i;\n  struct rte_eth_xstat_name *xstats_names = 0;\n',
      '  int len, ret, i;\n  struct rte_eth_xstat_name *xstats_names = 0;\n\n  if (xd->if_desc && strstr (xd->if_desc, "Microsoft Azure MANA"))\n    return;\n'
    )
    with open("src/plugins/dpdk/device/init.c", "w") as f:
      f.write(content)
    print("MANA xstats bypass added to init.c")

  with open("src/plugins/dpdk/device/dpdk_priv.h", "r") as f:
    priv = f.read()
  if mana_xstats not in priv:
    priv = priv.replace(
      '  if (!(xd->flags & DPDK_DEVICE_FLAG_ADMIN_UP))\n    return;\n',
      '  if (!(xd->flags & DPDK_DEVICE_FLAG_ADMIN_UP))\n    return;\n\n  if (xd->if_desc && strstr (xd->if_desc, "Microsoft Azure MANA"))\n    return;\n'
    )
    with open("src/plugins/dpdk/device/dpdk_priv.h", "w") as f:
      f.write(priv)
    print("MANA xstats bypass added to dpdk_priv.h")
PYEOF

# Check if VPP was already built (in tarball)
if [ -f /usr/local/lib/x86_64-linux-gnu/vpp_plugins/dpdk_plugin.so ]; then
    echo "dpdk_plugin.so exists, checking if MANA patched..."
    # Need to rebuild since the tarball has the old unpatched plugin
    echo "Rebuilding dpdk_plugin only..."
    
    # Need VPP build deps
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        autoconf automake libtool clang libpcap-dev python3-ply \
        libssl-dev libelf-dev nasm uuid-dev > /dev/null 2>&1
    pip3 install pyelftools ply > /dev/null 2>&1
    
    touch build-root/.deps.ok
    export PKG_CONFIG_PATH=/usr/local/lib/x86_64-linux-gnu/pkgconfig:$PKG_CONFIG_PATH
    make build-release CMAKE_ARGS="-DVPP_USE_SYSTEM_DPDK=ON" 2>&1 | tail -3
    
    # Copy patched plugin
    cp -f build-root/build-vpp-native/vpp/lib/x86_64-linux-gnu/vpp_plugins/dpdk_plugin.so \
          /usr/local/lib/x86_64-linux-gnu/vpp_plugins/dpdk_plugin.so
    
    # Also install VPP core libs from build
    cp -a build-root/install-vpp-native/vpp/lib/* /usr/local/lib/ 2>/dev/null
    cp -a build-root/install-vpp-native/vpp/bin/* /usr/local/bin/ 2>/dev/null
    ldconfig
    echo "VPP rebuilt with MANA patch: $(vpp --version 2>&1 | head -1)"
fi

echo "===== [7/8] Verify DPDK MANA with testpmd ====="
pkill -9 testpmd 2>/dev/null || true
rm -rf /var/run/dpdk
sleep 1
release_mana_pair
timeout 15 dpdk-testpmd -l 0-1 \
    -a 7870:00:00.0,mac=7c:ed:8d:25:e4:4d \
    --iova-mode va -m 512 \
    -- --auto-start --txd=128 --rxd=128 \
    > /tmp/testpmd-verify.log 2>&1
TESTPMD_RC=$?
echo "testpmd RC=$TESTPMD_RC"
grep -E "Port [0-9]+:|mana" /tmp/testpmd-verify.log || true
if grep -Eq "Port [0-9]+:" /tmp/testpmd-verify.log; then
    echo "DPDK MANA: VERIFIED WORKING"
else
    echo "DPDK MANA: FAILED"
    cat /tmp/testpmd-verify.log
    exit 1
fi
pkill -9 testpmd 2>/dev/null; rm -rf /var/run/dpdk; sleep 1

echo "===== [8/8] Start VPP with DPDK MANA ====="
pkill -9 -f "vpp -c" 2>/dev/null || true
sleep 1
rm -f /tmp/vpp-mana.log /run/vpp/cli.sock
mkdir -p /etc/vpp /run/vpp

python3 -c "
conf = '''unix {
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
'''
with open('/etc/vpp/startup.conf', 'w') as f:
    f.write(conf)
print('VPP config written')
"

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
    # Check if VPP is spinning (CPU > 95%)
    CPU=$(ps -p $VPP_PID -o pcpu= 2>/dev/null | tr -d ' ')
    if [ -n "$CPU" ] && [ "${CPU%.*}" -gt 95 ] 2>/dev/null && [ $i -gt 10 ]; then
        echo "VPP spinning at ${CPU}%! after ${i}s - killing"
        kill -9 $VPP_PID
        echo "VPP LOG:"
        cat /tmp/vpp-mana.log 2>/dev/null
        exit 1
    fi
done

echo ""
echo "============================================"
echo "         VPP DPDK MANA STATUS"
echo "============================================"
vppctl show version 2>&1
echo ""
echo "Interfaces:"
vppctl show interface 2>&1
echo ""
echo "Hardware:"
vppctl show hardware-interfaces 2>&1
echo ""
echo "VPP Log:"
cat /tmp/vpp-mana.log 2>/dev/null
echo ""
echo "============================================"
echo "VPP PID: $VPP_PID"
echo "============================================"
