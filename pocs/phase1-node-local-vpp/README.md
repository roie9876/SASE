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
    classDef tunnel fill:#e5e7eb,stroke:#4b5563,stroke-width:2px,color:#000
    classDef aks fill:#dcfce7,stroke:#166534,stroke-width:2px,color:#000
    classDef vpp fill:#fde68a,stroke:#92400e,stroke-width:2px,color:#000
    classDef service fill:#fee2e2,stroke:#b91c1c,stroke-width:2px,color:#000
    classDef mgmt fill:#ede9fe,stroke:#6d28d9,stroke-width:2px,color:#000

    subgraph branches [Branch Side]
        BRANCH_VM["Branch VM\neth0: branch underlay\nvxlan100: tunnel endpoint"]:::branch
        SRV6_ENCAP["SRv6 encap\nInner payload carries tenant or service context\nOuter transport stays VXLAN UDP 8472"]:::branch
        BRANCH_VM --> SRV6_ENCAP
    end

    subgraph overlay [Azure Transport]
        VXLAN_TUNNEL["VXLAN overlay over Azure SDN\nAzure routes only the outer packet\nClear native SRv6 is not used"]:::tunnel
        SRV6_ENCAP --> VXLAN_TUNNEL
    end

    subgraph node [AKS Dataplane Node]
        NODE_ETH0["Node eth0\nAKS management path\nAzure CNI Overlay plus Cilium"]:::mgmt
        NODE_ETH1["Node eth1\nDataplane NIC\nDedicated for the POC dataplane track"]:::aks

        subgraph vppnode [VPP Node-Local Forwarder]
            VPP_DS["VPP privileged DaemonSet pod\nhostNetwork plus hugepages plus host mounts"]:::vpp
            VXLAN_DECAP["VXLAN decap interface\nOuter tunnel terminates here"]:::vpp
            SRV6_LOOKUP["SRv6 lookup\nLocalSID or VRF decision"]:::vpp
            CHAIN["Static forwarding and chaining\nSame node first"]:::vpp

            VPP_DS --> VXLAN_DECAP
            VXLAN_DECAP --> SRV6_LOOKUP
            SRV6_LOOKUP --> CHAIN
        end

        subgraph svc [Fake SASE Service Pods]
            POD_A["Service Pod A\neth0: mgmt\nnet1: dataplane"]:::service
            POD_B["Service Pod B\neth0: mgmt\nnet1: dataplane"]:::service
            EGRESS["Egress or drop\nStatic Phase 1 action"]:::service
        end
    end

    VXLAN_TUNNEL --> VXLAN_DECAP
    NODE_ETH1 --> VPP_DS
    NODE_ETH0 -. mgmt only .-> POD_A
    NODE_ETH0 -. mgmt only .-> POD_B
    CHAIN --> POD_A
    CHAIN --> POD_B
    CHAIN --> EGRESS
    POD_A --> CHAIN
    POD_B --> CHAIN
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