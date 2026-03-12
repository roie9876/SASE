# Experiment: Native SRv6 Through Azure Fabric

## Summary

This scenario tested whether Azure SDN would pass native IPv6 packets containing a Segment Routing Header.

The result was negative in this POC:

- plain IPv6 traffic passed
- IPv6 traffic with SRH was dropped

## Topology

- dual-stack AKS cluster in Azure
- external Azure VM as the traffic source
- direct IPv6 path through Azure fabric
- no VXLAN wrapper for the SRv6 packet under test

## What Was Tested

1. plain IPv6 ICMPv6 from branch VM to AKS node
2. IPv6 packet with SRH toward the AKS node

## What Worked

- standard IPv6 traffic reached the AKS node successfully

## What Did Not Work

- IPv6 packets carrying SRH did not pass through the Azure fabric in this test

## Why It Matters

This matters because native SRv6 would be the cleanest way to carry tenant context and service-chaining information.

Because this path did not work, the POC had to use:

- SRv6 carried **inside VXLAN/UDP**

That is why the working functional POC used VXLAN as the Azure-safe outer transport.

## What This Scenario Proves

This scenario proves:

- Azure fabric supported plain IPv6 in the tested environment
- Azure fabric did not pass SRH-bearing IPv6 packets in the tested path

It does **not** prove whether every Azure networking path behaves identically, but for this POC it was enough to force the design toward VXLAN encapsulation.

## Current Status

Status: **not working for native SRv6 in this POC**

Best way to describe it:

"Native SRv6 through Azure fabric was not usable in this test, so the working design used SRv6 inside VXLAN instead."