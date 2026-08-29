# clam-header

> **⚠️ 2026-08-29 起已停用**，代码原样保留。实现出来的效果不满意，退回 dsh 自己的
> web header：`surfclam/cordis.patch.yml` 里那两行被注释掉了，解开再重启 dsh 即恢复。
> 它退休后 client 半边的折叠自动还原，窗口标题与工具栏那四格随之消失。
>
> **下面全文是现在时，说的是它在役时的样子。** 读的时候记住：这些行为眼下一条都不在
> 生效，`clam.window.title` / `clam.layout.titlebarMetrics` 两条通道当前只有 clam-layout
> 一端在场。

把 dsh 主内容区顶上那条 web header 搬进原生：会话标识走窗口标题，动作走工具栏，
网页那条就地折叠。插件退休页面自动还原。

```
window.title      会话标题        ← Mail / Notes 那条裸文字
window.subtitle   锁定的 preset · 后台任务计数
toolbar 贡献       [子代理▾] [Chat|Trajectory] [mode▾] [导出]
```

## 不占 `conversation.session.header` 槽

路线 A（占槽、原生视图塞回页面）出局。槽里那块地由页面排版，塞进去的原生视图拿不到
工具栏的显示模式、玻璃分组、徽标和溢出退让——等于把 AppKit 白送的东西全丢掉，
再用 SwiftUI 仿一个更差的。改成"web header 折叠 + 工具栏贡献"，排版全归 AppKit。

折叠靠 client 半边一条 CSS，锚点是 `[data-slot="conversation.session.header"]`
（**不是** `[data-phase] > header`，中间隔着 slot outlet）。槽 outlet 的
`data-slot` 是槽系统的一等契约，比任何 hash 化类名都稳。

## 一条设计原则决定了所有取舍

**圆胶囊是"可操作"的承诺。** 工具栏那四格每一格都真能按；按不动的东西一律退进
`window.subtitle`：

- 锁定后的 **agent preset** —— 会话跑过一轮就锁死，做成按钮等于承诺一件按下去不会
  发生的事；
- **后台任务** —— 上游 ui-jobs 自己也只给看不给停。

标识也是这么出的胶囊：曾经用 `NSHostingView` 画面包屑，被 AppKit 套了一枚玻璃胶囊，
而它并不可点。搬到 `window.title` / `window.subtitle` 之后，字体、字重、截断全归系统。

两条相关的硬事实：`window.title` 在统一工具栏里是**贪心**的，会为长标题留截断空间、
把 `content·leading` 的贡献一路顶到 `flexibleSpace` 那侧——想紧挨标题放东西只能用
subtitle；而 `subtitle` **只吃 `String`**，放不了图标（SF Symbols 是图片资源，
不是可嵌进字符串的字体）。

## 两条通道，判据是"真相住在哪个进程"

| 事实 | 通道 | 为什么 |
|---|---|---|
| active view（Chat / Trajectory） | 页内桥 | 真相在浏览器进程 |
| 会话、preset、jobs、子代理树 | node 半边 `lib/dsh-source.js` | 真相在 dsh 进程 |

node 半边订宿主服务与事件，投影经桥推 JSON；Swift 只管画和发动作。走 `ctx.apiProxy`
而不是 `sessions`/`workspaceRegistry`——后者那条路要自己重写冷会话合并、四个派生字段
和 fork 的轮次边界，而 `apiProxy` 就是 `/api` 那套方法的同进程实现本体。

**拓扑与流量分家**：`metadata` 一变就重建整条工具栏，所以徽标数字、菜单内容、
段控选中态、显隐都走活通道 `clam.toolbar.update`，不走 metadata。

## 文案：`swift/Strings.swift`，语言跟 dsh 走

用户可见的字全在 `struct L` 里（zh / en 并排一行），语言的唯一权威是 dsh 的
`locale` 设置（决议链见 `docs/clam-i18n-plan.md` §3）。日志一律留中文——读它的是
蹲在终端前的人，跟着界面语言变只会让排错时对不上账。

换语言时两条路各走各的，**这正是上面那条"拓扑与流量分家"的直接推论**：

| 什么 | 怎么跟上 |
|---|---|
| 四格的 `label`（拓扑键） | `HeaderPlugin` 订 `clam.locale`，**重新贡献**同一组 `(owner, id)`：就地覆盖、位置不变，`ToolbarItemState` 按 key 记账所以活状态不丢 |
| 菜单内容、tooltip、`window.subtitle`（流量） | `HeaderToolbarSync.push()` 第一句读 `model.strings`，于是语言对那圈 `withObservationTracking` 就是一次普通的 model 变化 |

两件事**不翻**：段控开局那两个名字（`Chat` / `Trajectory` 只是页面报来之前的占位，
真名单是 dsh 按它自己的 locale 给的），以及会话标题、preset 名这些数据——只有
"它没有标题时叫什么"这类兜底词归我们。「子代理」「后台任务」「一次性 / 可继续」
这些词是**照抄 dsh 词典**的：同一个会话在两半界面上出现时用词必须是一个。

`error` 帧里也一个显示文案都没有：node 推 `{action, code?, message}`
（`code` 是我们自己认领得了的原因码，`message` 是上游原话），文案归 Swift。

## 子代理 catalog 是唯一入口

**子代理会话不进侧边栏**（上游 README：parent header catalog 是它们唯一的导航入口），
所以这一格不是锦上添花——砍了就等于砍掉访问子代理会话的全部路径。

面包屑末段带计数下拉，子代理段是兄弟切换器，点开是原生重画的 catalog 树。
`session.list` 的契约原话是 "v1 returns everything"，一次就有整棵树，
所以展开是纯本地操作、零往返。细节见 `docs/native-subagent-catalog.md`。

## 工具栏底下那条带子归页面画

不是将就。原生三条路全试过都不给"纯模糊无装饰"：`NSVisualEffectView` **采不到**
WKWebView 那层 remote layer 的像素；`NSGlassEffectView` 采得到，但自带一圈关不掉的
边缘高光；macOS 26 的 scroll edge effect 由私有的 `NSScrollPocket` 承载、
**形状跟着浮在上面的元素走**，本来就不是一条通栏带子（它此刻正长在工具栏项的胶囊里）。

所以带子是 `lib/client.js` 里一条 `backdrop-filter`——**页面 compositor 是唯一看得见
内层滚动的东西**。代价是滚动时边缘会闪：backdrop-filter 每帧重新快照，且只采样元素
**内部**的背景，边缘天生缺料（原生 `CABackdropLayer` 有 `bleedAmount`，CSS 没有）。
`will-change: transform` 压掉了合成抖动那一半。
