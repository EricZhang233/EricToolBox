# 07 — 按钮执行指令：实测结论与三条约束

| 项 | 值 |
|---|---|
| 目标 | 确认**注入的按钮能不能执行指令**，以及后面接**项目主程序入口**时必须守哪些约束 |
| 结论 | ✅ **能**，命令行（exe + 参数）逐字符正确传递。**3 条设计约束**（都是正确性/易用性，**不作为安全问题**，见 §5 的决策记录）+ **1 条观察**（工作目录，见 §4 的"忽略"决策） |
| 日期 | 2026-10-03 |
| 环境 | Windows 11 build 26300.9550；ShellHost.exe（Medium IL） |
| 探针 | `docs/poc/src/probes/clickprobe.cpp`（报告子进程收到了什么）、`docs/poc/src/probes/lnkprobe.cpp`（命令行解析行为）、`docs/poc/scripts/click-probe.ps1`（UIA 点击 + 读数） |
| 复现 | 3 次（winver 回归 ×2 + 命令行探针 ×1） |

---

## 1. 结论速览

| # | 问题 | 结果 |
|---|---|---|
| 1 | 按钮点击能执行指令吗 | ✅ **能**。`winver.exe` 被拉起（3 次复现） |
| 2 | 能执行**带参数**的命令行吗 | ✅ **能**。`argv[1..3]` 全部正确，`"beta gamma"` 带引号的参数**没有被空格拆开** |
| 3 | 命令行里 exe 路径不加引号会怎样 | ⚠️ 会被**前缀试探**，可能启动**错的程序**（已复现）—— 见 §5 |
| 4 | 配置里写 `.lnk` 快捷方式行吗 | ❌ **不行**。`GetLastError=193`（`ERROR_BAD_EXE_FORMAT`）—— 见 §6 |
| 5 | 子进程的工作目录是什么 | 📌 继承自 ShellHost（实测 `C:\Windows\System32`）。**不属本设计规定范围**，见 §4 |

---

## 2. 怎么测的

**关键点：不靠"读代码推断"，而是让被点出来的子进程自己交代。**

`clickprobe.cpp` 是一个极小的 exe：把自己收到的 `GetCommandLineW()`、`argc`/`argv[]`、
`GetCurrentDirectoryW()` 写进 `%TEMP%\vmext-clickprobe.txt` 然后退出。

然后**临时**把 TAP 的点击处理器改成启动它（带三个参数，其中一个是带空格的引号参数），
通过 UIA 真实点击按钮，再读那份报告。测完立刻还原成 `winver.exe`。

---

## 3. ✅ 结论 A：命令行被逐字符正确传递

点击按钮后，子进程收到的内容：

```text
GetCommandLineW = ...\clickprobe.exe alpha "beta gamma" --flag=1
argc            = 4
  argv[0]       = [...\clickprobe.exe]
  argv[1]       = [alpha]
  argv[2]       = [beta gamma]        ← ★ 带引号的参数**完整保留**（没被空格拆成两个）
  argv[3]       = [--flag=1]
GetCurrentDirectoryW = C:\WINDOWS\system32
```

⇒ **可以用它接主程序入口**：`exe + 参数` 这种形态（`--profile xxx`、`--open volumemixer` 之类）
在 TAP 这一侧不需要任何额外处理。参数解析完全由 CreateProcess 完成。

---

## 4. 📌 观察：子进程的工作目录继承自 ShellHost（**不属本设计规定范围**）

观察结果：现在传的是 `lpCurrentDirectory = nullptr` ⇒ 子进程**继承 ShellHost 的当前目录**，
实测为 `C:\Windows\System32`。

**决策（Eric）**：**这一项不在本设计的规定范围内，忽略。**
由**接入程序**自己管理自己的工作目录 —— 被启动的程序应当按**自身模块路径**
（`GetModuleFileNameW`）解析配置/资源，而不是依赖 CWD。这是每个程序自己的事，
交付文档不做规定；本模块只负责"把这条命令行按原样启动"。

> 保留这条观察记录，只是为了将来排查"某个程序找不到自己的文件"时能立刻想到 CWD 这一层，
> **不是**一条要实现的要求。交付文档里也已删掉与之相关的坑位与检查项。

---

## 5. ⚠️ 结论 B：不加引号的含空格路径会被"前缀试探"，可能启动**错的程序**

> **决策记录（Eric，2026-10-03）：本项不作为安全问题处理。**
> 理由：TAP 运行在 **Medium IL → Medium IL 的同用户**上下文里，攻击者若能在路径前缀处放文件，
> 说明他**本来就已经能以你的身份执行代码** —— 没有任何权限边界被跨越。
> 这是自用工具，不按威胁模型处理。
> ⇒ 下面保留**技术事实**与"怎么写更稳"，但不再作为安全项；修复理由是**正确性**（避免启动错程序）。

### 5.1 现象

`CreateProcessW` 在 `lpApplicationName = NULL` 时，会对**没有加引号的含空格命令行**
**逐段前缀试探**，找到一个能启动的就启动它。于是：

| 场景 | 命令行 | 实际启动的进程 |
|---|---|---|
| 前缀处**存在** `C:\...\Temp\a.exe` | `C:\...\Temp\a b c\click probe.exe`（不加引号） | ⚠️ **`C:\...\Temp\a`**（`argv[0]` 只有 `...\Temp\a`）—— 启动了错的程序 |
| 前缀处不存在 | 同上 | ✅ 正确的 `...\a b c\click probe.exe` |

⇒ **平时能跑，但前缀处一旦存在同名文件，就会静默启动别的程序。**
这就是经典的"未加引号路径"问题（同族的 unquoted service path 在**跨权限**场景下才是提权，
这里同权限，所以只是"启动错程序"这个功能性问题）。

**为什么"不加引号恰好能跑"不能算通过**：这次实测里前缀处没有文件，所以落到了完整路径上；
结论只能来自"前缀处有文件时会怎样"。

### 5.2 正确写法（已落到 PoC 代码里）

```cpp
// ✅ 两个都做：lpApplicationName 给明确的可执行文件 + 命令行里路径加引号
wchar_t cmd[512];
swprintf_s(cmd, L"\"%s\"", exePath);              // 引号不是可选的
CreateProcessW(exePath, cmd, nullptr, nullptr, FALSE, 0, nullptr, dir, &si, &pi);
```

⛔ **不要**做这两种写法：

```cpp
CreateProcessW(nullptr, L"C:\\Program Files\\App\\app.exe --flag", ...);   // 会被前缀试探
CreateProcessW(nullptr, L"C:\\Program Files\\App\\app.exe", ...);          // 同上
```

产品侧的做法（写进 `action=exec` 的实现约定）：
1. **永远**显式传 `lpApplicationName`；
2. 命令行里**永远**给路径加引号 —— 且由**产品**拼，不指望用户填对；
3. ★ **把配置拆成 `entry1.exe`（exe 绝对路径）+ `entry1.args`（参数）两段**，
   由产品负责拼装。**"让用户填一整条命令行"这种设计本身就是 bug 的温床** ——
   实测里两种失败模式（不加引号、填 `.lnk`）都是这么来的。

> ✅ 这两份交付文档的配置 schema 已经按第 3 条改掉：`entry1.command` 已拆为 `entry1.exe` + `entry1.args`
> （C++ 版 §2.3；模型类与 `PerformClickAction` 也同步改了）。

### 5.3 复现方法

```powershell
# 1) 造一个含空格的目录，并在**该路径的前缀位置**放一个同名 exe
#    真目标: %TEMP%\a b c\click probe.exe      前缀文件: %TEMP%\a.exe
# 2) 只跑 D 用例（不加引号），看 clickprobe 报告里的 argv[0] 是哪个
lnkprobe.exe <任意.lnk> "%TEMP%\a b c\click probe.exe" d
Get-Content "$env:TEMP\vmext-clickprobe.txt" | Select-String 'argv\[0\]'
# 前缀文件在  -> argv[0] = C:\...\Temp\a                        （启动了前缀那个）
# 前缀文件删掉 -> argv[0] = C:\...\Temp\a b c\click probe.exe    （才落到真目标）
```

---

## 6. ❌ 结论 C：`.lnk` 快捷方式不能用

```text
CreateProcessW(L"\"C:\...\to-cmd.lnk\"")                => FAILED  GetLastError=193  (ERROR_BAD_EXE_FORMAT)
CreateProcessW(L"\"C:\Windows\System32\cmd.exe\"")      => OK  pid=16852      ← 对照
```

快捷方式的解析（目标重定向、参数、工作目录、环境变量）是 **shell** 的职责，
`CreateProcessW` 不做这件事。⇒ 配置里必须写**真实 exe 的绝对路径**。

需要"双击快捷方式"的效果时，只能显式借 shell 一手：

```text
entry1.exe=C:\Windows\explorer.exe
entry1.args="C:\...\某个.lnk"
```

---

## 7. 接主程序入口的检查清单

| # | 检查项 | 为什么 |
|---|---|---|
| 1 | 配置里是**真实 exe 绝对路径**，不是 `.lnk` | §6：`.lnk` → 193 |
| 2 | `lpApplicationName` 显式给 exe 路径 | §5：不给就会被前缀试探 |
| 3 | 命令行里路径**加引号**（由产品拼，不靠用户填） | §5 |
| 4 | 命令行走**临时可写缓冲**（不是字符串字面量） | `CreateProcessW` 会就地修改该缓冲 |
| 5 | 启动失败必须记 `GetLastError()` | 否则用户看到的是"点了没反应"，无从排查 |
| 6 | 不要 `WaitForSingleObject` 等子进程 | 那会**阻塞 ShellHost 的线程**；点一下就卡整个任务栏 |

> 第 4、5 条 PoC 里已经是对的；第 2、3 条已经在 PoC 的 `RunWinver()` 里改成正确形态并回归通过。

> 📌 **工作目录不在本清单里** —— 它是**接入程序**自己的事（§4），本设计不规定。

---

## 8. 回归确认

改成安全写法后重新跑了一次完整验收（`docs/poc/scripts/cycle.ps1` + `click-testlink.ps1`）：

```text
found TestLink at (2472,1419 71x40)          ← 几何未变
winver processes before: 0
winver processes after : 1
CLICK HANDLER OK -- winver.exe was launched by the injected button
   pid=4320 title=[关于"Windows"]
```

⇒ 安全写法**没有**破坏原有行为，位置与功能都一致。
