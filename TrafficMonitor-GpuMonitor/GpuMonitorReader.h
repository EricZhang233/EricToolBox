// ============================================================================
//  GpuMonitorReader.h —— 显存 + GPU 使用率 读取引擎（每块适配器一份数据）
//
//  两个数据源（都是 Windows 性能计数器，都不唤醒 GPU）：
//    1) 显存：  \GPU Adapter Memory(*)\Dedicated Usage
//               本机 3 个实例，单次约 9 微秒。
//    2) 使用率：\GPU Engine(*)\Utilization Percentage
//               本机 598 个实例（每进程每引擎一条），单次约 0.6~1.5 毫秒，
//               所以它单独一个 query，并且可以由上层控制采样间隔。
//
//  睡眠行为（实测）：独显处于 D3 时，它的 Engine 实例仍然存在、数值全为 0.00%，
//  所以「GPU 睡眠 -> 0%」不需要额外判断；且高频轮询不会把它唤醒（30 秒 D3 100%）。
//
//  一个适配器的使用率 = 该适配器所有引擎节点里**最忙的那个**（跨进程求和后取最大值），
//  与任务管理器「GPU」的口径一致，天然落在 0~100%。
//
//  依赖：pdh.lib、dxgi.lib（DXGI 只用于枚举适配器、拿到 LUID→名称/显存容量）
// ============================================================================
#pragma once

#include <windows.h>
#include <cstdint>
#include <string>
#include <vector>

// 显示单位
enum VramUnit
{
    VRAM_UNIT_AUTO = 0,   // 自动：>= 1024 MB 显示 GB，否则显示 MB
    VRAM_UNIT_MB   = 1,   // 固定 MB
    VRAM_UNIT_GB   = 2,   // 固定 GB
};

// 一个显示适配器的静态信息（通过 DXGI 枚举得到）
struct VramAdapterInfo
{
    UINT         luidLow  = 0;
    INT          luidHigh = 0;   // 注意：LUID 每次开机都会重新分配，不能用于持久化！
    std::wstring name;
    UINT         vendorId = 0;   // 0x10DE=NVIDIA, 0x1002=AMD, 0x8086=Intel, 0x1414=Microsoft
    UINT         deviceId = 0;
    UINT         subSysId = 0;
    UINT         revision = 0;
    uint64_t     dedicatedVideoMemory = 0;

    // 跨重启稳定的硬件标识，例如 "10DE2560_3A8017AA"（厂商+设备_子系统）。
    // 显示项 ID 与 INI 的 Adapters= 都用它，这样重启后设置不会失效。
    // 同一台机器出现完全相同的多块卡时，追加 -2、-3 区分。
    std::wstring stableKey;

    bool IsNvidia() const { return vendorId == 0x10DE; }
    bool IsAmd()    const { return vendorId == 0x1002; }
};

// 某一块适配器的当前数据
struct VramAdapterUsage
{
    UINT     luidLow   = 0;
    INT      luidHigh  = 0;
    uint64_t usedBytes = 0;        // 专用显存已用（字节）
    bool     valid     = false;    // 是否出现在显存计数器实例里
    double   usagePercent = 0.0;   // GPU 使用率 0~100
    bool     usageValid   = false; // 本次是否采到使用率（没采到按 0 处理）
};

class CVramReader
{
public:
    CVramReader() = default;
    ~CVramReader();

    CVramReader(const CVramReader&) = delete;
    CVramReader& operator=(const CVramReader&) = delete;

    // 只枚举适配器，不选卡、不开计数器。配置对话框用它刷新显卡列表。
    static bool EnumerateAdapters(std::vector<VramAdapterInfo>& adapters);

    // 枚举适配器并打开计数器。enableUsage=true 时额外打开 GPU 使用率计数器。
    // 可以重复调用（= 重新初始化）。
    bool Init(bool enableUsage = true);

    // 采样显存（约 10 微秒）
    bool Refresh();

    // 采样 GPU 使用率（约 0.6~1.5 毫秒）。未启用使用率时返回 false。
    bool RefreshUsage();

    bool IsUsageEnabled() const { return m_hUsageCounter != nullptr; }

    const std::vector<VramAdapterInfo>&  GetAdapters() const { return m_adapters; }
    const std::vector<VramAdapterUsage>& GetUsages()   const { return m_usages; }

    const VramAdapterInfo* FindAdapter(UINT luidLow) const;

    bool   GetUsage(UINT luidLow, uint64_t& usedBytes) const;
    double GetUsagePercent(UINT luidLow) const;     // 显存占用率；-1 = 未知
    double GetGpuUsagePercent(UINT luidLow) const;  // GPU 使用率 0~100

    static std::wstring FormatBytes(uint64_t bytes, int unit = VRAM_UNIT_AUTO);

    const std::wstring& GetLastErrorText() const { return m_lastError; }

private:
    struct EngineAgg
    {
        UINT   adapterIndex = 0;
        UINT   engineNode   = 0;
        double sum          = 0.0;
    };

    bool EnumAdapters();
    bool OpenMemoryCounter();
    bool OpenUsageCounter();
    void CloseCounters();

    // 实例名解析
    //   显存：   luid_0x00000000_0x00010C9B_phys_0
    //   使用率： pid_1234_luid_0x00000000_0x00010C9B_phys_0_eng_3_engtype_3D
    static bool ParseLuidInstanceName(const wchar_t* instanceName, UINT& luidLow, INT& luidHigh);
    static bool ParseEngineNode(const wchar_t* instanceName, UINT& engineNode);

    std::vector<VramAdapterInfo>  m_adapters;
    std::vector<VramAdapterUsage> m_usages;
    std::vector<EngineAgg>        m_engineAgg;

    void* m_hQuery        = nullptr;   // PDH_HQUERY（显存）
    void* m_hCounter      = nullptr;   // PDH_HCOUNTER
    void* m_hUsageQuery   = nullptr;   // PDH_HQUERY（GPU 使用率）
    void* m_hUsageCounter = nullptr;   // PDH_HCOUNTER

    std::vector<BYTE> m_buffer;
    std::vector<BYTE> m_usageBuffer;

    bool         m_inited = false;
    std::wstring m_lastError;
};
