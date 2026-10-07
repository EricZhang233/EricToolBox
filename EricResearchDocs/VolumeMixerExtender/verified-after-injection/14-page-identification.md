# 怎么认出「声音页」——入口判断

被测代码：`Components/inject.tap/Tap.cpp` + `Components/inject.tap/Page.h`。
采集时间：2026-10-03，本机（Windows 11 26100.9549，RDP）。

本文件回答一个 bug：**为什么「辅助功能」等其它二级菜单也被接管了**，
以及为什么答案不能是"看页面长得像不像"。

---

## 1. 症状

按 `OnVisualTreeChange` 匹配 `Add` + `Name == "Footer"` 就接管 ⇒ **所有 L2 页面都被接管**。

## 2. 为什么：所有 L2 页面**共用同一套壳**

用干净 shell（不注入）逐个页面实测，**逐项同名同结构**：

| | 声音输出 | 辅助功能 | 投影 |
|---|---|---|---|
| `PageWindow` | ✅ | ✅ | ✅ |
| `PageHeader`（ContentPresenter） | ✅ | ✅ | ✅ |
| `PageHeaderContentControl` | ✅ | ✅ | ✅ |
| `PageContent`（ContentPresenter） | ✅ | ✅ | ✅ |
| `ListContent`（ScrollViewer） | ✅ | ✅ | ❌ 页面根本没有 |
| `Footer`（ItemsControl，1 项） | ✅ | ✅ | ✅ |
| 标题控件 | `TextBlock name=[PageTitleText]` | `TextBlock name=[PageTitle]` | **`PageTitleText`** |

⚠️ **最后一行是踩过的坑**：曾经以为「标题控件叫 `PageTitleText`」是声音页的指纹
（辅助功能确实叫 `PageTitle`）。**投影用的是同一个 `PageTitleText`** —— 它只是被拦在
`ListContent 不是 ScrollViewer` 那一条上，纯属运气。

其它试过、**都不成立**的判据：

| 判据 | 实测结果 |
|---|---|
| 标题文本（"声音输出"） | ⛔ 本地化文本，不能用 |
| `ListContent.Content` 的**类型** | ⛔ 每个页面都是 `Windows.UI.Xaml.Controls.ItemsControl` |
| `PageWindow` 子树里有没有某个 AutomationId | ⛔ 找不到（`OutputGroupTitle` 那批**不是** `AutomationProperties`，见 §4） |
| `L2Frame` 导航参数 | ⛔ `ControlCenter.FrameWithContentChanged` **确实是 `Frame`**，`Navigated` 在**每条**入口路径上都触发，但 `Parameter` 是 `ControlCenter.AdvancedPageInfo`，**每次导航都是一个新对象**（实测 5 次拿到 5 个不同地址 `0xBFA27730` / `0xBFAC8490` / …），也不实现 `IStringable` ⇒ **读不出页面身份** |

> ℹ️ **入口信号是存在的、也是全路径覆盖的**（`L2Frame.Navigated` 每次进 L2 都触发），
> 只是它带的信息不足以区分页面。所以"入口"只用来**决定时机**，"是不是声音页"仍然要看页面自己。

## 3. 于是判据分两条，按入口走（`Page.h`）

### 3.1 判据 1 —— 入口（快路径，不闪）

L1 的「选择声音输出」按钮 `x:Name` 是 **`VolumeL2Button`**（实测：UIA `id=[VolumeL2Button]`）。
TAP 在它 `Add` 时给它挂一个 `Click`（**只观察**，系统自己的 handler 照跑），
置一个 5 秒的一次性标记；下一个 `Footer` 出现时**直接接管**，不必等页面内容。

⚠️ **`Win+Ctrl+V` 不走它**：实测快捷键路径**没有**触发 `Click`。所以必须有判据 2。

### 3.2 判据 2 —— 页面自己的内容（兜底，全覆盖）

这些是**声音页自己的 `x:Name`**（干净 shell + 深度 dump 读出来的，不是本地化文本，
也不是 `AutomationProperties`——系统那几个 `OutputGroupTitle` 之类的 UIA id 就来自 XAML 名字）：

```
OutputGroupTitle / MixerGroupTitle / SpatialGroupTitle / ListWithOutputGroupTitle
```

命中任意一个 ⇒ 是声音页。**正向判据**，所以 shell 改版把名字改掉时是**失败关闭**
（不再接管声音页），而不是去劫持别的页面。

⛔ **深度是这里的头号坑**：这些名字在页面根往下约 **25 层** ——
`PageContent → ListContent → ItemsControl → ItemsPresenter → StackPanel → ContentPresenter
→ GridView → ScrollViewer → ScrollContentPresenter → GridViewItem → ListViewItemPresenter → …`
（两层虚拟化列表）。深度上限取 24 时**静默返回"没有"**，表现是"声音页自己也不认"。
现在上限 **32**。

## 4. 接管被推迟了（这是有意的）

判据 2 要等页面**建完自己的内容**才成立，所以 `TakeOver` 只是"认领"这一页，
真正改树发生在 `Settle` 循环里认出内容之后：

```text
Footer appeared            -> 认领（先什么都不改）
+43 ms  页面里有声音页自己的内容 -> 接管
+110..125 ms  底栏三格已挂载
```

实测 43–67 ms 认出、110–125 ms 挂完底栏 —— **面板入场动画还没结束**，所以看不见系统页。
（`CommitTakeover` 之前不动 `ListContent.Content`，是为了"不是声音页"时**一个字节都不改树**。）

### 性能：识别必须节流

识别是一次深度 32 的全树遍历。挂在 `CoreDispatcherPriority::Low` 上时，
**Low 队列每秒能排空上千次**（实测：底栏重试链 450 ms 跑了 4450 次），
不节流就是每帧走一遍整棵树。现在按 **25 ms** 节流（中间的空转只是一次取时钟），
再加上底栏自己的 `SizeChanged` / `LayoutUpdated` 做即时唤醒 —— 挂载仍然落在第一次唤醒上。

> ⚠️ 反过来也不行：试过"识别阶段只靠事件驱动"，结果**漏掉**了内容出现的那一刻
> （底栏的 layout 事件在内容落地前就停了），快捷键路径整条失效。所以是"链 + 节流"，不是"只事件"。

## 5. 验收（UIA 实测，四条路径）

| # | 路径 | 期望 | 实测 |
|---|---|---|---|
| 1 | L1「选择声音输出」 | 接管 | ✅ `入口「选择声音输出」被点击 -> 直接接管` |
| 2 | `Win+Ctrl+V` | 接管 | ✅ `页面里有声音页自己的内容 -> 接管` |
| 3 | L1「辅助功能」 | **原样** | ✅ `无法确认是声音页（标题="辅助功能"）-> 不接管` |
| 4 | L1 第二页「投影」 | **原样** | ✅ `ListContent 不是 ScrollViewer -> 不接管` |

路径 3/4 的页面内容与系统完全一致（辅助功能：放大镜 / 讲述人 / 颜色滤镜 / 实时字幕 /
单声道音频 / 语音访问 / 粘滞键 / 更多辅助功能设置；投影：更多显示设置），
底栏也是它们自己那一格 —— **没有被换成我们的三格**。

> 回归：自定义页 / 设置页 / 系统页三态往返、`关闭再打开`、`Win+Ctrl+V` 直进，
> 底栏几何与 `13-footer-mount.md` §3 完全一致，ShellHost 存活。
