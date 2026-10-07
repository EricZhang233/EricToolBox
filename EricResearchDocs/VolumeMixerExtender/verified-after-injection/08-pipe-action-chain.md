# 08 — `action=pipe` 全链路（T3）

| 项 | 值 |
|---|---|
| 目标 | 验证 `action=pipe`：点击 → TAP 把点击报文写进命名管道 → App 侧读到；**且点击不阻塞 UI 线程** |
| 结论 | ✅ **全链路通**。报文逐字节正确；UI 线程实测**完全没被拖住**；管道 IO 确实在独立线程上（tid 可证） |
| 副产品 | ⚠️ **发现一个文档里的坑写漏了**：`ConnectNamedPipe` 的合法失败结果除了 `ERROR_PIPE_CONNECTED(110)` 还有 **`ERROR_NO_DATA(232)`**；把它当致命错误会**静默丢掉一次真实点击**（见 §5） |
| 日期 | 2026-10-03 |
| 环境 | Windows 11 build 26300.9550；ShellHost.exe（Medium IL） |
| 探针 | `docs/poc/src/probes/pipeserver.cpp`（**服务端**，产品侧 App 的原型）、`docs/poc/scripts/click-only.ps1`（点击并量耗时） |
| 复现 | 5 次（正常路径 ×2、服务端缺失 ×1、竞态 ×2） |

---

## 1. 为什么这项要单独验

`entry1.action` 有两种取值，`exec` 早先就验过了，`pipe` 一直没碰：

| 取值 | 点击时发生什么 |
|---|---|
| `exec` | TAP 自己 `CreateProcessW` 把程序拉起来 |
| `pipe` | TAP 往命名管道写一行 `CLICK <entryId> <unixMillisUtc>`，由 App 读走再决定 |

`pipe` 的**真实风险不在协议本身，而在"点击发生在 UI 线程上"**：写管道遇到"服务端没起来"要等/重试，
一旦在 UI 线程上等，**点一下就会卡住整个任务栏**。所以本项的验收核心是**"UI 线程没有被拖住"**，
而不是"报文发出去了"。

---

## 2. 怎么测的

| 组件 | 作用 |
|---|---|
| `pipeserver.cpp` | **服务端**（产品侧 App 的原型）：`CreateNamedPipeW` + `ConnectNamedPipe` + 按 `\n` 切行读，把收到的每行打印并落盘。带 `race` 模式用于确定性触发竞态（§5） |
| `click-only.ps1` | 通过 UIA `InvokePattern` 点按钮，并量三件事：① `Invoke` 往返耗时 ② 点击后**立刻**再读面板（证明 UI 线程活着）③ 从 TAP 日志里取"点击行"与"管道结果行"的 **tid** |
| TAP | 新增 `RunEntryAction()`：按 `entry1_action` 分派；`pipe` 走**独立线程**（`std::thread` + 最外层 `try/catch`，见坑 20） |

管道名与报文格式都按交付文档 §2.2.2 / §2.4：
管道名 `\\.\pipe\VmExt.Tap.S<sessionId>`（且**由直投配置通道送达**：`pipe=` 键），
报文 `CLICK <entryId> <unixMillisUtc>\n`，字节模式 + `\n` 分行。

> ★ 顺带验证：管道名确实是**经配置通道**传进 TAP 的 —— TAP 日志打印
> `管道名 = \\.\pipe\VmExt.Tap.S2`，而这个名字来自 Launcher 直投的 `pipe=` 键。

---

## 3. ✅ 正常路径（服务端在跑）

```text
SERVER: listening on \\.\pipe\VmExt.Tap.S2 (expected=1, timeout=25s)
SERVER: RECV: [CLICK volumemixer 1790967895413]
SERVER: OK -- 收到 1 条，退出                     退出码 = 0
```

TAP 侧：

```text
[03:04:55.413 tid=15444]  action=pipe: 报文=[CLICK volumemixer 1790967895413] -> \\.\pipe\VmExt.Tap.S2（已交独立线程…）
[03:04:55.413 tid=13760]  pipe: 已发出 32 字节 -> \\.\pipe\VmExt.Tap.S2
```

| 检查项 | 结果 |
|---|---|
| 报文逐字节正确 | ✅ 服务端收到 `CLICK volumemixer 1790967895413`，32 字节 = `5+1+11+1+13+1` |
| **管道 IO 不在 UI 线程** | ✅ **两行 tid 不同**：点击在 `15444`（UI 线程），管道写与结果在 `13760` |
| UIA `Invoke` 往返 | ✅ **14 ms** |
| 点击后立刻读面板 | ✅ **9 ms** 读到，位置未变 |
| 服务端 | ✅ 收到 1 条后正常退出，`ExitCode=0` |

---

## 4. ✅ 降级路径（服务端不在 = App 没运行）

```text
[03:05:22.681 tid=15444]  action=pipe: 报文=[CLICK volumemixer 1790967922682] …（已交独立线程）
[03:05:22.682 tid=15396]  pipe: 首次 CreateFile 失败 err=2，WaitNamedPipeW(200) 重试…
[03:05:22.682 tid=15396]  pipe: 服务端不可用，放弃本次点击 (err=2) —— 面板不受影响
```

| 检查项 | 结果 |
|---|---|
| 失败被显式记录（不是静默） | ✅ 记了两次（首次失败 + 最终放弃），带错误码 |
| **丢点击但不丢面板** | ✅ ShellHost 存活、CPU 0.81s，按钮仍在 `(2472,1419)` |
| UI 线程 | ✅ `Invoke` 往返 **7 ms**，点击后 9 ms 内可读面板 |
| 两个 tid 不同 | ✅ `15444` vs `15396` |

> 📌 **一个值得记住的细节**：`err=2` 是 `ERROR_FILE_NOT_FOUND` —— **立即返回**，不是等满 200ms。
> `WaitNamedPipeW` 的 200ms 只有在"管道**存在**但所有实例都忙"时才会等。
> 换句话说：App **完全没运行**时降级是瞬时的，反而是"App 在跑但忙于处理"时才会等那 200ms ——
> 而那种情况才真正需要"不能在 UI 线程上等"这条纪律。

---

## 5. ⚠️ 竞态：`ConnectNamedPipe` 的合法失败有**两种**，不是一种

交付文档（§4.3 坑 19）只写了 `ERROR_PIPE_CONNECTED`。这次实测发现还有第二种，而且**更容易写错**。

客户端（TAP）写完之后**立刻 `CloseHandle`**。如果"连上 + 关闭"这一整套都发生在服务端调用
`ConnectNamedPipe` **之前**，那么 `ConnectNamedPipe` 返回 `FALSE`，但 `GetLastError()` 是：

| 错误码 | 含义 | 正确处理 |
|---|---|---|
| `ERROR_PIPE_CONNECTED` (110) | 客户端已连接、**仍然开着** | ✅ 当作成功，直接进读循环 |
| **`ERROR_NO_DATA` (232)** | 客户端连接过、**已经关闭** | ⚠️ **不能当致命错误**！缓冲里的数据**仍然可读** —— 继续试着读一遍 |
| `ERROR_BROKEN_PIPE` (109) | 读的时候对端关闭 | ✅ 正常的流结束信号，**不是错误** |

### 5.1 复现方式（确定性，不靠运气）

`pipeserver.exe <name> 1 25 <out> race` 的 `race` 模式会在 `CreateNamedPipeW` **之后**先睡 3 秒
再调 `ConnectNamedPipe` —— 于是客户端一定在这段窗口里连上并关闭，必然命中 232。

### 5.2 实测结果：232 之后数据**没丢**

```text
SERVER: (race) CreateNamedPipe 已建实例，等 3s 让客户端先连上…
SERVER: (ConnectNamedPipe FALSE + ERROR_NO_DATA(232) -> 客户端连上又断开了；试着读缓冲)
SERVER: RECV: [CLICK volumemixer 1790968219070]        ← ★ 32 字节完好读回
SERVER: ReadFile err=109（客户端关闭通常也会走到这里）
SERVER: OK -- 收到 1 条，退出                          退出码 = 0
```

### 5.3 为什么这条很重要

我**第一版**探针就是把 232 当致命错误直接退出的（`return 1`）—— 而那正是"照着文档写"会写出来的代码。
后果是：**服务端恰好在这个竞态窗口里启动时，那一次点击被静默丢弃**（App 什么都没收到，用户只看到"点了没反应"）。

产品侧的 App 通常**在 logon 时就起好了**，所以稳态下不会命中；但"App 刚启动 / 正在重启"的那一小段
窗口是**完全真实**的场景。正确写法：

```cpp
BOOL ok = ConnectNamedPipe(h, nullptr);
if (!ok) {
    const DWORD e = GetLastError();
    if (e == ERROR_PIPE_CONNECTED) {
        ok = TRUE;                                  // 已连上，直接读
    } else if (e == ERROR_NO_DATA) {
        // 连上又断开了 —— 缓冲里可能还有数据，**必须继续读**
        // 读不到再 DisconnectNamedPipe(h) 重新 arm，然后 continue
        ok = TRUE;
    } else {
        // 真正的错误
    }
}
```

---

## 6. ✅ 恢复与热重载（附带验证）

| 检查 | 结果 |
|---|---|
| 降级失败后，服务端回来再点 | ✅ 收到 `CLICK volumemixer 1790967955192`（一次失败不会"卡死"后续点击） |
| **配置热重载**：只改 ini 里的 `entry1_action=pipe → exec`，**不重启 explorer、不重新注入** | ✅ 下一次点击立刻变成 `action=exec: CreateProcessW OK pid=9792` |
| `exec` 路径没被这次重构弄坏 | ✅ winver 被拉起，几何仍 `TestLink (2472,1419) 71x40` |

> 热重载这条是**顺带**验到的：TAP 在**每次点击时**才读 `entry1_action`，所以改 ini 立即生效。
> 这与文档 §2.3 声称的"每次命中 `Footer` 时重读 ini ⇒ 改配置后下次打开面板生效"是一致的，
> 而且这里比文档说的还宽松 —— 点击动作甚至**不用重开面板**。

---

## 7. 对交付文档的修改

| 位置 | 修改 |
|---|---|
| §4.3 坑 19 | `ConnectNamedPipe` 的合法失败**有两种**：`110`（已连上）与 **`232`（连上又关了，数据仍可读）**；再加 `109`（读时对端关闭 = 正常收尾） |
| T3 | 从"未验证"改为 ✅ 已验证（`exec` 与 `pipe` 两条都通） |
| V4 | 对应项标记为已验证：点击动作（`exec` / `pipe`）+ **点击时面板不卡顿**（实测 `Invoke` 往返 7–14 ms） |
| §2.4 IPC | 补充"服务端实现要点"三条：232 要读、109 不是错、App 完全没跑时是**瞬时**失败（不会等满 200ms） |

---

## 8. 本项**没有**覆盖的部分

* **报文积压/并发**：只测了"一次点击一条报文"。连续快速点击、以及服务端处理慢时的退避策略未测。
* **跨会话**：只测了同会话（Session 2）。管道名带 `S<sessionId>`，跨会话本来就不通。
* **管道安全性**：未设置安全描述符（默认继承创建者的 DACL）。同用户自用工具，未做加固。
* **`ERROR_PIPE_BUSY` + `WaitNamedPipeW` 真的等满 200ms 的那条路**：本次没构造"管道存在但实例全忙"的场景。
