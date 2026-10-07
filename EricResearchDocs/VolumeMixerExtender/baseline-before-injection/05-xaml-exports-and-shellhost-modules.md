<!-- 冻结快照：内容逐字摘录自 docs/reference/raw-outputs.md §07–§08 -->

> **来源**：`docs/reference/raw-outputs.md §07–§08`（逐字摘录，未改写）
> **采集时间**：2026-10-03
> **环境**：Windows 11 build 26300.9550，交互会话 2，System XAML
> **用途**：支撑"面板是 System XAML 而非 WinUI3"、"Windows.UI.Xaml.dll 导出 InitializeXamlDiagnosticsEx"，以及"ControlCenter.dll 只导出三个符号"这三条结论 —— 它们解释了为什么必须走 XAML 诊断 API 这条路。

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
