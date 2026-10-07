# probe-d.ps1 -- dig into the ControlCenterWindow child-window tree to find the XAML island host.
# Run under Windows PowerShell 5.1 (System.Windows.Automation). ASCII-only.

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Collections.Generic;

public static class PD
{
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int idx);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", EntryPoint = "GetWindowThreadProcessId")] public static extern uint TidOf(IntPtr h, IntPtr p);
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
    public static string Info(IntPtr h)
    {
        if (h == IntPtr.Zero) return "(null)";
        return string.Format("0x{0:X8} pid={1} tid={2} class=[{3}] title=[{4}] vis={5} child={6}",
            h.ToInt64(), Pid(h), TidOf(h, IntPtr.Zero), Cls(h), Txt(h),
            IsWindowVisible(h) ? 1 : 0, (GetWindowLong(h, -16) & unchecked((int)0x40000000)) != 0 ? 1 : 0);
    }
    public static List<string> Children(IntPtr root)
    {
        var list = new List<string>();
        Collect(root, list, 0);
        return list;
    }
    static void Collect(IntPtr h, List<string> acc, int depth)
    {
        EnumChildWindows(h, delegate(IntPtr c, IntPtr l)
        {
            acc.Add(depth + "|" + c.ToInt64().ToString("X") + "|" + Info(c));
            if (depth < 8) Collect(c, acc, depth + 1);
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
$LWIN = [UInt16]0x5B; $CTRL = [UInt16]0x11; $V = [UInt16]0x56

function Get-Panel {
    $h = [PD]::GetForegroundWindow()
    if ([PD]::Cls($h) -eq $PANEL_CLASS) { return $h }
    return [IntPtr]::Zero
}

Write-Output "=== STEP 1: panel ==="
$h = Get-Panel
if ($h -eq [IntPtr]::Zero) {
    Write-Output "  not open; opening with Win+Ctrl+V"
    [void][PD]::Combo(@($LWIN, $CTRL), $V); Start-Sleep -Milliseconds 1500
    $h = Get-Panel
}
if ($h -eq [IntPtr]::Zero) { Write-Output "  PANEL NOT FOUND"; exit 1 }
Write-Output ("  panel = " + [PD]::Info($h))

Write-Output ""
Write-Output "=== STEP 2: child window tree of the panel ==="
$children = [PD]::Children($h)
Write-Output ("  child count = " + $children.Count)
foreach ($c in $children) {
    $parts = $c.Split('|')
    Write-Output (('  ' + ('  ' * [int]$parts[0])) + $parts[2])
}

Write-Output ""
Write-Output "=== STEP 3: UIA probe of every descendant HWND ==="
$hwnds = @($h)
foreach ($c in $children) { $hwnds += [IntPtr][Convert]::ToInt64($c.Split('|')[1], 16) }

foreach ($w in $hwnds) {
    try {
        $el = $AE::FromHandle($w)
        $cur = $el.Current
        $n = $el.FindAll($TS::Children, $TC).Count
        $name = $cur.Name; if ($name.Length -gt 40) { $name = $name.Substring(0, 40) + '...' }
        Write-Output ("  0x" + $w.ToInt64().ToString("X8") + " [" + [PD]::Cls($w) + "] -> type=" + ($cur.ControlType.ProgrammaticName -replace '^ControlType\.', '') + " framework=" + $cur.FrameworkId + " name=[" + $name + "] children=" + $n)
    } catch {
        Write-Output ("  0x" + $w.ToInt64().ToString("X8") + " [" + [PD]::Cls($w) + "] -> UIA FromHandle FAILED: " + $_.Exception.Message)
    }
}

Write-Output ""
Write-Output "=== STEP 4: full UIA tree of the richest host ==="
$best = $null; $bestN = -1
foreach ($w in $hwnds) {
    try {
        $el = $AE::FromHandle($w)
        $n = $el.FindAll($TS::Descendants, $TC).Count
        if ($n -gt $bestN) { $bestN = $n; $best = $w }
    } catch { }
}
if ($best -eq $null) { Write-Output "  (no usable UIA host)"; exit 0 }
Write-Output ("  best host = 0x" + $best.ToInt64().ToString("X8") + " [" + [PD]::Cls($best) + "] descendants=" + $bestN)

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
Walk ($AE::FromHandle($best)) 0
Write-Output ""
Write-Output ("total = " + $script:count)
