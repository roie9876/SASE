#!/bin/bash
# Resume from the VPP portion after rdma-core and DPDK have already been built.
set -e

echo "===== [7/9] Clone & patch VPP v26.02 ====="
cd /tmp
rm -rf /tmp/vpp
git clone https://gerrit.fd.io/r/vpp -b v26.02 --depth 1 > /dev/null 2>&1
cd vpp

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
with open("src/plugins/dpdk/device/init.c", "w") as f:
    f.write(c)
print("VPP patched: system DPDK + MANA whitelist + skip UIO")
PYEOF

echo "===== [8/9] Build VPP ====="
touch build-root/.deps.ok
export PKG_CONFIG_PATH=/usr/local/lib/x86_64-linux-gnu/pkgconfig:$PKG_CONFIG_PATH
echo "Building VPP (this takes ~30 min)..."
make build-release CMAKE_ARGS="-DVPP_USE_SYSTEM_DPDK=ON" 2>&1 | tail -5
VPP_DIR=/tmp/vpp/build-root/install-vpp-native/vpp
cp -a "$VPP_DIR"/bin/* /usr/local/bin/ 2>/dev/null
cp -a "$VPP_DIR"/lib/* /usr/local/lib/ 2>/dev/null
cp -f /tmp/vpp/build-root/build-vpp-native/vpp/lib/x86_64-linux-gnu/vpp_plugins/dpdk_plugin.so \
  /usr/local/lib/x86_64-linux-gnu/vpp_plugins/dpdk_plugin.so
ldconfig
echo "VPP: $(vpp --version 2>&1 | head -1)"

tar czf /host/tmp/vpp-dpdk-all.tar.gz \
  /usr/local/bin/vpp /usr/local/bin/vppctl /usr/local/bin/dpdk-testpmd \
  /usr/local/lib/x86_64-linux-gnu/ \
  /usr/lib/x86_64-linux-gnu/libmana* \
  /usr/lib/x86_64-linux-gnu/libibverbs/ \
  /lib/x86_64-linux-gnu/libmlx5* \
  2>/dev/null || true
echo "Backup saved: $(ls -lh /host/tmp/vpp-dpdk-all.tar.gz 2>/dev/null | awk '{print $5}')"

echo "===== [9/9] Start VPP with DPDK MANA ====="
# Escape the pod cgroup so DPDK can mmap hugepages.
echo $$ > /sys/fs/cgroup/cgroup.procs
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
}
buffers {
  buffers-per-numa 16384
  default data-size 2048
}
dpdk {
  dev 7870:00:00.0 {
    name mana0
    devargs mac=60:45:bd:fd:d8:eb
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
"

ip link set enP30832s1d1 down 2>/dev/null || true
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
echo "Hardware:"
vppctl show hardware-interfaces 2>&1
echo ""
echo "Log:"
cat /tmp/vpp-mana.log 2>/dev/null
echo ""
echo "============================================"
echo "VPP PID: $VPP_PID"
echo "============================================"