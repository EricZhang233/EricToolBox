# qs-panel-probe.ps1 -- locate the Win11 Quick Settings panel and dump its XAML automation tree.
#
# Verified on: Windows 11 build 26300.9550, PowerShell 7.6.6 (also works on Windows PowerShell 5.1).
#
# Why this is not just FindWindow("ControlCenterWindow"):
#   The panel is created in a non-default window BAND (GetWindowBand = 4), and Windows excludes
#   banded windows from EnumWindows / EnumThreadWindows / FindWindow / UIA RootElement.
#   GetForegroundWindow() and GetGUIThreadInfo() still return it -- use those.
#
# The actual XAML content lives in a CHILD window of the panel:
#   ControlCenterWindow -> Windows.UI.Input.InputSite.WindowClass  (UIA FrameworkId = "XAML")

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class QsProbe
{
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    public delegate int GetWindowBandFn(IntPtr hwnd, out uint band);

    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern IntPtr FindWindow(string cls, string win);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi)] public static extern IntPtr GetModuleHandleA(string name);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi)] public static extern IntPtr GetProcAddress(IntPtr mod, string name);

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
    // Win+Ctrl+V -- the documented shortcut for the Quick Settings "sound output" page.
    public static int OpenSoundOutputPage()
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
    public static string Txt(IntPtr h) { var s = new StringBuilder(512); GetWindowText(h, s, s.Capacity); return s.ToString(); }
    public static uint Pid(IntPtr h) { uint p; GetWindowThreadProcessId(h, out p); return p; }

    public static string Band(IntPtr h)
    {
        var p = GetProcAddress(GetModuleHandleA("user32.dll"), "GetWindowBand");
        if (p == IntPtr.Zero) return "(n/a)";
        var fn = (GetWindowBandFn)Marshal.GetDelegateForFunctionPointer(p, typeof(GetWindowBandFn));
        uint b;
        try { return fn(h, out b) != 0 ? b.ToString() : "(not banded)"; }
        catch { return "(call failed)"; }
    }

    public static List<IntPtr> DescendantWindows(IntPtr root)
    {
        var list = new List<IntPtr>();
        Collect(root, list, 0);
        return list;
    }
    static void Collect(IntPtr h, List<IntPtr> acc, int depth)
    {
        EnumChildWindows(h, delegate(IntPtr c, IntPtr l)
        {
            acc.Add(c);
            if (depth < 6) Collect(c, acc, depth + 1);
            return true;
        }, IntPtr.Zero);
    }
}
'@

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$AE = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]
$TC = [System.Windows.Automation.Condition]::TrueCondition

$PANEL_CLASS = 'ControlCenterWindow'

function Get-PanelHandle {
    $h = [QsProbe]::GetForegroundWindow()
    if ($h -ne [IntPtr]::Zero -and [QsProbe]::Cls($h) -eq $PANEL_CLASS) { return $h }
    return [IntPtr]::Zero
}

Write-Output "=== 1. locate panel (foreground only -- enumeration cannot see it) ==="
$panel = Get-PanelHandle
if ($panel -eq [IntPtr]::Zero) {
    Write-Output "  not open -> sending Win+Ctrl+V"
    [void][QsProbe]::OpenSoundOutputPage()
    Start-Sleep -Milliseconds 1500
    $panel = Get-PanelHandle
}
if ($panel -eq [IntPtr]::Zero) { Write-Output "  PANEL NOT FOUND (is ShellHost.exe running?)"; exit 1 }
$pk = "0x" + $panel.ToInt64().ToString("X8")
Write-Output ("  panel hwnd = " + $pk + " pid=" + [QsProbe]::Pid($panel) + " class=[" + [QsProbe]::Cls($panel) + "] title=[" + [QsProbe]::Txt($panel) + "]")
Write-Output ("  FindWindow('" + $PANEL_CLASS + "') would return : " + [QsProbe]::FindWindow($PANEL_CLASS, $null))
Write-Output ("  window band                                : " + [QsProbe]::Band($panel))

Write-Output ""
Write-Output "=== 2. child HWNDs of the panel ==="
$kids = [QsProbe]::DescendantWindows($panel)
foreach ($k in $kids) {
    Write-Output ("  0x" + $k.ToInt64().ToString("X8") + " class=[" + [QsProbe]::Cls($k) + "] vis=" + [QsProbe]::IsWindowVisible($k))
}

Write-Output ""
Write-Output "=== 3. find the XAML host (UIA FrameworkId = XAML) ==="
$xamlHost = [IntPtr]::Zero
foreach ($k in $kids) {
    try { if ($AE::FromHandle($k).Current.FrameworkId -eq 'XAML') { $xamlHost = $k; break } } catch { }
}
if ($xamlHost -eq [IntPtr]::Zero) { Write-Output "  no XAML host found"; exit 1 }
Write-Output ("  xaml host = 0x" + $xamlHost.ToInt64().ToString("X8") + " class=[" + [QsProbe]::Cls($xamlHost) + "]")

Write-Output ""
Write-Output "=== 4. XAML automation tree: ControlType | Name | AutomationId | ClassName ==="
$script:count = 0
$script:max = 500
function Walk($el, $depth) {
    if ($el -eq $null -or $script:count -ge $script:max) { return }
    $script:count++
    $c = $el.Current
    $t = $c.ControlType.ProgrammaticName -replace '^ControlType\.', ''
    $line = ('  ' + ('| ' * $depth)) + $t + ' | ' + $c.Name + ' | id=' + $c.AutomationId + ' | ' + $c.ClassName
    if (-not $c.IsEnabled) { $line += ' | DISABLED' }
    if ($c.IsOffscreen) { $line += ' | offscreen' }
    Write-Output $line
    if ($depth -ge 14) { return }
    foreach ($k in $el.FindAll($TS::Children, $TC)) { Walk $k ($depth + 1) }
}
Walk ($AE::FromHandle($xamlHost)) 0
Write-Output ""
Write-Output ("  total elements = " + $script:count)
