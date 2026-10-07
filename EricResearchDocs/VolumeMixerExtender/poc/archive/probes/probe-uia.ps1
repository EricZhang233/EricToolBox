# probe-uia.ps1 -- UI Automation element dump of the Quick Settings panel.
# MUST run under Windows PowerShell 5.1 (System.Windows.Automation lives in .NET Framework).
# ASCII-only on purpose.

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Collections.Generic;

public static class PU
{
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern IntPtr FindWindow(string cls, string win);
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
    public static int Combo(ushort[] mods, ushort key)
    {
        var l = new List<INPUT>();
        foreach (var m in mods) l.Add(Ki(m, false));
        l.Add(Ki(key, false)); l.Add(Ki(key, true));
        for (int i = mods.Length - 1; i >= 0; i--) l.Add(Ki(mods[i], true));
        var a = l.ToArray(); Thread.Sleep(150);
        return (int)SendInput((uint)a.Length, a, Marshal.SizeOf(typeof(INPUT)));
    }
    public static string Cls(IntPtr h) { var s = new StringBuilder(512); GetClassName(h, s, s.Capacity); return s.ToString(); }
    public static string Txt(IntPtr h) { var s = new StringBuilder(512); GetWindowText(h, s, s.Capacity); return s.ToString(); }
    public static uint Pid(IntPtr h) { uint p; GetWindowThreadProcessId(h, out p); return p; }
}
'@

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$AE = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]
$TC = [System.Windows.Automation.Condition]::TrueCondition

$PANEL_CLASS = 'ControlCenterWindow'
$TITLE_QS = [string]::Concat([char]0x5FEB, [char]0x901F, [char]0x8BBE, [char]0x7F6E)
$LWIN = [UInt16]0x5B; $CTRL = [UInt16]0x11; $V = [UInt16]0x56

function Find-PanelViaUia {
    # Test: does UIA see the panel even though EnumWindows does not?
    $cond = New-Object System.Windows.Automation.PropertyCondition($AE::ClassNameProperty, $PANEL_CLASS)
    $el = $null
    try { $el = $AE::RootElement.FindFirst($TS::Children, $cond) } catch { Write-Output ("  RootElement search failed: " + $_.Exception.Message) }
    return $el
}

Write-Output "=== STEP 1: find the panel ==="
$h = [PU]::GetForegroundWindow()
Write-Output ("foreground now : 0x" + $h.ToInt64().ToString("X8") + " pid=" + [PU]::Pid($h) + " class=[" + [PU]::Cls($h) + "] title=[" + [PU]::Txt($h) + "]")

$panel = Find-PanelViaUia
if ($panel -ne $null) {
    Write-Output "  UIA RootElement DID find ControlCenterWindow (EnumWindows could not!)"
    Write-Output ("  NativeWindowHandle = 0x" + ([IntPtr]$panel.Current.NativeWindowHandle).ToInt64().ToString("X8"))
} else {
    Write-Output "  UIA RootElement did not find it either."
    if ([PU]::Cls($h) -ne $PANEL_CLASS) {
        Write-Output "  opening panel with Win+Ctrl+V ..."
        [void][PU]::Combo(@($LWIN, $CTRL), $V)
        Start-Sleep -Milliseconds 1500
        $h = [PU]::GetForegroundWindow()
        Write-Output ("  foreground now : 0x" + $h.ToInt64().ToString("X8") + " class=[" + [PU]::Cls($h) + "] title=[" + [PU]::Txt($h) + "]")
        $panel = Find-PanelViaUia
    }
    if ($panel -eq $null -and [PU]::Cls($h) -eq $PANEL_CLASS) {
        $panel = [System.Windows.Automation.AutomationElement]::FromHandle($h)
    }
}

if ($panel -eq $null) { Write-Output "PANEL NOT FOUND - aborting"; exit 1 }

$pc = $panel.Current
Write-Output ""
Write-Output "=== STEP 2: panel automation element ==="
Write-Output ("  Name            = [" + $pc.Name + "]")
Write-Output ("  ClassName       = [" + $pc.ClassName + "]")
Write-Output ("  ControlType     = " + $pc.ControlType.ProgrammaticName)
Write-Output ("  AutomationId    = [" + $pc.AutomationId + "]")
Write-Output ("  Framework       = " + $pc.FrameworkId)
Write-Output ("  ProcessId       = " + $pc.ProcessId)
$r = $pc.BoundingRectangle
Write-Output ("  BoundingRect    = " + $r.X + "," + $r.Y + " " + $r.Width + "x" + $r.Height)

Write-Output ""
Write-Output "=== STEP 3: descendant tree (ControlType | Name | AutomationId | ClassName) ==="
$script:count = 0
$script:max = 400

function Walk($el, $depth) {
    if ($el -eq $null) { return }
    if ($script:count -ge $script:max) { return }
    $script:count++
    $c = $el.Current
    $pad = '  ' + ('| ' * $depth)
    $t = $c.ControlType.ProgrammaticName -replace '^ControlType\.', ''
    $line = $pad + $t + ' | ' + $c.Name + ' | ' + $c.AutomationId + ' | ' + $c.ClassName
    if (-not $c.IsEnabled) { $line += ' | DISABLED' }
    if (-not $c.IsOffscreen) { $line += ' | ONSCREEN' }
    Write-Output $line
    if ($depth -ge 12) { return }
    $kids = $el.FindAll($TS::Children, $TC)
    foreach ($k in $kids) { Walk $k ($depth + 1) }
}

Walk $panel 0
Write-Output ""
Write-Output ("total elements dumped = " + $script:count)
