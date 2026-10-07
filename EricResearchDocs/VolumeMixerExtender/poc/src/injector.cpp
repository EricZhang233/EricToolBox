// injector.cpp -- minimal DLL injector (CreateRemoteThread + LoadLibraryW), optionally followed by a
// call to one of the injected DLL's exports.
//
// Usage:
//   injector.exe --dll <abs path to dll> [--process ShellHost.exe] [--pid N]
//                [--call <exportName>] [--arg <string>]
//
// --call exists because the payloads have two entry points: DllMain starts the work on its own
// thread, and VmExtLauncherRun() does the same work synchronously and returns its HRESULT as the
// thread exit code. Calling the export is how a run gets a real pass/fail answer -- and how it can
// be retried inside a process that already has the DLL loaded, since a second LoadLibraryW would
// just bump a reference count and never run DllMain again.
//
// Why this works here: ShellHost.exe runs at the same integrity level as us (Medium),
// is not a protected process, and OpenProcess(PROCESS_ALL_ACCESS) is granted.
// (measured -- see ../logs/injection-feasibility.txt)

#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <string>
#include <vector>

static DWORD FindPidByName(const wchar_t* name)
{
    DWORD pid = 0;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return 0;

    PROCESSENTRY32W pe = {};
    pe.dwSize = sizeof(pe);
    if (Process32FirstW(snap, &pe)) {
        do {
            if (_wcsicmp(pe.szExeFile, name) == 0) { pid = pe.th32ProcessID; break; }
        } while (Process32NextW(snap, &pe));
    }
    CloseHandle(snap);
    return pid;
}

// Writes a NUL-terminated buffer into the target and returns its address there.
static void* WriteRemoteString(HANDLE process, const wchar_t* text)
{
    const SIZE_T bytes = (wcslen(text) + 1) * sizeof(wchar_t);
    void* remote = VirtualAllocEx(process, nullptr, bytes, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!remote) return nullptr;

    SIZE_T written = 0;
    if (!WriteProcessMemory(process, remote, text, bytes, &written)) {
        VirtualFreeEx(process, remote, 0, MEM_RELEASE);
        return nullptr;
    }
    return remote;
}

// Runs a remote thread and returns its exit code (0 when the thread could not be created).
static DWORD RunRemoteThread(HANDLE process, void* start, void* parameter)
{
    HANDLE thread = CreateRemoteThread(process, nullptr, 0, (LPTHREAD_START_ROUTINE)start, parameter, 0, nullptr);
    if (!thread) return 0;

    const DWORD wait = WaitForSingleObject(thread, 30000);
    DWORD code = 0;
    if (wait == WAIT_OBJECT_0) {
        GetExitCodeThread(thread, &code);
    } else {
        wprintf(L"[!] remote thread did not finish (wait=0x%lX)\n", wait);
    }
    CloseHandle(thread);
    return code;
}

// Maps an RVA to a pointer inside the mapped file image. The export directory is addressed by RVA,
// and in a PE file an RVA is only equal to a file offset by coincidence.
static const BYTE* RvaToPointer(const std::vector<BYTE>& image, const IMAGE_NT_HEADERS64* nt, DWORD rva)
{
    const auto* section = IMAGE_FIRST_SECTION(nt);
    for (WORD i = 0; i < nt->FileHeader.NumberOfSections; ++i, ++section) {
        const DWORD size = section->Misc.VirtualSize > section->SizeOfRawData
            ? section->Misc.VirtualSize
            : section->SizeOfRawData;
        if (rva >= section->VirtualAddress && rva < section->VirtualAddress + size) {
            const DWORD offset = section->PointerToRawData + (rva - section->VirtualAddress);
            return offset < image.size() ? image.data() + offset : nullptr;
        }
    }
    return nullptr;
}

// Reads the export RVA straight out of the PE headers on disk.
//
// The tempting shortcut is a local LoadLibraryW + GetProcAddress, but that runs the payload's DllMain
// *in this process* -- and the payloads self-inject from DllMain, so the whole sequence (and its log
// files) would happen here instead of in the target. Parsing the file has no side effects at all.
static ULONG_PTR ExportRvaFromFile(const wchar_t* path, const char* exportName)
{
    HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                              FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        wprintf(L"[!] cannot open %s, err=%lu\n", path, GetLastError());
        return 0;
    }

    LARGE_INTEGER size{};
    if (!GetFileSizeEx(file, &size) || size.QuadPart < (LONGLONG)sizeof(IMAGE_DOS_HEADER)) {
        CloseHandle(file);
        return 0;
    }

    std::vector<BYTE> image((size_t)size.QuadPart);
    DWORD read = 0;
    const BOOL ok = ReadFile(file, image.data(), (DWORD)image.size(), &read, nullptr);
    CloseHandle(file);
    if (!ok || read != image.size()) {
        wprintf(L"[!] short read on %s (%lu of %llu)\n", path, read, (unsigned long long)image.size());
        return 0;
    }

    const auto* dos = (const IMAGE_DOS_HEADER*)image.data();
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) return 0;

    const auto* nt = (const IMAGE_NT_HEADERS64*)(image.data() + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) return 0;

    const auto& directory = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT];
    if (directory.VirtualAddress == 0 || directory.Size == 0) return 0;

    const auto* exports = (const IMAGE_EXPORT_DIRECTORY*)RvaToPointer(image, nt, directory.VirtualAddress);
    if (!exports) return 0;

    const auto* names = (const DWORD*)RvaToPointer(image, nt, exports->AddressOfNames);
    const auto* ordinals = (const WORD*)RvaToPointer(image, nt, exports->AddressOfNameOrdinals);
    const auto* functions = (const DWORD*)RvaToPointer(image, nt, exports->AddressOfFunctions);
    if (!names || !ordinals || !functions) return 0;

    for (DWORD i = 0; i < exports->NumberOfNames; ++i) {
        const char* name = (const char*)RvaToPointer(image, nt, names[i]);
        if (name && strcmp(name, exportName) == 0) {
            return functions[ordinals[i]];
        }
    }
    return 0;
}

int wmain(int argc, wchar_t** argv)
{
    std::wstring dllPath;
    std::wstring procName = L"ShellHost.exe";
    std::wstring exportName;
    std::wstring argument;
    bool hasArgument = false;
    DWORD pid = 0;

    for (int i = 1; i < argc; ++i) {
        if (!_wcsicmp(argv[i], L"--dll") && i + 1 < argc)          dllPath  = argv[++i];
        else if (!_wcsicmp(argv[i], L"--process") && i + 1 < argc) procName = argv[++i];
        else if (!_wcsicmp(argv[i], L"--pid") && i + 1 < argc)     pid      = wcstoul(argv[++i], nullptr, 10);
        else if (!_wcsicmp(argv[i], L"--call") && i + 1 < argc)    exportName = argv[++i];
        else if (!_wcsicmp(argv[i], L"--arg") && i + 1 < argc)   { argument = argv[++i]; hasArgument = true; }
    }

    if (dllPath.empty()) {
        wprintf(L"usage: injector.exe --dll <path> [--process <name>] [--pid <n>]"
                L" [--call <export>] [--arg <string>]\n");
        return 2;
    }

    wchar_t full[MAX_PATH] = {};
    if (!GetFullPathNameW(dllPath.c_str(), MAX_PATH, full, nullptr)) {
        wprintf(L"[!] bad dll path\n");
        return 2;
    }
    if (GetFileAttributesW(full) == INVALID_FILE_ATTRIBUTES) {
        wprintf(L"[!] dll not found: %s\n", full);
        return 2;
    }

    // The export has to be resolved in the target, and GetProcAddress only works on local handles.
    // Loading the same image locally gives us the RVA, which is all that differs between the two
    // mappings of the same file.
    ULONG_PTR exportRva = 0;
    if (!exportName.empty()) {
        std::string exportNameNarrow;
        exportNameNarrow.reserve(exportName.size());
        for (const auto character : exportName) {
            exportNameNarrow.push_back(static_cast<char>(character));   // export names are ASCII
        }

        exportRva = ExportRvaFromFile(full, exportNameNarrow.c_str());
        if (exportRva == 0) {
            wprintf(L"[!] %s does not export %s\n", full, exportName.c_str());
            return 2;
        }
        wprintf(L"[*] %s rva = 0x%llX\n", exportName.c_str(), (unsigned long long)exportRva);
    }

    if (!pid) pid = FindPidByName(procName.c_str());
    if (!pid) {
        wprintf(L"[!] process not found: %s\n", procName.c_str());
        return 3;
    }
    wprintf(L"[*] target : %s (pid %lu)\n", procName.c_str(), pid);
    wprintf(L"[*] dll    : %s\n", full);

    HANDLE hp = OpenProcess(PROCESS_CREATE_THREAD | PROCESS_VM_OPERATION | PROCESS_VM_WRITE |
                            PROCESS_VM_READ | PROCESS_QUERY_INFORMATION, FALSE, pid);
    if (!hp) {
        wprintf(L"[!] OpenProcess failed, err=%lu\n", GetLastError());
        return 4;
    }

    void* remote = WriteRemoteString(hp, full);
    if (!remote) {
        wprintf(L"[!] VirtualAllocEx/WriteProcessMemory failed, err=%lu\n", GetLastError());
        CloseHandle(hp);
        return 5;
    }

    FARPROC loadLib = GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "LoadLibraryW");
    if (!loadLib) {
        wprintf(L"[!] LoadLibraryW not found\n");
        CloseHandle(hp);
        return 7;
    }

    const ULONG_PTR remoteBase = RunRemoteThread(hp, (void*)loadLib, remote);
    if (!remoteBase) {
        wprintf(L"[!] remote LoadLibraryW FAILED (returned NULL)\n");
        VirtualFreeEx(hp, remote, 0, MEM_RELEASE);
        CloseHandle(hp);
        return 10;
    }
    wprintf(L"[+] injected OK, remote HMODULE = 0x%p\n", (void*)remoteBase);

    VirtualFreeEx(hp, remote, 0, MEM_RELEASE);

    int result = 0;
    if (!exportName.empty()) {
        void* remoteArg = hasArgument ? WriteRemoteString(hp, argument.c_str()) : nullptr;
        if (hasArgument && !remoteArg) {
            wprintf(L"[!] could not write the argument into the target, err=%lu\n", GetLastError());
            CloseHandle(hp);
            return 6;
        }

        const auto target = (void*)(remoteBase + exportRva);
        wprintf(L"[*] calling %s at 0x%p (arg=%s)\n", exportName.c_str(), target,
                hasArgument ? argument.c_str() : L"<none>");
        const DWORD code = RunRemoteThread(hp, target, remoteArg);
        wprintf(L"[%s] %s -> 0x%08lX  (hr=%s)\n",
                SUCCEEDED((HRESULT)code) ? L"+" : L"!", exportName.c_str(), code,
                SUCCEEDED((HRESULT)code) ? L"ok" : L"failed");
        result = SUCCEEDED((HRESULT)code) ? 0 : 11;

        if (remoteArg) VirtualFreeEx(hp, remoteArg, 0, MEM_RELEASE);
    }

    CloseHandle(hp);
    return result;
}

