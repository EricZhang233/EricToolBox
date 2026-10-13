# seek_matrix.ps1 — which SMTC lever actually flips "position control" off?
$ErrorActionPreference = 'Continue'
$cache = 'C:\Users\eric\Documents\deepseek-harness\default-workspace\.dsh\cache\smtc'
Add-Type -Path (Join-Path $cache 'WinRT.Runtime.dll')
Add-Type -Path (Join-Path $cache 'Microsoft.Windows.SDK.NET.dll')
Add-Type @'
using System;using System.Runtime.InteropServices;
public class SeekWin32 {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr CreateWindowExW(uint e,string c,string n,uint s,int x,int y,int w,int h,IntPtr p,IntPtr m,IntPtr i,IntPtr l);
    [DllImport("user32.dll")] public static extern bool DestroyWindow(IntPtr h);
}
'@

# full member dump so we do not miss a setter
$asm = [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'Microsoft.Windows.SDK.NET' }
try { $types = $asm.GetTypes() } catch { $types = $_.Exception.Types | Where-Object { $_ } }
foreach ($tn in 'Windows.Media.ISystemMediaTransportControls2','Windows.Media.ISystemMediaTransportControls') {
    $t = $types | Where-Object { $_.FullName -eq $tn }
    if ($t) {
        Write-Output "=== $tn members ==="
        $t.GetMembers() | ForEach-Object { $_.Name } | Sort-Object -Unique | ForEach-Object { "   $_" }
    }
}

$reader = Join-Path $env:TEMP 'airplay-capture\smtc_read.ps1'

function Test-Variant([string]$label, [bool]$ff, [bool]$rew, [double]$end, [double]$maxSeek, [bool]$useRate) {
    $h = [SeekWin32]::CreateWindowExW(0,'STATIC','SeekMatrix',0,0,0,0,0,[IntPtr]::Zero,[IntPtr]::Zero,[IntPtr]::Zero,[IntPtr]::Zero)
    $s = [Windows.Media.SystemMediaTransportControlsInterop]::GetForWindow($h)
    $s.IsEnabled = $true
    $s.IsPlayEnabled = $true; $s.IsPauseEnabled = $true; $s.IsNextEnabled = $true; $s.IsPreviousEnabled = $true
    $s.IsFastForwardEnabled = $ff; $s.IsRewindEnabled = $rew
    if ($useRate) { try { $s.PlaybackRate = 1.0 } catch { } }
    $s.PlaybackStatus = [Windows.Media.MediaPlaybackStatus]::Playing
    $u = $s.DisplayUpdater
    $u.Type = [Windows.Media.MediaPlaybackType]::Music
    $u.MusicProperties.Title = "SEEKTEST $label"
    $u.Update()
    $tl = [Windows.Media.SystemMediaTransportControlsTimelineProperties]::new()
    $tl.StartTime = [TimeSpan]::Zero
    $tl.EndTime = [TimeSpan]::FromSeconds($end)
    $tl.Position = [TimeSpan]::FromSeconds(30)
    $tl.MinSeekTime = [TimeSpan]::Zero
    $tl.MaxSeekTime = [TimeSpan]::FromSeconds($maxSeek)
    $s.UpdateTimelineProperties($tl)
    Start-Sleep -Seconds 2
    $out = & pwsh -NoProfile -ExecutionPolicy Bypass -File $reader 2>&1
    $mine = $out | Select-String -Pattern 'SEEKTEST' -Context 0,4
    $flag = ($out | Select-String -Pattern 'posControlEnabled=' | Select-Object -First 1).Line
    Write-Output ("[{0}] ff={1} rew={2} end={3} maxSeek={4} rate={5}  ->  {6}" -f $label, $ff, $rew, $end, $maxSeek, $useRate, ($flag -replace '.*posControlEnabled=', 'posControlEnabled='))
    $s.IsEnabled = $false
    [void][SeekWin32]::DestroyWindow($h)
    Start-Sleep -Milliseconds 600
}

Test-Variant 'A_end+maxFFon'   $true  $true  241 241 $true
Test-Variant 'B_end+max0'      $true  $true  241   0 $true
Test-Variant 'C_end+max0+ffoff' $false $false 241   0 $true
Test-Variant 'D_end+maxFFoff'  $false $false 241 241 $true
Test-Variant 'E_noend'         $true  $true    0   0 $true
Test-Variant 'F_norate'        $true  $true  241   0 $false
