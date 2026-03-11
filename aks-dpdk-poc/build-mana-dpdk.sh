#!/bin/bash
set -e

echo "=== Installing dependencies ==="
DEBIAN_FRONTEND=noninteractive apt-get update > /dev/null 2>&1
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  build-essential libudev-dev libnl-3-dev libnl-route-3-dev \
  ninja-build libssl-dev libelf-dev python3-pip meson libnuma-dev \
  rdma-core ibverbs-providers libibverbs-dev librdmacm-dev \
  curl gnupg2 git cmake iproute2 ethtool pciutils kmod > /dev/null 2>&1
pip3 install pyelftools > /dev/null 2>&1
echo "Dependencies installed"

echo "=== Building rdma-core v46 ==="
cd /tmp
if [ ! -d rdma-core ]; then
  git clone https://github.com/linux-rdma/rdma-core.git -b v46.0 --depth 1 > /dev/null 2>&1
fi
cd rdma-core
rm -rf build && mkdir build && cd build
cmake -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=lib/x86_64-linux-gnu .. > /dev/null 2>&1
make -j$(nproc) > /dev/null 2>&1
make install > /dev/null 2>&1
echo "rdma-core v46 installed"
ls /usr/lib/x86_64-linux-gnu/libibverbs/libmana* && echo "libmana provider OK"

echo "=== Building DPDK v23.11 ==="
cd /tmp
if [ ! -d dpdk ]; then
  git clone https://github.com/DPDK/dpdk.git -b v23.11 --depth 1 > /dev/null 2>&1
fi
cd dpdk
rm -rf build && meson build > /dev/null 2>&1
cd build
ninja -j$(nproc) > /dev/null 2>&1
ninja install > /dev/null 2>&1
ldconfig
echo "DPDK v23.11 installed"
which dpdk-testpmd && echo "testpmd binary ready"
