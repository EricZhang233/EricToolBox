// ============================================================================
//  GpuMonitorReader.cpp —— 显存 + GPU 使用率 读取引擎实现
//
//  计数器路径与口径见 GpuMonitorReader.h 顶部说明。
// ============================================================================
#include "GpuMonitorReader.h"

#include <pdh.h>
#include <pdhmsg.h>
#include <dxgi1_4.h>
#include <wrl/client.h>

#include <cstdio>
#include <cstdlib>
#include <cwchar>

#pragma comment(lib, "pdh.lib")
#pragma comment(lib, "dxgi.lib")

using Microsoft::WRL::ComPtr;

namespace
{
// 格式化标志必须用 PDH_FMT_DOUBLE (0x00000200)。
// 踩坑记录：写成 0x00000100 是 PDH_FMT_LONG，PDH 会只写 4 字节，
// 读 double 时得到 0 或天文数字（上半 4 字节是未初始化数据）。
const DWORD kPdhFormat = PDH_FMT_DOUBLE;

// 显存：整卡口径，实例少（本机 3 个），约 9 微秒
const wchar_t* const kMemoryCounterPath = L"\\GPU Adapter Memory(*)\\Dedicated Usage";

// GPU 使用率：实例多（本机 598 个），约 0.6~1.5 毫秒，单独一个 query 便于限频
const wchar_t* const kUsageCounterPath = L"\\GPU Engine(*)\\Utilization Percentage";
}

CVramReader::~CVramReader()
{
    CloseCounters();
}

void CVramReader::CloseCounters()
{
    if (m_hCounter != nullptr && m_hQuery != nullptr)
        PdhRemoveCounter(static_cast<PDH_HCOUNTER>(m_hCounter));
    m_hCounter = nullptr;
    if (m_hQuery != nullptr)
        PdhCloseQuery(static_cast<PDH_HQUERY>(m_hQuery));
    m_hQuery = nullptr;

    if (m_hUsageCounter != nullptr && m_hUsageQuery != nullptr)
        PdhRemoveCounter(static_cast<PDH_HCOUNTER>(m_hUsageCounter));
    m_hUsageCounter = nullptr;
    if (m_hUsageQuery != nullptr)
        PdhCloseQuery(static_cast<PDH_HQUERY>(m_hUsageQuery));
    m_hUsageQuery = nullptr;
}

bool CVramReader::EnumerateAdapters(std::vector<VramAdapterInfo>& adapters)
{
    adapters.clear();

    ComPtr<IDXGIFactory1> factory;
    HRESULT hr = CreateDXGIFactory1(IID_PPV_ARGS(&factory));
    if (FAILED(hr))
        return false;

    for (UINT i = 0; ; ++i)
    {
        ComPtr<IDXGIAdapter1> adapter;
        if (factory->EnumAdapters1(i, &adapter) == DXGI_ERROR_NOT_FOUND)
            break;

        DXGI_ADAPTER_DESC1 desc = {};
        if (SUCCEEDED(adapter->GetDesc1(&desc)))
        {
            VramAdapterInfo info;
            info.luidLow  = desc.AdapterLuid.LowPart;
            info.luidHigh = desc.AdapterLuid.HighPart;
            info.name     = desc.Description;
            info.vendorId = desc.VendorId;
            info.deviceId = desc.DeviceId;
            info.subSysId = desc.SubSysId;
            info.revision = desc.Revision;
            info.dedicatedVideoMemory = desc.DedicatedVideoMemory;
            adapters.push_back(info);
        }
    }

    // 生成跨重启稳定的 key。
    // LUID 每次开机都会重新分配（实测 0x10C9B -> 0x10BC0），所以持久化只能用硬件标识：
    //     厂商 + 设备 + 子系统，例如 10DE2560_3A8017AA
    // 同一台机器出现完全相同的多块卡时，追加 -2、-3 区分（顺序按枚举）。
    for (size_t i = 0; i < adapters.size(); ++i)
    {
        std::wstring key;
        int  dup   = 0;
        bool clash = false;
        do
        {
            wchar_t buf[80] = {};
            if (dup == 0)
                swprintf_s(buf, L"%04X%04X_%08X", adapters[i].vendorId, adapters[i].deviceId, adapters[i].subSysId);
            else
                swprintf_s(buf, L"%04X%04X_%08X-%d", adapters[i].vendorId, adapters[i].deviceId, adapters[i].subSysId, dup + 1);
            key = buf;

            clash = false;
            for (size_t k = 0; k < i; ++k)
            {
                if (adapters[k].stableKey == key)
                {
                    clash = true;
                    break;
                }
            }
            ++dup;
        } while (clash);

        adapters[i].stableKey = key;
    }

    return !adapters.empty();
}

bool CVramReader::EnumAdapters()
{
    if (!EnumerateAdapters(m_adapters))
    {
        m_lastError = L"没有枚举到任何显示适配器（CreateDXGIFactory1 / EnumAdapters1 失败）";
        return false;
    }
    return true;
}

bool CVramReader::OpenMemoryCounter()
{
    PDH_HQUERY   query   = nullptr;
    PDH_HCOUNTER counter = nullptr;

    PDH_STATUS status = PdhOpenQueryW(nullptr, 0, &query);
    if (status != ERROR_SUCCESS)
    {
        wchar_t buf[128];
        swprintf_s(buf, L"PdhOpenQuery 失败 (0x%08X)", static_cast<unsigned>(status));
        m_lastError = buf;
        return false;
    }

    status = PdhAddEnglishCounterW(query, kMemoryCounterPath, 0, &counter);
    if (status != ERROR_SUCCESS)
        status = PdhAddCounterW(query, kMemoryCounterPath, 0, &counter);

    if (status != ERROR_SUCCESS)
    {
        PdhCloseQuery(query);
        wchar_t buf[160];
        swprintf_s(buf, L"添加显存计数器失败 (0x%08X)，系统可能没有该性能计数器",
                   static_cast<unsigned>(status));
        m_lastError = buf;
        return false;
    }

    m_hQuery   = query;
    m_hCounter = counter;

    PdhCollectQueryData(query);
    PdhCollectQueryData(query);
    return true;
}

bool CVramReader::OpenUsageCounter()
{
    PDH_HQUERY   query   = nullptr;
    PDH_HCOUNTER counter = nullptr;

    PDH_STATUS status = PdhOpenQueryW(nullptr, 0, &query);
    if (status != ERROR_SUCCESS)
        return false;

    status = PdhAddEnglishCounterW(query, kUsageCounterPath, 0, &counter);
    if (status != ERROR_SUCCESS)
        status = PdhAddCounterW(query, kUsageCounterPath, 0, &counter);

    if (status != ERROR_SUCCESS)
    {
        PdhCloseQuery(query);
        return false;
    }

    m_hUsageQuery   = query;
    m_hUsageCounter = counter;

    // 使用率是速率计数器，需要两次采集才有基线
    PdhCollectQueryData(query);
    PdhCollectQueryData(query);
    return true;
}

bool CVramReader::Init(bool enableUsage)
{
    CloseCounters();
    m_usages.clear();
    m_engineAgg.clear();
    m_lastError.clear();
    m_inited = false;

    if (!EnumAdapters())
        return false;

    m_usages.reserve(m_adapters.size());
    for (const auto& a : m_adapters)
    {
        VramAdapterUsage u;
        u.luidLow  = a.luidLow;
        u.luidHigh = a.luidHigh;
        m_usages.push_back(u);
    }

    const bool memOk = OpenMemoryCounter();
    if (enableUsage)
        OpenUsageCounter();   // 失败不影响显存采集

    m_inited = true;

    if (memOk)
        Refresh();
    if (m_hUsageCounter != nullptr)
        RefreshUsage();

    return memOk;
}

bool CVramReader::Refresh()
{
    if (!m_inited)
    {
        if (!Init(true))
            return false;
    }

    if (m_hQuery == nullptr || m_hCounter == nullptr)
        return false;

    PDH_HQUERY   query   = static_cast<PDH_HQUERY>(m_hQuery);
    PDH_HCOUNTER counter = static_cast<PDH_HCOUNTER>(m_hCounter);

    PDH_STATUS status = PdhCollectQueryData(query);
    if (status != ERROR_SUCCESS)
    {
        wchar_t buf[128];
        swprintf_s(buf, L"PdhCollectQueryData 失败 (0x%08X)", static_cast<unsigned>(status));
        m_lastError = buf;
        return false;
    }

    DWORD size  = 0;
    DWORD count = 0;
    status = PdhGetFormattedCounterArrayW(counter, kPdhFormat, &size, &count, nullptr);
    if (status != PDH_MORE_DATA && status != ERROR_SUCCESS)
    {
        wchar_t buf[128];
        swprintf_s(buf, L"PdhGetFormattedCounterArray 查询缓冲失败 (0x%08X)", static_cast<unsigned>(status));
        m_lastError = buf;
        return false;
    }

    bool ok = false;
    for (int attempt = 0; attempt < 3 && !ok; ++attempt)
    {
        m_buffer.resize(size);
        DWORD bufferSize = static_cast<DWORD>(m_buffer.size());
        status = PdhGetFormattedCounterArrayW(
            counter, kPdhFormat, &bufferSize, &count,
            reinterpret_cast<PDH_FMT_COUNTERVALUE_ITEM_W*>(m_buffer.data()));

        if (status == PDH_MORE_DATA)
        {
            size = bufferSize;
            continue;
        }
        if (status != ERROR_SUCCESS)
        {
            wchar_t buf[128];
            swprintf_s(buf, L"PdhGetFormattedCounterArray 读取失败 (0x%08X)", static_cast<unsigned>(status));
            m_lastError = buf;
            return false;
        }
        ok = true;
    }
    if (!ok || m_buffer.empty())
        return false;

    for (auto& u : m_usages)
    {
        u.usedBytes = 0;
        u.valid     = false;
    }

    const PDH_FMT_COUNTERVALUE_ITEM_W* items =
        reinterpret_cast<const PDH_FMT_COUNTERVALUE_ITEM_W*>(m_buffer.data());

    for (DWORD i = 0; i < count; ++i)
    {
        if (items[i].FmtValue.CStatus != PDH_CSTATUS_VALID_DATA)
            continue;
        if (items[i].szName == nullptr)
            continue;

        UINT luidLow = 0;
        INT  luidHigh = 0;
        if (!ParseLuidInstanceName(items[i].szName, luidLow, luidHigh))
            continue;

        for (auto& u : m_usages)
        {
            if (u.luidLow == luidLow && u.luidHigh == luidHigh)
            {
                u.usedBytes = static_cast<uint64_t>(items[i].FmtValue.doubleValue + 0.5);
                u.valid     = true;
                break;
            }
        }
    }

    m_lastError.clear();
    return true;
}

bool CVramReader::RefreshUsage()
{
    if (m_hUsageQuery == nullptr || m_hUsageCounter == nullptr)
        return false;

    PDH_HQUERY   query   = static_cast<PDH_HQUERY>(m_hUsageQuery);
    PDH_HCOUNTER counter = static_cast<PDH_HCOUNTER>(m_hUsageCounter);

    PDH_STATUS status = PdhCollectQueryData(query);
    if (status != ERROR_SUCCESS)
        return false;

    DWORD size  = 0;
    DWORD count = 0;
    status = PdhGetFormattedCounterArrayW(counter, kPdhFormat, &size, &count, nullptr);
    if (status != PDH_MORE_DATA && status != ERROR_SUCCESS)
        return false;

    bool ok = false;
    for (int attempt = 0; attempt < 3 && !ok; ++attempt)
    {
        m_usageBuffer.resize(size);
        DWORD bufferSize = static_cast<DWORD>(m_usageBuffer.size());
        status = PdhGetFormattedCounterArrayW(
            counter, kPdhFormat, &bufferSize, &count,
            reinterpret_cast<PDH_FMT_COUNTERVALUE_ITEM_W*>(m_usageBuffer.data()));

        if (status == PDH_MORE_DATA)
        {
            size = bufferSize;
            continue;
        }
        if (status != ERROR_SUCCESS)
            return false;
        ok = true;
    }
    if (!ok || m_usageBuffer.empty())
        return false;

    // 全部先归零：没有实例的适配器（例如独显已休眠/无活动）就保持 0%
    for (auto& u : m_usages)
    {
        u.usagePercent = 0.0;
        u.usageValid   = false;
    }
    m_engineAgg.clear();

    const PDH_FMT_COUNTERVALUE_ITEM_W* items =
        reinterpret_cast<const PDH_FMT_COUNTERVALUE_ITEM_W*>(m_usageBuffer.data());

    for (DWORD i = 0; i < count; ++i)
    {
        if (items[i].FmtValue.CStatus != PDH_CSTATUS_VALID_DATA)
            continue;
        if (items[i].szName == nullptr)
            continue;

        UINT luidLow = 0;
        INT  luidHigh = 0;
        UINT engineNode = 0;
        if (!ParseLuidInstanceName(items[i].szName, luidLow, luidHigh))
            continue;
        if (!ParseEngineNode(items[i].szName, engineNode))
            continue;

        UINT adapterIndex = 0;
        bool foundAdapter = false;
        for (size_t k = 0; k < m_usages.size(); ++k)
        {
            if (m_usages[k].luidLow == luidLow)
            {
                adapterIndex = static_cast<UINT>(k);
                foundAdapter = true;
                break;
            }
        }
        if (!foundAdapter)
            continue;

        m_usages[adapterIndex].usageValid = true;

        // 按 (适配器, 引擎节点) 聚合，跨进程求和
        bool merged = false;
        for (auto& agg : m_engineAgg)
        {
            if (agg.adapterIndex == adapterIndex && agg.engineNode == engineNode)
            {
                agg.sum += items[i].FmtValue.doubleValue;
                merged = true;
                break;
            }
        }
        if (!merged)
        {
            EngineAgg agg;
            agg.adapterIndex = adapterIndex;
            agg.engineNode   = engineNode;
            agg.sum          = items[i].FmtValue.doubleValue;
            m_engineAgg.push_back(agg);
        }
    }

    // 一个适配器的使用率 = 最忙的那个引擎节点
    for (const auto& agg : m_engineAgg)
    {
        if (agg.adapterIndex >= m_usages.size())
            continue;

        double v = agg.sum;
        if (v < 0.0)   v = 0.0;
        if (v > 100.0) v = 100.0;

        if (v > m_usages[agg.adapterIndex].usagePercent)
            m_usages[agg.adapterIndex].usagePercent = v;
    }

    return true;
}

const VramAdapterInfo* CVramReader::FindAdapter(UINT luidLow) const
{
    for (const auto& a : m_adapters)
    {
        if (a.luidLow == luidLow)
            return &a;
    }
    return nullptr;
}

bool CVramReader::GetUsage(UINT luidLow, uint64_t& usedBytes) const
{
    for (const auto& u : m_usages)
    {
        if (u.luidLow == luidLow)
        {
            usedBytes = u.usedBytes;
            return u.valid;
        }
    }
    usedBytes = 0;
    return false;
}

double CVramReader::GetUsagePercent(UINT luidLow) const
{
    const VramAdapterInfo* info = FindAdapter(luidLow);
    if (info == nullptr || info->dedicatedVideoMemory == 0)
        return -1.0;

    uint64_t used = 0;
    GetUsage(luidLow, used);

    double pct = 100.0 * static_cast<double>(used) / static_cast<double>(info->dedicatedVideoMemory);
    if (pct < 0.0)   pct = 0.0;
    if (pct > 100.0) pct = 100.0;
    return pct;
}

double CVramReader::GetGpuUsagePercent(UINT luidLow) const
{
    for (const auto& u : m_usages)
    {
        if (u.luidLow == luidLow)
            return u.usagePercent;
    }
    return 0.0;
}

std::wstring CVramReader::FormatBytes(uint64_t bytes, int unit)
{
    wchar_t buf[64] = {};
    const double mb = static_cast<double>(bytes) / (1024.0 * 1024.0);

    switch (unit)
    {
    case VRAM_UNIT_MB:
        swprintf_s(buf, L"%.0f MB", mb);
        break;
    case VRAM_UNIT_GB:
        swprintf_s(buf, L"%.2f GB", mb / 1024.0);
        break;
    default:    // 自动
        if (mb >= 1024.0)
            swprintf_s(buf, L"%.2f GB", mb / 1024.0);
        else
            swprintf_s(buf, L"%.0f MB", mb);
        break;
    }
    return buf;
}

// 显存实例名： luid_0x00000000_0x00010C9B_phys_0
// 使用率实例名还有 pid_ 前缀，所以用 wcsstr 找 "luid_0x"
bool CVramReader::ParseLuidInstanceName(const wchar_t* instanceName, UINT& luidLow, INT& luidHigh)
{
    if (instanceName == nullptr)
        return false;

    const wchar_t* p = wcsstr(instanceName, L"luid_0x");
    if (p == nullptr)
        return false;
    p += 7;

    wchar_t* end = nullptr;
    const unsigned long long high = wcstoull(p, &end, 16);
    if (end == nullptr || end == p || *end != L'_')
        return false;

    p = end + 1;
    if (wcsncmp(p, L"0x", 2) != 0)
        return false;

    const unsigned long long low = wcstoull(p + 2, &end, 16);
    if (end == nullptr || end == p + 2)
        return false;

    luidHigh = static_cast<INT>(static_cast<uint32_t>(high));
    luidLow  = static_cast<UINT>(static_cast<uint32_t>(low));
    return true;
}

// 使用率实例名里的引擎节点号： ..._eng_3_engtype_3D
bool CVramReader::ParseEngineNode(const wchar_t* instanceName, UINT& engineNode)
{
    if (instanceName == nullptr)
        return false;

    const wchar_t* p = wcsstr(instanceName, L"_eng_");
    if (p == nullptr)
        return false;
    p += 5;

    if (*p < L'0' || *p > L'9')
        return false;

    engineNode = static_cast<UINT>(wcstoul(p, nullptr, 10));
    return true;
}
