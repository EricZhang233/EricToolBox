# element-persistence.ps1 -- is the Quick Settings XAML tree rebuilt on every open, or does it persist?
# Compares UIA GetRuntimeId() of the same elements across a close/open cycle.
# This decides the design: "hook creation" (rebuilt) vs "find existing tree" (persistent).
# Target: pwsh 7. ASCII-only.

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class EP
{
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);

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
    public static int Toggle()
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
    public static List<IntPtr> Kids(IntPtr root) { var l = new List<IntPtr>(); Collect(root, l, 0); return l; }
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
    $h = [EP]::GetForegroundWindow()
    if ($h -ne [IntPtr]::Zero -and [EP]::Cls($h) -eq 'ControlCenterWindow') { return $h }
    return [IntPtr]::Zero
}
function Get-XamlRoot {
    $p = Get-PanelHandle
    if ($p -eq [IntPtr]::Zero) { return $null }
    foreach ($k in [EP]::Kids($p)) { try { if ($AE::FromHandle($k).Current.FrameworkId -eq 'XAML') { return $AE::FromHandle($k) } } catch { } }
    return $null
}
function Rid($el) {
    if ($el -eq $null) { return "<none>" }
    return ($el.GetRuntimeId() -join '.')
}
function ById($root, $id) {
    if ($root -eq $null) { return $null }
    $c = New-Object System.Windows.Automation.PropertyCondition($AE::AutomationIdProperty, $id)
    return $root.FindFirst($TS::Descendants, $c)
}
function ByName($root, $name) {
    if ($root -eq $null) { return $null }
    $c = New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, $name)
    return $root.FindFirst($TS::Descendants, $c)
}

# --- ensure OPEN ---
$root = Get-XamlRoot
if ($root -eq $null) { [void][EP]::Toggle(); Start-Sleep -Milliseconds 1500; $root = Get-XamlRoot }
if ($root -eq $null) { Write-Output "PANEL NOT FOUND"; exit 1 }

Write-Output "=== CYCLE 1 (open) ==="
$panelHwnd1 = Get-PanelHandle
Write-Output ("  panel hwnd   : 0x" + $panelHwnd1.ToInt64().ToString("X8"))
Write-Output ("  xaml host    : 0x" + ([IntPtr]$root.Current.NativeWindowHandle).ToInt64().ToString("X8"))
$f1 = ById $root 'Footer'
$p1 = ById $root 'PageWindow'
$l1 = ById $root 'ListContent'
$s1 = ById $root 'AppVolumeLevel'
$b1 = ByName $root '更多音量设置'
Write-Output ("  PageWindow   : " + (Rid $p1))
Write-Output ("  ListContent  : " + (Rid $l1))
Write-Output ("  AppVolumeLevel: " + (Rid $s1))
Write-Output ("  Footer       : " + (Rid $f1))
Write-Output ("  '更多音量设置' Button : " + (Rid $b1))

Write-Output ""
Write-Output "=== closing panel ... ==="
[void][EP]::Toggle(); Start-Sleep -Milliseconds 1500
Write-Output ("  fg now : [" + [EP]::Cls([EP]::GetForegroundWindow()) + "]")

Write-Output ""
Write-Output "=== CYCLE 2 (reopen) ==="
[void][EP]::Toggle(); Start-Sleep -Milliseconds 1800
$root2 = Get-XamlRoot
if ($root2 -eq $null) { Write-Output "  could not reopen"; exit 1 }
$panelHwnd2 = Get-PanelHandle
Write-Output ("  panel hwnd   : 0x" + $panelHwnd2.ToInt64().ToString("X8") + "   (same as cycle 1? " + ($panelHwnd1 -eq $panelHwnd2) + ")")
Write-Output ("  xaml host    : 0x" + ([IntPtr]$root2.Current.NativeWindowHandle).ToInt64().ToString("X8"))
$f2 = ById $root2 'Footer'
$p2 = ById $root2 'PageWindow'
$l2 = ById $root2 'ListContent'
$s2 = ById $root2 'AppVolumeLevel'
$b2 = ByName $root2 '更多音量设置'
Write-Output ("  PageWindow   : " + (Rid $p2))
Write-Output ("  ListContent  : " + (Rid $l2))
Write-Output ("  AppVolumeLevel: " + (Rid $s2))
Write-Output ("  Footer       : " + (Rid $f2))
Write-Output ("  '更多音量设置' Button : " + (Rid $b2))

Write-Output ""
Write-Output "=== VERDICT ==="
$same = @()
if ((Rid $p1) -eq (Rid $p2)) { $same += 'PageWindow' }
if ((Rid $l1) -eq (Rid $l2)) { $same += 'ListContent' }
if ((Rid $f1) -eq (Rid $f2)) { $same += 'Footer' }
if ((Rid $s1) -eq (Rid $s2)) { $same += 'AppVolumeLevel' }
if ((Rid $b1) -eq (Rid $b2)) { $same += 'MoreButton' }
if ($same.Count -ge 3) {
    Write-Output ("  PERSISTENT: element instances survived the close/open cycle (" + ($same -join ', ') + ")")
    Write-Output "  -> hooking element creation will NOT fire again; design must FIND the existing tree."
} else {
    Write-Output ("  REBUILT: element instances differ after reopen (survivors: " + (($same -join ', ') -replace '^$', 'none') + ")")
    Write-Output "  -> hooking element creation IS a viable trigger."
}
