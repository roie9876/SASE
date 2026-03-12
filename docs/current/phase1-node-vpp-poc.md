# Phase 1 POC: Node-Local VPP On AKS

This document captures the current implementation direction for the new proof of concept.

It also records why this path was chosen over the alternatives that were discussed.

## Current Status

The direction in this document is now backed by a live validated Phase 1 baseline.

The detailed implementation, debugging notes, MTU findings, and measured performance are documented in:

- [../../pocs/phase1-node-local-vpp/README.md](../../pocs/phase1-node-local-vpp/README.md)
- [../../pocs/phase1-node-local-vpp/01-vxlan-srv6-afpacket/README.md](../../pocs/phase1-node-local-vpp/01-vxlan-srv6-afpacket/README.md)

What is proven so far:

- the branch tunnel can terminate on the AKS forwarding NIC path rather than the node management IP
- VPP can decapsulate VXLAN, consume SRv6 context, and deliver traffic to a same-node service pod dataplane interface
- the current tuned Phase 1 result reached about `2.16 Gbit/s` TCP and about `1.48 Gbit/s` UDP at `1.5 Gbit/s` offered load

What was learned so far:

- the forwarding underlay can be larger than the active service datapath
- on this AKS node, the Linux VXLAN interface still tops out at `1450`
- after SRv6 route encapsulation, the practical branch-to-service route MTU becomes `1386`
- PMTU alignment and offload control were required to recover stable TCP performance

If you are reading this document for the current Phase 1 state, use the `pocs/phase1-node-local-vpp/` documents above as the implementation record.

## Goal

Build a first POC that proves a single AKS node can behave like a SASE worker node with:

- one node-local VPP instance
- separate management and dataplane paths
- a small set of fake SASE service pods
- static forwarding and static service chaining
- DPDK plus MANA on the dataplane side

The first POC is about proving dataplane mechanics, not the final platform architecture.

## What Phase 1 Must Prove

- traffic can enter the node from a branch VM
- VPP can steer traffic into a selected SASE pod
- VPP can steer traffic between SASE pods on the same node
- the node can later be extended to node-to-node and cluster-to-cluster east-west transport
- the model can stay on AKS without forcing a self-managed Kubernetes control plane

## What Is Explicitly Deferred

- the Edge role
- dynamic policy engine integration
- dynamic customer scaling behavior
- re-homing and failure scenarios
- production traffic engineering decisions

## Decision Summary

Two different decisions were discussed and should not be mixed together.

### 1. Where VPP lives

Options considered:

- Option A: true host OS service
- Option B: privileged host-like DaemonSet on AKS
- Option C: separate VPP VM outside Kubernetes

### 2. What VPP owns

Models considered:

- Model A: VPP owns north-south, local same-node service chaining, and east-west forwarding
- Model B: VPP owns only north-south and east-west, while local pod chaining stays in kernel or CNI paths
- Model C: VPP owns only ingress and egress acceleration

## Chosen Direction

The current direction is:

- Model A architecturally
- Option B operationally

That means:

- VPP is treated as the node-local forwarding plane
- VPP is responsible for ingress, local service chaining, egress, and future east-west transport
- VPP runs on AKS as a privileged per-node DaemonSet rather than a true host systemd service

## Why Model A Was Chosen

Model A is the closest match to the customer requirement.

The customer view is that VPP is not the policy brain. It is the forwarding engine that receives instructions from an external policy entity and then decides whether traffic should:

- be sent to a service pod
- be sent to egress
- be dropped

That means VPP must remain the central dataplane owner on the node.

If local service chaining were pushed into ordinary Kubernetes service or kernel paths, the POC would stop representing the customer model accurately.

## Why Option B Was Chosen Over Option A

Option A is technically cleaner.

Advantages of a true host service:

- VPP becomes part of the node boot path
- VPP has the cleanest possible ownership of host networking, DPDK, hugepages, and CPU pinning
- the model matches the customer language most closely

But Option A was not selected for the current POC because the goal is to stay on a managed Kubernetes platform.

Disadvantages of Option A for this project:

- it pushes the POC away from AKS and toward self-managed Kubernetes
- it increases node lifecycle and drift management burden
- it makes AKS alignment weaker rather than stronger

Option B keeps AKS while getting close enough to the desired dataplane model.

Advantages of Option B:

- one VPP instance per node is natural with a DaemonSet
- VPP can still run with host networking, elevated privileges, hugepages, and direct device access
- rollout and rollback stay Kubernetes-native
- the node pool can remain managed by AKS

Tradeoffs accepted with Option B:

- VPP lifecycle is tied to pod lifecycle rather than true host service lifecycle
- VPP is not part of node boot in the same way as a systemd service
- some host integration tasks are less natural than with a native host process

The current judgment is that these tradeoffs are acceptable for Phase 1 because AKS alignment is more important than perfect host purity.

## Why Option C Was Rejected

Running VPP as a separate VM outside Kubernetes would simplify some routing questions, but it would fail to prove the main customer requirement.

It would not prove that one Kubernetes worker node can behave as a self-contained SASE worker with:

- node-local dataplane ownership
- local service chaining
- future east-west behavior

For that reason, Option C is not relevant to the active POC.

## Service Pod Connectivity Options

The next question is how the node-local VPP should connect to the SASE pods.

### Candidate A: ipvlan L3 via Multus

Pros:

- aligns with the current customer signal that L3 is enough
- fits naturally with multi-NIC pod design
- is relatively AKS-friendly for a first implementation

Cons:

- VPP has less explicit ownership of the pod-facing interface model than with a tighter host-controlled interface design

### Candidate B: TAP

Pros:

- keeps VPP more explicitly in the dataplane path toward pods
- fits the customer hint that a host-side TAP-like mechanism may exist
- makes the node-local forwarding role of VPP easier to explain

Cons:

- more custom plumbing work on the node
- more moving parts for the first AKS implementation

### Candidate C: veth

Pros:

- simplest debug and bring-up path
- useful fallback if other options are too slow to stabilize

Cons:

- more kernel involvement
- weaker as a final performance-oriented answer

## Current Implementation Preference

For the first implementation pass:

- keep VPP as a privileged per-node DaemonSet on a dedicated AKS dataplane node pool
- keep VPP as the node-local forwarding engine
- give service pods separate management and dataplane interfaces
- start with a simple, static same-node service chain

For the pod dataplane link, the current testing order should be:

1. ipvlan L3
2. TAP
3. veth as fallback or debug path

This order is chosen because ipvlan L3 is the least disruptive AKS-aligned starting point while still matching the customer's L3-only requirement.

## Phase 1 Topology

### Phase 1A: single node

- one branch VM
- one AKS dataplane node
- one VPP DaemonSet instance on that node
- two or three fake SASE pods
- static VPP forwarding policy

First traffic proofs:

- branch VM -> VPP -> selected SASE pod
- SASE pod A -> VPP -> SASE pod B on the same node
- VPP -> egress or drop based on static policy

### Phase 1B: same cluster, two nodes

- add a second dataplane node
- run one VPP instance per node
- prove static east-west between nodes

### Phase 1C: two clusters

- extend the same model across clusters
- prove cluster-to-cluster east-west transport

## Success Criteria For Phase 1A

- VPP comes up reliably on the dataplane node as a DaemonSet instance
- MANA DPDK path is usable on the target node SKU
- fake SASE pods receive both management and dataplane interfaces
- branch traffic can reach a selected service pod through VPP
- VPP can chain traffic between pods on the same node using static rules
- counters and packet capture make the datapath observable

## Main Risks

### Risk 1: VPP on MANA remains the hardest technical item

The existing repository history already shows that MANA DPDK can work in user space, but VPP-on-MANA is still the hardest part of the stack.

### Risk 2: host-like dataplane control from a DaemonSet has operational limits

The more host mutation and special node behavior the design needs, the more sensitive it becomes to AKS node upgrades and image changes.

### Risk 3: pod-facing dataplane interface choice may change after first bring-up

The first working option may not be the final preferred design, so the POC should optimize for learnings first, not permanence.

## Why This Is The Right First POC

This path preserves the customer-aligned node model while keeping the experiment on AKS.

It avoids trying to solve ingress, multi-region routing, and dynamic policy at the same time as the hardest dataplane mechanics.

If this POC works, later phases can add:

- the Edge role
- dynamic policy updates
- customer-aware endpoint placement
- cluster-to-cluster transport behaviors