#!/bin/bash
# Build-only script: builds rdma-core + DPDK, does NOT touch eth1
set -e

DEBIAN_FRONTEND=noninteractive apt-get update > /dev/null 2>&1
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  build-essential libudev-dev libnl-3-dev libnl-route-3-dev \
  ninja-build libssl-dev libelf-dev python3-pip meson libnuma-dev \
  rdma-core ibverbs-providers libibverbs-dev librdmacm-dev \
  curl gnupg2 git cmake iproute2 ethtool pciutils kmod \
  pkg-config python3-docutils util-linux > /dev/null 2>&1
pip3 install pyelftools > /dev/null 2>&1
echo "[1/3] Dependencies OK"

cd /tmp
[ ! -d rdma-core ] && git clone https://github.com/linux-rdma/rdma-core.git -b v46.0 --depth 1 > /dev/null 2>&1
cd rdma-core && rm -rf build && mkdir build && cd build
cmake -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=lib/x86_64-linux-gnu -DNO_MAN_PAGES=1 .. > /dev/null 2>&1
make -j$(nproc) > /dev/null 2>&1
cmake --install . 2>/dev/null || true
cp -f /tmp/rdma-core/build/lib/libmana.so* /usr/lib/x86_64-linux-gnu/ 2>/dev/null || true
cp -f /tmp/rdma-core/build/lib/libibverbs/libmana-rdmav34.so /usr/lib/x86_64-linux-gnu/libibverbs/ 2>/dev/null || true
cp -f /tmp/rdma-core/build/lib/pkgconfig/libmana.pc /usr/lib/x86_64-linux-gnu/pkgconfig/ 2>/dev/null || true
cp -f /tmp/rdma-core/build/include/infiniband/manadv.h /usr/include/infiniband/ 2>/dev/null || true
ldconfig
echo "[2/3] rdma-core v46 OK (libmana $(pkg-config --modversion libmana 2>/dev/null))"

cd /tmp
[ ! -d dpdk-24 ] && git clone https://github.com/DPDK/dpdk.git -b v24.11 --depth 1 dpdk-24 > /dev/null 2>&1
cd dpdk-24 && rm -rf build
meson setup build > /dev/null 2>&1
cd build && ninja -j$(nproc) > /dev/null 2>&1
ninja install > /dev/null 2>&1
ldconfig
echo "[3/3] DPDK v24.11 OK"
echo "BUILD COMPLETE - do NOT run this again, call test-mana-run.sh next"
