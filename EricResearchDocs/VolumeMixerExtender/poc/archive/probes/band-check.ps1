# band-check.ps1 -- correlate window band values with EnumWindows visibility
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class BT
{
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    public delegate int GetWindowBandFn(IntPtr hwnd, out uint band);

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr GetDesktopWindow();
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi)] public static extern IntPtr GetModuleHandleA(string n);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi)] public static extern IntPtr GetProcAddress(IntPtr m, string n);

    public static string Cls(IntPtr h) { var s = new StringBuilder(512); GetClassName(h, s, s.Capacity); return s.ToString(); }
    public static uint Pid(IntPtr h) { uint p; GetWindowThreadProcessId(h, out p); return p; }
    public static int Band(IntPtr h)
    {
        var p = GetProcAddress(GetModuleHandleA("user32.dll"), "GetWindowBand");
        if (p == IntPtr.Zero) return -99;
        var fn = (GetWindowBandFn)Marshal.GetDelegateForFunctionPointer(p, typeof(GetWindowBandFn));
        uint b;
        try { return fn(h, out b) != 0 ? (int)b : -1; } catch { return -98; }
    }
    public static List<string> Enum()
    {
        var list = new List<string>();
        EnumWindows(delegate(IntPtr h, IntPtr l) { list.Add(h.ToInt64().ToString("X") + "|" + Cls(h) + "|" + Pid(h) + "|" + Band(h)); return true; }, IntPtr.Zero);
        return list;
    }
    public static List<string> Chain()
    {
        var list = new List<string>();
        IntPtr c = GetWindow(GetDesktopWindow(), 5);
        int n = 0;
        while (c != IntPtr.Zero && n < 600) { list.Add(c.ToInt64().ToString("X") + "|" + Cls(c) + "|" + Pid(c) + "|" + Band(c)); c = GetWindow(c, 2); n++; }
        return list;
    }
}
'@

$e = [BT]::Enum()
$c = [BT]::Chain()
Write-Output ("EnumWindows count = " + $e.Count + " ; desktop chain count = " + $c.Count)

Write-Output ""
Write-Output "--- band distribution among EnumWindows-visible windows ---"
$e | ForEach-Object { ($_ -split '\|')[3] } | Group-Object | Sort-Object { [int]$_.Name } | ForEach-Object { Write-Output ("  band " + $_.Name + " : " + $_.Count) }

Write-Output ""
Write-Output "--- notable classes ---"
foreach ($k in @('Shell_TrayWnd', 'Shell_SecondaryTrayWnd', 'Progman', 'WorkerW', 'ControlCenterWindow', 'Windows.UI.Core.CoreWindow', 'XamlExplorerHostIslandWindow', 'TopLevelWindowForOverflowXamlIsland')) {
    $hit = @($e | Where-Object { ($_ -split '\|')[1] -eq $k })
    Write-Output ("  " + $k.PadRight(38) + " EnumWindows-count=" + $hit.Count + "  " + (($hit | Select-Object -First 2) -join ' ; '))
}

Write-Output ""
Write-Output "--- band for Shell_TrayWnd / Progman / a normal app window ---"
foreach ($k in @('Shell_TrayWnd', 'Progman', 'Chrome_WidgetWin_1')) {
    $hit = @($c | Where-Object { ($_ -split '\|')[1] -eq $k } | Select-Object -First 1)
    if ($hit) {
        $hw = [IntPtr][Convert]::ToInt64(($hit -split '\|')[0], 16)
        Write-Output ("  " + $k.PadRight(24) + " hwnd=0x" + $hw.ToInt64().ToString("X8") + " band=" + [BT]::Band($hw))
    } else { Write-Output ("  " + $k.PadRight(24) + " (not in chain)") }
}
