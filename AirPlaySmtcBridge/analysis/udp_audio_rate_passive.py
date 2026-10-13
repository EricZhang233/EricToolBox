"""Passive (no commands sent): break down UDP traffic from the iPhone by port pair, 12 s."""
import ctypes, ctypes.wintypes as w, struct, time, collections

Packet = ctypes.WinDLL("Packet.dll")
class OVERLAPPED(ctypes.Structure):
    _fields_ = [("Internal", ctypes.c_void_p), ("InternalHigh", ctypes.c_void_p),
                ("Offset", w.DWORD), ("OffsetHigh", w.DWORD), ("hEvent", w.HANDLE)]
class PACKET(ctypes.Structure):
    _fields_ = [("hEvent", w.HANDLE), ("Overlapped", OVERLAPPED), ("Buffer", ctypes.c_void_p),
                ("Length", w.UINT), ("ulBytesReceived", w.DWORD), ("bIoComplete", ctypes.c_ubyte)]
Packet.PacketGetAdapterNames.argtypes = [ctypes.c_char_p, ctypes.POINTER(w.ULONG)]
Packet.PacketGetAdapterNames.restype = w.BOOLEAN
Packet.PacketOpenAdapter.argtypes = [ctypes.c_char_p]; Packet.PacketOpenAdapter.restype = ctypes.c_void_p
Packet.PacketCloseAdapter.argtypes = [ctypes.c_void_p]
Packet.PacketSetHwFilter.argtypes = [ctypes.c_void_p, w.ULONG]
Packet.PacketSetBuff.argtypes = [ctypes.c_void_p, ctypes.c_int]
Packet.PacketSetReadTimeout.argtypes = [ctypes.c_void_p, ctypes.c_int]
Packet.PacketSetMinToCopy.argtypes = [ctypes.c_void_p, ctypes.c_int]
Packet.PacketReceivePacket.argtypes = [ctypes.c_void_p, ctypes.POINTER(PACKET), w.BOOLEAN]
Packet.PacketAllocatePacket.argtypes = []; Packet.PacketAllocatePacket.restype = ctypes.POINTER(PACKET)
Packet.PacketInitPacket.argtypes = [ctypes.POINTER(PACKET), ctypes.c_void_p, w.UINT]

def open_wifi():
    buf = ctypes.create_string_buffer(65536); size = w.ULONG(65536)
    Packet.PacketGetAdapterNames(buf, ctypes.byref(size))
    parts = buf.raw[:size.value].split(b'\x00')
    idx = parts.index(b'') if b'' in parts else len(parts)
    names = [p.decode('latin1') for p in parts[:idx] if p]
    descs = [p.decode('latin1', 'replace') for p in parts[idx + 1:] if p]
    for i, n in enumerate(names):
        d = (descs[i] if i < len(descs) else '').lower()
        if any(k in d for k in ('wi-fi', 'wifi', 'wlan', 'wireless')):
            ad = Packet.PacketOpenAdapter(n.encode('latin1'))
            if ad:
                Packet.PacketSetHwFilter(ad, 0x002F); Packet.PacketSetBuff(ad, 8 * 1024 * 1024)
                Packet.PacketSetReadTimeout(ad, 200); Packet.PacketSetMinToCopy(ad, 0)
                pkt = Packet.PacketAllocatePacket(); mem = ctypes.create_string_buffer(2 * 1024 * 1024)
                Packet.PacketInitPacket(pkt, ctypes.cast(mem, ctypes.c_void_p), len(mem))
                return ad, pkt, mem, (descs[i] if i < len(descs) else n)
    return None, None, None, None

def l4(frame):
    if len(frame) < 14: return None
    et = struct.unpack_from('>H', frame, 12)[0]; off = 14
    while et in (0x8100, 0x88A8) and len(frame) >= off + 4:
        et = struct.unpack_from('>H', frame, off + 2)[0]; off += 4
    if et == 0x0800 and len(frame) >= off + 20:
        ihl = (frame[off] & 0x0f) * 4; proto = frame[off + 9]; rest = frame[off + ihl:]
    elif et == 0x86DD and len(frame) >= off + 40:
        proto = frame[off + 6]; rest = frame[off + 40:]
    else: return None
    if proto == 17 and len(rest) >= 8:
        sp, dp = struct.unpack_from('>HH', rest, 0)
        return ('UDP', sp, dp, len(rest) - 8)
    if proto == 6 and len(rest) >= 20:
        sp, dp = struct.unpack_from('>HH', rest, 0); doff = (rest[12] >> 4) * 4
        return ('TCP', sp, dp, len(rest) - doff)
    return None

ad, pkt, mem, adapter = open_wifi()
print("adapter:", adapter, "| passive only, no commands sent")
counts = collections.Counter(); bytes_ = collections.Counter()
t0 = time.time(); end = t0 + 12
while time.time() < end:
    if Packet.PacketReceivePacket(ad, pkt, 1) == 0: continue
    n = ctypes.c_int.from_address(ctypes.addressof(pkt.contents) + 52).value
    if n <= 0: continue
    raw = mem.raw[:n]; off = 0
    while off + 20 <= n:
        caplen = struct.unpack_from('<i', raw, off + 8)[0]
        if caplen <= 0 or caplen > 65535 or off + 20 + caplen > n: break
        d = l4(raw[off + 20: off + 20 + caplen])
        if d:
            kind, sp, dp, plen = d
            if kind == 'UDP' and (6000 <= sp <= 6200 or 6000 <= dp <= 6200):
                key = (sp, dp, 'bulk' if plen >= 200 else plen)
                counts[key] += 1; bytes_[key] += plen
        off += ((20 + caplen) + 3) & ~3
dur = time.time() - t0
print(f"window {dur:.1f}s — flows involving ports 6000-6200:")
for k, c in counts.most_common(20):
    print(f"  sport={k[0]:5d} dport={k[1]:5d}  pkts={c:5d} ({c/dur:6.1f}/s)  bytes={bytes_[k]:9d}  avg={bytes_[k]/c:6.1f}")
print("\nnote: AirServer's AirPlay audio data ports are 6010/6011/6012; a bulk-payload flow that keeps")
print("      running at ~100+/s is the audio stream, a small steady flow is the RTCP/timing channel.")
