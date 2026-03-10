# Deploying VPP/DPDK on Azure AKS from Scratch (Step-by-Step)

This guide documents the exact replication steps to spin up the DPDK proof-of-concept (PoC) on a standard Azure Kubernetes Service (AKS) cluster from zero, seamlessly bypassing default Azure AKS abstractions.

## Supported Node SKUs
To run DPDK natively leveraging an SR-IOV Data Plane on Azure, your AKS Node VMs must support **Accelerated Networking**. 
Recommended instance sizes:
- `Standard_D4s_v5` or `Standard_D8s_v5` (General purpose)
- `Standard_F4s_v2` or higher (Compute optimized for packet processing)

> **Note**: A minimum of 4 vCPUs per node is strongly recommended so the `rte_eal_init` scheduler can isolate core usage effectively for DPDK polling vs. Linux control plane.

---

## Step 1: Bootstrap the Application Infrastructure (AKS)

Deploy an AKS Cluster utilizing **Azure CNI Powered by Cilium** (to strip out default iptables-based routing latency) and create your application Node Pool.

```bash
# 1. Ensure you have a Virtual Network and Subnet created
RESOURCE_GROUP="sase-poc-rg"
CLUSTER_NAME="sase-dpdk-aks"
LOCATION="swedencentral"

az group create --name $RESOURCE_GROUP --location $LOCATION
az network vnet create -g $RESOURCE_GROUP -n SASE-VNet --address-prefix 10.0.0.0/16
az network vnet subnet create -g $RESOURCE_GROUP --vnet-name SASE-VNet -n default --address-prefixes 10.0.0.0/24

SUBNET_ID=$(az network vnet subnet show -g $RESOURCE_GROUP --vnet-name SASE-VNet --name default --query id -o tsv)

# 2. Create the Master Control Plane Cluster (Cilium Dataplane)
az aks create \
    --resource-group $RESOURCE_GROUP \
    --name $CLUSTER_NAME \
    --location $LOCATION \
    --network-plugin azure \
    --network-dataplane cilium \
    --vnet-subnet-id $SUBNET_ID \
    --generate-ssh-keys 

# 3. Add the Data Plane Worker Pool (Accelerated Networking is auto-enabled on D4s_v5)
az aks nodepool add \
    --resource-group $RESOURCE_GROUP \
    --cluster-name $CLUSTER_NAME \
    --name dpdkpool \
    --node-count 1 \
    --node-vm-size Standard_D4s_v5 

# 4. Fetch the Administrator Credentials
az aks get-credentials -g $RESOURCE_GROUP -n $CLUSTER_NAME --admin
```

---

## Step 2: Inject Hardware Realities into the Worker Node

Azure AKS restricts Hugepages per Kubelet specifications to zero. To fix this, run this manual host shell injection to synthesize 2GB of raw contiguous RAM.

```bash
# 1. Find your DPDK pool node name
NODE_NAME=$(kubectl get nodes -l agentpool=dpdkpool -o jsonpath='{.items[0].metadata.name}')

# 2. Inject Hugepages directly onto the Physical OS using an ephemeral Chroot Debugger
kubectl debug node/$NODE_NAME -it --image=ubuntu -- chroot /host bash -c 'echo 1024 > /sys/devices/system/node/node0/hugepages/hugepages-2048kB/nr_hugepages && cat /proc/meminfo | grep Huge'
```
*Expected Output: `HugePages_Total: 1024`*

---

## Step 3: Deploy the Cloud-Native NVA

Deploy the provided `vpp-dpdk-pod.yaml` manifest. This manifest explicitly attaches `/dev/infiniband` to interact directly with the Mellanox ConnectX-5 PCI Subsystem. 

```bash
# Edit vpp-dpdk-pod.yaml to match your $NODE_NAME in the nodeSelector before applying.
sed -i "s/kubernetes.io\/hostname:.*/kubernetes.io\/hostname: $NODE_NAME/" vpp-dpdk-pod.yaml

kubectl apply -f vpp-dpdk-pod.yaml
kubectl wait --for=condition=Ready pod/vpp-router --timeout=30s
```

---

## Step 4: Neutralize Kubernetes Container Overlords (`cgroups v2`)

Kubelet enforces max limits on containers preventing them from running `mmap()`. By running the instruction below from the live cluster, we rewrite the local Pod's cgroups bounds inside the memory hierarchy.

```bash
# Obtain the true cgroup boundary string mapping and set its maximum limit to 'max'
kubectl exec vpp-router -- bash -c "echo max > /sys/fs/cgroup\$(cat /proc/1/cgroup | cut -d: -f3)/hugetlb.2MB.max"
```

---

## Step 5: Install and Align DPDK Subsystems (Mellanox Override)

Instead of the Linux defaults (VFIO/UIO), Mellanox specifically relies on user-space OFED drivers (`rdma-core`/`ibverbs`).

```bash
kubectl exec vpp-router -- bash -c "
apt-get update && \
apt-get install -y curl gnupg2 lsb-release ibverbs-providers rdma-core && \
curl -s https://packagecloud.io/install/repositories/fdio/release/script.deb.sh | bash && \
apt-get install -y vpp vpp-plugin-core vpp-plugin-dpdk pciutils
"
```

---

## Step 6: Map the Bootloader and Run the Data Path

Configure the `startup.conf` specifying the exact DBDF mapping (Domain:Bus:Device.Function).
*Note: Run `lspci -nn` inside the pod or node to find your Mellanox interface's specific PCI mapping (usually `xxxx:00:02.0`). Let's assume it is `b1fd:00:02.0` in this example.*

```bash
kubectl exec vpp-router -- bash -c "mkdir -p /etc/vpp && cat << 'EOF' > /etc/vpp/startup.conf
unix {
  nodaemon
  log /var/log/vpp/vpp.log
  full-coredump
  cli-listen /run/vpp/cli.sock
}
api-trace { on }
api-segment { gid root }
dpdk {
  dev b1fd:00:02.0
  log-level debug
}
EOF"
```

Launch the pipeline bypassing the POSIX RLIMIT:
```bash
kubectl exec vpp-router -- bash -c "ulimit -l unlimited && vpp -c /etc/vpp/startup.conf > /var/log/vpp.out 2>&1 &"
```

Validate!
```bash
kubectl exec vpp-router -- vppctl show hardware-interfaces
```
*You will successfully see your underlying Azure Mellanox NIC bonded to the VPP Data Engine via the RDMA DPDK plugin, entirely bypassing the Linux Host's core network stack.*