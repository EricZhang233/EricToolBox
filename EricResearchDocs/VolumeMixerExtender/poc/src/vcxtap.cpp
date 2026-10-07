// vcxtap.dll -- XAML diagnostics "TAP" for the Quick Settings panel (route B).
//
// How this fits together (route B of ../design.md):
//
//   vcxmix.dll (already inside ShellHost)  calls
//     Windows.UI.Xaml.dll!InitializeXamlDiagnosticsEx(
//         L"VisualDiagConnection<N>", GetCurrentProcessId(),
//         <sdk>\xamldiagnostics.dll, <our>\vcxtap.dll, CLSID_VcxTap, nullptr)
//
//   The XAML core then loads THIS DLL into ShellHost and asks it, via DllGetClassObject(CLSID_VcxTap),
//   for an object. That object is handed an IXamlDiagnostics* through IObjectWithSite::SetSite.
//   From there we:
//     * QI IVisualTreeService and AdviseVisualTreeChange  -> element-add/remove notifications
//     * on an Add whose element Name == "Footer":
//         IXamlDiagnostics::GetIInspectableFromHandle -> the real XAML FrameworkElement
//         -> append our "TestLink" Button (styled after the existing footer button, right aligned)
//
//   This route needs no code offsets, no pattern scanning and no PDB symbols; it only relies on
//   the documented xamlOM.h contract.
//
// vcxtap.ini (next to this DLL):
//   0 = log mutations only (bounded)
//   1 = full logging, no mutation (default, safe)
//   2 = additionally inject the TestLink button when the Footer appears

#include <windows.h>
// winbase.h's GetCurrentTime() macro collides with a member name used by the C++/WinRT
// XAML headers (warning C4002) -- drop it.
#ifdef GetCurrentTime
#undef GetCurrentTime
#endif

#include <ocidl.h>
#include <inspectable.h>
#include <xamlOM.h>
#include <stdio.h>
#include <stdarg.h>
#include <new>
#include <algorithm>
#include <cmath>
#include <string>
#include <thread>
#include <chrono>
#include <vector>

#include <winrt/base.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.UI.Core.h>
#include <winrt/Windows.UI.Xaml.h>
#include <winrt/Windows.UI.Xaml.Automation.h>
#include <winrt/Windows.UI.Xaml.Controls.h>
#include <winrt/Windows.UI.Xaml.Controls.Primitives.h>
#include <winrt/Windows.UI.Xaml.Media.h>

namespace WFI  = winrt::Windows::Foundation;
namespace WUX  = winrt::Windows::UI::Xaml;
namespace WUXC = winrt::Windows::UI::Xaml::Controls;
namespace WUXM = winrt::Windows::UI::Xaml::Media;
namespace WUXA = winrt::Windows::UI::Xaml::Automation;
namespace WUXCP = winrt::Windows::UI::Xaml::Controls::Primitives;
namespace WUC  = winrt::Windows::UI::Core;

// {A7C5F1E2-9B34-4D6E-8F21-5C0D3E7A9B44}
static const CLSID CLSID_VcxTap =
    { 0xA7C5F1E2, 0x9B34, 0x4D6E, { 0x8F, 0x21, 0x5C, 0x0D, 0x3E, 0x7A, 0x9B, 0x44 } };

// ---------------------------------------------------------------- logging
static HANDLE             g_log = INVALID_HANDLE_VALUE;
static CRITICAL_SECTION   g_logLock;
static HMODULE            g_self = nullptr;

static std::wstring DllDir()
{
    wchar_t path[MAX_PATH] = {};
    GetModuleFileNameW(g_self, path, MAX_PATH);
    std::wstring p(path);
    size_t slash = p.find_last_of(L'\\');
    return (slash == std::wstring::npos) ? L"." : p.substr(0, slash);
}

static void LogInit()
{
    std::wstring logPath = DllDir() + L"\\vcxtap.log";
    g_log = CreateFileW(logPath.c_str(), FILE_APPEND_DATA,
                        FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                        OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (g_log == INVALID_HANDLE_VALUE) return;
    InitializeCriticalSection(&g_logLock);
    static const char sep[] = "\r\n";
    DWORD wr = 0;
    WriteFile(g_log, sep, sizeof(sep) - 1, &wr, nullptr);
}

static void LogF(const char* fmt, ...)
{
    if (g_log == INVALID_HANDLE_VALUE) return;

    char buf[1600];
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

static std::string WideToUtf8(const wchar_t* w)
{
    if (!w) return std::string();
    int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
    if (n <= 1) return std::string();
    std::string s((size_t)(n - 1), '\0');
    WideCharToMultiByte(CP_UTF8, 0, w, -1, s.data(), n, nullptr, nullptr);
    return s;
}

static int ReadStage()
{
    std::wstring ini = DllDir() + L"\\vcxtap.ini";
    return (int)GetPrivateProfileIntW(L"vcxtap", L"stage", 1, ini.c_str());
}

// 配置文件路径：由直投配置里的 cfg= 填；空则退回 DLL 同目录的 vcxtap.ini。
// ★ 必须在 ReadIniRaw 之前声明（它要用）。
static std::wstring g_cfgPath;

static std::wstring ReadIniRaw(const wchar_t* key, const wchar_t* def = L"")
{
    const DWORD kChars = 8192;
    std::wstring buf(kChars, L'\0');
    // ★ 配置文件的路径优先用"直投配置里的 cfg="给出的那一个；没有才退回 DLL 同目录的 vcxtap.ini。
    //   这就是"配置经直投通道送达"的完整体现：连配置文件在哪，都是通道告诉我们的。
    std::wstring ini = g_cfgPath.empty() ? (DllDir() + L"\\vcxtap.ini") : g_cfgPath;
    DWORD n = GetPrivateProfileStringW(L"vcxtap", key, def, &buf[0], kChars, ini.c_str());
    buf.resize(n);
    return buf;
}

// 从 "k=v;k=v" 串里取一个键的值（与交付文档 Contract::Parse 的语义一致：
// 逐段按 ';' 切、按第一个 '=' 分键值、未知键忽略）。
static std::wstring CfgValue(const std::wstring& s, const wchar_t* key)
{
    const std::wstring k = std::wstring(key) + L"=";
    size_t pos = 0;
    while (pos <= s.size()) {
        size_t end = s.find(L';', pos);
        if (end == std::wstring::npos) end = s.size();
        if (s.compare(pos, k.size(), k) == 0) return s.substr(pos + k.size(), end - pos - k.size());
        if (end == s.size()) break;
        pos = end + 1;
    }
    return std::wstring();
}

// FNV-1a 64，输入按 UTF-16 码元逐位异或（wchar_t 环境下最自然的做法）。
// ★ 种子必须是标准 64 位偏移基 14695981039346656037（0xCBF29CE484222325）。
//   注意网上大量资料把它误写成 1469598103934665603（少一位）—— 那样算出来的哈希
//   跟任何标准 FNV 实现都不一致，别人无法独立复核。这里用正确值，
//   空串的哈希就应当等于 0xCBF29CE484222325，正好可以拿来自检。
static unsigned long long Fnv1a64(const std::wstring& s)
{
    unsigned long long h = 14695981039346656037ULL;
    for (size_t i = 0; i < s.size(); ++i) {
        h ^= (unsigned long long)(unsigned short)s[i];
        h *= 1099511628211ULL;
    }
    return h;
}

// 宽串 -> 纯 ASCII 可读形式（非 ASCII 打成 \uXXXX）。
// ★ 不直接 %ls 打原文：日志是窄字节流，MSVC 的 %ls 按 ANI 代码页转换，中文 Windows 上
//   会写成 GBK 字节，用 UTF-8 读就是乱码 —— 那会让我误判"回读失败"。
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

static int  g_stage = 1;
static long g_events = 0;
static long g_logLimit = 40000;

// ---------------------------------------------------------------- 配置直投通道（主通道）
// 背景（T1 实测结论）：InitializeXamlDiagnosticsEx 的第 6 个参数**确实**能被
//   IXamlDiagnostics::GetInitializationData() 原样回读，但**上限只有 259 字符**，
//   >= 260 时静默返回空串且 hr 仍是 S_OK（没有任何错误信号）。
//   => 通道本身可用，但**容量不可靠**，不能当配置主干。
//
// 所以配置走"直投"：Launcher 与 TAP 在**同一个进程**里。Launcher 直接 LoadLibrary 本 DLL
// 并调用下面这个导出，把配置放进本 DLL 的一个全局变量；随后 XAML core 也会加载同一个
// 模块（LoadLibrary 引用计数，拿到的是同一个 HMODULE），于是 DllGetClassObject 之前
// 配置就已经就位了。
//
// 这个方案的好处：
//   * 不依赖任何未文档化的行为
//   * 同一进程内的内存，**逐字符无损**（不像跨 API 可能被规范化/截断）
//   * 没有 initData 那种 259 字符上限（已验证 4000 字符无损通过）
// initData 仍然照传，降级为"人类可读的面包屑"：超限时丢的只是面包屑，配置不受影响。
static CRITICAL_SECTION g_cfgLock;
static bool             g_cfgLockInit = false;
static std::wstring     g_providedData;
static bool             g_hasProvided = false;

// 读一份直投配置的副本（加锁）。任何需要配置的地方都走它。
static std::wstring ProvidedConfig()
{
    if (!g_cfgLockInit) return std::wstring();
    EnterCriticalSection(&g_cfgLock);
    std::wstring s = g_providedData;
    LeaveCriticalSection(&g_cfgLock);
    return s;
}

extern "C" __declspec(dllexport) void WINAPI VmExtTapProvideInitData(const wchar_t* s)
{
    if (!g_cfgLockInit) return;
    std::wstring copy = s ? s : L"";
    EnterCriticalSection(&g_cfgLock);
    g_providedData = std::move(copy);
    g_hasProvided  = true;
    LeaveCriticalSection(&g_cfgLock);

    LogF("---- 配置直投通道 ----");
    LogF("收到直投配置 len=%llu fnv1a64=%016llX",
         (unsigned long long)g_providedData.size(), Fnv1a64(g_providedData));
    LogF("直投内容: %s", EscapeW(g_providedData, 400).c_str());
}

// ---------------------------------------------------------------- 点击动作
//
// ★ 幂等判定：**按内容判定，不用指针身份**。
//   曾经用 `g_lastInjectedFooter == get_abi(footer)` 当"这个 Footer 我注入过了"的判据 —— 实测踩坑：
//   面板关了又开时 XAML 会重建元素，但**分配器可能把同一个地址复用给新的 Footer**，
//   于是这个守卫把新 Footer 误判成旧的 ⇒ **按钮被静默跳过、什么都不显示**（实测复现，见日志里
//   两次 "Footer appeared" 拿到同一个 handle）。
//   现在改成"在这个 Footer 里找不找得到我们的按钮" —— 这是**自证**的：树里有就是有，
//   没有就注入。顺带还能自愈"按钮被别的东西移除了"的情况。
static const wchar_t kEntryAutomationId[] = L"VmExtEntry";

// 在 node 的子树里找 AutomationId == kEntryAutomationId 的元素。
static WUX::DependencyObject FindOurEntry(WUX::DependencyObject const& node, int depth)
{
    if (!node || depth > 40) return nullptr;
    int n = 0;
    try { n = WUXM::VisualTreeHelper::GetChildrenCount(node); } catch (...) { return nullptr; }
    for (int i = 0; i < n; ++i) {
        WUX::DependencyObject c = nullptr;
        try { c = WUXM::VisualTreeHelper::GetChild(node, i); } catch (...) { continue; }
        try {
            if (WUXA::AutomationProperties::GetAutomationId(c) == kEntryAutomationId) return c;
        } catch (...) { }
        if (auto r = FindOurEntry(c, depth + 1)) return r;
    }
    return nullptr;
}

// 管道名。SetSite 时从生效配置的 pipe= 取，缺省按 sessionId 拼（与交付文档 §2.2.2 一致）。
static std::wstring g_pipeName;

static std::wstring DefaultPipeName()
{
    DWORD sid = 0;
    ProcessIdToSessionId(GetCurrentProcessId(), &sid);
    wchar_t b[128];
    swprintf_s(b, L"\\\\.\\pipe\\VmExt.Tap.S%lu", sid);
    return b;
}

// "CLICK <entryId> <unixMillisUtc>\n" —— 与交付文档 §2.4 的报文格式一致。
// ★ 用**字节模式 + \n 分行**（不用消息模式），服务端按行读。
static std::string FormatClickMsg()
{
    const std::wstring id = ReadIniRaw(L"entry1_id", L"volumemixer");
    const unsigned long long ms = (unsigned long long)
        std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::system_clock::now().time_since_epoch()).count();
    char b[512];
    sprintf_s(b, "CLICK %s %llu\n", WideToUtf8(id.c_str()).c_str(), ms);
    return b;
}

// 往管道写一条点击报文。**只在独立线程里调用**（见 RunEntryAction）。
static void WriteClickToPipe(const std::wstring& pipeName, const std::string& msg)
{
    HANDLE h = CreateFileW(pipeName.c_str(), GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, 0, nullptr);
    if (h == INVALID_HANDLE_VALUE) {
        const DWORD first = GetLastError();
        // "服务端没起来"是最常见的情形（App 没运行）。等 200ms 再试一次 —— 这一等
        // 正是**不能放在 UI 线程上**的原因。
        LogF("   pipe: 首次 CreateFile 失败 err=%lu，WaitNamedPipeW(200) 重试…", first);
        if (WaitNamedPipeW(pipeName.c_str(), 200)) {
            h = CreateFileW(pipeName.c_str(), GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, 0, nullptr);
        }
        if (h == INVALID_HANDLE_VALUE) {
            // 明确记成"降级"：点击不生效，但**面板不受影响**（这正是 action=pipe 的设计取舍）
            LogF("   pipe: 服务端不可用，放弃本次点击 (err=%lu) —— 面板不受影响", GetLastError());
            return;
        }
    }

    DWORD wrote = 0;
    if (WriteFile(h, msg.data(), (DWORD)msg.size(), &wrote, nullptr)) {
        LogF("   pipe: 已发出 %lu 字节 -> %s", wrote, EscapeW(pipeName, 200).c_str());
    } else {
        LogF("   pipe: WriteFile 失败 err=%lu", GetLastError());
    }
    CloseHandle(h);
}

// ★ 安全写法：显式给 lpApplicationName，并且命令行里的路径**加引号**。
//
// 为什么不能用"裸路径命令行"：实测复现过 —— 当 lpApplicationName = NULL、
// 命令行又是**没加引号**的含空格路径时，CreateProcessW 会对它**逐段前缀试探**：
//   命令行 C:\...\Temp\a b c\click probe.exe
//   前缀处若存在 C:\...\Temp\a.exe  →  它启动的是**那个**（argv[0] 只有 ...\Temp\a）
// 前缀处不存在同名文件时才会落到完整路径上 —— 也就是"平时能跑，前缀处一旦有同名文件就跑错程序"。
//
// 所以规则是：**lpApplicationName 给一个明确的可执行文件，lpCommandLine 里路径加引号。**
// 产品接主程序入口时同样必须这么做（见交付文档 §4.3 坑 27）。
static void RunExec()
{
    static const wchar_t kExe[] = L"winver.exe";     // 产品里换成主程序 exe 的绝对路径
    wchar_t cmd[512];
    swprintf_s(cmd, L"\"%s\"", kExe);

    STARTUPINFOW si = {};
    si.cb = sizeof(si);
    PROCESS_INFORMATION pi = {};
    if (CreateProcessW(kExe, cmd, nullptr, nullptr, FALSE, 0, nullptr, nullptr, &si, &pi)) {
        LogF("   action=exec: CreateProcessW OK pid=%lu", pi.dwProcessId);
        CloseHandle(pi.hThread);                     // ⛔ 不要 WaitForSingleObject：会卡住 ShellHost
        CloseHandle(pi.hProcess);
    } else {
        LogF("   action=exec: CreateProcessW failed err=%lu", GetLastError());
    }
}

// 点击入口：按配置分派。exec 直接起进程；pipe 交给独立线程写管道。
static void RunEntryAction()
{
    const std::wstring action = ReadIniRaw(L"entry1_action", L"exec");

    if (action == L"pipe") {
        // ⛔ 绝不能在 UI 线程上做管道 IO：服务端没起来时 WaitNamedPipeW 会把整个面板卡住。
        const std::wstring pipeName = g_pipeName.empty() ? DefaultPipeName() : g_pipeName;
        const std::string  msg      = FormatClickMsg();
        LogF("   action=pipe: 报文=[%s] -> %s（已交独立线程，UI 线程不停留）",
             msg.c_str(), EscapeW(pipeName, 200).c_str());
        // ★ 线程入口最外层必须有 try/catch(...)：未捕获异常 → std::terminate → ShellHost 崩（坑 20）
        std::thread t([pipeName, msg]() noexcept {
            try { WriteClickToPipe(pipeName, msg); }
            catch (...) { LogF("   pipe: 线程内异常，已吞掉"); }
        });
        t.detach();
        return;
    }

    RunExec();
}

static std::string ClassOf(WFI::IInspectable const& o)
{
    try { return WideToUtf8(winrt::get_class_name(o).c_str()); } catch (...) { return "<err>"; }
}

// NaN is the "unset" value for XAML double DP properties, so print it as a word instead of "-nan".
static std::string FmtNum(double v)
{
    if (std::isnan(v)) return "nan";
    char b[32];
    sprintf_s(b, "%.1f", v);
    return b;
}

// The Footer turned out to be an ItemsControl (measured), whose ItemsPanel is a StackPanel.
// Alignment properties do nothing inside a StackPanel, so right-align by giving our button a
// computed left margin and recomputing it whenever the footer resizes.
static void ApplyRightAlign(WUX::FrameworkElement const& footer, WUXC::Button const& btn)
{
    btn.HorizontalAlignment(WUX::HorizontalAlignment::Right);
    btn.VerticalAlignment(WUX::VerticalAlignment::Center);

    auto recompute = [footer, btn]() {
        double used = 0;
        try {
            auto parent = WUXM::VisualTreeHelper::GetParent(btn);
            if (auto p = parent.try_as<WUXC::Panel>()) {
                for (auto const& c : p.Children()) {
                    if (winrt::get_abi(c) == winrt::get_abi(btn)) continue;
                    if (auto fe = c.try_as<WUX::FrameworkElement>()) {
                        double w = fe.ActualWidth();
                        if (w > 0) used += w;
                    }
                }
            }
        } catch (...) {}
        double avail = footer.ActualWidth() - used - btn.ActualWidth() - 12.0;
        if (avail < 8.0) avail = 8.0;
        btn.Margin(WUX::Thickness{ avail, 0, 12, 0 });
        LogF("   align: footerW=%.0f used=%.0f btnW=%.0f -> leftMargin=%.0f",
             footer.ActualWidth(), used, btn.ActualWidth(), avail);
    };

    footer.SizeChanged([recompute](WFI::IInspectable const&, WUX::SizeChangedEventArgs const&) {
        try { recompute(); } catch (...) {}
    });
    recompute();
}

static WUXC::Button FindModelButton(WUX::DependencyObject const& node, int depth)
{
    if (!node || depth > 12) return nullptr;
    UINT32 n = 0;
    try { n = WUXM::VisualTreeHelper::GetChildrenCount(node); } catch (...) { return nullptr; }
    for (UINT32 i = 0; i < n; ++i) {
        WUX::DependencyObject c = nullptr;
        try { c = WUXM::VisualTreeHelper::GetChild(node, i); } catch (...) { continue; }
        if (auto b = c.try_as<WUXC::Button>()) return b;
        if (auto r = FindModelButton(c, depth + 1)) return r;
    }
    return nullptr;
}

static WUXC::Panel FindFirstPanel(WUX::DependencyObject const& node, int depth)
{
    if (!node || depth > 12) return nullptr;
    UINT32 n = 0;
    try { n = WUXM::VisualTreeHelper::GetChildrenCount(node); } catch (...) { return nullptr; }
    for (UINT32 i = 0; i < n; ++i) {
        WUX::DependencyObject c = nullptr;
        try { c = WUXM::VisualTreeHelper::GetChild(node, i); } catch (...) { continue; }
        if (auto p = c.try_as<WUXC::Panel>()) return p;
        if (auto r = FindFirstPanel(c, depth + 1)) return r;
    }
    return nullptr;
}

// Match the existing footer button: same type, copy its explicit Style if it has one, and copy
// the layout properties that would otherwise differ.
static WUXC::Button BuildTestLinkButton(WUXC::Button const& model)
{
    WUXC::Button btn;
    // ★ 按钮文字来自配置（配置文件的路径是**经直投通道**告诉我们的，见 SetSite）。
    //   这一行就是"配置 -> 直投通道 -> 界面行为改变"整条链路的落点。
    std::wstring text = ReadIniRaw(L"entry1_text", L"TestLink");
    if (text.empty()) text = L"TestLink";
    LogF("   按钮文字 = %s  (来源: 配置 entry1_text)", EscapeW(text, 80).c_str());
    btn.Content(winrt::box_value(winrt::hstring(text)));
    // ★ 给我们的按钮打一个稳定的标记：幂等判定用它（见 InjectIntoFooter），
    //   验收脚本也可以用它精确定位（比"按会变的文字找"可靠）。
    WUXA::AutomationProperties::SetAutomationId(btn, kEntryAutomationId);
    if (model) {
        try {
            if (auto st = model.Style()) btn.Style(st);
            btn.MinWidth(model.MinWidth());
            btn.MinHeight(model.MinHeight());
            btn.Padding(model.Padding());
            btn.CornerRadius(model.CornerRadius());
            btn.FontSize(model.FontSize());
            btn.FontWeight(model.FontWeight());
            btn.HorizontalContentAlignment(model.HorizontalContentAlignment());
            btn.VerticalContentAlignment(model.VerticalContentAlignment());
            if (auto fg = model.Foreground()) btn.Foreground(fg);

            // The model's box (94x40) is the bar's hover/press highlight, so our button has to be
            // the same height or the highlight looks wrong. Height/MinHeight may be NaN when the
            // value comes from the template, so fall back to the explicit one, then to the live
            // measurement (which exists only once layout has run).
            LogF("   model metrics: Height=%s MinHeight=%s ActualH=%.1f Style=%s",
                 FmtNum(model.Height()).c_str(), FmtNum(model.MinHeight()).c_str(),
                 model.ActualHeight(), model.Style() ? "yes" : "none");
            double h = model.Height();
            if (!(h > 0)) h = model.MinHeight();
            if (!(h > 0)) h = 40.0;   // measured: the model button renders 40 px tall
            btn.Height(h);
            btn.MinHeight(h);
            LogF("   -> TestLink height forced to %.1f", h);
        } catch (...) {
            LogF("   style copy: partially failed (continuing)");
        }
    }
    btn.Click([](WFI::IInspectable const&, WUX::RoutedEventArgs const&) { RunEntryAction(); });
    return btn;
}

// The page-level "Footer" is an ItemsControl whose ItemsPanel is a VERTICAL StackPanel, so
// appending an item always produces a NEW ROW (measured: the footer grew 48 -> 78 px and the
// button landed on row 2). The empty space the user asked for is inside the row that already
// holds "更多音量设置", so wrap that row's generated container in a 2-column Grid and drop our
// button into the right-hand column. Measured row shape:
//   Button -> ContentPresenter -> ContentControl -> ContentPresenter   [the generated container]
//          -> StackPanel[Vertical, ItemsPanel] -> ItemsPresenter -> ItemsControl[Footer]
static bool InjectIntoRow(WUX::FrameworkElement const& model, WUXC::Button const& btn)
{
    WUX::DependencyObject child = model, cur = model, itemsPanel = nullptr, container = nullptr;
    for (int i = 0; i < 12 && cur; ++i) {
        WUX::DependencyObject p = nullptr;
        try { p = WUXM::VisualTreeHelper::GetParent(cur); } catch (...) { break; }
        if (!p) break;
        if (p.try_as<WUXC::ItemsPresenter>()) {
            itemsPanel = cur;   // the ItemsPanel itself
            container  = child; // the direct child of the ItemsPanel: the generated item container
            break;
        }
        child = cur;
        cur = p;
    }
    if (!container || !itemsPanel) {
        LogF("   no ItemsPresenter ancestor -- cannot find the row container");
        return false;
    }

    auto panel  = itemsPanel.try_as<WUXC::Panel>();
    auto holder = container.try_as<WUX::FrameworkElement>();
    if (!panel || !holder) {
        LogF("   row container is not a FrameworkElement inside a Panel -- cannot wrap it");
        return false;
    }

    uint32_t holderIndex = 0;
    if (!panel.Children().IndexOf(holder, holderIndex)) {
        LogF("   row container is not a child of the ItemsPanel -- cannot wrap it");
        return false;
    }

    WUXC::Grid grid;
    auto starCol = WUXC::ColumnDefinition();
    starCol.Width(WUX::GridLength{ 1.0, WUX::GridUnitType::Star });
    auto autoCol = WUXC::ColumnDefinition();
    autoCol.Width(WUX::GridLength{ 1.0, WUX::GridUnitType::Auto });
    grid.ColumnDefinitions().Append(starCol);
    grid.ColumnDefinitions().Append(autoCol);

    // Reparent the existing row into column 0. Column 0 is Star (not Auto) so the row keeps the
    // full footer width it had before, and the model button stays where it was.
    panel.Children().RemoveAt(holderIndex);
    WUXC::Grid::SetColumn(holder, 0);
    grid.Children().Append(holder);

    WUXC::Grid::SetColumn(btn, 1);
    btn.HorizontalAlignment(WUX::HorizontalAlignment::Right);
    btn.VerticalAlignment(WUX::VerticalAlignment::Center);
    // 4 px mirrors the left inset the model button itself has (measured: footer x=2189,
    // button x=2193), so the button lands symmetrically in the bar.
    btn.Margin(WUX::Thickness{ 8, 0, 4, 0 });
    grid.Children().Append(btn);

    panel.Children().Append(grid);

    LogF("   wrapped the row container (class=%s) inside the %s in a 2-column Grid",
         ClassOf(container).c_str(), ClassOf(itemsPanel).c_str());
    LogF("   *** TestLink injected on the SAME row as the model button (right aligned) ***");
    return true;
}

// ---------------------------------------------------------------------------
// 一次性能力探针：T14（能否激活自定义页所需的控件类型）+ T12（ListContent 内容是否可写、可还原）
// ---------------------------------------------------------------------------
template <typename T>
static void TryActivate(const wchar_t* name)
{
    try { T instance; (void)instance; LogF("   [ok]   %ls", name); }
    catch (winrt::hresult_error const& e) { LogF("   [FAIL] %ls  hr=0x%08lX", name, (unsigned long)e.code().value); }
    catch (...) { LogF("   [FAIL] %ls  (unknown)", name); }
}

static WUX::FrameworkElement FindByNameDeep(WUX::DependencyObject const& node, const wchar_t* want, int depth)
{
    if (depth > 14) return nullptr;
    UINT32 n = 0;
    try { n = WUXM::VisualTreeHelper::GetChildrenCount(node); } catch (...) { return nullptr; }
    for (UINT32 i = 0; i < n; ++i) {
        WUX::DependencyObject c = nullptr;
        try { c = WUXM::VisualTreeHelper::GetChild(node, i); } catch (...) { continue; }
        if (auto fe = c.try_as<WUX::FrameworkElement>()) {
            try { if (fe.Name() == want) return fe; } catch (...) {}
        }
        if (auto r = FindByNameDeep(c, want, depth + 1)) return r;
    }
    return nullptr;
}

static void ProbeCapabilities(WUX::FrameworkElement const& footer)
{
    static bool done = false;
    if (done) return;
    done = true;

    LogF("=== capability probe (T14) ===");
    TryActivate<WUXC::ComboBox>(L"ComboBox");
    TryActivate<WUXC::ComboBoxItem>(L"ComboBoxItem");
    TryActivate<WUXC::ListView>(L"ListView");
    TryActivate<WUXC::ListViewItem>(L"ListViewItem");
    TryActivate<WUXC::Slider>(L"Slider");
    TryActivate<WUXC::StackPanel>(L"StackPanel");
    TryActivate<WUXC::Grid>(L"Grid");
    TryActivate<WUXC::TextBlock>(L"TextBlock");
    TryActivate<WUXC::ScrollViewer>(L"ScrollViewer");
    TryActivate<WUXC::Image>(L"Image");

    // T18：「录制模式」复选框要用 CheckBox（T14 的 10 个类型不含它）。
    // ToggleButton 也曾因位于 Controls.Primitives 而编译失败 —— 顺带确认现在可激活。
    LogF("=== capability probe (T18: CheckBox) ===");
    TryActivate<WUXC::CheckBox>(L"CheckBox");
    TryActivate<WUXCP::ToggleButton>(L"ToggleButton");
    try {
        WUXC::CheckBox cb;
        cb.Content(winrt::box_value(L"probe"));
        cb.MinHeight(0.0);
        cb.IsThreeState(false);
        cb.IsChecked(winrt::box_value(true).as<WFI::IReference<bool>>());
        bool on = false;
        try { on = winrt::unbox_value<bool>(cb.IsChecked()); } catch (...) {}
        WUXC::StackPanel host;
        host.Children().Append(cb);
        std::wstring txt = winrt::unbox_value<winrt::hstring>(cb.Content()).c_str();
        LogF("   [ok]   CheckBox 建/设值/挂树：Content=%ls  IsChecked=%s  MinHeight=%.1f",
             txt.c_str(), on ? "true" : "false", cb.MinHeight());
    } catch (winrt::hresult_error const& e) {
        LogF("   [FAIL] CheckBox 建/设值/挂树  hr=0x%08lX", (unsigned long)e.code().value);
    } catch (...) {
        LogF("   [FAIL] CheckBox 建/设值/挂树  (unknown)");
    }

    LogF("=== capability probe (T12) ===");
    WUX::FrameworkElement pageWindow = nullptr;
    {
        WUX::DependencyObject cur = footer;
        for (int i = 0; i < 14 && cur; ++i) {
            WUX::DependencyObject p = nullptr;
            try { p = WUXM::VisualTreeHelper::GetParent(cur); } catch (...) { break; }
            if (!p) break;
            if (auto fe = p.try_as<WUX::FrameworkElement>()) {
                try { if (fe.Name() == L"PageWindow") { pageWindow = fe; break; } } catch (...) {}
            }
            cur = p;
        }
    }
    LogF("   PageWindow = %s", pageWindow ? "found" : "NOT FOUND");
    if (!pageWindow) return;

    auto listContent = FindByNameDeep(pageWindow, L"ListContent", 0);
    LogF("   ListContent = %s", listContent ? "found" : "NOT FOUND");
    if (!listContent) return;
    LogF("   ListContent class = %s", ClassOf(listContent).c_str());

    auto scroller = listContent.try_as<WUXC::ScrollViewer>();
    LogF("   as ScrollViewer = %s", scroller ? "yes" : "no");
    if (!scroller) return;

    WFI::IInspectable original = nullptr;
    try { original = scroller.Content(); } catch (...) {}
    LogF("   original Content = %s", original ? "non-null" : "null");

    WUXC::StackPanel probe;
    WUXC::TextBlock label;
    label.Text(L"probe");
    probe.Children().Append(label);
    try {
        scroller.Content(probe);
        LogF("   *** set Content = OK  (T12 写入可用) ***");
        scroller.Content(original);
        LogF("   *** restore Content = OK ***");
    } catch (winrt::hresult_error const& e) {
        LogF("   *** set Content FAILED  hr=0x%08lX ***", (unsigned long)e.code().value);
    } catch (...) {
        LogF("   *** set Content FAILED  (unknown) ***");
    }
}

static void InjectIntoFooter(WUX::FrameworkElement const& footer)
{
    ProbeCapabilities(footer);

    // ★ 幂等：按内容判定（见文首说明）。不再用指针身份 —— 那会被分配器地址复用骗到。
    if (auto existing = FindOurEntry(footer, 0)) {
        LogF("   Footer 里已经有我们的按钮了（AutomationId=%ls）-> 跳过（内容判定）",
             kEntryAutomationId);
        (void)existing;
        return;
    }

    LogF("   injecting into Footer (class=%s)", ClassOf(footer).c_str());

    WUXC::Button model = FindModelButton(footer, 0);
    LogF("   style model button = %s", model ? ClassOf(model).c_str() : "(none)");

    // Diagnostics: what exactly sits above the existing footer button?
    if (model) {
        WUX::DependencyObject cur = model;
        for (int i = 0; i < 10 && cur; ++i) {
            WUX::DependencyObject p = nullptr;
            try { p = WUXM::VisualTreeHelper::GetParent(cur); } catch (...) { break; }
            if (!p) break;
            std::string extra;
            if (auto sp = p.try_as<WUXC::StackPanel>()) {
                extra = (sp.Orientation() == WUXC::Orientation::Horizontal) ? " [Horizontal]" : " [Vertical]";
            } else if (auto g = p.try_as<WUXC::Grid>()) {
                extra = " [Grid cols=" + std::to_string(g.ColumnDefinitions().Size()) +
                        " rows=" + std::to_string(g.RowDefinitions().Size()) + "]";
            }
            LogF("      up[%d] %s%s", i, ClassOf(p).c_str(), extra.c_str());
            cur = p;
        }
    }

    WUXC::Button btn = BuildTestLinkButton(model);

    // Preferred: land on the same row as the model button, right aligned.
    if (model && InjectIntoRow(model, btn)) {
        LogF("   *** TestLink injected (click -> action=%s) ***",
             WideToUtf8(ReadIniRaw(L"entry1_action", L"exec").c_str()).c_str());
        return;
    }

    LogF("   row wrap failed -- falling back to an extra footer item");

    bool appended = false;
    if (auto items = footer.try_as<WUXC::ItemsControl>()) {
        try {
            items.Items().Append(btn);
            appended = true;
            LogF("   appended through ItemsControl.Items() (gets the item template)");
        } catch (...) {
            LogF("   ItemsControl.Items() append failed (bound ItemsSource?) -- falling back");
        }
    }
    if (!appended) {
        if (auto host = FindFirstPanel(footer, 0)) {
            host.Children().Append(btn);
            appended = true;
            LogF("   appended into the ItemsPanel (%s)", ClassOf(host).c_str());
        }
    }
    if (!appended) {
        if (auto cc = footer.try_as<WUXC::ContentControl>()) {
            cc.Content(btn);
            appended = true;
            LogF("   appended through ContentControl.Content");
        }
    }
    if (!appended) { LogF("   !! no place to append -- giving up"); return; }

    ApplyRightAlign(footer, btn);
    LogF("   *** TestLink injected (fallback path; click -> action=%s) ***",
         WideToUtf8(ReadIniRaw(L"entry1_action", L"exec").c_str()).c_str());
}

// Deferred: the Footer's own children may not exist yet when the Add notification arrives.
static void TryInjectLater(WUX::FrameworkElement const& footer, int attempt)
{
    WUC::CoreDispatcher d = nullptr;
    try { d = footer.Dispatcher(); } catch (...) {}
    if (!d) { try { InjectIntoFooter(footer); } catch (...) {} return; }

    auto attemptFn = [footer, attempt]() {
        WUXC::Button model = FindModelButton(footer, 0);
        if (!model && attempt < 20) {
            WUC::CoreDispatcher dd = nullptr;
            try { dd = footer.Dispatcher(); } catch (...) {}
            if (dd) dd.RunAsync(WUC::CoreDispatcherPriority::Low, [footer, attempt]() {
                TryInjectLater(footer, attempt + 1);
            });
            return;
        }
        try { InjectIntoFooter(footer); }
        catch (...) { LogF("   !! InjectIntoFooter threw (swallowed)"); }
    };

    if (d.HasThreadAccess()) {
        attemptFn();
    } else {
        d.RunAsync(WUC::CoreDispatcherPriority::Normal, attemptFn);
    }
}

// ---------------------------------------------------------------- the TAP object
class Tap : public IVisualTreeServiceCallback, public IObjectWithSite
{
public:
    Tap() { InterlockedIncrement(&g_objects); }
    virtual ~Tap()
    {
        if (m_vts)  { m_vts->Release();  m_vts = nullptr; }
        if (m_diag) { m_diag->Release(); m_diag = nullptr; }
        InterlockedDecrement(&g_objects);
    }

    // ---- IUnknown ----
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppv) override
    {
        if (!ppv) return E_POINTER;
        *ppv = nullptr;
        if (riid == __uuidof(IUnknown) || riid == __uuidof(IVisualTreeServiceCallback))
            *ppv = static_cast<IVisualTreeServiceCallback*>(this);
        else if (riid == __uuidof(IObjectWithSite))
            *ppv = static_cast<IObjectWithSite*>(this);
        else
            return E_NOINTERFACE;
        AddRef();
        return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return (ULONG)InterlockedIncrement(&m_ref); }
    ULONG STDMETHODCALLTYPE Release() override
    {
        LONG r = InterlockedDecrement(&m_ref);
        if (r == 0) delete this;
        return (ULONG)r;
    }

    // ---- IObjectWithSite ----
    HRESULT STDMETHODCALLTYPE SetSite(IUnknown* site) override
    {
        LogF("Tap::SetSite(site=%p)", site);
        if (m_vts)  { m_vts->Release();  m_vts = nullptr; }
        if (m_diag) { m_diag->Release(); m_diag = nullptr; }
        if (!site) return S_OK;

        HRESULT hr = site->QueryInterface(__uuidof(IXamlDiagnostics), (void**)&m_diag);
        LogF("   QI IXamlDiagnostics  hr=0x%08lX ptr=%p", (unsigned long)hr, m_diag);

        hr = site->QueryInterface(__uuidof(IVisualTreeService), (void**)&m_vts);
        if (FAILED(hr) || !m_vts) {
            hr = site->QueryInterface(__uuidof(IVisualTreeService3), (void**)&m_vts);
        }
        LogF("   QI IVisualTreeService hr=0x%08lX ptr=%p", (unsigned long)hr, m_vts);

        // ---- ★ 配置来源：直投通道（主）+ initData 回读（面包屑）----
        //
        // 实测结论（T1，2026-10-03，用逐长度二分法验证过；见 docs/verified-after-injection/06-*）：
        //   * GetInitializationData 确实会**原样**返回 InitializeXamlDiagnosticsEx 的第 6 个参数，
        //     但**长度上限正好 259 字符**；>= 260 时**静默返回空串**，hr 仍是 S_OK
        //     （没有任何错误信号 —— 这是最危险的地方）。上限对应 wchar_t buf[260] 留 1 个给 NUL。
        //   * 超限是**有界拒绝**，不是缓冲区溢出：4000 字符下 ShellHost 无异常、按钮照常注入。
        //   * 每次返回**新分配**的 BSTR（两次调用指针不同），按 MIDL [retval][out] 契约由
        //     调用方 SysFreeString —— 已验证安全（这一条要是搞错就会破坏 ShellHost 的堆）。
        //
        // 所以：**配置走直投通道**（Launcher 直接调本 DLL 的导出，同一进程内存，
        //       无长度与字符集限制），initData 只当人类可读的面包屑。
        std::wstring fromInitData;
        if (m_diag) {
            BSTR d = nullptr;
            if (SUCCEEDED(m_diag->GetInitializationData(&d)) && d) {
                fromInitData.assign(d, SysStringLen(d));   // SysStringLen：BSTR 里允许有 \0
                SysFreeString(d);
            }
        }

        std::wstring fromDirect;
        bool hasDirect = false;
        {
            EnterCriticalSection(&g_cfgLock);
            fromDirect = g_providedData;
            hasDirect  = g_hasProvided;
            LeaveCriticalSection(&g_cfgLock);
        }

        LogF("---- 配置来源 ----");
        LogF("直投通道: %s  len=%llu  fnv1a64=%016llX",
             hasDirect ? "有" : "无",
             (unsigned long long)fromDirect.size(), Fnv1a64(fromDirect));
        LogF("initData : len=%llu  fnv1a64=%016llX",
             (unsigned long long)fromInitData.size(), Fnv1a64(fromInitData));
        if (hasDirect && fromDirect.size() <= 400)
            LogF("直投内容: %s", EscapeW(fromDirect, 400).c_str());

        if (!hasDirect) {
            // 配置没送到 —— 这是降级路径，必须显式记录，不能静默。
            LogF("!! 直投通道未收到数据（Launcher 未调用 VmExtTapProvideInitData）");
        } else if (fromInitData == fromDirect) {
            LogF("两种通道内容一致（%llu 字符，未触及 259 上限）",
                 (unsigned long long)fromDirect.size());
        } else if (fromInitData.empty() && fromDirect.size() > 259) {
            LogF("initData 为空属**预期**：内容 %llu 字符超过 259 上限，框架静默丢弃",
                 (unsigned long long)fromDirect.size());
        } else if (!fromInitData.empty()) {
            LogF("!! 两通道内容不一致（initData=%llu，直投=%llu）—— 以直投为准",
                 (unsigned long long)fromInitData.size(), (unsigned long long)fromDirect.size());
        } else {
            // 直投有、initData 空、且长度没超上限 —— 不该发生（上限是唯一已知原因）。
            LogF("!! initData 回读为空，但内容仅 %llu 字符（<= 259）—— 非已知的长度上限原因，"
                 "说明这条面包屑通道还有别的静默失败条件",
                 (unsigned long long)fromDirect.size());
        }
        if (!hasDirect && !fromInitData.empty()) {
            // 降级路径：直投没到，但 initData 回读到了内容 -> 当作配置用。
            EnterCriticalSection(&g_cfgLock);
            g_providedData = fromInitData;
            g_hasProvided  = true;
            LeaveCriticalSection(&g_cfgLock);
            LogF("!! 直投未到，已把 initData 回读内容当作配置（降级路径）");
        }

        // ★ 从配置里取出"配置文件在哪"，之后所有 ini 读取都走它 —— 这样才算把通道接上。
        {
            const std::wstring eff = hasDirect ? fromDirect : fromInitData;
            std::wstring cfg = CfgValue(eff, L"cfg");
            if (!cfg.empty()) {
                g_cfgPath = cfg;
                LogF("已从直投配置解析出配置文件路径: %s", EscapeW(g_cfgPath, 400).c_str());
            } else {
                LogF("直投配置里没有 cfg= 键 -> 配置文件退回到 DLL 同目录的 vcxtap.ini");
            }

            // ★ 管道名同样走这条通道（action=pipe 用）。缺省按 sessionId 拼。
            std::wstring pn = CfgValue(eff, L"pipe");
            g_pipeName = pn.empty() ? DefaultPipeName() : pn;
            LogF("管道名 = %s", EscapeW(g_pipeName, 200).c_str());
        }


        if (m_vts) {
            AddRef();                     // the service keeps this pointer
            hr = m_vts->AdviseVisualTreeChange(this);
            LogF("   AdviseVisualTreeChange hr=0x%08lX", (unsigned long)hr);
            if (FAILED(hr)) Release();
        }
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetSite(REFIID riid, void** ppvSite) override
    {
        if (!ppvSite) return E_POINTER;
        *ppvSite = nullptr;
        if (!m_diag) return E_FAIL;
        return m_diag->QueryInterface(riid, ppvSite);
    }

    // ---- IVisualTreeServiceCallback ----
    HRESULT STDMETHODCALLTYPE OnVisualTreeChange(ParentChildRelation relation,
                                                 VisualElement element,
                                                 VisualMutationType mutationType) override
    {
        const wchar_t* type = element.Type ? element.Type : L"";
        const wchar_t* name = element.Name ? element.Name : L"";
        long seq = InterlockedIncrement(&g_events);

        if (seq <= g_logLimit) {
            LogF("  %s parent=%llX idx=%u handle=%llX type=[%ls] name=[%ls] children=%u",
                 mutationType == Add ? "ADD " : "REM ",
                 (unsigned long long)relation.Parent, relation.ChildIndex,
                 (unsigned long long)element.Handle,
                 type, name, element.NumChildren);
        }

        // Measured: "Footer" is the sound page's own bottom bar (PageWindow -> FullScreenPage ->
        // L2Frame -> PageContent -> Footer), which is the one holding "更多音量设置".
        // "FooterGrid"/"LeftFooter"/"RightFooter" are NOT this bar -- they hang off L1Grid, i.e.
        // the L1 (main Quick Settings) footer, and are empty. Match the page-level Footer only.
        if (mutationType == Add && g_stage >= 2 && name[0] && wcscmp(name, L"Footer") == 0) {
            LogF("*** %ls appeared: type=[%ls] handle=%llX children=%u",
                 name, type, (unsigned long long)element.Handle, element.NumChildren);
            if (m_diag) {
                IInspectable* insp = nullptr;
                HRESULT hr = m_diag->GetIInspectableFromHandle(element.Handle, &insp);
                LogF("    GetIInspectableFromHandle hr=0x%08lX ptr=%p", (unsigned long)hr, insp);
                if (SUCCEEDED(hr) && insp) {
                    WFI::IInspectable obj{ insp, winrt::take_ownership_from_abi };
                    auto fe = obj.try_as<WUX::FrameworkElement>();
                    if (fe) {
                        LogF("    -> real element class = [%s]", ClassOf(fe).c_str());
                        try { TryInjectLater(fe, 0); }
                        catch (...) { LogF("    !! TryInjectLater threw (swallowed)"); }
                    } else {
                        LogF("    !! inspectable is not a FrameworkElement");
                    }
                }
            }
        }
        return S_OK;
    }

private:
    LONG m_ref = 1;
    IXamlDiagnostics*  m_diag = nullptr;
    IVisualTreeService* m_vts = nullptr;

public:
    static LONG g_objects;
};
LONG Tap::g_objects = 0;

// ---------------------------------------------------------------- class factory
class TapFactory : public IClassFactory
{
public:
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppv) override
    {
        if (!ppv) return E_POINTER;
        *ppv = nullptr;
        if (riid == __uuidof(IUnknown) || riid == __uuidof(IClassFactory)) {
            *ppv = static_cast<IClassFactory*>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return (ULONG)InterlockedIncrement(&m_ref); }
    ULONG STDMETHODCALLTYPE Release() override
    {
        LONG r = InterlockedDecrement(&m_ref);
        if (r == 0) delete this;
        return (ULONG)r;
    }
    HRESULT STDMETHODCALLTYPE CreateInstance(IUnknown* outer, REFIID riid, void** ppv) override
    {
        if (outer) return CLASS_E_NOAGGREGATION;
        if (!ppv) return E_POINTER;
        *ppv = nullptr;
        auto* t = new (std::nothrow) Tap();
        if (!t) return E_OUTOFMEMORY;
        HRESULT hr = t->QueryInterface(riid, ppv);
        t->Release();
        return hr;
    }
    HRESULT STDMETHODCALLTYPE LockServer(BOOL) override { return S_OK; }

private:
    LONG m_ref = 1;
};

// ---------------------------------------------------------------- exports
// Declared in combaseapi.h as WINOLEAPI (== EXTERN_C HRESULT STDAPICALLTYPE), so match that
// linkage and export explicitly from the link line (see build.cmd).
STDAPI DllGetClassObject(REFCLSID rclsid, REFIID riid, LPVOID FAR* ppv)
{
    if (!ppv) return E_POINTER;
    *ppv = nullptr;
    if (!IsEqualCLSID(rclsid, CLSID_VcxTap)) return CLASS_E_CLASSNOTAVAILABLE;
    auto* f = new (std::nothrow) TapFactory();
    if (!f) return E_OUTOFMEMORY;
    HRESULT hr = f->QueryInterface(riid, ppv);
    f->Release();
    return hr;
}

STDAPI DllCanUnloadNow(void)
{
    return Tap::g_objects == 0 ? S_OK : S_FALSE;
}

BOOL WINAPI DllMain(HMODULE self, DWORD reason, LPVOID)
{
    if (reason == DLL_PROCESS_ATTACH) {
        g_self = self;
        DisableThreadLibraryCalls(self);
        LogInit();
        InitializeCriticalSection(&g_cfgLock);
        g_cfgLockInit = true;
        g_stage = ReadStage();
        LogF("================================================================");
        LogF("vcxtap loaded: pid=%lu stage=%d", GetCurrentProcessId(), g_stage);
    }
    return TRUE;
}
