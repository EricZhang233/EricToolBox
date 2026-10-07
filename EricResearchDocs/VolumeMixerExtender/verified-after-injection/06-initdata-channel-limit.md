# 06 — 配置下发通道：initData 的容量上限与定稿方案

| 项 | 值 |
|---|---|
| 验证编号 | **T1**（T1a 内容保真 / T1b BSTR 所有权 / T1c 替代通道） |
| 结论 | **initData 通道可用，但上限正好 259 字符；超限静默丢空且 `hr` 仍为 `S_OK`。配置因此改走"直投"通道。** |
| 测量日期 | 2026-10-03 |
| 环境 | Windows 11 build 26300.9550；ShellHost.exe；`Windows.UI.Xaml.dll` 10.0.26100.8972；SDK `xamldiagnostics.dll` 10.0.14393.33 |
| 测量脚本 | `docs/poc/scripts/probe-initdata.ps1`（`-Total <n>` 参数化）、`docs/poc/scripts/probe-config-chain.ps1`（端到端） |
| 复现次数 | 长度扫描 9 点；端到端链路 2 次独立复现；几何回归 4 次 |

---

## 1. 为什么要验这件事

产品的所有可配置项（按钮文字 / 点击动作 / 边距 / 日志路径 / 管道名）都要在**注入那一刻**送到
ShellHost 进程里的 TAP 里。当时唯一想到的官方通道是：

```
Launcher(注入器)  ──InitializeXamlDiagnosticsEx(..., wszInitializationData)──▶  XAML core
                                                                            │
                                              TAP: IXamlDiagnostics::GetInitializationData()  ◀┘
```

签名（逐字抄自 SDK `xamlOM.h`）：

```cpp
HRESULT InitializeXamlDiagnosticsEx(
    LPCWSTR endPointName,
    DWORD   pid,
    LPCWSTR wszDllXamlDiagnostics,
    LPCWSTR wszTAPDllName,
    CLSID   tapClsid,
    LPCWSTR wszInitializationData);   // ← 第 6 个参数，从未验证过
```

PoC 原先传的是 `nullptr`，**回读从未验证**。如果这条通道能原样回读，配置链路就成立了；
如果不能，整个"配置怎么进 TAP"要重新设计。

---

## 2. 怎么测的（排除混淆变量）

| 设计 | 目的 |
|---|---|
| 载荷 = `ini 里的 ASCII 基串` + `代码里写死的 CJK 后缀`（`;cjk=音量合成器测试`，用 `\uXXXX` 转义写，源码保持纯 ASCII） | 把"initData 通道是否正确"与"ini 编码是否正确"拆成**两个独立问题**。CJK 不经过 ini，所以 ini 编码问题不可能污染这里的结论 |
| CJK 自检改为 **ini 开关** `initdata_cjk_test=1`（默认关） | 正式路径就是"配置是什么发什么"；自检随时可复现 |
| 两个 ini 用 **UTF-8 无 BOM + 纯 ASCII** 写 | 同上，避免编码这个无关变量混进来 |
| TAP 侧不再写"期望值"，改成**"直投收到的内容"与"initData 回读的内容"互相比对** | 消除"两侧各写一份期望值"这种会同时写错的假阳性 |
| 载荷长度由 `-Total` 参数化，**逐长度二分** | 一开始只测了 17（过）和 331（不过），必须把边界钉死 |

---

## 3. 长度扫描（核心结果）

`total` = 实际传给 `InitializeXamlDiagnosticsEx` 的字符串总长（基串 + 12 字符 CJK 后缀）。

| # | 总长(字符) | `GetInitializationData` 回读 | 长度 | 与发送内容比对 | 备注 |
|---|---|---|---|---|---|
| 1 | 17 | ✅ 非空 | 17 | **逐字符一致**（含 CJK） | 通道确实可用 |
| 2 | 128 | ✅ 非空 | 128 | **逐字符一致** | |
| 3 | 255 | ✅ 非空 | 255 | **逐字符一致** | |
| 4 | 256 | ✅ 非空 | 256 | **逐字符一致** | 注意：**不是** `MAX_PATH`(260) 的边界 |
| 5 | **259** | ✅ 非空 | **259** | **逐字符一致** | ★ **最大可用长度** |
| 6 | **260** | ❌ **空串** | **0** | — | ★ **`hr` 仍是 `S_OK`，没有任何错误信号** |
| 7 | 300 | ❌ 空串 | 0 | — | 本轮用更新后的脚本复测，行为一致 |
| 8 | 331 | ❌ 空串 | 0 | — | 最初的发现点（当时误判为"通道不可用"） |
| 9 | 4000 | ❌ 空串 | 0 | — | **ShellHost 无异常、按钮照常注入** ⇒ 有界拒绝，非溢出 |

### 3.1 三个必须记住的点

1. **上限是 259，不是 260 或 256。** 对应 `wchar_t buf[260]` 留 1 位给 NUL 的经典写法
   —— 即框架内部按 `260` 容量接收，**第 260 个字符起被丢弃**。
   （严格说：长度恰好 260 时回读为空串，说明框架在"装不下"时选择**整串丢弃**而不是截断到 259。）
2. **超限是静默的。** `InitializeXamlDiagnosticsEx` 返回 `hr=0x00000000`，
   `GetInitializationData` 也返回 `S_OK`，只是 BSTR 长度为 0。
   ⇒ **任何"仅靠返回值判断成功"的代码都会把配置丢失当成成功。** 这是本项最大的风险点，
   也是必须在产品里显式记录的原因（见 §5 的告警日志）。
3. **超限不危险，只是无效。** 4000 字符下 ShellHost 进程健康、XAML 树正常、
   按钮照常注入 ⇒ 框架在写入前做了容量检查，**不是缓冲区溢出**。
   这条结论让"误传超长配置"从"可能崩掉整个任务栏"降级为"面包屑丢了"。

---

## 4. T1(b)：返回的 BSTR 归谁

`IXamlDiagnostics::GetInitializationData(BSTR*)` 的 IDL 契约是 `[retval][out]` ⇒ 调用方负责
`SysFreeString`。但**如果框架返回的是内部指针**，调用方释放就会**破坏 ShellHost 的堆**
（taskbar 崩溃级后果）。所以必须实测。

**方法**：连续调用两次，比较指针。

**结果**：两次返回**不同指针** ⇒ 每次都是**新分配**的 BSTR ⇒ 按契约 `SysFreeString` 安全。

```
T1(b) BSTR 所有权可释放 : PASS
```

日志中的 `initData : len=0 fnv1a64=CBF29CE484222325`（空串）也间接佐证：
即使内容为空也返回了一个合法的空 BSTR，没有返回 `NULL`/野指针。

> 实现里用 `SysStringLen(d)` 取长度而不是 `wcslen` —— BSTR **允许内嵌 `\0`**，
> `wcslen` 会在第一个 `\0` 处截断，把"内容不同"误判成"内容相同"。

---

## 5. 定稿方案：配置走"直投"，initData 降级为面包屑

259 字符装不下真实配置（一个 `cfg=<完整路径>` 就可能上百字符），而**上限不可协商**。
所以定稿为：

```
Launcher ──LoadLibraryW(vcxtap.dll)──▶ 同一进程内的 TAP 模块
        ──GetProcAddress("VmExtTapProvideInitData")──▶ 函数指针
        ──provide(<完整配置字符串>)──▶ TAP 的全局变量
                                        │
                    XAML core 稍后 DllGetClassObject 时，配置已就位
```

**为什么成立**：Launcher 与 TAP 在**同一个进程**里。先 `LoadLibraryW` 拿到 `HMODULE`
（XAML core 之后加载同一模块时是同一个 `HMODULE`），此时模块已被加载、
配置全局变量可写；`DllGetClassObject` 被调用时全局变量已就位。

**为什么刻意不 `FreeLibrary`**：多持一个引用，确保该模块**不会被卸载**，
全局变量不会随卸载丢失。

| 通道 | 角色 | 容量 | 失败模式 |
|---|---|---|---|
| **直投**（`VmExtTapProvideInitData`） | **配置主干** | 无限制（已验证 4000 字符无损） | 导出找不到 / 没调用 —— 会显式记日志 |
| initData | **人类可读的面包屑** | 259 字符 | 超限静默丢空（只影响可调试性） |
| initData（降级） | 直投未到时的兜底配置来源 | 259 字符 | 显式记 `!!` 日志 |

**契约新成员**（必须写进交付文档的跨进程契约）：

| 项 | 值 |
|---|---|
| 导出名 | `VmExtTapProvideInitData` |
| 签名 | `void WINAPI VmExtTapProvideInitData(const wchar_t*)` |
| 调用时机 | `InitializeXamlDiagnosticsEx` **之前**（或在同一注入序列内保证先于 `DllGetClassObject`） |
| 生命周期 | 调用方**不得** `FreeLibrary` 该模块 |
| 配置格式 | `key1=v1;key2=v2`（`=`、`;` 分隔，无转义） |
| 必备键 | `cfg=<配置文件绝对路径>` —— TAP 用它决定"去哪读配置" |

`cfg=` 这一项是关键设计：**连"配置文件在哪"都由通道本身传递**，
否则"配置里说配置在哪"会形成循环依赖。TAP 侧实现为
`g_cfgPath`（从直投配置解析，缺省回退到 DLL 同目录的 `vcxtap.ini`）。

---

## 6. 端到端验证：配置真的在驱动行为

只证明"字符串传过去了"不够 —— 要证明它**被用上了**。测试办法：把配置里的按钮文字改成
`TestLink2`，看界面上的按钮文字是否跟着变（该值不经过任何其他代码路径）。

| # | 检查项 | 结果 |
|---|---|---|
| 1 | Launcher 直投 `len=165`，`fnv1a64=E0C1B019B461A8F4` | ✅ |
| 2 | TAP 直投通道收到 `len=165`，哈希**完全相同** | ✅ |
| 3 | TAP 从直投配置解析出 `cfg=` 路径并使用它 | ✅ `已从直投配置解析出配置文件路径: ...\poc\vcxtap.ini` |
| 4 | `entry1_text=TestLink2` ⇒ 界面按钮文字 = `TestLink2` | ✅ UIA 读到 `Button name=[TestLink2]` |
| 5 | 几何回归：按钮仍在**同一行**、**右边缘贴合** | ✅ `(2464,1419) 79x40`，右边缘 2543 = 面板右 2547 − 4px |
| 6 | 两通道内容一致（未触及 259 上限） | ✅ 日志 `两种通道内容一致（165 字符，未触及 259 上限）` |
| 7 | 超限时只丢面包屑、不影响功能（`-Total 300`） | ✅ 按钮照常注入，几何不变 |

第 5 项的 `x` 从基线的 2472 变成 2464 是**正确的**：`TestLink2` 比 `TestLink` 长 1 字符，
宽度 71 → 79，而**右边缘恒为 2543** —— 所以验收断言应该断言**右边缘**，不能断言 `x`。

### 6.1 超限路径的实际日志（`-Total 300`）

```text
Launcher:
  注意：配置 300 字符 > 259 -> initData 面包屑会被框架静默丢弃（仅影响面包屑，配置由直投通道送达）
  已直投 300 字符
  SUCCESS: endpoint=VisualDiagConnection1  hr=0x00000000  (index 1)

TAP:
  直投通道: 有  len=300  fnv1a64=822F262C4804BA51
  initData : len=0  fnv1a64=CBF29CE484222325
  initData 为空属**预期**：内容 300 字符超过 259 上限，框架静默丢弃

在面板上:
  [] Button name=[TestLink] rect=(2472,1419 71x40)          ← 功能完全不受影响
```

TAP 侧还留了一个**反向哨兵**：如果出现"直投有内容、initData 为空、但长度 ≤ 259"，
会记 `!! ... 非已知的长度上限原因` —— 因为按本项测量，≤259 时不该为空。
将来 Windows 更新若引入**别的**静默失败条件，这一行会立刻暴露它，而不是无声丢配置。

---

## 7. 可复现性

* 脚本：`docs/poc/scripts/probe-initdata.ps1 -Total <n>`（长度扫描）、
  `docs/poc/scripts/probe-config-chain.ps1`（端到端，无参数）。
  两者都会：停 shell → 编译 → 写 ini → 重启 explorer → 注入 → 打印两侧日志 → 打开面板做几何回归 → 输出结论。
* **哈希可被外部复核**：`fnv1a64` 用标准 **FNV-1a 64**（偏移基 `0xCBF29CE484222325`，
  按 UTF-16 码元逐位异或）。空串哈希应等于该偏移基本身。

  > ⚠️ 测量过程中发现并修掉一个真实bug：原实现的种子写成了 `1469598103934665603`
  > —— 少一位，是网上广泛流传的**错版**。错版种子算出的哈希与任何标准 FNV 实现都不一致，
  > 导致"日志里的哈希"**无法被第三方独立复核**。已改为正确的 `14695981039346656037`。
  > 独立复核（Node.js，独立实现）：

  ```text
  len      = 165
  fnv1a64  = E0C1B019B461A8F4     ← 与 C++ 侧日志逐位一致
  empty    = CBF29CE484222325     ← 空串 = 偏移基，自检通过
  ```

---

## 8. 对交付文档的修改要点

| 文档位置 | 修改 |
|---|---|
| §2.2 配置下发 | initData 从"主通道"降级为"面包屑"；新增"直投通道 + 导出名 `VmExtTapProvideInitData`"为**跨进程契约的一部分**；补 259 上限与静默失败说明 |
| §2.1 常量表 | 新增导出名常量、259 上限常量 |
| §4.x 注入序列 | 步骤里插入"调用 `VmExtTapProvideInitData`"，并声明**必须在** `InitializeXamlDiagnosticsEx` 之前 |
| §10.x 风险表 | 把"initData 上限"从未知项改为**已知项 + 缓解措施** |
| 陷阱清单 `[同源]` | 新增两条：**① 超限静默失败（`hr==S_OK` 却空串）；② `/utf-8` 源码编码**（BOM-less UTF-8 + 中文注释会被 MSVC 按 936 代码页解读，UTF-8 尾字节 `0x5C` 会吃掉字符串收尾引号 → `C2001 newline in constant`） |

---

## 9. 本项**没有**覆盖的部分（不要误当成已验证）

* **ini 编码**（T2）：`GetPrivateProfileStringW` 对 UTF-16LE+BOM / UTF-8 无 BOM 的中文值行为
  —— 本项**故意**全程只用纯 ASCII 配置值，就是为了不把这个问题混进来。
* **`action=pipe` 全链路**（T3）：只实测过 `action=exec`。
* **"面板已打开时注入"**（T4）：❌ **不做支持** —— 音量浮层不是常驻窗口（按快捷键才出现、失焦即消失），
  本方案在**下次打开**面板时生效即可，无需查明"注入动作会不会把已经开着的浮层弄消失"。
* 直投通道在**多实例/多进程**并发下的行为（产品当前只注入一个 ShellHost，未涉及）。
