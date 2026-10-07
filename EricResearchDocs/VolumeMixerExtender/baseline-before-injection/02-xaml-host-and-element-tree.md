<!-- 冻结快照：内容逐字摘录自 docs/reference/raw-outputs.md §03–§04 -->

> **来源**：`docs/reference/raw-outputs.md §03–§04`（逐字摘录，未改写）
> **采集时间**：2026-10-03
> **环境**：Windows 11 build 26300.9550，交互会话 2，System XAML
> **用途**：支撑"ControlCenterWindow 在 UIA 里是空壳、真 XAML 树在子窗口 InputSite 里"，以及"声音输出页 28 个元素与关键 AutomationId（含 Footer）"这两条结论。

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

