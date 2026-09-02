# status-indicator —— 会话状态符号的选型对比台

侧边栏每行行首那个 20pt 状态槽里画什么。`Variants.swift` 用真实的行几何
（行高 32、槽 20、槽→标题 4、标题 13pt、时间 10pt tertiary）和真实的 sidebar 材质
（`NSVisualEffectView` `.sidebar`），把几组候选并排画在同一张图里，底下再放一排
24pt 的放大版只看形。**同图对比比跨截图稳**：材质、字号、间距全部一致，
差异只剩符号本身。

running 一律是系统 spinner，不参与选型（那一档没有争议）。

## 怎么跑

```sh
cd docs/spikes/status-indicator
swiftc -O Variants.swift -o Variants
./Variants --light &   # 或 --dark；不带参数跟随系统
../../../tools/shot.sh   # 截下来对比
```

`Variants` 是编译产物，已 gitignore。

## 定稿

`F`，已落进 `surf-sidebar/swift/StatusIndicator.swift`：

| 状态 | 符号 | 颜色 | 字号 / 字重 |
|---|---|---|---|
| 待批准 | `hand.raised` | orange | 13 regular |
| 待回答 | `questionmark` | blue | 13 semibold |
| 出错 | `exclamationmark.triangle` | red | 13 regular |
| 跑完了 | `checkmark` | green | 12 semibold |

- 淘汰 `*.circle.fill`（对照组 `A`）：圆底那块实心色在一列灰字里像红绿灯。
- 问号与勾不加粗（`F1`）时在描边符号旁边显虚；举手换实心（`F2`）又太重。
- 勾退到 12pt：它自带宽度，同字号下比另外三个显大一圈。

## 截图

- `light.png` / `dark.png`：第一轮，圆底 vs 裸符号的粗筛。
- `final-light.png` / `final-dark.png`：`A / F / F1 / F2` 终选，两种外观各一张。
