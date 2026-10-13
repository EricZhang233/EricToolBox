# auto_ctl_v2.ps1 — no human steps:
#   1) start bridge  2) synthesize ONE media key (expect pause)  3) verify PC timeline freezes
#   4) explicitly send DACP play to restore  5) verify Playing again  6) stop bridge
$ErrorActionPreference = 'Continue'
$src = Join-Path $env:TEMP 'airplay-capture\AirPlayBridge.ps1'
$dst = 'C:\Users\eric\Documents\DSH\AirPlayBridge\AirPlayBridge.ps1'
Copy-Item $src $dst -Force
$err = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($dst, [ref]$null, [ref]$err)
if ($err -and $err.Count) { Write-Output ("SYNTAX ERROR: " + $err[0].Message); exit 1 }
Write-Output 'syntax OK'

$log = Join-Path $env:TEMP 'airplay-capture\bridge_v2.out'
$errf = Join-Path $env:TEMP 'airplay-capture\bridge_v2.err'
Remove-Item $log, $errf -Force -ErrorAction SilentlyContinue
$p = Start-Process -FilePath 'pwsh' -PassThru -WindowStyle Hidden `
    -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $dst, '-Verbose' `
    -RedirectStandardOutput $log -RedirectStandardError $errf
Write-Output "bridge pid=$($p.Id)"
Start-Sleep -Seconds 20

Add-Type @'
using System;using System.Runtime.InteropServices;
public class Mk2 { [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
  public static void Tap(byte vk){ keybd_event(vk,0,0x0001,IntPtr.Zero); System.Threading.Thread.Sleep(70); keybd_event(vk,0,0x0001|0x0002,IntPtr.Zero); } }
'@
Write-Output '--- tapping VK_MEDIA_PLAY_PAUSE (0xB3) once ---'
[Mk2]::Tap(0xB3)
Start-Sleep -Seconds 8
Write-Output '--- bridge state after tap ---'
Get-Content $log -Encoding utf8 -EA SilentlyContinue | Select-String -Pattern 'audio .*pkt/s|control:|Active-Remote|timeline frozen|stats:' | Select-Object -Last 8 | ForEach-Object { $_.Line }

# restore with an explicit DACP play (do not rely on the media key toggle)
$cached = (Get-Content (Join-Path $env:TEMP 'AirPlayBridge\dacp.txt') -Raw -EA SilentlyContinue).Trim()
$ip, $port = $cached.Split(':')
Write-Output "--- explicit DACP play -> ${ip}:${port} ---"
try {
    $c = New-Object System.Net.Sockets.TcpClient
    $iar = $c.BeginConnect($ip, [int]$port, $null, $null); [void]$iar.AsyncWaitHandle.WaitOne(2500); $c.EndConnect($iar)
    $req = "GET /ctrl-int/1/play HTTP/1.1`r`nHost: ${ip}:${port}`r`nActive-Remote: 4292676759`r`n`r`n"
    $b = [Text.Encoding]::ASCII.GetBytes($req); $s = $c.GetStream(); $s.Write($b,0,$b.Length); $s.Flush()
    Start-Sleep -Milliseconds 400
    $buf = New-Object byte[] 256; $n = 0; try { $n = $s.Read($buf,0,256) } catch {}
    Write-Output ("  play -> " + ([Text.Encoding]::ASCII.GetString($buf,0,$n).Split("`r`n")[0]))
    $c.Close()
} catch { Write-Output ("  play EXC: " + $_.Exception.Message) }
Start-Sleep -Seconds 8
Write-Output '--- bridge state after restore ---'
Get-Content $log -Encoding utf8 -EA SilentlyContinue | Select-String -Pattern 'audio .*pkt/s|control:|stats:' | Select-Object -Last 6 | ForEach-Object { $_.Line }
Write-Output ''
Write-Output '=========== stderr ==========='
Get-Content $errf -Encoding utf8 -EA SilentlyContinue | Select-Object -First 6
Stop-Process -Id $p.Id -Force -EA SilentlyContinue
Write-Output '--- bridge stopped ---'
