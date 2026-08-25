# dash-sidebar

原生会话侧边栏。占 dash-layout 的 `sidebar` 槽；dash-layout 不在则整个插件不挂载
（cordis 的 `inject` 会让它安静地等着）。

## 数据面

`SessionStore`（DSHKit）由本插件创建，但**存进保管箱、跨世代复用**：

```swift
host.objects.object("dash.sidebar.sessionStore", as: SessionStore.self)
```

之所以敢往箱里放一个非 SDK 类型，是因为 DSHKit 和 DashSDK 一样是随 app bundle 分发的
**共享 dylib**（M3），类型身份跨世代稳定。收益是热替换时列表不闪、WS 事件流不断，
而壳一行业务代码都不用写。端点变了（dsh 换端口回来）就丢掉旧的重建——base URL 也记在
箱里供比对。

把数据面搬进 TS 半身是 M10 的事：收益是架构一致与 iOS 远程线地基，代价是要赌 dsh 内部
服务的 preview 稳定性。

## 从壳迁进插件时踩到的坑

- **`#if DEBUG` 在插件里永远不成立**：插件由壳在运行时用命令行 swiftc 编译，没有 `-DDEBUG`。
  底部那条橙色 DEV BUILD 改看壳的 bundle id 后缀（`io.wenbo.dash.dev`）。
- **`@MainActor` 要自己标**：`SessionStore` 是主线程类，而 `dash_plugin_entry` 是 nonisolated
  的 C 入口，所以类不能整个标 `@MainActor`，只能标到具体方法上。
- 选中高亮活过热替换靠 `host.store` 存 `selectedSessionId`。它只是"页面把 `currentSession`
  报回来之前先亮哪一行"的装饰状态，丢了不心疼——真相在 dsh 侧。
