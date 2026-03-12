# Customer Requirement Capture For Azure SASE Design

This page captures the current understanding of the customer requirements before moving into design options.

The intent is to confirm the functional and architectural expectations first, then evaluate implementation choices in Azure.

## Purpose

This summary is written as a requirements checkpoint.

Suggested customer prompt:

"This is the set of requirements and assumptions we understand so far. Can you please review and confirm whether this is accurate before we move into the design phase?"

## What We Understand So Far

### 1. Regional PoP Model

- The SASE platform is expected to run as multiple regional PoPs.
- Branch traffic should enter the PoP that is geographically closest to the branch or user when possible.
- After entering a regional PoP, traffic can use the Azure backbone to reach the broader global SASE network.

### 2. Node Dataplane Model

- Each worker node is expected to have a management-facing interface and one or more forwarding-facing interfaces.
- The forwarding interfaces are used for WAN and customer-facing dataplane traffic.
- A single VPP instance is expected per host.
- VPP is preferred as a host OS service, not as an application pod.
- The main reason for running VPP on the host is to avoid extra datapath overhead when traffic moves between chained SASE service pods.

### 3. Service Pod Model

- SASE functions such as IPsec, firewall, and QoS are expected to run as pods.
- These service pods are expected to use separate management and dataplane interfaces.
- A management interface is needed for Kubernetes and control-plane communication.
- A separate dataplane interface is needed for service traffic.
- Pure L3 connectivity is sufficient between the dataplane entity on the host and the service pods.
- L2 adjacency is not currently required.
- A host-side TAP or similar mechanism may be involved, but the exact pod dataplane attachment model is still to be confirmed.

### 4. Ingress Role

- The ingress edge role is similar to the current on-premises edge implementation.
- The edge acts as a classifier and load balancer toward IPsec endpoints.
- The edge does not terminate IPsec itself.
- The edge does not perform NAT in this role.
- The edge is expected to keep stickiness so that the same branch or client traffic is sent to the same IPsec endpoint.
- The exact hashing or stickiness fields are still unknown.
- The current implementation is understood to use VPP and DPDK on bare metal for this edge role.

### 5. IPsec Endpoint Model

- IPsec termination happens on IPsec service pods, not on the edge classifier.
- For a given customer, the IPsec pod set is expected to be relatively fixed for a period of time.
- If a customer grows and adds more branches, the platform may scale out by adding more IPsec pods.
- If demand decreases, the platform may scale in by removing pods.
- Different endpoint pools are expected for branch connectivity and mobile-user connectivity.

### 6. Service Chaining

- The service chain is decided by a policy engine that programs the forwarding behavior.
- The edge classifier is not responsible for deciding the service chain.
- The active service chain depends on customer policy and purchased service tier.
- For example, customers that pay for firewall service should receive a chain that includes the firewall function.
- The current proof-of-concept scope only needs to prove static routes and static service chaining.
- Full dynamic policy orchestration is out of scope for the first proof.

### 7. Traffic Placement Expectations

- It is preferable for a single service chain to stay on one worker node whenever possible.
- Affinity-style placement is therefore expected to be useful.
- Cross-node service chaining may still be needed, but it should not be the first or preferred path for the proof of concept.

### 8. East-West Transport Requirements

- Tenant isolation is required because overlapping customer IP space is expected.
- Native SRv6 is preferred by the customer as a conceptual direction, but it is understood that Azure may not support that model natively.
- The east-west path between nodes or clusters must therefore preserve tenant separation even if a different encapsulation model is used.
- East-west encryption is not currently a stated requirement.
- Minimizing performance impact on east-west forwarding is an important goal.

### 9. Egress And Return Path

- Symmetric forwarding is not required.
- Return traffic may leave through a different path if that gives better latency or a better overall route.
- A DSR-like model is therefore acceptable in principle.
- The exact Azure implementation model for that behavior is still to be defined.

## Initial Azure POC Scope

The first Azure proof of concept should focus on proving the basic forwarding architecture, not the final control plane.

### POC goals

- Prove one VPP instance per node running on the host.
- Prove separation between management traffic and dataplane traffic.
- Prove delivery from an ingress function to a selected IPsec pod.
- Prove static service chaining between IPsec, firewall, and QoS functions.
- Prefer to keep the service chain local to one node for the first proof.
- Add cross-node forwarding only after local chaining is validated.
- Add cross-cluster or cross-PoP forwarding only after cross-node behavior is validated.

### POC non-goals for the first stage

- Full dynamic policy engine integration.
- Full customer-driven elastic scaling behavior.
- Failure handling and tunnel re-homing scenarios.
- Final multi-region traffic engineering behavior.

## Open Questions To Confirm With The Customer

- When the edge selects an IPsec endpoint, is it selecting a pod directly, or selecting a node that then forwards locally to a pod?
- What fields are used for stickiness at the edge: source IP only, UDP source port, IKE SPI, or another tuple?
- Does the ingress path need to handle raw ESP at scale, or mainly UDP 4500 NAT-T traffic?
- Is the host-to-pod dataplane model based on TAP, ipvlan, or another specific interface type?
- In the current deployment, are service-chain functions always expected to stay on the same node for a given flow?
- For multi-region behavior, are sessions pinned to a home PoP until failure, or can they move during normal operation?

## Working Design Implications

Based on the current understanding, the first Azure design exploration should assume:

- host-resident VPP as the node-local dataplane entity
- service functions running as pods with separate management and dataplane interfaces
- a dedicated ingress classification function rather than standard Kubernetes ingress
- local service chaining as the preferred fast path
- an overlay-based east-west transport model to preserve tenant isolation when native SRv6 is unavailable

## Customer Review Request

Please confirm whether the statements in this page are accurate enough to use as the starting point for the Azure design phase.

If any point is incorrect, incomplete, or too strongly stated, it should be corrected here before design options are evaluated.