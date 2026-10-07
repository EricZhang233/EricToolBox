# pexports.ps1 -- list PE export names from a DLL (read-only, no LoadLibrary).
# Target: pwsh 7 (uses only BCL). Usage: pwsh -File pexports.ps1 <dll> [regex-filter]

param(
    [Parameter(Mandatory = $true)][string]$Path,
    [string]$Filter = '.'
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

public static class PeExp
{
    public static List<string> Read(string path)
    {
        byte[] b = File.ReadAllBytes(path);
        var list = new List<string>();
        int peOff = BitConverter.ToInt32(b, 0x3C);
        if (BitConverter.ToUInt32(b, peOff) != 0x00004550) throw new Exception("not a PE file");
        int numSec = BitConverter.ToUInt16(b, peOff + 6);
        int optSize = BitConverter.ToUInt16(b, peOff + 20);
        int optOff = peOff + 24;
        int magic = BitConverter.ToUInt16(b, optOff);
        int ddOff = optOff + (magic == 0x20B ? 112 : 96);
        int expRva = BitConverter.ToInt32(b, ddOff);
        if (expRva == 0) return list;
        int secOff = optOff + optSize;

        Func<int, int> rvaToOff = delegate (int rva)
        {
            for (int i = 0; i < numSec; i++)
            {
                int s = secOff + i * 40;
                uint vsize = BitConverter.ToUInt32(b, s + 8);
                uint vaddr = BitConverter.ToUInt32(b, s + 12);
                uint rsize = BitConverter.ToUInt32(b, s + 16);
                uint raddr = BitConverter.ToUInt32(b, s + 20);
                uint span = Math.Max(vsize, rsize);
                if ((uint)rva >= vaddr && (uint)rva < vaddr + span)
                    return (int)(raddr + ((uint)rva - vaddr));
            }
            return -1;
        };

        int e = rvaToOff(expRva);
        if (e < 0) return list;
        int nNames = BitConverter.ToInt32(b, e + 24);
        int namesRva = BitConverter.ToInt32(b, e + 32);
        int namesOff = rvaToOff(namesRva);
        if (namesOff < 0) return list;
        for (int i = 0; i < nNames; i++)
        {
            int nr = BitConverter.ToInt32(b, namesOff + i * 4);
            int no = rvaToOff(nr);
            if (no < 0) continue;
            int len = 0;
            while (b[no + len] != 0) len++;
            list.Add(Encoding.ASCII.GetString(b, no, len));
        }
        return list;
    }
}
'@

$names = [PeExp]::Read($Path)
Write-Output ("file    : " + $Path)
$vi = (Get-Item $Path).VersionInfo
Write-Output ("version : " + $vi.FileVersion + "  (" + $vi.ProductVersion + ")")
Write-Output ("exports : " + $names.Count)
Write-Output ("filter  : " + $Filter)
Write-Output ""
$names | Where-Object { $_ -match $Filter } | Sort-Object | ForEach-Object { Write-Output ("  " + $_) }
