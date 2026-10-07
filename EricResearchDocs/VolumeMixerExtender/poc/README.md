# docs/poc — 参考实现（C++）与全部验证脚本

> 这里的内容原先在仓库根目录下被 `.gitignore` 忽略的 `.research/`（活工作区）。
> 2026-10-03 决定**删除 `.research/`**，把其中有价值的资产**搬进 `docs/`（纳入 git 跟踪）**，
> 于是源码、脚本、配置模板与证据一起获得了版本历史。
>
> ⚠️ 搬家时踩到的坑：脚本里那些 `Split-Path -Parent` 算出来的层级**全都失效了**，
> 而症状只是"找不到文件"。现在统一由 `scripts/_paths.ps1` 解析路径 —— 见 §2。

**这里放的是"能跑的东西"**：PoC 源码、构建脚本、驱动/验证脚本、配置模板。
**结论性文档在上一层**：`../README.md`（总索引）、`../design.md`（设计与落地说明）、
两份交付文档、以及 `../verified-after-injection/`（实测证据）。

---

## 1. 这是什么

在 Win11 快速设置面板（`ControlCenterWindow`）的**音量页底栏右侧空位**注入一个自绘入口按钮的实现。
技术路线：**XAML 诊断 API（`InitializeXamlDiagnosticsEx`）+ 自写 TAP DLL**。

✅ **已跑通**，且几何与基线逐像素一致：

| 元素 | 屏幕矩形 |
|---|---|
| `Footer`（底栏） | `(2189,1417) 358x48` |
| `更多音量设置`（模型按钮） | `(2193,1420) 94x40` |
| 注入的按钮 | `(2472,1419) 71x40`（右边缘 2543 = 2547−4） |

---

## 2. 目录结构

```text
docs/poc/
├── README.md                    本文件（怎么构建、怎么跑、每个脚本干什么）
├── build.cmd                    构建全部产物：vcvars64 + cl（4 个 cl 都带 /utf-8）
├── src/                         ★ PoC 源码（"产品化"时的移植源头）
│   ├── injector.cpp             CreateRemoteThread + LoadLibraryW（注入器）
│   ├── vcxlaunch.cpp            ★ 在 ShellHost 进程内调 InitializeXamlDiagnosticsEx + 配置直投
│   ├── vcxtap.cpp               ★ XAML 诊断 TAP：注入按钮、绑点击、幂等判定
│   ├── vcxmix.cpp               方案 A 实验（**已证伪**，保留作记录，不要带进产品）
│   └── probes/                  一次性验证探针的源码（见 §4）
│       ├── clickprobe.cpp       子进程自报：完整命令行 / argv / 当前目录（T-clicks 用）
│       ├── lnkprobe.cpp         CreateProcessW 行为探针（.lnk / 引号 / 前缀试探）
│       ├── pipeserver.cpp       T3：命名管道**服务端**（产品侧 App 的原型，带 race 模式）
│       └── initest.cpp          T2：INI 编码矩阵（5 种编码 × 读/写两侧，带 hex 自证）
├── ini/                         配置模板（**UTF-16LE + BOM**，见 ../verified-after-injection/09-*.md）
│   ├── vcxlaunch.ini            Launcher 配置（含 initdata 串：ver=1;cfg=…;pipe=…）
│   ├── vcxtap.ini               TAP 配置（entry1_id / entry1_text / entry1_action）
│   └── vcxmix.ini               方案 A 的配置
├── scripts/                     ★ 全部驱动与验证脚本（**唯一一处**，不要再分散）
│   ├── _paths.ps1               ★ 路径解析器：从自身向上找 build.cmd 定出 PoC 目录，其余脚本都 dot-source 它
│   ├── cycle.ps1                ★ 一轮完整测试：停 shell→构建→重启 explorer→注入→开面板→打日志+几何
│   ├── stop-shell.ps1 / restart-and-inject.ps1 / run-diagnostics.ps1
│   ├── test-late-inject.ps1     ★ 实测：shell 已起来后才注入（产品不必抢在 explorer 之前启动）
│   ├── qs-panel-probe.ps1       打开/定位面板并 dump XAML 元素树
│   ├── footer-map.ps1           ★ 读底栏与全部按钮的屏幕矩形（验收主脚本）
│   ├── click-testlink.ps1       UIA 触发按钮并断言 winver 进程出现
│   ├── click-only.ps1           T3：点一下并量 Invoke 耗时 + 面板是否仍响应
│   ├── click-probe.ps1          点一下并读子进程收到的命令行/工作目录
│   ├── check-button-text.ps1    T2/V3：读按钮 Name 并与期望值**进程内**比较（只输出 ASCII + 码点）
│   ├── reopen-panel.ps1         让面板的 XAML 树真正重建，用 TAP 日志当判据
│   ├── probe-initdata.ps1       T1：逐长度测 initData 通道上限（-Total <n>）
│   ├── probe-config-chain.ps1   T1：端到端证明配置链路真的在驱动行为
│   ├── parse-tree.ps1           从 vcxtap.log 重建元素层次、打祖先链
│   ├── shot-footer.ps1          截底栏区域到 PNG（2 倍放大）
│   └── which-pid.ps1            面板当前在哪个 pid
└── archive/                     历史脚本（产生基线结论用过的，保留以便追溯）
    ├── recon/                   pexports / footer-geom / injection-feasibility / element-persistence / toggle-panel
    ├── hooks/                   event-test.ps1（SetWinEventHook 实测）
    └── probes/                  band-check / probe-c / probe-d / probe-e / probe-uia
```

> ⛔ **不纳入 git 的内容**：`build.cmd` 的产物（`*.exe`/`*.dll`/`*.obj`/`*.exp`/`*.lib`）和运行期日志（`*.log`）。
> 它们都是**可重新生成**的；二进制品进仓库只会让仓库膨胀。跑一次 `build.cmd` 即可全部重建。

---

## 3. 怎么构建、怎么跑

**环境**：Windows 11（本机 build 26300）；VS 18 Community 或 VS2022 BuildTools；Windows SDK 10.0.26100（含 cppwinrt 头）。
`cl.exe` / `cmake` **不在 PATH 上** —— `build.cmd` 会在同一个 cmd 进程里 `call vcvars64.bat` 再 `cl`。

```powershell
$poc = '<repo>\docs\poc'
$pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'

# 1) 构建（产物落在 docs\poc\ 下）
& $env:ComSpec /c "cd /d `"$poc`" && build.cmd"

# 2) 一轮完整测试（会重启 explorer；结束时面板上是注入好的按钮）
& $pwsh -File "$poc\scripts\cycle.ps1"

# 3) 验收：几何
& $pwsh -File "$poc\scripts\footer-map.ps1"     # Footer 358x48；模型按钮 94x40；我们的按钮右边缘 2543

# 4) 验收：点击能执行动作
& $pwsh -File "$poc\scripts\click-testlink.ps1"

# 5) 想复查元素层次
& $pwsh -File "$poc\scripts\parse-tree.ps1"
```

**构建脚本的分工**：`cycle.ps1` 等驱动脚本会**自己调 `build.cmd`**，所以一般不需要单独跑第 1 步。

---

## 4. 一次性探针（`src/probes/`）怎么用

这些是**为了验证某个具体假设而临时写的**小 exe，各自的结论已固化到
`../verified-after-injection/` 的 06–09 号证据文件里。留着是为了**可复核**。

| 探针 | 验证什么 | 结论在哪 |
|---|---|---|
| `initest.cpp` | `GetPrivateProfileStringW` 能读哪种编码的中文 | `09-ini-encoding.md` |
| `pipeserver.cpp` | `action=pipe` 全链路 + `ConnectNamedPipe` 的双错误码 | `08-pipe-action-chain.md` |
| `clickprobe.cpp` | 被点出来的子进程收到了什么（命令行/argv/CWD） | `07-click-execution-constraints.md` |
| `lnkprobe.cpp` | `.lnk` 能不能跑 / 不加引号会不会启动错程序 | `07-click-execution-constraints.md` |

编译它们不需要改 `build.cmd`，单独一行即可（在已 `call vcvars64.bat` 的同一个进程里）：

```cmd
cl /nologo /utf-8 /EHsc /MT src\probes\initest.cpp /Fe:initest.exe /link /SUBSYSTEM:CONSOLE
```

> ⚠️ **`/utf-8` 不能省**：源码里有中文注释，而无 BOM 的 UTF-8 会被 MSVC 按系统 ACP 解读，
> 某个中文字的尾字节 `0x5C` 会"吃掉"字符串字面量的收尾引号 → `C2001 常量中有换行符`，
> 报错行看着完全正常、极难定位（详见交付文档 §4.3 坑 23）。

---

## 5. ⚠️ 跑这些脚本时会踩到的坑（都实测过，别重复踩）

| 坑 | 现象 | 正确做法 |
|---|---|---|
| **DLL 被 ShellHost 持有 → 写锁定** | 改完 C++ 直接 `build.cmd` 会 `LNK1104` | 先停 ShellHost（`stop-shell.ps1`）再构建。产品部署同理：先停进程再替换文件 |
| **诊断会话是每进程一次的** | 同一 ShellHost 里反复测会污染结论（TAP 会重放既有树） | 想要干净结论就让 ShellHost 换一个进程（`cycle.ps1` 重启 explorer 的原因） |
| **面板是 band=4 窗口** | `EnumWindows`/`FindWindow`/UIA `RootElement` **都看不到它** | 用 `GetForegroundWindow()`；或缓存常驻 HWND 后用 `IsWindowVisible` |
| **`Win+Ctrl+V` 不是开关** | 面板已开着时它是空操作 ⇒ "多轮测试"其实一直在读**同一个树**，看起来每轮都通过 | 关面板要让它**失焦**；并且**用 TAP 日志里的 `Footer appeared` 计数**验证树真的重建了（`reopen-panel.ps1`） |
| **`IsWindowVisible` / 前台窗口类名判断"面板开没开"** | band=4 的 HWND 常驻，前者恒为真；后者实测骗过人（`Esc` 之后仍报 on-top） | 同上：以 TAP 日志为准 |
| **脚本依赖前台窗口** | 别的窗口抢了前台就报"面板未打开" | 自动化时应先拿到并缓存面板 HWND |
| **中文比较/打印** | 直接把中文打到子进程 stdout，编码会再乱一次，**分不清是数据错还是打印错** | 日志里用 `\uXXXX` 码点；比较在**进程内**做（见 `check-button-text.ps1`） |

---

## 6. 源码要怎么移植到产品

`src/` 下的三个文件（`injector.cpp` / `vcxlaunch.cpp` / `vcxtap.cpp`）基本就是产品里那三块的原型，
两份交付文档的附录 B 有逐文件的"需要做什么改动"清单。要点：

* `vcxtap.cpp` 里 **vtable / COM / 树遍历相关代码保持不动**（已跑通，重写没有收益）；
* `RunEntryAction()` 的分派、配置读取（`ReadIniRaw` / `CfgValue`）、幂等判定（按 `AutomationId` 查内容）
  是"产品化后仍然需要"的部分，可直接照着搬；
* `vcxmix.cpp`（方案 A）**不要带进产品** —— 它已被证伪，留在这里只是记录；
* 移植时务必带上那些"踩坑修正"（`/utf-8`、`CreateFileW` 写日志而不是 CRT 流、`STDAPI` + `/EXPORT:`、
  `IndexOf`+`RemoveAt`、`#undef GetCurrentTime`、`NOMINMAX` 全局……完整清单见交付文档 §4.3 与附录）。
