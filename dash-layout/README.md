# dash-layout

窗口布局：接管壳的 `root` 槽，把 WKWebView 和 `sidebar` 槽摆好。

```
root（本插件占）
└─ NSSplitViewController
   ├─ sidebar 槽（dash-sidebar 占；没人占就整个分栏项都不装）
   └─ WKWebView（壳的那一个，从保管箱借用）
```

## 为什么是 AppKit

`NSSplitViewItem(sidebarWithViewController:)` 白送这些东西：材质（macOS 26 的
Liquid Glass）、分隔条、拖拽调宽、双击复位、宽度 autosave、收起动画、以及工具栏里
跟随 divider 的 `NSTrackingSeparatorToolbarItem`。用 SwiftUI 的 `HSplitView` 重画一遍
只会得到一个更差的仿制品。所以 root 槽的形状是 **AppKit 包在 SwiftUI 里包在 AppKit 里**
（`NSViewControllerRepresentable`）——丑，但值。

**别覆写 `loadView()`**：`NSSplitViewController` 的默认实现会把自己的 `splitView` 装成
`view`，换成一个空 `NSView` 等于把分栏整个丢了，窗口会全白。

## WebView 的归属

WKWebView 实例归**壳**，放在保管箱（`DashObjects.Key.webView`）里，本插件只借用排版。
两个理由：

1. 壳的终极逃生舱（本插件缺席时的全出血网页模式）要用同一个实例，页面才不重载；
2. 本插件热替换时页面也不重载——M2 断言 9 实测：换代后 `window` 上的 JS 状态原样还在。

`navigationDelegate`/`uiDelegate` 同样归壳，所以计划 §10-R5 说的"新世代必须重设 delegate"
在这里根本不存在。

## 导出给下游的东西

- `public protocol DashConversationSurface` —— 会话展示面（选中会话 / 新建 / 打开设置）。
  **接口住在消费者侧**（1×N 规则）：拥有 WebView 的是本插件，所以协议定义在这里，
  随 `DashLayout.swiftmodule` 传给 dash-sidebar。SDK 只放内核词汇，生态词汇由插件自带。
- 实例经保管箱的 `DashObjects.Key.conversationSurface` 传递。

## 工具栏

归本插件（计划原本写"留壳"）：`NSTrackingSeparatorToolbarItem` 要 splitView，而 splitView
在这儿。壳只留菜单——⌘, 走 EventBus 的 `dash.menu.command` 广播出来，本插件接住再调
会话展示面。壳喊话，有能力的插件干活。
