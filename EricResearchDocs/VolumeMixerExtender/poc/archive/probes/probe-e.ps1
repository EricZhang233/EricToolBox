# probe-e.ps1 -- WHY is ControlCenterWindow invisible to EnumWindows? Test the "window band" hypothesis.
# Target: pwsh 7. ASCII-only.

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class PE
{
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    public delegate int GetWindowBandFn(IntPtr hwnd, out uint band);

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr GetDesktopWindow();
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi)] public static extern IntPtr GetModuleHandleA(string name);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi)] public static extern IntPtr GetProcAddress(IntPtr mod, string name);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string win);

    public static string Cls(IntPtr h) { var s = new StringBuilder(512); GetClassName(h, s, s.Capacity); return s.ToString(); }

    public static string Band(IntPtr h)
    {
        var mod = GetModuleHandleA("user32.dll");
        var p = GetProcAddress(mod, "GetWindowBand");
        if (p == IntPtr.Zero) return "(GetWindowBand not exported)";
        var fn = (GetWindowBandFn)Marshal.GetDelegateForFunctionPointer(p, typeof(GetWindowBandFn));
        uint b;
        try { int ok = fn(h, out b); return "ok=" + ok + " band=" + b; }
        catch (Exception e) { return "call failed: " + e.Message; }
    }

    public static List<string> DesktopChain()
    {
        var list = new List<string>();
        IntPtr d = GetDesktopWindow();
        list.Add("desktop hwnd = 0x" + d.ToInt64().ToString("X8") + " pid=" + PidOf(d) + " class=[" + Cls(d) + "]");
        IntPtr c = GetWindow(d, 5); // GW_CHILD
        int n = 0;
        while (c != IntPtr.Zero && n < 400)
        {
            uint pid; GetWindowThreadProcessId(c, out pid);
            list.Add("  child 0x" + c.ToInt64().ToString("X8") + " pid=" + pid + " class=[" + Cls(c) + "]");
            c = GetWindow(c, 2); // GW_HWNDNEXT
            n++;
        }
        list.Add("  desktop child count = " + n);
        return list;
    }
    public static uint PidOf(IntPtr h) { uint p; GetWindowThreadProcessId(h, out p); return p; }
}
'@

Write-Output "=== OS BUILD FACTS (settle 26200 vs 26300) ==="
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
Write-Output ("registry CurrentBuild      = " + $cv.CurrentBuild)
Write-Output ("registry CurrentBuildNumber= " + $cv.CurrentBuildNumber)
Write-Output ("registry UBR               = " + $cv.UBR)
Write-Output ("CIM Win32_OS.BuildNumber   = " + (Get-CimInstance Win32_OperatingSystem).BuildNumber)
Write-Output ("Environment.OSVersion      = " + [Environment]::OSVersion.Version)

Write-Output ""
Write-Output "=== find the panel ==="
$h = [PE]::GetForegroundWindow()
if ([PE]::Cls($h) -ne 'ControlCenterWindow') {
    Write-Output ("  foreground is [" + [PE]::Cls($h) + "], FindWindow fallback = " + [PE]::FindWindow('ControlCenterWindow', $null))
    Write-Output "  NOTE: panel must already be open; this probe does not open it."
    exit 0
}
Write-Output ("  panel = 0x" + $h.ToInt64().ToString("X8") + " pid=" + [PE]::PidOf($h))

Write-Output ""
Write-Output "=== WINDOW BAND TEST ==="
Write-Output ("  panel          band: " + [PE]::Band($h))
$tray = [PE]::FindWindow('Shell_TrayWnd', $null)
Write-Output ("  Shell_TrayWnd  band: " + [PE]::Band($tray))
$prog = [PE]::FindWindow('Progman', $null)
Write-Output ("  Progman        band: " + [PE]::Band($prog))
$fgDiff = [PE]::FindWindow('Chrome_WidgetWin_1', $null)
Write-Output ("  a Chrome win   band: " + [PE]::Band($fgDiff))

Write-Output ""
Write-Output "=== DESKTOP CHILD CHAIN (does it contain the panel?) ==="
$chain = [PE]::DesktopChain()
$chain | Select-Object -First 3 | ForEach-Object { Write-Output $_ }
$hex = "0x" + $h.ToInt64().ToString("X8")
if ($chain -match $hex) { Write-Output ("  panel " + $hex + " IS in the desktop child chain") } else { Write-Output ("  panel " + $hex + " is NOT in the desktop child chain") }
$chain | Where-Object { $_ -like '*ControlCenterWindow*' -or $_ -like '*Xaml*' -or $_ -like '*CoreWindow*' } | ForEach-Object { Write-Output ("  > " + $_) }
Write-Output ("  " + ($chain | Select-Object -Last 1))

Write-Output ""
Write-Output "=== compare: GA_PARENT of panel vs our GetDesktopWindow() ==="
$dp = [PE]::GetAncestor($h, 1)
$dw = [PE]::GetDesktopWindow()
Write-Output ("  panel GA_PARENT   = 0x" + $dp.ToInt64().ToString("X8") + " pid=" + [PE]::PidOf($dp) + " class=[" + [PE]::Cls($dp) + "]")
Write-Output ("  GetDesktopWindow  = 0x" + $dw.ToInt64().ToString("X8") + " pid=" + [PE]::PidOf($dw) + " class=[" + [PE]::Cls($dw) + "]")
Write-Output ("  same desktop? " + ($dp -eq $dw))
if ([PE]::PidOf($dp) -ne 0) {
    $ownerPid = [PE]::PidOf($dp)
    $p = Get-Process -Id $ownerPid -ErrorAction SilentlyContinue
    $ownerName = if ($p) { $p.ProcessName } else { "pid $ownerPid" }
    Write-Output ("  owner of panel's desktop window: " + $ownerName)
}
