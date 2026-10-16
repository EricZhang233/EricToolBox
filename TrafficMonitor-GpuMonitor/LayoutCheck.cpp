// ============================================================================
//  LayoutCheck.cpp —— 开发期版面自检工具（EXCLUDE_FROM_ALL，不随插件发布）
//
//  做法：把 GpuMonitor.dll 里的 IDD_VRAM_OPTIONS 真正创建出来（隐藏、不显示）：
//      CreateDialogParamW 会把模板里的对话框过程装到对话框上（dlgproc 就来自模板），
//      然后手动补一条 WM_INITDIALOG，让插件的 DialogInit 完整执行，
//      于是中文文字、控件尺寸都和真实运行时一致。随后逐个枚举子控件，检查：
//          1) 是否完整落在对话框客户区内（越界 = 用户看到的“元素超界”）；
//          2) 非分组框控件之间是否互相重叠；
//          3) 带文字的控件，文字宽度是否超过控件宽度（会被右端裁掉）。
//
//  用法：LayoutCheck.exe <GpuMonitor.dll 的完整路径>
// ============================================================================
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <commctrl.h>

#include <cstdio>
#include <cwchar>
#include <clocale>
#include <string>
#include <vector>

#pragma comment(lib, "user32.lib")
#pragma comment(lib, "comctl32.lib")

namespace
{
constexpr int kDialogId = 101;   // IDD_VRAM_OPTIONS

struct ChildInfo
{
    HWND         hwnd  = nullptr;
    int          id    = 0;
    bool         group = false;
    std::wstring cls;
    std::wstring text;
    RECT         rc    = {};   // 对话框客户区坐标
};

std::wstring GetClassNameOf(HWND h)
{
    wchar_t buf[128] = {};
    ::GetClassNameW(h, buf, _countof(buf));
    return buf;
}

// 不依赖 GetWindowTextLengthW：GroupBox / Static 在对话框未显示时会返回 0，
// 直接给固定缓冲读一次更可靠（这正是先前误判"文字为空"的原因）。
std::wstring GetTextOf(HWND h)
{
    wchar_t buf[2048] = {};
    const int got = ::GetWindowTextW(h, buf, _countof(buf));
    return (got > 0) ? std::wstring(buf, static_cast<size_t>(got)) : std::wstring();
}

std::vector<ChildInfo> CollectChildren(HWND dlg)
{
    std::vector<ChildInfo> out;
    for (HWND c = ::GetWindow(dlg, GW_CHILD); c != nullptr; c = ::GetWindow(c, GW_HWNDNEXT))
    {
        ChildInfo info;
        info.hwnd  = c;
        info.id    = ::GetDlgCtrlID(c);
        info.cls   = GetClassNameOf(c);
        info.text  = GetTextOf(c);
        info.group = (info.cls == L"Button") &&
                     ((::GetWindowLongPtrW(c, GWL_STYLE) & BS_TYPEMASK) == BS_GROUPBOX);

        RECT rc = {};
        ::GetWindowRect(c, &rc);
        POINT tl = { rc.left, rc.top };
        POINT br = { rc.right, rc.bottom };
        ::ScreenToClient(dlg, &tl);
        ::ScreenToClient(dlg, &br);
        info.rc = { tl.x, tl.y, br.x, br.y };

        out.push_back(info);
    }
    return out;
}

std::wstring Shorten(const std::wstring& s, size_t maxChars = 30)
{
    if (s.size() <= maxChars)
        return s;
    return s.substr(0, maxChars) + L"…";
}
} // namespace

int wmain(int argc, wchar_t** argv)
{
    // 没有这一行，wprintf 会在遇到非 ASCII 宽字符（中文提示）时提前截断输出
    ::setlocale(LC_ALL, "");
    ::SetConsoleOutputCP(CP_UTF8);

    if (argc < 2)
    {
        wprintf(L"用法: LayoutCheck.exe <GpuMonitorLayoutTest.dll 路径>\n");
        return 2;
    }

    // 必须用常规 LoadLibrary：LOAD_LIBRARY_AS_IMAGE_RESOURCE 返回的是伪句柄，
    // GetProcAddress 对它无效（GetModuleFileName 也会失败）。
    HMODULE mod = ::LoadLibraryW(argv[1]);
    if (mod == nullptr)
    {
        wprintf(L"[错误] 无法加载 %ls (GetLastError=%lu)\n", argv[1], ::GetLastError());
        return 1;
    }

    // 用插件自己的对话框过程建对话框（和宿主同一条路径），DialogInit 会完整执行
    using CreateFn = HWND(__cdecl*)(HWND);
    auto createDialog = reinterpret_cast<CreateFn>(::GetProcAddress(mod, "GpuMonitorTestCreateOptionsDialog"));
    if (createDialog == nullptr)
    {
        wchar_t full[MAX_PATH] = {};
        ::GetModuleFileNameW(mod, full, _countof(full));
        wprintf(L"[错误] 取不到 GpuMonitorTestCreateOptionsDialog 导出 (GetLastError=%lu)\n", ::GetLastError());
        wprintf(L"        实际加载: \"%ls\"\n", full);
        wprintf(L"        该 DLL 必须是用 GPU_MONITOR_LAYOUT_TEST 构建的 GpuMonitorLayoutTest.dll。\n");
        return 1;
    }

    INITCOMMONCONTROLSEX icc = {};
    icc.dwSize = sizeof(icc);
    icc.dwICC  = ICC_LISTVIEW_CLASSES;
    ::InitCommonControlsEx(&icc);

    HWND dlg = createDialog(nullptr);
    if (dlg == nullptr)
    {
        wprintf(L"[错误] 创建对话框失败 (GetLastError=%lu)\n", ::GetLastError());
        return 1;
    }

    RECT client = {};
    ::GetClientRect(dlg, &client);

    HDC hdc = ::GetDC(dlg);
    const std::vector<ChildInfo> children = CollectChildren(dlg);

    wprintf(L"对话框客户区: %ld x %ld 像素；子控件 %zu 个\n",
            client.right - client.left, client.bottom - client.top, children.size());
    wprintf(L"%-14ls %5ls %-9ls %-9ls %-34ls %ls\n",
            L"类", L"ID", L"位置", L"尺寸", L"文字", L"判定");
    wprintf(L"--------------------------------------------------------------------------------\n");

    int outOfBounds = 0;
    int overlapping = 0;
    int clipped     = 0;

    for (size_t i = 0; i < children.size(); ++i)
    {
        const ChildInfo& c = children[i];
        const int w = c.rc.right - c.rc.left;
        const int h = c.rc.bottom - c.rc.top;

        const bool oob = (c.rc.left < client.left) || (c.rc.top < client.top) ||
                         (c.rc.right > client.right) || (c.rc.bottom > client.bottom);

        bool overlap = false;
        if (!c.group && c.cls != L"SysListView32")
        {
            for (size_t k = 0; k < children.size() && !overlap; ++k)
            {
                if (k == i)
                    continue;
                const ChildInfo& o = children[k];
                if (o.group || o.cls == L"SysListView32")
                    continue;   // 分组框/列表天然包含别的控件，不算重叠
                overlap = (c.rc.left < o.rc.right) && (o.rc.left < c.rc.right) &&
                          (c.rc.top < o.rc.bottom) && (o.rc.top < c.rc.bottom);
            }
        }

        bool textClipped = false;
        long textWidth = 0;
        if (!c.text.empty())
        {
            HFONT font = reinterpret_cast<HFONT>(::SendMessageW(c.hwnd, WM_GETFONT, 0, 0));
            HGDIOBJ old = font != nullptr ? ::SelectObject(hdc, font) : nullptr;
            SIZE sz = {};
            if (::GetTextExtentPoint32W(hdc, c.text.c_str(), static_cast<int>(c.text.size()), &sz))
            {
                textWidth = sz.cx;
                textClipped = (sz.cx + 6 > w);
            }
            if (old != nullptr)
                ::SelectObject(hdc, old);
        }

        wchar_t pos[32] = {};
        swprintf_s(pos, L"%ld,%ld", c.rc.left, c.rc.top);
        wchar_t dim[32] = {};
        swprintf_s(dim, L"%dx%d", w, h);

        wprintf(L"%-14ls %5d %-9ls %-9ls %-34ls %ls%ls%ls\n",
                c.group ? L"GroupBox" : c.cls.c_str(), c.id, pos, dim,
                Shorten(c.text).c_str(),
                oob ? L"[越界]" : L"",
                overlap ? L"[重叠]" : L"",
                textClipped ? L"[文字被裁]" : L"");

        if (textClipped)
            wprintf(L"                 ^ 文字 %ld px > 可用 %d px\n", textWidth, w - 6);

        if (oob)         ++outOfBounds;
        if (overlap)     ++overlapping;
        if (textClipped) ++clipped;
    }

    ::ReleaseDC(dlg, hdc);
    ::DestroyWindow(dlg);
    ::FreeLibrary(mod);

    wprintf(L"--------------------------------------------------------------------------------\n");
    const bool pass = (outOfBounds == 0) && (overlapping == 0) && (clipped == 0);
    wprintf(L"结论: 越界 %d 个，重叠 %d 个，文字被裁 %d 个 -> %ls\n",
            outOfBounds, overlapping, clipped, pass ? L"通过" : L"不通过");
    return pass ? 0 : 1;
}
