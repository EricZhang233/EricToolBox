# Win11 快速设置「声音输出」页 · XAML 注入开发笔记

> 导出时间：2026-10-02 23:5x GMT+8
> **更新：2026-10-03 —— 已在开发机复现实测，新增 §9 / §10（含 window band 屏蔽、元素树、WinEvent 实测）；并更正 §2.5、§4.1 的窗口定位方式。**
> 来源系统：Windows 11，build 26300，x64
> 内容：探测结论 + 全部脚本
> 用途：转移到开发机继续做「检测元素并在快速设置音量界面上加按钮」的项目
> 工具环境：`pwsh` 7.6.6（Windows PowerShell 5.1 在本环境被禁用）

---

## 0. 项目目标（Eric 定稿）

- 在 Windows 11 快速设置的**音量/声音界面**里**检测元素并加按钮**。
- 按钮形态：**落 XAML（注入）**，而非悬浮合成。
- 后台检测要**足够轻量、最好 0 占用**。
- **不使用第三方框架**（Windhawk / ExplorerPatcher 等只作参考，不作为依赖）；**注入、hook、往可视化树插元素全部自写**。
- **只在自己环境用**：不需要分发，不考虑 EV 签名 / attestation。

---

## 1. 快捷键的官方定义（微软文档原文）

> **Windows key+Ctrl+V** — *Open the sound output page of quick settings, which includes settings for the output device, spatial sound, and the volume mixer.*
> （打开快速设置的「声音输出」页面，含输出设备、空间音效、音量合成器设置。）

来源：
- https://support.microsoft.com/en-us/windows/keyboard-shortcuts-in-windows-dcc61a57-8ff0-cffe-9796-cb9706c75eec
- https://support.microsoft.com/en-us/accessibility/windows/keyboard-shortcuts-in-windows

相邻关系（别搞混）：
- `Win+V` = 剪贴板历史
- `Win+Ctrl+V` = 快速设置的「声音输出」页
- `Win+A` = 快速设置面板（整体）

> ⚠️ 更正记录：我一开始凭印象说「Win+Ctrl+V 不是标准快捷键」——**错的**，它是微软正式收录的组合键。

---

## 2. 本机实测结论（build 26300）

### 2.1 目标窗口三要素（关键成果）

| 项 | 值 |
|---|---|
| **宿主进程** | **`ShellHost.exe`**（本会话实测 pid 6592） |
| **窗口类名** | **`ControlCenterWindow`** |
| **窗口标题** | **`快速设置`** |

获取方式：发 `Win+Ctrl+V` 后查前台窗口，得到
`0x00130BEE pid=6592 class=[ControlCenterWindow] title=[快速设置]`。

### 2.2 注入可行性

| 方式 | 结果 |
|---|---|
| `SendInput`（带 scancode） | ✅ **有效**（对照 `Win+E` 成功打开资源管理器） |
| `keybd_event`（VK_LWIN 直发） | ❌ 未触发（至少 Win+Ctrl+V 没响应） |

结论：**用 `SendInput`，别用 `keybd_event`**；修饰键要正确按下/释放顺序。

### 2.3 会话前提

- exec 进程与 `explorer.exe` **同在 session 1**（交互桌面）→ 注入能到达 shell。
- 若你的运行环境是服务/session 0，注入无效。

### 2.4 顺带观察到的 shell XAML 相关窗口类（同机）

| 类名 | 归属 | 备注 |
|---|---|---|
| `ControlCenterWindow` | ShellHost | **目标**（快速设置） |
| `XamlExplorerHostIslandWindow` | explorer | 看到过 title=`任务切换`（Task View）——**说明快速设置很可能也是这类 XAML island 宿主** |
| `TopLevelWindowForOverflowXamlIsland` | explorer | 托盘溢出浮层 |
| `Windows.UI.Core.CoreWindow` (title=`DesktopWindowXamlSource`) | explorer / ShellHost | XAML island 的承载窗口 |
| `Shell_TrayWnd` | explorer | 任务栏 |

### 2.5 一个重要的工具性坑（必读）【§9.2 已更正：不是"快照 diff 的坑"，是 window band 屏蔽】

> **⚠️ 更正（2026-10-03 实测）**：真正的原因是**快速设置被创建在非默认 window band（实测 band = 4）**，Windows 因此把它从 `EnumWindows` / `FindWindow` / UIA `RootElement` 的枚举里**整体屏蔽**（任务栏 band = 6 同样看不见）。
> 下面这段"快照 diff"的说法**不完整**，请以 §9.2 为准。

`ControlCenterWindow` 在「EnumWindows 快照 diff」里**不一定作为"新窗口"出现**（它可能是常驻窗口的 show/hide，而不改 `IsWindowVisible`/cloak 状态）。因此：

- ❌ **不要靠"快照 diff 找新窗口"**来定位它；
- ✅ ~~直接 `FindWindow("ControlCenterWindow", NULL)`~~ ← **本 build 上返回 0，不成立**；
- ✅ **改用 `GetForegroundWindow()` + 类名判定**（面板打开时它就是前台窗口）。详见 §9.2。

（我第一版探针就是被这点误导，才误判"没弹出来"。）

---

## 3. 关键设计坑（做之前先看）

1. **浮层失焦即关**：快速设置是临时面板，**一失焦就自动关闭**。
   - 悬浮按钮窗口必须带 `WS_EX_NOACTIVATE`，点击**不能抢焦点**；
   - 不要 `SetForegroundWindow`；用 `PostMessage` / 直接执行逻辑；
   - 落 XAML 方案天然没有这个问题（你就是面板的一部分），这也是选注入的理由之一。
2. **轻量检测 = 事件驱动，不轮询**：
   - `SetWinEventHook`（`EVENT_OBJECT_SHOW/HIDE/CREATE`）监听浮层出现；
   - UIA 事件订阅（`AddAutomationEventHandler`）作用域缩到目标窗口；
   - 元素读取用 `IUIAutomationCacheRequest`，**一次跨进程取回**属性；
   - 空闲时进程挂在事件上 → **0 CPU**。
3. **UIA 跨进程是主要开销点**：作用域必须窄；别对全桌面订阅。
4. **注入的代价**（自写方案要自己扛）：
   - 代码住在 shell 进程里 → 写崩 = 崩 shell；
   - hook 点随 Windows 版本变（build 26300 很前沿，尤其脆）；
   - `CreateRemoteThread + LoadLibrary` 是木马经典手法 → Defender 可能拦，需进程/目录排除；
   - 必须做"hook 失败即安全退出"的兜底。
5. **官方没有扩展点**：Win11 不提供快速设置/音量界面的插件 API。所以只能自绘或注入。

---

## 4. 技术路线

### 4.1 检测元素

- 事件：`SetWinEventHook` 捕 `ShellHost.exe` 的窗口 show/hide；或 UIA 事件订阅。
- 定位：**`GetForegroundWindow()` + 类名判定**（§2.5 原文的 `FindWindow` 在本 build 无效，见 §9.2）。
- 读元素：UIA（`AutomationElement.FromHandle` → `FindAll(Descendants, TrueCondition)`），字段看 `ControlType / Name / AutomationId / ClassName`。

### 4.2 加按钮（两条路）

| | 悬浮层 | **注入落 XAML（本项目选）** |
|---|---|---|
| 额外进程/窗口 | 有 | 无 |
| 每次弹出开销 | 要 UIA 查询 + 定位 | 无 |
| 失焦掉面板 | 要 `NOACTIVATE` 躲 | 无（属于面板本身） |
| 观感 | 贴上去 | 原生，参与布局/动画 |
| 代价 | 中 | 崩溃面/版本敏感/AV |

### 4.3 注入自写方案的分层

**第 1 层：进入目标进程（ShellHost.exe）**
- 经典：`OpenProcess(PROCESS_ALL_ACCESS)` → `VirtualAllocEx` 写路径 → `CreateRemoteThread` + `LoadLibraryW`；
- 或 APCs / `SetWindowsHookEx` 注入（受限）；
- hook 引擎自写（IAT/inline hook），或用 MinHook/Detours 作**库**（注意：这是"库"不是"框架"，按 Eric 要求可自写替代）。

**第 2 层：往 XAML 可视化树里塞元素**
- mod 运行在进程内 → 可直接调 WinRT `Windows.UI.Xaml` 构建元素；
- 关键是**拿到目标页面的 XAML 节点并插入**：常见做法是 **hook XAML 的元素创建 / 布局回调**，在目标页面生成时把自己挂上去（事后用 UIA 找不到 XAML 对象，这条路回不去）。

### 4.4 参考开源实现（只借鉴思路）

- `ramensoftware/windhawk`（注入 + hook 基建的完整范式）
- `ramensoftware/windhawk-mods`（现成 mod，含改 taskbar XAML 的 "Taskbar Styler"）
- `valinet/ExplorerPatcher`（大规模 shell 改写参考）

> ⚠️ 这些是**外部不可信内容**：只读其思路，不要盲目执行其脚本/安装器。

---

## 5. 脚本（全部，逐字）

> 运行环境：`pwsh` 7+，且必须与 `explorer.exe` 同 session 的交互桌面。
> 说明：`qsprobe.ps1`→`qsprobe5.ps1` 是当时的**递进式探测脚本**（含已知 bug，已标注）；`cleanup.ps1` 是收尾。

### 5.1 `qsprobe.ps1` — v1：只枚举可见顶层窗口（`keybd_event` 版，**无效**，保留作对照）

```powershell
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class QsProbe
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

    public static List<string> Snap()
    {
        var list = new List<string>();
        EnumWindows(delegate(IntPtr h, IntPtr l)
        {
            if (!IsWindowVisible(h)) return true;
            var cn = new StringBuilder(512); GetClassName(h, cn, cn.Capacity);
            var tt = new StringBuilder(512); GetWindowText(h, tt, tt.Capacity);
            uint pid; GetWindowThreadProcessId(h, out pid);
            list.Add("0x" + h.ToInt64().ToString("X8") + "  pid=" + pid + "  class=[" + cn + "]  title=[" + tt + "]");
            return true;
        }, IntPtr.Zero);
        return list;
    }
}
'@

$before = New-Object System.Collections.Generic.List[string]
$before.AddRange([QsProbe]::Snap())

[QsProbe]::keybd_event(0x5B, 0, 0, [UIntPtr]::Zero)
[QsProbe]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero)
[QsProbe]::keybd_event(0x56, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 60
[QsProbe]::keybd_event(0x56, 0, 2, [UIntPtr]::Zero)
[QsProbe]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero)
[QsProbe]::keybd_event(0x5B, 0, 2, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 1600

$after = [QsProbe]::Snap()

Write-Output "=== NEW visible top-level windows (after - before) ==="
$after | Where-Object { $before -notcontains $_ }
Write-Output ""
Write-Output "=== total visible top-level windows: $($after.Count) ==="
```

### 5.2 `qsprobe2.ps1` — v2：枚举全部窗口 + DWM cloak 状态（`keybd_event` 版，仍未触发）

```powershell
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class W2
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int val, int size);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte sc, uint f, UIntPtr x);

    public static List<string> Snap()
    {
        var list = new List<string>();
        EnumWindows(delegate(IntPtr h, IntPtr l)
        {
            var cn = new StringBuilder(512); GetClassName(h, cn, cn.Capacity);
            var tt = new StringBuilder(512); GetWindowText(h, tt, tt.Capacity);
            uint pid; GetWindowThreadProcessId(h, out pid);
            int clk = -1;
            try { DwmGetWindowAttribute(h, 14, out clk, 4); } catch { }
            list.Add("0x" + h.ToInt64().ToString("X8") + " pid=" + pid + " vis=" + (IsWindowVisible(h) ? "1" : "0") + " cloak=" + clk + " class=[" + cn + "] title=[" + tt + "]");
            return true;
        }, IntPtr.Zero);
        return list;
    }
}
'@

Write-Output ("session of this process = " + (Get-Process -Id $PID).SessionId)
Write-Output ("explorer session        = " + ((Get-Process explorer -ErrorAction SilentlyContinue | Select-Object -First 1).SessionId))

$before = New-Object System.Collections.Generic.List[string]
$before.AddRange([W2]::Snap())
$fg0 = [W2]::GetForegroundWindow()

[W2]::keybd_event(0x5B, 0, 0, [UIntPtr]::Zero)
[W2]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero)
[W2]::keybd_event(0x56, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 60
[W2]::keybd_event(0x56, 0, 2, [UIntPtr]::Zero)
[W2]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero)
[W2]::keybd_event(0x5B, 0, 2, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 1800

$after = [W2]::Snap()
$fg1 = [W2]::GetForegroundWindow()

Write-Output ""
Write-Output ("fg before = 0x" + $fg0.ToInt64().ToString("X8") + "   fg after = 0x" + $fg1.ToInt64().ToString("X8"))
Write-Output ""
Write-Output "=== DIFF (before -> after) ==="
Compare-Object $before $after | ForEach-Object { $_.SideIndicator + " " + $_.InputObject }
Write-Output ""
Write-Output "=== ALL top-level windows (after) ==="
$after
```

### 5.3 `qsprobe3.ps1` — v3：改用 `SendInput` + 三组对照（⚠️ 有 bug：输出被函数吞掉）

```powershell
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class W3
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int val, int size);

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    public struct HARDWAREINPUT { public uint uMsg; public ushort wParamL; public ushort wParamH; }
    [StructLayout(LayoutKind.Explicit)]
    public struct InputUnion { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; [FieldOffset(0)] public HARDWAREINPUT hi; }
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public InputUnion U; }

    [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
    [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint uCode, uint uMapType);

    const uint KEYEVENTF_KEYUP = 0x0002;

    static INPUT Ki(ushort vk, bool up)
    {
        var inp = new INPUT();
        inp.type = 1;
        inp.U.ki = new KEYBDINPUT { wVk = vk, wScan = (ushort)MapVirtualKey(vk, 0), dwFlags = up ? KEYEVENTF_KEYUP : 0, time = 0, dwExtraInfo = IntPtr.Zero };
        return inp;
    }

    public static int Combo(ushort[] mods, ushort key)
    {
        var list = new List<INPUT>();
        foreach (var m in mods) list.Add(Ki(m, false));
        list.Add(Ki(key, false));
        list.Add(Ki(key, true));
        for (int i = mods.Length - 1; i >= 0; i--) list.Add(Ki(mods[i], true));
        var arr = list.ToArray();
        Thread.Sleep(80);
        return (int)SendInput((uint)arr.Length, arr, Marshal.SizeOf(typeof(INPUT)));
    }

    public static List<string> Snap()
    {
        var list = new List<string>();
        EnumWindows(delegate(IntPtr h, IntPtr l)
        {
            var cn = new StringBuilder(512); GetClassName(h, cn, cn.Capacity);
            var tt = new StringBuilder(512); GetWindowText(h, tt, tt.Capacity);
            uint pid; GetWindowThreadProcessId(h, out pid);
            int clk = -1; try { DwmGetWindowAttribute(h, 14, out clk, 4); } catch { }
            list.Add("0x" + h.ToInt64().ToString("X8") + " pid=" + pid + " vis=" + (IsWindowVisible(h) ? "1" : "0") + " cloak=" + clk + " class=[" + cn + "] title=[" + tt + "]");
            return true;
        }, IntPtr.Zero);
        return list;
    }
}
'@

$LWIN = [UInt16]0x5B; $CTRL = [UInt16]0x11; $A = [UInt16]0x41; $E = [UInt16]0x45; $V = [UInt16]0x56

function Test-Combo($name, [UInt16[]]$mods, [UInt16]$key, $prev) {
    $r = [W3]::Combo($mods, $key)
    Start-Sleep -Milliseconds 1600
    $now = [W3]::Snap()
    Write-Output ""
    Write-Output ("### $name   (SendInput returned $r events; new windows below)")
    $new = $now | Where-Object { $prev -notcontains $_ }
    if ($new) { $new } else { Write-Output "  (no change)" }
    return ,$now
}

$s0 = [W3]::Snap()

$s1 = Test-Combo "T1  Win+Ctrl+V" @($LWIN, $CTRL) $V $s0
$s2 = Test-Combo "T2  Win+A"      @($LWIN)        $A $s1
$s3 = Test-Combo "T3  Win+E"      @($LWIN)        $E $s2

Write-Output ""
Write-Output "=== current foreground-ish: all visible windows ==="
[W3]::Snap() | Where-Object { $_ -match 'vis=1' }
```

> **BUG 说明**：`Test-Combo` 里 `Write-Output` 的内容会被 `$s1 = Test-Combo ...` 赋值吞掉 → T1/T2 的结果没打印出来。修正版见 5.4。**但这次运行证实了 `SendInput` 有效**（T3 的 `Win+E` 打开了资源管理器）。

### 5.4 `qsprobe5.ps1` — v5：**成功抓到目标窗口**（推荐参考版）

```powershell
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class W5
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int val, int size);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();

    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] public struct HARDWAREINPUT { public uint uMsg; public ushort wParamL; public ushort wParamH; }
    [StructLayout(LayoutKind.Explicit)] public struct InputUnion { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; [FieldOffset(0)] public HARDWAREINPUT hi; }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public InputUnion U; }
    [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
    [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint uCode, uint uMapType);

    const uint KEYEVENTF_KEYUP = 0x0002;
    static INPUT Ki(ushort vk, bool up)
    {
        var i = new INPUT(); i.type = 1;
        i.U.ki = new KEYBDINPUT { wVk = vk, wScan = (ushort)MapVirtualKey(vk, 0), dwFlags = up ? KEYEVENTF_KEYUP : 0, time = 0, dwExtraInfo = IntPtr.Zero };
        return i;
    }
    public static int Combo(ushort[] mods, ushort key)
    {
        var l = new List<INPUT>();
        foreach (var m in mods) l.Add(Ki(m, false));
        l.Add(Ki(key, false)); l.Add(Ki(key, true));
        for (int i = mods.Length - 1; i >= 0; i--) l.Add(Ki(mods[i], true));
        var a = l.ToArray(); Thread.Sleep(120);
        return (int)SendInput((uint)a.Length, a, Marshal.SizeOf(typeof(INPUT)));
    }
    public static List<string> Snap()
    {
        var list = new List<string>();
        EnumWindows(delegate(IntPtr h, IntPtr l)
        {
            var cn = new StringBuilder(512); GetClassName(h, cn, cn.Capacity);
            var tt = new StringBuilder(512); GetWindowText(h, tt, tt.Capacity);
            uint pid; GetWindowThreadProcessId(h, out pid);
            int clk = -1; try { DwmGetWindowAttribute(h, 14, out clk, 4); } catch { }
            list.Add("0x" + h.ToInt64().ToString("X8") + " pid=" + pid + " vis=" + (IsWindowVisible(h) ? "1" : "0") + " cloak=" + clk + " class=[" + cn + "] title=[" + tt + "]");
            return true;
        }, IntPtr.Zero);
        return list;
    }
    public static string Fg()
    {
        var h = GetForegroundWindow();
        var cn = new StringBuilder(512); GetClassName(h, cn, cn.Capacity);
        var tt = new StringBuilder(512); GetWindowText(h, tt, tt.Capacity);
        uint pid; GetWindowThreadProcessId(h, out pid);
        return "0x" + h.ToInt64().ToString("X8") + " pid=" + pid + " class=[" + cn + "] title=[" + tt + "]";
    }
}
'@

$LWIN = [UInt16]0x5B; $CTRL = [UInt16]0x11; $V = [UInt16]0x56

$s0 = [W5]::Snap()
Write-Host ("FG before: " + [W5]::Fg())

[void][W5]::Combo(@($LWIN, $CTRL), $V)
Start-Sleep -Milliseconds 1200

$s1 = [W5]::Snap()
Write-Host ""
Write-Host ("FG after : " + [W5]::Fg())
Write-Host ""
Write-Host "### NEW windows (vs before) ###"
$new = @($s1 | Where-Object { $s0 -notcontains $_ })
if ($new.Count -eq 0) { Write-Host "  (none)" } else { $new | ForEach-Object { Write-Host ("  " + $_) } }

Write-Host ""
Write-Host "### windows whose vis/cloak changed ###"
for ($i = 0; $i -lt $s0.Count; $i++) {
    if ($s1 -contains $s0[$i]) { continue }
    $hw = ($s0[$i] -split ' ')[0]
    $m = $s1 | Where-Object { $_.StartsWith($hw + " ") } | Select-Object -First 1
    if ($m) { Write-Host ("  before: " + $s0[$i]); Write-Host ("  after : " + $m) }
}

Write-Host ""
Write-Host "### all shell-ish windows now ###"
$s1 | Where-Object { $_ -match 'Xaml|CoreWindow|TrayWnd|Island|Windows\.UI|ShellExperience|pid=6592 |pid=23496 ' }
```

**这次的关键输出**：

```
FG before: 0x00B80DBE pid=38864 class=[Chrome_WidgetWin_1] title=[OpenClaw Control - ...]
FG after : 0x00130BEE pid=6592 class=[ControlCenterWindow] title=[快速设置]
```

### 5.5 `cleanup.ps1` — 收尾：关掉实验开出的资源管理器窗口（按精确句柄）

```powershell
$want = [Convert]::ToInt32("F1068", 16)   # 0x000F1068, the CabinetWClass window opened by probe3
$sh = New-Object -ComObject Shell.Application
$targets = @($sh.Windows()) | Where-Object { $_.HWND -eq $want }
if ($targets.Count -gt 0) {
    $targets | ForEach-Object { $_.Quit() }
    Write-Host ("closed " + $targets.Count + " window(s) (hwnd 0x000F1068)")
} else {
    Write-Host "target window 0x000F1068 not found (already closed)"
}
```

### 5.6 草稿（⚠️ **未运行**）：UIA 元素树 dump —— 开发机上的第一步

> 因 Eric 喊停，这个脚本**没有在本机执行过**。逻辑上正确，但请把"未验证"当默认状态。
> 用法：**你自己先按 `Win+Ctrl+V` 打开浮层**（不要用脚本注入），再运行本脚本（它只读、不注入）。

```powershell
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class W6
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string win);
}
'@

$h = [W6]::FindWindow("ControlCenterWindow", $null)
Write-Host ("ControlCenterWindow hwnd = 0x" + $h.ToInt64().ToString("X8"))
if ($h -eq [IntPtr]::Zero) { Write-Host "not open - open it with Win+Ctrl+V first"; exit }

try {
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes -ErrorAction Stop
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($h)
    Write-Host ("UIA root : name=[" + $root.Current.Name + "] class=[" + $root.Current.ClassName + "] type=" + $root.Current.ControlType.ProgrammaticName)
    $r = $root.Current.BoundingRectangle
    Write-Host ("rect     : " + $r.X + "," + $r.Y + "  " + $r.Width + "x" + $r.Height)
    $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    Write-Host ("descendants = " + $all.Count)
    $i = 0
    foreach ($e in $all) {
        $i++; if ($i -gt 200) { Write-Host "  ... (truncated)"; break }
        $c = $e.Current
        Write-Host ("  [" + $i.ToString("000") + "] " + $c.ControlType.ProgrammaticName.Replace("ControlType.","") + "  name=[" + $c.Name + "]  id=[" + $c.AutomationId + "]  cls=[" + $c.ClassName + "]")
    }
} catch {
    Write-Host ("UIA failed: " + $_.Exception.Message)
    Write-Host ("  type: " + $_.Exception.GetType().FullName)
}
```

> 备注：若 `Add-Type -AssemblyName UIAutomationClient` 在裸 pwsh 里失败，用 .NET Framework 的 `powershell.exe`(5.1) 跑这个脚本，或改用 `UIAutomationCore` 的 COM 封装。

### 5.7 未落盘的脚本

- `qsprobe4.ps1`：写过但被 Eric 的消息打断，**未落盘**（内容是 `CloseByClass` 版 + T1/T2 对照，功能已被 5.4/5.5 覆盖）。

---

## 6. 下一步（在开发机上）

1. ~~**只读**：手按 `Win+Ctrl+V` → 跑 5.6 → 拿到「声音输出」页的 **元素类名 / AutomationId / 层级**，定位到你要挂按钮的容器。~~
   ✅ **已完成**（2026-10-03）：元素树 + AutomationId 已拿到，见 §9.4 / §9.5；定位方式见 §9.2（**不是 FindWindow**）。
2. 决定 **hook 点**：XAML 元素创建/布局回调（在目标页面生成时插入自己的元素）。
3. 写**最小注入验证**：注入 `ShellHost.exe` → 在页面上加一个可见元素（先不绑逻辑）。
4. 验证通过后，再做**事件驱动的检测**（`SetWinEventHook` + 窄作用域 UIA），确认空闲 0 占用。
   ⚠️ **前置未知项**：band 窗口虽然不进枚举，但事件是否照发？必须先实测（见 §9.6-1）。
5. 兜底：hook 失败 → 安全退出，不拖垮 shell。

---

## 7. 运行环境约束

- 脚本要跑在**与 `explorer.exe` 同 session 的交互桌面**下（读取与注入都依赖此前提）。
- `pwsh` 7+（脚本里的 C# 代码在 .NET Framework 5.1 下亦可，见 5.6 备注）。
- shell 相关 UIA 树/窗口类**不是公开契约**，build 一变就可能失效；请把“版本适配”当常态。

---

## 8. 附：同会话另一个项目（虚拟音频设备，节选结论）

> 与本项目独立。完整方案已另存桌面：`VirtualAudio-Record-Mirror-Plan.md`（v6）。

- **目标**：录屏时把默认播放设备切到自建虚拟设备 V；V 输出「无音效、恒 100% 满幅」的干净数字流给录屏软件；同时把 V 镜像到指定真实设备 R 供监听。
- **已锁定**：内核驱动（PortCls，基于微软 SYSVAD 改造）；**仅一个 Render 端点** `OC Virtual Speaker`；**音量硬锁 100%（驱动音量节点范围固定 0 dB、不衰减）**；**不做音量路由/代理**；无自动化（默认设备手动切）；监听程序设置页只有「选择监听设备 R」。
- **关键点**：录制电平恒满幅，与监听音量完全无关（避免"以 50% 录 → 分享更小声"）；快速设置里的音量键在 V 上无反应属**已知并接受**。
- **工具链**：VS + WDK；本机自用走测试签名。

---

## 9. 开发机复现：定位窗口的正确姿势（2026-10-03 实测）

> 本节**更正 §2.5、§4.1**。结论：这个窗口之所以"抓不到"，不是快照 diff 的锅，而是它被创建在**非默认 window band**里，**枚举层面被屏蔽**。

### 9.1 环境（实测）

| 项 | 值 |
|---|---|
| OS | Windows 11 专业版，**build 26300.9550**（registry `CurrentBuild`=26300，`UBR`=9550；`Environment.OSVersion`=10.0.26300.0） |
| 会话 | 脚本与 `explorer.exe` / `ShellHost.exe` **同在 session 2**（交互桌面）✅ |
| PowerShell | 已装 **pwsh 7.6.6**：`C:\Program Files\PowerShell\7\pwsh.exe` |
| 宿主进程 | `ShellHost.exe`（本次 pid 3704，属 session 2） |
| 注 | `GetShellWindow()` 返回 `Progman`（pid 4872，即 explorer）；`FindWindow('Progman')` 可用 |

> ⚠️ **§5.6 的备注已过时**：这台机器上 `pwsh` 7.6.6 里 `Add-Type -AssemblyName UIAutomationClient` **成功**，`[System.Windows.Automation.AutomationElement]::RootElement` 也能用。UIA 不再必须退回 5.1（但 5.1 依然可用，本节的脚本两边都能跑）。

### 9.2 决定性发现：快速设置是「非默认 window band」窗口

`EnumWindows` 共 127 个窗口，按 `GetWindowBand`（user32 未文档化导出，`GetProcAddress` 取）统计：

| band | 数量 | 说明 |
|---|---|---|
| 1 | 117 | 普通窗口（`Progman`、Chrome 等） |
| 2 | 6 | |
| 16 | 4 | |

**被 `EnumWindows` 完全排除的（实测出现次数 = 0）**：

| 类名 | band |
|---|---|
| **`ControlCenterWindow`**（快速设置） | **4** |
| `Shell_TrayWnd` / `Shell_SecondaryTrayWnd`（任务栏） | **6** |
| `XamlExplorerHostIslandWindow` | — |
| `TopLevelWindowForOverflowXamlIsland` | — |

**规则（实测归纳）**：band ≥ 3 的「沉浸式」band 窗口**不进 `EnumWindows` 的链表**；band 1（默认桌面）/2/16（system tools）才进。
而 `FindWindow` 和 UIA 的 `RootElement` 都建立在同一套枚举之上 → **三个接口全都看不到它**。
（之前 §2.4 说"看到过 `Shell_TrayWnd`"，与本次实测矛盾 —— 本次 4 个接口一致地看不到任务栏。）

**仍然能拿到 HWND 的接口（实测可用）**：

- ✅ `GetForegroundWindow()` —— 面板打开时它**就是**前台窗口；
- ✅ `GetGUIThreadInfo(tid)` —— `hwndActive` 亦指向它；
- ✅ `GetWindowBand(hwnd, &band)` —— 用来验证/区分。

```text
panel hwnd = 0x000100FE pid=3704 class=[ControlCenterWindow] title=[快速设置] band=4
FindWindow('ControlCenterWindow') would return : 0     ← 失效
```

### 9.3 真正的 XAML 内容在**子窗口**里

`ControlCenterWindow` 本身在 UIA 里只是个**空壳**：

```text
0x000100FE [ControlCenterWindow]                    -> type=Pane framework=Win32  children=0
0x000302A6 [Windows.UI.Input.InputSite.WindowClass] -> type=Pane framework=XAML   children=2
```

- `AutomationElement.FromHandle(ControlCenterWindow)` → `FrameworkId = Win32`、**0 个子元素**（什么都拿不到）；
- 面板有且只有 1 个子窗口：`Windows.UI.Input.InputSite.WindowClass`，它才是 XAML island 宿主（`FrameworkId = XAML`），**整套自动化树在它下面**。

👉 正确链路：

```text
GetForegroundWindow()                                  # 拿到面板（枚举拿不到）
  → 类名 == "ControlCenterWindow"
  → EnumChildWindows(panel) 找到 class 含 "InputSite" 的子窗口
  → AutomationElement.FromHandle(子窗口)
  → 完整 XAML 树
```

### 9.4 「声音输出」页元素树（`Win+Ctrl+V` 打开后实测，完整 28 项）

```text
Pane |  | id= | Windows.UI.Input.InputSite.WindowClass
| Group | 媒体传输控件 | id=MediaTransportControls | NamedContainerAutomationPeer | offscreen
| Group | 快速设置 | id=ControlCenterRegion | NamedContainerAutomationPeer
| | Group | 声音输出 | id=PageWindow | NamedContainerAutomationPeer
| | | Button | 后退 | id=BackButton | Button
| | | Text | 声音输出 | id=PageTitleText | TextBlock
| | | Group | Windows 徽标键，控件， | id= | NamedContainerAutomationPeer
| | | | Text | Ctrl | id= | TextBlock
| | | | Text | V | id= | TextBlock
| | | Pane |  | id=ListContent | ScrollViewer
| | | | Text | 输出设备 | id=OutputGroupTitle | TextBlock
| | | | List | 输出设备 | id=ListWithOutputGroupTitle | ListView
| | | | | ListItem | 远程音频 | id= | ListViewItem
| | | | | | Group | 远程音频 | id= | NamedContainerAutomationPeer
| | | | Text | 空间音效 | id=SpatialGroupTitle | TextBlock
| | | | List | 空间音效 | id= | ListView
| | | | | ListItem | 关 | id= | ListViewItem
| | | | | | Text | 关 | id=TitleText | TextBlock
| | | | Text | 音量合成器 | id=MixerGroupTitle | TextBlock
| | | | Button | 音量合成器，更多合成器设置 | id= | Button
| | | | List | 音量合成器 | id= | ListView
| | | | | ListItem | 系统声音 | id= | ListViewItem
| | | | | | Group | 系统声音 | id= | NamedContainerAutomationPeer
| | | | | | | Button | 系统声音 (将应用设为静音) | id= | ToggleButton
| | | | | | | Slider | 音量 | id=AppVolumeLevel | Slider
| | | Group |  | id=Footer | LandmarkTarget
| | | | Button | 更多音量设置 | id= | Button
| | | | | Text | 更多音量设置 | id= | TextBlock
```

关键点：`AutomationId` 对**有名字的 XAML 元素**有效（就是 `x:Name`）；但**每项的 Button/ListItem/ListView 大多没有 id**（列表项是数据模板生成的，`id=` 为空）→ 只能用 `ControlType + Name` 定位。

### 9.5 可用的稳定锚点（AutomationId）

| AutomationId | 元素 | 用途 |
|---|---|---|
| `ControlCenterRegion` | Group | 快速设置根容器 |
| **`PageWindow`** | Group「声音输出」 | **当前页容器**（可判断"当前是否在声音输出页"） |
| `BackButton` / `PageTitleText` | Button / Text | 返回按钮 / 页标题 |
| **`ListContent`** | Pane（实为 `ScrollViewer`） | **内容滚动区：挂按钮的首选落点** |
| `OutputGroupTitle` / `ListWithOutputGroupTitle` | Text / List | 输出设备组 |
| `SpatialGroupTitle` | Text | 空间音效组 |
| **`MixerGroupTitle`** | Text | **音量合成器组标题（在其后插入按钮最自然）** |
| `AppVolumeLevel` | Slider | 合成器里每个 app 的音量条（**每个 ListItem 内一个**） |
| `Footer` | Group（`LandmarkTarget`） | 页脚（"更多音量设置"所在处） |
| `MediaTransportControls` | Group | 媒体传输控件（offscreen） |

**注入口候选**：`ListContent` 内、`MixerGroupTitle` 之后，或 `Footer`。

### 9.6 仍未解决 / 下一步

1. ~~**band 窗口会不会派发 WinEvent？**~~ ✅ **已实测：会，且空闲 0 事件** —— 「0 占用检测」成立，见 §9.8。
2. 注入后的 hook 点：XAML 元素创建 / 布局回调（§4.3 第 2 层）。
3. 最小注入验证：注入 `ShellHost.exe` → 在 `ListContent` 里插一个可见元素（先不绑逻辑）。
4. 兜底：hook 失败 → 安全退出，不拖垮 shell。

### 9.7 本次新增脚本

- §10.1 `qs-panel-probe.ps1` —— 定位面板 + 找 XAML 宿主 + dump 元素树；
- §10.2 `event-test.ps1` —— 验证 band 窗口的 WinEvent 派发。

原始探针文件（`probe-a/-b/-c/-d/-e`、`band-check`）在同目录会话工作区，未纳入本文件。

---

### 9.8 已实测：band 窗口照发 WinEvent → 「0 占用检测」成立

`EnumWindows` 看不到 ≠ 事件不发。实测（`SetWinEventHook`，`WINEVENT_OUTOFCONTEXT`）：

| 阶段 | 钩子 A（`idProcess` = ShellHost pid） | 钩子 B（不过滤进程） |
|---|---|---|
| 空闲 600 ms | **0** 个事件 | **0** 个事件 |
| `Win+Ctrl+V` 打开 | **2**：`OBJECT_SHOW` + `SYSTEM_FOREGROUND`（均 `hwnd` = 面板，`obj=0 child=0`） | 11 |
| 再按一次关闭 | **1**：`OBJECT_HIDE` | 12 |

实测事件原文（钩子 A）：

```text
A OBJECT_SHOW        hwnd=0x000100FE pid=3704 obj=0 child=0 class=[ControlCenterWindow] title=[快速设置]
A SYSTEM_FOREGROUND  hwnd=0x000100FE pid=3704 obj=0 child=0 class=[ControlCenterWindow] title=[快速设置]
A OBJECT_HIDE        hwnd=0x000100FE pid=3704 obj=0 child=0 class=[ControlCenterWindow] title=[快速设置]
```

结论：

- ✅ **按进程过滤的事件钩子能收到 band 窗口的 `OBJECT_SHOW/HIDE` 与 `SYSTEM_FOREGROUND`** —— 回调里**直接带 hwnd**，连 `EnumWindows`/`FindWindow` 都不需要；
- ✅ **空闲 600 ms 收到 0 个事件** → 事件驱动检测确实是 **0 CPU**（前提：回调里不做重活）；
- ⚠️ **面板 HWND 是常驻的**：开关前后都是同一个 `0x000100FE` → 只有**首次创建**才发 `OBJECT_CREATE`，之后每次开关只发 **`SHOW`/`HIDE`**。所以触发点必须用 **SHOW/HIDE（或 SYSTEM_FOREGROUND）**，**不能**指望 `OBJECT_CREATE`。（这解释了 §2.5 原文"可能是常驻窗口的 show/hide"的直觉是对的，错的是 FindWindow。）
- ⚠️ ShellHost 重启后 pid 会变 → 钩子要重挂（或改成不过滤进程、在回调里判类名）。

⇒ 推荐检测骨架：

```text
SetWinEventHook(EVENT_OBJECT_SHOW, EVENT_OBJECT_HIDE, null, cb,
                idProcess = ShellHost.pid, 0, WINEVENT_OUTOFCONTEXT)
  回调 hwnd:
    GetClassName(hwnd) == "ControlCenterWindow" ?
      SHOW -> EnumChildWindows 找 "InputSite" 子窗口 -> 从它拿 UIA 树 / 注入
      HIDE -> 卸掉自己加的东西
```

（脚本与完整输出见 §10.2。）

---

## 10. 脚本（本次新增全部）

### 10.1 `qs-panel-probe.ps1`（pwsh 7.6.6 / Windows PowerShell 5.1 双通）

> 一条命令跑完：定位面板 → 验证 band → 找 XAML 宿主 → dump 元素树。
> 面板已开就直接用，没开就自动发 `Win+Ctrl+V`。

```powershell
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
```

**实测输出（节选）**：

```text
=== 1. locate panel (foreground only -- enumeration cannot see it) ===
  panel hwnd = 0x000100FE pid=3704 class=[ControlCenterWindow] title=[快速设置]
  FindWindow('ControlCenterWindow') would return : 0
  window band                                : 4

=== 2. child HWNDs of the panel ===
  0x000302A6 class=[Windows.UI.Input.InputSite.WindowClass] vis=True

=== 3. find the XAML host (UIA FrameworkId = XAML) ===
  xaml host = 0x000302A6 class=[Windows.UI.Input.InputSite.WindowClass]
...
  total elements = 28
```

### 10.2 `event-test.ps1` —— 验证 band 窗口是否派发 WinEvent

```powershell
# event-test.ps1 -- does a banded (EnumWindows-invisible) window still raise WinEvents?
# Installs SetWinEventHook twice (process-filtered and unfiltered), toggles the Quick Settings
# panel, and reports which events were delivered.
# Target: pwsh 7. ASCII-only.

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class WE
{
    public delegate void WinEventDelegate(IntPtr hook, uint ev, IntPtr hwnd, int idObject, int idChild, uint tid, uint time);

    [DllImport("user32.dll")] public static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr mod, WinEventDelegate cb, uint pid, uint tid, uint flags);
    [DllImport("user32.dll")] public static extern bool UnhookWinEvent(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);

    [StructLayout(LayoutKind.Sequential)] public struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int ptX; public int ptY; }
    [DllImport("user32.dll")] static extern bool PeekMessage(out MSG m, IntPtr h, uint min, uint max, uint remove);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG m);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref MSG m);

    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] public struct HARDWAREINPUT { public uint uMsg; public ushort wParamL; public ushort wParamH; }
    [StructLayout(LayoutKind.Explicit)] public struct InputUnion { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; [FieldOffset(0)] public HARDWAREINPUT hi; }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public InputUnion U; }
    [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint n, INPUT[] p, int cb);
    [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint mapType);

    static WinEventDelegate _cbA;   // process-filtered hook
    static WinEventDelegate _cbB;   // unfiltered hook
    static IntPtr _hA = IntPtr.Zero, _hB = IntPtr.Zero;
    public static List<string> Log = new List<string>();
    public static int TotalA = 0, TotalB = 0;

    public static string Cls(IntPtr h) { var s = new StringBuilder(512); GetClassName(h, s, s.Capacity); return s.ToString(); }
    public static string Txt(IntPtr h) { var s = new StringBuilder(512); GetWindowText(h, s, s.Capacity); return s.ToString(); }
    public static uint Pid(IntPtr h) { uint p; GetWindowThreadProcessId(h, out p); return p; }

    public static string EvName(uint e)
    {
        switch (e)
        {
            case 0x0001: return "SYSTEM_SOUND";
            case 0x0002: return "SYSTEM_ALERT";
            case 0x0003: return "SYSTEM_FOREGROUND";
            case 0x0004: return "SYSTEM_MENUSTART";
            case 0x8000: return "OBJECT_CREATE";
            case 0x8001: return "OBJECT_DESTROY";
            case 0x8002: return "OBJECT_SHOW";
            case 0x8003: return "OBJECT_HIDE";
            case 0x8004: return "OBJECT_REORDER";
            case 0x8005: return "OBJECT_FOCUS";
            case 0x8006: return "OBJECT_SELECTION";
            case 0x800C: return "OBJECT_NAMECHANGE";
            case 0x8010: return "OBJECT_CLOAKED";
            case 0x8011: return "OBJECT_UNCLOAKED";
            case 0x8012: return "OBJECT_LIVEREGIONCHANGED";
            default: return "0x" + e.ToString("X");
        }
    }

    public static void Start(uint filterPid)
    {
        // EVENT_OBJECT_CREATE .. EVENT_OBJECT_HIDE = 0x8000..0x8003
        // plus EVENT_SYSTEM_FOREGROUND = 0x0003 (separate range)
        _cbA = new WinEventDelegate(OnA);
        _cbB = new WinEventDelegate(OnB);
        _hA = SetWinEventHook(0x8000, 0x8003, IntPtr.Zero, _cbA, filterPid, 0, 0x0000 /* OUTOFCONTEXT */);
        _hA = SetWinEventHook(0x0003, 0x0003, IntPtr.Zero, _cbA, filterPid, 0, 0x0000);
        _hB = SetWinEventHook(0x8000, 0x8003, IntPtr.Zero, _cbB, 0, 0, 0x0000);
        _hB = SetWinEventHook(0x0003, 0x0003, IntPtr.Zero, _cbB, 0, 0, 0x0000);
    }
    public static void Stop()
    {
        if (_hA != IntPtr.Zero) UnhookWinEvent(_hA);
        if (_hB != IntPtr.Zero) UnhookWinEvent(_hB);
    }

    static void OnA(IntPtr hook, uint ev, IntPtr hwnd, int idObject, int idChild, uint tid, uint time)
    {
        TotalA++;
        Log.Add("A " + EvName(ev) + " hwnd=0x" + hwnd.ToInt64().ToString("X8") + " pid=" + Pid(hwnd) + " obj=" + idObject + " child=" + idChild + " class=[" + Cls(hwnd) + "] title=[" + Txt(hwnd) + "]");
    }
    static void OnB(IntPtr hook, uint ev, IntPtr hwnd, int idObject, int idChild, uint tid, uint time)
    {
        TotalB++;
        // unfiltered: only log the interesting window to keep noise down
        string c = Cls(hwnd);
        if (c == "ControlCenterWindow" || c == "Windows.UI.Input.InputSite.WindowClass")
            Log.Add("B " + EvName(ev) + " hwnd=0x" + hwnd.ToInt64().ToString("X8") + " pid=" + Pid(hwnd) + " class=[" + c + "]");
    }

    public static int Pump(int ms)
    {
        var sw = Stopwatch.StartNew(); int n = 0;
        while (sw.ElapsedMilliseconds < ms)
        {
            MSG m;
            while (PeekMessage(out m, IntPtr.Zero, 0, 0, 1)) { TranslateMessage(ref m); DispatchMessage(ref m); n++; }
            Thread.Sleep(10);
        }
        return n;
    }

    // Win+Ctrl+V
    public static int ToggleSoundPage()
    {
        ushort[] mods = { 0x5B, 0x11 }; ushort key = 0x56;
        var l = new List<INPUT>();
        foreach (var m in mods) l.Add(Ki(m, false));
        l.Add(Ki(key, false)); l.Add(Ki(key, true));
        for (int i = mods.Length - 1; i >= 0; i--) l.Add(Ki(mods[i], true));
        var a = l.ToArray();
        return (int)SendInput((uint)a.Length, a, Marshal.SizeOf(typeof(INPUT)));
    }
    const uint KEYUP = 0x0002;
    static INPUT Ki(ushort vk, bool up)
    {
        var i = new INPUT(); i.type = 1;
        i.U.ki = new KEYBDINPUT { wVk = vk, wScan = (ushort)MapVirtualKey(vk, 0), dwFlags = up ? KEYUP : 0, dwExtraInfo = IntPtr.Zero };
        return i;
    }
}
'@

$sh = Get-Process ShellHost -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $sh) { Write-Output "ShellHost.exe not running"; exit 1 }
Write-Output ("ShellHost pid = " + $sh.Id)

function Show-Fg($tag) {
    $h = [WE]::GetForegroundWindow()
    Write-Host ("[$tag] fg = 0x" + $h.ToInt64().ToString("X8") + " pid=" + [WE]::Pid($h) + " class=[" + [WE]::Cls($h) + "] title=[" + [WE]::Txt($h) + "]")
    return $h
}

Write-Output ""
Write-Output "=== 0. make sure the panel is CLOSED before we start ==="
$fg = Show-Fg "before"
if ([WE]::Cls($fg) -eq 'ControlCenterWindow') {
    Write-Output "  panel is open -> toggling closed"
    [void][WE]::ToggleSoundPage()
    [void][WE]::Pump(1200)
    [void](Show-Fg "closed")
} else {
    Write-Output "  panel already closed"
}

Write-Output ""
Write-Output "=== 1. install hooks (A: idProcess=ShellHost pid, B: unfiltered) ==="
[WE]::Start([uint32]$sh.Id)
[WE]::Log.Clear()
[void][WE]::Pump(600)
Write-Output ("  hooks installed. events seen during idle 600ms: A=" + [WE]::TotalA + " B=" + [WE]::TotalB)

Write-Output ""
Write-Output "=== 2. open the panel (Win+Ctrl+V) and pump 2500ms ==="
[WE]::Log.Clear()
$beforeA = [WE]::TotalA; $beforeB = [WE]::TotalB
[void][WE]::ToggleSoundPage()
[void][WE]::Pump(2500)
Write-Output ("  A events during open: " + ([WE]::TotalA - $beforeA))
Write-Output ("  B events during open: " + ([WE]::TotalB - $beforeB))
[void](Show-Fg "after")

Write-Output ""
Write-Output "=== 3. events logged (A = pid-filtered hook) ==="
if ([WE]::Log.Count -eq 0) {
    Write-Output "  *** NOTHING. WinEvents are NOT delivered for this window. ***"
} else {
    [WE]::Log | ForEach-Object { Write-Output ("  " + $_) }
}

Write-Output ""
Write-Output "=== 4. close the panel again and watch HIDE/DESTROY ==="
[WE]::Log.Clear()
$beforeA = [WE]::TotalA; $beforeB = [WE]::TotalB
[void][WE]::ToggleSoundPage()
[void][WE]::Pump(2000)
Write-Output ("  A events during close: " + ([WE]::TotalA - $beforeA))
Write-Output ("  B events during close: " + ([WE]::TotalB - $beforeB))
[WE]::Log | ForEach-Object { Write-Output ("  " + $_) }

[WE]::Stop()
Write-Output ""
Write-Output "done."
```

**实测输出（build 26300.9550，pwsh 7.6.6，完整）**：

```text
ShellHost pid = 3704

=== 0. make sure the panel is CLOSED before we start ===
[before] fg = 0x000100FE pid=3704 class=[ControlCenterWindow] title=[快速设置]
  panel is open -> toggling closed
[closed] fg = 0x0002012C pid=4872 class=[Shell_TrayWnd] title=[]

=== 1. install hooks (A: idProcess=ShellHost pid, B: unfiltered) ===
  hooks installed. events seen during idle 600ms: A=0 B=0

=== 2. open the panel (Win+Ctrl+V) and pump 2500ms ===
  A events during open: 2
  B events during open: 11
[after] fg = 0x000100FE pid=3704 class=[ControlCenterWindow] title=[快速设置]

=== 3. events logged (A = pid-filtered hook) ===
  B OBJECT_SHOW hwnd=0x000100FE pid=3704 class=[ControlCenterWindow]
  A OBJECT_SHOW hwnd=0x000100FE pid=3704 obj=0 child=0 class=[ControlCenterWindow] title=[快速设置]
  B SYSTEM_FOREGROUND hwnd=0x000100FE pid=3704 class=[ControlCenterWindow]
  A SYSTEM_FOREGROUND hwnd=0x000100FE pid=3704 obj=0 child=0 class=[ControlCenterWindow] title=[快速设置]
  B OBJECT_CREATE hwnd=0x0001026A pid=4872 class=[Windows.UI.Input.InputSite.WindowClass]
  B OBJECT_SHOW hwnd=0x0001026A pid=4872 class=[Windows.UI.Input.InputSite.WindowClass]
  B OBJECT_CREATE hwnd=0x0001026A pid=4872 class=[Windows.UI.Input.InputSite.WindowClass]
  B OBJECT_SHOW hwnd=0x0001026A pid=4872 class=[Windows.UI.Input.InputSite.WindowClass]
  B OBJECT_CREATE hwnd=0x0001026A pid=4872 class=[Windows.UI.Input.InputSite.WindowClass]
  B OBJECT_SHOW hwnd=0x0001026A pid=4872 class=[Windows.UI.Input.InputSite.WindowClass]
  B OBJECT_HIDE hwnd=0x0001026A pid=4872 class=[Windows.UI.Input.InputSite.WindowClass]
  B OBJECT_DESTROY hwnd=0x0001026A pid=4872 class=[Windows.UI.Input.InputSite.WindowClass]

=== 4. close the panel again and watch HIDE/DESTROY ===
  A events during close: 1
  B events during close: 12
  B OBJECT_HIDE hwnd=0x000100FE pid=3704 class=[ControlCenterWindow]
  A OBJECT_HIDE hwnd=0x000100FE pid=3704 obj=0 child=0 class=[ControlCenterWindow] title=[快速设置]
  B OBJECT_CREATE hwnd=0x0001026A pid=4872 class=[Windows.UI.Input.InputSite.WindowClass]
  B OBJECT_SHOW hwnd=0x0001026A pid=4872 class=[Windows.UI.Input.InputSite.WindowClass]
  B OBJECT_HIDE hwnd=0x0001026A pid=4872 class=[Windows.UI.Input.InputSite.WindowClass]
  B OBJECT_DESTROY hwnd=0x0001026A pid=4872 class=[Windows.UI.Input.InputSite.WindowClass]
  B OBJECT_HIDE hwnd=0x0001026A pid=4872 class=[Windows.UI.Input.InputSite.WindowClass]
  B OBJECT_DESTROY hwnd=0x0001026A pid=4872 class=[Windows.UI.Input.InputSite.WindowClass]
  B OBJECT_HIDE hwnd=0x0001026A pid=4872 class=[Windows.UI.Input.InputSite.WindowClass]
  B OBJECT_DESTROY hwnd=0x0001026A pid=4872 class=[Windows.UI.Input.InputSite.WindowClass]

done.
```

> 附带观察：`Windows.UI.Input.InputSite.WindowClass`（pid 4872 = explorer）会随开关**反复 create/destroy**，那是任务栏那边的 island，与本项目无关；`ControlCenterWindow` 则是**常驻 + show/hide**。

---

## 11. 注入落地：走通了（2026-10-03）

§9/§10 是"看清楚"，这一节是"改进去"。**结论：注入成功，按钮就在底栏「更多音量设置」右侧、同一行、居右对齐，点击能拉起进程。**

### 11.1 先排除掉一条看起来最顺的路（方案 A 证伪）

原本最想走的是：hook `ControlCenter.dll!DllGetActivationFactory` → 在返回的工厂对象上 patch `IActivationFactory` 的 `vtable[6]`（`ActivateInstance`），
这样"页面被实例化"的瞬间就能拿到它的 `IInspectable*`。

结果**证伪**：

- `DllGetActivationFactory` 里能解析出 **101/102**（共 123 个候选）`ControlCenter.*` 类名；
- 工厂**不是单例**（每次返回新对象），但**共享同一份 `.rdata` vtable** → 全局 patch `vtable[6]` 是有效的；
- `IActivationFactory` vtable 布局：`[0..2]` IUnknown、`[3..5]` IInspectable、`[6]` `ActivateInstance`；
- **自测能命中**（`[detour] ActivateInstance ENTERED`）→ patch 本身活着；
- 决定性实验：全新 `ShellHost.exe`、**启动后 29 ms** 就注入（早于第一次面板创建）、然后开面板 → **命中 0 次**。

⇒ **shell 创建这些编译期 XAML 对象时不走 `IActivationFactory::ActivateInstance`**。白忙一场，但排得干净。

### 11.2 真正走通的：XAML 诊断 API + 自写 TAP（方案 B）

`Windows.UI.Xaml.dll` 导出 `InitializeXamlDiagnosticsEx`（§8 已列），**在目标进程内**调用它即可让 XAML core 反过来加载我们自己的 TAP DLL：

```text
injector.exe  → CreateRemoteThread + LoadLibraryW 注入 ShellHost
  └─ vcxlaunch.dll  等 Windows.UI.Xaml.dll 就绪 → 在进程内调
     InitializeXamlDiagnosticsEx(L"VisualDiagConnection1", pid,
         <SDK>\XamlDiagnostics\xamldiagnostics.dll, <poc>\vcxtap.dll, CLSID_VcxTap, nullptr)
       └─ XAML core 用 DllGetClassObject(CLSID_VcxTap) 载入 vcxtap.dll
            └─ IObjectWithSite::SetSite 拿到 IXamlDiagnostics* / IVisualTreeService*
               AdviseVisualTreeChange → 元素事件（**连已存在的树也会重放给你**）
```

几个实操要点：

- 端点名 `VisualDiagConnection1` 一发就成功（N=1）；
- **TAP DLL 不需要注册表注册**，XAML core 自己 `LoadLibrary` + `DllGetClassObject`；
- 导出必须是 `STDAPI`（与 `combaseapi.h` 一致）+ 链接器 `/EXPORT:`；用 `__declspec(dllexport)` + `extern "C" __stdcall` 会 C2375；
- 拿真对象的 API 是 `IXamlDiagnostics::GetIInspectableFromHandle(handle, &insp)`，`VisualElement.Handle` 是 `InstanceHandle`（`MIDL_uhyper`，u64）。

### 11.3 唯一的硬骨头：底栏的 `ItemsPanel` 是**纵向** StackPanel

这是这次真正花时间的地方。实测祖先链（日志里 `up[]` 打的）：

```text
Button[更多音量设置]
  → ContentPresenter → ContentControl
    → ContentPresenter        ← ItemsControl 为它生成的 item container
      → StackPanel[Vertical]  ← 「Footer」的 ItemsPanel ★
        → ItemsPresenter → ItemsControl name="Footer"
```

所以**往 `Footer` append 一项必然新起一行** ——实测 footer 从 `48` 高变成 `78`，按钮掉到第二行。
（顺带纠正 §9.5 里那个猜测：`FooterGrid` / `LeftFooter` / `RightFooter` **不是**这条底栏，它们挂在 `L1Grid` 下、属于 L1 主面板的底栏，而且一直是空的。声音输出页的底栏是页面级的 `Footer`。）

**修法**：把那个 item container 从 `ItemsPanel` 里取出，塞进一个两列 `Grid`（列 0 `*` 放原行、列 1 `Auto` 放我们的按钮），再把这个 `Grid` 放回 `ItemsPanel`。
列 0 必须用 `*` 而不是 `Auto`，否则原行会缩到内容宽度、`更多音量设置` 的 hover 高亮跟着缩水。

两个细节：

- **高度**：模型按钮的 `Height` 是显式 `40.0`（`MinHeight=0.0`），直接读 `Height()` 就能在注入当刻定死，**不依赖布局时机**；
- **右边距**：`4 px`，和左边距对称。

### 11.4 最终实测几何（UIA，连续两轮 cycle 复现一致）

| 元素 | 屏幕矩形 | 说明 |
|---|---|---|
| `Footer` | `(2189,1417) 358x48` | 高度仍 48 → 没有第二行 |
| `更多音量设置` | `(2193,1420) 94x40` | 位置与注入前一致 |
| `TestLink` | `(2472,1419) 71x40` | 同一行；右边缘 2543 = 距底栏右边 4 px；高 40 与模型一致 |

点击验证：UIA `InvokePattern` 调用后 `winver.exe` 启动（窗口标题「关于"Windows"」）。

### 11.5 一个值得记下来的坑

曾经想"优雅一点"：用 `TransformToVisual` 去**测量**模型按钮的内边距，再据此算右边距。
结果 —— 注入发生在**布局之前**，`model.ActualWidth()` 还是 `0`，算出 `354 px` 的荒谬边距；而之后 `SizeChanged` **不会再触发**（树早已布局完、尺寸不再变），于是错位被永久固化，UIA 矩形直接变成 `∞`。

> 教训：**任何依赖 `ActualWidth`/`ActualHeight` 的取值都必须先判 `> 0`**，否则就是这种静默错位。能用显式属性（`Height`）就别用测量值。

### 11.6 关于"要不要每次都重启 explorer"

`poc/cycle.ps1` 每轮都会重启 explorer，原因有两条，**都不是产品需求**：

1. **硬约束**：DLL 已被 `LoadLibraryW` 载入 `ShellHost.exe`，**进程内已加载的 DLL 文件写锁定**，`link` 会 LNK1104。改了 C++ 就必须让持有者退出；杀 explorer 是为了拿到确定全新的 ShellHost。
2. **测试卫生**：`InitializeXamlDiagnosticsEx` 是**每进程一次**的诊断初始化，TAP 常驻且会重放既有树；同进程反复测等于在"已被上一轮改造过的树"上继续跑，结论失真。

⇒ **产品上不需要重启 explorer，也不需要在 logon 阶段抢时间。** 实测（`docs/poc/scripts/test-late-inject.ps1`）：

- 全新 shell 起来后（ShellHost 已跑 ~30 s、面板已开过又关掉）才注入 → `InitializeXamlDiagnosticsEx` **仍然成功**，
  TAP 载入、advise 成功；之后**不再注入**，只是关掉再打开面板 → `TestLink (2472,1419) 71x40` 出现。
  ⇒ TAP 常驻，之后每次打开面板 `Footer` 一出现就自动注入（§9.3：XAML 元素每次打开都重建，进程/HWND 常驻）。

**真正的生命周期约束**：TAP 活在 **ShellHost** 里，而 **ShellHost 的父进程是 `sihost.exe`**（实测，不是 explorer）。
ShellHost 会随 shell 重启（explorer 重启 / sihost 重启 / 自身崩溃）换成新进程 → TAP 消失、按钮没了。
⇒ 产品需要的是「**等 ShellHost.exe 出现 → 注入 → 监视它退出 → 再来一遍**」的循环，而不是"重启 explorer"。
这个监视能做到 0 CPU（§9.8 已测 band 窗口照发 WinEvent、空闲 600 ms 0 事件；或 `RegisterWaitForSingleObject` / `Win32_ProcessStartTrace`）。

**反不掉的只有诊断会话本身**：`InitializeXamlDiagnosticsEx` 是每进程单例、没有 teardown API，TAP DLL 一旦载入就跟着
ShellHost 活到进程退出。但它不影响任何可见行为——把注入关掉就等于不存在，残留只是"ShellHost 里所有 XAML 变更都会回调我们"
那点开销（回调里只做一次字符串比较）。按钮本身要移除则完全不用重启：它活在每次打开都重建的树里，停止注入即可；
要在当前已开的树上立刻拿掉，把包的那层 `Grid` 拆掉、item container 放回 `ItemsPanel` 即可（机制与注入对称，未实测）。

### 11.7 脚本与产物位置

- 实现与全部说明：`docs/design.md` §6
- PoC 源码与构建：`docs/poc/`（`injector.cpp` / `vcxlaunch.cpp` / `vcxtap.cpp` / `build.cmd` / `cycle.ps1`）
- 验证工具：`docs/poc/scripts/footer-map.ps1`（打几何）、`docs/poc/scripts/click-testlink.ps1`（验点击）、`docs/poc/scripts/shot-footer.ps1`（截图）
  
---
  
## 12. 地基验证：配置下发 + 点击执行指令 + `action=pipe` + INI 编码（2026-10-03）
  
> 这一节是"接产品之前先把地基夯实"的实测记录。
> 完整数据在 `docs/verified-after-injection/06-*.md` 与 `07-*.md`，这里只留结论与陷阱。
  
### 12.1 配置怎么进 TAP：initData 有 259 字符硬上限，且超限**静默**失败
  
`InitializeXamlDiagnosticsEx` 的第 6 个参数确实能被 `IXamlDiagnostics::GetInitializationData()`
原样读回（含中文），但**上限正好 259 字符**。逐长度二分的结果：
  
| 总长 | 回读 |
|---|---|
| 17 / 128 / 255 / 256 / **259** | ✅ 逐字符一致（含 CJK） |
| **260** / 300 / 331 / 4000 | ❌ **空串**，且 `hr` 仍是 `S_OK` |
  
⛔ **最危险的地方是"静默"**：`InitializeXamlDiagnosticsEx` 返回 `S_OK`、
`GetInitializationData` 也返回 `S_OK`，只是 BSTR 长度为 0 —— **没有任何错误信号**。
✅ 好消息：超限是**有界拒绝**不是溢出（4000 字符下 ShellHost 健康、按钮照常注入）。
259 对应 `wchar_t buf[260]` 留 1 位给 NUL 的经典写法。
  
⇒ **定稿：配置走"直投"通道** —— Launcher 与 TAP 同进程，直接
`LoadLibraryW(vcxtap.dll)` + `GetProcAddress("VmExtTapProvideInitData")` + 调用，
把配置放进 TAP 的全局变量（已验证 4000 字符无损，无长度/字符集限制）。
⛔ 刻意**不** `FreeLibrary`（多持一个引用，确保模块不被卸载、全局变量不丢）。
initData 降级为"人类可读的面包屑"，超限时只丢面包屑并打警告。
  
**TAP 侧判定逻辑**（日志三行是排查配置问题的第一现场）：
直投 len/哈希 vs initData len/哈希 → 一致 / 预期内丢弃 / ⚠️非预期为空（反向哨兵）/ 不一致 / 直投未到（降级）。
  
`cfg=` 必须由通道自己传（否则"配置里说配置在哪"是循环依赖）；TAP 拿到 `cfg` 后
**所有** ini 读取都走它 ⇒ 配置文件放哪都行。
  
### 12.2 点击能不能执行指令：能（3 条约束 + 1 条观察）  
验法：写一个 `clickprobe.exe` 让**被点出来的子进程自己交代**收到了什么（完整命令行、argv、当前目录）。
  
| # | 项 | 结果 |
|---|---|---|
| 1 | 执行**带参数**的命令行（接主程序入口的真实形态） | ✅ `argv[]` 逐字符正确，`"beta gamma"` **没被空格拆开** |
| 2 | `.lnk` 快捷方式当 command | ❌ `GetLastError=193`（`ERROR_BAD_EXE_FORMAT`）—— shell 才解析快捷方式 |
| 3 | 子进程的工作目录 | 📌 继承自 ShellHost（实测 `C:\Windows\System32`）—— **不属本设计规定范围**，由接入程序自理 |
| 4 | exe 路径不加引号 | ⚠️ 会被**前缀试探**（前缀处有同名文件就启动那个）—— 见下，按**正确性**问题处理 |
  
**⚠️ 未加引号的含空格路径会被"前缀试探"（已复现）**：
`lpApplicationName = NULL` 时 `CreateProcessW` 会对命令行**逐段前缀试探**：
  
```text
命令行（不加引号）: C:\...\Temp\a b c\click probe.exe
  前缀处有 C:\...\Temp\a.exe  ->  启动的是那个（argv[0] = ...\Temp\a）
  前缀处没有文件              ->  才落到 ...\a b c\click probe.exe
```
  
即"平时能跑，前缀处一旦存在同名文件就会静默启动别的程序"。

> **决策记录（Eric）：不作为安全问题处理。** TAP 是 Medium IL → Medium IL 的**同用户**上下文，
> 能在路径前缀处放文件的人本来就已经能以你的身份执行代码，**没有权限边界被跨越**；
> 自用工具不按威胁模型处理。所以这里按**正确性**问题（别启动错程序）+ 易用性处理。
  
⇒ 规则（已落到 PoC 代码并回归通过）：
1. `lpApplicationName` **显式**给 exe 路径；
2. 命令行里路径**加引号**，且由**产品**拼，不指望用户填对；
3. `lpCommandLine` 用**可写缓冲**；失败要记 `GetLastError()`；⛔ 不要 `WaitForSingleObject`（会卡住 ShellHost）。

> 📌 **工作目录不作为规则**（Eric 决定）：子进程会继承 ShellHost 的 CWD（实测 `C:\Windows\System32`），
> 但这是**接入程序**自己该管的事 —— 被启动的程序应按自身模块路径解析资源，不依赖 CWD。
> 交付文档里相关的坑位与检查项已删除，只在证据文件里留一条观察记录备查。
  
⇒ 两份交付文档的配置 schema 因此把 `entry1.command` **拆成 `entry1.exe` + `entry1.args`** ——
"让用户填一整条命令行"这种设计本身就是 bug 的温床。
  
### 12.3 顺手修掉的两个真实 bug
  
1. **`/utf-8`**：无 BOM 的 UTF-8 源码 + 中文注释会被 MSVC 按系统 ACP（936）解读，
   某个中文字的 UTF-8 尾字节 `0x5C` 恰好"吃掉"字符串字面量的收尾引号 ⇒
   `C2001 常量中有换行符` + `C1075`，报错行看着完全正常、极难定位。`build.cmd` 已加 `/utf-8`。
2. **FNV-1a 种子写错**：原实现写成 `1469598103934665603`（**少一位**，是网上广为流传的错版），
   算出的哈希与任何标准实现都不一致 ⇒ **日志里的哈希无法被第三方独立复核**。
   已改为正确的 `14695981039346656037`（`0xCBF29CE484222325`），并用独立实现（Node）复核通过：
   `len=165 → E0C1B019B461A8F4` 与 C++ 侧逐位相同，空串哈希 = 偏移基（自检）。
  
### 12.4 `action=pipe` 全链路（T3，已验）

| 检查 | 结果 |
|---|---|
| 报文送达 | ✅ 服务端收到 `CLICK volumemixer <unixMillis>`，32 字节逐字节正确 |
| **点击会不会卡住面板** | ✅ 不会。UIA `Invoke` 往返 **7–14 ms**；点击后 9–10 ms 内仍能读面板 |
| 管道 IO 是否离开 UI 线程 | ✅ **tid 可证**：点击在 UI 线程，管道写与结果在另一个 tid |
| App 没运行时 | ✅ **瞬时**降级 + 显式日志（`err=2`，`WaitNamedPipeW` 立即返回，**不会**等满 200ms） |
| 失败后能否恢复 | ✅ 服务端回来再点，正常收到 |
| 配置热重载 | ✅ 顺带验证：只改 ini 的 `entry1_action`，不重启 explorer/不重新注入，下次点击立即生效 |

**⚠️ 发现文档漏写的一个坑（已补进两份交付文档）**：
`ConnectNamedPipe` 的合法失败**有两种**，不是一种：

| 错误码 | 含义 | 正确处理 |
|---|---|---|
| `ERROR_PIPE_CONNECTED` (110) | 客户端已连接、仍开着 | 当作成功，进读循环 |
| **`ERROR_NO_DATA` (232)** | 客户端连接过、**已关闭**（TAP 写完就 `CloseHandle`） | ⚠️ **不能当致命错误** —— 缓冲里数据**仍可读**（实测 32 字节完整读回）。当错误处理 ⇒ **静默丢一次点击**，最容易发生在"App 刚启动"的窗口里 |
| `ERROR_BROKEN_PIPE` (109) | 读时对端关闭 | 正常的**流结束**，不是错误 |

> 我第一版探针就是把 232 当致命错误 `return 1` 退出的 —— 而那正是"照着文档写"会写出来的代码。
> 复现方式（确定性）：`pipeserver.exe <name> 1 25 <out> race`，race 模式在 `CreateNamedPipeW` 之后
> 先睡 3 秒再 `ConnectNamedPipe`，客户端必然在这段窗口内连上并关闭。

### 12.5 三个"不做支持 / 不规定"的决定
| 项 | 决定 | 理由 |
|---|---|---|
| **"面板已打开时注入"立刻生效**（T4） | ❌ 不做支持 | **音量浮层不是常驻窗口** —— 按快捷键才出现、失焦即消失。产品模型是"注入一次 → TAP 常驻 → 每次打开面板自动注入"，不需要往一个正在被看的浮层里插东西 |
| **子进程的工作目录** | 📌 不规定 | 由**接入程序**自理：被启动的程序应按自身模块路径解析资源，不依赖 CWD |
| **未加引号路径的前缀试探** | ⚠️ 按正确性处理，**不作安全项** | 同用户上下文（Medium IL → Medium IL），能在前缀处放文件的人本来就能以你的身份执行代码，没有权限边界被跨越 |

> 三项都已在两份交付文档里改成"不做支持 / 不规定 / 按正确性处理"，对应的坑位与验收项已删除或改写。

### 12.6 INI 编码（T2，已验）+ 一个被顺带挖出的真 bug

**读侧矩阵**（`GetPrivateProfileStringW`，系统 ACP=936）：

| 编码 | 结果 |
|---|---|
| **UTF-16LE + BOM** | ✅ **唯一正确**（7 个汉字码点逐位一致） |
| UTF-8 无 BOM | ❌ **静默乱码**（ASCII 节名/key 匹配上，值全错） |
| UTF-8 有 BOM | ❌ **键都找不到** ⇒ 设置被**静默忽略**、回落默认值 |
| UTF-16LE 无 BOM | ❌ 被当 ANSI 读 ⇒ 乱码 |
| 系统 ACP（GBK） | ⚠️ 本机对，**只因 ACP=936**，换区域设置即坏 |

**写侧**：`WritePrivateProfileStringW` 对**全新文件**会写成 **ANSI**（不带 BOM）；只有对已带 BOM 的文件才保持 UTF-16LE。
⇒ C++ 轨道 `Ini::WriteAll` 必须自己写字节，不能裸委托给它。

**端到端**：ini 写成 UTF-16LE+BOM、`entry1_text=音量合成器` ⇒ 按钮 `Name` 码点 `\u97F3\u91CF\u5408\u6210\u5668` 逐位一致，右边缘仍 2543 ✅。

**⛔ 文档修正**：原交付文档里 `WriteTapIni` 曾写"**必须用 `Encoding.UTF8` 无 BOM 写**否则读不到第一行" —— **方向是反的**。
理由（BOM 破坏节名）没错，但结论应是"不要用 UTF-8"，而不是"用无 BOM 的 UTF-8"。

**🔴 顺带挖出并修掉的真 bug：幂等判定用"记住指针"**

```text
[03:15:12] Footer appeared: handle=2A2C2B97DD8   → 注入了
[03:19:14] Footer appeared: handle=2A2C2B97DD8   → 什么都没发生（静默跳过）
```

面板关了又开、元素确实重建，但**分配器把同一地址复用**给了新 `Footer`；而守卫是
`g_lastInjectedFooter == get_abi(footer)` ⇒ 新树被误判成"已处理"，**按钮被静默跳过**（连日志都没有）。

- 两份交付文档都写着"面板每次打开重建元素、**句柄会变所以不会误判**" —— 前半句对，**后半句错**，已改正。
- 修法：**按内容判定** —— 给按钮打 `AutomationId=VmExtEntry`，在 Footer 子树里找它，找不到才注入。
  判据自证，还能自愈"按钮被模板化移除"的情况。
- 教训：**幂等判定优先用"结果是否存在"，而不是"我记不记得做过"。**

**测试本身的坑**（也记下来了）：`Win+Ctrl+V` 不是开关（面板已开着时是空操作），
`IsWindowVisible`/前台窗口类名都不可靠 —— 判断"树是否重建"**只能看 TAP 日志里 `Footer appeared` 有没有新增**。
另外我第一版编码测试把 UTF-16LE 高位字节写死成 0，差点得出"推荐编码也不对"的**反向结论**；补上 hex dump 才自证。

### 12.7 本节新增的文件
  
- 探针源码：`docs/poc/src/probes/clickprobe.cpp`、`lnkprobe.cpp`、`pipeserver.cpp`（T3 服务端）、`initest.cpp`（T2 编码矩阵）
- 探针脚本：`docs/poc/scripts/` 下的 `probe-initdata.ps1`（`-Total <n>` 长度扫描）、`probe-config-chain.ps1`（端到端）、
  `click-probe.ps1`、`click-only.ps1`、`check-button-text.ps1`、`reopen-panel.ps1`
- 证据：`docs/verified-after-injection/06-initdata-channel-limit.md`、
  `07-click-execution-constraints.md`、`08-pipe-action-chain.md`、`09-ini-encoding.md`

> 📌 **2026-10-03 位置变更**：以上文件原在被 `.gitignore` 忽略的 `.research/` 下，现已全部搬进
> `docs/`（源码 → `docs/poc/src/`、脚本 → `docs/poc/scripts/`）并删除 `.research/`。
> 搬家时发现所有脚本的 `Split-Path -Parent` 层级都失效了，已改为 `docs/poc/scripts/_paths.ps1`
> 统一解析（向上找 `build.cmd` 定出 PoC 目录）。

- PoC 代码变化：TAP 的 `RunEntryAction()`（按 `entry1_action` 分派 `exec`/`pipe`）、
  管道客户端（独立线程 + `WaitNamedPipeW` 重试 + 降级日志）、`pipe=` 由直投配置通道下发；
  **幂等判定从"记住 Footer 指针"改为"按 `AutomationId` 查内容"**；
  `vcxtap.ini`/`vcxlaunch.ini` 改为 UTF-16LE+BOM 写
  
---
  
### 12.8 方向修订：入口接管 + 页面内容替换（2026-10-03 晚）

**目标变更**：不再"在系统页里加按钮"，而是让 L1 的「选择声音输出」**直接进入自定义页**；
原底栏按钮改为**系统页 ↔ 自定义页的切换**。

#### 补采了 L1 主面板的元素树（此前完全缺失）

```text
| Group | 快速设置 | id=ControlCenterRegion
| | Button | 静音音量     | id=Microsoft.QuickAction.VolumeNoTimer | ToggleButton
| | Slider | 声音输出     | id=                                     | Slider
| | Button | 选择声音输出 | id=VolumeL2Button                       | Button   ← ★ 入口
| | Group |  | id=FooterGrid | LandmarkTarget
| | | Button | 电池       | id=Microsoft.QuickAction.Battery
| | | Button | 所有设置   | id=Microsoft.QuickAction.AllSettings
| | Button | 投影         | id=Microsoft.QuickAction.ProjectL2      | offscreen
```

L1 = **31 元素**，L2 = 28 元素，两态**互斥**（`ControlCenterRegion` 里非此即彼）。
完整树见 `docs/baseline-before-injection/06-l1-main-panel-tree.md`。

#### 三条结论

1. **入口按钮确认**：`AutomationId = VolumeL2Button`，`Name` = 「选择声音输出」（与 tooltip 一致）。
   同一层还有「静音音量」(`ToggleButton`) 和「声音输出」(`Slider`)，名称相近 ⇒ **按 `AutomationId` 匹配**。

2. ⚠️ **"拦导航"路线被否掉**：`Microsoft.QuickAction.ProjectL2` 证明 **`L2` 后缀 = 导航到二级页**，
   即进入 L2 的入口是**一组**。在 `L2Frame` 上挂 `Navigating` 并无条件 `Cancel` 会**误伤「投影」**。
   加上"Cancel 后帧停在 L1、我们的页面无处安放"，这条路代价高且风险外溢。

3. **`FooterGrid` 属 L1 且非空**（装着「电池」「所有设置」）——
   §11 里"一直是空的"这句**要按此修正**。它与声音页的页面级 `Footer` 同名不同物。

#### 采用的机制

```text
点 VolumeL2Button → 系统照常导航 → 我们检测到声音页出现
→ 保存 ListContent 的原 Content → 换成自定义页
→ 底栏按钮在两态间切换（还原 / 再替换）
```

**误伤面为零**：只在声音页真正出现时动作，其他 L2 入口不受影响。
挂载点选 `ListContent` 而非整页替换 —— 底栏天然跨两态存续，后退键与标题免费保留。

⚠️ **最大成本**：没有 XAML 标记编译，界面只能用 `CreateInstance` 逐元素搭。
参照单个 `Button`（含样式抄写）约 60 行，一个带应用列表的页面保守估计 **1500–2500 行 C++**。
且目前**只验证过 `Button`**，`ComboBox`/`ListView`/`Slider` 的可用性未验（T14）。

#### 本轮新增/修改的文件

- 新增证据：`docs/baseline-before-injection/06-l1-main-panel-tree.md`
- `docs/reference/raw-outputs.md` 追加 §09（L1 原始 dump）
- `docs/design.md`：标题与目标改写，新增 **§7**（方向修订），并修正 5 处陈旧的 `logs/`、`recon/` 路径
- C++ 规格：§0.2 术语表、§1.1 目标、新增 **§5.7**（入口接管与内容替换）、§8.2 新增 AT-17…AT-22、
  §10.5 新增 T12…T16
- C# 规格：**已删除**（技术轨道定为 C++，不做双轨维护）

> 📌 顺带发现一个复现技巧：`qs-panel-probe.ps1` 用 `GetForegroundWindow()` 定位面板，
> 所以**开面板用 `Win+A` 采到 L1、用 `Win+Ctrl+V` 采到 L2**，同一脚本无需改动。
> 此前未记录，补上。

---

*（完）*
