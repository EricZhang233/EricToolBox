> **来源**：`docs/poc/src/vcxtap.cpp` 内的一次性能力探针（`ProbeCapabilities`，与 `10-page-swap-capability.md` 同一函数）
> **采集时间**：2026-10-03 14:18:43
> **环境**：Windows 11 build 26300.9550，交互会话 2，ShellHost pid 12452，面板 hwnd `0x000303BE` band=4
> **用途**：解除「录制模式」复选框的**最后一个前置未知项** —— `CheckBox` 类型能否在 ShellHost 内激活并使用（T18）。
> 方法：在既有注入时机（命中 `Footer`）插的探针里追加 `CheckBox` 一组，跑一次 `cycle.ps1` 即得结论 ——
> **未新建工程、未新增脚本、未新增注入时机**。

---

## 1 · T18：`CheckBox` 可用 —— ✅

```text
[14:18:43.620 tid=8872] === capability probe (T14) ===
[14:18:43.632 tid=8872]    [ok]   ComboBox
[14:18:43.632 tid=8872]    [ok]   ComboBoxItem
[14:18:43.632 tid=8872]    [ok]   ListView
[14:18:43.632 tid=8872]    [ok]   ListViewItem
[14:18:43.632 tid=8872]    [ok]   Slider
[14:18:43.632 tid=8872]    [ok]   StackPanel
[14:18:43.632 tid=8872]    [ok]   Grid
[14:18:43.632 tid=8872]    [ok]   TextBlock
[14:18:43.632 tid=8872]    [ok]   ScrollViewer
[14:18:43.632 tid=8872]    [ok]   Image
[14:18:43.632 tid=8872] === capability probe (T18: CheckBox) ===
[14:18:43.635 tid=8872]    [ok]   CheckBox
[14:18:43.635 tid=8872]    [ok]   ToggleButton
[14:18:43.635 tid=8872]    [ok]   CheckBox 建/设值/挂树：Content=probe  IsChecked=true  MinHeight=0.0
```

| 检查项 | 结果 |
|---|---|
| `WUXC::CheckBox` 可激活（`Windows.UI.Xaml.Controls.CheckBox`） | ✅ |
| `WUXCP::ToggleButton` 可激活（`Controls.Primitives`） | ✅ 见 §2，闭合 `10-` 留下的那条 ⚠️ |
| `Content` 可设（`winrt::box_value(L"probe")`） | ✅ 读回 `probe` |
| **`IsChecked` 可设且可读回**（`IReference<bool>` 往返） | ✅ 读回 `true` |
| `MinHeight(0.0)` 可设（紧凑模板的前提） | ✅ 读回 `0.0` |
| 可挂进可视树（`StackPanel.Children().Append`） | ✅ 未抛异常 |

⇒ 「录制模式」复选框**在注入侧没有形态风险**。方案 §5.7.7 的四条实现约束里，
第 4 条（紧凑模板）所需的 `MinHeight(0.0)` 已一并验证可用。

## 2 · 顺带闭合：`ToggleButton` 的命名空间问题

`10-page-swap-capability.md` §1 留过一条 ⚠️：`ToggleButton` 不在 `Windows.UI.Xaml.Controls` 下，
编译期报 C2039，当时**未纳入探测**。

本次加了 `namespace WUXCP = winrt::Windows::UI::Xaml::Controls::Primitives;` 别名后，
**编译通过、运行期也可激活**。该条 ⚠️ 可以撤销。

> 注：`vcxtap.cpp` 早就 `#include <winrt/Windows.UI.Xaml.Controls.Primitives.h>` 了（line 53），
> 缺的只是命名空间别名。

## 3 · 副作用检查：探针没有破坏面板

同一轮 cycle 的底栏几何（`footer-map.ps1` 读取）：

```text
  [Footer] Group name=[] rect=(2189,1417 358x48)
    [] Button name=[更多音量设置] rect=(2193,1420 94x40)
    [VmExtEntry] Button name=[TestLink] rect=(2472,1419 71x40)
```

与 `01-footer-geometry-after.md` 的基准**逐像素一致**（Footer `358x48` 未变、模型按钮 `94x40` 未动、
我们的按钮仍在 `(2472,1419) 71x40`）⇒ 说明探针建的 `CheckBox`/`StackPanel` 只活在局部作用域，
读写 `ListContent.Content` 后已还原，**未污染可视树**。

## 4 · 复现命令

```powershell
# 编译期先单独确认（不链接，避免 cycle 在"已杀 explorer"那步因编译错误停住）
#   cl /c src\vcxtap.cpp ...   -> exit 0

& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -ExecutionPolicy Bypass `
  -File 'docs\poc\scripts\cycle.ps1'

# 探针行不在 cycle.ps1 的过滤模式里，直接读原始日志：
Select-String -Path docs\poc\vcxtap.log -Pattern 'capability probe|\[ok\]|\[FAIL\]'
```

---

## 结论

**T18 ✅ 通过**（2026-10-03）。`CheckBox` 可激活、`IsChecked` 可往返、`MinHeight(0)` 可设、可挂树。
「录制模式」复选框的实现前置全部解除；`ToggleButton` 的命名空间遗留问题同时闭合。
