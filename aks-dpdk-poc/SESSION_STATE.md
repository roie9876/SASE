# MANA DPDK on AKS — Session State & Context

## What We're Building
Cloud-native SASE platform on AKS using FD.io VPP with DPDK kernel bypass on MANA NIC.

## Current Infrastructure (sase-poc-lab-rg, swedencentral)

### Working Cluster: sase-ubuntu2404-aks
- **OS**: Ubuntu 24.04 (`--os-sku Ubuntu2404`)
- **Kernel**: `6.8.0-1046-azure` (native `mana_ib` built-in!)
- **VM Size**: `Standard_D4s_v6` (guaranteed MANA NIC)
- **Network**: Dual-stack IPv4/IPv6, Azure CNI overlay + Cilium
- **VNet**: `AKS-DualStack-VNet` (10.120.0.0/16 + fd00:db8:deca::/48)
- **Node**: `aks-nodepool1-38799324-vmss000000` (IP: 10.120.2.6)
- **Dual NIC**: eth0 (K8s mgmt, 10.120.2.x) + eth1 (DPDK, 10.120.3.x subnet via dpdk-nic)

### Branch VM: branch-vm-dpdk
- **IP**: 10.120.4.4 (private), 20.240.44.74 (public SSH)
- **VNet**: Same AKS-DualStack-VNet, branch-subnet (10.120.4.0/24)
- **SSH**: `ssh azureuser@20.240.44.74`

### Pod: vpp-mana
- **Image**: `ubuntu:22.04` (base), everything built from source inside
- **Config**: hostNetwork, hostPID, privileged, /host mount
- **Node**: `aks-nodepool1-38799324-vmss000000`

## What Was Built Inside the Pod

### 1. rdma-core v46
- Source: `/tmp/rdma-core` (git clone v46.0)
- Installed to: `/usr/lib/x86_64-linux-gnu/`
- Key file: `libmana-rdmav34.so` (MANA verbs provider)
- pkg-config: `libmana 1.0.46.0`

### 2. DPDK v24.11 (SHARED libraries)
- Source: `/tmp/dpdk-24`
- Installed to: `/usr/local/lib/x86_64-linux-gnu/`
- Key file: `librte_net_mana.so.25` (MANA PMD!)
- PMD autoload: `/usr/local/lib/x86_64-linux-gnu/dpdk/pmds-25.0/librte_net_mana.so`
- testpmd: `/usr/local/bin/dpdk-testpmd`

### 3. VPP v26.02 (with system DPDK)
- Source: `/tmp/vpp` (git clone v26.02)
- Built with: `VPP_USE_SYSTEM_DPDK=ON` (forced via sed in CMakeLists.txt)
- Binary: `/tmp/vpp/build-root/install-vpp-native/vpp/bin/vpp`
- Installed to: `/usr/local/bin/vpp`, `/usr/local/lib/`
- dpdk_plugin.so links against shared librte_*.so.25 (includes MANA)

## Key Findings

### DPDK testpmd on MANA — WORKS!
```
EAL: Probe PCI driver: net_mana (1414:00ba) device: 7870:00:00.0
MANA_DRIVER: mana_mr_btree_init(): B-tree initialized
Configuring Port 0 (socket 0)
Port 0: 60:45:BD:FD:D8:EB
port 0: RX queue number: 1 Tx queue number: 1
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
- VPP starts with `page-size 4K` buffers (avoids hugepage cgroup issue)
- VPP correctly skips eth0 (host interface is up)
- **Need to verify**: Does `vppctl show interface` show a MANA DPDK port?

### Known Issues
1. **Hugepages in K8s pods**: cgroup blocks hugetlb allocation. Workaround: `page-size 4K` for VPP, `--no-huge` for testpmd
2. **eth1 netvsc unbind**: After binding to uio_hv_generic, eth1 disappears. Requires VMSS restart to restore.
3. **uio_hv_generic on Ubuntu 24.04**: Module on host only, use `chroot /host modprobe uio_hv_generic`

## MANA Interface Details
- **PCI**: `7870:00:00.0` (vendor 1414, device 00ba)
- **eth1 MAC**: `60:45:bd:fd:d8:eb`
- **eth1 VF**: `enP30832s1d1`
- **Bus info**: `7870:00:00.0`
- **Device UUID**: `f8615163-0001-1000-2000-6045bdfdd8eb`
- **IB devices**: `mana_0`, `manae_0` (uverbs0, uverbs1)

## VPP startup.conf That Works (no crash)
```
unix {
  nodaemon
  log /tmp/vpp2.log
  cli-listen /run/vpp/cli.sock
}
buffers {
  buffers-per-numa 16384
  page-size 4K
}
dpdk {
  no-pci
  no-hugetlb
  vdev 7870:00:00.0,mac=60:45:bd:fd:d8:eb
  iova-mode va
}
plugins {
  plugin dpdk_plugin.so { enable }
  plugin default { disable }
  plugin ping_plugin.so { enable }
}
```

## Netvsc Binding Procedure (must be done before DPDK)
```bash
# Get details BEFORE unbinding
SECONDARY=$(ip -br link show master eth1 | awk '{ print $1 }')
MANA_MAC=$(ip -br link show master eth1 | awk '{ print $3 }')
BUS_INFO=$(ethtool -i $SECONDARY | grep bus-info | awk '{ print $2 }')
DEV_UUID=$(basename $(readlink /sys/class/net/eth1/device))

# Set DOWN
ip link set eth1 down
ip link set $SECONDARY down

# Bind to uio_hv_generic
chroot /host modprobe uio_hv_generic
NET_UUID="f8615163-df3e-46c5-913f-f2d2f965ed0e"
echo $NET_UUID > /sys/bus/vmbus/drivers/uio_hv_generic/new_id 2>/dev/null || true
echo $DEV_UUID > /sys/bus/vmbus/drivers/hv_netvsc/unbind
echo $DEV_UUID > /sys/bus/vmbus/drivers/uio_hv_generic/bind
```

## Next Steps
1. Verify `vppctl show interface` shows MANA DPDK port (not just local0)
2. If no DPDK port: debug VPP's vdev parameter parsing for MANA
3. Set up VXLAN tunnel: branch-vm (10.120.4.4) → VPP pod
4. E2E traffic test: ping + iperf3 through VPP DPDK
5. Build Docker image: `docker build --platform linux/amd64 -f aks-dpdk-poc/Dockerfile.vpp-mana -t vpp-mana-dpdk:v26.02 .`
6. Document results in aks-dpdk-poc/README.md

## Other Clusters (can be deleted to save cost)
- `sase-dpdk-aks` — old Mellanox cluster (Ubuntu 22.04, D4s_v5)
- `sase-mana-aks` — Ubuntu 22.04 + D4s_v6 (mana_ib broken)
- `sase-azlinux-aks` — AzureLinux + D4s_v6 (CONFIG_MANA_INFINIBAND disabled)
