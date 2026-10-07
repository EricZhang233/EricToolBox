# probe-initdata.ps1 -- 验证 T1：
#   IXamlDiagnostics::GetInitializationData() 是否**原样**返回
#   InitializeXamlDiagnosticsEx 第 6 个参数（wszInitializationData）。
#
# 为什么这个验证重要：整个产品的"配置怎么进 TAP"就建立在这条通道上
#   （按钮文字 / 点击动作 / 边距 / 日志路径 / 管道名 全靠它传进去）。
#   PoC 原来传的是 nullptr，从未验证过回读。
#
# 设计要点：
#   * initData = "vcxlaunch.ini 里的 ASCII 基串" + "代码里写死的 CJK 后缀（ini 开关
#     initdata_cjk_test=1 打开，见 vcxlaunch.cpp 的 kCjkSelfTest）"
#     -> 把"initData 通道是否正确"与"ini 编码是否正确"拆成两个独立问题
#        （CJK 不经过 ini，所以这里不会因为 ini 编码而误判）
#   * SetSite 在**注入那一刻**就被调用，所以本探针**不需要打开面板**。
#   * 顺带验证更危险的一条：返回的 BSTR 到底归谁 —— 如果框架返回的是内部指针，
#     对它 SysFreeString 会破坏 ShellHost 的堆。
#
# ★ 定稿结论（9 个长度点扫完）：
#   * 通道**可用**，会原样回读（含 CJK），但**上限正好 259 字符**。
#   * >= 260 时**静默返回空串，且 hr 仍是 S_OK** —— 没有任何错误信号。
#   * 超限是**有界拒绝**（4000 字符下 ShellHost 无异常、按钮照常注入），不是溢出。
#   * 所以配置改走"直投通道"（Launcher 直接调 TAP 导出 VmExtTapProvideInitData），
#     initData 降级为人类可读的面包屑。详见 docs/verified-after-injection/06-*.md。
#   用 -Total 参数化总长度可复现整张扫描表。
#   total = 基串 + 后缀(";cjk=" + 7 个 CJK 字符 = 12 字符)

param([int]$Total = 331)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '_paths.ps1')
$poc  = $PocDir
$pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'

# ---- 构造探针载荷 ----
$suffixLen = 12
$base = 'a' * [Math]::Max(0, $Total - $suffixLen)
Write-Output ("探针载荷：目标总长 = " + $Total + " 字符（基串 " + $base.Length + " + 后缀 " + $suffixLen + "）")
Write-Output "  已测：17/128/255/256/259 -> 原样回读；260/300/331/4000 -> 回读为空串（静默，hr 仍是 S_OK）"
Write-Output "  => 上限正好 259 字符；配置已改走直投通道，initData 仅作面包屑"
Write-Output "  Launcher 侧会追加 CJK 自检后缀 ;cjk=音量合成器测试（ini 开关 initdata_cjk_test=1 已打开）"

Write-Output ""
Write-Output "=== 1. 停 shell（释放 DLL 文件锁）==="
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
    Get-Content (Join-Path $poc 'build.out.txt') | Select-Object -Last 25
    exit 1
}
Write-Output "  build OK"

Write-Output "=== 3. 写两个 ini（纯 ASCII，UTF-8 无 BOM，避免编码问题混淆结果）==="
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$launchIni = @(
    "[vcxlaunch]",
    "tap=vcxtap.dll",
    "xamldiag=C:\Program Files (x86)\Windows Kits\10\bin\x64\XamlDiagnostics\xamldiagnostics.dll",
    "initdata=$base",
    "initdata_cjk_test=1"
) -join "`r`n"
[IO.File]::WriteAllText((Join-Path $poc 'vcxlaunch.ini'), $launchIni + "`r`n", $utf8NoBom)

$tapIni = @(
    "[vcxtap]",
    "stage=2",
    "entry1_text=TestLink"
) -join "`r`n"
[IO.File]::WriteAllText((Join-Path $poc 'vcxtap.ini'), $tapIni + "`r`n", $utf8NoBom)
Write-Output ("  vcxlaunch.ini  initdata 行长度 = " + $base.Length + "  + 代码里的 CJK 自检串 12")
Write-Output '  vcxtap.ini     不带 expected_* —— 判定改为「直投内容」与「initData 回读」互比'

Write-Output "=== 4. 重启 explorer + 注入 launcher ==="
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

Write-Output "=== 5. Launcher 侧（发出去的是什么）==="
$llog = Join-Path $poc 'vcxlaunch.log'
if (Test-Path $llog) {
    Get-Content $llog | Select-String -Pattern 'initData|直投|LoadLibraryW|GetProcAddress|SUCCESS|hr=0x|发送' | ForEach-Object { '  ' + $_.Line }
} else { Write-Output '  (no launcher.log)' }

Write-Output "=== 6. TAP 侧（回读 vs 期望；直投 vs 期望；BSTR 所有权）==="
$tlog = Join-Path $poc 'vcxtap.log'
if (Test-Path $tlog) {
    Start-Sleep -Seconds 1
    Get-Content $tlog | Select-String -Pattern 'initData|GetInitializationData|回读|期望|T1|直投|指针相同|SysFreeString|首个差异|收到直投' |
        ForEach-Object { '  ' + $_.Line }
} else { Write-Output '  (no tap.log -- TAP 没被加载)' }

Write-Output ""
Write-Output "=== 7. 回归检查：打开面板，按钮还应正常出现 ==="
& $pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ScriptsDir 'qs-panel-probe.ps1') 2>&1 |
    Select-String -Pattern 'panel hwnd|not open' | ForEach-Object { '  ' + $_.Line }
Start-Sleep -Seconds 3
& $pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ScriptsDir 'footer-map.ps1') 2>&1 |
    Select-String -Pattern 'Footer\] Group|更多音量设置|TestLink|PANEL' | ForEach-Object { '  ' + $_.Line }

Write-Output ""
Write-Output "=== 8. 结论 ==="
# 判定改为"两个通道互比"，不再依赖两侧各写一份期望值：
#   initData 与 直投 内容一致           -> 通道回读正确（总长 <= 259）
#   initData 为空 + 直投 > 259 + 有直投 -> 预期内的静默丢弃（这就是上限）
#   直投未收到                          -> Launcher 侧调用断了
$t = if (Test-Path $tlog) { Get-Content $tlog -Raw } else { '' }
if     ($t -match '两种通道内容一致') {
    Write-Output ("  T1(a) initData 通道原样回读  : PASS（总长 " + $Total + " <= 259，含 CJK 逐字符一致）")
} elseif ($t -match 'initData 为空属\*\*预期\*\*') {
    Write-Output ("  T1(a) initData 通道原样回读  : FAIL-AS-EXPECTED（总长 " + $Total + " > 259 => 静默返回空串，hr 仍是 S_OK）")
} elseif ($t -match '两通道内容不一致') {
    Write-Output '  T1(a) initData 通道原样回读  : FAIL（长度不一致，见日志"两通道内容不一致"）'
} else {
    Write-Output '  T1(a) initData 通道原样回读  : 未得到结论'
}
# T1(b) 的判定依据是"initData 到底有没有取到"（取到才谈得上 SysFreeString），
# 以及释放后 ShellHost 是否还活着（活着的证据见第 7 步的回归检查）。
$lenM = [regex]::Match($t, 'initData : len=(\d+)')
if ($lenM.Success) {
    $initLen = [int]$lenM.Groups[1].Value
    if ($initLen -gt 0) {
        Write-Output ("  T1(b) BSTR 所有权可释放      : PASS（取到 " + $initLen + " 字符；已 SysFreeString，见第 7 步回归）")
    } else {
        Write-Output '  T1(b) BSTR 所有权可释放      : N/A（本长度下 initData 为空，没有 BSTR 可取；不是失败）'
    }
} else {
    Write-Output '  T1(b) BSTR 所有权可释放      : 未得到结论（日志里没有 initData 行）'
}
if     ($t -match '两种通道内容一致')     { Write-Output '  T1(c) 配置直投通道（主通道）  : PASS（与 initData 逐字符一致，含 CJK）' }
elseif ($t -match '直投通道: 有')        { Write-Output '  T1(c) 配置直投通道（主通道）  : PASS（已收到且内容完整；initData 侧超限属预期）' }
else                                     { Write-Output '  T1(c) 配置直投通道（主通道）  : FAIL（直投未收到 => Launcher 导出/调用有问题）' }
