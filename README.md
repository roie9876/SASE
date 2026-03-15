# Cloud-Native SASE / SD-WAN In Azure

## POC Results (Start Here)

**[pocs/phase1-node-local-vpp/README.md](./pocs/phase1-node-local-vpp/README.md)** — Complete E-W performance results, scenario index, and findings.

| Scenario | Result |
|----------|--------|
| [05 - VPP VXLAN E-W (MANA)](./pocs/phase1-node-local-vpp/05-vpp-owned-eth1/POC-GUIDE.md) | 1 Gbps UDP, 4.7ms ping, 4 bugs fixed |
| [06 - Cilium Baseline + Plugin Tests](./pocs/phase1-node-local-vpp/06-baseline-cilium-ebpf/README.md) | 9-12 Gbps TCP (Cilium), af_packet/rdma/xdp tested |
| [01 - Same-node VPP + Branch VXLAN](./pocs/phase1-node-local-vpp/01-vxlan-srv6-afpacket/README.md) | 2.16 Gbps TCP same-node |

## Background

- [docs/requirements/README.md](./docs/requirements/README.md) - customer requirements
- [docs/current/README.md](./docs/current/README.md) - active documentation index
- [docs/current/phase1-node-vpp-poc.md](./docs/current/phase1-node-vpp-poc.md) - why VPP was chosen
- [docs/education/README.md](./docs/education/README.md) - overlay/SRv6/cloud concepts

## Repository Map

- [pocs/phase1-node-local-vpp/](./pocs/phase1-node-local-vpp/) - **active POC scenarios and results**
- [docs/](./docs/) - documentation
- [manifests/](./manifests/) - shared Kubernetes manifests
- [tools/](./tools/) - helper scripts
- [archive/](./archive/) - older experiments (legacy-pocs/aks-dpdk-poc)
