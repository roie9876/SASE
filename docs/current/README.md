# Current Working Direction

This folder contains the active documentation set for the current Azure SASE investigation.

Use this area when you want the latest agreed direction, not the earlier exploratory material.

## Start Here

- [../requirements/README.md](../requirements/README.md) - customer requirement capture and open questions
- [phase1-node-vpp-poc.md](./phase1-node-vpp-poc.md) - current Phase 1 POC direction, tradeoffs, and implementation path
- [../../pocs/phase1-node-local-vpp/README.md](../../pocs/phase1-node-local-vpp/README.md) - live validated Phase 1 POC baseline and scenario index
- [../../pocs/phase1-node-local-vpp/01-vxlan-srv6-afpacket/README.md](../../pocs/phase1-node-local-vpp/01-vxlan-srv6-afpacket/README.md) - detailed findings, MTU analysis, and performance results

## Scope Of The Current Direction

The active POC direction is intentionally narrow:

- keep Azure Kubernetes Service as the managed Kubernetes platform
- defer the Edge role from Phase 1
- focus on one node acting as a SASE worker
- treat VPP as the node-local forwarding engine
- prove service chaining to and between SASE pods before solving full platform orchestration

## Not In Scope For This Phase

- full ingress and Edge design
- dynamic policy engine integration
- production-grade failure handling
- full global PoP routing behavior
- final east-west design across all regions