# Liquid Glass 对照台

**问题**：偏好设置里的按钮和分段控件为什么"没有 Liquid Glass 效果"？是不是我们
没启用、或者用错了 API？

**答案**：没用错，也不需要启用。**Liquid Glass 是"浮在内容之上那一层"的材质**，
不是所有控件的材质。工具栏、sidebar、sheet、浮动控件条自动获得它；嵌在 `Form`
里的表单控件按设计就不该有，也拿不到。

```sh
docs/spikes/liquid-glass/run.sh      # 编译并打开（约 3s），产物在 build/，已 gitignore
```

## 实测结论

一张图里同时放了五组，跑一次就看得见：

| | 长相 |
|---|---|
| **工具栏**里的 `Picker(.segmented)` | 药丸形，外面套一层玻璃胶囊，每组控件单独一个胶囊 |
| **`Form` 里**的同一个 `Picker(.segmented)` | 方角、扁平、无胶囊；选中态是一块实心 accent 色 |
| `Button` 默认（`.bordered`） | 老样子的圆角按钮 |
| `.buttonStyle(.glass)` | 更圆的胶囊，有玻璃边缘 |
| `.glassEffect()` 手动上玻璃 | 真玻璃：底下垫彩色渐变时能看到折射 |

**同一个控件，换个层就换个材质**——这是整件事的关键。AppKit 按控件类型自动把
工具栏里的分段控件、弹出按钮、搜索框各自包进独立的玻璃元素，不需要写一行代码；
而内容层的控件不参与这个分组。

## 因此，在 dash-settings 里

- 窗口工具栏那四个标签（`NSTabViewController(tabStyle: .toolbar)`）**已经是玻璃**。
- 页内分栏用 `TabView`（= `NSTabView`）而不是 `Picker(.segmented)`：它是导航层的
  控件，标签是玻璃凸起的一枚、没有 accent 色，还自带那块圆角内容面板。
- 表单里的行**不追求玻璃**。「外观」那一行曾经是分段控件，那块实心 accent 蓝不是
  "玻璃没生效"，是内容层控件的正常样子；换成下拉框只是为了跟同页另外四行一致。
- 想手动上玻璃有 `.glassEffect(_:in:)` / `GlassEffectContainer` / `.buttonStyle(.glass)`
  （SDK 里都有，见 `SwiftUICore.swiftinterface`），但**别往表单里塞**——玻璃嵌在
  内容里会跟它下面的内容抢注意力，这正是 Apple 把它限制在浮层的原因。

## 工具链前提

已经满足，记下来免得以后怀疑：Xcode 27 / MacOSX27.0.sdk / `MACOSX_DEPLOYMENT_TARGET
= 26.0`。用旧 SDK 构建的 app 会整体回落到旧外观，那才是"没启用"。
