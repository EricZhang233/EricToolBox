# EricNotificationToolkit

## 中文

`EricNotificationToolkit.ps1` 用于显示 Windows 托盘通知，无需安装应用，也不需要管理员权限。

### 一行复制模板

```powershell
.\EricNotificationToolkit.ps1 -Head '' -Title '' -Body '' -Image 0
```

### 功能

- 使用 .NET Framework 自带的 C# 编译器构建通知宿主。
- 将 C# 宿主源码直接嵌入 PowerShell 脚本。
- 每次调用都重新编译宿主，因此通知名称可以动态变化。
- 所有编译产物都放在 `%TEMP%\eric\EricNotificationToolkit\` 临时目录中。
- 启动通知宿主后，入口脚本立即返回。
- 通知发出后，注册清理在 1 秒后执行，宿主程序在同一时刻开始固定存活 15 秒。
- 宿主退出后由隐藏的 PowerShell 进程执行清理。
- 清理当前通知名称对应的通知注册记录。
- 正常发送通知时不输出控制台内容。
- 错误命令和缺少必填参数时显示英文帮助。

### 文件

```text
EricNotificationToolkit\
  EricNotificationToolkit.ps1  入口脚本和内嵌的通知宿主
  README.md                    项目说明
  example-body.txt             正文示例
```

### 用法

显示帮助：

```powershell
.\EricNotificationToolkit.ps1 -Help
```

显示通知：

```powershell
.\EricNotificationToolkit.ps1 `
    -Head 'EricNotificationToolkit - 构建完成' `
    -Body '构建通过</p>程序：pwsh.exe'
```

显示标题和系统图标：

```powershell
.\EricNotificationToolkit.ps1 `
    -Head 'EricNotificationToolkit - 构建完成' `
    -Title 'CI' `
    -Body '构建通过</p>耗时：12 秒' `
    -Image info
```

从文件读取正文：

```powershell
$body = ((Get-Content .\example-body.txt) |
    Where-Object { $_.Trim() }) -join '</p>'

.\EricNotificationToolkit.ps1 `
    -Head 'EricNotificationToolkit - 报告' `
    -Body $body
```

### 参数

| 参数 | 默认值 | 说明 |
|---|---|---|
| `-Head` | `EricNotificationToolkit` | 通知名称行，会被编译进程序集身份。 |
| `-Title` | 空 | 可选的内容标题行。 |
| `-Body` | 必填 | 通知正文，使用 `</p>` 分隔多行。 |
| `-Image` | 空 | `info`、`warning` 或 `error` 显示系统图标；空值或 `0` 不显示图标。 |
| `-Help` | 关闭 | 显示帮助并退出，不发送通知。 |

宿主程序固定在 15 秒后退出。该时长写死在内嵌 C# 源码中，不能通过 PowerShell 参数修改。

### 错误行为

正常发送通知时保持静默。如果缺少 `-Body`、`-Image` 值无效，或发生其他脚本错误，脚本会显示英文帮助并以退出码 `1` 退出。

显式执行 `-Help` 时显示相同帮助，并以退出码 `0` 退出。

### 清理行为

通知发出约 1000 毫秒后，隐藏的 PowerShell 进程会先清理通知注册；宿主退出后再删除临时编译目录。具体步骤为：

1. 删除 `DisplayName` 与当前 `-Head` 相同的 `NotifyIconGeneratedAumid_*` 项。
2. 删除以下通知设置目录中的同名项目：

   ```text
   HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings
   HKCU\Software\Microsoft\Windows\CurrentVersion\PushNotifications\Backup
   ```

3. 删除临时编译目录。

清理范围仅限于当前调用对应的通知注册记录。

### 系统要求

- Windows 10 或 Windows 11。
- PowerShell 7（`pwsh`）。
- .NET Framework 4.x 和 `csc.exe`。

不需要 .NET SDK、NuGet、Visual Studio、VC++ 运行库、安装程序或管理员权限。

### 限制

- 不支持外部图片文件，只支持 `info`、`warning` 和 `error` 三种系统图标。
- Windows 决定通知气泡实际显示多久；宿主进程会保持 15 秒，避免通知因宿主立即退出而消失。
- Windows 可能在通知显示期间重新生成通知元数据，宿主退出后会清理匹配项目。
- AppLocker 或 WDAC 等安全策略可能阻止从临时目录编译或执行程序。

---

## English

`EricNotificationToolkit.ps1` displays a Windows tray notification without installing an application or requiring administrator privileges.

### Copyable one-line template

```powershell
.\EricNotificationToolkit.ps1 -Head '' -Title '' -Body '' -Image 0
```

### Features

- Builds the notification host with the C# compiler included with .NET Framework.
- Embeds the C# host source directly in the PowerShell script.
- Compiles a fresh host for every invocation so the notification name can change.
- Uses only a temporary directory under `%TEMP%\eric\EricNotificationToolkit\`.
- Returns immediately after starting the notification host.
- Starts one-second registration cleanup and the fixed 15-second host lifetime from the same notification signal.
- Performs cleanup in a hidden PowerShell process after the host exits.
- Removes notification registrations associated with the current notification name.
- Produces no console output during normal notification execution.
- Redirects invalid commands and missing required arguments to the English help text.

### Files

```text
EricNotificationToolkit\
  EricNotificationToolkit.ps1  Entry point and embedded notification host
  README.md                    Project documentation
  example-body.txt             Example body content
```

### Usage

Show help:

```powershell
.\EricNotificationToolkit.ps1 -Help
```

Display a notification:

```powershell
.\EricNotificationToolkit.ps1 `
    -Head 'EricNotificationToolkit - Build complete' `
    -Body 'Build passed</p>Program: pwsh.exe'
```

Display a title and system icon:

```powershell
.\EricNotificationToolkit.ps1 `
    -Head 'EricNotificationToolkit - Build complete' `
    -Title 'CI' `
    -Body 'Build passed</p>Duration: 12 seconds' `
    -Image info
```

Read the body from a file:

```powershell
$body = ((Get-Content .\example-body.txt) |
    Where-Object { $_.Trim() }) -join '</p>'

.\EricNotificationToolkit.ps1 `
    -Head 'EricNotificationToolkit - Report' `
    -Body $body
```

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `-Head` | `EricNotificationToolkit` | Notification name line. It is compiled into the assembly identity. |
| `-Title` | Empty | Optional content title line. |
| `-Body` | Required | Notification body. Use `</p>` to separate lines. |
| `-Image` | Empty | `info`, `warning`, or `error` selects a system icon. Empty or `0` hides the icon. |
| `-Help` | Off | Displays the help text and exits without sending a notification. |

The notification host always exits after 15 seconds. This duration is fixed in the embedded C# source and cannot be changed through PowerShell parameters.

### Error behavior

Normal notification execution is silent. If `-Body` is missing, `-Image` is invalid, or another script error occurs, the script prints the English help text and exits with code `1`.

The explicit `-Help` command prints the same help text and exits with code `0`.

### Cleanup behavior

About 1000 milliseconds after the notification is sent, a hidden PowerShell process first cleans the notification registrations. After the host exits, it deletes the temporary build directory. The steps are:

1. Removes generated `NotifyIconGeneratedAumid_*` entries whose display name matches the current `-Head` value.
2. Removes matching entries from:

   ```text
   HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings
   HKCU\Software\Microsoft\Windows\CurrentVersion\PushNotifications\Backup
   ```

3. Deletes the temporary build directory.

Cleanup is limited to notification registrations associated with the current invocation.

### Requirements

- Windows 10 or Windows 11.
- PowerShell 7 (`pwsh`).
- .NET Framework 4.x with `csc.exe`.

The script does not require the .NET SDK, NuGet, Visual Studio, VC++ runtimes, an installer, or administrator privileges.

### Limitations

- External image files are not supported. Only the system icons `info`, `warning`, and `error` are supported.
- Windows controls the exact visual duration of the balloon notification. The host process remains alive for 15 seconds so the notification is not destroyed immediately.
- Windows may recreate notification metadata while the notification is being displayed. The cleanup process removes the matching entries after the host exits.
- AppLocker or WDAC policies may block compiling or executing a temporary executable.
