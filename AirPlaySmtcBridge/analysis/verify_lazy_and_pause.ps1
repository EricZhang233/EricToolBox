# verify_lazy.ps1 — automated check of the two design changes:
#   1) SMTC session must NOT exist before real AirPlay data, must exist after
#   2) playback state must follow the iPhone's own timeline reports (pause/resume)
$ErrorActionPreference = 'Continue'
$dst = 'C:\Users\eric\Documents\DSH\AirPlayBridge\AirPlayBridge.ps1'
Copy-Item (Join-Path $env:TEMP 'airplay-capture\AirPlayBridge.ps1') $dst -Force
$err = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($dst, [ref]$null, [ref]$err)
if ($err -and $err.Count) { Write-Output ("SYNTAX ERROR: " + $err[0].Message); exit 1 }
Write-Output 'syntax OK'

$read = Join-Path $env:TEMP 'airplay-capture\smtc_read.ps1'
function Read-Smtc([string]$tag) {
    Write-Output "--- $tag ---"
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $read 2>&1 | Select-String -Pattern 'sessions:|status|title|position' | ForEach-Object { '   ' + $_.Line }
}
$cached = (Get-Content (Join-Path $env:TEMP 'AirPlayBridge\dacp.txt') -Raw -EA SilentlyContinue).Trim()
$ip, $port = $cached.Split(':')
function Send-Dacp([string]$cmd) {
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $iar = $c.BeginConnect($ip, [int]$port, $null, $null); [void]$iar.AsyncWaitHandle.WaitOne(2500); $c.EndConnect($iar)
        $req = "GET /ctrl-int/1/$cmd HTTP/1.1`r`nHost: ${ip}:${port}`r`nActive-Remote: 4292676759`r`n`r`n"
        $b = [Text.Encoding]::ASCII.GetBytes($req); $s = $c.GetStream(); $s.Write($b,0,$b.Length); $s.Flush()
        Start-Sleep -Milliseconds 400
        $buf = New-Object byte[] 256; $n = 0; try { $n = $s.Read($buf,0,256) } catch {}
        $line = [Text.Encoding]::ASCII.GetString($buf,0,$n).Split("`r`n")[0]; $c.Close(); return $line
    } catch { return "EXC $($_.Exception.Message)" }
}

$log = Join-Path $env:TEMP 'airplay-capture\bridge_lazy.out'
Remove-Item $log -Force -EA SilentlyContinue
$p = Start-Process -FilePath 'pwsh' -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$dst,'-Verbose' -RedirectStandardOutput $log -RedirectStandardError (Join-Path $env:TEMP 'airplay-capture\bridge_lazy.err')
Write-Output "bridge pid=$($p.Id)"

Start-Sleep -Seconds 3
Read-Smtc 't=3s  期望 0 个会话（还没注册，不该出现 waiting 卡片）'
Start-Sleep -Seconds 16
Read-Smtc 't=19s 期望 1 个会话 + 真实标题/歌手'

Write-Output ("--- 通过 DACP 暂停: " + (Send-Dacp 'pause') + " ---")
Start-Sleep -Seconds 15
Read-Smtc '暂停后 15s 期望 status=Paused（靠 iPhone 不再上报时间轴判定）'

Write-Output ("--- 通过 DACP 恢复: " + (Send-Dacp 'play') + " ---")
Start-Sleep -Seconds 14
Read-Smtc '恢复后 14s 期望 status=Playing'

Write-Output '--- 桥日志关键行 ---'
Get-Content $log -Encoding utf8 -EA SilentlyContinue | Select-String -Pattern 'SMTC session registered|metadata cached|state ->|Active-Remote|stats:' | Select-Object -Last 12 | ForEach-Object { '   ' + $_.Line }

Stop-Process -Id $p.Id -Force -EA SilentlyContinue
Start-Sleep -Seconds 3
Read-Smtc '停桥后 期望 0 个会话（注销）'
