# test-late-inject.ps1 -- answers the product-lifecycle question:
#   "our product does NOT start before explorer -- can we still inject?"
# Sequence: fresh shell -> open the panel FIRST -> inject the launcher LAST -> is the button there?
# This is the opposite order from cycle.ps1 (which injects before the panel is opened).
# Nothing is restarted after the injection.
#
# Target: pwsh 7.

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '_paths.ps1')
$poc  = $PocDir
$pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'

function Invoke-Map {
    param([string]$Tag)
    Write-Output "── $Tag ──"
    & $pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ScriptsDir 'footer-map.ps1') 2>&1 |
        Select-String -Pattern '^\[Footer\]|^\[\] Button|Footer\] Group|TestLink|更多音量设置|not found|PANEL NOT OPEN' |
        ForEach-Object { '   ' + $_.Line }
}

Write-Output "=== 1. fresh shell (no injection yet) ==="
foreach ($name in @('ShellHost', 'explorer')) {
    foreach ($p in @(Get-Process $name -ErrorAction SilentlyContinue)) {
        Write-Output ("   stop " + $name + " pid " + $p.Id)
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
}
Start-Sleep -Seconds 2
Remove-Item (Join-Path $poc 'vcxlaunch.log'), (Join-Path $poc 'vcxtap.log') -ErrorAction SilentlyContinue
Start-Process explorer.exe
Start-Sleep -Seconds 2

$sh = $null
for ($i = 0; $i -lt 200; $i++) {
    $sh = Get-Process ShellHost -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($sh) { break }
    Start-Sleep -Milliseconds 200
}
if (-not $sh) { Write-Output 'ShellHost never appeared'; exit 1 }
Write-Output ("   ShellHost pid " + $sh.Id + " (NOT injected yet)")

Write-Output "=== 2. open the panel BEFORE injecting ==="
& $pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ScriptsDir 'qs-panel-probe.ps1') 2>&1 |
    Select-String -Pattern 'panel hwnd|window band|not open' | ForEach-Object { '   ' + $_.Line }
Start-Sleep -Seconds 3
Invoke-Map 'baseline: shell up, panel OPEN, nothing injected'

Write-Output "=== 3. inject the launcher NOW (panel already open, shell already up) ==="
& (Join-Path $poc 'injector.exe') --dll (Join-Path $poc 'vcxlaunch.dll') | ForEach-Object { '   ' + $_ }
Start-Sleep -Seconds 4
Write-Output '── vcxlaunch.log ──'
if (Test-Path (Join-Path $poc 'vcxlaunch.log')) { Get-Content (Join-Path $poc 'vcxlaunch.log') | ForEach-Object { '   ' + $_ } }
else { Write-Output '   (no vcxlaunch.log -- first-stage injection never ran)' }

Write-Output '── vcxtap.log (last 12) ──'
$tlog = Join-Path $poc 'vcxtap.log'
if (Test-Path $tlog) {
    $fs = [IO.File]::Open($tlog, 'Open', 'Read', 'ReadWrite'); $sr = New-Object IO.StreamReader($fs)
    $t = $sr.ReadToEnd(); $sr.Close(); $fs.Close()
    ($t -split "`r?`n") | Where-Object { $_ -ne '' } | Select-Object -Last 12 | ForEach-Object { '   ' + $_ }
} else { Write-Output '   (no vcxtap.log -- TAP was never loaded)' }

Invoke-Map 'result: after late injection (no restart of anything)'

Write-Output ""
Write-Output "=== 4. now close + reopen the panel (still no injection, TAP is resident) ==="
& $pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ScriptsDir 'qs-panel-probe.ps1') 2>&1 |
    Select-String -Pattern 'panel hwnd|not close|not open' | ForEach-Object { '   ' + $_.Line }
Start-Sleep -Seconds 2
& $pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ScriptsDir 'qs-panel-probe.ps1') 2>&1 |
    Select-String -Pattern 'panel hwnd|not close|not open' | ForEach-Object { '   ' + $_.Line }
Start-Sleep -Seconds 3
Invoke-Map 'result: reopened panel, no re-injection performed'
