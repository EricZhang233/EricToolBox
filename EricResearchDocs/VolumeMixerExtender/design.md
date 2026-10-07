# 注入设计：接管「选择声音输出」入口，用自绘页面替换系统声音页

> 目标（Eric 定稿）：点击快速设置**主面板（L1）的「选择声音输出」按钮**后，
> 直接进入**自定义页面**；声音页原有的底栏按钮改为**系统页 ↔ 自定义页的切换**。
> 目标机：Windows 11 build 26300.9550，ShellHost.exe，System XAML。
> 所有实测数据见 `reference/raw-outputs.md`。
>
> **演进脉络（2026-10-03）**：
> - 最初目标是"在声音页底栏加一个居右入口" —— 该技术路线**已跑通**，见 §6
> - 方案 A（vtable 打补丁）**已证伪**，仅作历史记录，见 §2 §3
> - **当前方向见 §7**：入口接管 + 页面内容替换（底栏注入法本身仍然复用）

---

## 1. 事实基线（全部已实测，不是推测）

| # | 事实 | 出处 |
|---|---|---|
| F1 | 面板窗口类 `ControlCenterWindow`，**band=4**；`EnumWindows`/`FindWindow`/UIA `RootElement` 都看不到它 | §01 §02 |
| F2 | 面板窗口 **HWND 常驻**（开关都是 `0x000100FE`），只有首建发 `OBJECT_CREATE` | §05 |
| F3 | **XAML 元素实例每次打开都重建**（runtime id `.4.76` → `.4.114`，5/5 全变） | 见 `baseline-before-injection/element-persistence.txt` |
| F4 | 真 XAML 树挂在子窗口 `Windows.UI.Input.InputSite.WindowClass`（`FrameworkId=XAML`）下 | §03 |
| F5 | 面板是 **System XAML**（`Windows.UI.Xaml.dll` 10.0.26100.8972 已加载；`Microsoft.Internal.FrameworkUdk.dll` / `Microsoft.UI.Content.*` **均未加载**） | §08 |
| F6 | ShellHost 与我们的进程**同为 Medium IL**，**非 PPL**，`OpenProcess(ALL_ACCESS)` **成功** → 经典 DLL 注入可行 | `baseline-before-injection/injection-feasibility.txt` |
| F7 | `Windows.UI.Xaml.dll` 导出 `InitializeXamlDiagnosticsEx`、`GetDependencyObjectAddress`、`OverrideXamlMetadataProvider`；WinUI3 侧无诊断入口 | §07 |
| F8 | `XamlDiagnostics.dll`（诊断 tap DLL）**在机器上找到了**：`C:\Program Files (x86)\Windows Kits\10\bin\x64\XamlDiagnostics\xamldiagnostics.dll`（arm64/x86 也有）。见 F13 | 实测（此前一次递归搜索漏报，已更正） |
| F13 | **本机有原生工具链**：`cl.exe` = `C:\Program Files\Microsoft Visual Studio\18\Community\VC\Tools\MSVC\14.50.35717\bin\Hostx64\x64\cl.exe`（另有 VS2022 BuildTools 14.44）；CMake 在 `C:\Program Files\CMake\bin\cmake.exe`；dotnet SDK 8.0.425 / 10.0.103。注意：**都不在 PATH 上**，也没有 vswhere/msbuild.exe | 实测 |
| F9 | 面板本体实现是 `ControlCenter.dll`（4 MB，WinRT 组件，只导出 3 个：`ControlCenterMain` / `DllCanUnloadNow` / `DllGetActivationFactory`） | §08 |
| F10 | `ControlCenter.dll` 内含类名（字符串）：`ControlCenter.ControlCenterPage`、`ControlCenter.ControlCenterView`、`ControlCenter.ControlCenterViewModel`、`ControlCenter.IVolumeMixerList`、`ControlCenter.AsyncSlider` … | 见下 §2 |
| F11 | **`ControlCenter.*` 没有注册到 `HKLM\...\WindowsRuntime\ActivatableClassId`** → `RoGetActivationFactory` 拿不到；只能直接调它自己的 `DllGetActivationFactory` | 实测 |
| F12 | Footer 几何：`x=2189, 358x48`；「更多音量设置」按钮 `x=2193, 94x40`；**右侧空位 `x=2287..2547`，约 256x40** | §06 |

`ControlCenter.dll` 里的类名（节选，共 60+）：

```text
ControlCenter.ControlCenterPage        ControlCenter.IControlCenterPage
ControlCenter.ControlCenterView        ControlCenter.IControlCenterView
ControlCenter.ControlCenterViewModel   ControlCenter.IVolumeMixerList
ControlCenter.AsyncSlider              ControlCenter.IAsyncSlider
ControlCenter.AccessibleItemContainer  ControlCenter.IQuickActionToggleButton
ControlCenter.DelegateCommand          ControlCenter.MediaTransportControls
```

**关键推论**：面板是「一个 WinRT 组件 DLL 提供的 XAML Page」，而且**每次打开都重新实例化**（F3）——
⇒ 只要拦住**页面的实例化**，就能在"页面刚建好"时拿到它的 `IInspectable*`，然后直接操作 XAML 树。

---

## 2. 方案选型

| 方案 | 可行性 | 依赖 | 脆弱性 | 结论 |
|---|---|---|---|---|
| **A. 激活工厂 vtable hook**（`ControlCenter.dll!DllGetActivationFactory` → 拦 `ActivateInstance`） | ❌ **已证伪**：hook 本身能装上（自测命中），但 shell **根本不用 `IActivationFactory::ActivateInstance` 创建这些编译期 XAML 对象**——全新 ShellHost + 面板首开后命中 **0 次**。详见 §6.1 | 无 | — | **不采用** |
| B. XAML 诊断 API（`InitializeXamlDiagnosticsEx` + `IVisualTreeService`） | ✅ **已跑通**：API 支持 `CreateInstance`/`AddChild`/`SetProperty`，`IXamlDiagnostics::GetIInspectableFromHandle` 给出真 `IInspectable`；`AdviseVisualTreeChange` 能推元素事件（正好在 `Footer` 出现时拦） | **本机已有 `xamldiagnostics.dll`（F8）+ `cl.exe`（F13）**；需自写 TAP DLL（实现 `IObjectWithSite` + `DllGetClassObject`，**无需注册表**） | 低：走文档化的 COM 契约，**不依赖类名/RVA/特征码** | **✅ 采用，已落地（§6）** |
| B′. A 与 B 组合 | — | 同上 | — | A 证伪后**无意义**，已放弃 |
| C. hook 组件实现方法（Windhawk/EP 套路：`TaskListButton::UpdateVisualStates` 之类） | ⚠️ 需按符号名/RVA 定位 | PDB 符号或特征码 | **高**（build 26300 很前沿，符号一变就崩） | 不采用 |
| D. 悬浮窗（`WS_EX_NOACTIVATE`） | ✅ | 无 | 低 | 不采用（失焦掉面板、非原生观感，§4.2 已否） |

---

## 3. 方案 A 的详细设计（**已证伪，仅作记录**，见 §6.1）

### 3.1 总体结构

```text
injector.exe（我们的进程，Medium IL）
  └─ OpenProcess(ALL_ACCESS) → VirtualAllocEx → WriteProcessMemory(DLL 路径)
     → CreateRemoteThread(LoadLibraryW)                       [F6 已验证可行]
        └─ 注入进 ShellHost.exe：vcxmix-hook.dll
             ├─ 1) 定位 ControlCenter.dll（已加载，F9）
             ├─ 2) GetProcAddress("DllGetActivationFactory")
             ├─ 3) 对每个 ControlCenter.* 类名调 DllGetActivationFactory
             │       → 得到单例 IActivationFactory*
             │       → 打补丁：vtable[6] = 我们的 ActivateInstance detour
             ├─ 4) 同时 inline hook DllGetActivationFactory 导出，
             │       把"之后才被激活"的工厂也一并包装
             └─ 5) detour 里：ActivateInstance 返回的 IInspectable* 就是页面
                     → try_as<FrameworkElement>() → add_Loaded(...)
                     → Loaded 回调里 FindName(L"Footer")
                     → 造一个 Button → Children().Append(button)
```

### 3.2 为什么是 vtable[6]

```text
IUnknown      : QueryInterface(0) AddRef(1) Release(2)
IInspectable  : GetIids(3) GetRuntimeClassName(4) GetTrustLevel(5)
IActivationFactory : ActivateInstance(6)      <-- 就是这一格
```

实现方式（两条都行，建议后者）：
- 改工厂对象的 vtable 指针 → 指向我们复制的表（污染面小，只影响这一个对象）；**注意**：工厂是**单例**，改它等于全局生效，正是我们要的。
- 或 `VirtualProtect(PAGE_READWRITE)` 直接改 `.rdata` 里那张 vtable 的第 6 格（更简单，但影响该 vtable 的所有实例）。

### 3.3 关键 API 签名

```c
// ControlCenter.dll 的导出
HRESULT DllGetActivationFactory(HSTRING activatableClassId, IActivationFactory** factory);

// IActivationFactory
HRESULT ActivateInstance(IInspectable** instance);

// 造控件（XAML 侧）
RoGetActivationFactory(HSTRING(L"Windows.UI.Xaml.Controls.Button"), IID_IActivationFactory, &f);
f->ActivateInstance(&btn);
btn->put_Content(/* ... */);
btn->put_HorizontalAlignment(/* 2 = Right */);

// 找元素
FrameworkElement::FindName(HSTRING(L"Footer"), IInspectable**);   // AutomationId "Footer" 大概率就是 x:Name
// 或 VisualTreeHelper::GetChildrenCount/GetChild 递归 + AutomationProperties::GetAutomationId
```

### 3.4 插入时机与线程

- `ActivateInstance` 会在**创建页面的那个线程**上被调用；XAML 页面只能在 UI 线程建 → **detour 本身就是 UI 线程**，可直接调 XAML API（C 里那个 RPC_E_WRONG_THREAD 的坑不存在）。
  ⚠️ 仍需在 PoC 里**实测确认**（V1 打日志记录 tid，和 `ControlCenterWindow` 的 tid=5136 比对）。
- **不要在 `ActivateInstance` 返回后立刻插元素**：那一刻 `OnApplyTemplate` 可能还没跑，`FindName("Footer")` 可能返回 null（Windhawk 的 mod 也踩过这个坑，注释原文：*"Calling ApplyAllSettings immediately from the constructor fires before the XamlRoot is stable … crash the process on startup"*）。
- **正确做法**：`add_Loaded(...)`，等页面的 `Loaded` 事件，再插。插之前判空 + try/catch，失败就静默放弃（不抛进 shell）。

### 3.5 居右对齐的落法（需运行时确认 Footer 类型）

Footer 现在只有 1 个子元素（「更多音量设置」按钮，`94x40` 靠左），说明 Footer 很可能是 **Grid**（左对齐子项 + 剩余空间）或 **水平 StackPanel**。两种情况的处理不同：

| Footer 实际类型 | 落法 |
|---|---|
| `Grid`（最常见） | 把我们的 Button 追加进去，`HorizontalAlignment = Right`；若 Grid 有 `ColumnDefinitions` 且最后一个列是自适应/星号，则用 `Grid::SetColumn(btn, last)` + `HorizontalAlignment=Right` |
| 水平 `StackPanel` | 追加会紧贴上一个按钮（不是贴右）→ 需要包一层：`Grid{ ColumnDefinitions: Auto, * }`，或改用 `RelativePanel`/设置 Footer 的 `HorizontalAlignment=Stretch` + 插入一个 `Width=*` 的 spacer，或直接在 Footer 里插一个 `Grid` 包住两者 |
| `RelativePanel` | `RelativePanel::SetAlignRightWithPanel(btn, true)` |

⇒ **PoC 第 3 步必须先 dump Footer 的 `winrt::get_class_name()` 和它的子元素类型**，再决定落法。这是设计里唯一还没定死的点。

### 3.6 失败的兜底

- 所有 detour body 用 `try/catch(...)` 包死：**任何异常都不许逃进 shell**。
- 版本/类名对不上（`DllGetActivationFactory` 返回失败 / `FindName` 一直 null）→ 打日志、卸钩子、保持沉默。
- 崩了 ShellHost 的后果：任务栏/开始/快速设置会重启（`ShellHost.exe` 由系统托管重启），但**若崩在 UI 线程可能连带 explorer 体验异常** → 必须先在**只加载不做事**的 V0 阶段验证稳定性。
- Defender：`CreateRemoteThread + LoadLibraryW` 是木马经典手法，很可能被拦 → 需要为输出目录/进程加排除（自己的机器、自己用，可接受）。

### 3.7 分阶段验证计划（每步都有可判定的通过标准）

| 阶段 | 内容 | 通过标准 |
|---|---|---|
| **V0** | 只注入，DLL 里只写日志（不 hook） | ShellHost 不崩；反复开关面板 10 次无异常；日志文件出现 |
| **V1** | hook `DllGetActivationFactory`，只**记录**被激活的类名 + tid | 开关面板一次，日志里出现页面类名；tid == 面板 tid（5136） |
| **V2** | 对 `ControlCenter.*` 全部类名逐个拿工厂 + 打 vtable[6]，记录 `ActivateInstance` 拿到的 `IInspectable*` 的 `GetRuntimeClassName` | 能打印出页面对象的真实运行时类名 → **确定是哪个类** |
| **V3** | 在该页面上 `FindName("Footer")`，dump Footer 的类名/子元素类型/子元素数 | 拿到 Footer 的类型 → 定下 §3.5 的落法 |
| **V4** | 追加一个纯色 Button（不绑逻辑），按 §3.5 居右 | 目视：面板底栏右侧出现按钮，位置在 `x≈2287..2547` 区间内 |
| **V5** | 绑 `Click`（`add_Click` + 自写 `winrt::implements` 委托）→ 打开「音量合成器」页或自己的程序 | 点击有反应；面板行为不受影响 |

---

## 4. 还没解决 / 待确认

> §4 是**方案 A 时期**的待办清单，逐项现状见括号（2026-10-03 更新）。

1. **哪个 `ControlCenter.*` 类对应「声音输出」页** —— （**已无关**：A 已证伪，B 不需要类名）
2. **Footer 的 XAML 类型**（决定 §3.5）—— （**已解决**：`Footer` 是 `ItemsControl`，`ItemsPanel` 是**纵向** `StackPanel`；落法见 §6.3，§3.5 那份三选一表格里的"水平 StackPanel"一行不是本案）
3. **`ActivateInstance` 是否真的在 UI 线程** —— （**已无关**：拦截根本没触发）
4. **方案 A vs B 的取舍** —— （**已定**：A 证伪，B 落地。B 的进程级单例 / 无 teardown 限制仍然成立，但已接受）
5. **Defender 是否会拦注入** —— （**实测不会**：`CreateRemoteThread + LoadLibraryW` 反复注入 ShellHost 全程无拦截）
6. **构建注意** —— （**已解决**：`build.cmd` 在同一个 `cmd.exe` 里 `call vcvars64.bat` 后调用 `cl`）

---

## 5. 参考（来自调研 agent 报告，见 `reference/research-agent-report.md`）

- Windhawk mod `taskbar-content-presenter-injector.wh.cpp`：**在 WinRT 实现方法里往 `panel.Children().Append(presenter)`** —— 与我们 V4 的做法同类；它还给出 `GetFrameworkElementFromNative`（从 native `this` 反查 WinRT 对象，偏移 `+3` 指针）与 `SYMBOL_HOOK` 表。
- ExplorerPatcher `ShellExperienceHostPatches.cpp`：hook `NetworkUX::App::LoadResourceDictionaries` + 改 `Application.Resources` 的 `QuickActionControlStyle.Setters()`。**注意**：那是**旧**的 ShellExperienceHost/NetworkUX 路径；我们这台 build 26300 的快速设置在 `ControlCenter.dll`（F9），ShellHost 里并没有 `NetworkUX.dll` —— 所以**不能照抄**，但"在进程内改 XAML 对象"的范式一致。
- XAML 诊断 API 的权威定义：`xamlOM.h`（`IVisualTreeService::{CreateInstance, AddChild, RemoveChild, ClearChildren, SetProperty}`、`IXamlDiagnostics::GetIInspectableFromHandle`）。
- 现成 TAP 实现可参考：`microsoft/microsoft-ui-xaml:Samples/WinUISnoop`、`asklar/lvt`、`TranslucentTB/ExplorerTAP`、`m417z/UWPSpy`、`windhawk-mods:mods/cjk-spacer.wh.cpp`。
- 安全提醒：**CVE-2023-36003** —— XAML 诊断注入是已知的提权原语；跨完整性级别可能被 OS 拦。我们同 IL（F6），风险不在这一档。

---

## 6. 最终落地：方案 B 跑通（2026-10-03）

### 6.1 先记结论：方案 A 为什么不行

不是"hook 装不上"，而是"装上了也没人走这条路"：

1. `ControlCenter.dll!DllGetActivationFactory` 能解析出 **101/102**（共 123 个候选）`ControlCenter.*` 类名；
2. 拿到的工厂**不是单例**（每次调用返回新对象），但**共享同一份 `.rdata` vtable** → patch `vtable[6]` 是全局生效的；
3. `IActivationFactory` vtable 布局：`[0..2]` IUnknown、`[3..5]` IInspectable（`GetIids`/`GetRuntimeClassName`/`GetTrustLevel`）、`[6]` `ActivateInstance`；
4. **自测能命中**（`[detour] ActivateInstance ENTERED` 打出来了）→ patch 本身是活的；
5. 决定性实验：全新 ShellHost，**启动后 29 ms** 就注入（早于第一次面板创建），然后开面板 → **命中 0 次**。

⇒ shell 创建这些编译期 XAML 对象时**不走 `IActivationFactory::ActivateInstance`**。这条路到此为止。

### 6.2 方案 B 的实际结构（4 个产物，都在 `poc/`）

```text
injector.exe     --dll <dll> [--process ShellHost.exe | --pid N]
                 经典 CreateRemoteThread + LoadLibraryW
   └─ 注入 vcxlaunch.dll
        └─ vcxlaunch.dll   等在目标进程里 WaitForModule(Windows.UI.Xaml.dll)，
        │                  然后**在进程内**调
        │                  InitializeXamlDiagnosticsEx(L"VisualDiagConnection1", pid,
        │                      <SDK>\xamldiagnostics.dll, <poc>\vcxtap.dll, CLSID_VcxTap, nullptr)
        │                  端点名第一发就成功（N=1）
        └─ XAML core 用 DllGetClassObject(CLSID_VcxTap) 把 vcxtap.dll 载入 ShellHost
             └─ vcxtap.dll  COM in-proc server，实现 IObjectWithSite + IVisualTreeServiceCallback
                SetSite 拿到 IXamlDiagnostics* / IVisualTreeService*
                AdviseVisualTreeChange → 元素 Add/Remove 事件（**会重放已存在的树**）
                命中 Name=="Footer" 时：
                    GetIInspectableFromHandle(handle) → 真 FrameworkElement
                    → 注入 Button（Content "TestLink"，Click → CreateProcessW("winver.exe")）
```

要点：
- **TAP DLL 不需要注册表注册**，XAML core 自己 `LoadLibrary` + `DllGetClassObject`；
- `vcxtap.dll` 的 `DllGetClassObject` / `DllCanUnloadNow` 必须是 `STDAPI`（与 `combaseapi.h` 一致）并走 `/EXPORT:` 导出，用 `__declspec(dllexport)` + `extern "C" __stdcall` 会 C2375；
- 关键 IID：`IVisualTreeServiceCallback {AA7A8931-80E4-4FEC-8F3B-553F87B4966E}`、`IVisualTreeService {A593B11A-D17F-48BB-8F66-83910731C8A5}`、`IXamlDiagnostics {18C9E2B6-3F43-4116-9F2B-FF935D7770D2}`。

### 6.3 唯一的硬骨头：底栏 ItemsPanel 是**纵向** StackPanel

实测出的关键事实（`vcxtap.log` 里打出的 `up[]` 就是这条链）：

```text
Button[更多音量设置]
  → ContentPresenter
    → ContentControl            ← 这一"行"的逻辑内容
      → ContentPresenter        ← ItemsControl 为它生成的 item container
        → StackPanel[Vertical]  ← Footer 的 ItemsPanel ★ 纵向
          → ItemsPresenter
            → ItemsControl name="Footer"
              → Grid → ContentPresenter[PageContent] → Grid[FullScreenPageRoot]
                → ContentPresenter → ContentControl[PageWindow]
                  → ControlCenter.FullScreenPage[FullScreenPageControl]
                    → ContentPresenter → L2Frame → … → ControlCenterView
```

所以**往 Footer append 一项必然新起一行**（实测 footer 从 48 高变成 78，按钮掉到第二行）。
修法（`InjectIntoRow`）：找到"item container"（即 ItemsPresenter 的直接子 `StackPanel` 的、位于模型按钮祖先链上的那个孩子），
把它从 ItemsPanel 里取出，塞进一个两列 `Grid`（列 0 `*` 放原行、列 1 `Auto` 放 TestLink），再把 Grid 放回 ItemsPanel。

- 列 0 用 `*` 而不是 `Auto`：这样原行的宽度和原来完全一致，`更多音量设置` 位置不动（hover 高亮不会缩水）；
- 属性复制：`Style` / `MinWidth` / `MinHeight` / `Padding` / `CornerRadius` / `FontSize` / `FontWeight` / 内容对齐 / `Foreground`；
- **高度**：模型按钮的 `Height` 是显式 **40.0**（`MinHeight=0.0`），所以直接读 `Height()` 就能在注入当刻定死 40，**不依赖布局时机**（这点很关键，见下）；
- **右边距**：4 px，和左边距对称。

> 踩过的坑：曾试过用 `TransformToVisual` 去"测量模型按钮的内边距"再算右边距 ——
> 但注入发生在布局之前，`model.ActualWidth()` 还是 0，算出 354 px 的荒谬边距，
> 而之后**没有**再触发 `SizeChanged` 去纠正（面板树已布局完，尺寸不再变化），结果 UIA 矩形直接变成 `∞`。
> 教训：**任何依赖 `ActualWidth/ActualHeight` 的取值都必须先判 `> 0`，否则就是这次这种静默错位。**

### 6.4 最终实测几何（UIA，稳定复现两轮）

| 元素 | 屏幕矩形 | 说明 |
|---|---|---|
| `Footer` | `(2189,1417) 358x48` | 高度仍是 48 → **没有多出第二行** |
| `更多音量设置` | `(2193,1420) 94x40` | 位置与注入前完全一致 |
| `TestLink` | `(2472,1419) 71x40` | 同一行、右边缘 2543 = 距底栏右边 **4 px**、高 **40** 与模型一致 |

点击验证：UIA `InvokePattern` 调用后 `winver.exe` 启动（标题「关于"Windows"」），已确认。验证脚本 `poc/scripts/click-testlink.ps1`。

顺带修正一个误判：`FooterGrid` / `LeftFooter` / `RightFooter` **不是**这条底栏。它们挂在 `L1Grid` 下，属于 **L1（主快速设置页）的底栏**，而且一直是空的。声音输出页的底栏是页面级的 `Footer`（`PageWindow → FullScreenPage → L2Frame → PageContent → Footer`）。所以匹配条件只认 `Footer`。

### 6.5 一轮测试的代价 / 为什么 cycle 要重启 explorer

`poc/cycle.ps1` 一条命令跑完：停 shell → 构建 → 重启 explorer → 注入 → 开面板 → 打日志 + 打几何。重启的原因有两条，**都不是产品需求**：

1. **硬约束**：`vcxlaunch.dll` / `vcxtap.dll` 已被 `LoadLibraryW` 载入 `ShellHost.exe`，**进程内已加载的 DLL 文件是写锁定的**，`link` 会 LNK1104 落不了盘。改了 C++ 就必须让持有者退出。（换文件名可以绕过，但那样只会攒出一堆 `vcxmix2..7.dll` 之类的垃圾。）杀 `explorer.exe` 是为了拿到**确定全新的 `ShellHost.exe`**——它由 shell 体系托管。
2. **测试卫生**：`InitializeXamlDiagnosticsEx` 是**每进程一次**的诊断初始化，TAP 常驻且会**重放已存在的树**；同一进程反复测等于在"已被上一轮改造过的树"上继续跑，结论会失真。

⇒ **产品上不需要重启 explorer，也不需要在 logon 阶段抢时间。** 实测（`poc/test-late-inject.ps1`）：

- 全新 shell 起来后（ShellHost 已跑 ~30 s、面板已开过又关掉）才注入 → `InitializeXamlDiagnosticsEx` **仍然成功**（`SUCCESS: endpoint=VisualDiagConnection1 hr=0x00000000`），TAP 载入、advise 成功；
- 之后**不再做任何注入**，只是关掉再打开面板 → `TestLink` 出现（`(2472,1419) 71x40`）。
  ⇒ TAP 常驻，之后**每次打开面板 `Footer` 一出现就自动注入**（F3：XAML 元素每次打开都重建，进程/HWND 常驻）。

**但有一个真正的生命周期约束**：TAP 活在 **ShellHost** 里，而 ShellHost 的父进程是 **`sihost.exe`**（实测，不是 explorer）。
ShellHost 会随 shell 重启（explorer 重启 / sihost 重启 / ShellHost 自身崩溃）而换成**新进程**，TAP 随之消失、按钮也就没了。
⇒ 产品需要的是「**等 ShellHost.exe 出现 → 注入 → 监视它退出 → 再来一遍**」这个循环，而不是"重启 explorer"。
这个监视可以做到 0 CPU：§9.8 已实测 band 窗口照发 WinEvent、空闲 600 ms 0 事件；或直接用 `RegisterWaitForSingleObject` / WMI `Win32_ProcessStartTrace` 盯进程创建。

**留一个诚实的保留**：这套流程**反不掉**的只有"诊断会话"本身——`InitializeXamlDiagnosticsEx` 是每进程单例、没有 teardown API，
TAP DLL 一旦载入就跟着 ShellHost 活到进程退出。但它**不影响任何可见行为**：把注入开关关掉（或让 TAP 什么都不做）就等于不存在，
残留的只是"ShellHost 里所有 XAML 变更都会回调我们"那点开销（回调里只做一次字符串比较）。
另外"面板正开着时注入会不会即时生效"没测成：那次实验里面板在注入前后就消失了，且**无法确定**是我的注入动作导致
（`InitializeXamlDiagnosticsEx` 会同步遍历整棵 XAML 树，可能短暂卡住 ShellHost UI 线程 → 面板失焦自动关闭）还是当时有人在操作机器。
由于面板本来每次都要重新打开，这一条不影响产品设计。

### 6.6 已知限制 / 待办

- TAP 的进程级单例特性：诊断初始化后**没有干净的 teardown**，卸载/重载 TAP 这条路没走通 → 每轮迭代靠重启 ShellHost。
- 匹配条件是 `Name=="Footer"` 这个**字符串**。它在 `ControlCenter.dll` 的编译期 XAML 里，属于"改了就不工作"的软依赖（但比 RVA/特征码稳得多）。
- 目前按钮的 `Click` 是硬编码 `winver.exe`，还没有真正的"扩展入口"语义。
- **交付形态已定（2026-10-03）**：登录自动启动走 **`Run` 键**
  （`HKCU\...\CurrentVersion\Run`，用户级、免提权），详见 §7.9.2 的「开机启动 = `Run` 键」。
- ⚠️ **控制台闪现**：`vmex.exe` 是**控制台子系统**，登录自启时**会闪一个控制台窗口**。
  **已决定接受**（不改成 `WIN32` 子系统 + `AttachConsole`，原 T25 关闭）—— 详见 §7.9.2 同一节。
- Defender 排除项：**仍然只提示命令、不自动执行**（加排除要管理员，与"全装 `%LOCALAPPDATA%`、不提权"冲突）。

---

## 7. 方向修订：接管入口 + 页面内容替换（2026-10-03 定稿）

§6 跑通的是「**在系统页里加一个按钮**」。本节记录目标变更后的设计：
让「选择声音输出」**直接进入我们的页面**，系统页降级为可来回切换的备用视图。

### 7.1 目标对比

| | 原 | 现 |
|---|---|---|
| 入口 | 底栏注入的按钮 | L1 的「选择声音输出」→ **自定义页** |
| 底栏按钮语义 | 启动一个外部进程 | **系统页 ↔ 自定义页** 切换 |
| 自定义页内容 | 无 | 默认输入/输出设备下拉框、逐应用音量与端点、清除重定向 |

**范围决策（Eric 定稿）：只做我们的强项。**

自定义页**只**放「默认设备下拉框 + 逐应用音量/端点」这两块。系统页原有的能力
（空间音效、设备单选列表、音量合成器分组等）**一律不自绘** —— 要看那些就按底栏的
`SystemMixer` 切回系统页。

理由：**系统页由系统自己绘制，我们既不重画也不修改**（见 §7.4）—— 它一直活着，切回去就是。
自绘一份等于凭空维护一套会随系统更新而失效的复制品。

> 副作用要清楚：停在我们页面时，系统页那些能力**只是不可见，并未被破坏**。

### 7.2 为什么**不**走"拦导航"

L1 树实测（[06-l1-main-panel-tree.md](baseline-before-injection/06-l1-main-panel-tree.md)）发现两个事实：

```text
| | Button | 选择声音输出 | id=VolumeL2Button                  | Button    ← 目标入口
| | Button | 投影         | id=Microsoft.QuickAction.ProjectL2 | offscreen
```

1. **`L2` 后缀是"导航到二级页"的命名规律** ⇒ 进入 L2 的入口是**一组**，不是唯一一个。
   在 `L2Frame` 上挂 `Navigating` 并无条件 `Cancel`，会把「投影」等一并劫持。
   （若坚持拦截，必须按 `SourcePageType` 精确甄别目标页类型。）
2. Cancel 之后**帧停在 L1**，我们的页面无处安放，等于连页骨架（后退键 / 标题 / 底栏）都要自建。

两点叠起来 ⇒ 拦截路线代价高且风险外溢。**弃用。**

### 7.3 采用的机制：不动导航，改内容

```text
① 用户点「选择声音输出」(VolumeL2Button)      ← 保持原样，不碰
② 系统照常导航到声音页                        ← 不拦、不 Cancel
③ OnVisualTreeChange 命中声音页出现           ← 复用已验机制（同 §6 的 Footer 触发）
④ 取 ListContent，保存其 Content，换成我们的页面
⑤ 底栏按钮切换：还原保存的内容 / 再次替换
```

**误伤面为零** —— 只在声音页真正出现时动作，其他 L2 入口完全不受影响。

### 7.4 挂载点

```text
PageWindow
├ BackButton        「后退」      ← 保留（免费）
├ PageTitleText     「声音输出」  ← 保留，或按需改写
├ ListContent       ScrollViewer   ← ★ 换掉它的 Content
└ Footer            底栏           ← 保留；我们的按钮在这里，天然跨两态存续
```

选 `ListContent` 而非整页替换的理由：

- **底栏天然跨两态存续** —— 正是"切换"所需的载体，不必另造底栏；
- 后退键与标题免费保留，页面看起来仍是系统页的一部分；
- 不必与 `Frame` 的内容模型打交道，风险面小。

### 7.5 底栏布局（两态）

```text
列0 = *                 列1 = Auto
[ 原行「更多音量设置」 ][ 切换按钮 ]     ← 系统态
[ 清除重定向 ][ 原行   ][ 切换按钮 ]     ← 自定义态（左位新增）
```

**底栏三态，同一个 `Footer` —— 三个格子是被「复用」的，不是「切换可见性」**（Eric 定稿）：

```
系统页    [ — ]             ……… [ — ]      ……… [ MixerExtender ]
自定义页  [ 清除重定向 ]     ……… [ 设置 ]    ……… [ SystemMixer ]
设置页    [ GitHub ]        ……… [ 返回 ]    ……… [ （占位） ]
```

- **系统页我们只加右侧一个按钮**，其余一概不碰；
- 自定义页：左「清除重定向」、中「设置」（后续零散小设置项都收在设置页里）；
- 设置页：左 GitHub 链接、中「返回」（回自定义页）、右**先占位**；
- ⚠️ **四项都是文字，没有图标**（不是齿轮图标）—— 理由见下方 §7.5.1。

⚠️ **关键实现约束：底栏是「一个」元素，而且三个格子每页都要换文案与动作。** `Footer` 是
`PageWindow` 的子元素，**不随 `ListContent` 的内容一起被换掉**。所以：

- 我们的三个元素**只在首次注入一次**，常驻于 `Footer`；
- **每个格子只挂一个 `Click` handler，handler 进来先读"当前在哪一页"再分发**
  （左格：自定义页→清除重定向 / 设置页→打开 GitHub；中格：自定义页→进设置页 / 设置页→返回；
  右格：自定义页→切系统页 / 设置页→无动作）。<br>
  ⛔ **不能"每到一页就新挂一个 Click"** —— 事件处理器会累积，来回切两次就会触发两次。
- 换页动作要同时做两件事：换 `ListContent.Content` + **更新三个格子的文案与（系统页时的）可见性**。

> **可见性与文案是两件事，别混**：可见性只用于"系统页时左、中必须消失"
> （那几个格子是我们塞进系统那一行的，系统页不该有我们的东西）；文案/动作一律靠 dispatch。

这与 §6.3 的列结构有关：系统页只需 `列0=*`（原行）`+ 列1=Auto`（我们的按钮）；
自定义页/设置页需要额外容纳左、中两个元素，因此网格需扩列，**且弹性列必须保留 `*`**
（否则原行「更多音量设置」宽度会被挤掉、hover 高亮缩水 —— 实测过的坑）。

**右键（右格）的文案指"目标"而不是"动作"**（仅系统页 ⇄ 自定义页 这一对）：

| 当前显示的页 | 按钮文字 | 点击后去哪 |
|---|---|---|
| 自定义页 | **`SystemMixer`** | 切到系统页 |
| 系统页 | **`MixerExtender`** | 切到自定义页 |
| 设置页 | **（占位）** | — |

这样那两态都不需要用户记"进入哪里" —— 文字本身就是目的地。

**设置页那三个格子的额外约束**：

- **左格 GitHub 只放短标签**。按底栏排版实测算：`github.com/EricZhang233/VolumeMixerExtender`
  （43 字符）在 `font-size:12` 下约 **258px 文字 + 22px 内边距 = 280px**，而底栏可用宽度只有
  `358 − 8 = 350px`，减去「返回」(46) 与右侧占位后**装不下** ⇒ 用「GitHub」，
  完整地址放 `title`（悬停可见）。
- **左格的颜色仍是中性灰**（已定，不破例），没有用 Windows 惯用的强调蓝超链接色 ——
  因为底栏各项是"复制系统按钮的 `Foreground`"得来的，单独加蓝就破了统一。
  **它看起来不像链接是刻意的**：底栏三格是"三种动作"，不是"三个链接"。
- ✅ **打开 GitHub 用 `action=open`（已定，2026-10-03）**。不复用 `exec`：
  两者调的是**不同的 API**，职责不同 ——
  `exec` 走 `CreateProcessW(exe, args)`：**只认 exe**，且必须显式给 `lpApplicationName`
  （否则前缀试探，见 §4.3 坑 27）；
  `open` 走 `ShellExecuteW(nullptr, L"open", url, nullptr, nullptr, SW_SHOWNORMAL)`：
  **走 shell 的关联解析**，这才是"用默认浏览器打开这个 URL"的官方途径。
  URL 不是 exe，用 `CreateProcessW` 打开 URL **不是被文档保证的行为**（不要把"某些机器上恰好能开"
  当成契约）。⇒ 两者在配置里是两个独立的 `action` 值，不是"同一个 action 的两种参数"。

#### 7.5.1 底栏项的样式：文字链接，不是按钮（像素实测）

证据来源：`verified-after-injection/02-footer-screenshot.png`（屏幕 `(2150,1390) 440x110` 的 2 倍放大），
逐像素取样。坐标映射以 UIA 的模型按钮文字 `(2204,1435) 72x9` 为基准校准 ——
取样得到的墨迹范围 `x 2203.5..2275.0` 与它逐像素吻合，证明映射正确。

| 观测项 | 实测值 | 结论 |
|---|---|---|
| 模型按钮框 `2193,1420 94x40` 内部 | 除字形外**全是纯背景** `#e8d4e8`（上边框带/左边框带/框内空白取样一致） | **无边框、无填充** ⇒ 是文字链接，不是按钮 |
| 文字墨迹核心 | `#5a535b`（最暗 `#575057`） | = 背景 `#e8d4e8` 叠 **60.6% 黑** ⇒ 等效 `TextFillColorSecondary` |
| 文字通道差 | R−B = 0，最大通道差 7 | **中性灰，不是强调蓝** —— 不是"超链接蓝"，只是普通次级前景色 |
| 墨迹范围 | `x 2203.5..2275.0`（宽 71.5）；`y 1432.5..1444.0`（高 11.5） | 与 UIA 的 `72x9` 一致，取样可信 |
| 文字宽度 | 「更多音量设置」= 6 个汉字 = 72px | **1 字 = 12px ⇒ `FontSize = 12`**（CJK 字宽 = 1em） |
| 水平内边距 | `94 − 72 = 22`，两侧各 11 | `Padding = 0 11px` |
| 底栏内缩 | 底栏 `x=2189`、模型按钮 `x=2193` | `4px` |
| 我们的按钮 `TestLink` | 文字核心 `#575057`、墨迹 `x 2483..2531`、墨高 `9.5` | **与模型逐像素同级** ⇒ "复制 `Style` + `Foreground`"确实做到了视觉一致 |

**落法**：底栏四项**共用同一套样式**，不给自己人加颜色或边框。
这正是 PoC 已有的做法（复制模型按钮的 `Style` 与 `Foreground`），
也是唯一能保证"外面看不出哪个是系统的、哪个是我们的"的做法。

> ⚠️ **未验证**：悬停 / 按下时的填充。`94x40` 这个框只在悬停时可见，
> 推测是 WinUI 的 subtle 填充（`SubtleFillColorSecondary`），
> 但截图时鼠标不在按钮上、**没有采到**。列为待验项。

### 7.6 动作类型要扩展

现有 `action=exec` / `action=pipe` 都面向"拉起外部进程"。页面切换是 **in-proc 行为**，
需新增一种动作（如 `action=page`），否则配置语义错位。

### 7.7 ⚠️ 最大成本：界面只能逐元素搭

**没有 XAML 标记编译** —— 那需要 UWP 工程体系（`xamlcompiler` + 应用包结构），
在注入用的普通 DLL 里不成立。所以界面只能用 `CreateInstance` 逐元素构建：

| 界面元素 | 代价 |
|---|---|
| 两个下拉框 | 每个 `ComboBox` + N 个 `ComboBoxItem` 手工创建 |
| 应用列表 | N 项 ×（图标 + 名称 + `Slider` + 静音键）全部手工 |
| 事件 | 每个 `Slider` 单独挂 `ValueChanged` |

参照 §6 中单个 `Button`（含样式抄写）约 60 行，一个带应用列表的页面保守估计
**1500–2500 行 C++**。这是本方案最大的成本项，排期时不可按"写个 XAML"估。

### 7.8 前置验证结论（2026-10-03 已全部完成）

| # | 项 | 结论 |
|---|---|---|
| T12 | `ListContent.Content` 可写 + 可还原 | ✅ 两者都成功 |
| T13 | `Footer` 触发时结构是否就绪 | ✅ 已就绪，无需额外调度 |
| T14 | `ComboBox` / `ListView` / `Slider` 可创建 | ✅ 10 个控件类型全部可激活 |

一次探针拿到全部结论，方法见 `verified-after-injection/10-page-swap-capability.md`。
**顺带纠正**：元素构建用的是 C++/WinRT 直接激活，不是 `IVisualTreeService::CreateInstance`。

仍未验证（不阻塞开工）：

- [ ] 系统页被换下后，其对象是否仍在后台活动（音频计量轮询等）—— 且要观察它**会不会自己重设 `Content`** 把我们的页面顶掉
- [ ] 自定义页根元素在 `ScrollViewer` 内的尺寸策略（`Height` 自适应 vs 固定）

---

### 7.9 布局定稿（2026-10-03）

**尺寸（全部来自实测）**：页面 `358 × 396`；标题行 40；底栏 48；**内容区可用 ≈ 308**。

```text
┌─ 358 ────────────────────────────────┐
│ [←]  声音输出                         │ 40   系统保留，不改
├──────────────────────────────────────┤
│ 默认输出设备                  ☐ 录制模式│ 16   标签行 + 右对齐复选框
│ [ 扬声器 (Realtek(R) Audio)       ▾ ] │ 34   ComboBox
│ 默认输入设备                          │
│ [ 麦克风阵列 (Intel® Smart Sound)  ▾ ]│ 34   ComboBox
│ 端点音量                              │
│ [🔊] 扬声器 (Realtek(R) Audio) [🔇] ▬▬│ 44   每个端点各一条（不是按通道）
│ [🔊] 耳机 (2- USB Audio)       [🔇] ▬ │ 44   ← 渲染端点逐条展开
│ [🔊] 显示器音频 (NVIDIA HD…)   [🔇] ▬ │ 44
│ [🎤] 输入设备（2）                 ▸  │ 44   ← 采集端点收成一个折叠组，默认收起
│    └(展开后) [🎤] 麦克风阵列   [🔇] ▬ │ 44   子行缩进 28px
│ 音量合成器                            │
│ [icon] 系统声音            [🔇] ▬▬▬▬  │ 44   应用行（单行）
│ [icon] Google Chrome       [🔇] ▬▬    │ 44   已重定向（名称下补端点，仍塞在 44 内）
│   └→ 耳机 (2- USB Audio)              │
│ [icon] Microsoft Teams (工作或…)      │ 47.3 名称过长，最多折两行
│   └→ 扬声器 (Realtek(R) Audio)        │
│ …（与上方共用一个滚动区）              │
├──────────────────────────────────────┤
│ [清除重定向]      [设置]      [SystemMixer]│ 48   底栏（纯文字，无框无底）
└──────────────────────────────────────┘
```

**定稿项**：

| 项 | 决定 |
|---|---|
| 下拉框标签 | 「**默认输出设备**」/「**默认输入设备**」—— 标签本身说明改的是系统默认设备，不加额外标记 |
| 应用列表分组 | **不分组**，平铺一条列表 |
| 滚动 | **共用一个滚动区**（下拉框会随内容滚走） |
| 应用行**宽度** | 恒定 330px（内容区 332 − 行内边距 10 + 圆角取整）。已重定向的行**不加宽** |
| 应用行**高度** | 从 44 起，**按需长高**；只长不宽。三种取值：<br>① 44 —— 名称一行（含"名称一行 + 端点一行"，两行合计 ≈ 37px，仍在 44 内）<br>② 47.3 —— 名称折两行 + 端点一行<br>③ 52 —— 理论上限（两行名称 ≈ 33 + 端点 ≈ 14 + 行内边距） |
| 名称过长 | **最多折两行**（`-webkit-line-clamp:2`），不截断成一行省略号 —— 侧栏只有 330px，全截断会让同一个前缀下的多个应用无法区分 |
| 端点行 | **单行 + 省略号**，全名放 `title`（悬停可见）。这样"名称两行 + 端点"不会比"名称两行"高出一个变量，行高上限可算 |
| 端点选择入口 | 藏在"点整行"里，不占常驻空间 |
| 「默认输出设备」行右上角 | 一个**右对齐的「录制模式」复选框**（16px 方框）。语义见 §7.9.1 |

**行的实现约束**：行高用 `min-height: 44` 而不是 `height: 44`，**不要同时写死高度**——
否则名称折两行时会被裁掉。XAML 侧对应 `MinHeight="44"` + `Height="Auto"`，
`ListContent` 是 `ScrollViewer`，行变高只影响滚动量、不影响宽度。

**接受的代价**：内容区 308px 装不下"两个下拉框 + 4 个应用行"
（实测 4 行时需 347.7px，超出 41.7px），**打开时列表底部会被裁切、需要滚动**。
这是共用滚动区方案的必然结果，已确认接受。

线框稿见仓库根目录的 `layout-preview.html`（临时文件，定稿后可移入 `docs/` 或删除）。
**该图只画自定义页** —— 系统页我们既不绘制也不设计，对它的全部改动就是底栏右侧多一个按钮（见 §7.5）。

#### 7.9.1 「录制模式」复选框（对接虚拟音频方案）

这是 `VirtualAudio-Record-Mirror-Plan.md` 在 UI 上的落点。
位置：**「默认输出设备」标签行的右端，右对齐**（与标签同一行，不占额外高度）。

| | 系统默认输出设备 | 这一行下拉框选的是 | 这一行的标题 |
|---|---|---|---|
| ☐ 未勾选 | = 下拉框选的那台 | **系统默认输出设备**（枚举 render 端点，**排除 V**） | 「默认输出设备」 |
| ☑ 录制模式 | **V = `OC Virtual Speaker`**（音量硬锁 100%，方案 §4/§5） | **监听设备 R**（枚举 render 端点，**排除 V**） | 「**监听输出设备**」 |

**切换是自动的、双向对称的**（Eric 定稿）：

```
勾选：  记住当前默认 D → 系统默认切到 V → R := D      标题 →「监听输出设备」
取消：  系统默认切回 R（= 记住的 D）                   标题 →「默认输出设备」
```

⇒ R **不是用户另外选的**，它就是从"切之前那台默认设备"来的。
两边完全对称、无中间态。（⚠️ 由此**推翻**了方案 §0/§8 的「自动化：无」—— 方案文档已同步修订。）

**录制模式不持久化**（Eric 定稿）：**勾选状态**不跨系统重启保存，每次启动一律从"未勾选"开始。

**残留问题由驱动侧的「常开开关」结构性解决**（Eric 定稿，驱动侧见方案 §4.3）：

> V 的**插头状态就是一个常开开关**：驱动加载后默认「**未插入**」，
> **只有我们的程序显式闭合**（录制模式打开时通过 IOCTL）才变「已插入」。
> 模式关闭、程序退出/崩溃/被杀 → 回到「未插入」——
> 由驱动在 `IRP_MJ_CLEANUP` 上兜底，**不依赖程序有机会做清理**。

| 时刻 | V 的插头 | 端点状态 | 系统里的表现 |
|---|---|---|---|
| 驱动刚加载 / 程序没跑 | **未插入**（常开） | `DEVICE_STATE_UNPLUGGED` | 列表里根本没有，谁也选不了 |
| 录制模式**开** | **已插入**（我们闭合） | `DEVICE_STATE_ACTIVE` | 可见、可当默认；我们**立刻**把它设为默认 |
| 录制模式**关** / 程序消失 | **未插入** | `DEVICE_STATE_UNPLUGGED` | 消失；Windows 自动把默认滚回真实设备 |

⇒ **不需要 `pendingRestore` / `previousDefaultId` 落盘，也不需要"启动时对账"** —— 残留结构上不可能存在。
⇒ **D 也只需活在内存里**（用于"取消勾选时立刻切回"，不必等 Windows 自己滚），这正合"录制模式不持久化"。

⚠️ **仍待验证**（**验收 7–11**，见方案 §11 —— ⚠️ 注意那是**方案的验收编号**，与本文档的 T 编号无关）：
端点状态能否**免重启**翻转、滚回目标是不是 D、
V 重现时 Windows 会不会**抢默认**、未插入端点是否真的从 Win11 列表消失。
**驱动层排在最后做、且在实体机验**（本开发机没有真实音频硬件）—— 见 `todo.md` 的「驱动层」一节。

**硬约束：V 永不显示。** V 不出现在本页任何列表或标签里，只能由这个复选框间接控制。
⇒ 枚举 render 端点时必须**过滤掉自己的虚拟端点**。否则用户能把它直接选成默认设备，
绕过录制模式、让录制链在"没有监听目标"的情况下空转。

**为什么标题要跟着变**：勾选后这一行选的东西换了含义，标题不动就名实不符；
而且**只勾复选框时下拉框文字常常一个字都不变**（R 往往就是原来那台扬声器），
那样"录制模式已开"在界面上就没有任何可见指示 —— 复选框本身成了唯一的状态指示。
标题用「监听输出设备」是为了与方案里"监听设备 R"的叫法一致。

**实现注意**：
- WinUI `CheckBox` 默认 `MinHeight = 32`、方框 `20px`，会把 16px 高的标签行撑到 32
  ⇒ 必须用紧凑模板（`MinHeight = 0` + `16px` 方框）。线框稿用的就是 16px，实测行高**保持 16 不变**。
- ✅ **`CheckBox` 类型可用（T18 已验，2026-10-03）**。`verified-after-injection/11-checkbox-capability.md`：
  可激活、`IsChecked` 可往返、`MinHeight(0)` 可设、可挂进可视树。上面那条紧凑模板约束所需的
  `MinHeight(0)` 也一并验证可用。顺带闭合了 `ToggleButton` 的命名空间问题
  （当初报 C2039 是因为缺 `Controls.Primitives` 别名；加上 `WUXCP` 后编译通过且可激活）。

#### 7.9.2 设置页（子页面 · 2026-10-03 新增）

> 🅿️ **挂起（2026-10-03）**：先做「端点音量」那一层（§7.9.3）。本节布局已画好，但**实现顺位后移**。

从自定义页底栏中位的「设置」进入。**这是"零散小设置项"的收容所** —— 产品里设置项不多，
所以除了「常规」下面那几行，其余地方留空，不造占位条目。

```text
┌─ 358 ────────────────────────────────┐
│ [←]  设置                             │ 40   系统保留，不改
├──────────────────────────────────────┤
│ 常规                                  │
│  开机启动                     ●——    │ 44   ToggleSwitch
│                                       │
│  ┌─────────────────────────────────┐  │
│  │     从系统卸载（连击 5 次）       │  │ 40   危险操作，置底
│  └─────────────────────────────────┘  │
├──────────────────────────────────────┤
│ [GitHub]       [返回]       （占位）  │ 48   底栏（三格复用，见 §7.5）
└──────────────────────────────────────┘
```

**定稿项**：

| 项 | 决定 |
|---|---|
| 标题 | 「设置」—— 标题行是系统的，除了文字以外我们什么都不改 |
| 入口 | 自定义页底栏中位的「设置」 |
| 返回 | 设置页底栏 **中位的「返回」** |
| 「开机启动」 | `ToggleSwitch`（switch，不是 `CheckBox`） |
| 「显示驱动名」 | `ToggleSwitch`，**默认开**。控制设备名要不要带括号里的驱动名后缀（`扬声器 (Realtek(R) Audio)` ↔ `扬声器`）。**作用面是三处**：两个下拉框的值 / 端点音量每一行 / 应用行里的"重定向目标端点"。三者都取自 `PKEY_Device_FriendlyName`，必须同步改 |
| 「从系统卸载」 | **置底** + 危险色；靠一个 `flex:1` 的空白块推到内容区底部。它**不属于底栏**，仍在内容区里（会随内容滚）。**不删程序文件、不卸驱动** —— 见下方"卸载到底做了什么" |
| 「从系统卸载」的确认 | **连击 5 次**，不用 `ContentDialog`。单击 → 文案转 `再单击{N}次从系统卸载`（N = 还差几次，首次为 **4**）；**相邻两次间隔须 ≤ 0.5s**，超时**立刻复位**回 `从系统卸载`；第 5 次单击即执行。详见下方说明 |
| 底栏左格 `GitHub` | 动作类型用 **`action=open`**（`ShellExecuteW`），不是 `exec` —— 见 §7.5 末尾 |
| 底栏三格 | 左 `GitHub` / 中 `返回` / 右 **占位** |

**「从系统卸载」的连击确认（已定稿）**：

```
状态机：hits = 0，文案 = 「从系统卸载」
  单击 → hits++
         hits < 5  → 文案 = 「再单击(5−hits)次从系统卸载」；重置 500ms 定时器
                      （第 1 次单击后 = 「再单击4次从系统卸载」）
         hits == 5 → 执行卸载
  500ms 内没有下一次单击 → hits = 0，文案复位
```

- **只计数，不做任何"半执行"** —— 第 1..4 次单击除改文案外**不产生任何副作用**，
  所以复位是纯内存操作，不需要回滚。
- **超时按"距上一次单击"算，不是总时长**：每次都重置同一个 `500ms` 定时器
  （即要求"两两相邻 ≤ 0.5s"，而不是"5 次总共 ≤ 0.5s"）。
- **用 `DispatcherTimer`，不要用 `Task.Delay`/线程池** —— 回调要改 UI 文案，必须回到 UI 线程；
  `DispatcherTimer` 天生在 UI 线程，省掉一次 `Dispatcher.RunAsync`。原语已在 T18 附近的
  XAML 里验证可用范围之内（同属 `Windows.UI.Xaml` 基础类型）。
- **为什么不用 `ContentDialog`**：① 浮层会盖住整个面板内容；② 多一个未验前置
  （`ContentDialog` 的 `XamlRoot` 必须设对，否则抛异常）；③ 收益只是"多一次确认"，
  而连击已经满足"防误触"的全部意图（误触一次不会卸载）。
- ⚠️ **计数状态是纯 UI 态**：`hits` 只活在当前面板这一次打开期间，面板关闭即丢失 —— 这是**期望行为**
  （关闭面板再打开应回到「从系统卸载」），不需要持久化。

**「从系统卸载」到底做了什么（已定稿）**

⭐ **语义 = "从系统里退出接管、回落原生行为"，不是"删掉这个软件"。**
**不删程序文件、不卸虚拟音频驱动、不删配置** —— 只做两件事：**删除开机自启项** + **重启 shell**。

| 步 | 动作 | 由谁执行 | 为什么必须在这一步 |
|---|---|---|---|
| 1 | 写 `enabled=0`（`vmext-tap.ini`） | **App** | 先把"重新注入"这条路断掉。TAP 是**每次命中 `Footer` 时重读 ini** 的 ⇒ 立刻生效 |
| 2 | 停 Watcher 线程 | **App** | ⛔ **顺序关键**：若不停，第 4 步杀掉 ShellHost 后，Watcher 会立刻在新 ShellHost 上**重新注入** ⇒ 前功尽弃 |
| 3 | 删**开机自启项**（`AutostartEntry::Disable()`：`Run` 值 + 系统禁用标记） | **App** | 「开机启动」就是这个自启项（见下方"开机启动 = `Run` 键"）。**整条删掉**，⛔ 不要只留个"已禁用"的残留 |
| 4 | 重启 shell（`explorer.exe`） | **App** | ShellHost 换新进程 ⇒ 旧 TAP 连同它的注入一起消失 ⇒ **原生 UI 回来**。这是唯一不需要"卸载 DLL"就能送走 TAP 的办法 |
| 5 | App 自己退出 | **App** | 此后系统上没有任何我们的进程在跑 |

⛔ **这五步必须全由 App 执行，不能由 TAP 执行。** 原因有两条，都致命：
1. **TAP 活在 ShellHost 里** —— 第 4 步重启 shell = **TAP 当场自杀**（在 `Click` 回调栈上）。不是"不行"，是"顺序没法保证"。
2. **只有 App 能在杀 ShellHost 之前先把 Watcher 停掉**（第 2 步）。TAP 自己去杀 shell，App 的 Watcher 会马上把 TAP 重新送回来。

⇒ **卸载动作走 `action=pipe`**（点击 → 报文 → App 执行）。
若 pipe 不可用（App 已崩 / 未运行）：**按钮拒绝执行**，只把文案改成失败提示 + 记日志。
⛔ **绝不降级成"TAP 自己重启 shell"** —— 那会变成半卸载（见上面第 1 条原因）。

**为什么"不删驱动"是安全的**：虚拟设备 V 的插头是**常开开关**（方案 §4.3）——
驱动上电默认「未插入」，只有我们显式闭合才「已插入」。App 退出后没人闭合它
⇒ **V 结构性不可用**，系统回落原生行为。所以卸载**不需要动驱动**，也**不需要重启系统**。

**✅ 不用管驱动（2026-10-03 定）**：**没有端点时 Windows 不会显示它** —— 宿主退出后没人闭合插头
⇒ V 是 `UNPLUGGED` ⇒ 系统自己的声音设置里也不会出现。
⇒ **卸载不需要动驱动**，也不会留下"看得见的残留"。~~原待验：驱动留着时系统设置里还会不会列出 V~~

**重新接管**：程序文件还在 ⇒ 用户**手动运行一次 exe** 即可恢复。
⇒ App 启动时必须写 `enabled=1`（覆盖卸载时留下的 `0`），否则会出现"程序在跑但不注入"的诡异状态。

**「开机启动」= `Run` 键（已定稿 · 2026-10-03；同日从"计划任务"改过来）**

⭐ 就一个值：`HKCU\Software\Microsoft\Windows\CurrentVersion\Run` 下
`VolumeMixerExtender` = `"<InstallRoot>\vmex.exe" --tray`。

| 项 | 值 | 理由 |
|---|---|---|
| 位置 / 值名 | `HKCU\...\CurrentVersion\Run` · `VolumeMixerExtender` | 用户级、免提权、免 UAC，与"全装 `%LOCALAPPDATA%`、不提权"一致 |
| 触发时机 | **登录时**（`Run` 键由 explorer 在用户登录后拉起） | ⛔ 不能是"开机时" —— 要注入的 `ShellHost.exe` 是**每会话**进程，开机时还没有用户会话 |
| 运行身份 | **当前用户 · 未提权**（继承 explorer 的令牌） | 注入契约的前提是**同完整性级别**（Medium → Medium）；`Run` 键天然不会提权 |
| 命令行 | `"<InstallRoot>\vmex.exe" --tray` | ⚠️ 路径**必须带引号**：`Run` 值是一整条命令行字符串，不像计划任务那样 `Path`/`Arguments` 分字段 |
| 多会话 | 每个用户会话各自拉起 | 多会话（多用户/多桌面）各自一个实例；同会话内的重复由 **App 自己的 per-session 单实例互斥**兜住 |

**为什么从计划任务改成 `Run` 键（2026-10-03）**

① 计划任务要用 `ITaskService` COM（`taskschd.dll`）注册一份十来项的 `ITaskDefinition`，还得逐项绕开
**`ExecutionTimeLimit` 默认 72 小时强杀**、**`DisallowStartIfOnBatteries` 默认 `true`（电池供电不启动）**、
**`StopIfGoingOnBatteries` 默认 `true`（一拔电就被杀）** 这些坑；`Run` 键**一个值就是全部语义**，无默认值陷阱。
② 计划任务要小心"运行身份"（当前用户 SID + `INTERACTIVE_TOKEN` + `TASK_RUNLEVEL_LUA`，
⛔ 绝不能 `HIGHEST`，否则拉起的 `vmex.exe` 与未提权的 ShellHost 不同完整性级别、注入契约当场失效）；
`Run` 键由 explorer 拉起，**天然是当前用户的未提权令牌**，不存在写错的可能。
③ 用户可见性更标准：在「设置 → 应用 → 启动」和「任务管理器 → 启动」里都能看见、能自己禁用。

**开关语义（`ToggleSwitch`）**：

```
初值    = Run 值存在 && 未被系统标记为禁用     ← ⛔ 不是"我记得我建过"，按"结果存在性"判定
打开    = 写 Run 值 + 清掉系统禁用标记
关闭    = 删 Run 值 + 删系统禁用标记           ← ⛔ 不留"已禁用"的残留项
```

⛔ **"被系统标记为禁用"这一项必须读**：用户在「任务管理器 → 启动」里关掉它时，Windows **不删**我们的
`Run` 值，而是往 `HKCU\...\Explorer\StartupApproved\Run` 写一个同名的 `REG_BINARY`（首字节低位 = 禁用）。
**只读 `Run` 值就会撒谎**（画"开"，实际登录不启动）—— 这正是本页所有开关共同的那条规矩：**画事实，不画记录**。
⇒ 关闭时也要**一并删掉这个标记**，否则下次打开会立刻又被判成"被禁用"。

⛔ **开关状态不存任何副本**（2026-10-03 定）：自启开关不是配置，它就是"自启项到底在不在"这个**事实**，
写进 ini 或我们自己的 `HKCU` 键只会多出一个必然和真实状态打架的第二来源 —— 用户手动删掉/禁用之后，
开关必须立刻显示"关"，所以每一页都**现查**（`AutostartEntry::IsEnabled()`）。

**实现落点（2026-10-03）**：`Core/AutostartEntry.*`（`IsEnabled` / `Enable` / `Disable`）。
宿主和 payload 都链接 `vmex_core` ⇒ 只有一份实现，**CLI（`vmex_cli autostart [on|off]`）与设置页开关共用它**。
**读侧必须就地**：`pipe` 单向，payload 问不了宿主"现在开着吗"，而"开着/关着"恰好就是开关要画的东西。

⚠️ 值里的路径指向 `<InstallRoot>\vmex.exe`（`platform::GetInstallDirectory()`，与宿主自己算配置/日志
路径用的是同一个来源）。该文件不存在时**拒绝注册**：否则会留下一个每次登录都失败、还赖在
「启动」列表里的自启项 —— 比"没注册"脏得多。

**⚠️ 控制台闪现（2026-10-03：接受，不改造）**

`vmex.exe` 是**控制台子系统**（`wmain`），在没有可继承的父控制台时（登录自启、双击）Windows 会**给它
分配一个新控制台窗口** ⇒ 每次登录闪一下黑窗。⚠️ 换 `Run` 键**免不掉**这一下：闪不闪由**镜像声明的
子系统**决定，与"谁拉起它"无关（从命令行跑不闪，只是因为继承了 cmd 的控制台）。

⇒ **决定：接受这一下闪烁**，不做 `WIN32` 子系统 + `AttachConsole` 改造（原 **T25 关闭**）。
理由：改造要动 `Program.cpp` 入口与 `CliService` 的输出分支，收益只有"登录时少闪一下"。
ℹ️ 真要去掉，唯一正道仍那条改造（`WIN32` 子系统 + `wWinMain` 开头 `AttachConsole(ATTACH_PARENT_PROCESS)`：
命令行跑 → 附着父控制台、CLI 照常；无父控制台 → 只写文件日志，零闪现）。

**待定 / 待验**：

| # | 项 | 说明 |
|---|---|---|
| 1 | ✅ ~~**标题行那个系统后退键**~~ | **已定（2026-10-03）：保持系统默认行为，不拦。**<br>⇒ 设置页有两个返回键且行为不同（标题行 = 退回 L1；底栏「返回」= 回自定义页）。**这是接受的取舍**，⛔ 不要再为此挂 `L2Frame.Navigating`（原 T20 一并关闭） |
| 2 | ⚠️ **`ToggleSwitch` 是新类型** | **不在已验集合里**（T14 的 10 个 + T18 的 `CheckBox` 都不含它）。同在 `Windows.UI.Xaml.Controls` 下，预计可用 —— 按惯例补一次探针 |
| 3 | ✅ ~~**「从系统卸载」要不要二次确认**~~ | **已定：连击 5 次**（不用 `ContentDialog`）。见上方状态机 |
| 4 | ✅ ~~**卸载的边界要写清**~~ | **已定（2026-10-03）**：不删程序文件、不卸驱动、不删配置；**只删开机自启项 + 重启 shell** ⇒ 回落系统原生行为。详见上方"卸载到底做了什么" |
| 5 | ✅ ~~**左格 GitHub 的动作类型**~~ | **已定：`action=open`**（`ShellExecuteW`）。见 §7.5 末尾 |
| 6 | ✅ ~~**左格用不用强调色**~~ | **已定：保持中性灰**，不破例。理由见 §7.5 末尾 |
| 7 | ⚠️ **「显示驱动名」只能按"元素是不是设备名"判定** | ⛔ **绝不能按"文本以 `(` 结尾"判定** —— 应用名里也有括号（`Microsoft Teams (工作或学校)`），线框稿第一版就把它削成了 `Microsoft Teams`，等于变成了另一个应用。XAML 侧每个 `TextBlock` 都是我们自己建的，所以"知道它是设备名"这件事天然成立；但**取值必须取对 Key**：设备名走 `PKEY_Device_FriendlyName`（或 `DeviceDesc` + `InterfaceFriendlyName` 自己拼），应用名走会话/进程信息 |
| 8 | ℹ️ **「显示驱动名」不省高度** | 实测开关前后内容高度 **603px → 603px 不变**（行高由 `min-height:44` 钉死）。它省的是折行/截断（`显示器音频 (NVIDIA High Definition Audio)` 折两行 → `显示器音频` 一行）。⇒ **这是可读性设置，不是省空间设置**，别指望它缓解 §7.9.3 的溢出 |

#### 7.9.3 端点音量（每个设备一条 · 2026-10-03 补）

三层结构里的**中间那层**：**选默认设备**（两个下拉框）→ **每个设备各一条音量** → **逐应用音量**（合成器）。
位置：插在「默认输入设备」与「音量合成器」**之间**。

**定稿项**：

| 项 | 决定 |
|---|---|
| 粒度 | **每个端点一条** —— **不是"输出/输入各一条"**。每台设备可单独调音量 + 静音 |
| 枚举范围 | `EnumAudioEndpoints(DEVICE_STATE_ACTIVE)` —— 「已禁用」「未插入」的一律不列（Windows 自己的列表也只列 ACTIVE） |
| ⭐ **过滤 V** | 与两个下拉框同一条硬约束：**虚拟设备 V 不出现**。它的音量本来就硬锁 100%（方案 §5.2），列出来只会是个拖不动的死滑块 |
| 顺序 | 渲染端点在前、采集端点在后；**不加分组标签**（"不是按通道"这条也守住了） |
| ⭐ **采集侧收成一个折叠组** | 渲染端点**逐条展开**；采集端点收成**一行「输入设备（N）」+ 展开箭头**，**默认不展开**，子行缩进 28px。⇒ **输入侧不再随设备数增长** —— 这是本层唯一的高度封顶手段 |
| 行结构 | 与 app 行完全一致：图标 + 名称 + 静音 + 音量条，`44px`；名称过长同样走"最多折两行"（§7.9） |
| 图标 | 喇叭 = 渲染端点，麦克风 = 采集端点 |

**✅ 安全 / 危险 API 的分界（2026-10-03 定，证据 `verified-after-injection/12-audio-interop-safety.md`）**

| 操作 | 在哪执行 | 为什么 |
|---|---|---|
| 枚举设备、读端点音量/静音、**读写**逐应用音量/静音 | **TAP 内联**（ShellHost 里） | 全走 SDK 文档化接口，实测无风险 |
| **切系统默认设备**、**逐应用重定向**、**清空重定向** | **走 `action=pipe` → 宿主** | 未公开接口，**在 ShellHost 里试错 = 崩掉用户的 shell**（2026-10-04 更正：当初的 `vtable[13]` AV 是探针槽位偏移所致；槽 13 就是 `SetDefaultEndpoint`，见 `verified-after-injection/15-host-pipe-and-device-policy.md` §3） |
| **开机自启**（查/注册/删除自启项） | **TAP → `Core/AutostartEntry` 就地** | ① 写的是 `HKCU` 的 `Run` 值，纯注册表操作，无未公开接口风险；② 开关**初值 = `Run` 值存在 && 未被系统禁用**（§7.9.2），而 `pipe` 是**单向**的 —— 就地查才拿得到"现在开着吗" |
| 从系统卸载 | **走 `action=pipe` → 宿主** | 生命周期原因：要**重启 shell**，而 TAP 就活在那个 shell 里 |

⚠️ 代价：`pipe` **单向**，切换结果拿不到确认 ⇒ UI **乐观更新**，下次打开面板重新枚举即对齐。
（开机自启不受这条限制：它每次都现查任务，所以**不是**乐观更新，而是"结果存在性"。）
⚠️ 本次探测在 **RDP + 虚拟端点**下做（唯一渲染端点是 `远程音频`、采集端点 **0** 个），
所以"AV 是 build 变了还是 RDP 造成的"**未定论** —— EarTrumpet 在真实硬件上同路径工作正常。

**⛔ 必须先避开的 EarTrumpet 已确认 bug（2026-10-03 查证）**

需求里那条"修复部分情况下可能丢失所有应用列表导致每个音频端点下方为空白"，
对应 EarTrumpet 的 master issue **File-New-Project/EarTrumpet#1305**
《Missing sessions when **audio device, session enumerator, etc. are invalidated**》
（#1487 / #814 / #846 / #483 … 二十多个 issue 都挂在它下面）。

**根因（从 #1305 里的用户调试日志读出）**：
EarTrumpet 在**设备构造时一次性**建好 `IAudioSessionManager2` + 会话枚举器，并把列表长期持有。
当**会话/设备/枚举器被 invalidated**（切换 Windows 用户、音频服务重启、声卡厂商软件重配驱动…），
Windows 会给**每个会话**发 `OnSessionDisconnected`：

```text
（切换 Windows 用户）
AudioDeviceSession DisconnectSession  firefox / steam / *SystemSounds …
UI  AudioDeviceSessionCollection RemoveSession  firefox / steam / *SystemSounds …
===> Speakers (…) Removed existing session from Apps:      ← 列表被清空
```

它**逐个 `RemoveSession` 清空列表**，而"加回来"只靠 `OnSessionCreated` ——
那个通知挂在**已经失效的** session manager 上 ⇒ **永远不再有新增**
⇒ 该端点下方**永久空白，只能重启程序**（维护者的原话：需要实现微软文档里那套"turn everything off/on again"）。

**我们的结构性修复（四条，缺一条就会复现）**：

| # | 规则 | 为什么 |
|---|---|---|
| **B1** | **绝不跨时间缓存** `IMMDevice` / `IAudioSessionManager2` / 会话枚举器 —— 每次要用都从 `IMMDeviceEnumerator` **重新取**、重新 `Activate` | 失效后旧引用永远救不回来，这正是 EarTrumpet 的病根 |
| **B2** | **以"重新枚举的结果"为准，不以"通知"为准** —— 收到 disconnected 不清空列表，而是**重新枚举一遍**；枚举返回 0 也**不当终局**，退避重试若干次 | 通知会漏、会乱序；枚举才是当前事实 |
| **B3** | **`AUDCLNT_E_DEVICE_INVALIDATED`（`0x88890004`）必须触发一次完整重取**：释放 → `GetDevice` → `Activate` → 重试 | 微软《Recovering from an Invalid-Device Error》规定的流程 |
| **B4** | **每次打开面板重新枚举会话** —— 我们的页面每次打开都重建，**天然自愈** | EarTrumpet 的列表是 app 生命周期级的，一次坏就坏到底；我们没有这个问题，**别把它丢掉** |

⚠️ **一处例外要注意**：滑块的 `ValueChanged` 里为了性能会**长期持有 `ISimpleAudioVolume`**
（= B1 的例外）。所以写入**失败时**必须按 B3 重新定位该会话再重试一次，
⛔ 不能一直往一个已失效的指针上写。

**录制模式下仍然可用，而且正好补上方案的缺口**：能调的是**监听设备 R** 的音量 ——
方案 §5.4 原本说"录制时请到系统里调 R 的滑块"，现在这个入口就在我们页面上。
（V 不在列表里 ⇒ 不存在"误调 V"的问题。）

**⚠️ 实测代价 —— 这一层把页面推过了一屏**：

| 量 | 值 |
|---|---|
| 内容区可用 | **306px** |
| 收起态（默认）内容需要 | **603px** ⇒ 超出 **297px（约 6.75 行）** |
| 展开输入设备后 | **691px** ⇒ 超出 **385px** |

⚠️ **折叠组只封顶了输入侧，渲染侧仍然不封顶** —— 线框稿只画了 3 台渲染端点；
真实机器上"扬声器 + 耳机 + HDMI + USB"到 5~6 台很常见，还要再加 2~3 行（88~132px）。
共用滚动区意味着打开时基本只看得到「两个下拉框 + 端点音量」，**应用列表要滚很远**。

**✅ 溢出已定：接受现状，不压缩（2026-10-03）**。共用滚动区就是设计的一部分 ——
这一层本来就会把应用列表推到下面，用户滚一下是预期操作，不是缺陷。
⇒ 上面那四个旋钮**全部不做**，`44px` 行高保持不动（与 app 行等高，视觉一致）。
（四个旋钮备查，将来真嫌长再挑：① 端点音量行用 `40px`；② 三个 `seclabel` 折进行内；
③ 这一层限高 + 内部自己滚；④ 渲染端点也做成折叠组。）

**✅ 滑块的高频回调走哪条路：已定方案 A —— TAP 在 ShellHost 内直接调 WASAPI（2026-10-03）**

现有 `action=pipe` 是为**点击**设计的（一次一个报文）。但 `Slider.ValueChanged` 在拖动时
**每秒触发几十次** —— 走管道会打满管道、引入队列延迟、让滑块跟手感变差。
⇒ **滑块流量一律不走 IPC**；`pipe` 继续只承载"点击/命令"（这一次决定把 §5.7 与 §2.4 的边界钉死了）。
这一条同时适用于「端点音量」与下一层的「逐应用音量」。

方案 A 带来的**三条硬约束**（都必须实现，不是"可选优化"）：

| # | 约束 | 说明 |
|---|---|---|
| **A1** | **WASAPI 封装必须两边共链** | TAP 与 App 都要用 `IAudioEndpointVolume`。⛔ **绝不能写两份** —— 两份实现 = 两份端点枚举顺序、两份 `DEVICE_STATE` 过滤、两份 V 过滤，迟早不一致。⇒ 抽成一个**静态库/仅头实现**，TAP 与 App 各链一份 |
| **A2** | **"外部改动"要回写到 UI** | 用户按**键盘音量键**、或用系统自己的音量面板改同一台设备时，我们的滑块必须跟着动。⇒ `IAudioEndpointVolume::RegisterControlChangeNotify`。<br>⛔ **回调不在 UI 线程**（COM 通知线程池）⇒ 回写 UI 必须 `Dispatcher.RunAsync` |
| **A3** | **区分"拖动中"与"拖动结束"** | `Slider.ValueChanged` 分不清这两者。外部回写时若直接改 `Value`，会和用户正在拖的位置**打架**。<br>⇒ 用 `Thumb.DragStarted` / `DragCompleted`（或 `PointerPressed`/`Released`）维护一个 `isDragging` 标志，**拖动中忽略外部回写**。WinUI `Slider` **没有** `IsDragging` 属性，别去找 |

**⚠️ 由此新增两个必须实测的点（本机就能验 —— 本机有 1 个渲染端点可读写）**：

- **T23**：`Slider.ValueChanged` 里直调 `SetMasterVolumeLevelScalar` 的**单次往返耗时**。
  它是跨进程 COM 调用（到 `audiosrv`），若达到数十 ms 且 UI 线程同步等待，拖动会顿。
- **T24**：`RegisterControlChangeNotify` 的**回调线程**是否真如文档所说不在 UI 线程
  （若真不在 UI 线程而直接改 UI ⇒ 崩）。
