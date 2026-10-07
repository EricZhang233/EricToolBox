# parse-tree.ps1 -- rebuild the element hierarchy from the TAP log and print ancestries.
# Usage: pwsh -File parse-tree.ps1 [-Handles 0A1B,0C2D] [-Log <path>]
#
# 日志来源：优先 PoC 目录下的活日志（vcxtap.log），没有就退回冻结快照
#   docs/verified-after-injection/03-tap-injection-full.log
# Handles 省略时自动取日志里最后一个 name=[Footer] 元素的句柄。

param(
    [string[]]$Handles = @(),
    [string]$Log = ''
)

. (Join-Path $PSScriptRoot '_paths.ps1')
if (-not $Log) {
    $candWorkspace = Join-Path $PocDir 'vcxtap.log'
    $candSnapshot  = Join-Path (Split-Path -Parent $PocDir) 'verified-after-injection\03-tap-injection-full.log'
    $Log = if (Test-Path $candWorkspace) { $candWorkspace }
           elseif (Test-Path $candSnapshot) { $candSnapshot }
           else { $candWorkspace }
}
if (-not (Test-Path $Log)) { Write-Output ("log not found: " + $Log); exit 1 }
Write-Output ("log = " + $Log)

$fs = [IO.File]::Open($Log, 'Open', 'Read', 'ReadWrite')
$sr = New-Object IO.StreamReader($fs)
$text = $sr.ReadToEnd()
$sr.Close(); $fs.Close()

# handle -> @{ parent; type; name; idx }
$info = @{}
foreach ($line in ($text -split "`r?`n")) {
    if ($line -match 'ADD\s+parent=([0-9A-Fa-f]+)\s+idx=(\d+)\s+handle=([0-9A-Fa-f]+)\s+type=\[([^\]]*)\]\s+name=\[([^\]]*)\]') {
        $h = $matches[3].ToUpper()
        $info[$h] = [pscustomobject]@{
            parent = $matches[1].ToUpper()
            idx    = [int]$matches[2]
            type   = $matches[4]
            name   = $matches[5]
        }
    }
}
Write-Output ("parsed " + $info.Count + " elements")

# Handles 省略时：自动取最后一个 name=[Footer] 的句柄，以及它的第一个子元素
if (-not $Handles -or $Handles.Count -eq 0) {
    $footer = $info.Keys | Where-Object { $info[$_].name -eq 'Footer' }
    if (-not $footer) { Write-Output 'no element named [Footer] in this log'; exit 0 }
    # 取日志里最后一次出现的那个（面板每次打开都重建元素，句柄会变）
    $Handles = @($footer | Select-Object -Last 1)
    Write-Output ("auto handle: " + $Handles[0])
}

function Show-Chain($start) {
    Write-Output ""
    Write-Output ("=== ancestry of " + $start + " ===")
    $cur = $start
    $depth = 0
    while ($cur -and $cur -ne '0' -and $depth -lt 25) {
        $e = $info[$cur]
        if (-not $e) { Write-Output ("  " + ('  ' * $depth) + $cur + "  (unknown)"); break }
        $short = $e.type -replace '^Windows\.UI\.Xaml\.', ''
        Write-Output ("  " + ('  ' * $depth) + $cur + "  [" + $e.name + "]  " + $short + "  (idx " + $e.idx + ")")
        $cur = $e.parent
        $depth++
    }
}

foreach ($h in $Handles) { Show-Chain $h.ToUpper() }

# children of an element
function Show-Children($h) {
    Write-Output ""
    Write-Output ("=== children of " + $h + " ===")
    $kids = $info.Keys | Where-Object { $info[$_].parent -eq $h } | Sort-Object { $info[$_].idx }
    foreach ($k in $kids) {
        $e = $info[$k]
        $short = $e.type -replace '^Windows\.UI\.Xaml\.', ''
        Write-Output ("  idx=" + $e.idx + "  " + $k + "  [" + $e.name + "]  " + $short)
    }
}
$rootHandle = $Handles[0]
Show-Children $rootHandle
