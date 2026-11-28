# EricSoftInstaller

从 EricGameLauncher 提取的 Windows 安装器源码模板。一个 Setup EXE 提供图形和静默安装、原地升级及可选的只解压模式。安装时会生成配套卸载器，并登记到 Windows 的已安装应用列表。

## 接入和打包

1. 将本目录复制到宿主项目。直接编辑 [installer.yaml](installer.yaml) 中的 `productName`、`productId` 和 `mainExecutable` 三个必填项。为产品使用稳定且唯一的 `productId`、主程序文件名和快捷方式名称。主程序文件名也用作 Windows App Paths 的登记名称。可选字段的格式和默认值见 YAML 内的注释。`publisher` 和 `version` 为空或无效时，安装界面隐藏对应信息。
2. 准备应用的完整运行产物，例如 `dist\app`。将主程序及需要等待退出的辅助程序放在载荷根目录。使用 ZIP 时，主程序必须位于 ZIP 根目录。`requiredPayloadFiles` 可补充构建时检查的必需文件。`excludedPayloadPatterns` 拒绝含有匹配项的载荷，请在应用打包步骤先清理这些文件。载荷上限为 100,000 个 ZIP 条目、单文件 4 GiB、解压后总计 8 GiB。
3. 在安装器模板目录用 PowerShell 7 运行构建。构建机需要 Visual Studio 的 C++ 构建工具和 Windows SDK。按 `architecture` 安装相应的 x64、x86 或 ARM64 C++ 工具链，并提供对应架构的应用载荷。Setup 和卸载器是原生 Windows 程序。

```powershell
pwsh -NoProfile -File .\build-setup.ps1 -PayloadPath .\dist\app
```

默认在载荷旁生成 `<主程序名>_Setup_<版本>.exe`。没有有效版本时文件名为 `<主程序名>_Setup.exe`。`-Config` 可以指定 YAML 文件，`-DestinationPath` 可以指定目标 EXE，目标须在载荷之外。`icon` 的相对路径以 YAML 文件所在目录为基准。

构建脚本会校验两个固定版本的依赖包摘要。离线构建时用 `-MinizArchive` 指向原始的 `miniz-3.1.2.zip`，并将 `yamldotnet.18.1.0.nupkg` 放在 NuGet 缓存下的 `yamldotnet\18.1.0\` 中。缓存根目录取 `$env:NUGET_PACKAGES`，默认是用户目录下的 `.nuget\packages\`。YamlDotNet 只在构建时解析配置。[miniz 3.1.2](https://github.com/richgel999/miniz/releases/tag/3.1.2) · [YamlDotNet 18.1.0](https://www.nuget.org/packages/YamlDotNet/18.1.0)

## 路径、范围与数据

`defaultInstallSubdirectory` 的前缀在打包时决定安装范围。放在前缀后的子路径会完整用于默认目录。仅填写前缀时，`<应用目录名>` 来自 `installDirectoryName`，留空则取 `productId`。

| 路径前缀 | 只写前缀时的默认目录 | 登记和快捷方式 |
| --- | --- | --- |
| `\AppData\` | `%LocalAppData%\Programs\<应用目录名>` | 当前用户的 `HKCU`、桌面和开始菜单 |
| `\ProgramFiles\` | 对应架构的 `Program Files\<应用目录名>` | `HKLM`、公共桌面和公共开始菜单 |

例如 `\AppData\Vendor\MyApp` 对应 `%LocalAppData%\Vendor\MyApp`。手动选择或通过 `--directory` 指定安装或解压位置时，Setup 通常会补齐 `installDirectoryName`。传入配置的完整默认目录或以该目录名结尾的路径时直接使用。已登记的升级沿用登记目录。整机安装、升级和卸载需要管理员权限，静默调用也可能触发 UAC。发布更新时应沿用同一安装范围。[Windows 安装上下文](https://learn.microsoft.com/en-us/windows/win32/msi/installation-context)

应用数据由宿主创建。`dataSubdirectory` 指向 `%ProgramData%` 下本产品专用的目录，默认采用 `productId`。两种安装范围共用此规则，卸载时可保留或删除该目录。`protectedPaths` 列出安装根目录下要保留的文件或目录名，这些名称也会在打包时禁止写入载荷。安装或升级遇到未登记为应用文件的同名文件时会报错，以保留现有文件。

## 调用 Setup

| 参数 | 用途 |
| --- | --- |
| `--quiet` | 静默执行。单独使用时，如此范围内已有安装，会进入升级。 |
| `--directory <路径>` | 指定安装或解压目标。与 `--update` 一起使用时，应传已登记的完整安装目录。 |
| `--update` | 静默升级同产品的已登记安装。缺少登记或路径不匹配时失败。 |
| `--sha256 <摘要>` | 在部署前校验整个 Setup EXE。接受 64 位十六进制，可带 `sha256:` 前缀。 |
| `--desktop` / `--no-desktop` | 新安装时指定是否创建桌面快捷方式。 |
| `--start-menu` / `--no-start-menu` | 新安装时指定是否创建开始菜单快捷方式。 |
| `--extract` | 只解压载荷文件，可配合 `--quiet` 执行。 |
| `--help` | 在控制台显示帮助。 |

Setup 退出码 `0` 表示操作成功，`1` 表示参数、路径、权限或部署失败，`2` 表示 SHA-256 格式错误或不匹配。需要等待结果的 PowerShell 调用可使用 `Start-Process -Wait -PassThru` 并读取 `ExitCode`。

`allowExtract` 控制图形界面、帮助和 CLI 的解压能力，默认开启。设为 `false` 后，传入 `--extract` 返回 `1`。解压只释放应用载荷，须选择独立目录，已有安装目录会被拒绝。重新解压到独立目录时，同名载荷文件会被替换。

## 接入应用内更新

宿主负责发现版本、准备本地 Setup EXE，并用可信来源提供的 SHA-256 摘要校验文件。宿主保存状态后启动 Setup 并退出，把部署交给安装器。相同摘要可以通过命令行传给 Setup，由 Setup 再校验一次。

```powershell
# $setupPath、$installPath 和 $expectedSha256 由宿主提供。
$arguments = '--quiet --update --directory "{0}" --sha256 {1}' -f $installPath, $expectedSha256
Start-Process -FilePath $setupPath -ArgumentList $arguments
```

如需由 Setup 启动新版主程序，在新安装包的 YAML 中设 `restartAfterInstall: true`。该设置适用于成功的静默安装和升级。启动失败会写日志，安装结果仍为成功。

替换文件前，Setup 会等待安装目录内的应用进程退出。可选的 `shutdownPipeName` 和 `shutdownPipeCommand` 用于向主程序发送 UTF-8 关停命令。校验和通过 `--sha256` 传入，关停管道只用于请求退出。

## 卸载、语言与日志

在 Windows 的已安装应用列表启动卸载，也可直接运行安装目录内的 `uninstallerName`（默认 `Uninstall.exe`）。静默卸载必须从 `--keep-data`、`--remove-data` 中选一个。图形卸载的默认数据选项由 `defaultKeepData` 控制。

```powershell
Start-Process -FilePath 'C:\Apps\MyApp\Uninstall.exe' -ArgumentList '--quiet --keep-data'
```

原卸载器启动临时工作进程后退出。自动化应确认已安装应用登记和应用入口文件均已移除，并在日志中核对完成状态。原进程的成功退出码只表示交接成功。

Setup 和卸载器内置语言匹配。它们按 Windows 界面语言选取 `text` 中的语言块，依次匹配完整语言、同语种和英语。字段省略、为空或格式无效时，对应文案不显示。配置中的 `{product}` 和 `{publisher}` 会替换为产品信息。

日志位于系统临时目录的 `<tempSubdirectory>\setup\<进程 ID>.log`，例如 `%TEMP%\EricSoftInstaller\<产品 ID>\setup\`。有 UAC 提权时，相关日志可能位于管理员账户的临时目录。排查升级失败时一并保存 Setup 退出码、目标目录和日志。

## 交付前验证

- 在目标 Windows 版本和架构上，用实际载荷测试首次安装、升级、卸载、快捷方式和已安装应用登记。当前整机卸载的提权工作进程位于用户临时目录。正式提供整机选项前，须将提权入口和工作进程移到受保护的位置，并验证标准账户的 UAC、共享快捷方式和 `HKLM` 登记。
- 验证应用退出和可选重启，并分别用正确、错误的摘要调用 Setup。若对 Setup 做了签名或其他后处理，对最终 EXE 重新生成摘要并复跑部署。
- 验证解压开关的图形和命令行行为，以及卸载时保留和删除数据的结果。将测试数据放在专用目录。
- 保留本模板的 [GPL-3.0 许可证](LICENSE) 和[来源记录](https://github.com/EricZhang233/EricGameLauncher/tree/a271085906ae47727f862df52fbffda71106248b)。Setup 的 miniz 许可随 EXE 资源嵌入。分发 Setup 二进制时，按随附许可证第 6 节提供相应源码，并保留构建所用的配置、脚本和修改。
