# AirPlayBridge — 把 AirPlay 的「现在播放」接到 Windows SMTC

把 iPhone 通过 AirPlay 投到本机（AirServer 或任意接收端）的音乐信息，**免提权**抓出来并发布成 Windows 系统媒体控件（SMTC）会话：歌名 / 歌手 / 专辑 / 封面 + 进度（当前位置 + 总时长）。

- 抓包：Npcap `Packet.dll`（用户态，**不需要管理员**）
- 解析：AirPlay/RAOP 的 RTSP 控制通道（TCP 7000）——`progress` + DMAP 元数据 + 封面
- 发布：`SystemMediaTransportControlsInterop.GetForWindow(hidden HWND)`（独立 SMTC 会话，时间轴完全由我们控制）
- 反控：DACP `GET /ctrl-int/1/<cmd>`（媒体卡片按钮 + 键盘媒体键 → iPhone，**不需要管理员**）

## 独立 App（推荐）：`AirPlaySmtcBridge.exe`

**单文件、无 GUI、无控制台窗口、纯后台**；用系统自带的 .NET Framework 编译器构建，**不需要 .NET SDK**（WinRT 走 OS 自带的 `WinMetadata\*.winmd`）。

```powershell
# 构建（几秒）
pwsh -NoProfile -ExecutionPolicy Bypass -File "<本文件所在目录>\build.ps1"
# 运行（双击亦可；不会出现任何窗口）
Start-Process "<本文件所在目录>\AirPlaySmtcBridge.exe"
# 可选参数
#   --no-control        只读镜像（不接管媒体键）
#   --no-timeline       不发布进度时间轴
#   --disconnect-sec=5  断联判定门槛（秒）
#   --verbose           额外把日志写到 stderr
#   --stop              让正在运行的实例注销 SMTC 会话并退出（优雅停止）
```

**务必用 `--stop` 停止，不要强杀**：SMTC 会话的生命周期绑在创建它的进程上，`Taskkill /F`、`Stop-Process -Force` 会**跳过清理代码**，把媒体卡片留成"幽灵"（外壳不一定马上回收，卡片继续显示上一次的歌名/封面）。`--stop` 走命名事件通知运行中的实例：
```
> AirPlaySmtcBridge.exe --stop
stop signal sent
[日志] stop requested -> unregistering the SMTC session and exiting
[日志] SMTC session unregistered (no AirPlay data any more; media keys released)
[读回] sessions: 0        ← 卡片消失，无残留
```
进程还会处理 `WM_ENDSESSION`：注销/关机时先注销会话，避免关机过程中留下幽灵卡片。

- **自带身份，每次启动自注册并覆盖**：
  - 进程 AUMID = **`AirPlaySmtcBridge`**；每次启动重写 `HKCU\Software\Classes\AppUserModelId\AirPlaySmtcBridge`（`DisplayName = AirPlay`、`IconUri = <exe 本体路径>`，不拷贝不重定向）
  - 每次启动重写开始菜单快捷方式 `%APPDATA%\Microsoft\Windows\Start Menu\Programs\AirPlaySmtcBridge.lnk`，带 `System.AppUserModel.ID = AirPlaySmtcBridge`、图标指向 exe —— 这是裸 Win32 应用在外壳 AppResolver 里的身份来源
  - 因此**换目录/改路径后直接跑即可**，注册项与快捷方式会自动指向新位置；旧的 `Clawrin.AirPlayBridge` / `eric.AirPlayBridge.app` 注册键与旧的 `AirPlay.lnk` 会自动清理
- **注册时机（无真实数据不注册）**：只在 iPhone 真的上报了歌曲数据（DMAP 元数据或 `progress` 时间轴锚点）时才创建 SMTC 会话；**音频流在流但没有任何歌曲数据时不注册**，所以启动阶段不会出现"占位卡片"。日志会记一行 `audio is flowing but no song data yet -> SMTC stays unregistered until the iPhone reports`。
- **图标**：`airplay.ico`（由 `airplay.png` 转出，7 种尺寸）通过 `/win32icon` **嵌进 exe**；SMTC 用的隐藏窗口也注册了自带图标的窗口类（外壳解析不到 AUMID 时会回退看窗口图标/标题）。
- **版本资源**：源码里的 `[assembly: AssemblyTitle/Product/Company/...]` 决定 exe 的 `FileDescription` / `ProductName` / `CompanyName`（**必须写**，否则 csc 生成的那份只有 1 个字符的 `FileDescription` 会让外壳显示"未知应用"）。
- 日志：`%TEMP%\AirPlayBridge\AirPlayBridge.log`；内存约 **50 MB**（PowerShell 版约 250 MB）。
- **单实例**：命名互斥体，重复启动会直接退出；生命周期仍由**外部** Taskkill 管理，程序自身永不退出。

### 抓包依赖（Npcap）：有就用，没有就自动安装（**本程序自己不提权**）
抓包靠 **Npcap**（第三方，非 Windows 自带；厂商 Insecure.Com LLC，本机 v1.60，由 AirServer 安装时静默装入）。启动时会自检并打一行：

```
npcap self-check: Packet.dll=yes driver=yes v1.60      # 或 Packet.dll=MISSING driver=MISSING
```

- **系统已有** → 直接使用（用户态 `Packet.dll` + 内核 `npcap` 驱动，普通权限即可，无需提权）。
- **系统没有** → 触发自动安装流程：
  1. **弹窗说明步骤**并征求确认（"下载官方包 → 安装器自己申请管理员权限（UAC）→ 安装完成后本程序自动重启"）；
  2. 从官网 `npcap.com` 解析**最新版**下载链接（实测 1.89）→ 下载 → **校验**：体积、`ProductName` 含 Npcap、**Authenticode 签名者必须是 Nmap**，通过后记录 SHA256；
  3. 以 `UseShellExecute + Verb=runas` 启动安装器 `/S` —— **提权是由安装器自己向 Windows 申请的**（弹 UAC 确认框），我们只负责启动它；
  4. 等安装结束 → 重新探测驱动 → **自动重启主程序**（单实例互斥体带交接等待，重启后无缝接管）；
  5. 任何一步失败都会弹说明窗口，给出**手动步骤**（npcap.com 下载 → 安装 → 重启）。
  - 若 exe 旁已放有 `npcap-installer.exe`（或任意 `npcap*.exe`），优先用本地那份，不联网。

诊断参数：`--fetch-npcap`（只下载+校验，不安装、不提权）、`--test-dialog`（只显示那个说明窗）、`--no-dialogs`（无人值守时改为只写日志）。

> ⚠️ **许可**：Npcap 免费版**不允许随包再分发**（Nmap Public Source License；商业分发/OEM 捆绑需 Npcap OEM 授权）。因此本程序**不内嵌安装包**：缺依赖时才从厂商官网获取（或你自行放置本地安装包）。

### 丢进开发环境（VS / dotnet）时的方言差异 ⚠️

| 环节 | .NET Framework 4.8（当前 `build.ps1`，系统自带 csc） | .NET 8/10（CsWinRT 投影） |
|---|---|---|
| 取 SMTC | 手动 COM 声明 `ISystemMediaTransportControlsInterop`（GUID `DDB0472D-…`）+ IID **`99FA3FF4-1742-42A6-902E-087D41F965EC`**（`ISystemMediaTransportControls`），再 `WindowsRuntimeMarshal.GetActivationFactory` | 直接用 `SystemMediaTransportControlsInterop.GetForWindow(hwnd)` |
| 挂事件 | 反射 `add_ButtonPressed` / `add_PlaybackPositionChangeRequested`（C# 不允许直接调访问器，CS0571） | 正常 `smtc.ButtonPressed += …` |
| WinRT 引用 | `%WINDIR%\System32\WinMetadata\*.winmd` + `System.Runtime.dll`、`System.Runtime.WindowsRuntime.dll`、`System.Runtime.InteropServices.WindowsRuntime.dll` | `Microsoft.Windows.SDK.NET.dll` + `WinRT.Runtime.dll` |
| 异步 | 轮询 `((IAsyncInfo)op).Status` 后 `op.GetResults()`（`AsTask()` 需额外引用） | `await …` 即可 |
| 版本资源 | 用程序集属性（见上） | SDK 风格项目文件里写 `<AssemblyTitle>` 等即可 |

> `dotnet build` 需要 SDK（本机只有运行时 8/9/10，没有 SDK）；当前构建走的是系统自带 `csc.exe`，无需安装任何东西。

> 同目录的 `AirPlayBridge.ps1` 是**等价参考实现**（同一套协议逻辑），保留用于对照/调试。

## 运行 PowerShell 版（备选）

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "<本文件所在目录>\AirPlayBridge.ps1"
# 常用参数
#   -TitleMode Lyric   标题改为「实时歌词行」（默认 Song：歌名）
#   -Verbose           打印每句歌词与进度
#   -DisconnectSec 5   断联判定门槛：多久没有 RTSP 保活 / 收到 TEARDOWN / 看到 FIN-RST 就注销会话
```

**进程生命周期由外部管理**：脚本**永不自行退出**（主循环没有 break/exit），它只负责 SMTC 会话的注册与注销；要结束就外部 `Taskkill` / `Stop-Process`（Ctrl+C 亦可，会顺手注销会话）。会话消失后只做**注销**，进程继续待命，等下一次 AirPlay 会话再注册。

**断联检测（三条独立信号，共用 `-DisconnectSec`，默认 5 秒）**：

| 信号 | 来源 | 说明 |
|---|---|---|
| 保活超时 | RTSP `OPTIONS *` | iOS 约每 2 秒一条，>5 秒没有即判断联（留 2.5 倍余量） |
| `TEARDOWN` | RTSP 请求 | 用户停止 AirPlay 时 iOS 主动发，收到即开始计时 |
| `FIN` / `RST` | 控制连接 TCP 标志位 | 网络掉线/被断开时可见；检查在 payload 判空**之前**做（这类段通常无载荷） |

任何存活证据（保活、`progress`、元数据）都会**取消**已开始的断联计时，所以连接抖动不会误注销。实测 45 秒连续播放 **0 次误判**。


## 反向控制（已实测，免提权）

桥会同时接两条控制入口，并映射成 iPhone 的 DACP 命令：

| 入口 | 实现 | 说明 |
|---|---|---|
| **SMTC 媒体键 / 媒体卡片按钮** | `SystemMediaTransportControls.ButtonPressed`（C# 回调，纯 .NET） | Windows 把媒体键路由给"当前会话"时走这条 |
| **键盘媒体键（兜底）** | `GetAsyncKeyState` 15 ms 轮询（`Timer`） | Windows 把键路由给别的 App 时仍能捕获 |

> 两条入口都**只在 SMTC 会话已注册期间生效**：没有会话时既不会 hook `ButtonPressed`，也会 `Dispose` 键盘轮询 Timer —— 绝不吞掉用户的媒体键。注册时启动、注销时释放（日志分别打印 `media keys captured while registered` / `media keys released`）。

| 按键 | DACP 命令 |
|---|---|
| 播放 / 暂停 / 停止 | `play` / `pause` / `stop` |
| 上一首 / 下一首 | `previtem` / `nextitem` |
| 快进 / 快退 | `beginff` / `beginrew` |

两条入口有 **800 ms 去重**（`rl=N` 计数可见），避免同一个键被处理两次而"暂停又播放"。

**端点与凭据**（都自动）：`_dacp._tcp` mDNS 发现端口（本机实测 59309）→ 缓存到 `%TEMP%\AirPlayBridge\dacp.txt`；`Active-Remote` token 从被嗅探的 RTSP 流里抓取（每次会话刷新）→ 缓存到 `token.txt`，启动即可控。

**SMTC 会话按需注册（懒注册）**：没有真实 AirPlay 数据时**不创建**会话，所以系统媒体卡片里**不会出现 `AirPlay (waiting)` 这种占位条目**；拿到第一条 `progress` 或元数据时才注册，并在 AirPlay 会话结束后（`-IdleStopSec`，默认 180 秒无保活）自动注销。

**播放状态以 iPhone 自己上报的时间轴为准**：
- 主判据：`progress: start/current/end` 的上报间隔。暂停时 iOS **直接停止上报**，所以"超过 `-PauseAfterSec`（默认 10 秒）没有新上报"即判为 Paused。
- 本机网络信号（数据端口大 UDP 包速率）**只用于否决误判**：只有当"疑似暂停"但音频流仍在明显流动时，才维持 Playing。它永远不会单独把状态推成 Paused —— 抓包不可靠也不会造成假暂停；恢复播放时还能让状态**立刻**回到 Playing，不必等下一次上报。
- `progress` 报文**不修改状态**，只推位置（曾导致曲末静音时状态抖动，已修）。

**进度条值只推真实数据**：每条 `progress` 到达即推**真实位置**（`(current-start)/44100`）；两次推送之间由 **Windows 自己插值**（`Position + LastUpdatedTime + PlaybackStatus`）。桥仅在 12 秒无新数据时做一次漂移校正；暂停时只切 `PlaybackStatus`，由 Windows 冻结进度条，**绝不推假位置**。

实测（读回验证，全自动）：
```
t=3s    sessions: 0                                   ← 没数据不注册
t=19s   sessions: 1  title=心跳23事  status=Playing     ← 有真实数据才注册
DACP pause -> 200 OK ;  暂停+15s  status=Paused         ← state -> Paused (iPhone last reported 10.7s ago)
DACP play  -> 200 OK ;  恢复+14s  status=Playing        ← position 19.6s / 04:20
停桥后  sessions: 0                                   ← 注销
```

**做不到的**：`seek`。iOS 的 DACP 只实现了按钮子集，`setproperty?dacp.playingtime=` 返回 400。

**尝试声明"进度条不可调整"（外壳不认，见下）**：SMTC 写入侧**没有** `IsPlaybackPositionEnabled` 之类的布尔开关（已反射核对整个 `SystemMediaTransportControls` 成员表），能设的只有 `SystemMediaTransportControlsTimelineProperties` 的**可调区间**。桥把 `MinSeekTime` 与 `MaxSeekTime` **都设为 0**（空区间 = 官方语义上的"位置只读"），同时仍给出 `StartTime`/`EndTime`/`Position` 供显示：

```
读回: position = 00:02:43.143 / 00:04:01.000
      seekable = 00:00:00.000 .. 00:00:00.000     ← 声明为不可调整
```

**⚠️ 但滑块并不会因此变灰**（实测）：写入侧**两个接口**（`ISystemMediaTransportControls`、`ISystemMediaTransportControls2`）的成员全表里**都没有**位置控制开关；6 组变体实验（`EndTime` 有/无、`MaxSeekTime` 有/无、快进快退开/关、`PlaybackRate` 有/无）读回 `posControlEnabled` **全部为 True** —— 该标志由外壳自行推导，应用侧无法关闭。

因此提供两层"实际效果"兜底：

1. **默认：拖动即回弹**。Windows 会把拖动事件送到我们（`PlaybackPositionChangeRequested`），桥立刻把**真实位置**重新推回去：
   ```
   [16:29:53] seek request ignored (iOS DACP has no seek)
   [16:29:53] seek not supported: asked 2.6s -> snapped back to the true position 236.4s
   [16:29:55] seek not supported: asked 50.3s -> snapped back to the true position 238.9s
   ```
2. **`-NoTimeline`：干脆不发布时间轴**。卡片拿不到任何位置数据（读回 `position 00:00:00.000 / 00:00:00.000`），滑块失去可拖对象；代价是**没有"已播/总时长"显示**。

快进/快退按钮**保留**，因为它们真能兑现（DACP `beginff` / `beginrew`）。

**关闭回控**：`-NoControl`（只读镜像）。

实测证据（全自动，模拟媒体键）：
```
[15:49:21] Active-Remote from cache: 4292676759
[15:49:28] audio 133 pkt/s -> Playing
[15:49:39] control: 15:49:38 [smtc] -> pause : HTTP/1.1 200 OK
[15:49:41] audio 0 pkt/s -> Paused, timeline frozen at 32.6s
[15:49:47] audio 56 pkt/s -> Playing
ctl[smtc=1 sent=1 rl=1]
```

## 依赖

| 依赖 | 说明 |
|---|---|
| Npcap（本机已装 1.60） | 安装时若勾选「仅管理员可访问」，本脚本会抓不到包 |
| CsWinRT 投影 | `<workspace>\.dsh\cache\smtc\`（WinRT.Runtime.dll + Microsoft.Windows.SDK.NET.dll，smtc-control skill 已缓存） |
| Windows 10/11 | SMTC + WinRT |

## 实测证据（2026-10-13）

| 项目 | 实测值 |
|---|---|
| 免提权抓包 | `\\.\NPCAP` 非提权打开成功；12 s 抓到 3637 帧，其中 30 帧 TCP 7000 |
| 进度语义 | `progress: start/current/end`，单位 RTP 帧 @ **44100 Hz**；位置 `(cur-start)/44100`，时长 `(end-start)/44100` |
| 采样率交叉验证 | 帧增量 ÷ 墙钟增量 = **44,097 Hz**；位置推进 113.89 s vs 墙钟 113.92 s（偏差 0.03%） |
| 端到端 | SMTC 会话标题=爱情转移、歌手=陈奕迅、专辑=爱情呼叫转移、`Position=111.9s / EndTime=255s` 实时推进 |
| 元数据解析 | 10/10 用例通过（含「歌词 - 歌名/歌手」形态） |

## 元数据判定规则（`Resolve-Meta`）

iOS 的 DMAP 元数据里，`minm` 常常是**逐句歌词**，而歌名/歌手藏在别处。按优先级：

1. `asar`（艺人字段）形如 `歌名 — 歌手`（**要求分隔符两侧有空格**）→ 取歌名 / 歌手
   - `胸前 — 徐良` → 歌名=胸前，歌手=徐良
   - `拾忆 — 张翰` → 歌名=拾忆，歌手=张翰
   - `我也很想他 — 孙燕姿` → 歌名=我也很想他，歌手=孙燕姿
2. `minm` 形如 `歌词 - 歌名/歌手` → 舍弃前段，**第一个 `/`** 切歌名与歌手（用户提供的规则）
   - `你想法很简单 我一切都要管 - 犯贱/徐良` → 歌名=犯贱，歌手=徐良
3. 换歌窗口（15 s 内）`minm` 形如 `歌名 - 歌手` → 切分
4. 换歌窗口内第一条 `minm` 视为歌名
5. 兜底：`asar` 原样作歌手；`minm` 原样作标题
   - `艺人1/艺人2`（如 `三Z-STUDIO/HOYO-MiX`）**不**按 `/` 切分，避免把多艺人列表切坏

换歌判定不用 `mper`（每句歌词都会变），而是用 `progress` 的 **RTP 锚点对 (start,end)**：同一首歌内只有 ±几帧抖动，跳变 > 1 s 才算换歌。

## 已知限制

| 限制 | 现状 |
|---|---|
| 反向控制（暂停/切歌/停止/快进快退） | ✅ 已打通：DACP `GET /ctrl-int/1/<cmd>` + `Active-Remote`（免提权）。**seek 除外**（iOS 不实现 `setproperty?dacp.playingtime=`） |
| 进度条可拖动 | ❌ 已主动声明为不可调整：`MinSeekTime = MaxSeekTime = 0`（写入侧没有 `IsPlaybackPositionEnabled` 开关）；拖动请求只记录并忽略 |
| 卡片归属显示为 PowerShell | ⚠️ 本机唯一的 `pwsh` 是 **Store 打包版**（`Microsoft.PowerShell_7.6.6.0_x64__8wekyb3d8bbwe`），包身份把会话 AUMID 钉死为 `Microsoft.PowerShell_8wekyb3d8bbwe!App`，`SetCurrentProcessExplicitAppUserModelID` 对打包进程无效 → 控制中心按该 AUMID 渲染应用名/图标。要改成自己的名字需要**非打包宿主**（独立 exe，或 MSI 版 PowerShell） |
| 封面（控制中心） | ✅ 两处修复：(1) `CreateFromUri(file://)` 在 interop 路径下不生效 → 改用 `StorageFile.GetFileFromPathAsync` + `RandomAccessStreamReference.CreateFromFile`；(2) iOS 封面常在**会话注册之前**到达，早期被丢弃 → 现在会记住并在注册时补挂（日志 `artwork applied at registration`），读回 `thumb: present`。注意：**缩略图缺失时控制中心会回退显示应用图标**（也就是那条 PowerShell 图标） |
| 中途接入 | 若在某首歌中途启动，`asar` 无分隔符时歌名要等下一次换歌才能确定（期间标题暂用歌词行） |
| 依赖 AirServer 在跑 | 本脚本只旁路读取，不干扰 AirServer；AirServer 仍负责解码与出声 |

## 排错

- **抓不到包**：确认 Npcap 服务在跑、安装时未限管理员；脚本会自动挑描述含 Wi-Fi/WLAN/Wireless 的网卡。
- **没有 SMTC 会话**：`GetSessions().Count` 应为 1；为 0 说明脚本已退出（看日志）。
- **标题一直是歌词**：说明该曲目的 `asar` 无分隔符且尚未换歌 —— 切一首歌即可，或用 `-TitleMode Lyric` 明确要歌词模式。

## 协议笔记（复用要点）

- 控制通道：TCP 7000（RTSP）。报文只有 `SET_PARAMETER` + `OPTIONS *` 保活 + `200 OK`。
- `Content-Type` 三类：`text/parameters`（progress）、`application/x-dmap-tagged`（DMAP：`mlit` 容器内 `minm`/`asar`/`asal`/`mper`）、`image/jpeg`（封面，约 150–180 KB，会重复发）。
- 请求头含 `DACP-ID` / `Active-Remote`（反向控制凭据，见上）、`RTP-Info: rtptime=<current>`、`User-Agent: AirPlay/980.77.1`。
- **抓包实现坑**：pktmon 的 pcapng 会把 802.11 帧标成 linktype=Ethernet（要按 802.11 头解析）；Npcap 的 `PacketReceivePacket` 原生返回 1 字节 `BOOLEAN`，C# P/Invoke 必须声明为 `byte`，否则高位垃圾导致立刻退出。
- 交叉验证（**仅分析阶段用，脚本运行时不读它**）：AirServer 的 Windows 事件日志（`App Dynamic-AirServer-AirServer/Operational`）里 `Playing <minm> by <asar> from the album <asal>` 与 RTSP 流里是同一份数据，可用来对照解析结果。曾试过用它给"中途接入"补歌名，**已回退**：本进程常驻，正常不会在歌中途启动；而 AirPlay 若在我们存活期间重新连接，发送端一定会重推当前曲目信息，同一份流里就能拿到。
