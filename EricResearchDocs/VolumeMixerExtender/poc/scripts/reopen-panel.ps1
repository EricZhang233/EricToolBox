# reopen-panel.ps1 -- 真正让面板的 XAML 树重建，并用 **TAP 自己的日志**当判据。
#
# 为什么不用窗口状态判断"关没关"：band=4 的 HWND 常驻，IsWindowVisible 一直为真；
#   前台窗口类名也不可靠（实测 Esc 之后仍显示 on-top）。这些启发式都骗过我。
#   唯一可靠的判据是：**TAP 有没有再次收到 `Footer appeared`** —— 那是树被重建的直接证据。
#
# 顺带把"新旧 Footer 的句柄（ABI 指针）"打出来：如果两者相同，就正好复现了
#   "分配器复用地址 -> 指针身份型幂等守卫误判" 那个场景（见 docs/verified-after-injection/09-*）。
#
# 用法: reopen-panel.ps1 [-LogPath <vcxtap.log>] [-Rounds 1]

param(
    [string]$LogPath = '',
    [int]$Rounds = 1
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_paths.ps1')
if (-not $LogPath) { $LogPath = Join-Path $PocDir 'vcxtap.log' }

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class RP {
    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit)] public struct InputUnion { [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public InputUnion U; }
    [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint n, INPUT[] p, int cb);
    [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint mapType);

    static INPUT Ki(ushort vk, bool up) {
        var i = new INPUT(); i.type = 1;
        i.U.ki = new KEYBDINPUT { wVk = vk, wScan = (ushort)MapVirtualKey(vk, 0), dwFlags = up ? 2u : 0u, dwExtraInfo = IntPtr.Zero };
        return i;
    }
    public static void Key(ushort vk) { var a = new INPUT[] { Ki(vk,false), Ki(vk,true) }; SendInput(2, a, Marshal.SizeOf(typeof(INPUT))); }
    // Win 组合键
    public static void WinCombo(ushort vk) {
        var l = new List<INPUT>();
        l.Add(Ki(0x5B, false));                       // LWIN down
        l.Add(Ki(vk, false)); l.Add(Ki(vk, true));
        l.Add(Ki(0x5B, true));
        var a = l.ToArray();
        SendInput((uint)a.Length, a, Marshal.SizeOf(typeof(INPUT)));
    }
    public static void WinCtrlCombo(ushort vk) {
        var l = new List<INPUT>();
        l.Add(Ki(0x5B, false)); l.Add(Ki(0x11, false));
        l.Add(Ki(vk, false)); l.Add(Ki(vk, true));
        l.Add(Ki(0x11, true)); l.Add(Ki(0x5B, true));
        var a = l.ToArray();
        SendInput((uint)a.Length, a, Marshal.SizeOf(typeof(INPUT)));
    }
}
'@

function Get-FooterLines {
    if (-not (Test-Path $LogPath)) { return @() }
    return @(Get-Content $LogPath | Select-String 'Footer appeared' | ForEach-Object { $_.Line })
}

$closeCandidates = @(
    @{ name = 'Win+D(显示桌面)'; action = { [RP]::WinCombo(0x44) } },
    @{ name = 'Win+A';           action = { [RP]::WinCombo(0x41) } },
    @{ name = 'Esc';             action = { [RP]::Key(0x1B) } }
)

for ($round = 1; $round -le $Rounds; ++$round) {
    $before = Get-FooterLines
    Write-Output ("第 $round 轮：切换前 Footer 出现次数 = " + $before.Count)

    $reopened = $false
    foreach ($c in $closeCandidates) {
        Write-Output ("  关：发 " + $c.name)
        & $c.action
        Start-Sleep -Milliseconds 1200

        Write-Output '  开：发 Win+Ctrl+V'
        [RP]::WinCtrlCombo(0x56)                 # V
        Start-Sleep -Milliseconds 2500

        $after = Get-FooterLines
        if ($after.Count -gt $before.Count) {
            Write-Output ("  ✅ 树确实重建了（Footer 出现次数 " + $before.Count + " -> " + $after.Count + "），用的是 " + $c.name)
            $reopened = $true
            break
        }
        Write-Output ("  ✗ " + $c.name + " 之后没有新的 Footer，换一种关法")
    }

    if (-not $reopened) { Write-Output '  ❌ 这一轮没能让树重建'; exit 2 }

    # 打印最近两次 Footer 的句柄 —— 相同就意味着命中了"地址复用"场景
    $all = Get-FooterLines
    $last2 = $all | Select-Object -Last 2
    foreach ($l in $last2) {
        if ($l -match 'handle=([0-9A-F]+)') { Write-Output ('     Footer handle = ' + $Matches[1]) }
    }
    if ($last2.Count -eq 2) {
        $h1 = $null; $h2 = $null
        if ($last2[0] -match 'handle=([0-9A-F]+)') { $h1 = $Matches[1] }
        if ($last2[1] -match 'handle=([0-9A-F]+)') { $h2 = $Matches[1] }
        if ($h1 -eq $h2) {
            Write-Output '  ★ 新旧 Footer 句柄**相同** —— 正好是"地址复用"场景（指针身份型守卫会误判）'
        } else {
            Write-Output '    新旧 Footer 句柄不同'
        }
    }
}
