# AirPlayBridge.ps1 — AirPlay (RAOP/RTSP over TCP 7000) -> Windows SMTC bridge, NO elevation required.
#   capture : Npcap Packet.dll (user mode, non-admin)
#   publish : SystemMediaTransportControlsInterop.GetForWindow(hidden HWND)
# Usage:  pwsh -NoProfile -ExecutionPolicy Bypass -File AirPlayBridge.ps1 [-Verbose]
param(
    [int]$PollMs = 800,
    [int]$DisconnectSec = 5,      # no RTSP keepalive (or FIN/TEARDOWN) for this long => unregister SMTC
    [int]$PauseAfterSec = 10,
    [ValidateSet('Song', 'Lyric')][string]$TitleMode = 'Song',
    [switch]$NoControl,
    [switch]$NoTimeline,          # publish no progress timeline at all (no scrubbable bar in the shell)
    [switch]$Verbose
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }
$work = Join-Path $env:TEMP 'AirPlayBridge'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$cache = 'C:\Users\eric\Documents\deepseek-harness\default-workspace\.dsh\cache\smtc'
if (-not (Test-Path (Join-Path $cache 'WinRT.Runtime.dll'))) { throw "CsWinRT projection missing at $cache" }
function Log([string]$m) {
    # [Console]::Out instead of Write-Output: keeps log lines OUT of the PowerShell pipeline, so
    # functions that also return a value (Resolve-Dacp, Set-Artwork, ...) do not get polluted
    [Console]::Out.WriteLine(('[{0:HH:mm:ss}] {1}' -f (Get-Date), $m))
}

Log 'loading WinRT projection ...'
Add-Type -Path (Join-Path $cache 'WinRT.Runtime.dll')
Add-Type -Path (Join-Path $cache 'Microsoft.Windows.SDK.NET.dll')

# ------------------------------------------------------------------ capture engine
Log 'compiling capture engine ...'
Add-Type -WarningAction SilentlyContinue -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public class AirPlaySniffer
{
    [DllImport("Packet.dll")] static extern byte PacketGetAdapterNames(byte[] a, ref uint size);
    [DllImport("Packet.dll", CharSet = CharSet.Ansi)] static extern IntPtr PacketOpenAdapter(string name);
    [DllImport("Packet.dll")] static extern byte PacketCloseAdapter(IntPtr a);
    [DllImport("Packet.dll")] static extern byte PacketSetHwFilter(IntPtr a, uint f);
    [DllImport("Packet.dll")] static extern byte PacketSetBuff(IntPtr a, int s);
    [DllImport("Packet.dll")] static extern byte PacketSetReadTimeout(IntPtr a, int ms);
    [DllImport("Packet.dll")] static extern byte PacketSetMinToCopy(IntPtr a, int n);
    [DllImport("Packet.dll")] static extern IntPtr PacketAllocatePacket();
    [DllImport("Packet.dll")] static extern void PacketFreePacket(IntPtr p);
    [DllImport("Packet.dll")] static extern void PacketInitPacket(IntPtr p, IntPtr buf, uint len);
    [DllImport("Packet.dll")] static extern byte PacketReceivePacket(IntPtr a, IntPtr p, byte sync);

    const int HDRLEN  = 20;                 // WinPcap record header (bpf_hdr, 4-byte aligned)
    const int CAPMAX  = 2 * 1024 * 1024;
    const int OFFS_UL = 52;                 // offsetof(PACKET, ulBytesReceived) on x64

    static IntPtr ad = IntPtr.Zero, pkt = IntPtr.Zero, mem = IntPtr.Zero;
    static byte[] d0 = new byte[1 << 16];   // iPhone -> PC  (dst port 7000)
    static byte[] d1 = new byte[1 << 16];   // PC -> iPhone
    static int l0 = 0, l1 = 0, c0 = 0, c1 = 0;
    static string lastArtSig = "";
    public static string Adapter = "";
    public static long Frames = 0, Pkts7000 = 0;
    public static long AudioPkts = 0;          // large UDP packets (the iPhone's audio stream)
    public static volatile string PeerMac = "";// MAC of the device talking to us on TCP 7000
    public static volatile bool ConnClosed = false; // FIN/RST seen on the AirPlay control connection
    public static void ClearConnClosed() { ConnClosed = false; }

    public static string OpenWifi()
    {
        byte[] buf = new byte[262144];
        uint size = (uint)buf.Length;
        if (PacketGetAdapterNames(buf, ref size) == 0) return "PacketGetAdapterNames failed";
        string raw = Encoding.ASCII.GetString(buf, 0, (int)size);
        string[] parts = raw.Split('\0');
        int n = 0; while (n < parts.Length && parts[n].Length > 0) n++;
        string[] names = new string[n];
        for (int i = 0; i < n; i++) names[i] = parts[i];
        int dn = 0; int p = n + 1;
        string[] descs = new string[parts.Length];
        while (p < parts.Length && parts[p].Length > 0) { descs[dn++] = parts[p]; p++; }
        int pick = -1;
        for (int i = 0; i < n; i++)
        {
            string d = (i < dn ? descs[i] : "").ToLower();
            if (d.Contains("wi-fi") || d.Contains("wifi") || d.Contains("wlan") || d.Contains("wireless")) { pick = i; break; }
        }
        if (pick < 0) return "no Wi-Fi adapter found";
        IntPtr h = PacketOpenAdapter(names[pick]);
        if (h == IntPtr.Zero) return "PacketOpenAdapter failed for " + names[pick];
        PacketSetHwFilter(h, 0x002F);            // promiscuous | all-local
        PacketSetBuff(h, 8 * 1024 * 1024);
        PacketSetReadTimeout(h, 300);
        PacketSetMinToCopy(h, 0);
        ad = h;
        Adapter = pick < dn ? descs[pick] : names[pick];
        pkt = PacketAllocatePacket();
        if (pkt == IntPtr.Zero) return "PacketAllocatePacket failed";
        mem = Marshal.AllocHGlobal(CAPMAX);
        PacketInitPacket(pkt, mem, (uint)CAPMAX);
        return "OK: " + Adapter;
    }

    public static void Close()
    {
        if (pkt != IntPtr.Zero) { PacketFreePacket(pkt); pkt = IntPtr.Zero; }
        if (mem != IntPtr.Zero) { Marshal.FreeHGlobal(mem); mem = IntPtr.Zero; }
        if (ad != IntPtr.Zero) { PacketCloseAdapter(ad); ad = IntPtr.Zero; }
    }

    public static string[] Pump(int ms)
    {
        if (ad == IntPtr.Zero) return new string[0];
        StringBuilder acc = new StringBuilder();
        DateTime deadline = DateTime.UtcNow.AddMilliseconds(ms);
        while (DateTime.UtcNow < deadline)
        {
            if (PacketReceivePacket(ad, pkt, 1) == 0) break;
            int n = Marshal.ReadInt32(pkt, OFFS_UL);
            if (n <= 0) continue;
            byte[] raw = new byte[n];
            Marshal.Copy(mem, raw, 0, n);
            int off = 0;
            while (off + HDRLEN <= n)
            {
                int caplen = BitConverter.ToInt32(raw, off + 8);
                if (caplen <= 0 || caplen > 65535 || off + HDRLEN + caplen > n) break;
                Frames++;
                Feed(raw, off + HDRLEN, caplen);
                off += ((HDRLEN + caplen) + 3) & ~3;
            }
            acc.Append(ParseFlow(d0, ref l0, ref c0));
            acc.Append(ParseFlow(d1, ref l1, ref c1));
        }
        return acc.ToString().Split('\n');
    }

    // ---- Ethernet / IPv6 / IPv4 / TCP ----
    static int U16(byte[] b, int o) { return (b[o] << 8) | b[o + 1]; }

    static void Feed(byte[] f, int baseOff, int len)
    {
        int end = baseOff + len;
        if (len < 14) return;
        int et = U16(f, baseOff + 12);
        int off = baseOff + 14;
        while ((et == 0x8100 || et == 0x88A8) && off + 4 <= end) { et = U16(f, off + 2); off += 4; }
        int proto;
        if (et == 0x0800 && off + 20 <= end) { proto = f[off + 9]; off += (f[off] & 0x0f) * 4; }
        else if (et == 0x86DD && off + 40 <= end) { proto = f[off + 6]; off += 40; }
        else return;
        if (proto == 17 && off + 8 <= end)
        {
            // audio stream = large UDP payloads on the AirPlay data ports (6010-6012 here).
            // Small packets on those ports are the RTCP/timing channel and keep flowing while paused.
            int usp = U16(f, off), udp = U16(f, off + 2);
            if (((usp >= 6000 && usp <= 6200) || (udp >= 6000 && udp <= 6200)) && (end - (off + 8)) >= 500)
                AudioPkts++;
            return;
        }
        if (proto != 6 || off + 20 > end) return;
        int sp = U16(f, off), dp = U16(f, off + 2);
        int doff = (f[off + 12] >> 4) * 4;
        // FIN/RST on the AirPlay control connection = the session is going away. Checked BEFORE the
        // payload guard, because those segments usually carry no payload.
        if ((dp == 7000 || sp == 7000) && ((f[off + 13] & 0x01) != 0 || (f[off + 13] & 0x04) != 0))
            ConnClosed = true;
        int payOff = off + doff, payLen = end - payOff;
        if (payLen <= 0) return;
        if (dp == 7000)
        {
            Pkts7000++;
            if (len >= 12)
            {
                var mb = new StringBuilder(17);
                for (int k = 6; k < 12; k++) { if (k > 6) mb.Append('-'); mb.Append(f[baseOff + k].ToString("X2")); }
                PeerMac = mb.ToString();
            }
            Append(ref d0, ref l0, f, payOff, payLen);
        }
        else if (sp == 7000) { Pkts7000++; Append(ref d1, ref l1, f, payOff, payLen); }
    }

    static void Append(ref byte[] b, ref int l, byte[] src, int off, int len)
    {
        if (l + len > b.Length)
        {
            int cap = b.Length; while (cap < l + len) cap *= 2;
            byte[] nb = new byte[cap]; Array.Copy(b, 0, nb, 0, l); b = nb;
        }
        Array.Copy(src, off, b, l, len);
        l += len;
    }

    static int Find(byte[] b, int from, int to, string needle)
    {
        int pl = needle.Length;
        if (pl == 0 || to - from < pl) return -1;
        for (int i = from; i <= to - pl; i++)
        {
            int j = 0; while (j < pl && b[i + j] == (byte)needle[j]) j++;
            if (j == pl) return i;
        }
        return -1;
    }

    static string Field(string head, string name)
    {
        int i = head.IndexOf(name, StringComparison.OrdinalIgnoreCase);
        if (i < 0) return "";
        int e = head.IndexOf('\r', i); if (e < 0) e = head.Length;
        string v = head.Substring(i + name.Length, e - i - name.Length).Trim();
        if (v.StartsWith(":")) v = v.Substring(1).Trim();
        return v;
    }

    static string San(string s)
    {
        if (s == null) return "";
        return s.Replace("|", "/").Replace("\r", " ").Replace("\n", " ").Trim();
    }

    static string ParseFlow(byte[] b, ref int len, ref int cursor)
    {
        StringBuilder outAll = new StringBuilder();
        string[] markers = { "SET_PARAMETER", "OPTIONS ", "RTSP/1.0", "POST ", "GET_PARAMETER", "FLUSH", "TEARDOWN" };
        int guard = 0;
        while (guard++ < 64 && cursor < len)
        {
            int best = -1;
            for (int m = 0; m < markers.Length; m++)
            {
                int q = Find(b, cursor, len, markers[m]);
                if (q >= 0 && (best < 0 || q < best)) best = q;
            }
            if (best < 0)
            {
                int keep = 8192;
                if (len > keep) { Array.Copy(b, len - keep, b, 0, keep); len = keep; cursor = 0; }
                break;
            }
            int he = Find(b, best, len, "\r\n\r\n");
            if (he < 0) { cursor = best; break; }
            string head = Encoding.UTF8.GetString(b, best, he - best);
            int cl = 0; int.TryParse(Field(head, "Content-Length"), out cl);
            int cs = he + 4;
            if (cs + cl > len) { cursor = best; break; }
            outAll.Append(Handle(b, best, he, cs, cl, head));
            cursor = cs + cl;
        }
        return outAll.ToString();
    }

    // DMAP tag scanner: 'mlit' is a container, so recurse into it
    static void ScanTags(byte[] b, int start, int end, ref string per, ref string title, ref string artist, ref string album)
    {
        int i = start;
        while (i + 8 <= end)
        {
            string tag = Encoding.ASCII.GetString(b, i, 4);
            int ln = (b[i + 4] << 24) | (b[i + 5] << 16) | (b[i + 6] << 8) | b[i + 7];
            if (ln < 0 || i + 8 + ln > end) break;
            if (tag == "mlit") ScanTags(b, i + 8, i + 8 + ln, ref per, ref title, ref artist, ref album);
            else if (tag == "mper") { StringBuilder h = new StringBuilder(); for (int k = 0; k < ln; k++) h.Append(b[i + 8 + k].ToString("x2")); per = h.ToString(); }
            else if (tag == "minm") title = Encoding.UTF8.GetString(b, i + 8, ln);
            else if (tag == "asar") artist = Encoding.UTF8.GetString(b, i + 8, ln);
            else if (tag == "asal") album = Encoding.UTF8.GetString(b, i + 8, ln);
            i += 8 + ln;
        }
    }

    static string Handle(byte[] b, int st, int he, int cs, int cl, string head)    {
        string ct = Field(head, "Content-Type");
        StringBuilder o = new StringBuilder();
        // the DACP credentials appear on every request (incl. OPTIONS keepalives) - grab them wherever
        string dacpId = Field(head, "DACP-ID"), activeR = Field(head, "Active-Remote");
        if (dacpId.Length > 0) o.Append("D|").Append(dacpId).Append("|").Append(activeR).Append("\n");
        if (ct.StartsWith("text/parameters"))
        {
            string body = Encoding.ASCII.GetString(b, cs, cl);
            int pi = body.IndexOf("progress:");
            if (pi >= 0) o.Append("P|").Append(body.Substring(pi + 9).Trim()).Append("\n");
        }
        else if (ct.StartsWith("application/x-dmap-tagged"))
        {
            string per = "", title = "", artist = "", album = "";
            ScanTags(b, cs, cs + cl, ref per, ref title, ref artist, ref album);
            o.Append("M|").Append(per).Append("|").Append(San(title)).Append("|").Append(San(artist)).Append("|").Append(San(album)).Append("\n");
        }
        else if (ct.StartsWith("image/jpeg") && cl > 1000)
        {
            // whole-body FNV-1a hash: different covers often share the same JPEG header (DQT), so
            // comparing the first bytes alone would keep a stale thumbnail across track changes
            uint h = 2166136261;
            for (int k = 0; k < cl; k++) { h ^= b[cs + k]; h *= 16777619; }
            string sig = cl.ToString() + "-" + h.ToString("x8");
            if (sig != lastArtSig)
            {
                lastArtSig = sig;
                byte[] img = new byte[cl];
                Array.Copy(b, cs, img, 0, cl);
                string p = Path.Combine(Path.Combine(Path.GetTempPath(), "AirPlayBridge"), "artwork.jpg");
                Directory.CreateDirectory(Path.GetDirectoryName(p));
                File.WriteAllBytes(p, img);
                o.Append("A|artwork.jpg|").Append(cl).Append("\n");
            }
        }
        else if (ct.Length == 0 && head.StartsWith("OPTIONS")) o.Append("K|\n");
        else if (ct.Length == 0 && head.StartsWith("TEARDOWN")) o.Append("T|\n");   // sender is leaving
        return o.ToString();
    }
}
'@

Log 'compiling Win32 helper ...'
Add-Type -WarningAction SilentlyContinue -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class BridgeWin32 {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr CreateWindowExW(uint ex, string cls, string name, uint style,
        int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    [DllImport("user32.dll")] public static extern bool DestroyWindow(IntPtr h);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string id);
}
'@

# ------------------------------------------------------------------ reverse control helper (runs entirely in .NET: no PowerShell on WinRT/foreign threads)
Log 'compiling reverse-control helper ...'
$rtDir = [System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
$ctlRefs = @((Join-Path $cache 'WinRT.Runtime.dll'), (Join-Path $cache 'Microsoft.Windows.SDK.NET.dll'))
$ctlRefs += (Get-ChildItem $rtDir -Filter 'System*.dll' -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notlike '*.Native.dll' -and $_.Name -notlike '*.resources.dll' } | ForEach-Object FullName)
$ctlRefs += (Join-Path $rtDir 'netstandard.dll')
Add-Type -WarningAction SilentlyContinue -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using Windows.Media;

public static class SmtcControl
{
    public static volatile string Host = "";
    public static volatile int    Port = 59309;
    public static volatile string Token = "";
    public static volatile bool   Enabled = true;
    public static volatile string LastLog = "";
    public static volatile int    Sent = 0;
    public static volatile int    SmtcEvents = 0;
    public static volatile int    KbEvents = 0;
    public static volatile int    RateLimited = 0;
    public static volatile string PeerName = "";   // mDNS name learned from the peer's A record
    static SystemMediaTransportControls smtcRef;
    static DateTime lastSend = DateTime.MinValue;

    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vKey);

    public static void Hook(SystemMediaTransportControls smtc)
    {
        smtcRef = smtc;
        smtc.ButtonPressed += (s, e) => { SmtcEvents++; Send(Map(e.Button.ToString()), "smtc"); };
        smtc.PlaybackPositionChangeRequested += (s, e) =>
        {
            SeekRequestedTo = e.RequestedPlaybackPosition.TotalSeconds;
            SeekRequested = true;
            LastLog = Stamp() + " seek request ignored (iOS DACP has no seek)";
        };
    }

    // keyboard media keys: polled, so it works even when Windows routes the key to another session
    static bool[] down = new bool[5];
    static readonly int[] VK = { 0xB3, 0xB0, 0xB1, 0xB2, 0xB3 };          // playpause, next, prev, stop, (dup guard)
    static readonly string[] CMDS = { "playpause", "nextitem", "previtem", "stop", null };
    public static string PollMediaKeys()
    {
        for (int i = 0; i < CMDS.Length; i++)
        {
            if (CMDS[i] == null) continue;
            bool isDown = (GetAsyncKeyState(VK[i]) & 0x8000) != 0;
            if (isDown && !down[i]) { down[i] = true; return CMDS[i]; }
            if (!isDown) down[i] = false;
        }
        return null;
    }

    // dedicated 15 ms key poller: the main PowerShell loop is far too slow to catch a key tap
    // (System.Threading.Thread cannot be compiled here - it forwards to CoreLib - so use a Timer)
    // It is started/stopped together with the SMTC session: with no SMTC registration we must not
    // swallow the user's media keys either.
    static System.Threading.Timer keyTimer;
    public static void StartKeyThread()
    {
        if (keyTimer != null) return;
        for (int i = 0; i < down.Length; i++) down[i] = false;
        keyTimer = new System.Threading.Timer((o) =>
        {
            string c = PollMediaKeys();
            if (c != null) Send(c, "kb");
        }, null, 0, 15);
    }
    public static void StopKeyThread()
    {
        if (keyTimer != null) { keyTimer.Dispose(); keyTimer = null; }
    }

    // a seek drag cannot be honoured (iOS DACP has no seek); record it so the PowerShell loop can
    // immediately re-push the true position and snap the slider back
    public static volatile bool SeekRequested = false;
    public static double SeekRequestedTo = 0;      // volatile is illegal for double; guarded by SeekRequested
    public static void ClearSeek() { SeekRequested = false; }

    static string Stamp() { return DateTime.Now.ToString("HH:mm:ss"); }

    static string Map(string b)
    {
        switch (b)
        {
            case "Play": return "play";
            case "Pause": return "pause";
            case "Stop": return "stop";
            case "Next": return "nextitem";
            case "Previous": return "previtem";
            case "FastForward": return "beginff";
            case "Rewind": return "beginrew";
            default: return null;
        }
    }

    public static void SendNow(string cmd) { Send(cmd, "kb"); }

    static void Send(string cmd, string src)
    {
        if (cmd == null) { LastLog = Stamp() + " unmapped button"; return; }
        if (!Enabled) { LastLog = Stamp() + " " + cmd + " skipped (-NoControl)"; return; }
        string tok = Token, host = Host; int port = Port;
        if (tok == null || tok.Length == 0 || host == null || host.Length == 0)
        { LastLog = Stamp() + " [" + src + "] " + cmd + " skipped (no Active-Remote/host yet)"; return; }
        // de-dupe: Windows may deliver the same media key both as an SMTC button and as a raw key
        if ((DateTime.UtcNow - lastSend).TotalMilliseconds < 800)
        { RateLimited++; LastLog = Stamp() + " " + cmd + " rate-limited (dedupe)"; return; }
        lastSend = DateTime.UtcNow;
        try
        {
            using (var c = new TcpClient())
            {
                var ar = c.BeginConnect(host, port, null, null);
                if (!ar.AsyncWaitHandle.WaitOne(1500)) { LastLog = Stamp() + " " + cmd + " connect timeout"; return; }
                c.EndConnect(ar);
                string req = "GET /ctrl-int/1/" + cmd + " HTTP/1.1\r\nHost: " + host + ":" + port +
                             "\r\nActive-Remote: " + tok + "\r\n\r\n";
                byte[] bytes = Encoding.ASCII.GetBytes(req);
                var st = c.GetStream();
                st.Write(bytes, 0, bytes.Length); st.Flush();
                byte[] buf = new byte[256]; int n = 0;
                try { st.ReadTimeout = 1500; n = st.Read(buf, 0, 256); } catch { }
                string status = n > 0 ? Encoding.ASCII.GetString(buf, 0, n).Split('\r')[0].Trim() : "(no response)";
                Sent++;
                if (cmd == "kb") KbEvents++;
                // keep our own SMTC state in sync so the next toggle sends the right command
                if (status.IndexOf("200") >= 0 && smtcRef != null)
                {
                    if (cmd == "play" || cmd == "playresume") smtcRef.PlaybackStatus = MediaPlaybackStatus.Playing;
                    else if (cmd == "pause" || cmd == "stop") smtcRef.PlaybackStatus = MediaPlaybackStatus.Paused;
                    else if (cmd == "playpause")
                        smtcRef.PlaybackStatus = (smtcRef.PlaybackStatus == MediaPlaybackStatus.Playing)
                            ? MediaPlaybackStatus.Paused : MediaPlaybackStatus.Playing;
                }
                LastLog = Stamp() + " [" + src + "] -> " + cmd + " : " + status;
            }
        }
        catch (Exception ex) { LastLog = Stamp() + " [" + src + "] -> " + cmd + " EXC " + ex.Message; }
    }

    // ---------------- mDNS: iTunes_Ctrl_<id>._dacp._tcp -> port + iPhone IPv4 ----------------
    static string ReadName(byte[] b, ref int off)
    {
        var sb = new StringBuilder(128); int jumped = 0, save = 0; bool didJump = false;
        while (off < b.Length && jumped < 30)
        {
            int len = b[off];
            if (len == 0) { off++; break; }
            if ((len & 0xC0) == 0xC0)
            {
                if (off + 1 >= b.Length) break;
                int ptr = ((len & 0x3F) << 8) | b[off + 1];
                if (!didJump) { save = off + 2; didJump = true; }
                off = ptr; jumped++; continue;
            }
            if (off + 1 + len > b.Length) break;
            if (sb.Length > 0) sb.Append('.');
            sb.Append(Encoding.ASCII.GetString(b, off + 1, len));
            off += 1 + len;
        }
        if (didJump) off = save;
        return sb.ToString();
    }

    public static string FindDacp(int timeoutMs)
    {
        try
        {
            byte[] q = new byte[12 + 24 + 4];
            q[0] = 0x12; q[1] = 0x34; q[5] = 1;         // id, flags, qdcount=1
            int qi = 12;
            foreach (var part in "_dacp._tcp.local".Split('.'))
            {
                q[qi++] = (byte)part.Length;
                for (int k = 0; k < part.Length; k++) q[qi++] = (byte)part[k];
            }
            q[qi++] = 0; q[qi++] = 0; q[qi++] = 12; q[qi++] = 0; q[qi++] = 1;   // root, PTR, IN

            using (var s = new UdpClient())
            {
                s.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
                s.Client.Bind(new IPEndPoint(IPAddress.Any, 5353));
                s.Client.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.AddMembership,
                    new MulticastOption(IPAddress.Parse("224.0.0.251"), IPAddress.Any));
                s.Send(q, qi, new IPEndPoint(IPAddress.Parse("224.0.0.251"), 5353));
                var ep = new IPEndPoint(IPAddress.Any, 0);
                int port = 0; string ipv4 = "";
                for (int round = 0; round < 4 && (port == 0 || ipv4.Length == 0); round++)
                {
                    if (round > 0) s.Send(q, qi, new IPEndPoint(IPAddress.Parse("224.0.0.251"), 5353));
                    DateTime end = DateTime.UtcNow.AddMilliseconds(Math.Max(700, timeoutMs / 4));
                    while (DateTime.UtcNow < end)
                    {
                        s.Client.ReceiveTimeout = Math.Max(150, (int)(end - DateTime.UtcNow).TotalMilliseconds);
                        byte[] d;
                        try { d = s.Receive(ref ep); } catch { break; }
                        if (d.Length < 12) continue;
                        int off = 12;
                        int qd = (d[4] << 8) | d[5], an = (d[6] << 8) | d[7], ns = (d[8] << 8) | d[9], ar = (d[10] << 8) | d[11];
                        for (int i = 0; i < qd && off < d.Length; i++) { ReadName(d, ref off); off += 4; }
                        for (int i = 0; i < an + ns + ar; i++)
                        {
                            if (off + 10 > d.Length) break;
                            string owner = ReadName(d, ref off);
                            int type = (d[off] << 8) | d[off + 1];
                            int rdlen = (d[off + 8] << 8) | d[off + 9];
                            off += 10;
                            if (off + rdlen > d.Length) break;
                            if (type == 33 && rdlen >= 6 && port == 0) port = (d[off + 4] << 8) | d[off + 5];
                            else if (type == 1 && rdlen == 4 && ipv4.Length == 0)
                            {
                                ipv4 = d[off] + "." + d[off + 1] + "." + d[off + 2] + "." + d[off + 3];
                                if (owner.Length > 0) PeerName = owner;
                            }
                            off += rdlen;
                        }
                    }
                }
                if (port != 0) Port = port;
                if (ipv4.Length != 0) Host = ipv4;
                if (port != 0 && ipv4.Length != 0) return ipv4 + ":" + port;
                if (port != 0) return "port-only:" + port;
                return "";
            }
        }
        catch (Exception ex) { return "EXC " + ex.Message; }
    }
    // unicast mDNS to a known address: used as a fallback when multicast is filtered
    public static string QueryAt(string ip)
    {
        try
        {
            byte[] q = new byte[12 + 24 + 4];
            q[0] = 0x12; q[1] = 0x35; q[5] = 1;
            int qi = 12;
            foreach (var part in "_dacp._tcp.local".Split('.'))
            {
                q[qi++] = (byte)part.Length;
                for (int k = 0; k < part.Length; k++) q[qi++] = (byte)part[k];
            }
            q[qi++] = 0; q[qi++] = 0; q[qi++] = 12; q[qi++] = 0; q[qi++] = 1;
            using (var s = new UdpClient())
            {
                s.Client.ReceiveTimeout = 1500;
                s.Send(q, qi, new IPEndPoint(IPAddress.Parse(ip), 5353));
                var ep = new IPEndPoint(IPAddress.Any, 0);
                DateTime end = DateTime.UtcNow.AddMilliseconds(1800);
                int port = 0; string found = "";
                while (DateTime.UtcNow < end)
                {
                    byte[] d;
                    try { d = s.Receive(ref ep); } catch { break; }
                    if (d.Length < 12) continue;
                    int off = 12;
                    int qd = (d[4] << 8) | d[5], an = (d[6] << 8) | d[7], ns = (d[8] << 8) | d[9], ar = (d[10] << 8) | d[11];
                    for (int i = 0; i < qd && off < d.Length; i++) { ReadName(d, ref off); off += 4; }
                    for (int i = 0; i < an + ns + ar && off + 10 <= d.Length; i++)
                    {
                        ReadName(d, ref off);
                        int type = (d[off] << 8) | d[off + 1];
                        int rdlen = (d[off + 8] << 8) | d[off + 9];
                        off += 10;
                        if (off + rdlen > d.Length) break;
                        if (type == 33 && rdlen >= 6 && port == 0) port = (d[off + 4] << 8) | d[off + 5];
                        else if (type == 1 && rdlen == 4 && found.Length == 0)
                            found = d[off] + "." + d[off + 1] + "." + d[off + 2] + "." + d[off + 3];
                        off += rdlen;
                    }
                    if (port != 0) break;
                }
                if (port != 0) { Port = port; Host = ip; return ip + ":" + port; }
                return "";
            }
        }
        catch (Exception ex) { return "EXC " + ex.Message; }
    }
}
'@ -ReferencedAssemblies $ctlRefs -IgnoreWarnings

# ------------------------------------------------------------------ SMTC publisher (LAZY)
# The session is only registered once real AirPlay data exists, so Windows never shows an
# "AirPlay (waiting)" placeholder card; it is unregistered again when the AirPlay session ends.
[void][BridgeWin32]::SetCurrentProcessExplicitAppUserModelID('Clawrin.AirPlayBridge')
$script:smtcActive = $false
$script:hwnd = [IntPtr]::Zero
$script:smtc = $null
$script:upd  = $null

function Start-Smtc {
    if ($script:smtcActive) { return }
    $h = [BridgeWin32]::CreateWindowExW(0, 'STATIC', 'AirPlayBridge', 0, 0, 0, 0, 0,
        [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)
    if ($h -eq [IntPtr]::Zero) { Log 'CreateWindowExW failed - SMTC not registered'; return }
    $s = [Windows.Media.SystemMediaTransportControlsInterop]::GetForWindow($h)
    $s.IsEnabled = $true
    $s.IsPlayEnabled = $true; $s.IsPauseEnabled = $true
    $s.IsNextEnabled = $true; $s.IsPreviousEnabled = $true; $s.IsStopEnabled = $true
    $s.IsFastForwardEnabled = $true; $s.IsRewindEnabled = $true
    try { $s.PlaybackRate = 1.0 } catch { }
    $s.PlaybackStatus = if ($state -and $state.Status -eq 'Playing') { [Windows.Media.MediaPlaybackStatus]::Playing } else { [Windows.Media.MediaPlaybackStatus]::Paused }
    $u = $s.DisplayUpdater
    $u.Type = [Windows.Media.MediaPlaybackType]::Music
    $u.Update()
    $script:hwnd = $h; $script:smtc = $s; $script:upd = $u; $script:smtcActive = $true
    if (-not $NoControl) {
        try { [SmtcControl]::Hook($s); [SmtcControl]::StartKeyThread() } catch { Log "control hook failed: $($_.Exception.Message)" }
    }
    Log "SMTC session registered (real AirPlay data present; hwnd=$h; media keys captured while registered)"
}

function Stop-Smtc {
    if (-not $script:smtcActive) { return }
    try { [SmtcControl]::StopKeyThread() } catch { }   # do not swallow media keys without an SMTC session
    try { $script:smtc.IsEnabled = $false } catch { }
    try { [void][BridgeWin32]::DestroyWindow($script:hwnd) } catch { }
    $script:smtcActive = $false
    $script:smtc = $null; $script:upd = $null; $script:hwnd = [IntPtr]::Zero
    Log 'SMTC session unregistered (no AirPlay data any more; media keys released)'
}

# ---------------- arm reverse control (SMTC buttons + keyboard media keys → DACP) ----------------
if ($NoControl) {
    [SmtcControl]::Enabled = $false
    Log 'reverse control DISABLED (-NoControl): read-only mirror'
} else {
    [SmtcControl]::Enabled = $true

    # Endpoint resolution, no disk cache: our own mDNS first, then the SYSTEM as the fallback.
    function Resolve-Dacp([int]$timeoutMs) {
        $r = [SmtcControl]::FindDacp($timeoutMs)
        if ($r -and $r -match '^\d+\.\d+\.\d+\.\d+:\d+$') { return $r }
        if (-not [SmtcControl]::Host -and [SmtcControl]::PeerName) {
            try {
                $a = Resolve-DnsName -Name ([SmtcControl]::PeerName) -Type A -ErrorAction Stop |
                     Where-Object { $_.IPAddress } | Select-Object -First 1
                if ($a) { [SmtcControl]::Host = $a.IPAddress; Log "endpoint: system resolver '$([SmtcControl]::PeerName)' -> $($a.IPAddress)" }
            } catch { Log "endpoint: system resolver failed for '$([SmtcControl]::PeerName)'" }
        }
        if (-not [SmtcControl]::Host -and [AirPlaySniffer]::PeerMac) {
            try {
                $mac = ([AirPlaySniffer]::PeerMac) -replace ':', '-'
                $n = Get-NetNeighbor -ErrorAction Stop |
                     Where-Object { $_.LinkLayerAddress -and ($_.LinkLayerAddress -replace ':', '-') -eq $mac -and $_.IPAddress -match '^\d+\.' } |
                     Select-Object -First 1
                if ($n) { [SmtcControl]::Host = $n.IPAddress; Log "endpoint: system neighbor table ($mac) -> $($n.IPAddress)" }
            } catch { }
        }
        if ([SmtcControl]::Host) {
            $u = [SmtcControl]::QueryAt([SmtcControl]::Host)
            if ($u -and $u -match '^\d+\.\d+\.\d+\.\d+:\d+$') { Log "endpoint: unicast mDNS -> $u"; return $u }
        }
        if ([SmtcControl]::Host) { return ("{0}:{1}" -f [SmtcControl]::Host, [SmtcControl]::Port) }
        return ''
    }

    $dacp = Resolve-Dacp 6000
    Log "DACP endpoint: '$dacp'  (host='$([SmtcControl]::Host)' port=$([SmtcControl]::Port))"
    Log 'reverse control armed (idle until an SMTC session is registered; token comes from the live RTSP stream)'
}

$state = @{
    Pos = 0.0; Dur = 0.0; LastProgress = $null; LastHeartbeat = $null
    Per = ''; Song = ''; Artist = ''; Album = ''; Published = ''
    Start = 0; End = 0; NewTrackUntil = $null
    LowStreak = 0; SawAudio = $false; HasData = $false; AudioOn = $false; AudioStreak = 0
    SessionGoneAt = $null; LastMetaAt = $null; LastAnchorAt = $null
    Rate = 44100.0; Status = 'Paused'
}

# ---- WinRT async bridge (StorageFile etc. return IAsyncOperation) ----
$script:AsTask = $null
foreach ($a in [AppDomain]::CurrentDomain.GetAssemblies()) {
    try { $t = $a.GetType('System.WindowsRuntimeSystemExtensions') } catch { $t = $null }
    if ($t) {
        try {
            $script:AsTask = $t.GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetParameters().Count -eq 1 } | Select-Object -First 1
        } catch { $script:AsTask = $null }
        if ($script:AsTask) { break }
    }
}
function Await-WinRT($op) {
    $iface = $op.GetType().GetInterfaces() | Where-Object { $_.IsGenericType -and $_.GetGenericTypeDefinition().FullName -like 'Windows.Foundation.IAsyncOperation*' } | Select-Object -First 1
    if (-not $iface) { throw ("not an IAsyncOperation: " + $op.GetType().FullName) }
    if ($script:AsTask) {
        $task = $script:AsTask.MakeGenericMethod($iface.GetGenericArguments()[0]).Invoke($null, @($op))
        return $task.GetAwaiter().GetResult()
    }
    $statusProp = $op.GetType().GetProperty('Status')
    if (-not $statusProp) { $statusProp = $op.GetType().GetInterface('Windows.Foundation.IAsyncInfo').GetProperty('Status') }
    $limit = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $limit -and ([string]$statusProp.GetValue($op)) -ne 'Completed') { Start-Sleep -Milliseconds 20 }
    return $iface.GetMethod('GetResults').Invoke($op, @())
}
function Set-Artwork([string]$path) {
    $file = Await-WinRT ([Windows.Storage.StorageFile]::GetFileFromPathAsync($path))
    $ref = [Windows.Storage.Streams.RandomAccessStreamReference]::CreateFromFile($file)
    if ($script:smtcActive -and $script:upd) { $script:upd.Thumbnail = $ref; $script:upd.Update() }
    return $ref
}

# Resolve (song, artist) from iOS' DMAP fields.  Observed real-world shapes:
#   asar = "歌名 — 歌手"            (most common for Apple Music CN tracks)
#   minm = "歌词 - 歌名/歌手"        (user-reported shape -> first '/' splits name/artist)
#   minm = "歌名 - 歌手"             (only trusted inside the new-track window)
#   asar = "艺人1/艺人2"             (multi-artist list, never split by '/')
function Resolve-Meta {
    param([string]$Minm, [string]$Asar, [string]$Asal, [string]$Fallback, [bool]$InWindow)
    $dash = '\s+[-–—]\s+'
    $out = @{ Song = $Fallback; Artist = $Asar; Album = $Asal; Source = 'fallback' }
    # 1) artist field carries "song — artist"
    if ($Asar -match "^(.+?)$dash(.+)$") {
        $out.Song = $Matches[1].Trim(); $out.Artist = $Matches[2].Trim(); $out.Source = 'asar'
        return $out
    }
    # 2) user's rule: "lyric - song/artist"  (first '/' after the dash splits name and artist)
    if ($Minm -match "^(.+?)$dash([^/]+)/(.+)$") {
        $out.Song = $Matches[2].Trim(); $out.Artist = $Matches[3].Trim(); $out.Source = 'minm-slash'
        return $out
    }
    # 3) "song - artist" inside the fresh-track window only (avoids lyric lines with a dash)
    if ($InWindow -and $Minm -match "^(.+?)$dash(.+)$") {
        $out.Song = $Matches[1].Trim(); $out.Artist = $Matches[2].Trim(); $out.Source = 'minm-dash'
        return $out
    }
    # 3b) dash outside the window is still safe when the RIGHT side is the asar artist: with lyrics
    #     OFF iOS sends minm="歌名 - 歌手"; with lyrics ON a lyric line's right side never equals the
    #     artist, so lyric lines still cannot be mistaken for a title.
    if ($Asar -and $Asar -notmatch $dash -and $Minm -match "^(.+?)$dash(.+)$") {
        $right = $Matches[2].Trim(); $art = $Asar.Trim()
        if ($right -eq $art -or $right.StartsWith($art)) {
            $out.Song = $Matches[1].Trim(); $out.Artist = $art; $out.Source = 'minm-dash-anchored'
            return $out
        }
    }
    # 4) fresh-track window: first metadata line is the song title
    if ($InWindow -and $Minm) { $out.Song = $Minm.Trim(); $out.Source = 'first' }
    return $out
}

function Update-Timeline([double]$pos, [double]$dur) {
    if (-not $script:smtcActive -or -not $script:smtc) { return }
    if ($NoTimeline) { return }        # publish no timeline at all => the shell has nothing to scrub
    if ($dur -le 0) { return }
    if ($pos -lt 0) { $pos = 0 }
    if ($pos -gt $dur) { $pos = $dur }
    $tl = [Windows.Media.SystemMediaTransportControlsTimelineProperties]::new()
    $tl.StartTime = [TimeSpan]::Zero
    $tl.EndTime = [TimeSpan]::FromSeconds($dur)
    $tl.Position = [TimeSpan]::FromSeconds($pos)
    # DECLARE "not seekable": iOS DACP has no seek (setproperty?dacp.playingtime returns 400), so we
    # publish an EMPTY seekable range (Min == Max == 0). Consumers then treat the bar as read-only.
    $tl.MinSeekTime = [TimeSpan]::Zero
    $tl.MaxSeekTime = [TimeSpan]::Zero
    $script:smtc.UpdateTimelineProperties($tl)
}


Log 'opening capture adapter ...'
$r = [AirPlaySniffer]::OpenWifi()
Log "capture: $r"
if (-not $r.StartsWith('OK:')) { throw "capture init failed: $r" }
Log 'listening for AirPlay RTSP (Ctrl+C to stop)'

# The process never exits on its own: its lifetime is owned externally (e.g. Taskkill).
# All this loop manages is SMTC registration/unregistration (and, while registered, the media keys).
try {
    while ($true) {
        foreach ($e in [AirPlaySniffer]::Pump($PollMs)) {
            if ([string]::IsNullOrWhiteSpace($e)) { continue }
            $p = $e.Split('|')
            switch ($p[0]) {
                'P' {
                    $v = $p[1].Split('/')
                    if ($v.Count -eq 3) {
                        $st = [double]$v[0]; $cur = [double]$v[1]; $end = [double]$v[2]
                        if ($end -gt $st) {
                            # the (start,end) RTP anchor pair identifies one track; it drifts a few frames
                            # within a track, so only a jump bigger than 1 s means a real track switch
                            $anchorJump = [math]::Abs($st - $state.Start)
                            $durJump = [math]::Abs(($end - $st) - ($state.End - $state.Start))
                            if ($state.Start -ne 0 -and ($anchorJump -gt 44100 -or $durJump -gt 44100)) {
                                Log ("track changed (anchor {0}/{1} -> {2}/{3})" -f $state.Start, $state.End, $st, $end)
                                $state.Song = ''
                                $state.NewTrackUntil = (Get-Date).AddSeconds(15)
                            }
                            $state.Start = $st; $state.End = $end
                            $state.Dur = ($end - $st) / $state.Rate
                            $state.Pos = ($cur - $st) / $state.Rate
                            $state.LastProgress = Get-Date
                            $state.LastAnchorAt = Get-Date
                            $state.HasData = $true
                            $state.SessionGoneAt = $null
                            # NOTE: playback STATE is derived from how recently the iPhone reported its
                            # timeline (see the state block below); this branch only publishes position.
                            if ($state.Dur -gt 0) {
                                Update-Timeline $state.Pos $state.Dur
                                $script:LastTimelinePush = Get-Date
                                if ($Verbose) { Log ("timeline <- real progress {0:n1}s / {1:n1}s" -f $state.Pos, $state.Dur) }
                            }
                        }
                    }
                }
                'M' {
                    $t = $p[2]; $a = $p[3]; $al = $p[4]
                    $inWindow = [bool]($state.NewTrackUntil -and (Get-Date) -lt $state.NewTrackUntil)
                    $res = Resolve-Meta -Minm $t -Asar $a -Asal $al -Fallback $state.Song -InWindow $inWindow
                    if ($res.Song -and $res.Song -ne $state.Song) {
                        $state.Song = $res.Song
                        Log ("song > {0}  |  {1}  |  {2}   [{3}]" -f $res.Song, $res.Artist, $res.Album, $res.Source)
                        $state.NewTrackUntil = $null
                    }
                    if ($res.Artist) { $state.Artist = $res.Artist }
                    if ($res.Album) { $state.Album = $res.Album }
                    if ($Verbose -and $t -and $t -ne $res.Song) { Log "lyric> $t" }
                    $title = if ($TitleMode -eq 'Lyric') { if ($t) { $t } else { $state.Song } }
                             else { if ($state.Song) { $state.Song } elseif ($t) { $t } else { '' } }
                    if ($title -and $title -ne $state.Published) {
                        $state.Published = $title
                        $state.HasData = $true
                        $state.SessionGoneAt = $null
                        $state.LastMetaAt = Get-Date
                        if ($script:smtcActive -and $script:upd) {
                            $script:upd.MusicProperties.Title = $title
                            $script:upd.MusicProperties.Artist = $state.Artist
                            $script:upd.MusicProperties.AlbumTitle = $state.Album
                            $script:upd.Update()
                            Log "SMTC title -> $title"
                        } else {
                            Log "metadata cached until the SMTC session registers: $title"
                        }
                    }
                }
                'A' {
                    $path = Join-Path $work $p[1]
                    $script:ArtPath = $path          # remember it: artwork often arrives BEFORE we register
                    if ($script:smtcActive -and $script:upd) {
                        try {
                            $ref = Set-Artwork $path
                            Log ("artwork applied ({0} bytes, thumbnailRef={1})" -f $p[2], ($null -ne $ref))
                        } catch { Log "artwork failed: $($_.Exception.Message)" }
                    } else {
                        Log ("artwork cached until the SMTC session registers ({0} bytes)" -f $p[2])
                    }
                }
                'K' {
                    $state.LastHeartbeat = Get-Date
                    $state.SessionGoneAt = $null
                    if (-not $script:SawKeepAlive) { $script:SawKeepAlive = $true; Log 'RTSP keepalive received -> parser OK' }
                }
                'T' {
                    if (-not $state.SessionGoneAt) {
                        $state.SessionGoneAt = Get-Date
                        Log 'RTSP TEARDOWN received -> sender is ending the AirPlay session'
                    }
                }
                'D' {
                    if ($p.Count -ge 3 -and $p[2]) {
                        [SmtcControl]::Token = $p[2]
                        if (-not $state.TokenSeen) {
                            $state.TokenSeen = $true
                            Log "Active-Remote token acquired from the live RTSP stream: $($p[2])"
                        }
                    }
                }
            }
        }
        # ---- lazy SMTC registration: only once the iPhone has actually told us something ----
        if (-not $script:smtcActive -and $state.HasData) {
            Start-Smtc
            if ($script:smtcActive) {
                if ($state.Published) {
                    $script:upd.MusicProperties.Title = $state.Published
                    $script:upd.MusicProperties.Artist = $state.Artist
                    $script:upd.MusicProperties.AlbumTitle = $state.Album
                    $script:upd.Update()
                }
                if ($state.Dur -gt 0) { Update-Timeline $state.Pos $state.Dur }
                # re-apply artwork that arrived before registration (iOS only sends it once per track,
                # so a dropped thumbnail would leave the shell showing the app icon for the whole track)
                if ($script:ArtPath -and (Test-Path -LiteralPath $script:ArtPath)) {
                    try {
                        $ref = Set-Artwork $script:ArtPath
                        Log ("artwork applied at registration (thumbnailRef={0})" -f ($null -ne $ref))
                    } catch { Log "artwork failed: $($_.Exception.Message)" }
                }
            }
        }

        # ---- reverse control: report what the helper did, and retry endpoint discovery if needed ----
        $ctl = [SmtcControl]::LastLog
        if ($ctl -and $ctl -ne $script:LastCtl) { $script:LastCtl = $ctl; Log "control: $ctl" }
        # a drag on the slider cannot be honoured: snap it straight back to the true position.
        # (there is no API flag to disable position control: both write-side interfaces have none,
        #  and the shell derives posControlEnabled itself, always True for interop sessions)
        if ([SmtcControl]::SeekRequested) {
            $asked = [SmtcControl]::SeekRequestedTo
            [SmtcControl]::ClearSeek()
            if ($state.Dur -gt 0) {
                $truePos = if ($state.LastProgress -and $state.Status -eq 'Playing') { $state.Pos + ((Get-Date) - $state.LastProgress).TotalSeconds } else { $state.Pos }
                Update-Timeline $truePos $state.Dur
                Log ("seek not supported: asked {0:n1}s -> snapped back to the true position {1:n1}s" -f $asked, $truePos)
            } else {
                Log ("seek not supported: asked {0:n1}s (no timeline published yet)" -f $asked)
            }
        }
        if (-not $NoControl -and -not [SmtcControl]::Host) {
            if (-not $script:LastDacpTry -or ((Get-Date) - $script:LastDacpTry).TotalSeconds -gt 20) {
                $script:LastDacpTry = Get-Date
                $d = Resolve-Dacp 5000
                if ($d) { Log "DACP endpoint (retry): '$d'" }
            }
        }

        if (-not $script:LastStat) { $script:LastStat = Get-Date }
        if (((Get-Date) - $script:LastStat).TotalSeconds -ge 20) {
            $script:LastStat = Get-Date
            Log ("stats: frames={0} tcp7000={1} audio={2}/s title='{3}' status={4} pos={5:n1}/{6:n1} smtc={7} ctl[smtc={8} sent={9} rl={10}]" -f `
                [AirPlaySniffer]::Frames, [AirPlaySniffer]::Pkts7000, [math]::Round($audioRate), $state.Published, $state.Status, $state.Pos, $state.Dur, $script:smtcActive, `
                [SmtcControl]::SmtcEvents, [SmtcControl]::Sent, [SmtcControl]::RateLimited)
        }

        # ---- playback state: the iPhone's OWN timeline reports are the primary signal ----
        # iOS simply stops sending `progress` while paused, so "no report for a while" = paused.
        # The local audio-packet rate is only consulted to VETO a false pause (capture can be wrong).
        $nowD = Get-Date
        $at = [AirPlaySniffer]::AudioPkts
        if ($at -gt 0) { $state.SawAudio = $true }
        if (-not $script:LastAudioT) {
            $script:LastAudioN = $at; $script:LastAudioT = $nowD; $script:LastAudioRate = 0; $audioRate = 0
        } else {
            $dt = ($nowD - $script:LastAudioT).TotalSeconds
            if ($dt -lt 0.25) { $audioRate = $script:LastAudioRate } else {
                $audioRate = ($at - $script:LastAudioN) / $dt
                $script:LastAudioN = $at; $script:LastAudioT = $nowD; $script:LastAudioRate = $audioRate
            }
        }
        if ($audioRate -gt 5) { $state.AudioStreak++ } else { $state.AudioStreak = 0 }
        $state.AudioOn = ($state.AudioStreak -ge 2)
        if ($state.AudioOn) { $state.HasData = $true }   # a live audio stream *is* real AirPlay data
        if ($state.HasData -or $state.AudioOn) {
            # liveness = the most recent of: progress report, metadata update, new-track anchor.
            # (with lyrics OFF iOS sends progress very rarely - every 80-125 s - so metadata/anchor
            #  arrival has to count as "the sender is alive" too, otherwise the inter-track gap
            #  flips the card to Paused for a few seconds on every song change)
            $sigAge = 9999
            foreach ($ts in @($state.LastProgress, $state.LastMetaAt, $state.LastAnchorAt)) {
                if ($ts) { $a = ($nowD - $ts).TotalSeconds; if ($a -lt $sigAge) { $sigAge = $a } }
            }
            # silence near the end of a track is still reported honestly: a real pause at the end of
            # a song is legitimate (and the next track arrives immediately anyway), so no special case
            #   liveness fresh (<=3 s) or audio flowing -> Playing
            #   liveness stale AND audio silent        -> Paused (both signals must agree)
            $want = if ($sigAge -le 3 -or $state.AudioOn) { 'Playing' } else { 'Paused' }
            if ($want -ne $state.Status) {
                $state.Status = $want
                if ($script:smtcActive -and $script:smtc) {
                    $script:smtc.PlaybackStatus = if ($want -eq 'Playing') { [Windows.Media.MediaPlaybackStatus]::Playing } else { [Windows.Media.MediaPlaybackStatus]::Paused }
                }
                Log ("state -> {0}  (liveness {1}; local audio {2:n0} pkt/s; pos {3:n1}/{4:n1})" -f $want, $(if ($sigAge -lt 9000) { "{0:n1}s ago" -f $sigAge } else { 'none yet' }), $audioRate, $state.Pos, $state.Dur)
            }
        }
        # Timeline drift guard: Windows interpolates between the real pushes.
        if ($state.Status -eq 'Playing' -and $state.Dur -gt 0 -and $state.LastProgress) {
            if (-not $script:LastTimelinePush -or ($nowD - $script:LastTimelinePush).TotalSeconds -ge 12) {
                $script:LastTimelinePush = $nowD
                Update-Timeline ($state.Pos + ($nowD - $state.LastProgress).TotalSeconds) $state.Dur
                if ($Verbose) { Log 'timeline refresh (drift guard)' }
            }
        }
        # ---- AirPlay session gone? unregister the card and forget the per-session state ----
        # three independent hints, all resolved within DisconnectSec (default 5 s):
        #   * no RTSP keepalive (iOS sends one every ~2 s)
        #   * a TEARDOWN request
        #   * FIN/RST observed on the control connection
        $kaAge = if ($state.LastHeartbeat) { ($nowD - $state.LastHeartbeat).TotalSeconds } else { 9999 }
        if ([AirPlaySniffer]::ConnClosed) {
            [AirPlaySniffer]::ClearConnClosed()
            if (-not $state.SessionGoneAt) { $state.SessionGoneAt = $nowD; Log 'control connection closed (FIN/RST) -> AirPlay session ending' }
        }
        $kaGone = [bool]($state.LastHeartbeat -and (($nowD - $state.LastHeartbeat).TotalSeconds -gt $DisconnectSec))
        $gone = [bool]($state.SessionGoneAt -and (($nowD - $state.SessionGoneAt).TotalSeconds -gt $DisconnectSec))
        if ($state.HasData -and ($kaGone -or $gone)) {
            $kaAge = if ($state.LastHeartbeat) { ($nowD - $state.LastHeartbeat).TotalSeconds } else { -1 }
            Log ("AirPlay session gone (keepalive {0}, disconnect hint {1}) -> unregistering SMTC" -f $(if ($kaAge -ge 0) { "{0:n1}s ago" -f $kaAge } else { 'never seen' }), $(if ($state.SessionGoneAt) { 'yes' } else { 'no' }))
            Stop-Smtc
            $state.Published = ''; $state.Song = ''; $state.Artist = ''; $state.Album = ''
            $state.Pos = 0; $state.Dur = 0; $state.LastProgress = $null; $state.Start = 0; $state.End = 0
            $state.HasData = $false; $state.Status = 'Paused'; $state.TokenSeen = $false
            $state.AudioOn = $false; $state.AudioStreak = 0; $state.SawAudio = $false
            $state.LastHeartbeat = $null; $state.SessionGoneAt = $null
        }
    }
} finally {
    [AirPlaySniffer]::Close()
    Stop-Smtc
    Log 'stopped'
}
