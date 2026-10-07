# cycle.ps1 -- one test iteration: stop the shell, build, restart explorer, inject the launcher,
# open the panel, then print the injection log lines and the resulting on-screen geometry.

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '_paths.ps1')
$poc   = $PocDir
$pwsh  = 'C:\Program Files\PowerShell\7\pwsh.exe'

Write-Output "=== 1. stop shell (releases the DLL file locks) ==="
foreach ($name in @('ShellHost', 'explorer')) {
    foreach ($p in @(Get-Process $name -ErrorAction SilentlyContinue)) {
        Write-Output ("  stop " + $name + " pid " + $p.Id)
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
}
Start-Sleep -Seconds 2

Write-Output "=== 2. build ==="
Push-Location $poc
& $env:ComSpec /c "build.cmd > build.out.txt 2>&1" | Out-Null
$rc = $LASTEXITCODE
Pop-Location
if ($rc -ne 0) {
    Write-Output "BUILD FAILED:"
    Get-Content (Join-Path $poc 'build.out.txt') | Select-Object -Last 25
    return
}
Write-Output "  build OK"

Write-Output "=== 3. restart explorer + inject launcher ==="
Remove-Item (Join-Path $poc 'vcxlaunch.log'), (Join-Path $poc 'vcxtap.log') -ErrorAction SilentlyContinue
Start-Process explorer.exe
Start-Sleep -Seconds 2
for ($i = 0; $i -lt 200; $i++) {
    $p = Get-Process ShellHost -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p) {
        Write-Output ("  ShellHost pid " + $p.Id + " -> injecting")
        & (Join-Path $poc 'injector.exe') --dll (Join-Path $poc 'vcxlaunch.dll') | Out-Null
        break
    }
    Start-Sleep -Milliseconds 200
}
Start-Sleep -Seconds 3

Write-Output "=== 4. open the panel ==="
& $pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ScriptsDir 'qs-panel-probe.ps1') 2>&1 |
    Select-String -Pattern 'panel hwnd|window band|not open' | ForEach-Object { $_.Line }
Start-Sleep -Seconds 3

Write-Output "=== 5. injection log ==="
$tlog = Join-Path $poc 'vcxtap.log'
if (Test-Path $tlog) {
    $fs = [IO.File]::Open($tlog, 'Open', 'Read', 'ReadWrite'); $sr = New-Object IO.StreamReader($fs)
    $t = $sr.ReadToEnd(); $sr.Close(); $fs.Close()
    ($t -split "`r?`n") | Select-String -Pattern 'appeared: type|injecting into|up\[|row container|style model|model metrics|height forced|wrapped|appended|TestLink injected|!|align:' |
        ForEach-Object { $_.Line } | Select-Object -Last 24
} else { Write-Output "  (no vcxtap.log)" }

Write-Output "=== 6. on-screen result ==="
& $pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ScriptsDir 'footer-map.ps1') 2>&1 |
    Select-String -Pattern 'Footer|TestLink|更多音量设置' | ForEach-Object { $_.Line }
