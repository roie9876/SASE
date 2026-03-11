#!/bin/bash
SUBNET_ID="/subscriptions/ed2fda1d-8138-4434-866b-d183eaaae104/resourceGroups/sase-poc-lab-rg/providers/Microsoft.Network/virtualNetworks/AKS-DualStack-VNet/subnets/azlinux-sub"

az aks create \
  --resource-group sase-poc-lab-rg \
  --name sase-azlinux-aks \
  --location swedencentral \
  --node-count 1 \
  --node-vm-size Standard_D4s_v6 \
  --os-sku AzureLinux \
  --network-plugin azure \
  --network-plugin-mode overlay \
  --network-dataplane cilium \
  --ip-families IPv4,IPv6 \
  --pod-cidrs 10.245.0.0/16,fd56:fd45:5a09:3491::/64 \
  --service-cidrs 10.1.0.0/16,fd56:a8f7:45f6:6149::/108 \
  --dns-service-ip 10.1.0.10 \
  --vnet-subnet-id $SUBNET_ID \
  --generate-ssh-keys \
  --no-wait

echo "AKS AzureLinux creation started!"
