# toggle-panel.ps1 -- 真正地"关掉再打开"快速设置面板（而不是只在它已经开着时读一次）。
#
# 为什么需要它：qs-panel-probe.ps1 只在"面板没开"时才发 Win+Ctrl+V，
#   面板已经开着时它什么都不做 —— 所以拿它做多轮测试会一直读**同一个树**，
#   看起来"每轮都在"，实际上没测到"重建"这条路径。
#   而"关掉再打开"恰恰是 XAML 元素重建、也是幂等判定最容易出错的地方。
#
# 做法：发一次 Win+Ctrl+V（切换）。发之前先确认当前状态，发之后确认状态**确实变了**。

# 为什么先 Esc 再快捷键：Win+Ctrl+V 是"打开声音输出页"，**不是 toggle** ——
#   面板已经开着时它什么都不做（实测踩过：以为在开关，其实一直在读同一个树）。
#   Esc 才能关掉它。顺序：Esc（关）-> 校验确实关了 -> Win+Ctrl+V（开）-> 校验确实开了。

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class TP {
    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit)] public struct InputUnion { [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public InputUnion U; }
    [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint n, INPUT[] p, int cb);
    [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint mapType);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowW(string cls, string title);

    static INPUT Ki(ushort vk, bool up) {
        var i = new INPUT(); i.type = 1;
        i.U.ki = new KEYBDINPUT { wVk = vk, wScan = (ushort)MapVirtualKey(vk, 0), dwFlags = up ? 2u : 0u, dwExtraInfo = IntPtr.Zero };
        return i;
    }
    public static void Key(ushort vk) {
        var a = new INPUT[] { Ki(vk, false), Ki(vk, true) };
        SendInput(2, a, Marshal.SizeOf(typeof(INPUT)));
    }
    public static void HotkeyWinCtrlV() {
        ushort[] mods = { 0x5B, 0x11 }; ushort key = 0x56;
        var l = new List<INPUT>();
        foreach (var m in mods) l.Add(Ki(m, false));
        l.Add(Ki(key, false)); l.Add(Ki(key, true));
        for (int i = mods.Length - 1; i >= 0; i--) l.Add(Ki(mods[i], true));
        var a = l.ToArray();
        SendInput((uint)a.Length, a, Marshal.SizeOf(typeof(INPUT)));
    }
    public static string Cls(IntPtr h) { var s = new StringBuilder(512); GetClassName(h, s, s.Capacity); return s.ToString(); }
    // "面板是否开着" 用**前台窗口**判断 —— 这比 IsWindowVisible 可靠：
    // band=4 的 HWND 本身可能一直"visible"，但只有真正弹出时才在前台。
    public static bool PanelOnTop() {
        IntPtr fg = GetForegroundWindow();
        if (fg == IntPtr.Zero) return false;
        return Cls(fg) == "ControlCenterWindow";
    }
}
'@

function Show-State {
    if ([TP]::PanelOnTop()) { return 'on-top（开着）' } else { return 'not-on-top（关着/不在前台）' }
}

Write-Output ("  切换前： " + (Show-State))

if ([TP]::PanelOnTop()) {
    # 关：Esc
    [TP]::Key(0x1B)                       # VK_ESCAPE
    Start-Sleep -Milliseconds 1200
    if ([TP]::PanelOnTop()) {
        Write-Output '  ⚠️ Esc 没能关掉面板（前台窗口可能不是面板？）'
        exit 2
    }
    Write-Output '  ✅ Esc 关掉了'
}

# 开：Win+Ctrl+V
[TP]::HotkeyWinCtrlV()
Start-Sleep -Milliseconds 1500
if (-not [TP]::PanelOnTop()) {
    [TP]::HotkeyWinCtrlV()
    Start-Sleep -Milliseconds 1500
}
if (-not [TP]::PanelOnTop()) {
    Write-Output '  ⚠️ 快捷键没能打开面板'
    exit 2
}
Write-Output '  ✅ 快捷键打开了（树会被重建）'

