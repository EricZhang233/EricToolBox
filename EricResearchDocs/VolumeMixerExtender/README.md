# docs/ —— 交付文档、参考实现与实测证据

本目录是**纳入 git 跟踪的交付物目录**，也是本项目的**唯一权威位置**：
交付文档、设计文档、参考实现（PoC 源码）、验证脚本、以及支撑结论的实测证据**都在这里**。

> 📌 **2026-10-03 结构变更**：原先 `.research/` 是一个被 `.gitignore` 忽略的"活工作区"，
> 研究过程和 PoC 都在那里进行，只有结论和证据快照被复制进 `docs/`。
> 这次把 `.research/` 里**有价值的资产全部搬进 `docs/`**（见 [poc/](poc)）并**删除了该目录** ——
> 于是源码和脚本也进了版本历史，不再有"快照 vs 工作区"两处并存、需要人工同步的问题。

---

## 1. 目录结构

```text
docs/
├── README.md                                        ← 本文件（总索引）
├── design.md                                        ← ★ 设计 + 落地说明（方案 A 证伪 / 方案 B 跑通 / 几何 / 坑 / **§7 方向修订**）
├── VolumeMixerExtender-功能模块方法与实现文档-Cpp版.md       ← ★ **维护中的唯一规格**
├── poc/                                             ← ★ 参考实现（构建 + 源码 + 全部脚本）
│   ├── README.md                                       怎么构建、怎么跑、每个脚本干什么、跑时的坑
│   ├── build.cmd                                       vcvars64 + cl（4 个 cl 都带 /utf-8）
│   ├── src/                                            PoC 源码（injector / vcxlaunch / vcxtap / vcxmix）
│   │   └── probes/                                     一次性验证探针源码（clickprobe / lnkprobe / pipeserver / initest）
│   ├── ini/                                            配置模板（UTF-16LE + BOM）
│   ├── scripts/                                        ★ 全部驱动与验证脚本（唯一一处）
│   └── archive/                                        历史脚本（产生基线结论用过的，保留以便追溯）
├── baseline-before-injection/                       ← 注入前基线（实测证据）
│   ├── README.md
│   ├── 01-window-locating-and-band.md                  窗口定位 + band=4（为什么 EnumWindows 看不到面板）
│   ├── 02-xaml-host-and-element-tree.md                XAML 宿主在子窗口 + **L2 声音输出页** 28 元素树
│   ├── 03-winevent-test.md                             band 窗口照发 WinEvent（0 CPU 检测的依据）
│   ├── 04-footer-geometry-before-injection.md          ★ 注入前底栏几何（一切"位置对不对"的基准）
│   ├── 05-xaml-exports-and-shellhost-modules.md        导出表 + ShellHost 模块清单（为什么走诊断 API）
│   ├── 06-l1-main-panel-tree.md                        ★ **L1 主面板** 31 元素树 + 入口按钮 `VolumeL2Button`
│   ├── element-persistence.txt                         ★ XAML 元素每次打开都重建（本方案的基石）
│   └── injection-feasibility.txt                       IL / PPL / OpenProcess 权限实测
├── verified-after-injection/                        ← 最终版注入后的实测结果
│   ├── README.md
│   ├── 01-footer-geometry-after.md                     ★ 注入后几何 + 三次独立复现
│   ├── 02-footer-screenshot.png                        底栏截图（2 倍放大）
│   ├── 03-tap-injection-full.log                       TAP 完整日志（625 行 / 83 KB）
│   ├── 04-launcher-full.log                            Launcher 完整日志
│   ├── 05-injection-sequence-excerpt.txt               ★ 注入过程节选（人读的那一份）
│   ├── 06-initdata-channel-limit.md                    ★ T1：配置下发通道的 259 字符上限 + 定稿方案
│   ├── 07-click-execution-constraints.md               ★ 点击执行指令：3 条约束（.lnk / 引号 / 缓冲）
│   ├── 08-pipe-action-chain.md                         ★ T3：`action=pipe` 全链路（含 232 竞态实测）
│   ├── 09-ini-encoding.md                              ★ T2：INI 编码矩阵 + 幂等 bug（指针身份误判）
│   ├── 10-page-swap-capability.md                      ★ T12/T13/T14：换内容可写可还原 + 10 个控件类型可激活
│   ├── 11-checkbox-capability.md                       ★ T18：`CheckBox` 可用（录制模式复选框的前置）
│   ├── 12-audio-interop-safety.md                      ★ 音频互操作安全分界：哪些 API 能在 ShellHost 里调
│   ├── 13-footer-mount.md                              ★ 产品侧底栏挂载：真实结构 + 3 个 bug + 几何验收
│   └── 14-page-identification.md                       ★ 怎么认出声音页：其它二级菜单被误接管的根因与判据
└── reference/
    ├── research-agent-report.md                     外部调研（Windhawk / ExplorerPatcher / 诊断 API，带源码引用）
    └── raw-outputs.md                               全部探针的**原始**捕获输出合集（八节，392 行）
```

**哪份文档回答什么问题**：

| 想看什么 | 去哪 |
|---|---|
| 产品怎么设计、怎么实现 | `VolumeMixerExtender-功能模块方法与实现文档-Cpp版.md`（★ **唯一维护中的规格**） |
| 为什么选这条路、踩过哪些坑 | `design.md`（§6 = 已跑通的旧路线；**§7 = 当前方向**） |
| 当前入口机制、自定义页怎么落地 | `design.md` §7 + C++ 版 **§5.7** |
| 怎么把参考实现跑起来 | `poc/README.md` |
| 哪些结论是**实测**的、哪些还没验 | 本文件 §6 + `verified-after-injection/` 的 06–09 |
| 面板两层的元素树长什么样 | `baseline-before-injection/02`（L2，28 元素）+ `06`（L1，31 元素） |
| 这些结论的原始数据长什么样 | `reference/raw-outputs.md` + `baseline-before-injection/` |

---

## 2. 技术轨道：已定为 C++（2026-10-03）

**结论：走 C++ 轨道。** 原 C# 方案文档**已删除**，项目只维护这一条轨道。

C++ 代码骨架已落在仓库根目录（不在 `docs/` 下）：

```text
Core/            业务静态库（基础设施 / 服务 / CLI 契约 / 组合根）
Components/      仅放"要嵌入主程序"的注入载荷（inject.launcher / inject.tap）
Program.cpp      命令行外壳（零业务逻辑）
cmake/           载荷资源生成、版本资源模板、打包脚本
```

选型依据（16 维度对照表）保留在 C++ 版 **§1.0**，作为历史记录。一句话：

> 真正难的核心代码（in-proc 两段）**本来就是 C++**，控制面只是外围。统一成 C++ 的代价是控制面代码量翻倍、内存要自己管；收益是**契约与配置这两处最容易出隐性 bug 的地方，从"跨语言约定"变成"编译期 + 单元测试可保证"**。
>
> 本项目的入口机制是 **XAML 树的运行时改写**（§7），它天然要写大量 WinRT 对象操作 ——
> 这部分无可避免是 C++，把控制面也统一过来反而减少一次跨语言约定的机会。

---

## 3. 权威性与版本历史

**本目录就是权威位置**，没有第二份副本需要同步。

> 📌 **2026-10-03 之前**：研究过程与 PoC 放在仓库根目录被 `.gitignore` 忽略的 `.research/` 里，
> `docs/` 只保存"复制过来的结论与证据快照"。两处并存需要人工同步，且 `.research/` 里的
> **源码和脚本没有版本历史**（改坏了无法回退）。
> 现在已把 `.research/` 里的资产全部搬进 `docs/`（源码 → [poc/src/](poc/src)、脚本 → [poc/scripts/](poc/scripts)、
> 历史脚本 → [poc/archive/](poc/archive)、设计文档 → [design.md](design.md)、原始数据 → [reference/raw-outputs.md](reference/raw-outputs.md)），
> 并**删除了 `.research/` 目录**。
>
> **代价与收益**：代价是 git 仓库变大（约 +200 KB 文本；**二进制与日志没有入库**，它们是可重新生成的）；
> 收益是从此**单一权威位置**、源码可追溯、脚本改动可回退。这是个划算的交换。

**`docs/poc/` 里的东西怎么重建**：`build.cmd` 会生成 `*.exe` / `*.dll` / `*.obj`；
运行期日志（`*.log`）由程序自己产生。**这两类都没有入库** —— 需要时跑一次 `build.cmd` 即可。
（`03-tap-injection-full.log` / `04-launcher-full.log` 是**人工挑选过的节选**，作为证据保留。）

---

## 4. 证据文件一览（来源与用途）

| 文件 | 来源 | 采集时间 | 支撑哪条结论 |
|---|---|---|---|
| `baseline‑before-injection/01-window-locating-and-band.md` | `reference/raw-outputs.md` §01–§02 | 2026-10-03 | 面板是 **band=4** 窗口，`EnumWindows`/`FindWindow`/UIA `RootElement` 都看不到它；拿 HWND 只能靠 `GetForegroundWindow`/`GetGUIThreadInfo` |
| `baseline‑before-injection/02-xaml-host-and-element-tree.md` | 同上 §03–§04 | 2026-10-03 | `ControlCenterWindow` 在 UIA 里是空壳；真 XAML 树在子窗口 `Windows.UI.Input.InputSite.WindowClass`；声音输出页 28 个元素与关键 `AutomationId`（含 `Footer`） |
| `baseline‑before-injection/03-winevent-test.md` | 同上 §05 | 2026-10-03 | band 窗口**照发 WinEvent**，且空闲期 600ms **0 事件** ⇒ 事件驱动检测 = 0 CPU |
| `baseline‑before-injection/04-footer-geometry-before-injection.md` | 同上 §06 | 2026-10-03 | ★ 注入前底栏 `(2189,1417) 358x48`、模型按钮 `(2193,1420) 94x40`、右侧约 `256x40` 空位 |
| `baseline‑before-injection/05-xaml-exports-and-shellhost-modules.md` | 同上 §07–§08 | 2026-10-03 | 面板是 **System XAML**（非 WinUI3）；`Windows.UI.Xaml.dll` 导出 `InitializeXamlDiagnosticsEx`；`ControlCenter.dll` 只导出 3 个符号 |
| `baseline‑before-injection/06-l1-main-panel-tree.md` | 同上 §09 / `poc/scripts/qs-panel-probe.ps1`（`Win+A` 开面板） | 2026-10-03 | ★★ **L1 主面板 31 元素树** + 入口按钮 `AutomationId` = **`VolumeL2Button`**（`Name` = 「选择声音输出」）；⚠️ `Microsoft.QuickAction.ProjectL2` 证明 **L2 入口是一组** ⇒ 弃用"拦导航"方案；`FooterGrid` 属 L1 且非空 |
| `baseline‑before-injection/element-persistence.txt` | `poc/archive/recon/element-persistence.ps1` | 2026-10-03 | ★ **XAML 元素实例每次打开面板都重建**（runtime id 5/5 全变）—— 这是"事件驱动 + 每次重注入"方案的基石，也是"按钮随面板关闭自动消失"的原因 |
| `baseline‑before-injection/injection-feasibility.txt` | `poc/archive/recon/injection-feasibility.ps1` | 2026-10-03 | ShellHost 与 App **同为 Medium IL、非 PPL**，`OpenProcess(ALL_ACCESS)` 成功 ⇒ 经典 DLL 注入可行 |
| `verified‑after‑injection/01-footer-geometry-after.md` | `poc/scripts/footer-map.ps1`（三次独立复现） | 2026-10-03 | ★ 注入后 `Footer` 仍 `358x48`、模型按钮位置不动、我们的按钮 `(2472,1419) 71x40` |
| `verified‑after‑injection/02-footer-screenshot.png` | `poc/scripts/shot-footer.ps1` | 2026-10-03 | 外观确认（2 倍放大） |
| `verified‑after‑injection/03-tap-injection-full.log` | `poc/src/vcxtap.cpp` 跑出的 `vcxtap.log` 的**节选**（625 行） | 2026-10-03 02:00:26 | ★ TAP 完整行为（SetSite → advise → 树重放 → 命中 Footer → 注入） |
| `verified‑after‑injection/04-launcher-full.log` | `poc/src/vcxlaunch.cpp` 跑出的 `vcxlaunch.log` 的**节选** | 同上 | `InitializeXamlDiagnosticsEx` 首次尝试即成功（`hr=0x00000000`，端点索引 1） |
| `verified‑after‑injection/05-injection-sequence-excerpt.txt` | 由 TAP 完整日志按关键字过滤 | 同上 | 人读版：三个 ★ 标记 + `up[]` 祖先链 |
| `verified‑after‑injection/06-initdata-channel-limit.md` | `poc/scripts/probe-initdata.ps1` / `probe-config-chain.ps1` | 2026-10-03 | ★★ **T1：initData 通道上限正好 259 字符，超限静默返回空串而 `hr` 仍是 `S_OK`** ⇒ 配置改走"直投"通道；含长度扫描 9 点表、BSTR 所有权、端到端配置链路验证 |
| `verified‑after‑injection/07-click-execution-constraints.md` | `poc/src/probes/clickprobe.cpp` / `lnkprobe.cpp` / `poc/scripts/click-probe.ps1` | 2026-10-03 | ★★ **按钮能执行命令行（含引号参数）**；3 条设计约束：① `.lnk` 不行（err=193）② ⚠️ 不加引号的含空格路径会被**前缀试探**（可能启动错的程序，已复现；**不作安全项**，见该文件 §5）③ 命令行必须用可写缓冲 + ⛔ 不要在点击里等子进程。另记录一条观察：子进程工作目录继承自 ShellHost（`C:\Windows\System32`）—— **不属本设计规定范围**，由接入程序自理 |
| `verified‑after‑injection/08-pipe-action-chain.md` | `poc/src/probes/pipeserver.cpp` / `poc/scripts/click-only.ps1` | 2026-10-03 | ★★ **T3：`action=pipe` 全链路通**。报文逐字节正确；**UI 线程未被拖住**（`Invoke` 往返 7–14 ms）；管道 IO 在独立线程（tid 可证）；服务端缺失时瞬时降级。★ 发现文档漏写的一个坑：`ConnectNamedPipe` 的合法失败有两种（110 / **232**），把 232 当致命错误会**静默丢一次点击** |
| `verified‑after‑injection/09-ini-encoding.md` | `poc/src/probes/initest.cpp` / `poc/scripts/check-button-text.ps1` / `reopen-panel.ps1` | 2026-10-03 | ★★ **T2：INI 编码只有 UTF-16LE + BOM 可用**。UTF-8 无 BOM ⇒ **静默乱码**；UTF-8 有 BOM ⇒ **键都找不到**（设置被静默忽略）；写侧 `WritePrivateProfileStringW` 对全新文件会写成 ANSI。★ 顺带挖出并修掉一个真 bug：**幂等判定用"记住 Footer 指针"，而分配器会复用地址 ⇒ 按钮被静默跳过** |
| `verified‑after‑injection/10-page-swap-capability.md` | `poc/src/vcxtap.cpp` 内的一次性探针（`ProbeCapabilities`） | 2026-10-03 | ★★ **入口接管方案的三项前置全部通过**：T14 十个控件类型可激活（含 `ComboBox`/`ListView`/`Slider`）；T12 `ListContent.Content` 可写且可还原；T13 `Footer` 触发时结构已就绪。★ 顺带纠正一处文档偏差：实际用 **C++/WinRT 直接激活**，不是 `IVisualTreeService::CreateInstance` |
| `verified‑after‑injection/11-checkbox-capability.md` | `poc/src/vcxtap.cpp` 内的一次性探针（追加的 T18 组） | 2026-10-03 | ★ **T18 通过：「录制模式」复选框无形态风险**。`CheckBox` 可激活、`IsChecked`（`IReference<bool>`）可往返、`MinHeight(0)` 可设（紧凑模板的前提）、可挂进可视树。★ 顺带闭合 `10-` 留下的 `ToggleButton` 命名空间遗留问题（缺 `Controls.Primitives` 别名 ⇒ C2039），并复查探针未污染可视树（底栏几何与基准逐像素一致） |
| `verified‑after‑injection/12-audio-interop-safety.md` | 独立探针进程 `poc/src/audiochk.cpp`（已删）+ `poc/src/vcxaudio.h` | 2026-10-03 | ★★ **决定了页面主体不需要 IPC、而设备策略必须走 IPC**。① 枚举/端点音量/会话读写全部走 SDK 文档化接口，**可安全内联**；② `IPolicyConfig` 按 EarTrumpet 的槽位声明实测 **`vtable[13]` 访问违规**（`slot11` 用已知正确的 `PKEY_Device_FriendlyName` 却返回 `S_OK`+`VT_EMPTY` ⇒ 槽位映射就是错的）⇒ **在 ShellHost 里试错 = 崩掉用户 shell**，改走 `action=pipe`；⚠️ **此条结论已于 2026-10-04 更正**（探针槽位整体偏移，槽 13 就是 `SetDefaultEndpoint`，见 15 号），但**分流方案不变**；③ `Windows.Media.Internal.AudioPolicyConfig` **可激活**（只认 `ab3d4648`），`set(NULL)` 成功、`set(id)` 返回 `E_INVALIDARG`（未定论，**无 AV 风险**）。★ 顺带修正环境记录：唯一渲染端点是 RDP 的 **`远程音频`**（不是之前记的网易虚拟声卡），**采集端点 0 个** |
| `verified‑after-injection/13-footer-mount.md` | 产品侧 `Components/inject.tap` + UIA（`poc/scripts/footer-map.ps1`） | 2026-10-03 | ★★ **产品底栏挂载打通，并挖出三个独立原因**：① `FindDescendant` 深度上限 8 而模型按钮在第 **12** 层（PoC 用的是 12，刚好够）⇒ 永远找不到；② `std::atomic` 一次性守卫**从不复位** ⇒ **关掉再打开面板就再也不接管**（XAML 树每次打开都重建）⇒ 判据改为「上次那一页是否仍挂在树上」；③ 纵向 `StackPanel` 只给子元素 desired height ⇒ 三格贴顶且只有 16px 高 ⇒ 用 `MinHeight(ItemsPanel.ActualHeight())` + 抄模型显式 `Height=40`。★ 附 `Footer` 两层嵌套 `ItemsControl` 的完整实测树，以及一条纯工具坑：`injector.exe --call` 会把 ShellHost CFG fast-fail（`0xC0000409` 子码 10），只有不带 `--call` 的自注入路径可用 |
| `verified‑after‑injection/14-page-identification.md` | 干净 shell 逐页 UIA + TAP 深度 dump；`L2Frame` 导航探针 | 2026-10-03 | ★★ **「其它二级菜单也被接管」的根因与定案**：① 所有 L2 页面**共用同一套壳**（`PageWindow`/`PageHeader`/`PageContent`/`Footer` 逐项同名同结构，`ListContent.Content` 都是 `ItemsControl`）⇒ 只按 `Name=="Footer"` 匹配必然误伤；② **`投影` 也用 `PageTitleText`**（曾误以为它是声音页指纹）；③ `L2Frame` 确实是 `Frame`、`Navigated` 全路径都触发，但 `Parameter`（`ControlCenter.AdvancedPageInfo`）**每次导航都是新对象**且不可读 ⇒ 入口只用来定时机、不能用来自证身份。定案两条判据：**入口**（L1 `VolumeL2Button` 的 `Click`，5s 窗口，快路径不闪；⚠️ `Win+Ctrl+V` 不走它）+ **页面内容**（`OutputGroupTitle`/`MixerGroupTitle`/`SpatialGroupTitle`/`ListWithOutputGroupTitle`，正向判据、失败关闭）。⛔ 两个坑：这些名字在页面根往下 **~25 层**（上限 24 会**静默找不到**）；识别是深度 32 全树遍历，挂在 dispatcher `Low` 上**必须按 25ms 节流**（Low 每秒排空上千次），但"只靠事件驱动"又会漏掉内容落地的那一刻 |
| `verified‑after-injection/15-host-pipe-and-device-policy.md` | 产品侧 `Core/TapPipeServer.*` / `Core/TapCommand.*` / `Core/HostPresence.*` + 独立 COM 探针 | 2026-10-04 | ★★ **宿主侧 TAP 动作接收端打通，并终结 `IPolicyConfig` 槽位之谜**：① `vmex.exe` 无控制台常驻 + 命名互斥体单实例，`vmex_cli status` 跨进程查询，管道报文（合法/参数不足/未知动词/未实现）四类分支实测；② `CoCreateInstance(PolicyConfigClient)` + `QI(IID F8679F50)` 在 26H2 **成功**，**槽 13 = `SetDefaultEndpoint`**（传真实端点 ID → `E_NOINTERFACE`，传其它任何 ID → `E_INVALIDARG`，说明它确实在解析设备 ID）⇒ 旧记录里的"`vtable[13]` 访问违规"是**探针槽位映射偏移**所致，现行声明不再 AV；③ `ClearAllPersistedApplicationDefaultEndpoints`（槽 27）`S_OK`、`SetPersisted`（槽 25）`E_INVALIDARG` ⇒ 本机 RDP 虚拟端点**拒绝一切对具体端点的改动**，属环境限制、待实体机复验；④ 顺带修掉两个真 bug：进程从未 `CoInitializeEx`（音频命令必失败）、`--verbose`/`--trace` 被 CLI 当未知选项 |
| `verified‑after‑injection/16-app-icon-and-per-app-redirect.md` | 产品侧 `Components/inject.tap/Page.h` + `Core/AppIcons.*` / `Core/RedirectStore.*` / `Core/PayloadResources.*`；日志 `tap-20261004-023535.log` / `tap-20261004-025324.log` / `app-20261004-025324.log` / `app-20261004-030240.log` | 2026-10-04 | ★★ **面板内的图标、逐应用重定向与「重定向端点显示」落地，并修掉四个"看起来能用"的真 bug**：① 图标 = exe → `HICON` → WIC PNG 缓存 → `Image` + `file:///`（取不到回落首字母色块，缓存命中不再重复提取）；② 重定向交互从"右侧小 chevron"（**实测点不动**：trailing 区不可点 + `Background(nullptr)` 只有字形参与命中测试）改为**整条标题带 = 一个透明底 Button** + 展开一个 `ComboBox`，并在**名称下方常显一行「→ 端点名」**（主题强调色、单行省略、悬停全名、与下拉框同源、跟"显示驱动名"开关联动）；③ **在 `Collapsed` 父容器里创建 `ComboBox` ⇒ 弹出层残留、吃掉整页输入**（改"先 `Visible` → 再创建 → 再挂树"）；④ 清除重定向"命令成功但界面毫无变化"⇒ 清本地选择 + `MountPage` 重建正文；⑤ 录制模式发**硬编码设备名**（被空格切分截成 `OC`）⇒ 改哨兵 `@virtual` + **收紧报文参数个数校验**（五类分支实测）；⑥ **载荷目录名只用尺寸 ⇒ 同尺寸重编复用旧 DLL**（注入的其实是上一版、日志却一路正常）⇒ 目录名加入内容哈希，部署产物与 `bin\Debug` 哈希逐位一致 | 
| `reference/research-agent-report.md` | 外部调研（独立 agent 产出） | 2026-10-03 | 方案选型的外部依据（Windhawk / ExplorerPatcher / XAML 诊断 API，带源码引用） |
> 01–06 号基线证据的内容都是**逐字摘录**（只在文件头加了"来源/时间/用途"说明块），
> 原始合集在 `reference/raw-outputs.md`（九节）。
> ⚠️ 那份合集里含一条**后来被证伪**的结论（"`xamldiagnostics.dll` NOT FOUND"），
> 已在 `baseline-before-injection/README.md` 顶部显著标注。

---

## 5. 怎么复现验收

**环境要求**：与 explorer 同会话的**交互桌面**（不能是 Session 0 / 无头），PowerShell 7（`C:\Program Files\PowerShell\7\pwsh.exe`）。

**前置**：先构建并注入 —— 直接跑 `poc/scripts/cycle.ps1` 一步到位（它会自己调 `build.cmd`、重启 explorer、注入）。

```powershell
$pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
$s    = '.\docs\poc\scripts'          # ★ 所有脚本现在只在这一处

# 0) 构建 + 注入 + 打开面板（会重启 explorer）
& $pwsh -File "$s\cycle.ps1"

# 1) AT-01 / AT-04：读底栏与全部按钮的屏幕矩形
#    期望：Footer 358x48；更多音量设置 (2193,1420) 94x40；我们的按钮右边缘距 Footer 右边缘 4px、高 40
& $pwsh -File "$s\footer-map.ps1"

# 2) AT-03：UIA 触发按钮，断言目标进程被拉起
& $pwsh -File "$s\click-testlink.ps1"

# 3) 截图看外观（2 倍放大）
& $pwsh -File "$s\shot-footer.ps1"

# 4) 想复查元素层次/祖先链（自动取日志里最后一个 name=[Footer] 的句柄）
& $pwsh -File "$s\parse-tree.ps1"
```

⚠️ **脚本的共同脆弱点**：`ControlCenterWindow` 是 **band=4** 窗口，`EnumWindows`/`FindWindow`/UIA `RootElement` **都看不到它**。拿 HWND 只能靠 `GetForegroundWindow()`。
⇒ **一旦有别的窗口抢走前台，脚本就会报"面板未打开"**（实测踩过：注入动作本身、或用户此刻在操作机器，都会导致）。
**要自动化就应该先拿到并缓存面板 HWND**（它是常驻的），后续用 `IsWindowVisible(hwnd)` 判断，不要每次都依赖前台窗口。
（⚠️ 补充：`IsWindowVisible` 对 band=4 窗口**恒为真**，判断"面板内容还在不在"更可靠的办法是看 TAP 日志里的 `Footer appeared` —— 见 `poc/README.md` §5。）

---

## 6. 验证状态总览（已完成的 / 仍未验证的）

两份交付文档的 §10.4 / §10.5 有完整清单。**已完成的 T1（配置下发）、点击执行指令、T3（`action=pipe`）已从中移除**，
证据分别在 `verified-after-injection/06`、`07`、`08`。

### 6.1 ✅ 已完成：T1 配置下发通道

| 项 | 结论 |
|---|---|
| `GetInitializationData` 是否原样回读 initData | ✅ **是**，含 CJK 逐字符一致 —— 但**上限正好 259 字符** |
| 超过 259 字符会怎样 | ❌ **静默**返回空串，且 `hr` 仍是 `S_OK`（**没有任何错误信号**）；这是**有界拒绝**而非缓冲区溢出 |
| 返回的 BSTR 归谁 | ✅ 每次**新分配**，调用方 `SysFreeString` 安全 |
| 259 装不下真实配置怎么办 | 配置改走**直投通道**（Launcher 直接调 TAP 导出 `VmExtTapProvideInitData`）；已验证 4000 字符无损 |
| 配置是否真的在驱动行为 | ✅ 改 `entry1_text` ⇒ 界面按钮文字随之改变；几何回归通过 |

⇒ **地基这一块可以认为已经夯实**：配置链路端到端可用，且失败模式已知、有告警、有哨兵。

### 6.2 ✅ 已完成：点击执行指令

| 项 | 结论 |
|---|---|
| 按钮能不能执行指令 | ✅ **能**。`winver.exe` 被拉起，3 次复现 |
| 能不能执行**带参数**的命令行（接主程序入口的真实形态） | ✅ **能**，`argv[]` 逐字符正确，`"beta gamma"` 这类引号参数**没被空格拆开** |
| 配置里写 `.lnk` 快捷方式 | ❌ **不行**，`GetLastError=193`（`ERROR_BAD_EXE_FORMAT`）；shell 才解析快捷方式 |
| 子进程的工作目录 | 📌 继承自 ShellHost（实测 `C:\Windows\System32`）—— **不属本设计规定范围**，由接入程序自己按模块路径解析资源 |
| exe 路径不加引号会怎样 | ⚠️ 被**前缀试探**：`lpApplicationName=NULL` + 不加引号的含空格路径，前缀处存在同名 exe 就启动那个（**已复现**）。按**正确性**问题处理 —— 同用户权限，不跨权限边界，因此**不作为安全项**（决策见证据文件 §5） |

⇒ 详见 `verified-after-injection/07-click-execution-constraints.md`。PoC 的点击处理器已改成安全写法（显式 `lpApplicationName` + 路径加引号）并回归通过。

### 6.3 ✅ 已完成：`action=pipe` 全链路（T3）

| 项 | 结论 |
|---|---|
| 报文是否正确送达 | ✅ 服务端收到 `CLICK volumemixer <unixMillis>`，逐字节正确（32 字节） |
| **点击会不会卡住面板** | ✅ **不会**。UIA `Invoke` 往返 7–14 ms；点击后 9–10 ms 内仍能读面板 |
| 管道 IO 是否真的离开了 UI 线程 | ✅ **tid 可证**：点击在 UI 线程，管道写与结果在另一个 tid |
| App 没运行时（服务端缺失） | ✅ **瞬时降级** + 显式日志（`err=2`，`WaitNamedPipeW` 立即返回，不会等满 200ms）；面板不受影响 |
| 竞态 `ConnectNamedPipe` | ⚠️ **文档漏了一种**：除了 `ERROR_PIPE_CONNECTED(110)` 还有 **`ERROR_NO_DATA(232)`**（客户端连上又关闭）。把 232 当致命错误会**静默丢一次点击** ⇒ 已补进两份文档与坑表 |
| 配置热重载 | ✅ 顺带验证：只改 ini 的 `entry1_action`（不重启 explorer、不重新注入），下一次点击立即生效 |

⇒ 详见 `verified-after-injection/08-pipe-action-chain.md`。

### 6.4 ✅ 已完成：INI 编码（T2）

| 项 | 结论 |
|---|---|
| 哪种编码能被 `GetPrivateProfileStringW` 正确读回中文 | ✅ **只有 UTF-16LE + BOM**（7 个汉字码点逐位一致） |
| UTF-8 无 BOM | ❌ **静默乱码**：ASCII 节名/key 能匹配，中文值被按系统 ACP 解读 |
| UTF-8 有 BOM | ❌ **键都找不到**：BOM 字节污染第一个节名 ⇒ 设置被**静默忽略**、回落默认值 |
| UTF-16LE 无 BOM | ❌ 被当 ANSI 读 ⇒ 乱码 |
| 系统 ACP（本机 GBK） | ⚠️ 本机正确**只因 ACP=936**，换区域设置即坏 ⇒ 不可作为契约 |
| 写侧 | ⚠️ `WritePrivateProfileStringW` 对**全新文件**会写成 ANSI（不带 BOM）；对已带 BOM 的文件才保持 UTF-16LE |
| 端到端 | ✅ 把 ini 写成 UTF-16LE+BOM、文字设为「音量合成器」⇒ 按钮 `Name` 码点逐位一致，右边缘仍 2543 |
| 文档修正 | ⛔ 原交付文档曾写「`WriteTapIni` **必须用 UTF-8 无 BOM** 写」—— **方向是反的**，已改 |

⇒ 详见 `verified-after-injection/09-ini-encoding.md`。

### 6.5 ✅ 顺带修掉一个真 bug：幂等判定用"记住指针"

| 项 | 内容 |
|---|---|
| 现象 | 面板关了又开，按钮**有时不出现**，且**日志里连一行都没有** |
| 根因 | 幂等守卫 `g_lastInjectedFooter == get_abi(footer)` 用**指针地址**当身份；实测两次面板打开拿到**同一个 handle**（分配器复用了地址）⇒ 新树被误判成"已处理" |
| 文档里的错误断言 | 两份文档都写着"面板每次打开重建元素、**句柄会变，所以不会误判**"—— 前半句对，后半句错，**已改正** |
| 修法 | 改成**按内容判定**：在 Footer 子树里找 `AutomationId == "VmExtEntry"` 的按钮，找不到才注入（判据自证，且能自愈） |
| 验证 | 肇事变量 0 处引用；树真重建后注入成功；中文文字 + 几何均正常 |
| 可推广的教训 | **幂等判定优先用"结果是否存在"，而不是"我记不记得做过"** |

### 6.6 仍未验证 / 不做支持

| # | 项 | 状态 |
|---|---|---|
| 1 | ~~INI 编码（T2）~~ | ✅ 已完成，见 §6.4 |
| 2 | ~~`action=pipe` 全链路（T3）~~ | ✅ 已完成，见 §6.3 |
| 3 | ~~"面板已经打开时注入"的确切行为~~ | ❌ **不做支持（产品决定）**：**音量浮层不是常驻窗口**（按快捷键才出现、失焦即消失），产品模型是"注入一次 → TAP 常驻 → 每次打开面板自动注入"，**不需要**往一个已经开着、正在被看的浮层里插东西。故不进验收。 |
| 4 | 子进程工作目录（`lpCurrentDirectory`） | 📌 **不规定**：由接入程序自理，交付文档不做要求（见 §6.2） |
| 5 | **字形/渲染层**（中文字体是否缺字、显示是否美观） | ⏳ 未验证。T2 只证明"读到的字符串码点正确"，外观不受编码影响 |
| 6 | ~~入口接管机制：`ListContent.Content` 可写性与还原~~ | ✅ **已验证**（T12）。写入与还原均成功，见 `verified-after-injection/10-page-swap-capability.md` |
| 7 | ~~换内容的最佳时机~~ | ✅ **已验证**（T13）。`Footer` 触发时 `PageWindow`/`ListContent` 已就绪、原内容已非空，无需额外调度 |
| 8 | ~~`ComboBox` / `ListView` / `Slider` 可用性~~ | ✅ **已验证**（T14）。10 个控件类型全部可激活，自定义页形态不受限 |
| 9 | 系统页被换下后是否仍在后台活动（音频计量轮询等） | ⏳ 未验证（T15） |
| 10 | 自定义页在 `ScrollViewer` 内的尺寸策略（自适应 vs 固定） | ⏳ 未验证（T16） |
| 11 | ~~设置页标题行后退键拦截（T20）~~ | ✅ **不需要了**（2026-10-03）：保持系统默认行为，不拦 —— 两个返回键行为不同是接受的取舍 |
| 12 | ~~`ContentDialog` 可激活（T21）~~ | ✅ **不需要了**：「从系统卸载」改用**连击 5 次**确认，不用浮层 |
| 13 | ~~打开 URL 用 `exec` 还是 `action=open`（T22）~~ | ✅ **已定：新增 `action=open`**（`ShellExecuteW(..., L"open", url, ...)`）。⛔ 不复用 `exec` —— `CreateProcessW` 只认 exe |
| 14 | **`ToggleSwitch` 类型可激活（T19）** | ⏳ 未验证。设置页「开机启动」「显示驱动名」两个开关要用（做法同 T18） |
| 15 | **滑块直调 WASAPI 的往返耗时（T23）** | ⏳ 未验证。已定方案 A：TAP 在 ShellHost 内**直接调** `SetMasterVolumeLevelScalar`，不走 IPC |
| 16 | **`RegisterControlChangeNotify` 的回调线程（T24）** | ⏳ 未验证。回调若不在 UI 线程而直接改 UI ⇒ 崩 |
| 17 | **控制台子系统改造（T25）** | ⛔ **已关闭（2026-10-03）**：登录自启改为 `Run` 键后仍会闪一下黑窗，**决定接受**，不做 `WIN32` 子系统 + `AttachConsole(ATTACH_PARENT_PROCESS)` |
| 18 | **`IPolicyConfig` 的正确槽位** | ✅ **已定论（2026-10-04）**：IID `F8679F50` 可 QI，**槽 13 = `SetDefaultEndpoint`**（按设备 ID 是否真实存在返回不同 HRESULT 可证）。见 §6.7 |
| 19 | **切换系统默认设备 / 逐应用重定向在实体机能否成功** | ⏳ 未验证（**本机不可验**）：本机是 RDP、唯一渲染端点是虚拟的 `远程音频`，系统对具体端点的改动一律拒绝（`E_NOINTERFACE` / `E_INVALIDARG`）；`ClearAll` 为 `S_OK` 说明调用形态无误 |

### 6.7 ✅ 已完成：宿主侧 TAP 动作接收端与设备策略（2026-10-04）

| 项 | 结论 |
|---|---|
| 后台进程 | `vmex.exe` 无控制台常驻 + `Local\VmExt.Host.S<sid>` 命名互斥体单实例；`vmex_cli status` 跨进程查询"在不在跑"与管道名 |
| 管道服务端 | `Core/TapPipeServer`：`ConnectNamedPipe` 的 `110` / `232` 都按成功处理、按 `\n` 切行、`DisconnectNamedPipe` 收尾；`Stop()` 用"自连一次"唤醒阻塞线程 |
| 报文派发 | `SETDEFAULT` / `SETREDIRECT` / `CLEARREDIRECT` / `UNINSTALL` 全部有落点；参数不足、**参数过多**、未知动词、尚未实现四类都**显式记日志**，不静默失败（参数个数在 16 号那轮收紧） |
| 设备策略 | `Core/EndpointPolicyService` 从桩换成真实实现，复用 `Core/AudioInterop.h` 既有封装（宿主进程内执行，不在 ShellHost 里试错） |
| CLI 等价 | `vmex devices` / `default` / `redirect` / `clear-redirect` 已接线；`clear-redirect` 本机端到端成功 |
| 环境限制 | RDP 虚拟端点下"改具体端点"被系统拒绝（详见 §6.6 #19），**需实体机复验**；`SetDefaultEndpoint` 的调用路径本身已确认正确 |

⇒ 详见 `verified-after-injection/15-host-pipe-and-device-policy.md`。

### 6.8 ✅ 已完成：面板内的应用图标与逐应用重定向（2026-10-04）

| 项 | 结论 |
|---|---|
| 应用图标 | `Core/AppIcons`：进程 exe → `HICON` → WIC 编码 PNG 缓存到 `<缓存根>\icons\<hash>.png`，TAP 用 `Image` + `file:///` 渲染；取不到时回落"首字母色块"。**缓存命中后不再重复提取** |
| 重定向交互 | 应用行**整条标题带**（图标 + 名称 + chevron）是一个**透明底** `Button`，点开向下展开一个 `ComboBox`（首项「默认设备」= 清除），选中即发 `SETREDIRECT`；**名称下方常显一行「→ 端点名」**（有重定向时才有，11px + 主题强调色 + 单行省略 + 悬停全名），行高按需长高（蓝图：整行封顶 ≈52px） |
| 修掉的真 bug | ① 在 `Collapsed` 的父容器里创建 `ComboBox` ⇒ **弹出层残留、吃掉整页输入**（改"先 Visible 再创建"）；② `Button.Background(nullptr)` ⇒ 只有字形能命中（改透明画刷）；③ 录制模式发**硬编码设备名** ⇒ 被空格切分截成 `OC`（改哨兵 `@virtual` 由宿主解析 + 收紧参数个数校验）；④ 载荷目录名只用**尺寸** ⇒ 同尺寸重编复用旧 DLL（改内容哈希，见 `16` 号 §8） |
| 清除重定向 | 命令本来就成功，缺的是**反馈**：现在清本地选择 + `MountPage` 重建正文，所有下拉回到「默认设备」；页面重建时从系统持久默认端点表读取当前值 |
| 边界 | `#system`（`pid=0`）行不给重定向；策略失败不会产生页面镜像，真值始终来自系统持久表 |

⇒ 详见 `verified-after-injection/16-app-icon-and-per-app-redirect.md`；"重定向真的搬运声音"与"切到 V"仍需实体机复验。
