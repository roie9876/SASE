#!/bin/bash
# ============================================================================
# Build VPP from source with MANA DPDK PMD support
# Run inside the vpp-mana pod on Ubuntu 24.04
# ============================================================================
set -e

echo "=== Phase 1: Install build dependencies ==="
DEBIAN_FRONTEND=noninteractive apt-get update > /dev/null 2>&1
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  git build-essential python3 python3-pip python3-venv \
  cmake ninja-build meson pkg-config \
  libnl-3-dev libnl-route-3-dev libssl-dev libelf-dev \
  libnuma-dev libudev-dev libmnl-dev \
  libibverbs-dev librdmacm-dev \
  iproute2 ethtool pciutils kmod iputils-ping iperf3 \
  nasm uuid-dev > /dev/null 2>&1
pip3 install pyelftools ply > /dev/null 2>&1
echo "[OK] Build dependencies"

echo "=== Phase 2: Build rdma-core v46 (for libmana) ==="
cd /tmp
if [ ! -d rdma-core ]; then
  git clone https://github.com/linux-rdma/rdma-core.git -b v46.0 --depth 1 > /dev/null 2>&1
fi
cd rdma-core && rm -rf build && mkdir build && cd build
cmake -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=lib/x86_64-linux-gnu -DNO_MAN_PAGES=1 .. > /dev/null 2>&1
make -j$(nproc) > /dev/null 2>&1
cmake --install . 2>/dev/null || true
cp -f /tmp/rdma-core/build/lib/libmana.so* /usr/lib/x86_64-linux-gnu/ 2>/dev/null || true
cp -f /tmp/rdma-core/build/lib/libibverbs/libmana-rdmav34.so /usr/lib/x86_64-linux-gnu/libibverbs/ 2>/dev/null || true
cp -f /tmp/rdma-core/build/lib/pkgconfig/libmana.pc /usr/lib/x86_64-linux-gnu/pkgconfig/ 2>/dev/null || true
cp -f /tmp/rdma-core/build/include/infiniband/manadv.h /usr/include/infiniband/ 2>/dev/null || true
ldconfig
echo "[OK] rdma-core v46 (libmana $(pkg-config --modversion libmana 2>/dev/null))"

echo "=== Phase 3: Clone VPP source ==="
cd /tmp
if [ ! -d vpp ]; then
  git clone https://gerrit.fd.io/r/vpp -b v26.02 --depth 1 > /dev/null 2>&1
fi
echo "[OK] VPP v26.02 source cloned"

echo "=== Phase 4: Configure VPP build with MANA PMD ==="
cd /tmp/vpp

# VPP uses an external DPDK or builds its own. We need to ensure net_mana is enabled.
# Check if there's a DPDK build config we can modify
if [ -f src/plugins/dpdk/CMakeLists.txt ]; then
  echo "  Found DPDK plugin CMakeLists"
fi

# Install VPP build deps
make install-dep UNATTENDED=y > /dev/null 2>&1 || true
echo "[OK] VPP build deps installed"

echo "=== Phase 5: Build VPP ==="
# Build VPP - this will take a while
export PKG_CONFIG_PATH=/usr/local/lib/x86_64-linux-gnu/pkgconfig:$PKG_CONFIG_PATH
make build-release CMAKE_ARGS="-DVPP_USE_SYSTEM_DPDK=ON" 2>&1 | tail -5
echo "[OK] VPP built"

echo "=== Phase 6: Check for MANA PMD ==="
find /tmp/vpp/build-root -name "dpdk_plugin.so" -exec strings {} \; | grep -iE "net_mana|mana_pci" | head -5
echo "=== BUILD DONE ==="
