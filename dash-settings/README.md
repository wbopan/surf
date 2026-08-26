# dash-settings

一扇真正的原生设置窗口：**窗框、导航、控件全是 AppKit/SwiftUI**，不加载任何网页。
数据面由跑在 dsh 进程里的 node 半边直接消费 host 服务（`ctx.settings` /
`ctx.llm` / credentials），桥上只走 JSON 快照与动作。

权威计划在 [`docs/dash-settings-plan.md`](../docs/dash-settings-plan.md)——
动手前先读它，尤其 §1（三条走不通的路，别重走）、§4（编辑器语义）、§5（三条红线）。

**当前进度：M0～M5 全部完成**，功能可用。数据面已用探针端到端验过
（见下面「怎么验它」），SwiftUI 那一面还欠一次人眼过目。

```
lib/index.js   快照往下推（describe → 有序 JSON）、单字段 op 往上收、ack 配对
lib/models.js  模型页数据面：llm × credentials 运行时嵌套，缺了只是那一页不出现
swift/         SettingsSchema/JSONValue（解码）· SettingsModel（状态）·
               FieldView/ScalarListEditor（七种编辑器语义）·
               NamespacePage/GeneralPage/ModelsPage（三类页面）· FieldNotes（注解表）
tools/probe.mjs  不开窗口、不碰屏幕，直接当"壳"连桥验数据面
```

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

## 字段文案从哪来

**schema 里一个字都没有**——上游 meta 的全集就 `required/default/role/min/max/step`，
没有 description，也没有"该不该给人看"。所以渲染是**纯 schema 驱动**（字段永远齐、
新 ns 自动出现），文案与「通用」页的精选来自一张手写的薄注解表
[`swift/FieldNotes.swift`](swift/FieldNotes.swift)：注解命中就用人话，
没命中就把键名机械美化一下照常渲染。

**不刮上游 web 产物**（计划 §1.3）：那是把别人的构建输出当 API 用，
升一次 dsh 就可能碎，而且碎得很安静。

## 怎么验它

```sh
node dash-settings/tools/probe.mjs              # 快照概览：ns / 字段数 / 覆盖数 / revision
node dash-settings/tools/probe.mjs --ns shell   # 某个 ns 的 schema 与值
node dash-settings/tools/probe.mjs --providers  # 模型页的数据
node dash-settings/tools/probe.mjs --set        # 写入 / 回读 / 乐观锁冲突 / 还原
```

数据面全跑在 dsh 进程里，跟 SwiftUI 没有半点关系——用截图验它等于让 21KB 的 JSON
通过一张 PNG 汇报自己。探针在屏幕锁着时照样能跑，实测已经靠它揪出过一个真 bug
（`refresh` 只重推 settings 不重推 providers，模型页会永远停在"llm 不在场"）。
