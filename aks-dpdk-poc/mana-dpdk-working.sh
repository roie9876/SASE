#!/bin/bash
# ============================================================================
# MANA DPDK Complete Working Test - Ubuntu 24.04 / kernel 6.8 / D4s_v6
# 
# Prerequisites:
#   - AKS with --os-sku Ubuntu2404, --node-vm-size Standard_D4s_v6
#   - Second NIC added to VMSS with AccelNet
#   - Pod: hostNetwork, hostPID, privileged, /host mount
# ============================================================================
set -e

echo "=========================================="
echo " MANA DPDK Test on Ubuntu 24.04 (k6.8)"
echo "=========================================="

# Phase 1: Install dependencies
echo "[Phase 1] Installing dependencies..."
DEBIAN_FRONTEND=noninteractive apt-get update > /dev/null 2>&1
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  build-essential libudev-dev libnl-3-dev libnl-route-3-dev \
  ninja-build libssl-dev libelf-dev python3-pip meson libnuma-dev \
  rdma-core ibverbs-providers libibverbs-dev librdmacm-dev \
  curl gnupg2 git cmake iproute2 ethtool pciutils kmod \
  pkg-config python3-docutils util-linux > /dev/null 2>&1
pip3 install pyelftools > /dev/null 2>&1
echo "  [OK] Dependencies"

# Phase 2: Build rdma-core v46
echo "[Phase 2] Building rdma-core v46..."
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
echo "  [OK] rdma-core v46 (libmana $(pkg-config --modversion libmana 2>/dev/null))"

# Phase 3: Build DPDK v24.11
echo "[Phase 3] Building DPDK v24.11..."
cd /tmp
[ ! -d dpdk-24 ] && git clone https://github.com/DPDK/dpdk.git -b v24.11 --depth 1 dpdk-24 > /dev/null 2>&1
cd dpdk-24 && rm -rf build
meson setup build > /dev/null 2>&1
cd build && ninja -j$(nproc) > /dev/null 2>&1
ninja install > /dev/null 2>&1
ldconfig
echo "  [OK] DPDK v24.11 with net_mana PMD"

# Phase 4: Verify MANA hardware
echo "[Phase 4] Verifying MANA..."
echo "  Kernel: $(uname -r)"
echo "  MANA PCI: $(lspci -d 1414:00ba 2>/dev/null)"
echo "  IB devices: $(ls /sys/class/infiniband/ 2>/dev/null)"
echo "  uverbs: $(ls /dev/infiniband/ 2>/dev/null | grep uverbs)"

# Phase 5: Identify eth1 MANA details (before touching it)
echo "[Phase 5] Identifying eth1..."
ip -br link | grep -E "eth|enP"
SECONDARY=$(ip -br link show master eth1 | awk '{ print $1 }')
MANA_MAC=$(ip -br link show master eth1 | awk '{ print $3 }')
BUS_INFO=$(ethtool -i $SECONDARY | grep bus-info | awk '{ print $2 }')
DEV_UUID=$(basename $(readlink /sys/class/net/eth1/device))
echo "  SECONDARY=$SECONDARY MAC=$MANA_MAC BUS=$BUS_INFO UUID=$DEV_UUID"

# Phase 6: Allocate hugepages
echo "[Phase 6] Allocating HugePages..."
echo 1024 | tee /sys/devices/system/node/node*/hugepages/hugepages-2048kB/nr_hugepages > /dev/null
echo "  HugePages_Total: $(grep HugePages_Total /proc/meminfo | awk '{print $2}')"

# Phase 7: Bind eth1 netvsc to uio_hv_generic
echo "[Phase 7] Binding eth1 to uio_hv_generic..."
ip link set eth1 down
ip link set $SECONDARY down
NET_UUID="f8615163-df3e-46c5-913f-f2d2f965ed0e"
chroot /host modprobe uio_hv_generic
echo $NET_UUID > /sys/bus/vmbus/drivers/uio_hv_generic/new_id 2>/dev/null || true
echo $DEV_UUID > /sys/bus/vmbus/drivers/hv_netvsc/unbind
echo $DEV_UUID > /sys/bus/vmbus/drivers/uio_hv_generic/bind
echo "  [OK] eth1 -> uio_hv_generic"

# Phase 8: Run testpmd
echo "[Phase 8] Running dpdk-testpmd..."
rm -rf /var/run/dpdk

# Using --no-huge for now (K8s cgroup blocks hugetlb allocation in pod)
# In production, use proper hugepages-2Mi resource requests
timeout 30 dpdk-testpmd -l 0-1 \
  --no-huge -m 512 \
  --iova-mode va \
  --vdev="$BUS_INFO,mac=$MANA_MAC" \
  -- --forward-mode=txonly --auto-start \
  --txd=128 --rxd=128 \
  --stats 2 \
  --total-num-mbufs=2048 2>&1 || true

echo "=========================================="
echo " TEST COMPLETE"
echo "=========================================="
