# Experiment: D4s_v6 MANA + Native DPDK

## Summary

This scenario is the **kernel-bypass investigation track**.

Its purpose was to determine whether Azure AKS can support a native DPDK path using Microsoft's own MANA NIC.

The key result is:

- **Native DPDK on Azure MANA works**
- **VPP on top of Azure MANA DPDK is still not working reliably**

## Topology

### Platform

- AKS node type: `Standard_D4s_v6`
- OS: Ubuntu 24.04
- Kernel: `6.8.0-1046-azure`
- NIC family: Azure MANA
- Pod model: privileged pod with host mounts, hugepages access, and direct visibility into the MANA environment

### Device Layout

- management path: `eth0` and its paired MANA VF
- DPDK test path: `eth1` and its paired MANA VF
- PCI device: `7870:00:00.0`
- active tested MANA MAC: `7c:ed:8d:25:e4:4d`

### Driver Model

This is a **bifurcated** model:

- kernel MANA path remains present
- `rdma-core` / `libmana` provides the userspace verbs path
- DPDK uses `net_mana`
- the synthetic interface and paired VF must be brought down before testing

## What Was Tested

1. OS and kernel combinations for `mana_ib`
2. `rdma-core` compatibility
3. DPDK `net_mana` initialization and port probe
4. `dpdk-testpmd` on native MANA
5. VPP integration with system DPDK and MANA patches

## What Worked

### Proven Base Combination

- Ubuntu 24.04 on AKS
- kernel 6.8
- `Standard_D4s_v6`
- `rdma-core` v46
- DPDK v24.11

### Proven DPDK Results

- MANA PCI device detected correctly
- `mana_ib` path available on the working OS/kernel combination
- `dpdk-testpmd` probes the device successfully
- RX/TX queue creation succeeds in the DPDK test path
- DPDK runs natively against Azure MANA with `net_mana`

## What Did Not Work

### VPP Over Native MANA

Even after fixing multiple VPP-side issues, the full VPP dataplane is still not reliable:

- VPP can see `mana0`
- wrong PMD selection was fixed
- unknown driver classification was fixed
- xstats crash path was bypassed
- some runs progressed further than before

But the unresolved problem remains:

- `mana0` does not reliably reach a usable admin-up state
- hardware state still shows zero functional RX/TX queues in the failing path
- dummy burst handlers still appear
- no trustworthy end-to-end forwarding result has been proven through VPP on native MANA

## What We Learned

### Required Fixes for This Scenario

1. remove PMDs that hijack MANA before `net_mana` binds
2. build VPP against **system DPDK**
3. add MANA-specific classification to VPP
4. skip the normal UIO binding path for Azure MANA in VPP
5. bring down both the synthetic interface and its paired VF before starting DPDK
6. use the MANA-specific xstats bypass to avoid the earlier counter crash

### Important Interpretation

This scenario proves that Azure has a **real native DPDK path** on AKS through MANA.

It does **not** yet prove that VPP can use that path successfully for production-style forwarding.

## What This Scenario Proves

This scenario proves:

- Azure MANA is a viable native DPDK target on AKS
- the right AKS OS/kernel combination matters
- the underlying DPDK userspace path is real and repeatable

It does **not** prove:

- full VPP dataplane readiness on MANA
- stable queue bring-up in VPP
- end-to-end traffic forwarding through VPP on native MANA

## Current Status

Status: **partially successful**

Best way to describe it:

"The D4s_v6 MANA scenario successfully validated native DPDK on AKS, but VPP on top of that native MANA path is still not working reliably."