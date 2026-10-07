# footer-map.ps1 -- dump every element whose AutomationId mentions "Footer", with rects,
# so we can see which bar is where and where "更多音量设置" really lives.
# Target: pwsh 7.

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class FM
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
    $h = [FM]::GetForegroundWindow()
    if ($h -ne [IntPtr]::Zero -and [FM]::Cls($h) -eq 'ControlCenterWindow') { return $h }
    return [IntPtr]::Zero
}

$panel = Get-PanelHandle
if ($panel -eq [IntPtr]::Zero) {
    Write-Output "panel closed -> opening"
    [void][FM]::Toggle(); Start-Sleep -Milliseconds 1500
    $panel = Get-PanelHandle
}
if ($panel -eq [IntPtr]::Zero) { Write-Output "PANEL NOT FOUND"; exit 1 }

# A rect can come back as NaN/Infinity when an element is pushed outside its parent's bounds
# (e.g. a bad margin), and [int] then throws. Clamp instead of losing the whole dump.
function Fmt-Rect($r) {
    $x = if ([double]::IsNaN($r.X) -or [double]::IsInfinity($r.X)) { '?' } else { [int]$r.X }
    $y = if ([double]::IsNaN($r.Y) -or [double]::IsInfinity($r.Y)) { '?' } else { [int]$r.Y }
    $w = if ([double]::IsNaN($r.Width) -or [double]::IsInfinity($r.Width)) { '?' } else { [int]$r.Width }
    $h = if ([double]::IsNaN($r.Height) -or [double]::IsInfinity($r.Height)) { '?' } else { [int]$r.Height }
    return "($x,$y ${w}x${h})"
}

$xamlHost = [IntPtr]::Zero
foreach ($k in [FM]::Kids($panel)) { try { if ($AE::FromHandle($k).Current.FrameworkId -eq 'XAML') { $xamlHost = $k; break } } catch { } }
$root = $AE::FromHandle($xamlHost)

Write-Output "=== all elements whose AutomationId mentions Footer (or that are Buttons) ==="
$all = $root.FindAll($TS::Descendants, $TC)
foreach ($e in $all) {
    $c = $e.Current
    $id = $c.AutomationId
    $isBtn = ($c.ControlType.ProgrammaticName -eq 'ControlType.Button')
    if ($id -match 'Footer' -or $isBtn) {
        $r = $c.BoundingRectangle
        $pad = if ($id -match 'Footer') { '  ' } else { '    ' }
        Write-Output ($pad + "[" + $id + "] " + $c.ControlType.ProgrammaticName.Replace('ControlType.','') +
                      " name=[" + $c.Name + "] rect=" + (Fmt-Rect $r))
    }
}
Write-Output ""
Write-Output "=== the region-level footer containers, with children ==="
foreach ($want in @('LeftFooter', 'RightFooter', 'FooterGrid')) {
    $cond = New-Object System.Windows.Automation.PropertyCondition($AE::AutomationIdProperty, $want)
    $el = $root.FindFirst($TS::Descendants, $cond)
    if ($el) {
        $r = $el.Current.BoundingRectangle
        Write-Output ("  [" + $want + "] rect=" + (Fmt-Rect $r))
        foreach ($k in $el.FindAll($TS::Children, $TC)) {
            $kr = $k.Current.BoundingRectangle
            Write-Output ("      - [" + $k.Current.AutomationId + "] " + $k.Current.ControlType.ProgrammaticName.Replace('ControlType.','') + " name=[" + $k.Current.Name + "] rect=" + (Fmt-Rect $kr))
        }
    } else { Write-Output ("  [" + $want + "] not found in the UIA tree") }
}
