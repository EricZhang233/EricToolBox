# check-button-text.ps1 -- 读底栏里注入的那个按钮的 Name，并与期望值比较。
#
# 为什么要单独一个脚本：期望值是中文，而**控制台/子进程 stdout 的编码**会把中文再搞乱一次，
# 于是"编码对不对"这个结论就不可靠了（分不清是 UIA 读错了、还是打印错了）。
# 所以这里：在**进程内**比较（PowerShell 内部是 UTF-16，比较是可靠的），
# 只把 ASCII 的 PASS/FAIL 打出来，另附**码点**（\uXXXX）供人工核对。
#
# 用法: check-button-text.ps1 -Expect 音量合成器 [-Container Footer]

param(
    [Parameter(Mandatory = $true)][string]$Expect,
    [string]$Container = 'Footer'
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class CBT
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

$panel = [CBT]::GetForegroundWindow()
if ($panel -eq [IntPtr]::Zero -or [CBT]::Cls($panel) -ne 'ControlCenterWindow') {
    Write-Output 'PANEL NOT OPEN'
    exit 1
}
$root = $null
foreach ($k in [CBT]::Kids($panel)) {
    try { if ($AE::FromHandle($k).Current.FrameworkId -eq 'XAML') { $root = $AE::FromHandle($k); break } } catch { }
}
if (-not $root) { Write-Output 'XAML host not found'; exit 1 }

# 把一串文本转成 \uXXXX 码点形式（只含 ASCII，输出安全）
function Esc([string]$s) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        $c = [int][char]$ch
        if ($c -ge 0x20 -and $c -lt 0x7F) { [void]$sb.Append([char]$c) }
        else { [void]$sb.Append('\u{0:X4}' -f $c) }
    }
    return $sb.ToString()
}

$cond = New-Object System.Windows.Automation.PropertyCondition(
    $AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)

# 找到那个 Container（默认 Footer 分组）下的所有按钮，取**最后一个**（注入的按钮是追加在最后的）
$grpCond = New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, $Container)
$groups = $root.FindAll($TS::Descendants, $grpCond)
$scope = $null
for ($i = 0; $i -lt $groups.Count; $i++) {
    if ($groups[$i].Current.ControlType.ProgrammaticName -eq 'ControlType.Group') { $scope = $groups[$i]; break }
}
if (-not $scope) { $scope = $root }

$btns = $scope.FindAll($TS::Descendants, $cond)
Write-Output ("容器里的按钮数 = " + $btns.Count)
$names = @()
for ($i = 0; $i -lt $btns.Count; $i++) {
    $n = $btns[$i].Current.Name
    $r = $btns[$i].Current.BoundingRectangle
    $names += $n
    Write-Output ("  [$i] name=$n  code=" + (Esc $n) + "  rect=(" + [int]$r.X + "," + [int]$r.Y + " " + [int]$r.Width + "x" + [int]$r.Height + ")")
}

Write-Output ''
Write-Output ('期望码点 = ' + (Esc $Expect))
$hit = $names | Where-Object { $_ -eq $Expect }
if ($hit) {
    Write-Output 'RESULT: PASS'
} else {
    Write-Output 'RESULT: FAIL'
}
