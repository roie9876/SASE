# Script Layout

This directory groups the operational scripts by purpose so the current MANA workflow is easy to find.

## Recommended Starting Points

If you want the current MANA path, use these first:

- `mana/build/build-all-mana.sh` - build rdma-core, DPDK, and VPP for the current Ubuntu 24.04 plus MANA path
- `mana/workflows/full-setup-vpp-mana.sh` - restore or rebuild the saved MANA artifact set in a fresh pod
- `mana/run/start-vpp-clean.sh` - clean native MANA DPDK start for VPP
- `mana/run/start-vpp-afpacket.sh` - Linux `af-packet` fallback path for functional testing
- `mana/test/test-dpdk-mana.sh` - quick `dpdk-testpmd` verification on MANA

## Directory Map

### `infra/`

AKS and Azure infrastructure/bootstrap scripts.

- cluster creation
- extra NIC setup
- infrastructure deployment helpers

### `mana/build/`

Current build scripts for the Azure MANA investigation.

### `mana/workflows/`

Multi-step scripts that rebuild, restore, or bring up the end-to-end MANA environment.

### `mana/run/`

Current start scripts for VPP on either:

- Linux `af-packet`
- native DPDK on MANA

### `mana/debug/`

Focused troubleshooting helpers for startup failures, PMD hijack issues, and driver bring-up.

### `mana/test/`

Targeted validation commands such as hugepage checks and `dpdk-testpmd` verification.

### `mana/patches/`

Reference patch files and extracted VPP patch content used during the MANA investigation.

## Historical Material

Older one-off scripts that were useful during discovery but are not the main supported path now were moved to:

- `../archive/mana/`

Keep them for reference, but do not treat them as the clean starting point for a new engineer.