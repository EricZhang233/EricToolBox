# event-test.ps1 -- does a banded (EnumWindows-invisible) window still raise WinEvents?
# Installs SetWinEventHook twice (process-filtered and unfiltered), toggles the Quick Settings
# panel, and reports which events were delivered.
# Target: pwsh 7. ASCII-only.

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class WE
{
    public delegate void WinEventDelegate(IntPtr hook, uint ev, IntPtr hwnd, int idObject, int idChild, uint tid, uint time);

    [DllImport("user32.dll")] public static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr mod, WinEventDelegate cb, uint pid, uint tid, uint flags);
    [DllImport("user32.dll")] public static extern bool UnhookWinEvent(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);

    [StructLayout(LayoutKind.Sequential)] public struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int ptX; public int ptY; }
    [DllImport("user32.dll")] static extern bool PeekMessage(out MSG m, IntPtr h, uint min, uint max, uint remove);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG m);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref MSG m);

    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] public struct HARDWAREINPUT { public uint uMsg; public ushort wParamL; public ushort wParamH; }
    [StructLayout(LayoutKind.Explicit)] public struct InputUnion { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; [FieldOffset(0)] public HARDWAREINPUT hi; }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public InputUnion U; }
    [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint n, INPUT[] p, int cb);
    [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint mapType);

    static WinEventDelegate _cbA;   // process-filtered hook
    static WinEventDelegate _cbB;   // unfiltered hook
    static IntPtr _hA = IntPtr.Zero, _hB = IntPtr.Zero;
    public static List<string> Log = new List<string>();
    public static int TotalA = 0, TotalB = 0;

    public static string Cls(IntPtr h) { var s = new StringBuilder(512); GetClassName(h, s, s.Capacity); return s.ToString(); }
    public static string Txt(IntPtr h) { var s = new StringBuilder(512); GetWindowText(h, s, s.Capacity); return s.ToString(); }
    public static uint Pid(IntPtr h) { uint p; GetWindowThreadProcessId(h, out p); return p; }

    public static string EvName(uint e)
    {
        switch (e)
        {
            case 0x0001: return "SYSTEM_SOUND";
            case 0x0002: return "SYSTEM_ALERT";
            case 0x0003: return "SYSTEM_FOREGROUND";
            case 0x0004: return "SYSTEM_MENUSTART";
            case 0x8000: return "OBJECT_CREATE";
            case 0x8001: return "OBJECT_DESTROY";
            case 0x8002: return "OBJECT_SHOW";
            case 0x8003: return "OBJECT_HIDE";
            case 0x8004: return "OBJECT_REORDER";
            case 0x8005: return "OBJECT_FOCUS";
            case 0x8006: return "OBJECT_SELECTION";
            case 0x800C: return "OBJECT_NAMECHANGE";
            case 0x8010: return "OBJECT_CLOAKED";
            case 0x8011: return "OBJECT_UNCLOAKED";
            case 0x8012: return "OBJECT_LIVEREGIONCHANGED";
            default: return "0x" + e.ToString("X");
        }
    }

    public static void Start(uint filterPid)
    {
        // EVENT_OBJECT_CREATE .. EVENT_OBJECT_HIDE = 0x8000..0x8003
        // plus EVENT_SYSTEM_FOREGROUND = 0x0003 (separate range)
        _cbA = new WinEventDelegate(OnA);
        _cbB = new WinEventDelegate(OnB);
        _hA = SetWinEventHook(0x8000, 0x8003, IntPtr.Zero, _cbA, filterPid, 0, 0x0000 /* OUTOFCONTEXT */);
        _hA = SetWinEventHook(0x0003, 0x0003, IntPtr.Zero, _cbA, filterPid, 0, 0x0000);
        _hB = SetWinEventHook(0x8000, 0x8003, IntPtr.Zero, _cbB, 0, 0, 0x0000);
        _hB = SetWinEventHook(0x0003, 0x0003, IntPtr.Zero, _cbB, 0, 0, 0x0000);
    }
    public static void Stop()
    {
        if (_hA != IntPtr.Zero) UnhookWinEvent(_hA);
        if (_hB != IntPtr.Zero) UnhookWinEvent(_hB);
    }

    static void OnA(IntPtr hook, uint ev, IntPtr hwnd, int idObject, int idChild, uint tid, uint time)
    {
        TotalA++;
        Log.Add("A " + EvName(ev) + " hwnd=0x" + hwnd.ToInt64().ToString("X8") + " pid=" + Pid(hwnd) + " obj=" + idObject + " child=" + idChild + " class=[" + Cls(hwnd) + "] title=[" + Txt(hwnd) + "]");
    }
    static void OnB(IntPtr hook, uint ev, IntPtr hwnd, int idObject, int idChild, uint tid, uint time)
    {
        TotalB++;
        // unfiltered: only log the interesting window to keep noise down
        string c = Cls(hwnd);
        if (c == "ControlCenterWindow" || c == "Windows.UI.Input.InputSite.WindowClass")
            Log.Add("B " + EvName(ev) + " hwnd=0x" + hwnd.ToInt64().ToString("X8") + " pid=" + Pid(hwnd) + " class=[" + c + "]");
    }

    public static int Pump(int ms)
    {
        var sw = Stopwatch.StartNew(); int n = 0;
        while (sw.ElapsedMilliseconds < ms)
        {
            MSG m;
            while (PeekMessage(out m, IntPtr.Zero, 0, 0, 1)) { TranslateMessage(ref m); DispatchMessage(ref m); n++; }
            Thread.Sleep(10);
        }
        return n;
    }

    // Win+Ctrl+V
    public static int ToggleSoundPage()
    {
        ushort[] mods = { 0x5B, 0x11 }; ushort key = 0x56;
        var l = new List<INPUT>();
        foreach (var m in mods) l.Add(Ki(m, false));
        l.Add(Ki(key, false)); l.Add(Ki(key, true));
        for (int i = mods.Length - 1; i >= 0; i--) l.Add(Ki(mods[i], true));
        var a = l.ToArray();
        return (int)SendInput((uint)a.Length, a, Marshal.SizeOf(typeof(INPUT)));
    }
    const uint KEYUP = 0x0002;
    static INPUT Ki(ushort vk, bool up)
    {
        var i = new INPUT(); i.type = 1;
        i.U.ki = new KEYBDINPUT { wVk = vk, wScan = (ushort)MapVirtualKey(vk, 0), dwFlags = up ? KEYUP : 0, dwExtraInfo = IntPtr.Zero };
        return i;
    }
}
'@

$sh = Get-Process ShellHost -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $sh) { Write-Output "ShellHost.exe not running"; exit 1 }
Write-Output ("ShellHost pid = " + $sh.Id)

function Show-Fg($tag) {
    $h = [WE]::GetForegroundWindow()
    Write-Host ("[$tag] fg = 0x" + $h.ToInt64().ToString("X8") + " pid=" + [WE]::Pid($h) + " class=[" + [WE]::Cls($h) + "] title=[" + [WE]::Txt($h) + "]")
    return $h
}

Write-Output ""
Write-Output "=== 0. make sure the panel is CLOSED before we start ==="
$fg = Show-Fg "before"
if ([WE]::Cls($fg) -eq 'ControlCenterWindow') {
    Write-Output "  panel is open -> toggling closed"
    [void][WE]::ToggleSoundPage()
    [void][WE]::Pump(1200)
    [void](Show-Fg "closed")
} else {
    Write-Output "  panel already closed"
}

Write-Output ""
Write-Output "=== 1. install hooks (A: idProcess=ShellHost pid, B: unfiltered) ==="
[WE]::Start([uint32]$sh.Id)
[WE]::Log.Clear()
[void][WE]::Pump(600)
Write-Output ("  hooks installed. events seen during idle 600ms: A=" + [WE]::TotalA + " B=" + [WE]::TotalB)

Write-Output ""
Write-Output "=== 2. open the panel (Win+Ctrl+V) and pump 2500ms ==="
[WE]::Log.Clear()
$beforeA = [WE]::TotalA; $beforeB = [WE]::TotalB
[void][WE]::ToggleSoundPage()
[void][WE]::Pump(2500)
Write-Output ("  A events during open: " + ([WE]::TotalA - $beforeA))
Write-Output ("  B events during open: " + ([WE]::TotalB - $beforeB))
[void](Show-Fg "after")

Write-Output ""
Write-Output "=== 3. events logged (A = pid-filtered hook) ==="
if ([WE]::Log.Count -eq 0) {
    Write-Output "  *** NOTHING. WinEvents are NOT delivered for this window. ***"
} else {
    [WE]::Log | ForEach-Object { Write-Output ("  " + $_) }
}

Write-Output ""
Write-Output "=== 4. close the panel again and watch HIDE/DESTROY ==="
[WE]::Log.Clear()
$beforeA = [WE]::TotalA; $beforeB = [WE]::TotalB
[void][WE]::ToggleSoundPage()
[void][WE]::Pump(2000)
Write-Output ("  A events during close: " + ([WE]::TotalA - $beforeA))
Write-Output ("  B events during close: " + ([WE]::TotalB - $beforeB))
[WE]::Log | ForEach-Object { Write-Output ("  " + $_) }

[WE]::Stop()
Write-Output ""
Write-Output "done."
