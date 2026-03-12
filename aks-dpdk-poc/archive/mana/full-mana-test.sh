#!/bin/bash
set -e

echo "=== Installing all dependencies ==="
DEBIAN_FRONTEND=noninteractive apt-get update > /dev/null 2>&1
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  build-essential libudev-dev libnl-3-dev libnl-route-3-dev \
  ninja-build libssl-dev libelf-dev python3-pip meson libnuma-dev \
  rdma-core ibverbs-providers libibverbs-dev librdmacm-dev \
  curl gnupg2 git cmake iproute2 ethtool pciutils kmod \
  pkg-config python3-docutils > /dev/null 2>&1
pip3 install pyelftools > /dev/null 2>&1
echo "Dependencies OK"

echo "=== Building rdma-core v46 (libmana) ==="
cd /tmp
if [ ! -d rdma-core ]; then
  git clone https://github.com/linux-rdma/rdma-core.git -b v46.0 --depth 1 > /dev/null 2>&1
fi
cd rdma-core && rm -rf build && mkdir build && cd build
cmake -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=lib/x86_64-linux-gnu .. > /dev/null 2>&1
make -j$(nproc) > /dev/null 2>&1
make install > /dev/null 2>&1
ls /usr/lib/x86_64-linux-gnu/libibverbs/libmana* > /dev/null && echo "libmana OK"

echo "=== Building DPDK v23.11 (MANA PMD) ==="
cd /tmp
if [ ! -d dpdk ]; then
  git clone https://github.com/DPDK/dpdk.git -b v23.11 --depth 1 > /dev/null 2>&1
fi
cd dpdk && rm -rf build && meson build > /dev/null 2>&1
cd build && ninja -j$(nproc) > /dev/null 2>&1
ninja install > /dev/null 2>&1
ldconfig
echo "DPDK OK: $(which dpdk-testpmd)"

echo "=== Allocating HugePages ==="
echo 1024 | tee /sys/devices/system/node/node*/hugepages/hugepages-2048kB/nr_hugepages > /dev/null
grep HugePages_Total /proc/meminfo

echo "=== MANA DPDK testpmd on eth1 ==="
# eth1 netvsc is already bound to uio_hv_generic from previous step
# Using known values for the secondary NIC
BUS_INFO="7870:00:00.0"
MANA_MAC="70:a8:a5:52:d4:42"

echo "BUS_INFO: $BUS_INFO"
echo "MANA_MAC: $MANA_MAC"

# Make sure enP30832s1d1 (the MANA VF for eth1) is down
ip link set enP30832s1d1 down 2>/dev/null || true

echo ""
echo "=== Starting dpdk-testpmd ==="
timeout 20 dpdk-testpmd -l 0-1 \
  --vdev="$BUS_INFO,mac=$MANA_MAC" \
  -- --forward-mode=txonly --auto-start \
  --txd=128 --rxd=128 --stats 2 2>&1 || true

echo "=== DONE ==="
