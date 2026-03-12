# Azure AKS Node Network Performance Tuning for SASE (DPDK & SR-IOV)

Deploying a Telco-grade DPDK/VPP workload in Azure Kubernetes Service (AKS) is fundamentally different from running standard web microservices. Achieving 10+ Gbps throughput per node with million-packet-per-second (PPS) routing requires precise selection of Azure VM limits, hardware adapters, and Kubernetes node configurations.

This document consolidates Azure's network hardware documentation into actionable requirements for a Check Point SASE architecture.

---

## 1. The "B-Series" Question: Can we use Azure B-Series VMs?

**Short Answer: Absolutely not. It will cause a catastrophic network collapse.**

While the newer **Bsv2-series** (Burstable v2) VMs *do* now officially support Accelerated Networking (SR-IOV / MANA) and advertise decent NIC throughput (e.g., 6.25 Gbps), they are still fundamentally incompatible with DPDK/VPP architectures due to how their CPUs process math:
1.  **CPU Credit Exhaustion vs DPDK Polling:** Regular Linux networking (`kube-proxy` / `iptables`) uses CPU dynamically—when a packet arrives, the CPU wakes up, processes it, and goes back to sleep. A B-Series VM accumulates "CPU Credits" while asleep. 
However, **DPDK operates in "Polling Mode."** It intentionally pins a CPU core at **100% utilization in an infinite loop**, constantly watching the RAM for new packets to achieve zero-latency forwarding.
2.  **The Catastrophic Failure:** Because the Master VPP DaemonSet will run the CPU at 100% permanently, a Bsv2 VM will burn through its entire bank of CPU credits within minutes of booting. Once the credits hit zero, Azure's hypervisor will aggressively throttle the physical CPU down to its baseline performance (e.g., 10% to 20% of a core). 
3.  **The Result:** The DPDK engine will instantly stall. Polling will slow to a crawl, and the VPP engine will begin blindly dropping millions of customer packets on the floor because the throttled CPU physically cannot read the memory buffer fast enough.

**Requirement:** You must use **Compute-Optimized (Fsv2, Fsv3)** or **General Purpose (Dsv4, Dsv5)** series VMs with a minimum of 8 vCPUs. These instances guarantee 100% sustained, unthrottled CPU clock cycles permanently, which is mandatory for DPDK polling loops.

---

## 2. The 1 NIC Bandwidth Myth (Scaling SR-IOV Performance)

A very common misconception when moving from heavily-cabled physical datacenters to Azure SDN is assuming that bandwidth is tied to the physical number of Virtual Machine NICs you provision. *("If my VPP Pod needs 25 Gbps, I must attach multiple 10 Gbps Ethernet interfaces to the K8s Worker Node.")*

**This is definitively false in Azure Cloud.**

In Azure, **Network Bandwidth is metered and enforced globally at the VM Size/SKU level**, completely regardless of how many individual Network Interfaces (vNICs or Virtual Functions) are mapped to it. 

### Why 1 NIC is all you need for 40+ Gbps:
1.  **The Physical Hardware Pipeline is Massive:** The actual physical SmartNIC (Mellanox ConnectX or Microsoft MANA) sitting in the Azure server rack that hosts your VM is a huge **100 Gbps or 200 Gbps** physical card. 
2.  **SR-IOV Slicing Shares the Pipeline:** As documented in the CNI architecture, SR-IOV slices that single 100G card into Virtual Functions (`eth1`, `eth2`) for the Pod. All slices share the parent card's massive bandwidth pool.
3.  **The Azure SDN Quality of Service (QoS) Throttle:** The hypervisor looks directly at the VM SKU you paid for and applies a hard QoS software limit across *all* SR-IOV slices cumulatively. 

### SASE Production Scaling Table:
When you need to handle more customer IPsec tunnels or process more raw Gbps throughput, **you do not add more NICs to the AKS worker node**. Instead, you vertically or horizontally scale the VM CPU tier. Upgrading the CPU count automatically unlocks higher bandwidth allowances from the underlying 100Gbps SmartNIC:

| Azure VM Size (Example) | vCPU Core Count | SR-IOV Supported? | Maximum Permitted Bandwidth (QoS Limit) | Role |
| :--- | :--- | :--- | :--- | :--- |
| `Standard_D4s_v5` | 4 vCPUs | ✅ Yes | **12.5 Gbps** | Educational POC / Lab |
| `Standard_D16s_v5` | 16 vCPUs | ✅ Yes | **12.5 Gbps** | Small Regional Hub |
| `Standard_D32s_v5` | 32 vCPUs | ✅ Yes | **16.0 Gbps** | Medium Regional Hub |
| `Standard_F32s_v2` | 32 vCPUs | ✅ Yes | **16.0 Gbps** | Production Check Point SASE Hub |
| `Standard_F72s_v2` | 72 vCPUs | ✅ Yes | **30.0 Gbps** | Dense Enterprise Gateway Hub |

> **Note**: PPS (Packets Per Second) values are not published by Microsoft per VM SKU. The bandwidth values above are "Expected Network Bandwidth" from [Azure VM size documentation](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/). Actual PPS depends on packet size, CPU utilization, and whether DPDK kernel bypass is used.

*Therefore, the SR-IOV Multus design remains identical whether you are pushing 100 Mbps or 30 Gbps. The only variable that changes is the underlying AKS Node SKU bandwidth limit.*

---

## 3. Maximizing the Physical NIC: Accelerated Networking & MANA

In Azure, to get the absolute maximum performance from a NIC, you must bypass the virtualized Hyper-V switch using **Accelerated Networking**.

### The Microsoft Azure Network Adapter (MANA) Transition
Historically, Azure used Mellanox (ConnectX) smart NICs for Accelerated Networking. Azure is currently transitioning to their own custom silicon called **MANA (Microsoft Azure Network Adapter)**. 
*   **Why it matters for DPDK:** DPDK relies on specific **Poll Mode Drivers (PMD)** to speak directly to the physical NIC hardware. If the Check Point VPP engine only includes Mellanox drivers, it will fail to bind to newer Azure hardware.
*   **The Fix:** Check Point's VPP container image must explicitly include the **`mana_en` DPDK PMD** to support forward compatibility on new AKS node pools, alongside legacy Mellanox `mlx5_core` drivers.

### AKS Context: Enabling Multi-NIC & SR-IOV
In a standard Azure VM, you define Accelerated Networking on the portal. In **AKS**, you must define this at the Node Pool generation level:
*   The AKS Node Pool must be deployed using an instance type that supports at least **3 NICs** (for our `eth0`, `eth1`, and `eth2` architecture).
*   Accelerated Networking is enabled by default on supported AKS SKUs (like `Standard_F16s_v2`), but to attach those VFs to Pods, the cluster requires a device plugin (like the **SR-IOV Network Device Plugin for Kubernetes**) to allocate the hardware VFs to the Multus CNI.

---

## 3. Host-Level TCP/IP & DPDK Tuning in AKS

Because AKS provisions managed worker nodes, you cannot simply SSH into a VM and run `sysctl` commands manually. To achieve maximum throughput, the AKS Node Pools must be customized using **Custom Node Configuration (kubelet and OS config)** or DaemonSets.

### A. Hugepages (RAM Pre-allocation for DPDK)
DPDK requires massive, contiguous blocks of RAM (Hugepages) so it doesn't waste time translating tiny 4KB memory chunks. 
*   **AKS Implementation:** You must use AKS Custom Node Configuration to inject `vm.nr_hugepages` (e.g., allocating 16GB of 1GB hugepages) directly into the Node OS upon booting. Kubernetes `kubelet` then needs to be configured to recognize these hugepages so the SASE Pod can request them in its YAML manifest (`resources.limits."hugepages-1Gi"`).

### B. CPU Pinning & NUMA Alignment
To hit millions of PPS, the VPP worker threads must never be interrupted by standard Linux processes, and they must read from RAM physically closest to the NIC (NUMA Node 0).
*   **AKS Implementation:** You must set the Kubelet CPU Manager Policy to `static`. When the Check Point Pod requests an exact integer of CPUs (e.g., exactly `limits: cpu: 8`), the AKS Kubelet will lock those 8 physical cores exclusively to the VPP engine and banish all other K8s background noise (kube-proxy, standard logging) to the remaining cores.

### C. Azure VM Bandwidth Limits (Capping)
**Crucial Architecture Warning:** In Azure, the physical NIC speed (e.g., 40Gbps) does **not** equal the VM's allowed throughput. Azure places artificial caps on throughput based on the VM SKU size.
*   If you use an 8-core `Standard_D8s_v5`, Azure strictly throttles outbound traffic to **12.5 Gbps**, even if the underlying physical MANA NIC can do 100Gbps and DPDK is running perfectly.
*   To achieve **50 Gbps** per AKS node for a heavy SASE hub, you must select an egregiously large VM SKU (e.g., `Standard_D32s_v5` or `Standard_F32s_v2`), specifically to buy the "Network Bandwidth Quota" from Microsoft, not necessarily because VPP needs 32 cores.

### D. MTU Optimization (Jumbo Frames)
Azure natively supports an MTU of up to **~4000 bytes** internally for VMs in the same VNet/vWAN. 
*   Because Check Point wraps Customer IPv4 packets inside an IPv6 SRv6 header, and then wraps *that* inside a UDP IPv4 packet, the total header overhead balloons.
*   **AKS Implementation:** The `eth1` physical SR-IOV VF and the `eth1` interface inside the Pod must be hardcoded to an MTU of at least `3900` to ensure that standard 1500-byte customer packets can be fully encapsulated (encap overhead ~100 bytes) without forcing DPDK to perform expensive packet fragmentation before hitting the Azure physical network.
