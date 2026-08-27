# 主内容区 header 原生化：实施计划

配套调研见同目录那份 header 调研文档。**本文只管"怎么做"**，并就地更正
调研里三处已经过时或已被证实的结论。

写于 2026-08-26，dsh `0.1.1-rc.2`。dsh 侧行号指
`~/.dsh/profiles/node_modules/@deepseek-ai/` 下的包。

---

## 0. 先更正调研文档的三条

调研成文时，仓库还没有贡献槽、页内桥还带白名单。之后两个提交把它们都补上了
（`1dd7211` + `43a6a41` 贡献槽，`c204332` 页内桥去白名单），于是：

| 调研里的说法 | 现在的事实 |
|---|---|
| §5「工具栏项目前是硬编码在 delegate 里的，没有槽的概念」 | **已有 `toolbar` 贡献槽**，约定写在 `dash-layout/swift/LayoutSplitController.swift` 的扩展注释里。自家"新建会话"已经降级成一条普通贡献 |
| §6「`handleBridgeMessage` 是写死的类型白名单，因此需要壳改一次」 | **已去白名单**。未知 type 一律广播成 `dash.page.<type>`（`MainWindowController.swift:711` 附近的 `default:` 分支）。**本计划全程不需要改壳** |
| §4「第三方占 `conversation.session.header` 拿不到同一个 chat store —— 推断，未实测，优先级最高」 | **已由源码证实，路线 A 出局**。证据见下一节 |

调研第 1、2、3 节（DOM 锚点、四个子槽的 kind 与注册者、四类内容的 dsh 侧出处）
复核过，全部仍然成立。

---

## 1. 路线 A 出局：三条源码证据

调研把这一条列为"整个方案的分叉点，动手前应先证伪"。不用跑了，读源码就够：

1. **handle 是 `apply` 里的局部变量。** `const chatStore = createChatStore();`
   在 `dsh-client-ui-conversation/lib/client.js:9908`，此后被 `conversation.session`、
   `conversation.session.header`、`conversation.view#chat`、`details` 四处注册
   以 `store: chatStore` 共享。它从不导出——该包的 `exports` 只有
   `ConversationController` / `apply` / `inject`，对外服务面 `ctx.conversation`
   （`IConversation`）是 send / cancel / updateQueue / loadOlder + input + blocks，
   **一个 view 相关的成员都没有**。

2. **传工厂 = 铸新 handle。** `SlotRegistry` 的类注释明写它负责
   "exclusive-factory minting (`store: createXxxStore` becomes a per-entry handle)"，
   而实例缓存的键是 **handle × scope key**（`dsh-client-runtime/lib/types/client/slots.d.ts`
   顶部与 `contract/store.d.ts` 的 `EngineStoreHandle.create` 注释）。
   第三方自己 `createChatStore()` 得到的是另一个 handle，于是另一个实例：
   写进去 ui-conversation 的会话体读不到。

3. **框架发的 session kit 里没有它。** 每个 session 域槽组件白拿的只有
   `useSession`（`SnapshotSelectorHook<ConversationSnapshot>`——**runtime 的会话镜像**，
   不是 chat store）、`sessionId`、`useProjection`
   （`dsh-client-runtime/lib/types/client/index.d.ts:69-78`）。
   `view` 字段住在 ui-conversation 私有的 `ChatStoreState` 里，不在这三样中。

**顺带堵掉第四条歪路**：`createChatStore` 声明了 `persist: "dsh.conversation.chat"`，
所以 view 确实会落 localStorage。但 rehydrate 只发生在实例创建时，外部写 storage
不会即时生效，切换 tab 得等下次实例重建——不是通道，是陷阱。别去试。

于是**路线 B（保持内置 header 挂载 + CSS 折叠 + ARIA 驱动）是唯一可行路线**，
本计划按它展开。

### 顺手记下 tabs 的确切形状

`ConversationSessionHeader`（`client.js:7321`）里 tab 按钮长这样：

```js
tabs.length > 1 && <div className={…tabs} role="tablist">
  {tabs.map(viewTab => <button type="button" role="tab"
      aria-selected={viewTab.id === active?.id}
      onClick={() => { actions.setView(viewTab.id); }}
      >{viewTab.label}</button>)}
</div>
```

三件事因此确定：

- **驱动就是 `dispatchEvent('click')`**，onClick 是普通 React 合成事件，
  零高度容器不影响程序化派发（`pointer-events:none` 只影响 hit-testing）。
- **DOM 里没有 view id**，只有本地化过的 `label` 文本。原生侧因此按**下标**认人，
  不按 id——投影和驱动都用下标，两边就永远对得上。
- **`aria-selected` 是唯一的选中态真相**，`resolveActiveView` 还会把失效的持久化
  选择回落到 `chat`，所以别自己算，读 DOM 就好。

---

## 2. 架构决定

### 2.1 新插件 `@wenbo/dash-header`，不塞进 dash-layout

三个半边都在一个包里：

```
dash-header/
  lib/index.js     node 半边（createSwiftPlugin；H1~H4 只是个空壳，留给 H5 的数据面）
  lib/client.js    浏览器半边：tabs 投影（读）+ window.__dashHeader（写）+ 折叠 CSS
  swift/           Swift 半身：@Observable model + NSSegmentedControl，贡献进 toolbar 槽
```

理由和 dash-sidebar 一样：dash-layout 管的是"排版和开槽"，header 是**一位贡献者**。
把它写进 dash-layout 等于把刚建立的贡献槽规矩自己破了一次。

**协议两端同包**：client 半边装 `window.__dashHeader`，Swift 半身自己
`evaluateJavaScript` 调它。**不扩 `DashConversationSurface`**——那是 dash-layout 的
协议，加一个 `setConversationView` 会让 dash-layout 认识 header，白白多一条跨包耦合。
WKWebView 从保管箱取（`DashObjects.Key.webView`，public，LayoutPlugin 就是这么拿的）。

### 2.2 `toolbar` 贡献槽要开两维

现在槽的形状是「所有贡献排在 `.flexibleSpace` 之后、`.toggleSidebar` 之前」——
**全部落在 `sidebarTrackingSeparator` 左边，也就是侧边栏那一侧**。header 的项必须
落在右边（内容侧）。另有一处会硌到：非 SF Symbol 的贡献走兜底路线，
`makeContributionItem` 把 `NSHostingView` 的**尺寸当场冻死**——那条纪律对状态指示器
是对的，但段控的宽度要随 tab 标签文本走（切会话、换语言都会变）。

所以 H1 给 metadata 加两个键，**都缺省保持现状，现有贡献一个字不用改**：

| 键 | 值 | 缺省 | 作用 |
|---|---|---|---|
| `region` | `"sidebar"` / `"content"` | `"sidebar"` | 排在 `sidebarTrackingSeparator` 之前还是之后 |
| `sizing` | `"fixed"` / `"dynamic"` | `"fixed"` | `dynamic` 不冻 frame，交给 `NSHostingView` 的 intrinsicContentSize |

`centered`（走 `toolbar.centeredItemIdentifiers`）**先不加**：它是相对整个窗口居中、
不是相对内容区，有侧边栏时会偏，等 H4 看过实际观感再定。

---

## 3. 里程碑

H1~H4 自足，**不依赖那条还在评估的数据面结论**。H5 才依赖，所以放最后、单独判。

### H0 · 看一眼现状（动手前必做，10 分钟）

`./dev` 起一套，`tools/shot.sh` 截一张。要确认的就一件事：**web header 的 titleRow
此刻和工具栏按钮是怎么共处的**——WebView 全出血 + 标题栏透明，标题行本来就压在
标题栏那条带子里。这张图决定 H4 之后还要不要做 H5（如果标题行现在看着已经没问题，
H5 的性价比就低了）。顺手数一下默认有几个 tab（`tabs.length > 1` 才渲染，通常是
Chat + Trajectory 两个）。

### H1 · `toolbar` 槽开出 `region` / `sizing` 两维

只改 `dash-layout/swift/LayoutSplitController.swift`：

- `toolbarDefaultItemIdentifiers` 按 region 分两段拼：
  `[.flexibleSpace] + sidebar段 + [.toggleSidebar, .sidebarTrackingSeparator] + content段`。
- `refreshToolbarSnapshot` 的签名折进 `region` 与 `sizing`（不然改了这两个键不会重建）。
- `makeContributionItem` 在 `sizing == "dynamic"` 时不写 `hosting.frame`。
- 槽约定注释同步更新——**那份注释是这个槽唯一的文档**，第三方照着它写。

验收：拿现有的"新建会话"贡献临时改成 `region: "content"`，截图确认它跳到了分隔线
右边，再改回来。纯 Swift 改动，存盘 1~3s 热替换，不重启任何东西。

### H2 · dash-header 骨架 + tabs 投影（只读，web header 原样留着）

新包落地，编排表 `dash/cordis.patch.yml` 加一行（**改编排要重启 dsh**）。

client 半边：门控沿用 dash-layout 那套（UA 含 `Dash/` + `?dash-native-sidebar=1`），
常驻巡检 + MutationObserver 盯 `[data-slot="conversation.session.header"]`
（**实施时更正**：不是调研文档说的 `[data-phase] > header`，见 §6.1），投影

```js
{ type: "headerTabs", tabs: ["Chat", "Trajectory"], active: 1, present: true, canExport: true }
```

经 `window.webkit.messageHandlers.dash.postMessage` 上去，壳按去白名单后的通道广播成
`dash.page.headerTabs`。**observer 必须常驻并每轮比对节点身份**——理由与
dash-layout 的 `forceSidebarCollapsed` 一模一样：React 会把 header 整个换成新节点，
绑死旧节点的 observer 会永久失效（CLAUDE.md「踩坑记录」有这条）。

Swift 半身：`@Observable` 的 model 收事件，`NSSegmentedControl`（或 SwiftUI
`Picker(.segmented)`）贡献进 `toolbar` 槽的 `content` 区、`sizing: "dynamic"`。
**选中态必须由 model 驱动，不能靠 metadata 变化**——metadata 一变就重建整条工具栏，
切个 tab 不该有那么大动静。这与 dash-sidebar 的 `AppSidebarModel` 是同一个模式。

验收：web header 和原生段控并排出现，切 tab / 切会话 / 开子代理，两边始终一致。
**这是全计划的关键验证点**，两边并存正是为了能直接对照。

### H3 · tabs 驱动（写）

client 半边加 `window.__dashHeader.setView(index)`：按下标取
`document.querySelectorAll('[role="tab"]')[index]`，`el.click()`。
Swift 段控的 action → `evaluateJavaScript`。

**下标而不是 label**：label 是本地化文本，按它匹配等于把 i18n 变成正确性依赖。
投影和驱动共用下标，DOM 顺序就是唯一的对齐基准。

验收：点原生段控，页面真切换，且投影回来的 `active` 跟上（形成闭环，不做乐观更新）。

### H4 · 只折叠 tabs 那一行

```css
html[data-dash-header-scope="tabs"] [data-slot="conversation.session.header"] [role="tablist"] {
  height: 0; overflow: hidden; opacity: 0; pointer-events: none;
}
```

**实施时的两处偏差**：锚点换成了 `[data-slot=...]`（§6.1）；开关从一个布尔属性变成了
`data-dash-header-scope` 这个**两级**枚举（`"tabs"` 只折 tabs 行 / `"full"` 连 titleRow
一起折），因为 H5 落地后面包屑与 mode 也搬进了工具栏，`"tabs"` 这一级就只剩降级形态了。
两级共用同一套自愈与 token 逻辑。

**只折 tabs 行，不折整条 header。** titleRow（面包屑 + actions + utilities）原样留在
页面里，于是 lineage / actions / utilities 三个子槽的内容一条都不丢，jobs 那种带浮层的
控件也不受影响（调研 §7 明确列了"带浮层的控件不要走 DOM 驱动"）。省下的 ~28px 是纯赚。

**自愈**：`data-dash-native-header` 属性只在 client 半边真的找到了 tablist、
**并且**收到过原生侧的确认之后才加。dsh 升级改了 DOM 就退回今天的样子，
而不是标题栏和页面各画一半。属性值写实例 token，cleanup 只收 token 对得上的
（HMR 的「新实例先启、旧实例后清」，CLAUDE.md 有这条）。

**空会话**：header 自己会挂 `headerHidden` + `aria-hidden`
（`blank && composerPhase === "blank"`）。投影里带上 `present: false`，
原生段控跟着藏，否则新建会话时标题栏上会挂着上一个会话的 tab。

到这里就该停下来看效果。**H4 完成 = 一个自足的、可以长期就这么用的形态。**

### H5 · 标题 / mode / Session log / jobs（依赖数据面结论，单独判）

四项在 dsh 侧都有一等契约（调研 §3 记了出处：`agentPreset.list/.select` 是 RPC，
jobs 在 mux 事件帧里，导出是 `/api/session.export`，面包屑在会话摘要里），
**但"经由哪一层拿"取决于那条正在评估的线**。dash-sidebar 的 node 半边
（`lib/dsh-source.js` 订 `ctx.apiProxy`）已经是现成样板，dash-header 的
`lib/index.js` 照抄即可。

做这一步才需要折叠整条 header（`data-dash-header-scope="full"`）。
**jobs 原生重画、不要去点隐藏按钮**——它是 popover，锚到零尺寸元素上位置会错。

~~WebView 顶部接 `window.contentLayoutGuide`~~ —— **不做，见 §6.5**。内容从工具栏
底下穿过是想要的效果；顶端切字那点问题由 client 半边一条 `padding-top` 解决，
壳一个字都不用改。

---

## 4. 风险台账

| 风险 | 处置 |
|---|---|
| dsh 升级改了 `[role="tab"]` 结构 | 找不到就不加属性，退回 web header（H4 的自愈） |
| 工具栏一行塞不下（有侧边栏时内容侧很窄） | H4 先只放段控，H5 再评估；窗口 `minSize` 已经是 432 |
| 段控宽度随 tab 文本跳动 | H1 的 `sizing: "dynamic"`；如仍跳，退回固定宽度 |
| 热替换后段控丢选中态 | model 在 activate 时主动向 client 要一次投影（dash-sidebar 的 `snapshot` 动作同款：**不给新世代补发，由请求方自己要**） |
| 两个 worktree 的 App 并存 | 与本计划无关，`NSUserDefaults` 那点共享是已知无害项 |

## 5. 明确不做

- **不改壳。** 页内桥已经通用转发，工具栏归 dash-layout，没有一处需要动
  `dash-app/host/`。
- **不占 `conversation.session.header` 槽**（路线 A，§1 已出局）。
- **不动 `conversation.view` 槽**：往里加 view 是"多一个 tab"，不是"接管 tabs"。
- **不碰 dash-nativeify**：它零服务依赖、要抢首帧，header 折叠是有条件的，
  两件事不该混。

---

## 6. 实施记录（H0～H5 全部完成）

计划与实现的差异、以及只有跑起来才知道的事。**下面每条都是实测的**，
不是推演。

### 6.1 锚点更正：`[data-slot="conversation.session.header"]`

调研文档给的 `[data-phase] > header` 是错的——两者之间隔着一个 slot outlet，
`> ` 直接子代选择器落空。dsh 的槽系统给每个 outlet 挂 `data-slot="<槽名>"`
（`display: contents`，不产生盒子），**这是整个 web UI 里最稳的 DOM 锚点**：
它是槽系统的一等属性，不是样式副产物，也不会被 CSS module 哈希化。

header 本体 = `seat.firstElementChild`。导出按钮在子槽
`[data-slot="conversation.session.header.utilities"]` 里。

### 6.2 两条"未验证"假设，都成立

- **`dispatchEvent('click')` 打得穿零尺寸 + `pointer-events: none` 的 tab。**
  实测切了视图。`pointer-events` 只挡真实指针命中测试，不挡合成事件派发——
  所以"折叠 tabs 行"和"仍然点得动它"不冲突，H3 的驱动不需要临时恢复可见性。
- **折叠 tabs 行不产生布局副作用。** header 76px → 49px，scrollport 自动跟上
  （+27px），没有别的位移。

### 6.3 AppKit 的 contentView 不是翻转坐标系

算工具栏高度时踩的：`window.contentLayoutGuide.frame.minY` **恒为 ~0**，
因为 AppKit 的 contentView 原点在左下角（UIKit 才是左上）。正确写法是
`contentView.bounds.maxY - layoutGuide.frame.maxY`，得 52pt。
症状是"算出来永远是 0"，很容易误判成 layoutGuide 没生效。
（顺带：`NSLayoutGuide` 的属性叫 `.frame`，`layoutFrame` 是 UIKit 的名字。）

这条最后没派上用场（见 §6.5），但结论留着——下次谁要量标题栏高度会再踩。

### 6.4 `Label` 放进 `Menu` 的 label 位会被吃掉文字

mode 那格一开始只显示图标不显示文字。原因是 macOS 把 `Menu { } label: { Label(...) }`
里的 `Label` 折叠成 icon-only。换成显式 `HStack { Image(systemName:); Text(...) }`
即可。**不是 `labelStyle` 能救的**，那个改的是渲染样式，这里是 `Menu` 对
`Label` 的特化处理。

### 6.5 不给内容加 top inset —— 内容就该从工具栏底下穿过

曾经做了一版 `dash.layout.contentTopInset` 事件 + 可调的 `webTopConstraint`，
让 WebView 内容避开标题栏。**已整体回退。** 从工具栏底下穿过（配合 Liquid Glass
的模糊）正是 macOS 26 想要的样子，避让反而显得笨。

顶端第一行被切的问题由 client 半边一条 CSS 解决：

```css
[data-conversation-scroll] { padding-top: var(--dash-header-inset); }
```

只影响滚到最顶时的起始位置，滚动中照样穿过（Safari、Xcode 都是这个行为）。
**壳与 dash-layout 因此一行都不用为 header 改**——H1 那两维是通用能力，不是
为 header 开的后门。

### 6.6 与 dash-sidebar 的重复 I/O：靠 `isWatched()` 收窄

两家都得调 `session.list`（上游没有单会话 RPC）。dash-header 的
`lib/dsh-source.js` 把 `session/event` 过滤到**焦点会话及其祖先**——面包屑只需要
这条链，别的会话变动一律不触发重取。600ms 去抖再兜一层。

### 6.7 jobs 是只读的，这是对等不是降级

翻了上游 `ui-jobs`：没有 stop / kill 之类的动作。所以原生 popover 只读地列出
后台任务，功能上与 web 版**完全对等**。

### 6.8 别的 worktree 的壳会串进来

发现文件是"扫目录取候选"，所以另一个 worktree 里跑着的 `dash Dev` 会连上本
worktree 的 dsh，然后拿它自己那份 DashSDK 去编译本仓库的 Swift 源码。
症状是终端刷出一串对不上号的 `编译失败：dash-layout @ <陌生 hash>`，而本地
`git diff` 干干净净。**判据是 hash**：自己那套的 hash 会同时出现在
`~/Library/Application Support/io.wenbo.dash/native-plugins/generations/<Module>/`
底下，陌生 hash 不会（那次编译的临时目录失败后就清了）。
`pgrep -af "dash Dev.app/Contents/MacOS"` 数一下有几个实例即可确认。

### 6.9 漏掉的那一条：`lineage` 槽（已补，见单独文档）

初版把 header 的贡献来源数齐了（`lineage` / `actions`×2 / `utilities` + view
tabs，五条一一对应），**但 `lineage` 只投影了纯文本面包屑**——它真正的内容是
`dsh-client-ui-subagent` 独占的那套子代理导航：后代计数下拉、兄弟切换器、
以及背后那棵 catalog 树。

而 `scope: "full"` 折叠整条 header 时把它一起折没了。**子代理会话不进侧边栏**
（上游 README：parent header catalog 是它们唯一的导航入口），所以那一版实际上
砍掉了访问子代理会话的全部路径——是功能倒退，不是等价替换。

已按原生重画补齐，过程与实测记在 [`native-subagent-catalog.md`](native-subagent-catalog.md)。
一条值得在这里重复的结论：**`session.list` 的契约原话是 "v1 returns
everything"**，node 半边一次就能拿到整棵树，所以原生这版不需要上游那套逐层
懒加载——展开是纯本地操作。

### 6.10 落地清单

新包 `@wenbo/dash-header`（第六个插件），三个半边：

| 文件 | 职责 |
|---|---|
| `lib/client.js` | 浏览器半边：投影 tabs / 驱动 setView / 导出 / 两级折叠 CSS |
| `lib/index.js` | node 半边：`createSwiftPlugin`，`schemaVersion: 2` |
| `lib/dsh-source.js` | **唯一碰 dsh 内部的文件**：sessions / agentPresets / jobs |
| `swift/HeaderSnapshot.swift` | 只解码的 wire 结构，宽进，形状不对返回 nil |
| `swift/HeaderModel.swift` | `@Observable`，**同时**持两条通道（页内桥 + 数据桥） |
| `swift/HeaderTabsView.swift`、`HeaderViews.swift` | 段控 / 面包屑（含计数下拉与兄弟切换器）/ mode / jobs / 导出 |
| `swift/SubagentCatalogView.swift` | 子代理 catalog 树（见 §6.9） |
| `swift/HeaderFormatting.swift` | token / 时长格式化，逐字复刻上游 |
| `swift/HeaderPlugin.swift` | 五条贡献，order 0/10/20/30/40，全部 `region: "content"` + `sizing: "dynamic"` |

**为什么 model 同时持两条通道**：active view 的真相在浏览器进程里（它是纯 UI 状态，
dsh 不知道），session / preset / jobs 的真相在 dsh 进程里。判据永远是"这个事实的
真相住在哪个进程"，不是"哪条通道更方便"。

**退场自愈**：插件退休时 `DashDisposable { model.dismissNative() }` 撤掉折叠属性，
web header 原样回来。带世代闸（`generation` 单调递增），防止旧世代的清理砍掉
新世代刚装好的那一份——与 dash-layout 的 `makeToken` 是同一个坑。

---

## 7. 工具栏排布与玻璃底板（本轮）

设计定稿见画布 <https://claude.ai/code/artifact/d7b9f4fa-bcd7-4265-b16f-3cc0ccea78c1>
（方向 A 修订版：**标识靠左、正中留空、段控与动作靠右，默认纯图标**）。

### 7.1 槽约定新增两个键

`toolbar` 贡献槽的 metadata 加了 `align` 与 `spaced`（约定文档在
`dash-layout/swift/LayoutSplitController.swift` 的槽约定注释里，那份注释是
这个槽唯一的文档）：

| 键 | 值 | 作用 |
|---|---|---|
| `align` | `"leading"`（缺省）/ `"trailing"` | 内容区里靠哪一边。两组之间夹一个 `.flexibleSpace` |
| `spaced` | `Bool`（缺省 false） | 该项之前插一个 `.space`。**空隙就是 AppKit 的分组语法**——macOS 26 把相邻的工具栏项合成一枚玻璃胶囊，断开才另起一枚 |

dash-header 五格因此排成 `[标识] ······ [Chat|Trajectory] [模式] [任务 导出]`：
任务与导出相邻不断，合成一枚（Mail 对 archive/trash/flag 就是这么做的）。

`toolbar.autosavesConfiguration = true` 一并补上——`allowsDisplayModeCustomization`
在 macOS 15+ 默认就是 YES，用户右键工具栏能改成 Icon and Text / Text Only，
不开 autosaves 就是每次启动弹回 `.iconOnly`。

### 7.2 液态玻璃底板：AppKit 给不了，必须页面自己画

macOS 26 里 Mail / Notes 工具栏背后那层会糊掉内容的玻璃，是 **scroll edge
effect**——AppKit 盯着窗口里的 `NSScrollView`，内容滚到标题栏底下时自动上材质
（26.1 起可以用 `NSTitlebarAccessoryViewController.preferredScrollEdgeEffectStyle`
调软硬边，但那只是**调样式**，触发权仍在 scroll view 手里）。

**我们拿不到它**：macOS 的 WKWebView 里根本没有 NSScrollView（滚动在 Web 进程），
AppKit 无从观察，那条带子于是什么都不画。

实测（把一块 12pt 红蓝条纹的原生 CALayer 塞进 `window.contentView` 顶部，
它在标题栏容器**之下**）：

- 带子内外的条纹**逐像素一致**——底板零贡献，`titlebarAppearsTransparent`
  设成 `false` 也一样（那个开关只是"别画标题栏背景"，而 Tahoe 的默认背景本来
  就是空的）。
- 反过来，**工具栏项自己那枚胶囊是真玻璃**——条纹在它背后糊成一片红蓝。
  所以"原生控件有玻璃"和"底板有玻璃"是两件事，前者白送，后者没有。

结论：底板补在**页面这一侧**（`dash-header/lib/client.js` 的 `installStyle`，
`[data-conversation-scroll]::before`，`position: fixed` + `backdrop-filter`
+ 底边 `mask-image` 软收）。这不是将就——`backdrop-filter` 与正文同处一个渲染
上下文，糊的就是真内容，比任何跨进程材质都准。底色走 `--dsw-alias-bg-base`，
深浅色自动切换。高度复用已有的 `--dash-header-inset`，与那条 `padding-top`
同生同灭。

### 7.3 一个会让整项凭空消失的坑

`HeaderCrumbsView` 原本写 `.frame(maxWidth: 520, alignment: .leading)`。
**SwiftUI 的 `maxWidth` 是贪心的**：NSHostingView 把 520 当理想宽度一路顶回
工具栏，这一格就真要 520pt，加上右边四格超出内容区，整项被挤进溢出——
界面上一个字都不剩。症状极像"数据没到"（node 半边日志明明写着"面包屑 1 段"）。

判据：**先怀疑宽度，再怀疑数据**。改成 220（上游 `_crumb{max-width:220px}`
的同一个数）立刻回来。

### 7.4 五格改原生子类：排版整个还给 AppKit

原来五格全是 `NSHostingView` 装着的 SwiftUI 视图。AppKit 只看见"一块不透明的
矩形"，于是宽度、间距、玻璃胶囊分组、显示模式、溢出退让**全得自己算**——
而算错是静默的（§7.3 那条就是）。现在只剩面包屑还走那条路：

| 格 | kind | 造出来的东西 |
|---|---|---|
| 标识（面包屑） | `view` | `NSHostingView`。**没得选**：它挂着一棵可展开的子代理树，菜单表达不了 |
| 会话视图 | `group` | `NSToolbarItemGroup(images:selectionMode:.selectOne, labels:)` + `.expanded` |
| 模式 | `menu` | `NSMenuToolbarItem`（indicator / 菜单定位 / 键盘全带） |
| 后台任务 | `menu` | 同上 + `NSToolbarItem.badge = .count(n)` |
| 导出 | `button` | `NSToolbarItem` + `isBordered` |

**段控用 `images:` 而不是 `titles:`** 是关键的一处：这样 Icon Only 显示图标、
Text Only 显示 `labels`，"给不给文字"就真的交回给了系统。用 `titles:` 会把它
钉死成永远文字，用户右键改显示模式时它是唯一不跟着变的那一格。

Chat 用 `text.bubble`，Trajectory 用 `list.bullet.indent`——后者不是语义上最贴切
的那枚（`point.topleft.down.to.point.bottomright.curvepath` 才是），但那枚缩到
14pt 读起来像个电话听筒，实测过。

### 7.5 拓扑与流量分家

贡献的 metadata 是**拓扑**，一变就重建整条工具栏。徽标数字、菜单内容、段控
选中态、显隐是**流量**，一秒能变好几次。混在一起的后果是每次投影到来都把工具栏
拆了重装（按钮闪、popover 掉）。

所以加了一条活通道 `dash.toolbar.update`：`{owner, id, ...patch}`，消费方把 patch
记进 `ToolbarItemState` **并**就地改活着的那一项。记账不能省——项会因换代 / 溢出
进出而重造，那时得把状态补回去。只有 `items`（段控分段）会触发那一项重建，
因为 images/labels 是构造时给的。

回来的动作同样走总线：`dash.toolbar.activate`（`group` 额外带 `index`/`itemId`）、
`dash.toolbar.menuSelect`。原生项拿不到闭包（target/action 必须 `@objc`，
闭包跨不了世代），字符串主题名反而天然扛热替换。

**实测过的一条完整链路**（`NSMenu.performActionForItem(at:)` 让 AppKit 自己派发）：
菜单第 2 项 → `selectToolbarMenuItem` → `dash.toolbar.menuSelect(itemId: "code")`
→ header 的订阅 → `model.selectPreset` → 桥 → node → dsh 回
`has already started; its agent preset is fixed`。**被拒是对的**——那个会话跑过
turn 了，能看见这句就说明写通道整条都通。

### 7.6 顶部留白跟着显示模式走

Icon and Text 会把工具栏撑高（52pt → 66pt），正文的顶部留白得跟着变。所以
`titlebarInset` 不再是装配时量一次的常量：dash-layout 在 `viewDidLayout`
（以及 `displayMode` 的 KVO）里量 `contentLayoutGuide`，变了就广播
`dash.layout.titlebarMetrics`。

**盯 `viewDidLayout` 而不是只盯 KVO**：厚度真正变的时刻是布局落定之后，
KVO 响时窗口还没重排、量到的是旧值；而显示模式、窗口缩放、全屏切换、工具栏
显隐——凡是会改厚度的最终都会走到 `viewDidLayout`。两条一起兜。

配套加了 `dash.layout.requestTitlebarMetrics`：厚度只在**变化**时才广播，而
dash-header 多半是在 layout 广播完之后才上线的，不问就永远等不到
（与"node 半边不给新世代补发投影"是同一条纪律——补发归请求方）。

### 7.7 三条新的硬事实

1. **`NSToolbar.displayMode` 是只读给用户的。** `allowsDisplayModeCustomization`
   在 macOS 15+ 默认 YES，头文件原话是"这时 displayMode 是一个用户可改的属性"。
   存过配置之后再赋值会被当场弹回——设完立刻读还是旧值（实测）。
   代码里那句 `toolbar.displayMode = .iconOnly` 只是**开局值**。
   要它记住用户的选择，`autosavesConfiguration` 必须开。
2. **`withObservationTracking` 的观察者没人强持有就静默死掉。**
   `HeaderToolbarSync` 是 `activate` 里的局部变量，`start()` 返回的 disposable
   写成 `[weak self]` 就等于没人持有它——只有构造时那一次同步 push 生效过。
   **症状只在冷启动露馅**：换代时 model 从保管箱拿到种子，第一推就把该显示的
   都显示了，看起来完全正常；冷启动没有种子，第一推全是 `hidden: true`，
   于是工具栏内容区一片空白，而日志里"header 上线 5 格"写得清清楚楚。
3. **`NSHostingView` 的默认压缩阻力会把别人挤进溢出菜单。** 默认 750 意味着
   这块矩形一步不让，AppKit 转而把别的项收进 `»`。降到 `.defaultLow`
   （并把 hugging 拉到 `.defaultHigh`）它才会先自己截断。
