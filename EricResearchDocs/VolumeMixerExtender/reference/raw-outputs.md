# 原始捕获输出（2026-10-03，开发机，Windows 11 build 26300.9550）

> 全部为当时探针的**原样输出**，未改写。对应脚本现位于 `../poc/src/probes/`、`../poc/archive/hooks/`、`../poc/archive/recon/`。
> 结论汇总见仓库根目录的 `Win11-QuickSettings-XAML-Injection-Notes.md` §9。

---

## 01 · 环境与定位（probe-a.ps1 + probe-e.ps1 + band-check.ps1）

### OS / 会话

```text
registry CurrentBuild      = 26300
registry CurrentBuildNumber= 26300
registry UBR               = 9550
CIM Win32_OS.BuildNumber   = 26300
Environment.OSVersion      = 10.0.26300.0

my SessionId     : 2
explorer Session : 2
ShellHost procs  : 3704@s2
pwsh available   : True  (C:\Program Files\PowerShell\7\pwsh.exe, 7.6.6)
```

### 第一次抓到目标（probe-a 的关键输出）

```text
=== BEFORE ===
fg : 0x000302EE pid=15108 class=[Chrome_WidgetWin_1] title=[.gitattributes - ... - Visual Studio Code]
FindWindow(ControlCenterWindow) : (null)

=== sending Win+Ctrl+V ===
SendInput returned 6 events

=== AFTER ===
fg : 0x0001010C pid=7760 class=[ControlCenterWindow] title=[快速设置]
FindWindow(ControlCenterWindow) : (null)          <-- 注意：前台能拿到，FindWindow 拿不到
```

### band 分布（band-check.ps1）

```text
EnumWindows count = 127 ; desktop chain count = 127

--- band distribution among EnumWindows-visible windows ---
  band 1 : 117
  band 2 : 6
  band 16 : 4

--- notable classes ---
  Shell_TrayWnd                          EnumWindows-count=0
  Shell_SecondaryTrayWnd                 EnumWindows-count=0
  Progman                                EnumWindows-count=1  10162|Progman|4872|1
  WorkerW                                EnumWindows-count=13
  ControlCenterWindow                    EnumWindows-count=0
  Windows.UI.Core.CoreWindow             EnumWindows-count=4
  XamlExplorerHostIslandWindow           EnumWindows-count=0
  TopLevelWindowForOverflowXamlIsland    EnumWindows-count=0

--- band for notable windows ---
  Progman                  hwnd=0x00010162 band=1
  Chrome_WidgetWin_1       hwnd=0x00020578 band=1
```

### band 值（probe-e.ps1）

```text
=== WINDOW BAND TEST ===
  panel (ControlCenterWindow) band: ok=1 band=4
  Shell_TrayWnd               band: ok=1 band=6
  Progman                     band: ok=0 band=0
  a Chrome win                band: ok=0 band=0

=== DESKTOP CHILD CHAIN ===
desktop hwnd = 0x0001000C pid=6208 class=[#32769]
  child 0x00010360 pid=7088 class=[MSCTFIME UI]
  child 0x0001034A pid=7088 class=[IME]
  panel 0x000100FE is NOT in the desktop child chain
  desktop child count = 127

=== compare ===
  panel GA_PARENT   = 0x0001000C pid=6208 class=[#32769]
  GetDesktopWindow  = 0x0001000C pid=6208 class=[#32769]
  same desktop? True
  owner of panel's desktop window: csrss
```

**结论**：同一桌面、同一 HWND 树，但 **band=4** 的窗口不进枚举链表（band 1/2/16 才进）。

---

## 02 · band 与定位诊断（probe-c.ps1）

```text
=== 0. ENVIRONMENT ===
PSVersion      : 7.6.6
PSEdition      : Core
OS build       : 26300
my SessionId   : 2
ShellHost      : 3704@s2

=== 1. ENSURE PANEL STATE ===
no panel open
top-level window count before = 132

=== 2. OPEN PANEL (SendInput Win+Ctrl+V) ===
SendInput events = 6

=== 3. FOREGROUND WINDOW ===
fg            = 0x000100FE pid=3704 tid=5136 class=[ControlCenterWindow] title=[快速设置] vis=1 cloak=0 child=0 popup=1 style=0x94000000 ex=0x00200088 rect=(2176,0)-(2560,1478)
IsWindow(fg)  = True
GTI           = active=0x000100FE pid=3704 tid=5136 class=[ControlCenterWindow] ...
   focus=0x000302A6 pid=3704 tid=5136 class=[Windows.UI.Input.InputSite.WindowClass] title=[] vis=1 child=1
ancestry:
  [0] 0x000100FE ... class=[ControlCenterWindow]
  GA_ROOT   = 0x000100FE ...
  GA_PARENT = 0x0001000C pid=6208 class=[#32769]   (desktop)

=== 4. FindWindow RESULTS ===
FindWindow('ControlCenterWindow', null) = (null)
FindWindow(null, TITLE_QS)              = (null)
GetShellWindow()                        = 0x00010162 pid=4872 class=[Progman]

=== 5. ENUMWINDOWS / ENUMTHREADWINDOWS for ShellHost ===
-- pid 3704 (EnumWindows):
   0x0006007E pid=3704 tid=17044 class=[WorkerW]
   0x00020104 pid=3704 tid=5136 class=[Windows.UI.Core.CoreWindow] title=[DesktopWindowXamlSource] vis=0
   0x00060080 pid=3704 tid=17044 class=[IME]
   thread 5136 (EnumThreadWindows):
     0x00020104 pid=3704 tid=5136 class=[Windows.UI.Core.CoreWindow] ...

=== 6. IS THE PANEL A CHILD SOMEWHERE? ===
   (no ControlCenterWindow found among children)

=== 7. ENUMWINDOWS DIFF ===
   fg hwnd listed by EnumWindows? False
```

**要点**：`style=0x94000000` = `WS_POPUP|WS_VISIBLE|WS_CLIPSIBLINGS`，`ex=0x00200088` = `WS_EX_TOPMOST|WS_EX_TOOLWINDOW|WS_EX_NOREDIRECTIONBITMAP`；`IsWindow=True`、可见、未 cloak —— 一切"正常"，只是**枚举看不到**。线程 tid=5136，焦点子窗口 = `InputSite.WindowClass`。

---

## 03 · 子窗口与 XAML 宿主（probe-uia.ps1 + probe-d.ps1）

### probe-uia.ps1（UIA 也看不到；FromHandle 只给空壳）

```text
=== STEP 1: find the panel ===
foreground now : 0x000100FE pid=3704 class=[ControlCenterWindow] title=[快速设置]
  UIA RootElement did not find it either.

=== STEP 2: panel automation element ===
  Name            = [快速设置]
  ClassName       = [ControlCenterWindow]
  ControlType     = ControlType.Pane
  AutomationId    = []
  Framework       = Win32          <-- 空壳
  ProcessId       = 3704
  BoundingRect    = 2176,0 384x1478

=== STEP 3: descendant tree ===
  Pane | 快速设置 |  | ControlCenterWindow | ONSCREEN
total elements dumped = 1
```

### probe-d.ps1（真身在子窗口里）

```text
=== STEP 1: panel ===
  panel = 0x000100FE pid=3704 tid=5136 class=[ControlCenterWindow] title=[快速设置] vis=1 child=0

=== STEP 2: child window tree of the panel ===
  child count = 1
  0x000302A6 pid=3704 tid=5136 class=[Windows.UI.Input.InputSite.WindowClass] title=[] vis=1 child=1

=== STEP 3: UIA probe of every descendant HWND ===
  0x000100FE [ControlCenterWindow]                -> type=Pane framework=Win32 name=[快速设置] children=0
  0x000302A6 [Windows.UI.Input.InputSite.WindowClass] -> type=Pane framework=XAML  children=2

=== STEP 4: full UIA tree of the richest host ===
  best host = 0x000302A6 [Windows.UI.Input.InputSite.WindowClass] descendants=27
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

total = 28
```

---

## 04 · 元素树复现（hooks/qs-panel-probe.ps1）

```text
=== 1. locate panel (foreground only -- enumeration cannot see it) ===
  panel hwnd = 0x000100FE pid=3704 class=[ControlCenterWindow] title=[快速设置]
  FindWindow('ControlCenterWindow') would return : 0
  window band                                : 4

=== 2. child HWNDs of the panel ===
  0x000302A6 class=[Windows.UI.Input.InputSite.WindowClass] vis=True

=== 3. find the XAML host (UIA FrameworkId = XAML) ===
  xaml host = 0x000302A6 class=[Windows.UI.Input.InputSite.WindowClass]

=== 4. XAML automation tree ===
  ... (与 03 的 28 项完全一致) ...
  total elements = 28
```

---

## 05 · WinEvent 实测（hooks/event-test.ps1）★ 最关键

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
  ...

done.
```

**要点**
- 空闲 600ms：**0 事件** → 事件驱动检测真是 0 CPU。
- 面板 HWND **常驻**（开/关都是 `0x000100FE`）→ 只有首次 `OBJECT_CREATE`，之后每次只发 `SHOW`/`HIDE`。触发点用 SHOW/HIDE。
- `pid=4872`(=explorer) 的 `InputSite.WindowClass` 是任务栏那边的 island，反复 create/destroy，与本项目无关。

---

## 06 · Footer 几何（recon/footer-geom.ps1）

```text
panel closed -> opening with Win+Ctrl+V
panel = 0x000100FE
xaml host = 0x000302A6

=== 1. panel rect ===
  panel window : ControlCenterWindow rect=(2176,0 384x1478)

=== 2. locate AutomationId = Footer ===
  footer = Group |  | id=Footer | LandmarkTarget (2189,1417 358x48)

=== 3. parent chain (with rects) ===
  [0] Group | 声音输出 | id=PageWindow | NamedContainerAutomationPeer (2189,1065 358x400)
  [1] Group | 快速设置 | id=ControlCenterRegion | NamedContainerAutomationPeer (2188,1064 360x402)
  [2] Pane |  | id= | Windows.UI.Input.InputSite.WindowClass (2176,0 384x1478)
  [3] Pane | 快速设置 | id= | ControlCenterWindow (2176,0 384x1478)
  [4] Pane |  | id= | #32769 (0,0 2560x1510)

=== 4. footer subtree (rects) ===
  Group |  | id=Footer | LandmarkTarget (2189,1417 358x48)
    Button | 更多音量设置 | id= | Button (2193,1420 94x40)
      Text | 更多音量设置 | id= | TextBlock (2204,1435 72x9)

=== 5. all direct children of the Footer's PARENT (layout context) ===
  parent = Group | 声音输出 | id=PageWindow | NamedContainerAutomationPeer (2189,1065 358x400)
    - Button | 后退 | id=BackButton | Button (2193,1069 40x40)
    - Text | 声音输出 | id=PageTitleText | TextBlock (2237,1084 56x10)
    - Group | Windows 徽标键，控件， | id= | NamedContainerAutomationPeer (2301,1081 65x16)
    - Pane |  | id=ListContent | ScrollViewer (2189,1113 358x304)
    - Group |  | id=Footer | LandmarkTarget (2189,1417 358x48)
```

**可用空间计算**

| 量 | 值 |
|---|---|
| Footer 矩形 | `x=2189, y=1417, 358 x 48` |
| Footer 右边界 | `2189 + 358 = 2547` |
| 「更多音量设置」按钮 | `x=2193, y=1420, 94 x 40`；右边界 `2287` |
| **按钮右侧空位** | **`x = 2287 … 2547` → 约 256 x 40**，够放一个居右的入口 |

---

## 07 · XAML 导出表（recon/pexports.ps1）

```text
file    : C:\Windows\System32\Windows.UI.Xaml.dll
version : 10.0.26100.8972
exports : 16
  CalculateAvailableMonitorRect
  CreateString
  CreateXamlUIPresenter
  DeleteString
  DisableDeferredInvoke
  DllCanUnloadNow
  DllGetActivationFactory
  DllMain
  GetDependencyObjectAddress
  GetErrorContextIndex
  GetGlobalModuleParams
  GetStringLen
  GetStringRawBuffer
  InitializeXamlDiagnosticsEx        <-- XAML 诊断入口
  OverrideXamlMetadataProvider       <-- 可注入自己的 XAML 类型/元数据
  OverrideXamlResourcePropertyBag

file    : C:\Windows\SystemApps\Microsoft.UI.Xaml.CBS_8wekyb3d8bbwe\Microsoft.UI.Xaml.dll
version : 2.9.2603.18001
exports : 4
  DllCanUnloadNow
  DllGetActivationFactory
  DllMain
  SendTelemetryOnSuspend             <-- WinUI3 这边没有诊断入口

XamlDiagnostics.dll on disk?
  C:\Windows\System32\XamlDiagnostics.dll : False
  C:\Windows\SysWOW64\XamlDiagnostics.dll : False
```

**结论**：诊断 API **只在 System XAML 侧有**（`InitializeXamlDiagnosticsEx`），且 `XamlDiagnostics.dll`（"tap" DLL）**不在系统里**，要从 Windows SDK 拿。

---

## 08 · ShellHost 模块清单（169 个，关键项）

```text
ControlCenter.dll               <-- 快速设置的本体实现
Microsoft.UI.Xaml.dll           C:\WINDOWS\SystemApps\Microsoft.UI.Xaml.CBS_8wekyb3d8bbwe\  (2.9.2603.18001)
Windows.UI.Xaml.dll             C:\Windows\System32\  (10.0.26100.8972)      <-- System XAML
Windows.UI.Xaml.Controls.dll    (10.0.10011.16384)
Windows.UI.Xaml.Phone.dll
Windows.UI.Immersive.dll
Windows.UI.dll
UiaManager.dll
uiautomationcore.dll
OLEACC.dll
QuickActionsDataModel.dll
windowsudk.shellcommon.dll
SettingsHandlers_*.dll
CoreMessaging.dll / InputHost.dll / dcomp.dll / directmanipulation.dll
```

**缺席的**：`Microsoft.UI.Content.*`、`Microsoft.UI.Windowing.*`、`Microsoft.UI.Dispatching.dll` → ShellHost 里的 WinUI3 **没有在驱动窗口**；
加上 island 宿主窗口类是 `Windows.UI.Input.InputSite.WindowClass`（`DesktopWindowXamlSource` 的宿主类），
⇒ **快速设置面板是 System XAML（`Windows.UI.Xaml`）**，不是 WinUI3。

---

## 09 · L1 主面板元素树（hooks/qs-panel-probe.ps1，2026-10-03 补采）

> 此前 §03/§04 只覆盖 L2（声音输出页）。本节补采 **L1（主快速设置页）**，
> 用于给「入口接管」方案选址。开面板方式为 `Win+A`（**不是** `Win+Ctrl+V`，后者直接进 L2）。

```text
=== 1. locate panel (foreground only -- enumeration cannot see it) ===
  panel hwnd = 0x000200F0 pid=7536 class=[ControlCenterWindow] title=[快速设置]
  FindWindow('ControlCenterWindow') would return : 0
  window band                                : 4

=== 2. child HWNDs of the panel ===
  0x00010342 class=[Windows.UI.Input.InputSite.WindowClass] vis=True

=== 3. find the XAML host (UIA FrameworkId = XAML) ===
  xaml host = 0x00010342 class=[Windows.UI.Input.InputSite.WindowClass]

=== 4. XAML automation tree: ControlType | Name | AutomationId | ClassName ===
  Pane |  | id= | Windows.UI.Input.InputSite.WindowClass
  | Group | 媒体传输控件 | id=MediaTransportControls | NamedContainerAutomationPeer | offscreen
  | Group | 快速设置 | id=ControlCenterRegion | NamedContainerAutomationPeer
  | | Button | 飞行模式 | id=Microsoft.QuickAction.AirplaneMode |  | DISABLED
  | | Text | 飞行模式 | id=TitleText | TextBlock
  | | Button | 辅助功能 | id=Microsoft.QuickAction.Accessibility | 
  | | Text | 辅助功能 | id=TitleText | TextBlock
  | | Button | 节能模式 | id=Microsoft.QuickAction.BatterySaver | 
  | | Text | 节能模式 | id=TitleText | TextBlock
  | | Button | 实时字幕 | id=Microsoft.QuickAction.LiveCaptions | 
  | | Text | 实时字幕 | id=TitleText | TextBlock
  | | Button | 夜间模式 | id=Microsoft.QuickAction.BlueLightReduction | 
  | | Text | 夜间模式 | id=TitleText | TextBlock
  | | Button | 就近共享 | id=Microsoft.QuickAction.NearShare | 
  | | Text | 就近共享 | id=TitleText | TextBlock
  | | Button | 投放 | id=Microsoft.QuickAction.Cast |  | offscreen
  | | Text | 有线显示器 | id=StatusText | TextBlock | offscreen
  | | Button | 投影 | id=Microsoft.QuickAction.ProjectL2 |  | offscreen
  | | Text | 投影 | id=TitleText | TextBlock | offscreen
  | | Menu | 寻呼机 | id=QuickActionsPager | Microsoft.UI.Xaml.Controls.PipsPager
  | | | Button | 上一页 | id=PreviousPageButton | Button | DISABLED
  | | | Pane |  | id=PipsPagerScrollViewer | ScrollViewer
  | | | | Button | 页面 1 | id= | Button
  | | | | Button | 页面 2 | id= | Button
  | | | Button | 下一页 | id=NextPageButton | Button
  | | Button | 静音音量 | id=Microsoft.QuickAction.VolumeNoTimer | ToggleButton
  | | Slider | 声音输出 | id= | Slider
  | | Button | 选择声音输出 | id=VolumeL2Button | Button
  | | Group |  | id=FooterGrid | LandmarkTarget
  | | | Button | 电池 | id=Microsoft.QuickAction.Battery | Button
  | | | Button | 所有设置 | id=Microsoft.QuickAction.AllSettings | Button

  total elements = 31
```

**要点**：

- 入口按钮 = `VolumeL2Button`，`Name` = 「选择声音输出」（与 tooltip 一致），`ControlType` = `Button`；
- 音量行由三个同级元素组成：`静音音量`(ToggleButton) / `声音输出`(Slider) / `选择声音输出`(Button)；
- ⚠️ `Microsoft.QuickAction.ProjectL2` 证明 **L2 入口是一组**（命名规律 `L2` 后缀 = 导航到二级页），
  因此"拦 `L2Frame.Navigating` 并无条件 Cancel"会误伤兄弟入口；
- `FooterGrid` 属于 L1 自身底栏（含「电池」「所有设置」），与声音页的 `Footer` 同名不同物。
