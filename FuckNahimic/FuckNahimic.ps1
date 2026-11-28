<#
.SYNOPSIS
Previews or removes local Nahimic and Sonic Studio components.
.DESCRIPTION
For a discovered OEM audio device, the plan switches the device to
the in-box Microsoft driver, backs up the identified OEM audio driver packages,
and removes the matching Realtek base, extensions, and card-specific Realtek components.
Removes Realtek Audio Control registrations and provisioning. The affected sound card's endpoint
names are saved before cleanup and restored once after the next restart.
On the verified hardware, FuckNahimic monitors pending driver offers after cleanup.
-InstallGuard installs only the watcher. -RemoveGuard removes only the watcher.
-SkipGuard skips the watcher during cleanup.
-CheckOnly returns 0 when actions are planned, 1 when none are needed,
and 2 when the scan is incomplete.
#>
[CmdletBinding()]
param(
    [switch]$AutoApprove,
    [switch]$CheckOnly,
    [switch]$SkipReboot,
    [switch]$InstallGuard,
    [switch]$RemoveGuard,
    [switch]$SkipGuard,
    [switch]$NoPause,
    [string]$LogFile = 'auto'
)

$ScriptVersion = '4.3.4'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Wait-ForUserToReview {
    if ($NoPause -or $Host.Name -ne 'ConsoleHost') { return }
    try {
        if ([Console]::IsInputRedirected) { return }
        [void](Read-Host '运行已结束。按 Enter 关闭此窗口')
    } catch { }
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    Write-Error 'This script requires Windows.' -ErrorAction Continue
    Wait-ForUserToReview
    exit 2
}
if ($LogFile -ne 'auto') {
    try {
        $LogFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogFile)
    } catch {
        Write-Error "Invalid log path: $_" -ErrorAction Continue
        Wait-ForUserToReview
        exit 2
    }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if ($PSVersionTable.PSVersion.Major -lt 7 -or -not $isAdmin) {
    try {
        $pwsh = if ($PSVersionTable.PSVersion.Major -ge 7) {
            Join-Path $PSHOME 'pwsh.exe'
        } else {
            (Get-Command pwsh.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        }
        $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
        if ($AutoApprove) { $arguments += '-AutoApprove' }
        if ($CheckOnly) { $arguments += '-CheckOnly' }
        if ($SkipReboot) { $arguments += '-SkipReboot' }
        if ($InstallGuard) { $arguments += '-InstallGuard' }
        if ($RemoveGuard) { $arguments += '-RemoveGuard' }
        if ($SkipGuard) { $arguments += '-SkipGuard' }
        if ($LogFile -ne 'auto') { $arguments += @('-LogFile', $LogFile) }
        if ($NoPause) { $arguments += '-NoPause' }
        if ($isAdmin) {
            & $pwsh @arguments
            $childExitCode = $LASTEXITCODE
            exit $childExitCode
        }
        $arguments[5] = '"{0}"' -f $PSCommandPath
        if ($LogFile -ne 'auto') {
            $logFileIndex = [Array]::IndexOf($arguments, '-LogFile') + 1
            $arguments[$logFileIndex] = '"{0}"' -f $LogFile
        }
        $child = Start-Process -FilePath $pwsh -Verb RunAs -ArgumentList $arguments -Wait -PassThru
        exit $child.ExitCode
    } catch {
        Write-Error "Could not start elevated PowerShell 7: $_" -ErrorAction Continue
        Wait-ForUserToReview
        exit 2
    }
}

if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    Write-Error 'Run the 64-bit version of PowerShell 7.' -ErrorAction Continue
    Wait-ForUserToReview
    exit 2
}
$PSNativeCommandUseErrorActionPreference = $false

$WindowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$PnpUtil = Join-Path $env:SystemRoot 'System32\pnputil.exe'
$RegistryExe = Join-Path $env:SystemRoot 'System32\reg.exe'
$ServiceExe = Join-Path $env:SystemRoot 'System32\sc.exe'
$script:WindowsUpdateRecoveryTaskName = 'FuckNahimic-RestoreWindowsUpdate'
$TargetPattern = 'Nahimic|A[-_ ]?Volute|NhNotif|\bA[-_ ]?Studio\b|Sonic[-_ ]?Studio|SonicSuite'
$NahimicProvider = '^(?:A[-_ ]?Volute|Nahimic|NhNotif)(?:\s|$)'
$RealtekAudioProvider = '^Realtek(?:\(|\s|$)'
$OemAudioProvider = '^(?:Realtek|Lenovo|A[-_ ]?Volute|Nahimic)(?:\s|$)'
$GenericInf = 'hdaudio.inf'
$RealtekAudioControlAppx = 'RealtekSemiconductorCorp.RealtekAudioControl'
$MediaClass = '{4d36e96c-e325-11ce-bfc1-08002be10318}'
$ExtensionClass = '{e2f84ce7-8efa-411c-aa69-97454ca4cb57}'
$EndpointClass = '{c166523c-fe0c-4a94-a586-f1a80cfbbf3e}'
$SoftwareComponentClass = '{5c4c3332-344d-483c-8739-259e934c9cc8}'
$ApoClass = '{5989fce8-9cd0-467d-8a6a-5419e31529d4}'
$AudioClassPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$MediaClass"
$ApoPaths = @(
    'HKLM:\SOFTWARE\Classes\AudioEngine\AudioProcessingObjects'
    'HKLM:\SOFTWARE\Classes\WOW6432Node\AudioEngine\AudioProcessingObjects'
)
$ApoPropertyPattern = '^\{(?:9B8844FE-1650-40E5-A5EA-11B8C83821A1|F363DF17-A750-4AC3-B7B5-2BBEFFA9085F|E0F2C10F-8244-476E-8EBE-B6EE73D8F2FB|D3465FC4-DB6D-4796-8FDE-0CB851BE2EC9)\}'
function Initialize-DeviceDriverApi {
    if ('FuckNahimic.DeviceDriver' -as [type]) { return }

    Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;

namespace FuckNahimic
{
    public static class DeviceDriver
    {
        private const uint CompatibleDrivers = 2;
        private const int InsufficientBuffer = 122;
        private const int NoMoreItems = 259;

        [StructLayout(LayoutKind.Sequential)]
        private struct DeviceInfo
        {
            public uint Size;
            public Guid ClassGuid;
            public uint DevInst;
            public IntPtr Reserved;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct DriverInfo
        {
            public uint Size;
            public uint DriverType;
            public IntPtr Reserved;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Description;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Manufacturer;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Provider;
            public System.Runtime.InteropServices.ComTypes.FILETIME Date;
            public ulong Version;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct DriverDetail
        {
            public uint Size;
            public System.Runtime.InteropServices.ComTypes.FILETIME Date;
            public uint CompatibleIdsOffset;
            public uint CompatibleIdsLength;
            public IntPtr Reserved;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string SectionName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string InfPath;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Description;
            public ushort FirstHardwareIdCharacter;
        }

        [DllImport("setupapi.dll", ExactSpelling = true, SetLastError = true)]
        private static extern IntPtr SetupDiCreateDeviceInfoList(IntPtr classGuid, IntPtr parent);

        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        private static extern bool SetupDiOpenDeviceInfoW(
            IntPtr set, string instanceId, IntPtr parent, uint flags, ref DeviceInfo device);

        [DllImport("setupapi.dll", ExactSpelling = true, SetLastError = true)]
        private static extern bool SetupDiBuildDriverInfoList(IntPtr set, ref DeviceInfo device, uint type);

        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        private static extern bool SetupDiEnumDriverInfoW(
            IntPtr set, ref DeviceInfo device, uint type, uint index, ref DriverInfo driver);

        [DllImport("setupapi.dll", ExactSpelling = true, SetLastError = true)]
        private static extern bool SetupDiGetDriverInfoDetailW(
            IntPtr set, ref DeviceInfo device, ref DriverInfo driver, IntPtr detail, uint size, out uint required);

        [DllImport("setupapi.dll", ExactSpelling = true)]
        private static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);

        [DllImport("newdev.dll", ExactSpelling = true, SetLastError = true)]
        private static extern bool DiInstallDevice(
            IntPtr parent, IntPtr set, ref DeviceInfo device, ref DriverInfo driver, uint flags,
            [MarshalAs(UnmanagedType.Bool)] out bool needReboot);

        private static Win32Exception Failure(string operation, int code)
        {
            return new Win32Exception(code, operation + ": " + new Win32Exception(code).Message);
        }

        private static string GetInfName(IntPtr set, ref DeviceInfo device, ref DriverInfo driver)
        {
            uint required;
            if (!SetupDiGetDriverInfoDetailW(set, ref device, ref driver, IntPtr.Zero, 0, out required))
            {
                int error = Marshal.GetLastWin32Error();
                if (error != InsufficientBuffer)
                    throw Failure("Get driver information size", error);
            }

            int headerSize = Marshal.SizeOf<DriverDetail>();
            int bufferSize = Math.Max(headerSize, checked((int)required));
            IntPtr buffer = Marshal.AllocHGlobal(bufferSize);
            try
            {
                Marshal.WriteInt32(buffer, headerSize);
                if (!SetupDiGetDriverInfoDetailW(set, ref device, ref driver, buffer, (uint)bufferSize, out required))
                    throw Failure("Read driver information", Marshal.GetLastWin32Error());
                return Path.GetFileName(Marshal.PtrToStructure<DriverDetail>(buffer).InfPath);
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }

        public static bool Select(string instanceId, string infName, string provider, bool install)
        {
            IntPtr set = SetupDiCreateDeviceInfoList(IntPtr.Zero, IntPtr.Zero);
            if (set == new IntPtr(-1))
                throw Failure("Create device information list", Marshal.GetLastWin32Error());
            try
            {
                var device = new DeviceInfo { Size = (uint)Marshal.SizeOf<DeviceInfo>() };
                if (!SetupDiOpenDeviceInfoW(set, instanceId, IntPtr.Zero, 0, ref device))
                    throw Failure("Open device instance", Marshal.GetLastWin32Error());
                if (!SetupDiBuildDriverInfoList(set, ref device, CompatibleDrivers))
                    throw Failure("List compatible drivers", Marshal.GetLastWin32Error());

                for (uint index = 0; ; index++)
                {
                    var driver = new DriverInfo { Size = (uint)Marshal.SizeOf<DriverInfo>() };
                    if (!SetupDiEnumDriverInfoW(set, ref device, CompatibleDrivers, index, ref driver))
                    {
                        int error = Marshal.GetLastWin32Error();
                        if (error == NoMoreItems)
                            throw new InvalidOperationException("The requested compatible driver was not found: " + infName);
                        throw Failure("Enumerate compatible driver", error);
                    }
                    if (!String.Equals(driver.Provider, provider, StringComparison.OrdinalIgnoreCase) ||
                        !String.Equals(GetInfName(set, ref device, ref driver), infName, StringComparison.OrdinalIgnoreCase))
                        continue;

                    if (!install)
                        return false;
                    bool needReboot;
                    if (!DiInstallDevice(IntPtr.Zero, set, ref device, ref driver, 0, out needReboot))
                        throw Failure("Bind selected driver to device", Marshal.GetLastWin32Error());
                    return needReboot;
                }
            }
            finally
            {
                SetupDiDestroyDeviceInfoList(set);
            }
        }
    }
}
"@
}

function Invoke-Native {
    param(
        [string]$File,
        [string[]]$Arguments,
        [switch]$AllowRebootRequired
    )

    $output = @(& $File @Arguments 2>&1)
    $code = $LASTEXITCODE
    if ($code -eq 3010 -and $AllowRebootRequired) {
        $script:RebootRequired = $true
    } elseif ($code -ne 0) {
        throw "$([IO.Path]::GetFileName($File)) $($Arguments -join ' ') exited with code $code. $($output -join ' ')"
    }
    $output | ForEach-Object { [string]$_ }
}

function Invoke-WindowsPowerShell {
    param([string]$Command)

    $command = '$ErrorActionPreference = "Stop"; $ProgressPreference = "SilentlyContinue"; [Console]::OutputEncoding = [Text.Encoding]::UTF8; ' + $Command
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $savedEncoding = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [Text.Encoding]::UTF8
        Invoke-Native $WindowsPowerShell @('-NoLogo','-NoProfile','-NonInteractive','-OutputFormat','Text','-EncodedCommand',$encoded)
    } finally {
        [Console]::OutputEncoding = $savedEncoding
    }
}

function Get-ProvisionedAppx {
    param([string]$RemovePackage)

    # The DISM AppX COM class is available in Windows PowerShell 5.1 on the target.
    if ($RemovePackage) {
        $literal = $RemovePackage.Replace("'", "''")
        Invoke-WindowsPowerShell "Remove-AppxProvisionedPackage -Online -PackageName '$literal' -ErrorAction Stop | Out-Null"
        return
    }
    $output = @(Invoke-WindowsPowerShell 'Get-AppxProvisionedPackage -Online | Select-Object DisplayName,PackageName | ConvertTo-Json -Compress')
    if ($output.Count) { ($output -join [Environment]::NewLine) | ConvertFrom-Json }
}

function Remove-InstalledAppx {
    param([string]$FullName)

    $literal = $FullName.Replace("'", "''")
    $command = '$packageFullName = ' + "'$literal'; " + @'
function Get-ExactPackage {
    Get-AppxPackage -AllUsers -PackageTypeFilter Main,Bundle | Where-Object PackageFullName -EQ $packageFullName
}

$package = @(Get-ExactPackage)
if (-not $package.Count) { return }
if ($package | Where-Object NonRemovable) { throw "Windows marks $packageFullName as non-removable." }

$currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$registrations = @($package | ForEach-Object PackageUserInformation | Where-Object InstallState -EQ 'Installed')
$owners = @(foreach ($registration in $registrations) {
    $identity = $registration.UserSecurityId
    if ($identity -is [Security.Principal.SecurityIdentifier]) {
        $identity.Value
    } elseif ($identity -and $identity.PSObject.Properties['Sid']) {
        [string]$identity.Sid
    } else {
        [string]$identity
    }
})
$owners = @($owners | Where-Object { $_ -match '^S-1-\d+(?:-\d+)+$' } | Select-Object -Unique)
if ($owners.Count -eq 1 -and $owners[0] -eq $currentSid -and $registrations.Count -eq 1) {
    Remove-AppxPackage -Package $packageFullName
} else {
    try {
        Remove-AppxPackage -Package $packageFullName -AllUsers
    } catch {
        $allUsersError = $_
        if (-not $owners.Count -or $owners.Count -ne $registrations.Count) { throw $allUsersError }
        foreach ($owner in $owners) {
            if ($owner -eq $currentSid) {
                Remove-AppxPackage -Package $packageFullName
            } else {
                Remove-AppxPackage -Package $packageFullName -User $owner
            }
        }
    }
}
$remaining = @(Get-ExactPackage | ForEach-Object PackageUserInformation | Where-Object InstallState -EQ 'Installed')
if ($remaining.Count) { throw "The application is still installed after removal: $packageFullName." }
'@
    Invoke-WindowsPowerShell $command | ForEach-Object { Write-Host $_ }
}

function Get-DriverInventory {
    $lines = @(Invoke-Native $PnpUtil @('/enum-drivers','/devices','/format','csv'))
    if ($lines.Count -eq 0 -or $lines[0] -notmatch '^(?:"?DriverName"?),') {
        throw 'PnPUtil did not provide the structured driver and device inventory.'
    }
    $rows = @(($lines -join [Environment]::NewLine) | ConvertFrom-Csv)
    $bindings = @{}
    foreach ($row in $rows) {
        if ($row.Device) {
            if (-not $bindings.ContainsKey($row.DriverName)) {
                $bindings[$row.DriverName] = [System.Collections.Generic.List[string]]::new()
            }
            $bindings[$row.DriverName].Add($row.Device)
        }
    }
    foreach ($row in $rows) {
        if (-not $row.OriginalName) { continue }
        if ($row.DriverName -notmatch '^oem\d+\.inf$' -or $row.ClassGuid -notmatch '^\{[0-9a-f-]{36}\}$') {
            throw "Invalid driver inventory entry: $($row.DriverName), $($row.OriginalName)."
        }
        $ids = if ($bindings.ContainsKey($row.DriverName)) { $bindings[$row.DriverName] }
        [pscustomobject]@{
            Name = $row.DriverName
            Original = $row.OriginalName
            Provider = $row.ProviderName
            Class = $row.ClassGuid
            Version = $row.DriverVersion
            Devices = @($ids | Select-Object -Unique)
        }
    }
}

function Get-CurrentInf {
    param([string]$InstanceId)
    [string](Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName DEVPKEY_Device_DriverInfPath).Data
}

function Initialize-AudioEndpointApi {
    if ('FuckNahimic.AudioEndpointApi' -as [type]) { return }
    Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace FuckNahimic
{
    public sealed class AudioEndpoint
    {
        public string Id;
        public string StableId;
        public string Name;
        public string Description;
        public int Direction;
        public int FormFactor;
        public string JackType;
        public int State;
    }

    public static class AudioEndpointApi
    {
        private const int AvailableEndpointStates = 0x0B;
        private const int AllEndpointStates = 0x0F;
        private const ushort StringType = 31;
        private const ushort UnsignedType = 19;
        private static readonly Guid EndpointProperties = new Guid("1da5d803-d492-4edd-8c23-e0c0ffee7f0e");
        private static readonly Guid DeviceProperties = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0");
        private static readonly Guid EnumeratorClass = new Guid("bcde0395-e52f-467c-8e3d-c4579291692e");
        private static readonly Guid PolicyClass = new Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9");

        [StructLayout(LayoutKind.Sequential)]
        private struct PropertyKey
        {
            public Guid Format;
            public uint Id;
            public PropertyKey(Guid format, uint id) { Format = format; Id = id; }
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PropVariant
        {
            public ushort Type, Reserved1, Reserved2, Reserved3;
            public IntPtr Value;
            public IntPtr Padding;
        }

        [ComImport, Guid("a95664d2-9614-4f35-a746-de8db63617e6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface DeviceEnumerator
        {
            [PreserveSig] int EnumAudioEndpoints(int direction, int states, out DeviceCollection collection);
            [PreserveSig] int GetDefaultAudioEndpoint(int direction, int role, out Device device);
            [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out Device device);
        }

        [ComImport, Guid("0bd7a1be-7a1a-44db-8397-cc5392387b5e"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface DeviceCollection
        {
            [PreserveSig] int GetCount(out uint count);
            [PreserveSig] int Item(uint index, out Device device);
        }

        [ComImport, Guid("d666063f-1587-4e43-81f1-b948e807363f"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface Device
        {
            [PreserveSig] int Activate(ref Guid id, int clsContext, IntPtr arguments, out IntPtr result);
            [PreserveSig] int OpenPropertyStore(int access, out Store store);
            [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
            [PreserveSig] int GetState(out int state);
        }

        [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface Store
        {
            [PreserveSig] int GetCount(out uint count);
            [PreserveSig] int GetAt(uint index, out PropertyKey key);
            [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
            [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
            [PreserveSig] int Commit();
        }

        // The endpoint policy interface mirrors the Sound control panel's endpoint properties.
        // Preceding methods declare vtable slots only. SetPropertyValue is the only slot called.
        [ComImport, Guid("f8679f50-850a-41cf-9c72-430f290290c8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface EndpointPolicy
        {
            [PreserveSig] int GetMixFormat();
            [PreserveSig] int GetDeviceFormat();
            [PreserveSig] int ResetDeviceFormat();
            [PreserveSig] int SetDeviceFormat();
            [PreserveSig] int GetProcessingPeriod();
            [PreserveSig] int SetProcessingPeriod();
            [PreserveSig] int GetShareMode();
            [PreserveSig] int SetShareMode();
            [PreserveSig] int GetPropertyValue();
            [PreserveSig] int SetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string id, int fxStore,
                ref PropertyKey key, ref PropVariant value);
        }

        [DllImport("ole32.dll", ExactSpelling = true)]
        private static extern int PropVariantClear(ref PropVariant value);

        private static string Text(Store store, PropertyKey key)
        {
            PropVariant value;
            int result = store.GetValue(ref key, out value);
            try
            {
                return result >= 0 && value.Type == StringType ? Marshal.PtrToStringUni(value.Value) : null;
            }
            finally { PropVariantClear(ref value); }
        }

        private static int Number(Store store, PropertyKey key)
        {
            PropVariant value;
            int result = store.GetValue(ref key, out value);
            try
            {
                return result >= 0 && value.Type == UnsignedType ? unchecked((int)value.Value.ToInt64()) : -1;
            }
            finally { PropVariantClear(ref value); }
        }

        public static AudioEndpoint[] Read(string[] requestedIds, bool includeNotPresent)
        {
            var endpoints = new List<AudioEndpoint>();
            var requested = new HashSet<string>(requestedIds, StringComparer.OrdinalIgnoreCase);
            var enumerator = (DeviceEnumerator)Activator.CreateInstance(Type.GetTypeFromCLSID(EnumeratorClass));
            try
            {
                for (int direction = 0; direction <= 1; direction++)
                {
                    DeviceCollection collection;
                    Marshal.ThrowExceptionForHR(enumerator.EnumAudioEndpoints(direction, includeNotPresent ? AllEndpointStates : AvailableEndpointStates, out collection));
                    try
                    {
                        uint count;
                        Marshal.ThrowExceptionForHR(collection.GetCount(out count));
                        for (uint index = 0; index < count; index++)
                        {
                            Device device;
                            Marshal.ThrowExceptionForHR(collection.Item(index, out device));
                            try
                            {
                                string id;
                                Marshal.ThrowExceptionForHR(device.GetId(out id));
                                if (!requested.Contains(id))
                                    continue;
                                int state;
                                if (device.GetState(out state) < 0)
                                    continue;
                                Store properties;
                                if (device.OpenPropertyStore(0, out properties) < 0)
                                    continue;
                                try
                                {
                                    endpoints.Add(new AudioEndpoint
                                    {
                                        Id = id,
                                        StableId = Text(properties, new PropertyKey(EndpointProperties, 12)),
                                        Name = Text(properties, new PropertyKey(DeviceProperties, 14)),
                                        Description = Text(properties, new PropertyKey(DeviceProperties, 2)),
                                        Direction = direction,
                                        State = state,
                                        FormFactor = Number(properties, new PropertyKey(EndpointProperties, 0)),
                                        JackType = Text(properties, new PropertyKey(EndpointProperties, 8))
                                    });
                                }
                                finally { Marshal.ReleaseComObject(properties); }
                            }
                            finally { Marshal.ReleaseComObject(device); }
                        }
                    }
                    finally { Marshal.ReleaseComObject(collection); }
                }
            }
            finally { Marshal.ReleaseComObject(enumerator); }
            return endpoints.ToArray();
        }

        private static string ReadNameProperty(Device device, PropertyKey key)
        {
            Store store;
            Marshal.ThrowExceptionForHR(device.OpenPropertyStore(0, out store));
            try { return Text(store, key); }
            finally { Marshal.ReleaseComObject(store); }
        }

        private static void WriteNameProperty(Device device, string id, PropertyKey key, string name)
        {
            if (String.IsNullOrWhiteSpace(name) || String.Equals(ReadNameProperty(device, key), name, StringComparison.Ordinal))
                return;

            var value = new PropVariant { Type = StringType, Value = Marshal.StringToCoTaskMemUni(name) };
            try
            {
                Store store;
                int status = device.OpenPropertyStore(2, out store);
                if (status >= 0)
                {
                    try
                    {
                        status = store.SetValue(ref key, ref value);
                        if (status >= 0)
                            status = store.Commit();
                    }
                    finally { Marshal.ReleaseComObject(store); }
                }

                if (status < 0 || !String.Equals(ReadNameProperty(device, key), name, StringComparison.Ordinal))
                {
                    var policy = (EndpointPolicy)Activator.CreateInstance(Type.GetTypeFromCLSID(PolicyClass));
                    try { Marshal.ThrowExceptionForHR(policy.SetPropertyValue(id, 0, ref key, ref value)); }
                    finally { Marshal.ReleaseComObject(policy); }
                }
                if (!String.Equals(ReadNameProperty(device, key), name, StringComparison.Ordinal))
                    throw new InvalidOperationException("Windows did not retain the requested endpoint name property.");
            }
            finally { PropVariantClear(ref value); }
        }


        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandleW(
            Microsoft.Win32.SafeHandles.SafeFileHandle file, System.Text.StringBuilder path, uint capacity, uint flags);

        public static System.IO.FileStream CreateRestoreFile(string path)
        {
            var file = new System.IO.FileStream(path, System.IO.FileMode.CreateNew,
                System.IO.FileAccess.Write, System.IO.FileShare.Read);
            try
            {
                var resolved = new System.Text.StringBuilder(32768);
                uint length = GetFinalPathNameByHandleW(file.SafeFileHandle, resolved, (uint)resolved.Capacity, 0);
                string expected = @"\\?\" + System.IO.Path.GetFullPath(path);
                if (length == 0 || length >= resolved.Capacity ||
                    !String.Equals(resolved.ToString(), expected, StringComparison.OrdinalIgnoreCase))
                    throw new System.IO.IOException("The restore log was redirected away from its original Temp path.");
                return file;
            }
            catch
            {
                file.Dispose();
                throw;
            }
        }
        public static System.IO.StreamWriter OpenRestoreLog(string path)
        {
            return new System.IO.StreamWriter(CreateRestoreFile(path), new System.Text.UTF8Encoding(true));
        }

        public static string Rename(string id, string displayName, string description)
        {
            var enumerator = (DeviceEnumerator)Activator.CreateInstance(Type.GetTypeFromCLSID(EnumeratorClass));
            try
            {
                Device device;
                Marshal.ThrowExceptionForHR(enumerator.GetDevice(id, out device));
                try
                {
                    string descriptionWarning = null;
                    try { WriteNameProperty(device, id, new PropertyKey(DeviceProperties, 2), description); }
                    catch (Exception error) { descriptionWarning = error.Message; }

                    WriteNameProperty(device, id, new PropertyKey(DeviceProperties, 14), displayName);
                    return descriptionWarning;
                }
                finally { Marshal.ReleaseComObject(device); }
            }
            finally { Marshal.ReleaseComObject(enumerator); }
        }
    }
}
"@
}

function Get-CardAudioEndpoints {
    param([string]$InstanceId, [switch]$IncludeNotPresent)

    $prefix = 'SWD\MMDEVAPI\'
    $devices = @(Get-PnpDevice -Class AudioEndpoint | Where-Object InstanceId -Like "$prefix*")
    if (-not $devices.Count) { return }
    $parents = @(Get-PnpDeviceProperty -InstanceId $devices.InstanceId -KeyName DEVPKEY_Device_Parent -ErrorAction SilentlyContinue)
    $ids = @($parents | Where-Object Data -EQ $InstanceId | ForEach-Object { $_.InstanceId.Substring($prefix.Length) })
    if (-not $ids.Count) { return }

    $pnpNames = @{}
    foreach ($device in $devices) {
        $id = $device.InstanceId.Substring($prefix.Length)
        if ($id -in $ids -and -not [string]::IsNullOrWhiteSpace($device.FriendlyName)) {
            $pnpNames[$id] = $device.FriendlyName
        }
    }
    Initialize-AudioEndpointApi
    foreach ($endpoint in [FuckNahimic.AudioEndpointApi]::Read([string[]]$ids, [bool]$IncludeNotPresent)) {
        if ($IncludeNotPresent -and [string]::IsNullOrWhiteSpace($endpoint.Name)) {
            $endpoint.Name = $pnpNames[$endpoint.Id]
        }
        if (-not [string]::IsNullOrWhiteSpace($endpoint.Name)) {
            $pnpNames.Remove($endpoint.Id)
            $endpoint
        }
    }

    # An old endpoint can still have a name and this parent in PnP, while
    # its property store is no longer exposed in Core Audio.
    if ($IncludeNotPresent) {
        foreach ($id in $ids | Select-Object -Unique) {
            if ($pnpNames.ContainsKey($id)) {
                [pscustomobject]@{
                    Id = $id; Name = $pnpNames[$id]; StableId = $null; Description = $null
                    State = -1; Direction = -1; FormFactor = -1; JackType = $null
                }
            }
        }
    }
}

function Test-HistoricalAudioEndpoint {
    param($Endpoint)
    $state = $Endpoint.PSObject.Properties['State']
    return $null -ne $state -and [int]$state.Value -in -1,4
}

function Format-SavedAudioEndpoint {
    param($Endpoint)
    $label = switch ($Endpoint.State) {
        1 { 'active' }
        2 { 'disabled' }
        4 { 'not present' }
        8 { 'unplugged' }
        default { 'PnP record' }
    }
    "$($Endpoint.Name) [$label]"
}

function Resolve-AudioEndpointNames {
    param([object[]]$Saved, [object[]]$Current)

    $pairs = [System.Collections.Generic.List[object]]::new()
    $known = @($Saved | Where-Object { -not (Test-HistoricalAudioEndpoint $_) })
    $historical = @($Saved | Where-Object { Test-HistoricalAudioEndpoint $_ })
    $available = @($Current | Where-Object { -not (Test-HistoricalAudioEndpoint $_) })

    # Restore names for the endpoints that the card exposed before its driver
    # changed first. An older record needs an exact stable ID or endpoint ID.
    foreach ($criterion in 'StableId','EndpointId','JackType','EndpointRole','HistoricalStableId','HistoricalEndpointId') {
        $matchedOld = @($pairs | ForEach-Object { $_.Saved.Id })
        $matchedNew = @($pairs | ForEach-Object { $_.Current.Id })
        $pool = if ($criterion -like 'Historical*') { $historical } else { $known }
        $availableOld = @($pool | Where-Object { $_.Id -notin $matchedOld })
        $availableNew = @($available | Where-Object { $_.Id -notin $matchedNew })
        $claims = @(foreach ($old in $availableOld) {
            $options = @($availableNew | Where-Object {
                $candidate = $_
                if ($old.Direction -ge 0 -and $candidate.Direction -ne $old.Direction) { return $false }
                switch -Wildcard ($criterion) {
                    '*StableId' { return $old.StableId -and $candidate.StableId -ceq $old.StableId }
                    '*EndpointId' {
                        return $candidate.Id -eq $old.Id -and
                            (-not $candidate.StableId -or -not $old.StableId -or $candidate.StableId -ceq $old.StableId)
                    }
                    'JackType' {
                        return $old.JackType -and $old.JackType -ne '{00000000-0000-0000-0000-000000000000}' -and
                            $candidate.FormFactor -eq $old.FormFactor -and $candidate.JackType -eq $old.JackType
                    }
                    'EndpointRole' {
                        return $old.FormFactor -ge 1 -and $old.FormFactor -le 9 -and $candidate.FormFactor -eq $old.FormFactor
                    }
                }
            })
            foreach ($option in $options) {
                [pscustomobject]@{ Saved = $old; Current = $option; Criterion = $criterion }
            }
        })
        foreach ($claim in $claims) {
            if (@($claims | Where-Object { $_.Saved.Id -eq $claim.Saved.Id }).Count -eq 1 -and
                @($claims | Where-Object { $_.Current.Id -eq $claim.Current.Id }).Count -eq 1) {
                $pairs.Add($claim)
            }
        }
    }
    $restoredIds = @($pairs | ForEach-Object { $_.Saved.Id })
    [pscustomobject]@{
        Pairs = $pairs.ToArray()
        Unmatched = @($Saved | Where-Object { $_.Id -notin $restoredIds })
    }
}

function Invoke-AudioEndpointRestore {
    param([string]$Directory, [string]$SnapshotJson)

    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    $state = $SnapshotJson | ConvertFrom-Json
    if ($state.Computer -ne $env:COMPUTERNAME) { throw 'Endpoint name snapshot belongs to a different computer.' }

    Initialize-AudioEndpointApi
    $log = [FuckNahimic.AudioEndpointApi]::OpenRestoreLog((Join-Path $Directory 'FuckNahimic.Restore.log'))
    $log.AutoFlush = $true
    $code = 0
    try {
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $resolution = $null
        $currentDriver = $null
        $inventoryError = $null
        do {
            try {
                $currentDriver = Get-CurrentInf $state.Instance
                if ($currentDriver -eq $state.GenericInf) {
                    $endpoints = @(Get-CardAudioEndpoints $state.Instance)
                    $resolution = Resolve-AudioEndpointNames @($state.Endpoints) $endpoints
                    $inventoryError = $null
                    if ($endpoints.Count -and -not ($resolution.Unmatched | Where-Object { -not (Test-HistoricalAudioEndpoint $_) })) { break }
                } else {
                    $resolution = $null
                }
            } catch {
                $resolution = $null
                $inventoryError = $_.Exception.GetBaseException().Message
            }
            Start-Sleep -Seconds 10
        } while ($timer.Elapsed.TotalSeconds -lt 120)

        if ($null -eq $resolution) {
            throw "Could not verify the Microsoft generic audio device and read its endpoints. Last driver: $currentDriver. $inventoryError"
        }
        if ((Get-CurrentInf $state.Instance) -ne $state.GenericInf) {
            throw 'The primary audio driver changed while waiting for endpoints.'
        }
        foreach ($pair in $resolution.Pairs) {
            try {
                $warning = [FuckNahimic.AudioEndpointApi]::Rename(
                    $pair.Current.Id, $pair.Saved.Name, $pair.Saved.Description
                )
                $log.WriteLine("Restored [$($pair.Criterion)] $($pair.Current.Id) to $($pair.Saved.Name).")
                if ($warning) {
                    $code = 2
                    $log.WriteLine("WARNING: The endpoint's short name could not be verified: $warning")
                }
            } catch {
                $code = 2
                $log.WriteLine("WARNING: Could not restore [$($pair.Saved.Name)]: $($_.Exception.GetBaseException().Message)")
            }
        }
        foreach ($old in $resolution.Unmatched) {
            if (Test-HistoricalAudioEndpoint $old) {
                $log.WriteLine("Kept in the snapshot [$($old.Name)]: this historical endpoint has no exact available match.")
            } else {
                $code = 2
                $log.WriteLine("WARNING: Skipped [$($old.Name)]: no unique matching endpoint on the same audio device.")
            }
        }
    } catch {
        $code = 2
        $log.WriteLine("WARNING: Endpoint name restore: $($_.Exception.GetBaseException().Message)")
    } finally {
        $log.Dispose()
    }
    return $code
}

function New-EndpointRestoreCommand {
    param([string]$Directory, [string]$TaskName, [long]$BootTicks, [string]$WorkerHash, [string]$SnapshotHash)

    # Both hashes and the destination are part of the registered task, outside
    # the user profile. The byte arrays that pass validation are the ones used.
    $launcher = @'
param([string]$Directory, [string]$TaskName, [long]$BootTicks, [string]$WorkerHash, [string]$SnapshotHash)
$ErrorActionPreference = 'Stop'
try {
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
    if ($boot.Ticks -le $BootTicks) { exit 0 }
    Unregister-ScheduledTask -TaskName $TaskName -TaskPath '\' -Confirm:$false

    function Read-VerifiedRestoreFile([string]$Path, [string]$ExpectedHash) {
        $file = [IO.File]::OpenRead($Path)
        try {
            if ($file.Length -gt 1048576) { throw 'The endpoint restore file exceeds the allowed size.' }
            $buffer = [byte[]]::new([int]$file.Length)
            $offset = 0
            while ($offset -lt $buffer.Length) {
                $count = $file.Read($buffer, $offset, $buffer.Length - $offset)
                if ($count -le 0) { throw 'The endpoint restore file was truncated.' }
                $offset += $count
            }
        } finally {
            $file.Dispose()
        }
        $sha256 = [Security.Cryptography.SHA256]::Create()
        try {
            $actual = [BitConverter]::ToString($sha256.ComputeHash($buffer)).Replace('-', '')
        } finally {
            $sha256.Dispose()
        }
        if ($actual -ne $ExpectedHash) { throw "Endpoint restore file changed: $Path" }
        [Text.Encoding]::UTF8.GetString($buffer).TrimStart([char]0xFEFF)
    }

    $worker = Read-VerifiedRestoreFile (Join-Path $Directory 'FuckNahimic.RestoreAudioEndpoints.ps1') $WorkerHash
    $snapshot = Read-VerifiedRestoreFile (Join-Path $Directory 'FuckNahimic.EndpointNames.json') $SnapshotHash
    exit (& ([scriptblock]::Create($worker)) $Directory $snapshot)
} catch {
    Write-Error $_ -ErrorAction Continue
    exit 2
}
'@
    $values = foreach ($value in @($Directory,$TaskName,$BootTicks.ToString([Globalization.CultureInfo]::InvariantCulture),$WorkerHash,$SnapshotHash)) {
        "'" + $value.Replace("'", "''") + "'"
    }
    $command = '& {' + [Environment]::NewLine + $launcher + [Environment]::NewLine + '} ' + ($values -join ' ')
    [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
}

function Get-EndpointRestoreTaskXml {
    param([string]$PowerShellExe, [string]$EncodedCommand)
    $command = [Security.SecurityElement]::Escape($PowerShellExe)
    $encoded = [Security.SecurityElement]::Escape($EncodedCommand)
    $now = [DateTime]::UtcNow
    $start = $now.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $end = $now.AddDays(14).ToString('yyyy-MM-ddTHH:mm:ssZ')
    @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Restore saved audio endpoint names after the next Windows startup.</Description></RegistrationInfo>
  <Triggers>
    <BootTrigger>
      <StartBoundary>$start</StartBoundary>
      <EndBoundary>$end</EndBoundary>
      <Enabled>true</Enabled>
      <Delay>PT30S</Delay>
    </BootTrigger>
  </Triggers>
  <Principals>
    <Principal id="SystemAccount">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>false</StartWhenAvailable>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <DeleteExpiredTaskAfter>PT1H</DeleteExpiredTaskAfter>
  </Settings>
  <Actions Context="SystemAccount">
    <Exec>
      <Command>$command</Command>
      <Arguments>-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded</Arguments>
    </Exec>
  </Actions>
</Task>
"@
}

function Install-AudioEndpointRestore {
    param([string]$InstanceId, [object[]]$Endpoints)

    $restoreRoot = [IO.Path]::GetFullPath($script:runDirectory)
    foreach ($existing in Get-ScheduledTask -TaskName 'FuckNahimic-RestoreAudioEndpoints-*' -TaskPath '\' -ErrorAction SilentlyContinue) {
        if ($existing.TaskName -notmatch '^FuckNahimic-RestoreAudioEndpoints-([0-9a-f]{32})$') { continue }
        $leaf = "FuckNahimic-AudioEndpoints-$($Matches[1])"
        if ($existing.Principal.UserId -notmatch '^(?:S-1-5-18|(?:NT AUTHORITY\\)?SYSTEM)$') { continue }
        $existingSnapshot = Join-Path (Join-Path $restoreRoot $leaf) 'FuckNahimic.EndpointNames.json'
        if (-not (Test-Path -LiteralPath $existingSnapshot -PathType Leaf)) { continue }
        $saved = Get-Content -LiteralPath $existingSnapshot -Raw | ConvertFrom-Json
        if ($saved.Computer -eq $env:COMPUTERNAME -and $saved.Instance -eq $InstanceId -and
            $saved.TaskName -eq $existing.TaskName -and @($saved.Endpoints).Count) {
            $script:EndpointRestoreTaskName = $existing.TaskName
            Write-Host "Using the pending original endpoint snapshot: $existingSnapshot"
            return
        }
    }

    $runId = [guid]::NewGuid().ToString('N')
    $taskName = "FuckNahimic-RestoreAudioEndpoints-$runId"
    $directory = Join-Path $restoreRoot "FuckNahimic-AudioEndpoints-$runId"
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $acl.SetOwner($administrators)
    $inherit = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $access = @{
        'S-1-5-18' = 'FullControl'
        'S-1-5-32-544' = 'FullControl'
    }
    $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if (-not $access.ContainsKey($userSid)) { $access[$userSid] = 'ReadAndExecute' }
    foreach ($id in $access.Keys) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($id), [Security.AccessControl.FileSystemRights]$access[$id],
            $inherit, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow
        )
        $acl.AddAccessRule($rule)
    }
    [IO.FileSystemAclExtensions]::CreateDirectory($acl, $directory) | Out-Null

    $bootTicks = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().Ticks
    $state = [ordered]@{
        Computer = $env:COMPUTERNAME
        Instance = $InstanceId
        GenericInf = $GenericInf
        TaskName = $taskName
        BootTicks = $bootTicks.ToString()
        Endpoints = @($Endpoints | Select-Object Id,StableId,Name,Description,Direction,FormFactor,JackType,State)
    }
    # Take the worker from the loaded functions so Temp never supplies its own trusted code.
    $functions = foreach ($name in @(
        'Initialize-AudioEndpointApi','Get-CurrentInf','Get-CardAudioEndpoints',
        'Test-HistoricalAudioEndpoint','Resolve-AudioEndpointNames','Invoke-AudioEndpointRestore'
    )) {
        $implementation = (Get-Command -Name $name -CommandType Function).ScriptBlock.ToString()
        "function $name {" + [Environment]::NewLine + $implementation + [Environment]::NewLine + '}'
    }
    $workerText = (@('param([string]$Directory, [string]$SnapshotJson)') + $functions +
        'Invoke-AudioEndpointRestore -Directory $Directory -SnapshotJson $SnapshotJson') -join [Environment]::NewLine
    $encoding = [Text.UTF8Encoding]::new($true)
    [byte[]]$workerBytes = $encoding.GetPreamble() + $encoding.GetBytes($workerText)
    [byte[]]$snapshotBytes = $encoding.GetPreamble() + $encoding.GetBytes(($state | ConvertTo-Json -Depth 5))
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $workerHash = [BitConverter]::ToString($sha.ComputeHash($workerBytes)).Replace('-', '')
        $snapshotHash = [BitConverter]::ToString($sha.ComputeHash($snapshotBytes)).Replace('-', '')
    } finally {
        $sha.Dispose()
    }

    $worker = Join-Path $directory 'FuckNahimic.RestoreAudioEndpoints.ps1'
    $statePath = Join-Path $directory 'FuckNahimic.EndpointNames.json'
    Initialize-AudioEndpointApi
    foreach ($file in @(@{ Path = $worker; Bytes = $workerBytes }, @{ Path = $statePath; Bytes = $snapshotBytes })) {
        $stream = [FuckNahimic.AudioEndpointApi]::CreateRestoreFile($file.Path)
        try {
            $stream.Write($file.Bytes, 0, $file.Bytes.Length)
        } finally {
            $stream.Dispose()
        }
    }

    $encoded = New-EndpointRestoreCommand $directory $taskName $bootTicks $workerHash $snapshotHash
    $powerShellExe = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
    $xml = Get-EndpointRestoreTaskXml $powerShellExe $encoded
    $scheduler = New-Object -ComObject Schedule.Service
    $scheduler.Connect()
    $root = $scheduler.GetFolder('\')
    # TASK_CREATE (2) and TASK_LOGON_SERVICE_ACCOUNT (5) select an explicit SYSTEM startup task.
    $null = $root.RegisterTask($taskName, $xml, 2, 'SYSTEM', $null, 5, $null)
    $script:EndpointRestoreTaskName = $taskName
    Write-Host "Saved $($Endpoints.Count) endpoint name(s): $statePath"
    Write-Host "One-time startup task: $taskName. Restore log: $(Join-Path $directory 'FuckNahimic.Restore.log')"
}

function Get-BoardAudioIds {
    param($Device)
    @($Device.HardwareID) + @($Device.CompatibleID) | Where-Object {
        $_ -match '^HDAUDIO\\FUNC_01&(?:GF&)?VEN_[0-9a-f]{4}&DEV_[0-9a-f]{4}&SUBSYS_[0-9a-f]{8}(?:&REV_[0-9a-f]+)?$'
    } | Sort-Object -Unique
}

function Test-AudioInfMatch {
    param($Package, [string[]]$HardwareIds)
    if (-not $HardwareIds.Count -or $Package.Name -notmatch '^oem\d+\.inf$') { return $false }
    $infPath = Join-Path (Join-Path $env:SystemRoot 'INF') $Package.Name
    if (-not (Test-Path -LiteralPath $infPath -PathType Leaf)) { return $false }
    $alternatives = ($HardwareIds | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $modelEntry = '^\s*[^;=\[]+\s*=\s*[^;,]+,\s*"?(?:' + $alternatives + ')"?\s*(?=[,;]|$)'
    Select-String -LiteralPath $infPath -Pattern $modelEntry -Quiet
}

function Get-ScopedRealtekDevices {
    param($Target, [object[]]$Devices, [object[]]$Inventory)
    if (-not $Target) { return }
    $parent = $Target.InstanceId
    $extensionIds = @(foreach ($package in $Inventory | Where-Object {
        $_.Class -eq $ExtensionClass -and $_.Provider -match $RealtekAudioProvider -and
            $_.Devices -contains $parent -and $_.Name -match '^oem\d+\.inf$'
    }) {
        $path = Join-Path (Join-Path $env:SystemRoot 'INF') $package.Name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $entry = Select-String -LiteralPath $path -Pattern '^\s*ExtensionId\s*=\s*(\{[0-9a-f-]{36}\})\s*(?:;.*)?$' | Select-Object -First 1
        if ($entry) { $entry.Matches[0].Groups[1].Value }
    })
    if (-not $extensionIds.Count) { return }

    $children = @(Get-PnpDeviceProperty -InstanceId $parent -KeyName DEVPKEY_Device_Children -ErrorAction SilentlyContinue | ForEach-Object Data)
    foreach ($device in $Devices | Where-Object {
        $_.InstanceId -in $children -and $_.FriendlyName -match $RealtekAudioProvider
    }) {
        if ($device.InstanceId -match '^SWD\\DRIVERENUM\\(\{[0-9a-f-]{36}\})#' -and
            $Matches[1] -in $extensionIds -and (Test-NahimicSoftwareDevice $device -ApprovedInstance)) {
            $device
        }
    }
}

function Test-ScopedRealtekDriver {
    param($Package, [hashtable]$DeviceIds)
    return $DeviceIds.Count -gt 0 -and $Package.Provider -match $RealtekAudioProvider -and
        $Package.Class -in $SoftwareComponentClass,$ApoClass -and
        -not @($Package.Devices | Where-Object { -not $DeviceIds.ContainsKey($_) }).Count
}

function Get-AudioUpdateScope {
    param([object[]]$Devices, [object[]]$Inventory)

    $software = @($Devices | Where-Object { Test-NahimicSoftwareDevice $_ })
    $presentChildren = @($software | Where-Object Present | ForEach-Object InstanceId)
    $parents = if ($presentChildren.Count) {
        Get-PnpDeviceProperty -InstanceId $presentChildren -KeyName DEVPKEY_Device_Parent -ErrorAction SilentlyContinue |
            ForEach-Object Data
    }
    # This is the previously verified card association, used only to locate live endpoints after the OEM packages are gone.
    $previousCard = Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\EricSoft\FuckNahimic' -Name AudioInstance -ErrorAction SilentlyContinue
    $associated = [System.Collections.Generic.List[object]]::new()
    $generic = [System.Collections.Generic.List[object]]::new()
    foreach ($device in $Devices | Where-Object {
        $_.Present -and $_.Class -eq 'MEDIA' -and $_.InstanceId -like 'HDAUDIO\*'
    }) {
        $ids = @(Get-BoardAudioIds $device)
        if (-not $ids.Count) { continue }
        $instance = $device.InstanceId
        $candidate = [pscustomobject]@{ Device = $device; HardwareIds = $ids }
        if ($instance -in $parents -or $instance -eq $previousCard -or @($Inventory | Where-Object {
            $_.Class -eq $ExtensionClass -and ($_.Provider -match $NahimicProvider -or $_.Original -match $TargetPattern) -and
                ($_.Devices -contains $instance -or (-not $_.Devices.Count -and (Test-AudioInfMatch $_ $ids)))
        } | Select-Object -First 1).Count) {
            $associated.Add($candidate)
            continue
        }
        if ((Get-CurrentInf $instance) -ne $GenericInf) { continue }
        # A staged vendor base INF can identify a card that already uses the inbox driver.
        if ($device.FriendlyName -match $RealtekAudioProvider -or $device.Manufacturer -match $RealtekAudioProvider -or
            @($Inventory | Where-Object {
                $_.Class -eq $MediaClass -and $_.Provider -match $RealtekAudioProvider -and (Test-AudioInfMatch $_ $ids)
            } | Select-Object -First 1).Count) {
            $generic.Add($candidate)
        }
    }
    $candidates = @(if ($associated.Count) { $associated.ToArray() } else { $generic.ToArray() })
    $target = $null
    $targetIds = @()
    if ($candidates.Count -eq 1) {
        $target = $candidates[0].Device
        $targetIds = @($candidates[0].HardwareIds)
    }
    $realtek = @(Get-ScopedRealtekDevices $target $Devices $Inventory)
    $realtekInstances = @($realtek | ForEach-Object InstanceId)
    $otherHardware = @(if ($realtek.Count) {
        $Devices | Where-Object { $_.Present -and $_.InstanceId -notin $realtekInstances } | ForEach-Object HardwareID
    })
    [pscustomobject]@{
        Device = $target
        HardwareIds = $targetIds
        Ambiguous = $candidates.Count -gt 1
        RealtekDevices = $realtek
        RealtekHardwareIds = @($realtek | ForEach-Object HardwareID | Where-Object {
            $_ -match '^SWC\\' -and $_ -notin $otherHardware
        } | Sort-Object -Unique)
        SoftwareDevices = $software
        SoftwareHardwareIds = @($software | ForEach-Object HardwareID | Where-Object { $_ -match '^(?:ROOT|SWC|SWD)\\' } | Sort-Object -Unique)
    }
}

function Update-AudioUpdateScope {
    $script:AudioUpdateScope = Get-AudioUpdateScope @(Get-PnpDevice) @(Get-DriverInventory)
}

function Get-MigrationPackages {
    param([object[]]$Inventory, [string]$InstanceId, [string]$CurrentInf, [string[]]$HardwareIds)

    foreach ($package in $Inventory) {
        if ($package.Class -eq $MediaClass -and $package.Provider -match $RealtekAudioProvider) {
            $boundElsewhere = @($package.Devices | Where-Object { $_ -ne $InstanceId }).Count -gt 0
            if ($package.Name -eq $CurrentInf) {
                if ($boundElsewhere) { throw "The active OEM base package $($package.Name) is shared with another device." }
                $package
            } elseif (-not $boundElsewhere -and (Test-AudioInfMatch $package $HardwareIds)) {
                $package
            }
            continue
        }
        if ($package.Class -ne $ExtensionClass -or $package.Provider -notmatch $OemAudioProvider) { continue }
        $boundToTarget = $package.Devices -contains $InstanceId
        if (-not $boundToTarget -and ($package.Devices.Count -or -not (Test-AudioInfMatch $package $HardwareIds))) { continue }
        if (@($package.Devices | Where-Object { $_ -ne $InstanceId }).Count) {
            throw "$($package.Name) is shared with another device. Switch and package removal require a separate review."
        }
        $package
    }
}


function Test-NahimicSoftwareDevice {
    param($Device, [switch]$ApprovedInstance)
    if ((-not $ApprovedInstance -and $Device.FriendlyName -notmatch $TargetPattern) -or
        $Device.InstanceId -notmatch '^(?:SWC|ROOT|SWD)\\') {
        return $false
    }
    $physicalBus = '^(?:HDAUDIO|USB|PCI|ACPI|SCSI|BTH|BTHENUM|BTHHFENUM|BTHLEDEVICE|DISPLAY|DT|MMDEVAPI|INTELAUDIO|I2S|UART|SERENUM|STORAGE)\\'
    return -not @($Device.HardwareID | Where-Object { $_ -match $physicalBus }).Count
}

function Test-NahimicDriver {
    param($Package, [hashtable]$SoftwareDeviceIds)
    if ($Package.Class -eq $EndpointClass -or $Package.Original -eq $GenericInf) { return $false }
    if ($Package.Class -eq $MediaClass -and $Package.Provider -notmatch $NahimicProvider) { return $false }
    if (@($Package.Devices | Where-Object { -not $SoftwareDeviceIds.ContainsKey($_) }).Count) { return $false }
    if ($Package.Provider -match $NahimicProvider) { return $true }
    return $Package.Original -match $TargetPattern -and
        ($Package.Class -in $SoftwareComponentClass,$ApoClass -or $Package.Provider -match '^(?:ASUSTeK|ASUS)(?:\s|$)')
}

function Add-Operation {
    param([string]$Kind, [string]$Detail, [hashtable]$Data = @{})
    $script:Plan.Add([pscustomobject]@{ Kind = $Kind; Detail = $Detail; Data = $Data })
}

function Add-ScanIssue {
    param([string]$Message)
    $script:ScanIssues.Add($Message)
    Write-Warning $Message
}

function Add-DriverPlan {
    param([object[]]$Devices)

    $inventory = @(Get-DriverInventory)
    $script:AudioUpdateScope = Get-AudioUpdateScope $Devices $inventory
    $softwareDevices = @($script:AudioUpdateScope.SoftwareDevices)
    $allowed = @{}
    foreach ($device in $softwareDevices) { $allowed[$device.InstanceId] = $true }
    $realtekDevices = @($script:AudioUpdateScope.RealtekDevices)
    $realtekAllowed = @{}
    foreach ($device in $realtekDevices) { $realtekAllowed[$device.InstanceId] = $true }

    $target = $script:AudioUpdateScope.Device
    if ($script:AudioUpdateScope.Ambiguous) { Add-ScanIssue 'Multiple physical audio devices match the OEM evidence. No card was selected for migration.' }
    $migrationNames = @()
    if ($target) {
        $instance = $target.InstanceId
        $script:AudioEndpointInstance = $instance
        $baseInf = Get-CurrentInf $instance
        $packages = @(Get-MigrationPackages $inventory $instance $baseInf $script:AudioUpdateScope.HardwareIds)
        $migrationNames = @($packages | ForEach-Object Name)
        $extensions = @($packages | Where-Object Class -EQ $ExtensionClass)
        $extensionNames = @($extensions | ForEach-Object Name)
        $otherExtensions = @($inventory | Where-Object {
            $_.Class -eq $ExtensionClass -and $_.Devices -contains $instance -and $_.Name -notin $extensionNames
        })
        if ($otherExtensions.Count) {
            throw "Unrecognized extensions on the primary audio device: $($otherExtensions.Name -join ', ')."
        }
        $basePackages = @($packages | Where-Object Class -EQ $MediaClass)
        if ($baseInf -ne $GenericInf -and $baseInf -notin @($basePackages | ForEach-Object Name)) {
            throw "Unrecognized base driver on the primary audio device: $baseInf."
        }
        if ($baseInf -ne $GenericInf -or $extensions.Count -or $basePackages.Count) {
            if ($baseInf -ne $GenericInf) {
                Initialize-DeviceDriverApi
                $null = [FuckNahimic.DeviceDriver]::Select($instance, $GenericInf, 'Microsoft', $false)
                $detail = "$($target.FriendlyName) switches from $baseInf to $GenericInf."
            } else {
                $detail = "$($target.FriendlyName) already uses $GenericInf."
            }
            if ($packages.Count) { $detail += " Back up and remove OEM driver packages $($packages.Name -join ', ')." }
            Add-Operation AudioMigration $detail @{
                Instance = $instance
                Base = $baseInf
                BasePackages = $basePackages
                Extensions = $extensions
            }
            Add-Operation OemUpdateRecheck 'After audio migration, scan for newly offered OEM driver updates and hide matching revisions.' @{
                Instance = $instance
            }
        }
    }

    foreach ($device in (($softwareDevices + $realtekDevices) | Sort-Object InstanceId -Unique)) {
        Add-Operation PnpDevice "$($device.FriendlyName) [$($device.InstanceId)]" @{ Instance = $device.InstanceId }
    }
    foreach ($package in $inventory) {
        if ($package.Name -in $migrationNames) { continue }
        if (Test-NahimicDriver $package $allowed) {
            Add-Operation Driver "$($package.Name) ($($package.Original))" @{ Package = $package; Allowed = $allowed }
        } elseif ($package.Devices.Count -and (Test-ScopedRealtekDriver $package $realtekAllowed)) {
            Add-Operation Driver "$($package.Name) ($($package.Original))" @{
                Package = $package; Allowed = $realtekAllowed; ScopedRealtek = $true
            }
        }
    }
}

function Test-GuardApprovedUpdate {
    param([string]$UpdateId, [int]$Revision)
    $approved = Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\EricSoft\FuckNahimic\Guard\Approved' -Name "$UpdateId/$Revision" -ErrorAction SilentlyContinue
    return $approved -eq 1
}

function Request-AudioGuardScan {
    try {
        $event = [Threading.EventWaitHandle]::OpenExisting('Global\EricSoft.FuckNahimic.Wake')
        try { return $event.Set() }
        finally { $event.Dispose() }
    } catch [Threading.WaitHandleCannotBeOpenedException] {
        return $false
    } catch [UnauthorizedAccessException] {
        return $false
    }
}

function Get-AudioGuardPaths {
    $programData = [Environment]::GetFolderPath('CommonApplicationData')
    $vendorPath = Join-Path $programData 'EricSoft'
    $homePath = Join-Path $vendorPath 'FuckNahimic'
    $executable = Join-Path $homePath 'FuckNahimic.exe'
    @{
        ProgramData = $programData
        VendorPath = $vendorPath
        Root = $homePath
        Executable = $executable
        ServiceCommand = '"{0}" --service' -f $executable
        ProtocolCommand = '"{0}" --reply "%1"' -f $executable
        Protocol = 'HKLM:\SOFTWARE\Classes\fucknahimic'
        Shortcut = Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'FuckNahimic.lnk'
        State = 'HKLM:\SOFTWARE\EricSoft\FuckNahimic\Guard'
    }
}

function Get-OwnedAudioGuardService {
    param([hashtable]$Paths)
    $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='FuckNahimic'"
    if ($service -and ($service.PathName -ne $Paths.ServiceCommand -or $service.StartName -ne 'LocalSystem')) {
        throw 'FuckNahimic already belongs to a different program or account.'
    }
    $service
}

function Get-AudioGuardProtocolCommand {
    param([string]$ProtocolPath)
    $key = Get-Item -LiteralPath (Join-Path $ProtocolPath 'shell\open\command') -ErrorAction SilentlyContinue
    if (-not $key) { return }
    try { $key.GetValue('') }
    finally { $key.Dispose() }
}

function Test-AudioGuardReady {
    $paths = Get-AudioGuardPaths
    $service = Get-OwnedAudioGuardService $paths
    if (-not $service -or $service.PathName -ne $paths.ServiceCommand -or $service.State -ne 'Running' -or $service.StartMode -ne 'Auto') { return $false }
    if ((Get-ItemPropertyValue -LiteralPath $paths.State -Name Version -ErrorAction SilentlyContinue) -ne $ScriptVersion) { return $false }
    if ((Get-AudioGuardProtocolCommand $paths.Protocol) -ne $paths.ProtocolCommand) { return $false }
    $required = @($paths.Executable, (Join-Path $paths.Root 'FuckNahimic.UpdateWorker.ps1'), (Join-Path $paths.Root 'FuckNahimic.ShowToast.ps1'),
        (Join-Path $paths.Root 'FuckNahimic.Config.json'), $paths.Shortcut)
    if (@($required | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }).Count) { return $false }
    Assert-AudioGuardDirectory $paths.ProgramData -IsParent
    Assert-AudioGuardDirectory $paths.VendorPath -IsParent
    Assert-AudioGuardDirectory $paths.Root
    Assert-AudioGuardFiles $paths.Root
    return $true
}

function Assert-AudioGuardDirectory {
    param([string]$Path, [switch]$IsParent)
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "The guard directory is not an ordinary directory: $Path"
    }

    $admins = 'S-1-5-32-544'
    $system = 'S-1-5-18'
    $acl = Get-Acl -LiteralPath $Path
    $sidType = [Security.Principal.SecurityIdentifier]
    $rights = [Security.AccessControl.FileSystemRights]
    $forbidden = $rights::Delete -bor $rights::DeleteSubdirectoriesAndFiles -bor
        $rights::ChangePermissions -bor $rights::TakeOwnership
    if (-not $IsParent) { $forbidden = $forbidden -bor $rights::Write }
    $inheritOnly = [Security.AccessControl.PropagationFlags]::InheritOnly
    $ownerRestricted = $false
    foreach ($rule in $acl.GetAccessRules($true, $true, $sidType)) {
        if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -eq 'S-1-3-4' -and
            -not ($rule.PropagationFlags -band $inheritOnly)) {
            $ownerRestricted = $true
        }
        if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin $admins,$system -and
            (-not $IsParent -or -not ($rule.PropagationFlags -band $inheritOnly)) -and ($rule.FileSystemRights -band $forbidden)) {
            throw "Unprivileged changes are allowed on the guard directory: $Path"
        }
    }
    if (-not $ownerRestricted -and $acl.GetOwner($sidType).Value -notin $admins,$system) {
        throw "The guard directory has an unprivileged owner: $Path"
    }
}

function New-AudioGuardDirectory {
    param([string]$Path, [switch]$IsParent)
    if (-not (Test-Path -LiteralPath $Path)) {
        $security = [Security.AccessControl.DirectorySecurity]::new()
        $security.SetAccessRuleProtection($true, $false)
        $rights = [Security.AccessControl.FileSystemRights]
        $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
            [Security.AccessControl.InheritanceFlags]::ObjectInherit
        foreach ($entry in @(
            @{ Sid = 'S-1-5-18'; Rights = $rights::FullControl }
            @{ Sid = 'S-1-5-32-544'; Rights = $rights::FullControl }
            @{ Sid = 'S-1-5-32-545'; Rights = $rights::ReadAndExecute }
            # This SID suppresses the owner's implicit permission to rewrite an inherited file ACL.
            @{ Sid = 'S-1-3-4'; Rights = $rights::ReadPermissions }
        )) {
            $sid = [Security.Principal.SecurityIdentifier]::new($entry.Sid)
            $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                $sid, $entry.Rights, $inheritance, [Security.AccessControl.PropagationFlags]::None,
                [Security.AccessControl.AccessControlType]::Allow
            ))
        }
        $null = [IO.FileSystemAclExtensions]::CreateDirectory($security, $Path)
    }
    Assert-AudioGuardDirectory $Path -IsParent:$IsParent
}

function Assert-AudioGuardFiles {
    param([string]$Path)
    foreach ($file in Get-ChildItem -LiteralPath $Path -File -Force) {
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "The guard file is a reparse point: $($file.FullName)"
        }
        $sidType = [Security.Principal.SecurityIdentifier]
        $acl = Get-Acl -LiteralPath $file.FullName
        $rules = $acl.GetAccessRules($true, $true, $sidType)
        $admins = 'S-1-5-32-544'
        $system = 'S-1-5-18'
        $rights = [Security.AccessControl.FileSystemRights]
        $forbidden = $rights::Write -bor $rights::Delete -bor $rights::ChangePermissions -bor $rights::TakeOwnership
        $ownerRestricted = $false
        foreach ($rule in $rules) {
            if ($rule.AccessControlType -ne 'Allow' -or $rule.IdentityReference.Value -in $admins,$system) { continue }
            if ($rule.FileSystemRights -band $forbidden) {
                throw "Unprivileged changes are allowed on a guard file: $($file.FullName)"
            }
            if ($rule.IdentityReference.Value -eq 'S-1-3-4') { $ownerRestricted = $true }
        }
        if (-not $ownerRestricted -and $acl.GetOwner($sidType).Value -notin $admins,$system) {
            throw "The guard file has an unprivileged owner: $($file.FullName)"
        }
    }
}

function Remove-AudioGuardFiles {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "The guard directory is a reparse point: $Path"
    }
    foreach ($name in 'FuckNahimic.exe','FuckNahimic.UpdateWorker.ps1','FuckNahimic.ShowToast.ps1','FuckNahimic.Config.json') {
        $file = Join-Path $Path $name
        if (Test-Path -LiteralPath $file -PathType Leaf) { [IO.File]::Delete($file) }
    }
}

function Install-FuckNahimic {
    $paths = Get-AudioGuardPaths
    $service = Get-OwnedAudioGuardService $paths
    if (-not [Environment]::Is64BitProcess -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64' -or [Environment]::OSVersion.Version.Build -lt 22000) {
        throw 'FuckNahimic requires x64 Windows 11.'
    }
    $version = Get-ItemPropertyValue -LiteralPath $paths.State -Name Version -ErrorAction SilentlyContinue
    $required = @($paths.Executable, (Join-Path $paths.Root 'FuckNahimic.UpdateWorker.ps1'), (Join-Path $paths.Root 'FuckNahimic.ShowToast.ps1'), (Join-Path $paths.Root 'FuckNahimic.Config.json'), $paths.Shortcut)
    $complete = @($required | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }).Count -eq 0
    $protocolCommand = Get-AudioGuardProtocolCommand $paths.Protocol
    if ($protocolCommand -and $protocolCommand -ne $paths.ProtocolCommand) {
        throw 'The fucknahimic URL protocol is already in use.'
    }

    Assert-AudioGuardDirectory $paths.ProgramData -IsParent
    New-AudioGuardDirectory $paths.VendorPath -IsParent
    New-AudioGuardDirectory $paths.Root
    Assert-AudioGuardFiles $paths.Root
    $rebuild = -not $service -or $version -ne $ScriptVersion -or -not $complete -or $protocolCommand -ne $paths.ProtocolCommand
    if ($rebuild) {
        $framework = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319'
        $compiler = Join-Path $framework 'csc.exe'
        if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { throw 'The Windows .NET Framework compiler was not found.' }

        $id = [guid]::NewGuid().ToString('N')
        $source = Join-Path $paths.Root "Build-$id.cs"
        $build = Join-Path $paths.Root "Build-$id.exe"
        try {
            [IO.File]::WriteAllText($source, (Get-AudioGuardServiceSource))
            Invoke-Native $compiler @('/nologo','/target:winexe','/platform:x64','/optimize+','/warnaserror+','/r:System.ServiceProcess.dll',"/out:$build",$source) | Out-Null
            if ($service -and $service.State -ne 'Stopped') { Stop-Service -Name FuckNahimic }
            [IO.File]::Move($build, $paths.Executable, $true)
        } finally {
            foreach ($temporaryFile in @($source,$build)) {
                if (Test-Path -LiteralPath $temporaryFile -PathType Leaf) { [IO.File]::Delete($temporaryFile) }
            }
        }

        $definitions = foreach ($name in @(
            'Get-TargetUpdateMatch','Test-GuardApprovedUpdate','Test-NahimicSoftwareDevice',
            'Get-BoardAudioIds','Test-AudioInfMatch','Get-ScopedRealtekDevices','Get-AudioUpdateScope','Update-AudioUpdateScope',
            'Invoke-Native','Get-DriverInventory','Get-CurrentInf'
        )) {
            "function $name {" + (Get-Command -Name $name -CommandType Function).ScriptBlock.ToString() + '}'
        }
        $worker = (Get-AudioGuardWorkerSource).Replace('# GUARD_DEFINITIONS', ($definitions -join [Environment]::NewLine))
        $encoding = [Text.UTF8Encoding]::new($true)
        [IO.File]::WriteAllText((Join-Path $paths.Root 'FuckNahimic.UpdateWorker.ps1'), $worker, $encoding)
        [IO.File]::WriteAllText((Join-Path $paths.Root 'FuckNahimic.ShowToast.ps1'), (Get-AudioGuardToastSource), $encoding)

        $key = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey('SOFTWARE\Classes\fucknahimic')
        try {
            $key.SetValue('', 'URL: FuckNahimic')
            $key.SetValue('URL Protocol', '')
            $open = $key.CreateSubKey('shell\open\command')
            try { $open.SetValue('', $paths.ProtocolCommand) }
            finally { $open.Dispose() }
        } finally { $key.Dispose() }

        $shortcut = Start-Process -FilePath $paths.Executable -ArgumentList @('--shortcut', ('"{0}"' -f $paths.Shortcut)) -WindowStyle Hidden -Wait -PassThru
        if ($shortcut.ExitCode -ne 0) { throw 'Could not register the Start menu notification identity.' }
        if (-not [Diagnostics.EventLog]::SourceExists('FuckNahimic')) {
            [Diagnostics.EventLog]::CreateEventSource('FuckNahimic', 'Application')
        }
    }

    $config = @{
        TargetPattern = $TargetPattern; NahimicProvider = $NahimicProvider
        OemAudioProvider = $OemAudioProvider; RealtekAudioProvider = $RealtekAudioProvider
        GenericInf = $GenericInf; MediaClass = $MediaClass; ExtensionClass = $ExtensionClass
    } | ConvertTo-Json -Compress
    $configFile = Join-Path $paths.Root 'FuckNahimic.Config.json'
    $stageConfig = Join-Path $paths.Root ('Config-' + [guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::WriteAllText($stageConfig, $config)
    [IO.File]::Move($stageConfig, $configFile, $true)
    Assert-AudioGuardFiles $paths.Root

    if (-not $service) {
        $null = New-Service -Name FuckNahimic -BinaryPathName $paths.ServiceCommand -DisplayName 'FuckNahimic' -StartupType Automatic

    }
    if ($rebuild) {
        Invoke-Native $ServiceExe @('failure','FuckNahimic','reset=','86400','actions=','restart/5000/restart/30000') | Out-Null
    }

    $controller = Get-Service -Name FuckNahimic
    if ($controller.StartType -ne 'Automatic') { Set-Service -Name FuckNahimic -StartupType Automatic }
    if ($controller.Status -ne 'Running') { Start-Service -Name FuckNahimic }
    $null = New-Item -Path $paths.State -Force
    $null = New-ItemProperty -LiteralPath $paths.State -Name Version -PropertyType String -Value $ScriptVersion -Force
    $null = Request-AudioGuardScan
    Write-Host "FuckNahimic is running from $($paths.Root)."
}

function Uninstall-FuckNahimic {
    $paths = Get-AudioGuardPaths
    $service = Get-OwnedAudioGuardService $paths
    if (Test-Path -LiteralPath $paths.Root -PathType Container) {
        Assert-AudioGuardDirectory $paths.ProgramData -IsParent
        Assert-AudioGuardDirectory $paths.VendorPath -IsParent
        Assert-AudioGuardDirectory $paths.Root
    }
    if ($service) {
        if ($service.State -ne 'Stopped') { Stop-Service -Name FuckNahimic }
        Invoke-Native $ServiceExe @('delete','FuckNahimic') | Out-Null
    }
    if ((Get-AudioGuardProtocolCommand $paths.Protocol) -eq $paths.ProtocolCommand) {
        [Microsoft.Win32.Registry]::LocalMachine.DeleteSubKeyTree('SOFTWARE\Classes\fucknahimic', $false)
    }
    if (Test-Path -LiteralPath $paths.State) {
        [Microsoft.Win32.Registry]::LocalMachine.DeleteSubKeyTree('SOFTWARE\EricSoft\FuckNahimic\Guard', $false)
    }
    if ($service -or (Test-Path -LiteralPath $paths.Executable -PathType Leaf)) {
        if (Test-Path -LiteralPath $paths.Shortcut -PathType Leaf) { [IO.File]::Delete($paths.Shortcut) }
    }
    Remove-AudioGuardFiles $paths.Root
    Write-Host 'FuckNahimic was removed. Existing Windows Update hidden states are preserved.'
}

function Get-AudioGuardServiceSource {
    @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Diagnostics.Eventing.Reader;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Reflection;
using System.Security.AccessControl;
using System.Security.Principal;
using System.ServiceProcess;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

[assembly: AssemblyTitle("FuckNahimic")]
[assembly: AssemblyProduct("FuckNahimic")]

internal sealed class FuckNahimic : ServiceBase
{
    internal const string GuardName = "FuckNahimic";
    internal const string WakeName = @"Global\EricSoft.FuckNahimic.Wake";
    internal const string DecisionPrefix = @"Global\EricSoft.FuckNahimic.";
    internal const string AppId = "EricSoft.FuckNahimic";
    private const string ScanChannel = "Microsoft-Windows-WindowsUpdateClient/Operational";
    private static readonly string Home = AppDomain.CurrentDomain.BaseDirectory;
    private static readonly string WindowsPowerShell =
        Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
    private readonly ManualResetEvent stop = new ManualResetEvent(false);
    private EventWaitHandle wake;
    private Thread worker;
    private long ignoreScanEventsThrough;

    internal FuckNahimic()
    {
        ServiceName = GuardName;
        AutoLog = false;
        CanStop = true;
    }

    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            if (args.Length == 1 && args[0] == "--service")
            {
                ServiceBase.Run(new FuckNahimic());
                return 0;
            }
            if (args.Length == 2 && args[0] == "--reply")
                return Reply(args[1]);
            if (args.Length == 2 && args[0] == "--shortcut")
            {
                ToastShortcut.Create(args[1]);
                return 0;
            }
            return 2;
        }
        catch (Exception error)
        {
            Log(error.Message, EventLogEntryType.Error);
            return 2;
        }
    }

    protected override void OnStart(string[] args)
    {
        stop.Reset();
        bool created;
        wake = new EventWaitHandle(false, EventResetMode.AutoReset, WakeName, out created,
            EventSecurity(null));
        if (!created)
        {
            wake.Dispose();
            throw new InvalidOperationException("The guard wake event already exists.");
        }
        worker = new Thread(Run) { IsBackground = true, Name = "Audio driver policy" };
        worker.Start();
    }

    protected override void OnStop()
    {
        stop.Set();
        if (worker.Join(TimeSpan.FromSeconds(10)))
            wake.Dispose();
    }

    private EventLogWatcher Watch(string channel, string xpath)
    {
        var watcher = new EventLogWatcher(new EventLogQuery(channel, PathType.LogName, xpath));
        try
        {
            watcher.EventRecordWritten += UpdateActivity;
            watcher.Enabled = true;
            return watcher;
        }
        catch (Exception error)
        {
            watcher.Dispose();
            Log("Cannot observe " + channel + ": " + error.Message, EventLogEntryType.Error);
            return null;
        }
    }

    private void UpdateActivity(object sender, EventRecordWrittenEventArgs args)
    {
        using (EventRecord record = args.EventRecord)
        {
            if (record == null)
            {
                if (args.EventException != null)
                    Log("Windows Update event subscription: " + args.EventException.Message, EventLogEntryType.Warning);
                return;
            }
            DateTime? time = record.TimeCreated;
            if (record.Id == 26 && (!time.HasValue ||
                time.Value.ToUniversalTime().Ticks <= Interlocked.Read(ref ignoreScanEventsThrough)))
                return;
            try { wake.Set(); } catch (ObjectDisposedException) { }
        }
    }

    private void Run()
    {
        try
        {
            using (Watch(ScanChannel, "*[System[EventID=26] and EventData[Data[@Name='updateCount']!='0']]"))
            using (Watch("System", "*[System[Provider[@Name='Microsoft-Windows-WindowsUpdateClient'] and EventID=44]]"))
            {
                wake.Set();
                while (WaitHandle.WaitAny(new WaitHandle[] { stop, wake }) == 1)
                {
                    try { Inspect(); }
                    catch (OperationCanceledException) { return; }
                    catch (Exception error) { Log(error.Message, EventLogEntryType.Warning); }
                }
            }
        }
        catch (Exception error) { Log(error.Message, EventLogEntryType.Error); }
    }

    private void Inspect()
    {
        List<string> updates;
        Interlocked.Exchange(ref ignoreScanEventsThrough, long.MaxValue);
        try { updates = RunWorker("Scan"); }
        finally { Interlocked.Exchange(ref ignoreScanEventsThrough, DateTime.UtcNow.Ticks); }

        foreach (string line in updates)
        {
            if (stop.WaitOne(0))
                return;
            Match item = Regex.Match(line, @"\A([0-9a-f-]{36})/([0-9]+)\|([A-Za-z0-9+/=]+)\z");
            if (!item.Success)
                continue;

            string id = item.Groups[1].Value;
            string revision = item.Groups[2].Value;
            string label = Encoding.UTF8.GetString(Convert.FromBase64String(item.Groups[3].Value));
            Log("Hidden pending driver " + id + "/" + revision + ": " + label, EventLogEntryType.Information);
            if (Ask(item.Groups[3].Value))
            {
                Interlocked.Exchange(ref ignoreScanEventsThrough, long.MaxValue);
                try { RunWorker("Allow -UpdateId " + id + " -Revision " + revision); }
                finally { Interlocked.Exchange(ref ignoreScanEventsThrough, DateTime.UtcNow.Ticks); }
                Log("Allowed driver " + id + "/" + revision, EventLogEntryType.Information);
            }
            else
            {
                Log("Driver remains blocked " + id + "/" + revision, EventLogEntryType.Information);
            }
        }
    }

    private List<string> RunWorker(string arguments)
    {
        var output = new List<string>();
        var errors = new StringBuilder();
        using (var process = new Process())
        {
            process.StartInfo = new ProcessStartInfo(WindowsPowerShell,
                "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" +
                Path.Combine(Home, "FuckNahimic.UpdateWorker.ps1") + "\" -Mode " + arguments)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            process.OutputDataReceived += (sender, args) =>
            {
                if (args.Data != null) output.Add(args.Data);
            };
            process.ErrorDataReceived += (sender, args) =>
            {
                if (args.Data != null) errors.AppendLine(args.Data);
            };
            process.Start();
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
            using (var exited = new ManualResetEvent(false))
            {
                process.Exited += (sender, args) => { try { exited.Set(); } catch (ObjectDisposedException) { } };
                process.EnableRaisingEvents = true;
                int result = WaitHandle.WaitAny(new WaitHandle[] { stop, exited }, 45000);
                if (result != 1)
                {
                    if (!process.HasExited)
                    {
                        try { process.Kill(); } catch (InvalidOperationException) { }
                    }
                    if (result == 0) throw new OperationCanceledException();
                    throw new System.TimeoutException("The Windows Update cache query timed out.");
                }
            }
            process.WaitForExit();
            if (errors.Length != 0)
                Log(errors.ToString(), EventLogEntryType.Warning);
            if (process.ExitCode != 0)
                throw new InvalidOperationException("The update worker exited with code " + process.ExitCode);
        }
        return output;
    }

    private bool Ask(string label)
    {
        IntPtr token;
        uint session = WTSGetActiveConsoleSessionId();
        if (session == uint.MaxValue || !WTSQueryUserToken(session, out token))
            return false;

        try
        {
            string id = Guid.NewGuid().ToString("N");
            using (var identity = new WindowsIdentity(token))
            {
                var security = EventSecurity(identity.User);
                bool created;
                using (var allow = new EventWaitHandle(false, EventResetMode.ManualReset,
                    DecisionPrefix + id + ".allow", out created, security))
                using (var block = new EventWaitHandle(false, EventResetMode.ManualReset,
                    DecisionPrefix + id + ".block", out created, security))
                {
                    LaunchToast(token, id, label);
                    return WaitHandle.WaitAny(new WaitHandle[] { stop, block, allow },
                        TimeSpan.FromSeconds(30)) == 2;
                }
            }
        }
        catch (Exception error)
        {
            Log("Notification unavailable: " + error.Message, EventLogEntryType.Warning);
            return false;
        }
        finally { CloseHandle(token); }
    }

    private static EventWaitHandleSecurity EventSecurity(SecurityIdentifier user)
    {
        var security = new EventWaitHandleSecurity();
        security.AddAccessRule(new EventWaitHandleAccessRule(
            new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
            EventWaitHandleRights.FullControl, AccessControlType.Allow));
        security.AddAccessRule(new EventWaitHandleAccessRule(
            new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null),
            EventWaitHandleRights.Modify | EventWaitHandleRights.Synchronize, AccessControlType.Allow));
        if (user != null)
            security.AddAccessRule(new EventWaitHandleAccessRule(
                user, EventWaitHandleRights.Modify, AccessControlType.Allow));
        return security;
    }

    private static int Reply(string request)
    {
        Match match = Regex.Match(request, @"\Afucknahimic://(allow|block)/([0-9a-f]{32})/?\z");
        if (!match.Success) return 2;
        try
        {
            using (var reply = EventWaitHandle.OpenExisting(
                DecisionPrefix + match.Groups[2].Value + "." + match.Groups[1].Value,
                EventWaitHandleRights.Modify))
                reply.Set();
            return 0;
        }
        catch (WaitHandleCannotBeOpenedException) { return 1; }
        catch (UnauthorizedAccessException) { return 1; }
    }

    private static void LaunchToast(IntPtr token, string id, string label)
    {
        IntPtr environment;
        if (!CreateEnvironmentBlock(out environment, token, false))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        try
        {
            var startup = new StartupInfo { Size = Marshal.SizeOf(typeof(StartupInfo)), Desktop = @"winsta0\default" };
            var command = new StringBuilder("\"" + WindowsPowerShell +
                "\" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" +
                Path.Combine(Home, "FuckNahimic.ShowToast.ps1") + "\" -Token " + id + " -Label " + label +
                " -ExpiresAt " + DateTimeOffset.UtcNow.AddSeconds(30).ToUnixTimeSeconds().ToString(CultureInfo.InvariantCulture));
            ProcessInformation process;
            const uint unicodeEnvironment = 0x400;
            const uint noWindow = 0x08000000;
            if (!CreateProcessAsUser(token, WindowsPowerShell, command, IntPtr.Zero, IntPtr.Zero,
                false, unicodeEnvironment | noWindow, environment, Home, ref startup, out process))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            CloseHandle(process.Process);
            CloseHandle(process.Thread);
        }
        finally { DestroyEnvironmentBlock(environment); }
    }

    private static void Log(string message, EventLogEntryType level)
    {
        if (message.Length > 6000) message = message.Substring(0, 6000);
        try { EventLog.WriteEntry(GuardName, message, level); }
        catch (InvalidOperationException) { }
        catch (System.Security.SecurityException) { }
        catch (Win32Exception) { }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInfo
    {
        public int Size;
        public string Reserved, Desktop, Title;
        public int X, Y, XSize, YSize, XCountChars, YCountChars, FillAttribute, Flags;
        public short ShowWindow, Reserved2;
        public IntPtr Reserved3, StandardInput, StandardOutput, StandardError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInformation
    {
        public IntPtr Process, Thread;
        public int ProcessId, ThreadId;
    }

    [DllImport("kernel32.dll")] private static extern uint WTSGetActiveConsoleSessionId();
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    [DllImport("wtsapi32.dll", SetLastError = true)] private static extern bool WTSQueryUserToken(uint session, out IntPtr token);
    [DllImport("userenv.dll", SetLastError = true)] private static extern bool CreateEnvironmentBlock(out IntPtr environment, IntPtr token, bool inherit);
    [DllImport("userenv.dll")] private static extern bool DestroyEnvironmentBlock(IntPtr environment);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcessAsUser(IntPtr token, string application, StringBuilder command,
        IntPtr processAttributes, IntPtr threadAttributes, bool inherit, uint flags, IntPtr environment,
        string directory, ref StartupInfo startup, out ProcessInformation process);
}

internal static class ToastShortcut
{
    private static readonly Guid AppModelKey = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");

    internal static void Create(string destination)
    {
        object instance = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("00021401-0000-0000-C000-000000000046")));
        try
        {
            ((IShellLinkW)instance).SetPath(Process.GetCurrentProcess().MainModule.FileName);
            var store = (IPropertyStore)instance;
            Set(store, 5, 31, Marshal.StringToCoTaskMemUni(FuckNahimic.AppId));
            // Protocol activation is used for both buttons. The stub CLSID retains the toast in Notification Center.
            IntPtr clsid = Marshal.AllocCoTaskMem(16);
            Marshal.StructureToPtr(new Guid("CB56093A-653C-4589-AF38-F8FD91DDB493"), clsid, false);
            Set(store, 26, 72, clsid);
            store.Commit();
            ((IPersistFile)instance).Save(destination, true);
        }
        finally { Marshal.FinalReleaseComObject(instance); }
    }

    private static void Set(IPropertyStore store, uint property, ushort type, IntPtr value)
    {
        var key = new PropertyKey { Format = AppModelKey, Id = property };
        var variant = new PropVariant { Type = type, Value = value };
        try { store.SetValue(ref key, ref variant); }
        finally { Marshal.FreeCoTaskMem(value); }
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct PropertyKey { public Guid Format; public uint Id; }

    [StructLayout(LayoutKind.Explicit, Size = 24)]
    private struct PropVariant
    {
        [FieldOffset(0)] public ushort Type;
        [FieldOffset(8)] public IntPtr Value;
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPropertyStore
    {
        void GetCount();
        void GetAt();
        void GetValue();
        void SetValue(ref PropertyKey key, ref PropVariant value);
        void Commit();
    }

    [ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellLinkW
    {
        void GetPath(); void GetIDList(); void SetIDList(); void GetDescription(); void SetDescription();
        void GetWorkingDirectory(); void SetWorkingDirectory(); void GetArguments(); void SetArguments();
        void GetHotkey(); void SetHotkey(); void GetShowCmd(); void SetShowCmd(); void GetIconLocation();
        void SetIconLocation(); void SetRelativePath(); void Resolve();
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string path);
    }
}
'@
}

function Get-AudioGuardWorkerSource {
    @'
param(
    [Parameter(Mandatory)][ValidateSet('Scan','Allow')][string]$Mode,
    [guid]$UpdateId,
    [int]$Revision
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$state = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'FuckNahimic.Config.json') -Raw | ConvertFrom-Json
$TargetPattern = $state.TargetPattern
$NahimicProvider = $state.NahimicProvider
$OemAudioProvider = $state.OemAudioProvider
$RealtekAudioProvider = $state.RealtekAudioProvider
$GenericInf = $state.GenericInf
$MediaClass = $state.MediaClass
$ExtensionClass = $state.ExtensionClass
$PnpUtil = Join-Path $env:SystemRoot 'System32\pnputil.exe'

# Existing update matching and exact-revision approval helpers are added here.
# GUARD_DEFINITIONS

$updateService = Get-Service -Name wuauserv
if ($updateService.StartType -eq 'Disabled') {
    if ($Mode -eq 'Allow') { throw 'Windows Update is disabled.' }
    return
}
if ($Mode -eq 'Scan' -and $updateService.Status -ne 'Running') { return }
$searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
$searcher.Online = $false
$searcher.IncludePotentiallySupersededUpdates = $true

if ($Mode -eq 'Scan') {
    $result = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Driver'")
    if ([int]$result.ResultCode -ne 2) { throw "Cached driver search result: $($result.ResultCode)" }
    if (-not $result.Updates.Count) { return }
    Update-AudioUpdateScope
    foreach ($update in $result.Updates) {
        $match = Get-TargetUpdateMatch $update -DriverOnly
        if (-not $match) { continue }
        $id = ([guid]$update.Identity.UpdateID).ToString('D')
        $rev = [int]$update.Identity.RevisionNumber
        if (Test-GuardApprovedUpdate $id $rev) { continue }
        try {
            if ($update.IsMandatory) { throw 'Windows Update marks this update as mandatory.' }
            $update.IsHidden = $true
            if (-not $update.IsHidden) { throw 'Windows Update did not confirm the block.' }
            $label = [string]$update.Title
            $label = $label -replace '[\x00-\x1f]', ' '
            if ($label.Length -gt 220) { $label = $label.Substring(0,220) }
            [Console]::WriteLine("$id/$rev|" + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($label)))
        } catch {
            [Console]::Error.WriteLine("Could not block $id/$rev ($($update.Title)): $_")
        }
    }
    return
}

if ($UpdateId -eq [guid]::Empty -or $Revision -lt 1) { throw 'Invalid update identity.' }
$id = $UpdateId.ToString('D')
$result = $searcher.Search("IsInstalled=0 and IsHidden=1 and UpdateID='$id' and RevisionNumber=$Revision")
if ([int]$result.ResultCode -ne 2) { throw "Cached exact update search result: $($result.ResultCode)" }
$items = @($result.Updates | Where-Object {
    ([guid]$_.Identity.UpdateID) -eq $UpdateId -and [int]$_.Identity.RevisionNumber -eq $Revision
})
Update-AudioUpdateScope
if ($items.Count -ne 1 -or -not (Get-TargetUpdateMatch $items[0] -DriverOnly)) {
    throw 'The exact pending update is no longer blocked or in scope.'
}
$key = 'HKLM:\SOFTWARE\EricSoft\FuckNahimic\Guard\Approved'
$null = New-Item -Path $key -Force
$property = "$id/$Revision"
$items[0].IsHidden = $false
if ($items[0].IsHidden) { throw 'Windows Update did not confirm that the update was allowed.' }
try {
    $null = New-ItemProperty -LiteralPath $key -Name $property -PropertyType DWord -Value 1 -Force
} catch {
    $items[0].IsHidden = $true
    throw
}
'@
}

function Get-AudioGuardToastSource {
    @'
param(
    [Parameter(Mandatory)][ValidatePattern('\A[0-9a-f]{32}\z')][string]$Token,
    [Parameter(Mandatory)][string]$Label,
    [Parameter(Mandatory)][long]$ExpiresAt
)
$ErrorActionPreference = 'Stop'
$expiry = [DateTimeOffset]::FromUnixTimeSeconds($ExpiresAt)
if ($expiry -le [DateTimeOffset]::UtcNow) { return }
$title = [Security.SecurityElement]::Escape([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Label)))
$allow = "fucknahimic://allow/$Token"
$block = "fucknahimic://block/$Token"
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime] | Out-Null
[Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType=WindowsRuntime] | Out-Null
$xml = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType=WindowsRuntime]::new()
$xml.LoadXml(@"
<toast scenario="reminder" activationType="protocol" launch="fucknahimic://view/$Token">
  <visual><binding template="ToastGeneric">
    <text>FuckNahimic · 已屏蔽音频驱动更新</text>
    <text>$title</text>
    <text>30 秒内可允许安装。超时后继续屏蔽。</text>
  </binding></visual>
  <actions>
    <action content="允许安装" arguments="$allow" activationType="protocol" />
    <action content="继续阻止" arguments="$block" activationType="protocol" />
  </actions>
  <audio silent="true" />
</toast>
"@)
$notification = [Windows.UI.Notifications.ToastNotification]::new($xml)
$notification.ExpirationTime = $expiry
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('EricSoft.FuckNahimic').Show($notification)
'@
}

function Get-TargetUpdateMatch {
    param($Update, [switch]$DriverOnly)

    if ([int]$Update.Type -ne 2) {
        if (-not $DriverOnly -and $Update.Title -match $TargetPattern) {
            return [pscustomobject]@{ OemAudio = $false; Detail = 'Nahimic or Sonic Studio software' }
        }
        return
    }

    # A driver update can carry multiple applicable entries. All entries must
    # match the cleanup scope before the entire update can be hidden.
    $entries = @($Update)
    $entryProperty = $Update.PSObject.Properties['WindowsDriverUpdateEntries']
    if ($entryProperty) {
        $collection = $entryProperty.Value
        if ($null -ne $collection -and $collection.Count -gt 0) {
            $entries = @(for ($i = 0; $i -lt $collection.Count; $i++) { $collection.Item($i) })
        }
    }

    $driverMatches = @(foreach ($entry in $entries) {
        $hardwareId = [string]$entry.DriverHardwareID
        $provider = [string]$entry.DriverProvider
        if (-not $provider) { $provider = [string]$entry.DriverManufacturer }
        if ($provider -match '^Microsoft(?:\s|$)') { return }

        $oemAudio = $hardwareId -in $script:AudioUpdateScope.HardwareIds -and
            $provider -match $OemAudioProvider -and
            $entry.DriverClass -in 'MEDIA','Extension','SoftwareComponent','AudioProcessingObject'
        # Windows Update reports these SWC matches as OtherHardware even when the
        # update title and matched device are SoftwareComponent audio packages.
        $realtekSoftware = $hardwareId -in $script:AudioUpdateScope.RealtekHardwareIds -and
            $provider -match $RealtekAudioProvider -and
            $hardwareId -match '^SWC\\' -and
            $entry.DriverClass -in 'SoftwareComponent','AudioProcessingObject','OtherHardware'
        if (-not ($oemAudio -or $realtekSoftware)) {
            $nahimicSoftware = $hardwareId -match '^(?:ROOT|SWC|SWD)\\' -and
                $entry.DriverClass -in 'MEDIA','Extension','SoftwareComponent','AudioProcessingObject' -and
                ($provider -match $NahimicProvider -or
                 ($hardwareId -in $script:AudioUpdateScope.SoftwareHardwareIds -and $Update.Title -match $TargetPattern))
            if (-not $nahimicSoftware) { return }
        }

        [pscustomobject]@{ OemAudio = $oemAudio; Detail = "$provider | $hardwareId" }
    })
    if ($driverMatches.Count -ne $entries.Count) { return }
    [pscustomobject]@{
        OemAudio = $true -in $driverMatches.OemAudio
        Detail = ($driverMatches.Detail | Select-Object -Unique) -join '; '
    }
}

function Get-WindowsUpdateResult {
    param([string]$Criteria, [switch]$Cached)
    $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
    if ($Cached) { $searcher.Online = $false }
    $result = $searcher.Search($Criteria)
    if ([int]$result.ResultCode -ne 2) {
        throw "Windows Update search result: $($result.ResultCode)."
    }
    $result
}

function Get-WindowsUpdateOperations {
    param([switch]$DriverOnly)
    $criteria = 'IsInstalled=0 and IsHidden=0'
    if ($DriverOnly) { $criteria += " and Type='Driver'" }
    $result = Get-WindowsUpdateResult $criteria
    $seen = @{}
    foreach ($update in $result.Updates) {
        $match = Get-TargetUpdateMatch $update -DriverOnly:$DriverOnly
        if (-not $match) { continue }

        $id = ([guid]$update.Identity.UpdateID).ToString('D')
        $revision = [int]$update.Identity.RevisionNumber
        $key = "$id/$revision"
        if (Test-GuardApprovedUpdate $id $revision) { continue }
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        [pscustomobject]@{
            Kind = 'WindowsUpdate'
            Detail = "$($update.Title) [$id rev. $revision] ($($match.Detail))"
            Data = @{
                UpdateId = $id
                Revision = $revision
                DriverOnly = [bool]$DriverOnly
                TargetsOemAudio = $match.OemAudio
            }
        }
    }
}

function Add-WindowsUpdatePlan {
    $operations = @(Get-WindowsUpdateOperations)
    foreach ($operation in $operations) { $script:Plan.Add($operation) }
    if (-not $operations.Count) { Write-Host 'Windows Update: no matching pending updates to hide in this scan.' }
}

function Hide-PlannedWindowsUpdate {
    param([hashtable]$Data)
    $id = ([guid]$Data.UpdateId).ToString('D')
    $revision = [int]$Data.Revision
    $result = Get-WindowsUpdateResult "IsInstalled=0 and UpdateID='$id' and RevisionNumber=$revision" -Cached
    $update = @($result.Updates | Where-Object {
        ([guid]$_.Identity.UpdateID).ToString('D') -eq $id -and [int]$_.Identity.RevisionNumber -eq $revision
    })
    if ($update.Count -ne 1) {
        throw "Could not locate the exact pending Windows Update revision $id/$revision in the update cache."
    }
    $selected = $update[0]
    if (Test-GuardApprovedUpdate $id $revision) { return }
    if (-not (Get-TargetUpdateMatch $selected -DriverOnly:$Data.DriverOnly)) {
        throw 'The update no longer matches the approved hardware and driver provider.'
    }
    if (-not $selected.IsHidden) {
        if ($selected.IsMandatory) { throw 'Windows Update marks this update as mandatory, so it cannot be hidden.' }
        $selected.IsHidden = $true
    }
    if (-not $selected.IsHidden) { throw 'Windows Update did not confirm the change.' }
}

function Get-WindowsUpdateStartMode {
    $path = 'HKLM:\SYSTEM\CurrentControlSet\Services\wuauserv'
    $configuration = Get-ItemProperty -LiteralPath $path
    switch ([int]$configuration.Start) {
        2 {
            $delayed = $configuration.PSObject.Properties['DelayedAutoStart']
            if ($delayed -and [int]$delayed.Value -eq 1) { return 'delayed-auto' }
            return 'auto'
        }
        3 { return 'demand' }
        4 { return 'disabled' }
        default { throw 'Unexpected Windows Update service startup mode.' }
    }
}

function Get-WindowsUpdateAutomaticPolicy {
    $path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    $policy = $null
    try {
        $policy = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
    } catch [System.Management.Automation.ItemNotFoundException] {
        # An unconfigured policy may have no AU key.
    }
    $values = [ordered]@{ NoAutoUpdate = $null; AUOptions = $null }
    if ($policy) {
        foreach ($name in 'NoAutoUpdate','AUOptions') {
            $property = $policy.PSObject.Properties[$name]
            if ($property) { $values[$name] = $property.Value }
        }
    }
    [pscustomobject]$values
}

function Get-WindowsUpdateSnapshot {
    $service = Get-Service -Name wuauserv
    $policy = Get-WindowsUpdateAutomaticPolicy
    [pscustomobject]@{
        StartMode = Get-WindowsUpdateStartMode
        WasRunning = $service.Status -in 'Running','StartPending'
        AutomaticPolicy = $policy
    }
}

function Set-WindowsUpdateStartMode {
    param([ValidateSet('auto','delayed-auto','demand','disabled')][string]$Mode)
    $sc = Join-Path ([Environment]::SystemDirectory) 'sc.exe'
    $output = @(& $sc config wuauserv 'start=' $Mode 2>&1)
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "Could not set Windows Update service to $Mode (exit $code). $($output -join ' ')" }
    if ((Get-WindowsUpdateStartMode) -ne $Mode) {
        throw "Windows Update service did not retain startup mode $Mode."
    }
}

function Restore-WindowsUpdateService {
    param([string]$OriginalMode, [bool]$WasRunning)

    $current = Get-WindowsUpdateStartMode
    if ($current -eq 'disabled' -and $OriginalMode -ne 'disabled') {
        Set-WindowsUpdateStartMode $OriginalMode
    } elseif ($current -ne $OriginalMode) {
        Write-Warning "Windows Update startup mode was changed separately to $current. Leaving it in that mode."
        return
    }

    $service = Get-Service -Name wuauserv
    if ($WasRunning -and $service.Status -ne 'Running') {
        Start-Service -Name wuauserv
        $service.WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
    } elseif (-not $WasRunning -and $service.Status -ne 'Stopped') {
        Stop-Service -Name wuauserv
        $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
    }
    Write-Host "Windows Update restored: $OriginalMode, $($service.Status)."
}

function Get-EndpointWorkerDigest {
    param([string]$Arguments)

    if ($Arguments -notmatch '(?i)(?:^|\s)-EncodedCommand\s+"?([a-z0-9+/=]+)') { return }
    $token = $Matches[1]
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::ASCII.GetBytes($token))).Replace('-', '')
    } finally {
        $sha.Dispose()
    }
}

function Wait-ForEndpointWorker {
    param([string]$TaskName, [string]$CommandDigest)

    if (-not $TaskName) { return }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        $task = Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction SilentlyContinue
        $workerRunning = $false
        if ($CommandDigest) {
            # The endpoint task unregisters itself before writing names. The process
            # stays alive, so track that exact action as well as the scheduled entry.
            foreach ($process in Get-CimInstance Win32_Process -Filter "Name='powershell.exe'") {
                if ((Get-EndpointWorkerDigest $process.CommandLine) -eq $CommandDigest) {
                    $workerRunning = $true
                    break
                }
            }
        }
        if (-not $task -and -not $workerRunning) { return }
        Start-Sleep -Seconds 5
    } while ($timer.Elapsed.TotalSeconds -lt 300)
    Write-Warning 'The audio endpoint task did not finish within five minutes. Restoring Windows Update anyway.'
}

function Invoke-WindowsUpdateRecovery {
    param($State)

    $ErrorActionPreference = 'Stop'
    $global:PSNativeCommandUseErrorActionPreference = $false
    $rebooted = $false
    try {
        $rebooted = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().Ticks -gt [long]$State.BootTicks
    } catch {
        Write-Warning "Could not read boot time; restoring Windows Update anyway. $_"
    }
    if ($rebooted) {
        try {
            Wait-ForEndpointWorker ([string]$State.EndpointTaskName) ([string]$State.EndpointDigest)
        } catch {
            Write-Warning "Could not verify the audio endpoint task status: $_"
        }
    }
    # The fallback trigger also runs on the same boot if a restart was delayed.
    # Restore the service before opening any Windows Update search session.
    Restore-WindowsUpdateService $State.StartMode ([bool]$State.WasRunning)
    Unregister-ScheduledTask -TaskName $State.RecoveryTask -TaskPath '\' -Confirm:$false

    if ($State.PSObject.Properties['AutomaticPolicy']) {
        $policy = Get-WindowsUpdateAutomaticPolicy
        $recorded = $State.AutomaticPolicy
        if ($policy.NoAutoUpdate -ne $recorded.NoAutoUpdate -or $policy.AUOptions -ne $recorded.AUOptions) {
            Write-Warning 'The automatic-update policy changed separately during maintenance. The current policy was left in place.'
        }
    }
    # Cached and online WUA calls can start a previously stopped service.
    if (-not $State.WasRunning -or $State.StartMode -eq 'disabled' -or (Get-WindowsUpdateStartMode) -ne $State.StartMode) { return }
    $guardReady = Request-AudioGuardScan
    if ($rebooted -and -not $guardReady) {
        $TargetPattern = $State.TargetPattern
        $NahimicProvider = $State.NahimicProvider
        $OemAudioProvider = $State.OemAudioProvider
        $RealtekAudioProvider = $State.RealtekAudioProvider
        $GenericInf = $State.GenericInf
        $MediaClass = $State.MediaClass
        $ExtensionClass = $State.ExtensionClass
        $PnpUtil = Join-Path $env:SystemRoot 'System32\pnputil.exe'
        try {
            Update-AudioUpdateScope
            foreach ($operation in Get-WindowsUpdateOperations -DriverOnly) {
                try {
                    Hide-PlannedWindowsUpdate $operation.Data
                    Write-Host "Hidden after restart: $($operation.Detail)"
                } catch {
                    Write-Warning "Could not hide update after restart [$($operation.Detail)]: $_"
                }
            }
        } catch {
            Write-Warning "Windows Update was restored, but the follow-up driver search failed: $_"
        }
    }
}

function New-WindowsUpdateRecoveryCommand {
    param([hashtable]$State)
    $definitions = foreach ($name in @(
        'Get-WindowsUpdateStartMode','Get-WindowsUpdateAutomaticPolicy','Set-WindowsUpdateStartMode','Restore-WindowsUpdateService',
        'Get-EndpointWorkerDigest','Wait-ForEndpointWorker','Get-TargetUpdateMatch',
        'Get-WindowsUpdateResult','Get-WindowsUpdateOperations','Hide-PlannedWindowsUpdate',
        'Test-GuardApprovedUpdate','Request-AudioGuardScan','Invoke-WindowsUpdateRecovery',
        'Test-NahimicSoftwareDevice','Get-BoardAudioIds','Test-AudioInfMatch','Get-ScopedRealtekDevices','Get-AudioUpdateScope',
        'Update-AudioUpdateScope','Invoke-Native','Get-DriverInventory','Get-CurrentInf'
    )) {
        $body = (Get-Command -Name $name -CommandType Function).ScriptBlock.ToString()
        "function $name {" + [Environment]::NewLine + $body + [Environment]::NewLine + '}'
    }
    $json = ($State | ConvertTo-Json -Depth 4 -Compress).Replace("'", "''")
    $entry = 'try { Invoke-WindowsUpdateRecovery (ConvertFrom-Json ''{0}''); exit 0 } catch { Write-Error -Message $_.Exception.Message -ErrorAction Continue; exit 2 }'
    $command = ($definitions + $entry.Replace('{0}', $json)) -join [Environment]::NewLine
    $memory = [IO.MemoryStream]::new()
    try {
        $zip = [IO.Compression.GZipStream]::new($memory, [IO.Compression.CompressionMode]::Compress, $true)
        $bytes = [Text.Encoding]::UTF8.GetBytes($command)
        try { $zip.Write($bytes, 0, $bytes.Length) }
        finally { $zip.Dispose() }
        $payload = [Convert]::ToBase64String($memory.ToArray())
    } finally { $memory.Dispose() }
    $loader = @'
$m = [IO.MemoryStream]::new([Convert]::FromBase64String('RECOVERY_PAYLOAD'))
$z = [IO.Compression.GZipStream]::new($m, [IO.Compression.CompressionMode]::Decompress)
$r = [IO.StreamReader]::new($z, [Text.Encoding]::UTF8)
try { $source = $r.ReadToEnd() } finally { $r.Dispose() }
& ([scriptblock]::Create($source))
'@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($loader.Replace('RECOVERY_PAYLOAD', $payload)))
    if ($encoded.Length -gt 30000) { throw 'The Windows Update recovery command exceeds the startup task limit.' }
    $encoded
}

function Get-WindowsUpdateRecoveryXml {
    param([string]$PowerShellExe, [string]$EncodedCommand, [DateTime]$Deadline)

    $exe = [Security.SecurityElement]::Escape($PowerShellExe)
    $encoded = [Security.SecurityElement]::Escape($EncodedCommand)
    $time = $Deadline.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Restore Windows Update after audio maintenance or at the timeout.</Description></RegistrationInfo>
  <Triggers>
    <BootTrigger><Enabled>true</Enabled><Delay>PT45S</Delay></BootTrigger>
    <TimeTrigger><StartBoundary>$time</StartBoundary><Enabled>true</Enabled></TimeTrigger>
  </Triggers>
  <Principals>
    <Principal id="SystemAccount"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <Enabled>true</Enabled>
    <ExecutionTimeLimit>PT12M</ExecutionTimeLimit>
    <RestartOnFailure><Interval>PT2M</Interval><Count>3</Count></RestartOnFailure>
  </Settings>
  <Actions Context="SystemAccount">
    <Exec>
      <Command>$exe</Command>
      <Arguments>-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded</Arguments>
    </Exec>
  </Actions>
</Task>
"@
}

function Read-WindowsUpdateRecoveryState {
    param($Task, [string]$TaskName, [string]$PowerShellExe)
    $actions = @($Task.Actions)
    if ($Task.Principal.UserId -notmatch '^(?:S-1-5-18|(?:NT AUTHORITY\\)?SYSTEM)$' -or
        $actions.Count -ne 1 -or $actions[0].Execute -ne $PowerShellExe) {
        throw 'The Windows Update recovery task name is in use by an unrecognized action.'
    }
    $argsMatch = [regex]::Match([string]$actions[0].Arguments, '(?i)(?:^|\s)-EncodedCommand\s+"?([a-z0-9+/=]{1,30000})"?(?:\s|$)')
    if (-not $argsMatch.Success) { throw 'The Windows Update recovery task does not contain the expected command.' }
    $launcher = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($argsMatch.Groups[1].Value))
    $payload = [regex]::Match($launcher, "FromBase64String\('([a-zA-Z0-9+/=]+)'\)")
    if (-not $payload.Success) { throw 'The existing Windows Update recovery state could not be read.' }

    $memory = [IO.MemoryStream]::new([Convert]::FromBase64String($payload.Groups[1].Value))
    $zip = [IO.Compression.GZipStream]::new($memory, [IO.Compression.CompressionMode]::Decompress)
    $reader = [IO.StreamReader]::new($zip, [Text.Encoding]::UTF8)
    try {
        $buffer = [char[]]::new(131072)
        $count = $reader.ReadBlock($buffer, 0, $buffer.Length)
        if ($count -eq $buffer.Length) { throw 'The existing recovery payload exceeds the supported size.' }
        $command = [string]::new($buffer, 0, $count)
    } finally { $reader.Dispose() }

    $record = [regex]::Match($command, "(?m)^try \{ Invoke-WindowsUpdateRecovery \(ConvertFrom-Json '((?:[^'\r\n]|'')*)'\); exit 0 \}")
    if (-not $record.Success) { throw 'The existing recovery task does not contain a recognized state.' }
    $state = $record.Groups[1].Value.Replace("''", "'") | ConvertFrom-Json -ErrorAction Stop
    if ($state.RecoveryTask -ne $TaskName -or $state.StartMode -notin 'auto','delayed-auto','demand' -or
        $state.WasRunning -isnot [bool]) {
        throw 'The existing Windows Update recovery state does not match this task.'
    }
    $state
}

function Suspend-WindowsUpdateForCleanup {
    $taskName = $script:WindowsUpdateRecoveryTaskName
    $powerShell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
    $currentMode = Get-WindowsUpdateStartMode
    $service = Get-Service -Name wuauserv
    $existing = Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
    if ($currentMode -eq 'disabled' -and $service.Status -ne 'Stopped') {
        throw 'Windows Update startup is disabled, but the service is still running. Cleanup has not started.'
    }

    $prior = $null
    if ($existing) {
        if ($existing.State -in 'Running','Queued') {
            throw 'The previous Windows Update recovery is running. Let it finish before retrying.'
        }
        $prior = Read-WindowsUpdateRecoveryState $existing $taskName $powerShell
    }
    if ($currentMode -eq 'disabled' -and -not $prior) {
        $script:WindowsUpdateSuspended = $true
        Write-Host 'Windows Update was already disabled. Its service configuration is being preserved.'
        return
    }

    $before = $script:WindowsUpdateBeforeCleanup
    $automaticPolicy = $before.AutomaticPolicy
    if ($currentMode -eq 'disabled') {
        $originalMode = $prior.StartMode
        $wasRunning = $prior.WasRunning
        if ($prior.PSObject.Properties['AutomaticPolicy']) { $automaticPolicy = $prior.AutomaticPolicy }
    } else {
        if ($currentMode -ne $before.StartMode) {
            throw 'The Windows Update startup mode changed during the preview. Refresh the cleanup plan.'
        }
        $originalMode = $before.StartMode
        $wasRunning = $before.WasRunning
    }
    $installer = $null
    if ($service.Status -ne 'Stopped') {
        $installer = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateInstaller()
        if ($installer.IsBusy) { throw 'Windows Update is currently installing or uninstalling an update. Try cleanup after it finishes.' }
    }

    $endpointTask = if ($script:EndpointRestoreTaskName) {
        Get-ScheduledTask -TaskName $script:EndpointRestoreTaskName -TaskPath '\' -ErrorAction SilentlyContinue
    }
    $digest = if ($endpointTask) { Get-EndpointWorkerDigest $endpointTask.Actions[0].Arguments }
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
    $deadline = [DateTime]::UtcNow.AddMinutes(30)
    $state = @{
        RecoveryTask = $taskName; StartMode = $originalMode; WasRunning = $wasRunning; AutomaticPolicy = $automaticPolicy
        BootTicks = $boot.Ticks.ToString(); EndpointTaskName = $script:EndpointRestoreTaskName; EndpointDigest = $digest
        TargetPattern = $TargetPattern; NahimicProvider = $NahimicProvider
        OemAudioProvider = $OemAudioProvider; RealtekAudioProvider = $RealtekAudioProvider
        GenericInf = $GenericInf; MediaClass = $MediaClass; ExtensionClass = $ExtensionClass
    }

    $xml = Get-WindowsUpdateRecoveryXml $powerShell (New-WindowsUpdateRecoveryCommand $state) $deadline
    $scheduler = New-Object -ComObject Schedule.Service
    $scheduler.Connect()
    $root = $scheduler.GetFolder('\')
    $registrationMode = 2 # TASK_CREATE
    if ($existing) {
        $pending = Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
        if (-not $pending -or $pending.State -in 'Running','Queued' -or
            $pending.Actions.Count -ne 1 -or $pending.Actions[0].Arguments -ne $existing.Actions[0].Arguments -or
            $pending.Actions[0].Execute -ne $existing.Actions[0].Execute -or $pending.Principal.UserId -ne $existing.Principal.UserId) {
            throw 'The pending Windows Update recovery task changed while the cleanup was being prepared.'
        }
        $registrationMode = 4 # TASK_UPDATE
    }
    $recovery = $root.RegisterTask($taskName, $xml, $registrationMode, 'SYSTEM', $null, 5, $null)
    try {
        if (-not $recovery.Enabled) { throw 'The Windows Update recovery task was registered but is disabled.' }
        if ($installer -and $installer.IsBusy) { throw 'Windows Update started installing an update before the pause.' }
        if ($currentMode -ne 'disabled') { Set-WindowsUpdateStartMode disabled }
        $service.Refresh()
        if ($service.Status -ne 'Stopped') {
            Stop-Service -Name wuauserv
            $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
        }
        $script:WindowsUpdateSuspended = $true
        if ($existing) { Write-Host "Refreshed the pending Windows Update recovery task: $taskName." }
        Write-Host "Windows Update paused. Recovery state: $originalMode, service was running: $wasRunning. Fallback: $($deadline.ToLocalTime().ToString('HH:mm:ss'))."
    } catch {
        $pauseError = $_
        try {
            Restore-WindowsUpdateService $originalMode $wasRunning
            Unregister-ScheduledTask -TaskName $taskName -TaskPath '\' -Confirm:$false
        } catch {
            Write-Warning "Immediate Windows Update rollback did not finish; the scheduled recovery is retained. $_"
        }
        throw $pauseError
    }
}

function Add-ApplicationPlan {
    foreach ($root in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($key in Get-ChildItem -LiteralPath $root) {
            $name = [string]$key.GetValue('DisplayName')
            if ($name -notmatch $TargetPattern) { continue }
            $quiet = [string]$key.GetValue('QuietUninstallString')
            $uninstall = [string]$key.GetValue('UninstallString')
            $msiProductPattern = '\{[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\}'
            if ($uninstall -match '(?:^|[\\"])msiexec(?:\.exe)?["\s]' -and $uninstall -match $msiProductPattern) {
                $command = Join-Path $env:SystemRoot 'System32\msiexec.exe'
                $arguments = "/x $($Matches[0]) /qn /norestart"
            } elseif ($quiet -match '^\s*"([^"]+)"\s*(.*)$' -or $quiet -match '^\s*(.+?\.exe)(?:\s+(.*)|\s*$)') {
                $command = [Environment]::ExpandEnvironmentVariables([string]$Matches[1])
                $arguments = [Environment]::ExpandEnvironmentVariables([string]$Matches[2])
            } else {
                Add-ScanIssue "No supported unattended uninstall command for $name."
                continue
            }
            Add-Operation Win32 $name @{ Command = $command; Arguments = $arguments; Key = $key.PSPath }
        }
    }

    $appx = @(Get-AppxPackage -AllUsers -PackageTypeFilter Main,Bundle | Where-Object {
        $_.Name -eq $RealtekAudioControlAppx -or $_.Name -match $TargetPattern -or $_.PackageFullName -match $TargetPattern
    })
    foreach ($group in $appx | Group-Object Name) {
        $bundles = @($group.Group | Where-Object IsBundle)
        foreach ($package in $group.Group) {
            if (-not $package.IsBundle -and @($bundles | Where-Object Version -EQ $package.Version).Count) { continue }
            Add-Operation Appx $package.PackageFullName @{ FullName = $package.PackageFullName }
        }
    }
}

function Read-RegistryKey {
    param(
        [string]$Path,
        [System.Security.AccessControl.RegistryRights]$Rights,
        [scriptblock]$Read,
        [switch]$StopOnError
    )

    $key = $null
    try {
        $hive = if ($Path.StartsWith('HKLM:\')) {
            [Microsoft.Win32.Registry]::LocalMachine
        } elseif ($Path.StartsWith('HKCU:\')) {
            [Microsoft.Win32.Registry]::CurrentUser
        } else {
            throw "Unsupported registry path: $Path"
        }
        $key = $hive.OpenSubKey($Path.Substring(6), [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadSubTree, $Rights)
        if ($null -ne $key) { & $Read $key }
    } catch {
        if ($StopOnError) { throw }
        Add-ScanIssue "Registry inventory [$Path]: $($_.Exception.GetBaseException().Message)"
    } finally {
        if ($null -ne $key) { $key.Dispose() }
    }
}

function Add-RegistryPlan {
    $queryValues = [System.Security.AccessControl.RegistryRights]::QueryValues
    $listSubkeys = $queryValues -bor [System.Security.AccessControl.RegistryRights]::EnumerateSubKeys
    $keys = @(
        'HKCU:\SOFTWARE\A-Volute'
        'HKLM:\SOFTWARE\A-Volute'
        'HKLM:\SOFTWARE\WOW6432Node\A-Volute'
        'HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application\NahimicService'
        'HKLM:\SOFTWARE\ASUS\ASUS Sonic Studio'
        'HKLM:\SOFTWARE\WOW6432Node\ASUS\ASUS Sonic Studio'
        'HKCU:\SOFTWARE\ASUS\SonicStudio'
        'HKLM:\SOFTWARE\ASUS\A-Studio'
        'HKCU:\SOFTWARE\ASUS\A-Studio'
        'HKLM:\SOFTWARE\ASUSTeK Computer Inc.\ASUS Sonic Studio'
    )
    foreach ($path in $keys) {
        if (Read-RegistryKey $path $queryValues { param($key) $true }) {
            Add-Operation Registry $path @{ Path = $path }
        }
    }

    # Enumerate names on the parent so unrelated protected child keys stay unopened.
    $deviceNames = @(Read-RegistryKey $AudioClassPath $listSubkeys { param($key) $key.GetSubKeyNames() })
    foreach ($device in $deviceNames | Where-Object { $_ -match '^\d{4}$' }) {
        $interfacePath = "$AudioClassPath\$device\InterfaceSetting"
        foreach ($leaf in Read-RegistryKey $interfacePath $listSubkeys { param($key) $key.GetSubKeyNames() }) {
            if ($leaf -in 'PlaybackSS3Config','RecordSS3Config') {
                Add-Operation ApoKey "$device\InterfaceSetting\$leaf" @{ Path = "$interfacePath\$leaf" }
            }
        }

        $fxPath = "$AudioClassPath\$device\FxProperties"
        foreach ($name in Read-RegistryKey $fxPath $queryValues { param($key) $key.GetValueNames() }) {
            if ($name -match $ApoPropertyPattern) {
                Add-Operation ApoValue "$device\FxProperties\$name" @{ Path = $fxPath; Name = $name }
            }
        }
    }

    foreach ($root in $ApoPaths) {
        foreach ($name in Read-RegistryKey $root $listSubkeys { param($key) $key.GetSubKeyNames() }) {
            $path = "$root\$name"
            $targetApo = Read-RegistryKey $path $queryValues {
                param($key)
                $key.GetValue('FriendlyName') -match $TargetPattern -or $key.GetValue('Copyright') -match $TargetPattern
            }
            if ($targetApo) { Add-Operation ApoKey $path @{ Path = $path } }
        }
    }
}

function Add-FilePlan {
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($path in @(
        "$env:SystemRoot\System32\A-Volute"
        "$env:LOCALAPPDATA\NhNotifSys"
        "$env:ProgramData\A-Volute"
        "$env:APPDATA\A-Volute"
        "$env:LOCALAPPDATA\ASUS\SonicStudio"
        "$env:APPDATA\ASUS\SonicStudio"
        "$env:ProgramData\ASUS\SonicStudio"
    )) { $paths.Add($path) }
    $programRoots = @($env:ProgramFiles, [Environment]::GetEnvironmentVariable('ProgramFiles(x86)'))
    foreach ($root in $programRoots | Where-Object { $_ } | Select-Object -Unique) {
        foreach ($relative in @('MSI\One Dragon Center\Nahimic','ASUS\SonicStudio3','ASUS\Sonic Suite','ASUS\A-Studio')) {
            $paths.Add((Join-Path $root $relative))
        }
    }
    foreach ($directory in @("$env:SystemRoot\System32","$env:SystemRoot\SysWOW64")) {
        if (-not (Test-Path -LiteralPath $directory)) { continue }
        foreach ($file in Get-ChildItem -LiteralPath $directory -File | Where-Object Name -Match $TargetPattern) {
            $paths.Add($file.FullName)
        }
    }
    foreach ($path in $paths | Select-Object -Unique) {
        if (Test-Path -LiteralPath $path) { Add-Operation File $path @{ Path = $path } }
    }
}

function New-RemovalPlan {
    $script:Plan = [System.Collections.Generic.List[object]]::new()
    $script:ScanIssues = [System.Collections.Generic.List[string]]::new()
    $script:AudioUpdateScope = $null
    $script:AudioEndpointInstance = $null
    $script:EndpointRestoreTaskName = $null
    $script:WindowsUpdateBeforeCleanup = Get-WindowsUpdateSnapshot
    $before = $script:WindowsUpdateBeforeCleanup
    $policy = $before.AutomaticPolicy
    Write-Host "Windows Update before cleanup: StartMode=$($before.StartMode), WasRunning=$($before.WasRunning), AUOptions=$($policy.AUOptions), NoAutoUpdate=$($policy.NoAutoUpdate)."

    # The driver scan is required. Without bindings, the plan cannot safely proceed.
    $pnpDevices = @(Get-PnpDevice)
    Add-DriverPlan $pnpDevices
    try { Add-ApplicationPlan } catch { Add-ScanIssue "Application inventory: $_" }
    try {
        foreach ($package in Get-ProvisionedAppx) {
            if ($package.DisplayName -eq $RealtekAudioControlAppx -or $package.PackageName -like "$($RealtekAudioControlAppx)_*" -or
                $package.DisplayName -match $TargetPattern -or $package.PackageName -match $TargetPattern) {
                Add-Operation ProvisionedAppx $package.PackageName @{ Package = $package.PackageName }
            }
        }
    } catch { Add-ScanIssue "Provisioned AppX inventory: $_" }
    try {
        foreach ($service in Get-Service | Where-Object Name -Match '^(?:NahimicService|Nahimic_Mirroring|AVolute.*|SonicSuite.*|ASSonicStudio.*|ASonicStudio.*)$') {
            Add-Operation Service "$($service.Name) [$($service.Status)]" @{ Name = $service.Name }
        }
        foreach ($process in Get-Process | Where-Object ProcessName -Match '^(?:Nahimic(?:Svc|Service).*|A[-_ ]Volute.*|NhNotifSys.*|(?:AS|A)?SonicStudio.*|SonicSuite.*|A[-_ ]?Studio.*)$') {
            Add-Operation Process "$($process.Name) [PID $($process.Id)]" @{
                Name = $process.Name
                Id = $process.Id
                Started = $process.StartTime
            }
        }
    } catch { Add-ScanIssue "Service or process inventory: $_" }
    try { Add-RegistryPlan } catch { Add-ScanIssue "Registry inventory: $_" }
    try { Add-FilePlan } catch { Add-ScanIssue "File inventory: $_" }
    try {
        foreach ($task in Get-ScheduledTask | Where-Object {
            $ownTask = $_.TaskPath -eq '\' -and ($_.TaskName -eq $script:WindowsUpdateRecoveryTaskName -or
                $_.TaskName -match '^FuckNahimic-RestoreAudioEndpoints-[0-9a-f]{32}$')
            -not $ownTask -and ($_.TaskName -match $TargetPattern -or $_.TaskPath -match $TargetPattern)
        }) {
            Add-Operation Task "$($task.TaskPath)$($task.TaskName)" @{ Name = $task.TaskName; Path = $task.TaskPath }
        }
    } catch { Add-ScanIssue "Scheduled task inventory: $_" }
    $needsMaintenance = [bool]($script:Plan | Where-Object Kind -NotIn 'WindowsUpdate','OemUpdateRecheck')
    try {
        if ($before.StartMode -ne 'disabled' -and $before.WasRunning) {
            Add-WindowsUpdatePlan
        } else {
            Write-Host 'Windows Update was disabled or stopped; skipping the search to preserve its state.'
        }
    } catch { Add-ScanIssue "Windows Update inventory: $_" }
    if ($needsMaintenance) {
        Add-Operation WindowsUpdatePause 'Pause Windows Update before cleanup. Restore after the audio startup task or after a 30-minute fallback.'
    }
    if ($script:AudioEndpointInstance -and $needsMaintenance) {
        try {
            $endpoints = @(Get-CardAudioEndpoints $script:AudioEndpointInstance -IncludeNotPresent)
            if (-not $endpoints.Count) { throw 'No named endpoints for the primary audio device are visible.' }
            $labels = @($endpoints | ForEach-Object { Format-SavedAudioEndpoint $_ })
            $namePlan = "Save and restore once after restart: $($labels -join ', ')"
        } catch {
            Add-ScanIssue "Audio endpoint names: $_"
            $namePlan = 'Retry the endpoint snapshot before applying local audio cleanup'
        }
        Add-Operation EndpointNames $namePlan @{ Instance = $script:AudioEndpointInstance }
    }
    if (-not $SkipGuard -and ($script:AudioUpdateScope.Device -or $script:AudioUpdateScope.SoftwareDevices.Count)) {
        try {
            if (-not (Test-AudioGuardReady)) {
                Add-Operation FuckNahimic 'Install the event-driven Windows Update guard with a 30-second notification decision.'
            }
        } catch { Add-ScanIssue "FuckNahimic inventory: $_" }
    }
}

function Get-PlannedPackage {
    param($Package)

    $live = @(Get-DriverInventory | Where-Object Name -EQ $Package.Name)
    if ($live.Count -eq 0) { return }
    if ($live.Count -ne 1 -or $live[0].Original -ne $Package.Original -or
        $live[0].Provider -ne $Package.Provider -or $live[0].Class -ne $Package.Class -or
        $live[0].Version -ne $Package.Version) {
        throw "Driver identity changed after preview: $($Package.Name). Run the preview again."
    }
    $live[0]
}

function Remove-PlannedPackage {
    param($Package, [switch]$Uninstall, [switch]$VerifiedOemBase)

    if ($Package.Class -eq $MediaClass -and $Package.Provider -notmatch $NahimicProvider) {
        if (-not $VerifiedOemBase -or $Uninstall -or $Package.Provider -notmatch $RealtekAudioProvider -or $Package.Devices.Count) {
            throw "The OEM audio base package is still in use or was not verified for removal: $($Package.Name)."
        }
    }
    $arguments = @('/delete-driver', $Package.Name)
    if ($Uninstall) { $arguments += '/uninstall' }
    Invoke-Native $PnpUtil $arguments -AllowRebootRequired | ForEach-Object { Write-Host $_ }
    if (Get-PlannedPackage $Package) {
        throw "Driver package still present after PnPUtil completed: $($Package.Name)."
    }
}

function Invoke-AudioMigration {
    param([hashtable]$Data)

    $instance = $Data.Instance
    $current = Get-CurrentInf $instance
    if ($current -ne $Data.Base -and $current -ne $GenericInf) {
        throw "The primary audio driver changed after preview: $current."
    }
    $liveExtensions = @(foreach ($package in $Data.Extensions) {
        $item = Get-PlannedPackage $package
        if (-not $item) { continue }
        if ($item.Class -ne $ExtensionClass -or @($item.Devices | Where-Object { $_ -ne $instance }).Count) {
            throw "$($item.Name) no longer matches the approved extension bindings."
        }
        $item
    })
    $liveBase = @(foreach ($package in $Data.BasePackages) {
        $item = Get-PlannedPackage $package
        if (-not $item) { continue }
        if ($item.Class -ne $MediaClass -or $item.Provider -notmatch $RealtekAudioProvider -or
            @($item.Devices | Where-Object { $_ -ne $instance }).Count) {
            throw "$($item.Name) no longer matches the approved OEM base bindings."
        }
        $item
    })
    if ($current -ne $GenericInf -and $current -notin @($liveBase | ForEach-Object Name)) {
        throw "Could not verify the active OEM base package: $current."
    }
    $backupPackages = $liveBase + $liveExtensions

    foreach ($package in $backupPackages) {
        $directory = Join-Path $script:BackupDirectory $package.Name
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        Invoke-Native $PnpUtil @('/export-driver',$package.Name,$directory) | ForEach-Object { Write-Host $_ }
        if (-not (Get-ChildItem -LiteralPath $directory -Recurse -File -Filter $package.Original | Select-Object -First 1)) {
            throw "Driver export did not contain $($package.Original): $directory."
        }
    }
    if ($backupPackages.Count) { Write-Host "OEM driver backup: $script:BackupDirectory" }


    if ($current -ne $GenericInf -and [FuckNahimic.DeviceDriver]::Select($instance, $GenericInf, 'Microsoft', $true)) {
        $script:RebootRequired = $true
    }
    if ((Get-CurrentInf $instance) -ne $GenericInf) {
        throw "Could not verify $GenericInf on the primary audio device. OEM packages have been retained."
    }
    $device = @(Get-PnpDevice -InstanceId $instance -PresentOnly)
    if ($device.Count -ne 1 -or $device[0].Status -ne 'OK') {
        throw "The primary audio device is not ready. OEM packages have been retained."
    }

    # Keep the verified card association even after all matching vendor packages are removed.
    $statePath = 'HKLM:\SOFTWARE\EricSoft\FuckNahimic'
    $null = New-Item -Path $statePath -Force
    $null = New-ItemProperty -LiteralPath $statePath -Name AudioInstance -PropertyType String -Value $instance -Force

    # Removing an installed extension can restart PnP driver selection. Remove
    # the backed-up, unbound OEM base candidates first so they cannot win again.
    foreach ($package in $liveBase) {
        $item = Get-PlannedPackage $package
        if (-not $item) { continue }
        $activeInf = Get-CurrentInf $instance
        if ($activeInf -ne $GenericInf) {
            throw "Before removing $($item.Name), the primary card reports '$activeInf'; expected $GenericInf."
        }
        if ($item.Devices.Count) {
            throw "The OEM base package $($item.Name) is still bound to a device. It was kept."
        }
        Remove-PlannedPackage $item -VerifiedOemBase
    }

    foreach ($package in $liveExtensions) {
        $item = Get-PlannedPackage $package
        if (-not $item) { continue }
        $activeInf = Get-CurrentInf $instance
        if ($activeInf -ne $GenericInf) {
            throw "Before removing extension $($item.Name), the primary card reports '$activeInf'; expected $GenericInf."
        }
        if (@($item.Devices | Where-Object { $_ -ne $instance }).Count) {
            throw "Extension $($item.Name) was rebound to another device. It was kept."
        }
        Remove-PlannedPackage $item -Uninstall:($item.Devices.Count -gt 0)
    }

    Assert-GenericAudio $instance
}

function Assert-GenericAudio {
    param([string]$InstanceId)
    if ((Get-CurrentInf $InstanceId) -ne $GenericInf) {
        throw 'The primary audio device no longer reports the Microsoft generic driver.'
    }
    $device = @(Get-PnpDevice -InstanceId $InstanceId -PresentOnly)
    if ($device.Count -ne 1 -or $device[0].Status -ne 'OK') {
        throw 'Windows does not report the primary audio device as healthy.'
    }
    $remaining = @(Get-DriverInventory | Where-Object { $_.Class -eq $ExtensionClass -and $_.Devices -contains $InstanceId })
    if ($remaining.Count) {
        throw "Extensions still bound to the primary audio device: $($remaining.Name -join ', ')."
    }
}

function Invoke-Operation {
    param($Operation)

    $data = $Operation.Data
    switch ($Operation.Kind) {
        'WindowsUpdate' {
            Hide-PlannedWindowsUpdate $data
        }
        'FuckNahimic' {
            Install-FuckNahimic
        }
        'WindowsUpdatePause' {
            Suspend-WindowsUpdateForCleanup
        }
        'OemUpdateRecheck' {
            Assert-GenericAudio $data.Instance
            if ($script:WindowsUpdateSuspended) {
                Write-Host 'Windows Update is paused. The driver search is deferred until scheduled recovery if configured.'
                return
            }
            Update-AudioUpdateScope
            $newOperations = @(Get-WindowsUpdateOperations -DriverOnly)
            if (-not $newOperations.Count) {
                Write-Host 'Windows Update: no matching OEM driver updates after audio migration.'
            }
            foreach ($item in $newOperations) { Invoke-RecordedOperation $item }
        }
        'EndpointNames' {
            if ($script:OemAudioHideFailed -and $script:Plan.Kind -contains 'AudioMigration') {
                throw 'An offered OEM audio update could not be hidden.'
            }
            $endpoints = @(Get-CardAudioEndpoints $data.Instance -IncludeNotPresent)
            if (-not $endpoints.Count) {
                throw 'No named endpoints for the primary audio device are visible. Run locally with the audio device available.'
            }
            Install-AudioEndpointRestore $data.Instance $endpoints
        }
        'AudioMigration' {
            if ($script:OemAudioHideFailed) {
                throw 'An offered OEM audio update could not be hidden. Audio migration was not started.'
            }
            Invoke-AudioMigration $data
        }
        'Win32' {
            if (-not (Test-Path -LiteralPath $data.Key)) { return }
            $parameters = @{ FilePath = $data.Command; Wait = $true; PassThru = $true; NoNewWindow = $true }
            if ($data.Arguments) { $parameters.ArgumentList = $data.Arguments }
            $process = Start-Process @parameters
            if ($process.ExitCode -in 1641,3010) {
                $script:RebootRequired = $true
            } elseif ($process.ExitCode -ne 0) {
                throw "Uninstaller exit code: $($process.ExitCode)."
            } elseif (Test-Path -LiteralPath $data.Key) {
                throw 'The uninstall entry is still registered.'
            }
        }
        'Appx' {
            Remove-InstalledAppx $data.FullName
        }
        'ProvisionedAppx' {
            Get-ProvisionedAppx -RemovePackage $data.Package
        }
        'Service' {
            $service = Get-Service | Where-Object Name -EQ $data.Name
            if (-not $service) { return }
            try {
                Set-Service -Name $data.Name -StartupType Disabled
                if ($service.Status -ne 'Stopped') {
                    Stop-Service -Name $data.Name
                    $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
                }
            } finally {
                $service.Dispose()
            }
            Invoke-Native $ServiceExe @('delete',$data.Name) | Out-Null
        }
        'Process' {
            $process = Get-Process -Id $data.Id -ErrorAction SilentlyContinue
            if ($process -and $process.Name -eq $data.Name -and $process.StartTime -eq $data.Started) {
                Stop-Process -InputObject $process -Force
            }
        }
        'PnpDevice' {
            $device = Get-PnpDevice | Where-Object InstanceId -EQ $data.Instance
            if (-not $device) { return }
            if (-not (Test-NahimicSoftwareDevice $device -ApprovedInstance)) {
                throw 'The device no longer matches the approved software target.'
            }
            Invoke-Native $PnpUtil @('/remove-device',$data.Instance) -AllowRebootRequired |
                ForEach-Object { Write-Host $_ }
        }
        'Driver' {
            $item = Get-PlannedPackage $data.Package
            if (-not $item) { return }
            $matchesPlan = if ($data['ScopedRealtek']) {
                Test-ScopedRealtekDriver $item $data.Allowed
            } else {
                Test-NahimicDriver $item $data.Allowed
            }
            if (-not $matchesPlan) {
                throw 'The driver is no longer safe to remove under the approved plan.'
            }
            Remove-PlannedPackage $item -Uninstall:($item.Devices.Count -gt 0)
        }
        'Registry' {
            if (-not (Test-Path -LiteralPath $data.Path)) { return }
            try {
                Remove-Item -LiteralPath $data.Path -Recurse -Force
            } catch {
                if ($data.Path -ne 'HKLM:\SOFTWARE\A-Volute') { throw }
                # Retry the exact vendor key without changing its access rules.
                Invoke-Native $RegistryExe @('delete','HKLM\SOFTWARE\A-Volute','/f') | Out-Null
                if (Test-Path -LiteralPath $data.Path) { throw 'The A-Volute registry key is still present.' }
            }
        }
        'ApoKey' {
            if (Test-Path -LiteralPath $data.Path) { Remove-Item -LiteralPath $data.Path -Recurse -Force }
        }
        'ApoValue' {
            if ((Test-Path -LiteralPath $data.Path) -and
                ($data.Name -in (Get-Item -LiteralPath $data.Path).GetValueNames())) {
                Remove-ItemProperty -LiteralPath $data.Path -Name $data.Name -Force
            }
        }
        'File' {
            if (-not (Test-Path -LiteralPath $data.Path)) { return }
            $item = Get-Item -LiteralPath $data.Path -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'A reparse point is in the removal plan.'
            }
            Remove-Item -LiteralPath $data.Path -Recurse -Force
        }
        'Task' {
            if (Get-ScheduledTask | Where-Object { $_.TaskPath -eq $data.Path -and $_.TaskName -eq $data.Name }) {
                Unregister-ScheduledTask -TaskName $data.Name -TaskPath $data.Path -Confirm:$false
            }
        }
        default { throw "Unsupported operation: $($Operation.Kind)." }
    }
}

function Invoke-RecordedOperation {
    param($Operation)
    try {
        Invoke-Operation $Operation
        $script:Completed++
        Write-Host "  Done: [$($Operation.Kind)] $($Operation.Detail)"
    } catch {
        $script:Failed++
        Write-Warning "[$($Operation.Kind)] $($Operation.Detail): $_"
        if ($Operation.Kind -eq 'WindowsUpdate' -and $Operation.Data.TargetsOemAudio) {
            $script:OemAudioHideFailed = $true
        }
        if ($Operation.Kind -in 'AudioMigration','EndpointNames','WindowsUpdatePause') {
            throw "[$($Operation.Kind)] failed. Remaining removal steps were stopped."
        }
    }
}

function Invoke-ApoPlan {
    param([object[]]$Operations)
    if (-not $Operations.Count) { return }

    New-Item -ItemType Directory -Path $script:BackupDirectory -Force | Out-Null
    $backedUpOperations = [System.Collections.Generic.List[object]]::new()
    $index = 0
    foreach ($group in $Operations | Group-Object -Property { $_.Data.Path }) {
        $path = $group.Group[0].Data.Path
        try {
            $exists = Read-RegistryKey $path ([System.Security.AccessControl.RegistryRights]::QueryValues) {
                param($key)
                $true
            } -StopOnError
            if (-not $exists) {
                $script:Completed += $group.Count
                Write-Host "  Already absent: $path"
                continue
            }

            $index++
            $nativePath = $path -replace '^HKLM:', 'HKLM'
            $destination = Join-Path $script:BackupDirectory "AudioRegistry-$index.reg"
            Invoke-Native $RegistryExe @('export',$nativePath,$destination,'/y') | Out-Null
            if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
                throw 'Registry export did not produce a backup file.'
            }
            foreach ($operation in $group.Group) { $backedUpOperations.Add($operation) }
        } catch {
            $script:Failed += $group.Count
            Write-Warning "Skipped APO entries at [$path]. Backup failed: $($_.Exception.GetBaseException().Message)"
        }
    }
    if (-not $backedUpOperations.Count) { return }

    $stopped = [System.Collections.Generic.List[string]]::new()
    try {
        foreach ($name in @('Audiosrv','AudioEndpointBuilder')) {
            $service = Get-Service -Name $name
            if ($service.Status -eq 'Running') {
                $stopped.Add($name)
                Stop-Service -Name $name
                $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
            }
        }
        foreach ($operation in $backedUpOperations) { Invoke-RecordedOperation $operation }
    } finally {
        for ($i = $stopped.Count - 1; $i -ge 0; $i--) {
            try {
                Start-Service -Name $stopped[$i]
                (Get-Service -Name $stopped[$i]).WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
            } catch {
                $script:Failed++
                Write-Warning "Could not restore $($stopped[$i]): $_"
            }
        }
    }
}

function Invoke-Removal {
    Write-Host "FuckNahimic $ScriptVersion on $env:COMPUTERNAME"
    if (($InstallGuard -and $RemoveGuard) -or ($SkipGuard -and ($InstallGuard -or $RemoveGuard))) {
        throw "Choose one guard switch at a time."
    }
    if ($InstallGuard -or $RemoveGuard) {
        if ($CheckOnly) {
            $needed = if ($InstallGuard) { -not (Test-AudioGuardReady) } else { [bool](Get-OwnedAudioGuardService (Get-AudioGuardPaths)) }
            if ($needed) { Write-Host "FuckNahimic change pending."; return 0 }
            return 1
        }
        if ($InstallGuard) { Install-FuckNahimic } else { Uninstall-FuckNahimic }
        return 0
    }
    New-RemovalPlan
    $operationOrder = @(
        'WindowsUpdate','EndpointNames','WindowsUpdatePause','AudioMigration','Task','Service','Process',
        'Win32','ProvisionedAppx','Appx','Driver','PnpDevice','Registry',
        'ApoKey','ApoValue','File','OemUpdateRecheck','FuckNahimic'
    )
    $orderedPlan = @(foreach ($kind in $operationOrder) { $script:Plan | Where-Object Kind -EQ $kind })
    foreach ($operation in $orderedPlan) {
        Write-Host "  [$($operation.Kind)] $($operation.Detail)"
    }
    Write-Host "Planned: $($script:Plan.Count). Scan issues: $($script:ScanIssues.Count)."

    if ($CheckOnly) {
        if ($script:ScanIssues.Count) { return 2 }
        if ($script:Plan.Count) { return 0 }
        return 1
    }
    if (-not $script:Plan.Count) {
        if ($script:ScanIssues.Count) { return 2 }
        return 0
    }
    if (-not $AutoApprove -and (Read-Host 'Apply the listed operations? (y/N)') -notmatch '^[yY]$') {
        return 0
    }

    $script:Completed = 0
    $script:Failed = 0
    $script:RebootRequired = $false
    $script:OemAudioHideFailed = $false
    $script:WindowsUpdateSuspended = $false
    foreach ($operation in $orderedPlan | Where-Object Kind -NotIn 'ApoKey','ApoValue','File','OemUpdateRecheck','FuckNahimic') {
        if ($script:WindowsUpdateSuspended -and $operation.Kind -in 'AudioMigration','Driver','Appx','ProvisionedAppx') {
            if ((Get-WindowsUpdateStartMode) -ne 'disabled' -or (Get-Service -Name wuauserv).Status -ne 'Stopped') {
                throw 'Windows Update resumed separately. Remaining driver and app cleanup was stopped.'
            }
        }
        Invoke-RecordedOperation $operation
    }
    try {
        Invoke-ApoPlan @($orderedPlan | Where-Object Kind -In 'ApoKey','ApoValue')
    } catch {
        $script:Failed++
        Write-Warning "APO cleanup: $_"
    }
    foreach ($operation in $orderedPlan | Where-Object Kind -EQ 'File') {
        Invoke-RecordedOperation $operation
    }

    foreach ($operation in $orderedPlan | Where-Object Kind -In 'OemUpdateRecheck','FuckNahimic') {
        Invoke-RecordedOperation $operation
    }
    Write-Host "Completed: $script:Completed. Failed: $script:Failed. Scan issues: $($script:ScanIssues.Count)."
    if ($script:RebootRequired) {
        Write-Host 'Windows reported that a restart is required. After restarting, check the plan again and verify audio playback and recording.'
    }
    if ($script:Failed -or $script:ScanIssues.Count) { return 2 }
    if (-not $SkipReboot -and -not $AutoApprove -and (Read-Host 'Restart now? (y/N)') -match '^[yY]$') {
        Restart-Computer
    }
    return 0
}

$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
$runDirectory = Join-Path $env:TEMP 'eric\FuckNahimic'
if ($LogFile -eq 'auto') { $LogFile = Join-Path $runDirectory "FuckNahimic-$stamp-$PID.log" }
$script:BackupDirectory = Join-Path $runDirectory "Backup-$stamp-$PID"
$transcriptStarted = $false
$result = 2
try {
    try {
        New-Item -Path (Split-Path -LiteralPath $LogFile) -ItemType Directory -Force | Out-Null
        Start-Transcript -LiteralPath $LogFile -Append | Out-Null
        $transcriptStarted = $true
        Write-Host "Log: $LogFile"
    } catch {
        Write-Warning "Could not start transcript: $_"
    }
    $result = Invoke-Removal
} catch {
    Write-Error $_ -ErrorAction Continue
    if ((Get-Variable RebootRequired -Scope Script -ErrorAction SilentlyContinue) -and $script:RebootRequired) {
        Write-Warning 'Windows reported a restart is required before continuing.'
    }
} finally {
    if ($transcriptStarted) {
        try { Stop-Transcript | Out-Null }
        catch { Write-Warning "Could not stop transcript: $_" }
    }
}
Write-Host "Finished with exit code $result. Review the transcript if one was created."
Wait-ForUserToReview
exit $result
