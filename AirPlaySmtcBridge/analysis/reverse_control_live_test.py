"""DACP reverse-control test v2 — objective evidence:
   (a) per-message arrival timestamps of RTSP `progress` on TCP 7000
   (b) UDP audio packet rate from the iPhone (stops when the sender pauses)
Sequence: baseline 14s -> ONE pause -> 16s -> ONE play -> 16s
"""
import ctypes, ctypes.wintypes as w, struct, time, re, socket, datetime, collections

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
Packet.PacketFreePacket.argtypes = [ctypes.POINTER(PACKET)]

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
    if proto == 6 and len(rest) >= 20:
        sp, dp = struct.unpack_from('>HH', rest, 0); doff = (rest[12] >> 4) * 4
        return ('TCP', sp, dp, rest[doff:])
    if proto == 17 and len(rest) >= 8:
        sp, dp = struct.unpack_from('>HH', rest, 0)
        return ('UDP', sp, dp, rest[8:])
    return None

ad, pkt, mem, adapter = open_wifi()
print(f"adapter: {adapter}")
blob = bytearray(); progress_seen = 0
audio_buckets = collections.Counter()   # second-bucket -> udp audio packets
progress_log = []                       # (arrival time, raw, pos_s, total_s)
def pos_of(raw):
    p = raw.split('/'); return (int(p[1]) - int(p[0])) / 44100.0, (int(p[2]) - int(p[0])) / 44100.0

def pump(seconds):
    global progress_seen
    end = time.time() + seconds
    while time.time() < end:
        if Packet.PacketReceivePacket(ad, pkt, 1) == 0:
            continue
        n = ctypes.c_int.from_address(ctypes.addressof(pkt.contents) + 52).value
        if n <= 0: continue
        raw = mem.raw[:n]; off = 0
        while off + 20 <= n:
            caplen = struct.unpack_from('<i', raw, off + 8)[0]
            if caplen <= 0 or caplen > 65535 or off + 20 + caplen > n: break
            d = l4(raw[off + 20: off + 20 + caplen])
            if d:
                kind, sp, dp, payload = d
                if kind == 'TCP' and 7000 in (sp, dp) and payload:
                    blob.extend(payload)
                elif kind == 'UDP' and (6000 <= sp <= 6200 or 6000 <= dp <= 6200):
                    audio_buckets[int(time.time())] += 1
            off += ((20 + caplen) + 3) & ~3

def collect_progress():
    global progress_seen
    matches = re.findall(rb'progress:\s*([\d/]+)', bytes(blob[-2000000:]))
    while progress_seen < len(matches):
        v = matches[progress_seen].decode(); progress_seen += 1
        p, tot = pos_of(v)
        now = datetime.datetime.now()
        if not progress_log or progress_log[-1][1] != v:
            progress_log.append((now, v, p, tot))

def report_phase(label, t0, t1):
    seg = [x for x in progress_log if t0 <= x[0] <= t1]
    audio = sum(c for b, c in audio_buckets.items() if t0.timestamp() <= b <= t1.timestamp())
    dur = (t1 - t0).total_seconds()
    print(f"  {label:22s} {t0:%H:%M:%S}-{t1:%H:%M:%S} ({dur:4.1f}s): progress={len(seg):2d}  audio_udp={audio:5d} pkt ({audio/dur:6.1f}/s)")
    for t, raw, p, tot in seg:
        print(f"       {t:%H:%M:%S.%f}"[:-3] + f"  pos={p:7.2f}s/{tot:7.2f}s  ({raw})")
    return len(seg), audio / dur if dur else 0

def dacp(ip, port, path, token):
    try:
        c = socket.create_connection((ip, port), timeout=4)
        c.sendall((f"GET /ctrl-int/1/{path} HTTP/1.1\r\nHost: {ip}:{port}\r\nActive-Remote: {token}\r\n\r\n").encode())
        c.settimeout(3); data = b''
        try:
            while len(data) < 400:
                ch = c.recv(400)
                if not ch: break
                data += ch
                if b'\r\n\r\n' in data: break
        except socket.timeout: pass
        c.close(); return data.split(b'\r\n')[0].decode('latin1', 'replace')
    except Exception as e:
        return f"EXC {type(e).__name__}: {e}"

print("phase 1: baseline 14s ...")
pump(14); collect_progress()
tok = re.findall(rb'Active-Remote:\s*(\d+)', bytes(blob))
token = tok[-1].decode() if tok else None
print(f"  live token = {token}; baseline progress msgs = {len(progress_log)}")
if not token:
    print("!! no token seen; aborting"); raise SystemExit(1)
t0 = datetime.datetime.now(); report_phase('baseline', t0 - datetime.timedelta(seconds=14), t0)

ip, port = '10.123.146.142', 59309
print(f"\nphase 2: ONE pause -> {ip}:{port}")
st = dacp(ip, port, 'pause', token); print("  pause ->", st)
tp0 = datetime.datetime.now(); pump(16); collect_progress(); tp1 = datetime.datetime.now()
n_p, rate_p = report_phase('during pause', tp0, tp1)

print(f"\nphase 3: ONE play")
st2 = dacp(ip, port, 'play', token); print("  play  ->", st2)
tr0 = datetime.datetime.now(); pump(16); collect_progress(); tr1 = datetime.datetime.now()
n_r, rate_r = report_phase('after resume', tr0, tr1)

print("\n================ VERDICT ================")
print(f"pause http: {st}")
print(f"play  http: {st2}")
print(f"progress msgs: during pause={n_p}, after resume={n_r}")
print(f"audio udp rate: during pause={rate_p:.1f}/s, after resume={rate_r:.1f}/s")
if '200 OK' in st and rate_p < max(1.0, rate_r * 0.2):
    print("=> PAUSE REALLY WORKED (audio stream went quiet) and PLAY resumed it. Reverse control confirmed.")
elif '200 OK' in st:
    print("=> 200 OK received, but the audio stream did NOT go quiet -> command accepted but no audible effect in this window.")
else:
    print("=> command rejected; nothing changed.")
Packet.PacketFreePacket(pkt); Packet.PacketCloseAdapter(ad)
