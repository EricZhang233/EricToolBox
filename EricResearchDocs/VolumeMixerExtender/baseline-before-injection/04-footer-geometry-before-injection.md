<!-- 冻结快照：内容逐字摘录自 docs/reference/raw-outputs.md §06 -->

> **来源**：`docs/reference/raw-outputs.md §06`（逐字摘录，未改写）
> **采集时间**：2026-10-03
> **环境**：Windows 11 build 26300.9550，交互会话 2，System XAML
> **用途**：★ 注入前基线几何：底栏 358x48、模型按钮 94x40、右侧约 256x40 空位。所有"位置是否正确"的判断都以它为准。

---

## 06 · Footer 几何（recon/footer-geom.ps1）

```text
panel closed -> opening with Win+Ctrl+V
panel = 0x000100FE
xaml host = 0x000302A6

=== 1. panel rect ===
  panel window : ControlCenterWindow rect=(2176,0 384x1478)

=== 2. locate AutomationId = Footer ===
  footer = Group |  | id=Footer | LandmarkTarget (2189,1417 358x48)

=== 3. parent chain (with rects) ===
  [0] Group | 声音输出 | id=PageWindow | NamedContainerAutomationPeer (2189,1065 358x400)
  [1] Group | 快速设置 | id=ControlCenterRegion | NamedContainerAutomationPeer (2188,1064 360x402)
  [2] Pane |  | id= | Windows.UI.Input.InputSite.WindowClass (2176,0 384x1478)
  [3] Pane | 快速设置 | id= | ControlCenterWindow (2176,0 384x1478)
  [4] Pane |  | id= | #32769 (0,0 2560x1510)

=== 4. footer subtree (rects) ===
  Group |  | id=Footer | LandmarkTarget (2189,1417 358x48)
    Button | 更多音量设置 | id= | Button (2193,1420 94x40)
      Text | 更多音量设置 | id= | TextBlock (2204,1435 72x9)

=== 5. all direct children of the Footer's PARENT (layout context) ===
  parent = Group | 声音输出 | id=PageWindow | NamedContainerAutomationPeer (2189,1065 358x400)
    - Button | 后退 | id=BackButton | Button (2193,1069 40x40)
    - Text | 声音输出 | id=PageTitleText | TextBlock (2237,1084 56x10)
    - Group | Windows 徽标键，控件， | id= | NamedContainerAutomationPeer (2301,1081 65x16)
    - Pane |  | id=ListContent | ScrollViewer (2189,1113 358x304)
    - Group |  | id=Footer | LandmarkTarget (2189,1417 358x48)
```

**可用空间计算**

| 量 | 值 |
|---|---|
| Footer 矩形 | `x=2189, y=1417, 358 x 48` |
| Footer 右边界 | `2189 + 358 = 2547` |
| 「更多音量设置」按钮 | `x=2193, y=1420, 94 x 40`；右边界 `2287` |
| **按钮右侧空位** | **`x = 2287 … 2547` → 约 256 x 40**，够放一个居右的入口 |

---

