# MANA DPDK on AKS — Session State & Context

## What We're Building
Cloud-native SASE platform on AKS using FD.io VPP with DPDK kernel bypass on MANA NIC.

## Current Status (March 11, 2026 — Late Night Session)

**DPDK MANA kernel bypass: PROVEN WORKING via testpmd with NATIVE net_mana driver**
**VPP with MANA: Shows `mana0` interface (not FailsafeEthernet1!), CLI responsive at ~13% CPU**
**Remaining blocker: `set interface state mana0 up` fails with -22 (EINVAL from mana_dev_start → ibv_create_cq)**

### Key Breakthroughs This Session
1. **Root cause of FailsafeEthernet1**: DPDK runtime loads PMD .so files from `dpdk/pmds-25.0/` directory. `net_failsafe`, `net_tap`, `net_netvsc`, and `net_vdev_netvsc` PMDs were hijacking the MANA device before `net_mana` could bind natively.
2. **Fix**: Remove `librte_net_{failsafe,tap,netvsc,vdev_netvsc}*.so*` from `/usr/local/lib/x86_64-linux-gnu/dpdk/pmds-25.0/`. After removal, testpmd shows `Driver name: net_mana` with 100 Gbps link.
3. **VPP driver classification**: Added `net_mana` to `src/plugins/dpdk/device/driver.c` so VPP recognizes it as "Microsoft Azure MANA" instead of "### UNKNOWN ###".
4. **VPP CPU spin fix**: Added `poll-sleep-usec 100` to VPP config to prevent main-thread polling loop from consuming 99% CPU and starving CLI.
5. **Build path fix**: All VPP build scripts now pass `CMAKE_ARGS="-DVPP_USE_SYSTEM_DPDK=ON"` explicitly. The `dpdk_plugin.so` links against system DPDK shared libraries (not VPP's bundled external DPDK).

## Current Infrastructure (sase-poc-lab-rg, swedencentral)

### Working Cluster: sase-ubuntu2404-aks
- **OS**: Ubuntu 24.04 (`--os-sku Ubuntu2404`)
- **Kernel**: `6.8.0-1046-azure` (native `mana_ib` built-in!)
- **VM Size**: `Standard_D4s_v6` (guaranteed MANA NIC)
- **Network**: Dual-stack IPv4/IPv6, Azure CNI overlay + Cilium
- **VNet**: `AKS-DualStack-VNet` (10.120.0.0/16 + fd00:db8:deca::/48)
- **Node**: `aks-nodepool1-38799324-vmss000000` (IP: 10.120.2.6)
- **Dual NIC**: eth0 (K8s mgmt, 10.120.2.x) + eth1 (DPDK, 10.120.3.x subnet via dpdk-nic)
- **ACR**: `sasepocacr.azurecr.io` (Standard SKU, attached to AKS)

### Branch VM: branch-vm-dpdk
- **IP**: 10.120.4.4 (private), 20.240.44.74 (public SSH)
- **VNet**: Same AKS-DualStack-VNet, branch-subnet (10.120.4.0/24)
- **SSH**: `ssh azureuser@20.240.44.74`

### Pod: vpp-mana
- **Image**: `ubuntu:22.04` (base), everything built from source inside
- **Config**: hostNetwork, hostPID, privileged, /host mount, /sys mount, /dev mount
- **Node**: `aks-nodepool1-38799324-vmss000000`

## What Needs to Be Built Inside the Pod

### 1. rdma-core v46
- Source: `/tmp/rdma-core` (git clone v46.0)
- Install to: `/usr/lib/x86_64-linux-gnu/`
- Key files: `libmana-rdmav34.so` (MANA verbs provider), `libmlx5.so.1` (MLX5_1.24 symbols)
- **CRITICAL**: Must install rdma-core v46's `libmlx5.so` over system version — DPDK 24.11 requires `MLX5_1.24` symbols (Ubuntu 22.04 apt only has up to `MLX5_1.22`)

### 2. DPDK v24.11 (SHARED libraries)
- Source: `/tmp/dpdk-24` (git clone v24.11)
- Install to: `/usr/local/lib/x86_64-linux-gnu/`
- Key file: `librte_net_mana.so.25` (MANA PMD!)
- testpmd: `/usr/local/bin/dpdk-testpmd`

### 3. VPP v26.02 (with system DPDK + MANA patch)
- Source: `/tmp/vpp` (git clone v26.02)
- Built with: `VPP_USE_SYSTEM_DPDK=ON` (via sed in CMakeLists.txt)
- **MANA PCI whitelist patch** applied to `src/plugins/dpdk/device/init.c` (see below)
- **CRITICAL**: After `make build-release`, copy `dpdk_plugin.so` from **build** dir, NOT install dir:
  ```
  cp -f build-root/build-vpp-native/vpp/lib/x86_64-linux-gnu/vpp_plugins/dpdk_plugin.so \
        /usr/local/lib/x86_64-linux-gnu/vpp_plugins/dpdk_plugin.so
  ```

## Key Findings & Breakthroughs

### DPDK testpmd on MANA — CONFIRMED WORKING (PCI mode + hugepages)
```
EAL: Selected IOVA mode 'VA'
MANA_DRIVER: mana_init_once(): MP INIT PRIMARY
MANA_DRIVER: mana_mr_btree_init(): B-tree initialized
Configuring Port 0 (socket 0)
Port 0: 60:45:BD:FD:D8:EB
port 0: RX queue number: 1 Tx queue number: 1
io packet forwarding - ports=1 - cores=1 - streams=1
```
**Command that works:**
```bash
echo $$ > /sys/fs/cgroup/cgroup.procs  # MUST escape pod cgroup first!
dpdk-testpmd -l 0-1 -a 7870:00:00.0,mac=60:45:bd:fd:d8:eb --iova-mode va -m 512 -- --auto-start --txd=128 --rxd=128
```

### Three Critical Fixes Discovered

#### Fix 1: Hugepage cgroup escape (SOLVED)
- **Problem**: Pod's cgroupv2 blocks `mmap` on hugetlbfs → `ENOMEM`
- **Root cause**: K8s node reports 0 hugepages to scheduler; pod cgroup can't account for hugetlb
- **Solution**: `echo $$ > /sys/fs/cgroup/cgroup.procs` — moves process to root cgroup
- **Verify**: `python3 -c "import os,mmap; fd=os.open('/dev/hugepages/t',os.O_CREAT|os.O_RDWR,0o600); os.ftruncate(fd,2*1024*1024); m=mmap.mmap(fd,2*1024*1024); print('OK'); m.close(); os.close(fd); os.unlink('/dev/hugepages/t')"`
- **Note**: `--no-huge` mode hangs DPDK EAL at `Selected IOVA mode 'VA'` — do NOT use

#### Fix 2: rdma-core v46 libmlx5 (SOLVED)
- **Problem**: DPDK 24.11's `librte_common_mlx5.so.25` requires `MLX5_1.24` symbol version
- **Root cause**: Ubuntu 22.04 apt rdma-core (v39) only has up to `MLX5_1.22`
- **Solution**: Build and install rdma-core v46 which includes `MLX5_1.24`
- **Verify**: `objdump -p /lib/x86_64-linux-gnu/libmlx5.so.1 | grep MLX5_1.24`

#### Fix 3: VPP MANA PCI whitelist patch (SOLVED)
- **Problem**: VPP v26.02 `dpdk_plugin.so` has hardcoded PCI device whitelist — MANA (`0x1414:0x00ba`) is NOT in it → `"Unsupported PCI device"` error
- **Location**: `src/plugins/dpdk/device/init.c`, line ~800
- **Solution**: Add MANA to whitelist with `goto next_device` (skip UIO bind, like Mellanox bifurcated driver)
- **Patch** (apply via `aks-dpdk-poc/mana-vpp-patch.py` or manually):
```c
    /* Google vNIC */
    else if (d->vendor_id == 0x1ae0 && d->device_id == 0x0042)
      ;
    /* Microsoft Azure MANA - bifurcated driver, skip UIO bind */
    else if (d->vendor_id == 0x1414 && d->device_id == 0x00ba)
      {
        goto next_device;
      }
    else
      {
        dpdk_log_warn ("Unsupported PCI device ...");
        continue;
      }
```
And add label before loop end:
```c
next_device:
  vec_free (pci_addr);
  vlib_pci_free_device_info (d);
}
```

### MANA DPDK Requirements (from Microsoft docs)
1. Kernel Ethernet driver (5.15+) → ✅
2. Kernel InfiniBand driver (6.2+) → ✅ built-in on Ubuntu 24.04 k6.8
3. DPDK MANA PMD (22.11+) → ✅ v24.11
4. rdma-core libmana (v44+) → ✅ v46

### OS/Kernel Test Matrix
| OS | Kernel | mana_ib | DPDK Result |
|----|--------|---------|-------------|
| Ubuntu 22.04 | 5.15 | Backport broken | ibv_reg_mr EPROTO |
| AzureLinux 3.0 | 6.6 | CONFIG disabled | No module |
| **Ubuntu 24.04** | **6.8** | **Built-in** | **WORKS** |

### VPP Start Status
- VPP PCI whitelist patch applied and `dpdk_plugin.so` rebuilt (incremental, seconds)
- VPP with `dev 7870:00:00.0` config — **untested after cgroup+mlx5 fixes** (rebuild in progress)
- Previous attempts: VPP hung at 100% CPU during DPDK init (before hugepage and mlx5 fixes were applied)
- March 11 finding: the failing runtime exposed `FailsafeEthernet1` and spun at ~99% CPU because some scripts patched `CMakeLists.txt` but still built VPP without `CMAKE_ARGS="-DVPP_USE_SYSTEM_DPDK=ON"`
- Corrective action: all rebuild/resume/image paths must pass `CMAKE_ARGS="-DVPP_USE_SYSTEM_DPDK=ON"` and install `dpdk_plugin.so` from `build-root/build-vpp-native/...`

### Known Issues & Workarounds
1. **Hugepages in K8s pods**: cgroupv2 blocks hugetlb mmap. **Workaround**: `echo $$ > /sys/fs/cgroup/cgroup.procs` before running DPDK/VPP
2. **`--no-huge` mode**: Hangs DPDK EAL — do NOT use. Use real hugepages with cgroup escape instead
3. **rdma-core MLX5 version**: Must install rdma-core v46 over apt version for `MLX5_1.24`
4. **VPP `make install-dep`**: Gets stuck on `tzdata` debconf prompt. **Workaround**: Skip with `touch build-root/.deps.ok` and install deps manually with `DEBIAN_FRONTEND=noninteractive`
5. **VPP dpdk_plugin.so install**: `make build-release` install dir has UNPATCHED plugin. Must `cp -f` from `build-root/build-vpp-native/vpp/lib/` after rebuild
6. **VPP spinning at 100% CPU**: VPP's DPDK polling loop starves the CLI. **Fix**: Add `poll-sleep-usec 100` to `unix {}` section of startup.conf
7. **DPDK failsafe/netvsc PMDs hijack MANA**: Even with system DPDK built correctly, the `net_failsafe`/`net_tap`/`net_netvsc` PMD .so files intercept the MANA device. **Fix**: Delete `librte_net_{failsafe,tap,netvsc,vdev_netvsc}*` from `dpdk/pmds-25.0/`
8. **VPP unknown driver 'net_mana'**: VPP v26.02 doesn't have MANA in its driver table. **Fix**: Add entry to `src/plugins/dpdk/device/driver.c`. Triggers SIGSEGV on `show hardware-interfaces mana0` without the patch.
9. **CURRENT BLOCKER: VPP SIGSEGV in dpdk_counters_xstats_init()**: When `set interface state mana0 up` executes, VPP calls `dpdk_interface_admin_up_down()` → `dpdk_counters_xstats_init()` → `vlib_validate_simple_counter()` → `vlib_stats_validate()` → SIGSEGV at address 0x7aa2a4b35ab0. The log shows `rte_eth_xstats_get(0) returned 8/0 stats` right before crash, suggesting a stats counter size mismatch. The underlying `rte_eth_dev_start()` may have also failed with -22 (from `mana_start_tx_queues` CQ creation), and the xstats init path crashes on the partially-initialized device. Fixing this likely requires either: (a) patching VPP's dpdk_counters_xstats_init to handle MANA's stats, (b) ensuring rte_eth_dev_configure() properly sets up queues before start, or (c) setting `n_rx_desc` and `n_tx_desc` to match MANA's limits (128 worked in testpmd).

## MANA Interface Details
- **PCI**: `7870:00:00.0` (vendor 1414, device 00ba)
- **eth1 MAC**: `60:45:bd:fd:d8:eb`
- **eth1 VF**: `enP30832s1d1`
- **Bus info**: `7870:00:00.0`
- **Device UUID**: `f8615163-0001-1000-2000-6045bdfdd8eb`
- **IB devices**: `mana_0`, `manae_0` (uverbs0, uverbs1)
- **MANA has 2 ports on 1 PCI device**: port 1 = eth0 (mgmt, UP), port 2 = enP30832s1d1 (DPDK, must be DOWN)

## VPP startup.conf for DPDK MANA (target config)
```
unix {
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
```
**Prerequisites before starting VPP:**
1. `echo $$ > /sys/fs/cgroup/cgroup.procs` (escape pod cgroup)
2. `ip link set enP30832s1d1 down` (DPDK needs VF down)
3. Hugepages allocated: `echo 1024 > /sys/devices/system/node/node*/hugepages/hugepages-2048kB/nr_hugepages`

## Artifact Backup & Restore

### Local backup (Mac)
The full artifact tarball (rdma-core + DPDK + VPP + plugins) is saved locally:
```
~/SASE/aks-dpdk-poc/artifacts/vpp-dpdk-all.tar.gz   (152MB)
```
It is also saved on the AKS node at `/host/tmp/vpp-dpdk-all.tar.gz` (survives pod restarts but not node reimaging).

### Restore after pod recreation
```bash
# Copy tarball into new pod
kubectl cp ~/SASE/aks-dpdk-poc/artifacts/vpp-dpdk-all.tar.gz default/vpp-mana:/tmp/vpp-dpdk-all.tar.gz

# Extract and ldconfig
kubectl exec vpp-mana -- sh -c 'tar xzf /tmp/vpp-dpdk-all.tar.gz -C / && ldconfig'

# Remove failsafe PMDs (CRITICAL - prevents MANA hijack)
kubectl exec vpp-mana -- sh -c 'rm -f /usr/local/lib/x86_64-linux-gnu/dpdk/pmds-25.0/librte_net_{failsafe,tap,netvsc,vdev_netvsc}*; ldconfig'
```
Or use the automated restore script: `aks-dpdk-poc/full-setup-vpp-mana.sh`

### What's in the tarball
- `/usr/local/bin/vpp`, `/usr/local/bin/vppctl`, `/usr/local/bin/dpdk-testpmd`
- `/usr/local/lib/x86_64-linux-gnu/` — all VPP + DPDK shared libraries + plugins
- `/usr/lib/x86_64-linux-gnu/libmana*` — rdma-core MANA verbs provider
- `/usr/lib/x86_64-linux-gnu/libibverbs/` — ibverbs providers
- `/lib/x86_64-linux-gnu/libmlx5*` — MLX5_1.24 from rdma-core v46

## Netvsc Binding Procedure (NOT needed for bifurcated DPDK)
**Note**: MANA DPDK uses bifurcated driver model (kernel mana driver + rdma-core verbs + DPDK PMD).
No UIO/VFIO binding needed. The kernel `mana` driver stays loaded. Just set the VF interface DOWN.

The old netvsc unbind procedure below is **NOT required** and causes eth1 to disappear (needs VMSS restart to restore):
```bash
# DO NOT USE - kept for reference only
# echo $DEV_UUID > /sys/bus/vmbus/drivers/hv_netvsc/unbind
# echo $DEV_UUID > /sys/bus/vmbus/drivers/uio_hv_generic/bind
```

## Build & Setup Scripts

| Script | Purpose |
|--------|---------|
| `aks-dpdk-poc/full-rebuild-and-start.sh` | Complete rebuild: rdma-core + DPDK + VPP (patched) + start VPP |
| `aks-dpdk-poc/fix-mana-dpdk.sh` | Remove failsafe/netvsc PMDs and verify testpmd uses native net_mana |
| `aks-dpdk-poc/patch-vpp-mana-driver.sh` | Patch VPP driver.c for MANA, incremental rebuild, start VPP |
| `aks-dpdk-poc/start-vpp-clean.sh` | Clean VPP start with poll-sleep-usec (no testpmd first) |
| `aks-dpdk-poc/start-vpp-native-mana.sh` | Start VPP with native MANA after failsafe PMDs removed |
| `aks-dpdk-poc/mana-vpp-patch.py` | Python script to patch VPP init.c for MANA whitelist |
| `aks-dpdk-poc/test-dpdk-mana.sh` | Quick DPDK testpmd verification on MANA |
| `aks-dpdk-poc/start-vpp-dpdk-mana.sh` | Start VPP with DPDK MANA (assumes binaries installed) |
| `aks-dpdk-poc/Dockerfile.vpp-mana` | Multi-stage Docker build (needs failsafe PMD removal step) |

## Next Steps
1. **Fix `rte_eth_dev_start()` -22 error** — testpmd works with 128 desc, VPP uses 1024. Investigate VPP queue setup vs MANA limits
2. **Fix SIGSEGV in `dpdk_counters_xstats_init()`** — patch xstats path or fix root cause (dev_start failure)
3. Set up VXLAN tunnel: branch-vm (10.120.4.4) → VPP pod
4. E2E traffic test: ping + iperf3 through VPP DPDK
5. Update Dockerfile with all fixes (cgroup, rdma-core v46, VPP patches, failsafe PMD removal)
6. Build Docker image to ACR

## Other Clusters (can be deleted to save cost)
- `sase-dpdk-aks` — old Mellanox cluster (Ubuntu 22.04, D4s_v5)
- `sase-mana-aks` — Ubuntu 22.04 + D4s_v6 (mana_ib broken)
- `sase-azlinux-aks` — AzureLinux + D4s_v6 (CONFIG_MANA_INFINIBAND disabled)
