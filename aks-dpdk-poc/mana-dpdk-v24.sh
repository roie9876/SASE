#!/bin/bash
# ============================================================================
# MANA DPDK v24.11 Complete Setup Script  
# Runs inside vpp-mana pod (hostNetwork, privileged)
# Keeps eth0 for K8s management, uses eth1 for DPDK
# ============================================================================
set -e

echo "========================================"
echo "Phase 1: Install dependencies"
echo "========================================"
DEBIAN_FRONTEND=noninteractive apt-get update > /dev/null 2>&1
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  build-essential libudev-dev libnl-3-dev libnl-route-3-dev \
  ninja-build libssl-dev libelf-dev python3-pip meson libnuma-dev \
  rdma-core ibverbs-providers libibverbs-dev librdmacm-dev \
  curl gnupg2 git cmake iproute2 ethtool pciutils kmod \
  pkg-config python3-docutils > /dev/null 2>&1
pip3 install pyelftools > /dev/null 2>&1
echo "[OK] Dependencies installed"

echo "========================================"
echo "Phase 2: Build rdma-core v46 (libmana)"  
echo "========================================"
cd /tmp
[ ! -d rdma-core ] && git clone https://github.com/linux-rdma/rdma-core.git -b v46.0 --depth 1 > /dev/null 2>&1
cd rdma-core && rm -rf build && mkdir build && cd build
cmake -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=lib/x86_64-linux-gnu -DNO_MAN_PAGES=1 .. > /dev/null 2>&1
make -j$(nproc) > /dev/null 2>&1
cmake --install . 2>/dev/null || true
# Manual copy in case cmake install fails on man pages
cp -f /tmp/rdma-core/build/lib/libmana.so* /usr/lib/x86_64-linux-gnu/ 2>/dev/null || true
cp -f /tmp/rdma-core/build/lib/libibverbs/libmana-rdmav34.so /usr/lib/x86_64-linux-gnu/libibverbs/ 2>/dev/null || true
cp -f /tmp/rdma-core/build/lib/pkgconfig/libmana.pc /usr/lib/x86_64-linux-gnu/pkgconfig/ 2>/dev/null || true
cp -f /tmp/rdma-core/build/include/infiniband/manadv.h /usr/include/infiniband/ 2>/dev/null || true
ldconfig
echo "[OK] rdma-core v46 (libmana $(pkg-config --modversion libmana 2>/dev/null))"

echo "========================================"
echo "Phase 3: Build DPDK v24.11 (MANA PMD)"
echo "========================================"
cd /tmp
[ ! -d dpdk-24 ] && git clone https://github.com/DPDK/dpdk.git -b v24.11 --depth 1 dpdk-24 > /dev/null 2>&1
cd dpdk-24 && rm -rf build
meson setup build 2>&1 | grep -E "mana|net_mana|libmana" || true
cd build && ninja -j$(nproc) > /dev/null 2>&1
ninja install > /dev/null 2>&1
ldconfig
echo "[OK] DPDK v24.11 ($(dpdk-testpmd --version 2>&1 | head -1 || echo 'installed'))"

echo "========================================"
echo "Phase 4: Configure HugePages"
echo "========================================"
echo 1024 | tee /sys/devices/system/node/node*/hugepages/hugepages-2048kB/nr_hugepages > /dev/null
mkdir -p /mnt/huge
mount -t hugetlbfs nodev /mnt/huge 2>/dev/null || true
echo "[OK] HugePages: $(grep HugePages_Total /proc/meminfo | awk '{print $2}') x 2MB"

echo "========================================"
echo "Phase 5: Identify MANA eth1 interfaces"
echo "========================================"
PRIMARY="eth1"
SECONDARY=$(ip -br link show master $PRIMARY | awk '{ print $1 }')
MANA_MAC=$(ip -br link show master $PRIMARY | awk '{ print $3 }')
BUS_INFO=$(ethtool -i $SECONDARY | grep bus-info | awk '{ print $2 }')
DEV_UUID=$(basename $(readlink /sys/class/net/$PRIMARY/device))

echo "   PRIMARY:   $PRIMARY"
echo "   SECONDARY: $SECONDARY"
echo "   MANA_MAC:  $MANA_MAC"
echo "   BUS_INFO:  $BUS_INFO"
echo "   DEV_UUID:  $DEV_UUID"

# Save for later use
echo "$MANA_MAC" > /tmp/mana_mac.txt
echo "$BUS_INFO" > /tmp/mana_bus.txt
echo "$DEV_UUID" > /tmp/mana_uuid.txt

echo "========================================"
echo "Phase 6: Bind eth1 netvsc to uio_hv_generic"
echo "========================================"
ip link set $PRIMARY down
ip link set $SECONDARY down
echo "[OK] Interfaces DOWN"

chroot /host modprobe uio_hv_generic
NET_UUID="f8615163-df3e-46c5-913f-f2d2f965ed0e"
echo $NET_UUID > /sys/bus/vmbus/drivers/uio_hv_generic/new_id 2>/dev/null || true
echo $DEV_UUID > /sys/bus/vmbus/drivers/hv_netvsc/unbind
echo $DEV_UUID > /sys/bus/vmbus/drivers/uio_hv_generic/bind
echo "[OK] eth1 netvsc -> uio_hv_generic"

echo "========================================"
echo "Phase 7: Run DPDK testpmd on MANA"
echo "========================================"
rm -rf /var/run/dpdk
ulimit -l unlimited

echo "--- testpmd starting (txonly, 20 sec) ---"
timeout 20 dpdk-testpmd -l 0-1 \
  --huge-dir /mnt/huge \
  --vdev="$BUS_INFO,mac=$MANA_MAC" \
  -- --forward-mode=txonly --auto-start \
  --txd=128 --rxd=128 \
  --stats 2 \
  --total-num-mbufs=2048 2>&1 || true

echo "========================================"
echo "COMPLETE"  
echo "========================================"
