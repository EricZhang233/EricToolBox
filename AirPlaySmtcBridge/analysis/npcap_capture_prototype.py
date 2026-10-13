"""Non-elevated capture prototype using Npcap's Packet.dll (no admin)."""
import ctypes, ctypes.wintypes as w, struct, time, re, sys

Packet = ctypes.WinDLL("Packet.dll")

class OVERLAPPED(ctypes.Structure):
    _fields_ = [("Internal", ctypes.c_void_p), ("InternalHigh", ctypes.c_void_p),
                ("Offset", w.DWORD), ("OffsetHigh", w.DWORD), ("hEvent", w.HANDLE)]

class PACKET(ctypes.Structure):
    _fields_ = [("hEvent", w.HANDLE), ("Overlapped", OVERLAPPED), ("Buffer", ctypes.c_void_p),
                ("Length", w.UINT), ("ulBytesReceived", w.DWORD), ("bIoComplete", ctypes.c_ubyte)]

Packet.PacketGetAdapterNames.argtypes = [ctypes.c_char_p, ctypes.POINTER(w.ULONG)]
Packet.PacketGetAdapterNames.restype = w.BOOLEAN
Packet.PacketOpenAdapter.argtypes = [ctypes.c_char_p]
Packet.PacketOpenAdapter.restype = ctypes.c_void_p
Packet.PacketCloseAdapter.argtypes = [ctypes.c_void_p]
Packet.PacketSetHwFilter.argtypes = [ctypes.c_void_p, w.ULONG]
Packet.PacketSetBuff.argtypes = [ctypes.c_void_p, ctypes.c_int]
Packet.PacketSetReadTimeout.argtypes = [ctypes.c_void_p, ctypes.c_int]
Packet.PacketSetMinToCopy.argtypes = [ctypes.c_void_p, ctypes.c_int]
Packet.PacketReceivePacket.argtypes = [ctypes.c_void_p, ctypes.POINTER(PACKET), w.BOOLEAN]
Packet.PacketAllocatePacket.argtypes = []
Packet.PacketAllocatePacket.restype = ctypes.POINTER(PACKET)
Packet.PacketInitPacket.argtypes = [ctypes.POINTER(PACKET), ctypes.c_void_p, w.UINT]
Packet.PacketFreePacket.argtypes = [ctypes.POINTER(PACKET)]
Packet.PacketGetVersion.restype = ctypes.c_char_p
try:
    Packet.PacketGetDriverVersion.restype = ctypes.c_char_p
except AttributeError:
    pass

print("Packet.dll version:", Packet.PacketGetVersion())
try:
    print("driver version   :", Packet.PacketGetDriverVersion())
except Exception as e:
    print("driver version   : ?", e)

bufsize = 65536
names = ctypes.create_string_buffer(bufsize)
size = w.ULONG(bufsize)
ok = Packet.PacketGetAdapterNames(names, ctypes.byref(size))
raw = names.raw[:size.value]
parts = raw.split(b'\x00')
# first the adapter names (until empty entry), then descriptions
idx = parts.index(b'') if b'' in parts else len(parts)
adapter_names = [p.decode('latin1') for p in parts[:idx] if p]
descs = [p.decode('latin1', 'replace') for p in parts[idx + 1:] if p]
print(f"PacketGetAdapterNames ok={bool(ok)} adapters={len(adapter_names)}")
for i, n in enumerate(adapter_names):
    d = descs[i] if i < len(descs) else '?'
    print(f"  [{i}] {n}   desc={d!r}")

def pick(name, desc):
    s = (name + ' ' + desc).lower()
    return any(k in s for k in ('wi-fi', 'wifi', 'wlan', 'wireless', '802.11', '无线'))
targets = [i for i in range(len(adapter_names)) if pick(adapter_names[i], descs[i] if i < len(descs) else '')]
if not targets:
    targets = list(range(len(adapter_names)))
print("candidate adapters:", targets)

ETH_TYPES = {0x0800, 0x86DD, 0x0806, 0x8100, 0x88A8}

def parse_records(rawmem, nbytes, hdrlen):
    """WinPcap packet buffer -> list of frames."""
    off = 0
    frames = []
    while off + hdrlen <= nbytes:
        caplen = struct.unpack_from('<I', rawmem, off + 8)[0]
        datalen = struct.unpack_from('<I', rawmem, off + 12)[0]
        hdr = struct.unpack_from('<H', rawmem, off + 16)[0] if hdrlen >= 18 else hdrlen
        if caplen == 0 or caplen > 65535 or datalen > 65535:
            break
        if off + hdrlen + caplen > nbytes:
            break
        frames.append(rawmem[off + hdrlen: off + hdrlen + caplen])
        step = hdrlen + caplen
        step = (step + 3) & ~3
        off += step
    return frames

def valid_frames(frames):
    good = 0
    for f in frames[:200]:
        if len(f) >= 14 and struct.unpack_from('>H', f, 12)[0] in ETH_TYPES:
            good += 1
    return good

def l4(frame):
    if len(frame) < 14:
        return None
    et = struct.unpack_from('>H', frame, 12)[0]
    off = 14
    while et in (0x8100, 0x88A8) and len(frame) >= off + 4:
        et = struct.unpack_from('>H', frame, off + 2)[0]
        off += 4
    if et == 0x0800 and len(frame) >= off + 20:
        ihl = (frame[off] & 0x0f) * 4
        proto = frame[off + 9]
        dst = '.'.join(str(b) for b in frame[off + 16:off + 20])
        src = '.'.join(str(b) for b in frame[off + 12:off + 16])
        rest = frame[off + ihl:]
    elif et == 0x86DD and len(frame) >= off + 40:
        proto = frame[off + 6]
        src = ':'.join('%02x%02x' % (frame[off + 8 + i], frame[off + 9 + i]) for i in range(0, 16, 2))
        dst = ':'.join('%02x%02x' % (frame[off + 24 + i], frame[off + 25 + i]) for i in range(0, 16, 2))
        rest = frame[off + 40:]
    else:
        return None
    if proto == 6 and len(rest) >= 20:
        sp, dp = struct.unpack_from('>HH', rest, 0)
        doff = (rest[12] >> 4) * 4
        return ('TCP', src, sp, dst, dp, rest[doff:])
    if proto == 17 and len(rest) >= 8:
        sp, dp = struct.unpack_from('>HH', rest, 0)
        return ('UDP', src, sp, dst, dp, rest[8:])
    return None

total = 0
p7000 = 0
samples = []
for i in targets:
    ad = Packet.PacketOpenAdapter(adapter_names[i].encode('latin1'))
    if not ad:
        print(f"  adapter {i}: open FAILED")
        continue
    print(f"  adapter {i}: opened (handle={hex(ad)})")
    Packet.PacketSetHwFilter(ad, 0x002F)
    Packet.PacketSetBuff(ad, 8 * 1024 * 1024)
    Packet.PacketSetReadTimeout(ad, 500)
    Packet.PacketSetMinToCopy(ad, 0)
    pkt = Packet.PacketAllocatePacket()
    if not pkt:
        print("    PacketAllocatePacket failed")
        Packet.PacketCloseAdapter(ad)
        continue
    mem = ctypes.create_string_buffer(2 * 1024 * 1024)
    Packet.PacketInitPacket(pkt, ctypes.cast(mem, ctypes.c_void_p), len(mem))
    hdrlen_chosen = None
    deadline = time.time() + 12
    got = 0
    while time.time() < deadline:
        r = Packet.PacketReceivePacket(ad, pkt, True)
        n = pkt.contents.ulBytesReceived
        if n == 0:
            continue
        if hdrlen_chosen is None:
            scores = {}
            for hl in (20, 18, 22, 24, 16):
                try:
                    fr = parse_records(mem.raw[:n], n, hl)
                    scores[hl] = valid_frames(fr)
                except Exception:
                    scores[hl] = -1
            hdrlen_chosen = max(scores, key=scores.get)
            print(f"    header layout probe: {scores} -> using hdrlen={hdrlen_chosen}")
        frames = parse_records(mem.raw[:n], n, hdrlen_chosen)
        got += len(frames)
        for f in frames:
            total += 1
            d = l4(f)
            if not d:
                continue
            kind, src, sp, dst, dp, payload = d
            if 7000 in (sp, dp):
                p7000 += 1
                if payload and (b'SET_PARAMETER' in payload or b'progress' in payload or b'RTSP' in payload):
                    for m in re.finditer(rb'[ -~]{8,}', payload):
                        s = m.group(0)
                        if b'SET_PARAMETER' in s or b'progress' in s or b'RTSP/1.0' in s:
                            samples.append((kind, f"{src}:{sp}->{dst}:{dp}", s[:120]))
    print(f"    captured frames in 12s: {got}")
    Packet.PacketFreePacket(pkt)
    Packet.PacketCloseAdapter(ad)
    if p7000:
        break

print(f"\nTOTAL frames={total}  frames on port 7000={p7000}")
print("RTSP samples seen non-elevated:")
for kind, flow, s in samples[:15]:
    print(f"  {kind} {flow}  {s.decode('utf-8','replace')}")
if not samples:
    print("  (none in this window - is the iPhone still streaming?)")
