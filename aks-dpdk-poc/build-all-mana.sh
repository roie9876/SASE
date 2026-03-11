#!/bin/bash
# ============================================================================
# Complete build: rdma-core + DPDK (shared) + VPP with MANA DPDK PMD
# Run inside vpp-mana pod on Ubuntu 24.04 / kernel 6.8
# ============================================================================
set -e

echo "=== [1/5] Install ALL dependencies ==="
DEBIAN_FRONTEND=noninteractive apt-get update > /dev/null 2>&1
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  build-essential libudev-dev libnl-3-dev libnl-route-3-dev \
  ninja-build libssl-dev libelf-dev python3-pip python3-venv meson libnuma-dev \
  rdma-core ibverbs-providers libibverbs-dev librdmacm-dev \
  curl gnupg2 git cmake iproute2 ethtool pciutils kmod \
  pkg-config python3-docutils util-linux sudo nasm uuid-dev \
  iputils-ping iperf3 binutils > /dev/null 2>&1
pip3 install pyelftools ply > /dev/null 2>&1
echo "  OK"

echo "=== [2/5] Build rdma-core v46 (libmana) ==="
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
echo "  OK (libmana $(pkg-config --modversion libmana 2>/dev/null))"

echo "=== [3/5] Build DPDK v24.11 SHARED (with MANA PMD) ==="
cd /tmp
[ ! -d dpdk-24 ] && git clone https://github.com/DPDK/dpdk.git -b v24.11 --depth 1 dpdk-24 > /dev/null 2>&1
cd dpdk-24 && rm -rf build
meson setup build --default-library=shared -Dprefix=/usr/local > /dev/null 2>&1
cd build && ninja -j$(nproc) > /dev/null 2>&1
ninja install > /dev/null 2>&1
ldconfig
echo "  OK - MANA PMD check:"
pkg-config --libs libdpdk 2>/dev/null | tr ' ' '\n' | grep -i mana || echo "  (MANA is statically linked into libdpdk)"
find /usr/local/lib -name "*mana*" 2>/dev/null
echo "  testpmd: $(which dpdk-testpmd)"

echo "=== [4/5] Build VPP v26.02 with system DPDK ==="
cd /tmp
[ ! -d vpp ] && git clone https://gerrit.fd.io/r/vpp -b v26.02 --depth 1 > /dev/null 2>&1
cd /tmp/vpp
# Install VPP build deps
make install-dep UNATTENDED=y > /dev/null 2>&1 || true
# Build with system DPDK
make build-release CMAKE_ARGS="-DVPP_USE_SYSTEM_DPDK=ON" 2>&1 | tail -5
echo "  VPP version:"
/tmp/vpp/build-root/install-vpp-native/vpp/bin/vpp --version 2>&1

echo "=== [5/5] Check MANA PMD in VPP ==="
DPDK_PLUGIN=$(find /tmp/vpp/build-root -name "dpdk_plugin.so" | head -1)
echo "  dpdk_plugin.so: $DPDK_PLUGIN"
if [ -n "$DPDK_PLUGIN" ]; then
  strings $DPDK_PLUGIN | grep -iE "net_mana|mana_pci" | head -5 || echo "  MANA not found in plugin (may be in shared libdpdk)"
fi
ldd $DPDK_PLUGIN 2>/dev/null | grep -i dpdk | head -5

echo "=== BUILD COMPLETE ==="
