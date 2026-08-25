# dash-settings

原生设置窗口：窗框、导航列表、关闭都归 AppKit，内容区是一块只画设置的
WKWebView，渲染 **dsh 官方的 settings 面板**——我们不复制 Models 的 provider
编辑器、不复制 Plugins 的卡片，上游改版自动跟随。

## 为什么内容是 web 而不是原生

数据面其实完全够原生用：`settings.describe/update/replace/mutate`、
`credentials.*`、`llm.providers/models/discoverModels` 全是 loopback RPC，
DSHKit 的 `DSHTransport.call` 直接能打；schema 也只有 8 种节点
（`const/number/string/object/union/boolean/array/dict`，meta 只有
`default/required/min/max/step/role`），写个 schema→SwiftUI 渲染器是天级工作量。

**但设置页远不止 schema 表单**：Models 段的 provider 编辑器、API key 流转、
模型发现、onboarding 向导，Plugins 段三张带控制器的卡片，插件清单——这些是手写
React，原生重写等于跟上游语义永久赛跑。所以第一版只把**窗框和导航**原生化
（"原生感"的大头），内容留在 web；将来想把哪一段换成原生就换哪一段，
因为导航是原生的，替换粒度天然是 section。

## 已证伪：注册进 `root` 槽，自己声明 `settings.*`（别再试了）

最初的设计是让设置页 shadow 掉官方 AppFrame——`root` 是 single 槽，压低
priority 就能赢——然后由我们重新声明 `settings.section` 等槽，官方各 section 的
`ctx.slots.inject("settings.section", …)` 会在我们的容器里重新注册。这样能得到
一个没有 modal、没有遮罩、不渲染主界面的干净设置页。

**两步都撞墙，第二步致命**：

1. `single slot "root" already has a registration at priority 0 (registered by z5)`
   ——同优先级的第二条注册是**报错**不是替换。加 `priority: -100` 可解
   （数值越低越先渲染，官方 ui-subagent 用 -10 抢自己的座）。
2. `slot "settings.header" is already declared (by an entry in "sidebar.settings")`
   ——**槽声明是 load-time 的，绑在 entry 的注册上，与这个 entry 是否胜出、
   是否渲染无关**。官方 SettingsRoot 注册在 `sidebar.settings` 上，哪怕它整条
   祖先链都没被渲染，它 declare 的 6 个 `settings.*` 依然占着名字。

想反过来"抢先声明"也不行：撞车的一方是**报错退出**，先声明只会让
ui-settings-general 整个插件加载失败，连 General 段一起赔进去。

`StoredEntry` 是 render-erased 的（拿不到组件），`ctx.slots.renderSlot` 运行时
只认 `'root'`——所以"不声明也能渲染别人的槽"这条路同样不存在。

结论：**设置面板的渲染树只能由官方那条链产出**，我们能做的是改变它的呈现形态
（见下）。ledger 只读那部分（`entries`/`subscribe`/`getVersion`/`resolveSlotLabel`）
是公开且好用的，导航数据仍然走它，不从 DOM 刮。

## 现在的做法

`?dash-settings=1` 时：

- 页面照常加载官方渲染树，但用 CSS 把 AppFrame 的其余部分收掉，只留设置面板；
  面板去掉遮罩、圆角、阴影，铺满整个窗口——它本来就是这个窗口的全部内容。
- 面板由页内自动打开（点 `button[aria-haspopup="dialog"]`，官方的开关是组件
  局部 state，没有公开服务）。
- 导航目录从 slot ledger 投影后上报给壳（`window.webkit.messageHandlers.dashSettings`），
  由原生列表渲染；壳切页经 `window.__dashSettings.show(id)`，落到点击对应的
  导航行——`display:none` 的元素照样能 dispatch click，React 合成事件正常触发。

**代价照实说**：这一版依赖 hash 化 CSS module 的语义后缀（`[class*="_panel"]`
这类，与仓库其它插件同一套防御式写法），以及"面板 nav 的顺序 = ledger 的
order 顺序"这条假设。升级 dsh 后先核对这两处。
