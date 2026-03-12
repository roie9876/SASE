# Scenario 01: VXLAN Plus SRv6 Over Functional VPP Path

This is the first scenario to review before deployment.

It intentionally uses the already-proven functional model from the earlier AKS work:

- branch traffic is wrapped in VXLAN
- the inner payload carries SRv6 data
- VPP receives the decapsulated traffic and applies the forwarding decision
- service delivery stays on one node first

## Why This Is First

This scenario proves the forwarding idea without blocking on the unfinished native MANA VPP dataplane work.

That means this scenario is about architectural proof first:

- Azure-safe outer transport
- tenant or service context inside the tunnel
- VPP as the node-local owner of the dataplane logic
- separate management and dataplane handling for service pods

## Planned Packet Path

1. The branch VM builds an SRv6 packet.
2. That packet is encapsulated inside VXLAN with an Azure-safe outer header.
3. Azure routes the outer packet to the AKS dataplane node.
4. VPP terminates the outer tunnel.
5. VPP reads the inner SRv6 context.
6. VPP forwards to the selected local service pod dataplane interface.
7. The service pod returns traffic to VPP for the next hop, egress, or drop.

## Planned Pod Model

- VPP pod:
  - host-facing and privileged
  - tied to the dataplane node
  - owns the local forwarding logic
- fake SASE service pods:
  - `eth0` for management and Kubernetes control-plane traffic
  - `net1` for dataplane traffic through Multus

## What This Scenario Must Show

1. Branch VM to VPP reachability over VXLAN.
2. Decapsulation at VPP.
3. SRv6-driven selection of the destination local flow.
4. VPP to service pod delivery on the dataplane interface.
5. Static same-node service chaining.

## What This Scenario Does Not Need Yet

- edge role behavior
- dynamic policy engine integration
- cross-node service chaining
- cross-cluster transport
- production traffic engineering
- final native DPDK optimization