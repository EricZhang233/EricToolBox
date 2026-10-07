# footer-geom.ps1 -- dump the Quick Settings footer subtree with bounding rectangles,
# to plan a right-aligned entry next to the "More volume settings" button.
# Target: pwsh 7 (also fine on Windows PowerShell 5.1). ASCII-only.

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class FG
{
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);

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
    public static int TogglePage()
    {
        ushort[] mods = { 0x5B, 0x11 }; ushort key = 0x56;
        var l = new List<INPUT>();
        foreach (var m in mods) l.Add(Ki(m, false));
        l.Add(Ki(key, false)); l.Add(Ki(key, true));
        for (int i = mods.Length - 1; i >= 0; i--) l.Add(Ki(mods[i], true));
        var a = l.ToArray(); Thread.Sleep(150);
        return (int)SendInput((uint)a.Length, a, Marshal.SizeOf(typeof(INPUT)));
    }
    public static string Cls(IntPtr h) { var s = new StringBuilder(512); GetClassName(h, s, s.Capacity); return s.ToString(); }
    public static List<IntPtr> Kids(IntPtr root)
    {
        var list = new List<IntPtr>();
        Collect(root, list, 0);
        return list;
    }
    static void Collect(IntPtr h, List<IntPtr> acc, int d)
    {
        EnumChildWindows(h, delegate(IntPtr c, IntPtr l) { acc.Add(c); if (d < 6) Collect(c, acc, d + 1); return true; }, IntPtr.Zero);
    }
}
'@

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$AE = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]
$TC = [System.Windows.Automation.Condition]::TrueCondition

function Get-PanelHandle {
    $h = [FG]::GetForegroundWindow()
    if ($h -ne [IntPtr]::Zero -and [FG]::Cls($h) -eq 'ControlCenterWindow') { return $h }
    return [IntPtr]::Zero
}

$panel = Get-PanelHandle
if ($panel -eq [IntPtr]::Zero) {
    Write-Output "panel closed -> opening with Win+Ctrl+V"
    [void][FG]::TogglePage(); Start-Sleep -Milliseconds 1500
    $panel = Get-PanelHandle
}
if ($panel -eq [IntPtr]::Zero) { Write-Output "PANEL NOT FOUND"; exit 1 }
Write-Output ("panel = 0x" + $panel.ToInt64().ToString("X8"))

$xamlHost = [IntPtr]::Zero
foreach ($k in [FG]::Kids($panel)) { try { if ($AE::FromHandle($k).Current.FrameworkId -eq 'XAML') { $xamlHost = $k; break } } catch { } }
if ($xamlHost -eq [IntPtr]::Zero) { Write-Output "no XAML host"; exit 1 }
$root = $AE::FromHandle($xamlHost)
Write-Output ("xaml host = 0x" + $xamlHost.ToInt64().ToString("X8"))

function Rect($el) {
    $r = $el.Current.BoundingRectangle
    return ("(" + [int]$r.X + "," + [int]$r.Y + " " + [int]$r.Width + "x" + [int]$r.Height + ")")
}
function Desc($el) {
    $c = $el.Current
    return (($c.ControlType.ProgrammaticName -replace '^ControlType\.', '') + ' | ' + $c.Name + ' | id=' + $c.AutomationId + ' | ' + $c.ClassName)
}

Write-Output ""
Write-Output "=== 1. panel rect ==="
Write-Output ("  panel window : " + [FG]::Cls($panel) + " rect=" + (Rect $root))

Write-Output ""
Write-Output "=== 2. locate AutomationId = Footer ==="
$cond = New-Object System.Windows.Automation.PropertyCondition($AE::AutomationIdProperty, 'Footer')
$footer = $root.FindFirst($TS::Descendants, $cond)
if ($footer -eq $null) { Write-Output "  Footer NOT FOUND"; exit 1 }
Write-Output ("  footer = " + (Desc $footer) + " " + (Rect $footer))

Write-Output ""
Write-Output "=== 3. parent chain (with rects) ==="
$w = [System.Windows.Automation.TreeWalker]::ControlViewWalker
$cur = $footer
for ($i = 0; $i -lt 6; $i++) {
    $p = $w.GetParent($cur)
    if ($p -eq $null) { break }
    Write-Output ("  [" + $i + "] " + (Desc $p) + " " + (Rect $p))
    $cur = $p
}

Write-Output ""
Write-Output "=== 4. footer subtree (rects) ==="
function Walk($el, $depth) {
    if ($el -eq $null) { return }
    Write-Output (('  ' + ('  ' * $depth)) + (Desc $el) + ' ' + (Rect $el))
    if ($depth -ge 6) { return }
    foreach ($k in $el.FindAll($TS::Children, $TC)) { Walk $k ($depth + 1) }
}
Walk $footer 0

Write-Output ""
Write-Output "=== 5. all direct children of the Footer's PARENT (layout context) ==="
$parent = $w.GetParent($footer)
if ($parent -ne $null) {
    Write-Output ("  parent = " + (Desc $parent) + " " + (Rect $parent))
    foreach ($k in $parent.FindAll($TS::Children, $TC)) {
        Write-Output ("    - " + (Desc $k) + " " + (Rect $k))
    }
}
