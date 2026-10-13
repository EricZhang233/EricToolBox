# build-dotnet-framework-csharp.ps1 — compile with the .NET Framework C# compiler.
# No .NET SDK required: WinRT comes from the OS winmd metadata, so the result is a single
# native Win32 exe (GUI subsystem => no console window) that runs on any Windows 10/11.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$src = Join-Path $root 'AirPlayBridge.cs'
$ico = Join-Path $root 'airplay.ico'
$out = Join-Path $root 'AirPlaySmtcBridge.exe'

$fw = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$wm = Join-Path $env:WINDIR 'System32\WinMetadata'
$csc = Join-Path $fw 'csc.exe'

foreach ($f in @($src, $ico, $csc, (Join-Path $wm 'Windows.Media.winmd'))) {
    if (-not (Test-Path -LiteralPath $f)) { throw "missing build input: $f" }
}

$cscArgs = @(
    '/nologo'
    '/target:winexe'          # GUI subsystem: no console window
    '/platform:x64'
    '/optimize+'
    '/define:NETFRAMEWORK'    # selects the .NET Framework dialect (manual interop + reflection events)
    "/out:$out"
)
if (Test-Path -LiteralPath $ico) { $cscArgs += "/win32icon:$ico" }   # embedded app/taskbar icon
$man = Join-Path $root 'app.manifest'
if (Test-Path -LiteralPath $man) { $cscArgs += "/win32manifest:$man" }  # supportedOS + dpiAware + asInvoker
$cscArgs += @(
    "/r:$wm\Windows.Media.winmd"
    "/r:$wm\Windows.Foundation.winmd"
    "/r:$wm\Windows.Storage.winmd"
    "/r:$fw\System.Runtime.dll"
    "/r:$fw\System.Runtime.WindowsRuntime.dll"
    "/r:$fw\System.Runtime.InteropServices.WindowsRuntime.dll"
    $src
)

& $csc @cscArgs
if ($LASTEXITCODE -ne 0) { throw "compile failed with exit code $LASTEXITCODE" }

$vi = (Get-Item -LiteralPath $out).VersionInfo
Write-Output ("built: {0} ({1} bytes)  FileDescription='{2}'  ProductName='{3}'  Company='{4}'" -f `
    $out, (Get-Item -LiteralPath $out).Length, $vi.FileDescription, $vi.ProductName, $vi.CompanyName)
