# Deploying Data Plane DPDK on Azure AKS (Mellanox Override)

When running the Check Point SASE data plane (VPP/DPDK) on standard Azure Kubernetes Service (AKS), DPDK will often crash during the Environment Abstraction Layer (EAL) initialization with errors like `rte_eal_init returned -1`. 

This happens because standard AKS node pools do not provision hugepages or allow direct DPDK mapping by default, enforcing strict memory boundaries limiting the DPDK application from initializing successfully.

To bypass these restrictions on live standard Azure VMs without re-provisioning specialized node pools or writing complex custom bootstrapping operators, we must manipulate the underlying host interfaces.

### 1. Hugepages Allocation (Host Memory Injection)
Standard AKS distributions dynamically configure `hugepages-2048kB` to `0` at runtime. We must inject memory blocks directly into the VM's bare-metal SYSFS boundary.

Run a privileged daemonset (or node debugger) mapped to the host's `/sys`:
```bash
echo 1024 > /sys/devices/system/node/node0/hugepages/hugepages-2048kB/nr_hugepages
```
This forces the allocation of 2GB (`1024 * 2MB`) of continuous RAM.
Verify the hardware accepted the reservation:
```bash
cat /proc/meminfo | grep Huge
```

### 2. Overriding the Cgroups V2 Container Governor
Kubernetes restricts physical memory mappings for containers via `cgroups v2`. Even if hugepages exist on the VM, Kubernetes will forcefully trigger an `mmap` allocation denial (`pmalloc_map_pages: failed to mmap... Cannot allocate memory`) because the Kubelet limit was configured to 0.

To bypass this without rebuilding the Kubelet capacity mapper:
```bash
echo max > /sys/fs/cgroup/kubepods.slice/kubepods-besteffort.slice/.../hugetlb.2MB.max
```
Inside the pod, run DPDK tools ensuring you remove the `RLIMIT_MEMLOCK` limit:
```bash
ulimit -l unlimited
```

### 3. Mellanox Native Driver & IBVerbs (The Azure SR-IOV Engine)
Standard DPDK manuals typically instruct binding standard networking devices to `uio_pci_generic` or `vfio-pci`. However, **Azure's Accelerated Networking relies strictly on Mellanox ConnectX cards.**

**Mellanox PMDs (Poll Mode Drivers) DO NOT use UIO or VFIO bindings.** 
Instead of unbinding the interface to give K8s exclusive device control, Mellanox uses the native Linux `mlx5_core` kernel driver alongside the user-space **RDMA Core / IBVerbs**.

To allow VPP's DPDK Engine to consume the Azure Accelerated Networking NIC:
1. **Never** unbind the PCI device from `mlx5_core`.
2. Do not attempt to mount `/dev/uio0`. Instead, mount the `/dev/infiniband` character device tree into the K8s pod as a type `Directory` to allow the user-space daemon to perform RDMA bypassing.
3. Install the Infiniband networking user-space libraries alongside your DPDK binaries inside the container:
```bash
apt-get install -y ibverbs-providers rdma-core
```
4. Within the `startup.conf` for VPP/DPDK, you do not need to specify `uio-driver`, just specify the exact PCI device ID directly.

By bridging the continuous physical RAM arrays, unlocking the Kubernetes Cgroups limitations natively, and accurately mapping the infiniband Mellanox subsystem, VPP will successfully boot a bare-metal DPDK engine natively across the Azure SR-IOV data path inside standard container distributions.