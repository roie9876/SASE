# Cloud-Native SASE / SD-WAN In Azure

This repository is split into a small active reading path and clearly separated legacy material.

The goal is to keep the current Azure SASE investigation easy to navigate while preserving earlier experiments and architecture notes for later reference.

## Current Reading Path

Start here if you want the current direction:

1. [docs/requirements/README.md](./docs/requirements/README.md) - customer requirements captured so far
2. [docs/current/README.md](./docs/current/README.md) - active documentation index
3. [docs/current/phase1-node-vpp-poc.md](./docs/current/phase1-node-vpp-poc.md) - current POC direction and why this path was chosen
4. [docs/education/README.md](./docs/education/README.md) - background concepts for overlays, SRv6, and cloud constraints

## Current POC Focus

The active POC is intentionally narrow.

It focuses on:

- AKS as the managed Kubernetes platform
- one node behaving as a SASE worker
- VPP as the node-local forwarding entity
- DPDK plus MANA on the dataplane side
- a few fake SASE service pods with separate management and dataplane paths
- static forwarding and static same-node service chaining first

The Edge role is intentionally out of scope for this first phase.

## Repository Map

- [docs/README.md](./docs/README.md) - documentation index
- [docs/current/README.md](./docs/current/README.md) - active direction
- [docs/requirements/README.md](./docs/requirements/README.md) - requirement capture
- [docs/legacy/README.md](./docs/legacy/README.md) - historical architecture references
- [archive/README.md](./archive/README.md) - archived older POC material
- [manifests/README.md](./manifests/README.md) - repository-scope manifests
- [tools/README.md](./tools/README.md) - helper tools

## Where The Older Work Went

To reduce confusion, earlier exploratory material has been moved out of the main path:

- old architecture documents are now under [docs/legacy/architecture](./docs/legacy/architecture)
- the previous AKS dataplane POC bundle is now under [archive/legacy-pocs/aks-dpdk-poc](./archive/legacy-pocs/aks-dpdk-poc)

Those materials are still relevant as implementation history and research background, but they are no longer the current plan of record.
