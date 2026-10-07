# 12 — 音频互操作层：哪些 API 能安全地在 ShellHost 里调（2026-10-03）

| 目标 | 在写自定义页之前，先确认"设备枚举 / 端点音量 / 会话 / 切默认设备 / 逐应用重定向"这五类调用里，
**哪些可以安全地在 ShellHost 进程内直接调**，哪些必须绕到我们自己的进程 |
|---|---|
| 结论 | **前三类安全**；后两类**一律改走 `action=pipe` 由宿主执行**。⚠️ 当初判"不安全"的理由（
"未公开接口在这个 build 上**会访问违规**"）**已于 2026-10-04 更正** —— AV 是旧探针槽位映射偏移所致，
不是接口本身的属性（见 [15](./15-host-pipe-and-device-policy.md) §3）。**分流方案不变**：代价（崩掉用户 shell）
仍由"宿主执行"这个隔离挡住 |
| 环境 | Windows 11 build 26100 系，**当前是通过远程桌面（RDP）访问**，全机只有 1 个渲染端点 |
| 证据 | 独立探针进程 `docs/poc/src/audiochk.cpp`（已删）、`docs/poc/src/vcxaudio.h` |

---

## 0. ⚠️ 先说环境：这台机器在 RDP 里，音频设备和之前记录的不一样

之前 `todo.md` 记的是「网易虚拟音频设备」的 `扬声器` + `麦克风阵列`。**现在已经不是了**：

```text
EnumEndpoints(render)  ok=1 count=1
  friendly = [远程音频]                     ← RDP 的音频重定向端点，不是真实硬件
  id       = [{3.0.0.00000002}.{6C26BA7D-F0B2-4225-B422-8168C5261E45}]
  sessions ok=1 count=1
     pid=0 sys=1 vol=1.00 mute=0 name=[系统声音]
EnumEndpoints(capture) ok=1 count=0         ← 采集端点 0 个（四个 state 全试过）
```

- 设备 id 形如 `{3.0.0.xxxxxxx}` 是**虚拟/重定向设备**的编号方式；真实硬件是 `{0.0.0.00000000}.{guid}`。
- **采集端点数量是 0**（`ACTIVE` / `DISABLED` / `NOTPRESENT` / `UNPLUGGED` 四种 state 全查过）。
- ⇒ 之前"本机只有 1 个渲染端点"的结论**依然成立，而且更强**：唯一的那个还不是真实硬件。
- ⚠️ 这条**修正**了 `todo.md` 驱动层那节记录的设备名 —— 换机器/退出 RDP 后要重新枚举一次。

## 1. ✅ 可以安全地在 ShellHost 内直接调的

| API | 来源 | 实测 |
|---|---|---|
| `IMMDeviceEnumerator::EnumAudioEndpoints` | SDK `mmdeviceapi.h` | ✅ `ok=1`，枚举、`GetId`、`GetState` 全正常 |
| `IPropertyStore::GetValue` + `PKEY_Device_FriendlyName` | SDK | ✅ 读到 `远程音频`（`vt=31` = `VT_LPWSTR`） |
| `IMMDevice::Activate(IAudioEndpointVolume)` | SDK `endpointvolume.h` | ✅ 读 `GetMasterVolumeLevelScalar` / `GetMute` 正常 |
| `IAudioSessionManager2` + `IAudioSessionEnumerator` + `IAudioSessionControl2` + `ISimpleAudioVolume` | SDK `audiopolicy.h` | ✅ 拿到 1 个会话（`系统声音`，`vol=1.00`），**写音量成功** |

⇒ **两端（设备列表 + 端点音量 + 逐应用音量）的全部读写都可以内联**，页面的主体不需要 IPC。

## 2. ⛔ 不能安全内联的：`IPolicyConfig`（切系统默认设备）

> ⚠️ **2026-10-04 更正（见 [15](./15-host-pipe-and-device-policy.md) §3）**：下面这段的结论「槽位映射是错的」
> **不成立** —— 是**旧探针的槽位编号整体偏移了一位**。重做探针后确认 **槽 13 就是 `SetDefaultEndpoint`**：
> 传真实端点 ID 得 `E_NOINTERFACE`、传任何别的 ID 得 `E_INVALIDARG`，**不 AV**。
> 本节保留原始实测记录（当时的观察是真的），但**"正确槽位未知"这句已作废**。
> 两节的共同结论不变：**设备策略走 `action=pipe` 到宿主**。

EarTrumpet 的声明（`Interop/MMDeviceAPI/IPolicyConfig.cs`）把前 8 个方法收成 8 个占位，
于是 `SetDefaultEndpoint` 落在 **vtable[13]**。我们照抄后实测：

```text
CoCreateInstance(CLSID PolicyConfigClient {870AF99C-…}, IID {F8679F50-…})  hr=0x00000000  ptr=00000123A54BBD68
slot11 GetPropertyValue(devId, &PKEY_Device_FriendlyName, &pv)             hr=0x00000000  vt=0   ← S_OK 但没填
slot13 SetDefaultEndpoint(devId, eConsole)                                 0xC0000005  ← 访问违规
```

两条独立的证据说明**槽位映射是错的**：

1. **`slot11` 不是 `GetPropertyValue`。** 用的 `PKEY_Device_FriendlyName` 是**已知正确**的
   —— 同一个 key 走 `IPropertyStore::GetValue` 能读出 `远程音频`；同一个 key 走 `slot11`
   却返回 `S_OK` 且 `PROPVARIANT` 仍是 `VT_EMPTY`。
   ⇒ `slot11` 是另一个方法（它吃掉了第 2 个参数——一个指针——并返回成功）。
2. **`slot13` 不是 `SetDefaultEndpoint`** —— 它直接访问违规。

另外两个 IID 在一个独立进程里都取不到对象：

```text
IID {CA286FC3-…} (W10 TH1)  CoCreateInstance hr=0x80004002 (E_NOINTERFACE)
IID {6BE54BE8-…} (W10 TH2)  CoCreateInstance hr=0x80004002 (E_NOINTERFACE)
```

⇒ 对象**只**暴露 `{F8679F50-…}`，所以"换个 IID"不是出路。

**⛔ 硬后果**：这个接口的**正确槽位未知**，而错槽位会 **AV**。
**在 ShellHost 里试错 = 把用户的 shell 崩掉**，而且崩在现场看不出是谁干的。
⇒ **不在 TAP 里调 `IPolicyConfig`**（见下节）。

⚠️ **未定论的部分**：本次环境是 **RDP + 虚拟端点**，无法区分这个 AV 是
"Win11 build 的 vtable 变了" 还是 "RDP 虚拟端点让某个内部空指针被解引用"。
EarTrumpet 在真实硬件上大量使用这条路径且工作正常，所以**很可能与 RDP 有关**。
⇒ 留作**实体机待验项**；在那之前一律按"不可用"处理。

## 3. ⚠️ 半可用：`IAudioPolicyConfigFactory`（逐应用重定向）

`RoGetActivationFactory(L"Windows.Media.Internal.AudioPolicyConfig")` —— **能激活**：

```text
IID {ab3d4648-…} (21H2+)   activate hr=0x00000000     ← 对象拿到了
IID {2a59116d-…} (downlevel) activate hr=0x80004002   ← 不存在，所以回退顺序 21H2 → downlevel 是对的
set(pid=self, eConsole,    packedId)  hr=0x80070057 (E_INVALIDARG)
set(pid=self, eMultimedia, packedId)  hr=0x80070057 (E_INVALIDARG)
get(pid=self, eMultimedia)            hr=0x80070057 (E_INVALIDARG)
set(pid=self, …) 传 NULL（清除）        hr=0x00000000  ✅
```

**没有 AV**，而且 **slot 25/26 的定位是对的** —— 证据是"传 NULL 清除"成功、
而"传设备 id"返回 `E_INVALIDARG`：错槽位不可能出现这种"参数一换就换结果"的行为。

`E_INVALIDARG` 的可能原因（**未定论**）：
① RDP 虚拟端点不接受重定向；② 我们的进程没有音频会话（探针是控制台程序，没放过声音）；
③ 打包 id 的 token 在这个 build 上要求不同写法。
⇒ **不阻塞**：这条路是**无 AV 风险**的，可以内联再试，但**必须记录 HRESULT**（别静默失败）。

## 4. ✅ 由此确定的架构：安全 / 危险 API 的分界

| 操作 | 在哪执行 | 为什么 |
|---|---|---|
| 枚举设备、读端点音量/静音、读写逐应用音量/静音 | **TAP 内联**（ShellHost 里） | 全部走 SDK 文档化接口，实测无风险 |
| **切系统默认设备**、**逐应用重定向**、**清空重定向** | **走 `action=pipe` → 宿主进程** | 未公开接口，槽位未确定、有 AV 风险。**宿主进程崩了可以重启，ShellHost 崩了是整个桌面没了** |
| **开机自启**（`Run` 键查询/注册/删除） | **TAP 内联**（`Core/AutostartEntry`） | 纯 `HKCU` 注册表操作，无未公开接口风险；且开关**初值必须现查**"自启项在不在"（含系统的禁用标记），而 `pipe` 单向问不了宿主 |
| 从系统卸载 | **走 `action=pipe` → 宿主进程** | 本来就该由宿主做（生命周期原因：要重启 shell，而 TAP 活在那个 shell 里；见 §5.7.8） |

⭐ 这条正好落在 §2.4 已经写下的判据上：
**"只有必须由 App 的进程身份 / 生命周期来做的事才加报文"** ——
"不能崩在别人的进程里"是同一类理由。

代价：`pipe` 是**单向**的，宿主无法回包 ⇒ 切换结果拿不到确认。
⇒ UI 采用**乐观更新**（点了就改显示），下次打开面板重新枚举即与事实对齐。

## 5. 复现方式

`vcxaudio.h` 是自包含的，可直接用 `cl` 单独编译/链接验证（不需要整套 PoC 构建）：

```bat
call vcvars64.bat
cl /nologo /std:c++17 /utf-8 /EHsc /O2 /MT /W3 /DUNICODE /D_UNICODE ^
   /c  src\audiochk.cpp /Fo:audiochk.obj
link /nologo audiochk.obj /out:audiochk.exe ^
   Mmdevapi.lib uuid.lib ole32.lib version.lib WindowsApp.lib
```

⚠️ 探针里要么 `setvbuf(stdout, nullptr, _IONBF, 0)`，要么别打印中文 —— 崩溃时缓冲会丢，
而 `printf("%ls")` 在 C locale 下转换不了中文会静默输出空（这两个坑各踩过一次）。
