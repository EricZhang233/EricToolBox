<!-- 冻结快照：内容逐字摘录自 docs/reference/raw-outputs.md §05 -->

> **来源**：`docs/reference/raw-outputs.md §05`（逐字摘录，未改写）
> **采集时间**：2026-10-03
> **环境**：Windows 11 build 26300.9550，交互会话 2，System XAML
> **用途**：支撑"band 窗口照发 WinEvent，且空闲期 0 事件"这一结论 —— 它是"事件驱动检测 = 0 CPU"的依据。

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

