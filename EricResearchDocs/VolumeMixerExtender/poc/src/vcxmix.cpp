// vcxmix.dll -- experiment: intercept ControlCenter.dll activation factories.
//
// Route A of the design (../design.md):
//   ControlCenter.* are *not* registered in HKLM\...\WindowsRuntime\ActivatableClassId,
//   so RoGetActivationFactory can't reach them -- but ControlCenter.dll exports
//   DllGetActivationFactory, and the factories it returns are singletons, i.e. the very
//   same objects the shell uses. So:
//
//     1) call DllGetActivationFactory ourselves for each ControlCenter.* class name
//     2) read the IActivationFactory vtable:  [6] = ActivateInstance
//     3) (stage >= 2) repoint vtable[6] at our detour, which logs the runtime class name
//        of whatever the shell creates
//
// IActivationFactory vtable layout (derivation):
//   IUnknown      : QueryInterface(0) AddRef(1) Release(2)
//   IInspectable  : GetIids(3) GetRuntimeClassName(4) GetTrustLevel(5)
//   IActivationFactory : ActivateInstance(6)
//
// Stages (vcxmix.ini, next to this DLL):
//   0 = load + log only
//   1 = resolve factories for the candidate class names and log their vtables   (default, safe)
//   2 = additionally patch vtable[6] and log every ActivateInstance
//
// Build: see build.cmd

#include <windows.h>
// winbase.h's GetCurrentTime() macro collides with a member name used by the C++/WinRT
// XAML headers (warning C4002) -- drop it.
#ifdef GetCurrentTime
#undef GetCurrentTime
#endif

#include <stdio.h>
#include <stdarg.h>
#include <algorithm>
#include <string>
#include <vector>

// C++/WinRT (needs the SDK's cppwinrt include dir + WindowsApp.lib -- see build.cmd).
// It is used only for the *UI* side (creating/attaching the button); the vtable patching
// below stays raw COM on purpose.
#include <winrt/base.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.UI.Core.h>
#include <winrt/Windows.UI.Xaml.h>
#include <winrt/Windows.UI.Xaml.Automation.h>
#include <winrt/Windows.UI.Xaml.Controls.h>
#include <winrt/Windows.UI.Xaml.Controls.Primitives.h>
#include <winrt/Windows.UI.Xaml.Media.h>

namespace WFI = winrt::Windows::Foundation;

// ---------------------------------------------------------------- HSTRING ABI
typedef struct HSTRING__* HSTRING;

// The HSTRING helpers live in api-ms-win-core-winrt-string-l1-1-0.dll. Resolve them at
// runtime instead of linking WindowsApp.lib, so the DLL has no extra link dependency.
typedef HRESULT(__stdcall* WindowsCreateStringFn)(const wchar_t* sourceString, UINT32 length, HSTRING* string);
typedef HRESULT(__stdcall* WindowsDeleteStringFn)(HSTRING string);
typedef const wchar_t*(__stdcall* WindowsGetStringRawBufferFn)(HSTRING string, UINT32* length);

static WindowsCreateStringFn        WinRT_CreateString = nullptr;
static WindowsDeleteStringFn        WinRT_DeleteString = nullptr;
static WindowsGetStringRawBufferFn  WinRT_GetStringRawBuffer = nullptr;

static bool LoadStringApi()
{
    const wchar_t* candidates[] = {
        L"api-ms-win-core-winrt-string-l1-1-0.dll",
        L"combase.dll",
    };
    for (const wchar_t* dll : candidates) {
        HMODULE m = GetModuleHandleW(dll);
        if (!m) m = LoadLibraryW(dll);
        if (!m) continue;
        WinRT_CreateString       = (WindowsCreateStringFn)GetProcAddress(m, "WindowsCreateString");
        WinRT_DeleteString       = (WindowsDeleteStringFn)GetProcAddress(m, "WindowsDeleteString");
        WinRT_GetStringRawBuffer = (WindowsGetStringRawBufferFn)GetProcAddress(m, "WindowsGetStringRawBuffer");
        if (WinRT_CreateString && WinRT_DeleteString && WinRT_GetStringRawBuffer) return true;
    }
    return false;
}

typedef HRESULT(__stdcall* ActivateInstanceFn)(void* self, void** instance);
typedef HRESULT(__stdcall* GetRuntimeClassNameFn)(void* self, HSTRING* name);

// vtable indices
enum { VT_GET_RUNTIME_CLASS_NAME = 4, VT_ACTIVATE_INSTANCE = 6 };

// ---------------------------------------------------------------- globals
// Using the Win32 file API rather than a CRT stream: the CRT's ccs=UTF-8 mode rejects
// narrow writes (that silently produced a BOM-only log), and CreateFileW lets us pick the
// share mode so the file stays readable while the target process holds it.
static HANDLE             g_log = INVALID_HANDLE_VALUE;
static CRITICAL_SECTION   g_logLock;
static std::wstring       g_logPath;

struct PatchEntry { void** vt; ActivateInstanceFn orig; };
static std::vector<PatchEntry> g_patched;
static CRITICAL_SECTION        g_patchLock;

// ---------------------------------------------------------------- logging
// Fixed names (independent of the DLL file name) so that re-testing with a renamed copy of
// the DLL -- which is required, because LoadLibrary on an already-loaded path is a no-op --
// still shares one ini and one log.
static std::wstring DllDir(HMODULE self)
{
    wchar_t path[MAX_PATH] = {};
    GetModuleFileNameW(self, path, MAX_PATH);
    std::wstring p(path);
    size_t slash = p.find_last_of(L'\\');
    return (slash == std::wstring::npos) ? L"." : p.substr(0, slash);
}

static void LogInit(HMODULE self)
{
    g_logPath = DllDir(self) + L"\\vcxmix.log";

    g_log = CreateFileW(g_logPath.c_str(), FILE_APPEND_DATA,
                        FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                        OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (g_log == INVALID_HANDLE_VALUE) return;

    static const char sep[] = "\r\n";
    DWORD wr = 0;
    WriteFile(g_log, sep, sizeof(sep) - 1, &wr, nullptr);

    InitializeCriticalSection(&g_logLock);
    InitializeCriticalSection(&g_patchLock);
}

static void LogF(const char* fmt, ...)
{
    if (g_log == INVALID_HANDLE_VALUE) return;

    char buf[1200];
    SYSTEMTIME st;
    GetLocalTime(&st);
    int n = _snprintf_s(buf, sizeof(buf), _TRUNCATE, "[%02d:%02d:%02d.%03d tid=%lu] ",
                        st.wHour, st.wMinute, st.wSecond, st.wMilliseconds, GetCurrentThreadId());
    if (n < 0) n = 0;

    va_list ap;
    va_start(ap, fmt);
    int m = _vsnprintf_s(buf + n, sizeof(buf) - (size_t)n, _TRUNCATE, fmt, ap);
    va_end(ap);
    if (m < 0) m = (int)strlen(buf + n);       // truncated: _TRUNCATE still NUL-terminates

    size_t len = (size_t)n + (size_t)m;
    if (len + 2 < sizeof(buf)) { buf[len++] = '\r'; buf[len++] = '\n'; }

    EnterCriticalSection(&g_logLock);
    DWORD wr = 0;
    WriteFile(g_log, buf, (DWORD)len, &wr, nullptr);
    LeaveCriticalSection(&g_logLock);
}

static void LogLine(const wchar_t* w)
{
    if (!w) return;
    char buf[1024];
    WideCharToMultiByte(CP_UTF8, 0, w, -1, buf, sizeof(buf), nullptr, nullptr);
    LogF("%s", buf);
}

// ---------------------------------------------------------------- helpers
static std::wstring ModuleOfAddress(void* p)
{
    HMODULE mod = nullptr;
    if (GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                           GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           (LPCWSTR)p, &mod) && mod) {
        wchar_t path[MAX_PATH] = {};
        GetModuleFileNameW(mod, path, MAX_PATH);
        std::wstring s(path);
        size_t slash = s.find_last_of(L'\\');
        return (slash == std::wstring::npos) ? s : s.substr(slash + 1);
    }
    return L"<unknown>";
}

static int ReadStage(HMODULE self)
{
    std::wstring ini = DllDir(self) + L"\\vcxmix.ini";
    return (int)GetPrivateProfileIntW(L"vcxmix", L"stage", 1, ini.c_str());
}

static ActivateInstanceFn FindOrig(void** vt)
{
    EnterCriticalSection(&g_patchLock);
    ActivateInstanceFn r = nullptr;
    for (size_t i = 0; i < g_patched.size(); ++i) {
        if (g_patched[i].vt == vt) { r = g_patched[i].orig; break; }
    }
    LeaveCriticalSection(&g_patchLock);
    return r;
}

// ---------------------------------------------------------------- UI side (C++/WinRT)
namespace WUX  = winrt::Windows::UI::Xaml;
namespace WUXC = winrt::Windows::UI::Xaml::Controls;
namespace WUXM = winrt::Windows::UI::Xaml::Media;
namespace WUXA = winrt::Windows::UI::Xaml::Automation;
namespace WUC  = winrt::Windows::UI::Core;

static void* g_injectedFooterAbi = nullptr;

static std::string ToUtf8(winrt::hstring const& h)
{
    std::wstring_view w = h;
    if (w.empty()) return std::string();
    int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), nullptr, 0, nullptr, nullptr);
    std::string s((size_t)n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), s.data(), n, nullptr, nullptr);
    return s;
}

static std::string ClassOf(WFI::IInspectable const& o)
{
    try { return ToUtf8(winrt::get_class_name(o)); } catch (...) { return "<err>"; }
}

static void RunWinver()
{
    LogF("   TestLink clicked -> launching winver.exe");
    STARTUPINFOW si = {};
    si.cb = sizeof(si);
    PROCESS_INFORMATION pi = {};
    wchar_t cmd[] = L"winver.exe";
    if (CreateProcessW(nullptr, cmd, nullptr, nullptr, FALSE, 0, nullptr, nullptr, &si, &pi)) {
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
    } else {
        LogF("   CreateProcessW(winver.exe) failed err=%lu", GetLastError());
    }
}

static WUX::FrameworkElement WalkForAutomationId(WUX::DependencyObject const& node,
                                                 wchar_t const* id, int depth)
{
    if (!node || depth > 40) return nullptr;
    UINT32 count = 0;
    try { count = WUXM::VisualTreeHelper::GetChildrenCount(node); } catch (...) { return nullptr; }
    for (UINT32 i = 0; i < count; ++i) {
        WUX::DependencyObject child = nullptr;
        try { child = WUXM::VisualTreeHelper::GetChild(node, i); } catch (...) { continue; }
        if (!child) continue;
        if (auto fe = child.try_as<WUX::FrameworkElement>()) {
            try {
                if (WUXA::AutomationProperties::GetAutomationId(fe) == id) return fe;
            } catch (...) {}
        }
        if (auto r = WalkForAutomationId(child, id, depth + 1)) return r;
    }
    return nullptr;
}

// The page's x:Name scope is not reachable from an arbitrary element, so try FindName on the
// page-like root first and fall back to a visual-tree walk on AutomationId.
static WUX::FrameworkElement FindFooter(WUX::FrameworkElement const& root)
{
    try {
        if (auto pg = root.try_as<WUXC::Page>()) {
            if (auto o = pg.FindName(L"Footer")) if (auto fe = o.try_as<WUX::FrameworkElement>()) return fe;
        }
        if (auto uc = root.try_as<WUXC::UserControl>()) {
            if (auto o = uc.FindName(L"Footer")) if (auto fe = o.try_as<WUX::FrameworkElement>()) return fe;
        }
    } catch (...) {}
    return WalkForAutomationId(root, L"Footer", 0);
}

static int ChildCount(WUX::FrameworkElement const& fe)
{
    try { return (int)WUXM::VisualTreeHelper::GetChildrenCount(fe); } catch (...) { return -1; }
}

// Right-align inside a horizontal StackPanel: children are laid out inline, so alignment
// properties do nothing -- push the button over with a computed left margin instead, and
// recompute whenever the footer resizes.
static void RecomputeStackMargin(WUX::FrameworkElement const& footer, WUXC::Button const& btn)
{
    double used = 0;
    if (auto panel = footer.try_as<WUXC::Panel>()) {
        for (auto const& c : panel.Children()) {
            if (c == btn) continue;
            if (auto fe = c.try_as<WUX::FrameworkElement>()) {
                double w = fe.ActualWidth();
                if (w > 0) used += w;
            }
        }
    }
    double avail = footer.ActualWidth() - used - btn.ActualWidth() - 12.0;
    if (avail < 8.0) avail = 8.0;
    btn.Margin(WUX::Thickness{ avail, 0, 12, 0 });
}

// Same look as the existing footer button: same type, and if it carries an explicit Style
// copy it (a plain implicit style is applied by XAML automatically anyway).
static WUXC::Button BuildTestLinkButton(WUXC::Button const& model)
{
    WUXC::Button btn;
    btn.Content(winrt::box_value(L"TestLink"));
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
        } catch (...) { LogF("   style copy: partially failed (kept going)"); }
    }
    btn.Click([](WFI::IInspectable const&, WUX::RoutedEventArgs const&) { RunWinver(); });
    return btn;
}

static void DoInject(WUX::FrameworkElement const& page, int attempt)
{
    auto footer = FindFooter(page);
    if (!footer) {
        if (attempt < 25) { /* scheduled again by caller */ }
        return;
    }
    if (g_injectedFooterAbi == winrt::get_abi(footer)) return;   // already done for this tree
    g_injectedFooterAbi = winrt::get_abi(footer);

    LogF("   injection: Footer = [%s] children=%d", ClassOf(footer).c_str(), ChildCount(footer));

    WUXC::Button model = nullptr;
    if (auto panel = footer.try_as<WUXC::Panel>()) {
        for (auto const& c : panel.Children()) {
            if (auto b = c.try_as<WUXC::Button>()) { model = b; break; }
        }
    }
    LogF("   injection: model button = %s", model ? ClassOf(model).c_str() : "(none)");

    WUXC::Button btn = BuildTestLinkButton(model);

    if (auto panel = footer.try_as<WUXC::Panel>()) {
        panel.Children().Append(btn);
    } else {
        LogF("   injection: Footer is not a Panel -- appending via ContentControl fallback");
        if (auto cc = footer.try_as<WUXC::ContentControl>()) cc.Content(btn);
    }

    if (footer.try_as<WUXC::Grid>()) {
        if (model) {
            try {
                WUXC::Grid::SetRow(btn, WUXC::Grid::GetRow(model));
                WUXC::Grid::SetColumn(btn, WUXC::Grid::GetColumn(model));
            } catch (...) {}
        }
        btn.HorizontalAlignment(WUX::HorizontalAlignment::Right);
        btn.VerticalAlignment(WUX::VerticalAlignment::Center);
        LogF("   injection: placed with Grid + HorizontalAlignment=Right");
    } else if (footer.try_as<WUXC::StackPanel>()) {
        btn.VerticalAlignment(WUX::VerticalAlignment::Center);
        footer.SizeChanged([footer, btn](WFI::IInspectable const&, WUX::SizeChangedEventArgs const&) {
            try { RecomputeStackMargin(footer, btn); } catch (...) {}
        });
        RecomputeStackMargin(footer, btn);
        LogF("   injection: placed with computed margin (StackPanel)");
    } else {
        btn.HorizontalAlignment(WUX::HorizontalAlignment::Right);
        btn.VerticalAlignment(WUX::VerticalAlignment::Center);
        LogF("   injection: placed with HorizontalAlignment=Right (generic)");
    }
    LogF("   injection: DONE -- 'TestLink' should be visible at the footer's right edge");
}

static void ScheduleInject(WUX::FrameworkElement const& page, int attempt)
{
    WUC::CoreDispatcher d = nullptr;
    try { d = page.Dispatcher(); } catch (...) { return; }
    if (!d) return;
    if (d.HasThreadAccess()) {
        DoInject(page, attempt);
        if (g_injectedFooterAbi == nullptr && attempt < 25) {
            // the tree may not be built yet -- try again on a later dispatcher turn
            d.RunAsync(WUC::CoreDispatcherPriority::Low, [page, attempt]() {
                ScheduleInject(page, attempt + 1);
            });
        }
        return;
    }
    d.RunAsync(WUC::CoreDispatcherPriority::Normal, [page, attempt]() {
        ScheduleInject(page, attempt);
    });
}

// Called for every object produced by a patched activation factory.
static void OnInstanceCreated(WFI::IInspectable const& obj, int stage)
{
    if (!obj) return;
    std::string cls = ClassOf(obj);
    LogF("   created instance class = [%s]", cls.c_str());

    if (stage < 3) return;

    auto fe = obj.try_as<WUX::FrameworkElement>();
    if (!fe) return;
    if (!obj.try_as<WUXC::Page>() && !obj.try_as<WUXC::UserControl>()) return;  // only page-like roots

    LogF("   page-like root detected -> scheduling button injection");
    ScheduleInject(fe, 0);
}

// ---------------------------------------------------------------- the detour
static int g_stage = 1;

static HRESULT __stdcall Hook_ActivateInstance(void* self, void** instance)
{
    LogF("   [detour] ActivateInstance ENTERED (self=%p)", self);

    ActivateInstanceFn orig = FindOrig(*(void***)self);
    if (!orig) {
        LogF("!! ActivateInstance detour fired but the original is unknown -- refusing to guess");
        return E_FAIL;
    }

    HRESULT hr = orig(self, instance);

    if (SUCCEEDED(hr) && instance && *instance) {
        // The caller owns the returned reference; AddRef before adopting it in a projected object.
        static_cast<::IUnknown*>(*instance)->AddRef();
        WFI::IInspectable obj{ *instance, winrt::take_ownership_from_abi };
        try {
            OnInstanceCreated(obj, g_stage);
        } catch (...) {
            LogF("!! OnInstanceCreated threw -- swallowed so the shell keeps working");
        }
    }
    return hr;
}

static bool PatchVtable(void** vt)
{
    if (!vt) return false;

    EnterCriticalSection(&g_patchLock);
    for (size_t i = 0; i < g_patched.size(); ++i) {
        if (g_patched[i].vt == vt) { LeaveCriticalSection(&g_patchLock); return true; } // already
    }
    LeaveCriticalSection(&g_patchLock);

    void* cur = vt[VT_ACTIVATE_INSTANCE];
    if (!cur) { LogF("   patch: vtable[6] is NULL, skipping"); return false; }

    DWORD old = 0;
    if (!VirtualProtect(&vt[VT_ACTIVATE_INSTANCE], sizeof(void*), PAGE_READWRITE, &old)) {
        LogF("   patch: VirtualProtect failed err=%lu", GetLastError());
        return false;
    }
    vt[VT_ACTIVATE_INSTANCE] = (void*)&Hook_ActivateInstance;
    DWORD tmp = 0;
    VirtualProtect(&vt[VT_ACTIVATE_INSTANCE], sizeof(void*), old, &tmp);

    EnterCriticalSection(&g_patchLock);
    PatchEntry e = { vt, (ActivateInstanceFn)cur };
    g_patched.push_back(e);
    LeaveCriticalSection(&g_patchLock);

    LogF("   patch: vtable %p ok (was %p -> detour)", vt, cur);
    return true;
}

// ---------------------------------------------------------------- candidates
// Names extracted from ControlCenter.dll's string table (it is a WinRT component DLL).
static const wchar_t* kCandidates[] = {
    L"ControlCenter.ControlCenterPage",
    L"ControlCenter.ControlCenterView",
    L"ControlCenter.ControlCenterViewModel",
    L"ControlCenter.FullScreenPage",
    L"ControlCenter.IControlCenterPage",
    L"ControlCenter.IControlCenterView",
    L"ControlCenter.IVolumeMixerList",
    L"ControlCenter.AccessibleItemContainer",
    L"ControlCenter.AsyncSlider",
    L"ControlCenter.DelegateCommand",
    L"ControlCenter.ListViewHelper",
    L"ControlCenter.MediaTransportControls",
    L"ControlCenter.EditModeContainer",
    L"ControlCenter.DevicesFlowWrapper",
    L"ControlCenter.IconScalingController",
    L"ControlCenter.QuickActionToggleButton",
};

static HSTRING MakeHString(const wchar_t* s)
{
    HSTRING h = nullptr;
    if (!WinRT_CreateString || FAILED(WinRT_CreateString(s, (UINT32)wcslen(s), &h))) return nullptr;
    return h;
}

// The hand-picked list above is only a starting point: ControlCenter.dll carries 60+ runtime
// class names. Read them straight out of the DLL image so we patch every one of them and
// don't have to guess which class is the visible page.
static std::vector<std::wstring> DiscoverClassNames(HMODULE cc)
{
    std::vector<std::wstring> out;
    wchar_t path[MAX_PATH] = {};
    GetModuleFileNameW(cc, path, MAX_PATH);

    HANDLE f = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                           nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (f == INVALID_HANDLE_VALUE) return out;

    LARGE_INTEGER sz = {};
    GetFileSizeEx(f, &sz);
    if (sz.QuadPart <= 0 || sz.QuadPart > (64 << 20)) { CloseHandle(f); return out; }

    std::vector<char> buf((size_t)sz.QuadPart);
    DWORD rd = 0;
    if (!ReadFile(f, buf.data(), (DWORD)buf.size(), &rd, nullptr)) { CloseHandle(f); return out; }
    CloseHandle(f);
    buf.resize(rd);

    static const wchar_t kPat[] = L"ControlCenter.";
    const size_t patBytes = (sizeof(kPat) / sizeof(wchar_t) - 1) * 2;
    for (size_t i = 0; i + patBytes + 2 <= buf.size(); i += 2) {
        if (memcmp(&buf[i], kPat, patBytes) != 0) continue;
        std::wstring s(kPat);
        size_t j = i + patBytes;
        while (j + 2 <= buf.size()) {
            wchar_t c = *reinterpret_cast<const wchar_t*>(&buf[j]);
            if (!(iswalnum(c) || c == L'.' || c == L'_')) break;
            s.push_back(c);
            j += 2;
        }
        if (s.size() > (sizeof(kPat) / sizeof(wchar_t) - 1)) out.push_back(s);
    }

    std::sort(out.begin(), out.end());
    out.erase(std::unique(out.begin(), out.end()), out.end());
    return out;
}

// ---------------------------------------------------------------- worker
static DWORD WINAPI Worker(LPVOID param)
{
    HMODULE self = (HMODULE)param;
    Sleep(200);                       // let the loader lock go
    LogInit(self);
    int stage = ReadStage(self);
    g_stage = stage;

    LogF("================================================================");
    LogF("vcxmix attached: pid=%lu tid=%lu stage=%d", GetCurrentProcessId(), GetCurrentThreadId(), stage);
    LogF("log file: %ls", g_logPath.c_str());

    HMODULE cc = nullptr;
    for (int i = 0; i < 300; ++i) {
        cc = GetModuleHandleW(L"ControlCenter.dll");
        if (cc) break;
        Sleep(100);
    }
    if (!cc) { LogF("ControlCenter.dll is NOT loaded (waited 30s) -- giving up"); return 0; }
    LogF("ControlCenter.dll base = %p", cc);

    if (!LoadStringApi()) {
        LogF("!! could not resolve WindowsCreateString/WindowsDeleteString -- giving up");
        return 0;
    }

    typedef HRESULT(__stdcall* DllGetActivationFactoryFn)(HSTRING, void**);
    DllGetActivationFactoryFn dgaf =
        (DllGetActivationFactoryFn)GetProcAddress(cc, "DllGetActivationFactory");
    if (!dgaf) { LogF("DllGetActivationFactory export NOT found -- giving up"); return 0; }
    LogF("DllGetActivationFactory = %p (%ls)", dgaf, ModuleOfAddress((void*)dgaf).c_str());

    if (stage < 1) { LogF("stage 0: log-only run complete"); return 0; }

    LogF("---- resolving candidate class names ----");
    std::vector<std::wstring> names = DiscoverClassNames(cc);
    for (size_t i = 0; i < _countof(kCandidates); ++i) names.push_back(kCandidates[i]);
    std::sort(names.begin(), names.end());
    names.erase(std::unique(names.begin(), names.end()), names.end());
    LogF("candidate class names: %d (auto-discovered from the DLL image + hand-picked list)",
         (int)names.size());

    int resolved = 0, patched = 0;
    for (size_t i = 0; i < names.size(); ++i) {
        const wchar_t* name = names[i].c_str();
        HSTRING hs = MakeHString(name);
        if (!hs) { LogF("  %ls : WindowsCreateString failed", name); continue; }

        void* f1 = nullptr;
        HRESULT hr = dgaf(hs, &f1);
        WinRT_DeleteString(hs);

        if (FAILED(hr) || !f1) continue;     // no factory -- stay quiet, there are many
        resolved++;

        // singleton check: ask again, compare pointers
        HSTRING hs2 = MakeHString(name);
        void* f2 = nullptr;
        if (hs2) { dgaf(hs2, &f2); WinRT_DeleteString(hs2); }
        bool singleton = (f1 == f2);

        void** vt = *(void***)f1;
        void* act = vt ? vt[VT_ACTIVATE_INSTANCE] : nullptr;
        LogF("  %ls : factory=%p singleton=%s vtable=%p vtable[6]=%p (%ls)",
             name, f1, singleton ? "yes" : "NO", vt, act, act ? ModuleOfAddress(act).c_str() : L"-");

        if (stage >= 2 && vt) {
            if (PatchVtable(vt)) patched++;
        }

        if (f2) ((void(__stdcall*)(void*))((*(void***)f2)[2]))(f2);   // Release
        ((void(__stdcall*)(void*))((*(void***)f1)[2]))(f1);           // Release
    }

    LogF("---- done: resolved=%d patched=%d ----", resolved, patched);

    // Self-test: prove the detour actually intercepts Activations. If this logs a
    // "[detour] ... ENTERED" line, the patch is live; if the shell still never hits it,
    // the shell simply does not create these objects through IActivationFactory.
    if (stage >= 2) {
        LogF("---- self-test: ActivateInstance(ControlCenter.DelegateCommand) ----");
        HSTRING hs = MakeHString(L"ControlCenter.DelegateCommand");
        void* f = nullptr;
        if (hs && SUCCEEDED(dgaf(hs, &f)) && f) {
            void* inst = nullptr;
            ActivateInstanceFn act = (ActivateInstanceFn)(*(void***)f)[VT_ACTIVATE_INSTANCE];
            LogF("   self-test: calling %p", act);
            HRESULT hr2 = act(f, &inst);
            LogF("   self-test: hr=0x%08lX instance=%p", (unsigned long)hr2, inst);
            if (inst) ((void(__stdcall*)(void*))((*(void***)inst)[2]))(inst);
            ((void(__stdcall*)(void*))((*(void***)f)[2]))(f);
        } else {
            LogF("   self-test: could not get a factory");
        }
        if (hs) WinRT_DeleteString(hs);
        LogF("---- self-test done ----");
    }
    if (stage >= 3) {
        LogF("stage 3 ON: a 'TestLink' button (click -> winver.exe) will be appended to the");
        LogF("Footer on the next page activation, styled after the existing footer button.");
    }
    LogF("now open the Quick Settings panel (Win+Ctrl+V) to see ActivateInstance traffic.");
    return 0;
}

// ---------------------------------------------------------------- entry
BOOL WINAPI DllMain(HMODULE self, DWORD reason, LPVOID)
{
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(self);
        HANDLE th = CreateThread(nullptr, 0, Worker, (LPVOID)self, 0, nullptr);
        if (th) CloseHandle(th);
    }
    return TRUE;
}
