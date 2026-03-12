# Manifest Layout

This directory groups Kubernetes manifests by scenario so the active MANA work is separated from the older Mellanox and SR-IOV path.

## `mana/`

Manifests related to the Azure MANA investigation.

- `vpp-mana-pod.yaml` - privileged pod used for the MANA DPDK and VPP investigation
- `test-pci.yaml` - helper manifest for PCI visibility and low-level validation

## `mellanox/`

Manifests related to the older Mellanox and SR-IOV-oriented experiments.

- `vpp-pod.yaml`
- `vpp-dpdk-pod.yaml`
- `sriovdp-config.yaml`
- `mactvlan.yaml`

These are kept because they are part of the history of the POC, but they are not the primary path for the current Azure MANA work.