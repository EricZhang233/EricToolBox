# click-testlink.ps1 -- invoke the injected "TestLink" button through UI Automation and confirm
# that its Click handler really launched winver.exe. Target: pwsh 7.

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class CT
{
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
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

$panel = [CT]::GetForegroundWindow()
if ($panel -eq [IntPtr]::Zero -or [CT]::Cls($panel) -ne 'ControlCenterWindow') {
    Write-Output 'PANEL NOT OPEN (bring the Quick Settings panel to the front first)'
    exit 1
}

$xamlHost = [IntPtr]::Zero
foreach ($k in [CT]::Kids($panel)) { try { if ($AE::FromHandle($k).Current.FrameworkId -eq 'XAML') { $xamlHost = $k; break } } catch { } }
if ($xamlHost -eq [IntPtr]::Zero) { Write-Output 'XAML host child not found'; exit 1 }
$root = $AE::FromHandle($xamlHost)

$cond = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)),
    (New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, 'TestLink')))
$btn = $root.FindFirst($TS::Descendants, $cond)
if (-not $btn) { Write-Output 'TestLink button NOT FOUND in the UIA tree'; exit 1 }

$r = $btn.Current.BoundingRectangle
Write-Output ("found TestLink at (" + [int]$r.X + "," + [int]$r.Y + " " + [int]$r.Width + "x" + [int]$r.Height + ")")

$before = @(Get-Process -Name winver -ErrorAction SilentlyContinue).Count
Write-Output "winver processes before: $before"

$pattern = $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
$pattern.Invoke()

Start-Sleep -Seconds 3
$after = @(Get-Process -Name winver -ErrorAction SilentlyContinue)
Write-Output "winver processes after : $($after.Count)"
if ($after.Count -gt $before) {
    Write-Output 'CLICK HANDLER OK -- winver.exe was launched by the injected button'
    foreach ($p in $after) { Write-Output ("   pid=" + $p.Id + " title=[" + $p.MainWindowTitle + "]") }
} else {
    Write-Output 'CLICK HANDLER DID NOT LAUNCH winver.exe'
}
