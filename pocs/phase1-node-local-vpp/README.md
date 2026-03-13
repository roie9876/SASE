# Phase 1 Node-Local VPP POC

This folder is the working area for the new Phase 1 proof of concept.

It is separated from older material so multiple POC scenarios can live side by side without mixing assumptions, manifests, or scripts.

## Goal

Prove that one AKS worker node can behave like a SASE worker with:

- VPP as the node-local forwarding engine
- a management path separated from a dataplane path
- branch traffic entering as VXLAN with inner SRv6 payload
- static same-node service delivery first
- native MANA plus DPDK treated as a gated optimization track, not the only bring-up path

## Current Phase 1 Status

Scenario `01-vxlan-srv6-afpacket` is now the live validated baseline for Phase 1.

What is proven so far:

- the branch tunnel can land on the AKS forwarding NIC `eth1` instead of the node management IP
- VPP can decapsulate VXLAN, process the SRv6 context, and deliver traffic to a same-node service pod
- the path is stable enough for real `ping` and `iperf3` validation
- the current tuned result is about `2.16 Gbit/s` TCP and about `1.48 Gbit/s` UDP at `1.5 Gbit/s` offered load

What has now been added for the next test stage:

- the AKS node pool was scaled from one worker to two workers
- the VMSS model was verified to carry the forwarding NIC on new nodes as well
- a second VPP pod and a second service pod were deployed on Node 2
- a dedicated Node 2 dataplane subnet was introduced to avoid `host-local` IPAM overlap with Node 1

Current Phase 1B status:

- east-west worker-to-worker dataplane testing is now an active test item
- Node 2 local service-to-VPP dataplane reachability was recovered after fixing the `host-dp0` path on the second VPP instance
- inter-node underlay reachability over forwarding NICs `10.120.3.4 <-> 10.120.3.5` is working
- inter-node service-pod forwarding through the second VPP instance is not yet stable enough to claim a valid throughput result

What was learned so far:

- the forwarding underlay can be larger than the active service datapath
- on this AKS node, the Linux VXLAN interface still tops out at `1450`
- with SRv6 encapsulation on the branch route, the practical route MTU becomes `1386`
- PMTU alignment and offload control are required for stable TCP
- scaling out the worker pool is straightforward, but cross-node throughput depends on stabilizing the second VPP instance's inter-node forwarding path before load tests are meaningful

Read [01-vxlan-srv6-afpacket/README.md](./01-vxlan-srv6-afpacket/README.md) for the full runbook, debugging findings, MTU analysis, and performance results.

## Why This Folder Exists

The repository already contains useful implementation history under `archive/legacy-pocs/aks-dpdk-poc`, but the active Phase 1 work needs its own clean location.

This folder is intended to hold:

- current docs
- current manifests
- current scripts
- scenario-specific configs
- test notes and checkpoints

## Scenario Split

### `01-vxlan-srv6-afpacket/`

First functional scenario.

Use the already-proven Azure-safe outer transport:

- branch VM sends VXLAN over IPv4 or UDP
- inner payload carries SRv6 data
- VPP decapsulates and forwards locally
- same-node service reachability is validated before kernel-bypass optimization

This is the fastest path to prove the forwarding model.

### `02-service-pod-dual-nic/`

Service pod attachment scenario.

Purpose:

- keep `eth0` for normal AKS management
- add a second interface for dataplane traffic using Multus
- validate the pod model needed for fake SASE functions

### `03-mana-dpdk-validation/`

Native MANA plus DPDK validation scenario.

Purpose:

- prove the second NIC and MANA environment are usable
- prove `dpdk-testpmd`
- only promote this path into the main POC after VPP forwarding is actually stable

### `04-east-west-throughput/`

Cross-node east-west throughput scenario.

Purpose:

- add a second worker node
- run one VPP instance on each worker
- place equal numbers of fake SASE pods on both workers
- measure aggregate throughput from Node 1 service pods to Node 2 service pods through the VPP dataplane

Current state:

- partially prepared in the live lab
- blocked on stabilizing inter-node forwarding through the second VPP instance

## Deployment Direction

The deployment model for this POC is:

1. AKS stays the managed Kubernetes platform.
2. A dedicated dataplane node pool is used.
3. The node has two paths:
   - `eth0` for AKS management and standard pod networking
   - `eth1` for the dataplane-side experiment
4. VPP runs per node as a privileged DaemonSet-style workload.
5. Service pods keep management on `eth0` and get a second dataplane interface through Multus.
6. Branch traffic arrives wrapped because native SRv6 in Azure fabric was not usable in the previous tests.

## Topology

```mermaid
flowchart TB
    classDef branch fill:#dbeafe,stroke:#1d4ed8,stroke-width:2px,color:#000
    classDef node fill:#f3f4f6,stroke:#4b5563,stroke-width:2px,color:#000
    classDef vpp fill:#fde68a,stroke:#92400e,stroke-width:2px,color:#000
    classDef service fill:#dcfce7,stroke:#166534,stroke-width:2px,color:#000
    classDef overlay fill:#ede9fe,stroke:#6d28d9,stroke-width:2px,color:#000
    classDef underlay fill:#e5e7eb,stroke:#4b5563,stroke-width:2px,color:#000
    classDef host fill:#fef3c7,stroke:#b45309,stroke-width:2px,color:#000
    classDef mgmt fill:#fee2e2,stroke:#b91c1c,stroke-width:2px,color:#000
    classDef note fill:#eff6ff,stroke:#2563eb,stroke-width:1px,color:#000

    subgraph branch [branch-vm-dpdk]
        BR_PLAIN["eth0\nunderlay NIC\n10.120.4.4"]:::branch
        BR_VX100["vxlan100\noverlay endpoint\n10.50.0.2/30\nfc00::2/64"]:::overlay
        BR_ROUTE["branch route\n10.20.0.0/16 via vxlan100\ninner SRv6 to fc00::a:1:e004"]:::branch
        BR_PLAIN --> BR_VX100 --> BR_ROUTE
    end

    subgraph azure [Azure VNet Underlay]
        AZ_NOTE["Azure-visible NIC IPs only\nbranch eth0 10.120.4.4\nnode1 eth0 10.120.2.4\nnode1 eth1 10.120.3.4\nnode2 eth0 10.120.2.5\nnode2 eth1 10.120.3.5"]:::underlay
    end

    subgraph node1 [AKS Node 1]
        N1_POD["phase1-service-a\neth0 10.246.0.95\nnet1 10.20.1.20/16"]:::service
        N1_MGMT["eth0\nmanagement NIC\n10.120.2.4"]:::mgmt
        subgraph N1_HOST [Linux host networking]
            N1_ETH1["eth1\nforwarding NIC\n10.120.3.4"]:::host
            N1_VX100["vxlan100\nbranch-facing outer VXLAN\nUDP 8472"]:::overlay
            N1_VX200["vxlan200\nnode2-facing outer VXLAN\nUDP 8472"]:::overlay
            N1_DP0["dp0\nmacvlan on eth1"]:::host
        end
        subgraph N1_VSW [VPP dataplane]
            N1_VPP["phase1-vpp\nVPP hostNetwork pod"]:::vpp
            N1_HVX100["host-vxlan100\n10.50.0.1/30\nfc00::1/64"]:::vpp
            N1_HVX200["host-vxlan200\n10.60.0.1/30"]:::vpp
            N1_HDP0["host-dp0\n10.20.0.254/16"]:::vpp
            N1_VPP --> N1_HVX100
            N1_VPP --> N1_HVX200
            N1_VPP --> N1_HDP0
        end

        N1_MGMT -. mgmt only .-> N1_POD
        N1_ETH1 --> N1_VX100
        N1_ETH1 --> N1_VX200
        N1_ETH1 --> N1_DP0
        N1_HDP0 --> N1_POD
        N1_POD --> N1_HDP0
    end

    subgraph node2 [AKS Node 2]
        N2_POD["phase1-service-b\neth0 10.246.1.223\nnet1 10.21.1.20/16"]:::service
        N2_MGMT["eth0\nmanagement NIC\n10.120.2.5"]:::mgmt
        subgraph N2_HOST [Linux host networking]
            N2_ETH1["eth1\nforwarding NIC\n10.120.3.5"]:::host
            N2_VX200["vxlan200\nnode1-facing outer VXLAN\nUDP 8472"]:::overlay
            N2_DP0["dp0\nmacvlan on eth1"]:::host
        end
        subgraph N2_VSW [VPP dataplane]
            N2_VPP["phase1-vpp-node2\nVPP hostNetwork pod"]:::vpp
            N2_HVX200["host-vxlan200\n10.60.0.2/30"]:::vpp
            N2_HDP0["host-dp0\n10.21.0.254/16"]:::vpp
            N2_VPP --> N2_HVX200
            N2_VPP --> N2_HDP0
        end

        N2_MGMT -. mgmt only .-> N2_POD
        N2_ETH1 --> N2_VX200
        N2_ETH1 --> N2_DP0
        N2_HDP0 --> N2_POD
        N2_POD --> N2_HDP0
    end

    BR_VX100 -.->|outer VXLAN over Azure| N1_VX100
    N1_VX200 -.->|outer VXLAN over Azure| N2_VX200
    BR_ROUTE -.->|inner SRv6 context| N1_HVX100
    N1_HVX200 -.->|inter-node transit overlay| N2_HVX200
    AZ_NOTE --- BR_ETH0
    AZ_NOTE --- N1_ETH1
    AZ_NOTE --- N2_ETH1
```

## First Success Criteria

The first reviewed scenario should prove these items in order:

1. Branch VM can send VXLAN-wrapped SRv6 payload to the AKS dataplane node.
2. VPP can terminate the outer VXLAN wrapper.
3. VPP can use the inner SRv6 context to select a local forwarding action.
4. VPP can deliver traffic to a same-node service pod dataplane interface.
5. VPP can steer traffic from one local service pod to another local service pod.
6. The datapath is observable with counters and packet capture.

## Important Constraints Carried Forward From Earlier Work

- Native SRv6 through Azure fabric is not the starting point.
- VXLAN on UDP `8472` is the known safe outer transport.
- The af-packet path is the functional bring-up path.
- Native MANA DPDK is promising, but VPP forwarding on top of it is still a gated item.

## Next Read

Start with [01-vxlan-srv6-afpacket/README.md](./01-vxlan-srv6-afpacket/README.md).