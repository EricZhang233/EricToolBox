param(
    [Alias('Profile')][string]$Config = 'installer.yaml',
    [Parameter(Mandatory)][string]$PayloadPath,
    [string]$DestinationPath,
    [string]$MinizArchive
)
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/Configuration.psm1" -Force
$configuration = Read-InstallerConfig $Config
$settings = $configuration.Settings
$Version = $settings.version
$repo = Join-Path $PSScriptRoot 'native'
$intermediate = Join-Path ([IO.Path]::GetTempPath()) ('EricSoftInstaller-' + [guid]::NewGuid().ToString('N'))
$payload = Get-Item -LiteralPath $PayloadPath
if (-not $DestinationPath) {
    $parent = if ($payload.PSIsContainer) { $payload.Parent.FullName } else { $payload.DirectoryName }
    $name = [IO.Path]::GetFileNameWithoutExtension($settings.mainExecutable)
    $suffix = if ($Version) { "_$Version" } else { '' }
    $DestinationPath = Join-Path $parent "$($name)_Setup$suffix.exe"
}
$destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DestinationPath)
if ($destination -ieq $payload.FullName -or ($payload.PSIsContainer -and
        $destination.StartsWith($payload.FullName.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase))) {
    throw 'The installer destination must be outside the payload.'
}
function Compile([string]$Source, [string]$Name, [string[]]$Extra = @()) {
    $object = Join-Path $intermediate "$Name.obj"
    & cl.exe @common @Extra /c (Join-Path $repo $Source) "/Fo$object" | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Native compilation failed: $Source" }
    return $object
}
function Build-Resource([string]$Name, [string]$Uninstaller) {
    $resource = Join-Path $intermediate "$Name.rc"
    $fileVersion = if (-not $Version) { '0.0.0.0' } elseif ($Version.Split('.').Count -eq 3) { $Version + '.0' } else { $Version }
    $lines = @(
        '#include <windows.h>',
        ('103 RCDATA "' + (Join-Path $thirdParty 'LICENSE').Replace('\', '\\') + '"'),
        ('1 24 "' + (Join-Path $repo 'setup/setup.manifest').Replace('\', '\\') + '"'),
        '1 VERSIONINFO', ('FILEVERSION ' + $fileVersion.Replace('.', ',')), ('PRODUCTVERSION ' + $fileVersion.Replace('.', ',')),
        'FILEOS VOS_NT_WINDOWS32', 'FILETYPE VFT_APP', 'BEGIN', 'BLOCK "StringFileInfo"', 'BEGIN', 'BLOCK "040904B0"', 'BEGIN',
        ('VALUE "FileDescription", "' + $settings.productName + ' ' + $Name + '\0"'),
        ('VALUE "ProductName", "' + $settings.productName + '\0"')
    )
    if ($settings.publisher) { $lines += 'VALUE "CompanyName", "' + $settings.publisher + '\0"' }
    if ($Version) { $lines += ('VALUE "FileVersion", "' + $fileVersion + '\0"'), ('VALUE "ProductVersion", "' + $Version + '\0"') }
    $lines += 'END', 'END', 'BLOCK "VarFileInfo"', 'BEGIN', 'VALUE "Translation", 0x409, 1200', 'END', 'END'
    if ($Uninstaller) { $lines += '102 RCDATA "' + $Uninstaller.Replace('\', '\\') + '"' }
    $baseLines = $lines
    if ($configuration.Icon) { $lines += '100 ICON "' + $configuration.Icon.Replace('\', '\\') + '"' }
    [IO.File]::WriteAllLines($resource, $lines, [Text.UTF8Encoding]::new($false))
    $compiled = Join-Path $intermediate "$Name.res"
    $PSNativeCommandUseErrorActionPreference = $false
    $diagnostics = & rc.exe /nologo /c65001 "/fo$compiled" $resource 2>&1
    if ($LASTEXITCODE -ne 0 -and $configuration.Icon) {
        [IO.File]::WriteAllLines($resource, $baseLines, [Text.UTF8Encoding]::new($false))
        $diagnostics = & rc.exe /nologo /c65001 "/fo$compiled" $resource 2>&1
        if ($LASTEXITCODE -eq 0) { $configuration.Icon = $null }
    }
    $diagnostics | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Native resource compilation failed: $Name" }
    return $compiled
}
function Link([string]$Name, [string[]]$Objects, [string]$Resource) {
    $destination = Join-Path $intermediate "$Name.exe"
    & link.exe /NOLOGO /LTCG /OPT:REF /OPT:ICF /DYNAMICBASE /NXCOMPAT /GUARD:CF "/MACHINE:$($settings.architecture)" /SUBSYSTEM:WINDOWS /MANIFEST:NO "/OUT:$destination" @Objects $Resource kernel32.lib user32.lib gdi32.lib shell32.lib ole32.lib oleaut32.lib advapi32.lib propsys.lib uuid.lib bcrypt.lib comctl32.lib dwmapi.lib uxtheme.lib | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Native link failed: $Name" }
    return $destination
}

New-Item -ItemType Directory -Path $intermediate | Out-Null
try {
    $sourceZip = $payload.FullName
    if ($payload.PSIsContainer) {
        if ($payload.Attributes -band [IO.FileAttributes]::ReparsePoint -or
            (Get-ChildItem -LiteralPath $payload.FullName -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })) {
            throw 'The payload directory contains a reparse point.'
        }
        $sourceZip = Join-Path $intermediate 'payload.zip'
        [IO.Compression.ZipFile]::CreateFromDirectory($payload.FullName, $sourceZip)
    }
    $source = [IO.Compression.ZipFile]::OpenRead($sourceZip)
    try { Assert-PayloadEntries $source.Entries $settings } finally { $source.Dispose() }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    $vcComponent = if ($settings.architecture -eq 'arm64') { 'Microsoft.VisualStudio.Component.VC.Tools.ARM64' } else { 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64' }
    $visualStudio = & $vswhere -latest -products '*' -requires $vcComponent -property installationPath
    if ($LASTEXITCODE -ne 0 -or -not $visualStudio) { throw "Visual C++ $($settings.architecture) build tools are required." }
    Import-Module (Join-Path $visualStudio 'Common7/Tools/Microsoft.VisualStudio.DevShell.dll')
    Enter-VsDevShell -VsInstallPath $visualStudio -SkipAutomaticLocation -DevCmdArguments "-arch=$($settings.architecture) -host_arch=x64" | Out-Null
    $sourceArchive = if ($MinizArchive) { (Get-Item -LiteralPath $MinizArchive).FullName } else { Join-Path $intermediate 'miniz-3.1.2.zip' }
    $sourceHash = 'f0446d863f9c19926ad9483c523fdc42e42b8d4a6a431d27e09d49c79a140d9a'
    if (-not $MinizArchive) {
        Invoke-WebRequest 'https://github.com/richgel999/miniz/releases/download/3.1.2/miniz-3.1.2.zip' -OutFile $sourceArchive -TimeoutSec 60
    }
    if ((Get-FileHash -LiteralPath $sourceArchive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sourceHash) { throw 'miniz source integrity check failed.' }
    $thirdParty = Join-Path $intermediate 'miniz'
    [IO.Compression.ZipFile]::ExtractToDirectory($sourceArchive, $thirdParty)
    $versionHeader = Join-Path $intermediate 'InstallerProfile.h'
    Write-NativeProfile $configuration $versionHeader
    $common = @('/nologo', '/std:c++20', '/O1', '/GL', '/Gy', '/Gw', '/MT', '/EHsc', '/utf-8', '/W4', '/WX', '/DUNICODE', '/D_UNICODE', '/D_WIN32_WINNT=0x0A00', '/DWINVER=0x0A00', '/D_CRT_SECURE_NO_WARNINGS', "/FI$versionHeader", "/I$thirdParty", '/DMINIZ_NO_ARCHIVE_WRITING_APIS', '/DMINIZ_NO_ZLIB_APIS', '/DMINIZ_NO_STDIO')
    $shared = Compile 'setup.core/Installation.cpp' 'Installation'
    $window = Compile 'setup/Window.cpp' 'Window'
    $uninstall = Compile 'setup.core/Uninstaller.cpp' 'Uninstaller'
    $uninstallEntry = Compile 'setup/Entry.cpp' 'UninstallEntry' @('/DSETUP_UNINSTALL')
    $uninstallResource = Build-Resource 'Uninstall' ''
    $uninstallPath = Link 'Uninstall' @($shared, $window, $uninstall, $uninstallEntry) $uninstallResource
    $compression = Join-Path $intermediate 'miniz.obj'
    & cl.exe /nologo /O1 /GL /Gy /Gw /MT /TC /W0 /D_CRT_SECURE_NO_WARNINGS /DMINIZ_NO_ARCHIVE_WRITING_APIS /DMINIZ_NO_ZLIB_APIS /DMINIZ_NO_STDIO /c (Join-Path $thirdParty 'miniz.c') "/Fo$compression"
    if ($LASTEXITCODE -ne 0) { throw 'Native ZIP library compilation failed.' }
    $install = Compile 'setup.core/Installer.cpp' 'Installer'
    $entry = Compile 'setup/Entry.cpp' 'SetupEntry'
    $resource = Build-Resource 'Setup' $uninstallPath
    $installerPath = Link 'Setup' @($shared, $window, $install, $entry, $compression) $resource
    Add-SetupPayload $installerPath $sourceZip $settings
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
    [IO.File]::Move($installerPath, $destination, $true)
    Get-Item -LiteralPath $destination
} finally {
    Remove-BuildWorkspace $intermediate
}
