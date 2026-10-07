# Captures the Quick Settings sound-page footer region to a PNG so the injected button can be
# inspected visually. Region is in screen pixels (the UIA rects are screen coordinates).
param(
    [int]$X = 2150,
    [int]$Y = 1390,
    [int]$W = 440,
    [int]$H = 110,
    [string]$Out = "$PSScriptRoot\..\logs\footer-shot.png"
)

Add-Type -AssemblyName System.Drawing

$bmp = New-Object System.Drawing.Bitmap($W, $H)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($X, $Y, 0, 0, (New-Object System.Drawing.Size($W, $H)))
$g.Dispose()

$dir = Split-Path -Parent $Out
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }

# scale 2x so the small text is legible
$big = New-Object System.Drawing.Bitmap(($W * 2), ($H * 2))
$g2 = [System.Drawing.Graphics]::FromImage($big)
$g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
$g2.DrawImage($bmp, 0, 0, ($W * 2), ($H * 2))
$g2.Dispose()
$big.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$big.Dispose()
$bmp.Dispose()

Write-Output "saved $Out  (region $X,$Y ${W}x${H}, shown 2x)"
