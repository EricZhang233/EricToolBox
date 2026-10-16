// ============================================================================
//  GpuMonitor.cpp —— TrafficMonitor GPU 监控插件（显存 + GPU 使用率）
//                    （TrafficMonitor-VramPlugin 的“使用率”分支）
//
//  针对官方 PluginInterface.h（API version 8，Copyright (C) Zhong Yang 2021）。
//
//  设计：
//    * **每块被勾选的显卡各生成两个显示项**（显存占用 + GPU 使用率）：
//          「显存 - NVIDIA GeForce RTX 3060 Laptop GPU」        ID=Vram_<稳定键>
//          「GPU 使用率 - NVIDIA GeForce RTX 3060 Laptop GPU」  ID=GpuUse_<稳定键>
//      ID 跨会话稳定；只想显示其中一项时，在 TrafficMonitor「选项 → 显示设置」里取消勾选即可。
//    * 配置窗口里的显卡列表是**带复选框的多选列表**（SysListView32）：勾哪块卡就监控哪块卡。
//
//  性能与睡眠（实测）：
//    * 显存 \GPU Adapter Memory(*)\Dedicated Usage：3 个实例，单次约 9 微秒。
//    * 使用率 \GPU Engine(*)\Utilization Percentage：598 个实例，单次约 0.6~1.5 毫秒，
//      默认 1 秒采一次（≈0.15% 单核），可用 INI 的 UsageIntervalMs 拉长间隔。
//    * 两者都不会唤醒独显：1 Hz / 10 Hz 轮询 30 秒，独显 100% 停在 D3。
//    * 独显睡眠时它的 Engine 实例仍在、数值为 0.00%，所以「睡眠即 0%」天然成立。
//
//  ── 编译要点 ──────────────────────────────────────────────────────────────
//   1) 依赖官方头文件 PluginInterface.h（本目录下已随包提供）。
//   2) 必须 x64；必须 /utf-8（源码含中文字符串）。
//   3) 需要编译 GpuMonitor.rc；用到 comctl32（ListView）。
// ============================================================================
#include <windows.h>
#include <commctrl.h>

#include "PluginInterface.h"
#include "GpuMonitorReader.h"
#include "resource.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cwchar>
#include <string>
#include <vector>

#pragma comment(lib, "user32.lib")
#pragma comment(lib, "comctl32.lib")

namespace
{
constexpr int kMaxItems = 16;   // 最多 8 块显卡 × 2 类显示项

// 显示项类型
enum ItemKind
{
    KIND_VRAM  = 0,   // 显存占用
    KIND_USAGE = 1,   // GPU 使用率
};

// 显存项的显示内容
enum VramShowMode
{
    VRAM_SHOW_USED    = 0,
    VRAM_SHOW_PERCENT = 1,
    VRAM_SHOW_BOTH    = 2,
};

const wchar_t* const kIniSection          = L"General";
const wchar_t* const kIniKeyAdapters      = L"Adapters";         // "00010C9B,0000F836" / "-" / 空 = 默认
const wchar_t* const kIniKeyUsageInterval = L"UsageIntervalMs";  // GPU 使用率采样间隔（毫秒）
const wchar_t* const kIniKeyUnit          = L"Unit";             // 0=自动 1=MB 2=GB
const wchar_t* const kIniKeyUsedDisplay   = L"UsedDisplay";      // 0=已用数 1=百分比 2=两者
const wchar_t* const kIniKeyTooltipName   = L"TooltipShowName";  // 1/0

// 落盘文件名（1.4.0 起由 VramMonitor.* 更名为 GpuMonitor.*，不做旧名兼容）
const wchar_t* const kIniFileName = L"GpuMonitor.ini";
const wchar_t* const kLogFileName = L"GpuMonitor.log";

class CVramPlugin;

// 仅用于 GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS) 取本 DLL 的 HMODULE
void ModuleAnchor() {}

HMODULE SelfModule()
{
    HMODULE self = nullptr;
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                       GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                       reinterpret_cast<LPCWSTR>(&ModuleAnchor), &self);
    return self;
}

std::wstring VendorLabel(UINT vendorId)
{
    switch (vendorId)
    {
    case 0x10DE: return L"NVIDIA";
    case 0x1002: return L"AMD";
    case 0x8086: return L"Intel";
    case 0x1414: return L"Microsoft";
    default:
        {
            wchar_t buf[32] = {};
            swprintf_s(buf, L"GPU 0x%04X", vendorId);
            return buf;
        }
    }
}

// ---------------------------------------------------------------------------
//  单个显示项
// ---------------------------------------------------------------------------
class CVramItem : public IPluginItem
{
public:
    CVramItem(CVramPlugin* owner, int index) : m_owner(owner), m_index(index) {}

    const wchar_t* GetItemName() const override;
    const wchar_t* GetItemId() const override;
    const wchar_t* GetItemLableText() const override;
    const wchar_t* GetItemValueText() const override;
    const wchar_t* GetItemValueSampleText() const override;
    int            IsDrawResourceUsageGraph() const override;
    float          GetResourceUsageGraphValue() const override;

private:
    CVramPlugin* m_owner;
    int          m_index;
};

// ---------------------------------------------------------------------------
//  插件本体
// ---------------------------------------------------------------------------
class CVramPlugin : public ITMPlugin
{
public:
    IPluginItem* GetItem(int index) override
    {
        // 宿主打开「显示设置」时会先枚举 GetItem()，可能早于第一次 DataRequired()
        EnsureInit();

        if (index < 0 || index >= m_itemCount)
            return nullptr;
        return &m_items[index];
    }

    void DataRequired() override
    {
        EnsureInit();

        // 1) 显存（便宜，每次都要）
        const bool memOk = m_reader.Refresh();

        // 2) GPU 使用率（贵，按 UsageIntervalMs 限频）
        if (m_reader.IsUsageEnabled() && m_usageIntervalMs > 0)
        {
            const ULONGLONG now = ::GetTickCount64();
            if (m_lastUsageTick == 0 ||
                (now - m_lastUsageTick) >= static_cast<ULONGLONG>(m_usageIntervalMs))
            {
                m_reader.RefreshUsage();
                m_lastUsageTick = now;
            }
        }

        for (int i = 0; i < m_itemCount; ++i)
        {
            const UINT luid = m_itemMeta[i].luid;

            if (m_itemMeta[i].kind == KIND_USAGE)
            {
                // 独显睡眠 / 没有引擎活动时这里是 0
                const double gpu = m_reader.GetGpuUsagePercent(luid);

                wchar_t buf[32] = {};
                swprintf_s(buf, L"%.0f%%", gpu);
                m_itemValues[i] = buf;
                m_itemGraph[i]  = static_cast<float>(gpu / 100.0);
                continue;
            }

            // 显存项
            if (!memOk)
            {
                m_itemValues[i] = L"N/A";
                m_itemGraph[i]  = 0.0f;
                continue;
            }

            uint64_t used = 0;
            m_reader.GetUsage(luid, used);
            const double pct    = m_reader.GetUsagePercent(luid);
            const bool   hasPct = (pct >= 0.0);

            wchar_t pctText[32] = {};
            if (hasPct)
                swprintf_s(pctText, L"%.0f%%", pct);

            const std::wstring usedText = CVramReader::FormatBytes(used, m_unit);

            switch (m_usedDisplay)
            {
            case VRAM_SHOW_PERCENT:
                m_itemValues[i] = hasPct ? pctText : L"N/A";
                break;
            case VRAM_SHOW_BOTH:
                if (hasPct)
                {
                    wchar_t both[96] = {};
                    swprintf_s(both, L"%ls (%ls)", usedText.c_str(), pctText);
                    m_itemValues[i] = both;
                }
                else
                {
                    m_itemValues[i] = usedText;
                }
                break;
            default:
                m_itemValues[i] = usedText;
                break;
            }

            m_itemGraph[i] = hasPct ? static_cast<float>(pct / 100.0) : 0.0f;
        }

        if (memOk)
            BuildTooltip();
        else
            m_tooltip = L"GPU 监控：读取失败";
    }

    const wchar_t* GetInfo(PluginInfoIndex index) override
    {
        switch (index)
        {
        case TMI_NAME:        return L"GPU 监控";
        case TMI_DESCRIPTION: return L"每块显卡的显存占用与 GPU 使用率（Windows 性能计数器）。"
                                     L"设置里打勾的显卡才会显示；不唤醒休眠中的 GPU，睡眠时使用率为 0%。";
        case TMI_AUTHOR:      return L"Eric / Clawrin";
        case TMI_COPYRIGHT:   return L"MIT License";
        case TMI_VERSION:     return L"1.4.0";
        case TMI_URL:         return L"";
        case TMI_MAX:         return L"";
        default:              return L"";
        }
    }

    void OnExtenedInfo(ExtendedInfoIndex index, const wchar_t* data) override
    {
        // 官方头文件里的拼写就是 ExtenedInfo（少一个 d）
        if (index == EI_CONFIG_DIR && data != nullptr)
            m_configDir = data;
    }

    void OnInitialize(ITrafficMonitor* pApp) override
    {
        m_pApp = pApp;
        EnsureInit();
    }

    const wchar_t* GetTooltipInfo() override
    {
        return m_tooltip.c_str();
    }

    OptionReturn ShowOptionsDialog(void* hParent) override
    {
        EnsureInit();
        m_dialogChanged = false;

        INITCOMMONCONTROLSEX icc = {};
        icc.dwSize = sizeof(icc);
        icc.dwICC  = ICC_LISTVIEW_CLASSES;
        ::InitCommonControlsEx(&icc);

        ::DialogBoxParamW(SelfModule(), MAKEINTRESOURCEW(IDD_VRAM_OPTIONS),
                          reinterpret_cast<HWND>(hParent),
                          &CVramPlugin::OptionsDlgProc, reinterpret_cast<LPARAM>(this));

        return m_dialogChanged ? OR_OPTION_CHANGED : OR_OPTION_UNCHANGED;
    }

    // ---------------- 供 CVramItem 使用 ----------------
    const std::wstring& ItemName(int index)   const { return m_itemMeta[index].name; }
    const std::wstring& ItemId(int index)     const { return m_itemMeta[index].id; }
    const std::wstring& ItemLabel(int index)  const { return m_itemMeta[index].label; }
    const std::wstring& ItemSample(int index) const { return m_itemMeta[index].sample; }
    const std::wstring& ItemValue(int index)  const { return m_itemValues[index]; }
    float ItemGraph(int index) const { return m_itemGraph[index]; }
    ItemKind ItemType(int index) const { return m_itemMeta[index].kind; }
    int   ShowMode() const { return m_usedDisplay; }

private:
    struct ItemMeta
    {
        std::wstring name;
        std::wstring id;
        std::wstring label;
        std::wstring sample;
        ItemKind     kind = KIND_VRAM;
        UINT         luid = 0;
    };

    // ---------------- 初始化 ----------------
    void EnsureInit()
    {
        if (m_inited)
            return;
        m_inited = true;

        LoadSettings(IniPath());
        m_reader.Init(true);
        RebuildItems();
        WriteDiagnosticLog();
    }

    // 兼容旧版 INI：8 位十六进制（旧格式存的是 LUID，重启后会失效）
    static bool IsLegacyLuidKey(const std::wstring& key)
    {
        if (key.size() != 8)
            return false;
        for (size_t i = 0; i < key.size(); ++i)
        {
            const wchar_t c = key[i];
            const bool hex = (c >= L'0' && c <= L'9') || (c >= L'a' && c <= L'f') || (c >= L'A' && c <= L'F');
            if (!hex)
                return false;
        }
        return true;
    }

    bool IsMonitoredAdapter(const VramAdapterInfo& a) const
    {
        if (!m_adaptersConfigured)
            return a.dedicatedVideoMemory > 0;   // 默认：有独立显存的都监控

        for (const auto& key : m_selectedKeys)
        {
            if (key == a.stableKey)
                return true;
            if (IsLegacyLuidKey(key) && a.luidLow == static_cast<UINT>(wcstoul(key.c_str(), nullptr, 16)))
                return true;
        }
        return false;
    }

    static int VendorRank(UINT vendorId)
    {
        switch (vendorId)
        {
        case 0x10DE: return 0;   // NVIDIA
        case 0x1002: return 1;   // AMD
        case 0x8086: return 2;   // Intel
        case 0x1414: return 3;   // Microsoft
        default:     return 4;
        }
    }

    // ---------- 重复适配器去重 ----------
    // 有些虚拟显示/串流软件（本机是 GameViewer 的间接显示驱动 IDD）会让 DXGI 多枚举出一个
    // 与真实显卡**完全同型号**的适配器对象。它与真卡的区别是：
    //     它在 GPU 性能计数器（\GPU Adapter Memory(*)）里**从来没有实例**，
    //     也没有任何输出（EnumOutputs 为空）。
    // 判据只用"有没有计数器实例"这一条，并且**只在同硬件键里存在有实例的成员时才去重**：
    // 真装两块同型号显卡时两块都会有自己的实例，因此不会被误删；
    // 系统整体没有 GPU 计数器时（全部无实例），也一律保留，宁可多显示。

    // 去掉 reader 给"同型号多卡"加的 -2/-3 后缀，得到同组判据
    static std::wstring BaseHardwareKey(const std::wstring& key)
    {
        const size_t pos = key.find_last_of(L'-');
        if (pos == std::wstring::npos || pos + 1 >= key.size())
            return key;

        for (size_t i = pos + 1; i < key.size(); ++i)
        {
            if (key[i] < L'0' || key[i] > L'9')
                return key;     // 后缀不是纯数字，不当作分组后缀
        }
        return key.substr(0, pos);
    }

    bool AdapterHasCounters(const VramAdapterInfo& a) const
    {
        uint64_t used = 0;
        return m_reader.GetUsage(a.luidLow, used);
    }

    // 自己没实例、但存在同硬件键且有实例的兄弟 → 判定为虚拟显示派生出来的重复项
    bool IsCounterlessDuplicate(const VramAdapterInfo& a) const
    {
        if (AdapterHasCounters(a))
            return false;

        const std::wstring base = BaseHardwareKey(a.stableKey);
        for (const auto& b : m_reader.GetAdapters())
        {
            if (b.luidLow == a.luidLow)
                continue;
            if (BaseHardwareKey(b.stableKey) != base)
                continue;
            if (AdapterHasCounters(b))
                return true;
        }
        return false;
    }

    void RebuildItems()
    {
        m_itemCount = 0;

        // 收集要监控的适配器（顺带剔除虚拟显示派生出来的重复项），
        // 并按「厂商优先级 + 稳定键」排序，这样显示项顺序跨重启不变
        std::vector<const VramAdapterInfo*> monitored;
        m_skippedDuplicates.clear();

        for (const auto& a : m_reader.GetAdapters())
        {
            if (!IsMonitoredAdapter(a))
                continue;

            if (IsCounterlessDuplicate(a))
            {
                m_skippedDuplicates.push_back(a.name + L" [Key " + a.stableKey + L"]");
                continue;   // 与真卡同型号但没有 GPU 计数器实例 → 跳过
            }
            monitored.push_back(&a);
        }

        // 配置里指定过显卡，但一块都没匹配上（例如旧版 INI 存的是重启前的 LUID）：
        // 退回默认（所有有独立显存的适配器），避免重启后"一个显示项都没有"
        if (monitored.empty() && m_adaptersConfigured && !m_selectedKeys.empty())
        {
            m_configuredButUnmatched = true;
            for (const auto& a : m_reader.GetAdapters())
            {
                if (a.dedicatedVideoMemory > 0 && !IsCounterlessDuplicate(a))
                    monitored.push_back(&a);
            }
        }
        else
        {
            m_configuredButUnmatched = false;
        }

        std::sort(monitored.begin(), monitored.end(),
                  [](const VramAdapterInfo* x, const VramAdapterInfo* y)
                  {
                      const int rx = VendorRank(x->vendorId);
                      const int ry = VendorRank(y->vendorId);
                      if (rx != ry)
                          return rx < ry;
                      return x->stableKey < y->stableKey;
                  });

        for (const VramAdapterInfo* pa : monitored)
        {
            const VramAdapterInfo& a = *pa;

            // 显存项
            if (m_itemCount < kMaxItems)
            {
                ItemMeta meta;
                meta.kind  = KIND_VRAM;
                meta.luid  = a.luidLow;
                meta.name  = std::wstring(L"显存 - ") + a.name;
                meta.label = VendorLabel(a.vendorId);
                {
                    wchar_t id[96] = {};
                    swprintf_s(id, L"Vram_%ls", a.stableKey.c_str());
                    meta.id = id;
                }
                m_itemMeta[m_itemCount]    = meta;
                m_itemValues[m_itemCount]  = L"N/A";
                m_itemGraph[m_itemCount]   = 0.0f;
                ++m_itemCount;
            }

            // GPU 使用率项
            if (m_itemCount < kMaxItems)
            {
                ItemMeta meta;
                meta.kind  = KIND_USAGE;
                meta.luid  = a.luidLow;
                meta.name  = std::wstring(L"GPU 使用率 - ") + a.name;
                meta.label = VendorLabel(a.vendorId) + L" GPU";
                {
                    wchar_t id[96] = {};
                    swprintf_s(id, L"GpuUse_%ls", a.stableKey.c_str());
                    meta.id = id;
                }
                m_itemMeta[m_itemCount]    = meta;
                m_itemValues[m_itemCount]  = L"N/A";
                m_itemGraph[m_itemCount]   = 0.0f;
                ++m_itemCount;
            }
        }

        UpdateSamples();
    }

    void UpdateSamples()
    {
        const bool gb = (m_unit == VRAM_UNIT_GB);
        const wchar_t* bytesSample = gb ? L"0.00 GB" : L"0000 MB";

        for (int i = 0; i < kMaxItems; ++i)
        {
            if (m_itemMeta[i].kind == KIND_USAGE)
            {
                m_itemMeta[i].sample = L"100%";
                continue;
            }

            switch (m_usedDisplay)
            {
            case VRAM_SHOW_PERCENT: m_itemMeta[i].sample = L"100%"; break;
            case VRAM_SHOW_BOTH:    m_itemMeta[i].sample = gb ? L"0.00 GB (100%)" : L"0000 MB (100%)"; break;
            default:                m_itemMeta[i].sample = bytesSample; break;
            }
        }
    }

    void BuildTooltip()
    {
        std::wstring tip;

        for (const auto& a : m_reader.GetAdapters())
        {
            if (!IsMonitoredAdapter(a))
                continue;

            uint64_t used = 0;
            m_reader.GetUsage(a.luidLow, used);
            const double pct = m_reader.GetUsagePercent(a.luidLow);
            const double gpu = m_reader.GetGpuUsagePercent(a.luidLow);

            const unsigned long long usedMb  = static_cast<unsigned long long>(used / (1024ULL * 1024ULL));
            const unsigned long long totalMb = static_cast<unsigned long long>(a.dedicatedVideoMemory / (1024ULL * 1024ULL));

            wchar_t pctSuffix[40] = {};
            if (pct >= 0.0)
                swprintf_s(pctSuffix, L" (%.0f%%)", pct);

            wchar_t line[384] = {};
            swprintf_s(line, L"显存 %llu / %llu MB%ls · GPU %.0f%%", usedMb, totalMb, pctSuffix, gpu);

            if (!tip.empty())
                tip += L"\r\n";

            if (m_tooltipShowName && !a.name.empty())
                tip += a.name + L"\r\n";

            tip += line;
        }

        if (tip.empty())
            tip = L"GPU 监控：未选择显卡（请在插件设置里打勾）";

        m_tooltip = tip;
    }

    // ---------------- 配置读写 ----------------
    std::wstring ConfigDir() const
    {
        if (!m_configDir.empty())
            return m_configDir;

        if (m_pApp != nullptr)
        {
            const wchar_t* dir = m_pApp->GetPluginConfigDir();
            if (dir != nullptr && dir[0] != L'\0')
                return dir;
        }

        wchar_t path[MAX_PATH] = {};
        if (::GetModuleFileNameW(SelfModule(), path, MAX_PATH) == 0)
            return std::wstring();

        std::wstring dir = path;
        const size_t pos = dir.find_last_of(L'\\');
        return (pos == std::wstring::npos) ? std::wstring() : dir.substr(0, pos);
    }

    static std::wstring ModuleDir()
    {
        wchar_t path[MAX_PATH] = {};
        if (::GetModuleFileNameW(SelfModule(), path, MAX_PATH) == 0)
            return std::wstring();

        std::wstring dir = path;
        const size_t pos = dir.find_last_of(L'\\');
        return (pos == std::wstring::npos) ? std::wstring() : dir.substr(0, pos);
    }

    static bool FileExists(const std::wstring& path)
    {
        if (path.empty())
            return false;
        const DWORD attr = ::GetFileAttributesW(path.c_str());
        return (attr != INVALID_FILE_ATTRIBUTES) && ((attr & FILE_ATTRIBUTE_DIRECTORY) == 0);
    }

    static std::wstring JoinFile(const std::wstring& dir, const wchar_t* fileName)
    {
        if (dir.empty())
            return std::wstring();

        std::wstring p = dir;
        if (p.back() != L'\\' && p.back() != L'/')
            p += L'\\';
        p += fileName;
        return p;
    }

    // 配置文件位置要"粘住"：优先用已经存在的那份（宿主的插件配置目录 或 DLL 所在目录），
    // 都没有才用宿主给的配置目录 —— 避免因为目录解析变化导致重启后读不到旧配置
    std::wstring IniPath() const
    {
        const std::wstring primary = JoinFile(ConfigDir(), kIniFileName);
        const std::wstring secondary = JoinFile(ModuleDir(), kIniFileName);

        if (FileExists(primary))
            return primary;
        if (FileExists(secondary))
            return secondary;
        return primary.empty() ? secondary : primary;
    }

    void LoadSettings(const std::wstring& iniPath)
    {
        if (iniPath.empty())
            return;

        wchar_t buf[256] = {};

        // 要监控的显卡：空/不存在 = 默认（所有有独立显存的适配器）；"-" = 一个都不选
        // 键格式是跨重启稳定的硬件标识（如 10DE2560_3A8017AA）；旧版 INI 里的 8 位 LUID 也兼容
        ::GetPrivateProfileStringW(kIniSection, kIniKeyAdapters, L"", buf, _countof(buf), iniPath.c_str());
        m_adaptersConfigured = false;
        m_selectedKeys.clear();
        if (buf[0] != L'\0')
        {
            m_adaptersConfigured = true;
            if (wcscmp(buf, L"-") != 0)
            {
                wchar_t* ctx = nullptr;
                for (wchar_t* tok = wcstok_s(buf, L",", &ctx); tok != nullptr; tok = wcstok_s(nullptr, L",", &ctx))
                {
                    std::wstring key = tok;
                    while (!key.empty() && (key.front() == L' ' || key.front() == L'\t'))
                        key.erase(key.begin());
                    while (!key.empty() && (key.back() == L' ' || key.back() == L'\t'))
                        key.pop_back();
                    if (!key.empty())
                        m_selectedKeys.push_back(key);
                }
            }
        }

        ::GetPrivateProfileStringW(kIniSection, kIniKeyUsageInterval, L"1000", buf, _countof(buf), iniPath.c_str());
        m_usageIntervalMs = _wtoi(buf);
        if (m_usageIntervalMs < 200)     m_usageIntervalMs = 200;
        if (m_usageIntervalMs > 60000)   m_usageIntervalMs = 60000;

        ::GetPrivateProfileStringW(kIniSection, kIniKeyUnit, L"0", buf, _countof(buf), iniPath.c_str());
        m_unit = _wtoi(buf);
        if (m_unit < VRAM_UNIT_AUTO || m_unit > VRAM_UNIT_GB)
            m_unit = VRAM_UNIT_AUTO;

        ::GetPrivateProfileStringW(kIniSection, kIniKeyUsedDisplay, L"0", buf, _countof(buf), iniPath.c_str());
        m_usedDisplay = _wtoi(buf);
        if (m_usedDisplay < VRAM_SHOW_USED || m_usedDisplay > VRAM_SHOW_BOTH)
            m_usedDisplay = VRAM_SHOW_USED;

        ::GetPrivateProfileStringW(kIniSection, kIniKeyTooltipName, L"1", buf, _countof(buf), iniPath.c_str());
        m_tooltipShowName = (_wtoi(buf) != 0);
    }

    void SaveSettings() const
    {
        const std::wstring iniPath = IniPath();
        if (iniPath.empty())
            return;

        std::wstring adapters;
        if (m_adaptersConfigured)
        {
            if (m_selectedKeys.empty())
            {
                adapters = L"-";
            }
            else
            {
                for (size_t i = 0; i < m_selectedKeys.size(); ++i)
                {
                    if (i > 0)
                        adapters += L',';
                    adapters += m_selectedKeys[i];
                }
            }
        }
        ::WritePrivateProfileStringW(kIniSection, kIniKeyAdapters, adapters.c_str(), iniPath.c_str());

        wchar_t buf[32] = {};

        swprintf_s(buf, L"%d", m_usageIntervalMs);
        ::WritePrivateProfileStringW(kIniSection, kIniKeyUsageInterval, buf, iniPath.c_str());

        swprintf_s(buf, L"%d", m_unit);
        ::WritePrivateProfileStringW(kIniSection, kIniKeyUnit, buf, iniPath.c_str());

        swprintf_s(buf, L"%d", m_usedDisplay);
        ::WritePrivateProfileStringW(kIniSection, kIniKeyUsedDisplay, buf, iniPath.c_str());

        ::WritePrivateProfileStringW(kIniSection, kIniKeyTooltipName, m_tooltipShowName ? L"1" : L"0", iniPath.c_str());
    }

    // ---------------- 诊断日志 ----------------
    static void WriteAllTextUtf16(const std::wstring& path, const std::wstring& text)
    {
        HANDLE h = ::CreateFileW(path.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr,
                                CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (h == INVALID_HANDLE_VALUE)
            return;

        const wchar_t bom = 0xFEFF;
        DWORD written = 0;
        ::WriteFile(h, &bom, sizeof(bom), &written, nullptr);
        ::WriteFile(h, text.c_str(), static_cast<DWORD>(text.size() * sizeof(wchar_t)), &written, nullptr);
        ::CloseHandle(h);
    }

    void WriteDiagnosticLog() const
    {
        const std::wstring dir = ConfigDir();
        if (dir.empty())
            return;

        std::wstring path = dir;
        if (path.back() != L'\\' && path.back() != L'/')
            path += L'\\';
        path += kLogFileName;

        wchar_t buf[512] = {};
        std::wstring log = L"GPU 监控插件 1.4.0\n";

        log += L"配置目录: " + dir + L"\n";
        log += L"配置文件: " + IniPath() + L"\n";
        swprintf_s(buf, L"显存计数器: %ls\n", m_reader.GetLastErrorText().empty() ? L"正常" : m_reader.GetLastErrorText().c_str());
        log += buf;
        swprintf_s(buf, L"GPU 使用率计数器: %ls（采样间隔 %d ms，每块显卡一个显示项）\n",
                   m_reader.IsUsageEnabled() ? L"已启用" : L"未启用", m_usageIntervalMs);
        log += buf;

        swprintf_s(buf, L"枚举到 %u 块适配器:\n", static_cast<unsigned>(m_reader.GetAdapters().size()));
        log += buf;

        for (const auto& a : m_reader.GetAdapters())
        {
            swprintf_s(buf, L"    Key=%ls  LUID 0x%08X  厂商 0x%04X  显存 %llu MB  %ls  ->  %ls\n",
                       a.stableKey.c_str(), a.luidLow, a.vendorId,
                       static_cast<unsigned long long>(a.dedicatedVideoMemory / (1024ULL * 1024ULL)),
                       a.name.c_str(),
                       IsMonitoredAdapter(a) ? L"监控" : L"不监控");
            log += buf;
        }

        if (!m_adaptersConfigured)
        {
            log += L"选择来源: 默认（所有有独立显存的适配器）\n";
        }
        else if (m_selectedKeys.empty())
        {
            log += L"选择来源: 配置里一个都没勾\n";
        }
        else
        {
            log += L"选择来源: 配置 Adapters=";
            for (size_t i = 0; i < m_selectedKeys.size(); ++i)
            {
                if (i > 0)
                    log += L',';
                log += m_selectedKeys[i];
            }
            if (m_configuredButUnmatched)
                log += L"  （这些键当前一块都没匹配上，已临时退回默认全选；请在设置里重新勾选一次以写入新键）";
            log += L"\n";
        }

        swprintf_s(buf, L"生成显示项 %d 个（每块勾选的显卡各 2 项：显存 + 使用率）:\n", m_itemCount);
        log += buf;

        for (int i = 0; i < m_itemCount; ++i)
        {
            swprintf_s(buf, L"    [%d] [%ls] %ls  (ID=%ls)\n", i,
                       (m_itemMeta[i].kind == KIND_USAGE) ? L"使用率" : L"显存",
                       m_itemMeta[i].name.c_str(), m_itemMeta[i].id.c_str());
            log += buf;
        }
        if (m_itemCount == 0)
            log += L"    （0 个：请检查显卡勾选与「生成的显示项」设置）\n";

        if (!m_skippedDuplicates.empty())
        {
            swprintf_s(buf, L"去重跳过 %u 个重复适配器（同硬件键但无 GPU 计数器实例，通常是虚拟显示驱动派生）：\n",
                       static_cast<unsigned>(m_skippedDuplicates.size()));
            log += buf;
            for (const auto& s : m_skippedDuplicates)
                log += L"    " + s + L"\n";
        }

        WriteAllTextUtf16(path, log);
    }

    // ---------------- 配置窗口 ----------------
    static INT_PTR CALLBACK OptionsDlgProc(HWND hDlg, UINT msg, WPARAM wParam, LPARAM lParam)
    {
        CVramPlugin* self = reinterpret_cast<CVramPlugin*>(::GetWindowLongPtrW(hDlg, GWLP_USERDATA));

        switch (msg)
        {
        case WM_INITDIALOG:
            self = reinterpret_cast<CVramPlugin*>(lParam);
            ::SetWindowLongPtrW(hDlg, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
            if (self != nullptr)
                self->DialogInit(hDlg);
            return TRUE;

        case WM_COMMAND:
            if (self == nullptr)
                break;
            switch (LOWORD(wParam))
            {
            case IDC_BTN_REFRESH:
                self->DialogFillAdapters(hDlg, true);
                return TRUE;
            case IDOK:
                self->DialogApply(hDlg);
                ::EndDialog(hDlg, IDOK);
                return TRUE;
            case IDCANCEL:
                ::EndDialog(hDlg, IDCANCEL);
                return TRUE;
            default:
                break;
            }
            return FALSE;

        case WM_CLOSE:
            ::EndDialog(hDlg, IDCANCEL);
            return TRUE;

        default:
            break;
        }
        return FALSE;
    }

    // 只负责把一句提示压进控件宽度：放不下就逐字截断加省略号。
    // 返回的是"估算结果"，调用方还会用实测宽度复核一次（见 SetFittedDlgItemText）。
    static std::wstring FitTextToWidth(HFONT font, int maxWidth, const std::wstring& text)
    {
        if (maxWidth <= 0)
            return text;

        HDC hdc = ::GetDC(nullptr);
        if (hdc == nullptr)
            return text;

        HGDIOBJ old = font != nullptr ? ::SelectObject(hdc, font) : nullptr;

        std::wstring result;
        for (;;)
        {
            SIZE sz = {};
            const bool measured =
                (::GetTextExtentPoint32W(hdc, text.c_str(), static_cast<int>(text.size()), &sz) != FALSE);
            if (measured && sz.cx <= maxWidth)
            {
                result = text;
                break;
            }

            // 逐字回退，找到能放下的最长前缀，再加省略号
            std::wstring stem;
            for (size_t i = 1; i <= text.size(); ++i)
            {
                SIZE s = {};
                if (!::GetTextExtentPoint32W(hdc, text.c_str(), static_cast<int>(i), &s))
                    break;
                if (s.cx > maxWidth)
                    break;
                stem.assign(text, 0, i);
            }
            while (!stem.empty() && stem.back() == L' ')
                stem.pop_back();

            if (stem.empty())
            {
                // 连一个字符都放不下（控件被压得极窄）：只能留空，避免溢出边框
                result.clear();
                break;
            }
            result = stem + L"…";
            break;
        }

        if (old != nullptr)
            ::SelectObject(hdc, old);
        ::ReleaseDC(nullptr, hdc);
        return result;
    }

    // 按控件实际像素宽度压入文本，并在写入后实测复核：
    // 仍然偏宽就每轮再让出 4px 收紧，直到真的放得下（最多 6 轮）。
    // 10px 初始余量覆盖 static 控件自身的内缩与高 DPI 取整误差。
    static void SetFittedDlgItemText(HWND hDlg, int id, const std::wstring& text)
    {
        HWND hCtl = ::GetDlgItem(hDlg, id);
        if (hCtl == nullptr)
            return;

        RECT rc = {};
        ::GetWindowRect(hCtl, &rc);
        const int controlWidth = rc.right - rc.left;
        const int reserve = (GetWindowLongPtrW(hCtl, GWL_STYLE) & SS_TYPEMASK) == SS_LEFT ? 6 : 4;
        int maxWidth = controlWidth - 10;

        if (controlWidth <= 0)
        {
            ::SetWindowTextW(hCtl, text.c_str());
            return;
        }

        const HFONT font = reinterpret_cast<HFONT>(::SendMessageW(hCtl, WM_GETFONT, 0, 0));
        std::wstring fitted = FitTextToWidth(font, maxWidth, text);

        HDC hdc = ::GetDC(hCtl);
        if (hdc != nullptr)
        {
            HGDIOBJ old = font != nullptr ? ::SelectObject(hdc, font) : nullptr;
            for (int attempt = 0; attempt < 6; ++attempt)
            {
                SIZE sz = {};
                if (!::GetTextExtentPoint32W(hdc, fitted.c_str(), static_cast<int>(fitted.size()), &sz))
                    break;
                if (sz.cx + reserve <= controlWidth)
                    break;   // 实测放得下
                maxWidth -= 4;
                if (maxWidth <= 0)
                    break;
                fitted = FitTextToWidth(font, maxWidth, text);
            }
            if (old != nullptr)
                ::SelectObject(hdc, old);
            ::ReleaseDC(hCtl, hdc);
        }

        ::SetWindowTextW(hCtl, fitted.c_str());
    }

    void DialogInit(HWND hDlg)
    {
        ::SetWindowTextW(hDlg, L"GPU 监控 - 设置");
        ::SetDlgItemTextW(hDlg, IDC_GRP_ADAPTER,        L"要监控的显卡（打勾 = 监控这块卡，可多选）");
        ::SetDlgItemTextW(hDlg, IDC_BTN_REFRESH,        L"刷新列表(&R)");
        ::SetDlgItemTextW(hDlg, IDC_STATIC_HINT,        L"打勾的显卡会各生成两个显示项：显存占用 + GPU 使用率。");

        ::SetDlgItemTextW(hDlg, IDC_GRP_USED,           L"显存显示内容");
        ::SetDlgItemTextW(hDlg, IDC_RADIO_USED_MB,      L"已用数");
        ::SetDlgItemTextW(hDlg, IDC_RADIO_USED_PCT,     L"百分比");
        ::SetDlgItemTextW(hDlg, IDC_RADIO_USED_BOTH,    L"已用数 + 百分比");

        ::SetDlgItemTextW(hDlg, IDC_GRP_UNIT,           L"显示单位");
        ::SetDlgItemTextW(hDlg, IDC_RADIO_UNIT_AUTO,    L"自动");
        ::SetDlgItemTextW(hDlg, IDC_RADIO_UNIT_MB,      L"固定 MB");
        ::SetDlgItemTextW(hDlg, IDC_RADIO_UNIT_GB,      L"固定 GB");

        ::SetDlgItemTextW(hDlg, IDC_CHECK_TOOLTIP_NAME, L"鼠标提示中显示显卡名称");
        ::SetDlgItemTextW(hDlg, IDOK,                   L"确定");
        ::SetDlgItemTextW(hDlg, IDCANCEL,               L"取消");

        // 说明文字按控件实际宽度压排（超宽就截断加省略号，不会溢出边框）
        SetFittedDlgItemText(hDlg, IDC_GRP_ADAPTER,  L"要监控的显卡（打勾 = 监控这块卡，可多选）");
        SetFittedDlgItemText(hDlg, IDC_STATIC_HINT,  L"打勾的卡各生成两个显示项");
        SetFittedDlgItemText(hDlg, IDC_STATIC_HINT2, std::wstring(L"显示哪些项目请在「选项 → 显示设置」里再勾选；GPU 使用率采样间隔见 ") + kIniFileName + L" 的 UsageIntervalMs。");
        SetFittedDlgItemText(hDlg, IDC_STATIC_HINT3, std::wstring(L"诊断日志：") + kLogFileName + L"（每次初始化覆盖写入，UTF-16）。");

        const int usedId  = (m_usedDisplay == VRAM_SHOW_PERCENT) ? IDC_RADIO_USED_PCT
                          : (m_usedDisplay == VRAM_SHOW_BOTH)    ? IDC_RADIO_USED_BOTH
                                                                 : IDC_RADIO_USED_MB;
        ::CheckRadioButton(hDlg, IDC_RADIO_USED_MB, IDC_RADIO_USED_BOTH, usedId);

        const int unitId = (m_unit == VRAM_UNIT_MB) ? IDC_RADIO_UNIT_MB
                         : (m_unit == VRAM_UNIT_GB) ? IDC_RADIO_UNIT_GB
                                                    : IDC_RADIO_UNIT_AUTO;
        ::CheckRadioButton(hDlg, IDC_RADIO_UNIT_AUTO, IDC_RADIO_UNIT_GB, unitId);

        ::CheckDlgButton(hDlg, IDC_CHECK_TOOLTIP_NAME, m_tooltipShowName ? BST_CHECKED : BST_UNCHECKED);

        HWND hLV = ::GetDlgItem(hDlg, IDC_LIST_ADAPTER);
        if (hLV != nullptr)
        {
            ListView_SetExtendedListViewStyle(hLV, LVS_EX_CHECKBOXES | LVS_EX_FULLROWSELECT);

            RECT rc = {};
            ::GetClientRect(hLV, &rc);

            LVCOLUMNW col = {};
            col.mask     = LVCF_TEXT | LVCF_WIDTH | LVCF_SUBITEM;
            col.pszText  = const_cast<LPWSTR>(L"显卡");
            col.cx       = (rc.right - rc.left) - 6;
            col.iSubItem = 0;
            ::SendMessageW(hLV, LVM_INSERTCOLUMNW, 0, reinterpret_cast<LPARAM>(&col));
        }

        DialogFillAdapters(hDlg, true);
    }

    void DialogFillAdapters(HWND hDlg, bool reenumerate)
    {
        if (reenumerate)
        {
            std::vector<VramAdapterInfo> list;
            CVramReader::EnumerateAdapters(list);
            m_dlgAdapters.swap(list);
        }

        HWND hLV = ::GetDlgItem(hDlg, IDC_LIST_ADAPTER);
        if (hLV == nullptr)
            return;

        ::SendMessageW(hLV, LVM_DELETEALLITEMS, 0, 0);

        int row = 0;
        for (const auto& a : m_dlgAdapters)
        {
            wchar_t text[420] = {};
            swprintf_s(text, L"%ls   [Key %ls]   %llu MB%ls", a.name.c_str(), a.stableKey.c_str(),
                       static_cast<unsigned long long>(a.dedicatedVideoMemory / (1024ULL * 1024ULL)),
                       IsCounterlessDuplicate(a) ? L"   （无 GPU 计数器实例：虚拟显示派生，已自动忽略）" : L"");

            LVITEMW item = {};
            item.mask    = LVIF_TEXT | LVIF_PARAM;
            item.iItem   = row;
            item.pszText = text;
            item.lParam  = static_cast<LPARAM>(row);   // 行号 = m_dlgAdapters 下标

            const int idx = static_cast<int>(::SendMessageW(hLV, LVM_INSERTITEMW, 0, reinterpret_cast<LPARAM>(&item)));
            if (idx < 0)
                continue;

            ListView_SetCheckState(hLV, idx, IsMonitoredAdapter(a) ? TRUE : FALSE);
            ++row;
        }
    }

    void DialogApply(HWND hDlg)
    {
        std::vector<std::wstring> checkedKeys;
        HWND hLV = ::GetDlgItem(hDlg, IDC_LIST_ADAPTER);
        if (hLV != nullptr)
        {
            const int n = static_cast<int>(::SendMessageW(hLV, LVM_GETITEMCOUNT, 0, 0));
            for (int i = 0; i < n; ++i)
            {
                if (ListView_GetCheckState(hLV, i) <= 0)
                    continue;

                // ListView 没有 LVM_GETITEMDATA 这条消息，取 lParam 要用 LVM_GETITEMW + LVIF_PARAM
                LVITEMW item = {};
                item.mask  = LVIF_PARAM;
                item.iItem = i;
                if (::SendMessageW(hLV, LVM_GETITEMW, 0, reinterpret_cast<LPARAM>(&item)) == 0)
                    continue;

                const size_t idx = static_cast<size_t>(item.lParam);
                if (idx >= m_dlgAdapters.size())
                    continue;
                if (IsCounterlessDuplicate(m_dlgAdapters[idx]))
                    continue;   // 虚拟显示派生项，勾了也不会生成显示项
                checkedKeys.push_back(m_dlgAdapters[idx].stableKey);
            }
        }

        int newUsedDisplay = VRAM_SHOW_USED;
        if (::IsDlgButtonChecked(hDlg, IDC_RADIO_USED_PCT) == BST_CHECKED)
            newUsedDisplay = VRAM_SHOW_PERCENT;
        else if (::IsDlgButtonChecked(hDlg, IDC_RADIO_USED_BOTH) == BST_CHECKED)
            newUsedDisplay = VRAM_SHOW_BOTH;

        int newUnit = VRAM_UNIT_AUTO;
        if (::IsDlgButtonChecked(hDlg, IDC_RADIO_UNIT_MB) == BST_CHECKED)
            newUnit = VRAM_UNIT_MB;
        else if (::IsDlgButtonChecked(hDlg, IDC_RADIO_UNIT_GB) == BST_CHECKED)
            newUnit = VRAM_UNIT_GB;

        const bool newTooltipName = (::IsDlgButtonChecked(hDlg, IDC_CHECK_TOOLTIP_NAME) == BST_CHECKED);

        const bool adaptersChanged = (!m_adaptersConfigured) || (checkedKeys != m_selectedKeys);
        const bool optionsChanged  = (newUsedDisplay != m_usedDisplay) ||
                                     (newUnit != m_unit) ||
                                     (newTooltipName != m_tooltipShowName);

        if (!adaptersChanged && !optionsChanged)
        {
            m_dialogChanged = false;
            return;
        }

        m_adaptersConfigured = true;
        m_selectedKeys       = checkedKeys;
        m_usedDisplay        = newUsedDisplay;
        m_unit               = newUnit;
        m_tooltipShowName    = newTooltipName;

        SaveSettings();

        // 重新枚举适配器并按新的勾选重建显示项（每块卡 = 显存 + 使用率两项）
        m_reader.Init(true);
        RebuildItems();
        m_lastUsageTick = 0;

        m_dialogChanged = true;
    }

    // ---------------- 数据成员 ----------------
    CVramReader      m_reader;
    ITrafficMonitor* m_pApp = nullptr;

    bool m_inited             = false;
    bool m_dialogChanged      = false;
    bool m_adaptersConfigured = false;
    bool m_tooltipShowName    = true;
    int  m_unit               = VRAM_UNIT_AUTO;
    int  m_usedDisplay        = VRAM_SHOW_USED;
    int  m_usageIntervalMs    = 1000;
    ULONGLONG m_lastUsageTick = 0;

    std::vector<std::wstring> m_selectedKeys;    // 勾选的显卡（稳定键）
    std::vector<VramAdapterInfo> m_dlgAdapters;
    std::vector<std::wstring> m_skippedDuplicates; // 被去重跳过的重复适配器（写进日志）
    bool m_configuredButUnmatched = false;       // 配置里的键一个都没匹配上

    int  m_itemCount = 0;
    ItemMeta m_itemMeta[kMaxItems];
    std::wstring m_itemValues[kMaxItems];
    float m_itemGraph[kMaxItems] = {};

    std::wstring m_configDir;
    std::wstring m_tooltip = L"GPU 监控";

    CVramItem m_items[kMaxItems] =
    {
        CVramItem(this, 0),  CVramItem(this, 1),  CVramItem(this, 2),  CVramItem(this, 3),
        CVramItem(this, 4),  CVramItem(this, 5),  CVramItem(this, 6),  CVramItem(this, 7),
        CVramItem(this, 8),  CVramItem(this, 9),  CVramItem(this, 10), CVramItem(this, 11),
        CVramItem(this, 12), CVramItem(this, 13), CVramItem(this, 14), CVramItem(this, 15),
    };
};

const wchar_t* CVramItem::GetItemName() const   { return m_owner->ItemName(m_index).c_str(); }
const wchar_t* CVramItem::GetItemId() const     { return m_owner->ItemId(m_index).c_str(); }
const wchar_t* CVramItem::GetItemLableText() const { return m_owner->ItemLabel(m_index).c_str(); }
const wchar_t* CVramItem::GetItemValueText() const { return m_owner->ItemValue(m_index).c_str(); }
const wchar_t* CVramItem::GetItemValueSampleText() const { return m_owner->ItemSample(m_index).c_str(); }

// GPU 使用率项始终提供占用图；显存项只在显示百分比时提供
int CVramItem::IsDrawResourceUsageGraph() const
{
    if (m_owner->ItemType(m_index) == KIND_USAGE)
        return 1;
    return (m_owner->ShowMode() == VRAM_SHOW_USED) ? 0 : 1;
}

float CVramItem::GetResourceUsageGraphValue() const
{
    return m_owner->ItemGraph(m_index);
}

} // namespace

// ---------------------------------------------------------------------------
//  插件导出入口（官方头文件要求：ITMPlugin* TMPluginGetInstance();）
// ---------------------------------------------------------------------------
extern "C" __declspec(dllexport) ITMPlugin* TMPluginGetInstance()
{
    static CVramPlugin instance;
    return &instance;
}

#ifdef GPU_MONITOR_LAYOUT_TEST
// ---------------------------------------------------------------------------
//  仅自检构建（LayoutCheck 用）：用插件自己的对话框过程把配置对话框建出来。
//  走的是和宿主完全一样的入口（CreateDialogParamW + OptionsDlgProc + this），
//  但用非模态方式，好让自检工具能枚举控件、量尺寸。
//  正常发布的 GpuMonitor.dll 不含这个导出。
// ---------------------------------------------------------------------------
extern "C" __declspec(dllexport) HWND GpuMonitorTestCreateOptionsDialog(HWND hParent)
{
    auto* plugin = reinterpret_cast<CVramPlugin*>(TMPluginGetInstance());
    return ::CreateDialogParamW(SelfModule(), MAKEINTRESOURCEW(IDD_VRAM_OPTIONS), hParent,
                                &CVramPlugin::OptionsDlgProc, reinterpret_cast<LPARAM>(plugin));
}

// 自检用：等价于点「确定」，可以验证 DialogApply 也不会把控件挤出边界
extern "C" __declspec(dllexport) void GpuMonitorTestAcceptOptionsDialog(HWND hDlg)
{
    if (hDlg != nullptr)
        ::SendMessageW(hDlg, WM_COMMAND, MAKEWPARAM(IDOK, BN_CLICKED), 0);
}
#endif

BOOL APIENTRY DllMain(HMODULE hModule, DWORD reason, LPVOID reserved)
{
    UNREFERENCED_PARAMETER(hModule);
    UNREFERENCED_PARAMETER(reason);
    UNREFERENCED_PARAMETER(reserved);
    return TRUE;
}
