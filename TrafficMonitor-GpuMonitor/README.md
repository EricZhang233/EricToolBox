# TrafficMonitor GPU 监控插件（GpuMonitor）

> 这是 **TrafficMonitor-VramPlugin（只做显存）的使用率分支**：在原有显存显示的基础上，
> 增加**每块显卡的 GPU 使用率**显示项。两个插件二选一安装即可（DLL 名分别是 GpuMonitor / VramMonitor）。

给 [TrafficMonitor](https://github.com/zhongyang219/TrafficMonitor) 增加
「显存占用」+「GPU 使用率」显示项与专用配置窗口。

- 作者：Eric / Clawrin
- 许可：MIT
- 目标宿主：TrafficMonitor V1.86 x64（插件接口 **API version 8**）
- 数据源（都是 Windows 性能计数器，**都不唤醒 GPU**）：
  - 显存：`\GPU Adapter Memory(*)\Dedicated Usage`（任务管理器「专用 GPU 内存」同源，整卡口径）
  - 使用率：`\GPU Engine(*)\Utilization Percentage`（任务管理器「GPU」同源）

## 显示项：勾一块卡 = 两个显示项

**在插件设置里勾选显卡就够了**：每块打勾的显卡会同时生成「显存占用」和「GPU 使用率」两个显示项，
再在 TrafficMonitor「选项 → 显示设置」里勾选要显示的具体项（不想看哪项就取消勾选）：

| 显示项（名称） | ID | 内容 | 示例值 |
|---|---|---|---|
| `显存 - NVIDIA GeForce RTX 3060 Laptop GPU` | `Vram_<LUID>` | 可配置：已用数 / 百分比 / 两者 | `1645 MB` / `27%` |
| `GPU 使用率 - NVIDIA GeForce RTX 3060 Laptop GPU` | `GpuUse_<LUID>` | 使用率 | `15%` |
| `显存 - AMD Radeon(TM) Graphics` | `Vram_<LUID>` | 同上 | `690 MB` |
| `GPU 使用率 - AMD Radeon(TM) Graphics` | `GpuUse_<LUID>` | 同上 | `3%` |

- ID 跨会话稳定，显示设置里改过的标签/勾选不会丢。
- 默认标签：显存项用厂商名（`NVIDIA` / `AMD`），使用率项用 `NVIDIA GPU` / `AMD GPU`。
- 两项都向**任务栏资源占用图**提供数值（使用率项始终提供；显存项在显示百分比时提供）。
- 鼠标提示按显卡分组：`显存 1645 / 5994 MB (27%) · GPU 15%`。

## GPU 睡眠时为什么是 0%

实测（本机 RTX 3060 Laptop，独显处于 D3）：

- `\GPU Engine(*)\Utilization Percentage` 里属于独显的 28 条实例**依然存在，数值全是 `0.00%`**；
- 1 Hz 与 10 Hz 轮询 30 秒，独显 **D3 占比 100%**（D0 = 0 次采样）——轮询不会把它唤醒。

所以「GPU 睡眠 → 0%」是计数器本身给的，不需要额外判定；反过来，只要有进程在用独显，
该适配器就会立刻出现非 0 值。

## 开销（实测）

| 计数器 | 实例数 | 单次读取 | 默认频率 | 折合 CPU |
|---|---|---|---|---|
| 显存 `GPU Adapter Memory(*)` | 3 | **9.0 µs** | 每个刷新周期 | ≈0.001% |
| 使用率 `GPU Engine(*)` | **598** | **614 µs**（1 Hz 场景 1.25~1.5 ms） | 1 秒（可调） | ≈0.15% 单核 |

两个计数器各自独立 query：显存**每次都采**，使用率**按 `UsageIntervalMs` 限频**（默认 1000 ms）。
想更省就在 INI 里把它改成 2000 / 5000（此时使用率项的数值更新会变慢，但显示项仍然在）。

## 配置窗口（选项 → 插件 → GPU 监控 → 设置）

- **要监控的显卡（可多选）**：带复选框的列表，来自 DXGI 实时枚举（`显卡名 [LUID 0x........] 显存容量`）；
  打勾的显卡各生成「显存 + GPU 使用率」两个显示项，显卡启用/禁用后点「刷新列表」。
- **显存显示内容**：已用数 / 百分比 / 已用数 + 百分比。
- **显示单位**：自动（≥1024 MB 显示 GB）/ 固定 MB / 固定 GB。
- **鼠标提示中显示显卡名称**。

设置写入 `<配置目录>\GpuMonitor.ini`：

```ini
[General]
; 要监控的显卡，逗号分隔的 LUID 低 32 位（十六进制）
;   不写 / 留空 = 默认（所有有独立显存的适配器）；"-" = 一个都不监控
Adapters=00010C9B,0000F836
UsageIntervalMs=1000      ; GPU 使用率采样间隔（毫秒，200~60000）
UsedDisplay=0             ; 显存显示内容：0=已用数 1=百分比 2=已用数+百分比
Unit=0                    ; 0=自动 1=固定MB 2=固定GB
TooltipShowName=1         ; 鼠标提示里显示显卡名称
```

## 目录结构

```
GpuMonitor.cpp       插件本体（ITMPlugin / IPluginItem / 配置对话框）
GpuMonitor.rc        配置对话框模板（纯 ASCII，中文界面文字在代码里设置）
resource.h           对话框与控件 ID
GpuMonitorReader.h/.cpp  显存 + GPU 使用率 读取引擎（PDH + DXGI 枚举），可单独复用
GpuMonitorTest.cpp   独立控制台测试程序，不需要 TrafficMonitor
LayoutCheck.cpp      开发期版面自检工具（见下），不随插件发布
CMakeLists.txt       构建脚本（输出 GpuMonitor.dll）
PluginInterface.h    官方插件接口头文件（API version 8）
```

> 1.4.0 的改动：`VramPlugin/VramReader/VramTest` 一律改名为 `GpuMonitor*`；
> `include\PluginInterface.h` 移到项目根目录（`include\` 目录已删除）；
> 配置文件由 `VramMonitor.ini` 改名为 `GpuMonitor.ini`，日志改名为 `GpuMonitor.log`
> （**不兼容旧文件名**，需要重新在设置里勾一次显卡）。

## 编译

```bat
:: CMake（推荐，会自动编译 .rc）
cmake -B build -A x64
cmake --build build --config Release

:: 或手工调 cl.exe（注意先编译资源，必须 x64、必须 /utf-8）
rc /nologo /fo GpuMonitor.res GpuMonitor.rc
cl /nologo /LD /O2 /EHsc /utf-8 /DUNICODE /D_UNICODE ^
   GpuMonitor.cpp GpuMonitorReader.cpp GpuMonitor.res ^
   /Fe:GpuMonitor.dll /link pdh.lib dxgi.lib user32.lib comctl32.lib

cl /nologo /O2 /EHsc /utf-8 /DUNICODE /D_UNICODE ^
   GpuMonitorTest.cpp GpuMonitorReader.cpp ^
   /Fe:GpuMonitorTest.exe /link pdh.lib dxgi.lib
```

## 配置窗口版面自检（改版面后请跑一次）

对话框的中文全部由代码设置，靠肉眼很难发现"某个控件被挤出边框"。
`LayoutCheck` 会把对话框按真实路径建出来（隐藏、不显示），逐个量控件：
是否越界、是否互相重叠、文字是否宽过控件而会被裁掉。

```bat
cmake --build build --config Release --target LayoutCheck
build\Release\LayoutCheck.exe build\layouttest\Release\GpuMonitorLayoutTest.dll
```

- 它加载的是 `GpuMonitorLayoutTest.dll`（`EXCLUDE_FROM_ALL`，额外导出建对话框的入口），
  发布的 `GpuMonitor.dll` 不含任何自检代码。
- 退出码 0 = 通过；非 0 时会打印具体是哪个控件、差多少像素。
- 版面本身在 `GpuMonitor.rc` 里按 DLU 排布，并在 150% 缩放下验证过：
  360 x 362 DLU，左右外边距 10，组内控件内缩 10，按钮固定在右下角。

## 安装

1. 在 TrafficMonitor 目录下建立 `plugins` 文件夹（若不存在）。
2. 把 `GpuMonitor.dll` 放进去；**不要同时放 VramMonitor.dll**（会重复显示显存项）。
3. 重启 TrafficMonitor → **选项 → 插件** → 勾选「GPU 监控」。
4. 点「设置」打开配置窗口勾选显卡与显示项；再到 **选项 → 显示设置** 勾选要显示的具体项目。

## 先验证（不装 TrafficMonitor）

```bat
GpuMonitorTest.exe 10          :: 每秒打印一次，含每块显卡的显存与 GPU 使用率
GpuMonitorTest.exe 10 noun     :: 只测显存
nvidia-smi --query-gpu=memory.used,utilization.gpu --format=csv
```

对拍参考（本机）：显存一侧 nvidia-smi 1641 MiB vs 本方案 1645.0 MB；
使用率一侧以任务管理器「性能 → GPU」的百分比为准（本方案取该卡最忙引擎节点的利用率，天然 0~100%）。

## 排错

### 重复适配器自动去重（1.3.0+）

有些虚拟显示 / 串流软件（本机是 **网易 GameViewer** 装的间接显示驱动 IDD）会让 DXGI
**多枚举出一个与真实显卡完全同型号的适配器**（本机表现为第二个 `AMD Radeon(TM) Graphics`）。
它与真卡的区别是：**在 GPU 性能计数器里从来没有实例**（`\GPU Adapter Memory(*)` 只有真卡那一条），
也没有任何输出。

插件据此去重，但判据刻意做得很保守：

| 情况 | 行为 |
|---|---|
| 同硬件键（厂商+设备+子系统）里**至少有一个**成员有计数器实例 | 只保留有实例的那些（真卡；睡眠中的卡也有实例，值为 0） |
| 同硬件键里**一个都没有**实例（例如系统没有 GPU 计数器） | **全部保留**，宁可多显示也不误删 |
| 真装了两块同型号显卡 | 两块各有自己的实例 → **两块都保留**，不会被当成重复项 |

被跳过的项会写进 `GpuMonitor.log`（`去重跳过 N 个重复适配器…`），插件设置里的列表也会在该行
标注「无 GPU 计数器实例：虚拟显示派生，已自动忽略」，勾选它不会生成显示项。

### 诊断日志

插件每次初始化会**覆盖写**一份诊断日志 `<配置目录>\GpuMonitor.log`（UTF-16），包含：

- 显存计数器 / 使用率计数器是否正常打开
- DXGI 枚举到的每块适配器（Key / LUID / 厂商 / 显存 / 是否被勾选）
- 选择来源（默认 / 配置文件 / 一个都没勾）
- 生成了几个显示项（标明是"显存"还是"使用率"）、各自的名称与 ID
- 去重跳过了哪些重复适配器

「显示设置里看不到项」时先看这个文件。

另外注意：宿主打开「显示设置」时会先枚举 `IPluginItem`，**可能早于第一次 `DataRequired()`**，
所以插件在 `GetItem()` / `OnInitialize()` 里也会完成初始化。

## 接口对齐说明（已按官方头文件逐条核对）

- `IPluginItem` 的 5 个**纯虚且 const** 函数：`GetItemName` / `GetItemId` / `GetItemLableText` /
  `GetItemValueText` / `GetItemValueSampleText`（`Lable` 是官方拼写）。
- 一个插件可提供多个 `IPluginItem`：`GetItem(index)` 依次返回，越界返回 `nullptr`。
- 未重写 `IsCustomDraw()`（默认 false），由主程序绘制「标签 + 数值」。
- 可选接口：`IsDrawResourceUsageGraph()` / `GetResourceUsageGraphValue()`（0.0~1.0）。
- `ITMPlugin`：`GetItem` / `DataRequired` / `GetInfo`（`TMI_*`）/ `OnExtenedInfo`（`EI_CONFIG_DIR`）/
  `OnInitialize` / `GetTooltipInfo` / `ShowOptionsDialog`；`GetAPIVersion()` 用基类默认值（8）。
- 导出函数：`ITMPlugin* TMPluginGetInstance()`。
- 多选列表用 `SysListView32` + `LVS_EX_CHECKBOXES`（需 comctl32 与 `InitCommonControlsEx`）。
- `.rc` 只用 ASCII，中文界面文字由 `SetDlgItemTextW` 设置，避免 rc.exe 代码页问题。

## 已知限制

- 显存读数是**整卡口径**（该卡所有进程合计）。
- GPU 使用率取「该卡最忙的引擎节点」，与任务管理器口径一致；单卡跑满时显示 100%。
- 使用率计数器实例较多（本机 598 个），是这两个数据源里较贵的一个——所以给了 `UsageIntervalMs`。
- 不含显存温度、显存频率。
