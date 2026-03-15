#!/bin/bash

# Test af_xdp TX on eth1
vppctl set interface state eth1/0 up
vppctl set interface ip address eth1/0 10.120.3.10/24

echo "=== PING via af_xdp eth1/0 ==="
vppctl ping 10.120.3.1 source eth1/0 repeat 5

echo "=== tcpdump verify ==="
nohup timeout 6 tcpdump -i eth1 -c 5 -nn icmp -w /tmp/xdp_tx.pcap 2>/dev/null &
sleep 1
vppctl ping 10.120.3.1 source eth1/0 repeat 3
sleep 4
echo "Packets on wire:"
tcpdump -r /tmp/xdp_tx.pcap -nn 2>/dev/null
echo "Count: $(tcpdump -r /tmp/xdp_tx.pcap -nn 2>/dev/null | wc -l)"

echo "=== VPP counters ==="
vppctl show interface eth1/0
