# run-diagnostics.ps1 -- clean slate: restart the shell, inject vcxlaunch.dll as early as possible.
# After this, open the panel once (qs-panel-probe.ps1) and check vcxtap.log / the UI.

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '_paths.ps1')
$poc = $PocDir
$dll = Join-Path $poc 'vcxlaunch.dll'
$inj = Join-Path $poc 'injector.exe'

Write-Output "=== 1. stop shell ==="
foreach ($name in @('ShellHost', 'explorer')) {
    foreach ($p in @(Get-Process $name -ErrorAction SilentlyContinue)) {
        Write-Output ("  stop " + $name + " pid " + $p.Id)
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
}
Start-Sleep -Seconds 3

Write-Output "=== 2. start explorer ==="
Start-Process explorer.exe
Start-Sleep -Seconds 2
Write-Output ("  explorer: " + (@(Get-Process explorer -ErrorAction SilentlyContinue | ForEach-Object { $_.Id }) -join ', '))

Write-Output "=== 3. wait for ShellHost.exe and inject vcxlaunch.dll ==="
$sw = [Diagnostics.Stopwatch]::StartNew()
for ($i = 0; $i -lt 200; $i++) {
    $p = Get-Process ShellHost -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p) {
        Write-Output ("  ShellHost pid " + $p.Id + " after " + $sw.ElapsedMilliseconds + " ms -> injecting")
        & $inj --dll $dll
        break
    }
    Start-Sleep -Milliseconds 200
}
Start-Sleep -Seconds 4
Write-Output ("  ShellHost now: " + (@(Get-Process ShellHost -ErrorAction SilentlyContinue | ForEach-Object { $_.Id }) -join ', '))
