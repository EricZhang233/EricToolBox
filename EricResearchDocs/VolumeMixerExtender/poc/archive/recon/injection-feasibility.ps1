# injection-feasibility.ps1 -- can we actually inject into ShellHost.exe from this context?
# Read-only: only queries tokens/access rights, never writes to the target.
# Target: pwsh 7. ASCII-only.

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class Feas
{
    [DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool CloseHandle(IntPtr h);
    [DllImport("advapi32.dll", SetLastError = true)] public static extern bool OpenProcessToken(IntPtr proc, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)] public static extern bool GetTokenInformation(IntPtr token, int cls, IntPtr buf, int len, out int ret);
    [DllImport("advapi32.dll")] public static extern IntPtr GetSidSubAuthority(IntPtr sid, uint index);
    [DllImport("advapi32.dll")] public static extern IntPtr GetSidSubAuthorityCount(IntPtr sid);
    [DllImport("ntdll.dll")] public static extern int NtQueryInformationProcess(IntPtr proc, int cls, IntPtr buf, int len, out int ret);
    [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();

    public static string IntegrityLevel(IntPtr proc)
    {
        IntPtr token;
        if (!OpenProcessToken(proc, 0x0008 /*TOKEN_QUERY*/, out token)) return "OpenProcessToken failed: " + Marshal.GetLastWin32Error();
        try
        {
            int len;
            GetTokenInformation(token, 25 /*TokenIntegrityLevel*/, IntPtr.Zero, 0, out len);
            IntPtr buf = Marshal.AllocHGlobal(len);
            try
            {
                int ret;
                if (!GetTokenInformation(token, 25, buf, len, out ret)) return "GetTokenInformation failed: " + Marshal.GetLastWin32Error();
                IntPtr sid = Marshal.ReadIntPtr(buf);            // TOKEN_MANDATORY_LABEL.Label.Sid
                IntPtr cnt = GetSidSubAuthorityCount(sid);
                byte n = Marshal.ReadByte(cnt);
                IntPtr ridPtr = GetSidSubAuthority(sid, (uint)(n - 1));
                uint rid = (uint)Marshal.ReadInt32(ridPtr);
                string name;
                switch (rid)
                {
                    case 0x0000: name = "Untrusted"; break;
                    case 0x1000: name = "Low"; break;
                    case 0x2000: name = "Medium"; break;
                    case 0x2100: name = "MediumPlus"; break;
                    case 0x3000: name = "High"; break;
                    case 0x4000: name = "System"; break;
                    case 0x5000: name = "Protected"; break;
                    default: name = "?"; break;
                }
                return name + " (RID 0x" + rid.ToString("X") + ")";
            }
            finally { Marshal.FreeHGlobal(buf); }
        }
        finally { CloseHandle(token); }
    }

    // PS_PROTECTION: 1 byte Level/Type + 1 byte Audit + 1 byte Signer
    public static string Protection(IntPtr proc)
    {
        IntPtr buf = Marshal.AllocHGlobal(16);
        try
        {
            for (int i = 0; i < 16; i++) Marshal.WriteByte(buf, i, 0);
            int ret;
            int st = NtQueryInformationProcess(proc, 61 /*ProcessProtectionInformation*/, buf, 16, out ret);
            if (st != 0) return "NtQueryInformationProcess failed: 0x" + st.ToString("X8");
            byte type = Marshal.ReadByte(buf, 0);
            byte audit = Marshal.ReadByte(buf, 1);
            byte signer = Marshal.ReadByte(buf, 2);
            string t;
            switch (type)
            {
                case 0: t = "None"; break;
                case 1: t = "PPL (light)"; break;
                case 2: t = "PP (full)"; break;
                default: t = "type=" + type; break;
            }
            return t + " audit=" + audit + " signer=" + signer;
        }
        finally { Marshal.FreeHGlobal(buf); }
    }
}
'@

$target = Get-Process ShellHost -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $target) { Write-Output "ShellHost not running"; exit 1 }

Write-Output "=== 1. integrity level ==="
Write-Output ("  this process (pid " + $PID + ") : " + [Feas]::IntegrityLevel([Feas]::GetCurrentProcess()))
Write-Output ("  ShellHost  (pid " + $target.Id + ") : " + [Feas]::IntegrityLevel($target.Handle))
Write-Output ("  explorer   (pid " + ((Get-Process explorer | Select-Object -First 1).Id) + ") : " + [Feas]::IntegrityLevel((Get-Process explorer | Select-Object -First 1).Handle))

Write-Output ""
Write-Output "=== 2. protection (PPL?) ==="
Write-Output ("  ShellHost : " + [Feas]::Protection($target.Handle))
Write-Output ("  explorer  : " + [Feas]::Protection((Get-Process explorer | Select-Object -First 1).Handle))

Write-Output ""
Write-Output "=== 3. OpenProcess access test (what an injector needs) ==="
$PROCESS_CREATE_THREAD        = 0x0002
$PROCESS_VM_OPERATION         = 0x0008
$PROCESS_VM_WRITE             = 0x0020
$PROCESS_VM_READ              = 0x0010
$PROCESS_QUERY_INFORMATION    = 0x0400
$PROCESS_ALL_ACCESS           = 0x001FFFFF
$need = $PROCESS_CREATE_THREAD -bor $PROCESS_VM_OPERATION -bor $PROCESS_VM_WRITE -bor $PROCESS_VM_READ -bor $PROCESS_QUERY_INFORMATION
foreach ($mask in @(@('injection rights', $need), @('ALL_ACCESS', $PROCESS_ALL_ACCESS))) {
    $h = [Feas]::OpenProcess([uint32]$mask[1], $false, [uint32]$target.Id)
    if ($h -eq [IntPtr]::Zero) {
        Write-Output ("  " + $mask[0] + " (0x" + ([uint32]$mask[1]).ToString("X6") + ") : DENIED, GetLastError=" + [Runtime.InteropServices.Marshal]::GetLastWin32Error())
    } else {
        Write-Output ("  " + $mask[0] + " (0x" + ([uint32]$mask[1]).ToString("X6") + ") : GRANTED (handle=0x" + $h.ToInt64().ToString("X") + ")")
        [void][Feas]::CloseHandle($h)
    }
}

Write-Output ""
Write-Output "=== 4. is XamlDiagnostics.dll available from any Windows SDK on this machine? ==="
$kits = @("$env:ProgramFiles(x86)\Windows Kits\10\bin", "$env:ProgramFiles\Windows Kits\10\bin")
$found = @()
foreach ($k in $kits) {
    if (Test-Path $k) {
        $found += Get-ChildItem -Path $k -Recurse -Filter 'XamlDiagnostics.dll' -ErrorAction SilentlyContinue
    }
}
if ($found.Count -eq 0) { Write-Output "  NOT FOUND (no Windows SDK with the XAML diagnostics tap DLL)" }
else { $found | ForEach-Object { Write-Output ("  " + $_.FullName + "  (" + $_.Length + " bytes)") } }

Write-Output ""
Write-Output "=== 5. ControlCenter.dll (the Quick Settings implementation) exports ==="
Write-Output ""
& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'pexports.ps1') "C:\Windows\System32\ControlCenter.dll" "."
