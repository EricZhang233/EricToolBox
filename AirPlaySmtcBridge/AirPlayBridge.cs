// AirPlayBridge.exe — no-GUI background bridge: AirPlay (RAOP/RTSP over TCP 7000) -> Windows SMTC.
// Compiled with PowerShell's bundled Roslyn (no .NET SDK needed), runs on the installed .NET runtime.
// Being an unpackaged process, SetCurrentProcessExplicitAppUserModelID works, so the shell shows
// OUR name/logo instead of PowerShell's.
//
// Usage: AirPlayBridge.exe [--no-control] [--no-timeline] [--disconnect-sec N] [--poll-ms N] [--verbose]
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Text;
using System.Threading;
using Microsoft.Win32;
using Windows.Foundation;
using Windows.Media;
using Windows.Storage;
using Windows.Storage.Streams;

// csc derives the Win32 version resource from these assembly attributes; the shell reads
// FileDescription/ProductName from it for unpackaged apps (without them the media card says
// "unknown app"). In an SDK-style project these come from the project file instead, so they are
// compiled only for the classic csc build to avoid duplicate-attribute errors.
#if NETFRAMEWORK
[assembly: System.Reflection.AssemblyTitle("AirPlaySmtcBridge.eric.app")]
[assembly: System.Reflection.AssemblyProduct("AirPlaySmtcBridge.eric.app")]
[assembly: System.Reflection.AssemblyCompany("eric")]
[assembly: System.Reflection.AssemblyDescription("AirPlaySmtcBridge.eric.app")]
[assembly: System.Reflection.AssemblyCopyright("eric")]
[assembly: System.Reflection.AssemblyFileVersion("1.0.0.0")]
[assembly: System.Reflection.AssemblyVersion("1.0.0.0")]
#endif

#if NETFRAMEWORK
// .NET Framework's winmd projection does not expose SystemMediaTransportControlsInterop, so the
// interop interface is declared by hand (GUID + method shape taken from the SDK projection).
[ComImport, Guid("DDB0472D-C911-4A1F-86D9-DC3D71A95F5A"), InterfaceType(ComInterfaceType.InterfaceIsIInspectable)]
interface ISystemMediaTransportControlsInterop
{
    [return: MarshalAs(UnmanagedType.IInspectable)]
    object GetForWindow([In] IntPtr appWindow, [In] ref Guid riid);
}
#endif

// ---- Shell shortcut helpers: a Start Menu shortcut carrying System.AppUserModel.ID is how a
// ---- desktop (unpackaged) app gets its identity in the shell's app resolver, which is what the
// ---- media card uses to show the friendly app name + icon (otherwise it prints the raw AUMID).
[ComImport, Guid("00021401-0000-0000-C000-000000000046")] class ShellLinkCoClass { }
[ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IShellLinkW
{
    void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszFile, int cch, IntPtr pfd, uint fFlags);
    void GetIDList(out IntPtr ppidl);
    void SetIDList(IntPtr pidl);
    void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszName, int cch);
    void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string pszName);
    void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszDir, int cch);
    void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string pszDir);
    void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszArgs, int cch);
    void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string pszArgs);
    void GetHotkey(out short pwHotkey);
    void SetHotkey(short wHotkey);
    void GetShowCmd(out int piShowCmd);
    void SetShowCmd(int iShowCmd);
    void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszIconPath, int cch, out int piIcon);
    void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string pszIconPath, int iIcon);
    void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string pszPathRel, uint dwReserved);
    void Resolve(IntPtr hwnd, uint fFlags);
    void SetPath([MarshalAs(UnmanagedType.LPWStr)] string pszFile);
}
[ComImport, Guid("0000010b-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IPersistFile
{
    void GetClassID(out Guid pClassID);
    void IsDirty();
    void Load([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, uint dwMode);
    void Save([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, bool fRemember);
    void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string pszFileName);
    void GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string ppszFileName);
}
[StructLayout(LayoutKind.Sequential, Pack = 4)]
struct PropertyKey
{
    public Guid fmtid; public uint pid;
    public PropertyKey(Guid f, uint p) { fmtid = f; pid = p; }
}
[StructLayout(LayoutKind.Explicit)]
struct PropVariant
{
    [FieldOffset(0)] public ushort vt;
    [FieldOffset(8)] public IntPtr pointerValue;
}
[ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IPropertyStore
{
    void GetCount(out uint cProps);
    void GetAt(uint iProp, out PropertyKey pkey);
    void GetValue(ref PropertyKey key, out PropVariant pv);
    void SetValue(ref PropertyKey key, ref PropVariant pv);
    void Commit();
}

public static class Program
{
    // ------------------------------------------------------------------ config
    const string Aumid = "AirPlaySmtcBridge";        // global identity (was eric.AirPlayBridge.app)
    const string AppName = "AirPlay";                // bare name shown on the media card
    const string ShortcutName = "AirPlaySmtcBridge"; // Start Menu shortcut file name
    const int PollMs = 150;
    const int DisconnectSec = 5;
    const int DriftGuardSec = 12;

    public static bool NoControl, NoTimeline, Verbose;
    public static int DisconnectSecCfg = DisconnectSec;
    const string StopEventName = "Global\\AirPlaySmtcBridge.Stop";
    const string MutexName = "Global\\AirPlaySmtcBridge";
    static Mutex mutex;
    static readonly string[] LegacyAumids = { "Clawrin.AirPlayBridge", "eric.AirPlayBridge.app" };
    static EventWaitHandle stopEvent;

    static readonly string Work = Path.Combine(Path.GetTempPath(), "eric", "AirPlayBridge");
    static readonly string ArtFile = Path.Combine(Work, "artwork.jpg");
    static readonly string LogFile = Path.Combine(Work, "AirPlayBridge.log");

    // ------------------------------------------------------------------ logging
    static readonly object LogLock = new object();
    public static void Log(string msg)
    {
        lock (LogLock)
        {
            try
            {
                Directory.CreateDirectory(Work);
                var fi = new FileInfo(LogFile);
                if (fi.Exists && fi.Length > 4 * 1024 * 1024) File.Delete(LogFile);
                File.AppendAllText(LogFile, "[" + DateTime.Now.ToString("HH:mm:ss") + "] " + msg + "\r\n", Encoding.UTF8);
            }
            catch { }
            if (Verbose) { try { Console.Error.WriteLine(msg); } catch { } }
        }
    }

    // ------------------------------------------------------------------ Win32
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateWindowExW(uint ex, string cls, string name, uint style,
        int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr h);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern int SetCurrentProcessExplicitAppUserModelID(string id);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vKey);

    // ---- simple dialogs (no WinForms dependency); the app is a GUI-subsystem process already
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);
    const uint MB_OK = 0x0, MB_YESNO = 0x4, MB_ICONERROR = 0x10, MB_ICONINFORMATION = 0x40,
               MB_ICONWARNING = 0x30, MB_TOPMOST = 0x40000, MB_SETFOREGROUND = 0x10000;
    static bool DialogsDisabled;

    static void InfoBox(string text, string caption)
    {
        if (DialogsDisabled) { Log("[" + caption + "] " + text.Replace("\r\n", " ")); return; }
        MessageBoxW(IntPtr.Zero, text, caption, MB_OK | MB_ICONINFORMATION | MB_TOPMOST | MB_SETFOREGROUND);
    }

    static bool YesNoBox(string text, string caption)
    {
        if (DialogsDisabled) { Log("(dialogs disabled -> continuing) " + caption); return true; }
        return MessageBoxW(IntPtr.Zero, text, caption, MB_YESNO | MB_ICONINFORMATION | MB_TOPMOST | MB_SETFOREGROUND) == 6;
    }

    // A real window class with OUR icon and a title: the shell falls back to the window icon/title
    // when it cannot resolve the AppUserModelID, and a system "STATIC" window has neither.
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WNDCLASSEX
    {
        public uint cbSize; public uint style; public IntPtr lpfnWndProc;
        public int cbClsExtra; public int cbWndExtra; public IntPtr hInstance;
        public IntPtr hIcon; public IntPtr hCursor; public IntPtr hbrBackground;
        public string lpszMenuName; public string lpszClassName; public IntPtr hIconSm;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern ushort RegisterClassExW(ref WNDCLASSEX wc);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr DefWindowProcW(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr GetModuleHandleW(string name);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr LoadIconW(IntPtr hInstance, IntPtr name);

    delegate IntPtr WndProcDelegate(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    static WndProcDelegate wndProcKeepAlive;
    const string WindowClass = "AirPlayBridgeWnd";

    static void EnsureWindowClass()
    {
        var wc = new WNDCLASSEX();
        wc.cbSize = (uint)Marshal.SizeOf(typeof(WNDCLASSEX));
        wc.lpfnWndProc = Marshal.GetFunctionPointerForDelegate(wndProcKeepAlive);
        wc.hInstance = GetModuleHandleW(null);
        wc.hIcon = LoadIconW(wc.hInstance, (IntPtr)32512);      // icon embedded by /win32icon
        wc.hIconSm = wc.hIcon;
        wc.lpszClassName = WindowClass;
        RegisterClassExW(ref wc);                               // 0 = already registered, fine
    }

#if NETFRAMEWORK
    static readonly Guid SmtcIid = new Guid("99FA3FF4-1742-42A6-902E-087D41F965EC");   // ISystemMediaTransportControls

    /// <summary>Win32 host -> SMTC for the given window, via the hand-declared interop interface.</summary>
    static SystemMediaTransportControls GetSmtc(IntPtr h)
    {
        var interop = (ISystemMediaTransportControlsInterop)(object)
            WindowsRuntimeMarshal.GetActivationFactory(typeof(SystemMediaTransportControls));
        var iid = SmtcIid;
        return (SystemMediaTransportControls)interop.GetForWindow(h, ref iid);
    }
#endif

    // ------------------------------------------------------------------ state
    class State
    {
        public double Pos, Dur;
        public DateTime LastProgress, LastMetaAt, LastAnchorAt, LastHeartbeat, SessionGoneAt;
        public bool HasProgress, HasHeartbeat, HasSessionGone;
        public string Published = "", Song = "", Artist = "", Album = "";
        public double Start, End;
        public DateTime NewTrackUntil; public bool HasNewTrackWindow;
        public bool HasData, AudioOn;
        public bool SawAudio;
        public bool LoggedWaiting;
        public string Status = "Paused";
        public bool TokenSeen;
        public double Rate = 44100.0;
    }

    static readonly State St = new State();
    static readonly object StLock = new object();

    // ------------------------------------------------------------------ capture (Npcap Packet.dll)
    class Sniffer
    {
        [StructLayout(LayoutKind.Sequential)]
        public struct OVERLAPPED_ENTRY { public IntPtr Internal, InternalHigh, Pointer, hEvent; }
        [StructLayout(LayoutKind.Sequential)]
        public struct PACKET
        {
            public IntPtr hEvent;
            public OVERLAPPED_ENTRY Overlapped;
            public IntPtr Buffer;
            public uint Length;
            public uint BytesReceived;
            public byte IoComplete;
        }

        [DllImport("Packet.dll", CharSet = CharSet.Ansi)]
        static extern bool PacketGetAdapterNames(byte[] names, ref uint size);
        [DllImport("Packet.dll", CharSet = CharSet.Ansi)]
        static extern IntPtr PacketOpenAdapter(string name);
        [DllImport("Packet.dll")] static extern bool PacketCloseAdapter(IntPtr a);
        [DllImport("Packet.dll")] static extern bool PacketSetHwFilter(IntPtr a, uint f);
        [DllImport("Packet.dll")] static extern bool PacketSetBuff(IntPtr a, int size);
        [DllImport("Packet.dll")] static extern bool PacketSetReadTimeout(IntPtr a, int ms);
        [DllImport("Packet.dll")] static extern bool PacketSetMinToCopy(IntPtr a, int n);
        [DllImport("Packet.dll")] static extern IntPtr PacketAllocatePacket();
        [DllImport("Packet.dll")] static extern bool PacketInitPacket(IntPtr p, IntPtr buf, uint len);
        [DllImport("Packet.dll")] static extern bool PacketReceivePacket(IntPtr a, IntPtr p, bool sync);
        [DllImport("Packet.dll")] static extern bool PacketFreePacket(IntPtr p);

        IntPtr ad = IntPtr.Zero, pkt = IntPtr.Zero, mem = IntPtr.Zero;
        const int MemSize = 2 * 1024 * 1024;

        public long Frames, Pkts7000, AudioPkts;
        public volatile bool ConnClosed;
        public volatile string PeerMac = "";
        public volatile string PeerV6 = "";
        public volatile string PeerV4 = "";

        readonly List<byte> d0 = new List<byte>();   // client -> receiver
        readonly List<byte> d1 = new List<byte>();   // receiver -> client
        int c0, c1;
        static readonly byte[][] Markers = new byte[][] {
            Encoding.ASCII.GetBytes("OPTIONS "), Encoding.ASCII.GetBytes("SET_PARAMETER "),
            Encoding.ASCII.GetBytes("TEARDOWN "), Encoding.ASCII.GetBytes("FLUSH "),
            Encoding.ASCII.GetBytes("ANNOUNCE "), Encoding.ASCII.GetBytes("SETUP "),
            Encoding.ASCII.GetBytes("RECORD "), Encoding.ASCII.GetBytes("GET_PARAMETER "),
            Encoding.ASCII.GetBytes("POST "), Encoding.ASCII.GetBytes("GET ")
        };

        public string Open()
        {
            var buf = new byte[65536]; uint sz = 65536;
            if (!PacketGetAdapterNames(buf, ref sz)) return "adapter list failed";
            var text = Encoding.ASCII.GetString(buf, 0, (int)sz);
            var parts = text.Split('\0');
            int blank = Array.IndexOf(parts, "");
            if (blank < 0) blank = parts.Length;
            string pick = null;
            for (int i = 0; i < blank; i++)
            {
                string desc = (blank + 1 + i) < parts.Length ? parts[blank + 1 + i] : "";
                string d = desc.ToLowerInvariant();
                if (d.Contains("wi-fi") || d.Contains("wifi") || d.Contains("wlan") || d.Contains("wireless"))
                { pick = parts[i]; break; }
            }
            if (pick == null) return "no wireless adapter found";
            ad = PacketOpenAdapter(pick);
            if (ad == IntPtr.Zero || ad == (IntPtr)(-1)) return "PacketOpenAdapter failed";
            PacketSetHwFilter(ad, 0x002F);
            PacketSetBuff(ad, 8 * 1024 * 1024);
            PacketSetReadTimeout(ad, 100);
            PacketSetMinToCopy(ad, 0);
            pkt = PacketAllocatePacket();
            mem = Marshal.AllocHGlobal(MemSize);
            PacketInitPacket(pkt, mem, MemSize);
            return "OK: " + pick;
        }

        public void Close()
        {
            try { if (pkt != IntPtr.Zero) PacketFreePacket(pkt); } catch { }
            try { if (mem != IntPtr.Zero) Marshal.FreeHGlobal(mem); } catch { }
            try { if (ad != IntPtr.Zero) PacketCloseAdapter(ad); } catch { }
            pkt = IntPtr.Zero; mem = IntPtr.Zero; ad = IntPtr.Zero;
        }

        static ushort U16(byte[] b, int o) { return (ushort)((b[o] << 8) | b[o + 1]); }
        static uint U32(byte[] b, int o) { return (uint)((b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]); }

        /// <summary>Receive for up to timeoutMs and parse; returns the list of protocol events.</summary>
        public List<string> Pump(int timeoutMs)
        {
            var events = new List<string>();
            var sw = Stopwatch.StartNew();
            while (sw.ElapsedMilliseconds < timeoutMs)
            {
                if (PacketReceivePacket(ad, pkt, true) == false) continue;   // returns 1-byte BOOLEAN
                var p = (PACKET)Marshal.PtrToStructure(pkt, typeof(PACKET));
                uint n = p.BytesReceived;
                if (n == 0) continue;
                var raw = new byte[n];
                Marshal.Copy(mem, raw, 0, (int)n);
                int off = 0;
                while (off + 20 <= n)
                {
                    int caplen = (raw[off + 8]) | (raw[off + 9] << 8) | (raw[off + 10] << 16) | (raw[off + 11] << 24);
                    if (caplen <= 0 || caplen > 65535 || off + 20 + caplen > n) break;
                    Frames++;
                    Feed(raw, off + 20, caplen, events);
                    off += ((20 + caplen) + 3) & ~3;
                }
            }
            return events;
        }

        void Feed(byte[] f, int baseOff, int len, List<string> events)
        {
            if (len < 34) return;
            int etherType = U16(f, baseOff + 12);
            int off = baseOff + 14;
            while ((etherType == 0x8100 || etherType == 0x88A8) && off + 4 <= baseOff + len)
            { etherType = U16(f, off + 2); off += 4; }

            if (etherType == 0x0800)
            {
                if (off + 20 > baseOff + len) return;
                int ihl = (f[off] & 0x0f) * 4;
                if (ihl < 20) return;
                int proto = f[off + 9];
                int tot = U16(f, off + 2);
                string src = f[off + 12] + "." + f[off + 13] + "." + f[off + 14] + "." + f[off + 15];
                string dst = f[off + 16] + "." + f[off + 17] + "." + f[off + 18] + "." + f[off + 19];
                int l4 = off + ihl;
                int payloadLen = tot - ihl;
                HandleL4(f, baseOff, len, l4, proto, payloadLen, src, dst, false, events);
            }
            else if (etherType == 0x86DD)
            {
                if (off + 40 > baseOff + len) return;
                int proto = f[off + 6];
                int payloadLen = U16(f, off + 4);
                var sb = new StringBuilder();
                for (int i = 0; i < 16; i += 2) { if (i > 0) sb.Append(':'); sb.Append(f[off + 8 + i].ToString("x2")).Append(f[off + 9 + i].ToString("x2")); }
                string src = sb.ToString();
                sb.Length = 0;
                for (int i = 0; i < 16; i += 2) { if (i > 0) sb.Append(':'); sb.Append(f[off + 24 + i].ToString("x2")).Append(f[off + 25 + i].ToString("x2")); }
                string dst = sb.ToString();
                HandleL4(f, baseOff, len, off + 40, proto, payloadLen, src, dst, true, events);
            }
        }

        void HandleL4(byte[] f, int baseOff, int len, int l4, int proto, int payloadLen, string src, string dst, bool v6, List<string> events)
        {
            if (proto == 17)   // UDP: the audio stream is the large-payload traffic on 6000-6200
            {
                if (l4 + 8 > baseOff + len) return;
                int sp = U16(f, l4), dp = U16(f, l4 + 2);
                int payload = payloadLen - 8;
                if (((sp >= 6000 && sp <= 6200) || (dp >= 6000 && dp <= 6200)) && payload >= 500) AudioPkts++;
                return;
            }
            if (proto != 6) return;
            if (l4 + 20 > baseOff + len) return;
            int sport = U16(f, l4), dport = U16(f, l4 + 2);
            int doff = (f[l4 + 12] >> 4) * 4;
            int flags = f[l4 + 13];
            if ((dport == 7000 || sport == 7000) && ((flags & 0x01) != 0 || (flags & 0x04) != 0)) ConnClosed = true;
            int payOff = l4 + doff;
            int payLen = (baseOff + len) - payOff;
            if (payLen <= 0) return;
            if (dport == 7000)
            {
                Pkts7000++;
                if (len >= 12)
                {
                    var sb = new StringBuilder(17);
                    for (int k = 6; k < 12; k++) { if (k > 6) sb.Append('-'); sb.Append(f[baseOff + k].ToString("X2")); }
                    PeerMac = sb.ToString();
                }
                if (v6) PeerV6 = src; else PeerV4 = src;
                Append(d0, ref c0, f, payOff, payLen);
                Parse(d0, ref c0, events);
            }
            else if (sport == 7000)
            {
                Pkts7000++;
                if (v6) PeerV6 = dst; else PeerV4 = dst;
                Append(d1, ref c1, f, payOff, payLen);
            }
        }

        static void Append(List<byte> dst, ref int cursor, byte[] src, int off, int len)
        {
            if (cursor > 65536) { dst.RemoveRange(0, cursor); cursor = 0; }
            for (int i = 0; i < len; i++) dst.Add(src[off + i]);
        }

        void Parse(List<byte> buf, ref int cursor, List<string> events)
        {
            while (true)
            {
                int best = -1; int bestMarker = -1;
                for (int i = cursor; i < buf.Count; i++)
                {
                    for (int m = 0; m < Markers.Length; m++)
                    {
                        var mk = Markers[m];
                        if (i + mk.Length > buf.Count) continue;
                        bool ok = true;
                        for (int k = 0; k < mk.Length; k++) if (buf[i + k] != mk[k]) { ok = false; break; }
                        if (ok) { best = i; bestMarker = m; break; }
                    }
                    if (best >= 0) break;
                }
                if (best < 0)
                {
                    // keep a tail in case a message straddles packets
                    if (cursor > 0 && buf.Count - cursor < 8192) break;
                    if (buf.Count > 8192) { buf.RemoveRange(0, buf.Count - 8192); cursor = 0; }
                    break;
                }
                if (best > cursor) cursor = best;
                int headEnd = -1;
                for (int i = cursor; i + 3 < buf.Count; i++)
                    if (buf[i] == 13 && buf[i + 1] == 10 && buf[i + 2] == 13 && buf[i + 3] == 10) { headEnd = i; break; }
                if (headEnd < 0) break;                       // headers not complete yet
                string head = Encoding.ASCII.GetString(buf.ToArray(), cursor, headEnd - cursor);
                int contentLength = 0;
                foreach (var line in head.Split(new[] { "\r\n" }, StringSplitOptions.None))
                {
                    int c = line.IndexOf(':');
                    if (c <= 0) continue;
                    if (line.Substring(0, c).Trim().Equals("Content-Length", StringComparison.OrdinalIgnoreCase))
                        int.TryParse(line.Substring(c + 1).Trim(), out contentLength);
                }
                int bodyStart = headEnd + 4;
                if (bodyStart + contentLength > buf.Count) break;   // body not complete yet
                string ev = Handle(buf, bodyStart, contentLength, head);
                if (ev != null && ev.Length > 0) events.Add(ev);
                cursor = bodyStart + contentLength;
                if (cursor > 65536) { buf.RemoveRange(0, cursor); cursor = 0; }
            }
        }

        static string Field(string head, string name)
        {
            foreach (var line in head.Split(new[] { "\r\n" }, StringSplitOptions.None))
            {
                int c = line.IndexOf(':');
                if (c <= 0) continue;
                if (line.Substring(0, c).Trim().Equals(name, StringComparison.OrdinalIgnoreCase))
                    return line.Substring(c + 1).Trim();
            }
            return "";
        }

        static string Handle(List<byte> buf, int cs, int cl, string head)
        {
            var arr = buf.ToArray();
            string ct = Field(head, "Content-Type");
            var o = new StringBuilder();
            // DACP credentials ride on every request (incl. OPTIONS keepalives)
            string dacpId = Field(head, "DACP-ID"), activeR = Field(head, "Active-Remote");
            if (dacpId.Length > 0) o.Append("D|").Append(dacpId).Append('|').Append(activeR).Append('\n');
            if (ct.StartsWith("text/parameters"))
            {
                string body = Encoding.ASCII.GetString(arr, cs, cl);
                int pi = body.IndexOf("progress:");
                if (pi >= 0) o.Append("P|").Append(body.Substring(pi + 9).Trim()).Append('\n');
            }
            else if (ct.StartsWith("application/x-dmap-tagged"))
            {
                string minm = DmapField(arr, cs, cl, "minm");
                string asar = DmapField(arr, cs, cl, "asar");
                string asal = DmapField(arr, cs, cl, "asal");
                if (minm.Length == 0 && asar.Length == 0 && asal.Length == 0) return o.ToString();
                o.Append("M|").Append(Clean(minm)).Append('|').Append(Clean(asar)).Append('|').Append(Clean(asal)).Append('\n');
            }
            else if (ct.StartsWith("image/jpeg"))
            {
                try
                {
                    Directory.CreateDirectory(Work);
                    var body = new byte[cl];
                    Array.Copy(arr, cs, body, 0, cl);
                    File.WriteAllBytes(ArtFile, body);
                    o.Append("A|artwork.jpg|").Append(cl).Append('\n');
                }
                catch (Exception ex) { Log("artwork write failed: " + ex.Message); }
            }
            else if (ct.Length == 0 && head.StartsWith("OPTIONS")) o.Append("K|\n");
            else if (ct.Length == 0 && head.StartsWith("TEARDOWN")) o.Append("T|\n");
            return o.ToString();
        }

        static string Clean(string s) { return s.Replace("|", "/").Replace("\n", " ").Replace("\r", " "); }

        static string DmapField(byte[] b, int start, int len, string key)
        {
            var kb = Encoding.ASCII.GetBytes(key);
            int end = start + len;
            for (int i = start; i + 8 <= end; i++)
            {
                if (b[i] != kb[0] || b[i + 1] != kb[1] || b[i + 2] != kb[2] || b[i + 3] != kb[3]) continue;
                long ln = U32(b, i + 4);
                if (ln <= 0 || ln > 4096 || i + 8 + ln > end) continue;
                return Encoding.UTF8.GetString(b, i + 8, (int)ln).Trim();
            }
            return "";
        }
    }

    // ------------------------------------------------------------------ metadata rules
    // asar = "song — artist" | minm = "lyric - song/artist" | minm = "song - artist" (window) |
    // minm = "song" (lyrics off, iOS sends a clean title) | asar = "artist1/artist2" (never split)
    static readonly System.Text.RegularExpressions.Regex DashRe =
        new System.Text.RegularExpressions.Regex(@"^(.+?)\s+[-–—]\s+(.+)$");

    class Meta { public string Song = "", Artist = "", Album = "", Source = "fallback"; }

    static Meta ResolveMeta(string minm, string asar, string asal, string fallback, bool inWindow)
    {
        var m = new Meta();
        m.Song = fallback; m.Artist = asar; m.Album = asal;
        var dash = new System.Text.RegularExpressions.Regex(@"\s+[-–—]\s+");
        if (!string.IsNullOrEmpty(asar) && dash.IsMatch(asar))
        {
            var g = dash.Split(asar, 2);
            m.Song = g[0].Trim(); m.Artist = g[1].Trim(); m.Source = "asar"; return m;
        }
        if (!string.IsNullOrEmpty(minm))
        {
            var mm = System.Text.RegularExpressions.Regex.Match(minm, @"^(.+?)\s+[-–—]\s+([^/]+)/(.+)$");
            if (mm.Success) { m.Song = mm.Groups[2].Value.Trim(); m.Artist = mm.Groups[3].Value.Trim(); m.Source = "minm-slash"; return m; }
            if (inWindow)
            {
                var md = DashRe.Match(minm);
                if (md.Success) { m.Song = md.Groups[1].Value.Trim(); m.Artist = md.Groups[2].Value.Trim(); m.Source = "minm-dash"; return m; }
                if (minm.Trim().Length > 0) { m.Song = minm.Trim(); m.Source = "first"; return m; }
            }
            // lyrics OFF: "song - artist" outside the window is safe when the right side IS the artist
            if (!string.IsNullOrEmpty(asar) && !dash.IsMatch(asar))
            {
                var md2 = DashRe.Match(minm);
                if (md2.Success)
                {
                    string right = md2.Groups[2].Value.Trim(); string art = asar.Trim();
                    if (right == art || right.StartsWith(art))
                    { m.Song = md2.Groups[1].Value.Trim(); m.Artist = art; m.Source = "minm-dash-anchored"; return m; }
                }
            }
        }
        return m;
    }

    // ------------------------------------------------------------------ DACP reverse control
    static class Dacp
    {
        public static volatile bool Enabled = true;
        public static volatile string Token = "";
        public static volatile string Host = "";
        public static volatile int Port = 0;
        public static int Sent, RateLimited, SmtcEvents, KbEvents;
        public static string LastLog = "";
        static DateTime lastSend = DateTime.MinValue;
        static readonly object SendLock = new object();

        public static string Send(string cmd, string src)
        {
            string msg = SendCore(cmd, src);
            if (!string.IsNullOrEmpty(msg)) { LastLog = msg; Log("control: " + msg); }   // log both paths, not just the last writer
            return msg;
        }

        static string SendCore(string cmd, string src)
        {
            if (cmd == null) { LastLog = Stamp() + " unmapped button"; return ""; }
            if (!Enabled) { LastLog = Stamp() + " " + cmd + " skipped (--no-control)"; return ""; }
            string tok = Token, host = Host; int port = Port;
            if (string.IsNullOrEmpty(tok) || string.IsNullOrEmpty(host) || port == 0)
            { LastLog = Stamp() + " [" + src + "] " + cmd + " skipped (no Active-Remote/host yet)"; return ""; }
            lock (SendLock)
            {
                if ((DateTime.UtcNow - lastSend).TotalMilliseconds < 800)
                { RateLimited++; LastLog = Stamp() + " " + cmd + " rate-limited (dedupe)"; return ""; }
                lastSend = DateTime.UtcNow;
                try
                {
                    IPAddress addr;
                    if (!IPAddress.TryParse(host, out addr))
                    { LastLog = Stamp() + " " + cmd + " bad host '" + host + "'"; return ""; }
                    using (var c = new TcpClient(addr.AddressFamily))
                    {
                        var ar = c.BeginConnect(addr, port, null, null);
                        if (!ar.AsyncWaitHandle.WaitOne(1500)) { LastLog = Stamp() + " " + cmd + " connect timeout"; return ""; }
                        c.EndConnect(ar);
                        string req = "GET /ctrl-int/1/" + cmd + " HTTP/1.1\r\nHost: " + host + ":" + port +
                                     "\r\nActive-Remote: " + tok + "\r\n\r\n";
                        var bytes = Encoding.ASCII.GetBytes(req);
                        var st = c.GetStream();
                        st.Write(bytes, 0, bytes.Length); st.Flush();
                        var buf = new byte[256]; int n = 0;
                        try { st.ReadTimeout = 1500; n = st.Read(buf, 0, 256); } catch { }
                        string status = n > 0 ? Encoding.ASCII.GetString(buf, 0, n).Split('\r')[0].Trim() : "(no response)";
                        Sent++;
                        if (cmd == "play" || cmd == "playresume") St.Status = "Playing";
                        else if (cmd == "pause" || cmd == "stop") St.Status = "Paused";
                        else if (cmd == "playpause") St.Status = (St.Status == "Playing") ? "Paused" : "Playing";
                        LastLog = Stamp() + " [" + src + "] -> " + cmd + " : " + status;
                    }
                }
                catch (Exception ex) { LastLog = Stamp() + " [" + src + "] -> " + cmd + " EXC " + ex.Message; }
                return LastLog;
            }
        }
        static string Stamp() { return DateTime.Now.ToString("HH:mm:ss"); }

        // ---- mDNS: multicast query, then unicast to candidates we already know
        public static string Resolve(int timeoutMs)
        {
            try
            {
                var q = BuildQuery();
                var want = new[] { "_dacp._tcp.local" };
                var candidates = new List<IPAddress>();
                int port = 0; string ip = "";
                // 1) multicast (v4 + v6)
                foreach (var target in new[] { new IPEndPoint(IPAddress.Parse("224.0.0.251"), 5353), new IPEndPoint(IPAddress.Parse("ff02::fb"), 5353) })
                {
                    try
                    {
                        using (var u = new UdpClient(target.AddressFamily))
                        {
                            u.Client.ReceiveTimeout = 900;
                            u.Send(q, q.Length, target);
                            var end = DateTime.UtcNow.AddMilliseconds(timeoutMs / 2);
                            while (DateTime.UtcNow < end)
                            {
                                IPEndPoint ep = null;
                                byte[] r;
                                try { r = u.Receive(ref ep); } catch { break; }
                                ParseMdns(r, ref port, ref ip, candidates);
                            }
                        }
                    }
                    catch { }
                }
                // 2) unicast to anything we learned (or the peer address the sniffer saw)
                foreach (var cand in CandidateList(candidates))
                {
                    if (port != 0) break;
                    try
                    {
                        using (var u = new UdpClient(cand.AddressFamily))
                        {
                            u.Client.ReceiveTimeout = 900;
                            u.Send(q, q.Length, new IPEndPoint(cand, 5353));
                            var end = DateTime.UtcNow.AddMilliseconds(1200);
                            while (DateTime.UtcNow < end)
                            {
                                IPEndPoint ep = null; byte[] r;
                                try { r = u.Receive(ref ep); } catch { break; }
                                ParseMdns(r, ref port, ref ip, candidates);
                            }
                        }
                    }
                    catch { }
                }
                if (port != 0)
                {
                    Port = port;
                    if (ip.Length > 0) Host = Scopeify(ip);
                    if (string.IsNullOrEmpty(Host)) return "";
                    return Host + ":" + Port;
                }
                return "";
            }
            catch (Exception ex) { return "EXC " + ex.Message; }
        }

        /// <summary>IPv6 link-local targets need a scope id ("%12") or the connect fails.</summary>
        static string Scopeify(string host)
        {
            if (host.IndexOf(':') < 0) return host;            // IPv4
            if (host.IndexOf('%') >= 0) return host;           // already scoped
            if (!host.StartsWith("fe80", StringComparison.OrdinalIgnoreCase)) return host;
            int idx = WifiIndex();
            return idx > 0 ? host + "%" + idx : host;
        }

        static int WifiIndex()
        {
            try
            {
                foreach (var ni in System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces())
                {
                    if (ni.NetworkInterfaceType != System.Net.NetworkInformation.NetworkInterfaceType.Wireless80211) continue;
                    if (ni.OperationalStatus != System.Net.NetworkInformation.OperationalStatus.Up) continue;
                    var props = ni.GetIPProperties();
                    if (props == null) continue;
                    var v4 = props.GetIPv4Properties();
                    if (v4 != null) return v4.Index;
                }
            }
            catch { }
            return 0;
        }

        static IEnumerable<IPAddress> CandidateList(List<IPAddress> seen)        {
            var list = new List<IPAddress>();
            foreach (var a in seen) if (!list.Contains(a)) list.Add(a);
            var v6 = SnifferRef != null ? SnifferRef.PeerV6 : "";
            var v4 = SnifferRef != null ? SnifferRef.PeerV4 : "";
            if (!string.IsNullOrEmpty(v4)) { try { var a = IPAddress.Parse(v4); if (!list.Contains(a)) list.Add(a); } catch { } }
            if (!string.IsNullOrEmpty(v6)) { try { var a = IPAddress.Parse(v6); if (!list.Contains(a)) list.Add(a); } catch { } }
            return list;
        }

        static byte[] BuildQuery()
        {
            var ms = new MemoryStream();
            var w = new BinaryWriter(ms);
            w.Write(new byte[] { 0x12, 0x35, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 });
            foreach (var part in "_dacp._tcp.local".Split('.'))
            { w.Write((byte)part.Length); w.Write(Encoding.ASCII.GetBytes(part)); }
            w.Write((byte)0); w.Write((byte)0); w.Write((byte)12); w.Write((byte)0); w.Write((byte)1);
            return ms.ToArray();
        }

        static string ReadName(byte[] d, ref int off)
        {
            var sb = new StringBuilder();
            int guard = 0;
            while (off < d.Length && guard++ < 128)
            {
                int len = d[off++];
                if (len == 0) break;
                if ((len & 0xC0) == 0xC0) { if (off < d.Length) off++; break; }
                if (off + len > d.Length) break;
                sb.Append(Encoding.ASCII.GetString(d, off, len)).Append('.');
                off += len;
            }
            return sb.ToString().TrimEnd('.');
        }

        static void ParseMdns(byte[] d, ref int port, ref string ip, List<IPAddress> candidates)
        {
            if (d == null || d.Length < 12) return;
            int off = 12;
            int qd = (d[4] << 8) | d[5], an = (d[6] << 8) | d[7], ns = (d[8] << 8) | d[9], ar = (d[10] << 8) | d[11];
            for (int i = 0; i < qd && off < d.Length; i++) { ReadName(d, ref off); off += 4; }
            for (int i = 0; i < an + ns + ar && off + 10 <= d.Length; i++)
            {
                ReadName(d, ref off);
                if (off + 10 > d.Length) return;
                int type = (d[off] << 8) | d[off + 1];
                int rdlen = (d[off + 8] << 8) | d[off + 9];
                off += 10;
                if (off + rdlen > d.Length) return;
                if (type == 33 && rdlen >= 6 && port == 0) port = (d[off + 4] << 8) | d[off + 5];
                else if (type == 1 && rdlen == 4)
                {
                    // IPv4 is strongly preferred: a link-local IPv6 DACP target needs a scope id
                    ip = d[off] + "." + d[off + 1] + "." + d[off + 2] + "." + d[off + 3];
                }
                else if (type == 28 && rdlen == 16 && ip.Length == 0)
                {
                    var sb = new StringBuilder();
                    for (int k = 0; k < 16; k += 2) { if (k > 0) sb.Append(':'); sb.Append(d[off + k].ToString("x2")).Append(d[off + k + 1].ToString("x2")); }
                    ip = sb.ToString();
                }
                if (type == 1 && rdlen == 4) { try { candidates.Add(new IPAddress(new[] { d[off], d[off + 1], d[off + 2], d[off + 3] })); } catch { } }
                if (type == 28 && rdlen == 16) { var bb = new byte[16]; Array.Copy(d, off, bb, 0, 16); try { candidates.Add(new IPAddress(bb)); } catch { } }
                off += rdlen;
            }
        }
    }

    // ------------------------------------------------------------------ SMTC publisher (lazy)
    static class Smtc
    {
        static IntPtr hwnd = IntPtr.Zero;
        public static volatile bool Active = false;
        static SystemMediaTransportControls smtc;
        static SystemMediaTransportControlsDisplayUpdater upd;
        static System.Threading.Timer keyTimer;
        static TypedEventHandler<SystemMediaTransportControls, SystemMediaTransportControlsButtonPressedEventArgs> btnHandler;
        static readonly bool[] keyDown = new bool[8];
        static readonly int[] keys = { 0xB3, 0xB0, 0xB1, 0xB2 };   // play/pause, next, prev, stop
        static readonly string[] keyCmd = { "playpause", "nextitem", "previtem", "stop" };
        public static string LastHookLog = "";

        public static void Start()
        {
            if (Active) return;
            EnsureWindowClass();
            hwnd = CreateWindowExW(0, WindowClass, AppName, 0, 0, 0, 0, 0,
                IntPtr.Zero, IntPtr.Zero, GetModuleHandleW(null), IntPtr.Zero);
            if (hwnd == IntPtr.Zero) { Log("CreateWindowExW failed - SMTC not registered"); return; }
#if NETFRAMEWORK
            smtc = GetSmtc(hwnd);
#else
            smtc = SystemMediaTransportControlsInterop.GetForWindow(hwnd);   // CsWinRT projection
#endif
            smtc.IsEnabled = true;
            smtc.IsPlayEnabled = true; smtc.IsPauseEnabled = true;
            smtc.IsNextEnabled = true; smtc.IsPreviousEnabled = true; smtc.IsStopEnabled = true;
            smtc.IsFastForwardEnabled = true; smtc.IsRewindEnabled = true;
            try { smtc.PlaybackRate = 1.0; } catch { }
            smtc.PlaybackStatus = St.Status == "Playing" ? MediaPlaybackStatus.Playing : MediaPlaybackStatus.Paused;
            upd = smtc.DisplayUpdater;
            upd.Type = MediaPlaybackType.Music;
            upd.Update();
#if NETFRAMEWORK
            // C# refuses explicit event-accessor calls on the winmd projection (CS0571): use reflection.
            // The delegates are kept in static fields so the GC cannot collect them.
            btnHandler = new TypedEventHandler<SystemMediaTransportControls, SystemMediaTransportControlsButtonPressedEventArgs>(OnButton);
            try
            {
                typeof(SystemMediaTransportControls).GetMethod("add_ButtonPressed").Invoke(smtc, new object[] { btnHandler });
            }
            catch (Exception ex) { Log("control hook failed: " + ex.Message); }
#else
            smtc.ButtonPressed += OnButton;                                  // CsWinRT projection
#endif
            Active = true;
            if (Dacp.Enabled)
            {
                keyTimer = new System.Threading.Timer(KeyTick, null, 0, 15);
            }
            Log("SMTC session registered (aumid=" + Aumid + "; hwnd=" + hwnd + "; media keys captured while registered)");
        }

        public static void Stop()
        {
            if (!Active) return;
            if (keyTimer != null) { keyTimer.Dispose(); keyTimer = null; }
            try { smtc.ButtonPressed -= OnButton; } catch { }
            try { smtc.IsEnabled = false; } catch { }
            try { DestroyWindow(hwnd); } catch { }
            Active = false; smtc = null; upd = null; hwnd = IntPtr.Zero;
            Log("SMTC session unregistered (no AirPlay data any more; media keys released)");
        }

        static void OnButton(SystemMediaTransportControls s, SystemMediaTransportControlsButtonPressedEventArgs e)
        {
            Interlocked.Increment(ref Dacp.SmtcEvents);
            string cmd;
            switch (e.Button)
            {
                case SystemMediaTransportControlsButton.Play: cmd = "play"; break;
                case SystemMediaTransportControlsButton.Pause: cmd = "pause"; break;
                case SystemMediaTransportControlsButton.Stop: cmd = "stop"; break;
                case SystemMediaTransportControlsButton.Next: cmd = "nextitem"; break;
                case SystemMediaTransportControlsButton.Previous: cmd = "previtem"; break;
                case SystemMediaTransportControlsButton.FastForward: cmd = "beginff"; break;
                case SystemMediaTransportControlsButton.Rewind: cmd = "beginrew"; break;
                default: cmd = null; break;
            }
            Dacp.Send(cmd, "smtc");
        }

        static void KeyTick(object o)
        {
            for (int i = 0; i < keys.Length; i++)
            {
                bool down = (GetAsyncKeyState(keys[i]) & 0x8000) != 0;
                if (down && !keyDown[i])
                {
                    keyDown[i] = true;
                    Interlocked.Increment(ref Dacp.KbEvents);
                    Dacp.Send(keyCmd[i], "kb");
                }
                else if (!down) keyDown[i] = false;
            }
        }

        public static void SetStatus(string status)
        {
            if (!Active || smtc == null) return;
            try { smtc.PlaybackStatus = status == "Playing" ? MediaPlaybackStatus.Playing : MediaPlaybackStatus.Paused; } catch { }
        }

        public static void SetMeta(string title, string artist, string album)
        {
            if (!Active || upd == null) return;
            try
            {
                upd.MusicProperties.Title = title ?? "";
                upd.MusicProperties.Artist = artist ?? "";
                upd.MusicProperties.AlbumTitle = album ?? "";
                upd.Update();
            }
            catch (Exception ex) { Log("display update failed: " + ex.Message); }
        }

        public static bool SetArtwork(string path)
        {
            if (!Active || upd == null) return false;
            try
            {
                var op = StorageFile.GetFileFromPathAsync(path);
                var info = (IAsyncInfo)op;
                var sw = Stopwatch.StartNew();
                while (info.Status == AsyncStatus.Started && sw.ElapsedMilliseconds < 5000) Thread.Sleep(10);
                var file = op.GetResults();
                var reference = RandomAccessStreamReference.CreateFromFile(file);
                upd.Thumbnail = reference;
                upd.Update();
                return true;
            }
            catch (Exception ex) { Log("artwork failed: " + ex.Message); return false; }
        }

        public static void SetTimeline(double pos, double dur)
        {
            if (!Active || smtc == null) return;
            if (NoTimeline) return;
            if (dur <= 0) return;
            if (pos < 0) pos = 0;
            if (pos > dur) pos = dur;
            try
            {
                var tl = new SystemMediaTransportControlsTimelineProperties();
                tl.StartTime = TimeSpan.Zero;
                tl.EndTime = TimeSpan.FromSeconds(dur);
                tl.Position = TimeSpan.FromSeconds(pos);
                // Publish a zero-width seek range at the current position. Start/End/Position
                // remain populated so the timeline is visible, while consumers see no seek span.
                var current = TimeSpan.FromSeconds(pos);
                tl.MinSeekTime = current;
                tl.MaxSeekTime = current;
                smtc.UpdateTimelineProperties(tl);
            }
            catch (Exception ex) { Log("timeline failed: " + ex.Message); }
        }
    }

    // ------------------------------------------------------------------ Npcap (capture driver)
    /// <summary>Is the Npcap driver + user-mode API available on this machine?</summary>
    static bool NpcapPresent()
    {
        try
        {
            bool dllOk = File.Exists(Path.Combine(Environment.SystemDirectory, "Packet.dll"));
            bool drvOk = false;
            try { using (var k = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Services\npcap")) drvOk = k != null; } catch { }
            return dllOk && drvOk;
        }
        catch { return false; }
    }

    static string NpcapStatus()
    {
        string dll = Path.Combine(Environment.SystemDirectory, "Packet.dll");
        bool dllOk = File.Exists(dll);
        bool drvOk = false; string ver = "";
        try { using (var k = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Services\npcap")) drvOk = k != null; } catch { }
        if (dllOk) { try { ver = " v" + FileVersionInfo.GetVersionInfo(dll).FileVersion; } catch { } }
        return "Packet.dll=" + (dllOk ? "yes" : "MISSING") + " driver=" + (drvOk ? "yes" : "MISSING") + ver;
    }

    /// <summary>
    /// Option B: when Npcap is absent, fetch the OFFICIAL installer at runtime, verify it, run it
    /// ELEVATED by the installer itself (UAC) after a dialog explains the steps, then it restarts
    /// the bridge. The installer is never
    /// redistributed inside this exe (Npcap's licence forbids that): it always comes from the
    /// vendor over HTTPS and is checked (size, ProductName, Authenticode signer = Nmap) first.
    /// </summary>
    static bool TryFetchNpcapInstaller(out string path)
    {
        path = Path.Combine(Work, "npcap-installer.exe");
        string url = null;

        // newest release advertised by the official page (fall back to a pinned one)
        try
        {
            using (var wc = new WebClient())
            {
                wc.Headers.Add("User-Agent", "AirPlaySmtcBridge");
                string html = wc.DownloadString("https://npcap.com/");
                var best = (Version)null; string bestRel = null;
                foreach (System.Text.RegularExpressions.Match m in
                         System.Text.RegularExpressions.Regex.Matches(html, @"dist/npcap-(\d+(?:\.\d+)*)\.exe"))
                {
                    var v = new Version(m.Groups[1].Value);
                    if (best == null || v > best) { best = v; bestRel = m.Value; }
                }
                if (bestRel != null) { url = "https://npcap.com/" + bestRel; Log("npcap.com advertises the newest installer: " + bestRel); }
            }
        }
        catch (Exception ex) { Log("could not query npcap.com (" + ex.Message + "); using the pinned release"); }
        if (url == null) url = "https://npcap.com/dist/npcap-1.89.exe";

        Log("downloading the official Npcap installer: " + url);
        try
        {
            using (var wc = new WebClient())
            {
                wc.Headers.Add("User-Agent", "AirPlaySmtcBridge");
                wc.DownloadFile(url, path);
            }
        }
        catch (Exception ex) { Log("download failed: " + ex.Message); return false; }

        // ---- verify before elevating anything
        var fi = new FileInfo(path);
        if (!fi.Exists || fi.Length < 300 * 1024)
        { Log("downloaded file looks wrong (size=" + (fi.Exists ? fi.Length.ToString() : "n/a") + ") -> aborting"); return false; }

        string product = "";
        try { product = FileVersionInfo.GetVersionInfo(path).ProductName ?? ""; } catch { }
        if (product.IndexOf("Npcap", StringComparison.OrdinalIgnoreCase) < 0)
        { Log("downloaded file is not the Npcap installer (ProductName='" + product + "') -> aborting"); return false; }

        string signer;
        try
        {
            var cert = System.Security.Cryptography.X509Certificates.X509Certificate.CreateFromSignedFile(path);
            signer = new System.Security.Cryptography.X509Certificates.X509Certificate2(cert).Subject;
        }
        catch (Exception ex) { Log("installer is not Authenticode-signed (" + ex.Message + ") -> aborting"); return false; }
        if (signer.IndexOf("Nmap", StringComparison.OrdinalIgnoreCase) < 0)
        { Log("unexpected signer '" + signer + "' -> aborting"); return false; }

        string hash;
        using (var sha = System.Security.Cryptography.SHA256.Create())
        using (var fs = File.OpenRead(path))
            hash = BitConverter.ToString(sha.ComputeHash(fs)).Replace("-", "");
        Log("installer verified: '" + product + "' v" + FileVersionInfo.GetVersionInfo(path).FileVersion
            + ", signer=" + signer.Split(',')[0] + ", " + fi.Length + " bytes, sha256=" + hash);
        return true;
    }

    static string FindLocalInstaller()
    {
        var baseDir = AppDomain.CurrentDomain.BaseDirectory;
        var candidates = new List<string>();
        candidates.Add(Path.Combine(baseDir, "npcap-installer.exe"));
        try { candidates.AddRange(Directory.GetFiles(baseDir, "npcap*.exe")); } catch { }
        candidates.Add(Path.Combine(Work, "npcap-installer.exe"));
        foreach (var c in candidates) if (File.Exists(c)) return c;
        return null;
    }

    /// <summary>
    /// Deploy Npcap when it is missing: explain the steps in a dialog, fetch + verify the official
    /// installer, launch it (it requests elevation itself via UAC - we never elevate ourselves),
    /// then restart the app.
    /// </summary>
    static bool TryInstallNpcap()
    {
        bool go = YesNoBox(
            "缺少 Npcap 抓包驱动 —— AirPlay 桥需要它才能读取 AirPlay 数据。\r\n\r\n" +
            "接下来会自动执行：\r\n" +
            "    1) 从官网 npcap.com 下载官方安装包，并校验其数字签名（签名者必须是 Nmap）\r\n" +
            "    2) 启动安装程序；它自己会向 Windows 申请管理员权限（会弹出 UAC 确认框，请选“是”）\r\n" +
            "    3) 安装完成后本程序自动重启，继续工作\r\n\r\n" +
            "说明：安装 Npcap 必须由管理员完成，但本程序自己不申请提权；\r\n" +
            "安装包不随本程序分发，始终从厂商官网获取。\r\n\r\n" +
            "现在开始吗？",
            "AirPlaySmtcBridge — 缺少 Npcap 抓包驱动");
        if (!go) { Log("user declined the Npcap deployment"); return false; }

        string installer = FindLocalInstaller();
        if (installer == null)
        {
            Log("Npcap is missing and no local installer was found -> fetching the official one");
            if (!TryFetchNpcapInstaller(out installer))
            {
                InfoBox("下载或校验安装包失败，无法自动安装 Npcap。\r\n\r\n" +
                        "可手动安装：\r\n    1) 打开 https://npcap.com/#download\r\n" +
                        "    2) 下载并安装（安装时勾选 “Install Npcap in WinPcap API-compatible Mode” 也可）\r\n" +
                        "    3) 重新启动 AirPlaySmtcBridge.exe",
                        "AirPlaySmtcBridge — Npcap 安装失败");
                return false;
            }
        }
        else Log("using the local installer: " + installer);

        Log("launching the Npcap installer (it requests elevation itself; UAC prompt expected): " + installer);
        try
        {
            var psi = new ProcessStartInfo(installer, "/S");
            psi.UseShellExecute = true;   // required so the installer's own manifest can elevate
            psi.Verb = "runas";           // ask the shell for the UAC prompt (installer owns the elevation)
            var p = Process.Start(psi);
            if (p == null) { Log("could not start the installer"); return false; }
            p.WaitForExit(300000);
            Log("installer exited with code " + p.ExitCode);
        }
        catch (Exception ex)
        {
            Log("installer launch failed: " + ex.Message);
            InfoBox("Npcap 安装未完成：" + ex.Message + "\r\n\r\n可手动执行：\r\n    " + installer + " /S\r\n" +
                    "或从 https://npcap.com/#download 下载安装后重启本程序。",
                    "AirPlaySmtcBridge — Npcap 安装失败");
            return false;
        }

        for (int i = 0; i < 20 && !NpcapPresent(); i++) Thread.Sleep(1000);   // the driver needs a moment
        Log("Npcap after deployment: " + NpcapStatus());
        if (!NpcapPresent())
        {
            InfoBox("安装程序已结束，但仍未检测到 Npcap 驱动。\r\n\r\n请从 https://npcap.com/#download 手动安装后重启本程序。",
                    "AirPlaySmtcBridge — Npcap 仍未就绪");
            return false;
        }
        return true;
    }

    /// <summary>Relaunch this executable (used after deploying Npcap) and leave.</summary>
    static void RestartSelf(string reason)
    {
        try
        {
            var exe = System.Reflection.Assembly.GetEntryAssembly().Location;
            Log("restarting the bridge (" + reason + "): " + exe);
            try { if (mutex != null) { mutex.ReleaseMutex(); mutex.Dispose(); mutex = null; } } catch { }
            var psi = new ProcessStartInfo(exe);
            psi.UseShellExecute = false;
            psi.WorkingDirectory = Path.GetDirectoryName(exe);
            Process.Start(psi);
        }
        catch (Exception ex) { Log("restart failed: " + ex.Message); }
        Environment.Exit(0);
    }

    // ------------------------------------------------------------------ main
    static Sniffer SnifferRef;
    static readonly object DacpLock = new object();
    static DateTime LastDacpTry = DateTime.MinValue;
    static DateTime LastStat = DateTime.MinValue;
    static DateTime LastTimelinePush = DateTime.MinValue;
    static bool HasTimelinePush = false;
    static DateTime LastAudioT = DateTime.MinValue;
    static long LastAudioN = 0;
    static double LastAudioRate = 0;
    static string LastCtl = "";
    static bool SawKeepAlive = false;
    static string ArtPath = "";

    public static int Main(string[] args)
    {
        Directory.CreateDirectory(Work);
        try { ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12; } catch { }   // for the Npcap fetch
        var args0 = args;
        bool justStop = false, fetchOnly = false, dialogTest = false;
        foreach (var a in args0)
        {
            if (a == "--stop") justStop = true;
            else if (a == "--fetch-npcap") fetchOnly = true;
            else if (a == "--test-dialog") dialogTest = true;
            else if (a == "--no-dialogs") DialogsDisabled = true;
            else if (a == "--no-control") NoControl = true;
            else if (a == "--no-timeline") NoTimeline = true;
            else if (a == "--verbose") Verbose = true;
            else if (a.StartsWith("--disconnect-sec=")) int.TryParse(a.Substring(17), out DisconnectSecCfg);
        }
        if (DisconnectSecCfg <= 0) DisconnectSecCfg = DisconnectSec;

        // --test-dialog: show the missing-Npcap dialog (diagnostics; nothing is installed)
        if (dialogTest)
        {
            bool answer = YesNoBox(
                "缺少 Npcap 抓包驱动 —— AirPlay 桥需要它才能读取 AirPlay 数据。\r\n\r\n" +
                "接下来会自动执行：\r\n" +
                "    1) 从官网 npcap.com 下载官方安装包，并校验其数字签名（签名者必须是 Nmap）\r\n" +
                "    2) 启动安装程序；它自己会向 Windows 申请管理员权限（会弹出 UAC 确认框，请选“是”）\r\n" +
                "    3) 安装完成后本程序自动重启，继续工作\r\n\r\n" +
                "说明：安装 Npcap 必须由管理员完成，但本程序自己不申请提权；\r\n" +
                "安装包不随本程序分发，始终从厂商官网获取。\r\n\r\n" +
                "现在开始吗？",
                "AirPlaySmtcBridge — 缺少 Npcap 抓包驱动");
            Log("--test-dialog: user answered " + answer);
            return 0;
        }

        // --fetch-npcap: only download + verify the installer (diagnostics; no install, no elevation)
        if (fetchOnly)
        {
            Log("npcap self-check: " + NpcapStatus());
            string fetched;
            bool ok = TryFetchNpcapInstaller(out fetched);
            Log("fetch result: " + (ok ? "OK -> " + fetched : "FAILED"));
            return ok ? 0 : 3;
        }

        // --stop: ask the running instance to unregister its SMTC session and exit cleanly.
        // Force-killing (Taskkill /F, Stop-Process -Force) cannot run any cleanup code, which leaves
        // a ghost media card behind, so this is the supported way to shut the bridge down.
        if (justStop)
        {
            try
            {
                using (var ev = EventWaitHandle.OpenExisting(StopEventName))
                {
                    ev.Set();
                    Console.Error.WriteLine("stop signal sent");
                    return 0;
                }
            }
            catch
            {
                Console.Error.WriteLine("no running AirPlayBridge instance found");
                return 1;
            }
        }

        // single instance: a second copy would publish a second SMTC session.
        // Wait briefly when another instance is shutting down, because after deploying Npcap we
        // restart ourselves and the child must be able to take over the mutex.
        bool created;
        mutex = new Mutex(true, MutexName, out created);
        for (int i = 0; i < 40 && !created; i++)
        {
            Thread.Sleep(500);
            try { created = mutex.WaitOne(0); } catch { }
        }
        if (!created) { Log("another AirPlaySmtcBridge is already running -> exiting"); return 1; }

        SetCurrentProcessExplicitAppUserModelID(Aumid);
        wndProcKeepAlive = delegate(IntPtr h, uint m, IntPtr w, IntPtr l)
        {
            // Windows is ending the session (logoff/shutdown): release the SMTC session so the card
            // does not linger as a ghost.
            if (m == 0x0016) { try { Smtc.Stop(); } catch { } }          // WM_ENDSESSION
            return DefWindowProcW(h, m, w, l);
        };
        try { stopEvent = new EventWaitHandle(false, EventResetMode.ManualReset, StopEventName); } catch { }
        RegisterAumid();
        EnsureShortcut();
        Log("=== " + Path.GetFileName(System.Reflection.Assembly.GetEntryAssembly().Location) + " started (pid=" + Process.GetCurrentProcess().Id + ", log=" + LogFile + ") ===");
        Log("config: control=" + (!NoControl) + " timeline=" + (!NoTimeline) + " disconnectSec=" + DisconnectSecCfg);

        Log("npcap self-check: " + NpcapStatus());
        SnifferRef = new Sniffer();
        var open = SnifferRef.Open();
        if (!open.StartsWith("OK") && !NpcapPresent())
        {
            Log("capture init failed and Npcap is absent -> fetching + installing it elevated");
            if (TryInstallNpcap())
            {
                // the capture stack was already probed in this process: start fresh
                RestartSelf("Npcap deployed");
            }
            Log("Npcap deployment did not succeed -> capture will fail below");
        }
        Log("capture: " + open);
        if (!open.StartsWith("OK")) { Log("capture init failed -> exiting"); return 2; }

        if (!NoControl)
        {
            Dacp.Enabled = true;
            var d = Dacp.Resolve(6000);
            Log("DACP endpoint: '" + d + "' (host='" + Dacp.Host + "' port=" + Dacp.Port + ")");
        }
        else { Dacp.Enabled = false; Log("reverse control DISABLED (--no-control): read-only mirror"); }

        Log("listening for AirPlay RTSP (terminate externally, e.g. Taskkill)");
        while (true)
        {
            try { Tick(); }
            catch (Exception ex) { Log("loop error: " + ex); Thread.Sleep(500); }
        }
    }

    /// <summary>Start Menu shortcut carrying our AUMID: this is the identity the shell's app
    /// resolver uses, so the media card shows "AirPlay" + our icon instead of the raw AUMID.</summary>
    static void EnsureShortcut()
    {
        try
        {
            var exePath = System.Reflection.Assembly.GetEntryAssembly().Location;
            var startMenu = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                @"Microsoft\Windows\Start Menu\Programs");
            Directory.CreateDirectory(startMenu);
            var lnk = Path.Combine(startMenu, ShortcutName + ".lnk");
            // remove a stale shortcut from an earlier naming scheme (only if it points at our exe)
            var legacy = Path.Combine(startMenu, "AirPlay.lnk");
            if (File.Exists(legacy) && legacy != lnk) { try { File.Delete(legacy); } catch { } }

            var link = (IShellLinkW)new ShellLinkCoClass();
            link.SetPath(exePath);
            link.SetArguments("");
            link.SetWorkingDirectory(Path.GetDirectoryName(exePath));
            link.SetDescription(AppName);
            link.SetIconLocation(exePath, 0);

            var store = (IPropertyStore)link;
            var key = new PropertyKey(new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), 5);   // PKEY_AppUserModel_ID
            var pv = new PropVariant();
            pv.vt = 31;                                        // VT_LPWSTR
            pv.pointerValue = Marshal.StringToCoTaskMemUni(Aumid);
            try
            {
                store.SetValue(ref key, ref pv);
                store.Commit();
            }
            finally { Marshal.FreeCoTaskMem(pv.pointerValue); }

            ((IPersistFile)link).Save(lnk, true);
            Log("Start Menu shortcut ready: " + lnk + "  (System.AppUserModel.ID=" + Aumid + ", icon=" + exePath + ")");
        }
        catch (Exception ex) { Log("shortcut creation failed: " + ex.Message); }
    }

    static void RegisterAumid()
    {        try
        {
            // IconUri points straight at this executable (no copy / no redirection): the icon is
            // embedded in it by /win32icon, and the shell resolves it from the image itself.
            var exePath = System.Reflection.Assembly.GetEntryAssembly().Location;
            // overwrite our own registration on every start (the exe may have moved since last run)
            using (var k = Registry.CurrentUser.CreateSubKey(@"Software\Classes\AppUserModelId\" + Aumid))
            {
                k.SetValue("DisplayName", AppName);
                k.SetValue("IconUri", exePath);
            }
            foreach (var old in LegacyAumids)
            {
                try { Registry.CurrentUser.DeleteSubKeyTree(@"Software\Classes\AppUserModelId\" + old, false); } catch { }
            }
            Log("AUMID registered (HKCU\\Software\\Classes\\AppUserModelId\\" + Aumid + " -> '" + AppName + "', icon=" + exePath + ")");
        }
        catch (Exception ex) { Log("AUMID registration failed: " + ex.Message); }
    }

    static void Tick()
    {
        var now = DateTime.Now;
        // graceful stop request (AirPlayBridge.exe --stop): unregister, then leave.
        if (stopEvent != null && stopEvent.WaitOne(0))
        {
            Log("stop requested -> unregistering the SMTC session and exiting");
            Smtc.Stop();
            Environment.Exit(0);
        }
        var events = SnifferRef.Pump(PollMs);
        foreach (var rawEvent in events)
        {
          foreach (var e in rawEvent.Split('\n'))
          {
            if (e.Length == 0) continue;
            var p = e.Split('|');
            switch (p[0])
            {
                case "P":
                    {
                        var v = p[1].Split('/');
                        if (v.Length == 3)
                        {
                            double st, cur, end;
                            if (double.TryParse(v[0], out st) && double.TryParse(v[1], out cur) && double.TryParse(v[2], out end) && end > st)
                            {
                                double anchorJump = Math.Abs(st - St.Start);
                                double durJump = Math.Abs((end - st) - (St.End - St.Start));
                                if (St.Start != 0 && (anchorJump > 44100 || durJump > 44100))
                                {
                                    Log(string.Format("track changed (anchor {0}/{1} -> {2}/{3})", St.Start, St.End, st, end));
                                    St.Song = "";
                                    St.NewTrackUntil = now.AddSeconds(15); St.HasNewTrackWindow = true;
                                }
                                St.Start = st; St.End = end;
                                St.Dur = (end - st) / St.Rate;
                                St.Pos = (cur - st) / St.Rate;
                                St.LastProgress = now; St.LastAnchorAt = now; St.HasProgress = true;
                                St.HasData = true; St.HasSessionGone = false;
                                Smtc.SetTimeline(St.Pos, St.Dur);
                                LastTimelinePush = now; HasTimelinePush = true;
                                if (Verbose) Log(string.Format("timeline <- real progress {0:n1}s / {1:n1}s", St.Pos, St.Dur));
                            }
                        }
                        break;
                    }
                case "M":
                    {
                        var t = p.Length > 1 ? p[1] : "";
                        var a = p.Length > 2 ? p[2] : "";
                        var al = p.Length > 3 ? p[3] : "";
                        bool inWindow = St.HasNewTrackWindow && now < St.NewTrackUntil;
                        var res = ResolveMeta(t, a, al, St.Song, inWindow);
                        if (!string.IsNullOrEmpty(res.Song) && res.Song != St.Song)
                        {
                            St.Song = res.Song;
                            Log(string.Format("song > {0}  |  {1}  |  {2}   [{3}]", res.Song, res.Artist, res.Album, res.Source));
                            St.HasNewTrackWindow = false;
                        }
                        if (!string.IsNullOrEmpty(res.Artist)) St.Artist = res.Artist;
                        if (!string.IsNullOrEmpty(res.Album)) St.Album = res.Album;
                        var title = St.Song;
                        if (string.IsNullOrEmpty(title)) title = t;
                        if (!string.IsNullOrEmpty(title) && title != St.Published)
                        {
                            St.Published = title; St.HasData = true; St.HasSessionGone = false; St.LastMetaAt = now;
                            if (Smtc.Active) { Smtc.SetMeta(title, St.Artist, St.Album); Log("SMTC title -> " + title); }
                            else Log("metadata cached until the SMTC session registers: " + title);
                        }
                        break;
                    }
                case "A":
                    {
                        ArtPath = ArtFile;
                        if (Smtc.Active)
                        {
                            bool ok = Smtc.SetArtwork(ArtFile);
                            Log(string.Format("artwork applied ({0} bytes, thumbnail={1})", p[2], ok));
                        }
                        else Log("artwork cached until the SMTC session registers (" + p[2] + " bytes)");
                        break;
                    }
                case "D":
                    if (p.Length > 2 && p[2].Length > 0)
                    {
                        Dacp.Token = p[2];
                        if (!St.TokenSeen) { St.TokenSeen = true; Log("Active-Remote token acquired from the live RTSP stream: " + p[2]); }
                    }
                    break;
                case "K":
                    St.LastHeartbeat = now; St.HasHeartbeat = true; St.HasSessionGone = false;
                    if (!SawKeepAlive) { SawKeepAlive = true; Log("RTSP keepalive received -> parser OK"); }
                    break;
                case "T":
                    if (!St.HasSessionGone) { St.HasSessionGone = true; St.SessionGoneAt = now; Log("RTSP TEARDOWN received -> sender is ending the AirPlay session"); }
                    break;
            }
          }
        }

        // ---- lazy SMTC registration
        if (!Smtc.Active && St.HasData)
        {
            Smtc.Start();
            if (Smtc.Active)
            {
                if (!string.IsNullOrEmpty(St.Published)) Smtc.SetMeta(St.Published, St.Artist, St.Album);
                if (St.Dur > 0) Smtc.SetTimeline(St.Pos, St.Dur);
                if (!string.IsNullOrEmpty(ArtPath) && File.Exists(ArtPath))
                    Log("artwork applied at registration (thumbnail=" + Smtc.SetArtwork(ArtPath) + ")");
            }
        }

        // ---- control housekeeping
        var ctl = Dacp.LastLog;
        if (!string.IsNullOrEmpty(ctl) && ctl != LastCtl) { LastCtl = ctl; }
        if (Dacp.Enabled && string.IsNullOrEmpty(Dacp.Host) && (now - LastDacpTry).TotalSeconds > 20)
        {
            LastDacpTry = now;
            var d = Dacp.Resolve(4000);
            if (!string.IsNullOrEmpty(d)) Log("DACP endpoint (retry): '" + d + "'");
        }
        // ---- stats
        if ((now - LastStat).TotalSeconds >= 30)
        {
            LastStat = now;
            Log(string.Format("stats: frames={0} tcp7000={1} audio={2:n0}/s title='{3}' status={4} pos={5:n1}/{6:n1} smtc={7} ctl[smtc={8} sent={9} rl={10} kb={11}]",
                SnifferRef.Frames, SnifferRef.Pkts7000, LastAudioRate, St.Published, St.Status, St.Pos, St.Dur, Smtc.Active,
                Dacp.SmtcEvents, Dacp.Sent, Dacp.RateLimited, Dacp.KbEvents));
        }

        // ---- audio rate (large UDP packets) -> liveness fallback / "is the stream alive"
        long at = SnifferRef.AudioPkts;
        if (at > 0) St.SawAudio = true;
        if (LastAudioT == DateTime.MinValue) { LastAudioN = at; LastAudioT = now; LastAudioRate = 0; }
        else
        {
            double dt = (now - LastAudioT).TotalSeconds;
            if (dt >= 0.25) { LastAudioRate = (at - LastAudioN) / dt; LastAudioN = at; LastAudioT = now; }
        }
        // Playback state follows only the large audio packets. RTCP/timing packets are
        // intentionally excluded in Sniffer.HandleL4 (payload >= 500 bytes).
        St.AudioOn = LastAudioRate > 0;
        // Deliberately NOT "St.HasData = true" here: audio flowing alone must not register the
        // session. The card appears only once the iPhone reports real song data (metadata or a
        // progress/timeline anchor), which is what the user asked for.
        if (St.AudioOn && !St.HasData && !Smtc.Active && !St.LoggedWaiting)
        {
            St.LoggedWaiting = true;
            Log("audio is flowing but no song data yet -> SMTC stays unregistered until the iPhone reports");
        }

        // ---- playback state: only observed large audio packets indicate Playing.
        if (St.HasData || St.AudioOn)
        {
            string want = St.AudioOn ? "Playing" : "Paused";
            if (want != St.Status)
            {
                St.Status = want;
                Smtc.SetStatus(want);
                Log(string.Format("state -> {0}  (large audio packets {1:n0}/s; pos {2:n1}/{3:n1})",
                    want, LastAudioRate, St.Pos, St.Dur));
            }
        }

        // ---- timeline drift guard (Windows interpolates between real pushes)
        if (St.Status == "Playing" && St.Dur > 0 && St.HasProgress)
        {
            if (!HasTimelinePush || (now - LastTimelinePush).TotalSeconds >= DriftGuardSec)
            {
                HasTimelinePush = true; LastTimelinePush = now;
                Smtc.SetTimeline(St.Pos + (now - St.LastProgress).TotalSeconds, St.Dur);
                if (Verbose) Log("timeline refresh (drift guard)");
            }
        }

        // ---- session gone? (no keepalive / TEARDOWN / FIN-RST, all within DisconnectSec)
        if (SnifferRef.ConnClosed)
        {
            SnifferRef.ConnClosed = false;
            if (!St.HasSessionGone) { St.HasSessionGone = true; St.SessionGoneAt = now; Log("control connection closed (FIN/RST) -> AirPlay session ending"); }
        }
        bool kaGone = St.HasHeartbeat && (now - St.LastHeartbeat).TotalSeconds > DisconnectSecCfg;
        bool gone = St.HasSessionGone && (now - St.SessionGoneAt).TotalSeconds > DisconnectSecCfg;
        if (St.HasData && (kaGone || gone))
        {
            double kaAge = St.HasHeartbeat ? (now - St.LastHeartbeat).TotalSeconds : -1;
            Log(string.Format("AirPlay session gone (keepalive {0}, disconnect hint {1}) -> unregistering SMTC",
                kaAge >= 0 ? string.Format("{0:n1}s ago", kaAge) : "never seen", St.HasSessionGone ? "yes" : "no"));
            Smtc.Stop();
            St.Published = ""; St.Song = ""; St.Artist = ""; St.Album = "";
            St.Pos = 0; St.Dur = 0; St.HasProgress = false; St.Start = 0; St.End = 0;
            St.HasData = false; St.AudioOn = false; St.SawAudio = false; St.LoggedWaiting = false;
            St.Status = "Paused"; St.TokenSeen = false; St.HasHeartbeat = false; St.HasSessionGone = false;
            St.LastProgress = DateTime.MinValue; St.LastMetaAt = DateTime.MinValue; St.LastAnchorAt = DateTime.MinValue;
        }
    }
}
