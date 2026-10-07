# click-probe.ps1 -- 通过 UIA 点一下注入的按钮，然后把"被点出来的子进程收到了什么"打印出来。
#
# 与 click-testlink.ps1 的区别：那个断言的是 winver.exe（早期验收）；
# 这个读的是 clickprobe.exe 落盘的报告，用来验证**命令行（exe + 参数）是否被正确传递**、
# 以及**子进程继承到的当前目录是什么** —— 后者是接项目主程序入口时会踩到的点。

$ErrorActionPreference = 'Stop'
$report = Join-Path $env:TEMP 'vmext-clickprobe.txt'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class CPK
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

$panel = [CPK]::GetForegroundWindow()
if ($panel -eq [IntPtr]::Zero -or [CPK]::Cls($panel) -ne 'ControlCenterWindow') {
    Write-Output 'PANEL NOT OPEN (先把快速设置面板调到前台)'
    exit 1
}
$xamlHost = [IntPtr]::Zero
foreach ($k in [CPK]::Kids($panel)) { try { if ($AE::FromHandle($k).Current.FrameworkId -eq 'XAML') { $xamlHost = $k; break } } catch { } }
if ($xamlHost -eq [IntPtr]::Zero) { Write-Output 'XAML host child not found'; exit 1 }
$root = $AE::FromHandle($xamlHost)

$cond = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)),
    (New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, 'TestLink')))
$btn = $root.FindFirst($TS::Descendants, $cond)
if (-not $btn) { Write-Output 'TestLink button NOT FOUND'; exit 1 }

$r = $btn.Current.BoundingRectangle
Write-Output ("找到 TestLink @ (" + [int]$r.X + "," + [int]$r.Y + " " + [int]$r.Width + "x" + [int]$r.Height + ")")

Remove-Item $report -ErrorAction SilentlyContinue
Write-Output ("已清掉旧报告: " + $report)

$pattern = $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
$pattern.Invoke()
Write-Output '已通过 UIA InvokePattern 点击'
Start-Sleep -Seconds 3

Write-Output ''
if (Test-Path $report) {
    Write-Output '=== 子进程收到的内容 ==='
    Get-Content $report | ForEach-Object { '  ' + $_ }
    Write-Output ''
    Write-Output '=== 结论 ==='
    $t = Get-Content $report -Raw
    if ($t -match 'argv\[2\]\s+= \[beta gamma\]') { Write-Output '  ✅ 带引号的参数被**完整**传递（没有被空格拆开）' } else { Write-Output '  ❌ 带引号的参数传递有问题' }
    if ($t -match 'argv\[3\]\s+= \[--flag=1\]')   { Write-Output '  ✅ 第三个参数也在' }
    if ($t -match 'GetCommandLineW = "(.*)"')    { Write-Output ('  ✅ 完整命令行 = ' + $Matches[1]) }
    if ($t -match 'GetCurrentDirectoryW = (.*)') { Write-Output ('  ⚠️ 子进程继承的当前目录 = ' + $Matches[1].Trim()) }
} else {
    Write-Output '❌ 报告文件没生成 —— 子进程根本没跑起来（或跑了但没写成功）'
    Write-Output ("   期望路径: " + $report)
}
