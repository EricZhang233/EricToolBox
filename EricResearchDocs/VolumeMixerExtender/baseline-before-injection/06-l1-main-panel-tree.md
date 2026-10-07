> **来源**：本机实测，`docs/poc/scripts/qs-panel-probe.ps1` 直接输出（逐字摘录，未改写）
> **采集时间**：2026-10-03
> **环境**：Windows 11 build 26300.9550，交互会话 2，System XAML
> **用途**：支撑「入口接管」新方案的选址。此前所有证据都只覆盖 L2（声音输出页），
> L1（主快速设置页）的元素树从未采集，而新方案要劫持的入口按钮在 L1 上。

---

## 01 · L1 主面板完整元素树

开面板方式：`Esc` 关掉已有面板 → `Win+A` 打开快速设置（停在 L1，**不按 `Win+Ctrl+V`**，
后者会直接进 L2）。随后照常跑 `qs-panel-probe.ps1`——它用 `GetForegroundWindow()` 抓当前前台面板，
所以只要面板停在 L1，抓到的就是 L1 的树。

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

---

## 02 · 三条结论

### 2.1 入口按钮已确认：`VolumeL2Button`

| 属性 | 值 |
|---|---|
| `AutomationId` | **`VolumeL2Button`** |
| `Name` | **`选择声音输出`**（与用户可见 tooltip 一致） |
| `ControlType` | `Button` |
| 位置 | `ControlCenterRegion` 的**直接子元素**，与音量条 `Slider` 同级 |

音量这一行由三个同级元素构成：

```text
| | Button | 静音音量     | id=Microsoft.QuickAction.VolumeNoTimer | ToggleButton
| | Slider | 声音输出     | id=                                     | Slider
| | Button | 选择声音输出 | id=VolumeL2Button                       | Button
```

> ⚠️ 判别要点：`Name` 为「选择声音输出」的才是入口。同一层还有「静音音量」
> (`ToggleButton`) 与「声音输出」(`Slider`)，名称相近，**按 `AutomationId` 匹配最稳**。

### 2.2 ⚠️ 进入 L2 的入口不止一个 —— 拦导航会误伤

同一份树里：

```text
| | Button | 投影 | id=Microsoft.QuickAction.ProjectL2 |  | offscreen
```

命名规律是 **`L2` 后缀 = 该按钮导航到二级页**（`Microsoft.QuickAction.ProjectL2` 即"投影"的二级页）。
由此可推：L2 入口是**一组**，而非仅音量这一个。

**这直接否掉了一种实现思路**：在 `L2Frame` 上挂 `Navigating` 并无条件 `Cancel`，
会把"投影"等兄弟入口一并劫持。若要走拦截路线，必须按 `SourcePageType` 精确甄别目标页类型。

现方案（**导航后换内容**）不受此影响：它只在声音页真正出现时动作，天然不涉及其他页。

### 2.3 `FooterGrid` 属于 L1，与声音页底栏无关

```text
| | Group |  | id=FooterGrid | LandmarkTarget
| | | Button | 电池       | id=Microsoft.QuickAction.Battery
| | | Button | 所有设置   | id=Microsoft.QuickAction.AllSettings
```

L1 自己的底栏，装着「电池」「所有设置」，**非空**（早前笔记里"一直是空的"这句需按此修正）。
声音输出页的底栏是页面级的 `Footer`（`PageWindow → FullScreenPage → L2Frame → PageContent → Footer`）。
两者同名不同物，注入时的匹配条件只能认后者。

---

## 03 · L1 与 L2 的互斥关系

| | 元素数 | `ControlCenterRegion` 下的内容 |
|---|---|---|
| **L1**（本文件） | **31** | 快捷按钮组（飞行模式…所有设置）+ `FooterGrid` |
| **L2**（[02-xaml-host-and-element-tree.md](02-xaml-host-and-element-tree.md)） | **28** | `PageWindow`（后退键 / 标题 / `ListContent` / `Footer`） |

两态**互斥**：`ControlCenterRegion` 里要么是快捷按钮组，要么是 `PageWindow`，不会并存。

> L2 态下整套快捷按钮消失、`PageWindow` 出现 —— 说明这是**同一容器内的内容替换式导航**，
> 而非叠层。这也解释了为什么"换掉 `ListContent` 的内容"是安全的：我们改的是 L2 态内部的
> 一个子区域，不影响导航模型本身。

---

## 04 · 复现方法

```powershell
# 1) 确保面板关着（若开着，Esc）
# 2) Win+A 打开快速设置，停在 L1  ← 关键：不要用 Win+Ctrl+V，那个直接进 L2
# 3) 前台面板即 L1，直接跑既有脚本
pwsh -NoProfile -File docs\poc\scripts\qs-panel-probe.ps1
```

`qs-panel-probe.ps1` 用 `GetForegroundWindow()` 定位面板，因此**无需任何改动**即可采 L1 或 L2
——取决于开面板时用的是哪个快捷键。这一点此前未被记录，补上。
