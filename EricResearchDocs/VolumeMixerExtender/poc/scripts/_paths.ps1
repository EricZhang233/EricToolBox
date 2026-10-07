# _paths.ps1 -- 被同目录脚本 dot-source，用来定位 PoC 目录（exe/dll/ini/日志都在那一层）。
#
# 为什么不每个脚本自己算层级：脚本从旧的活工作区搬到 docs\poc\scripts\ 时，
#   所有 `Split-Path -Parent` 的层数都错了，而症状只是"找不到文件" —— 很难查。
#   改成从本文件自身向上找 build.cmd 这个标记，布局再变也不用动脚本。
#
# 用法（在每个脚本的顶部）：
#   . (Join-Path $PSScriptRoot '_paths.ps1')
#   然后使用 $PocDir / $ScriptsDir

$ScriptsDir = $PSScriptRoot
if (-not $ScriptsDir) { throw '_paths.ps1 必须以脚本文件形式 dot-source（$PSScriptRoot 为空）' }

$PocDir = Split-Path -Parent $ScriptsDir
while ($PocDir -and -not (Test-Path (Join-Path $PocDir 'build.cmd'))) {
    $parent = Split-Path -Parent $PocDir
    if ($parent -eq $PocDir) { $PocDir = $null; break }
    $PocDir = $parent
}
if (-not $PocDir) { throw "找不到 PoC 目录：从 $ScriptsDir 向上都没有 build.cmd" }
