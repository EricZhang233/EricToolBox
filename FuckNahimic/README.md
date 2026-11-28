# FuckNahimic

清理 Windows 上的 Nahimic、A-Volute 和相关 OEM 音频组件。脚本为识别出的 Realtek 主声卡切换到微软通用 `hdaudio.inf`，核对绑定后备份并移除对应的 OEM 驱动包。清理范围还包括该声卡关联的 Realtek 软件组件，以及 Realtek Audio Control 的应用注册和预配包。

## 系统要求

- Windows 11 x64 和 PowerShell 7 x64。
- 管理员权限。普通权限启动时，脚本会通过 UAC 请求提权。
- 系统的 `pnputil` 须支持 `pnputil /enum-drivers /devices /format csv`。
- 安装守护服务时，需要 Windows 自带的 .NET Framework 64 位 C# 编译器。

## 使用方式

在工具目录打开 PowerShell 7，先预览操作计划。

```powershell
.\FuckNahimic.ps1 -CheckOnly
```

确认清单后执行交互式清理。

```powershell
.\FuckNahimic.ps1
```

| 参数 | 用途 |
| --- | --- |
| `-CheckOnly` | 列出计划，写日志，并在 Windows Update 服务已运行时查询待安装更新。退出码 `0` 表示有待办，`1` 表示暂无待办，`2` 表示扫描不完整或失败。 |
| `-AutoApprove` | 直接应用计划，跳过确认和重启提问。 |
| `-SkipReboot` | 跳过重启提问。已安排的恢复任务仍会在各自的触发条件满足时运行。 |
| `-SkipGuard` | 本次清理跳过守护服务的安装或升级。 |
| `-InstallGuard` | 单独安装或升级守护服务。服务启动后会检查待安装驱动。 |
| `-RemoveGuard` | 移除守护服务及其通知注册。已隐藏的更新保持隐藏。 |
| `-LogFile` | 指定本次清理日志文件。 |

## 驱动和重启恢复

脚本从 PnP 设备树和 Driver Store 读取设备绑定、驱动类别、提供商及版本。删除以本机发布的 `oem*.inf` 包名为目标。对已确认的主声卡，先导出 OEM 主驱动和扩展，再切换并核对微软通用驱动，随后先删除已解绑的 OEM 主包，再卸载已核实的 OEM 扩展。这个顺序避免 Windows 在卸载扩展时重新选中仍在 Driver Store 里的 OEM 主驱动。

清理前会保存这张卡的播放和录音端点名称，包括可识别的未插入端点。下次开机时，一次性任务会按稳定标识等信息恢复能唯一匹配的端点名称。开始扫描前会记录 Windows Update 服务的启动方式和运行状态。清理期间暂时暂停该服务，端点恢复完成或到达兜底时间后按记录恢复。手动停着的服务保持停止，原本禁用的服务保持禁用。自动更新关闭或通知后手动批准的策略在维护期间保留。若上一次的恢复任务仍在等待，重试会先核对并刷新该任务。

日志、驱动备份和端点快照默认放在 `%TEMP%\eric\FuckNahimic`。主声卡使用通用驱动后，可在系统重新启动后验证扬声器、耳机和麦克风。

## 守护服务

服务名为 `FuckNahimic`，程序安装在 `%ProgramData%\EricSoft\FuckNahimic`。它在 Windows Update 事件到来时检查待安装的目标驱动，先隐藏确切的更新修订，再发出 Windows 通知。点「允许安装」会放行当前修订。点「继续阻止」或 30 秒内未回应，更新保持隐藏。

空闲时服务等待系统事件。通知决策写入 Windows 应用程序日志，事件来源为 `FuckNahimic`。守护覆盖 Windows Update 中可隐藏的待安装驱动。强制更新、已经开始安装的更新和第三方安装器执行的安装不在其控制范围内。
