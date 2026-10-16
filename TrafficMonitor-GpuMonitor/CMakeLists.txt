cmake_minimum_required(VERSION 3.15)
project(TrafficMonitorGpuMonitor CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 配置对话框用到了 .rc 资源
if(WIN32)
    enable_language(RC)
endif()

if(MSVC)
    # /utf-8：源码含中文字符串，不加会乱码
    # /wd4100：静音官方 PluginInterface.h 里默认实现的未引用参数警告
    add_compile_options(/utf-8 /W4 /wd4100)
endif()

# 官方头文件 PluginInterface.h 就在本目录（1.4.0 起从 include\ 移到了根目录）
set(PLUGIN_SDK_DIR "${CMAKE_CURRENT_SOURCE_DIR}")

# ---------------- 插件 DLL（输出 GpuMonitor.dll）----------------
add_library(GpuMonitor SHARED
    GpuMonitor.cpp
    GpuMonitorReader.cpp
    GpuMonitor.rc
)
target_include_directories(GpuMonitor PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${PLUGIN_SDK_DIR}"
)
target_link_libraries(GpuMonitor PRIVATE pdh dxgi user32 comctl32)

# 装到 TrafficMonitor\plugins\ 下时叫什么都可以；
# 注意：这是“显存 + GPU 使用率”分支，和只做显存的 VramMonitor.dll 不要同时放进 plugins
set_target_properties(GpuMonitor PROPERTIES
    OUTPUT_NAME "GpuMonitor"
    PREFIX ""
)

# ---------------- 独立测试程序（不需要 TrafficMonitor） ----------------
add_executable(GpuMonitorTest
    GpuMonitorTest.cpp
    GpuMonitorReader.cpp
)
target_include_directories(GpuMonitorTest PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(GpuMonitorTest PRIVATE pdh dxgi)

# ---------------- 开发期版面自检（EXCLUDE_FROM_ALL，不随插件发布）----------------
# GPU_MONITOR_LAYOUT_TEST 会额外导出一个"用插件自己的过程建配置对话框"的入口，
# 供 LayoutCheck 把对话框真正建出来量控件尺寸。
add_library(GpuMonitorLayoutTest SHARED EXCLUDE_FROM_ALL
    GpuMonitor.cpp
    GpuMonitorReader.cpp
    GpuMonitor.rc
)
target_compile_definitions(GpuMonitorLayoutTest PRIVATE GPU_MONITOR_LAYOUT_TEST)
target_include_directories(GpuMonitorLayoutTest PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${PLUGIN_SDK_DIR}"
)
target_link_libraries(GpuMonitorLayoutTest PRIVATE pdh dxgi user32 comctl32)
set_target_properties(GpuMonitorLayoutTest PROPERTIES
    PREFIX ""
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/layouttest"
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/layouttest"
)

# 把 GpuMonitor.dll 里的对话框真正建出来，检查控件是否越界/重叠/文字被裁。
add_executable(LayoutCheck EXCLUDE_FROM_ALL
    LayoutCheck.cpp
)
target_compile_options(LayoutCheck PRIVATE /utf-8)
target_link_libraries(LayoutCheck PRIVATE user32 comctl32)
add_dependencies(LayoutCheck GpuMonitorLayoutTest)
