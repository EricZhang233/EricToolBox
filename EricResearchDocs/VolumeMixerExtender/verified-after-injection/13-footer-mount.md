# 底栏挂载（产品侧实测）

对应验收用例 **AT-01/AT-03/AT-04**（底栏三格同一行 · 点击可用 · 与系统项视觉一致）。
被测代码：`Components/inject.tap/Tap.cpp` + `Components/inject.tap/Page.h`（产品侧，不是 PoC）。
采集时间：2026-10-03，本机（Windows 11 26100.9549，RDP）。

本文件回答的是「**为什么底栏一直是空的**」——这个卡了很久的问题有 **3 个独立原因**，
其中 1 个是我们自己的假设错了，2 个是真 bug。都在下面给了实测证据。

---

## 1. `Footer` 的真实结构（实测，不是猜的）

`Footer` **不是**一个直接装按钮的容器，而是**两层嵌套的 `ItemsControl`**。
`TapPageDumpTree` 的实测输出（`Page.h` 里的诊断，深度 14）：

```text
ItemsControl name=[Footer]            vis=0 size=358x48 items=1 children=1
  ItemsPresenter                      vis=0 size=358x48 children=3
    ContentControl                    vis=1 size=0x0 children=0        ← 回收容器（Collapsed）
    StackPanel                        vis=0 size=358x48 children=1     ← Footer 的 ItemsPanel（Vertical）
      ContentPresenter                vis=0 size=358x48 children=1     ← Footer 那条 item 的容器
        Border                        vis=0 size=358x48 children=1
          ItemsControl                vis=0 size=358x47 items=1 children=1   ← ★ 真正装底栏项的控件
            ItemsPresenter            vis=0 size=358x47 children=3
              ContentControl          vis=1 size=0x0 children=0       ← 回收容器
              StackPanel              vis=0 size=358x47 children=1    ← ★ 底栏这一行的 ItemsPanel
                ContentPresenter      vis=0 size=358x42 children=1
                  ContentControl      vis=0 size=358x42 children=1
                    ContentPresenter  vis=0 size=358x42 children=1
                      Button          vis=0 size=94x40 children=1    ← ★ 「更多音量设置」（模型项）
                        Grid name=[RootGrid]          94x40
                          ContentPresenter name=[Content]  72x29
                            TextBlock                     72x8
              ContentControl          vis=1 size=0x0 children=0       ← 回收容器
    ContentControl                    vis=1 size=0x0 children=0
```

要点：

| # | 事实 | 后果 |
|---|---|---|
| 1 | 模型 `Button` 在 **`Footer` 往下第 12 层** | 见 §2.1 |
| 2 | 两层 `ItemsPanel` 都是**纵向 `StackPanel`** | 见 §2.3 |
| 3 | 模型按钮 `94x40` = 文字 `72` + 左右各 `11`；底栏内缩 **4px**（`2193 − 2189`） | 与 `layout-preview.html` 的 `.fbtn` / `.footerbar` 逐项一致 |
| 3b | 主体的左右内缩是 **8px**（`PageWindow` x=2189，内容 x=2197） | 见 §3.2：底栏保持 4px 与系统对齐，内容更深一档；内缩只能加在**主体容器**上 |
| 4 | 模型按钮的 `Height` 是**显式 `40.0`**（不是靠 `MinHeight`） | 可以在挂载当刻抄下来，不依赖测量 |
| 5 | 每个 `ItemsPresenter` 恒有 3 个 child（1 个真实 + 2 个 `Collapsed` 回收容器） | 「数 children」不能判断是否已 realize；要看 `size` 或 `items` |

> ⚠️ **树形是编译进 `ControlCenter.dll` 的 XAML**，属于软依赖。所以挂载逻辑是
> 「**找已 realize 出来的东西**」（`Footer` 里第一个 `Button` → 往上找第一个 `Panel`），
> **不是**按固定路径取节点。任何一步失败都必须能说出**是哪一步**（`FooterMount::reason`）。

---

## 2. 三个原因

### 2.1 ⛔ `FindDescendant` 的深度上限 8 < 实际深度 12

第一版的搜索深度上限是 `depth > 8 return nullptr`。模型按钮在第 12 层 ⇒ **永远找不到**，
于是 `TapPageMountFooterRow` 每次都在第一步就返回，函数看起来「运行了但什么也没做」。

- 症状：日志里只有一句笼统的「还没realize」，看不出是"没 realize"还是"找得不够深"。
- ✅ 修：上限提到 **20**，并把**失败原因**逐段写进 `FooterMount::reason`
  （`系统项还没realize` / `系统项上面没有 Panel` / `ItemContainer 不在它自己的 Panel 里`）。
- 📌 这正是「PoC 当年能跑通、产品侧跑不通」的分水岭：PoC 用的是 `depth > 12`（刚好够）。

### 2.2 ⛔ 一次性守卫 `std::atomic<bool> m_takenOver` ⇒ 第二次开面板不接管

原实现：

```cpp
if (m_takenOver.exchange(true)) return;   // 只置位，从不复位
```

本意是「`Footer` 被重复 Add 时别叠第二份页面」。但它把
**「同一页里重复 Add」** 和 **「关掉再打开后的新一页」** 当成了同一件事。

实测（UIA，关掉面板再打开）：

```text
=== 打开 #1 ===   清除重定向 / 设置 / SystemMixer            ← 接管成功
=== 关掉 → 打开 #2 ===   只有系统的「更多音量设置」          ← 完全没接管
```

根因：**面板关闭时 XAML 树整体销毁**（本仓库早已验过：`baseline-before-injection/element-persistence.txt`），
所以「每次打开都是新对象、都要重新接管」——`m_takenOver` 一旦置位就再没有第二次机会。

- ✅ 修：判据从「**有没有接管过**」改成「**我接管的那一页还在不在屏幕上**」：

```cpp
// 持有强引用 ⇒ 旧页面的元素不会被释放、地址不会被下一次分配复用
static bool IsAttached(FrameworkElement const& e)
{
    return e && VisualTreeHelper::GetParent(e) != nullptr;
}
```

  `OnVisualTreeChange` 里：上一页的 `Footer` **仍挂在树上** ⇒ 是同一页的重复通知，忽略；
  **已脱树** ⇒ 是新一页，重新接管。接管成功才缓存指针（失败不缓存，否则下一次会被误判成"同一页"）。
- ⛔ **不要退回「记住指针身份」**：`09-ini-encoding.md` 已经踩过一次——分配器会复用地址，
  指针身份会**静默**判成"同一页"。判「是否还在树上」不受地址复用影响。
- ⚠️ 顺带：这也解释了为什么 PoC 的 `test-late-inject.ps1` 能给出
  「注入一次，之后每次开关面板按钮都在」的结论——**PoC 每次 Add 都重新注入**，它没有这个守卫。

### 2.3 ⛔ 行高：纵向 `StackPanel` 只给子元素「它想要的高度」

修好前两条之后，三格已经**挂上去了**，但几何是错的：

```text
Footer        (2189,1417 358x48)
清除重定向     (2189,1418 82x16)     ← y 贴着底栏顶边，高度只有 16
```

原因：替换进去的那一行 `Grid` 只有「自然高度」，而它的父级是**纵向 `StackPanel`**——
`StackPanel` 在堆叠方向上给子元素的就是子元素的 desired height，
`VerticalAlignment=Stretch` 在 `StackPanel` 里**不生效**。所以这一行贴顶、高 16。

- ✅ 修（两件事，都在 `TapPageMountFooterRow`）：
  1. `row.MinHeight(panel.ActualHeight())` —— 让这一行撑满 `ItemsPanel`（挂载发生在首次布局之后，
     测量值是真的；`0`/`NaN` 时就不设，退化为自然高度）；
  2. 抄模型按钮的**显式 `Height`** 给三个格子，并 `VerticalAlignment(Center)`
     —— hover 高亮区与系统项一致（`Height()` 未设时返回 `NaN`，`NaN > 0` 为 false，天然安全）。
- 另外把左右两格各加 **4px** 外边距，与系统项的 `4px` 内缩对称（`01-` 的 AT-03）。

---

## 3. 验收（UIA 实测）

`poc/scripts/footer-map.ps1` / 会话用 `uia.ps1`。⚠️ 面板是 band=4 窗口，
XAML 内容在**一个 `FrameworkId == "XAML"` 的子 HWND** 里，
直接 `FromHandle(panel).FindAll(Descendants)` **什么都找不到**，必须先钻到那个子 HWND。

| # | 检查 | 期望 | 实测 | 结论 |
|---|---|---|---|---|
| 1 | 三格都在底栏内 | y 落在 `1417..1465` | `1422`，高 `40` | ✅ |
| 2 | 左格内缩 | `4px` | `2193 − 2189 = 4` | ✅ |
| 3 | 右格内缩 | `4px` | `2543` vs 底栏右边 `2547` | ✅ |
| 4 | 高度与系统项一致 | `40` | `40`（系统项也是 `40`） | ✅ |
| 5 | 垂直居中 | 与系统项同 y | 都是 `1422`（系统页 `1423`，1px 取整） | ✅ |
| 6 | 中格居中 | 与 mockup 的 `.spacer{flex:1}` 同算法 | 是同一个公式 | ✅ |

三态实测（同一份载荷，未重新注入）：

```text
=== 自定义页 ===  清除重定向(2193,1422 82x40) / 设置(2345,1422 46x40) / SystemMixer(2453,1422 90x40)
=== 系统页 ===    [更多音量设置](2193,1423 94x40) 恢复显示 / [MixerExtender](2445,1422 98x40)
=== 设置页 ===    GitHub(2193,1422 60x40) / 返回(2345,1422 46x40) / MixerExtender(2445,1422 98x40)
```

`SystemMixer` ↔ `MixerExtender` 往返、`设置` / `返回` 往返都按一下就成了。
**关掉面板再打开**（连续两次）三格依旧在 —— §2.2 的回归点。

### 3.1 中格为什么用「对齐」而不是「星号列」

初版用 `[Auto][Auto][*][Auto][*][Auto]` 六列网格，中格落点是
**`底栏中心 + (左格宽 − 右格宽) / 2`** —— 只有左右两格等宽时才是正中：

| 页面 | 左格 / 右格 | 中格偏差 |
|---|---|---|
| 自定义页 | 清除重定向 `82` / SystemMixer `90` | `−4px`（看不出来） |
| 设置页 | GitHub `60` / MixerExtender `98` | **`−19px`（明显不居中）** |

⚠️ 这个公式和 mockup 原来的 `[项][flex:1][项][flex:1][项]` **完全一样**，所以 mockup 当时也是偏的
（已把 mockup 改成 `grid-template-columns:1fr auto 1fr`）。

✅ 改法：整个一行只留**一个网格单元**，四个子元素靠 `HorizontalAlignment` 落位
（`左 / 中 / 右`，系统项保持 `Stretch` 贴左边，与改造前逐像素一致）。
单格子里 `Center` 就是**底栏的正中**，与左右两格宽度无关：

```text
设置页：返回 (2345,1422 46x40) → 中心 2368 = 底栏中心 (2189 + 358/2)
```

> 左格与系统项都贴左边、会重叠 —— 这没问题：`RefreshFooter` 保证两者**永不同时可见**
> （自定义页/设置页隐藏系统项，系统页隐藏左中两格）。折叠的元素不参与命中测试。

### 3.2 主体左右 8px 内缩（底栏仍是 4px）

`PageWindow` x=`2189`：**内容** x=`2193+4`=`2197`，**底栏三格**仍从 `2193` 起
（`kBodyInset = 8` vs `kFooterInset = 4` —— 刻意不同：底栏跟系统项对齐，内容多留一档）。

关键是内缩**只能加在主体容器上**：

- ❌ 初版把 4px 分散在行里（`Row()` 左右 `4/6`、下拉框 `4/4`），于是**没有行内边距的元素**
  （「从系统卸载」）直接顶到 `2189`、铺满 `358`；
- ✅ 现在 `root.Padding(8,0,8,0)` 一处生效，行内元素的横向内边距全部归零 ——
  实测「从系统卸载」左右各 8px；标签、下拉框、开关同一条竖线上。

⚠️ 诊断时注意：**UIA 报告的 `ComboBox` 矩形比它的真实布局框左右各宽 4px**
（含下拉边框内边距）。把内缩临时改成 `24` 复测即可看出：真实框是 `2193+20`，报告值是 `2189+16`。
⇒ 别用 ComboBox 的 UIA 矩形判断它有没有吃到内边距，用它的**子文本**或别的元素。

### 3.3 「从系统卸载」的视觉

取自 mockup 的 `.danger` / `.danger.arm`：`40px` 高、`5px` 圆角、`#E5484D`
（文字 α`FF` / 边框 α`73` / 填充 α`10`；已武装态文字仍 α`FF`、边框 α`E6`、填充 α`38）。
> 底色原为 `#FF99A4`（Fluent 深色主题那支**偏淡**的 critical），已改深为 `#E5484D`；
> 因为填充是「底色 × 低透明度」，底色变深同时也会让填充变深。

⛔ 一个 `Button` **只有 Normal 态会显示我们设的 `Background`**：模板的 `VisualState` 会在
hover / press 时把 `ContentPresenter` 的 `Background` 换成 `{ThemeResource ButtonBackgroundPointerOver}`
等主题资源 —— 不覆盖的话，鼠标一碰红色就变回系统灰。所以
`ButtonBackgroundPointerOver` / `ButtonBackgroundPressed` / `ButtonBorderBrushPointerOver` /
`ButtonBorderBrushPressed` / `ButtonForegroundPointerOver` / `ButtonForegroundPressed`
六个键都写进按钮自己的 `Resources`。

连击计数期间切到**已武装态**（填充 α`38`、边框 α`E6`）—— 否则唯一的反馈只有文字，
0.5s 的窗口看起来"什么都没发生"。超时（`DispatcherTimer` 500ms）或第 5 次点击后复位。

实测：单击 1 次 → 文案 `再单击4次从系统卸载`；0.5s 后自动回到 `从系统卸载`（不会误触发卸载）。

---

## 4. ⚠️ 一个纯工具坑：`injector.exe --call` 会让 ShellHost 崩

不是产品问题，但会浪费很多时间，记在这里：

```text
[+] injected OK, remote HMODULE = 0x…F16A0000
[!] VmExtLauncherRun -> 0xC0000409            ← 进程当场死，日志一行都不写
WER: c0000409 子码 0x0a (FAST_FAIL_GUARD_ICALL_CHECK_FAILURE), PCH_CC_FROM_unknown
```

- 用 `CreateRemoteThread` 把起点设成**导出地址**去同步调用，会在进入函数体前就 CFG fast-fail；
  连 `AttachLogging()` 都来不及跑（所以日志文件是 0 字节 / 根本不出现，很容易误判成"载荷坏了"）。
- ✅ 一直可用的路径是 **`--dll <载荷>\vmex_launcher.dll` 不带 `--call`**：
  走 `DllMain → BeginSelfInjection()`，loader 直接调用，不经间接调用检查。
- ℹ️ `todo.md` 里「载荷必须 `/guard:cf`」那条说的是**另一个**场景（XAML core 间接调用 TAP 导出），
  两者不是一回事。
