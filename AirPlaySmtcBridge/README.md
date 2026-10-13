# AirPlaySmtcBridge

AirPlaySmtcBridge 是一个 Windows 后台桥接程序：它被动读取本机网络适配器上的 AirPlay/RAOP 流量，并把歌曲信息、封面、播放状态和播放进度发布到 Windows 的系统媒体传输控件（SMTC）。程序本身不接收、播放或转发音频。**本机必须另有 AirPlay 接收软件正在运行并接收 AirPlay 流**；如果没有这样的接收软件，或当前没有活动的 AirPlay 接收会话，本程序就没有可抓取的 AirPlay 流量，媒体信息和控制功能也不会生效。

- 本机需要另行安装并运行一个 AirPlay 接收客户端(目前确认适配的有[AirServer](www.airserver.com/)，_其他软件适配未知，按理说只要是标准AirPlay协议都支持，但是实测爱思投屏不支持，同理可能各种用于投画面的非标AirPlay软件都不支持，我也不打算进一步支持这些非标软件_)，由该客户端接收发送设备推送的 AirPlay 流。本程序只抓取本机网络适配器上的流量，不提供 AirPlay 接收服务；没有活动的接收客户端会话时，项目无法获取 AirPlay 数据。

## 功能

- 从 AirPlay RTSP 流中读取歌曲信息、封面、播放进度和会话状态。
- 在 Windows 媒体控件中显示歌曲名、艺人、专辑、封面和进度。
- 将媒体控件中的播放、暂停、上一首、下一首、快退和快进操作通过 AirPlay DACP 发回发送端。
- 通过大包 UDP 音频流量判断播放状态：检测到音频包时显示“正在播放”，采样期间没有音频包时显示“已暂停”。
- 将 SMTC 时间轴的最小和最大跳转位置都设为当前播放位置，以保留进度显示并关闭可拖动的跳转范围。
- 使用 `AirPlaySmtcBridge` 作为进程互斥标识，避免多个实例同时运行。

## 运行要求

- 本机需要另行安装并运行一个 AirPlay 接收客户端(目前确认适配的有`[AirServer](https://www.airserver.com/)`，其他软件适配未知，按理说只要是标准AirPlay协议都支持，但是实测爱思投屏不支持，同理可能各种用于投画面的非标AirPlay软件都不支持，我也不打算进一步支持这些非标软件)，由该客户端接收发送设备推送的 AirPlay 流。本程序只抓取本机网络适配器上的流量，不提供 AirPlay 接收服务；没有活动的接收客户端会话时，项目无法获取 AirPlay 数据。
- Windows 10 或 Windows 11（x64）。
- 本机无线网卡和 Npcap 抓包驱动。程序通过 Npcap 的 `Packet.dll` 被动读取网络帧。
- 首次运行如未检测到 Npcap，程序会提示并尝试从 Npcap 官网下载官方安装程序；安装需要在 Windows UAC 提示中由用户确认。程序自身不提权。
- AirPlay 发送设备与运行桥接程序的电脑应处于可互相通信的网络中。

## 构建

仓库包含 C# 源码和 PowerShell 构建脚本。使用 Windows 自带的 .NET Framework C# 编译器构建，不需要安装 .NET SDK：

```powershell
.\build-dotnet-framework-csharp.ps1
```

构建输出为项目目录下的 `AirPlaySmtcBridge.exe`。需要 `airplay.ico`、`app.manifest`、Windows SDK WinMD 元数据以及系统自带的 .NET Framework 编译器。

也可以直接用 .NET CLI 构建，或在 Visual Studio 中打开 `AirPlaySmtcBridge.csproj` 并选择 `Release`、`x64`：

```powershell
dotnet build .\AirPlaySmtcBridge.csproj -c Release -p:Platform=x64
```

构建产物位于 `bin\Release\AirPlaySmtcBridge.exe`。需要 .NET SDK、MSBuild 工具和 .NET Framework 4.8 targeting pack。

## 启动与参数

双击 `AirPlaySmtcBridge.exe` 即可启动。程序没有主窗口；运行日志写入：

```text
%TEMP%\eric\AirPlayBridge\AirPlayBridge.log
```

支持以下命令行参数：

| 参数 | 作用 |
| --- | --- |
| `--no-control` | 不向发送端发送播放控制命令，只镜像媒体信息。 |
| `--no-timeline` | 不发布播放进度时间轴。 |
| `--disconnect-sec=N` | 设置判断 AirPlay 会话结束的等待秒数，默认 5 秒。 |
| `--verbose` | 在日志文件之外向标准错误输出额外诊断信息。 |
| `--no-dialogs` | 禁用提示对话框，诊断和部署流程改写入日志。 |
| `--stop` | 通知正在运行的实例正常退出并清理 SMTC 媒体会话。 |
| `--fetch-npcap` | 仅下载并验证 Npcap 安装程序，不安装。 |
| `--test-dialog` | 显示 Npcap 安装提示对话框，用于检查提示内容。 |

例如，关闭回传控制并开启详细日志：

```powershell
.\AirPlaySmtcBridge.exe --no-control --verbose
```

## 工作方式与限制

- 程序优先选择名称或描述中包含 Wi-Fi、WLAN、wireless 的网络适配器进行抓包。若系统有多个无线适配器，可能需要调整适配器配置后重启程序。
- 播放进度来自 AirPlay 上报的时间轴；在两次上报之间，Windows 会根据已发布的时间轴继续推进显示。设备上报间隔较长或上报位置与实际声音不同步时，电脑上的显示也可能落后或偏离听感。桥接程序没有实际音频输出时间戳，无法保证消除这类偏差。
- 暂停状态依据音频 UDP 大包流量推断，不依据进度上报间隔。网络丢包、抓包适配器选择或 Npcap 状态异常都可能影响判断。
- 进度条仍显示位置和总时长，但跳转范围被设为零宽；不同 Windows 组件可能有不同的进度条交互表现。
- 快退和快进按钮保持启用。其具体效果取决于发送设备及 AirPlay/DACP 会话是否支持相应命令。
- 程序会在 `%TEMP%\eric\AirPlayBridge` 保存运行日志和临时封面文件。

## 项目文件

- `AirPlayBridge.cs`：程序实现。
- `build-dotnet-framework-csharp.ps1`：使用 .NET Framework C# 编译器的简易构建脚本。
- `AirPlaySmtcBridge.csproj`：Visual Studio 和 .NET CLI 共用的 MSBuild 项目。
- `app.manifest`：Windows 应用清单。
- `airplay.ico`、`airplay.png`：应用图标资源。
