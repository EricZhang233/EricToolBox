import struct, re, collections, datetime

PCAP = r"C:\Users\eric\AppData\Local\Temp\airplay-capture\air.pcapng"
RATE = 44100.0  # assumed; validated empirically below

def read_pcapng(path):
    data = open(path, 'rb').read()
    off, tsresol = 0, 6
    pkts = []
    while off + 12 <= len(data):
        bt, bl = struct.unpack_from('<II', data, off)
        if bl < 12 or off + bl > len(data):
            break
        body = data[off + 8:off + bl - 4]
        if bt == 1:
            o = 8
            while o + 4 <= len(body):
                code, olen = struct.unpack_from('<HH', body, o)
                if code == 0:
                    break
                if code == 9 and olen >= 1:
                    tsresol = body[o + 4] & 0x7f
                o += 4 + olen + ((4 - olen % 4) % 4)
        elif bt == 6:
            iface, tsh, tsl, caplen, origlen = struct.unpack_from('<IIIII', body, 0)
            pkts.append((((tsh << 32) | tsl), body[20:20 + caplen]))
        off += bl
    return tsresol, pkts

tsresol, pkts = read_pcapng(PCAP)

def ts_str(ts):
    if not ts:
        return "?"
    return datetime.datetime.fromtimestamp(ts / (10 ** tsresol)).strftime('%H:%M:%S.%f')[:-3]

def decode_l3(et, payload):
    if et == 0x0800:
        if len(payload) < 20:
            return None
        ihl = (payload[0] & 0x0f) * 4
        proto = payload[9]
        src = '.'.join(str(b) for b in payload[12:16]); dst = '.'.join(str(b) for b in payload[16:20])
        rest = payload[ihl:]
    elif et == 0x86DD:
        if len(payload) < 40:
            return None
        proto = payload[6]
        src = ':'.join('%02x%02x' % (payload[8 + i], payload[9 + i]) for i in range(0, 16, 2))
        dst = ':'.join('%02x%02x' % (payload[24 + i], payload[25 + i]) for i in range(0, 16, 2))
        rest = payload[40:]
    else:
        return None
    if proto == 6 and len(rest) >= 20:
        sport, dport, seq = struct.unpack_from('>HHI', rest, 0)
        doff = (rest[12] >> 4) * 4
        return ('TCP', src, sport, dst, dport, seq, rest[doff:])
    if proto == 17 and len(rest) >= 8:
        sport, dport = struct.unpack_from('>HH', rest, 0)
        return ('UDP', src, sport, dst, dport, 0, rest[8:])
    return None

def decode(pkt):
    if len(pkt) >= 24:
        fc = pkt[0] | (pkt[1] << 8)
        if ((fc >> 2) & 0x3) == 2:
            subtype = (fc >> 4) & 0xf
            tods = (fc >> 8) & 1; fromds = (fc >> 9) & 1
            hdr = 24 + (6 if (tods and fromds) else 0) + (2 if subtype & 0x08 else 0) + (4 if fc & 0x8000 else 0)
            if len(pkt) >= hdr + 8 and pkt[hdr:hdr + 6] == b'\xaa\xaa\x03\x00\x00\x00':
                return decode_l3(struct.unpack_from('>H', pkt, hdr + 6)[0], pkt[hdr + 8:])
    if len(pkt) >= 14:
        et = struct.unpack_from('>H', pkt, 12)[0]
        off = 14
        while et in (0x8100, 0x88a8) and len(pkt) >= off + 4:
            et = struct.unpack_from('>H', pkt, off + 2)[0]; off += 4
        return decode_l3(et, pkt[off:])
    return None

streams = collections.OrderedDict()
for ts, pkt in pkts:
    d = decode(pkt)
    if not d:
        continue
    kind, src, sport, dst, dport, seq, payload = d
    streams.setdefault((kind, src, sport, dst, dport), []).append((seq, payload, ts))

def reassemble(items):
    """returns (buf, segments) where segments = list of (out_offset, ts, length)"""
    segs = sorted([(s, p, t) for s, p, t in items if p], key=lambda x: x[0])
    out = bytearray(); marks = []; next_seq = None; synth = 0
    for seq, p, t in segs:
        if next_seq is None:
            next_seq = seq
        if seq > next_seq:
            gap = seq - next_seq
            out.extend(b'\x00' * gap); synth += gap
            next_seq = seq
        elif seq < next_seq:
            skip = next_seq - seq
            if skip >= len(p):
                continue
            p = p[skip:]
        marks.append((len(out), t, len(p)))
        out.extend(p); next_seq += len(p)
    def off_to_ts(off):
        best = 0
        for o, t, l in marks:
            if o <= off:
                best = t
            else:
                break
        return best
    return bytes(out), off_to_ts, synth

METHODS = (b'OPTIONS', b'ANNOUNCE', b'SETUP', b'RECORD', b'PAUSE', b'FLUSH', b'TEARDOWN',
           b'SET_PARAMETER', b'GET_PARAMETER', b'POST', b'GET', b'PUT', b'DELETE')

def walk(buf, off_to_ts):
    """walk RTSP messages + interleaved RTP ($) blocks"""
    msgs = []
    i = 0; n = len(buf); interleaved = 0
    while i < n:
        if buf[i:i + 1] == b'$' and i + 4 <= n:
            ln = struct.unpack_from('>H', buf, i + 2)[0]
            if 0 < ln <= 65535 and i + 4 + ln <= n:
                interleaved += 1
                i += 4 + ln
                continue
        m = None
        for meth in METHODS:
            if buf.startswith(meth, i) or buf.startswith(b'RTSP/1.0', i):
                m = True
                break
        if not m:
            nxt = n
            for tok in (b'RTSP/1.0', b'SET_PARAMETER', b'OPTIONS', b'SETUP', b'RECORD', b'FLUSH', b'TEARDOWN', b'GET_PARAMETER'):
                p = buf.find(tok, i + 1)
                if p != -1:
                    nxt = min(nxt, p)
            i = nxt if nxt > i else i + 1
            continue
        he = buf.find(b'\r\n\r\n', i)
        if he == -1 or he - i > 8192:
            i += 1
            continue
        head = buf[i:he]
        lines = head.split(b'\r\n')
        first = lines[0]
        hdrs = {}
        for h in lines[1:]:
            if b':' in h:
                k, v = h.split(b':', 1)
                hdrs[k.strip().lower()] = v.strip()
        cl = int(hdrs.get(b'content-length', b'0') or b'0')
        body = buf[he + 4:he + 4 + cl]
        msgs.append({'off': i, 't': off_to_ts(i), 'first': first.decode('utf-8', 'replace'),
                     'hdrs': hdrs, 'body': body})
        i = he + 4 + cl
    return msgs, interleaved

def dmap_parse(b):
    """parse DAAP/DMAP tag stream -> dict of leaf tags; mlit recursed into a list"""
    out = {}
    items = []
    pos = 0
    while pos + 8 <= len(b):
        tag = b[pos:pos + 4]
        ln = struct.unpack_from('>I', b, pos + 4)[0]
        val = b[pos + 8:pos + 8 + ln]
        if len(val) < ln:
            break
        if tag == b'mlit':
            items.append(dmap_parse(val))
        else:
            out[tag.decode('latin1')] = val
        pos += 8 + ln
    if items:
        out['_items'] = items
    return out

def dm(v):
    for enc in ('utf-8', 'utf-16-be'):
        try:
            s = v.decode(enc)
            if s.isprintable() or any(c.isalnum() for c in s):
                return s
        except Exception:
            pass
    if len(v) in (1, 2, 4, 8):
        return str(int.from_bytes(v, 'big'))
    return v.hex()

progress_rows = []
meta_rows = []
art = 0
other = collections.Counter()
for key, items in streams.items():
    if key[0] != 'TCP':
        continue
    buf, off_to_ts, synth = reassemble(items)
    msgs, inter = walk(buf, off_to_ts)
    print(f"stream {key[1]}:{key[2]} -> {key[3]}:{key[4]}  bytes={len(buf)} (synthetic {synth})  msgs={len(msgs)} interleaved_blocks={inter}")
    for m in msgs:
        ct = m['hdrs'].get(b'content-type', b'').decode('latin1', 'replace')
        rt = m['hdrs'].get(b'rtp-info', b'').decode('latin1', 'replace')
        if ct.startswith('text/parameters'):
            txt = m['body'].decode('utf-8', 'replace')
            pm = re.search(r'progress:\s*([\d/]+)', txt)
            if pm:
                parts = pm.group(1).split('/')
                st, cur, end = (int(x) for x in parts)
                progress_rows.append({'t': m['t'], 'rtpinfo': rt, 'start': st, 'cur': cur, 'end': end,
                                      'raw': txt.strip()})
            else:
                other['text/parameters:' + txt[:40]] += 1
        elif ct.startswith('application/x-dmap-tagged'):
            d = dmap_parse(m['body'])
            top = d.get('_items', [d])
            for it in top:
                rec = {'t': m['t'], 'rtpinfo': rt}
                for tag, name in (('minm', 'title'), ('asar', 'artist'), ('asal', 'album'),
                                  ('astn', 'track'), ('mper', 'per'), ('asgn', 'genre'), ('asfm', 'format')):
                    if tag in it:
                        rec[name] = dm(it[tag])
                meta_rows.append(rec)
        elif ct.startswith('image/'):
            art += 1 if ct != 'image/none' else 0
            other['art:' + ct] += 1
        else:
            other['ct:' + ct + '|' + m['first'][:40]] += 1

print(f"\n=== message classes ===")
for k, v in other.most_common():
    print(f"  {k}  x{v}")

print(f"\n=== progress messages ({len(progress_rows)}) : raw start/current/end in RTP frames ===")
for r in progress_rows:
    el = (r['cur'] - r['start']) / RATE
    tot = (r['end'] - r['start']) / RATE
    print(f"  {ts_str(r['t'])}  {r['raw']:45s} -> pos {el:7.2f}s / total {tot:7.2f}s   ({r['rtpinfo']})")

print(f"\n=== DMAP metadata messages ({len(meta_rows)}) ===")
last = None
for r in meta_rows:
    sig = (r.get('title'), r.get('artist'), r.get('album'))
    if sig != last:
        print(f"  {ts_str(r['t'])}  title={r.get('title')!r} artist={r.get('artist')!r} album={r.get('album')!r} track={r.get('track')}")
        last = sig

print(f"\n=== sample-rate validation (frame delta / wall-clock delta) ===")
for a, b in zip(progress_rows, progress_rows[1:]):
    if b['start'] == a['start'] and a['t'] and b['t']:
        dt = (b['t'] - a['t']) / 1e6
        if dt > 0.05:
            print(f"  {ts_str(a['t'])} -> {ts_str(b['t'])}  d_frames={b['cur'] - a['cur']:>10d}  dt={dt:6.2f}s  => {((b['cur'] - a['cur']) / dt):10.1f} Hz")

print("\n=== pairwise rate estimate (current-frame delta / wall-clock delta) ===")
for a, b in zip(progress_rows, progress_rows[1:]):
    if a['t'] and b['t']:
        dt = (b['t'] - a['t']) / 1e6
        if dt > 0.5 and b['cur'] > a['cur']:
            print(f"  {ts_str(a['t'])} -> {ts_str(b['t'])}  {b['cur'] - a['cur']:>9d} frames / {dt:6.2f}s = {((b['cur'] - a['cur']) / dt):9.1f} Hz")
if progress_rows and len(progress_rows) > 1:
    a, b = progress_rows[0], progress_rows[-1]
    dt = (b['t'] - a['t']) / 1e6
    print(f"  OVERALL: {b['cur'] - a['cur']} frames / {dt:.3f}s = {((b['cur'] - a['cur']) / dt):.1f} Hz")
    print(f"  position advanced {(b['cur'] - b['start']) / RATE - (a['cur'] - a['start']) / RATE:.2f}s while wall clock advanced {dt:.2f}s")

# ---- merged UTF-8 timeline ----
meta_sorted = sorted(meta_rows, key=lambda r: r['t'] or 0)
with open(r"C:\Users\eric\AppData\Local\Temp\airplay-capture\timeline.tsv", "w", encoding="utf-8") as f:
    f.write("time\tposition_s\ttotal_s\traw_progress\tlyric_line\n")
    for r in progress_rows:
        t = r['t']
        cur_title = ''
        for m in meta_sorted:
            if m['t'] <= t:
                cur_title = m.get('title') or ''
            else:
                break
        f.write(f"{ts_str(t)}\t{(r['cur'] - r['start']) / RATE:.2f}\t{(r['end'] - r['start']) / RATE:.2f}\t{r['raw']}\t{cur_title}\n")
    f.write("\n# DMAP metadata updates (artist/album constant per track)\n")
    f.write("time\tlyric_line\tartist\talbum\n")
    for m in meta_sorted:
        f.write(f"{ts_str(m['t'])}\t{m.get('title', '')}\t{m.get('artist', '')}\t{m.get('album', '')}\n")
print("\nmerged timeline -> timeline.tsv")

print("\n=== distinct (start,end) timeline pairs ===")
seen = {}
for r in progress_rows:
    k = (r['start'], r['end'])
    if k not in seen:
        seen[k] = r
for k, r in seen.items():
    print(f"  start={k[0]} end={k[1]}  total={(k[1]-k[0])/RATE:7.2f}s  first seen {ts_str(r['t'])}  last pos {(r['cur']-r['start'])/RATE:7.2f}s")
