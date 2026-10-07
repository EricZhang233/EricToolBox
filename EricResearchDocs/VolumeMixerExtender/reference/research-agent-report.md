Agent is idle (waiting for messages). agent_id: 06f62dd3-6798-49eb-8faa-b1bdf6e158a2, agent_type: research, status: idle, description: Research Win11 shell XAML injection, elapsed: 326s, total_turns: 1

[Turn 0]
I have gathered comprehensive source-verified evidence. Here is the technical report.

---

# XAML-injection research report — Windows 11 build 26300 (ShellHost.exe / Quick Settings)

**Scope note:** Everything below is traced to source files I actually read (GitHub paths with line ranges). Items I could **not** verify are marked ⚠️ **UNVERIFIED**. Nothing in the repo was modified.

---

## Summary

The Windows 11 shell XAML is **system XAML (`Windows.UI.Xaml.dll`)**, not WinUI 3, for the taskbar and (by class-name evidence) the Quick Settings panel. Two mature, independent in-process techniques exist:

1. **Hook a component-specific WinRT implementation method** in the relevant `.dll`, then walk the live `XamlRoot`/`VisualTreeHelper` and construct/insert real WinRT objects (`Panel.Children().Append(...)`). This is what every Windhawk taskbar mod and ExplorerPatcher do. Hook libraries: **MinHook** (Windhawk engine), **funchook** + IAT patching (ExplorerPatcher), **Detours** (TranslucentTB).
2. **XAML Diagnostics** (`InitializeXamlDiagnosticsEx` + a TAP DLL you supply + `IXamlDiagnostics`/`IVisualTreeService(2/3)`). This enumerates the live tree, returns **real `IInspectable`s** via `GetIInspectableFromHandle`, and the interface even exposes `CreateInstance`/`AddChild`/`SetProperty`. It does **not** require a debugger; it does require your own TAP DLL, a connection-endpoint walk, and it is a process-wide singleton (only one consumer at a time; init once per thread). Working open-source examples: Microsoft's own `WinUISnoop` sample, `asklar/lvt`, `TranslucentTB/ExplorerTAP`, `m417z/UWPSpy`.

The single most relevant existing code to your goal is **ExplorerPatcher's `ShellExperienceHostPatches.cpp`**, which restyles the Win11 Quick Settings ("QuickActions") XAML in-process by hooking `NetworkUX::App::LoadResourceDictionaries` and rewriting the `Application.Resources` style dictionary. It does not *insert an element*, but it is the closest proven pattern.

---

## Q1 — How existing OSS modifies the Win11 shell XAML in-process

### Windhawk mods (`ramensoftware/windhawk-mods`)

**Closest analog to "inject a new element": `taskbar-content-presenter-injector.wh.cpp`** (author Lockframe). It injects a `ContentPresenter` into taskbar panels.

- Technique — hook WinRT implementation methods and, from inside them, walk the tree and append a real WinRT object:
  - Constants: `c_TargetPanelLabeled = L"Taskbar.TaskListLabeledButtonPanel"`, `c_TargetPanelButton = L"Taskbar.TaskListButtonPanel"`, `c_TargetSearchBar = L"SearchUx.SearchUI.SearchButtonRootGrid"`, `c_RootFrameName = L"Taskbar.TaskbarFrame"`, `c_InjectedControlName = L"CustomInjectedPresenter"` — `mods/taskbar-content-presenter-injector.wh.cpp:48-56`.
  - **Native `this` → WinRT object**: `GetFrameworkElementFromNative(void* pThis)` does `void* iUnknownPtr = (void**)pThis + 3; winrt::copy_from_abi(iUnknown, iUnknownPtr); return iUnknown.try_as<FrameworkElement>();` — `:90-104`. (i.e. the WinRT implementation stores a back-pointer to `IUnknown` at a fixed offset `+3` pointers — version/fragile.)
  - Insertion: `panel.Children().Append(presenter)` after deferring until `ActualWidth()>0 && ActualHeight()>0` via the `FrameworkElement.SizeChanged` event, dispatched with `CoreDispatcher.RunAsync` — `:135-230`.
  - Tree walk: `ScanAndInjectRecursive` using `Media::VisualTreeHelper::GetChildrenCount/GetChild` and `winrt::get_class_name(element)` — `:228-241`.
  - Hooks (installed on the class methods): `TaskListButton_UpdateVisualStates_Hook`, `TaskListButton_UpdateButtonPadding_Hook`, `ExperienceToggleButton_UpdateVisualStates_Hook` — `:324-340`.
  - Symbol hook table (demangled MSVC signatures) via `WindhawkUtils::SYMBOL_HOOK` + `HookSymbols`:
    - `private: void __cdecl winrt::Taskbar::implementation::TaskListButton::UpdateVisualStates(void)`
    - `private: void __cdecl winrt::Taskbar::implementation::TaskListButton::UpdateButtonPadding(void)`
    - `private: void __cdecl winrt::Taskbar::implementation::ExperienceToggleButton::UpdateVisualStates(void)`
    — `:344-365`.
  - Lazy module load: hooks `LoadLibraryExW` and calls `Wh_ApplyHookOperations()` once `Taskbar.View.dll` / `ExplorerExtensions.dll` loads — `:379-400`.

- **`taskbar-vd-switcher.wh.cpp`** (sb4ssman) is the reference for the reusable **`GetTaskbarXamlRoot`** boilerplate (credited to `sb4ssman/Windhawk-Mod-Lab`, `vertical-omnibutton`):
  - `RunFromWindowThread(HWND, proc, param)` — marshals to the UI thread via `SetWindowsHookEx(WH_CALLWNDPROC,...)` + `SendMessage` of a registered `Windhawk_RunFromWindowThread_<id>` message — `:611-631`.
  - `FindCurrentProcessTaskbarWnd()` enumerates `Shell_TrayWnd` filtered by PID — `:634-646`.
  - `GetTaskbarXamlRoot(HWND)` — resolves the taskbar's `XamlRoot` by: `GetProp(hTaskbarWnd, L"TaskbandHWND")` → `GetWindowLongPtr(...,0)` → scan for the `CTaskBand::\`vftable'{for \`ITaskListWndSite'}` → `CTaskBand::GetTaskbarHost()` → read a `FrameworkElement*` at an **offset derived from the machine code of `TaskbarHost::FrameHeight`** (`sub rsp,28; add rcx,<imm8>` → offset = imm8) → `QueryInterface(FrameworkElement)` → `.XamlRoot()` — `:658-720`.
  - Hook + retry pattern: hook `winrt::SystemTray::implementation::IconView::IconView(void)` constructor, then defer work to `iconView.Loaded(...)` because "Calling ApplyAllSettings immediately from the constructor fires before the XamlRoot is stable, causing null dereferences and WinRT exceptions … and crash the process on startup" — `:2483-2520`.
  - `SYMBOL_HOOK` tables for `taskbar.dll` (vftable, `CTaskBand::GetTaskbarHost`, `TaskbarHost::FrameHeight`, `std::_Ref_count_base::_Decref`) and `SystemTray.dll`/`Taskbar.View.dll` (`IconView::IconView`) — `:2542-2568`.

- **Style/restyle pattern** (`hide-start-button.wh.cpp`): get `XamlRoot`, then `xamlRoot.Content()`→ walk with `VisualTreeHelper` → find by `winrt::get_class_name` / `AutomationProperties::GetAutomationId` → set `Visibility(...)` — `mods/hide-start-button.wh.cpp:40-70` (`ApplyStyle`).

- **Hooking library = MinHook.** The Windhawk engine bundles MinHook: `ramensoftware/windhawk:src/windhawk/engine/libraries/MinHook/src/hook.c` (`MH_CreateHook`, `MH_EnableHook`) and `.../libraries/MinHook/include/MinHook.h`, plus a `MinHook-Detours` variant. Mods never call MinHook directly; they use the engine wrappers `WindhawkUtils::SYMBOL_HOOK`, `HookSymbols`, `Wh_SetFunctionHookT`, `Wh_ApplyHookOperations` (see injector mod `:342-400`).

### ExplorerPatcher (`valinet/ExplorerPatcher`)

- **Hook library = funchook** plus its own IAT patcher. Examples: `funchook_prepare(funchook, (void**)&..., ...)` in `ExplorerPatcher/TwinUIPatches.cpp:2532-2540`, `:3238-3241`, `:3704-3730`; IAT patch helper `VnPatchIAT_NonInline` declared at `TwinUIPatches.cpp:391` and used in `ShellExperienceHostPatches.cpp` (`VnPatchIAT(hModule, "api-ms-win-core-winrt-string-l1-1-0.dll", "WindowsCreateStringReference", ...)`).
- **Symbol names come from PDBs.** `TwinUIPatches.cpp:1648` — `// Names taken from Windows.UI.Xaml.pdb, only defining the used ones`. Its `symbols.h`/`settings.ini` machinery downloads and parses symbols at runtime to get hook offsets per build (`CHANGELOG.md`, "Library downloads and parses symbols in order to determine function hooking offsets at runtime and saves the data in a 'settings.ini' file … invalidated when a new OS build is detected").
- **XAML-adjacent hooks**: `CMultitaskingViewManager::_CreateXamlMTVHost()` in `twinui.pcshell.dll` — `TwinUIPatches.cpp:1055-1060`, `:3573`, `:3704-3714`.
- **Most relevant file — `ExplorerPatcher/ShellExperienceHostPatches.cpp`** (this is the Quick Settings / QuickActions path). It:
  - Hooks `NetworkUX::App::LoadResourceDictionaries()` by **byte-pattern scan** of `.text` and `funchook_prepare` — `ShellExperienceHostPatches.cpp:469-505` (x64 pattern `48 8B 40 10 E8 … E8 … 80 3D … 75 05 E8`; note it says "break when the class sizes change").
  - Hook body `NetworkUX_App_LoadResourceDictionariesHook()` calls original then `NetworkUX_PatchResourceDictionary()` — `:437-444`.
  - `NetworkUX_PatchResourceDictionary()` gets `Windows.UI.Xaml.Application.Current().Resources()` (as `IMap<IInspectable*,IInspectable*>`), and **replaces** values / rebuilds setters: swaps `QuickActionPanelMargin` and clears+repopulates `QuickActionControlStyle.Setters()` with `Setter` objects for `FrameworkElement.MarginProperty/WidthProperty/HeightProperty` — `:333-430`. This is a proven in-process mutation of the Quick Settings XAML **without inserting new elements** — the natural template if you only need to restyle, and the pattern to extend if you want to add.
  - Injection entry: `GetActivationFactoryByPCWSTR` hook detects `QuickActions.quickactions_XamlTypeInfo.XamlMetaDataProvider` and `NetworkUX.networkux_XamlTypeInfo.XamlMetaDataProvider` to know the module loaded — `:509-525`.

---

## Q2 — Is the XAML Diagnostics API usable to enumerate AND modify a live tree?

**Yes — verified by interface definitions and multiple working implementations. Both enumeration and mutation are supported.**

### Export location (answers "which DLL exports it")

- **System XAML:** `InitializeXamlDiagnosticsEx` is exported by **`Windows.UI.Xaml.dll`**. Confirmed from a dumped export table: `magnusstubman/dll-exports:win11.22000/System32/Windows.UI.Xaml.dll.def` — `InitializeXamlDiagnosticsEx=C:\Windows\System32\Windows.UI.Xaml.InitializeXamlDiagnosticsEx` (also the `.cpp` linker `#pragma comment(linker, "/export:InitializeXamlDiagnosticsEx=…")`). ⚠️ This export list is from build 22000; I did **not** find an export dump for 26300.
- **WinUI 3:** it is exported by **`Microsoft.Internal.FrameworkUdk.dll`**, *not* `Microsoft.UI.Xaml.dll`. `asklar/lvt:src/providers/winui3_provider.cpp` finds `Microsoft.Internal.FrameworkUdk.dll` in the target (`find_framework_udk`) and pass it as `initDllPath`, with the comment: *"InitializeXamlDiagnosticsEx for WinUI 3 is exported by the Windows App SDK's FrameworkUdk. Microsoft.UI.Xaml.dll can also be the WinUI 2 controls library hosted by system XAML, so falling back to Windows.UI.Xaml.dll here would use the wrong endpoint flavor."* `windhawk-mods:mods/cjk-spacer.wh.cpp:2494-2510` agrees (it loads from `Windows.UI.Xaml.dll` for the Windows flavor and `Microsoft.Internal.FrameworkUdk.dll` for the Microsoft flavor).

### Signature and COM interfaces (official header)

Source: `microsoft/win32metadata:generation/WinSDK/RecompiledIdlHeaders/um/xamlOM.h` (the Windows SDK `xamlOM.idl`).

- `InitializeXamlDiagnosticsEx(LPCWSTR endPointName, DWORD pid, LPCWSTR wszDllXamlDiagnostics, LPCWSTR wszTAPDllName, CLSID tapClsid, LPCWSTR wszInitializationData)` — `xamlOM.h:124`.
- `typedef MIDL_uhyper InstanceHandle;` — `:125`; `enum VisualMutationType { Add, Remove }` — `:128`.
- **`IVisualTreeService`** `IID {A593B11A-D17F-48BB-8F66-83910731C8A5}` — `:472-567`. Methods: `AdviseVisualTreeChange(pCallback)`, `UnadviseVisualTreeChange`, `GetEnums`, **`CreateInstance(BSTR typeName, BSTR value, InstanceHandle* pInstanceHandle)`**, `GetPropertyValuesChain(instanceHandle, …)`, **`SetProperty(instanceHandle, value, propertyIndex)`**, `ClearProperty`, `GetCollectionCount`, `GetCollectionElements`, **`AddChild(InstanceHandle parent, InstanceHandle child, unsigned int index)`**, **`RemoveChild`**, **`ClearChildren`**.
- **`IVisualTreeService2`** `IID {130F5136-EC43-4F61-89C7-9801A36D2E95}` — `:1106-1140`: adds `GetPropertyIndex`, `GetProperty`, `ReplaceResource`, `RenderTargetBitmap`.
- **`IVisualTreeService3`** `IID {0E79C6E0-85A0-4BE8-B41A-655CF1FD19BD}` — `:1415-1445`: adds `ResolveResource`, `GetDictionaryItem`, `AddDictionaryItem`, `RemoveDictionaryItem`.
- **`IXamlDiagnostics`** `IID {18C9E2B6-3F43-4116-9F2B-FF935D7770D2}` — `:770-820`. Methods: `GetDispatcher`, `GetUiLayer`, `GetApplication`, **`GetIInspectableFromHandle(InstanceHandle, IInspectable** ppInstance)`**, **`GetHandleFromIInspectable(IInspectable*, InstanceHandle*)`**, `HitTest`, `RegisterInstance`, `GetInitializationData`.

So: **`IXamlDiagnostics::GetIInspectableFromHandle` returns a genuine `IInspectable`** you can `QueryInterface`/`try_as` to `FrameworkElement`/`DependencyObject` and mutate directly. Verified in Microsoft's own sample: `microsoft/microsoft-ui-xaml:Samples/WinUISnoop/WinUISnoopTap/Tap.cpp:277, 379-393, 429` use it then cast to `DependencyObject` and call `VisualTreeHelper::GetChildrenCount/GetChild`, and reverse with `GetHandleFromIInspectable`. `windhawk-mods:mods/cjk-spacer.wh.cpp:2038-2045` (`FromHandle`) does the same.

### Working open-source examples (all real, cited)

- **`microsoft/microsoft-ui-xaml:Samples/WinUISnoop`** — Microsoft's own TAP: `WinUISnoopTap/Tap.cpp`, `Class.cpp/.h/.idl`, `xamlOM.h`, `WinUISnoopTap.def`. Shows `IObjectWithSite::SetSite(IXamlDiagnostics*)`, `AdviseVisualTreeChange`, `DispatcherQueue.TryEnqueue` to marshal to the UI thread (`Tap.cpp:28-68, 123-178`), and a `XamlSnoopLauncherFactory` class-factory (`Tap.cpp:639-646`).
- **`asklar/lvt`** — full-featured: `src/providers/xaml_diag_common.cpp` (injection), `src/tap/lvt_tap.cpp` (TAP with `setProperty`/`clearProperty`/`createInstance` commands, `m_diag->GetIInspectableFromHandle(handle, &raw)` at `:1734`, `m_vts->CreateInstance(...)`/`SetProperty(...)`/`ClearProperty(...)` at `:884-960`), `docs/tap-dll-design.md`.
- **`TranslucentTB/TranslucentTB:ExplorerTAP`** — `api.cpp` (uses **Detours**: `DetourFindRemotePayload`/`DetourCopyPayloadToProcess`), `tapsite.cpp` (`TAPSite::Install` loads `Windows.UI.Xaml.dll`, calls `InitializeXamlDiagnosticsEx`, retries 60×; `SetSite` creates the `VisualTreeWatcher`).
- **`m417z/UWPSpy`** — `UWPSpy/UWPSpy.cpp` (`GetProcAddress(wux, "InitializeXamlDiagnosticsEx")`); README cites the MS docs and says the only usage example it could find was ExplorerTAP.

### Requirements / opt-in — precise answers

- **No debugger required.** `lvt.exe` (external process) calls the function with the target's `pid`; `xaml_diag_common.cpp:1271-1339` calls `pInit(endPoint, pid, xamlDiagDll, tapDll, CLSID_LvtTap, initData)` with a pid that isn't its own. `TranslucentTB` and `cjk-spacer` call it *from inside* the target instead.
- **You MUST supply a TAP DLL.** Args 4/5 are your DLL path and a CLSID in it. Your TAP implements `IObjectWithSite` (receiving `IXamlDiagnostics*`) and exports `DllGetClassObject`/a class factory. Examples: `cjk-spacer.wh.cpp:2208-2340` (`class WindhawkTap : winrt::implements<…, IObjectWithSite>` + `CLSID_CjkSpacerTap` + `DllGetClassObject`), `TranslucentTB:ExplorerTAP/tapsite.cpp`, `microsoft-ui-xaml:WinUISnoopTap/Class.cpp`.
- **It is a process-wide singleton.** `mods/explorer-command-bar.wh.cpp` states: *"the mod does **not** use XAML Diagnostics (`InitializeXamlDiagnosticsEx`), since only one XAML diagnostics consumer can be active in a process at a time."* `cjk-spacer.wh.cpp:2440-2490` handles the "another diagnostics tool probably blocked the connection" case. `TranslucentTB:ExplorerTAP/tapsite.cpp` comment: *"XAML Diagnostics can only be initialized once per thread — future calls simply return S_OK without doing anything."*
- **Connection-endpoint names must be walked.** System XAML prefix `VisualDiagConnection`, WinUI3 prefix `WinUIVisualDiagConnection`, suffix = index; both `cjk-spacer` and `lvt` loop with a **10000** ceiling because the index is a process-lifetime core ordinal (`cjk-spacer.wh.cpp:1869, 2370-2400`; `xaml_diag_common.cpp:1300-1335`, which cites UWPSpy for the 10000 figure).
- **No teardown API.** `asklar/lvt:docs/tap-dll-design.md:301`: *"None of these has a `Close()`, `Disconnect()`, `Shutdown()`, or `Uninitialize()` … `UnadviseVisualTreeChange` removes the mutation-event subscriber but does not terminate the session or release the `IObjectWithSite` reference."* The TAP DLL is pinned (`api.cpp` comment: *"InitializeXamlDiagnosticsEx pins the DLL forever in the target process"*).
- **Security caveat:** this is a known elevation-of-privilege primitive — **CVE-2023-36003** (m417z). Injecting into a higher-integrity process may be blocked; same-user / same-integrity targets (your ShellHost.exe case) should work.
- ⚠️ **UNVERIFIED:** I found **no** open-source example that uses `IVisualTreeService::AddChild`/`CreateInstance` to insert a *new live interactive control* into the tree. `CreateInstance`/`AddChild` exist in the header, and LVT uses `CreateInstance`+`SetProperty` for **property values**, but "diagnostics-driven element insertion" is not demonstrated anywhere I read. The demonstrated insertion route is the Q1 route (in-process WinRT `Children().Append`). Also note Microsoft's sample *deliberately avoids* mutating the visual tree for adornments (`Tap.cpp:410-418`: it uses a Composition `SpriteVisual` via `ElementCompositionPreview.SetElementChildVisual` because *"any UIElement we added would be picked up by IVisualTreeService::OnVisualTreeChange and surface as a phantom node"*).

---

## Q3 — In-process hook points to intercept element creation / layout

**What real mods actually use (all verified):**

| Hook point | Binary | Where | Why |
|---|---|---|---|
| `winrt::Taskbar::implementation::TaskListButton::UpdateVisualStates` / `UpdateButtonPadding` | `Taskbar.View.dll` / `ExplorerExtensions.dll` | `mods/taskbar-content-presenter-injector.wh.cpp:344-365` | Runs whenever a task button is (re)built → inject the child then |
| `winrt::Taskbar::implementation::ExperienceToggleButton::UpdateVisualStates` | same | same | same, for toggle buttons (Start/Search/etc.) |
| `winrt::SystemTray::implementation::IconView::IconView` **constructor** | `SystemTray.dll` / `Taskbar.View.dll` | `mods/taskbar-vd-switcher.wh.cpp:2483-2520, 2557-2562` | Ctor gives you the element, then subscribe `.Loaded(...)` to act once it's live |
| `CTaskBand::GetTaskbarHost` + `TaskbarHost::FrameHeight` + vftable | `taskbar.dll` | `mods/taskbar-vd-switcher.wh.cpp:2542-2556` | Recover the taskbar's `XamlRoot` without a creation hook |
| `CMultitaskingViewManager::_CreateXamlMTVHost` | `twinui.pcshell.dll` | `valinet/ExplorerPatcher:ExplorerPatcher/TwinUIPatches.cpp:1055-1060, 3704-3714` | Win11 Task-View XAML host creation |
| `NetworkUX::App::LoadResourceDictionaries` | `NetworkUX.dll` (ShellExperienceHost.exe) | `ExplorerPatcher/ShellExperienceHostPatches.cpp:469-505` | Load-time entry to mutate Quick Settings XAML resources |

**The general recipe** (from the mods): hook a component method/ctor → obtain the WinRT object from the raw `this` (`GetFrameworkElementFromNative`, `((IUnknown**)pThis)[1]->QueryInterface(...)`) → **defer to `Loaded` or `SizeChanged`** (the XAML tree is not stable inside a constructor) → walk with `VisualTreeHelper` matching `winrt::get_class_name` / `x:Name` / `AutomationId` → `Panel.Children().Append(...)` on the UI thread.

**`ElementLoaded` / `Loaded`:** use the WinRT `FrameworkElement.Loaded` (RoutedEventHandler) as the "it's in the tree now" signal; `SizeChanged` is used when you additionally need non-zero `ActualWidth/Height` before committing layout-affecting insertions (`taskbar-content-presenter-injector.wh.cpp:178-230`; `taskbar-vd-switcher.wh.cpp:2505-2520`).

**`DXamlCore::CreateElement` / `CCoreServices` / `CreateFromMetadataProvider` / `CContentDialog`:**
- ⚠️ **UNVERIFIED / not found.** A code search of `microsoft/microsoft-ui-xaml` for `DXamlCore::CreateElement` and `CCoreServices` returned **0** results (the dxaml/XCP core is not open-sourced; only the public WinUI repo surface is). No Windhawk mod or ExplorerPatcher source I read hooks these by name. ExplorerPatcher does exploit such symbols indirectly: it resolves **`Windows.UI.Xaml.pdb`** names at runtime (`TwinUIPatches.cpp:1648`) and defines a partial enum from that PDB (`:1648-1660`), so the symbols exist but are consumed via PDB/symbol resolution, not hardcoded. If you want a universal "every element created" hook you would be pioneering that; the proven path is per-component hooks.

**Version fragility (explicit):**
- Symbol-by-name hooks (Windhawk `SYMBOL_HOOK`) break when MSVC demangled signatures or function layout change; Windhawk resolves these against downloaded symbol info per build.
- ExplorerPatcher uses **raw byte-pattern scans** with explicit warnings (*"these patterns will break when the class sizes change"*, `ShellExperienceHostPatches.cpp:193, 251`) and an offset **extracted from machine code** (`GetTaskbarXamlRoot` reads the `add rcx,<imm8>` operand of `TaskbarHost::FrameHeight` — `taskbar-vd-switcher.wh.cpp:690-716`). Build 26300 is bleeding-edge, so expect all of these to need per-build verification.

---

## Q4 — `Windows.UI.Xaml.dll` (system XAML) vs `Microsoft.UI.Xaml.dll` (WinUI 3), and telling them apart

**Practical hooking difference:** they are different runtime cores with different host windows and different diagnostics endpoints, but the same COM diagnostics contract.

| | System XAML | WinUI 3 |
|---|---|---|
| Core module | `Windows.UI.Xaml.dll` | `Microsoft.UI.Xaml.dll` (WinUI 2 control lib may also be this name) + **`Microsoft.Internal.FrameworkUdk.dll`**, `CoreMessagingXP.dll` |
| Exports `InitializeXamlDiagnosticsEx` | `Windows.UI.Xaml.dll` | `Microsoft.Internal.FrameworkUdk.dll` |
| Endpoint prefix | `VisualDiagConnection<N>` | `WinUIVisualDiagConnection<N>` |
| Host window classes | `Windows.UI.Core.CoreWindow`, `Windows.UI.Composition.DesktopWindowContentBridge` (desktop island), `XamlExplorerHostIslandWindow`, `Shell_InputSwitchTopLevelWindow`, `Windows.UI.Input.InputSite.WindowClass` | `Microsoft.UI.Content.DesktopChildSiteBridge`, `InputNonClientPointerSource`, `InputSiteWindowClass`, `XamlExplorerHostIslandWindow_WASDK`, `CabinetWClass` |

Evidence:
- Class→flavor mapping: `windhawk-mods:mods/cjk-spacer.wh.cpp:2700-2730` (`ClassifyModernXamlHost`): `XamlExplorerHostIslandWindow`, `Shell_InputSwitchTopLevelWindow`, `Windows.UI.Composition.DesktopWindowContentBridge` (parent `Shell_TrayWnd`) → **Windows**; `CabinetWClass`, `XamlExplorerHostIslandWindow_WASDK` → **Microsoft**.
- Module→flavor mapping: `cjk-spacer.wh.cpp:2846-2875` (`GetXamlDiagnosticsModuleFlavor`): `Windows.UI.Xaml.dll` → Windows; `Microsoft.Internal.FrameworkUdk.dll` or `CoreMessagingXP.dll` → Microsoft.
- LVT labeling: `asklar/lvt:src/providers/winui3_provider.cpp:12-33` labels `Microsoft.UI.Content.DesktopChildSiteBridge`, `InputNonClientPointerSource`, `InputSiteWindowClass` as `winui3`; `src/providers/xaml_provider.cpp:12-24` treats `Windows.UI.Core.CoreWindow` as system XAML and `Windows.UI.Composition.DesktopWindowContentBridge` as a desktop system-XAML island.

**Two independent runtime tests to identify the owner of an island:**
1. **Module presence** — `EnumProcessModulesEx`/`GetModuleHandleW` for `Windows.UI.Xaml.dll` vs `Microsoft.Internal.FrameworkUdk.dll` (this is exactly what LVT's `find_framework_udk` and `cjk-spacer`'s `LoadLibraryExWHook` do — `xaml_diag_common`/`winui3_provider.cpp:36-60`).
2. **Host window class** of the island's container, then pick the matching endpoint prefix and call `InitializeXamlDiagnosticsEx`.

**For your Quick Settings target (ShellHost.exe / `ControlCenterWindow`):**
- Local empirical notes (your repo) establish: panel `hwnd` has class `ControlCenterWindow`, band=4; its only child is `Windows.UI.Input.InputSite.WindowClass` with **UIA `FrameworkId = "XAML"`**, and the whole automation tree hangs below it (`Win11-QuickSettings-XAML-Injection-Notes.md:632-660`). The `Windows.UI.Input.*` namespace + the input-site child is characteristic of **system XAML** (`Windows.UI.Xaml`), not WinUI 3 — but ⚠️ this is **inferred from class names**, not confirmed by checking loaded modules in ShellHost.exe. Recommended runtime confirmation: enumerate `ShellHost.exe` modules for `Windows.UI.Xaml.dll` vs `Microsoft.Internal.FrameworkUdk.dll`, and try the `VisualDiagConnection` endpoint first.
- ⚠️ **UNVERIFIED:** the claim that WinUI 3 ships via a "`Microsoft.UI.Xaml.CBS` appx under `C:\Windows\SystemApps`" — I found no source confirming the exact package path. (WinUI 3 in-box is delivered via the Windows App SDK's `FrameworkUdk`; LVT's code is the strongest evidence of the module name.)

---

## Q5 — WinEvent / UIA-only (non-injection) alternatives — dead ends?

**Confirmed dead ends for *adding* an interactive element:**

- **WinEvent is notification-only.** `SetWinEventHook(EVENT_OBJECT_SHOW/HIDE, …)` gives you the `hwnd` (your notes measured: exactly 2 events on open, 1 on close, **0 events when idle**), but there is no WinEvent API to create/mutate UI — `Win11-QuickSettings-XAML-Injection-Notes.md:720-760`.
- **UIA is a read/invoke client model with no "add element" API.** UIA can *find* elements, read properties (via `IUIAutomationCacheRequest`), and *invoke* existing controls (`InvokePattern`), but it cannot construct or insert elements into another process's visual tree — the provider-side tree is owned by the target. Your own notes confirm the detection path works (enumerate `InputSite` child → full tree, `:632-660`) but every "add" plan relies on injection, not UIA (`:117-140`).
- **UIA/WinEvent can't even see the panel's own HWND via enumeration:** band≥3 windows (`ControlCenterWindow` band 4, `Shell_TrayWnd` band 6) are excluded from `EnumWindows`/`FindWindow`/UIA `RootElement`; you must use `GetForegroundWindow()`/`GetGUIThreadInfo()`/`GetWindowBand` — `Win11-QuickSettings-XAML-Injection-Notes.md:594-628`.
- **Composition overlay route is in-process-only and non-interactive:** the composition `SpriteVisual` technique (`microsoft-ui-xaml:Samples/WinUISnoop/WinUISnoopTap/Tap.cpp:410-440`) draws *below* XAML and "doesn't participate in layout or hit-testing" — fine for adorners, useless for a clickable button, and it still requires being in-process.
- The only true no-injection alternative in your notes is a **separate `WS_EX_NOACTIVATE` overlay window** (not UIA/WinEvent), with the documented focus-loss drawback (`Win11-QuickSettings-XAML-Injection-Notes.md:96-130`).

**Conclusion:** there is no source-verified WinEvent/UIA-only way to *add* an interactive button. Detection can be done event-driven and zero-cost via WinEvent + narrow-scope UIA; addition requires in-process XAML manipulation.

---

## Gaps & uncertainties (explicit)

1. ⚠️ **`windows-11-taskbar-styler.wh.cpp` not read** — the file is >1 MB, so GitHub's content API returned `unsupported content encoding`, and `raw.githubusercontent.com`/`learn.microsoft.com` are blocked by the sandbox's address filter. I inferred its technique belongs to the same `GetTaskbarXamlRoot`/CTaskBand family (the VD-switcher mod explicitly cites it for XAML tree element names: `taskbar-vd-switcher.wh.cpp:123`). **Not verified by direct read.**
2. ⚠️ **No example of diagnostics-driven element *insertion*** (`AddChild`/`CreateInstance` used to add a live control). API exists (`xamlOM.h:472-567`); no demo found.
3. ⚠️ **`DXamlCore::CreateElement` / `CCoreServices` / `CContentDialog` hook points: not found** in any OSS (search of `microsoft/microsoft-ui-xaml` returned 0). Only reachable via PDB symbol names (ExplorerPatcher pattern).
4. ⚠️ **No confirmation that ShellHost.exe's Quick Settings XAML exposes a diagnostics endpoint**, nor which core it uses, by module inspection. Class-name evidence points to system XAML; must be tested on build 26300.
5. ⚠️ **DLL export dump is for build 22000**, not 26300 (`magnusstubman/dll-exports`). Verify `InitializeXamlDiagnosticsEx` export on 26300 with `dumpbin /exports C:\Windows\System32\Windows.UI.Xaml.dll`.
6. ⚠️ The `Microsoft.UI.Xaml.CBS` appx path was not verified.
7. **CVE-2023-36003** (m417z) — diagnostics injection is a known EoP primitive; cross-integrity injection may be blocked by the OS.

**Suggested follow-up searches:**
- `microsoft-ui-xaml` `tools/XamlProfiler/XamlProfilerApp/Services/TapChannel.cs` and `tools/XamlProfiler/XamlProfilerTap/xamlOM.h` (Microsoft's other TAP — not read here).
- TranslucentTB `ExplorerTAP/VisualTreeWatcher.cpp` (mutation/event handling — not read).
- A dedicated search for `IVisualTreeService::AddChild` call sites to find any insertion demo.
- On-box: enumerate `ShellHost.exe` modules and attempt `VisualDiagConnection1..N` to determine the real endpoint flavor for the Quick Settings island.