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

工具栏上的按钮**全部来自 `toolbar` 贡献槽**，本插件自己一颗都不放。
完整约定写在 `swift/LayoutSplitController.swift` 底部那段注释里，摘要：

| metadata | 拿到什么 | 什么时候用 |
|---|---|---|
| `label` | 标题 + 无障碍名 | 必填 |
| `symbol` | `NSToolbarItem` + `isBordered`，玻璃观感白送 | 有 SF Symbol 就给 |
| `menu` | `NSMenuToolbarItem` + 系统菜单（勾选态、键盘、溢出全白送） | 点开是一串开关 |
| `event` | 点击广播的主题名（缺省 `dash.toolbar.activate`） | 走 `symbol` 那条时 |

`menu` 的类型必须是 `@convention(block) (NSMenu) -> Void`：它要装在 `[String: Any]` 里
穿过 dylib 边界，ObjC block 是个货真价实的对象，装箱取箱都稳；裸 Swift 闭包的函数类型
元数据跨 image 取回来是碰运气。菜单**每次弹出前重建**（`ContributionMenuDelegate`），
所以 block 里读什么状态都是当场的，勾选态不会停在上次打开时的样子。

槽名与默认主题从 `public enum LayoutToolbar` 引（`LayoutSplitController` 自己是
internal，它是实现细节）。

**「新建会话」不在工具栏上**：那一格让给了 dash-sidebar 的「筛选」。
`LayoutPlugin.newSessionTopic` 这条主题仍然在——⌘N 与第三方按钮都 emit 它。
