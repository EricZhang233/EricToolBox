> **来源**：`docs/poc/src/vcxtap.cpp` 内的一次性能力探针（`ProbeCapabilities`）
> **采集时间**：2026-10-03 13:37:20
> **环境**：Windows 11 build 26300.9550，交互会话 2，ShellHost pid 6072
> **用途**：验证"入口接管 + 页面内容替换"方案的三个前置未知项（T12 / T13 / T14）。
> 方法：在既有注入时机（命中 `Footer`）插入探针，跑一次 `cycle.ps1` 即得全部结论 ——
> **未新建任何工程、未新增脚本**。

---

## 1 · T14：控件类型可激活性 —— ✅ 全部可用

```
=== capability probe (T14) ===
   [ok]   ComboBox
   [ok]   ComboBoxItem
   [ok]   ListView
   [ok]   ListViewItem
   [ok]   Slider
   [ok]   StackPanel
   [ok]   Grid
   [ok]   TextBlock
   [ok]   ScrollViewer
   [ok]   Image
```

自定义页所需的三类关键控件 —— **`ComboBox`（下拉框）、`ListView` + `ListViewItem`（应用列表）、
`Slider`（音量条）—— 全部可激活**。这解除了本方案最大的形态风险。

> ⚠️ `ToggleButton` 不在 `Windows.UI.Xaml.Controls` 命名空间下（编译期即失败，C2039），
> 它属于 `Controls.Primitives`。本次未纳入探测；静音键可改用 `Button`，或按该命名空间再引一次。
> **→ 已在 `11-checkbox-capability.md` 闭合**：加 `WUXCP` 别名后编译通过且可激活。

## 2 · ⚠️ 顺带纠正一处文档与实现的偏差

**交付文档写的是 `IVisualTreeService::CreateInstance`，但 PoC 实际用的是 C++/WinRT 直接激活**
（`WXC::Button btn;`，即 `RoActivateInstance`）。两者都能建元素，但性质不同：

| | C++/WinRT 直接激活 | `IVisualTreeService::CreateInstance` |
|---|---|---|
| 用法 | `WUXC::ComboBox c;` | 先取 `CreateInstance(typeName, ...)` |
| 依赖 | WinRT 类型工厂（ShellHost 里 `Windows.UI.Xaml` 已加载） | 诊断服务 |
| 状态 | ✅ **PoC 全程在用，已验** | ❓ 未验证 |

**本方案按 C++/WinRT 直接激活走**（已验、更简单）。文档 §5.7.4 的措辞需据此修正。

## 3 · T12：`ListContent.Content` 可写且可还原 —— ✅

```
=== capability probe (T12) ===
   PageWindow = found
   ListContent = found
   ListContent class = Windows.UI.Xaml.Controls.ScrollViewer
   as ScrollViewer = yes
   original Content = non-null
   *** set Content = OK  (T12 写入可用) ***
   *** restore Content = OK ***
```

| 检查项 | 结果 |
|---|---|
| 从 `Footer` 沿祖先链能找到 `PageWindow` | ✅ |
| `PageWindow` 下能按名找到 `ListContent` | ✅ |
| `ListContent` 确实是 `ScrollViewer` | ✅（与 UIA 的 `Pane` 判定一致） |
| 原 `Content` 非空（有东西可保存） | ✅ |
| 写入我们的元素 | ✅ |
| **还原原 `Content`** | ✅ |

替换与还原都成功，且**替换后原内容可原样写回** —— 这是"系统页 ↔ 自定义页"切换的实现基础。

## 4 · T13：换内容的最佳时机 —— ✅ `Footer` 触发点已足够

探针在 **`Footer appeared` 的同一时刻**运行，此时：

- `PageWindow` 已存在且可上溯到；
- `ListContent` 已在树中且可定位；
- 它的 `Content` 已非空 —— **说明系统页的内容已经构建完成**。

⇒ **不需要额外的延迟或二次调度**。原先担心的"注入早于布局"问题（§5.5 记录过
`ActualWidth` 为 0 的坑）在**查找结构**这一层不成立；但**读取尺寸**仍要看 `ActualWidth > 0`
（那是另一回事）。

## 5 · 副作用检查 —— ✅ 探针未破坏面板

探针之后同一轮里注入继续正常：

```
   *** TestLink injected on the SAME row as the model button (right aligned) ***
   *** TestLink injected (click -> action=exec) ***
```

重新打开面板后的 UIA 几何：

```
  [Footer] Group rect=(2189,1417 358x48)
    [] Button name=[更多音量设置] rect=(2193,1420 94x40)
    [VmExtEntry] Button name=[TestLink] rect=(2472,1419 71x40)
```

底栏仍是 `358x48`、模型按钮位置不变、我们的按钮仍 `(2472,1419) 71x40` —— **与历史基准逐像素一致**。
"换内容再还原"是可安全做的操作。

## 6 · 结论

| # | 项 | 结论 |
|---|---|---|
| **T14** | `ComboBox` / `ListView` / `Slider` 可创建 | ✅ **可用**，界面形态不受限 |
| **T12** | `ListContent.Content` 可写 + 可还原 | ✅ **可用**，切换机制成立 |
| **T13** | `Footer` 触发时结构是否就绪 | ✅ **已就绪**，无需额外调度 |

方案的两个关键假设（能画出自定义页、能挂上去并切回）**都已落地验证**。
