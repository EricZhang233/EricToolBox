// ============================================================================
//  GpuMonitorTest.cpp —— 独立测试程序（不需要 TrafficMonitor）
//
//  用途：在开发机上先验证读取是否正常，并和 nvidia-smi / 任务管理器对拍。
//        会列出所有适配器，然后每秒打印一次每块适配器的显存与 GPU 使用率。
//
//  用法：
//      GpuMonitorTest.exe            每秒打印一次，共 10 次
//      GpuMonitorTest.exe 60         每秒打印一次，共 60 次
//      GpuMonitorTest.exe 60 noun    不使用率（只测显存）
// ============================================================================
#include <windows.h>

#include "GpuMonitorReader.h"

#include <cstdio>
#include <cstdlib>
#include <cwchar>

namespace
{
unsigned long long ToMb(uint64_t bytes)
{
    return static_cast<unsigned long long>(bytes / (1024ULL * 1024ULL));
}
}

int wmain(int argc, wchar_t** argv)
{
    const int  seconds     = (argc > 1) ? _wtoi(argv[1]) : 10;
    const bool enableUsage = !(argc > 2 && _wcsicmp(argv[2], L"noun") == 0);

    CVramReader reader;
    if (!reader.Init(enableUsage))
    {
        wprintf(L"[错误] 初始化失败: %ls\n", reader.GetLastErrorText().c_str());
        wprintf(L"提示：若提示找不到 GPU 计数器，说明该系统没有 \\GPU Adapter Memory 计数器。\n");
        return 1;
    }

    wprintf(L"枚举到的适配器：\n");
    for (const auto& a : reader.GetAdapters())
    {
        wprintf(L"    LUID 0x%08X  厂商 0x%04X  显存 %6llu MB  %ls\n",
                a.luidLow, a.vendorId, ToMb(a.dedicatedVideoMemory), a.name.c_str());
    }
    wprintf(L"GPU 使用率计数器：%ls\n\n", reader.IsUsageEnabled() ? L"已启用" : L"未启用");

    for (int i = 0; i < seconds; ++i)
    {
        const bool memOk = reader.Refresh();
        if (enableUsage)
            reader.RefreshUsage();

        SYSTEMTIME st = {};
        ::GetLocalTime(&st);
        wprintf(L"[%3d] %02d:%02d:%02d  %ls\n", i + 1, st.wHour, st.wMinute, st.wSecond,
                memOk ? L"" : L"(显存读取失败)");

        for (const auto& a : reader.GetAdapters())
        {
            uint64_t used = 0;
            reader.GetUsage(a.luidLow, used);
            const double pct = reader.GetUsagePercent(a.luidLow);

            wprintf(L"        %-44ls %6llu / %6llu MB", a.name.c_str(), ToMb(used), ToMb(a.dedicatedVideoMemory));
            if (pct >= 0.0)
                wprintf(L" %5.1f%%", pct);
            if (enableUsage)
                wprintf(L"   GPU %5.1f%%", reader.GetGpuUsagePercent(a.luidLow));
            wprintf(L"\n");
        }

        Sleep(1000);
    }

    return 0;
}
