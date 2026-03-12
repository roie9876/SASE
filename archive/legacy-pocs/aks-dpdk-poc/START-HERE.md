# Start Here

This page is the shortest path to understanding the POC.

It is intended for a new engineer opening this folder for the first time.

## What This POC Is

This repository contains multiple related AKS networking experiments.

The two most important tracks are:

1. A working functional VPP topology using Linux `af-packet`
2. A native Azure MANA plus DPDK investigation, where `dpdk-testpmd` works but full VPP dataplane forwarding is still not proven

## What Is Working Today

- Functional VPP data path using `af-packet`
- Native DPDK on Azure MANA with `dpdk-testpmd`

## What Is Not Fully Working Today

- Reliable end-to-end forwarding through VPP on top of native MANA DPDK

## Read In This Order

1. [poc-concepts-primer.md](./poc-concepts-primer.md)
2. [experiments/README.md](./experiments/README.md)
3. [experiments/d4sv5-mellanox-afpacket.md](./experiments/d4sv5-mellanox-afpacket.md)
4. [experiments/d4sv6-mana-dpdk.md](./experiments/d4sv6-mana-dpdk.md)
5. [internal/notes/MANA-ENGINEERING-NOTES.md](./internal/notes/MANA-ENGINEERING-NOTES.md) if you need the detailed debug history

## Folder Map

- [scripts/README.md](./scripts/README.md): current operational scripts
- [manifests/README.md](./manifests/README.md): manifests split by scenario
- [archive/mana/README.md](./archive/mana/README.md): historical scripts kept only for reference

## If You Want The Current MANA Path

Start with these files:

1. [scripts/mana/build/build-all-mana.sh](./scripts/mana/build/build-all-mana.sh)
2. [scripts/mana/workflows/full-setup-vpp-mana.sh](./scripts/mana/workflows/full-setup-vpp-mana.sh)
3. [scripts/mana/run/start-vpp-clean.sh](./scripts/mana/run/start-vpp-clean.sh)
4. [scripts/mana/test/test-dpdk-mana.sh](./scripts/mana/test/test-dpdk-mana.sh)

## If You Want The Functional Fallback Path

Start with:

1. [scripts/mana/run/start-vpp-afpacket.sh](./scripts/mana/run/start-vpp-afpacket.sh)
2. [OPERATIONS_GUIDE.md](./OPERATIONS_GUIDE.md)

## Important Distinction

- `af-packet` path: easier to understand, works functionally, not kernel bypass
- native DPDK path: correct direction for performance, partially proven, still under investigation for VPP

## What To Ignore At First

Do not start from the older one-off scripts in `archive/mana/`.

Those files are preserved because they contain useful investigation history, but they are not the clean supported path.