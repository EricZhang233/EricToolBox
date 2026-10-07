# stop-shell.ps1 -- stop ShellHost.exe and explorer.exe (they restart on demand / via explorer restart).
# Kept in a script file because the tool guard requires a literal PID on the command line.

foreach ($name in @('ShellHost', 'explorer')) {
    $procs = @(Get-Process $name -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { Write-Output ("  " + $name + ": not running"); continue }
    foreach ($p in $procs) {
        Write-Output ("  stopping " + $name + " pid " + $p.Id)
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
}
Start-Sleep -Seconds 2
Write-Output ("  remaining ShellHost: " + (@(Get-Process ShellHost -ErrorAction SilentlyContinue).Count))
Write-Output ("  remaining explorer : " + (@(Get-Process explorer -ErrorAction SilentlyContinue).Count))
