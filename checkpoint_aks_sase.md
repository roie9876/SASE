# Check Point AKS Cloud-Native SASE Architecture

As SASE providers scale, migrating from traditional virtual machines to Cloud-Native Network Functions (CNFs) hosted on Azure Kubernetes Service (AKS) becomes critical. 

This document explores how Check Point implements a high-speed, multi-tenant SASE fabric using Multi-NIC Pods integrated with Azure's physical backbone and Virtual WAN (vWAN) using Multus, DPDK, and SR-IOV.

---

## 1. High-Level Azure Multi-Region Architecture (10,000 ft View)

**IPv4 vs. IPv6 (SRv6) Clarification:** 
It is critical to distinguish where traffic shifts from IPv4 to IPv6:
*   **Customer On-Premises (Edgers):** The user's actual branch networks operate on native **IPv4** (e.g., overlapping `10.0.0.0/8`).
*   **SASE Overlay (Data Plane):** Once inside the Check Point SASE Hub, the VPP engines translate and route packets using **IPv6 (SRv6)** to completely isolate Customer A from Customer B and to define security service chains.
*   **Azure Underlay (vWAN):** Azure's physical switches cannot route custom SRv6 natively. Therefore, the IPv6/SRv6 traffic is encapsulated inside a standard **IPv4 UDP** packet before touching the Azure backbone. Azure merely routes standard IPv4 UDP over vWAN.

This topology illustrates the macroscopic routing landscape. It demonstrates how two overlapping enterprise customers (`Customer A` and `Customer B`, both using the exact same `10.0.0.0/8` IPv4 space) are securely routed across Azure vWAN using custom Check Point VPP containers. 

```mermaid
flowchart TD
    %% Styling
    classDef azure fill:#0078D4,stroke:#fff,stroke-width:2px,color:#fff
    classDef custA fill:#00796B,stroke:#fff,stroke-width:2px,color:#fff
    classDef custB fill:#E64A19,stroke:#fff,stroke-width:2px,color:#fff
    classDef hw fill:#424242,stroke:#fff,stroke-width:2px,color:#fff
    classDef aws fill:#FF9900,stroke:#fff,stroke-width:2px,color:#fff

    subgraph AWS [" 🧠 AWS Management Cloud "]
        Infinity["Check Point Infinity Portal<br/>(Management & Control Plane)"]:::aws
    end

    %% Using separate subgraphs for edges fixes the UI text cutoff
    subgraph EdgeA [" 🏢 Customer A Ecosystem "]
        A_Branch["Customer A Edge<br/>(IPv4: 10.0.0.0/8)<br/>Quantum SD-WAN & Harmony"]:::custA
    end

    subgraph EdgeB [" 🏢 Customer B Ecosystem "]
        B_Branch["Customer B Edge<br/>(IPv4: 10.0.0.0/8)<br/>Quantum SD-WAN & Harmony"]:::custB
    end

    subgraph RegionA [" 📍 Region A: Azure AKS (East US) "]
        SaseHubA["Check Point SASE Hub<br/>(Internal Data Plane: IPv6 SRv6)"]:::hw
    end

    subgraph Underlay [" 🌐 Microsoft Azure Global Backbone "]
        vWAN{"Azure Virtual WAN Hub<br/>(Blind IPv4 UDP Transport)"}:::azure
    end

    subgraph RegionB [" 📍 Region B: Azure AKS (West EU) "]
        SaseHubB["Check Point SASE Hub<br/>(Internal Data Plane: IPv6 SRv6)"]:::hw
    end

    %% Edge Connections
    A_Branch ==>|"IPv4 over IPsec/ZTNA"| SaseHubA
    B_Branch ==>|"IPv4 over IPsec"| SaseHubA

    %% Control Plane Connections
    SaseHubA -. "Telemetry/API" .-> Infinity
    SaseHubB -. "Telemetry/API" .-> Infinity

    %% Data Plane Tunnels Routing
    SaseHubA ==>|"IPv6 encapsulated in IPv4 UDP Tunnel"| vWAN
    vWAN ==>|"IPv6 encapsulated in IPv4 UDP Tunnel"| SaseHubB
```

---

## 2. Zoom-in: VPP DaemonSet & Microservices Architecture (The Datapath)

Zooming into **Region A**, this diagram explains the complex host-level networking required to perform Telco-grade packet processing inside an AKS Worker Node. 

Because underlying public cloud fabrics (like Azure) do not natively route SRv6 packets, Check Point must handle the complex SRv6-to-UDP encapsulation themselves. Instead of putting a VPP engine inside every single customer Pod (which creates immense overhead), Check Point utilizes a **Master VPP vRouter** deployed as a **DaemonSet** on the worker node. This Master VPP acts as the high-speed traffic cop, orchestrating the entire Service Chain across specialized Cloud-Native Network Function (CNF) Pods.

```mermaid
flowchart TD
    %% Styling
    classDef azure fill:#0078D4,stroke:#fff,stroke-width:2px,color:#fff
    classDef vpp fill:#B71C1C,stroke:#fff,stroke-width:2px,color:#fff
    classDef pod fill:#00796B,stroke:#fff,stroke-width:2px,color:#fff
    classDef hw fill:#424242,stroke:#fff,stroke-width:2px,color:#fff
    classDef mgmt fill:#00ACC1,stroke:#fff,stroke-width:2px,color:#fff
    classDef net fill:#005A9E,stroke:#fff,stroke-width:2px,color:#fff

    %% External Cloud Entities
    vWAN(("1. Azure vWAN Hub<br/>(Global Intranet Route)")):::azure
    NAT(("1. Azure NAT Gateway<br/>(Public WWW Breakout)")):::net
    Infinity(("1. AWS Infinity Portal<br/>(Global Mgmt Plane)")):::mgmt

    subgraph AKS_Node [" 📍 Azure AKS Worker Node (Master VPP Architecture) "]
        
        subgraph NICs [" 2. Physical Host Interfaces "]
            eth1["eth1: SR-IOV VF<br/>(Physical Data Plane)"]:::hw
            eth2["eth2: SR-IOV VF<br/>(Physical Data Plane)"]:::hw
            eth0["eth0: Azure CNI<br/>(Mgmt / Cilium)"]:::mgmt
        end

        VPP["3. Master VPP DaemonSet vRouter<br/>(DPDK Kernel Bypass Engine)"]:::vpp

        subgraph Chain [" 4. Specialized SASE Service Pods "]
            IPsec["IPsec / WireGuard Pod"]:::pod
            QoS["QoS Traffic Shaping Pod"]:::pod
            FW["Firewall Inspection Pod"]:::pod
            CASB["CASB / SWG Proxy Pod"]:::pod
        end

        %% Internal Links
        eth1 ===>|"Direct Memory Map"| VPP
        eth2 ===>|"Direct Memory Map"| VPP

        VPP <==>|"Standard K8s veth / TAP"| IPsec
        IPsec ==>|"Routing Chain"| QoS
        QoS ==>|"Routing Chain"| FW
        FW ==>|"Routing Chain"| CASB
        CASB -.->|"Packet processed,<br/>returns to VPP"| VPP
    end

    %% External Links (Binds the outside world to the Worker Node)
    vWAN <==>|"Encapsulated UDP/SRv6"| eth1
    NAT <==>|"Cleartext Decrypted"| eth2
    Infinity <.->|"Telemetry APIs"| eth0

    %% Enforce Alignment
    vWAN ~~~ NAT ~~~ Infinity
```

### Architectural Deep Dive

#### 1. The VPP DaemonSet (Host Network)
In a pure microservices SASE environment, placing the DPDK engine inside the worker node itself (as a DaemonSet running with `hostNetwork: true`) is highly efficient. The Master VPP vRouter binds directly to Azure's physical NICs via Accelerated Networking (SR-IOV). It processes the millions of raw packets hitting the server, unwraps the IPv4 UDP transport tunnels, reads the inner SRv6 headers, and routes the traffic to the appropriate security pod.

#### 2. High-Speed Service Chaining (Standard Interfaces)
A SASE inspection pipeline requires multiple specialized engines (IPsec/WireGuard termination, QoS traffic shaping, Firewall/IPS inspection, and CASB/SWG proxies). If the underlying product architecture does not support custom shared-memory interfaces like **`memif`** (which requires heavy application rewrites to support memory-mapped datapath transfers), the VPP DaemonSet falls back to routing traffic into the specialized Pods using highly optimized **standard Linux virtual interfaces** (like `veth` pairs or `TAP` interfaces tuned for DPDK). The VPP DaemonSet acts as the central traffic switch, ensuring traffic reliably hops between the Pods. 

#### 3. Overcoming Azure vWAN & IPv6 Overlap Limitations
Azure vWAN is an incredibly powerful global transit layer, but it is deeply intolerant of overlapping BGP IPv4 spaces. In our diagram, multiple customers use `10.0.0.0/8`. 
*   **The Problem:** If Check Point injected those overlapping routes directly into the Azure vWAN Hub, the Azure BGP tables would instantly collide. Furthermore, if the VPP engine transmits a raw **SRv6** packet, Azure's physical switches would simply drop the custom headers.
*   **The "Over-The-Top" Solution:** Check Point utilizes vWAN strictly as a physical transport. The VPP DaemonSet isolates the overlapping IPv4 payloads, wraps them in SRv6 routing logic, and finally encapsulates the entire data structure inside a standard IPv4 UDP packet. Azure vWAN routes the encapsulating UDP packet seamlessly across global regions without ever touching the sensitive overlapping customer data hidden inside.
*   **The Tenant ID Routing:** When the packet reaches the destination region, the remote worker node's Master VPP DaemonSet strips off the outer IPv4 UDP shell, reads the internal SRv6 header, and extracts the **Tenant ID (VRF)**. The VPP engine uses this Tenant ID to immediately place the packet into the correct customer's isolated routing table and service chain, completely oblivious to Azure's underlying infrastructure.

#### 4. Managing 10,000+ Customer Routes: Fast Path & Slow Path Architecture
A massive cloud-native SASE deployment cannot hold every possible BGP route, for tens of thousands of tenants with overlapping subnets, inside the active memory of every single worker node's VPP engine. Doing so would exhaust the RAM (Hugepages) and destroy lookup speeds. Check Point solves this "Big Table" problem through a strict **Fast Path / Slow Path** flow caching design:

*   **The Slow Path (Punt on Cache Miss):** When the very *first* packet of a new customer connection arrives at the `eth1` physical data plane, the Master VPP DaemonSet's cache has no idea where to send it. This is a "Cache Miss". The VPP engine immediately "punts" this single packet up to an intelligent **Packet Path Classifier** (the Control Plane routing brain). This classifier does the heavy lifting: it identifies the customer's Tenant ID, looks up their specific VRF mapping, determines the exact security Microservice Chain (e.g., IPsec -> Firewall -> CASB) required, and calculates the remote SRv6 destination. 
*   **The Fast Path (Flow Cache):** Once the Classifier computes the path, it writes a tiny, highly-optimized micro-rule directly into the DPDK engine's **Flow Cache**. 
*   **Line-Rate Polling:** For the next 5 million packets in that exact same session, the VPP engine never looks at the massive routing table again. It simply hits the Flow Cache, applying the required Service Chain routing and SRv6 encapsulation on the fly. Because the DPDK engine is running in **Direct Memory Map** mode—where dedicated CPU cores are pinned in a continuous 100% loop polling a pre-allocated block of server RAM (Hugepages)—it processes these cached packets at raw physical hardware speed, completely bypassing Linux Kernel interruptions. 

#### 5. The Separation of Cloud (WWW) and Intranet (vWAN)
The VPP routing logic actively splits datapath traffic locally at the node:
*   **Intranet Payload (`eth1` bound):** Corporate data is wrapped in SRv6/UDP and pushed out to the Azure vWAN fabric.
*   **Local Web Breakout (`eth2` bound):** Standard internet browsing (e.g., Office365, YouTube) does not need to cross the expensive corporate vWAN. Instead, VPP applies NAT locally and pushes it straight to a localized Azure NAT Gateway for immediate public breakout, radically reducing vWAN transit costs. 

#### 6. The Role of Azure CNI Powered by Cilium
While DPDK handles the ultra-fast datapaths, standard Kubernetes Management (pushing configuration, talking to the Infinity Portal, metrics) is handed off to **Azure CNI Powered by Cilium**. Cilium acts independently on the `eth0` interface, using lightweight eBPF rules to enforce strict network policies over the cluster's control plane telemetry without interfering with VPP's specialized transit.