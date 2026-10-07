# click-only.ps1 -- 只做一件事：通过 UIA 点一下注入的按钮，并把"点击耗时 + 面板是否还响应"量出来。
#
# 为什么需要它（而不复用 click-testlink.ps1）：那个脚本断言的是"winver.exe 被拉起"，
# 而验 T3（action=pipe）时点击**不该**起进程。这里改成量三件与 T3 直接相关的事：
#   1. UIA Invoke 的往返耗时（若 TAP 在 UI 线程上等管道，这里会明显变大，≈ WaitNamedPipe 的 200ms）
#   2. 点击后**立刻**再读一次面板元素（证明 ShellHost 的 UI 线程没被卡住）
#   3. TAP 日志里"点击"与"管道结果"两行的 tid 是否不同（证明管道 IO 确实离开了 UI 线程）
#
# 用法: click-only.ps1 [-ButtonName TestLink] [-LogPath <vcxtap.log>]

param(
    [string]$ButtonName = 'TestLink',
    [string]$LogPath = ''
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class CO
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

function Get-Root {
    $panel = [CO]::GetForegroundWindow()
    if ($panel -eq [IntPtr]::Zero -or [CO]::Cls($panel) -ne 'ControlCenterWindow') { return $null }
    foreach ($k in [CO]::Kids($panel)) {
        try { if ($AE::FromHandle($k).Current.FrameworkId -eq 'XAML') { return $AE::FromHandle($k) } } catch { }
    }
    return $null
}

$root = Get-Root
if (-not $root) { Write-Output 'PANEL NOT OPEN (先把快速设置面板调到前台)'; exit 1 }

$cond = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)),
    (New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, $ButtonName)))
$btn = $root.FindFirst($TS::Descendants, $cond)
if (-not $btn) { Write-Output "button [$ButtonName] NOT FOUND"; exit 1 }

$r = $btn.Current.BoundingRectangle
Write-Output ("找到 [$ButtonName] @ (" + [int]$r.X + "," + [int]$r.Y + " " + [int]$r.Width + "x" + [int]$r.Height + ")")

# ---- 1) 量 Invoke 往返 ----
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$pattern = $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
$pattern.Invoke()
$sw.Stop()
$invokeMs = $sw.ElapsedMilliseconds
Write-Output ("UIA Invoke 往返: " + $invokeMs + " ms")

# ---- 2) 点击后立刻再读面板，量 UIA 是否还响应 ----
$sw2 = [System.Diagnostics.Stopwatch]::StartNew()
$btn2 = (Get-Root).FindFirst($TS::Descendants, $cond)
$sw2.Stop()
if ($btn2) {
    $r2 = $btn2.Current.BoundingRectangle
    Write-Output ("点击后立刻再读面板: " + $sw2.ElapsedMilliseconds + " ms，按钮仍在 (" + [int]$r2.X + "," + [int]$r2.Y + ")")
} else {
    Write-Output ("点击后立刻再读面板: 按钮没找到（" + $sw2.ElapsedMilliseconds + " ms）")
}

# ---- 3) 结论 ----
Write-Output ''
Write-Output '=== 结论 ==='
if ($invokeMs -lt 120) {
    Write-Output ("  ✅ Invoke 往返 " + $invokeMs + " ms < 120ms —— UI 线程没有被管道 IO 拖住")
} else {
    Write-Output ("  ❌ Invoke 往返 " + $invokeMs + " ms —— 偏大，怀疑 TAP 在 UI 线程上做了阻塞操作（WaitNamedPipe 是 200ms）")
}
if ($sw2.ElapsedMilliseconds -lt 300) {
    Write-Output ("  ✅ 点击后 UIA 仍可在 " + $sw2.ElapsedMilliseconds + " ms 内读到面板 —— ShellHost UI 线程活着")
} else {
    Write-Output ("  ⚠️ 点击后读面板用了 " + $sw2.ElapsedMilliseconds + " ms —— 可能被卡过")
}

if ($LogPath -and (Test-Path $LogPath)) {
    Write-Output ''
    Write-Output '--- TAP 日志：点击与管道结果的 tid ---'
    Get-Content $LogPath | Select-String 'action=pipe|pipe:|管道名' |
        Select-Object -Last 6 | ForEach-Object { '  ' + $_.Line }
}
