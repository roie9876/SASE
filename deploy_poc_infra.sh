#!/bin/bash

# ==============================================================================
# SASE / Telco Kubernetes POC - Infrastructure Deployment Script
# This script uses Azure CLI (az) to deploy the underlay networking, overlapping 
# branches, and the DPDK-capable AKS cluster for the educational lab.
# ==============================================================================

# Variables
RG_NAME="sase-poc-lab-rg"
LOCATION="eastus" # Use a region that supports Standard_D4s_v5
VWAN_NAME="sase-vwan"
VHUB_NAME="sase-vhub"
AKS_CLUSTER_NAME="sase-dpdk-aks"

# Define overlapping subnets for Branches, and distinct subnet for AKS
BRANCH1_VNET="Branch1-VNet"
BRANCH1_CIDR="192.168.1.0/24" # Overlap

BRANCH2_VNET="Branch2-VNet"
BRANCH2_CIDR="192.168.1.0/24" # Overlap

AKS_VNET="AKS-Hub-VNet"
AKS_CIDR="10.100.0.0/16"
AKS_SUBNET="10.100.1.0/24"

# ==============================================================================
echo "1. Group & Virtual Networks..."
# ==============================================================================
az group create --name $RG_NAME --location $LOCATION

az network vnet create --resource-group $RG_NAME --name $BRANCH1_VNET --address-prefix $BRANCH1_CIDR --subnet-name default --subnet-prefix $BRANCH1_CIDR
az network vnet create --resource-group $RG_NAME --name $BRANCH2_VNET --address-prefix $BRANCH2_CIDR --subnet-name default --subnet-prefix $BRANCH2_CIDR
az network vnet create --resource-group $RG_NAME --name $AKS_VNET --address-prefix $AKS_CIDR --subnet-name default --subnet-prefix $AKS_SUBNET

# ==============================================================================
echo "2. Deploying Branch VMs (Standard_B1s)..."
# ==============================================================================
# Generate SSH keys if they don't exist
# Branch 1
az vm create --resource-group $RG_NAME --name "Branch1-VM" \
  --vnet-name $BRANCH1_VNET --subnet default \
  --image Ubuntu2204 --size Standard_B1s \
  --admin-username adminuser --generate-ssh-keys --no-wait

# Branch 2
az vm create --resource-group $RG_NAME --name "Branch2-VM" \
  --vnet-name $BRANCH2_VNET --subnet default \
  --image Ubuntu2204 --size Standard_B1s \
  --admin-username adminuser --no-wait

# ==============================================================================
echo "3. Deploying Azure Virtual WAN (vWAN)..."
# Warning: vWAN Hub creation can take ~30 minutes in Azure!
# ==============================================================================
az network vwan create --resource-group $RG_NAME --name $VWAN_NAME --location $LOCATION --type Standard
az network vhub create --resource-group $RG_NAME --name $VHUB_NAME --vwan $VWAN_NAME --address-prefix 10.200.0.0/24 --location $LOCATION

# Connect VNets to vWAN Hub
az network vhub connection create --resource-group $RG_NAME --hub-name $VHUB_NAME --name "conn-branch1" --remote-vnet $BRANCH1_VNET
az network vhub connection create --resource-group $RG_NAME --hub-name $VHUB_NAME --name "conn-branch2" --remote-vnet $BRANCH2_VNET
az network vhub connection create --resource-group $RG_NAME --hub-name $VHUB_NAME --name "conn-aks" --remote-vnet $AKS_VNET

# ==============================================================================
echo "4. Deploying AKS Cluster (Azure CNI Powered by Cilium)..."
# Using Standard_D4s_v5 to ensure Accelerated Networking (SR-IOV) DPDK support.
# ==============================================================================
# Get Subnet ID for AKS
AKS_SUBNET_ID=$(az network vnet subnet show -g $RG_NAME --vnet-name $AKS_VNET --name default --query id -o tsv)

az aks create \
    --resource-group $RG_NAME \
    --name $AKS_CLUSTER_NAME \
    --location $LOCATION \
    --node-count 1 \
    --node-vm-size Standard_D4s_v5 \
    --network-plugin azure \
    --network-dataplane cilium \
    --vnet-subnet-id $AKS_SUBNET_ID \
    --generate-ssh-keys

echo "Deployment Phase 1 Complete!"
echo "Next step: Run 'az aks get-credentials --resource-group $RG_NAME --name $AKS_CLUSTER_NAME' to log into your new DPDK-capable cluster!"
