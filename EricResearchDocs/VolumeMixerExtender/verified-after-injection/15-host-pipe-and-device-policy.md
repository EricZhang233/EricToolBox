# 15 · 宿主侧 TAP 动作接收端与设备策略（2026-10-04）

| 项 | 内容 |
|---|---|
| 目的 | TAP 侧已在发 `SETDEFAULT` / `SETREDIRECT` / `CLEARREDIRECT` / `UNINSTALL`，但宿主没有任何接收端，`Core/EndpointPolicyService` 还是桩 ⇒ 下拉框、清空重定向、从系统卸载全部落空 |
| 结论 | ★ **管道全链路已通**（报文 → 逐行解析 → 派发 → 日志）；`CLEARREDIRECT` 端到端成功；`SETDEFAULT` / `SETREDIRECT` 的调用路径已确认正确，但**本机 RDP 会话下被系统拒绝**（见 §4） |
| 新增 | `Core/TapCommand.*`（协议解析）、`Core/TapPipeServer.*`（named pipe 服务端）、`Core/HostPresence.*`（后台进程存在性）、`vmex_cli host` 命令、`vmex_cli status` 真实查询 |
| 顺带修掉 | ① 进程从未 `CoInitializeEx` ⇒ 所有音频命令必然失败（此前是桩，未暴露）；② `--verbose` / `--trace` 被 CLI 当成未知选项拒绝 |

---

## 1. 后台进程模型（不做托盘态、不做窗口态）

| 项 | 决定 |
|---|---|
| 形态 | `vmex.exe`：无控制台后台进程，起 named pipe 服务端后常驻；`vmex_cli host` 用于命令行启动 |
| 单实例 | `Local\VmExt.Host.S<sessionId>` 命名互斥体；第二个 `vmex_cli host` 直接失败，不抢占 |
| 状态查询 | `vmex_cli status`：另一个进程通过 `OpenMutexW` 判断"在不在跑"，并回显管道名 |
| 自启 | `HKCU\...\Run` 的 `VolumeMixerExtender` 值改为 `"<InstallRoot>\vmex.exe" host`（原 `--tray` 已废） |
| 管道名 | `\\.\pipe\VmExt.Tap.S<sessionId>`（`Core/InjectionContract.h`，TAP 与宿主同源） |

`vmex_cli status`（宿主在跑 / 不在跑两种情形，实测）：

```text
  命令: status
  后台进程: 运行中
  管道: \\.\pipe\VmExt.Tap.S1
  状态: 尚未实现          ← 注入服务仍是桩，如实回显
完成

  命令: status
  后台进程: 未运行
  状态: 尚未实现
完成
```

## 2. 管道服务端的四个既有坑（照 `08-pipe-action-chain.md` 落实）

| 坑 | 处理 |
|---|---|
| `ConnectNamedPipe` 返回 `FALSE` 且 `ERROR_PIPE_CONNECTED (110)` | 视为成功，直接进读循环 |
| `ConnectNamedPipe` 返回 `FALSE` 且 `ERROR_NO_DATA (232)` | **同样视为成功**（客户端连上又关闭，缓冲仍可读） |
| 不 `DisconnectNamedPipe` | 循环末尾必须调用，否则下一次 `CreateNamedPipeW` 失败 |
| 半行 / 多行 | 累积缓冲 + 按 `\n` 切分 + 修剪 `\r`；畸形输入超 4096 字节清空 |

`Stop()` 用"自己连一次管道"把阻塞在 `ConnectNamedPipe` 的服务线程唤醒，避免为取消而引入 overlapped I/O。

## 3. 动作派发（实测日志）

发往管道：`CLEARREDIRECT` / `SETDEFAULT render <真实端点ID>` / `SETREDIRECT render 1234 <ID>` /
`SETDEFAULT bogus` / `WHATEVER hello` / `UNINSTALL`，宿主日志（节选）：

```text
[INFO] [app] 后台进程已启动, 管道=\\.\pipe\VmExt.Tap.S1
[INFO] [pipe] 收到报文 CLEARREDIRECT: CLEARREDIRECT
[INFO] [pipe] 清空逐应用重定向 结果=0
[INFO] [pipe] 收到报文 SETDEFAULT: SETDEFAULT render {3.0.0.00000001}.{6C26BA7D-...}
[WARN] [audio.policy] 切换系统默认设备失败: {...} (hr=0x80004002, role=0)
[INFO] [pipe] 切换默认设备 flow=render role=console 结果=3
[INFO] [pipe] 切换默认设备 flow=render role=multimedia 结果=3
[INFO] [pipe] 切换默认设备 flow=render role=communications 结果=3
[INFO] [pipe] 收到报文 SETDEFAULT: SETDEFAULT bogus
[WARN] [pipe] 报文参数不合法, 已忽略: SETDEFAULT bogus
[WARN] [pipe] 未知报文, 已忽略: WHATEVER hello
[INFO] [pipe] 收到报文 UNINSTALL: UNINSTALL
[WARN] [pipe] 收到卸载请求, 卸载流程尚未实现
```

覆盖到的分支：合法动作、参数不足（丢弃）、未知动词（丢弃）、尚未实现（显式记录、不静默）。

## 4. ★ `IPolicyConfig` 槽位之谜：本次给出确定结论

用独立探针进程（`CoCreateInstance(PolicyConfigClient)` + 逐个 IID `QueryInterface` + 直调 vtable 槽）逐项验证：

| 观察 | 结果 |
|---|---|
| `CoCreateInstance(CLSID_PolicyConfigClient, IID_IUnknown)` | ✅ `S_OK` |
| `QueryInterface(IID_IPolicyConfig = F8679F50-…)` | ✅ `S_OK` |
| `QueryInterface(IID_IPolicyConfigVista = 568B9108-…)` | ❌ `E_NOINTERFACE` |
| 槽 11 传 `(id, nullptr, nullptr)` | `0x800706F4`（`RPC_X_NULL_REF_POINTER`）⇒ 与 `GetPropertyValue` 的形参一致 |
| **槽 13 传真实端点 ID** | `0x80004002`（`E_NOINTERFACE`） |
| **槽 13 传任意其它 ID**（含 packed 形式、空串、假 ID） | `0x80070057`（`E_INVALIDARG`） |

⇒ 槽 13 **就是** `SetDefaultEndpoint`：它会解析设备 ID，只对**真实存在的端点**才继续往下走。
先前 `12-audio-interop-safety.md` 记的"`vtable[13]` 访问违规"是**旧探针的槽位映射写错**（同一份文档里 `slot11` 用正确的 `PKEY_Device_FriendlyName` 却拿到 `VT_EMPTY`，已经指向"整体偏移一位"）；
按本仓库现有的 `IPolicyConfig` 声明（`Unused1..8` → 11 `GetPropertyValue` → 12 `SetPropertyValue` → **13 `SetDefaultEndpoint`** → 14 `SetEndpointVisibility`）调用**不再 AV**。

**但调用到真实端点时返回 `E_NOINTERFACE`** —— 本机环境限制，见下。

| 策略动作 | 本机结果 |
|---|---|
| `SetDefaultEndpoint`（`IPolicyConfig`，槽 13） | ❌ `E_NOINTERFACE`（真实 RDP 端点） |
| `SetPersistedDefaultAudioEndpoint`（WinRT 工厂，槽 25） | ❌ `E_INVALIDARG`（raw 与 packed 设备 ID 都试过；`pid=0` 与真实 pid 都试过） |
| `GetPersistedDefaultAudioEndpoint`（槽 26） | ❌ `E_INVALIDARG` |
| `ClearAllPersistedApplicationDefaultEndpoints`（槽 27） | ✅ `S_OK`（宿主侧 `vmex clear-redirect` 端到端成功） |

⇒ 槽位映射与调用形态都对（`ClearAll` 成功即证明工厂 QI / 槽序号无误），失败集中在"**要对具体端点做改动**"这一步。
本机是 RDP 会话、唯一渲染端点是虚拟的 `远程音频`、采集端点 0 个 ⇒ **与 `12-audio-interop-safety.md` 记录的"未定论"一致，判定为环境限制，需实体机复验**。
（推论也有旁证：`12-` 里"`set(id)` 返回 `E_INVALIDARG`"当时被记成"未定论"，本次确认它并非实现问题。）

## 5. 顺带修掉的两个真 bug

| # | 现象 | 根因 | 修法 |
|---|---|---|---|
| 1 | `vmex devices` 报 `EnumAudioEndpoints failed` | 进程从未 `CoInitializeEx`；TAP 侧能用只是因为 ShellHost 是 COM 已初始化的进程 | `App::Initialize` 以 `COINIT_MULTITHREADED` 初始化；管道线程在每次派发前自行初始化（`RPC_E_CHANGED_MODE` 视为已初始化） |
| 2 | `vmex devices --verbose` 报"未知选项" | `--verbose` / `--trace` 只被 `BuildOptions` 读走，仍原样传给 CLI 解析 | `Program.cpp` 在交给 `CliService` 前剔除这两个全局开关 |

## 6. 复现步骤

```powershell
cmake --build --preset debug
& bin\Debug\vmex.exe status                     # 后台进程: 未运行
& bin\Debug\vmex.exe host                       # 另开一个窗口常驻
& bin\Debug\vmex.exe status                     # 后台进程: 运行中 + 管道名
& bin\Debug\vmex.exe devices --flow render      # 端点列表（含 标识 / 状态 / 默认）
& bin\Debug\vmex.exe clear-redirect             # 走宿主策略，本机实测成功
```

日志：`%TEMP%\eric\VolumeMixerExtender\log\app-<stamp>.log`（一次进程会话一个文件）。
