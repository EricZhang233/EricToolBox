Set-StrictMode -Version Latest

function Test-PathPart($Name) {
    return ($Name -is [string] -and -not [string]::IsNullOrWhiteSpace($Name) -and
        $Name -notmatch '[\\/:*?"<>|\x00-\x1f]|[. ]$|^(?i:CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)')
}

function Assert-PathPart($Name) {
    if (-not (Test-PathPart $Name)) {
        throw "Invalid Windows file or directory name: $Name"
    }
}

function Test-RelativePath($Path) {
    if ($Path -isnot [string]) { return $false }
    foreach ($part in ($Path -split '[/\\]')) {
        if (-not (Test-PathPart $part)) { return $false }
    }
    return $true
}

function Test-PayloadExecutable($Name) {
    return ((Test-PathPart $Name) -and $Name -like '*.exe' -and $Name -notmatch '^\.(?:_|migration-)')
}

function Test-PayloadPattern($Pattern) {
    if ($Pattern -isnot [string] -or [string]::IsNullOrWhiteSpace($Pattern) -or $Pattern -match '[\x00-\x1f]') { return $false }
    try {
        $null = [Management.Automation.WildcardPattern]::new($Pattern).IsMatch('')
        return $true
    } catch [Management.Automation.WildcardPatternException] { return $false }
}

function Get-PathParts([string]$RelativePath) {
    $parts = $RelativePath -split '[/\\]'
    foreach ($part in $parts) { Assert-PathPart $part }
    return $parts
}

function Import-InstallerYaml {
    if ('YamlDotNet.Serialization.DeserializerBuilder' -as [type]) { return }
    $version = '18.1.0'
    $cache = if ($env:NUGET_PACKAGES) { $env:NUGET_PACKAGES } else {
        Join-Path ([Environment]::GetFolderPath('UserProfile')) '.nuget/packages'
    }
    $package = Join-Path $cache "yamldotnet/$version/yamldotnet.$version.nupkg"
    $temporary = $null
    try {
        if (-not (Test-Path -LiteralPath $package -PathType Leaf)) {
            $temporary = [IO.Path]::GetTempFileName()
            $package = $temporary
            Invoke-WebRequest "https://api.nuget.org/v3-flatcontainer/yamldotnet/$version/yamldotnet.$version.nupkg" -OutFile $package -TimeoutSec 60
        }
        if ((Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash -ne '59FFE65ADE67AD9D886267F877B634A450363CB81B94E19DB9CA4C36461416F6') {
            throw 'YamlDotNet package integrity check failed.'
        }
        $zip = [IO.Compression.ZipFile]::OpenRead($package)
        try {
            $entry = $zip.GetEntry('lib/netstandard2.0/YamlDotNet.dll')
            $input = $entry.Open()
            $assembly = [IO.MemoryStream]::new()
            try {
                $input.CopyTo($assembly)
                $null = [Reflection.Assembly]::Load($assembly.ToArray())
            } finally { $input.Dispose(); $assembly.Dispose() }
        } finally { $zip.Dispose() }
    } finally {
        if ($temporary) { [IO.File]::Delete($temporary) }
    }
}

function Convert-InstallerYamlValue($Value) {
    if ($Value -is [Collections.IDictionary]) {
        $mapping = [ordered]@{}
        foreach ($entry in $Value.GetEnumerator()) {
            if ($entry.Key -is [string]) { $mapping[$entry.Key] = Convert-InstallerYamlValue $entry.Value }
        }
        return $mapping
    }
    if ($Value -is [Collections.IList]) {
        $items = foreach ($item in $Value) { Convert-InstallerYamlValue $item }
        return ,@($items)
    }
    return $Value
}

function Read-InstallerConfig([string]$Path) {
    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    Import-InstallerYaml
    $deserializer = [YamlDotNet.Serialization.DeserializerBuilder]::new().WithDuplicateKeyChecking().WithAttemptingUnquotedStringTypeDeserialization().Build()
    $settings = Convert-InstallerYamlValue ($deserializer.Deserialize([IO.File]::ReadAllText($file.FullName)))
    if ($settings -isnot [Collections.IDictionary]) { throw 'The installer YAML must contain a mapping.' }
    foreach ($key in @($settings.Keys)) {
        if ($settings[$key] -is [string] -and [string]::IsNullOrWhiteSpace($settings[$key])) { $settings[$key] = $null }
    }
    $version = $settings['version']
    if ($version -isnot [string] -or $version -notmatch '^[0-9]{1,5}\.[0-9]{1,5}\.[0-9]{1,5}(\.[0-9]{1,5})?\z' -or
        ($version.Split('.') | Where-Object { [int]$_ -gt 65535 })) {
        $settings['version'] = ''
    }
    $publisher = $settings['publisher']
    $settings['publisher'] = if ($publisher -is [string] -and $publisher -notmatch '["\\\x00-\x1f\x7f]') { $publisher.Trim() } else { '' }
    foreach ($name in @('productName', 'productId', 'mainExecutable')) {
        if ([string]::IsNullOrWhiteSpace($settings[$name])) { throw "Missing installer setting: $name" }
        Assert-PathPart $settings[$name]
    }
    if (-not (Test-PayloadExecutable $settings.mainExecutable)) { throw 'mainExecutable must be a valid payload EXE filename.' }

    if (-not (Test-PathPart $settings['installDirectoryName'])) { $settings['installDirectoryName'] = $settings.productId }
    $defaultUserDirectory = 'Programs/' + $settings.installDirectoryName
    $configuredDirectory = $settings['defaultInstallSubdirectory']
    $installSubdirectory = $defaultUserDirectory
    $machineInstall = $false
    if ($configuredDirectory -is [string] -and $configuredDirectory -match '^[/\\](AppData|ProgramFiles)(?:[/\\](.*))?\z') {
        $base = $Matches[1]
        $suffix = ([string]$Matches[2]).TrimEnd([char[]]@('/', '\'))
        if (-not $suffix -or (Test-RelativePath $suffix)) {
            $machineInstall = $base -eq 'ProgramFiles'
            if ($suffix) { $installSubdirectory = $suffix }
            elseif ($machineInstall) { $installSubdirectory = $settings.installDirectoryName }
        }
    } elseif (Test-RelativePath $configuredDirectory) {
        $installSubdirectory = $configuredDirectory
    }
    $settings['defaultInstallSubdirectory'] = $installSubdirectory
    $defaults = @{
        architecture = 'x64'
        dataSubdirectory = $settings.productId
        tempSubdirectory = 'EricSoftInstaller/' + $settings.productId
        shortcutName = $settings.productName
        appUserModelId = $settings.productId
        startupValueName = $settings.productId
        uninstallerName = 'Uninstall.exe'
        allowExtract = $true
        restartAfterInstall = $false
        defaultDesktopShortcut = $false
        defaultStartMenuShortcut = $true
        defaultKeepData = $true
        companionExecutables = @()
        shutdownPipeName = ''
        shutdownPipeCommand = 'EXIT'
        protectedPaths = @()
        requiredPayloadFiles = @()
        excludedPayloadPatterns = @('*.pdb', '*.log', '*.bak')
        text = @{}
        icon = ''
    }
    foreach ($entry in $defaults.GetEnumerator()) { $settings[$entry.Key] ??= $entry.Value }
    if ($settings.text -isnot [Collections.IDictionary]) { $settings.text = $defaults.text }
    $settings.architecture = if ($settings.architecture -is [string] -and $settings.architecture -in @('x64', 'arm64', 'x86')) {
        $settings.architecture.ToLowerInvariant()
    } else { $defaults.architecture }
    foreach ($name in @('appUserModelId', 'startupValueName', 'shortcutName', 'shutdownPipeName')) {
        if (-not (Test-PathPart $settings[$name])) { $settings[$name] = $defaults[$name] }
    }
    if ($settings.appUserModelId.Length -gt 128 -or $settings.appUserModelId -match '\s') { $settings.appUserModelId = $defaults.appUserModelId }
    if ($settings.appUserModelId.Length -gt 128 -or $settings.appUserModelId -match '\s') {
        throw 'Provide a productId or appUserModelId with at most 128 characters and no whitespace.'
    }
    if (-not (Test-PayloadExecutable $settings.uninstallerName) -or $settings.uninstallerName -eq $settings.mainExecutable) {
        $settings.uninstallerName = $defaults.uninstallerName
    }
    if ($settings.mainExecutable -eq $settings.uninstallerName) { throw 'The main executable and uninstaller need distinct names.' }
    foreach ($name in @('dataSubdirectory', 'tempSubdirectory')) {
        if (-not (Test-RelativePath $settings[$name])) { $settings[$name] = $defaults[$name] }
    }
    foreach ($name in @('defaultDesktopShortcut', 'defaultStartMenuShortcut', 'defaultKeepData', 'allowExtract', 'restartAfterInstall')) {
        if ($settings[$name] -isnot [bool]) { $settings[$name] = $defaults[$name] }
    }
    $settings.companionExecutables = @($settings.companionExecutables | Where-Object {
        (Test-PayloadExecutable $_) -and $_ -ne $settings.uninstallerName -and $_ -ne $settings.mainExecutable
    })
    $executables = @($settings.mainExecutable, $settings.uninstallerName) + $settings.companionExecutables
    $settings.protectedPaths = @($settings.protectedPaths | Where-Object {
        (Test-PathPart $_) -and $_ -notin $executables -and $_ -notlike '._*' -and $_ -notlike '.migration-*'
    })
    $settings.requiredPayloadFiles = @($settings.requiredPayloadFiles | Where-Object { Test-RelativePath $_ })
    $patterns = @($settings.excludedPayloadPatterns | Where-Object { Test-PayloadPattern $_ })
    if ($patterns.Count -eq 0 -and @($settings.excludedPayloadPatterns).Count -gt 0) { $patterns = $defaults.excludedPayloadPatterns }
    $settings.excludedPayloadPatterns = $patterns
    if ($settings.shutdownPipeCommand -isnot [string] -or $settings.shutdownPipeCommand -match '[\x00-\x1f]') {
        $settings.shutdownPipeCommand = $defaults.shutdownPipeCommand
    }
    $icon = if ((Test-RelativePath $settings.icon) -and $settings.icon -like '*.ico') {
        $candidate = Get-Item -LiteralPath (Join-Path $file.DirectoryName $settings.icon) -ErrorAction SilentlyContinue
        if ($candidate -is [IO.FileInfo]) { $candidate.FullName }
    }
    return [pscustomobject]@{ File = $file.FullName; Settings = $settings; Icon = $icon; MachineInstall = $machineInstall }
}

function Assert-PayloadEntries($Entries, $Settings) {
    # Keep these bounds in sync with Extract in native/setup.core/Installer.cpp.
    if ($Entries.Count -gt 100000) { throw 'The payload has more than 100,000 ZIP entries.' }
    $totalSize = 0L
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $files = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $Entries) {
        $path = $entry.FullName.Replace('\', '/')
        $directory = $path.EndsWith('/')
        $path = $path.TrimEnd('/')
        $parts = @(Get-PathParts $path)
        $top = $parts[0]
        if ($top.StartsWith('._') -or $top.StartsWith('.migration-', [StringComparison]::OrdinalIgnoreCase) -or $top -in $Settings.protectedPaths -or $top -eq $Settings.uninstallerName) {
            throw "Payload contains a reserved path: $path"
        }
        foreach ($pattern in $Settings.excludedPayloadPatterns) {
            if ($path -like $pattern -or ($parts | Where-Object { $_ -like $pattern })) { throw "Payload contains an excluded file or directory: $path" }
        }
        if (-not $seen.Add($path)) { throw "Payload contains a duplicate path: $path" }
        if (-not $directory) {
            $totalSize += $entry.Length
            if ($entry.Length -gt 4GB -or $totalSize -gt 8GB) { throw "Payload exceeds the size limit at: $path" }
            $null = $files.Add($path)
        }
    }
    foreach ($file in $files) {
        $parts = $file.Split('/')
        for ($i = 1; $i -lt $parts.Length; $i++) {
            if ($files.Contains(($parts[0..($i - 1)] -join '/'))) { throw "Payload uses a file as a directory: $file" }
        }
    }
    foreach ($required in @($Settings.mainExecutable) + @($Settings.companionExecutables) + @($Settings.requiredPayloadFiles)) {
        $name = (Get-PathParts $required) -join '/'
        if (-not $files.Contains($name)) { throw "Payload is missing $name." }
    }
}

function Quote-Cpp([string]$Value) {
    return '"' + $Value.Replace('\', '\\').Replace('"', '\"').Replace([string][char]13, '\r').Replace([string][char]10, '\n').Replace([string][char]9, '\t') + '"'
}

function Write-NativeProfile($Configuration, [string]$Destination) {
    $settings = $Configuration.Settings
    $fields = [ordered]@{
        Product = $settings.productName
        Publisher = $settings.publisher
        Version = $settings.version
        MainExecutable = $settings.mainExecutable
        UninstallerName = $settings.uninstallerName
        InstallDirectoryName = $settings.installDirectoryName
        ShortcutFile = $settings.shortcutName + '.lnk'
        AppUserModelId = $settings.appUserModelId
        StartupValueName = $settings.startupValueName
        ShutdownPipeName = $settings.shutdownPipeName
        WindowClass = $settings.productId + '.ModernSetup'
        DataMutexPrefix = 'Local\' + $settings.productName + '.Data.'
        UninstallKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\' + $settings.productId
        AppPathKey = 'Software\Microsoft\Windows\CurrentVersion\App Paths\' + $settings.mainExecutable
        DefaultInstallSubdirectory = $settings.defaultInstallSubdirectory.Replace('/', '\')
        DataSubdirectory = $settings.dataSubdirectory.Replace('/', '\')
        TempSubdirectory = $settings.tempSubdirectory.Replace('/', '\')
    }
    $lines = [Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]]@('#pragma once', '#include <array>', 'namespace setup {'))
    foreach ($field in $fields.Keys) { $lines.Add("inline constexpr auto $field = L$(Quote-Cpp $fields[$field]);") }
    $machineInstall = $Configuration.MachineInstall.ToString().ToLowerInvariant()
    $lines.Add("inline constexpr bool MachineInstall = $machineInstall;")
    $lines.Add("inline constexpr auto ShutdownPipeCommand = $(Quote-Cpp $settings.shutdownPipeCommand);")
    foreach ($field in @('DefaultDesktopShortcut', 'DefaultStartMenuShortcut', 'DefaultKeepData', 'AllowExtract', 'RestartAfterInstall')) {
        $key = $field.Substring(0, 1).ToLowerInvariant() + $field.Substring(1)
        $value = $settings[$key].ToString().ToLowerInvariant()
        $lines.Add("inline constexpr bool $field = $value;")
    }
    foreach ($field in @('CompanionExecutables', 'ProtectedPaths')) {
        $key = $field.Substring(0, 1).ToLowerInvariant() + $field.Substring(1)
        $values = @($settings[$key] | ForEach-Object { 'L' + (Quote-Cpp $_) })
        $lines.Add("inline constexpr std::array<const wchar_t*, $($values.Count)> $field = { $($values -join ', ') };")
    }
    $translations = $settings.text
    $languages = @($translations.Keys | Where-Object { $_ -is [string] -and $translations[$_] -is [Collections.IDictionary] })
    $entries = [Collections.Generic.List[string]]::new()
    foreach ($language in $languages) {
        foreach ($key in $translations[$language].Keys) {
            $value = $translations[$language][$key]
            if ($key -isnot [string] -or $key -notlike 'Installer_*' -or $value -isnot [string] -or $value -match '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]') { continue }
            $value = $value.Replace('{product}', $settings.productName).Replace('{publisher}', $settings.publisher).Trim()
            if ($value) { $entries.Add("    { L$(Quote-Cpp $language), $(Quote-Cpp $key), L$(Quote-Cpp $value) },") }
        }
    }
    $quotedLanguages = @($languages | ForEach-Object { 'L' + (Quote-Cpp $_) })
    $lines.Add("inline constexpr std::array<const wchar_t*, $($languages.Count)> TextLanguages = { $($quotedLanguages -join ', ') };")
    $lines.Add('struct TextEntry { const wchar_t* language; const char* key; const wchar_t* value; };')
    $lines.Add("inline constexpr std::array<TextEntry, $($entries.Count)> Translations = {{")
    $lines.AddRange($entries)
    $lines.AddRange([string[]]@('}};', '}'))
    [IO.File]::WriteAllLines($Destination, $lines, [Text.UTF8Encoding]::new($false))
}

function Add-SetupPayload([string]$Installer, [string]$Zip, $Settings) {
    $source = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        Assert-PayloadEntries $source.Entries $Settings
        $output = [IO.File]::Open($Installer, 'Open', 'ReadWrite', 'None')
        try {
            $output.Position = $output.Length
            $archive = [IO.Compression.ZipArchive]::new($output, 'Create', $true)
            try {
                foreach ($entry in $source.Entries) {
                    $copy = $archive.CreateEntry($entry.FullName.Replace('\', '/'))
                    $copy.LastWriteTime = $entry.LastWriteTime
                    $input = $entry.Open()
                    try {
                        $target = $copy.Open()
                        try { $input.CopyTo($target) } finally { $target.Dispose() }
                    } finally { $input.Dispose() }
                }
            } finally { $archive.Dispose() }
            $output.Flush($true)
        } finally { $output.Dispose() }
    } finally { $source.Dispose() }
    $check = [IO.Compression.ZipFile]::OpenRead($Installer)
    try { Assert-PayloadEntries $check.Entries $Settings } finally { $check.Dispose() }
}

function Remove-BuildWorkspace([string]$Directory) {
    $full = [IO.Path]::GetFullPath($Directory)
    $tempRoot = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath([IO.Path]::GetTempPath()))
    if (([IO.Path]::GetDirectoryName($full) -eq $tempRoot) -and ([IO.Path]::GetFileName($full) -like 'EricSoftInstaller-*')) {
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}

Export-ModuleMember -Function Read-InstallerConfig, Assert-PayloadEntries, Write-NativeProfile, Add-SetupPayload, Remove-BuildWorkspace
