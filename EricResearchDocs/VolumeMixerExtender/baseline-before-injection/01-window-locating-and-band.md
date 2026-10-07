<!-- 冻结快照：内容逐字摘录自 docs/reference/raw-outputs.md §01–§02 -->

> **来源**：`docs/reference/raw-outputs.md §01–§02`（逐字摘录，未改写）
> **采集时间**：2026-10-03
> **环境**：Windows 11 build 26300.9550，交互会话 2，System XAML
> **用途**：支撑"面板是 band=4 窗口、EnumWindows/FindWindow/UIA RootElement 都看不到它"这一结论，以及"拿 HWND 只能靠 GetForegroundWindow/GetGUIThreadInfo"的结论。

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

