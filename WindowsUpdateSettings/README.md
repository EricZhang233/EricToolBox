# WindowsUpdateSettings

`WUSettings.ps1` 是一个用于管理 Windows Update 策略的 PowerShell 脚本，支持：

- 设置自动更新模式（通知/自动下载/计划安装/本地管理员选择/恢复默认）
- 一键切换驱动更新阻止状态
- 交互式隐藏或恢复指定更新（软件与驱动）

脚本会在非管理员启动时自动尝试提权后重启自身。

## 文件

```text
WindowsUpdateSettings/
  WUSettings.ps1
  README.md
```

## 系统要求

- Windows 10 / 11
- Windows PowerShell 5.1+ 或 PowerShell 7+
- 可用的 Windows Update 服务（用于查询/隐藏更新）

## 快速用法

进入交互菜单：

```powershell
.\WUSettings.ps1
```

设置“仅通知，不自动下载/安装”（AUOptions=2）：

```powershell
.\WUSettings.ps1 -Block
```

恢复自动更新策略为系统默认：

```powershell
.\WUSettings.ps1 -Restore
```

在“仅通知”和“恢复默认”之间切换：

```powershell
.\WUSettings.ps1 -TogglePush
```

直接进入更新隐藏/恢复界面：

```powershell
.\WUSettings.ps1 -Hide
```

自定义窗口标题：

```powershell
.\WUSettings.ps1 -Title "My Windows Update Policy"
```

## 参数说明

| 参数 | 说明 |
|---|---|
| `-Title` | 控制台标题，默认 `Windows Update Settings` |
| `-Block` | 设置自动更新为 `AUOptions=2`（通知下载和安装） |
| `-Restore` | 删除 `AUOptions` 策略值，恢复系统默认行为 |
| `-TogglePush` | 在 `-Block` 与 `-Restore` 两种状态间切换 |
| `-Hide` | 打开更新列表，勾选后应用隐藏/恢复操作 |

## 交互菜单功能

主菜单包含 3 项：

1. **Auto-Update Policy**：选择自动更新模式  
   - `2` Notify for Download and Install  
   - `3` Auto Download, Notify for Install  
   - `4` Auto Download, Scheduled Install  
   - `5` Allow Local Admin to Choose  
   - `default` Remove Policy / Default
2. **Driver Updates**：切换是否阻止通过 Windows Update 分发驱动
3. **Hide/Restore Updates**：浏览待更新与已隐藏更新，按空格勾选，回车应用

## 脚本会修改的关键策略位置

- `HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU`（`AUOptions`）
- `HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate`（`ExcludeWUDriversInQualityUpdate`）
- `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching`（`SearchOrderConfig`）
- `HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UpdatePolicy\PolicyState`（`ExcludeWUDrivers`）

## 说明

- 脚本在策略变更后会调用 `gpupdate /force /target:computer` 以加快生效。
- 更新隐藏/恢复依赖 `Microsoft.Update.Session` COM 查询结果，通常需要网络连接。
