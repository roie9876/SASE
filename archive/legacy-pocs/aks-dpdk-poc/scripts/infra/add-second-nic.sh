#!/bin/bash
# Add a second NIC with AccelNet to the AzureLinux AKS VMSS
set -e

RG="MC_sase-poc-lab-rg_sase-azlinux-aks_swedencentral"
VMSS="aks-nodepool1-14290527-vmss"
DPDK_SUBNET_ID="/subscriptions/ed2fda1d-8138-4434-866b-d183eaaae104/resourceGroups/sase-poc-lab-rg/providers/Microsoft.Network/virtualNetworks/AKS-DualStack-VNet/subnets/dpdk-subnet"

echo "1. Deallocating VMSS instance 0..."
az vmss deallocate -g $RG -n $VMSS --instance-ids 0
echo "   Done"

echo "2. Adding second NIC with AccelNet..."
az vmss update -g $RG -n $VMSS \
  --set 'virtualMachineProfile.networkProfile.networkInterfaceConfigurations[0].primary=true' \
  --add virtualMachineProfile.networkProfile.networkInterfaceConfigurations '{
    "name": "dpdk-nic",
    "primary": false,
    "enableAcceleratedNetworking": true,
    "ipConfigurations": [
      {
        "name": "dpdk-ipconfig",
        "subnet": {
          "id": "'"$DPDK_SUBNET_ID"'"
        }
      }
    ]
  }' -o none
echo "   Done"

echo "3. Updating instance 0..."
az vmss update-instances -g $RG -n $VMSS --instance-ids 0
echo "   Done"

echo "4. Starting instance 0..."
az vmss start -g $RG -n $VMSS --instance-ids 0
echo "   Done"

echo "Node will boot with 2 NICs (eth0=mgmt, eth1=DPDK)"
