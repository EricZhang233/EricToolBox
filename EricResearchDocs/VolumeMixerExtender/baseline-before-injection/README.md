# 注入前基线（实测证据快照）

本目录是**注入发生之前**测到的客观事实。它的作用是：**任何"位置对不对""行为对不对"的判断，都以这里的数据为基准**，而不是靠记忆或推断。

采集时间：2026-10-03
环境：Windows 11 build 26300.9550，交互会话 2，System XAML
原始合集：`docs/reference/raw-outputs.md`（392 行，八节）—— 下方的 `.md` 文件是它的**逐字摘录**，只在文件头加了来源说明。

---

## 1. 文件与它支撑的结论

| 文件 | 内容 | 支撑的结论 |
|---|---|---|
| `01-window-locating-and-band.md` | 环境与会话、首次抓到目标窗口、band 分布统计、`GetWindowBand` 实测值 | 面板是 **band=4** 窗口；`EnumWindows`/`FindWindow`/UIA `RootElement` **都看不到它**；拿 HWND 只能靠 `GetForegroundWindow()`/`GetGUIThreadInfo()` |
| `02-xaml-host-and-element-tree.md` | `probe-uia.ps1`（UIA 看不到面板）、`probe-d.ps1`（真身在子窗口）、`qs-panel-probe.ps1`（28 元素树） | `ControlCenterWindow` 在 UIA 里是**空壳**；真 XAML 树在子窗口 `Windows.UI.Input.InputSite.WindowClass`（`FrameworkId=XAML`）里；声音输出页有 28 个元素，关键 `AutomationId` 已枚举 |
| `03-winevent-test.md` | `SetWinEventHook` 两组对照实验 | **band 窗口照发 WinEvent**（`OBJECT_SHOW`/`OBJECT_HIDE`/`SYSTEM_FOREGROUND`），且空闲 600ms **0 事件** ⇒ 事件驱动检测 = **0 CPU** |
| `04-footer-geometry-before-injection.md` | ★ `poc/archive/recon/footer-geom.ps1` 的输出 | **注入前的底栏几何** —— 见下方"关键基准值" |
| `05-xaml-exports-and-shellhost-modules.md` | `pexports.ps1` 对 `Windows.UI.Xaml.dll` 的导出表 + ShellHost 已加载模块清单 | 面板是 **System XAML** 而不是 WinUI3；`Windows.UI.Xaml.dll` 导出 `InitializeXamlDiagnosticsEx`/`GetDependencyObjectAddress`/`OverrideXamlMetadataProvider`；`ControlCenter.dll` 只导出 3 个符号 |
| `element-persistence.txt` | ★ 元素 runtime id 实测对比（5/5 全变） | **XAML 元素实例每次打开面板都重建**（只有 HWND 常驻）。这是"事件驱动 + 每次重新注入"方案的基石，也解释了"为什么关闭面板后按钮自动消失、不需要清理逻辑" |
| `injection-feasibility.txt` | 完整性级别 / PPL 检查 / `OpenProcess` 权限测试 | ShellHost 与我们的进程**同为 Medium IL、非 PPL**，`OpenProcess(ALL_ACCESS)` **成功** ⇒ 经典 DLL 注入可行 |

> ⚠️ **`injection-feasibility.txt` 里有一处结论后来被推翻了，读的时候必须知道**：
>
> 该文件第 4 节写着「is XamlDiagnostics.dll available from any Windows SDK on this machine? → **NOT FOUND**」。
> **这是错的** —— 那次递归搜索漏报了。诊断运行时**在本机存在**，就在：
> `C:\Program Files (x86)\Windows Kits\10\bin\x64\XamlDiagnostics\xamldiagnostics.dll`
> （arm64/x86 也有；PoC 后来用的就是这个路径，实测可用。）
>
> 这个误报一度让"方案 B（XAML 诊断 TAP）不可行"看起来成立。**保留原件不改**是有意的 —— 它记录了当时的真实认知状态，
> 而纠正记录在交付文档里（C++ 版 §10.2 S7）。
> **教训**：`Get-ChildItem -Recurse` 在 `Program Files` 这类目录上会因为权限/重定向静默漏项，探测 SDK 路径时不要只靠一次递归搜索。

---

## 2. ★ 关键基准值（下面每一条都是后面所有判断的基准）

| 项 | 值 | 在哪 |
|---|---|---|
| 面板窗口类 / 标题 | `ControlCenterWindow` / 「快速设置」 | `01-` |
| 面板窗口 **band** | **4** | `01-` |
| 面板宿主进程 | `ShellHost.exe`（父进程 `sihost.exe`） | `01-` |
| 面板子窗口（真 XAML 宿主） | `Windows.UI.Input.InputSite.WindowClass`，UIA `FrameworkId = XAML` | `02-` |
| 面板的 XAML 实现 | **System XAML** = `Windows.UI.Xaml.dll` 10.0.26100.8972（**不是** WinUI3） | `05-` |
| **底栏 `Footer` 几何** | `(2189,1417) 358x48` | `04-` |
| **模型按钮「更多音量设置」几何** | `(2193,1420) 94x40` | `04-` |
| 底栏右侧空位 | `x = 2287..2547`，约 `256x40` | `04-` |
| 元素生命周期 | 每次打开面板重建；只有 HWND 常驻 | `element-persistence.txt` |
| 注入可行性 | Medium IL、非 PPL、`OpenProcess(ALL_ACCESS)` 成功 | `injection-feasibility.txt` |

---

## 3. 从这些数据直接推出的三条设计决定

这三条不是"最佳实践"，而是**被基线数据逼出来的**：

| 设计决定 | 依据 |
|---|---|
| ⭐ **必须走 XAML 诊断 API（TAP）这条路，不能 hook 创建点** | `05-` 显示 `ControlCenter.dll` 只导出 3 个符号（`ControlCenterMain`/`DllCanUnloadNow`/`DllGetActivationFactory`），`ControlCenter.*` 类**没有注册**为 `ActivatableClassId`；而 `Windows.UI.Xaml.dll` **有** `InitializeXamlDiagnosticsEx`。后来实测证明"拦激活工厂"这条路是死的（见交付文档 §6.1/§10.1 的方案 A 证伪） |
| ⭐ **必须每次面板打开都重新注入，不能缓存元素引用** | `element-persistence.txt`：XAML 元素实例每次打开都重建。⇒ 方案只能是"事件驱动：`Footer` 出现时注入"，而不是"找到一次就长期持有" |
| ⭐ **检测/触发机制可以做到 0 CPU** | `03-`：band 窗口照发 WinEvent，空闲期 0 事件 ⇒ 用 `SetWinEventHook`/进程句柄等待而不是轮询。交付文档里 Watcher 的"用 `WaitForMultipleObjects` 等进程句柄"就是这个结论的直接应用 |
