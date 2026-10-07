# restart-and-inject.ps1 -- restart the shell so our hook is in place BEFORE the Quick Settings
# panel is created for the first time, then inject as early as possible.
#
# Why: with the previous injections the panel had already been created at least once in that
# ShellHost process, so we could not tell "the shell never uses IActivationFactory" apart from
# "the shell used it once, before we were loaded".
#
# ASCII-only.

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '_paths.ps1')
$poc = $PocDir
$dll = Join-Path $poc 'vcxmix7.dll'
$inj = Join-Path $poc 'injector.exe'

Write-Output "=== 1. stopping shell ==="
foreach ($n in @('ShellHost', 'explorer')) {
    $procs = @(Get-Process $n -ErrorAction SilentlyContinue)
    foreach ($p in $procs) {
        Write-Output ("  stopping " + $n + " pid " + $p.Id)
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
}
Start-Sleep -Seconds 3

Write-Output "=== 2. starting explorer ==="
Start-Process explorer.exe
Start-Sleep -Seconds 2
Write-Output ("  explorer pids: " + (@(Get-Process explorer -ErrorAction SilentlyContinue | ForEach-Object { $_.Id }) -join ', '))
Write-Output ("  ShellHost pids: " + (@(Get-Process ShellHost -ErrorAction SilentlyContinue | ForEach-Object { $_.Id }) -join ', '))

Write-Output "=== 3. waiting for ShellHost.exe and injecting the moment it appears ==="
$sw = [Diagnostics.Stopwatch]::StartNew()
$injected = $false
for ($i = 0; $i -lt 160; $i++) {
    $p = Get-Process ShellHost -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p) {
        Write-Output ("  ShellHost pid " + $p.Id + " appeared after " + $sw.ElapsedMilliseconds + " ms -> injecting NOW")
        & $inj --dll $dll
        $injected = $true
        break
    }
    Start-Sleep -Milliseconds 200
}
if (-not $injected) {
    Write-Output "  ShellHost.exe never appeared on its own within 32 s."
    Write-Output "  (it is probably started on demand when the panel is first opened)"
}
Write-Output ("elapsed total: " + $sw.ElapsedMilliseconds + " ms")
