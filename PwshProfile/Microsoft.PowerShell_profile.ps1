# --------- Shell helpers - custom commands and settings ---------

$global:ProjectRoot = 'C:\Project'  # change with: cdp -setdir <path>

function cdp {
    param(
        [Alias('ls')]
        [switch]$List,

        [string]$SetDir,

        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [ArgumentCompleter({
            param($cmdName, $paramName, $wordToComplete, $commandAst, $fakeBoundParameters)
            $base = $global:ProjectRoot
            if (-not $base) { return }
            $word = $wordToComplete -replace '^["'']', ''
            $i    = if ($word) { $word.LastIndexOfAny([char[]]@('\', '/')) } else { -1 }
            if ($i -ge 0) { $dirPart = $word.Substring(0, $i); $leaf = $word.Substring($i + 1) }
            else          { $dirPart = '';                     $leaf = $word }
            $root = if ($dirPart) { Join-Path $base $dirPart } else { $base }
            if (-not (Test-Path -LiteralPath $root -PathType Container)) { return }
            Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like "$leaf*" } |
                ForEach-Object {
                    $val = if ($dirPart) { Join-Path $dirPart $_.Name } else { $_.Name }
                    [System.Management.Automation.CompletionResult]::new($val, $val, 'ParameterValue', $_.FullName)
                }
        })]
        [string[]]$Path
    )

    if ($List) {
        $base = $global:ProjectRoot
        if (-not $base) { $host.UI.WriteErrorLine('cdp: $ProjectRoot is not set'); return }
        if (-not (Test-Path -LiteralPath $base -PathType Container)) { $host.UI.WriteErrorLine("cdp: project root not found: $base"); return }
        Get-ChildItem -LiteralPath $base -Directory |
            Sort-Object Name |
            Select-Object @{ n = 'Project'; e = { $_.Name } }, @{ n = 'Path'; e = { $_.FullName } }
        return
    }

    if ($PSBoundParameters.ContainsKey('SetDir')) {
        $resolved = try {
            (Resolve-Path -LiteralPath $SetDir -ErrorAction Stop | Select-Object -First 1).ProviderPath
        } catch {
            $host.UI.WriteErrorLine("cdp: directory not found: $SetDir")
            return
        }

        $prof = $PROFILE.CurrentUserCurrentHost
        if (-not (Test-Path -LiteralPath $prof)) { $host.UI.WriteErrorLine("cdp: profile not found: $prof"); return }

        $value = '$global:ProjectRoot = ' + "'" + ($resolved -replace "'", "''") + "'"

        $lines = @(Get-Content -LiteralPath $prof)
        $idx   = -1
        for ($k = 0; $k -lt $lines.Count; $k++) {
            if ($lines[$k] -match '^\$((global|script):)?ProjectRoot\s*=') { $idx = $k; break }
        }

        $changed = $false
        if ($idx -ge 0) {
            $orig = $lines[$idx]
            $cmt  = -1
            $inq  = $false
            for ($c = 0; $c -lt $orig.Length; $c++) {
                if ($orig[$c] -eq [char]39) { $inq = -not $inq }
                elseif ($orig[$c] -eq [char]35 -and -not $inq) { $cmt = $c; break }
            }
            if ($cmt -ge 0) {
                $head = $orig.Substring(0, $cmt)
                $pad  = $head.Substring($head.TrimEnd().Length)
                $new  = $value + $pad + $orig.Substring($cmt)
            } else {
                $new = $value
            }
            if ($new -ne $orig) { $lines[$idx] = $new; $changed = $true }
        } else {
            $new = $value + '  # change with: cdp -setdir <path>'
            $at  = 0
            for ($k = 0; $k -lt $lines.Count; $k++) {
                if ($lines[$k] -match '^# -{2,}') { $at = $k + 1; break }
            }
            $before = @(if ($at -gt 0) { $lines[0..($at - 1)] })
            $after  = @(if ($at -lt $lines.Count) { $lines[$at..($lines.Count - 1)] })
            $skip   = 0
            while ($skip -lt $after.Count -and $after[$skip] -eq '') { $skip++ }
            $after  = @(if ($skip -lt $after.Count) { $after[$skip..($after.Count - 1)] })
            $lines  = $before + @($new, '') + $after
            $changed = $true
        }

        if ($changed) {
            [System.IO.File]::WriteAllText($prof, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
        }

        $global:ProjectRoot = $resolved
        Set-Location -LiteralPath $resolved
        Write-Host "ProjectRoot set to $resolved"
        if ($changed) { Write-Host "Updated profile: $prof" } else { Write-Host "Profile already had this value, file untouched" }
        return
    }

    if ($Path.Count -gt 0 -and $Path[0].StartsWith('-')) {
        $opt   = $Path[0]
        $name  = $opt.TrimStart('-')
        $first = if ($name) { $name.Substring(0, 1) } else { '' }
        $hint  = @('list', 'setdir') | Where-Object { $first -and $_.StartsWith($first) } | Select-Object -First 1
        $msg   = "unknown option '$opt'. valid: cdp -list, cdp -setdir <path>"
        if ($hint) { $msg += " (did you mean -${hint}?)" }
        $host.UI.WriteErrorLine("cdp: $msg")
        return
    }

    $base = $global:ProjectRoot
    if (-not $base) { $host.UI.WriteErrorLine('cdp: $ProjectRoot is not set'); return }
    if (-not (Test-Path -LiteralPath $base -PathType Container)) { $host.UI.WriteErrorLine("cdp: project root not found: $base"); return }
    $target = if ($Path) { $Path -join '\' } else { '' }
    $full   = if ([System.IO.Path]::IsPathRooted($target)) { $target } else { Join-Path $base $target }
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { $host.UI.WriteErrorLine("cdp: directory not found: $full"); return }
    Set-Location -LiteralPath $full
}

# --------- .NET shortcuts ---------

function .n {dotnet @args}
function .nc {dotnet clean @args}
function .nr {dotnet restore @args}
function .nbr {dotnet build -c Release @args}
function .nbd {dotnet build -c Debug @args}
function .nrr {dotnet run -c Release @args}
function .nrd {dotnet run -c Debug @args}

# --------- CMake shortcuts ---------

function .c {cmake @args}
function .cc {cmake --preset vs18-x64; cmake --build --preset debug --target clean @args}
function .cbd {cmake --preset vs18-x64; cmake --build --preset debug @args}
function .cbr {cmake --preset vs18-x64; cmake --build --preset release @args}
