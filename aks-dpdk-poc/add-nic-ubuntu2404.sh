#!/bin/bash
set -e

RG="MC_sase-poc-lab-rg_sase-ubuntu2404-aks_swedencentral"
VMSS="aks-nodepool1-38799324-vmss"
DPDK_SUBNET_ID="/subscriptions/ed2fda1d-8138-4434-866b-d183eaaae104/resourceGroups/sase-poc-lab-rg/providers/Microsoft.Network/virtualNetworks/AKS-DualStack-VNet/subnets/azlinux-sub"

echo "1. Deallocating..."
az vmss deallocate -g $RG -n $VMSS --instance-ids 0
echo "2. Adding second NIC..."
az vmss update -g $RG -n $VMSS \
  --set 'virtualMachineProfile.networkProfile.networkInterfaceConfigurations[0].primary=true' \
  --add virtualMachineProfile.networkProfile.networkInterfaceConfigurations '{
    "name": "dpdk-nic",
    "primary": false,
    "enableAcceleratedNetworking": true,
    "ipConfigurations": [{"name": "dpdk-ipconfig","subnet": {"id": "'"$DPDK_SUBNET_ID"'"}}]
  }' -o none
echo "3. Updating instance..."
az vmss update-instances -g $RG -n $VMSS --instance-ids 0
echo "4. Starting..."
az vmss start -g $RG -n $VMSS --instance-ids 0
echo "DONE - node boots with 2 MANA NICs"
