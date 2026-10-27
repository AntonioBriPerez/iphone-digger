"""Self-check for the packet parsing in agent.py: python3 agent/test_agent.py"""

import os
import struct
import sys
from types import SimpleNamespace

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # also works under python -I, like the app runs it
from agent import parse_dns, parse_packet  # noqa: E402

ETH = b"\xbe\xef" * 6 + b"\x08\x00"


def ipv4_udp(src, dst, sport, dport, payload):
    udp = struct.pack(">HHHH", sport, dport, 8 + len(payload), 0) + payload
    return bytes([0x45, 0]) + struct.pack(">H", 20 + len(udp)) + bytes(5) + bytes([17]) + bytes(2) + bytes(src) + bytes(dst) + udp


def dns_answer(name, ips):
    q = b"".join(bytes([len(p)]) + p.encode() for p in name.split(".")) + b"\0" + struct.pack(">HH", 1, 1)
    answers = b"".join(b"\xc0\x0c" + struct.pack(">HHIH", 1 if len(ip) == 4 else 28, 1, 60, len(ip)) + bytes(ip) for ip in ips)
    return struct.pack(">HHHHHH", 7, 0x8180, 1, len(ips), 0, 0) + q + answers


resp = dns_answer("api.example.com", [[93, 184, 216, 34], [1] * 16])
assert parse_dns(resp) == {"93.184.216.34": "api.example.com", "101:101:101:101:101:101:101:101": "api.example.com"}
assert parse_dns(resp[:20]) is None  # truncated packets are skipped, not fatal

# DNS reply from the router to the phone, on Wi-Fi without a link header: inbound, remote = resolver
pkt = SimpleNamespace(frame_pre_length=0, interface_name="en0", data=ETH + ipv4_udp([192, 168, 1, 1], [192, 168, 1, 20], 53, 51000, resp))
ip, port, inbound, size, dns = parse_packet(pkt)
assert (ip, port, inbound, dns["93.184.216.34"]) == ("192.168.1.1", 53, True, "api.example.com")

# Phone -> server on utun (4-byte AF header): outbound, remote = the server, port 443
pkt = SimpleNamespace(frame_pre_length=4, interface_name="utun3", data=b"\0\0\0\2" + ipv4_udp([10, 0, 0, 2], [93, 184, 216, 34], 50123, 443, b"x"))
assert parse_packet(pkt)[:3] == ("93.184.216.34", 443, False)

# Multicast is local noise
pkt = SimpleNamespace(frame_pre_length=0, interface_name="en0", data=ETH + ipv4_udp([192, 168, 1, 20], [224, 0, 0, 251], 5353, 5353, b""))
assert parse_packet(pkt) is None
print("ok")
