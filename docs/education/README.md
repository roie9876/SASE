# SASE And SRv6 Education Guide

This page collects the background material that used to make the repository root README too heavy.

Use it when you want the conceptual foundation before reading the Azure and AKS implementation documents.

## What Is SASE?

SASE means Secure Access Service Edge.

At a high level, it combines WAN connectivity and cloud-delivered security into a single distributed service model.

Instead of forcing remote users and branches to backhaul everything to one central data center, SASE places routing and security functions closer to the user, branch, or workload.

## Core SASE Building Blocks

### Networking side

- SD-WAN
- branch connectivity
- path selection across multiple transports

### Security side

- ZTNA
- secure web gateway
- CASB
- firewall as a service

## Why This Matters In Azure

The central design challenge in this repository is that Azure is very good at being a cloud network underlay, but it does not expose the kind of low-level programmable routing behavior that a custom SASE dataplane wants.

That means the design often becomes:

1. Treat Azure as the transport underlay
2. Build the interesting routing and service-chaining logic in an overlay
3. Use VPP, DPDK, tunnels, and controller logic to regain control above the cloud fabric

## Underlay Versus Overlay

This is the most important mental model in the repository.

- The underlay is Azure's native network transport
- The overlay is the ISV-controlled routing and service layer built on top of it

In practice, that means advanced packet steering is often hidden inside ordinary IP or UDP traffic so Azure will carry it without needing to understand the inner logic.

## ELI5 Version

Think of Azure as a delivery company that only agrees to move plain sealed boxes.

If you want to carry rich instructions such as:

- first inspect in firewall
- then send through proxy
- then route toward destination

you place those instructions inside the box instead of expecting the delivery company to understand them.

That is the role of the overlay.

## What Is SRv6?

SRv6 means Segment Routing over IPv6.

The short version is:

- the desired path or behavior is encoded into the packet
- segments are represented as IPv6 addresses or functions
- the ingress point decides the logical path

This is attractive for service chaining and traffic engineering because it turns the packet into a programmable instruction carrier.

## Why SRv6 Is Attractive For SASE

SRv6 is useful in this repository because it helps with:

- service chaining
- multi-tenant steering
- traffic engineering
- avoiding heavy per-flow state in the core

It is especially attractive when you want packets to carry explicit instructions for the next processing stages.

## Why Native SRv6 Is Hard In Public Cloud

Public clouds often do not like unfamiliar extension-header behavior in their internal network fabric.

In Azure, native SRH pass-through is not something you can assume will work end to end.

That is why this repository repeatedly lands on the same practical conclusion:

- if the cloud fabric will not carry SRv6 natively,
- the realistic workaround is to encapsulate it inside something the cloud does carry safely, such as UDP-based overlay traffic.

## Why VPP And DPDK Show Up Here

This repository is not only about architecture diagrams. It also tries to validate whether a high-performance dataplane can be built inside AKS.

- VPP is the software packet-processing engine
- DPDK is the userspace packet I/O framework used for kernel-bypass paths
- MANA is Azure's NIC technology for the relevant VM family in the current POC

That practical side is documented under [aks-dpdk-poc/START-HERE.md](../../aks-dpdk-poc/START-HERE.md).

## Recommended Follow-Up Reading

If you finished this page, continue here:

1. [../architecture/checkpoint_aks_sase.md](../architecture/checkpoint_aks_sase.md)
2. [../architecture/azure_aks_cni_architecture.md](../architecture/azure_aks_cni_architecture.md)
3. [../architecture/azure_aks_nic_performance.md](../architecture/azure_aks_nic_performance.md)
4. [../../aks-dpdk-poc/START-HERE.md](../../aks-dpdk-poc/START-HERE.md)