// vcxlaunch.dll -- call InitializeXamlDiagnosticsEx from *inside* the target process.
//
// InitializeXamlDiagnosticsEx is exported by the target's own Windows.UI.Xaml.dll, so it has to
// be called in-process. That is the only job of this DLL: it does NOT touch the shell's code.
//
//   InitializeXamlDiagnosticsEx(L"VisualDiagConnection<N>", GetCurrentProcessId(),
//                               <sdk>\xamldiagnostics.dll, <us>\vcxtap.dll,
//                               CLSID_VcxTap, nullptr)
//
// The XAML core then loads vcxtap.dll (the TAP) and hands it an IXamlDiagnostics*.
//
// vcxlaunch.ini (next to this DLL):
//   [vcxlaunch]
//   xamldiag=C:\Program Files (x86)\Windows Kits\10\bin\x64\XamlDiagnostics\xamldiagnostics.dll
//   tap=vcxtap.dll          ; relative to this DLL, or an absolute path

#include <windows.h>
#include <stdio.h>
#include <stdarg.h>
#include <string>

// {A7C5F1E2-9B34-4D6E-8F21-5C0D3E7A9B44}  -- must match vcxtap.cpp
static const CLSID CLSID_VcxTap =
    { 0xA7C5F1E2, 0x9B34, 0x4D6E, { 0x8F, 0x21, 0x5C, 0x0D, 0x3E, 0x7A, 0x9B, 0x44 } };

typedef HRESULT(__stdcall* InitXamlDiagnosticsExFn)(
    LPCWSTR endPointName,
    DWORD pid,
    LPCWSTR wszDllXamlDiagnostics,
    LPCWSTR wszTAPDllName,
    CLSID tapClsid,
    LPCWSTR wszInitializationData);

// ---------------------------------------------------------------- logging
static HANDLE           g_log = INVALID_HANDLE_VALUE;
static CRITICAL_SECTION g_logLock;
static HMODULE          g_self = nullptr;

static std::wstring DllDir()
{
    wchar_t path[MAX_PATH] = {};
    GetModuleFileNameW(g_self, path, MAX_PATH);
    std::wstring p(path);
    size_t slash = p.find_last_of(L'\\');
    return (slash == std::wstring::npos) ? L"." : p.substr(0, slash);
}

static std::wstring IniPath() { return DllDir() + L"\\vcxlaunch.ini"; }

static void LogF(const char* fmt, ...)
{
    if (g_log == INVALID_HANDLE_VALUE) return;
    char buf[1400];
    SYSTEMTIME st;
    GetLocalTime(&st);
    int n = _snprintf_s(buf, sizeof(buf), _TRUNCATE, "[%02d:%02d:%02d.%03d tid=%lu] ",
                        st.wHour, st.wMinute, st.wSecond, st.wMilliseconds, GetCurrentThreadId());
    if (n < 0) n = 0;
    va_list ap;
    va_start(ap, fmt);
    int m = _vsnprintf_s(buf + n, sizeof(buf) - (size_t)n, _TRUNCATE, fmt, ap);
    va_end(ap);
    if (m < 0) m = (int)strlen(buf + n);
    size_t len = (size_t)n + (size_t)m;
    if (len + 2 < sizeof(buf)) { buf[len++] = '\r'; buf[len++] = '\n'; }
    EnterCriticalSection(&g_logLock);
    DWORD wr = 0;
    WriteFile(g_log, buf, (DWORD)len, &wr, nullptr);
    LeaveCriticalSection(&g_logLock);
}

static std::wstring ReadIniString(const wchar_t* key, const wchar_t* def)
{
    wchar_t buf[MAX_PATH] = {};
    GetPrivateProfileStringW(L"vcxlaunch", key, def, buf, MAX_PATH, IniPath().c_str());
    std::wstring s(buf);
    if (s.find(L'\\') == std::wstring::npos && s.find(L':') == std::wstring::npos)
        s = DllDir() + L"\\" + s;          // relative -> next to this DLL
    return s;
}

static bool FileExists(const std::wstring& p)
{
    return !p.empty() && GetFileAttributesW(p.c_str()) != INVALID_FILE_ATTRIBUTES;
}

// ---------------------------------------------------------------- 配置下发（T1 验证后的定稿）
// T1 的非 ASCII 保真自检串。默认**不启用**（ini 里 initdata_cjk_test=1 才加），
// 这样正式路径就是"配置是什么就发什么"，自检随时可复现。
// 用 \u 转义写以保持源码纯 ASCII —— 免得把"源码编码"这个无关变量混进结果。
static const wchar_t kCjkSelfTest[] = L";cjk=\u97F3\u91CF\u5408\u6210\u5668\u6D4B\u8BD5";

// 读一个可能很长的 ini 值。★ 不能用默认的 MAX_PATH(260) 缓冲，initData 会超过它而被静默截断。
static std::wstring ReadIniRaw(const wchar_t* key, const wchar_t* def = L"")
{
    const DWORD kChars = 8192;
    std::wstring buf(kChars, L'\0');
    DWORD n = GetPrivateProfileStringW(L"vcxlaunch", key, def, &buf[0], kChars, IniPath().c_str());
    buf.resize(n);
    return buf;
}

// FNV-1a 64，输入按 UTF-16 码元逐位异或。种子用标准 64 位偏移基
// 14695981039346656037（0xCBF29CE484222325）—— 与 TAP 侧一致，可被任何标准 FNV 实现复核。
static unsigned long long Fnv1a64(const std::wstring& s)
{
    unsigned long long h = 14695981039346656037ULL;
    for (size_t i = 0; i < s.size(); ++i) {
        h ^= (unsigned long long)(unsigned short)s[i];
        h *= 1099511628211ULL;
    }
    return h;
}

// 把宽串转成**纯 ASCII** 的可读形式（非 ASCII 打成 \uXXXX）。
// ★ 为什么不直接 %ls 打出原文：日志文件是窄字节流，MSVC 的 %ls 会按当前 ANSI 代码页转换，
//   中文 Windows 上会写成 GBK 字节，用 UTF-8 读就是乱码 —— 那会让我误判"回读失败"。
static std::string EscapeW(const std::wstring& s, size_t maxChars)
{
    std::string out;
    size_t n = (s.size() < maxChars) ? s.size() : maxChars;
    char b[24];
    for (size_t i = 0; i < n; ++i) {
        unsigned c = (unsigned)(unsigned short)s[i];
        if (c >= 0x20 && c < 0x7F) {
            out.push_back((char)c);
        } else {
            _snprintf_s(b, sizeof(b), _TRUNCATE, "\\u%04X", c);
            out += b;
        }
    }
    if (s.size() > n) {
        _snprintf_s(b, sizeof(b), _TRUNCATE, "...(+%llu more)", (unsigned long long)(s.size() - n));
        out += b;
    }
    return out;
}

// ---------------------------------------------------------------- worker
static DWORD WINAPI Worker(LPVOID param)
{
    g_self = (HMODULE)param;
    Sleep(200);

    std::wstring logPath = DllDir() + L"\\vcxlaunch.log";
    g_log = CreateFileW(logPath.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
                        nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    InitializeCriticalSection(&g_logLock);

    HRESULT co = CoInitializeEx(nullptr, COINIT_MULTITHREADED);

    LogF("================================================================");
    LogF("vcxlaunch attached: pid=%lu tid=%lu CoInitializeEx=0x%08lX",
         GetCurrentProcessId(), GetCurrentThreadId(), (unsigned long)co);

    // The XAML core must already be loaded in this process.
    HMODULE xaml = nullptr;
    for (int i = 0; i < 300; ++i) {
        xaml = GetModuleHandleW(L"Windows.UI.Xaml.dll");
        if (xaml) break;
        Sleep(100);
    }
    if (!xaml) { LogF("Windows.UI.Xaml.dll not loaded (waited 30s) -- giving up"); return 0; }
    LogF("Windows.UI.Xaml.dll = %p", xaml);

    auto pInit = (InitXamlDiagnosticsExFn)GetProcAddress(xaml, "InitializeXamlDiagnosticsEx");
    if (!pInit) { LogF("InitializeXamlDiagnosticsEx NOT exported -- giving up"); return 0; }
    LogF("InitializeXamlDiagnosticsEx = %p", pInit);

    std::wstring diag = ReadIniString(L"xamldiag",
        L"C:\\Program Files (x86)\\Windows Kits\\10\\bin\\x64\\XamlDiagnostics\\xamldiagnostics.dll");
    std::wstring tap  = ReadIniString(L"tap", L"vcxtap.dll");
    LogF("xamldiagnostics.dll = %ls  (exists=%d)", diag.c_str(), FileExists(diag));
    LogF("TAP dll             = %ls  (exists=%d)", tap.c_str(), FileExists(tap));
    if (!FileExists(diag) || !FileExists(tap)) { LogF("missing file(s) -- giving up"); return 0; }

    // ---- ★ 配置下发：直投通道（主）+ initData（面包屑）----
    //
    // 实测（T1，2026-10-03，逐长度二分）：InitializeXamlDiagnosticsEx 的第 6 个参数**确实**
    // 能被 TAP 通过 IXamlDiagnostics::GetInitializationData 原样读回，但**上限正好 259 字符**；
    // >= 260 时**静默返回空串，且 hr 仍是 S_OK** —— 没有任何错误信号。所以配置不能靠它传。
    //
    // 配置改走"直投"：本 DLL 与 TAP 在同一进程，直接 LoadLibrary + 调用 TAP 的导出
    // VmExtTapProvideInitData 把配置放进它的全局变量 —— 无长度与字符集限制（已测 4000 字符）。
    // initData 仍然照传，只当人类可读的面包屑，便于事后从日志判断"本该是什么"。
    std::wstring init = ReadIniRaw(L"initdata");
    if (ReadIniRaw(L"initdata_cjk_test") == L"1") {
        init += kCjkSelfTest;
        LogF("（已附加非 ASCII 自检串 initdata_cjk_test=1）");
    }
    LogF("---- 配置下发 ----");
    LogF("配置 len=%llu  fnv1a64=%016llX", (unsigned long long)init.size(), Fnv1a64(init));
    if (init.size() > 259) {
        LogF("注意：配置 %llu 字符 > 259 -> initData 面包屑会被框架静默丢弃"
             "（仅影响面包屑，配置由直投通道送达）", (unsigned long long)init.size());
    }
    if (init.size() <= 400) LogF("配置内容: %s", EscapeW(init, 400).c_str());
    const wchar_t* initPtr = init.empty() ? nullptr : init.c_str();

    // ---- ★ 配置直投 ----
    LogF("---- 配置直投 ----");
    HMODULE hTap = LoadLibraryW(tap.c_str());
    LogF("LoadLibraryW(TAP) = %p (err=%lu)", hTap, GetLastError());
    if (hTap) {
        auto provide = (void (WINAPI*)(const wchar_t*))GetProcAddress(hTap, "VmExtTapProvideInitData");
        LogF("GetProcAddress(VmExtTapProvideInitData) = %p", provide);
        if (provide) {
            provide(init.c_str());
            LogF("已直投 %llu 字符", (unsigned long long)init.size());
        } else {
            LogF("!! 找不到导出 VmExtTapProvideInitData");
        }
        // ★ 刻意**不** FreeLibrary：多持一个引用可确保该模块不被卸载，
        //   从而保证全局配置在 DllGetClassObject 被调用时还在。
    }

    LogF("---- walking endpoint names VisualDiagConnection1..N ----");
    for (int i = 1; i <= 10000; ++i) {
        wchar_t endpoint[64];
        _snwprintf_s(endpoint, _TRUNCATE, L"VisualDiagConnection%d", i);

        HRESULT hr = pInit(endpoint, GetCurrentProcessId(), diag.c_str(), tap.c_str(),
                           CLSID_VcxTap, initPtr);
        if (SUCCEEDED(hr)) {
            LogF("SUCCESS: endpoint=%ls  hr=0x%08lX  (index %d)", endpoint, (unsigned long)hr, i);
            LogF("the TAP should now be loaded; watch vcxtap.log");
            return 0;
        }
        if (i <= 3 || (i % 1000) == 0)
            LogF("  %ls -> hr=0x%08lX", endpoint, (unsigned long)hr);
        if (hr == E_INVALIDARG) {
            LogF("E_INVALIDARG at index %d -- the endpoint name is probably rejected for another reason; stopping", i);
            break;
        }
    }
    LogF("no free endpoint found -- giving up");
    return 0;
}

BOOL WINAPI DllMain(HMODULE self, DWORD reason, LPVOID)
{
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(self);
        HANDLE th = CreateThread(nullptr, 0, Worker, (LPVOID)self, 0, nullptr);
        if (th) CloseHandle(th);
    }
    return TRUE;
}
