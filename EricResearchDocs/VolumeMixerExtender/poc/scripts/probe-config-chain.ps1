# probe-config-chain.ps1 -- 端到端验证"配置链路"已经打通：
#   直投通道（Launcher 直接调 TAP 的导出）-> TAP 解析出 cfg= 路径 -> 用该路径读配置
#   -> 界面行为随之改变（按钮文字变成配置里的值）
#
# 与 probe-initdata.ps1 的区别：那个是"逐长度量 initData 通道的上限"；
# 这个是"证明定稿后的直投方案端到端可用"。
#
# 注意：本轮按钮文字用**纯 ASCII**（TestLink2）。
#   如果这里放中文，就会撞上尚未验证的 T2（INI 编码），把两个问题混在一起。
#   非 ASCII 的保真已经由 Launcher 的 kCjkSelfTest（initdata_cjk_test=1）在直投通道上验证过了。

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '_paths.ps1')
$poc  = $PocDir
$pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
$cfgPath  = Join-Path $poc 'vcxtap.ini'
$initData = "ver=1;cfg=$cfgPath;log=$(Join-Path $poc 'vcxtap.log')"
Write-Output "initData（也是传给 InitializeXamlDiagnosticsEx 的面包屑）= $initData"

Write-Output ""
Write-Output "=== 1. 停 shell ==="
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
    Get-Content (Join-Path $poc 'build.out.txt') | Select-Object -Last 30
    exit 1
}
Write-Output "  build OK"

Write-Output "=== 3. 写配置（按钮文字改成 TestLink2）==="
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $poc 'vcxlaunch.ini'),
    "[vcxlaunch]`r`ntap=vcxtap.dll`r`nxamldiag=C:\Program Files (x86)\Windows Kits\10\bin\x64\XamlDiagnostics\xamldiagnostics.dll`r`ninitdata=$initData`r`n",
    $utf8NoBom)
[IO.File]::WriteAllText($cfgPath,
    "[vcxtap]`r`nstage=2`r`nentry1_text=TestLink2`r`n",
    $utf8NoBom)
Write-Output ("  " + $cfgPath + " 里 entry1_text=TestLink2")

Write-Output "=== 4. 重启 explorer + 注入 ==="
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
Write-Output ("  ShellHost pid " + $sh.Id)
& (Join-Path $poc 'injector.exe') --dll (Join-Path $poc 'vcxlaunch.dll') | ForEach-Object { '  ' + $_ }
Start-Sleep -Seconds 3

Write-Output "=== 5. Launcher 日志（配置怎么发出去的）==="
Get-Content (Join-Path $poc 'vcxlaunch.log') |
    Select-String -Pattern '配置|直投|LoadLibraryW|GetProcAddress|SUCCESS' | ForEach-Object { '  ' + $_.Line }

Write-Output "=== 6. TAP 日志（通道是否一致 + cfg 路径是否解析出来）==="
Get-Content (Join-Path $poc 'vcxtap.log') |
    Select-String -Pattern '配置来源|直投通道|initData :|已从直投|退回|预期|不一致|未收到' | ForEach-Object { '  ' + $_.Line }

Write-Output "=== 7. 打开面板，看按钮文字是否真的变成配置里的值 ==="
& $pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ScriptsDir 'qs-panel-probe.ps1') 2>&1 |
    Select-String -Pattern 'panel hwnd|not open' | ForEach-Object { '  ' + $_.Line }
Start-Sleep -Seconds 3
$map = & $pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ScriptsDir 'footer-map.ps1') 2>&1
$map | Select-String -Pattern 'Footer\] Group|更多音量设置|TestLink|PANEL' | ForEach-Object { '  ' + $_.Line }

Write-Output '── TAP 里记录的按钮文字来源 ──'
Get-Content (Join-Path $poc 'vcxtap.log') |
    Select-String -Pattern '按钮文字|wrapped the row|SAME row' | ForEach-Object { '  ' + $_.Line }

Write-Output ""
Write-Output "=== 8. 结论 ==="
$t  = Get-Content (Join-Path $poc 'vcxtap.log') -Raw
$ok = $false
if ($map -match 'name=\[TestLink2\]') { Write-Output '  ✅ 按钮文字 = TestLink2  => 配置链路端到端打通'; $ok = $true }
else { Write-Output '  ❌ 按钮文字没变成 TestLink2（看上面日志：cfg 路径/ini 读取哪一环断了）' }
if ($t -match '已从直投配置解析出配置文件路径') { Write-Output '  ✅ TAP 从直投配置里解析出了 cfg 路径' }
else { Write-Output '  ❌ 没解析出 cfg 路径（配置里没有 cfg= ？）' }
if ($t -match '两种通道内容一致') { Write-Output '  ✅ initData 与直投内容一致（未触及 259 上限）' }
else { Write-Output '  ℹ️  两通道结果不同（看上面"预期/不一致"那几行）' }
# 按钮文字长度会变，所以 x 会变；真正的不变量是"右边缘贴合 4px 内缩"= 2547-4 = 2543。
# 面板宽度、DPI 变了这个数也要跟着变，这里按本轮实测值断言。
$btnLine = ($map | Select-String 'name=\[TestLink2\]').Line
if ($btnLine -match 'rect=\((-?\d+),(-?\d+) (\d+)x(\d+)\)') {
    $x = [int]$Matches[1]; $w = [int]$Matches[3]; $right = $x + $w
    Write-Output "  位置: x=$x w=$w  ->  右边缘 $right"
    if ($right -eq 2543) { Write-Output '  ✅ 右边缘 2543 = 面板右 2547 - 4px 内缩（与模型按钮 +4px 左内缩镜像）' }
    else { Write-Output "  ❌ 右边缘 $right ≠ 2543，右对齐错了" }
    if ($btnLine -match ' (\d+)x(\d+)\)') { }
} else { Write-Output '  ❌ 读不出 TestLink2 的 rect' }
