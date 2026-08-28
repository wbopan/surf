# Liquid Glass 对照台

**问题**：偏好设置里的按钮和分段控件为什么"没有 Liquid Glass 效果"？是不是我们
没启用、或者用错了 API？

**答案分两层。**

**第一层**：Liquid Glass 是"浮在内容之上那一层"的材质,不是所有控件的材质。工具栏、
sidebar、sheet、浮动控件条自动获得它;嵌在 `Form` 里的表单控件按设计拿不到。

**第二层**(更要紧,一开始漏了):那块刺眼的蓝**不是"玻璃没生效"**,而是 AppKit 对
分段控件的两种**角色**给了两种外观。macOS 27 起可以显式指定——`NSSegmentedControl.Role`
的 `.tabs`(浅色凸起,像标签)与 `.valueSelection`(accent 填充);SwiftUI 这边就是
`.pickerStyle(.tabs)` 与 `.pickerStyle(.segmented)`。**所以蓝色去得掉。**
工具栏里的分段控件之所以看着"是玻璃的",一半是外面那层玻璃胶囊,另一半就是它
自动用了 tabs 角色。

```sh
docs/spikes/liquid-glass/run.sh      # 编译并打开（约 3s），产物在 build/，已 gitignore
```

## 实测结论

一张图里同时放了五组，跑一次就看得见：

| | 选中态 |
|---|---|
| `Form` 里的 `.segmented` | **实心 accent 蓝** |
| `Form` 里的 `.tabs`（macOS 27+） | **白色凸起，无蓝** |
| `Form` 里的 `.segmented` + `.glassEffect()` | 灰色凸起（玻璃背景压掉了 accent，属于副作用不是设计意图） |
| **工具栏**里的 `.segmented` | 白色凸起 + 外面一层玻璃胶囊，每组控件单独一个胶囊 |
| `Button` 默认 / `.glass` / `.glassProminent` | 圆角 / 更圆的玻璃胶囊 / 实心 accent |
| `.glassEffect()` 手动上玻璃 | 真玻璃：底下垫彩色渐变时能看到折射 |

**同一个控件，换个层就换个材质**——这是整件事的关键。AppKit 按控件类型自动把
工具栏里的分段控件、弹出按钮、搜索框各自包进独立的玻璃元素，不需要写一行代码；
而内容层的控件不参与这个分组。

## 因此，在 clam-settings 里

- 窗口工具栏那四个标签（`NSTabViewController(tabStyle: .toolbar)`）**已经是玻璃**。
- 页内分栏用 `TabView`（= `NSTabView`）而不是 `Picker(.segmented)`：它是导航层的
  控件，标签是玻璃凸起的一枚、没有 accent 色，还自带那块圆角内容面板。
- 「外观」那一行用 `.pickerStyle(.tabs)`：**借的是它的外观，不是它的语义**。严格说
  「浅色/深色/跟随系统」是选值(`.valueSelection`)，但这一行有「外观：」这个标签把
  语义钉死了，不会被读成导航，换来的是整页没有一块突兀的饱和色。
- 想手动上玻璃有 `.glassEffect(_:in:)` / `GlassEffectContainer` / `.buttonStyle(.glass)`
  （SDK 里都有，见 `SwiftUICore.swiftinterface`），但**别往表单里塞**——玻璃嵌在
  内容里会跟它下面的内容抢注意力，这正是 Apple 把它限制在浮层的原因。

## 工具链前提

Xcode 27 / MacOSX27.0.sdk / `MACOSX_DEPLOYMENT_TARGET = 27.0`。用旧 SDK 构建的 app
会整体回落到旧外观，那才是真的"没启用"。

**部署目标要三处一起改**（少一处就静默不生效）：`project.yml` 的 `deploymentTarget`
与 `MACOSX_DEPLOYMENT_TARGET`、`scripts/build-modules.sh` 的 `TARGET`、
`CompilerService.targetTriple()` 的 fallback。插件的三元组是从 ClamSDK 的
`.swiftinterface` 头里抄的，所以真正说了算的是第二处。
