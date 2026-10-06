#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$Title = 'Windows Update Settings',
    [switch]$Block,
    [switch]$Restore,
    [switch]$TogglePush,
    [switch]$Hide
)

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $hostExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($k in $PSBoundParameters.Keys) {
        $relaunch += "-$k"
        if ($PSBoundParameters[$k] -isnot [switch]) { $relaunch += "`"$($PSBoundParameters[$k])`"" }
    }
    if ($env:WT_SESSION) {
        Start-Process -FilePath 'wt.exe' -Verb RunAs -ArgumentList (@($hostExe) + $relaunch)
    } else {
        Start-Process -FilePath $hostExe -Verb RunAs -ArgumentList $relaunch
    }
    exit 0
}

$ErrorActionPreference = 'Continue'
try { [Console]::Title = $Title } catch {}

$WU_AU_POLICY = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
$WU_WU_POLICY = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$DRV_SEARCH   = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching'
$UPP_STATE    = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UpdatePolicy\PolicyState'
$AU_NOTIFY    = 2

function Write-Step { param([string]$T) Write-Host "`n[*] $T" -ForegroundColor Cyan }
function Write-OK   { param([string]$T) Write-Host "    [+] $T" -ForegroundColor Green }
function Write-Warn { param([string]$T) Write-Host "    [!] $T" -ForegroundColor Yellow }

function ConvertTo-PaddedString {
    param([string]$Text, [int]$Width)
    $w = 0
    foreach ($ch in $Text.ToCharArray()) { $w += if ([int]$ch -gt 127) { 2 } else { 1 } }
    if ($w -gt $Width) {
        $limit = $Width - 3
        if ($limit -lt 0) { $limit = 0 }
        $acc = 0
        $out = ''
        foreach ($ch in $Text.ToCharArray()) {
            $cw = if ([int]$ch -gt 127) { 2 } else { 1 }
            if ($acc + $cw -gt $limit) { break }
            $out += $ch
            $acc += $cw
        }
        return $out + '...'
    }
    return $Text + (' ' * ($Width - $w))
}

function Set-WuNotifyOnly {
    Write-Step 'Block Automatic Updates (AUOptions=2)'
    try {
        $cur = (Get-ItemProperty $WU_AU_POLICY -ErrorAction SilentlyContinue).AUOptions
        if ($cur -and $cur -ne $AU_NOTIFY) {
            Write-Warn "Existing AUOptions=$cur will be overwritten to $AU_NOTIFY."
        }
        New-Item -Path $WU_AU_POLICY -Force -ErrorAction Stop | Out-Null
        Set-ItemProperty -Path $WU_AU_POLICY -Name 'AUOptions' -Value $AU_NOTIFY -Type DWord -Force
        & gpupdate.exe /force /target:computer 2>&1 | Out-Null
        Write-OK 'Configure Automatic Updates = 2 (Notify for download and install).'
        Write-OK 'No updates (incl. drivers) will download or install automatically; manual check still works.'
    } catch { Write-Warn "Operation failed: $_" }
}

function Test-WuNotifyOnly {
    $p = Get-ItemProperty $WU_AU_POLICY -ErrorAction SilentlyContinue
    return ($p -and $p.AUOptions -eq $AU_NOTIFY)
}

function Switch-WuPolicy {
    if (Test-WuNotifyOnly) { Restore-WuNotifyOnly } else { Set-WuNotifyOnly }
}

function Get-AuOption {
    $p = Get-ItemProperty $WU_AU_POLICY -ErrorAction SilentlyContinue
    if ($p -and $p.AUOptions) { return $p.AUOptions }
    return $null
}

function Set-AuOption {
    param([int]$Value)
    Write-Step ("Set Automatic Updates Mode = {0}" -f $Value)
    try {
        New-Item -Path $WU_AU_POLICY -Force -ErrorAction Stop | Out-Null
        Set-ItemProperty -Path $WU_AU_POLICY -Name 'AUOptions' -Value $Value -Type DWord -Force
        & gpupdate.exe /force /target:computer 2>&1 | Out-Null
        Write-OK ("AUOptions = {0} applied." -f $Value)
    } catch { Write-Warn "Operation failed: $_" }
}

function Test-DriverBlock {
    $w = Get-ItemProperty $WU_WU_POLICY -ErrorAction SilentlyContinue
    $p = Get-ItemProperty $DRV_SEARCH -ErrorAction SilentlyContinue
    $u = Get-ItemProperty $UPP_STATE -ErrorAction SilentlyContinue
    if ($w -and $null -ne $w.ExcludeWUDriversInQualityUpdate -and $w.ExcludeWUDriversInQualityUpdate -ne 0) { return $true }
    if ($p -and $null -ne $p.SearchOrderConfig -and $p.SearchOrderConfig -eq 0) { return $true }
    if ($u -and $null -ne $u.ExcludeWUDrivers -and $u.ExcludeWUDrivers -ne 0) { return $true }
    return $false
}

function Set-DriverBlock {
    Write-Step 'Block Driver Updates'
    try {
        New-Item -Path $WU_WU_POLICY -Force -ErrorAction Stop | Out-Null
        Set-ItemProperty -Path $WU_WU_POLICY -Name 'ExcludeWUDriversInQualityUpdate' -Value 1 -Type DWord -Force
        New-Item -Path $DRV_SEARCH -Force -ErrorAction Stop | Out-Null
        Set-ItemProperty -Path $DRV_SEARCH -Name 'SearchOrderConfig' -Value 0 -Type DWord -Force
        New-Item -Path $UPP_STATE -Force -ErrorAction Stop | Out-Null
        Set-ItemProperty -Path $UPP_STATE -Name 'ExcludeWUDrivers' -Value 1 -Type DWord -Force
        & gpupdate.exe /force /target:computer 2>&1 | Out-Null
        Write-OK 'Driver channel blocked: no driver installs or driver updates via Windows Update.'
    } catch { Write-Warn "Operation failed: $_" }
}

function Restore-DriverBlock {
    Write-Step 'Restore Driver Updates'
    try {
        $fail = 0
        if (Test-Path $WU_WU_POLICY) {
            $v = (Get-ItemProperty $WU_WU_POLICY -ErrorAction SilentlyContinue).ExcludeWUDriversInQualityUpdate
            if ($null -ne $v) {
                try { Remove-ItemProperty -Path $WU_WU_POLICY -Name 'ExcludeWUDriversInQualityUpdate' -ErrorAction Stop; Write-OK 'ExcludeWUDriversInQualityUpdate removed' }
                catch { Write-Warn "Remove ExcludeWUDriversInQualityUpdate failed: $_"; $fail++ }
            }
        }
        if (Test-Path $DRV_SEARCH) {
            $v = (Get-ItemProperty $DRV_SEARCH -ErrorAction SilentlyContinue).SearchOrderConfig
            if ($null -ne $v) {
                try { Remove-ItemProperty -Path $DRV_SEARCH -Name 'SearchOrderConfig' -ErrorAction Stop; Write-OK 'SearchOrderConfig removed' }
                catch {
                    Write-Warn "Remove SearchOrderConfig failed: $_"
                    & reg.exe delete 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching' /v SearchOrderConfig /f 2>&1 | Out-Null
                    if ($null -eq (Get-ItemProperty $DRV_SEARCH -ErrorAction SilentlyContinue).SearchOrderConfig) { Write-OK 'SearchOrderConfig removed (reg.exe)' } else { $fail++ }
                }
            }
        }
        if (Test-Path $UPP_STATE) {
            try { Set-ItemProperty -Path $UPP_STATE -Name 'ExcludeWUDrivers' -Value 0 -Type DWord -Force -ErrorAction Stop; Write-OK 'ExcludeWUDrivers set to 0' }
            catch {
                Write-Warn "Set ExcludeWUDrivers failed: $_"
                & reg.exe add 'HKLM\SOFTWARE\Microsoft\WindowsUpdate\UpdatePolicy\PolicyState' /v ExcludeWUDrivers /t REG_DWORD /d 0 /f 2>&1 | Out-Null
                if ((Get-ItemProperty $UPP_STATE -ErrorAction SilentlyContinue).ExcludeWUDrivers -eq 0) { Write-OK 'ExcludeWUDrivers set to 0 (reg.exe)' } else { $fail++ }
            }
        }
        & gpupdate.exe /force /target:computer 2>&1 | Out-Null
        if ($fail -gt 0) {
            Write-Warn "Restore incomplete ($fail operation(s) failed)."
        } elseif (Test-DriverBlock) {
            Write-Warn 'State still reads blocked:'
            $w = Get-ItemProperty $WU_WU_POLICY -ErrorAction SilentlyContinue
            $p = Get-ItemProperty $DRV_SEARCH -ErrorAction SilentlyContinue
            $u = Get-ItemProperty $UPP_STATE -ErrorAction SilentlyContinue
            if ($w.ExcludeWUDriversInQualityUpdate) { Write-Warn "  ExcludeWUDriversInQualityUpdate = $($w.ExcludeWUDriversInQualityUpdate)" }
            if ($p.SearchOrderConfig -eq 0) { Write-Warn "  SearchOrderConfig = $($p.SearchOrderConfig)" }
            if ($u.ExcludeWUDrivers) { Write-Warn "  ExcludeWUDrivers = $($u.ExcludeWUDrivers)" }
        } else {
            Write-OK 'Driver channel restored.'
        }
    } catch { Write-Warn "Operation failed: $_" }
}

function Switch-DriverBlock {
    if (Test-DriverBlock) { Restore-DriverBlock } else { Set-DriverBlock }
}

function Get-UpdateLists {
    $pq = 'IsInstalled=0 and IsHidden=0'
    $hq = 'IsInstalled=0 and IsHidden=1'
    try {
        $ps = [powershell]::Create()
        try { $ps.Runspace.ApartmentState = [System.Threading.ApartmentState]::STA } catch {}
        $null = $ps.AddScript('
param($pq, $hq)
$s = New-Object -ComObject Microsoft.Update.Session
$sr = $s.CreateUpdateSearcher()
[PSCustomObject]@{ Pending = @($sr.Search($pq).Updates); Hidden = @($sr.Search($hq).Updates) }
').AddArgument($pq).AddArgument($hq)

        $handle = $ps.BeginInvoke()
        $chars = '|/-\'
        $i = 0
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $cursor = $true
        try { $cursor = [Console]::CursorVisible; [Console]::CursorVisible = $false } catch {}
        try {
            while (-not $handle.IsCompleted) {
                Write-Host ("`r  Fetching update list... {0}  {1:N0}s" -f $chars[$i % 4], $sw.Elapsed.TotalSeconds) -NoNewline
                $i++
                Start-Sleep -Milliseconds 120
            }
        } finally {
            Write-Host (' ' * 60) -NoNewline
            Write-Host "`r" -NoNewline
            try { [Console]::CursorVisible = $cursor } catch {}
        }
        $obj = $ps.EndInvoke($handle)[0]
        $ps.Dispose()
        if (-not $obj) { return ,@(@(), @()) }
        return ,@(@($obj.Pending), @($obj.Hidden))
    } catch {
        Write-Host ''
        Write-Warn "Background fetch failed; fell back to synchronous query: $($_.Exception.Message)"
        $s = New-Object -ComObject Microsoft.Update.Session
        $sr = $s.CreateUpdateSearcher()
        $pending = @($sr.Search($pq).Updates)
        $hidden  = @($sr.Search($hq).Updates)
        return ,@($pending, $hidden)
    }
}

function Invoke-WuHideRestore {
    Write-Step 'Hide/Restore Updates'
    Write-Host '    Space toggles check (checked = hidden), Enter applies, Esc returns.' -ForegroundColor Gray
    try {
        $lists = Get-UpdateLists
        $pending = @($lists[0])
        $hidden  = @($lists[1])
        if ($pending.Count -eq 0 -and $hidden.Count -eq 0) {
            Write-Warn 'No pending updates in the catalog.'
            return
        }

        $picked = Show-UpdatePicker -Pending $pending -Hidden $hidden
        $items = $picked[0]
        $mode  = $picked[1]
        if ($mode -eq 'cancel') { Write-Host 'Cancelled.'; return }

        $hideCount = 0
        $restoreCount = 0
        foreach ($it in $items) {
            $current = ($it.Action -eq 'hidden')
            if ($it.Checked -eq $current) { continue }
            $u = $it.Update
            if ($it.Checked) {
                $u.IsHidden = $true
                $verb = 'Hidden'
                $hideCount++
            } else {
                $u.IsHidden = $false
                $verb = 'Restored'
                $restoreCount++
            }
            Write-OK "${verb}: $($u.Title)"
        }
        if ($hideCount -eq 0 -and $restoreCount -eq 0) {
            Write-Host 'No state changes.'
        } else {
            Write-OK "Done: hidden $hideCount, restored $restoreCount."
        }
    } catch { Write-Warn "Hide/Restore failed: $($_.Exception.Message)" }
}

function Get-ItemLine {
    param($Item, [int]$Index, [int]$Width)
    $box = if ($Item.Checked) { '[x]' } else { '[ ]' }
    $tag = if ($Item.Update.Type -eq 2) { 'Driver' } else { 'Software' }
    return ConvertTo-PaddedString ("  {0} {1,3} [{2}] {3}" -f $box, ($Index + 1), $tag, $Item.Update.Title) $Width
}

function Write-ItemLine {
    param($Item, [int]$Index, [int]$Width, [bool]$Selected)
    $line = Get-ItemLine $Item $Index $Width
    if ($Selected) {
        Write-Host $line -ForegroundColor Cyan -NoNewline
        Write-Host ''
    } else {
        $fg = if ($Item.Action -eq 'pending') { 'White' } else { 'Green' }
        Write-Host $line -ForegroundColor $fg
    }
}

function Show-UpdatePicker {
    param(
        [Parameter(Mandatory=$true)]$Pending,
        [Parameter(Mandatory=$true)]$Hidden
    )
    $items = @()
    foreach ($p in $Pending) { $items += [PSCustomObject]@{ Update = $p; Action = 'pending'; Checked = $false } }
    foreach ($h in $Hidden)  { $items += [PSCustomObject]@{ Update = $h; Action = 'hidden';  Checked = $true } }

    if ($items.Count -eq 0) { return ,@(@(), 'cancel') }

    $sel = 0
    $width = [Math]::Max(40, [Math]::Min(110, [Console]::WindowWidth - 2))

    $headerRow = [Console]::CursorTop
    $checkedCount = @($items | Where-Object { $_.Checked }).Count
    Write-Host (ConvertTo-PaddedString ("{0} items ({1} to hide / {2} to restore) selected: {3}" -f $items.Count, $Pending.Count, $Hidden.Count, $checkedCount) $width) -ForegroundColor White

    $firstItemRow = $headerRow + 1
    for ($i = 0; $i -lt $items.Count; $i++) {
        Write-ItemLine $items[$i] $i $width ($i -eq $sel)
    }
    $hintRow = [Console]::CursorTop
    Write-Host (ConvertTo-PaddedString '  Space toggle   Enter apply   Esc back' $width) -ForegroundColor Gray

    $cursor = $true
    try { $cursor = [Console]::CursorVisible; [Console]::CursorVisible = $false } catch {}
    $result = $null
    try {
        while ($true) {
            $key = [Console]::ReadKey($true)
            $old = $sel
            switch ($key.Key) {
                'UpArrow'    { $sel = ($sel + $items.Count - 1) % $items.Count }
                'LeftArrow'  { $sel = ($sel + $items.Count - 1) % $items.Count }
                'DownArrow'  { $sel = ($sel + 1) % $items.Count }
                'RightArrow' { $sel = ($sel + 1) % $items.Count }
                'Spacebar'   { $items[$sel].Checked = -not $items[$sel].Checked }
                'Enter'      { $result = 'ok'; break }
                'Escape'     { $result = 'cancel'; break }
            }
            if ($result) { break }

            if ($sel -ne $old) {
                [Console]::SetCursorPosition(0, $firstItemRow + $old)
                Write-ItemLine $items[$old] $old $width $false
                [Console]::SetCursorPosition(0, $firstItemRow + $sel)
                Write-ItemLine $items[$sel] $sel $width $true
            }
            if ($key.Key -eq 'Spacebar') {
                [Console]::SetCursorPosition(0, $firstItemRow + $sel)
                Write-ItemLine $items[$sel] $sel $width $true
                $checkedCount = @($items | Where-Object { $_.Checked }).Count
                [Console]::SetCursorPosition(0, $headerRow)
                Write-Host (ConvertTo-PaddedString ("{0} items ({1} to hide / {2} to restore) selected: {3}" -f $items.Count, $Pending.Count, $Hidden.Count, $checkedCount) $width) -ForegroundColor White -NoNewline
            }
            [Console]::SetCursorPosition(0, $hintRow + 1)
        }
    } finally {
        try { [Console]::CursorVisible = $cursor } catch {}
    }
    return ,@($items, $result)
}

function Restore-WuNotifyOnly {
    Write-Step 'Restore Automatic Updates'
    try {
        if (Test-Path $WU_AU_POLICY) {
            $had = (Get-ItemProperty $WU_AU_POLICY -ErrorAction SilentlyContinue).AUOptions
            Remove-ItemProperty -Path $WU_AU_POLICY -Name 'AUOptions' -ErrorAction SilentlyContinue
            & gpupdate.exe /force /target:computer 2>&1 | Out-Null
            if ($had) { Write-OK "AUOptions removed (was $had); automatic updates restored." }
            else { Write-OK 'No AUOptions present; defaults already active.' }
        } else {
            Write-OK 'No policy key present; defaults already active.'
        }
    } catch { Write-Warn "Operation failed: $_" }
}

function Write-MenuLine {
    param($Item, [int]$Width, [bool]$Selected)
    $cursor = if ($Selected) { '>' } else { ' ' }
    $line = ConvertTo-PaddedString ("  {0} [{1}] {2}" -f $cursor, $Item.Key, $Item.Text) $Width
    if ($Selected) {
        Write-Host $line -ForegroundColor Cyan -NoNewline
        Write-Host ''
    } else {
        Write-Host $line -ForegroundColor White -NoNewline
        Write-Host ''
    }
}

function Show-Menu {
    param($Items)
    $sel = 0
    $result = '0'
    $width = [Math]::Max(40, [Math]::Min(110, [Console]::WindowWidth - 2))

    $listTop = [Console]::CursorTop
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-MenuLine $Items[$i] $width ($i -eq $sel)
    }
    $descRow = [Console]::CursorTop
    Write-Host (ConvertTo-PaddedString ('  ' + $Items[$sel].Desc) $width) -ForegroundColor Gray
    $hintRow = [Console]::CursorTop
    Write-Host (ConvertTo-PaddedString '  Arrows move, Enter confirm, number keys select, Esc exit' $width) -ForegroundColor Gray

    $cursor = $true
    try { $cursor = [Console]::CursorVisible; [Console]::CursorVisible = $false } catch {}
    try {
        while ($true) {
            $key = [Console]::ReadKey($true)
            $old = $sel
            $done = $false
            switch ($key.Key) {
                'UpArrow'    { $sel = ($sel + $Items.Count - 1) % $Items.Count }
                'LeftArrow'  { $sel = ($sel + $Items.Count - 1) % $Items.Count }
                'DownArrow'  { $sel = ($sel + 1) % $Items.Count }
                'RightArrow' { $sel = ($sel + 1) % $Items.Count }
                'Enter'      { $done = $true; $result = $Items[$sel].Key }
                'Escape'     { $done = $true; $result = '0' }
                default {
                    $ch = $key.KeyChar
                    foreach ($it in $Items) {
                        if ($ch -eq [char]$it.Key) { $done = $true; $result = $it.Key; break }
                    }
                }
            }
            if ($done) { break }

            if ($sel -ne $old) {
                [Console]::SetCursorPosition(0, $listTop + $old)
                Write-MenuLine $Items[$old] $width $false
                [Console]::SetCursorPosition(0, $listTop + $sel)
                Write-MenuLine $Items[$sel] $width $true
                [Console]::SetCursorPosition(0, $descRow)
                Write-Host (ConvertTo-PaddedString ('  ' + $Items[$sel].Desc) $width) -ForegroundColor Gray -NoNewline
            }
            [Console]::SetCursorPosition(0, $hintRow + 1)
        }
    } finally {
        try { [Console]::CursorVisible = $cursor } catch {}
    }
    return $result
}

function Show-MainMenu {
    $mode = Get-AuOption
    $modeText = switch ($mode) {
        2 { 'Notify Only' }
        3 { 'Auto Download' }
        4 { 'Scheduled Install' }
        5 { 'Local Admin Choice' }
        default { 'Default' }
    }
    $drvText = if (Test-DriverBlock) { 'Blocked' } else { 'Included' }
    $items = @(
        [PSCustomObject]@{ Key = '1'; Text = ("Auto-Update Policy [Current: {0}]" -f $modeText); Desc = 'Configure Automatic Updates mode: notify, auto download, scheduled install, or admin choice.' },
        [PSCustomObject]@{ Key = '2'; Text = ("Driver Updates [Current: {0}]" -f $drvText); Desc = 'Block or restore driver delivery via Windows Update (installs and updates).' },
        [PSCustomObject]@{ Key = '3'; Text = 'Hide/Restore Updates'; Desc = 'Browse the update catalog (drivers and software). Space toggles check (checked = hidden), Enter applies. Requires network.' },
        [PSCustomObject]@{ Key = '0'; Text = 'Exit'; Desc = 'Exit the script.' }
    )
    return Show-Menu $items
}

function Get-AuItemColor {
    param($Mode)
    switch ($Mode) {
        2 { 'DarkCyan' }
        3 { 'DarkGreen' }
        4 { 'DarkYellow' }
        5 { 'DarkRed' }
        default { 'DarkBlue' }
    }
}

function Write-AuItemLine {
    param($M, [int]$Index, [int]$Width, [bool]$Selected, $Checked)
    $box = if ($Checked -eq $M.Mode) { '[x]' } else { '[ ]' }
    $num = if ($M.Mode -is [int]) { $M.Mode } else { '-' }
    $line = ConvertTo-PaddedString ("  {0} {1} {2}" -f $box, $num, $M.Name) $Width
    if ($Selected) {
        Write-Host $line -ForegroundColor Cyan -NoNewline
        Write-Host ''
    } elseif ($Checked -eq $M.Mode) {
        Write-Host $line -ForegroundColor (Get-AuItemColor $M.Mode) -NoNewline
        Write-Host ''
    } else {
        Write-Host $line -NoNewline
        Write-Host ''
    }
}

function Show-AuPicker {
    param($Modes)
    $sel = 0
    $cur = Get-AuOption
    $checked = if ($null -eq $cur) { 'default' } else { $cur }
    $width = [Math]::Max(40, [Math]::Min(110, [Console]::WindowWidth - 2))

    $headerRow = [Console]::CursorTop
    Write-Host (ConvertTo-PaddedString '  Automatic updates mode' $width) -ForegroundColor Gray
    $firstItemRow = [Console]::CursorTop
    for ($i = 0; $i -lt $Modes.Count; $i++) {
        Write-AuItemLine $Modes[$i] $i $width ($i -eq $sel) $checked
    }
    $hintRow = [Console]::CursorTop
    Write-Host (ConvertTo-PaddedString '  Enter apply   Esc back' $width) -ForegroundColor Gray

    $cursor = $true
    try { $cursor = [Console]::CursorVisible; [Console]::CursorVisible = $false } catch {}
    try {
        while ($true) {
            $key = [Console]::ReadKey($true)
            $old = $sel
            switch ($key.Key) {
                'UpArrow'    { $sel = ($sel + $Modes.Count - 1) % $Modes.Count }
                'LeftArrow'  { $sel = ($sel + $Modes.Count - 1) % $Modes.Count }
                'DownArrow'  { $sel = ($sel + 1) % $Modes.Count }
                'RightArrow' { $sel = ($sel + 1) % $Modes.Count }
                'Enter'      { return $Modes[$sel] }
                'Escape'     { return $null }
            }
            if ($sel -ne $old) {
                [Console]::SetCursorPosition(0, $firstItemRow + $old)
                Write-AuItemLine $Modes[$old] $old $width $false $checked
                [Console]::SetCursorPosition(0, $firstItemRow + $sel)
                Write-AuItemLine $Modes[$sel] $sel $width $true $checked
            }
            [Console]::SetCursorPosition(0, $hintRow + 1)
        }
    } finally {
        try { [Console]::CursorVisible = $cursor } catch {}
    }
}

function Show-AuMenu {
    $modes = @(
        @{ Mode = 2; Name = 'Notify for Download and Install' },
        @{ Mode = 3; Name = 'Auto Download, Notify for Install' },
        @{ Mode = 4; Name = 'Auto Download, Scheduled Install' },
        @{ Mode = 5; Name = 'Allow Local Admin to Choose' },
        @{ Mode = 'default'; Name = 'Remove Policy / Default' }
    )
    $pick = Show-AuPicker $modes
    if ($null -eq $pick) { return }
    if ($pick.Mode -eq 'default') { Restore-WuNotifyOnly } else { Set-AuOption $pick.Mode }
}

if ($Block)      { Set-WuNotifyOnly;     exit 0 }
if ($Restore)    { Restore-WuNotifyOnly; exit 0 }
if ($TogglePush) { Switch-WuPolicy;      exit 0 }
if ($Hide)       { Invoke-WuHideRestore; exit 0 }

while ($true) {
    Write-Host ''
    Write-Host "========== $Title ==========" -ForegroundColor Magenta
    Write-Host ''
    $choice = Show-MainMenu
    switch ($choice) {
        '1' { Show-AuMenu }
        '2' { Switch-DriverBlock }
        '3' { Invoke-WuHideRestore }
        '0' { Write-Host 'Exited.'; exit 0 }
    }
    Write-Host ''
    Write-Host 'Press any key to return to the menu.' -ForegroundColor Gray
    $null = [Console]::ReadKey($true)
}
