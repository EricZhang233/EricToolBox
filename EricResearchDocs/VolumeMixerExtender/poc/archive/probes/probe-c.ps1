# probe-c.ps1 -- locate the Quick Settings panel on this build.
# Target: pwsh 7 (also runs under Windows PowerShell 5.1).
# ASCII-only on purpose so it survives any console codepage.

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class PC
{
    public delegate bool EnumProc(IntPtr h, IntPtr l);

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumThreadWindows(uint tid, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr GetShellWindow();
    [DllImport("user32.dll")] public static extern IntPtr GetDesktopWindow();
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int idx);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr p);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string win);
    [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint tid, ref GUITHREADINFO gti);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int val, int size);

    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)]
    public struct GUITHREADINFO
    {
        public int cbSize; public int flags;
        public IntPtr hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret;
        public RECT rcCaret;
    }

    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] public struct HARDWAREINPUT { public uint uMsg; public ushort wParamL; public ushort wParamH; }
    [StructLayout(LayoutKind.Explicit)] public struct InputUnion { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; [FieldOffset(0)] public HARDWAREINPUT hi; }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public InputUnion U; }
    [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint n, INPUT[] p, int cb);
    [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint mapType);

    const uint KEYUP = 0x0002;
    static INPUT Ki(ushort vk, bool up)
    {
        var i = new INPUT(); i.type = 1;
        i.U.ki = new KEYBDINPUT { wVk = vk, wScan = (ushort)MapVirtualKey(vk, 0), dwFlags = up ? KEYUP : 0, dwExtraInfo = IntPtr.Zero };
        return i;
    }
    public static int Combo(ushort[] mods, ushort key)
    {
        var l = new List<INPUT>();
        foreach (var m in mods) l.Add(Ki(m, false));
        l.Add(Ki(key, false)); l.Add(Ki(key, true));
        for (int i = mods.Length - 1; i >= 0; i--) l.Add(Ki(mods[i], true));
        var a = l.ToArray(); Thread.Sleep(120);
        return (int)SendInput((uint)a.Length, a, Marshal.SizeOf(typeof(INPUT)));
    }

    public static string Cls(IntPtr h) { var s = new StringBuilder(512); GetClassName(h, s, s.Capacity); return s.ToString(); }
    public static string Txt(IntPtr h) { var s = new StringBuilder(512); GetWindowText(h, s, s.Capacity); return s.ToString(); }
    public static uint Pid(IntPtr h) { uint p; GetWindowThreadProcessId(h, out p); return p; }
    public static uint Tid(IntPtr h) { return GetWindowThreadProcessId(h, IntPtr.Zero); }

    public static string Info(IntPtr h)
    {
        if (h == IntPtr.Zero) return "(null)";
        int style = GetWindowLong(h, -16);
        int ex = GetWindowLong(h, -20);
        int clk = -1; try { DwmGetWindowAttribute(h, 14, out clk, 4); } catch { }
        RECT r; GetWindowRect(h, out r);
        bool child = (style & unchecked((int)0x40000000)) != 0;
        bool popup = (style & unchecked((int)0x80000000)) != 0;
        var sb = new StringBuilder();
        sb.AppendFormat("0x{0:X8} pid={1} tid={2} class=[{3}] title=[{4}]", h.ToInt64(), Pid(h), Tid(h), Cls(h), Txt(h));
        sb.AppendFormat(" vis={0} cloak={1} child={2} popup={3} style=0x{4:X8} ex=0x{5:X8} rect=({6},{7})-({8},{9})",
            IsWindowVisible(h) ? 1 : 0, clk, child ? 1 : 0, popup ? 1 : 0, style, ex, r.L, r.T, r.R, r.B);
        return sb.ToString();
    }

    public static List<string> TopLevel()
    {
        var list = new List<string>();
        EnumWindows(delegate(IntPtr h, IntPtr l) { list.Add(Info(h)); return true; }, IntPtr.Zero);
        return list;
    }
    public static List<string> ByPid(uint want)
    {
        var list = new List<string>();
        EnumWindows(delegate(IntPtr h, IntPtr l) { if (Pid(h) == want) list.Add(Info(h)); return true; }, IntPtr.Zero);
        return list;
    }
    public static List<string> ByThread(uint tid)
    {
        var list = new List<string>();
        EnumThreadWindows(tid, delegate(IntPtr h, IntPtr l) { list.Add(Info(h)); return true; }, IntPtr.Zero);
        return list;
    }
    public static List<string> ChildrenAll(IntPtr root)
    {
        var list = new List<string>();
        CollectChildren(root, list, 0);
        return list;
    }
    static void CollectChildren(IntPtr h, List<string> acc, int depth)
    {
        EnumChildWindows(h, delegate(IntPtr c, IntPtr l)
        {
            acc.Add(new string(' ', 2 + depth * 2) + Info(c));
            if (depth < 6) CollectChildren(c, acc, depth + 1);
            return true;
        }, IntPtr.Zero);
    }
    public static string Ancestry(IntPtr h)
    {
        var sb = new StringBuilder();
        var cur = h; int d = 0;
        while (cur != IntPtr.Zero && d < 8) { sb.Append("  [" + d + "] " + Info(cur) + "\r\n"); cur = GetParent(cur); d++; }
        sb.Append("  GA_ROOT   = " + Info(GetAncestor(h, 2)) + "\r\n");
        sb.Append("  GA_PARENT = " + Info(GetAncestor(h, 1)) + "\r\n");
        return sb.ToString();
    }
    public static string Gti(uint tid)
    {
        var g = new GUITHREADINFO();
        g.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
        if (!GetGUIThreadInfo(tid, ref g)) return "(GetGUIThreadInfo failed)";
        return "active=" + Info(g.hwndActive) + "\r\n   focus=" + Info(g.hwndFocus);
    }
}
'@

$TITLE_QS = [string]::Concat([char]0x5FEB, [char]0x901F, [char]0x8BBE, [char]0x7F6E)
$LWIN = [UInt16]0x5B; $CTRL = [UInt16]0x11; $V = [UInt16]0x56

function Get-PanelHwnd {
    # primary: foreground window; secondary: FindWindow (works on some builds)
    $h = [PC]::GetForegroundWindow()
    if ($h -ne [IntPtr]::Zero -and [PC]::Cls($h) -eq 'ControlCenterWindow') { return $h }
    return [PC]::FindWindow('ControlCenterWindow', $null)
}

Write-Output "=== 0. ENVIRONMENT ==="
Write-Output ("PSVersion      : " + $PSVersionTable.PSVersion)
Write-Output ("PSEdition      : " + $PSVersionTable.PSEdition)
Write-Output ("OS build       : " + (Get-CimInstance Win32_OperatingSystem).BuildNumber)
Write-Output ("my SessionId   : " + (Get-Process -Id $PID).SessionId)
$sh = @(Get-Process ShellHost -ErrorAction SilentlyContinue)
Write-Output ("ShellHost      : " + (($sh | ForEach-Object { "$($_.Id)@s$($_.SessionId)" }) -join ", "))

Write-Output ""
Write-Output "=== 1. ENSURE PANEL STATE ==="
$p0 = Get-PanelHwnd
if ($p0 -ne [IntPtr]::Zero) {
    Write-Output ("panel already open: " + [PC]::Info($p0) + "  -> toggling closed")
    [void][PC]::Combo(@($LWIN, $CTRL), $V); Start-Sleep -Milliseconds 900
} else {
    Write-Output "no panel open"
}
$topBefore = [PC]::TopLevel()
Write-Output ("top-level window count before = " + $topBefore.Count)

Write-Output ""
Write-Output "=== 2. OPEN PANEL (SendInput Win+Ctrl+V) ==="
Write-Output ("SendInput events = " + [PC]::Combo(@($LWIN, $CTRL), $V))
Start-Sleep -Milliseconds 1200

Write-Output ""
Write-Output "=== 3. FOREGROUND WINDOW ==="
$fg = [PC]::GetForegroundWindow()
Write-Output ("fg            = " + [PC]::Info($fg))
Write-Output ("IsWindow(fg)  = " + [PC]::IsWindow($fg))
Write-Output ("GTI           = " + [PC]::Gti([PC]::Tid($fg)))
Write-Output "ancestry:"
Write-Output ([PC]::Ancestry($fg))

Write-Output ""
Write-Output "=== 4. FindWindow RESULTS ==="
Write-Output ("FindWindow('ControlCenterWindow', null) = " + [PC]::Info([PC]::FindWindow('ControlCenterWindow', $null)))
Write-Output ("FindWindow(null, TITLE_QS)              = " + [PC]::Info([PC]::FindWindow($null, $TITLE_QS)))
Write-Output ("GetShellWindow()                        = " + [PC]::Info([PC]::GetShellWindow()))

Write-Output ""
Write-Output "=== 5. ENUMWINDOWS / ENUMTHREADWINDOWS for ShellHost ==="
foreach ($p in $sh) {
    Write-Output ("-- pid " + $p.Id + " (EnumWindows):")
    $l = [PC]::ByPid([uint32]$p.Id)
    if ($l.Count -eq 0) { Write-Output "   (none)" } else { $l | ForEach-Object { Write-Output ("   " + $_) } }
    foreach ($t in $p.Threads) {
        $tl = [PC]::ByThread([uint32]$t.Id)
        if ($tl.Count -gt 0) { Write-Output ("   thread " + $t.Id + " (EnumThreadWindows):"); $tl | ForEach-Object { Write-Output ("     " + $_) } }
    }
}

Write-Output ""
Write-Output "=== 6. IS THE PANEL A CHILD SOMEWHERE? (recursive search of ShellHost top-level windows) ==="
$found = $false
foreach ($p in $sh) {
    foreach ($line in [PC]::ByPid([uint32]$p.Id)) {
        $hx = $line.Split(' ')[0]
        $h = [IntPtr][Convert]::ToInt64($hx.Substring(2), 16)
        $kids = [PC]::ChildrenAll($h)
        foreach ($k in $kids) {
            if ($k -like '*ControlCenterWindow*') { Write-Output ("   FOUND child: " + $k.Trim()); $found = $true }
        }
        if ($kids.Count -gt 0) { Write-Output ("   " + $line + "  -> " + $kids.Count + " children"); $kids | Select-Object -First 40 | ForEach-Object { Write-Output ("     " + $_) } }
    }
}
if (-not $found) { Write-Output "   (no ControlCenterWindow found among children)" }

Write-Output ""
Write-Output "=== 7. ENUMWINDOWS DIFF (before -> after) ==="
$topAfter = [PC]::TopLevel()
Write-Output ("top-level window count after = " + $topAfter.Count)
$new = @($topAfter | Where-Object { $topBefore -notcontains $_ })
if ($new.Count -eq 0) { Write-Output "   (no new/changed entries)" } else { $new | ForEach-Object { Write-Output ("   + " + $_) } }
$fgHex = "0x" + $fg.ToInt64().ToString("X8")
Write-Output ("   fg hwnd listed by EnumWindows? " + (@($topAfter | Where-Object { $_.StartsWith($fgHex) }).Count -gt 0))
