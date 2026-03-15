#!/bin/bash
set -e

# Kill VPP
pkill -9 vpp 2>/dev/null || true
sleep 1

# Give eth1 an IP
ip link set eth1 up
ip addr flush dev eth1
ip addr add 10.120.3.10/24 dev eth1
sleep 2

echo "=== TEST 1: Linux kernel ping (NOT af_packet) ==="
ping -c 3 -W 2 -I eth1 10.120.3.1 2>&1 || echo "PING FAILED"

echo ""
echo "=== TEST 2: tcpdump + Linux ping ==="
nohup timeout 5 tcpdump -i eth1 -c 5 -nn -w /tmp/kern_ping.pcap 2>/dev/null &
sleep 1
ping -c 2 -W 2 -I eth1 10.120.3.1 2>&1 || true
sleep 3
echo "Kernel ping packets on eth1:"
tcpdump -r /tmp/kern_ping.pcap -nn 2>/dev/null | wc -l

echo ""
echo "=== TEST 3: af_packet raw socket TX (like VPP uses) ==="
apt-get install -y -qq python3 > /dev/null 2>&1
python3 << 'PYEOF'
import socket, struct, time, fcntl

# AF_PACKET SOCK_RAW — same socket type VPP uses
s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0003))
s.bind(("eth1", 0))

# Get MAC
mac = fcntl.ioctl(s.fileno(), 0x8927, struct.pack("256s", b"eth1"))[18:24]
print(f"eth1 MAC: {':'.join('%02x' % b for b in mac)}")

# Build a simple ARP request for 10.120.3.1
dst = b"\xff\xff\xff\xff\xff\xff"
etype = struct.pack("!H", 0x0806)
arp = struct.pack("!HHBBH6s4s6s4s",
    1, 0x0800, 6, 4, 1,
    mac, socket.inet_aton("10.120.3.10"),
    b"\x00"*6, socket.inet_aton("10.120.3.1"))

frame = dst + mac + etype + arp
sent = s.send(frame)
print(f"af_packet send() returned: {sent} bytes")

time.sleep(1)
s.setblocking(False)
try:
    data = s.recv(1500)
    print(f"Got reply: {len(data)} bytes")
except BlockingIOError:
    print("No reply — af_packet TX may be broken")
s.close()
PYEOF

echo ""
echo "=== TEST 4: tcpdump during af_packet raw send ==="
rm -f /tmp/afp_test.pcap
nohup timeout 6 tcpdump -i eth1 -c 5 -nn arp -w /tmp/afp_test.pcap 2>/dev/null &
sleep 1
python3 << 'PYEOF2'
import socket, struct, fcntl

s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0003))
s.bind(("eth1", 0))
mac = fcntl.ioctl(s.fileno(), 0x8927, struct.pack("256s", b"eth1"))[18:24]
dst = b"\xff\xff\xff\xff\xff\xff"
etype = struct.pack("!H", 0x0806)
arp = struct.pack("!HHBBH6s4s6s4s",
    1, 0x0800, 6, 4, 1,
    mac, socket.inet_aton("10.120.3.10"),
    b"\x00"*6, socket.inet_aton("10.120.3.1"))
for i in range(5):
    s.send(dst + mac + etype + arp)
print("Sent 5 ARP frames via af_packet")
s.close()
PYEOF2
sleep 4
echo "af_packet ARP frames seen by tcpdump:"
tcpdump -r /tmp/afp_test.pcap -nn 2>/dev/null
echo "Count: $(tcpdump -r /tmp/afp_test.pcap -nn 2>/dev/null | wc -l)"
