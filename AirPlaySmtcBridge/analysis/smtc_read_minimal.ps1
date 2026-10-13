# smtc_read.ps1 — minimal SMTC reader that avoids the brittle GetMethods() reflection
# (the workspace smtc-control skill trips over "Operation is not supported" on WinRT projections)
$ErrorActionPreference = 'Continue'
$cache = 'C:\Users\eric\Documents\deepseek-harness\default-workspace\.dsh\cache\smtc'
Add-Type -Path (Join-Path $cache 'WinRT.Runtime.dll')
Add-Type -Path (Join-Path $cache 'Microsoft.Windows.SDK.NET.dll')

function Await-Op($op) {
    $iface = $op.GetType().GetInterfaces() | Where-Object { $_.IsGenericType -and $_.GetGenericTypeDefinition().FullName -like 'Windows.Foundation.IAsyncOperation*' } | Select-Object -First 1
    if (-not $iface) { throw 'not an IAsyncOperation' }
    $limit = (Get-Date).AddSeconds(8)
    while ((Get-Date) -lt $limit) {
        $st = $null
        try { $st = $op.Status } catch { }
        if (-not $st) { $st = $op.GetType().GetProperty('Status').GetValue($op) }
        if ([string]$st -eq 'Completed') { break }
        Start-Sleep -Milliseconds 20
    }
    return $iface.GetMethod('GetResults').Invoke($op, @())
}

$mgr = Await-Op ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync())
$sessions = $mgr.GetSessions()
Write-Output ("sessions: " + $sessions.Count)
foreach ($s in $sessions) {
    $pi = $s.GetPlaybackInfo()
    $tl = $s.GetTimelineProperties()
    $mp = Await-Op ($s.TryGetMediaPropertiesAsync())
    Write-Output ("  app      : " + $s.SourceAppUserModelId)
    Write-Output ("  status   : " + $pi.PlaybackStatus + "   rate=" + $pi.PlaybackRate)
    Write-Output ("  title    : " + $mp.Title)
    Write-Output ("  artist   : " + $mp.Artist + "   album=" + $mp.AlbumTitle)
    Write-Output ("  position : " + $tl.Position.ToString('hh\:mm\:ss\.fff') + "  /  " + $tl.EndTime.ToString('hh\:mm\:ss\.fff') + "   lastUpdated=" + $tl.LastUpdatedTime.ToString('HH:mm:ss'))
    Write-Output ("  thumb    : " + $(if ($mp.Thumbnail) { 'present' } else { 'null' }))
}
