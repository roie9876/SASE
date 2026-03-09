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

    subgraph RegionA [" 📍 Azure AKS Worker Node (DaemonSet Architecture) "]
        
        SRIOV_WAN["Azure Physical NIC 1<br/>(Intranet Traffic via SR-IOV)"]:::hw
        SRIOV_WWW["Azure Physical NIC 2<br/>(WWW Breakout via SR-IOV)"]:::hw

        subgraph VPP_DS [" Master VPP vRouter (Host Network DaemonSet) "]
            direction TB
            DPDK["DPDK Engine<br/>(Kernel Bypass Polling)"]:::vpp
            VPP["VPP / SRv6 Router<br/>(UDP Encap / Decap)"]:::vpp
            DPDK <--> VPP
        end

        subgraph ServiceChain [" Check Point Specialized Service Pods (Microservices) "]
            direction LR
            IPsec["IPsec / WireGuard Pod"]:::pod
            QoS["QoS Pod"]:::pod
            FW["Firewall Pod"]:::pod
            CASB["CASB / SWG Pod"]:::pod
        end

        %% Connections to NICs
        SRIOV_WAN <-->|"Accelerated Networking (Bypass OS)"| DPDK
        SRIOV_WWW <-->|"Accelerated Networking (Bypass OS)"| DPDK

        %% High-speed links to Pods
        VPP <-->|"memif / AF_XDP"| IPsec
        IPsec -. "Service Chain" .-> QoS
        QoS -. "Service Chain" .-> FW
        FW -. "Service Chain" .-> CASB
        CASB -. "Return to pipeline" .-> VPP
    end

    %% External I/O
    Infinity(("To: AWS Infinity Portal<br/>(Control Plane)")):::mgmt
    vWAN(("To: Azure vWAN<br/>(Intranet Traffic)")):::azure
    NAT(("To: Azure NAT Gateway<br/>(Public WWW Traffic)")):::net
    
    RegionA -. "eth0 Control Plane Telemetry<br/>(Azure CNI / Cilium)" .-> Infinity
    SRIOV_WAN ==>|"Encapsulated SRv6"| vWAN
    SRIOV_WWW ==>|"Raw Cleartext NAT"| NAT
```

### Architectural Deep Dive

#### 1. The VPP DaemonSet (Host Network)
In a pure microservices SASE environment, placing the DPDK engine inside the worker node itself (as a DaemonSet running with `hostNetwork: true`) is highly efficient. The Master VPP vRouter binds directly to Azure's physical NICs via Accelerated Networking (SR-IOV). It processes the millions of raw packets hitting the server, unwraps the IPv4 UDP transport tunnels, reads the inner SRv6 headers, and routes the traffic to the appropriate security pod.

#### 2. High-Speed Service Chaining (Kernel Bypass)
A SASE inspection pipeline requires multiple specialized engines (IPsec/WireGuard termination, QoS traffic shaping, Firewall/IPS inspection, and CASB/SWG proxies). If these are separated into individual Pods, standard Kubernetes routing (`kube-proxy` or standard `veth` pairs) is far too slow for service chaining.
To solve this, the VPP vRouter utilizes high-speed memory interfaces like **`memif`** (Shared Memory Interface) or **`AF_XDP`**. When the VPP router needs to send a packet to the IPsec Pod, and then from the IPsec Pod to the Firewall Pod, it does not send it over a traditional Linux network stack. Instead, the pods read and write the packets directly into exact shared RAM blocks on the same physical motherboard, achieving zero-copy transfer speeds.

#### 3. Overcoming Azure vWAN & IPv6 Overlap Limitations
Azure vWAN is an incredibly powerful global transit layer, but it is deeply intolerant of overlapping BGP IPv4 spaces. In our diagram, multiple customers use `10.0.0.0/8`. 
*   **The Problem:** If Check Point injected those overlapping routes directly into the Azure vWAN Hub, the Azure BGP tables would instantly collide. Furthermore, if the VPP engine transmits a raw **SRv6** packet, Azure's physical switches would simply drop the custom headers.
*   **The "Over-The-Top" Solution:** Check Point utilizes vWAN strictly as a physical transport. The VPP DaemonSet isolates the overlapping IPv4 payloads, wraps them in SRv6 routing logic, and finally encapsulates the entire data structure inside a standard IPv4 UDP packet. Azure vWAN routes the encapsulating UDP packet seamlessly across global regions without ever touching the sensitive overlapping customer data hidden inside.

#### 4. The Separation of Cloud (WWW) and Intranet (vWAN)
The VPP routing logic actively splits datapath traffic locally at the node:
*   **Intranet Payload (`eth1` bound):** Corporate data is wrapped in SRv6/UDP and pushed out to the Azure vWAN fabric.
*   **Local Web Breakout (`eth2` bound):** Standard internet browsing (e.g., Office365, YouTube) does not need to cross the expensive corporate vWAN. Instead, VPP applies NAT locally and pushes it straight to a localized Azure NAT Gateway for immediate public breakout, radically reducing vWAN transit costs. 

#### 5. The Role of Azure CNI Powered by Cilium
While DPDK handles the ultra-fast datapaths, standard Kubernetes Management (pushing configuration, talking to the Infinity Portal, metrics) is handed off to **Azure CNI Powered by Cilium**. Cilium acts independently on the `eth0` interface, using lightweight eBPF rules to enforce strict network policies over the cluster's control plane telemetry without interfering with VPP's specialized transit.