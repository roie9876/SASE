#!/bin/bash
# Deploy AKS with Ubuntu 24.04 (kernel 6.8+) for native MANA DPDK support
set -e

SUBNET_ID="/subscriptions/ed2fda1d-8138-4434-866b-d183eaaae104/resourceGroups/sase-poc-lab-rg/providers/Microsoft.Network/virtualNetworks/AKS-DualStack-VNet/subnets/dpdk-subnet"

echo "Creating AKS with Ubuntu 24.04 + D4s_v6..."
az aks create \
  --resource-group sase-poc-lab-rg \
  --name sase-ubuntu2404-aks \
  --location swedencentral \
  --node-count 1 \
  --node-vm-size Standard_D4s_v6 \
  --os-sku Ubuntu2404 \
  --network-plugin azure \
  --network-plugin-mode overlay \
  --network-dataplane cilium \
  --ip-families IPv4,IPv6 \
  --pod-cidrs 10.246.0.0/16,fd57:fd45:5a09:3491::/64 \
  --service-cidrs 10.2.0.0/16,fd57:a8f7:45f6:6149::/108 \
  --dns-service-ip 10.2.0.10 \
  --vnet-subnet-id $SUBNET_ID \
  --generate-ssh-keys \
  --no-wait

echo "AKS Ubuntu 24.04 creation started!"
