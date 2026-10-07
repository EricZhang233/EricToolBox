# 最终版注入后的实测结果（实测证据快照）

本目录是**最终版注入生效之后**测到的客观结果。它对应交付文档里的验收用例 AT-01 ~ AT-05，以及验证计划的 V0/V1/V5。

| 项 | 值 |
|---|---|
| 采集时间 | 2026-10-03 02:00:26（一次干净 cycle：停 shell → 构建 → 重启 explorer → 注入 → 打开面板） |
| 环境 | Windows 11 build 26300.9550，交互会话 2，ShellHost.exe 原生 System XAML |
| 被测版本 | `docs/poc/src/vcxtap.cpp` 的最终版：包两列 Grid 落位 + 高度读显式 `Height` + 右边距 4px |
| 注入内容 | 一个 `Button`，文字 `TestLink`，点击执行 `winver.exe`（PoC 占位动作） |
| 复现次数 | **3 次独立完整 cycle，几何完全一致**（详见 `01-footer-geometry-after.md`） |

---

## 1. 文件说明

| 文件 | 是什么 | 怎么用 |
|---|---|---|
| ⭐ `01-footer-geometry-after.md` | 注入后的几何 + 三次独立复现 + 点击验证 | 验收基准。看这一份就够了 |
| `02-footer-screenshot.png` | 底栏截图（2 倍放大，区域 `(2150,1390) 440x110`） | 外观确认。可看到两个按钮在同一行、右侧对齐、高度一致 |
| `03-tap-injection-full.log` | TAP 完整日志，625 行 / 83 KB | ⭐ **原始证据**。含 XAML 树重放的完整事件流（448 个元素） |
| `04-launcher-full.log` | Launcher 完整日志 | 证明 `InitializeXamlDiagnosticsEx` 首次尝试即成功 |
| ⭐ `05-injection-sequence-excerpt.txt` | 上面完整日志的**节选**（23 行日志 + 头部说明） | **人读的那一份**。三个 ★ 标记 + `up[]` 祖先链都在这里 |
| `../poc/scripts/` | 自包含的验证脚本（**统一放在那里**，本目录不再有 scripts/） | 见本文末尾"复现命令" |

---

## 2. ⭐ 怎么读 `05-injection-sequence-excerpt.txt`

日志里三个 ★ 标记是排障的全部关键，**中间断在哪一个就直接定位到对应章节**：

```text
★1  "vcxtap loaded: pid=... stage=2"          -> TAP 已被 XAML core 加载
     "QI IXamlDiagnostics  hr=0x00000000"     -> 拿到诊断接口
     "QI IVisualTreeService hr=0x00000000"    -> 拿到视觉树服务
     "AdviseVisualTreeChange hr=0x00000000"   -> 开始收事件（之前的树会被重放）

★2  "*** Footer appeared: type=[...ItemsControl] handle=... children=0"
                                              -> 声音输出页的底栏元素出现了（匹配成功）

     接着 10 行 "up[0] ... up[9]"             -> ★ 模型按钮的祖先链（§5.1 定位算法的唯一现场证据）
                                                 up[3] = StackPanel [Vertical]
                                                 ↑ 底栏 ItemsPanel 是**纵向**的 ——
                                                   这就是"往 Footer 追加一项必然新起一行"、
                                                   以及"必须把原行包进两列 Grid"的根本原因

     "model metrics: Height=40.0 MinHeight=0.0 ActualH=40.0 Style=yes"
     "-> TestLink height forced to 40.0"      -> 高度取的是**显式属性**，不依赖布局时机
                                                 （这一步是踩坑换来的，见交付文档 §5.3/§5.5）

★3  "wrapped the row container (class=...ContentPresenter) inside the
      ...StackPanel in a 2-column Grid"       -> ★ 注入成功：原行被包进两列 Grid
     "*** TestLink injected on the SAME row as the model button (right aligned) ***"
```

**如果排障时 ★3 没有出现**，日志里会出现下面二者之一，含义完全不同：

| 日志 | 含义 | 后果 |
|---|---|---|
| `no ItemsPresenter ancestor -- cannot find the row container` | 用 `ItemsPresenter` 当锚没找到（层数变了 或 模板变了） | 走兜底 → 按钮落在**第二行**，`Footer` 高度 48 → 78 |
| `row container is not a child of the ItemsPanel -- cannot wrap it` | 找到了 panel 但原行不是它的直接子节点 | 同上 |

这两条都属于"功能可用、位置不理想"的**安全降级**。真正需要担心的是 ★2 完全不出现（页面结构大改，`Name` 不再叫 `Footer`）。

**关于 `stage=2`**：那是 PoC 的日志分级开关（`vcxtap.ini` 的 `stage`），`2` = 记录事件并注入。产品版会把它换成配置里的 `enabled=0/1`（见交付文档 §2.3）。

---

## 3. ⚠️ 这份日志的两个"已知噪声"

诚实标注，避免读者困惑：

1. **`GetIInspectableFromHandle hr=... ptr=...` 这类行已从节选里滤掉**，但它出现在完整日志中。完整日志有 448 个元素的 ADD 事件，绝大多数是 XAML 树重放的噪声 —— 这也是为什么要有节选。
2. **`handle` 每次面板打开都会变**（如 `255F221CDA8` vs `...34BA8`）。这是**预期行为**，不是异常：实测证明 XAML 元素实例每次打开面板都重建（见 `../baseline-before-injection/element-persistence.txt`）。所以日志里的句柄**不能跨面板打开比较**。

---

## 4. 复现命令

```powershell
$pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
$s    = '.\scripts'      # 或 docs\verified-after-injection\scripts 的绝对路径

# 让面板处于打开状态（没开就自动发 Win+Ctrl+V）
& $pwsh -File "$s\qs-panel-probe.ps1"

# AT-01/04/05：读底栏与全部按钮的屏幕矩形
& $pwsh -File "$s\footer-map.ps1"

# AT-03：UIA 触发按钮，断言目标进程被拉起
& $pwsh -File "$s\click-testlink.ps1"

# 截图
& $pwsh -File "$s\shot-footer.ps1"

# 复查元素层次/祖先链（自动取日志里最后一个 name=[Footer] 的句柄）
& $pwsh -File "$s\parse-tree.ps1"
& $pwsh -File "$s\parse-tree.ps1" -Log .\03-tap-injection-full.log -Handles 255F221CDA8
```

⚠️ **`footer-map.ps1` / `click-testlink.ps1` 依赖 `GetForegroundWindow()` 才能拿到面板句柄**（因为面板是 band=4 窗口，`EnumWindows` 看不到它）。
**一旦有别的窗口抢走前台，它们会报"面板未打开"** —— 这不是 bug，是本机窗口模型决定的限制。要自动化必须先缓存面板 HWND（它常驻），用 `IsWindowVisible` 判断。

---

## 5. 本目录**没有**覆盖的部分

| 验收用例 | 为什么没有证据 |
|---|---|
| AT-06 `enabled=0` 不注入 | PoC 用 `vcxtap.ini` 的 `stage` 代替，未单独留证 |
| AT-07 shell 重启后自愈 | 需要 Watcher 与编排器（产品版才有；PoC 是脚本驱动的注入），**未验证** |
| AT-09 稳态 CPU | 未测（Watcher 的 0 CPU 依据来自 `baseline/03-winevent-test.md`，不是直接测量本产品） |
| AT-11 卸载无残留 | 产品版才有卸载脚本 |
| AT-14 契约往返单元测试 | 产品版才有（C++ 轨道下这是纯单元测试，不需要 ShellHost） |
| **V2/V3/V4/V6/V7/V8** | 全部未验证。完整清单见两份交付文档的 §10.4/§10.5 |
