# dash-settings

一扇真正的原生设置窗口：**窗框、导航、控件全是 AppKit/SwiftUI**，不加载任何网页。
数据面由跑在 dsh 进程里的 node 半边直接消费 host 服务（`ctx.settings` /
`ctx.llm` / credentials），桥上只走 JSON 快照与动作。

权威计划在 [`docs/dash-settings-plan.md`](../docs/dash-settings-plan.md)——
动手前先读它，尤其 §1（三条走不通的路，别重走）、§4（编辑器语义）、§5（三条红线）。

**当前进度：M0（接线）**。窗口能开、让位能让，内容是占位视图。

## 为什么数据面在 node 半边而不是 Swift 直连 HTTP

`/api/*` 那套 wire 是给远程浏览器准备的窄面，host 服务面更宽。我们本来就在 dsh
进程里，没理由从窄的那头进；附带好处是进程内事件（`settings/document-updated`、
`llm/adapters-updated`）直接可订，不必再开一条 SSE，Swift 侧连 DSHKit 都不需要。

## 缺席时会发生什么（这是设计好的，不是意外）

`settings` 服务是**硬 inject**：服务不在，整个插件不挂载 → Swift 半边不会去占
`DashObjects.Key.settingsOwner` → dash-layout 见无主，⌘, 回落到 dsh 自己的页内
modal。一个设置界面缺席时的正确姿态是让位给还能用的那个，不是开出一扇空窗。

`llm` / `credentials` 反过来：它们缺席只该让「模型」那一页不出现，不该连累整扇窗口，
所以**不写进静态 inject**，而用 `ctx.inject([...], cb)` 运行时嵌套（M4）。
这个 cordis fork 的 `inject` 只有数组与 intercept-config 两种形态，
没有 `{required, optional}`——嵌套是它表达可选依赖的唯一方式。

## 没有 client 半边

设置的渲染完全在原生这边，页面里什么都不改。顺带白捡一条：不必踩
「`__ModuleLoader__.load({id})` 的 id 必须逐字等于包名」那个坑。
