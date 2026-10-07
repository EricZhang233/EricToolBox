# VolumeMixerExtender 功能模块方法与实现交付文档（C++ 版）

| 项 | 值 |
|---|---|
| 文档版本 | 1.0 |
| 日期 | 2026-10-03 |
| 目标平台 | Windows 11 build 26300.9550（实测环境） |
| 技术轨道 | 控制面与 in-proc 两段全部原生 C++，零 .NET 依赖 |
| 文档状态 | 架构与契约已定稿；PoC 已跑通；标 ⚠️ 的条目待 V 阶段验证 |
| 标记约定 | ✅ 已实测 / ⚠️ 设计推断需验证 / ⛔ 硬限制不可消除 |

---

## 0. 文档说明

### 0.1 读者与用途

面向要接手实现/维护本项目的开发者。回答：**有哪些模块、每个模块有哪些方法、方法之间怎么串、怎么验证和排障**。

本文是项目**维护中的唯一规格**。

各章节的难度分布：§2.0 共享契约、§3 控制面实现、§6 错误与资源策略、§7 原生构建、§9 原生排障手段
是本文的深度所在。

### 0.2 术语表

| 术语 | 含义 |
|---|---|
| **面板** / ControlCenter | Win11 快速设置窗口，类 `ControlCenterWindow` |
| **L1** / 主快速设置页 | 面板打开时的第一层（`Win+A` 进入）。`ControlCenterRegion` 下是快捷按钮组 + `FooterGrid`，31 个元素（`06-l1-main-panel-tree.md`） |
| **入口按钮** | L1 的「选择声音输出」，`AutomationId` = **`VolumeL2Button`**，本项目要接管的入口 |
| **声音输出页** | 面板内进入的二级页（`FullScreenPage` / `PageWindow`），即系统自带的声音页，28 个元素 |
| **自定义页** | 本项目自绘的页面，占据声音输出页的 `ListContent` 区域 |
| **`ListContent`** | 声音输出页的内容区（`ScrollViewer`），自定义页的**挂载点** |
| **底栏** / Footer | 声音输出页底部 `ItemsControl`，`Name` = `Footer`，几何 `(2189,1417) 358x48` |
| **模型按钮** | 底栏已有按钮「更多音量设置」，`(2193,1420) 94x40`，取样式与位置基准 |
| **ShellHost** | `ShellHost.exe`，托管面板 XAML 的宿主进程，**注入目标**，父进程 `sihost.exe` ✅ |
| **band** | 非默认窗口 band。面板 = 4 ⇒ `EnumWindows`/`FindWindow`/UIA `RootElement` 都看不到 ✅ |
| **TAP** | Type Activation Provider，XAML 诊断框架的进程内 COM 对象。本项目自写一个 |
| **in-proc 两段** | 必须在 ShellHost 内执行的两段：Launcher（调诊断入口）与 Tap（收事件改树） |
| **控制面** | 我们自己的进程（托盘宿主）：进程监视、注入、配置、日志、IPC、UI |
| **共享静态库** | C++ 轨道独有的概念：一份代码被控制面与 in-proc 两段**同时静态链接**（§3.0） |

### 0.3 交付物清单

| # | 交付物 | 类型 | 位置（安装后） | 必须 |
|---|---|---|---|---|
| D1 | `VmExt.App.exe` | 原生可执行（托盘宿主 + 配置窗） | 根目录 | 是 |
| D2 | `VmExt.Launcher.dll` | 原生 DLL（in-proc 第 1 段） | 根目录 | 是 |
| D3 | `VmExt.Tap.dll` | 原生 DLL（in-proc 第 2 段，COM in-proc server） | 根目录 | 是 |
| D4 | `vmext.ini` | 控制面配置（原生 INI，自己读写） | 根目录 | 是 |
| D5 | `vmext-tap.ini` | TAP 配置（热重载） | 根目录 | 是 |
| D6 | `vm-ext.rc` 编译进 exe | 托盘图标、菜单、对话框资源 | — | 是 |
| D7 | `install.ps1` / `uninstall.ps1` | 安装/卸载 | `tools\` | 是 |
| D8 | `xamldiagnostics.dll` | **来自 Windows SDK**，不是我们的 | 由 SDK 路径指向 | 前置依赖 |
| D9 | `VmExt.Tap.pdb` / `VmExt.App.pdb` | 符号（排障必需，见 §9.4） | `symbols\` | 是 |
| D10 | 本文档 | 文档 | `docs\` | 是 |

⛔ **没有 .NET 运行时、没有第三方库、没有 VC++ Redistributable**（静态 CRT）。这是本轨道的主要卖点，见 §1.0。

### 0.4 明确不做的事

1. 不做多会话同时注入（只处理**当前会话**）。
2. 不保证「面板已打开时注入立刻生效」（面板每次打开重建 XAML 元素，本方案在**下次打开**生效）。
3. 不做 TAP 卸载（⛔ §10.1）。「禁用」= 让 TAP 什么都不做。
4. 不 hook shell 的任何函数、不改 ShellHost 代码段、不写注册表 hook 项。
5. 不依赖 Windhawk / ExplorerPatcher / 任何第三方框架。
6. 不做驱动（本机无 WDK；也不需要）。
7. **不引入第三方 C++ 库**（不用 nlohmann/json、不用 wil、不用 Catch2 作为运行时依赖）。理由见 §7.5；测试框架按需引入但**不进产品二进制**。

---

## 1. 系统总览

### 1.1 目标功能（一句话）

点击快速设置主面板（L1）的 **「选择声音输出」按钮**后，**直接进入自定义页**（自绘 XAML，占据声音输出页的内容区）；
声音输出页原有的**底栏按钮**改为**系统页 ↔ 自定义页的切换**。

自定义页承载：默认输入/输出设备切换、逐应用音量与输出端点、一键清除重定向。

**范围边界（重要）**：自定义页**只做这两块强项**。系统页原有的能力（空间音效、设备单选列表等）
**一律不自绘** —— 用户按底栏的 `SystemMixer` 切回系统页即可。
因为**系统页由系统自己绘制、我们不修改**（§5.7.3），它一直活着，切回去就是；自绘一份等于
维护一套会随系统更新而失效的复制品。

> ⚠️ **与旧版的区别**：早前设计是"在声音输出页底栏右侧注入一个入口按钮，点击执行外部指令"。
> 底栏注入的技术路线仍然复用（§5.2），但**入口语义已转移**：入口现在是 L1 的 `VolumeL2Button`。
> 详见 §5.7 与 `docs/design.md` §7。

### 1.2 为什么 in-proc 两段必须是原生代码

| # | 约束 | 后果 |
|---|---|---|
| C1 | ✅ `InitializeXamlDiagnosticsEx` 由**目标进程自己的** `Windows.UI.Xaml.dll` 导出，**只能在目标进程内调用**。无 out-of-proc 版本 | 必须有一段代码跑在 ShellHost 里 ⇒ 必须 DLL 注入 |
| C2 | ✅ TAP 被 XAML core 用 `LoadLibrary` + `DllGetClassObject(CLSID)` 加载，要求导出 `DllGetClassObject` 并**手搓 COM vtable** | 这段必须是原生代码 |
| C3 | ⛔ ShellHost 是**原生、非 .NET** 进程。要让托管代码在里面跑，必须把 CLR 运行时（`hostfxr`/`coreclr`）也塞进去 | 在别人的进程里塞整套运行时不可接受 |

**⇒ 本轨道下这个约束"消失"了**：整条链路都是 C++，不存在"哪一层用什么语言"的选择题。这是 C++ 轨道在**架构简单性**上的真实优势 —— 只有一种语言、一套构建、一套符号、一个调试器。

### 1.3 进程与线程模型

```text
┌─ 用户会话 (Session N) ───────────────────────────────────────────────────────────┐
│                                                                                 │
│  ┌─ VmExt.App.exe（原生 C++，Medium IL，我们自己的进程）───────────────────┐   │
│  │  主线程        : Win32 消息循环（隐藏消息窗 + 托盘 + 配置对话框）        │   │
│  │  Watcher 线程  : WaitForMultipleObjects(进程句柄)，★ 空闲 0 CPU          │   │
│  │  Orchestrator  : 由 Watcher 事件驱动，短暂工作，跑在一人一线程上         │   │
│  │  Pipe 线程     : ConnectNamedPipe/ReadFile 阻塞循环，接收 TAP 点击       │   │
│  │  Health 线程   : 每 30s 一次，三个 syscall 量级                          │   │
│  └────────────┬───────────────────────────────────────────────────────────┘   │
│               │ CreateRemoteThread(LoadLibraryW("VmExt.Launcher.dll"))          │
│               ▼                                                                 │
│  ┌─ ShellHost.exe（原生，Medium IL，sihost.exe 的子进程）──────────────────┐   │
│  │  [注入的] VmExt.Launcher.dll                                            │   │
│  │    DllMain → CreateThread(Worker)                                       │   │
│  │    Worker : 等 Windows.UI.Xaml.dll → GetProcAddress →                   │   │
│  │             InitializeXamlDiagnosticsEx(..., initData)                  │   │
│  │  [XAML core 加载的] VmExt.Tap.dll                                       │   │
│  │    DllMain → 日志（共享 Log 实现，静态链接）                            │   │
│  │    IObjectWithSite::SetSite → QI IXamlDiagnostics / IVisualTreeService  │   │
│  │    AdviseVisualTreeChange → 之后由 XAML core **在 UI 线程**回调         │   │
│  │       OnVisualTreeChange → 命中 Footer → 包 Grid + 加按钮               │   │
│  │  [面板的] ControlCenterWindow (band=4) → InputSite 子窗口（XAML 根）     │   │
│  └─────────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────────┘
```

**⭐ 与控制面共享代码的三处**（C++ 轨道独有，见 §3.0）：

```text
        ┌──────────────────── VmExt.Shared.lib（静态库，只编译一次）────────────────────┐
        │  Log（日志）  Ini（配置读写）  Str（字符串/路径）  Contract（契约）  Win32（RAII）│
        └───────┬─────────────────────────────┬─────────────────────────────┬───────────┘
                │ 静态链接                     │ 静态链接                     │ 静态链接
        VmExt.App.exe                 VmExt.Launcher.dll              VmExt.Tap.dll
        （控制面）                      （in-proc 第 1 段）              （in-proc 第 2 段）
```

**线程铁律**（违反会崩 shell）：

| 规则 | 原因 |
|---|---|
| `OnVisualTreeChange` 运行在 **ShellHost 的 XAML UI 线程**（✅ 实测 tid 恒定）。改 XAML 必须在**这个**线程上 | XAML 对象有线程亲和性 |
| Launcher 的 `Worker` 必须是**独立线程**，不是 `DllMain` 线程 | `DllMain` 里做重活会死锁在 loader lock |
| 改 XAML 必须在**布局完成之后**（`ActualWidth > 0`） | ✅ 实测踩坑：算出 354px 离谱边距并永久固化 |
| 需要延后执行用 `CoreDispatcher::RunAsync`，**不要 `Sleep`** | UI 线程不能阻塞 |
| TAP 的点击动作**不得阻塞 UI 线程**（独立线程或短超时） | 否则面板卡死 |
| ⭐ **控制面的线程与 in-proc 的线程互不等待** | 控制面的 `std::mutex` 与 TAP 的 `CRITICAL_SECTION` 是两个进程的锁，不可能互等；但**TAP 内部的锁绝不能跨越 `CreateProcess`/管道 IO** |

### 1.4 组件清单与依赖矩阵

| 模块 | 编译进 | 进程 | 依赖 | 被谁调用 |
|---|---|---|---|---|
| `vmext_contract.h` | 全部 | — | 无（纯头文件 + 少量 inline） | App / Launcher / Tap |
| `VmExt.Shared.lib`（Log / Ini / Str / Win32 RAII） | App / Launcher / Tap | — | 仅 Win32 | 全部 |
| `VmExt.Locator` | App | App | Shared, Win32 | Watcher / Injector / Health |
| `VmExt.Watcher` | App | App | Locator | Orchestrator |
| `VmExt.Injector` | App | App | Win32 | Orchestrator |
| `VmExt.DiagLocator` | App | App | Shared | Orchestrator |
| `VmExt.TapProbe` | App | App | Win32 | Orchestrator / Health |
| `VmExt.Orchestrator` | App | App | 上面全部 | TrayApp |
| `VmExt.Health` | App | App | TapProbe, Locator | TrayApp |
| `VmExt.PipeServer` | App | App | Win32 | TrayApp |
| `VmExt.TrayApp` / `VmExt.SettingsDlg` | App | App | 全部 | 用户 |
| `VmExt.Launcher.dll` | DLL | **ShellHost** | Shared, `ole32` | 注入后自启线程 |
| `VmExt.Tap.dll` | DLL | **ShellHost** | Shared, cppwinrt 头, `WindowsApp.lib`, `ole32` | XAML core |

### 1.5 一次完整生命周期的时序

```text
VmExt.App.exe 启动
  │
  ├─ Str::ValidateInstallPath()             ← 路径不能含 ';' 或 '='（§2.2）
  ├─ Ini::Read(vmext.ini) → AppConfig
  ├─ DiagLocator::Locate()                  ← 找不到 xamldiagnostics.dll ⇒ 进 Faulted，不注入
  ├─ PipeServer::Start()
  ├─ TrayApp::CreateTrayIcon()              ← 之后主线程进消息循环
  └─ Watcher::Start(onStarted, onExited)
       │
       ▼  onStarted(ShellHost)
  Orchestrator::TryInject(shellHost)
  ├─ TapProbe::IsAlive(pid)?  ── 是 ─→ 跳过（幂等）
  ├─ Ini::Write(vmext-tap.ini)                  ← 每次注入前重写（配置可能刚改过）
  ├─ Ini::Write(VmExt.Launcher.ini, ...,
  │             Contract::BuildInitData(...))    ← ★ 与 TAP 共享同一个实现
  ├─ Injector::InjectInto(pid, kLauncherDll)     ← RVA 算法，见 §3.7
  └─ TapProbe::WaitUntilAlive(pid, 10s)
       │
       ▼  （用户按 Win+Ctrl+C/V 或点任务栏音量）
  ShellHost 创建声音输出页 XAML 树
  └─ Tap::OnVisualTreeChange(Add, Name="Footer")
       └─ InjectIntoRow()：包两列 Grid + 造按钮 + 复制样式 + 绑 Click
       │
       ▼  （用户点按钮）
  ConfigReader::ReadEntry（按钮创建时已读入闭包）
      action=exec → BuildCommandLine(exe, args) → CreateProcessW(exe, cmd, …, exe 所在目录)
      action=pipe → 起独立线程 → CreateFileW(pipe) → 写 "CLICK <id>\n"
      action=open → ShellExecuteW(nullptr, L"open", url, …, SW_SHOWNORMAL)  ← URL 专用
        └─ PipeServer 线程收到 → 投递到主线程 → 执行动作
       ▼
（关面板）→ XAML 树销毁 → 按钮消失（无残留）
（再开面板）→ 重新走回调；enabled=0 则什么都不做
```

### 1.6 ShellHost 生命周期与重注入

✅ 实测：`ShellHost.exe` 的父进程是 **`sihost.exe`**。它会随 shell 重启（explorer 重启 / sihost 重启 / 自身崩溃）换成**新进程**。

```text
loop（在 Watcher 线程里）:
    1. 扫描本会话的 ShellHost
    2. 对每个候选：TapProbe::IsAlive(pid)?
         是 → 跳过
         否 → Injector + WaitUntilAlive
    3. WaitForMultipleObjects(进程句柄, 5s)   ← 阻塞，0 CPU
    4. 有进程退出 → 触发 onExited → 回到 1
```

**要点**：TAP 活在 ShellHost 里，ShellHost 一换进程 TAP 就没了。正常运行要的是这个**重注入循环**（保持接管），
不是"重启 explorer"。
> ⭐ 但**卸载反着用同一个事实**：既然"ShellHost 换进程 ⇒ TAP 必然消失"，那**重启 shell 就是唯一
> 不需要"卸载 DLL"就能送走 TAP 的手段** —— 这正是 §5.7.8「从系统卸载」第 4 步的依据。

---

## 2. 跨进程契约

### 2.0 契约从"约定"变成"代码"

CLSID、端点名前缀、initData 键名、管道名格式、互斥体名格式、INI 键名 —— 这些若分处两侧**各写一份**，就会"改一处忘另一处、编译通过、运行出错"，而且错得很隐蔽（例如 CLSID 差一个字节 → `DllGetClassObject` 返回 `CLASS_E_CLASSNOTAVAILABLE`，看起来像"TAP 加载失败"）。

**做法**：一个头文件，三个二进制同时 include。

```cpp
// ---------------------------------------------------------------------------
// vmext_contract.h  —— 单一事实来源（Single Source of Truth）
// 被 VmExt.App.exe / VmExt.Launcher.dll / VmExt.Tap.dll 同时包含。
// ⛔ 任何常量改动只需要改这一个文件，改动必然同时作用于三个二进制。
// ---------------------------------------------------------------------------
#pragma once
#include <windows.h>
#include <string>
#include <string_view>
#include <vector>
#include <optional>

namespace vmext::contract {

// ============ 1. in-proc 契约（改动会同时影响两侧的编译产物）============
// TAP 的 COM 类 ID。✅ PoC 实测可用。
inline constexpr GUID kTapClsid =
    { 0xA7C5F1E2, 0x9B34, 0x4D6E, { 0x8F, 0x21, 0x5C, 0x0D, 0x3E, 0x7A, 0x9B, 0x44 } };

// 诊断端点名前缀。⛔ OS 约定，不可改。
inline constexpr wchar_t kEndPointPrefix[] = L"VisualDiagConnection";

inline constexpr wchar_t kTargetProcessExe[]   = L"ShellHost.exe";
inline constexpr wchar_t kTargetProcessName[]  = L"ShellHost";      // 无扩展名，进程快照用
inline constexpr wchar_t kLauncherDllName[]    = L"VmExt.Launcher.dll";
inline constexpr wchar_t kTapDllName[]         = L"VmExt.Tap.dll";
inline constexpr wchar_t kLauncherIniName[]    = L"VmExt.Launcher.ini";
inline constexpr wchar_t kDiagnosticsDllName[] = L"xamldiagnostics.dll";

// ============ 2. 协议版本与配置下发（§2.2）============
inline constexpr int kInitDataVersion = 1;

// TAP 的"配置直投"导出名。★ 这是配置的**主通道**（§2.2.1）。
// 两侧都从同一个宏来，不存在"各写一个裸字符串"的可能。
#define VMEXT_TAP_PROVIDE_EXPORT_NAME  VmExtTapProvideInitData
inline constexpr wchar_t kTapProvideInitDataExport[] = L"VmExtTapProvideInitData";
using TapProvideInitDataFn = void (WINAPI*)(const wchar_t*);

// ⚠️ initData 通道的**实测硬上限**（字符数）。超过它，OS 会**静默**丢弃整个串：
//    InitializeXamlDiagnosticsEx 与 GetInitializationData 都返回 S_OK，只是拿到空串。
//    超限不是错误（配置走直投通道），但必须打警告，否则排查时会被误导。
inline constexpr size_t kInitDataHardLimit = 259;

// ============ 3. 名字生成（唯一实现）============
inline std::wstring PipeName(unsigned long sessionId) {
    return L"\\\\.\\pipe\\VmExt.Tap.S" + std::to_wstring(sessionId);
}
inline std::wstring TapMutexName(unsigned long pid) {
    return L"Local\\VmExt.Tap.Singleton." + std::to_wstring(pid);
}
inline std::wstring EndPointName(int index) {
    return std::wstring(kEndPointPrefix) + std::to_wstring(index);
}

// ============ 4. initData 的结构与编解码（★ 与约定不同：这里是共享实现）============
struct InitData {
    int          ver   = kInitDataVersion;
    std::wstring cfg;    // vmext-tap.ini 的绝对路径
    std::wstring log;    // TAP 日志绝对路径
    std::wstring pipe;   // 管道名
    std::wstring mutex;  // 单例互斥体名
};

// 序列化成 "ver=1;cfg=...;log=...;pipe=...;mutex=..."。值里含 ';' 或 '=' 时返回 false。
// ⚠️ 产出结果若超过 kInitDataHardLimit，调用方**照传**但必须打警告（见 §2.2.2 约束 1）。
bool Build(const InitData& d, std::wstring& out, std::wstring& err);

// 反序列化。未知键忽略；ver 不识别则返回 false（调用方据此"安全退化"）。
bool Parse(std::wstring_view s, InitData& out, std::wstring& err);

// ============ 4b. 命令行拼装（★ 安全相关，必须共享）============
// 把 exe 路径与参数拼成一条**安全**的命令行：exe 路径加引号。
// 为什么这件事需要一个共享函数而不是"谁用谁拼"：
//   CreateProcessW 在 lpApplicationName=NULL 时会对**未加引号的含空格路径逐段前缀试探**，
//   前缀处存在同名 exe 就会启动那个（已实测复现，见 §4.3 坑 27）。
//   把它集中成一个带单元测试的函数，就等于把这个洞焊死了。
std::wstring BuildCommandLine(std::wstring_view exePath, std::wstring_view args);

// ============ 5. INI 键名（写方与读方必须一致，所以放这里）============
namespace inikey {
    inline constexpr wchar_t kSection[]      = L"vmext";
    inline constexpr wchar_t kEnabled[]      = L"enabled";
    inline constexpr wchar_t kEntryPrefix[]  = L"entry";      // + <n> + "." + <字段>
    inline constexpr wchar_t kId[]           = L"id";
    inline constexpr wchar_t kText[]         = L"text";
    inline constexpr wchar_t kAction[]       = L"action";
    inline constexpr wchar_t kExe[]          = L"exe";
    inline constexpr wchar_t kArgs[]         = L"args";    inline constexpr wchar_t kInset[]        = L"inset";
    inline constexpr wchar_t kHeight[]       = L"height";
}

// ============ 6. IPC 报文 ============
namespace ipc {
    inline constexpr char kClickPrefix[] = "CLICK ";
    inline constexpr char kUninstallLine[] = "UNINSTALL\n";
    // 完整的点击报文： "CLICK <entryId> <unixMillisUtc>\n"
    std::string FormatClick(std::string_view entryId, unsigned long long unixMillis);
}

} // namespace vmext::contract
```

**这一节直接解决的两件事**：

| 问题 | 做法 |
|---|---|
| ⭐ **配置下发往返**（§4.2.3，原 V2 验证项） | 配置主干是"直投"（等于一次同进程函数调用）。导出名进共享头文件 ⇒ 两侧同源；`BuildCommandLine`/`Parse`/`Ini` 的边界串（空值/超长/含分隔符/未知键/非法 ver/含空格的路径）是**纯单元测试**，不需要注入任何东西 |
| ⭐ **INI 编码**（原 §4.3 坑 13） | `Ini::Write` 与 `Ini::Read` 是**同一份代码**（§3.3），结构上不可能不一致。再配一个"写→读→比对含中文的值"的单元测试 |
| ⭐ **命令行拼装**（§2.3 / §4.3 坑 27） | 拼装逻辑集中在 `Contract::BuildCommandLine`，配单元测试（路径含空格、含 `"`、参数含空格、空参数）⇒ 从"纪律"变成"代码 + 测试" |

> **这是本轨道最大的实际价值所在**：不是性能、不是体积，而是**把项目里那几个最容易出隐性 bug（含"要记住三条纪律"这种）的环节变成编译期 + 单元测试可保证的东西**。
>
> ✅ 顺带说明 T1 的结论：initData 通道**可用但上限 259 字符、超限静默失败**（实测），
> 因此配置主干走"直投"，initData 只作面包屑。

### 2.1 常量全表

| 常量 | 值 | 谁用 | 可变性 |
|---|---|---|---|
| TAP CLSID | `{A7C5F1E2-9B34-4D6E-8F21-5C0D3E7A9B44}` ✅ | Launcher 传 + TAP 返回 | 改动只需改 `vmext_contract.h`（三处同时生效） |
| 端点名前缀 | `VisualDiagConnection` | Launcher 拼接 | ⛔ OS 固定 |
| Launcher / Tap DLL 名 | `VmExt.Launcher.dll` / `VmExt.Tap.dll` | Injector / Launcher | 可改（一处） |
| 管道名 | `\\.\pipe\VmExt.Tap.S<sessionId>` | Tap 客户端 / App 服务端 | 可改（一处） |
| 单例互斥体名 | `Local\VmExt.Tap.Singleton.<pid>` | Tap 自检 | 可改（一处） |
| 诊断运行时 | `xamldiagnostics.dll` | DiagLocator | ⛔ 固定 |
| 目标进程 | `ShellHost.exe` | Locator | ⚠️ 软依赖（§10.2 S5） |
| 目标元素名 | `Footer` | Tap 匹配 | ⚠️ 软依赖（§10.2 S1） |
| **TAP 配置直投导出名** | `VmExtTapProvideInitData` ✅ | Launcher 直投配置给 Tap | 改动只需改 `vmext_contract.h`（导出名由宏派生） |
| **initData 硬上限** | `259` 字符（实测值） | `Contract::Build` 之后的长度自检 + 告警 | ⛔ OS 行为，不可改（§2.2.1） |
| 日志目录 | `<cache>\log` = `%TEMP%\eric\VolumeMixerExtender\log` | App / Launcher / TAP 共用 | ⛔ 与隔壁 EricGameLauncher 同构：一次进程会话一个文件 `<role>-<yyyyMMdd-HHmmss>.log`（`role` = `app`/`launcher`/`tap`） |
| 点击消息号（备选方案） | `WM_APP + 0x2100` | Tap → App | 可改 |
| **IPC 报文 VERB** | `CLICK `（带 `<entryId> <unixMillisUtc>`）/ `UNINSTALL`（无参数） | Tap 生成 / App 解析 | ⚠️ ⛔ **App 侧必须先取 VERB 再分支**，不能按"第一段一定是 CLICK"写死（§2.4） |

### 2.2 配置下发（两条通道，主次分明）

> ✅ **本节已在 PoC 上实测完毕**（T1）。完整长度扫描表、BSTR 所有权、端到端链路验证见
> `verified-after-injection/06-initdata-channel-limit.md`。下面是**实测之后的定稿设计**。

| 通道 | 角色 | 容量 | 实测结论 |
|---|---|---|---|
| **直投**（Launcher 直接调 TAP 的导出） | ★ **配置主干** | **无限制** | 已验证 **4000 字符逐字符无损** |
| `InitializeXamlDiagnosticsEx` 第 6 参数 `wszInitializationData` | **面包屑**（人类可读，便于事后核对"本该是什么"） | ⚠️ **正好 259 字符** | ≤259 逐字符一致（含中文）；≥260 **静默返回空串** |
| initData（直投失败时） | 降级配置来源 | 259 字符 | 已实现并显式记日志 |

#### 2.2.1 直投通道（主通道）★

`InitializeXamlDiagnosticsEx` 的第 6 个参数**确实**能被 `IXamlDiagnostics::GetInitializationData()`
原样读回 —— 但**上限正好 259 字符**，而且超限时是**静默失败**：`InitializeXamlDiagnosticsEx`
返回 `S_OK`，`GetInitializationData` 也返回 `S_OK`，只是拿到的 BSTR 长度为 0。
一个 `cfg=<完整安装路径>` 就可能上百字符，259 装不下真实配置，而**上限不可协商**。

所以配置走"直投"：**Launcher 与 TAP 在同一个进程里**，Launcher 直接 `LoadLibraryW` 加载 TAP DLL，
`GetProcAddress` 拿到导出的函数指针，把配置字符串交给它：

```cpp
// ① 直投（必须在 InitializeXamlDiagnosticsEx 之前）
HMODULE hTap = ::LoadLibraryW(tapDllPath);
auto provide = reinterpret_cast<TapProvideInitDataFn>(
                   ::GetProcAddress(hTap, contract::kTapProvideInitDataExport));
if (provide) provide(config.c_str());        // ← TAP 的全局变量就位
// ★ 刻意**不** FreeLibrary：多持一个引用确保模块不被卸载，全局变量不会随卸载丢失

// ② 再发起注入（initData 只作面包屑）
HRESULT hr = InitializeXamlDiagnosticsEx(endpoint, ::GetCurrentProcessId(),
                                         xamldiag, tap, contract::kTapClsid, config.c_str());
```

**为什么成立**：先 `LoadLibraryW` 时模块已被加载、全局变量可写；XAML core 之后加载同一模块时
拿到的是同一个 `HMODULE`（`LoadLibrary` 引用计数），所以 TAP 的 `DllGetClassObject` 被调用时，
配置**已经就位**。

**跨进程契约新增项**：

| 项 | 值 | 备注 |
|---|---|---|
| 导出名 | `VmExtTapProvideInitData` | 定稿，两侧都不可单方面改 |
| 签名 | `void WINAPI VmExtTapProvideInitData(const wchar_t*)` | 不返回错误码：失败通过**日志**暴露 |
| 调用时机 | **先直投，后 `InitializeXamlDiagnosticsEx`** | 顺序反了配置就丢了 |
| 生命周期 | 调用方**不得** `FreeLibrary` 该 DLL | 否则全局变量随卸载丢失 |
| 入参 | 见 §2.2.2 的 `k=v;` 串 | 与 initData **同一个字符串** |

> **为什么"同一个字符串"很重要**：两条通道内容一致，才能拿日志里的哈希直接对比 ——
> 这是"配置有没有被改坏"的最省事自检。PoC 就是这么验的（两侧打印 `fnv1a64`，要求逐位相同）。

**导出名必须同源**：若它只是个**裸字符串**，拼错了编译器不管，
只有运行时 `GetProcAddress` 返回 `NULL`。所以让它进共享头文件：

```cpp
// vmext_contract.h（新增）
#define VMEXT_TAP_PROVIDE_EXPORT_NAME  VmExtTapProvideInitData

inline constexpr wchar_t kTapProvideInitDataExport[] = L"VmExtTapProvideInitData";
using TapProvideInitDataFn = void (WINAPI*)(const wchar_t*);
```

```cpp
// VmExt.Tap.cpp —— 导出名来自同一个宏，不手写第二遍
#define VMEXT_WIDEN2(x) L##x
#define VMEXT_WIDEN(x)  VMEXT_WIDEN2(x)
#pragma comment(linker, "/EXPORT:" VMEXT_WIDEN(VMEXT_TAP_PROVIDE_EXPORT_NAME))
```

链接器的 `/EXPORT:` **只接受字面量**，所以"宏"和"常量数组"这两处必须各写一遍 ——
但两者的一致性可以**用一条单元测试钉死**（比较两个字符串），
于是"写错也不报错"这个洞就被堵上了。
这正是 §2.0 所说"把约定变成代码"的又一个具体落点。

#### 2.2.2 载荷格式

**格式**：单行 UTF-16，`k=v` 用 `;` 分隔。**刻意不用 JSON**：

| 理由 | 说明 |
|---|---|
| 原生侧要手写 JSON 解析器毫无价值 | C++ 里没有标准 JSON；引入 `nlohmann/json` 违背"零第三方依赖"（§0.4 第 7 条） |
| `k=v` 的解析是十行代码 | `wcsstr` + `wcsncmp`，可单测 |
| 反序列化在**两个**地方都要用 | TAP 解析配置，Launcher 构造它 —— 共享实现（§2.0） |

```text
ver=1;cfg=<vmext-tap.ini 绝对路径>;log=<tap 日志绝对路径>;pipe=\\.\pipe\VmExt.Tap.S2;mutex=Local\VmExt.Tap.Singleton.17080
```

| 键 | 必需 | 缺省行为 |
|---|---|---|
| `ver` | 是 | 视为 1；不认识的版本 → TAP 静默不注入（只记日志） |
| `cfg` | 是 | 相对路径按 TAP DLL 所在目录解析 |
| `log` | 否 | TAP DLL 同目录 `tap.log` |
| `pipe` | 否 | 无 ⇒ `action=pipe` 的条目会失败并记日志 |
| `mutex` | 否 | 自动拼 `Local\VmExt.Tap.Singleton.<pid>` |

> ★ **`cfg` 必须由通道自己传**。若"配置里说配置在哪"就形成循环依赖了 ——
> 所以 `cfg` 是**唯一必须由通道送达**的键：TAP 先拿到 `cfg`，其余全部从那个 INI 读。
> 这样配置文件**放哪都行**（安装目录、`%LOCALAPPDATA%`、U 盘），不必与 DLL 同目录。

**约束**：

1. ⛔ **initData 通道的硬上限是 259 字符**（实测值，见 §2.2.1）。`Contract::Build` 之后要加一层长度校验：
   超限**仍然照传**（功能不受影响，配置由直投通道送达），但要打**警告日志**说明"面包屑会被丢弃"，
   否则将来排查时会误以为"配置没送过去"。
2. ⛔ **不要用返回值判断 initData 是否送达** —— 超限时 `hr` 仍是 `S_OK`。
   判断"配置到了没有"只能看 TAP 侧的日志（`直投通道: 有/无`）。
3. `;` 与 `=` **不得出现在值里**。`Contract::Build` 会检测并返回错误（见 §3.1）。
4. ✅ **原"未验证"项已消除**（V2 已完成）：`GetInitializationData` **会**原样返回该串，
   含中文逐字符一致，但上限 259。`Contract::Parse` 的单元测试仍然只能验证**我们自己的编解码**
   —— 但那本来就不是本项的未知量；本项的未知量已在 OS 侧钉死。
   ⚠️ **发现**：`Parse(Build(d)) == d` 这种往返测试**测不出** 259 上限（那是 OS 的行为），
   所以单元测试里要**另外**加一条：`Build` 产出的串若 >259，必须产生警告标志（可断言）。
5. Launcher 自身怎么知道这些值？→ **`VmExt.Launcher.ini`**（注入前由 App 写在 Launcher DLL 同目录）。这样注入参数只有 DLL 路径一项。
6. ⚠️ 直投发生在**注入器自己**的线程里。`InitializeXamlDiagnosticsEx` 会加载模块并同步遍历 XAML 树，
   中间不要插耗时操作；`provide()` 必须是**快速写全局变量**，不要在里面读文件/开日志文件。

### 2.3 配置：`vmext.ini` 与 `vmext-tap.ini`

**两种配置都用 INI**，不用 JSON。

| 配置 | 文件 | 读写 |
|---|---|---|
| 控制面 | `vmext.ini` | `Ini::Read` / `Ini::Write`（§3.3） |
| TAP | `vmext-tap.ini` | 同上，**同一份实现** |

理由：C++ 里 JSON 需要第三方库，而本项目配置本身就是扁平的键值对，INI 完全够用；只用一种格式意味着**一份读写实现 + 一组单元测试**。

**`vmext.ini`（控制面，App 读写）**：

```ini
[app]
; 总开关。0 = 完全不注入
enabled=1
; 显式指定诊断运行时；留空则自动探测（§3.8）
diagnostics_dll=
; 日志级别：0=Trace 1=Debug 2=Info 3=Warn 4=Error
log_level=2

[entry1]
id=volumemixer
text=音量合成器
; exec = TAP 直接 CreateProcessW；pipe = 通知 App 由 App 决定；open = ShellExecuteW 打开 URL
action=pipe
; ★ action=exec 时用这两项：exe 是**真实 exe 的绝对路径**（不是 .lnk），args 可选。
;   刻意不给"一整条命令行"的写法，见 §2.3 的安全说明。
exe=
args=
```

**`vmext-tap.ini`（TAP 读，App 写；**每次命中 `Footer` 时重读 ⇒ 热重载，无需重新注入**）**：

```ini
[vmext]
; 1 = 注入按钮；0 = 什么都不做（"反注入"的开关）
; ⚠️ "从系统卸载"的第一步就是把它写成 0（§5.7.8）；App 启动时会写回 1
enabled=1

entry1.id=volumemixer
entry1.text=音量合成器
entry1.action=pipe
; ★ 拆成 exe + args 两段，**不要**给一整条命令行 —— 理由见下方警告
; action=exec 时必填：真实 exe 的**绝对路径**（⛔ 不能是 .lnk 快捷方式）
entry1.exe=
; 可选：附加参数（原样拼到 exe 后面）
entry1.args=
; ★ 仅 action=open 时用：要打开的 URL（如 https://github.com/EricZhang233/VolumeMixerExtender）
entry1.url=
; 右侧内边距（像素）。✅ 实测底栏左边距也是 4，所以默认 4 得到对称
entry1.inset=4
; 按钮高度。0 = 跟随模型按钮的显式 Height（✅ 实测为 40，推荐）
entry1.height=0
```

| 字段 | 依据（与实测事实的对应） |
|---|---|
| `enabled` | 反注入开关。关闭后 TAP 常驻但不再改树（⛔ TAP 无法卸载，§10.1）。**`enabled=0` 是"从系统卸载"的第一步**（§5.7.8）—— 它先把"重新注入"这条路断掉；相应地 **App 启动时必须写回 `enabled=1`**，否则手动重开程序会出现"在跑但不注入" |
| `entry1.text` | 注入后 UIA 读到的 `Name` 就是它（PoC 用 `TestLink`） |
| `entry1.action=exec` | PoC 用 `CreateProcessW(L"winver.exe")` ✅ 已实测能拉起进程（安全写法，见 §4.3 坑 27–29） |
| `entry1.exe` | ★ **拆开而不是一整条命令行**：一整条命令行交给用户填，就会有人写成不加引号、或写成 `.lnk`。拆成 `exe` + `args` 后由 `Contract::BuildCommandLine` 负责加引号 ⇒ 用户**无从写错** |
| `entry1.action=pipe` | ⚠️ 设计新增，V4 验证 |
| `entry1.action=open` | ✅ **已定（2026-10-03）**：底栏左格 GitHub 用这个。`ShellExecuteW(nullptr, L"open", url, …)` —— **不复用 `exec`**，理由见 §4.2.5 的 ⚠️ |
| `entry1.url` | 仅 `action=open` 时读；放**完整 URL**（`https://…`）。⛔ 别把它塞进 `args` —— `ShellExecuteW` 的第二个参数（verb）和第三个参数（file/URL）是两个位置，语义不同 |
| `entry1.inset=4` | ✅ 实测：底栏 x=2189、模型按钮 x=2193 ⇒ 左边距 4；取 4 后按钮右边缘 2543 = 2547-4 |
| `entry1.height=0` | ✅ 实测：模型按钮 `Height` 是显式 `40.0`、`MinHeight=0.0`，直接读即可定高 |

> ⛔ **`entry1.exe` 不能指向快捷方式（`.lnk`）** —— ✅ 已用本机工具链实测（`docs/poc/src/probes/lnkprobe.cpp`）：
>
> ```text
> CreateProcessW(L"\"C:\...\x.lnk\"")                 => FAILED  GetLastError=193  (ERROR_BAD_EXE_FORMAT)
> CreateProcessW(L"\"C:\Windows\System32\cmd.exe\"")  => OK  pid=16852     ← 对照
> CreateProcessW(L"\"C:\Windows\System32\cmd.exe\" /c exit") => OK  pid=2440 ← 带参数也 OK
> ```
>
> 快捷方式的解析（目标重定向、参数、工作目录、环境变量）是 **shell** 的职责，`CreateProcessW` 不做这件事。
> 所以"启动什么"有三种可用形态（注意都经由 `entry1.exe` / `entry1.args` 表达）：
>
> | 形态 | 写法 | 适用 |
> |---|---|---|
> | 直接 exe | `entry1.exe=C:\...\VolumeMixerExtender.exe` | ★ 首选（自己的程序） |
> | ★ 交给 shell 解析 | `entry1.exe=C:\Windows\explorer.exe` + `entry1.args=ms-settings:apps-volume` | 需要 shell 参与（URI 协议、打开文件夹） |
> | ★★ 目标只能以快捷方式表达 | `entry1.exe=C:\Windows\explorer.exe` + `entry1.args="C:\...\某个.lnk"` | Store 应用等（`.lnk` 不能直接当 exe） |
>
> ⇒ **`action=exec` 不会自动获得"双击快捷方式"的效果。** 需要那种效果就必须显式走 `explorer.exe`。
> ⚠️ `SHELLEXECUTEINFO` + `ShellExecuteExW` 是另一条路（能直接吃 `.lnk`、URI、文档），
> 但它会 `CoInitialize`、可能弹 UAC、且**会在 UI 线程栈上做更多事** —— v1 刻意不用它（§4.3 坑 22）。

> ⚠️ **一条容易踩的坑：exe 路径必须加引号。**
> `CreateProcessW` 在 `lpApplicationName = NULL` 时会对**未加引号的含空格命令行逐段前缀试探**，
> 前缀位置存在同名 exe 就启动那个。✅ 已复现：
>
> ```text
> 命令行（不加引号）: C:\...\Temp\a b c\click probe.exe
>   前缀处放了 C:\...\Temp\a.exe  ->  实际启动的是那个（argv[0] = ...\Temp\a）
>   前缀处没有文件               ->  才落到 ...\a b c\click probe.exe
> ```
>
> 即"平时能跑，前缀处一旦存在同名文件就会静默启动别的程序"。
> ⚠️ 这是**正确性**问题（启动错程序），**不作为安全问题** —— TAP 是同用户上下文，
> 能在前缀处放文件的人本来就能以你的身份执行代码，没有权限边界被跨越。
>
> ★ **这也是上面配置 schema 把 `command` 拆成 `exe` + `args` 的原因**：
> "让用户填一整条命令行、还得记得加引号"这种设计本身就是 bug 的温床 ——
> 而在 C++ 轨道里，拼装代码就在 `vmext_contract.h` 旁边，可以配单元测试
> （用例：路径含空格、路径含 `"`、参数含空格、空参数）。


**⭐ 编码约定（C++ 轨道的写法）**：INI **一律用 UTF-16LE + BOM 写**，用 `GetPrivateProfileStringW` 读。

```cpp
// 唯一的写入口（§3.3）。UTF-16LE + BOM 是刻意的选择：
//  GetPrivateProfileStringW 是非 Unicode API 的 W 变体，其内部对文件编码的处理依赖系统
//  区域设置。UTF-16LE+BOM 是最无歧义的写法，且能保证中文值（entry1.text）正确往返。
//  这一点由"一份实现"保证，见 §2.0。
```

### 2.4 IPC 协议（`action=pipe` 模式）

| 项 | 值 |
|---|---|
| 传输 | 命名管道，**字节模式 + `\n` 分行** |
| 方向 | **单向**：TAP → App。App 不回包（避免 TAP 等回复而阻塞 UI 线程） |
| 服务端 | App：`CreateNamedPipeW` + `ConnectNamedPipe` 阻塞循环（§3.12） |
| 客户端 | TAP：`CreateFileW` + `WriteFile` + `CloseHandle` |
| 报文 | `<VERB> <args…>\n`。**VERB 是第一段**，App 先取 VERB 再分支（⛔ ⛔ 别按"第一段一定是 CLICK"写死）：<br>`CLICK <entryId> <unixMillis>\n` —— 点击条目<br>`SETDEFAULT <render\|capture> <deviceId\|@virtual>\n` —— 切系统默认设备（`@virtual` = 由宿主解析虚拟端点 V 的真实 ID）<br>`SETREDIRECT <render\|capture> <pid> [deviceId]\n` —— 逐应用重定向（`deviceId` 省略/为空 = 清除该应用）<br>`CLEARREDIRECT\n` —— 清空所有逐应用重定向<br>`UNINSTALL\n` —— 「从系统卸载」全套流程（§5.7.8）<br>⚠️ **参数按空格切分，且个数受校验**：`SETDEFAULT` 必须 2 段、`SETREDIRECT` 2–3 段、`CLEARREDIRECT`/`UNINSTALL` 0 段，不符即记 `报文参数不合法, 已忽略` 并丢弃（⛔ 别塞带空格的显示名进报文——实测会被截断成第一段） |
| 超时 | 客户端：`WaitNamedPipeW` 200ms；失败则**记日志并放弃**（不重试、不弹窗） |
| 线程 | ⚠️ **必须**在 TAP 的独立线程里做（或保证 200ms 上限），避免阻塞 XAML UI 线程 |

⚠️ **原 `AUTOSTART <0\|1>` 已不是管道动词**（2026-10-03 改）：开关必须**现查**「任务在不在」（管道单向，
问不了宿主），所以查/注册/删除全在 `Core/AutostartEntry` 里就地做，TAP 不再发包。
`UNINSTALL` 仍在管道上 —— 它要**重启 shell**，而 TAP 就在那个 shell 里，只能交给宿主。

**为什么不用窗口消息（`PostMessage`）**：`HWND` 在 App 重启后失效而 TAP 无法感知；管道名稳定且可重连。窗口消息列为备选（常量表已留消息号）。

⛔ **本协议不是数据通道，只走"离散事件"（点击 / 命令）。**
`Slider.ValueChanged` 这类**高频流量一律不走这里** —— 已定由 TAP 在 ShellHost 内**直接调 WASAPI**（§5.7.9 方案 A）。
⇒ 新增动作**优先考虑 TAP 内联实现**，只有"必须由 App 的进程身份/生命周期来做"的事才加报文。

⭐ **判据（2026-10-03 补，来自 `verified-after-injection/12-audio-interop-safety.md`）**：
除了"进程身份/生命周期"，**"不能崩在别人的进程里"也是同一类理由**。
未公开接口（`IPolicyConfig` 那类）**槽位未经证实、错槽位会 AV** ——
**在 ShellHost 里试错就是崩掉用户的 shell**，而在宿主进程里崩了只是重启一下。
⇒ **所有设备策略改动（切默认 / 逐应用重定向 / 清空重定向）都走本协议**，不在 TAP 内联。

### 2.5 日志契约

三份日志，**同一套写实现**（§3.2 的 `Log` 类静态链接进 App 与两个 DLL）：

| 文件 | 写入者 | 内容 |
|---|---|---|
| `<InstallRoot>\logs\app.log` | App | 编排/注入/健康/IPC |
| `<InstallRoot>\logs\launcher.log` | Launcher | 启动 → 等模块 → 解析导出 → 逐端点尝试 → 结果 |
| `<InstallRoot>\logs\tap.log` | TAP | 加载 → SetSite → 命中 Footer → 注入步骤 → 点击 |

⛔ **三条硬性约定**（全部来自 PoC 踩坑）：

1. **必须用 `CreateFileW(FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, OPEN_ALWAYS)` 写**。
   ⛔ **不要用 CRT 的 `std::wofstream` / `_wfopen`**：本机上 `ccs=UTF-8` 的 CRT 流会**静默只写一个 BOM，内容全丢**（实测）。`FILE_SHARE_READ|WRITE` 让 App 能在 TAP 持有句柄时读日志。
2. **写日志必须持锁**（`CRITICAL_SECTION`）。TAP 的日志会被多个线程写。
3. **只追加、不轮转**（TAP 内轮转会造成复杂性与丢失风险）。量级很小（每次开面板几十行）。App 启动时可按大小截断自己的日志。

### 2.6 会话与完整性级别契约

| 检查项 | 要求 | 依据 |
|---|---|---|
| 会话 | App 与 ShellHost 的 `SessionId` **必须相同**（`ProcessIdToSessionId`） | 跨会话注入无意义且通常失败 |
| 完整性级别 | 两侧都是 Medium IL | ✅ `OpenProcess(ALL_ACCESS)` 成功 |
| 保护进程 | ShellHost **不是** PPL | ✅ |
| 架构 | 位宽一致（都是 x64） | 跨架构注入不可能 |
| UAC | **不需要提权**，全装 `%LOCALAPPDATA%` | 设计决定 |

⛔ 一旦 ShellHost 变成 PPL 或换到更高 IL，本方案整体失效 —— 见 §10.2。

---

## 3. 原生宿主侧（控制面）功能模块

### 3.0 解决方案与项目结构

```
VolumeMixerExtender.sln                     （VS 2026 / MSBuild）
├─ VolumeMixerExtender.props                 ← 共享属性（C++ 没有 Directory.Build.props，用 .props）
├─ src/
│  ├─ VmExt.Shared/           静态库 .lib    ★ 被三个二进制同时链接（§2.0 的载体）
│  │     include/vmext_contract.h    契约（§2.0）
│  │     include/vmext_log.h         日志（§3.2）
│  │     include/vmext_ini.h         INI 读写（§3.3）
│  │     include/vmext_str.h         字符串/路径（§3.4）
│  │     include/vmext_win32.h       RAII 句柄与枚举（§3.5）
│  │     src/*.cpp
│  ├─ VmExt.Launcher/         DLL            in-proc 第 1 段（§4.1）
│  ├─ VmExt.Tap/              DLL            in-proc 第 2 段（§4.2）
│  ├─ VmExt.Control/          静态库
│  │     include/vmext_locator.h      §3.6
│  │     include/vmext_watcher.h      §3.7
│  │     include/vmext_injector.h     §3.8
│  │     include/vmext_diaglocator.h  §3.9
│  │     include/vmext_tapprobe.h     §3.10
│  │     include/vmext_orchestrator.h §3.11
│  │     include/vmext_health.h       §3.12
│  │     include/vmext_pipe.h         §3.13
│  └─ VmExt.App/              Win32 EXE
│        VmExt.App.rc                托盘图标/菜单/对话框资源
│        resource.h
│        main.cpp                     wWinMain + 自检 + 生命周期装配
│        tray.cpp / tray.h            §3.14
│        settings_dlg.cpp             §3.15
└─ tests/
   └─ VmExt.Tests/            控制台 EXE    契约/INI/字符串/注入错误路径（§3.16）
```

**项目级约定**：

| 项 | 取值 | 理由 |
|---|---|---|
| C++ 标准 | **`/std:c++20`** | 需要 `std::jthread` + `std::stop_token`（线程停止）、`std::span`、`if constexpr`。MSVC 19.5x 完整支持 |
| 运行库 | **`/MT`（静态 CRT）** | 免 VC++ Redistributable。⛔ Launcher/Tap 必须 `/MT`，否则 `LoadLibraryW` 在目标进程里可能因缺 DLL 返回 NULL |
| 字符集 | Unicode（`UNICODE;_UNICODE`） | 全程 `wchar_t` |
| 平台 | **x64 only** | 与 ShellHost 位宽一致 |
| 异常 | 控制面：**开**（`/EHsc`）；in-proc：开但要全捕获 | 见 §6.1 的异常策略 |
| RTTI | 开（Tap 需要 cppwinrt 的 `try_as`，虽然那是自定义机制；保持开最简单） | |
| 第三方库 | **运行时零依赖** | §0.4 第 7 条 |
| 警告 | `/W4` + `/WX`（对 VmExt.Shared / VmExt.Control 强制） | C++ 轨道的 bug 大多能从警告里抓出来 |
| 链接期优化 | Release 开 `/LTCG`；**Launcher/Tap 也开** | 体积与速度；对 in-proc 的有界代码量无风险 |
| 预处理器 | `_WIN32_WINNT=0x0A00`、`WIN32_LEAN_AND_MEAN`、`NOMINMAX` | 后者两个是避免 `<windows.h>` 污染 `std::min/max` |

> ⛔ **`WIN32_LEAN_AND_MEAN` / `NOMINMAX` 必须全局定义**（放在 `.props` 里）。忘记 `NOMINMAX` 会让 `<algorithm>` 的 `std::min/max` 被宏替换，报出难以理解的错误。

---

### 3.1 `vmext_contract.h` — 契约（★ C++ 轨道独有）

**职责**：把 §2.1 的常量表 + §2.2 的 initData 编解码 + §2.3 的 INI 键名 + §2.4 的报文格式，变成**一份被三个二进制共享的头文件实现**。

**不负责**：不做 IO（不读文件、不建对象）。

**API**：见 §2.0 的完整代码（`InitData` / `Build` / `Parse` / `PipeName` / `TapMutexName` / `EndPointName` / `inikey::*` / `ipc::FormatClick`）。

**`Build` / `Parse` 的实现要点**：

```cpp
bool Build(const InitData& d, std::wstring& out, std::wstring& err)
{
    // 值里禁止 ';' 与 '='。检测必须在**序列化之前**，否则会写出一个自己都解析不回来的串。
    for (const auto* v : { &d.cfg, &d.log, &d.pipe, &d.mutex }) {
        if (!v->empty() && v->find_first_of(L";=") != std::wstring::npos) {
            err = L"initData 值含保留字符 ';' 或 '=': " + *v;
            return false;
        }
    }
    out = L"ver=" + std::to_wstring(d.ver)
        + L";cfg="  + d.cfg
        + L";log="  + d.log
        + L";pipe=" + d.pipe
        + L";mutex="+ d.mutex;
    return true;
}

bool Parse(std::wstring_view s, InitData& out, std::wstring& err)
{
    out = {};
    out.ver = 0;                                  // 0 = 未见到 ver
    if (s.size() > 2048) { err = L"initData 过长"; return false; }

    size_t pos = 0;
    while (pos <= s.size()) {
        size_t end = s.find(L';', pos);
        if (end == std::wstring_view::npos) end = s.size();
        std::wstring_view kv = s.substr(pos, end - pos);
        if (!kv.empty()) {
            size_t eq = kv.find(L'=');
            if (eq != std::wstring_view::npos) {
                std::wstring key(kv.substr(0, eq));
                std::wstring val(kv.substr(eq + 1));
                if      (key == L"ver")   out.ver   = _wtoi(val.c_str());
                else if (key == L"cfg")   out.cfg   = val;
                else if (key == L"log")   out.log   = val;
                else if (key == L"pipe")  out.pipe  = val;
                else if (key == L"mutex") out.mutex = val;
                // 未知键：忽略（向前兼容，便于以后加键而不破坏老 TAP）
            }
        }
        if (end == s.size()) break;
        pos = end + 1;
    }

    if (out.ver != kInitDataVersion) {            // ★ 版本不匹配 = 两侧二进制错配 ⇒ 安全退化
        err = L"initData 版本不支持: " + std::to_wstring(out.ver);
        return false;
    }
    if (out.cfg.empty()) { err = L"initData 缺少 cfg"; return false; }
    return true;
}
```

| 设计点 | 为什么 |
|---|---|
| 未知键**忽略**而不是报错 | 以后加键时，老版本 TAP 仍能工作（向前兼容）。这是分布式协议的基本要求，虽然这里只有两个二进制 |
| `ver` 不匹配 → **返回失败**，调用方"安全退化" | 两侧二进制错配时，任何"尽力而为"都可能造成不可预期后果 |
| 长度上限 2048 | 防止异常串导致解析器长时间工作（它在 UI 线程路径上） |
| `out.ver = 0` 初值 | 用于区分"没写 ver"和"ver=0" |
| ⛔ **不要在 `Parse` 里分配大对象** | TAP 在 UI 线程上调它 |

**⭐ 单元测试（这是本轨道最大价值，见 §2.0）**：

```cpp
// tests/test_contract.cpp —— 不需要注入、不需要 ShellHost、不需要管理员
TEST(Build_Parse_RoundTrip)          // 正常往返
TEST(Build_Rejects_Semicolon)        // 值含 ';' → Build 返回 false
TEST(Build_Rejects_Equals)           // 值含 '=' → Build 返回 false
TEST(Parse_Ignores_UnknownKeys)      // 多一个 k=v 仍能解析
TEST(Parse_Rejects_WrongVersion)     // ver=99 → false
TEST(Parse_Rejects_MissingCfg)       // 没有 cfg → false
TEST(Parse_Rejects_Overlong)         // 2049 字符 → false
TEST(Parse_EmptyValue)               // "cfg=;log=x" → cfg 为空 → 沿用 MissingCfg 的判定
TEST(PipeName_And_MutexName_Format)  // 与文档 §2.1 的字面量一致（防手改）
TEST(Ipc_FormatClick_Shape)          // "CLICK id 123\n" 三段 + 换行
TEST(Ipc_UninstallLine_Shape)        // "UNINSTALL\n" 且**不含** entryId（它没有 id 参数）
```

---

### 3.2 `vmext_log.h` — 日志（共享）

**职责**：一个**进程内唯一**的日志汇。App 用它写 `app.log`；Launcher/Tap 用它写各自日志。**同一份实现**。
**不负责**：不轮转（App 侧启动时截断）、不订阅、不做日志级别以外的过滤。

```cpp
namespace vmext {

enum class LogLevel : int { Trace = 0, Debug = 1, Info = 2, Warn = 3, Error = 4, Fatal = 5 };

class Log final {
public:
    // 打开/切换日志文件。幂等：已打开时先关旧的。
    // 返回 false 表示打不开 —— 此后所有 Write 静默（★ 不抛、不弹、不影响主流程）。
    static bool Open(const std::wstring& path, LogLevel minLevel) noexcept;
    static void Close() noexcept;
    static bool IsOpen() noexcept;
    static void SetMinLevel(LogLevel lv) noexcept;

    // 单行日志。格式："<ISO8601> | <LEVEL> | t<tid> | <tag> | <msg>\r\n"
    static void Write(LogLevel lv, const char* tag, const char* fmt, ...) noexcept;
    static void WriteV(LogLevel lv, const char* tag, const char* fmt, va_list ap) noexcept;

    // 便捷封装（宽字符串版，内部转 UTF-8）
    static void WriteW(LogLevel lv, const char* tag, const std::wstring& msg) noexcept;
};

#define VLOG_TRACE(tag, ...) ::vmext::Log::Write(::vmext::LogLevel::Trace, tag, __VA_ARGS__)
#define VLOG_DEBUG(tag, ...) ::vmext::Log::Write(::vmext::LogLevel::Debug, tag, __VA_ARGS__)
#define VLOG_INFO(tag,  ...) ::vmext::Log::Write(::vmext::LogLevel::Info,  tag, __VA_ARGS__)
#define VLOG_WARN(tag,  ...) ::vmext::Log::Write(::vmext::LogLevel::Warn,  tag, __VA_ARGS__)
#define VLOG_ERR(tag,   ...) ::vmext::Log::Write(::vmext::LogLevel::Error, tag, __VA_ARGS__)

} // namespace vmext
```

| 方法 | 返回 | 异常 | 线程 | 幂等 |
|---|---|---|---|---|
| `Open` | `false` = 打不开（静默降级） | **不抛**（`noexcept`） | 任意 | 是（切换目标文件） |
| `Close` | — | 不抛 | 任意 | 是 |
| `SetMinLevel` | — | 不抛 | 任意 | 是 |
| `Write` / `WriteV` / `WriteW` | — | **不抛** | **线程安全**（内部 `CRITICAL_SECTION`） | 是 |

**实现要点（逐条都有原因）**：

```cpp
static HANDLE           g_file = INVALID_HANDLE_VALUE;
static CRITICAL_SECTION g_lock;
static bool             g_lockInit = false;
static LogLevel         g_min = LogLevel::Info;
static std::atomic<bool> g_faulted{ false };   // 写失败后置位，后续静默

void Log::WriteV(LogLevel lv, const char* tag, const char* fmt, va_list ap) noexcept
{
    // ① 早退：没打开 / 被过滤 / 已故障 —— 全部在拿锁之前，避免无谓的锁竞争
    if (g_file == INVALID_HANDLE_VALUE || g_faulted.load(std::memory_order_relaxed)) return;
    if ((int)lv < (int)g_min) return;

    char buf[1600];
    // ② 时间戳：GetLocalTime + 手写 ISO8601，不用 CRT 的 strftime（避免 locale 影响）
    SYSTEMTIME st{}; GetLocalTime(&st);
    int n = _snprintf_s(buf, _TRUNCATE,
        "%04d-%02d-%02dT%02d:%02d:%02d.%03d | %-5s | t%-5lu | %-12s | ",
        ...);
    if (n < 0) n = 0;

    // ③ 正文：_vsnprintf_s 的 _TRUNCATE 保证不溢出；返回 -1 时用 strlen 兜底
    int m = _vsnprintf_s(buf + n, sizeof(buf) - (size_t)n, _TRUNCATE, fmt, ap);
    if (m < 0) m = (int)strlen(buf + n);

    size_t len = (size_t)n + (size_t)m;
    if (len + 2 < sizeof(buf)) { buf[len++] = '\r'; buf[len++] = '\n'; }   // 保持 CRLF

    // ④ 持锁写。写失败 → 置 faulted（一次失败后不再尝试，避免刷屏与卡顿）
    EnterCriticalSection(&g_lock);
    DWORD wr = 0;
    if (!WriteFile(g_file, buf, (DWORD)len, &wr, nullptr) || wr != len)
        g_faulted.store(true, std::memory_order_relaxed);
    LeaveCriticalSection(&g_lock);
}
```

```cpp
bool Log::Open(const std::wstring& path, LogLevel minLevel) noexcept
{
    if (!g_lockInit) {                       // ④ 锁初始化要做"一次"且要线程安全
        static std::once_flag once;
        std::call_once(once, [] { InitializeCriticalSection(&g_lock); g_lockInit = true; });
    }
    EnterCriticalSection(&g_lock);
    if (g_file != INVALID_HANDLE_VALUE) { CloseHandle(g_file); g_file = INVALID_HANDLE_VALUE; }

    // ⛔ 不用 CRT 的 _wfopen / std::wofstream：
    //    本机实测 ccs=UTF-8 的 CRT 流会静默只写一个 BOM，内容全丢（见 §2.5）。
    //    FILE_SHARE_READ|WRITE 让 App 能在 TAP 持有句柄时读日志。
    g_file = CreateFileW(path.c_str(), FILE_APPEND_DATA,
                         FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                         OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    bool ok = (g_file != INVALID_HANDLE_VALUE);
    if (ok) g_faulted.store(false, std::memory_order_relaxed);
    LeaveCriticalSection(&g_lock);
    g_min = minLevel;
    return ok;
}
```

| 设计点 | 原因 |
|---|---|
| ⛔ 不用 CRT 流 | ✅ 实测：`ccs=UTF-8` 的 CRT 流静默只写 BOM，日志全丢（§2.5 坑 1） |
| `FILE_SHARE_READ \| FILE_SHARE_WRITE` | 让另一个进程能在写入方持有句柄时读日志 |
| `g_faulted` 一次性降级 | 磁盘满/权限变化时不进入"每次写都失败 + 每次都重试"的坏状态 |
| 固定 1600 字节缓冲 + `_TRUNCATE` | 日志本身不能成为崩溃源 |
| `std::call_once` 初始化锁 | `Open` 可能从多个线程第一次被调用 |
| `LogLevel` 过滤在**拿锁之前** | 减少锁竞争；TAP 的日志调用在 UI 线程路径上，必须便宜 |
| `noexcept` 全部标注 | 编译器强制我们处理完所有异常路径；调用方也不必包 try |

---

### 3.3 `vmext_ini.h` — INI 读写（共享，★ 直接消掉编码坑）

**职责**：读写 INI。**App 与 TAP 用同一份代码**，所以"写方编码假设"与"读方编码假设"不可能不一致。
**不负责**：不做配置语义校验（那是 `Orchestrator::Start` 与 TAP 的事）。

```cpp
namespace vmext {

class Ini final {
public:
    // ---- 读 ----
    // 路径不存在 / section 或 key 缺失 → 返回 def。★ 不抛。
    static std::wstring ReadString(const std::wstring& path,
                                  const wchar_t* section, const wchar_t* key,
                                  const wchar_t* def) noexcept;
    static int ReadInt(const std::wstring& path,
                       const wchar_t* section, const wchar_t* key, int def) noexcept;

    // ---- 写 ----
    struct Line {
        std::wstring section;    // 空 = 沿用上一条的 section
        std::wstring key;
        std::wstring value;
        bool         comment = false;   // true 时 key 字段当作注释正文整行写出
    };
    // 整文件重写（不是追加）。编码固定 UTF-16LE + BOM（见下）。
    static bool WriteAll(const std::wstring& path,
                         const std::vector<Line>& lines,
                         std::wstring& err) noexcept;

    // ---- 自检（启动时用）----
    static bool SelfTest(std::wstring& err) noexcept;
};

} // namespace vmext
```

| 方法 | 返回值 | 异常 | 说明 |
|---|---|---|---|
| `ReadString` / `ReadInt` | 值或 `def` | **不抛**（`noexcept`） | 内部 `GetPrivateProfileStringW` |
| `WriteAll` | `true` 成功；`false` 时 `err` 有原因 | 不抛 | 整文件重写，**先用临时文件 + `MoveFileExW(REPLACE_EXISTING)`** 实现原子替换 |
| `SelfTest` | 写一个临时 INI（含中文值）→ 读回比对 → 删掉 | 不抛 | ⭐ **在真机上验证编码假设**，见下 |

**读实现**：

```cpp
std::wstring Ini::ReadString(const std::wstring& path, const wchar_t* section,
                            const wchar_t* key, const wchar_t* def) noexcept
{
    wchar_t buf[1024] = {};
    // ⛔ 必须传**绝对路径**。传相对路径时 GetPrivateProfileStringW 会去做
    //    "系统目录/Windows 目录"的搜索，行为不可预期且可能被缓存。
    DWORD n = GetPrivateProfileStringW(section, key, def, buf, _countof(buf), path.c_str());
    if (n == 0 && def) return def;      // 注意：值为空串时 n 也是 0，所以用 def 兜底
    return std::wstring(buf, n);
}
```

**写实现（关键：编码）**：

```cpp
bool Ini::WriteAll(const std::wstring& path, const std::vector<Line>& lines, std::wstring& err) noexcept
{
    // ① 先在内存里拼完整内容
    std::wstring body;
    std::wstring curSection;
    for (const auto& l : lines) {
        if (l.comment) { body += L"; " + l.key + L"\r\n"; continue; }
        if (!l.section.empty() && l.section != curSection) {
            if (!body.empty()) body += L"\r\n";
            body += L"[" + l.section + L"]\r\n";
            curSection = l.section;
        }
        body += l.key + L"=" + l.value + L"\r\n";
    }

    // ② 原子写：临时文件 → ReplaceFile/MoveFileEx。避免写一半崩了留下坏配置。
    std::wstring tmp = path + L".tmp";
    UniqueHandle h(CreateFileW(tmp.c_str(), GENERIC_WRITE, 0, nullptr,
                               CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr));
    if (!h) { err = L"无法创建临时文件: " + tmp; return false; }

    DWORD wr = 0;
    const WORD kBom = 0xFEFF;                       // UTF-16LE BOM
    if (!WriteFile(h.get(), &kBom, sizeof(kBom), &wr, nullptr)) { err = L"写 BOM 失败"; return false; }
    if (!WriteFile(h.get(), body.data(), (DWORD)(body.size() * sizeof(wchar_t)), &wr, nullptr)) {
        err = L"写内容失败"; return false;
    }
    h.reset();                                       // 先关句柄再替换（MoveFileEx 需要）

    if (!MoveFileExW(tmp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING)) {
        err = L"替换文件失败: " + path; DeleteFileW(tmp.c_str()); return false;
    }
    return true;
}
```

**⭐ 为什么用 UTF-16LE + BOM**（✅ 2026-10-03 实测确认，见 `verified-after-injection/09-ini-encoding.md`）：

| 方案 | 实测结果 |
|---|---|
| UTF-8 无 BOM | ❌ **静默乱码**：节名/key 是 ASCII 所以**键能匹配上**，但中文值被按系统 ACP 解读 ⇒ 读到一串错码点。`\u97F3\u91CF…` 变成 `\u95CA\u62BD…` |
| UTF-8 带 BOM | ❌ **连键都找不到**：BOM 字节（EF BB BF）污染了第一个节名 `[t]` ⇒ 返回缺省值 ⇒ **设置被静默忽略**（比乱码更隐蔽：界面显示默认文本，没人会想到是编码问题） |
| UTF-16LE **无** BOM | ❌ 被当 ANSI 读 ⇒ 乱码 |
| 系统 ACP（GBK） | ⚠️ 本机正确，**只因本机 ACP=936**。换区域设置就坏 ⇒ 不可作为契约 |
| **UTF-16LE + BOM**（采用） | ✅ **唯一与系统区域设置无关的正确写法**；7 个中文字码点逐位一致 |

⚠️ **不能只靠推理**：`Ini::SelfTest()` 在启动自检里真的跑一次"写含中文的 INI → 读回比对"。这样即使在某个特殊系统上这个假设不成立，也会在**启动时**明确报错，而不是在用户看到乱码按钮时才暴露。

**★ 写侧还有一个坑（实测）**：`WritePrivateProfileStringW` **对全新文件会写成 ANSI**（不带 UTF-16 BOM，本机是 GBK 字节）—— 对**已带 BOM** 的文件它才会保持 UTF-16LE。
⇒ 所以 `Ini::WriteAll` **必须自己写 BOM 与 UTF-16LE 字节**，**不能**图省事把整个写侧委托给
`WritePrivateProfileStringW`。后者只适合"文件已存在且已是 UTF-16LE"时的改键。
这也正是 C++ 轨道把 `Ini::Write` 做成"唯一写入口"的价值：这个坑只需要在一个地方挡掉。

**`SelfTest` 的返回纳入启动自检**（§7.6 第 10 项）。

---

### 3.4 `vmext_str.h` — 字符串与路径工具（共享）

```cpp
namespace vmext::str {

// 本 DLL/EXE 所在目录（不含尾部反斜杠）。由 GetModuleFileNameW(hSelf) 得到。
std::wstring ModuleDir(HMODULE hSelf) noexcept;

// 若 b 是相对路径 → 拼到 a 后面；否则原样返回 b
std::wstring ResolveRelative(const std::wstring& a, const std::wstring& b) noexcept;

std::wstring Join(const std::wstring& a, const std::wstring& b) noexcept;
bool         FileExists(const std::wstring& p) noexcept;
std::optional<unsigned long long> FileSize(const std::wstring& p) noexcept;
std::optional<FILETIME>           LastWriteTime(const std::wstring& p) noexcept;   // 健康检查用

// 格式化（宽字符版，内部固定缓冲 + 截断）
std::wstring Format(const wchar_t* fmt, ...) noexcept;

std::string  WideToUtf8(std::wstring_view w) noexcept;
std::wstring Utf8ToWide(std::string_view s) noexcept;

std::vector<std::wstring> Split(std::wstring_view s, wchar_t sep) noexcept;
std::wstring              Trim(std::wstring_view s) noexcept;
std::wstring              ToLower(std::wstring_view s) noexcept;

// ★ 校验：路径里不能含 ';' 或 '='（initData 契约，§2.2）
bool ContainsReservedChars(std::wstring_view s) noexcept;

// 进程名比较（大小写不敏感，"ShellHost.exe" vs "shellhost.exe"）
bool EqualsNoCase(std::wstring_view a, std::wstring_view b) noexcept;

} // namespace vmext::str
```

| 注意 | 说明 |
|---|---|
| `ModuleDir(HMODULE)` 必须接受 HMODULE 参数 | in-proc 的 DllMain 里用 `g_self`；App 里用 `GetModuleHandleW(nullptr)`。**不要**用 `GetCurrentDirectory`（从快捷方式启动时可能是别的地方） |
| `WideToUtf8` 的返回值用 `std::string` | 日志与 IPC 报文都用 UTF-8；避免 CRT 的 locale 依赖（`wcstombs` 会受 `setlocale` 影响） |
| `ContainsReservedChars` 单独一个函数 | 让 `Contract::Build` 与启动自检复用同一个判定 |

---

### 3.5 `vmext_win32.h` — RAII 与枚举（共享）

**职责**：把"忘记 `CloseHandle`"这类错误从**纪律问题**变成**类型问题**。C++ 轨道的第 7 项劣势（§1.0）主要靠这个头文件缓解。

```cpp
namespace vmext::win32 {

class UniqueHandle {
public:
    UniqueHandle() noexcept = default;
    explicit UniqueHandle(HANDLE h) noexcept : h_(h) {}
    ~UniqueHandle() { reset(); }
    UniqueHandle(UniqueHandle&& o) noexcept : h_(o.release()) {}
    UniqueHandle& operator=(UniqueHandle&& o) noexcept {
        if (this != &o) reset(o.release());
        return *this;
    }
    UniqueHandle(const UniqueHandle&) = delete;
    UniqueHandle& operator=(const UniqueHandle&) = delete;

    HANDLE get() const noexcept { return h_; }
    explicit operator bool() const noexcept { return h_ != nullptr && h_ != INVALID_HANDLE_VALUE; }
    HANDLE release() noexcept { HANDLE t = h_; h_ = nullptr; return t; }
    void reset(HANDLE h = nullptr) noexcept {
        if (h_ && h_ != INVALID_HANDLE_VALUE) CloseHandle(h_);
        h_ = h;
    }
private:
    HANDLE h_ = nullptr;
};

// 需要不同 Close 函数的，用同一模式特化（模板避免复制粘贴出错）
template <class Traits> class UniqueResource { /* ... */ };

struct RegKeyTraits  { using type = HKEY;   static void Close(HKEY h)   noexcept { RegCloseKey(h); }  static constexpr HKEY Invalid = nullptr; };
struct FindTraits    { using type = HANDLE; static void Close(HANDLE h) noexcept { FindClose(h); }    static constexpr HANDLE Invalid = INVALID_HANDLE_VALUE; };
struct SnapTraits    { using type = HANDLE; static void Close(HANDLE h) noexcept { CloseHandle(h); }  static constexpr HANDLE Invalid = INVALID_HANDLE_VALUE; };
struct ModuleTraits  { using type = HMODULE;static void Close(HMODULE h)noexcept { FreeLibrary(h); } static constexpr HMODULE Invalid = nullptr; };

using UniqueRegKey    = UniqueResource<RegKeyTraits>;
using UniqueFind      = UniqueResource<FindTraits>;
using UniqueSnapshot  = UniqueResource<SnapTraits>;
using UniqueModule    = UniqueResource<ModuleTraits>;

// ---- 枚举工具（内部用上面两个 RAII 类型，调用方拿不到裸句柄）----
// 回调返回 false 表示提前停止。
bool ForEachProcess(const std::function<bool(const PROCESSENTRY32W&)>& fn) noexcept;
bool ForEachModule(DWORD pid, const std::function<bool(const MODULEENTRY32W&)>& fn) noexcept;

} // namespace vmext::win32
```

**实现要点**：

```cpp
bool ForEachProcess(const std::function<bool(const PROCESSENTRY32W&)>& fn) noexcept
{
    UniqueSnapshot snap(CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0));
    if (!snap) return false;
    PROCESSENTRY32W pe{}; pe.dwSize = sizeof(pe);
    if (!Process32FirstW(snap.get(), &pe)) return false;
    do { if (!fn(pe)) break; } while (Process32NextW(snap.get(), &pe));
    return true;
}
```

| 陷阱 | 说明 |
|---|---|
| ⛔ `PROCESSENTRY32W::dwSize` 必须**在每次调用前**设置 | 唯一常见的"快照 API 第一次就失败"的原因 |
| 句柄比较：`INVALID_HANDLE_VALUE` 是 `(HANDLE)-1`，不是 `nullptr` | `UniqueHandle` 的 `operator bool` 两个都要判 |
| `ForEachModule` 需要 `TH32CS_SNAPMODULE \| TH32CS_SNAPMODULE32` | 只传前者在有 32 位模块的进程里会失败 |
| `/W4 /WX` 下 `std::function` 的构造可能触发 C4267 等 | 回调签名统一用引用传递的结构体 |

---

### 3.6 `vmext_locator.h` — 目标进程定位

```cpp
namespace vmext {

struct ShellHostInfo {
    DWORD        pid        = 0;
    DWORD        sessionId  = 0;
    ULONGLONG    startTimeUtc = 0;   // FILETIME 折算成毫秒（自 1601），仅用于日志/去重
    std::wstring imagePath;          // 可能为空（权限不足时）
};

class ShellHostLocator final {
public:
    static DWORD CurrentSessionId() noexcept;

    // 全部会话的 ShellHost（含其它登录用户）。失败返回空 vector，★ 不抛。
    static std::vector<ShellHostInfo> FindAll() noexcept;

    // 只要本会话的
    static std::vector<ShellHostInfo> FindInSession(DWORD sessionId) noexcept;

    // 指定 pid 是否仍是本会话的 ShellHost
    static std::optional<ShellHostInfo> FindById(DWORD pid, DWORD sessionId) noexcept;
};

} // namespace vmext
```

| 方法 | 返回 | 异常 | 备注 |
|---|---|---|---|
| `CurrentSessionId` | 本进程 session | 不抛 | `ProcessIdToSessionId(GetCurrentProcessId(), &s)`；缓存 |
| `FindAll` | 可能为空 | 不抛 | 逐条容错：单条查询失败只跳过它 |
| `FindInSession` | 可能为空 | 不抛 | **业务用这个** |
| `FindById` | `nullopt` | 不抛 | 健康检查用 |

**实现要点**：

```cpp
std::vector<ShellHostInfo> ShellHostLocator::FindAll() noexcept
{
    std::vector<ShellHostInfo> out;
    win32::ForEachProcess([&](const PROCESSENTRY32W& pe) {
        // 名字比较：进程快照给的是 "shellhost.exe"（原始大小写），要大小写不敏感比
        if (!str::EqualsNoCase(pe.szExeFile, contract::kTargetProcessExe)) return true;

        ShellHostInfo info;
        info.pid = pe.th32ProcessID;
        // 会话：ProcessIdToSessionId 对已退出进程会失败 → 跳过
        DWORD s = 0;
        if (!ProcessIdToSessionId(info.pid, &s)) return true;
        info.sessionId = s;
        // 启动时间：GetProcessTimes；失败给 0，不致命
        {   UniqueHandle h(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, info.pid));
            if (h) { FILETIME c{}, e{}, k{}, u{};
                     if (GetProcessTimes(h.get(), &c, &e, &k, &u)) info.startTimeUtc = ToMillis(c); }
        }
        // 映像路径：QueryFullProcessImageNameW（比 GetModuleFileNameEx 更省权限）
        {   wchar_t buf[MAX_PATH] = {}; DWORD n = MAX_PATH;
            UniqueHandle h(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, info.pid));
            if (h && QueryFullProcessImageNameW(h.get(), 0, buf, &n)) info.imagePath = buf;
        }
        out.push_back(std::move(info));
        return true;
    });
    return out;
}
```

| 设计点 | 原因 |
|---|---|
| 名字比较**大小写不敏感** | 进程快照的大小写不保证 |
| 每个进程单独开句柄、**用完即关**（RAII） | 避免句柄堆积；也避免一次性开太多 |
| 用 `PROCESS_QUERY_LIMITED_INFORMATION` 而不是 `QUERY_INFORMATION` | 前者权限要求更低，且足够拿时间与路径 |
| ⛔ **不要只取第一个结果** | 多用户机器上同时存在多个 ShellHost 是正常的，必须按 session 过滤 |
| 单条失败只跳过 | 别的会话的进程可能拒绝访问，不能因此整次扫描失败 |

---

### 3.7 `vmext_watcher.h` — ShellHost 生命周期监视

**职责**：长时间、**接近 0 CPU** 地监视 ShellHost 的产生与消亡。
**不负责**：不执行注入（§3.11 的事）。

```cpp
namespace vmext {

class ShellHostWatcher final {
public:
    using StartedFn = std::function<void(const ShellHostInfo&)>;
    using ExitedFn  = std::function<void(DWORD pid)>;

    explicit ShellHostWatcher(DWORD newProcessPollGapMs = 500) noexcept;
    ~ShellHostWatcher();                                  // 自动 Stop

    ShellHostWatcher(const ShellHostWatcher&) = delete;
    ShellHostWatcher& operator=(const ShellHostWatcher&) = delete;

    // 起线程。幂等：已运行则返回 true。
    // ★ 会立刻对新线程做一次全量扫描，为**已存在**的 ShellHost 触发 onStarted
    //    —— 这样"App 晚启动"的场景不需要额外代码路径。
    bool Start(StartedFn onStarted, ExitedFn onExited) noexcept;
    void Stop() noexcept;                                 // 阻塞直到线程退出
    bool IsRunning() const noexcept;

private:
    void ThreadMain(std::stop_token st);

    DWORD                     pollGapMs_;
    std::jthread              thread_;
    std::atomic<bool>         running_{ false };
    StartedFn                 onStarted_;
    ExitedFn                  onExited_;
};

} // namespace vmext
```

| 方法 | 线程 | 副作用 | 幂等 |
|---|---|---|---|
| `Start` | 任意 | 起 `std::jthread`；回调在**该线程**上触发 | 是 |
| `Stop` | 任意 | 请求停止并 `join`；**会阻塞到线程真正退出** | 是 |
| `IsRunning` | 任意 | 无 | — |

**`ThreadMain` 的完整逻辑（本类全部价值）**：

```cpp
void ShellHostWatcher::ThreadMain(std::stop_token st)
{
    // 每个被监视的 ShellHost 一个进程句柄（只为 WaitForMultipleObjects 等它退出）
    struct Tracked { DWORD pid; UniqueHandle handle; };
    std::vector<Tracked> alive;

    // 供 WaitForMultipleObjects 用的句柄数组。索引 0 是"停止事件"。
    // 用 CreateEventW 而不是 std::stop_token 轮询：这样等待是真正的阻塞。
    UniqueHandle stopEvent(CreateEventW(nullptr, TRUE, FALSE, nullptr));

    auto rebuild = [&]() {
        handles_.assign(1, stopEvent.get());
        for (auto& t : alive) handles_.push_back(t.handle.get());
    };

    // ---- 首次全量扫描：为已存在的 ShellHost 触发 onStarted ----
    for (auto& p : ShellHostLocator::FindInSession(ShellHostLocator::CurrentSessionId())) {
        UniqueHandle h(OpenProcess(SYNCHRONIZE, FALSE, p.pid));
        if (!h) continue;
        alive.push_back({ p.pid, std::move(h) });
        rebuild();
        onStarted_(p);                       // ★ 已经存在的也通知
    }

    while (!st.stop_requested()) {
        if (!alive.empty()) {
            // ★ 阻塞等待任一 ShellHost 退出。5s 超时只是为了有机会检查 stop。
            DWORD r = WaitForMultipleObjects((DWORD)handles_.size(), handles_.data(),
                                             FALSE, 5000);
            if (r == WAIT_TIMEOUT) continue;
            if (r == WAIT_OBJECT_0) break;                       // 停止事件
            if (r == WAIT_FAILED)  { Sleep(100); continue; }     // 罕见：句柄被别处关了

            size_t idx = r - WAIT_OBJECT_0;                      // 1..N
            DWORD pid = alive[idx - 1].pid;
            onExited_(pid);
            alive.erase(alive.begin() + (idx - 1));
            rebuild();
        } else {
            // 一个都没有：只能低速轮询（此时是短暂的，ShellHost 很快会出现）
            if (stopEvent) WaitForSingleObject(stopEvent.get(), pollGapMs_);
            for (auto& p : ShellHostLocator::FindInSession(ShellHostLocator::CurrentSessionId())) {
                if (std::any_of(alive.begin(), alive.end(),
                                [&](const Tracked& t){ return t.pid == p.pid; })) continue;
                UniqueHandle h(OpenProcess(SYNCHRONIZE, FALSE, p.pid));
                if (!h) continue;
                alive.push_back({ p.pid, std::move(h) });
                rebuild();
                onStarted_(p);
            }
        }
    }

    if (stopEvent) SetEvent(stopEvent.get());
    alive.clear();          // RAII 关掉所有进程句柄
}
```

```cpp
void ShellHostWatcher::Stop() noexcept
{
    if (!thread_.joinable()) return;
    thread_.request_stop();
    // 需要唤醒可能正阻塞在 WaitForMultipleObjects 的线程 —— 见下
    if (stopEventShared_) SetEvent(stopEventShared_.get());
    thread_.join();
    running_.store(false);
}
```

| 设计点 | 原因 |
|---|---|
| ⭐ 用 `WaitForMultipleObjects` 等**进程句柄**，不轮询 | ✅ 空闲 0 CPU。轮询进程列表空闲时也是每秒几十次系统调用 |
| 分"有活着的"与"一个都没有"两条路径 | 有活着的 → 等句柄（高效）；没有 → 只能轮询（短暂状态） |
| `timeout = 5000` 而非 `INFINITE` | 让循环有机会检查 `stop_requested`（另外还有 stop 事件，双保险） |
| 首次全量扫描也触发 `onStarted` | App 晚启动时不需要第二套代码路径。这是产品行为，与实现语言无关 |
| 停止事件放在数组索引 0 | `WaitForMultipleObjects` 返回值的索引语义直观；`Stop()` 里 `SetEvent` 能立刻打断阻塞 |
| ⛔ 事件必须是**手动重置**（`CreateEventW(..., TRUE, ...)`） | 自动重置事件在多个等待者下会被吃掉 |
| ⚠️ **`WaitForMultipleObjects` 上限 64 个句柄** | 正常只有 1 个 ShellHost；但要在 `handles_.size() >= 60` 时清理已退出项并重建数组 |
| 回调在 watcher 线程触发 | **订阅者必须自己切线程**。`Orchestrator::TryInject` 会做 IO（打开进程、写 ini、注入）—— 它必须在 watcher 线程上串行执行（**恰好**，见 §3.11），但**绝不能**在主线程（UI）上执行 |

---

### 3.8 `vmext_injector.h` — 远程注入

**职责**：把一个原生 DLL 注入目标进程。（**唯一的侵入性动作**）

```cpp
namespace vmext::inject {

enum class Error {
    None = 0,
    TargetGone,              // 进程已退出
    OpenProcessFailed,       // 权限/不存在（看 win32）
    AllocFailed,
    WriteFailed,
    ModuleBaseFailed,        // 远程 kernel32 基址取不到
    RemoteResolverFailed,    // 本地导出地址取不到 / DLL 路径不合法
    ThreadCreateFailed,
    ThreadTimeout,
    RemoteLoadReturnedNull,  // 注入成功但 LoadLibraryW 返回 NULL（DLL 自身没加载起来）
};

struct Result {
    Error error = Error::None;
    DWORD win32 = 0;
    void* remoteModule = nullptr;         // 非空 = 远程 HMODULE

    bool        ok() const noexcept { return error == Error::None; }
    const char* Name() const noexcept;    // 供日志用
};

// 注入。timeoutMs 是等远程线程的上限（不是"注入耗时"）。
Result InjectInto(DWORD pid, const std::wstring& dllAbsolutePath, DWORD timeoutMs) noexcept;

// 目标进程里某模块的加载基址（Toolhelp32）。失败返回 nullptr。
void* RemoteModuleBase(DWORD pid, const wchar_t* moduleName) noexcept;

} // namespace vmext::inject
```

**完整实现（本轨道最需要照抄的一段）**：

```cpp
Result InjectInto(DWORD pid, const std::wstring& dllAbsolutePath, DWORD timeoutMs) noexcept
{
    Result r;

    // 0) 前置校验：路径必须绝对且存在（CreateRemoteThread 里无法给相对路径）
    wchar_t full[32768] = {};
    if (!GetFullPathNameW(dllAbsolutePath.c_str(), _countof(full), full, nullptr) ||
        GetFileAttributesW(full) == INVALID_FILE_ATTRIBUTES) {
        r.error = Error::RemoteResolverFailed;
        r.win32 = GetLastError();
        return r;
    }

    const DWORD access = PROCESS_CREATE_THREAD | PROCESS_VM_OPERATION | PROCESS_VM_WRITE
                       | PROCESS_VM_READ | PROCESS_QUERY_INFORMATION | SYNCHRONIZE;

    UniqueHandle hProc(OpenProcess(access, FALSE, pid));
    if (!hProc) {
        r.win32 = GetLastError();
        // ⭐ ERROR_INVALID_PARAMETER(87) 是"进程已退出"的实际信号（不是 ERROR_NOT_FOUND）。
        //    不映射的话，编排器会对一个已死的 pid 反复重试。
        r.error = (r.win32 == ERROR_INVALID_PARAMETER) ? Error::TargetGone
                                                       : Error::OpenProcessFailed;
        return r;
    }

    // 1) 把 DLL 路径（UTF-16 + NUL）写进目标进程
    const size_t bytes = (wcslen(full) + 1) * sizeof(wchar_t);
    void* remote = VirtualAllocEx(hProc.get(), nullptr, bytes,
                                 MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!remote) { r.error = Error::AllocFailed; r.win32 = GetLastError(); return r; }

    // 用 RAII 保证异常/早退路径也释放远程内存
    struct RemoteFree {
        HANDLE p; void* a;
        ~RemoteFree() { if (a) VirtualFreeEx(p, a, 0, MEM_RELEASE); }
    } guard{ hProc.get(), remote };

    SIZE_T written = 0;
    if (!WriteProcessMemory(hProc.get(), remote, full, bytes, &written)) {
        r.error = Error::WriteFailed; r.win32 = GetLastError(); return r;
    }

    // 2) ⭐ 远程 LoadLibraryW 地址 = 远程 kernel32 基址 + 本地算出的 RVA
    //    ⛔ 不要直接把本进程的 LoadLibraryW 地址当远程地址用 —— 见下方说明框。
    void* remoteK32 = RemoteModuleBase(pid, L"kernel32.dll");
    if (!remoteK32) { r.error = Error::ModuleBaseFailed; r.win32 = GetLastError(); return r; }

    HMODULE localK32 = GetModuleHandleW(L"kernel32.dll");
    FARPROC localFn  = GetProcAddress(localK32, "LoadLibraryW");
    if (!localK32 || !localFn) { r.error = Error::RemoteResolverFailed; return r; }

    const auto rva = reinterpret_cast<uintptr_t>(localFn) - reinterpret_cast<uintptr_t>(localK32);
    auto remoteFn = reinterpret_cast<LPTHREAD_START_ROUTINE>(
                        reinterpret_cast<uintptr_t>(remoteK32) + rva);

    // 3) 远程线程执行 LoadLibraryW(path)
    UniqueHandle hThread(CreateRemoteThread(hProc.get(), nullptr, 0, remoteFn, remote, 0, nullptr));
    if (!hThread) { r.error = Error::ThreadCreateFailed; r.win32 = GetLastError(); return r; }

    // 4) 等它完成（LoadLibraryW 会跑目标 DLL 的 DllMain，我们等的其实是"DllMain 返回"）
    DWORD w = WaitForSingleObject(hThread.get(), timeoutMs);
    if (w != WAIT_OBJECT_0) { r.error = Error::ThreadTimeout; return r; }

    // 5) 返回值就是远程 HMODULE；为 0 说明 LoadLibraryW 失败（DLL 没加载起来）
    DWORD ec = 0;
    if (!GetExitCodeThread(hThread.get(), &ec) || ec == 0) {
        r.error = Error::RemoteLoadReturnedNull;
        r.win32 = GetLastError();
        return r;
    }

    r.error = Error::None;
    r.remoteModule = reinterpret_cast<void*>(static_cast<uintptr_t>(ec));
    return r;
}
```

```cpp
void* RemoteModuleBase(DWORD pid, const wchar_t* moduleName) noexcept
{
    void* base = nullptr;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, pid);
    if (snap == INVALID_HANDLE_VALUE) return nullptr;
    MODULEENTRY32W me{}; me.dwSize = sizeof(me);
    if (Module32FirstW(snap, &me)) {
        do {
            if (str::EqualsNoCase(me.szModule, moduleName)) { base = me.modBaseAddr; break; }
        } while (Module32NextW(snap, &me));
    }
    CloseHandle(snap);
    return base;
}
```

> **⛔ 为什么必须"本地 RVA + 远程基址"，不能直接用本地地址**（这一段是踩坑总结，很多注入器示例是错的）：
>
> 常见错误写法：`GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "LoadLibraryW")` 拿到**本进程**的地址，直接当远程地址用。
> ASLR 原则上让每个进程的模块基址独立。实践里系统 DLL（尤其 kernel32）在同一 boot 上**往往恰好**同基址 ——
> PoC 就是这么写的并且成功了，但这是**巧合而非保证**（换 IL、开强制 ASLR、不同 boot 都可能失效）。
>
> 正确算法只依赖"同一份 kernel32 在同一台机器上的导出表布局一致"，这在**同架构同 boot** 下成立。

**必须知道的四件事**：

1. **`LoadLibraryW` 在 `DllMain` 里是受限的**。所以 `VmExt.Launcher.dll` 的 `DllMain` **只做一件事**：`CreateThread(Worker)` 然后立刻返回（✅ PoC 就是这么做的）。
2. **超时 20s 是给 `WaitForSingleObject` 的上限，不是"注入耗时"**。实测注入返回是**毫秒级**。超时通常意味着目标进程的 loader lock 被别人占着。
3. **`RemoteFree` 这种"局部 RAII 守卫"是 C++ 轨道必须养成的习惯**。上面 6 个早退路径里只要有 1 个忘了 `VirtualFreeEx`，每次重试就泄漏一块远程内存。
4. `r.remoteModule` 非空不代表 TAP 就绪 —— 只代表 DLL 加载成功。TAP 就绪由 `TapProbe` 判断（§3.10）。

**测试要点**（不需要真的注入 shell）：

```cpp
TEST(Inject_Into_DummyProcess_Succeeds)     // 起一个自建靶进程，注入一个空 DLL
TEST(Inject_NonexistentDll_Returns_RemoteLoadReturnedNull)
TEST(Inject_DeadPid_Returns_TargetGone)     // 起进程→杀→立刻注入（覆盖 ERROR_INVALID_PARAMETER 映射）
TEST(RemoteModuleBase_Kernel32_NonZero)
TEST(Result_Name_Table_Exhaustive)          // 每个 Error 都有非空的 Name()（防止日志打出 "(null)"）
```

---

### 3.9 `vmext_diaglocator.h` — 诊断运行时定位

**职责**：找到 SDK 里的 `xamldiagnostics.dll`（**不是我们的文件，不随包分发**）。

```cpp
namespace vmext {

struct DiagnosticsRuntime {
    std::wstring path;
    std::wstring source;      // "explicit" / "env" / "registry" / "commonpath" / "fallback"
};

class DiagnosticsRuntimeLocator final {
public:
    // explicitPath 非空时只用它；不存在则返回 nullopt（★ 不静默回退）
    static std::optional<DiagnosticsRuntime> Locate(const std::wstring& explicitPath) noexcept;

    // "我找过哪些地方"（多行文本），直接展示给用户
    static std::wstring DescribeSearchFailure() noexcept;

private:
    static std::optional<std::wstring> FromEnv() noexcept;
    static std::optional<std::wstring> FromRegistry() noexcept;
    static std::optional<std::wstring> FromCommonPaths() noexcept;
    static std::optional<std::wstring> FromKnownPath() noexcept;
    static std::optional<std::wstring> PickHighestVersion(const std::wstring& binRoot) noexcept;
};

} // namespace vmext
```

**探测顺序**：

| 顺序 | Source | 具体 |
|---|---|---|
| 1 | `explicit` | `vmext.ini` 的 `diagnostics_dll`。非空但不存在 → **返回 `nullopt` 并报错**（用户明确指了路径却不对，静默回退会让人困惑） |
| 2 | `env` | `%WindowsSdkDir%bin\%WindowsSDKVersion%x64\XamlDiagnostics\xamldiagnostics.dll` |
| 3 | `registry` | `HKLM\SOFTWARE\Microsoft\Windows Kits\Installed Roots` → `KitsRoot10` → `bin\*\x64\XamlDiagnostics\...` |
| 4 | `commonpath` | `%ProgramFiles(x86)%\Windows Kits\10\bin\*\x64\XamlDiagnostics\...` |
| 5 | `fallback` | `C:\Program Files (x86)\Windows Kits\10\bin\x64\XamlDiagnostics\xamldiagnostics.dll`（✅ PoC 用的就是这条） |

**实现要点**：

```cpp
std::optional<std::wstring> DiagnosticsRuntimeLocator::PickHighestVersion(const std::wstring& binRoot) noexcept
{
    // binRoot = "...\Windows Kits\10\bin"
    std::wstring pattern = binRoot + L"\\*";
    WIN32_FIND_DATAW fd{};
    UniqueFind find(FindFirstFileW(pattern.c_str(), &fd));
    if (!find) return std::nullopt;

    // 版本号最大的那个目录。★ 用 GetFileVersionInfo 太慢也没必要 —— 目录名就是 "10.0.26100.0"
    std::optional<std::pair<ULONGLONG, std::wstring>> best;
    do {
        if (!(fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) continue;
        ULONGLONG key = VersionKey(fd.cFileName);        // "10.0.26100.0" → 排序键
        if (key == 0) continue;
        std::wstring p = binRoot + L"\\" + fd.cFileName + L"\\x64\\XamlDiagnostics\\" + contract::kDiagnosticsDllName;
        if (!str::FileExists(p)) continue;
        if (!best || key > best->first) best = { key, p };
    } while (FindNextFileW(find.get(), &fd));

    return best ? std::optional<std::wstring>(best->second) : std::nullopt;
}
```

| 设计点 | 原因 |
|---|---|
| ⭐ `%ProgramFiles(x86)%` 用 `SHGetKnownFolderPath(FOLDERID_ProgramFilesX86)` | 硬编码 `C:\Program Files (x86)` 在非 C 盘或本地化系统上会错 |
| 版本比较用目录名解析，不用 `GetFileVersionInfo` | 目录名就是版本号，省一次文件打开；解析失败则跳过该目录 |
| ⛔ 只做**存在性**判断，不 `LoadLibrary` 验证 | 只有目标进程那一侧才能确认真能被那侧的 XAML core 加载。在这里验证会引入一次无意义的加载（而且会把 DLL 加载进**我们的**进程） |
| `DescribeSearchFailure()` 输出每条尝试的路径与结果 | **这是最常见的部署失败**，含糊的报错会浪费大量时间 |
| ⚠️ **版本兼容性未验证** | ✅ PoC 实测：SDK 10.0.14393.33 的 `xamldiagnostics.dll` 配 `Windows.UI.Xaml.dll` 10.0.26100.8972 **可用**。跨系统大版本更新后必须重跑 V1 |

---

### 3.10 `vmext_tapprobe.h` — TAP 心跳探测

**职责**：判断某个 ShellHost 里**是否已经有一个活着的 TAP**。这是幂等注入的唯一依据。

```cpp
namespace vmext {

class TapProbe final {
public:
    // 打开一个内核对象，~µs。TAP 在 SetSite 成功后才创建它。
    static bool IsAlive(DWORD shellHostPid) noexcept;

    // 轮询等待（50ms 间隔）。总超时由调用方给。
    static bool WaitUntilAlive(DWORD shellHostPid, DWORD timeoutMs) noexcept;

    // ★ 唤醒/等待辅助：TAP 就绪是"瞬间"事件，但也可能永远不来，
    //    所以用轮询而不是事件 —— 见下方"为什么不用事件"。
};

} // namespace vmext
```

**原理**：TAP 在 `SetSite` 里成功拿到 `IXamlDiagnostics`/`IVisualTreeService` 之后，**创建并长期持有一个命名互斥体**：

```text
CreateMutexW(nullptr, FALSE, L"Local\\VmExt.Tap.Singleton.<pid>")
  GetLastError() == ERROR_ALREADY_EXISTS
     → 本实例是重复注入：记日志，置 dormant，**不 advise、不注入**
  否则持有句柄到进程退出
```

App 侧 `OpenMutexW(SYNCHRONIZE, FALSE, name) != nullptr` 即"TAP 活着"。`Local\` 命名空间 = 会话隔离，正好匹配"只关心本会话"。

| 实现 | 说明 |
|---|---|
| `IsAlive` | `UniqueHandle h(OpenMutexW(SYNCHRONIZE, FALSE, name.c_str())); return (bool)h;` |
| `WaitUntilAlive` | `GetTickCount64()` 循环 + `Sleep(50)` |
| ⛔ **不要用 `WaitForSingleObject` 等互斥体** | TAP 是**持有者**而不是释放者。等它会被立刻满足（因为互斥体是"有信号"状态），给出错误的正面结论 |

**为什么用内核对象而不是文件/管道探测**：

| 载体 | 优点 |
|---|---|
| **命名互斥体**（采用） | 进程退出后**自动消失**（文件会留下假阳性）；探测成本 ~µs；不可能被误删；⭐ **同时解决重复注入** |
| 心跳文件 | ShellHost 崩溃后文件还在 → 假阳性 |
| 管道探测 | 需要 App 侧服务端在线，且 TAP 侧要处理连接失败 |

⛔ **注意"TAP 活着"≠"按钮已注入"**。`IsAlive` 只说明 TAP 在跑。用户看到的按钮是否存在，取决于 TAP 的 `enabled` 配置与 `Footer` 是否真的出现。UI 上要区分这两个状态（§3.14）。

---

### 3.11 `vmext_orchestrator.h` — 编排（产品的大脑）

**职责**：把 §3.6–§3.10 串成**幂等、可恢复、有状态**的流程。

```cpp
namespace vmext {

enum class State { Stopped = 0, LocatingRuntime, WaitingForShellHost, Injecting, WaitingForTap, Ready, Faulted };

struct AppConfig {
    bool                     enabled = true;
    std::wstring             diagnosticsDll;          // 空 = 自动探测
    LogLevel                 logLevel = LogLevel::Info;
    std::vector<EntryConfig> entries;
};
struct EntryConfig {
    std::wstring id, text, action, exe, args;
    int inset = 4, height = 0;
};

class Orchestrator final {
public:
    using StateFn = std::function<void(State)>;

    Orchestrator(const AppConfig& cfg, std::wstring installRoot, StateFn onStateChanged);
    ~Orchestrator();

    bool  Start() noexcept;                                    // 定位运行时；失败 → Faulted
    bool  TryInject(const ShellHostInfo& target) noexcept;      // ★ 幂等；从 watcher 线程调用
    void  NotifyShellHostExited(DWORD pid) noexcept;
    bool  ForceReinject() noexcept;                             // 托盘菜单"重新注入"
    void  Stop() noexcept;                                      // 停编排线程

    State              GetState() const noexcept;
    DWORD              CurrentPid() const noexcept;             // 0 = 无
    std::wstring       LastError() const noexcept;
    const DiagnosticsRuntime& Runtime() const noexcept;

private:
    void ThreadMain(std::stop_token st);                        // 唯一执行注入的线程
    void SetState(State s) noexcept;
    bool DoInject(DWORD pid) noexcept;

    AppConfig             cfg_;
    std::wstring          installRoot_;
    StateFn               onStateChanged_;
    std::atomic<State>    state_{ State::Stopped };
    std::atomic<DWORD>    currentPid_{ 0 };
    mutable std::mutex    mtx_;
    std::wstring          lastError_;
    std::jthread          thread_;
    std::condition_variable_any cv_;
    std::optional<DiagnosticsRuntime> runtime_;
    DWORD                 retryDelayMs_ = 1000;                 // 退避当前值
};

} // namespace vmext
```

**状态机（完整转移表）**

| 当前状态 | 事件 | 动作 | 新状态 |
|---|---|---|---|
| `Stopped` | `Start` | `DiagLocator::Locate` | 成功→`WaitingForShellHost`；失败→`Faulted` |
| `WaitingForShellHost` | `TryInject(target)` | 转 `Injecting`，起编排作业 | 见下 |
| `Injecting` | `TapProbe::IsAlive(pid)` == true | 记"已存在 TAP，跳过" | `Ready` |
| `Injecting` | 注入返回 ok | 转 `WaitingForTap`，`WaitUntilAlive` | 成功→`Ready`；超时→重试 |
| `Injecting`/`WaitingForTap` | 可重试类失败 | 退避（1s→2s→4s…上限 30s）后重试 | `Injecting` |
| 同上 | `TargetGone` | 清 pid | `WaitingForShellHost` |
| 任意 | `NotifyShellHostExited(pid)` | 清 `currentPid_` | `WaitingForShellHost` |
| `Ready` | `HealthMonitor` 发现 `!IsAlive` | `ForceReinject` | `Injecting` |
| `Faulted` | 用户改配置并重启 | — | `Stopped` |
| 任意 | `Stop` | `request_stop` + `join` | `Stopped` |

**⭐ 线程模型：编排器有且只有一条线程执行注入**

```cpp
void Orchestrator::ThreadMain(std::stop_token st)
{
    while (!st.stop_requested()) {
        std::unique_lock lk(mtx_);

        // 等到有作业、或退避到期、或收到停止
        cv_.wait_for(lk, std::chrono::milliseconds(retryDelayMs_),
                     [&]{ return st.stop_requested() || pendingJob_; });
        if (st.stop_requested()) break;
        if (!pendingJob_) { retryDelayMs_ = std::min(retryDelayMs_ * 2, 30'000u); continue; }

        DWORD pid = pendingJobPid_;
        pendingJob_ = false;
        lk.unlock();
        // ★ 锁外做 IO（打开进程、写 ini、注入、等 TAP）。绝不持锁做 IO。
        bool ok = DoInject(pid);
        ...
    }
}
```

| 设计点 | 原因 |
|---|---|
| ⭐ **注入动作串行化到一条专用线程** | 避免"watcher 线程"与"托盘'重新注入'菜单（主线程）"同时注入造成竞态。L1 幂等（`TapProbe`）能让并发**基本**安全，但串行化让它**确定**安全 |
| ⭐ **绝不持锁做 IO** | 注入涉及 `OpenProcess`/`WriteProcessMemory`/等 20s，持锁会让托盘菜单卡住 |
| `condition_variable_any` + `std::stop_token` 的重载 | C++20 才有的"可中断等待"；不用它就只能靠 5s 轮询 |
| 退避在**没有作业**时增长，有作业时重置 | 语义：连续失败 → 越来越慢；一旦有新事件（新的 ShellHost）→ 立刻重试 |

**`TryInject`（幂等是重点）**

```cpp
bool Orchestrator::TryInject(const ShellHostInfo& target) noexcept
{
    // ① ⭐ 幂等前置检查 —— 没有这一步，App 重启一次就会多出一个 TAP、出现两个按钮
    if (TapProbe::IsAlive(target.pid)) {
        VLOG_INFO("Orch", "pid=%lu 已有 TAP，跳过注入", target.pid);
        currentPid_ = target.pid;
        SetState(State::Ready);
        return true;
    }

    // ② 每次注入前重写两个 ini（配置可能刚被用户改过）
    if (!WriteTapIni(target)) { SetState(State::Faulted); return false; }
    if (!WriteLauncherIni(target)) { SetState(State::Faulted); return false; }

    // ③ 交给编排线程做实际注入
    {
        std::lock_guard lk(mtx_);
        pendingJob_ = true;
        pendingJobPid_ = target.pid;
        retryDelayMs_ = 1000;                  // 有新事件 → 重置退避
    }
    cv_.notify_all();
    return true;
}
```

```cpp
bool Orchestrator::DoInject(DWORD pid) noexcept
{
    SetState(State::Injecting);
    currentPid_ = pid;

    auto launcher = installRoot_ + L"\\" + contract::kLauncherDllName;
    auto r = inject::InjectInto(pid, launcher, 20000);

    if (!r.ok()) {
        SetLastError(str::Format(L"注入失败 pid=%lu err=%S win32=%lu", pid, r.Name(), r.win32));
        VLOG_ERR("Orch", "注入失败 pid=%lu err=%s win32=%lu", pid, r.Name(), r.win32);
        if (r.error == inject::Error::TargetGone) {
            currentPid_ = 0;
            SetState(State::WaitingForShellHost);
        }
        return false;
    }

    SetState(State::WaitingForTap);
    // ④ 等 TAP 自己报活（注入成功 ≠ TAP 就绪）
    if (!TapProbe::WaitUntilAlive(pid, 10000)) {
        SetLastError(str::Format(L"pid=%lu 注入成功但 TAP 10s 内未就绪", pid));
        VLOG_ERR("Orch", "pid=%lu 注入成功但 TAP 未就绪；看 launcher.log 与 tap.log", pid);
        return false;
    }

    VLOG_INFO("Orch", "pid=%lu TAP 就绪", pid);
    retryDelayMs_ = 1000;                      // 成功 → 重置退避
    SetState(State::Ready);
    return true;
}
```

**为什么必须有 ①**：App 重启（或用户点两次"重新注入"）时 ShellHost 里可能已经有一个 TAP。再注入一次会让 `InitializeXamlDiagnosticsEx` 用**下一个空闲端点**（`VisualDiagConnection2`）加载**第二个 TAP 实例** —— 两个 TAP 都会改 `Footer` ⇒ **两个按钮**。
**App 侧检查（①）+ TAP 侧单例互斥体（§3.10/§4.2）= 双保险。**
⚠️ **未验证**：同进程对不同端点名调两次 `InitializeXamlDiagnosticsEx` 是否被允许。TAP 侧守卫让它即使发生也无害。

---

### 3.12 `vmext_health.h` — 健康检查与自愈

```cpp
namespace vmext {

class HealthMonitor final {
public:
    HealthMonitor(Orchestrator& orch, DWORD intervalMs = 30000) noexcept;
    ~HealthMonitor();
    void Start(Orchestrator::StateFn onStateChanged) noexcept;
    void Stop() noexcept;

private:
    void ThreadMain(std::stop_token st);
    Orchestrator& orch_;
    DWORD         intervalMs_;
    std::jthread  thread_;
    int           consecutiveTapLoss_ = 0;      // ★ 见下
};

} // namespace vmext
```

**每次 tick 的检查（按顺序，短路）**

| # | 检查 | 不通过的结论 | 动作 |
|---|---|---|---|
| 1 | `orch.GetState() == Ready`？ | 别处在处理 | 跳过本次 |
| 2 | `ShellHostLocator::FindById(pid, session)` 还在？ | ShellHost 没了 | `orch.NotifyShellHostExited(pid)` |
| 3 | `TapProbe::IsAlive(pid)`？ | ⚠️ ShellHost 活着但 TAP 没了 | **记 Warn + `ForceReinject`**；连续 3 次 → `Faulted` |
| 4 | `tap.log` 的 `LastWriteTime` 在 `interval*2` 内？ | 只是提示级信息 | 仅 Debug 日志，不动作 |

| 设计点 | 原因 |
|---|---|
| 第 3 项是**观测型**检查 | 其结论"TAP 无法卸载"来自 ⛔ §10.1，**没有实测过 TAP 消失**。如果真的触发，是**重大信号** —— 必须把现场（pid、两个日志尾部、mutex 名）完整记下来 |
| 用 `consecutiveTapLoss_` 计数 | 单次触发可能只是竞态（ShellHost 正在退出）；连续 3 次才是真问题 |
| `std::jthread` + `stop_token` | 与其它线程一致的停止语义 |
| 默认 30s，三个 syscall 量级 | 开销可忽略 |

---

### 3.13 `vmext_pipe.h` — IPC 服务端（`action=pipe` 模式）

```cpp
namespace vmext {

class PipeServer final {
public:
    using ClickFn = std::function<void(const std::string& entryId)>;

    PipeServer(std::wstring pipeName, ClickFn onClick) noexcept;
    ~PipeServer();

    bool Start() noexcept;      // 起线程
    void Stop() noexcept;

private:
    void ThreadMain(std::stop_token st);
    std::wstring pipeName_;
    ClickFn      onClick_;
    std::jthread thread_;
};

} // namespace vmext
```

**`ThreadMain` 的实现（有三个经典陷阱）**：

```cpp
void PipeServer::ThreadMain(std::stop_token st)
{
    const std::wstring name = pipeName_;

    while (!st.stop_requested()) {
        UniqueHandle h(CreateNamedPipeW(
            name.c_str(),
            PIPE_ACCESS_INBOUND,                                  // 只读（我们只收）
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,      // 字节流、阻塞
            1,                                                    // ★ 单实例：见下
            4096, 4096, 0, nullptr));
        if (!h) {
            VLOG_ERR("Pipe", "CreateNamedPipeW 失败 err=%lu name=%S", GetLastError(), name.c_str());
            Sleep(1000);
            continue;
        }

        // ⚠️ 陷阱 1：ConnectNamedPipe 的合法失败**有两种**（✅ 2026-10-03 实测，见
        //            verified-after-injection/08-pipe-action-chain.md）：
        //   * ERROR_PIPE_CONNECTED (110)：客户端已连接、**仍开着** -> 直接读。
        //   * ERROR_NO_DATA (232)：客户端连接过、**已经关闭**（TAP 写完就 CloseHandle，
        //       若"连上+关闭"都发生在 ConnectNamedPipe 之前就会命中）-> **不能当致命错误**！
        //       缓冲里的数据**仍然可读**，实测 32 字节报文完整读回。
        //       把 232 当错误直接 continue/return，会在"App 刚启动"的窗口里**静默丢一次点击**。
        //   * 另外：读循环里 ReadFile 返回 FALSE 且 err=ERROR_BROKEN_PIPE(109) 是**正常收尾**，不是错误。
        BOOL ok = ConnectNamedPipe(h.get(), nullptr);
        if (!ok) {
            const DWORD e = GetLastError();
            if (e == ERROR_PIPE_CONNECTED) {
                ok = TRUE;                                          // 已连上，直接进读循环
            } else if (e == ERROR_NO_DATA) {
                ok = TRUE;                                          // ★ 连上又关了：仍要读缓冲
                VLOG_DEBUG("Pipe", "ConnectNamedPipe=ERROR_NO_DATA(232)：客户端已断开，仍尝试读缓冲");
            } else {
                VLOG_WARN("Pipe", "ConnectNamedPipe 真失败 err=%lu", e);
                continue;                                            // RAII 关句柄
            }
        }

        // ⚠️ 陷阱 2：必须把缓冲区收干净。TAP 可能一次写多行 / 半行。
        std::string acc;
        char buf[512];
        for (;;) {
            DWORD n = 0;
            if (!ReadFile(h.get(), buf, sizeof(buf), &n, nullptr) || n == 0) break;
            acc.append(buf, n);
            // 逐行处理：每行 "CLICK <entryId> <unixMillis>"
            size_t pos;
            while ((pos = acc.find('\n')) != std::string::npos) {
                std::string line = acc.substr(0, pos);
                acc.erase(0, pos + 1);
                if (!line.empty() && line.back() == '\r') line.pop_back();
                DispatchLine(line);
            }
            if (acc.size() > 4096) acc.clear();                  // 防御：畸形输入
        }

        // ⚠️ 陷阱 3：一定要 DisconnectNamedPipe，否则下一次 CreateNamedPipe 会失败
        FlushFileBuffers(h.get());
        DisconnectNamedPipe(h.get());
    }
}
```

```cpp
void PipeServer::DispatchLine(const std::string& line) noexcept
{
    // "CLICK <entryId> <unixMillisUtc>"
    if (line.rfind(contract::ipc::kClickPrefix, 0) != 0) {
        VLOG_WARN("Pipe", "未知报文，忽略: %s", line.c_str());
        return;
    }
    // 解析 entryId（空格分隔）；未知 id 也交给上层（上层可能刚删了这个条目）
    auto rest = line.substr(sizeof(contract::ipc::kClickPrefix) - 1);
    auto sp   = rest.find(' ');
    std::string id = (sp == std::string::npos) ? rest : rest.substr(0, sp);

    VLOG_INFO("Pipe", "收到点击 entryId=%s", id.c_str());
    // ★ 回调跑在**管道线程**上。上层必须自己切到主线程（PostMessage），不得阻塞这里。
    try { if (onClick_) onClick_(id); }
    catch (...) { VLOG_ERR("Pipe", "点击回调抛出异常（已吞掉）"); }
}
```

| 陷阱 | 症状 | 正确做法 |
|---|---|---|
| ⚠️ `ConnectNamedPipe` + `ERROR_PIPE_CONNECTED (110)` | **间歇性丢点击**（难以复现，最难查的一类 bug） | 把 `ERROR_PIPE_CONNECTED` 当作成功 |
| ⚠️ **`ConnectNamedPipe` + `ERROR_NO_DATA (232)`**（★ 实测补充） | 同样是**间歇性丢点击**，而且发生在"App 刚启动 / 正在重启"的窗口里 | **不能当致命错误**：客户端连上又关闭了，但**缓冲里的数据仍可读**（实测 32 字节完整读回）⇒ 仍要继续读 |
| ⚠️ `ReadFile` + `ERROR_BROKEN_PIPE (109)` | 被当成错误记满日志 | 对端关闭 = **正常的流结束**，不是错误 |
| ⚠️ 不 `DisconnectNamedPipe` | 第二次 `CreateNamedPipeW` 失败 → 只有第一次点击有效 | 循环末尾必须 `DisconnectNamedPipe` |
| ⚠️ 不做逐行缓冲 | 一次写多行或半行时解析失败 | 累积缓冲 + 按 `\n` 切分 + `\r` 修剪 |
| 单实例（`nMaxInstances = 1`） | TAP 并发写入时第二个会等待 | **有意为之**：TAP 一次只写一行且很快关闭，串行化更简单。若实测发现 TAP 等待导致卡顿，改为 4 |
| 回调线程 | 在管道线程上执行 → 如果上层做 UI 操作会死锁 | 回调里只 `PostMessage`（§3.14） |

---

### 3.14 `VmExt.App` — 托盘宿主

```cpp
namespace vmext::app {

class TrayApp final {
public:
    TrayApp(const AppConfig& cfg, std::wstring installRoot);
    ~TrayApp();

    int Run(HINSTANCE hInst);      // 注册窗口类 → 建隐藏消息窗 → 装托盘 → 消息循环

private:
    static LRESULT CALLBACK WndProc(HWND, UINT, WPARAM, LPARAM);
    LRESULT HandleMessage(UINT msg, WPARAM wp, LPARAM lp);

    void AddTrayIcon();
    void RemoveTrayIcon();
    void ShowContextMenu();
    void ShowSettings();
    void UpdateTooltip(State s, const std::wstring& extra);
    void OnEntryClicked(const std::string& entryId);     // 从管道线程 PostMessage 而来

    HWND              hwnd_ = nullptr;
    HINSTANCE         hInst_ = nullptr;
    NOTIFYICONDATAW   nid_{};
    UINT              msgTaskbarCreated_ = 0;            // ★ RegisterWindowMessageW(L"TaskbarCreated")
    AppConfig         cfg_;
    std::wstring      installRoot_;
    Orchestrator      orch_;
    HealthMonitor     health_;
    PipeServer        pipe_;
    ShellHostWatcher  watcher_;
};

} // namespace vmext::app
```

**自定义消息**

```cpp
enum : UINT {
    WM_VMEXT_TRAY       = WM_APP + 0x2000,   // 托盘回调
    WM_VMEXT_STATE      = WM_APP + 0x2001,   // 状态变化（从编排/健康线程 → 主线程）
    WM_VMEXT_CLICK      = WM_APP + 0x2100,   // 点击事件（从管道线程 → 主线程），wParam = entryId 在表里的索引
};
```

**`WndProc` 里必须处理的四件事（全部踩坑得来）**

| 消息 | 处理 | 不处理会怎样 |
|---|---|---|
| `msgTaskbarCreated_`（`RegisterWindowMessageW(L"TaskbarCreated")`） | 重新 `Shell_NotifyIconW(NIM_ADD, ...)` | ⭐ **explorer 重启后托盘图标消失**。本项目会**频繁重启 explorer**，所以这一条尤其重要 |
| `WM_VMEXT_TRAY` + `WM_RBUTTONUP` | `SetForegroundWindow(hwnd_)` → `TrackPopupMenu(TPM_RIGHTBUTTON \| TPM_RETURNCMD)` → **`PostMessage(hwnd_, WM_NULL, 0, 0)`** | ① 不 `SetForegroundWindow`：菜单点外面不会消失 ② 不 `PostMessage(WM_NULL)`：菜单消失后鼠标还"黏"在菜单上（经典 Win32 bug） |
| `WM_VMEXT_STATE` | `UpdateTooltip(...)` + 重建菜单 | 托盘状态永远停在启动时的值 |
| `WM_VMEXT_CLICK` | 按 entryId 找条目 → 执行动作（或显示 UI） | 点击无反应 |
| `WM_DESTROY` | `Shell_NotifyIconW(NIM_DELETE, ...)` → `PostQuitMessage(0)` | 托盘留一个幽灵图标，直到鼠标划过 |

**启动自检（`wWinMain` 里）**

```cpp
int wWinMain(HINSTANCE hInst, HINSTANCE, LPWSTR, int)
{
    // 0) 单实例
    UniqueHandle single(CreateMutexW(nullptr, TRUE, L"Local\\VmExt.App.Singleton"));
    if (single && GetLastError() == ERROR_ALREADY_EXISTS) {
        MessageBoxW(nullptr, L"VolumeMixerExtender 已在运行。", L"提示", MB_ICONINFORMATION);
        return 0;
    }

    const std::wstring root = ComputeInstallRoot(hInst);      // app 所在目录

    // 1) 路径不含 ';' 或 '='（initData 契约，§2.2）
    if (str::ContainsReservedChars(root)) {
        ShowError(L"安装路径含保留字符 ';' 或 '='，请把程序移到只含普通字符的目录：\n" + root);
        return 1;
    }

    // 2) 两个原生组件存在
    for (auto name : { contract::kLauncherDllName, contract::kTapDllName }) {
        auto p = str::Join(root, name);
        if (!str::FileExists(p)) { ShowError(L"缺少组件：\n" + p); return 1; }
    }

    // 3) 位宽自检（必须是 x64）
    if (!IsSelfX64()) { ShowError(L"原生组件非 x64，与系统外壳不匹配。"); return 1; }

    // 4) ★ INI 编码自检（写含中文的临时 INI → 读回比对）
    std::wstring err;
    if (!Ini::SelfTest(err)) {
        ShowError(L"INI 读写自检失败（编码不兼容），无法可靠传递按钮文字。\n" + err);
        return 1;
    }

    // 5) 日志（失败不致命）—— <cache>\log，一次会话一个文件，见 §9.3
    CreateDirectoryIfNeeded(platform::GetCacheDirectory() / L"log");
    Log::Open(log::SessionLogFile(L"app"), cfg.logLevel);

    // 6) 诊断运行时（失败 → 进 Faulted，但仍启动托盘，让用户能看到原因与诊断信息）
    auto rt = DiagnosticsRuntimeLocator::Locate(cfg.diagnosticsDll);

    // 7) 装配 + 进消息循环
    TrayApp app(cfg, root);
    return app.Run(hInst);
}
```

**"诊断信息"对话框的内容**（一键复制，是让用户/自己快速定位的关键）：

```
VolumeMixerExtender 诊断信息
  版本            : 1.0.0
  安装根目录      : C:\Users\eric\AppData\Local\VolumeMixerExtender
  会话 ID         : 2
  诊断运行时      : C:\Program Files (x86)\Windows Kits\10\bin\x64\XamlDiagnostics\xamldiagnostics.dll  (来源: commonpath)
  进程架构        : x64
  ShellHost       : pid=17080 start=...  TAP=就绪
  Launcher DLL    : ...\VmExt.Launcher.dll  (存在)
  TAP DLL         : ...\VmExt.Tap.dll       (存在)
  initData        : ver=1;cfg=...;log=...;pipe=...;mutex=...
  最近错误        : （无）
  日志目录        : %TEMP%\eric\VolumeMixerExtender\log
```

> **⚠️ 待补的可用性缺口**：TAP 完成一次按钮注入后**没有回传任何信号**。
> 要真正做到"状态可信"，需要让 TAP 在注入成功后也走管道写一行 `INJECTED <entryId>`。
> v1 里状态只到"TAP 就绪"。**文档写清楚，不要假装状态是准的。**

---

### 3.14.1 开机自启（`Run` 键）与「从系统卸载」

> 设计见 `../design.md` §7.9.2。**已定（2026-10-03）：登录自启走 `Run` 键**
> （同日从"计划任务"改过来：一个值就是全部语义，没有 `ExecutionTimeLimit` / 电池那几项默认值陷阱，
> 也不存在把运行身份写成提权的可能）。
> **已实现（2026-10-03）：`Core/AutostartEntry.{h,cpp}`**，命名空间 `vmex::autostart`
> （本项目统一用 `vmex`，不是文档早期的 `vmext`）。

```cpp
namespace vmex::autostart {

class AutostartEntry final {
public:
    // 值名固定：HKCU\Software\Microsoft\Windows\CurrentVersion\Run 下的这一个名字。
    static constexpr wchar_t kValueName[] = L"VolumeMixerExtender";

    // 初值判定：Run 值存在 && 未被系统标记为禁用。⛔ 不是"我记得我建过"
    [[nodiscard]] static bool IsEnabled();
    static bool Enable(std::wstring& error);
    static bool Disable(std::wstring& error);
};

} // namespace vmex::autostart
```

| 项 | 值 |
|---|---|
| 位置 / 值名 | `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` · `VolumeMixerExtender` |
| 值 | `"<InstallRoot>\vmex.exe" --tray`（⚠️ 路径带引号：`Run` 值是一整条命令行字符串） |
| 触发 | 登录时（explorer 拉起），**每会话一份** |
| 运行身份 | 当前用户、**未提权**（继承 explorer 令牌）⇒ 与 ShellHost 同完整性级别，注入契约成立 |
| 禁用标记 | `HKCU\...\Explorer\StartupApproved\Run` 下的同名 `REG_BINARY`，**首字节低位 = 1 表示已被用户禁用** |

**开关语义**：`初值 = Run 值存在 && 未被禁用`；`打开 = 写 Run 值 + 清禁用标记`；
`关闭 = 删 Run 值 + 删禁用标记`（⛔ 不留"已禁用"残留）。

⛔ **禁用标记必须一起读、一起删**：用户在「任务管理器 → 启动」里关掉它时，Windows **不删**
我们的 `Run` 值，只写那个标记 ⇒ 只读 `Run` 值会**画"开"而实际不启动**；关闭时不清标记则下次
打开又被判成"被禁用"。

⛔ **开关状态不存任何副本**：自启开关画的是"自启项到底在不在"这个事实，任何镜像都会和用户的
手动删改打架 ⇒ 每次现查（payload 与宿主都链接 `vmex_core`，实现只有这一份）。

⚠️ `<InstallRoot>\vmex.exe` 不存在时**拒绝注册**（否则留下一个每次登录都失败、还赖在「启动」列表里的项）。

**CLI**：`vmex_cli autostart` 查询、`vmex_cli autostart on|off` 注册/取消（与设置页开关同一份实现）。

**控制台闪现**：`vmex.exe` 是控制台子系统，登录自启时会闪一下控制台窗口 ——
**已决定接受**（不做 `WIN32` 子系统 + `AttachConsole` 改造，原 T25 关闭）。

---

### 3.15 配置对话框

| 项 | 做法 |
|---|---|
| 实现 | `DialogBoxParamW(hInst, MAKEINTRESOURCE(IDD_SETTINGS), hwnd, SettingsDlgProc, (LPARAM)this)` + `VmExt.App.rc` |
| 控件 | 总开关（`BS_AUTOCHECKBOX`）、条目表格（`ListView` 报告模式或最简的一行两个 `Edit`）、诊断运行时路径（`Edit` + "浏览"）、`应用`/`确定`/`取消` |
| 校验 | 复用启动自检的检查项（路径保留字符、DLL 存在） |
| 落盘 | `Ini::WriteAll` 写 `vmext.ini` + `vmext-tap.ini`；然后提示"**下次打开面板生效**"（因为 TAP 每次命中 `Footer` 时重读配置） |
| ⛔ 不要在对话框里重新注入 | 配置热重载已经覆盖；重新注入只会增加风险面。想立即重建可选择菜单里的"重新注入" |

**v1 的简化取舍**：配置对话框可以只做"总开关 + 诊断运行时路径 + 按钮文字"，其余字段让用户直接编辑 `vmext.ini`（菜单里有"打开配置文件夹"）。**原生 UI 的成本高，把可编辑的字段留在文件里是合理的取舍** —— 但要在文档里写明。

---

### 3.16 测试策略（C++ 轨道的现实）

**结论：自写极简断言，不引入测试框架。**

| 方案 | 取舍 |
|---|---|
| **自写约 40 行的断言宏 + `main()`**（采用） | 保持"零第三方依赖"（§0.4 第 7 条）；本项目的可测单元很少且都很简单；`VmExt.Tests.exe` 直接跑、退出码即结果，能被任何 CI 消费 |
| Catch2（单头，MIT） | 表达式分解、`TEST_CASE` 更舒服，但为了几个测试引入一个几百 KB 的头文件不值得。若测试数量增长到 100+ 再考虑 |
| GoogleTest | 重量级，需要 CMake 集成，不符合"零依赖"的取向 |

**可测单元清单**：

| 文件 | 覆盖 |
|---|---|
| `test_contract.cpp` | initData `Build`/`Parse` 往返与全部边界（§3.1 的清单）；`PipeName`/`TapMutexName`/`EndPointName` 的字面量形状；报文格式 |
| `test_ini.cpp` | `WriteAll`+`ReadString` 往返（**含中文值**）；缺文件/缺键返回默认；`ReadInt` 边界；`SelfTest` 通过 |
| `test_str.cpp` | `ModuleDir`/`Join`/`ResolveRelative`/`ContainsReservedChars`/`UTF-8 ↔ UTF-16` 往返（含 emoji）；`EqualsNoCase` |
| `test_injector.cpp` | 错误分类（不存在的 DLL / 已退出的 pid / 非法路径）；`RemoteModuleBase(pid,"kernel32.dll")` 非零；注到一个自建靶进程成功；`Error::Name()` 穷尽 |
| `test_log.cpp` | 并发写不乱行；`Open` 失败后静默；`LogLevel` 过滤 |
| `test_locator.cpp` | `CurrentSessionId` 非 0；`FindAll` 不抛；`FindById(自己 pid, 自己 session)` 空 |

**测试怎么跑**：

```cmd
:: 不需要管理员、不需要 ShellHost、不需要交互桌面 —— 这就是 C++ 轨道把部分验证前移的收益
build\tests\VmExt.Tests.exe
echo %ERRORLEVEL%     :: 0 = 全部通过
```

⛔ **仍然必须跑在有交互桌面上的是第四类**（真实端到端：注入 ShellHost → 开面板 → UIA 断言几何 → 触发点击），脚本清单见 §8.3。

---

## 4. in-proc 两段

> 这两段运行在 ShellHost 进程内，**必须是原生代码**（§1.2）。
> 它们依赖的"日志 / INI / 字符串工具"来自 `VmExt.Shared.lib` 静态链接（§3.0），
> 所以下面的代码里不会出现"为了在 DLL 里也能用而重新实现一遍"的东西。

### 4.1 `VmExt.Launcher.dll`（in-proc 第 1 段）

**职责**：在 ShellHost 进程内调用 `InitializeXamlDiagnosticsEx`，把 TAP 拉起来。**只做这一件事。**

**导出**：无（只有 `DllMain`）。
**依赖**：`VmExt.Shared.lib`（Log / Ini / Str）、`ole32.lib`。**不需要** cppwinrt 头、不需要 `WindowsApp.lib`。

#### 4.1.1 `VmExt.Launcher.ini`（与本 DLL 同目录，注入前由 App 写好）

```ini
[launcher]
; TAP DLL 路径。相对路径按本 DLL 所在目录解析
tap=VmExt.Tap.dll
; SDK 里的诊断运行时
xamldiag=C:\Program Files (x86)\Windows Kits\10\bin\x64\XamlDiagnostics\xamldiagnostics.dll
; ★ initData（§2.2 的 k=v; 串），由 App 用 Contract::Build 生成
initdata=ver=1;cfg=...;log=...;pipe=...;mutex=...
; 日志路径（缺省为本 DLL 同目录 launcher.log）
log=...\logs\launcher.log
; 等 Windows.UI.Xaml.dll 的上限
xamlWaitMs=30000
; 端点名探测起始索引（正常恒为 1）
endpointStart=1
```

#### 4.1.2 方法逐条

| 方法 | 签名 | 线程 | 职责 | 失败处理 |
|---|---|---|---|---|
| `DllMain` | `BOOL WINAPI DllMain(HMODULE, DWORD, LPVOID)` | loader 线程 | 只做：`g_self = self` → `DisableThreadLibraryCalls` → `CreateThread(Worker)` → `CloseHandle` | 建线程失败：返回 `TRUE`（**不要**返回 FALSE，那会变成注入失败） |
| `Worker` | `DWORD WINAPI Worker(LPVOID self)` | 自建线程 | 全部实际工作，见 §4.1.3 | 任何一步失败 → 记日志 → `return 0`（⛔ **不要** `ExitProcess`） |
| `InitXamlDiagnosticsExFn` | 函数指针 typedef，6 参数 | — | `HRESULT __stdcall(LPCWSTR endPointName, DWORD pid, LPCWSTR wszDllXamlDiagnostics, LPCWSTR wszTAPDllName, CLSID tapClsid, LPCWSTR wszInitializationData)` | — |
| `ProvideConfigToTap` | `bool ProvideConfigToTap(const std::wstring& tapPath, const std::wstring& config)` | 任意（Worker 内） | ★ 直投：`LoadLibraryW` + `GetProcAddress(kTapProvideInitDataExport)` + 调用；**刻意不** `FreeLibrary` | 加载失败或找不到导出 → 记日志 + `return false`（**不致命**，initData 还能兜底 ≤259 的配置） |

> ⛔ **函数指针的 6 个参数与顺序必须与附录 A 完全一致**。这是 ABI 级契约：写错不会编译报错，只会拿到诡异的 HRESULT 或崩在目标进程里。

#### 4.1.3 `Worker` 的完整步骤

```text
 1. Sleep(200)
     为什么：注入线程已在别人的进程里跑。给目标 loader 一点余量，避免与
              CreateRemoteThread 的初始化抢 loader lock。PoC 实测需要。

 2. Log::Open(<logPath>, Info)
     日志打不开也继续（后续静默）。⚠️ 一定要在**调用任何会写日志的代码之前**开。

 3. CoInitializeEx(nullptr, COINIT_MULTITHREADED)
     返回 S_FALSE / RPC_E_CHANGED_MODE 也继续（不是致命）。

 4. 等 XAML 核心就绪：循环 GetModuleHandleW(L"Windows.UI.Xaml.dll")，100ms 一次，
    上限 xamlWaitMs（默认 30000）。拿不到 → 记日志 + return。
     为什么：目标可能刚启动，XAML 还没加载；而 InitializeXamlDiagnosticsEx
              是那个 DLL 的导出。

 5. GetProcAddress(xaml, "InitializeXamlDiagnosticsEx")
     拿不到 → 记日志（含 DLL 路径）+ return。可能原因：WinUI3 而非 System XAML。

 6. 读 ini 并校验两个路径都存在（Ini::ReadString + str::FileExists）：
       tap / xamldiag / initdata / log / xamlWaitMs / endpointStart
     缺一个必要项 → 记日志（写清缺哪个、展开成什么绝对路径）+ return。
     为什么：这两个文件是在**目标进程**里被加载的，必须是目标能访问的绝对路径。

 7. ★ 组装配置串（`Contract::Build`，§2.2.2 格式），然后做长度自检：
       > contract::kInitDataHardLimit(259) → **仍然照传**，但记一条警告：
         "配置 N 字符 > 259，initData 面包屑会被框架静默丢弃（配置由直投通道送达）"
     为什么还要照传：超限丢的只是面包屑，功能不受影响；但这条日志是将来排查的唯一线索
                    —— 不写它，事后看到 TAP 侧 initData 为空就会误判成"配置没送出去"。

 8. ★★ 配置直投（**必须在第 9 步之前**）：
       HMODULE hTap = LoadLibraryW(<tap 绝对路径>);
       auto p = (contract::TapProvideInitDataFn)GetProcAddress(
                    hTap, contract::kTapProvideInitDataExport);
       if (p) p(config.c_str());  else 记日志 "找不到导出"
       ★ 刻意**不** FreeLibrary（§2.2.1）
     为什么排在这里：此刻 TAP 模块已被加载、全局变量可写；随后 XAML core 加载同一模块
                    （同一个 HMODULE）时配置已就位，DllGetClassObject 才拿得到。
     失败处理：导出找不到 → 记日志但**继续**（initData 通道还能兜底 ≤259 的配置）。

 9. initdata 为空则传 nullptr；非空则原样传第 6 个参数（见第 7 步）。

10. 端点名探测循环 i = endpointStart(1) .. start+10000：
       endpoint = contract::EndPointName(i)
       hr = pInit(endpoint.c_str(), GetCurrentProcessId(),
                  diag.c_str(), tap.c_str(), contract::kTapClsid, initDataOrNull)
       SUCCEEDED(hr)   → 记 SUCCESS（含端点名与索引）+ Log::Close() + return
       hr == E_INVALIDARG → 记日志 + break
          为什么：E_INVALIDARG 通常不是"端点被占用"，而是参数本身不被接受
                  （路径不对、CLSID 不对、initdata 不合规）。继续加索引无意义。
       否则 → 继续下一个索引（前 3 次与每 1000 次记日志，避免刷屏）
```

**关于端点名探测**（✅ 实测）：第一次尝试 `VisualDiagConnection1` 就成功。保留循环是为了**幂等性**：如果 ShellHost 里已经有诊断会话（App 重启后重复注入，或别的工具先占了），`1` 会失败，循环让新会话拿到 `2`、`3`… —— 但这时会出现多个诊断会话并存，靠 §4.2 的 TAP 单例守卫保证只有一个生效。

#### 4.1.4 日志样本（排障时按这个判断）

```
2026-10-03T01:41:33.502 | INFO  | t6500 | Launcher | ================================
2026-10-03T01:41:33.502 | INFO  | t6500 | Launcher | attached: pid=17080 CoInitializeEx=0x00000000
2026-10-03T01:41:33.502 | INFO  | t6500 | Launcher | Windows.UI.Xaml.dll = 00007FFE421D0000
2026-10-03T01:41:33.502 | INFO  | t6500 | Launcher | InitializeXamlDiagnosticsEx = 00007FFE42907C30
2026-10-03T01:41:33.502 | INFO  | t6500 | Launcher | xamldiagnostics.dll = C:\...\xamldiagnostics.dll (exists=1)
2026-10-03T01:41:33.502 | INFO  | t6500 | Launcher | TAP dll = C:\...\VmExt.Tap.dll (exists=1)
2026-10-03T01:41:33.502 | INFO  | t6500 | Launcher | initData 长度=142
2026-10-03T01:41:33.502 | INFO  | t6500 | Launcher | walking endpoint names VisualDiagConnection1..N
2026-10-03T01:41:33.502 | INFO  | t6500 | Launcher | SUCCESS endpoint=VisualDiagConnection1 hr=0x00000000 (index 1)
```

| 日志停在哪一行 | 结论 |
|---|---|
| 没有 `attached` | 注入没成功，或 `DllMain` 里 `CreateThread` 失败 → 看 App 日志的 `Result:Name()` |
| 停在 `Windows.UI.Xaml.dll` 之前 | 等了 30s 还没等到 XAML → 目标不是 System XAML 宿主 |
| 停在 `InitializeXamlDiagnosticsEx` | 导出不存在 → 可能 WinUI3 |
| 有 `(exists=0)` | 路径不对 → 看 App 写的 `VmExt.Launcher.ini` |
| 出现多个 `hr=` 后没有 SUCCESS | 端点被占 → 同时检查 `tap.log` 是否已有另一个实例 |
| `SUCCESS` 之后 `tap.log` 没动静 | TAP DLL 加载失败（依赖缺失、导出名错）→ `dumpbin /exports` 核对；或看系统事件日志的 loader 错误 |

### 4.2 `VmExt.Tap.dll`（in-proc 第 2 段，COM in-proc server）

**职责**：接住 XAML 视觉树事件，`Footer` 出现时注入按钮，把点击动作送出去。
**不负责**：不做进程监视、不做注入、不决定业务。

**导出**（⛔ 必须用链接器 `/EXPORT:`，不是 `__declspec(dllexport)`，见 §4.3 坑 3）：

```text
DllGetClassObject(REFCLSID, REFIID, LPVOID*)   → 只为 contract::kTapClsid 服务
DllCanUnloadNow()                               → 仅当无存活 Tap 对象时返回 S_OK
```

**依赖**：`VmExt.Shared.lib`、cppwinrt 头（仅头文件）、`WindowsApp.lib`、`ole32.lib`。

#### 4.2.1 COM 对象模型

```text
DllGetClassObject(CLSID, IID_IClassFactory)
  └─ TapFactory : IClassFactory
       QueryInterface : IUnknown | IClassFactory
       CreateInstance(outer, riid, ppv)
            outer != nullptr → CLASS_E_NOAGGREGATION
            new Tap() → QueryInterface(riid, ppv) → Release()
       LockServer → S_OK                       // 什么都不做

Tap : IVisualTreeServiceCallback, IObjectWithSite
  QueryInterface :
      IUnknown                     → this（投给 IVisualTreeServiceCallback*）
      IVisualTreeServiceCallback   → this
      IObjectWithSite              → this
      其它（含 IVisualTreeServiceCallback2） → E_NOINTERFACE     ★ 见下
  AddRef / Release : Interlocked，归零即 delete this
  IObjectWithSite::SetSite / GetSite
  IVisualTreeServiceCallback::OnVisualTreeChange
```

> ⭐ **只声明 `IVisualTreeServiceCallback` + `IObjectWithSite` 是够的**（✅ PoC 全程跑通）。
> `IVisualTreeServiceCallback2`（`OnElementStateChanged`）是**可选**回传接口：XAML core 会 QI 它，拿到 `E_NOINTERFACE` 就退回 v1，**不会**拒绝连接。
> ⛔ **不要**为了"更完整"去实现它 —— 多一个接口就多一份 vtable 布局出错的机会，而它对需求没有价值。

#### 4.2.2 方法逐条

| 方法 | 职责 | 关键约束 |
|---|---|---|
| `DllMain(DLL_PROCESS_ATTACH)` | `g_self = self` → `DisableThreadLibraryCalls` → 读 `VmExt.Launcher.ini` 的 `log` → `Log::Open` → 记一行分隔线 | ⛔ **不得**在这里创建互斥体、不得做 COM 初始化、不得 `LoadLibrary`（loader lock）。只做日志与保存 HMODULE |
| `Tap::SetSite(IUnknown*)` | 见 §4.2.3 | 必须在 **advise 之前**完成单例检查 |
| `Tap::GetSite(riid, ppvSite)` | 转发给 `m_diag->QueryInterface` | — |
| `Tap::OnVisualTreeChange(rel, el, type)` | 见 §4.2.4 | ⛔ 在 UI 线程；⛔ 不得抛；⛔ 不得长阻塞 |
| `BuildEntryButton(model, entry)` | 造按钮 + 复制样式 + 绑 Click | §5.3 |
| `InjectIntoRow(model, btn)` | 包 Grid 落位 | §5.2 |
| `InjectIntoFooter(footer)` | 重读配置 + 去重 + 找模型按钮 + 调上面两个 | §4.2.4 |
| `TryInjectLater(footer, attempt)` | 排到 UI 线程并等模型按钮出现 | `CoreDispatcher` + 最多 20 次 Low 优先级重试 |
| `ApplyRightAlign(footer, btn)` | **仅兜底路径**的右边距计算 | ⛔ 内部读 `ActualWidth`，必须先判 `>0`（§5.5） |
| `PerformClickAction(entry)` | 按配置执行动作 | ⛔ 不得阻塞 UI 线程 |

#### 4.2.3 `SetSite` 的精确流程

```text
 1. 清掉旧的 m_vts / m_diag（Release）+ reset m_mutex / m_mutexOwned
 2. site == nullptr → return S_OK（XAML 在拆除诊断会话）
 3. QI IXamlDiagnostics  → m_diag
    QI IVisualTreeService → m_vts
    任一失败 → 记日志 + return S_OK（★ 返回失败会让 XAML 认为 TAP 坏了）
 4. ★ 配置来源判定（**直投为主，initData 面包屑**，§2.2.1）：
      a) 先取直投配置：加锁读本 DLL 的全局变量 g_provided（由导出 VmExtTapProvideInitData 写入）
         为什么先取它：它是主通道，且**没有长度限制**
      b) 再读 initData：m_diag->GetInitializationData(&bstr)
         ⚠️ 用 SysStringLen(bstr) 取长度，**不要**用 wcslen —— BSTR 允许内嵌 \0
         ⚠️ 用完 SysFreeString（实测每次是新分配，释放安全）
         Contract::Parse(bstr, d, err)   ← ★ 与 App 用的是**同一个函数**（§2.0）
      c) 比对并记日志（这三行是排查配置问题的第一现场）：
           直投通道: 有/无  len=N  fnv1a64=XXXX
           initData : len=N  fnv1a64=XXXX
           + 判定：
             两者一致                        → "两种通道内容一致（未触及 259 上限）"
             直投有、initData 空、直投 > 259 → "initData 为空属**预期**：超过 259 上限被静默丢弃"
             直投有、initData 空、直投 ≤ 259 → "!! 非已知的长度上限原因"（★ 反向哨兵）
             两者都非空但不一致               → "!! 两通道内容不一致 —— 以直投为准"
             直投无                          → "!! 直投通道未收到数据"（降级路径）
      d) 决定生效配置：直投有则用直投；直投无但 initData 非空则用 initData（降级，仍记 !! 日志）
      e) ★ 从生效配置里取 cfg= → 存进 g_cfgPath，之后**所有** ini 读取都走它
         取不到 cfg → 回退到 DLL 同目录的 vmext-tap.ini，并记日志
         为什么必须有 e)：这才叫"把通道接上了"。否则通道只传了一堆没人用的字节。
      解析失败（含 ver 不匹配）→ 置 dormant，记日志，return S_OK（安全退化）
 5. ★ 单例自检：
      m_mutex.reset(CreateMutexW(nullptr, FALSE, mutexName.c_str()));
      if (GetLastError() == ERROR_ALREADY_EXISTS) {
          记日志 "duplicate TAP, going dormant";
          m_dormant = true;  return S_OK;            // 不 advise、不注入
      }
      ★ 为什么必须在"advise 之前"：advise 之后就开始收事件，
        重复实例如果在事件里才发现自己是多余的，可能已经注入过一次按钮。
 6. 若配置里给了 log 路径，Log::Open 切过去
 7. m_vts->AdviseVisualTreeChange(this)
      成功 → 记日志；之后 OnVisualTreeChange 会开始被调用（**包括已存在树的重放**）
      失败 → 记 hr + return S_OK
```

✅ **第 4 步已实测完毕**（T1，长度扫描 9 点）。结论：`GetInitializationData` **会**原样返回
initData（含中文，≤259 字符逐字符一致），但 **≥260 字符时静默返回空串且 `hr` 仍是 `S_OK`**
⇒ 配置主干改走**直投通道**（第 4a 步），initData 降级为面包屑。
完整数据见 `verified-after-injection/06-initdata-channel-limit.md`。

> ⚠️ **第 4c 步的"反向哨兵"不是装饰**：按实测，直投 ≤259 时 initData **不该**为空。
> 真出现这种组合，说明 OS 引入了**别的**静默失败条件（Windows 更新就可能发生）。
> 没有这一行，那种情况会表现为"配置神秘丢失"且毫无线索。

#### 4.2.4 `OnVisualTreeChange` 的精确流程

```text
 1. seq = InterlockedIncrement(&g_events)
 2. 有界日志：seq <= kLogLimit(40000) 才打
      "ADD/REM parent=.. idx=.. handle=.. type=[] name=[] children=N"
      ★ 必须有界：面板每次打开推送几百条事件，无界日志会吃掉磁盘
 3. m_dormant → return S_OK
 4. 快速过滤（在拿真对象之前，尽量便宜）：
      mutationType == Add
      && element.Name != nullptr && element.Name[0] != 0
      && wcscmp(element.Name, L"Footer") == 0
      ★ 同时检查"本次是否启用"：每次命中都 Ini::ReadString(enabled) —— 这就是热重载
         （读一个 INI 键很便宜；若担心开销，可加 200ms 的读缓存）
      未启用 → return S_OK（★ 这就是"反注入"的实现）
 5. m_diag->GetIInspectableFromHandle(element.Handle, &insp)
      失败 → 记 hr + return S_OK
 6. winrt::Windows::Foundation::IInspectable obj{insp, winrt::take_ownership_from_abi};
    obj.try_as<WUX::FrameworkElement>() → 失败 → 记日志 + return S_OK
 7. TryInjectLater(fe, 0)   整段包在 try/catch(...)，捕获后只记日志
 8. return S_OK             ★ 无论内部发生什么，都返回 S_OK
```

**第 4 步之后为什么要"延后"（`TryInjectLater`）**：✅ 实测 `Footer` 的 **Add 事件先到，它的子元素（含模型按钮）随后才出现**。所以在 Add 回调里立即找模型按钮会拿到 `nullptr`。

```cpp
static void TryInjectLater(WUX::FrameworkElement const& footer, int attempt)
{
    WUC::CoreDispatcher d = nullptr;
    try { d = footer.Dispatcher(); } catch (...) {}
    if (!d) { try { InjectIntoFooter(footer); } catch (...) {} return; }

    auto attemptFn = [footer, attempt]() {          // ★ 按值捕获 FrameworkElement
        WUXC::Button model = FindModelButton(footer, 0);
        if (!model && attempt < 20) {
            WUC::CoreDispatcher dd = nullptr;
            try { dd = footer.Dispatcher(); } catch (...) {}
            if (dd) dd.RunAsync(WUC::CoreDispatcherPriority::Low,
                                [footer, attempt]() { TryInjectLater(footer, attempt + 1); });
            return;
        }
        try { InjectIntoFooter(footer); }
        catch (...) { VLOG_ERR("Tap", "InjectIntoFooter 抛出（已吞掉）"); }
    };

    if (d.HasThreadAccess()) attemptFn();           // 已在 UI 线程：别再绕一圈
    else d.RunAsync(WUC::CoreDispatcherPriority::Normal, attemptFn);
}
```

| 细节 | 说明 |
|---|---|
| ⛔ lambda 必须**按值**捕获 `FrameworkElement` | 捕获引用/裸指针会在面板关闭后悬空 |
| 重试上限 20 次 | 每次 Low 优先级；实测**第 1~2 次就成功**。上限只是防死循环 |
| 20 次都失败 | 记 Warn（说明页面元素结构可能变了 → §10.2 S2），然后放弃 |

#### 4.2.5 点击动作 `PerformClickAction`

```cpp
void Tap::PerformClickAction(const EntryConfig& e) noexcept
{
    if (e.action == L"exec") {
        if (e.exe.empty()) { VLOG_WARN("Tap", "action=exec 但 exe 为空，忽略"); return; }

        // ★ 命令行由 Contract::BuildCommandLine 拼：exe 路径**加引号**，参数原样附上。
        //   为什么不能拿配置里的整条命令行直接用：见 §4.3 坑 27 ——
        //   lpApplicationName=NULL + **未加引号**的含空格路径，会被 CreateProcessW
        //   **逐段前缀试探**，前缀位置存在同名 exe 就启动那个。
        //   （已实测复现：C:\...\Temp\a b c\x.exe 不加引号时启动了 C:\...\Temp\a.exe）
        const std::wstring cmdline = contract::BuildCommandLine(e.exe, e.args);

        // ⛔ lpCommandLine 必须指向**可写内存**（API 可能原地改写）
        std::vector<wchar_t> cmd(cmdline.begin(), cmdline.end());
        cmd.push_back(L'\0');

        // 工作目录：留 nullptr。子进程会继承 ShellHost 的当前目录（实测是 C:\Windows\System32），
        // 但**这不该由本设计负责** —— 被启动的程序应当按自己的模块路径解析资源，
        // 而不是依赖工作目录（见 §2.3 的 📌）。
        STARTUPINFOW si{}; si.cb = sizeof(si);
        PROCESS_INFORMATION pi{};
        if (CreateProcessW(e.exe.c_str(),               // ★ 显式给 lpApplicationName，杜绝前缀试探
                           cmd.data(),
                           nullptr, nullptr, FALSE, 0,
                           nullptr,
                           nullptr,                     // 工作目录：交给被启动的程序自己处理
                           &si, &pi)) {
            CloseHandle(pi.hThread);                    // ★ 不关就每次点击泄漏两个句柄
            CloseHandle(pi.hProcess);                   // ⛔ 不要 WaitForSingleObject：会卡住 ShellHost
        } else {
            VLOG_ERR("Tap", "CreateProcessW 失败 err=%lu", GetLastError());
        }
        return;
    }

    if (e.action == L"pipe") {
        // ⛔ 绝不能在这个线程上做管道 IO（服务端没起来会卡住整个面板）
        const std::wstring pipe = m_pipeName;        // SetSite 时已从生效配置解析
        const std::string  msg  = contract::ipc::FormatClick(ToUtf8(e.id), NowUnixMillis());
        std::thread([pipe, msg]() noexcept {
            try {
                // WaitNamedPipeW 短超时 + 一次性尝试两次；失败就放弃（不重试、不弹窗）
                HANDLE h = CreateFileW(pipe.c_str(), GENERIC_WRITE, 0, nullptr,
                                       OPEN_EXISTING, 0, nullptr);
                if (h == INVALID_HANDLE_VALUE && WaitNamedPipeW(pipe.c_str(), 200))
                    h = CreateFileW(pipe.c_str(), GENERIC_WRITE, 0, nullptr,
                                    OPEN_EXISTING, 0, nullptr);
                if (h == INVALID_HANDLE_VALUE) {
                    VLOG_WARN("Tap", "管道不可用，点击事件丢弃 err=%lu", GetLastError());
                    return;
                }
                DWORD wr = 0;
                WriteFile(h, msg.data(), (DWORD)msg.size(), &wr, nullptr);
                CloseHandle(h);
            } catch (...) { /* 线程入口，绝不能抛 */ }
        }).detach();
        return;
    }

    if (e.action == L"open") {
        // ★ 为什么不复用 action=exec 走 CreateProcessW：
        //   CreateProcessW 只认 exe，URL 不是 exe —— "用默认浏览器打开 URL" 是 shell 的职责。
        //   ShellExecuteW 的 verb=L"open" 才是官方途径（走 URL/文档关联解析）。
        if (e.url.empty()) { VLOG_WARN("Tap", "action=open 但 url 为空，忽略"); return; }

        // hwnd = nullptr（不指定父窗口）。
        // ⚠️ ShellExecuteW 的返回值**不是** BOOL：> 32 才算成功，<= 32 是错误码（老 API 的历史包袱）。
        const INT_PTR r = ::ShellExecuteW(nullptr, L"open", e.url.c_str(),
                                          nullptr, nullptr, SW_SHOWNORMAL);
        if (r <= 32) VLOG_ERR("Tap", "ShellExecuteW 失败 code=%lld", (long long)r);
        return;
    }

    VLOG_WARN("Tap", "未知 action: %S", e.action.c_str());
}
```

| 陷阱 | 说明 |
|---|---|
| ⛔ `CreateProcessW` 的 `lpCommandLine` 必须可写 | 传字面量可能被改写导致访问违规 |
| 只 `CreateProcessW` 不 `CloseHandle` | 每次点击泄漏两个句柄 |
| 在 UI 线程上 `CreateFileW` 管道 | 服务端没起来会卡住整个面板。**必须**独立线程 + 短超时 |
| `std::thread(...).detach()` 的异常安全 | 线程函数的**最外层**必须 `try/catch(...)`：线程里未捕获的异常会 `std::terminate` 整个 ShellHost |
| 用 `std::jthread` 代替 `detach` 更安全？ | ⚠️ 不能：`jthread` 析构会 `join`，而 Click 处理器返回时线程还在跑，`join` 会阻塞 UI 线程。**这里必须 `detach` + 全捕获** |
| ⛔ `ShellExecuteW` 的返回值**不是 BOOL** | `> 32` 才算成功，`<= 32` 是错误码（`SE_ERR_*`）。写成 `if (!r)` 会把失败当成成功 |
| `action=open` 别把 URL 塞进 `args` | `ShellExecuteW` 的 verb / file 是两个独立参数位；URL 必须走 `entry1.url` |

> **✅ 已实测**：`CreateProcessW(L"winver.exe")` 从 `Button.Click` 里调用成功拉起进程（UIA `InvokePattern` 触发，窗口标题「关于"Windows"」）。
> **⚠️ 未实测**：`action=pipe` 全链路（服务端 + 客户端 + UI 线程不阻塞）。

#### 4.2.6 内存与生命周期规则

| 规则 | 说明 |
|---|---|
| `VisualElement::Type` / `Name` 是 **BSTR** | ⛔ **不要 `SysFreeString`**。所有权在诊断框架，PoC 全程只读。⚠️ 所有权未正式验证 —— 保守起见只读、绝不释放 |
| `GetInitializationData` 返回的 BSTR **是**我们的 | ✅ 这个必须 `SysFreeString`（标准的 `[retval][out] BSTR*` 契约） |
| `GetIInspectableFromHandle` 拿到的 `IInspectable*` 是**带引用的** | 用 `winrt::take_ownership_from_abi` 接管，**不要**再手动 `Release` |
| `m_diag` / `m_vts` 在 `SetSite` 换新值前与析构时都要 `Release` | |
| `Tap::g_objects` 用 `InterlockedIncrement/Decrement` | `DllCanUnloadNow` 靠它判断 |
| ⛔ **TAP 实际上卸载不掉** | 我们把 `this` 交给 `AdviseVisualTreeChange` 且**从不** `UnadviseVisualTreeChange`（没必要：下一块面板打开时还要用同一个对象）。框架持有该回调引用 ⇒ `g_objects` 持续 ≥ 1 ⇒ `DllCanUnloadNow` 永远 `S_FALSE`。**这是刻意的选择，不是缺陷**（§10.1） |
| 注入的按钮**不会**持有 `Tap` 引用 | `Click` 的 lambda 按值捕获 entry 配置，不捕获 `this`。"按钮存在"不是 TAP 卸载不掉的原因 |
| 单例互斥体句柄 `m_mutex` 由 `Tap` 持有 | 用 `UniqueHandle`；析构时自动关 ⇒ 进程退出即消失（这正是 `TapProbe` 依赖的语义） |

### 4.3 原生代码的硬性约束清单（全部是踩过的坑）

⛔ **编码前必读**。每条都对应一次真实失败。

| # | 约束 | 症状 | 正确做法 |
|---|---|---|---|
| 1 | `DllMain` 里不能做重活 | 死锁 / 注入超时 | 只 `DisableThreadLibraryCalls` + `CreateThread` + 返回 TRUE |
| 2 | ⛔ 不用 CRT 流写日志 | **静默只写一个 BOM，日志全丢**（实测） | `CreateFileW` + `WriteFile`，`FILE_SHARE_READ\|WRITE`，`OPEN_ALWAYS`（§3.2 已封装） |
| 3 | ⛔ `DllGetClassObject`/`DllCanUnloadNow` 必须用 `STDAPI` | `error C2375: 重定义；不同的链接` | `combaseapi.h` 里它们是 `WINOLEAPI`（`EXTERN_C HRESULT STDAPICALLTYPE`）；导出靠链接器 `/EXPORT:`。**不要**用 `__declspec(dllexport)` + `extern "C" HRESULT __stdcall` |
| 4 | 需要装 `Button.Click` 事件 | 找不到 `Click` | `#include <winrt/Windows.UI.Xaml.Controls.Primitives.h>`（`Click` 在 `ButtonBase` 上） |
| 5 | 需要 `Panel::Children()` / `IVector` | 编译错误 | `#include <winrt/Windows.Foundation.Collections.h>` |
| 6 | `windows.h` 的 `GetCurrentTime` 宏与 cppwinrt 成员名冲突 | `warning C4002` | `#include <windows.h>` 之后 `#ifdef GetCurrentTime / #undef GetCurrentTime / #endif` |
| 7 | 本机 cppwinrt 版本**没有** `winrt::IInspectable` | `IInspectable 不是 winrt 的成员` | 用全名 `winrt::Windows::Foundation::IInspectable` |
| 8 | `UIElementCollection` **没有** `Remove(UIElement)` | `C2039: "Remove" 不是 ... 的成员` | 它是 `IVector<UIElement>` + `require<IUIElementCollection>` → `IndexOf(el, idx)` + `RemoveAt(idx)` |
| 9 | `Grid::SetColumn` 参数是 `FrameworkElement` | `C2664: 无法将 UIElement 转换为 FrameworkElement` | 先 `try_as<WUX::FrameworkElement>()` 再传 |
| 10 | `TransformToVisual` 在 `UIElement` 上，不在 `DependencyObject` 上 | `C2039` 一串连带错误 | 参数类型用 `WUX::FrameworkElement const&` |
| 11 | 已加载的 DLL 文件被写锁定 | `LNK1104: 无法打开文件 ...dll` | 迭代时停 ShellHost；部署时**先停进程再替换文件**（§7.4） |
| 12 | 所有 COM 边界必须吞异常 | 异常穿过 COM 边界 → shell 崩 | 每个导出/回调整体 `try { } catch (...) { VLOG_ERR(...); }`，返回 `S_OK` |
| 13 | ⭐ INI 编码 | 中文按钮文字乱码（UTF-8 无 BOM）/ 设置被静默忽略（UTF-8 有 BOM：键都找不到） | 用 `Ini::WriteAll`（UTF-16LE + BOM）+ `GetPrivateProfileStringW`（§3.3）。**C++ 轨道下 App 与 TAP 共用一份实现，结构上不可能不一致**。✅ T2 实测：只有 UTF-16LE+BOM 正确；另 `WritePrivateProfileStringW` 对**全新文件**会写成 ANSI（见 §3.3） |
| 14 | CRT 用 `/MT` 静态链接 | 目标机缺 VC++ Redistributable 时 `LoadLibraryW` 返回 NULL → 注入报 `RemoteLoadReturnedNull` | `/MT`（含 Launcher/Tap） |
| 15 | cppwinrt 需要 `WindowsApp.lib` | 链接错误找不到 `RoActivateInstance` 等 | Tap：`/link WindowsApp.lib ole32.lib`；Launcher：只要 `ole32.lib` |
| 16 | 记日志要带 tid | 无法判断回调在哪个线程 | `Log::Write` 固定输出 `GetCurrentThreadId()`；判断"是否在 UI 线程"的唯一手段 |
| 17 | ⭐ `NOMINMAX` + `WIN32_LEAN_AND_MEAN` 必须全局定义 | `std::min/max` 被宏替换，报出莫名其妙的错误 | 放在 `VolumeMixerExtender.props` 里 |
| 18 | ⭐ `PROCESSENTRY32W`/`MODULEENTRY32W.dwSize` 每次调用前都要设 | 快照 API 第一次就失败 | 构造时初始化；不要复用未重置的结构 |
| 19 | ⭐ `ConnectNamedPipe` 的合法失败**有两种**：`110`（已连上）/ **`232`（连上又关了，数据仍可读）** | 间歇性丢点击（"App 刚启动"的窗口里最易命中） | 两种都当作"可以进读循环"；另 `ReadFile` 的 `109` 是正常收尾（§3.13，实测见 `08-pipe-action-chain.md`） |
| 20 | ⛔ `std::thread` 函数最外层必须 `try/catch(...)` | 未捕获异常 → `std::terminate` → **ShellHost 崩** | 所有线程入口（含 `detach` 的）都包全捕获 |
| 21 | 线程停止要用 `std::jthread`/`stop_token` | 析构时 `join` 卡住 / 无法中断阻塞等待 | 统一用 `std::jthread` + `stop_token`；⚠️ 但 Click 里的 detach 线程除外（见 §4.2.5） |
| 22 | ⛔ **`CreateProcessW` 不解析 `.lnk` 快捷方式** | `entry1.exe` 配成快捷方式 → 点击**什么都没发生**，只在日志里留一行 `GetLastError=193`（`ERROR_BAD_EXE_FORMAT`） | ✅ 实测确认（`lnkprobe.cpp`）。shell 解析快捷方式（目标重定向、参数、工作目录、环境变量），`CreateProcessW` 不做。⇒ 要快捷方式效果必须显式 `explorer.exe "<lnk>"`（§2.3） |
| 23 | ⛔ **无 BOM 的 UTF-8 源码 + 中文注释** | `warning C4819`，进而 **`error C2001: 常量中有换行符`** + `C1075`；报错行看着完全正常，**极难定位** | MSVC 无 BOM 时按**系统 ACP**（本机 936）解读源码；某个中文字的 UTF-8 尾字节是 `0x5C`（`\`），恰好把字面量的收尾引号"吃掉" ⇒ 字面量跨行。**编译参数加 `/utf-8`**（`build.cmd` 已加；§7.3） |
| 24 | ⛔ **`InitializeXamlDiagnosticsEx` 的 initData 超过 259 字符会静默失效** | 没有任何错误信号：`hr=S_OK`，`GetInitializationData` 也返回 `S_OK`，只是 BSTR 长度为 0 ⇒ **配置神秘丢失** | 配置走**直投通道**（§2.2.1），initData 只当面包屑；超限时**主动打警告日志**（附长度），否则事后无从判断 |
| 25 | ⛔ 用 `wcslen` 量 BSTR 长度 | BSTR 允许内嵌 `\0` ⇒ 把"内容不同"误判成"内容相同" | 用 `SysStringLen(bstr)` |
| 26 | ⚠️ 自己实现哈希用于"配置是否一致"的比对 | 哈希种子/算法与外部实现不一致 ⇒ 日志里的哈希**无法被第三方独立复核** | 用**标准 FNV-1a 64**：偏移基 `0xCBF29CE484222325`（⚠️ 网上大量资料误写成 `1469598103934665603`，**少一位**），按 UTF-16 码元逐位异或；空串哈希应等于偏移基（最好的自检） |
| 27 | ⚠️ **`CreateProcessW(lpApplicationName=NULL, 未加引号的含空格路径)`** | ⚠️ **可能启动错的程序**：该 API 会对命令行**逐段前缀试探**，前缀处存在同名 exe 就启动它（已复现：`C:\...\Temp\a b c\x.exe` 不加引号时启动了 `C:\...\Temp\a.exe`）。**平时能跑，前缀处一旦有同名文件就静默跑错程序** | **两个都做**：① `lpApplicationName` 显式传 exe 路径；② 命令行里路径**加引号**。最好把配置拆成 `entry1.exe` + `entry1.args`，拼装放进 `Contract`（可单测）<br>⚠️ 这是**正确性**问题，不是安全问题（同用户上下文，不跨权限边界） |
| 28 | ⚠️ `lpCommandLine` 传 `const wchar_t*` 字面量 | 行为未定义（API 会**就地修改**该缓冲） | 复制到 `wchar_t[]` 临时缓冲再传（PoC 用 `lstrcpynW`/`swprintf_s`） |
| 29 | ⛔ 点击处理里 `WaitForSingleObject(子进程句柄)` | **阻塞 ShellHost 的线程** ⇒ 点一下卡住整个任务栏 | 拿到 `PROCESS_INFORMATION` 就关句柄走人，不要等 |

---

## 5. 关键算法与不变量

> 这一节是项目的核心知识，**与语言无关**。本文给自包含的完整说明（压缩版），逐条依据都来自实测。

### 5.1 `Footer` 定位算法

**✅ 实测的祖先链**（TAP 日志里 `up[]` 就是这个顺序）：

```text
Button            ← 模型按钮「更多音量设置」，样式与位置基准
  → ContentPresenter          up[0]
    → ContentControl          up[1]   ← 这一"行"的逻辑内容
      → ContentPresenter      up[2]   ← ★ ItemsControl 为它生成的 item container
        → StackPanel[Vertical] up[3]  ← ★★ ItemsPanel（纵向！这就是必须包 Grid 的根本原因）
          → ItemsPresenter     up[4]
            → ItemsControl     up[5]  ← Name = "Footer"（我们匹配的那个）
              → Border         up[6]
                → ContentPresenter up[7][PageContent]
                  → Grid[FullScreenPageRoot] up[8]
                    → ...（继续向上：PageWindow / FullScreenPage / L2Frame / ControlCenterView）
```

**算法（`InjectIntoRow` 前半段）**：

```cpp
WUX::DependencyObject child = model, cur = model, itemsPanel = nullptr, container = nullptr;
for (int i = 0; i < 12 && cur; ++i) {
    auto p = WUXM::VisualTreeHelper::GetParent(cur);
    if (!p) break;
    if (p.try_as<WUXC::ItemsPresenter>()) {     // 命中：说明 cur 就是 ItemsPanel
        itemsPanel = cur;                       //   → StackPanel
        container  = child;                     //   → 上一次循环里的那个（item container）
        break;
    }
    child = cur;                                // 记住"上一个"，它才是 panel 的直接子节点
    cur   = p;
}
```

| 判定 | 为什么这么写 |
|---|---|
| 用 `ItemsPresenter` 当"锚"而不是数层数 | 层数随模板变化；`ItemsControl → ItemsPresenter → ItemsPanel` 是 XAML 语义约定 |
| 用 `child` 而不是 `cur` 作为 container | 命中时 `cur` 已是 ItemsPanel；**panel 的直接子节点才是 item container**。这是最容易写错的一处 |
| 上限 12 层 | 实测只需 5 层。留余量但不无限走 |
| 参数类型是 `FrameworkElement` 不是 `DependencyObject` | 后续要用 `TransformToVisual`（§4.3 坑 10） |

**找不到怎么办**：返回 `false` → 走兜底（往 `ItemsControl.Items()` append 一项）。
兜底的**已知后果**（✅ 实测）：因为 ItemsPanel 是纵向的，按钮落在**第二行**，footer 高度 48 → 78。
**这是可接受的降级**（功能可用、位置不理想），但必须在日志里明确写出"走了兜底路径"。

### 5.2 同行右对齐算法（本项目核心难点）

**问题**：底栏 `ItemsControl` 的 `ItemsPanel` 是**纵向** `StackPanel` ⇒ **append 一项必然新起一行**（✅ 实测 48→78，按钮掉到第二行）。

**被否决的三个方案**：

| 方案 | 为什么否决 |
|---|---|
| 把 `ItemsPanel.Orientation` 改成 `Horizontal` 再 append | ① 横向 `StackPanel` 用**无限宽度**测量，`HorizontalAlignment` 完全失效 → 仍无法右对齐；② 原行 container 从"撑满 358"缩到"内容宽度"，`更多音量设置` 的 hover 高亮跟着缩水（视觉回归） |
| 往 `ItemsControl.Items()` append 一个含 `Grid` 的项 | 还是新起一行 —— 问题在 panel 的排布方向，不在项的内容 |
| 用 `TransformToVisual` 测量模型按钮内边距再设 `Margin.Left` | ✅ **实测失败**：注入发生在布局之前，`ActualWidth()` 是 0，算出 354px 荒谬边距；且之后 `SizeChanged` 不再触发，错位被永久固化（UIA 矩形变成 `∞`）。见 §5.5 |

**采用方案：把原行"包"进一个两列 `Grid`**

```text
改前：  ItemsPanel(StackPanel, Vertical)
            └─ ContentPresenter  ← item container（原行，宽度 = 358）
                 └─ ... → Button[更多音量设置]

改后：  ItemsPanel(StackPanel, Vertical)
            └─ Grid  ← 新加的两列容器
                 ├─ Col0 (*)    : ContentPresenter  ← 原行（宽度仍 = 358 - 按钮宽 - 边距）
                 │                   └─ ... → Button[更多音量设置]   位置不变
                 └─ Col1 (Auto) : Button[我们的入口]                 右对齐
```

**精确操作序列（顺序不能换）**：

```cpp
// ① 建 Grid，两列
WUXC::Grid grid;
auto starCol = WUXC::ColumnDefinition();
starCol.Width(WUX::GridLength{ 1.0, WUX::GridUnitType::Star });     // 列 0
auto autoCol = WUXC::ColumnDefinition();
autoCol.Width(WUX::GridLength{ 1.0, WUX::GridUnitType::Auto });     // 列 1
grid.ColumnDefinitions().Append(starCol);
grid.ColumnDefinitions().Append(autoCol);

// ② 先把原行从 ItemsPanel 取出（★ 必须先 IndexOf 再 RemoveAt，§4.3 坑 8）
uint32_t holderIndex = 0;
if (!panel.Children().IndexOf(holder, holderIndex)) return false;   // 不在 panel 里 → 兜底
panel.Children().RemoveAt(holderIndex);

// ③ 原行放进列 0；我们的按钮放进列 1
WUXC::Grid::SetColumn(holder, 0);
grid.Children().Append(holder);
WUXC::Grid::SetColumn(btn, 1);
btn.HorizontalAlignment(WUX::HorizontalAlignment::Right);
btn.VerticalAlignment(WUX::VerticalAlignment::Center);
grid.Children().Append(btn);

// ④ Grid 放回 ItemsPanel
panel.Children().Append(grid);
```

| 设计点 | 为什么 |
|---|---|
| ⭐ **列 0 必须是 `Star` 而不是 `Auto`** | `Auto` 列测量时给无限宽度 → 原行缩到内容宽度 → `更多音量设置` 的 hover 高亮缩水。`Star` 让原行保留剩余全部宽度，**位置与外观与注入前完全一致**（✅ 实测仍是 `(2193,1420) 94x40`） |
| 为什么"取出再放回"而不是"往 panel append 第二个孩子" | panel 是纵向的，直接 append 就是第二行 |
| 右边距 `4` | ✅ 底栏左边距也是 4（底栏 x=2189、模型按钮 x=2193）→ 取 4 得到对称。结果：我们的按钮右边缘 2543 = 2547-4 |
| 垂直对齐 `Center` | ✅ 模型按钮中心 y=1440；我们的按钮中心 y=1439（差 1px 是取整） |
| 幂等 | ⛔ **不能用"记住 Footer 指针"**。早期写法 `g_lastInjectedFooter == get_abi(footer)`，理由是"面板每次打开重建元素、句柄会变，所以不会误判" —— ❌ **已被实测证伪**：元素确实重建，但**分配器会复用同一地址**，旧守卫因此把新树误判成处理过的，**按钮被静默跳过**（实测日志里两次 `Footer appeared` 拿到同一 handle）。✅ 正确做法：**按内容判定** —— 在 Footer 子树里找 `AutomationId == L"VmExtEntry"` 的按钮，找不到才注入（§5.4 L3） |

**✅ 实测的最终几何（连续两轮完整 cycle 复现一致）**

| 元素 | 屏幕矩形 | 说明 |
|---|---|---|
| `Footer` | `(2189,1417) 358x48` | 高度仍 48 → **没有第二行** |
| `更多音量设置` | `(2193,1420) 94x40` | 与注入前完全一致 |
| 我们的按钮 | `(2472,1419) 71x40` | 同行、右边缘 2543、高 40 与模型一致 |

### 5.3 样式继承算法

**复制清单（`BuildEntryButton`）**：

| 属性 | 来源 | 为什么必须复制 |
|---|---|---|
| `Style` | `model.Style()`（非 null 才设） | 底栏按钮的模板/圆角/间距大多在 style 里 |
| `MinWidth` / `MinHeight` | model | 防止内容更长的按钮被压小 |
| `Padding` | model | 影响点击区与文字间距 |
| `CornerRadius` | model | 悬停高亮的圆角 |
| `FontSize` / `FontWeight` | model | 字形一致 |
| `HorizontalContentAlignment` / `VerticalContentAlignment` | model | 文字在按钮内的对齐 |
| `Foreground` | model | 文字颜色（含浅色/深色主题差异） |
| ⭐ **`Height`** | 见下方规则 | **决定 hover 高亮框的高度** |

> **实测外观（说明为什么必须复制 `Style` + `Foreground`）**：2026-10-03 逐像素取样证明，
> 底栏按钮**静止时无边框、无填充** —— 它是**文字式按钮，不是带框按钮**。文字核心 `#5a535b`
> 叠在背景 `#e8d4e8` 上正好是 **60.6% 前景**（等效 `TextFillColorSecondary`），
> 且 R−B 差 = 0 ⇒ **中性灰，不是强调色**。
> 几何：`94x40` 框 = 文字 `72` + 左右各 `11px`；「更多音量设置」6 个汉字 = 72px ⇒ `FontSize = 12`。
> 完整取样数据见 `../design.md` §7.5.1。

**不复制、而是显式设定**：

| 属性 | 我们设成 | 原因 |
|---|---|---|
| `Width` | **不设** | 我们的文字长度与模型不同，设死会截断或留白 |
| `HorizontalAlignment` | `Right` | 这是整个需求的目标 |
| `VerticalAlignment` | `Center` | 与模型在行内垂直居中一致 |
| `Margin` | `{8, 0, 4, 0}` | 左 8 是与模型的最小间距；右 4 见 §5.2 |
| `Background` | **不设** | 交给 `Style` / 主题资源；硬设会破坏 hover/press 变色 |

**⭐ `Height` 的规则（本算法最易出错处）**

```cpp
// 读显式属性，绝不"测量"
double h = model.Height();          // 未设置时，XAML 的 double DP 是 NaN
if (!(h > 0)) h = model.MinHeight();
if (!(h > 0)) h = 40.0;             // 兜底常量：✅ 本机实测模型按钮渲染高度就是 40
btn.Height(h);
btn.MinHeight(h);
```

✅ **实测依据**：模型按钮的 `Height` 是**显式 `40.0`**、`MinHeight` 是 `0.0`。所以这一行能在**注入当刻**就把高度定死，**完全不依赖布局时机**：

```
model metrics: Height=40.0 MinHeight=0.0 ActualH=40.0 Style=yes
-> TestLink height forced to 40.0
```

| 反面做法 | 为什么不行 |
|---|---|
| 读 `model.ActualHeight()` | 注入发生在布局之前 → 拿到 0 → 高度错（且 0 会让按钮不可见） |
| 用 `SizeChanged` 延后设定 | 面板树可能已布局完成，事件不再触发 → 永不生效 |
| 干脆不设高度，靠 `Style` | ✅ 实测：不设时渲染成 **71x30**，与模型的 40 不一致 → **hover 高亮框明显偏小** |

> **通用原则**：显式属性（`Height`/`MinHeight`）**永远优先于测量值**（`ActualWidth`/`ActualHeight`）。见 §5.5。

### 5.4 幂等与去重（三层）

**为什么重要**：`Footer` 的 Add 事件在一次面板打开里可能出现多次；App 重启、用户连点"重新注入"也会再注入一次 Launcher。任一层缺失都会出现**两个按钮**。

| 层 | 位置 | 机制 | 覆盖场景 |
|---|---|---|---|
| **L1** | `Orchestrator::TryInject` | 注入前 `TapProbe::IsAlive(pid)`，已就绪则跳过 | App 重启 / 重复点菜单 |
| **L2** | TAP `SetSite` | 命名互斥体 `Local\VmExt.Tap.Singleton.<pid>`；`ERROR_ALREADY_EXISTS` → 休眠 | L1 失效（多端点会话、多个 Launcher 竞态） |
| **L3** | TAP `InjectIntoFooter` | **按内容判定**：在 Footer 子树里找 `AutomationId == L"VmExtEntry"`，找不到才注入 | 同一 `Footer` 的 Add 事件被重复投递；以及"树被重建" |

> ⛔ **L3 为什么不能用"记住 Footer 指针"**（原设计，已实测证伪）
>
> 原写法 `static void* g_lastInjectedFooter; if (g_lastInjectedFooter == get_abi(footer)) return;`，
> 文档原话是"面板每次打开重建元素、句柄会变，所以不会误判"。**前半句对，后半句错**：
>
> * 元素确实会重建（早前已实测）；
> * 但**分配器会把同一地址复用给新的 `Footer`** —— ✅ 实测抓到过：两次面板打开，
>   `Footer appeared` 拿到**同一个 handle**，守卫遂把新树误判成"已处理"，
>   **按钮被静默跳过**（日志里连一行都没有，因为当时是裸 `return`）。
>
> 本质错误：**用"身份"（指针地址）表达"状态"**。地址不是身份，它只是"当时恰好没被占用"。
> 而且失效是**静默**的 —— 表现成"有时面板打开没有按钮"，归因极难。
>
> ✅ **改法**：让判据**自证** —— 直接问"这个 Footer 里有没有我的按钮"。
> 给按钮打上 `AutomationProperties.AutomationId = L"VmExtEntry"` 后，这个检查既准确又可读，
> 还顺带自愈"按钮被 XAML 重新模板化移除"的情况（指针守卫在这种情况下反而会**永久阻断**再注入）。
>
> ⭐ 可推广的教训：**幂等判定优先用"结果是否存在"，而不是"我记不记得做过"。**
> L2 的互斥体之所以可靠，正是因为它由**内核对象**仲裁（所有权明确），而不是靠我们自己记地址。
> 同理，C++ 轨道里"配置是否送达"也应该看**内容哈希**而不是"我调用过导出没有"。

**⚠️ L1 的边界**：`TapProbe` 只认"TAP 已就绪"。若 TAP 已加载但**尚未完成 SetSite**（互斥体还没创建的毫秒级窗口），L1 会判定"没有 TAP"而再注入一次 —— 此时 L2 兜住（先创建互斥体的赢）。

**为什么"先到者赢"**：后到的实例难以判断先到者的状态；先到者已开始工作，让后到者休眠是唯一安全的选择。

### 5.5 布局时机不变量（全部由踩坑换来）

**不变量 I1**：
> **任何依赖 `ActualWidth` / `ActualHeight` 的取值，必须先判 `> 0`。** 为真才使用；否则走"显式属性"或"延后重试"路径。

**违反 I1 的实测后果（完整复盘）**：

```text
想法：用 TransformToVisual 测量模型按钮相对 ItemsPanel 的位置，据此算右边距 —— 更"优雅"
实际：注入发生在布局之前 → model.ActualWidth() == 0
      → inset = 358 - (4 + 0) = 354  →  btn.Margin { 8, 0, 354, 0 }
      → 按钮被推出底栏
      → 且 panel.SizeChanged 不再触发（树早就布局完了，尺寸不变）
      → 错位被永久固化：UIA 读到的矩形变成 ∞
      → 验证脚本 footer-map.ps1 在 [int] 转换时抛异常，把真实症状掩盖成"脚本挂了"
```

| 教训 | 落地规则 |
|---|---|
| 布局前测量会拿到 0 | 先判 `> 0`（I1） |
| 定了错的东西不一定有第二次机会 | 能一次定死就用显式属性（`Height`） |
| 验证脚本本身也会成为盲区 | 矩形转换必须容忍 NaN/∞（✅ 已修 `footer-map.ps1`） |

**不变量 I2**：
> **需要在 UI 线程上做、但当前不在 UI 线程的工作，必须 `CoreDispatcher::RunAsync` 排队，不得 `Sleep` 等待。**

范式见 §4.2.4 的 `TryInjectLater`（`HasThreadAccess()` 为真时直接同步执行，避免多绕一圈）。

**不变量 I3**：
> **注入/改动 XAML 之后，不要假设布局已经更新。** 需要"改动后的几何"时，用另一个进程的 UIA 去读（§8.3），不要在 TAP 里读完立刻自证。

### 5.6 ⭐ 资源所有权不变量（C++ 轨道独有）

C++ 轨道用静态 CRT，这带来一条**必须遵守的规则**：

> **不变量 I4：共享静态库的代码在每个二进制里各有一份 CRT 堆。绝不允许跨 DLL 边界传递"由 CRT 分配的内存"或"含 CRT 分配资源的对象"（`std::string`/`std::vector`/`std::wstring`/`FILE*`），也不允许在一个二进制里分配、在另一个二进制里释放。**

| 场景 | 是否安全 | 说明 |
|---|---|---|
| App 内 `Ini::WriteAll(path, lines)` | ✅ | 分配与释放都在 App 的 CRT 堆里 |
| TAP 内 `Contract::Parse(...)` | ✅ | 分配与释放都在 TAP 的 CRT 堆里 |
| App 把 `std::wstring` 传给 **Launcher** | ✅ | 它们在不同进程，物理上不可能发生 |
| App 里 `new` 一个对象，把它交给"另一个 DLL 导出的函数"释放 | ⛔ **禁止** | 两个二进制各自的 `operator delete` 操作的是各自的堆 |
| 在同一进程里让 App 与 Launcher 共享一个 `std::mutex` 对象 | ⛔ **禁止** | 每个二进制有自己的一份 STL 实现状态 |

**本项目为什么天然安全**：三个二进制在**不同进程**里运行（App 一个进程，Launcher/Tap 在 ShellHost 里），跨进程只能通过内核对象与文件通信。所以 I4 主要是**在 App 进程内部**（App.exe 与它加载的 DLL）需要注意 —— 而 App 不加载自己的 DLL，所以实际上不会触发。

> **但要把这条写进文档**：如果将来为了复用而把 `VmExt.Shared` 从静态库改成 **DLL**（例如想让 App、Launcher、Tap 共享一个物理 DLL），那么 I4 立刻变成必须严格处理的问题 —— 届时的正确做法是用 `CoTaskMemAlloc`/`LocalAlloc` 这类"中立分配器"传内存，或者干脆**不要改**。
> **建议：保持静态库。** 代价是每个二进制里多一份工具代码（几 KB），换来的是"不可能踩 I4"。

---

### 5.7 入口接管与页面内容替换（★ 新机制）

> 本节是目标修订后的**主路径**。§5.1–§5.6 描述的底栏注入法**仍然复用**（自定义页需要底栏按钮），
> 但"入口"的语义已从"底栏注入的按钮"转移到 L1 的 `VolumeL2Button`。
> 设计背景与取舍见 `docs/design.md` §7。

#### 5.7.1 目标入口

| 项 | 值 |
|---|---|
| 元素 | L1 的「选择声音输出」 |
| `AutomationId` | **`VolumeL2Button`** |
| `Name` | `选择声音输出`（与 tooltip 一致，**按 `AutomationId` 匹配最稳**） |
| 父级 | `ControlCenterRegion` 的直接子元素，与音量条 `Slider` 同级 |

实测数据：`docs/baseline-before-injection/06-l1-main-panel-tree.md`。

#### 5.7.2 ⛔ 不要拦导航

L1 树里还有 `Microsoft.QuickAction.ProjectL2` —— **`L2` 后缀是"导航到二级页"的命名规律**，
说明进入 L2 的入口是**一组**而非唯一一个。在 `L2Frame` 上挂 `Navigating` 并无条件 `Cancel`
会**误伤「投影」等兄弟入口**；且 Cancel 之后帧停在 L1，我们的页面无处安放。

⇒ **不碰导航，不碰按钮。** 让系统照常导航，我们改页面内容。

#### 5.7.3 算法

```text
① 触发：OnVisualTreeChange 命中 name == "Footer"（沿用已验条件，见 §5.1）
② 从 Footer 沿祖先链上溯到 PageWindow（§5.1 已有该链）
③ 在 PageWindow 下按 Name 找 ListContent（ScrollViewer）
④ 幂等判定：若 ListContent.Content 已是我们的根节点 → 直接返回（勿重复替换）
⑤ 首次：g_systemContent = ListContent.Content()   ← 保存引用，勿释放
         ListContent.Content(BuildCustomPage())
         g_customMode = true
⑥ 切换：Content 在 g_systemContent 与我们的根节点之间来回
```

**为什么触发点仍用 `Footer`**：它是**已实测稳定**的锚点（§5.1），且与 `ListContent` 同属
`PageWindow` 的子元素、在页面构建时一同出现。用一个已验证的锚点去定位另一个元素，
比直接赌 `ListContent` 的事件时序更稳。

#### 5.7.4 ⚠️ 界面只能逐元素构建（最大成本项）

**没有 XAML 标记编译** —— 那需要 UWP 工程体系（`xamlcompiler` + 应用包结构），
在注入用的普通 DLL 里不成立。自定义页只能逐元素构建。

> ⚠️ **构建方式已更正**：本文早前写的是 `IVisualTreeService::CreateInstance`，
> 但 **PoC 实际用的是 C++/WinRT 直接激活**（`WUXC::ComboBox c;`，即 `RoActivateInstance`）——
> ShellHost 内 `Windows.UI.Xaml` 已加载，类型工厂可用。**按已验的方式走**。
> 见 `verified-after-injection/10-page-swap-capability.md`。

| 元素 | 代价 |
|---|---|
| 两个下拉框 | 每个 `ComboBox` + N 个 `ComboBoxItem` 手工创建 |
| 「录制模式」复选框 | 一个 `CheckBox` + **紧凑模板**（默认 `MinHeight=32`/方框 `20px` 会撑高标签行，见 §5.7.7） |
| 应用列表 | N 项 ×（图标 + 名称 + `Slider` + 静音键）全部手工 |
| 事件 | 每个 `Slider` 单独挂 `ValueChanged`；`CheckBox` 挂 `Checked`/`Unchecked` |

参照 §5.2 中单个 `Button`（含样式抄写）约 60 行，一个带应用列表的页面保守估计
**1500–2500 行 C++**。**排期时不可按"写个 XAML"估算。**

> ✅ **已实测**：`ComboBox` / `ComboBoxItem` / `ListView` / `ListViewItem` / `Slider` / `StackPanel` /
> `Grid` / `TextBlock` / `ScrollViewer` / `Image` **全部可激活**（T14，2026-10-03）。
> `ToggleButton` 属 `Controls.Primitives`，需另引该命名空间 —— **已验可用**（T18）。
> ✅ `CheckBox`（§5.7.7 需要）**已验证可激活**：见 `verified-after-injection/11-checkbox-capability.md`。

#### 5.7.5 新增不变量

| # | 不变量 | 理由 |
|---|---|---|
| **I5** | 系统页的 `Content` 引用必须**保存且不得释放**，切换时原样写回 | 丢失引用 ⇒ 系统页再也回不来（AT-20） |
| **I6** | 替换必须**幂等**：以"`Content` 是否已是我们"为判据，**不要用"我记不记得做过"** | §5.4 已记录过指针身份判定的教训（分配器会复用地址 ⇒ 静默跳过） |
| **I7** | 自定义页的所有元素必须**由 TAP 在 ShellHost 内创建** | 跨进程传递 XAML 对象不可能；只能在目标进程内 `CreateInstance` |
| **I8** | 替换动作只允许发生在 **UI 线程**（`OnVisualTreeChange` 本就在 UI 线程） | 改可视树非线程安全；且不得在此做阻塞 IO（§2.4 的 `action=pipe` 教训） |

#### 5.7.6 底栏：三态 + 三格复用

底栏仍按 §5.2 注入，但**三个格子每页给不同文案与动作，且始终是同一个 `Footer` 元素**：

| | 左格 | 中格 | 右格 |
|---|---|---|---|
| 系统页 | —（隐藏） | —（隐藏） | `MixerExtender` |
| 自定义页 | `清除重定向` | `设置` | `SystemMixer` |
| 设置页 | `GitHub` | `返回` | （占位，先空着） |

**四个元素全部是纯文字，没有图标**（中格不是齿轮图标）。样式一律由 §5.3 的复制算法得出：
底栏项**静止时无边框、无填充**，`Foreground` 等效 `TextFillColorSecondary`（中性灰，非强调色），
内边距 `0 11px`、`FontSize = 12`。实测依据见 `../design.md` §7.5.1。

**系统页我们只加右侧一个按钮**，其余一概不碰。

⛔ **实现约束一：每格只挂一个 handler，进来先读"当前页"再分发。**
`Footer` 是 `PageWindow` 的子元素，**不随 `ListContent` 的内容一起被换掉**，
所以三个元素**只注入一次**并常驻。
**绝不能"每到一页就新挂一个 `Click`"** —— `Button::Click` 只能注册、不能注销，
handler 会累积，来回切两页之后一次点击就会触发两次。

```text
左格 onClick:  当前==自定义页 ? 清除重定向 : (当前==设置页 ? 打开 GitHub : 无)
中格 onClick:  当前==自定义页 ? 进设置页   : (当前==设置页 ? 返回自定义页 : 无)
右格 onClick:  当前==自定义页 ? 切系统页   : (当前==设置页 ? 无 : 切自定义页)
```

⛔ **实现约束二：可见性与文案是两件事，别混。**
**可见性**只用于"系统页时左、中必须隐藏"（那两格是我们塞进系统那一行的，系统页不该有我们的东西）；
**文案/动作**一律靠上面的 dispatch。混在一起就会写出"每页重建底栏"的错误做法。

**右格的文案指"目标"而非"动作"**（仅系统页 ⇄ 自定义页这一对）：

| 当前显示的页 | 右格文字 | 动作 |
|---|---|---|
| 系统页 | **`MixerExtender`** | 切到自定义页 |
| 自定义页 | **`SystemMixer`** | 切回系统页 |
| 设置页 | **（占位）** | — |

⇒ 页面切换需要一个**新的动作类型**（如 `action=page`）。现有的 `exec` / `pipe` 都面向
"拉起外部进程"，页面切换是 in-proc 行为，复用它们会导致配置语义错位。

**左格 `GitHub` 用 `action=open`**（已定，2026-10-03）—— 它调 `ShellExecuteW(..., L"open", url, ...)`
走 shell 的 URL 关联解析，不复用 `exec` 的 `CreateProcessW`（URL 不是 exe，详见 §2.3 / §4.2.5）。

底栏左侧另需一个「清除重定向」按钮 —— §5.2 的两列网格需扩为**四列**：
`左格(Auto) | 弹性列(*) | 中格(Auto) | 右格(Auto)`。

#### 5.7.7 「录制模式」复选框（对接虚拟音频驱动方案）

UI 落点与语义见 `../design.md` §7.9.1，对应 `VirtualAudio-Record-Mirror-Plan.md`。

- **位置**：「默认输出设备」标签行的右端，**右对齐**，与标签同一行（不占额外高度）。
- **切换自动、双向对称**：

```text
勾选：  记住当前默认 D → 系统默认切到 V → R := D      标题 → 监听输出设备
取消：  系统默认切回 R（= 记住的 D）                   标题 → 默认输出设备
```

| | 系统默认输出设备 | 本行下拉框选的是 | 本行标题 |
|---|---|---|---|
| ☐ 未勾选 | = 下拉框选的那台 | 系统默认输出设备（render 端点，**排除 V**） | `默认输出设备` |
| ☑ 录制模式 | **`OC Virtual Speaker`**（V，音量硬锁 100%） | **监听设备 R**（render 端点，**排除 V**） | `监听输出设备` |

> ⚠️ **这推翻了方案 §0/§8 的「自动化：无（默认设备手动切换，无脚本、无看门狗）」** ——
> 现在切换由本复选框自动完成。`VirtualAudio-Record-Mirror-Plan.md` 已同步修订（§0/§8/§10）。

**实现约束**：

1. **V 永不显示** —— 枚举 render 端点时必须**过滤掉自己的虚拟端点**（按 FriendlyName / 硬件 ID 判定），
   两态的列表都过滤。否则用户能把它直接选成默认设备，绕过录制模式、让录制链空转（没有监听目标）。
2. **录制模式不持久化** —— **勾选状态**不跨系统重启保存，每次启动一律从"未勾选"开始。
   D **也只活在会话内存里**（用于"取消勾选时立刻切回"，不必等 Windows 自己滚）。
3. **残留不靠对账，靠驱动的「常开开关」** —— 见方案 §4.3。V 的插头默认「**未插入**」，
   只有我们显式闭合（录制模式打开时通过 IOCTL）才「已插入」；模式关 / 程序退出 / 崩溃 →
   驱动在 `IRP_MJ_CLEANUP` 上兜底回到「未插入」。
   ⇒ **不需要 `pendingRestore` / `previousDefaultId`、也不需要"启动时对账"** —— 残留结构上不可能存在。
   本侧要做的是：**录制模式开 → ① 让驱动闭合插头 ② 立刻把默认切到 V**（两件事必须都做）。
4. **必须用紧凑模板** —— WinUI `CheckBox` 默认 `MinHeight = 32`、方框 `20px`；
   而标签行只有 **16px** 高，直接用默认模板会把整行撑到 32。
   ⇒ 设 `MinHeight = 0` 并使用 16px 方框的模板。（线框稿实测：16px 方框下**行高保持 16 不变**。）

#### 5.7.8 设置页（子页面）

> 🅿️ **挂起（2026-10-03）**：先做 §5.7.9 的端点音量层。本节布局已定，**实现顺位后移**。

布局与定稿项见 `../design.md` §7.9.2。要点：

- **入口**：自定义页底栏中格的「设置」；**返回**：设置页底栏中格的「返回」。
- **「开机启动」= `ToggleSwitch`**（不是 `CheckBox`）。
  ⚠️ **新类型，尚未验证**（T14 的 10 个 + T18 的 `CheckBox` 都不含它）—— 见 §10.5 的 T19。
- **「从系统卸载」**：置底 + 危险色（`SystemFillColorCriticalBrush`）。
  XAML 侧靠一个 `RowDefinition Height="*"` 的空白行推到内容区底部。
  它**在内容区里**，不属底栏 —— 所以会随内容一起滚。
- ⭐ **「从系统卸载」= 退出接管、回落原生行为，不是删除软件**（已定，2026-10-03）：
  **不删程序文件、不卸驱动、不删配置**，只做 **删除开机自启项 + 重启 shell**。

```text
由 App 执行，顺序不可换：
  1. 写 enabled=0（vmext-tap.ini）   ← 先断"重新注入"；TAP 每次命中 Footer 时重读 ini ⇒ 立刻生效
  2. 停 Watcher 线程                  ← ⛔ 顺序关键，见下
  3. 删除开机自启项（AutostartEntry::Disable()：Run 值 + 系统禁用标记；见 §3.14.1）
  4. 重启 shell（explorer.exe）       ← ShellHost 换新进程 ⇒ 旧 TAP 连同注入一起消失 ⇒ 原生 UI 回来
  5. App 自己退出
```

  - ⛔ **第 1、2 步必须在第 4 步之前**：否则杀掉 ShellHost 后，Watcher 会立刻在新 ShellHost 上
    **重新注入**，卸载等于没做。
  - ⛔ **这五步必须全由 App 执行，不能由 TAP 执行**。两条致命原因：
    ① **TAP 活在 ShellHost 里** —— 第 4 步 = TAP 在 `Click` 回调栈上当场自杀，顺序没法保证；
    ② **只有 App 能在杀 ShellHost 之前先把 Watcher 停掉**（第 2 步）。
    ⇒ **卸载动作走 `action=pipe`**（点击 → 报文 → App 执行，如 `UNINSTALL`）。
    **pipe 不可用（App 已崩/未运行）时拒绝执行** + 改文案 + 记日志，
    ⛔ **绝不降级成"TAP 自己重启 shell"**（那就是半卸载）。
  - **第 3 步**：删干净（`Run` 值 + `StartupApproved\Run` 标记）。⛔ **不要只禁用** ——
    只禁用会在「任务管理器 → 启动」和「设置 → 应用 → 启动」里留一条灰项。
    ⚠️ 用户手动禁用过的话，Windows 是**往 `StartupApproved\Run` 写标记**、不删 `Run` 值 ⇒
    这一步必须**两个都删**：只删 `Run` 值会留下禁用标记，下次打开开关会立刻又被判成"被禁用"。
    ⚠️ 反过来说，**只读 `Run` 值是会撒谎的** —— 初值必须连禁用标记一起读。详见 §3.14.1。
  - **不删驱动是安全的**：V 的插头是**常开开关**（方案 §4.3）—— 驱动上电默认「未插入」，
    只有我们显式闭合才「已插入」。App 退出后没人闭合 ⇒ **V 结构性不可用** ⇒ 系统回落原生行为。
    ⇒ 卸载**不需要动驱动**，也**不需要重启系统**（这正是"直接重启 shell"能成立的原因）。
  - **重新接管**：程序文件还在 ⇒ 用户**手动运行一次 exe** 即可。
    ⇒ **App 启动时必须写 `enabled=1`**，覆盖卸载留下的 `0`，否则会出现"程序在跑但不注入"的诡异状态。
  - ✅ **不用管驱动**（2026-10-03 定）：**没有端点时 Windows 不会显示它** —— 宿主退出后没人闭合插头
    ⇒ V 是 `UNPLUGGED` ⇒ 系统自己的声音设置里也不会出现。⇒ 卸载不需要动驱动，也不会有"看得见的残留"。
- ✅ **标题行的系统后退键：保持系统默认行为，不拦**（已定，2026-10-03）。
  ⇒ 设置页会出现两个返回键且行为不同（标题行 = 退回 L1；底栏「返回」= 回自定义页）。
  **这是接受的取舍** —— ⛔ 不要再为此挂 `L2Frame.Navigating`（**原 T20 一并关闭，不必再验 `Cancel` 可写性**）。
- ✅ **「从系统卸载」的确认方式：连击 5 次**（已定，2026-10-03），**不用 `ContentDialog`**。

```text
hits = 0，文案 = 「从系统卸载」
  单击 → hits++
         hits < 5  → 文案 = 「再单击(5−hits)次从系统卸载」；**重置** 500ms 定时器（首次为 4）
         hits == 5 → 执行卸载
  500ms 内无下一次单击 → hits = 0，文案复位
```

  - **超时按"距上一次单击"算**（两两相邻 ≤ 0.5s），不是"5 次总时长"。
  - **第 1..4 次单击无任何副作用**，只改文案 ⇒ 复位是纯内存操作，无需回滚。
  - **必须用 `DispatcherTimer`**（回调改 UI 文案，`DispatcherTimer` 天生在 UI 线程）；
    ⛔ 不要用 `Task.Delay` / 线程池 + `Dispatcher.RunAsync`。
  - ⛔ **`hits` 是纯 UI 态**：只活在面板这一次打开期间，关面板即丢弃（**这是期望行为**，不需要持久化）。
  - **为什么不用 `ContentDialog`**：① 浮层盖住整个面板；② `XamlRoot` 是额外未验前置（原 T21）；
    ③ 防误触的意图连击已经满足（误触一次不会卸载）。⇒ **T21 可以不做**。
- ✅ **左格 GitHub 用 `action=open`**（已定，2026-10-03），见 §5.7.6 与 §4.2.5。
- **「显示驱动名」= `ToggleSwitch`，默认开**：控制设备名要不要带括号里的驱动名后缀
  （`扬声器 (Realtek(R) Audio)` ↔ `扬声器`）。**作用面三处，必须同步**：
  两个下拉框的值 / 端点音量每一行 / 应用行里的"重定向目标端点"。
  - ⛔ **判定方式：按"元素是不是设备名"，不能按"文本以 `(` 结尾"。**
    应用名里也有括号（`Microsoft Teams (工作或学校)`），按文本判定会把应用名削掉一截。
    我们这边每个 `TextBlock` 都是自己建的，所以天然知道它是设备名 —— **别偷懒去正则扫文本**。
  - **取值 Key**：`PKEY_Device_FriendlyName`（或 `PKEY_Device_DeviceDesc` + `PKEY_DeviceInterface_FriendlyName` 自己拼）；
    应用名走会话/进程信息，两者别混用一个取值函数。
  - ℹ️ **「显示驱动名」不省高度**：实测开关前后内容高度 603px → 603px 不变（行高由 `min-height:44` 钉死），
      只影响折行/截断。**别指望它缓解 §5.7.9 的溢出。**

#### 5.7.9 端点音量（每个设备一条）

布局与定稿项见 `../design.md` §7.9.3。要点：

- **粒度：每个端点一条** —— **不是"输出/输入各一条"**。每台设备单独调音量 + 静音。
- **枚举**：`EnumAudioEndpoints(DEVICE_STATE_ACTIVE)`，`eRender` 在前、`eCapture` 在后，**不加分组标签**。
  ⚠️ 用 `DEVICE_STATE_ACTIVE` 而不是 `DEVICE_STATE_ALL` ——「已禁用」「未插入」的一律不列。
- ⭐ **必须过滤掉 V**：与两个下拉框同一条硬约束（§5.7.7 约束 1）。
  **一处实现、两处复用**（下拉框 + 这里），不要写两份判定。
- ⭐ **采集侧收成一个折叠组**：渲染端点逐条展开；采集端点收成一行「输入设备（N）」+ 展开箭头，
  **默认不展开**，子行缩进 28px。⇒ 输入侧不再随设备数增长（§7.9.3 的"高度封顶"）。
- ✅ **溢出已接受，不做压缩**（2026-10-03 定）：收起态 603px 对可用 306px，靠**共用滚动区**消化，
  行高**保持 `44px`**（与 app 行等高）。⛔ 不要"顺手优化"成 40px、或给这一层加内部滚动、
  或把渲染端点也折叠 —— 那四个旋钮都已被明确否决（`../design.md` §7.9.3）。
- ✅ **安全 / 危险 API 的分界（2026-10-03 定，证据 `verified-after-injection/12-audio-interop-safety.md`）**：

  | 操作 | 在哪执行 | 为什么 |
  |---|---|---|
  | 枚举设备、读端点音量/静音、**读写**逐应用音量/静音 | **TAP 内联**（ShellHost 里） | 全走 SDK 文档化接口，实测无风险 |
  | **切系统默认设备**、**逐应用重定向**、**清空重定向** | **走 `action=pipe` → 宿主** | 未公开接口，**在 ShellHost 里试错 = 崩掉用户的 shell**；宿主崩了只是重启（2026-10-04 更正：当初的 `vtable[13]` AV 是探针槽位偏移所致，槽 13 就是 `SetDefaultEndpoint`） |
  | 开机自启、从系统卸载 | **走 `action=pipe` → 宿主** | 生命周期/进程身份原因（§5.7.8） |

  ⚠️ **代价要认**：`pipe` 是**单向**的，宿主不回包 ⇒ **切换结果拿不到确认**。
  ⇒ UI 用**乐观更新**（点了就改显示），下次打开面板重新枚举即与事实对齐。

  ⚠️ **未定论**：`IPolicyConfig` 的正确槽位，以及"AV 是不是 RDP 虚拟端点造成的"。
  本次探测在 **RDP 会话 + 虚拟端点**下进行（唯一渲染端点是 `远程音频`，采集端点 0 个），
  而 EarTrumpet 在真实硬件上大量使用同一路径且工作正常 ⇒ **留作实体机待验**。

- ✅ **滑块的高频回调走哪条路：已定方案 A —— TAP 在 ShellHost 内直接调 WASAPI**（2026-10-03）。
  `Slider.ValueChanged` 拖动时**每秒触发几十次** ⇒ **滑块流量一律不走 IPC**；
  `action=pipe` 继续**只承载"点击/命令"**（这就把 §2.4 的边界钉死了：pipe 不是数据通道）。
  本层与下一层「逐应用音量」同用这一条。

  方案 A 的**三条硬约束**（都必须实现，不是可选优化）：

  | # | 约束 | 说明 |
  |---|---|---|
  | **A1** | **WASAPI 封装两边共链** | TAP 与 App 都要用 `IAudioEndpointVolume`。⛔ **绝不能写两份** —— 两份实现 = 两份端点枚举顺序、两份 `DEVICE_STATE` 过滤、两份 V 过滤，迟早不一致。⇒ 抽成**静态库 / 仅头实现**，TAP 与 App 各链一份 |
  | **A2** | **外部改动要回写 UI** | 键盘音量键、系统自己的音量面板改同一台设备时，我们的滑块必须跟着动 ⇒ `IAudioEndpointVolume::RegisterControlChangeNotify`。⛔ 回调**不在 UI 线程**（COM 通知线程池）⇒ 回写 UI 必须 `Dispatcher.RunAsync` |
  | **A3** | **必须区分"拖动中"与"拖动结束"** | `Slider.ValueChanged` 分不清。外部回写时直接改 `Value` 会和用户正在拖的位置**打架**。⇒ 用 `Thumb.DragStarted` / `DragCompleted`（或 `PointerPressed`/`Released`）维护 `isDragging`，**拖动中忽略外部回写**。⚠️ WinUI `Slider` **没有** `IsDragging` 属性，别去找 |

- ⚠️ **A1/A2 带来两个必须先实测的点（本机就能验 —— 本机有 1 个渲染端点可读写）**：
  - **T23**：`Slider.ValueChanged` 里直调 `SetMasterVolumeLevelScalar` 的**单次往返耗时**。
    这是跨进程 COM 调用（到 `audiosrv`），若达数十 ms 且 UI 线程同步等待，拖动会顿。
  - **T24**：`RegisterControlChangeNotify` 的**回调线程**是否真不在 UI 线程（若不在而直接改 UI ⇒ 崩）。

- **音量读写**：`IMMDevice::Activate(IID_IAudioEndpointVolume)` →
  `GetMasterVolumeLevelScalar` / `SetMasterVolumeLevelScalar`、`GetMute` / `SetMute`。
  ⚠️ **不要用 `SetMasterVolumeLevel`（dB 版）** —— 线性标量版（0..1）才是滑块要的，
  dB 版要经过系统的音量曲线换算，容易和 Windows 自己的滑块对不上。
- ⚠️ **不要对 V 调用任何音量 API**：方案 §5.2 把 V 的音量节点做成 `min = max = 0 dB`，
  写了也会失败或被忽略。（V 已被过滤掉，这里是双保险。）

---

## 6. 状态机与错误处理（C++ 具体实现）

### 6.1 异常策略：分层，别搞混

C++ 轨道最容易出的架构错误是"异常策略不统一"。本项目的规则是**按层分工**：

| 层 | 策略 | 理由 |
|---|---|---|
| **in-proc 两段（Launcher / Tap）** | ⛔ **对外绝不抛**。所有 COM 方法/回调/DllMain 里的代码整体 `try/catch(...)`，捕获后只记日志并返回 `S_OK` | 异常穿过 COM 边界是未定义行为；而且**我们是在别人的进程里**，抛出去就是 shell 崩 |
| **共享静态库（Log / Ini / Str / Contract / Win32）** | 全部标注 `noexcept`；内部出错用**返回值**表达（`false` + `err` 字符串），**不用异常** | 它被 in-proc 两段链接，如果它抛异常，"对外绝不抛"就要求每个调用点都包 try，容易漏 |
| **控制面（App / Control）** | 用异常表达"不该发生"的错误（如 `GetLastError` 后的 `std::system_error`），但**线程入口与窗口过程必须整体捕获** | 控制面是我们自己的进程，异常是方便的；但托盘线程/窗口过程抛出去会终止进程 |

**统一入口处的捕获模板**（所有线程入口与 `WndProc` 都必须这样写）：

```cpp
// 线程入口
void Orchestrator::ThreadMain(std::stop_token st)
{
    try {
        // ... 全部工作 ...
    } catch (const std::exception& e) {
        VLOG_ERR("Orch", "线程发生未捕获异常: %s", e.what());
    } catch (...) {
        VLOG_ERR("Orch", "线程发生未知异常");
    }
    // ⛔ 绝不让异常离开这个函数
}
```

```cpp
LRESULT CALLBACK TrayApp::WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    try {
        auto* self = reinterpret_cast<TrayApp*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
        if (!self) return DefWindowProcW(hwnd, msg, wp, lp);
        return self->HandleMessage(msg, wp, lp);
    } catch (...) {
        // 窗口过程抛异常会终止进程 —— 必须吞掉
        return DefWindowProcW(hwnd, msg, wp, lp);
    }
}
```

### 6.2 HRESULT 到错误码的映射

| 来源 | 处理 |
|---|---|
| `Injector::InjectInto` | 返回 `inject::Error`（枚举），`win32` 字段保留原始 `GetLastError`，`Name()` 供日志 |
| `InitializeXamlDiagnosticsEx` | 返回 `HRESULT`。`SUCCEEDED(hr)` 才成功；`E_INVALIDARG` 视为"参数不被接受"并**停止探测循环**（§4.1.3 第 8 步） |
| `GetIInspectableFromHandle` / `AdviseVisualTreeChange` / QI | 记 `hr`（**十六进制**，便于比对文档里的值）后继续/降级，**不中断** |
| Win32 API | 每次失败立刻 `GetLastError()`（⛔ 不要在失败与读值之间插入任何其它 API 调用，会覆盖错误码） |

**`inject::Error` 与用户可见信息、动作的映射**（产品行为，与实现语言无关）：

| `Error` | 用户可见 | 动作 |
|---|---|---|
| `None` | 「已注入」 | — |
| `TargetGone` | 无感 | 回 `WaitingForShellHost` |
| `OpenProcessFailed` | 「故障：无法打开系统外壳进程」 | 重试 3 次后 `Faulted` |
| `RemoteLoadReturnedNull` | 「故障：注入未生效」+ 提示看日志 | 退避重试；诊断运行时/DLL 依赖问题 |
| `ThreadTimeout` | 「故障：注入超时」 | 退避重试 |
| `ModuleBaseFailed` / `RemoteResolverFailed` | 「故障：内部错误」 | `Faulted`（代码问题，重试无意义） |

### 6.3 失败降级矩阵

| 失败点 | 检测方式 | 降级行为 | 用户可见 |
|---|---|---|---|
| 找不到 `xamldiagnostics.dll` | `DiagLocator::Locate` 返回 `nullopt` | 进 `Faulted`，**不注入** | 「故障：找不到 XAML 诊断运行时」+ 搜索详情 |
| 安装路径含 `;` / `=` | `str::ContainsReservedChars`（启动自检） | 进 `Faulted` | 「故障：安装路径含保留字符」+ 建议换路径 |
| `Ini::SelfTest` 失败 | 写→读→比对的编码自检不通过 | 进 `Faulted` | 「故障：INI 读写自检失败（编码不兼容）」 |
| `OpenProcess` 权限失败 | `Error::OpenProcessFailed` | 重试 3 次后 `Faulted` | 「故障：无法打开系统外壳进程」 |
| 目标进程不存在 | `Error::TargetGone` | **不算故障**，回 `WaitingForShellHost` | 无感 |
| `LoadLibraryW` 返回 NULL | `Error::RemoteLoadReturnedNull` | 退避重试 | 长时间不成功则 `Faulted` |
| 注入成功但 TAP 未就绪 | `WaitUntilAlive` 超时 | 重试；连续 3 次 → `Faulted` | 「故障：注入未生效」 |
| TAP 在但有重复实例 | 互斥体已存在 | TAP 自己休眠（L2，§5.4） | 无感 |
| `Footer` 一直没出现 | TAP 日志无命中 | TAP 什么都不做 | 无感（可能用户就没开面板） |
| 元素结构变了 | `TryInjectLater` 20 次失败 / `InjectIntoRow` 返回 false | 记 Warn；兜底（第二行）或放弃 | 位置不佳或没有按钮 |
| ini 读不到 / `enabled` 缺失 | `Ini::ReadInt` 返回默认 | 视为 `enabled=0`（⭐ **保守：什么都不做**） | 无按钮 |
| INI 解析出非法 action | 不认识 `entry1.action` | 记 Warn，跳过该条目 | 无按钮 |
| 管道写入失败 | `CreateFileW`/`WriteFile` 失败 | 记日志，**不重试**、不弹窗 | 点击无反应（日志有原因） |
| TAP 里发生 C++ 异常 | `catch (...)` | 记日志 + 返回 `S_OK` | 无感 |
| ShellHost 崩溃/重启 | Watcher 的 `onExited` | 回 `WaitingForShellHost` → 自动重注入 | 短暂无感 |
| App 自身崩溃 | WER / 启动自检下一轮 | 由"开机自启 + 单实例"兜住 | 托盘图标消失（用户重启即可） |

**两处刻意的"保守默认"**：
1. **ini 缺失/解析失败 → 视为禁用**。宁可没有按钮，也不要因配置读失败而在系统面板上留下奇怪的东西。
2. **协议版本不认识 → 只记日志不注入**。

### 6.4 重试与退避策略

| 场景 | 退避 | 上限 | 说明 |
|---|---|---|---|
| 注入失败（可重试类） | 1s → 2s → 4s → 8s → 16s → 30s（封顶） | 同一 ShellHost 生命周期内**无限重试** | 每次失败都是毫秒级，且不触碰 shell 代码，无限重试是安全的 |
| `TargetGone` | 不重试 | — | 等新的 ShellHost |
| 注入成功但 TAP 未就绪 | 每 50ms 查 `IsAlive` | 10s | 超时后**重新注入**（而不是重等）："注入成功"可能只是 `DllMain` 上了而 Worker 卡住 |
| 健康检查发现 TAP 消失 | 立即 `ForceReinject` | 连续 3 次 → `Faulted` | §3.12 |
| 用户点「重新注入」 | 立即 | 每次点击一次 | 有 L1 幂等，重复点无害 |

⛔ **禁止**：不要给 `Injecting` 加"全局互斥 + 失败长时间冷却"。ShellHost 可能在几秒内被重建多次（用户折腾 explorer），冷却会让产品在这些时刻静默失效。

### 6.5 "绝不崩 shell"的规则（Code Review Checklist）

**最高优先级约束。ShellHost 崩了会影响任务栏/开始菜单/快速设置，那是用户的日常环境。**

| # | 检查项 | 为什么 |
|---|---|---|
| 1 | 每个 COM 导出方法整体 `try/catch(...)`？ | 异常穿过 COM 边界 = 未定义行为 |
| 2 | `OnVisualTreeChange` 整体 `try/catch(...)` 且**总是返回 `S_OK`**？ | 返回失败会让 XAML 认为 TAP 异常 |
| 3 | `SetSite` 在任一 QI 失败时也返回 `S_OK`？ | 同上 |
| 4 | `DllMain` 里除 `DisableThreadLibraryCalls` + `CreateThread` 什么都没做？ | loader lock 死锁 |
| 5 | 有**任何** `Sleep` 在 UI 线程路径上（`OnVisualTreeChange` → `TryInjectLater` → `InjectIntoFooter` → 点击处理器）？ | UI 线程阻塞 = 面板卡死 |
| 6 | 在 `DllMain` 里（loader lock 下）调用了 `LoadLibrary` / `CoInitialize` / 创建互斥体？ | loader lock 死锁。这些只能放到 `Worker` 线程里做 |
| 7 | 所有 C++/WinRT 调用都被 try/catch 包住？ | cppwinrt 的失败以异常形式抛出（`hresult_error`） |
| 8 | lambda 捕获的是**值**（`FrameworkElement`）而不是引用/裸指针？ | 面板关闭后捕获的引用悬空 |
| 9 | 有对 `VisualElement::Type`/`Name` 做 `SysFreeString`？ | 所有权在框架，**不要释放** |
| 10 | `GetInitializationData` 的 BSTR **有**`SysFreeString`？ | 那个是我们的，必须释放 |
| 11 | `CreateProcessW` 的命令行缓冲是**可写**的？ | 字面量可能被改写 → 访问违规 |
| 12 | `CreateProcessW` 的两个句柄都关闭了？ | 句柄泄漏 |
| 13 | 点击动作里的管道 IO 不在 UI 线程？ | 服务端没起来会卡住面板 |
| 14 | 所有 `detach` 的线程函数最外层有 `try/catch(...)`？ | 未捕获异常 → `std::terminate` → **ShellHost 崩** |
| 15 | 所有 `BSTR`/`IInspectable*` 引用计数配对正确？ | 泄漏或提前释放 → 崩 |
| 16 | 对未知 `Name` / 未知 mutation / `nullptr` 参数都有早退？ | 防御性编程 |
| 17 | ⭐ 注入的两个 DLL **不是 Debug CRT 构建**（或已确认不会有断言触发）？ | Debug CRT 的 `_CRT_ASSERT` 会**在 ShellHost 里弹出对话框**，卡住整个外壳。见 §10.3 |
| 18 | 拿不到 `ItemsPresenter` / `IndexOf` 失败时返回 `false` 走兜底，而不是继续操作？ | 避免对错误对象操作 |

**验收底线**：注入后反复开关面板 20 次、反复点击按钮 20 次、注入状态下重启 explorer 3 次 —— 全程 ShellHost 不崩、任务栏不闪、无异常对话框。

---

## 7. 构建、打包、部署

### 7.1 安装后的目录布局

**全部装在用户目录，全程不需要管理员权限。**

```text
%LOCALAPPDATA%\VolumeMixerExtender\
├── VmExt.App.exe
├── VmExt.Launcher.dll
├── VmExt.Tap.dll
├── vmext.ini                 ← 控制面配置
├── vmext-tap.ini             ← TAP 配置（热重载）
├── VmExt.Launcher.ini        ← 注入前由 App 写
├── logs\
│   ├── app.log
│   ├── launcher.log
│   └── tap.log
├── symbols\                  ← PDB（排障必需）
│   ├── VmExt.App.pdb
│   ├── VmExt.Launcher.pdb
│   └── VmExt.Tap.pdb
└── tools\
    ├── install.ps1
    └── uninstall.ps1
```

⛔ **路径里不能有 `;` 或 `=`**（§2.2）。`%LOCALAPPDATA%` 通常安全，但用户名可能含特殊字符 —— 启动自检必须验证。

**三个二进制都放根目录**：因为 `.ini` 与日志的相对路径都按"exe/dll 所在目录"解析，放平最省心。若要分目录，必须同步改 `str::ModuleDir` 的使用点。

### 7.2 构建系统：vcxproj 还是 CMake？

| 方案 | 优点 | 缺点 | 结论 |
|---|---|---|---|
| **vcxproj + `.sln`**（推荐） | VS 里 F5 就能构建/调试；**"附加到 ShellHost 调试 TAP"的配置最简单**；`VolumeMixerExtender.props` 共享属性；本机已装 VS18 + BuildTools | 只能在 Windows/VS 上构建 | ⭐ **采用** |
| CMake | 跨工具链；本机有 CMake 4.4.0 | 调试 in-proc DLL 需要手工配 `launch.vs.json`；多一层生成步骤；对单人 Windows-only 项目是净负担 | 备选 |
| 裸 `cl` + `build.cmd` | 无依赖（PoC 就是这么干的） | 无 IDE 索引、无符号调试体验、无法集成到解决方案 | 仅在无 VS 的机器上应急（保留 `build-native.cmd`） |

### 7.3 `VolumeMixerExtender.props`（共享构建属性）

```xml
<?xml version="1.0" encoding="utf-8"?>
<Project ToolsVersion="Current" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <PropertyGroup>
    <PreferredToolArchitecture>x64</PreferredToolArchitecture>
    <PlatformToolset>v145</PlatformToolset>          <!-- 按实际 VS 版本调整 -->
    <WindowsTargetPlatformVersion>10.0.26100.0</WindowsTargetPlatformVersion>
    <OutDir>$(SolutionDir)out\$(Configuration)\</OutDir>
    <IntDir>$(SolutionDir)obj\$(ProjectName)\$(Configuration)\</IntDir>
    <!-- ★ PDB 放到固定位置，方便附加调试时找符号 -->
    <ProgramDataBaseFileName>$(SolutionDir)out\$(Configuration)\symbols\$(TargetName).pdb</ProgramDataBaseFileName>
  </PropertyGroup>

  <ItemDefinitionGroup>
    <ClCompile>
      <LanguageStandard>stdcpp20</LanguageStandard>   <!-- ★ §3.0：需要 jthread/stop_token -->
      <MultiProcessorCompilation>true</MultiProcessorCompilation>
      <WarningLevel>Level4</WarningLevel>
      <TreatWarningAsError>true</TreatWarningAsError> <!-- ★ 建议开；C++ 的 bug 多在警告里 -->
      <SDLCheck>true</SDLCheck>
      <ConformanceMode>true</ConformanceMode>
      <PreprocessorDefinitions>
        WIN32_LEAN_AND_MEAN;NOMINMAX;            <!-- ★ §4.3 坑 17，必须全局 -->
        _WIN32_WINNT=0x0A00;
        UNICODE;_UNICODE;%(PreprocessorDefinitions)
      </PreprocessorDefinitions>
      <AdditionalOptions>/utf-8 %(AdditionalOptions)</AdditionalOptions>  <!-- ★ 源码按 UTF-8 读 -->
      <DebugInformationFormat>ProgramDatabase</DebugInformationFormat>
    </ClCompile>
    <Link>
      <SubSystem>Windows</SubSystem>
      <GenerateDebugInformation>true</GenerateDebugInformation>
      <LinkIncremental>false</LinkIncremental>        <!-- ★ 避免增量链接产物与"已加载 DLL"的锁冲突 -->
    </Link>
    <ResourceCompile>
      <AdditionalIncludeDirectories>$(ProjectDir);%(AdditionalIncludeDirectories)</AdditionalIncludeDirectories>
    </ResourceCompile>
  </ItemDefinitionGroup>

  <ItemDefinitionGroup Condition="'$(Configuration)'=='Release'">
    <ClCompile>
      <Optimization>MaxSpeed</Optimization>
      <RuntimeLibrary>MultiThreaded</RuntimeLibrary>       <!-- ★ /MT，§4.3 坑 14 -->
      <WholeProgramOptimization>true</WholeProgramOptimization>
    </ClCompile>
    <Link><EnableCOMDATFolding>true</EnableCOMDATFolding><OptimizeReferences>true</OptimizeReferences></Link>
  </ItemDefinitionGroup>

  <ItemDefinitionGroup Condition="'$(Configuration)'=='Debug'">
    <ClCompile>
      <Optimization>Disabled</Optimization>
      <RuntimeLibrary>MultiThreadedDebug</RuntimeLibrary>  <!-- ★ /MTd：但见 §10.3 的断言风险 -->
    </ClCompile>
  </ItemDefinitionGroup>
</Project>
```

**各项目的额外设置**：

| 项目 | 设置 |
|---|---|
| `VmExt.Tap` | 附加包含目录 `$(WindowsSdkDir)Include\$(WindowsSDKVersion)cppwinrt`；附加依赖 `WindowsApp.lib;ole32.lib`；**链接器 → 输入 → 强制符号引用/导出**：`/EXPORT:DllGetClassObject /EXPORT:DllCanUnloadNow`（⛔ 不能用 `__declspec(dllexport)`，§4.3 坑 3） |
| `VmExt.Launcher` | 附加依赖 `ole32.lib`；**不需要** cppwinrt / `WindowsApp.lib` |
| `VmExt.App` | 附加依赖 `ole32.lib;comctl32.lib;shlwapi.lib;shell32.lib;advapi32.lib;user32.lib;gdi32.lib`（comctl32 需要 `#pragma comment(linker,"/manifestdependency:...")` 或在 .rc 里加 manifest 启用 v6 控件） |
| 所有 DLL | 预处理器加 `VMEXT_IS_INPROC=1`（供共享库区分日志默认路径等） |

### 7.4 构建、部署、安装/卸载

**构建**（命令行，等价于 VS 里构建解决方案）：

```powershell
$msbuild = & "${env:ProgramFiles}\Microsoft Visual Studio\2026\Community\MSBuild\Current\Bin\MSBuild.exe" # 路径按实际调整
& $msbuild VolumeMixerExtender.sln /p:Configuration=Release /p:Platform=x64 /m
```

**构建后自检（放进构建脚本，防止"编出来了但导出名/依赖不对"）**：

```powershell
# ① 必须正好出现这两个导出
dumpbin /exports out\Release\VmExt.Tap.dll | Select-String 'DllGetClassObject|DllCanUnloadNow'
# ② 必须不出现对 VCRUNTIME*.dll / ucrtbased.dll 的依赖（确认 /MT 生效、且不是 Debug CRT）
dumpbin /dependents out\Release\VmExt.Tap.dll
# ③ 单元测试
& out\Release\VmExt.Tests.exe; if ($LASTEXITCODE -ne 0) { throw "单元测试失败" }
```

**打包**：一个 zip（个人工具，不需要 MSI/WiX）。

| 项 | 做法 |
|---|---|
| 内容 | `VmExt.App.exe`、两个 DLL、`*.ini` 模板、`symbols\*.pdb`、`tools\*.ps1`、`docs\` |
| 签名 | ⚠️ 不签名。**必须**在 README 里写清"未签名、会注入 ShellHost，Defender 可能报"（§10.4 第 4 步） |
| ⭐ **下载后必须解除锁定** | 从网上下来的 zip 解出的文件带 `Zone.Identifier`，会被 SmartScreen/Defender 额外审查。安装脚本第一步应执行 `Get-ChildItem -Recurse \| Unblock-File` |
| 版本号 | 单一来源：`VolumeMixerExtender.props` 的 `<Version>`，同时写进 `version.h` 与诊断信息输出 |

**`tools\install.ps1`（幂等）**：

```text
1. Get-ChildItem -Recurse | Unblock-File                        ← ★ 解除 Zone.Identifier
2. ★ 覆盖前先停进程：
     Stop-Process -Name VmExt.App -ErrorAction SilentlyContinue
     # ⛔ 两个 DLL 可能被 ShellHost 持有文件锁，无法覆盖。
     #    两条对策（推荐第一条）：
     #    A) 停 ShellHost（sihost 会自动重新拉起，Watcher 随后自动重新注入新 DLL）
     #       用户感知只是"快速设置闪了一下"
     Stop-Process -Name ShellHost -ErrorAction SilentlyContinue
     Start-Sleep -Seconds 2
3. 拷贝到 %LOCALAPPDATA%\VolumeMixerExtender\（覆盖）
4. 若 *.ini 不存在则写出模板（★ 不覆盖用户已有配置）
5. 注册开机自启：HKCU\Software\Microsoft\Windows\CurrentVersion\Run
     "VolumeMixerExtender" = "<InstallRoot>\VmExt.App.exe"
6. 提示（不自动做）Defender 排除：
     Add-MpPreference -ExclusionPath "<InstallRoot>"
   （需要管理员；脚本只输出这行命令让用户自己决定）
7. 启动 VmExt.App.exe
```

**`tools\uninstall.ps1`**：

```text
1. 停 VmExt.App.exe；删除 HKCU\...\Run 的项
2. ★ 提示：两个 DLL 仍被 ShellHost 持有，无法立即删除
     - 提供 -RestartShell 开关：Stop-Process ShellHost → 等 2s → 删文件
     - 或让用户重启 explorer/注销后手工删目录
3. 保留 logs\（除非 -PurgeLogs），方便事后排查
4. 打印"剩余未删除的文件清单"（诚实，不要假装卸载干净了）
```

### 7.5 为什么坚持"零第三方库"

| 候选 | 用在哪 | 引入成本 | 结论 |
|---|---|---|---|
| `nlohmann/json`（单头） | 配置 | 一个几百 KB 的头文件；本项目配置是扁平键值对，INI 完全够 | 不用（§2.3） |
| `wil`（Windows Implementation Library，微软） | RAII/HRESULT 包装 | 质量很高，但引入一个外部依赖树；我们的需求只需 ~60 行 RAII（§3.5） | 不用 |
| Catch2 / GoogleTest | 测试 | 不进产品二进制，但需要构建集成 | v1 用自写断言（§3.16）；测试数超过 100 再考虑 |
| cppwinrt | TAP 构造 XAML 对象 | **必需**，但它是 **Windows SDK 的一部分**（仅头文件 + `WindowsApp.lib`），不算第三方 | 必须用 |

⛔ **坚持零依赖的实际收益**：交付是一个 zip，解压即用；没有许可证审查；没有"某个库停止维护"的风险；`dumpbin /dependents` 的输出里只有系统 DLL。

### 7.6 调试配置（C++ 轨道的强项）

| 调试目标 | 怎么调 |
|---|---|
| **VmExt.App.exe** | VS 里直接 F5。或 `调试 → 附加到进程 → VmExt.App.exe`（Native only） |
| ⭐ **VmExt.Tap.dll（在 ShellHost 里）** | ⛔ 不能 F5（TAP 不是可执行文件，它是被 ShellHost 加载的）。正确流程：<br>① `调试 → 附加到进程` → 选 **ShellHost.exe** → "附加到"选 **Native code**<br>② 附加后 `调试 → 窗口 → 模块` 里此时**还看不到** `VmExt.Tap.dll`（还没注入）<br>③ 让 App 注入（或从托盘菜单点"重新注入"）<br>④ 模块列表出现 `VmExt.Tap.dll` 后，在 `调试 → 窗口 → 模块` 上右键 → **加载符号**，然后下断点<br>⑤ 打开音量面板 → 断在 `OnVisualTreeChange` |
| **VmExt.Launcher.dll** | 同上流程。注意 Worker 有 `Sleep(200)`，附加后要有耐心 |
| 符号 | 把 `symbols\*.pdb` 与对应的 DLL **放在同一目录或相邻的 symbols 目录**；VS 在"模块"窗口里会显示"未找到符号"并允许手工指定路径 |
| ⭐ **热点：为什么必须在注入前附加** | 因为断点下在"未加载的模块"上是"待定断点"（VS 会提示），一旦 DLL 加载就会生效。但在**注入之前**附加可以让我们断在 `DllMain`，看到加载失败的现场 |
| 崩溃现场 | 见 §9.4 |
| ⛔ 不要在 ShellHost 里用 `_CrtSetDbgFlag` / PageHeap | 见 §9.4 的最后一条 |

---

## 8. 验证与验收

### 8.1 分级验证

**必须按顺序做。任何一级不通过，不要往下做** —— 后面的失败会被前面的问题掩盖。

| 级 | 目的 | 步骤 | 通过标准 | 不通过说明什么 |
|---|---|---|---|---|
| **V0** | 注入不加任何东西也安全 | 注入 Launcher，但 `enabled=0` | ShellHost 不崩；反复开关面板 20 次无异常；两个日志出现 | 注入方式或 DLL 依赖有问题（先查 `dumpbin /dependents`） |
| **V1** | TAP 能连上诊断会话 | `enabled=0`，看 `tap.log` | `vcxtap loaded` → `SetSite` → `QI IXamlDiagnostics hr=0x0` → `QI IVisualTreeService hr=0x0` → `AdviseVisualTreeChange hr=0x0`，随后大量 `ADD` | 端点名/CLSID/TAP 加载有问题 |
| **V2** | ⭐ **配置下发契约成立**（直投主 + initData 面包屑） | `enabled=0`，配置串带可识别的 `cfg=` | ① `tap.log` 打印 `直投通道: 有 len=N fnv1a64=H1`，且 `H1` 与 Launcher 日志里的哈希**逐位相同**；② 打印出解析到的 `cfg`，与 App 写的一致；③ ≤259 时 `initData : len=N fnv1a64=H1` 也一致 | ① 直投没到 → 导出名/签名/顺序（§2.2.1）② `cfg` 没解析出来 → `Contract::Build` 格式 ③ initData 为空但长度 ≤259 → **看 TAP 的反向哨兵日志**（§4.2.3 第 4c 步） |
| **V2.1** | initData 上限行为符合预期 | 配置串刻意做成 >259 字符 | Launcher 警告日志出现"面包屑会被静默丢弃"；TAP 打印"initData 为空属**预期**"；**按钮照常注入**、几何不变 | 若按钮没出现，说明配置**没有**走直投通道（超限时被一起丢了） |
| **V3** | 配置与编码 | `enabled=1`，`text` 设为中文 | 按钮文字**正确显示**，不是乱码 | ⭐ 注意：`Ini::SelfTest` 已经在启动自检里拦住了编码问题（✅ T2 已把编码这一层钉死）；若 V3 仍乱码，说明问题在 **cppwinrt/字体侧**而不是 INI |
| **V4** | 点击动作（`exec` / `pipe`） | ① `action=exec` ② `action=pipe`，App 侧服务端在跑 ③ 服务端**不在**时也要点一次 | ① 程序被拉起 ② App 收到 `CLICK <id> <ts>` ③ **两次点击时面板都不卡顿**（`Invoke` 往返 < 120ms） | pipe 链路或 UI 线程阻塞。✅ 三项均已在 PoC 验证（`08-pipe-action-chain.md`） |
| **V5** | 生效时机 | 干净 shell → 注入 → 打开面板 | **第一次**打开面板就有按钮 | 若"第一次没有、第二次才有"，说明 `TryInjectLater` 重试次数不够或事件时序理解有误 |
| **V6** | 幂等 | 连续调 3 次「重新注入」，然后开面板 | **只有一个**按钮；`tap.log` 里能看到重复实例被判为 `dormant` | L1/L2 去重失效 |
| **V7** | 生命周期 | 注入就绪后重启 explorer | App 日志出现 `onExited` → `onStarted` → 注入 → `TAP 就绪`；再开面板按钮仍在 | Watcher 或编排器有问题 |
| **V8** | 资源泄漏 | 反复注入/重启 shell 10 轮；每次开面板点按钮 20 次 | 无崩溃；用 Process Explorer 看 App 与 ShellHost 的**句柄数**不持续增长 | ⭐ C++ 轨道的重点级（§10.3）：句柄/引用计数泄漏 |

**⚠️ 当前状态**：V0/V1/V2/V2.1/V5 已由 PoC 等价验证 ✅（V2 的证据见 `verified-after-injection/06-initdata-channel-limit.md`，含三次独立复现；点击动作的能力与安全约束见 `07-click-execution-constraints.md`）；**V3/V4/V6/V7/V8 未验证**。

**⭐ 额外前置**：`VmExt.Tests.exe` 必须先全绿。它覆盖契约往返、INI 中文往返、注入错误分类、字符串/路径工具 —— 这些若不靠单元测试，就只能端到端验证，成本高得多。

### 8.2 验收测试用例表

| ID | 名称 | 步骤 | 期望 | 可自动化 |
|---|---|---|---|---|
| AT-01 | 按钮在同一行右侧 | 打开音量面板；UIA 读 `Footer` 与全部 `Button` 矩形 | 两按钮 **y 区间重叠**；我们的按钮右边缘距 `Footer` 右边缘 **≤8px**；`Footer` 高度 **48**（不是 78） | ✅ `poc/scripts/footer-map.ps1` |
| AT-02 | 按钮文字正确 | 同上，读 `Name` | 等于 `vmext-tap.ini` 的 `entry1.text` | ✅ |
| AT-03 | 点击执行动作 | UIA `InvokePattern` 调用 | `exec` → 目标进程出现；`pipe` → App 日志出现 `收到点击` | ✅ `poc/scripts/click-testlink.ps1` |
| AT-04 | 与模型按钮视觉一致 | 比两个按钮高度 | 相等（都是 40） | ✅ |
| AT-05 | 关闭面板无残留 | 开关面板 5 次 | 每次只有一个按钮 | ✅ |
| AT-06 | `enabled=0` 不注入 | 设 0，重开面板 | 无按钮；`tap.log` 有 "disabled" | ✅ |
| AT-07 | shell 重启后自愈 | 注入就绪 → 重启 explorer → 等 15s → 开面板 | 按钮仍在 | ⚠️ 半自动 |
| AT-08 | 面板已打开时注入 | 先开面板 → 注入 → 关面板 → 再开 | **再一次打开时**出现按钮（本方案不承诺"立刻出现"） | ✅ |
| AT-09 | 稳态 CPU | 注入就绪后静置 5 分钟 | App **< 0.1%**；ShellHost 相对基线无可见增长 | ⚠️ 人工 |
| AT-10 | 面板不卡顿 | 打开面板后快速滑动音量列表 | 无明显卡顿（对比未注入） | ❌ 人工 |
| AT-11 | 卸载后无残留 | `uninstall.ps1 -RestartShell` | 面板无按钮；`HKCU\...\Run` 无项 | ⚠️ 半自动 |
| AT-12 | 缺诊断运行时的表现 | 把 `diagnostics_dll` 指向不存在的文件 | 托盘明确故障；**不注入**；诊断信息列出搜索过的路径 | ✅ |
| AT-13 | ⭐ **INI 编码自检** | 改一个含中文的 `text`，重启 App | 启动自检通过；按钮文字正确 | ✅ |
| AT-14 | ⭐ **契约往返** | 跑 `VmExt.Tests.exe` | 全绿（尤其 initData 往返与非法字符拒绝） | ✅ **不需要 ShellHost** |
| AT-15 | ⭐ **句柄不泄漏** | 循环 10 轮注入/重启 shell | App 句柄数回到基线（±10） | ⚠️ 半自动 |
| AT-16 | 托盘图标在 explorer 重启后恢复 | 重启 explorer | 图标自动重新出现（`TaskbarCreated` 处理生效） | ⚠️ 半自动 |
| **AT-17** | ⭐ **入口接管生效** | 开面板（L1）→ UIA `InvokePattern` 点 `VolumeL2Button` | 进入后显示**自定义页**（我们的内容），**不是**系统声音页 | ✅ |
| **AT-18** | ⭐ **不误伤兄弟 L2 入口** | 点 L1 的「投影」(`Microsoft.QuickAction.ProjectL2`) | 正常进入系统投影页；自定义页**不出现** | ⚠️ 半自动 |
| **AT-19** | ⭐ **底栏切换往返** | 自定义页点切换 → 系统页再点切换 | 内容正确来回；底栏按钮两态都常驻、文案随态变化 | ✅ |
| **AT-20** | ⭐ **系统内容还原完整** | 从自定义页切回系统页 | 设备列表 / 音量条数值与切换前**一致**（验证保存的 `Content` 可原样恢复） | ⚠️ 半自动 |
| **AT-21** | ⭐ **入口无关性** | 用其它路径（键盘 / 后续新增入口）进声音页 | 同样落在自定义页 —— 机制基于"页面出现"而非"某个按钮" | ✅ |
| **AT-22** | 自定义页可滚动 | 应用数超过一屏 | 内容区可滚动，底栏**不随滚动移动** | ❌ 人工 |

### 8.3 自动化脚本清单（复用 `docs/poc/scripts/` 的现成工具）

| 脚本 | 作用 | 用于 |
|---|---|---|
| `docs/poc/scripts/cycle.ps1` | 一轮完整迭代：停 shell → 构建 → 重启 explorer → 注入 → 开面板 → 打日志 + 几何 | 开发期迭代 |
| `docs/poc/scripts/footer-map.ps1` | UIA 打印 `Footer` 与全部 `Button` 的屏幕矩形 | AT-01/04/05 |
| `docs/poc/scripts/click-testlink.ps1` | UIA `InvokePattern` 触发并断言目标进程出现 | AT-03 |
| `docs/poc/scripts/shot-footer.ps1` | 截取底栏区域到 PNG（2 倍放大） | 视觉确认 |
| `docs/poc/scripts/parse-tree.ps1` | 从 `tap.log` 重建元素层次并打祖先链 | 定位算法排障 |
| `docs/poc/scripts/qs-panel-probe.ps1` | 打开/定位面板并 dump XAML 元素树 | 所有需要面板的场景 |

⛔ **共同的脆弱点**：`ControlCenterWindow` 是 **band=4** 窗口，`EnumWindows`/`FindWindow`/UIA `RootElement` **都看不到它** ✅。拿 HWND 只能靠 `GetForegroundWindow()`/`GetGUIThreadInfo()`。
⇒ **一旦有别的窗口抢走前台，脚本就会报"面板未打开"**（✅ 踩过）。
**自动化的正确做法**：先拿到并**缓存面板 HWND**（它常驻），后续用 `IsWindowVisible(hwnd)` 判断，不要每次都依赖前台窗口。

---

## 9. 排障手册

### 9.1 症状 → 原因 → 动作

| 症状 | 最可能的原因 | 动作 |
|---|---|---|
| 托盘「等待系统外壳就绪」很久 | ShellHost 没起来（用户很久没开快速设置/开始菜单） | 正常。让用户按 `Win+Ctrl+V` 触发一次 |
| 托盘「已注入」但面板没按钮 | ① `enabled=0` ② `Footer` 名称变了 ③ `TryInjectLater` 20 次都失败 | 看 `tap.log` 有没有 `Footer appeared`，再看 `no ItemsPresenter ancestor` / `row wrap failed` |
| 按钮在**第二行**，footer 变高 | 走了兜底路径（`InjectIntoRow` 返回 false） | 看 `tap.log` 的 `up[]` 祖先链是否还是 5 层结构 |
| 按钮跑到面板外 / UIA 读到 `∞` | 用了布局前的测量值（违反 I1） | 查代码里未判 `>0` 的 `ActualWidth/ActualHeight`（§5.5 复盘） |
| 出现**两个**按钮 | 去重失效（§5.4） | 看 `tap.log` 是否有两个 `Tap 加载`；查 L1 是否被绕过 |
| 点击没反应 | ① `pipe` 模式但 App 没跑/管道名不匹配 ② `exec` 命令行不对 ③ 写入失败 | 看 `tap.log` 的点击记录与失败 err；核对 `Contract::PipeName(sessionId)` 与 initData 一致 |
| 点击后面板卡住 | 管道 IO 在 UI 线程上（§4.2.5） | 移到独立线程 + 短超时 |
| 注入报 `OpenProcessFailed` | 目标 IL 变高 / 成为 PPL / 是别的会话 | 查 session 过滤；确认 ShellHost 非 PPL（§2.6） |
| 注入报 `RemoteLoadReturnedNull` | **DLL 依赖缺失**（CRT 动态链接 / Debug CRT）、位宽不符、文件被 Zone 阻塞 | `dumpbin /dependents` 确认无 `VCRUNTIME*.dll`/`ucrtbased.dll`；确认 x64；`Unblock-File` |
| `LNK1104 无法打开 VmExt.Tap.dll` | 构建目标正被 ShellHost 加载 | 停 ShellHost（§7.4） |
| `launcher.log` 里 `hr=0x80070057`（E_INVALIDARG） | 参数不被接受：路径不存在、CLSID 不符、initData 不合规 | 逐项核对 `VmExt.Launcher.ini`；**先用 `VmExt.Tests.exe` 排除"我们的序列化有问题"** |
| `xamldiagnostics.dll 存在` 但 TAP 没起来 | SDK 的 `xamldiagnostics.dll` 与系统 XAML 不兼容 | 换匹配的 SDK（§10.2 S7） |
| `tap.log` 有 `duplicate TAP, going dormant` | 重复注入（L2 正常工作） | 无需处理；若仍有两个按钮，说明 L3 失效 |
| ⭐ 注入后 ShellHost **弹出断言对话框** | 用了 Debug CRT，`_CRT_ASSERT` 触发 | 见 §10.3。改用 Release + `/Zi` 构建注入用的 DLL |
| ⭐托盘图标在 explorer 重启后消失 | 没处理 `TaskbarCreated` | §3.14 的四件事 |
| ⭐右键菜单点外面不消失 / 鼠标"黏"在菜单上 | 没 `SetForegroundWindow` / 没 `PostMessage(WM_NULL)` | §3.14 |
| App 句柄数持续增长 | 漏了 `CloseHandle`（注入器早退路径、点击处理器、枚举） | 全部改用 `win32::UniqueHandle`；用 Process Explorer 对比基线 |

### 9.2 诊断命令集

```powershell
# ---- 1. 目标进程 ----
Get-Process ShellHost | Select-Object Id, SessionId, StartTime
(Get-CimInstance Win32_Process -Filter "Name='ShellHost.exe'").ParentProcessId   # 期望 sihost

# ---- 2. TAP 心跳（命名互斥体）----  存在即"TAP 已就绪"
$shpid = (Get-Process ShellHost).Id
[System.Threading.Mutex]::TryOpenExisting("Local\VmExt.Tap.Singleton.$shpid", [ref]$null)

# ---- 3. 面板与底栏几何（需要面板在前台）----
& .\docs\poc\scripts\footer-map.ps1

# ---- 4. 日志（`<cache>\log`，一次进程会话一个文件）----
$log = "$env:TEMP\eric\VolumeMixerExtender\log"
Get-ChildItem $log\app-*.log      | Sort-Object LastWriteTime | Select-Object -Last 1 | Get-Content -Tail 40
Get-ChildItem $log\launcher-*.log | Sort-Object LastWriteTime | Select-Object -Last 1 | Get-Content -Tail 30
Get-ChildItem $log\tap-*.log      | Sort-Object LastWriteTime | Select-Object -Last 1 | Get-Content -Tail 60

# ---- 5. 原生 DLL 自检 ----
dumpbin /exports    "$env:LOCALAPPDATA\VolumeMixerExtender\VmExt.Tap.dll"
dumpbin /dependents "$env:LOCALAPPDATA\VolumeMixerExtender\VmExt.Tap.dll"   # 应只有系统 DLL
dumpbin /headers    "$env:LOCALAPPDATA\VolumeMixerExtender\VmExt.App.exe" | Select-String 'machine'

# ---- 6. 诊断运行时探测 ----
Get-ChildItem "$env:ProgramFiles(x86)\Windows Kits\10\bin\*\x64\XamlDiagnostics\xamldiagnostics.dll" |
    Sort-Object FullName -Descending | Select-Object -First 5 FullName

# ---- 7. INI 编码检查 ----
Format-Hex "$env:LOCALAPPDATA\VolumeMixerExtender\vmext-tap.ini" | Select-Object -First 2   # 期望 FF FE 开头
Get-Content "$env:LOCALAPPDATA\VolumeMixerExtender\vmext-tap.ini"                            # 中文是否正常

# ---- 8. 是否被 Zone 阻塞 ----
Get-Item "$env:LOCALAPPDATA\VolumeMixerExtender\VmExt.Tap.dll" -Stream Zone.Identifier -ErrorAction SilentlyContinue
```

### 9.3 日志阅读指南

> 三个日志都在 `<cache>\log`（`%TEMP%\eric\VolumeMixerExtender\log`），且**一次进程会话一个文件**：
> `app-<yyyyMMdd-HHmmss>.log` / `launcher-<...>.log` / `tap-<...>.log`（同名同秒时加 `-2` 后缀）。
> 所以"最新的那个"通常就是当前这次的会话 —— ⛔ 不要按固定文件名去 tail。

**判断"注入是否成功"的正确顺序**：

```text
① app-*.log
     "onStarted pid=..."            → Watcher 发现了目标
     "TryInject pid=..."            → 开始注入
     "pid=... TAP 就绪"             → ★ 到这一步才叫注入成功

② launcher-*.log
     "SUCCESS endpoint=... hr=0x00000000"  → in-proc 入口调用成功
     ← 若这里没有，问题在 Launcher 内部（§4.1.4 表格）

③ tap-*.log
     "Tap 加载: pid=... "           → TAP 被 XAML core 加载
     "QI IXamlDiagnostics hr=0x0"   → 拿到诊断接口
     "AdviseVisualTreeChange hr=0x0"→ 开始收事件
     "*** Footer appeared: ..."     → ★ 页面的底栏出现了
     "up[0] ... up[9] ..."          → 祖先链（对照 §5.1）
     "wrapped the row container ..."→ ★ 注入成功
     "align: ..."                   → 兜底路径的对齐计算
     "*** 按钮已注入 ***"           → 完成
```

**三个 ★ 是排障的全部关键**：`TAP 就绪` → `Footer appeared` → `wrapped the row container`。中间断在哪一个，就直接定位到对应章节。

### 9.4 ⭐ C++ 特有的排障手段

| 场景 | 手段 |
|---|---|
| **ShellHost 崩了，想知道崩在哪** | ① 先开本地 dump：`HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps` 建 key `ShellHost.exe`，`DumpType=2`（完整）、`DumpFolder` 指向一个可写目录 → 复现 → 用 WinDbg 打开 dump，`!analyze -v`，`~*k` 看所有线程栈<br>② 或者用 `procdump -ma -e -w ShellHost.exe` 挂着等崩溃<br>③ WinDbg 里 `.ecxr` + `k` 定位异常上下文；若栈里有我们的模块，用 `.reload /f VmExt.Tap.dll` 加符号后再看 |
| **ShellHost 卡死（不是崩）** | WinDbg 附加 → `~*k` 看 XAML UI 线程是否在等我们的锁/IO。⭐ 这是"UI 线程上做了阻塞 IO"的典型症状 |
| **句柄泄漏**（App 是长期运行的托盘进程，最容易中） | ① Process Explorer → 选进程 → `View → Lower Pane → Handles`，按 Type 排序，看 `Event`/`Process`/`Thread` 是否持续增长<br>② `!htrace`（需先 `!htrace -enable`）能给出**分配点的调用栈** —— 这是定位 `CreateEventW` 漏关的最有效手段<br>③ 把该报错的 `HANDLE` 逐个改成 `win32::UniqueHandle`（§3.5） |
| **内存泄漏** | ⚠️ 注入用的 DLL **不要**在 ShellHost 里开 PageHeap/AppVerifier（会把整个 shell 变慢甚至不稳）。做法：在**自建靶进程**里跑注入测试并用 `gflags /p /enable <靶进程>.exe /full`，先在那里抓到，再修 |
| **CRT 断言弹窗卡住外壳** | ⭐ 见 §10.3。立刻用 `Stop-Process ShellHost` 恢复；然后把注入用的两个 DLL 改成 Release 构建 |
| **符号加载不上** | VS `调试 → 窗口 → 模块` → 右键 → 加载符号 → 指定 `symbols\` 目录；确认 PDB 的 GUID 与 DLL 匹配（用 `dumpbin /headers` 看不到，但"不匹配"会在 VS 里明确提示） |
| **想确认是否真的在 UI 线程** | 日志里的 `t<tid>`。对比"面板创建时"与"`OnVisualTreeChange` 回调"的 tid 是否相同（✅ 实测相同） |
| **想确认是否在目标进程里** | 日志里的 `pid=`。Launcher/Tap 的日志必须打印 `GetCurrentProcessId()`，与 App 日志里的 ShellHost pid 对照 |
| ⛔ **不要用 `OutputDebugString`** 做正式日志 | 需要外部监听器（DebugView），开销大，且在无人监听时会阻塞。正式日志永远走文件（§3.2） |

---

## 10. 已知限制、风险与版本兼容

### 10.1 硬限制（⛔ 不可消除，全部由体系结构决定）

| # | 限制 | 后果 | 应对 |
|---|---|---|---|
| 1 | `InitializeXamlDiagnosticsEx` 是**每进程一次**的诊断初始化，**无 teardown API** | TAP DLL 一旦加载就跟着 ShellHost 活到进程退出 | "禁用"通过 `enabled=0` 实现。**不要**去找卸载 API，浪费时间 |
| 2 | TAP 从不调 `UnadviseVisualTreeChange` | 框架持续持有回调引用 ⇒ `DllCanUnloadNow` 永远 `S_FALSE` ⇒ TAP 卸载不掉 | 同上。**这是刻意的**：既然会话本身反不掉，再花力气反掉 TAP 也没意义 |
| 3 | 已加载的 DLL 文件被写锁定 | 无法原地升级/卸载（LNK1104） | 停 ShellHost 后替换（§7.4） |
| 4 | 面板是 **band=4** 窗口 | `EnumWindows`/`FindWindow`/UIA `RootElement` 都看不到 | 只用 `GetForegroundWindow()`/`GetGUIThreadInfo()`；自动化里缓存 HWND（§8.3） |
| 5 | XAML 元素实例**每次打开面板都重建** | 无法长期持有元素引用；注入必须每次重做 | 事件驱动（`Footer` 的 Add）+ 每次重注入。**这让"按钮消失"是免费的**，不需要清理逻辑 |
| 6 | ShellHost 是原生非 .NET 进程 | 托管代码进不去（§1.2 C3） | 本轨道本来就全 C++，此约束不构成选择 |
| 7 | `WaitForMultipleObjects` 上限 64 句柄 | 极端情况下 Watcher 数组会满 | 达到 60 时清理已退出项并重建数组（§3.7） |

### 10.2 软依赖与版本敏感点（**必须监控**）

| # | 依赖 | 当前值（实测） | 失效后果 | 发现方式 |
|---|---|---|---|---|
| S1 | ⚠️ 底栏元素 `Name` 是 `Footer` | 来自 `ControlCenter.dll` 的编译期 XAML | TAP 匹配不到 → 不注入（**安全退化**） | `tap.log` 里没有 `Footer appeared`。可加主动探测：advise 后 5s 内没见到 `Footer` 就记 Warn |
| S2 | ⚠️ 元素结构（`Button → ContentPresenter → ContentControl → ContentPresenter → StackPanel[V] → ItemsPresenter → ItemsControl`） | 见 §5.1 | 兜底（第二行）或放弃（安全退化） | `tap.log` 的 `up[]` / `no ItemsPresenter ancestor` / `row wrap failed` |
| S3 | ⚠️ 模型按钮 `Height` 是显式 `40.0` | 实测 | 高度回退到常量 40，仍安全 | 日志 `model metrics: Height=...`，定期人工核对 |
| S4 | ⚠️ 底栏几何 `(2189,1417) 358x48`、左边距 4 | 实测（依赖分辨率/DPI/语言/缩放） | 右侧边距不再对称（视觉小瑕疵） | ⛔ **不要把绝对坐标写进代码**，只用相对关系（左 inset 镜像） |
| S5 | ⚠️ 目标进程名 `ShellHost.exe` | 实测 | 找不到目标 → 一直 `WaitingForShellHost` | 启动自检可验证"是否存在"并提示 |
| S6 | ⚠️ ShellHost 与 App 同为 Medium IL、非 PPL | 实测 | `OpenProcess` 失败 → `Faulted` | 每次注入前检查（已经是这样） |
| S7 | ⚠️ SDK 的 `xamldiagnostics.dll` 与系统 `Windows.UI.Xaml.dll` 版本兼容 | SDK 10.0.14393.33 + Xaml 10.0.26100.8972 ✅ | TAP 起不来 → 一直 `WaitingForTap` | 诊断信息里记录两者版本；系统大版本更新后**必须重跑 V1** |
| S8 | ⚠️ 同进程对不同端点名重复 `InitializeXamlDiagnosticsEx` 的行为 | **未验证** | 可能加载第二个 TAP（被 L2 兜住） | V6 覆盖 |

**维护建议**：
1. 把 S1–S3、S5 的值写进**可执行的探测脚本**，每次 Windows 大更新后跑一次。
2. `tap.log` 的 `up[]` 祖先链输出**不要删** —— 它是结构变化时唯一的现场证据。
3. S1/S2 失效时产品行为是"安全地没有按钮"而不是崩溃。**这是刻意设计的，要保留。**

### 10.3 ⭐ 本轨道特有的风险

| # | 风险 | 严重度 | 说明与对策 |
|---|---|---|---|
| R1 | ⛔ **Debug CRT 的断言会在 ShellHost 里弹对话框，卡死整个外壳** | **高** | `/MTd` 静态链接 Debug CRT 时，`_CRT_ASSERT` / `_ASSERTE` / STL 的迭代器检查失败会调 `_CrtDbgReport`，默认**弹消息框**。在注入的 DLL 里弹框 = 模态阻塞 ShellHost UI 线程 = 任务栏/开始菜单/快速设置全卡住。<br>**对策**：注入用的两个 DLL **一律用 Release 构建**（`/MT` + `/Zi` 保留 PDB 便于调试）。若必须 Debug 构建，在 `DllMain` 里 `_CrtSetReportMode(_CRT_ASSERT, _CRTDBG_MODE_FILE)` + `_CrtSetReportFile(_CRT_ASSERT, _CRTDBG_FILE_STDERR)` —— 但**首选是别用 Debug CRT** |
| R2 | 手写 Win32 托盘/窗口代码的 bug 面 | 中 | `TaskbarCreated`、`SetForegroundWindow`+`TrackPopupMenu`、`PostMessage(WM_NULL)`、`WM_DESTROY` 里 `NIM_DELETE` —— 四个都必须处理（§3.14）。手写就没有框架兜底，漏一个就是可见缺陷 |
| R3 | ⭐ **DPI 感知必须在 manifest 里声明** | 中 | 不声明的话文本框/图标在高 DPI 下模糊或被系统缩放。<br>在 `VmExt.App` 的 manifest（或 `.rc` 的 `RT_MANIFEST`）里加：`<dpiAware>true/pm</dpiAware>` + `<dpiAwareness>PerMonitorV2</dpiAwareness>`。<br>⚠️ **注意**：这不影响 XAML 侧的按钮几何（那是 ShellHost 的事），但会影响**验收脚本读到的屏幕坐标** —— `footer-map.ps1` 读到的 `(2189,1417)` 是**当前缩放下的物理像素**。跨 DPI 比较几何时要换算（见 T10） |
| R4 | ⛔ **跨模块 CRT 边界**（不变量 I4） | 高（架构级） | 静态 CRT 下每个二进制各有一份堆；绝不允许跨 DLL 边界传 CRT 分配的内存或含它的对象。<br>本轨道下三个二进制在**不同进程**，所以天然不会触发；**但如果将来把 `VmExt.Shared` 改成 DLL，I4 立刻变成必须严格处理的问题**。建议保持静态库（§5.6） |
| R5 | ⛔ 线程入口/窗口过程漏 `try/catch(...)` → `std::terminate` | **高** | 在 ShellHost 里就是 shell 崩。所有线程入口（**含 `detach` 的**）与 `WndProc` 必须整体捕获（§6.1） |
| R6 | 无 GC：App 是长期运行的托盘进程，句柄泄漏会累积 | 中 | 全部用 `win32::UniqueHandle`；AT-15 做里程碑式检查；必要时用 `!htrace` 定位分配点（§9.4） |
| R7 | ⭐ **改共享库 → 三个二进制全重建，且 in-proc 两个要重启 ShellHost 才能替换** | 中 | 共享静态库让"一份代码、三处使用"成为可能，代价是它的任何改动都会牵动全部二进制，而 in-proc 两个**必须让 ShellHost 重启才能替换**（DLL 被加载即锁定）。对策：把共享库的接口设计得极其稳定（`vmext_contract.h` 与 Log/Ini/Str 的签名尽量不动），把易变的业务逻辑放在 `VmExt.Control` 与 `VmExt.App`（这两个重建不影响 ShellHost 里的 DLL） |
| R8 | `/W4 /WX` 与 cppwinrt 头共存会报一堆警告 | 低 | 把 cppwinrt 目录标记为**外部头**：MSBuild 里设 `<ExternalIncludePath>`，或命令行 `/external:I"<cppwinrt>" /external:W0`。这样外部头的警告被静音，而我们自己的代码仍然 `/WX` |
| R9 | `std::filesystem` 会引入较多 CRT 代码进 in-proc DLL | 低 | 统一用 Win32 API 做文件操作（`str::FileExists` 等），in-proc DLL 更小、启动更快、依赖更少 |
| R10 | `/GL`（LTCG）+ `/MT` 的构建时间更长 | 低 | 只对 Release 开；开发期用 Debug 配置迭代（但**注入用的产物必须 Release**，见 R1） |

### 10.4 安全与合规说明

| 项 | 说明 |
|---|---|
| 注入手法 | `CreateRemoteThread` + `LoadLibraryW` —— **木马经典手法**。Defender/EDR 很可能拦或报毒。这是**自用工具**的已知代价 |
| 缓解 | 安装目录加 Defender 排除（脚本只提示命令，不自动执行）。**不要**把这套东西分发给第三方 |
| XAML 诊断 API 的安全背景 | ⚠️ **CVE-2023-36003** 记录了"XAML 诊断注入是提权原语"。本项目的前提是**同完整性级别**（Medium → Medium），✅ 实测成立，不跨越 IL 边界 |
| 不提权 | 全装 `%LOCALAPPDATA%`，不用管理员。**不要**为了"方便"改成装 `Program Files` + 服务 —— 那会把用户级工具变成需提权的系统级工具，风险面完全不同 |
| 不越界 | 不 hook shell 代码、不改 shell 注册表项、不修改 `ControlCenter.dll`。只通过**文档化的诊断契约**操作 XAML 对象树 |
| 数据 | 不收集、不上传。全部日志在本机 |
| ⭐ **下载来源** | zip 解出的文件带 `Zone.Identifier` 会被额外审查；安装脚本第一步 `Unblock-File`（§7.4） |
| 用户预期 | README 与文档必须写清："会向 `ShellHost.exe` 注入代码，Defender 可能报警，建议加排除" |

### 10.5 待解决 / 待补

| # | 项 | 优先级 | 说明 |
|---|---|---|---|
| ~~T1~~ | ~~`GetInitializationData` 是否原样返回我们的串~~ | — | ✅ **已验证完毕**（2026-10-03）。结论：**返回**，含中文逐字符一致，但**上限正好 259 字符**，≥260 静默返回空串且 `hr` 仍是 `S_OK`。⇒ 配置改走**直投通道**，initData 降级为面包屑。长度扫描表见 `verified-after-injection/06-initdata-channel-limit.md` |
| ~~T2~~ | ~~**`Ini::SelfTest` 在真实系统上的结果**~~ | — | ✅ **已验证完毕**（2026-10-03）。结论：**只有 UTF-16LE + BOM 可用**。UTF-8 无 BOM ⇒ **静默乱码**；UTF-8 有 BOM ⇒ **键都找不到**（设置被静默忽略）；UTF-16LE 无 BOM ⇒ 乱码；系统 ACP ⇒ 本机可用但换区域设置即坏。写侧：`WritePrivateProfileStringW` 对**全新文件**会写成 ANSI。见 `verified-after-injection/09-ini-encoding.md` |
| ~~T3~~ | ~~`action=pipe` 全链路~~ | — | ✅ **已验证完毕**（2026-10-03）。报文逐字节正确；**UI 线程实测未被拖住**（`Invoke` 往返 7–14 ms），管道 IO 在独立线程（tid 可证）；服务端缺失时**瞬时降级**且有日志；配置热重载顺带验证。★ 副产品：发现 `ConnectNamedPipe` 的合法失败**有两种**（110 / **232**），后者写错会**静默丢点击**。见 `verified-after-injection/08-pipe-action-chain.md` |
| ~~T4~~ | ~~"面板已打开时注入"的真实行为~~ | — | ❌ **不做支持（by design）**。原因：**音量浮层不是常驻窗口** —— 只在按快捷键时出现、失焦即消失。产品模型是"注入一次 → TAP 常驻 → 之后每次打开面板自动注入"（§9），**不需要**"往一个已经开着、正在被看的浮层里插东西"。故此行为不进验收。（曾观察到面板消失但原因未定，与产品无关） |
| T5 | **TAP → App 的"注入完成"回传**（`INJECTED <entryId>`） | 中 | 目前托盘状态只能到"TAP 就绪"，说不了"按钮已添加"（§3.14） |
| T6 | 多显示器 / 不同缩放下的几何 | 中 | §5.2 用的是相对关系 + 常量 4，理论上缩放无关，但**未验证**；与 R3 一起看 |
| T7 | 深色/浅色主题、高对比度主题下的一致性 | 低 | `Foreground`/`Style` 已复制，理论上跟随主题 |
| T8 | 一个 ShellHost 里两个诊断会话并存的实际后果 | 低 | V6 覆盖 |
| T9 | ⭐ **R7 的额外重建成本是否可接受** | 中 | 若不可接受，评估"把 `VmExt.Shared` 改成 DLL 并严格处理 I4"——**但这是一次架构级改动，不要轻易做** |
| T10 | ⭐ **验收脚本在非 100% 缩放下的坐标处理** | 中 | UIA 返回物理像素；要在 100% 缩放下跑，或做 DPI 换算。写进脚本的说明里 |
| T11 | 配置对话框的完整度 | 低 | v1 只做"总开关 + 诊断运行时路径 + 按钮文字"，其余让用户编辑 INI（§3.15） |
| ~~T12~~ | ~~`ListContent.Content` 可写性与还原~~ | — | ✅ **已验证**（2026-10-03）。写入与还原均成功。见 `verified-after-injection/10-page-swap-capability.md` |
| ~~T13~~ | ~~换内容的最佳时机~~ | — | ✅ **已验证**。`Footer` 触发时 `PageWindow`/`ListContent` 已就绪、原内容已非空 ⇒ 无需额外调度 |
| ~~T14~~ | ~~`ComboBox` / `ListView` / `Slider` 可用性~~ | — | ✅ **已验证**。10 个控件类型全部可激活（含 `ComboBoxItem`/`ListViewItem`/`Image`/`ScrollViewer`）。★ 顺带纠正：实际用 **C++/WinRT 直接激活**，不是 `IVisualTreeService::CreateInstance`（见 §5.7.4） |
| **T15** | 系统页被换下后是否仍在后台活动 | 中 | 音频计量、设备枚举轮询等；若要显式停用需评估副作用 |
| **T16** | 自定义页在 `ScrollViewer` 内的尺寸策略 | 中 | `Height` 自适应 vs 固定值；影响滚动行为（AT-22） |
| **T17** | 底栏按钮**悬停/按下时的填充** | 低 | 已验静止态：**无边框、无填充**、`Foreground` 等效 `TextFillColorSecondary`（`../design.md` §7.5.1）。但 hover 填充**没采到**（截图时鼠标不在按钮上）。PoC 注释假设 `94x40` 框是 hover 高亮 —— **该假设未独立验证**。做法：开面板 → 把鼠标移到「更多音量设置」上 → 截图取像素 |
| ~~T18~~ | ~~`CheckBox` 类型是否可激活~~ | — | ✅ **已验证**（2026-10-03）。`CheckBox` 可激活、`IsChecked`（`IReference<bool>`）可往返、`MinHeight(0)` 可设、可挂进可视树；`ToggleButton` 的 `Controls.Primitives` 命名空间问题同时闭合。证据：`verified-after-injection/11-checkbox-capability.md` |
| **T19** | ⭐ **`ToggleSwitch` 类型是否可激活** | 中 | §5.7.8 的「开机启动」要用。**不在已验集合里**（T14 的 10 个 + T18 的 `CheckBox` 都不含它）。同在 `Windows.UI.Xaml.Controls` 下，预计可用。做法同 T18：探针加一行 + 读回 `IsOn` |
| ~~T20~~ | ~~`NavigatingCancelEventArgs.Cancel` 是否可写~~ | — | ✅ **不需要了**（2026-10-03）：设置页标题行的系统后退键**保持默认行为，不拦**（§5.7.8） |
| ~~T21~~ | ~~`ContentDialog` 是否可激活~~ | — | ✅ **不需要了**（2026-10-03）：「从系统卸载」改用**连击 5 次**确认，不用浮层（§5.7.8） |
| ~~T22~~ | ~~打开 URL 用 `exec` 还是新增 `action=open`~~ | — | ✅ **已定：新增 `action=open`**（`ShellExecuteW(..., L"open", url, ...)`），见 §2.3 / §4.2.5 / §5.7.6。⛔ 不复用 `exec`：`CreateProcessW` 只认 exe，URL 不是 exe |
| **T23** | ⭐ **`Slider.ValueChanged` 里直调 `SetMasterVolumeLevelScalar` 的往返耗时** | 中 | §5.7.9 已定方案 A（TAP 内直调）。这是**跨进程 COM 调用**（到 `audiosrv`），若达数十 ms 且 UI 线程同步等待，拖动会顿。做法：探针里对唯一渲染端点连调 100 次，量单次中位数/p95 |
| **T24** | ⭐ **`RegisterControlChangeNotify` 的回调在哪个线程** | 中 | §5.7.9 约束 A2。若回调**不在** UI 线程而我们直接改 UI ⇒ 崩。做法：回调里打印 `GetCurrentThreadId()`，与 UI 线程 id 比对；再试一次直接改 `Slider.Value`（看是否抛 `RPC_E_WRONG_THREAD` / `UnauthorizedAccessException`） |
| **T25** | ⛔ **已关闭（2026-10-03）**：不做控制台子系统改造 | — | `vmex.exe` 是控制台子系统，登录自启会闪一下黑窗。**已决定接受**（换 `Run` 键免不掉这一下 —— 闪不闪由镜像声明的子系统决定）。真要免掉仍需改 `WIN32` 子系统 + `AttachConsole(ATTACH_PARENT_PROCESS)` |

---

## 11. 附录

### 附录 A：`xamlOM.h` 关键签名

来源：`C:\Program Files (x86)\Windows Kits\10\Include\10.0.26100.0\um\xamlOM.h`（✅ 已核对）

```cpp
// 入口：必须由目标进程自己调用（该导出位于目标的 Windows.UI.Xaml.dll）
_Check_return_ HRESULT InitializeXamlDiagnosticsEx(
    _In_ LPCWSTR endPointName,           // 如 L"VisualDiagConnection1"
    _In_ DWORD   pid,                    // GetCurrentProcessId()
    _In_ LPCWSTR wszDllXamlDiagnostics,  // SDK 的 xamldiagnostics.dll 绝对路径
    _In_ LPCWSTR wszTAPDllName,          // 我们的 TAP DLL 绝对路径
    _In_ CLSID   tapClsid,               // contract::kTapClsid
    _In_ LPCWSTR wszInitializationData); // ★ §2.2 的 k=v; 串

typedef MIDL_uhyper InstanceHandle;                        // u64

typedef enum VisualMutationType { Add = 0, Remove = 1 } VisualMutationType;

typedef struct VisualElement {
    InstanceHandle Handle;
    SourceInfo     SrcInfo;
    BSTR           Type;      // ⛔ 只读，不要 SysFreeString
    BSTR           Name;      // ⛔ 只读，不要 SysFreeString
    unsigned int   NumChildren;
} VisualElement;

typedef struct ParentChildRelation {
    InstanceHandle Parent;
    InstanceHandle Child;
    unsigned int   ChildIndex;
} ParentChildRelation;
```

**本方案用到的三个接口**：

| 接口 | IID | 用到的方法 |
|---|---|---|
| `IVisualTreeServiceCallback` | `{AA7A8931-80E4-4FEC-8F3B-553F87B4966E}` | `OnVisualTreeChange(ParentChildRelation, VisualElement, VisualMutationType)` |
| `IVisualTreeService` | `{A593B11A-D17F-48BB-8F66-83910731C8A5}` | `AdviseVisualTreeChange(IVisualTreeServiceCallback*)`、`UnadviseVisualTreeChange`（**不用**）、`AddChild`/`RemoveChild`/`CreateInstance`/`SetProperty`（**不用**，见下） |
| `IXamlDiagnostics` | `{18C9E2B6-3F43-4116-9F2B-FF935D7770D2}` | ⭐ `GetIInspectableFromHandle(InstanceHandle, IInspectable**)`、⭐ `GetInitializationData(BSTR*)` |

**其余可选接口（刻意不用）**：

| 接口 | IID | 为什么不用 |
|---|---|---|
| `IVisualTreeServiceCallback2` | `{BAD9EB88-AE77-4397-B948-5FA2DB0A19EA}` | `OnElementStateChanged` 对需求无价值，多实现一个接口就多一份 vtable 出错风险 |
| `IVisualTreeService2` / `IVisualTreeService3` | `{130F5136-...}` / `{0E79C6E0-85A0-4BE8-B41A-655CF1FD19BD}` | 提供"用诊断 API 造元素"的能力。我们选择用 **C++/WinRT 直接构造 XAML 对象**（类型安全、编译期检查、代码短）。用诊断 API 要手写 `BSTR typeName` 与字符串化属性值（`"Windows.UI.Xaml.Controls.Button"`、`"4,0,4,0"`），脆弱且无编译期保护。⭐ **本轨道下这个选择更明显**：既然整个项目都是 C++，直接 `#include <winrt/...>` 是最自然的做法 |
| `IObjectWithSite` | OS 标准 | **必须实现**：用来接收 `IXamlDiagnostics*` |

### 附录 B：PoC → C++ 产品代码映射表

PoC 在 `docs/poc/`，**已跑通**。⭐ 这个映射不需要任何"重写为另一种语言"，PoC 与产品同语言同工具链。

| PoC 文件 | 行数 | 产品对应 | 需要做的改动 |
|---|---|---|---|
| `injector.cpp`（4096 B） | ~150 | `src/VmExt.Control/vmext_injector.cpp` | ① 把 `main()` 改造成**库函数** `InjectInto(pid, path, timeout)`；② 把 `exit code` 改成 `inject::Error` 枚举 + `Name()`；③ ⭐ **换成"本地 RVA + 远程基址"算法**（PoC 用的是"本地 kernel32 地址当远程地址"的简化，见 §3.8）；④ 用 `win32::UniqueHandle` 替代手写 `CloseHandle`；⑤ 加 `TargetGone` 的 `ERROR_INVALID_PARAMETER` 映射 |
| `vcxlaunch.cpp` | ~200 | `src/VmExt.Launcher/launcher.cpp` | ① 读 `initdata` 并传第 6 个参数（PoC 传 `nullptr`）；② ini 名改 `VmExt.Launcher.ini`；③ 日志/ini/字符串工具改用 `VmExt.Shared`（删掉本地重复实现）；④ CLSID 改用 `contract::kTapClsid`；⑤ 端点名用 `contract::EndPointName(i)` |
| `vcxtap.cpp` | 631 | `src/VmExt.Tap/tap.cpp` | ① 读 initData（`Contract::Parse`）+ 单例互斥体（§4.2.3）；② 配置从 `vmext-tap.ini` 读（现在是 `vcxtap.ini` 的 `stage`）；③ `RunWinver()` → `PerformClickAction(entry)` + `pipe` 模式；④ 按钮文字/边距/高度来自配置；⑤ 去掉 `stage` 分级日志机制，只留 `enabled`；⑥ **vtable / 包 Grid / 定位 / 样式复制这些核心代码保持不动**（已跑通，重写没有收益） |
| `vcxmix.cpp` | ~600 | **无**（方案 A 已证伪） | ⛔ **删除**。留在 `docs/poc/src/` 作为记录，不要带进产品仓库 |
| `build.cmd` | — | `VolumeMixerExtender.props` + `*.vcxproj` | 见 §7.2/§7.3。`build.cmd` 的**最小编译/链接参数**就是 `.props` 的取值来源（尤其是 `/std:c++17`→`/std:c++20`、`/MT`、`/EXPORT:`） |
| `cycle.ps1` / `scripts\*.ps1` | — | 保留在开发工具目录 | 见 §8.3 |
| —（无对应） | — | `src/VmExt.App/*`、`src/VmExt.Control/*`（除 injector） | ⭐ **全部是新代码**：托盘、配置窗、IPC 服务端、Watcher、Orchestrator、Health、DiagLocator、TapProbe。这部分是本轨道的**主要工作量**（估算 2000–3000 行） |

**必须一起搬过去的"踩坑修正"**（PoC 花时间换来的，重新踩一遍毫无意义）：

1. 日志用 `CreateFileW` 而不是 CRT 流（§4.3 坑 2）
2. `STDAPI` + `/EXPORT:`（§4.3 坑 3）
3. `#undef GetCurrentTime`（§4.3 坑 6）
4. `IndexOf` + `RemoveAt` 而不是 `Remove`（§4.3 坑 8）
5. `Grid::SetColumn` 要 `FrameworkElement`（§4.3 坑 9）
6. 列 0 用 `Star` 不用 `Auto`（§5.2）
7. `Height` 读显式属性、不测量（§5.3）
8. 所有 `ActualXxx` 先判 `>0`（§5.5 / I1）
9. `WaitForMultipleObjects` 等进程句柄而不是轮询（§3.7）
10. `ConnectNamedPipe` 的合法失败**有两种**：`ERROR_PIPE_CONNECTED`(110) 与 `ERROR_NO_DATA`(232)（§3.13；实测见 `08-pipe-action-chain.md`）

### 附录 C：环境事实速查（实测，用于交叉核对）

| 项 | 值 |
|---|---|
| Windows build | 26300.9550 |
| 面板窗口类 / 标题 | `ControlCenterWindow` / 「快速设置」 |
| 面板 band | **4** |
| 面板宿主 | `ShellHost.exe`，父进程 `sihost.exe` |
| 面板子窗口（XAML 宿主） | `Windows.UI.Input.InputSite.WindowClass`（UIA `FrameworkId=XAML`） |
| XAML 实现 | **System XAML** = `Windows.UI.Xaml.dll` 10.0.26100.8972（**不是** WinUI3） |
| `Windows.UI.Xaml.dll` 相关导出 | `InitializeXamlDiagnosticsEx`、`GetDependencyObjectAddress`、`OverrideXamlMetadataProvider` |
| 诊断运行时 | `xamldiagnostics.dll`（SDK 10.0.14393.33）位于 `C:\Program Files (x86)\Windows Kits\10\bin\x64\XamlDiagnostics\` |
| `ControlCenter.dll` | 4 MB WinRT 组件，只导出 `ControlCenterMain` / `DllCanUnloadNow` / `DllGetActivationFactory` |
| `ControlCenter.*` 是否注册为 ActivatableClassId | **否**（所以方案 A 才需直接调 `DllGetActivationFactory`） |
| ShellHost 完整性级别 | Medium IL，非 PPL，`OpenProcess(ALL_ACCESS)` 成功 |
| 底栏几何（注入前） | `(2189,1417) 358x48` |
| 模型按钮几何 | `(2193,1420) 94x40`，`Height=40.0` 显式，`MinHeight=0.0`，`Style` 非空 |
| 注入后按钮几何 | `(2472,1419) 71x40`（右边缘 2543 = 2547-4，高 40） |
| C++ 工具链 | VS18 Community 14.50.35717（另有 VS2022 BuildTools 14.44）；Windows SDK 10.0.26100.0（含 cppwinrt 头） |
| `cl` / `cmake` / `msbuild` | **都不在 PATH**。`cl` 在 `<VS>\VC\Tools\MSVC\14.50.35717\bin\Hostx64\x64\`；CMake 在 `C:\Program Files\CMake\bin\` |
| dotnet SDK（本轨道**不需要**） | 8.0.425 / 10.0.103 |
| WDK | **未安装**（`Include\10.0.26100.0\km` 缺失）→ 驱动开发被阻断，但本方案不需要 |

### 附录 D：参考

| 来源 | 内容 |
|---|---|
| `Win11-QuickSettings-XAML-Injection-Notes.md` §9–§11 | 全部探测过程与结论、注入落地的完整记录 |
| `docs/design.md` §2 §6 | 方案选型（含方案 A 完整证伪证据链）、最终实现说明 |
| `docs/reference/research-agent-report.md` | 外部调研：Windhawk / ExplorerPatcher / XAML 诊断 API（带源码引用） |
| `xamlOM.h` | 诊断接口的权威定义（附录 A 即摘自此文件） |
| `microsoft/microsoft-ui-xaml` Samples/WinUISnoop、`asklar/lvt`、`TranslucentTB/ExplorerTAP`、`m417z/UWPSpy` | 现成 TAP 实现的可参考样本 |
| Microsoft Docs: `Shell_NotifyIcon`、`Named Pipes`、`Toolhelp32Snapshot`、`CreateRemoteThread` | §3 各处 Win32 用法的官方说明 |

### 附录 E：修改记录

| 版本 | 日期 | 变更 |
|---|---|---|
| 1.0 | 2026-10-03 | 首版。基于已跑通的 PoC（Route B：XAML 诊断 TAP）。含 §2.0 共享契约头、§3 控制面逐模块、§4 in-proc 两段、§5 算法与不变量（含 I4）、§6 异常/资源策略、§7 原生构建与调试、§9.4 原生崩溃与句柄泄漏排障、§10.3 本轨道特有风险 |
| 1.1 | 2026-10-03 | 目标修订为「入口接管 + 页面内容替换」，新增 §5.7、AT-17…AT-22、T12…T16；删除两轨选型对照（§1.0），全文改为单轨表述；C# 版交付文档已删除 |


