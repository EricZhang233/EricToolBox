<#
.SYNOPSIS
  EricNotificationToolkit - display a Windows notification with a custom head line.
.DESCRIPTION
  Accepts notification parameters, builds the host in
  %TEMP%\eric\EricNotificationToolkit\, displays the notification,
  and cleans the temporary directory after the host exits.

  The head line is compiled into the assembly identity, so the host is rebuilt
  for every invocation. Only the built-in C# compiler is required.
.PARAMETER Head
  Notification name line, shown as supplied.
.PARAMETER Title
  Content title line; empty means no title.
.PARAMETER Body
  Notification body; use </p> to separate lines.
.PARAMETER Image
  System icon: info, warning, or error. Empty or 0 hides the icon.
.PARAMETER Help
  Show usage and exit without sending a notification.
.EXAMPLE
  .\EricNotificationToolkit.ps1 -Head 'EricNotificationToolkit - Report' -Body 'Cleanup complete</p>Program: pwsh.exe' -Image info
.EXAMPLE
  # The body can also be read from a file with one line per item.
  $b = ((Get-Content .\example-body.txt) | Where-Object { $_.Trim() }) -join '</p>'
  .\EricNotificationToolkit.ps1 -Head 'EricNotificationToolkit' -Body $b
#>
param(
    [string]$Head    = 'EricNotificationToolkit',
    [string]$Title   = '',
    [string]$Body    = '',
    [string]$Image   = '',
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

function Show-Help {
    @'
EricNotificationToolkit

Usage:
  .\EricNotificationToolkit.ps1 -Head <head> -Body <body> [-Title <title>] [-Image <image>]

Parameters:
  -Head   Notification name line. Default: EricNotificationToolkit
  -Title  Optional content title line
  -Body   Required body; use </p> to separate lines
  -Image  info, warning, error, or 0. Empty or 0 hides the icon
  -Help   Show this help

Example:
  .\EricNotificationToolkit.ps1 -Head 'Build complete' -Body 'Build passed</p>Program: pwsh.exe' -Image info
'@
}

trap {
    Show-Help
    exit 1
}

if ($Help) {
    Show-Help
    exit 0
}

if (-not $Body -or $Image -notmatch '^(?i:|0|info|warning|error|\[(info|warning|error)\])$') {
    Show-Help
    exit 1
}

# Use the built-in C# compiler; fall back to Framework on 32-bit systems.
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$platform = 'x64'
if (-not (Test-Path $csc)) {
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
    $platform = 'anycpu'
}
if (-not (Test-Path $csc)) { throw "Built-in csc compiler not found: $csc" }

# Keep all build artifacts in temp without changing the caller's working directory.
$runDir = Join-Path $env:TEMP ('eric\EricNotificationToolkit\' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $runDir -Force | Out-Null
$exe   = Join-Path $runDir 'EricNotificationToolkit.exe'
$brand = Join-Path $runDir 'Brand.cs'
$src   = Join-Path $runDir 'EricNotificationToolkit.cs'
$ico   = Join-Path $runDir 'blank.ico'
$cleanup = Join-Path $runDir 'Cleanup.ps1'
$headFile = Join-Path $runDir 'Head.txt'
$signalFile = Join-Path $runDir 'NotificationStarted'
$utf8  = New-Object Text.UTF8Encoding($true)

# The host source is embedded and written to this temporary directory at runtime.
$source = @'
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Windows.Forms;

// The notification name line is part of the compiled assembly identity.
class EricNotificationToolkit
{
    static NotifyIcon tray;
    static Timer life;

    static string Opt(string a)
    {
        if (a == null || a.Length == 0 || a[0] != '-') { return null; }
        return a.TrimStart('-').ToLowerInvariant();
    }

    static ToolTipIcon Glyph(string spec)
    {
        string s = spec == null ? "" : spec.Trim().ToLowerInvariant();
        if (s.Length > 1 && s[0] == '[' && s[s.Length - 1] == ']') { s = s.Substring(1, s.Length - 2).Trim(); }
        if (s == "info") { return ToolTipIcon.Info; }
        if (s == "warning" || s == "exclamation") { return ToolTipIcon.Warning; }
        if (s == "error" || s == "hand") { return ToolTipIcon.Error; }
        return ToolTipIcon.None;
    }

    static string Head()
    {
        try
        {
            FileVersionInfo v = FileVersionInfo.GetVersionInfo(Application.ExecutablePath);
            if (v.FileDescription != null && v.FileDescription.Length > 0) { return v.FileDescription; }
            if (v.ProductName != null && v.ProductName.Length > 0) { return v.ProductName; }
        }
        catch { }
        return "EricNotificationToolkit";
    }

    [STAThread]
    static void Main(string[] args)
    {
        if (args.Length == 0) { return; }

        string title = "";
        string body = "";
        string image = "";
        string signalFile = "";

        for (int i = 0; i < args.Length; i++)
        {
            string opt = Opt(args[i]);
            if (opt == "title" && i + 1 < args.Length) { title = args[i + 1]; i++; }
            else if (opt == "body" && i + 1 < args.Length) { body = args[i + 1]; i++; }
            else if (opt == "image" && i + 1 < args.Length) { image = args[i + 1]; i++; }
            else if (opt == "signal" && i + 1 < args.Length) { signalFile = args[i + 1]; i++; }
        }

        if (body.Length == 0) { return; }
        body = body.Replace("</p>", "\r\n");

        string tip = title.Length > 0 ? title : Head();
        if (tip.Length > 62) { tip = tip.Substring(0, 62); }

        Application.EnableVisualStyles();

        Icon appIcon = null;
        try { appIcon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); }
        catch { }

        tray = new NotifyIcon();
        tray.Icon = appIcon != null ? appIcon : SystemIcons.Information;
        tray.Text = tip;
        if (title.Length > 0) { tray.BalloonTipTitle = title; }
        tray.BalloonTipText = body;
        tray.BalloonTipIcon = Glyph(image);
        tray.Visible = true;
        tray.ShowBalloonTip(0);
        if (signalFile.Length > 0) { File.WriteAllText(signalFile, "started"); }

        life = new Timer();
        life.Interval = 15000;
        life.Tick += delegate
        {
            life.Stop();
            tray.Visible = false;
            tray.Dispose();
            Application.Exit();
        };
        life.Start();

        Application.Run();
    }
}
'@
[IO.File]::WriteAllText($src, $source, $utf8)
[IO.File]::WriteAllText($headFile, $Head, $utf8)
[IO.File]::WriteAllText($cleanup, @'
param(
    [int]$ProcessId,
    [string]$HeadFile,
    [string]$RunDir,
    [string]$SignalFile
)

for ($i = 0; $i -lt 600 -and -not (Test-Path -LiteralPath $SignalFile); $i++) {
    Start-Sleep -Milliseconds 50
}
Start-Sleep -Milliseconds 1000
$head = Get-Content -LiteralPath $HeadFile -Raw -ErrorAction SilentlyContinue

$appUserModelRoot = 'HKCU:\Software\Classes\AppUserModelId'
if (Test-Path -LiteralPath $appUserModelRoot) {
    Get-ChildItem -LiteralPath $appUserModelRoot -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -like 'NotifyIconGeneratedAumid_*' } |
        ForEach-Object {
            $displayName = (Get-ItemProperty -LiteralPath $_.PSPath -Name DisplayName -ErrorAction SilentlyContinue).DisplayName
            if ([string]$displayName -eq [string]$head) {
                Remove-Item -LiteralPath $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
}

foreach ($root in @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications\Backup'
)) {
    if (Test-Path -LiteralPath $root) {
        Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -eq $head } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$escapedRunDir = $RunDir.Replace("'", "''")
$finalizer = "Wait-Process -Id $ProcessId -Timeout 120 -ErrorAction SilentlyContinue; " +
             "Remove-Item -LiteralPath '$escapedRunDir' -Recurse -Force -ErrorAction SilentlyContinue"
Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') `
    -ArgumentList @('-NoProfile', '-Command', $finalizer) `
    -WindowStyle Hidden
'@, $utf8)

# Write the head line into the assembly identity (UTF-8 with BOM).
$literal = $Head.Replace('\', '\\').Replace('"', '\"')
[IO.File]::WriteAllText($brand, @"
using System.Reflection;
[assembly: AssemblyTitle("$literal")]
[assembly: AssemblyProduct("$literal")]
[assembly: AssemblyDescription("$literal")]
[assembly: AssemblyCompany("$literal")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]
"@, $utf8)

# Create a fully transparent 32x32 icon so the notification has no app icon.
Add-Type -AssemblyName System.Drawing
$bmp = New-Object System.Drawing.Bitmap 32, 32
$png = New-Object IO.MemoryStream
$bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
$pngBytes = $png.ToArray()
$ms = New-Object IO.MemoryStream
$bw = New-Object IO.BinaryWriter($ms)
$bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]1)
$bw.Write([Byte]32); $bw.Write([Byte]32); $bw.Write([Byte]0); $bw.Write([Byte]0)
$bw.Write([UInt16]1); $bw.Write([UInt16]32)
$bw.Write([UInt32]$pngBytes.Length); $bw.Write([UInt32]22)
$bw.Write($pngBytes)
$bw.Flush(); $bw.Dispose(); $bmp.Dispose()
[IO.File]::WriteAllBytes($ico, $ms.ToArray())

& $csc /nologo /codepage:65001 /win32icon:"$ico" /target:winexe /platform:$platform /optimize+ /out:"$exe" "$brand" "$src" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Compilation failed (exit $LASTEXITCODE)." }

# Quote every argument because Start-Process does not quote array elements.
function Quote([string]$value) { '"' + $value.Replace('"', '\"') + '"' }

$argLine = '--title ' + (Quote $Title) + ' --body ' + (Quote $Body) + ' --image ' + (Quote $Image) +
           ' --signal ' + (Quote $signalFile)
$proc = Start-Process -FilePath $exe -ArgumentList $argLine -PassThru

# Clean up notification registrations and build artifacts after the host exits.
$cleanerArgs = '-NoProfile -File ' + (Quote $cleanup) +
               ' -ProcessId ' + $proc.Id +
               ' -HeadFile ' + (Quote $headFile) +
               ' -RunDir ' + (Quote $runDir) +
               ' -SignalFile ' + (Quote $signalFile)
Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList $cleanerArgs -WindowStyle Hidden
