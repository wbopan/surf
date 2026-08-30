# surf-sidebar

原生会话侧边栏。占 surf-layout 的 `sidebar` 槽；surf-layout 不在则整个插件不挂载
（cordis 的 `inject` 会让它安静地等着）。

## 两半各管什么

| | 谁 | 干什么 |
|---|---|---|
| node 半边 | `lib/index.js` + `lib/dsh-source.js` | **数据面**：调 `ctx.apiProxy`、订 cordis 事件，组投影，经桥推 JSON；七个写动作 |
| Swift 半边 | `swift/` | 画列表、发动作、收敛选中状态。**零数据逻辑** |

数据面在 node 而不在 Swift（M10 从 DSHKit 迁过来的理由）：壳与共享 module 随 app
bundle 冻结、用户改不了，而会话/工作区的 wire 模型是随 dsh 版本演进最快的那一层
——层放错了。node 半边住在 dsh 进程里、随 npm 可更新，且 Swift 插件怎么热替换它
都不动。附带好处：Swift 那边不再需要一份 HTTP/WS 客户端，`DSHKit` 整个退役。

桥协议（三条下行频道、七个上行动作）的完整表在 `lib/index.js` 顶部注释里。

**跟 dsh 打交道的代码全部关在 `lib/dsh-source.js` 一个文件里，dsh 升级后先核对它。**
它走的是 `ctx.apiProxy`——`/api` 那套方法的同进程实现本体（HTTP carrier 只是包了
它一层），所以行为与 web UI 逐字节同源，零网络、零重复实现。计划 §1.6 猜的
`ctx.sessions` / `ctx.workspaceRegistry` 那条路要自己重写一大段上游逻辑
（`ctx.sessions.list()` 只有活会话、title/running/blank/updatedAt 全是派生的、
registry 上根本没有 rename……），四条实测理由写在那个文件顶部。

## 跨代不闪列表

Swift 半边每代把收到的最后一份 snapshot 原样存进保管箱：

```swift
host.objects.setObject("surf.sidebar.snapshot", payload as NSDictionary)
```

下一代 activate 时先拿它渲染，同时发 `snapshot` 动作要一份 fresh 全量，到了再替换。
**箱里放的是 `NSDictionary`（系统类型），不是本 module 定义的任何 struct**——新旧两代
的同名类型互不认识，取出来 `as?` 只会安静地得到 nil（M2 断言 4）。投影的 struct
（`SidebarSnapshot`）每代自己 decode，实例永不过界。

（M6~M9 时箱里放的是 `DSHKit.SessionStore` 实例。那时敢放一个非 SDK 类型，是因为
DSHKit 也是随 bundle 分发的共享 dylib；M10 之后连这个例外都不需要了。）

## 显示层与数据层的分界

投影原样带上 `blank` / `isSubagent` / `archived`，**过滤在 Swift**：
"列表里显示什么"是 UI 政策。兜底组的标题同理：数据层给空串 + `workspaceId: null`，
「未分组」四个字归显示层。

归档曾经是**例外**（v2 及以前 node 半边直接滤掉，理由是"那是数据事实"）。
v3 收回了这个例外：侧边栏有了「显示已归档」开关，滤在 node 那边的话开关就够不着了。

## 文案：一张表，两种语言（i2）

**Swift 半边所有用户可见的字都在 `swift/Strings.swift`**（`struct L`，zh / en
并排同一行）。语言跟着 dsh 的 `locale` 设置走，本插件不存任何语言偏好：
插件 `activate` 里建一个 `SurfLocaleStore(bus: host.events)`（订粘性主题
`surf.locale`），视图 body 读 `L(locale.current)` 就建立了观察依赖，切语言自动重渲
——**不用 `withObservationTracking`**（静默死亡坑）。权威计划见
`docs/archive/surf-i18n-plan.md`。

三条纪律：

- **日志不翻**：`host.log(...)` 一律中文（读它的是蹲在终端前的人）。要在日志里
  写动作名就显式取 `L(.zh)`，见 `AppSidebarModel.reportFailure`。
- **标识与文案解耦**：`sidebar.*` 那些 accessibilityIdentifier、筛选胶囊的
  `Mode.rawValue`、「按时间」分段的 `TimeBuckets.Bucket` 全是稳定英文串。
  换语言后这从"纪律"变成了正确性——分段一度拿中文段名当 `Identifiable.id`。
- **node 半边不产出显示文案**：`error` 帧是 `{action, code?, message}`，
  Swift 用 `L.actionFailed` 组「归档会话失败：<原因>」。以前 `dsh-source.js` 的
  `call(..., what)` 把中文动作名拼进 Error message 推到原生 alert 上，界面
  切成英文也改不掉——那条路 v5 断根了。

工具栏那枚「筛选」不在 SwiftUI 里：`label` / `tooltip` 是贡献槽的**拓扑键**，
只在注册那一刻被读走，所以插件另订一次 `surf.locale`，语言一变**重新贡献**
同一条 `(owner, id)`（就地覆盖、位置不变、整条工具栏重建）。菜单内容是每次
弹出前现填的，那一半自己就跟上了。
现在归档只是行上的一个 `archived: true`，行照常下来，由 `SidebarFilterState` 决定露不露。

## 副行摘要（`preview`）

会话行的第二、三行是**最后一条 assistant 回复**的摘要。**上游没有这个字段**
——`session.list` 的 schema 里一个字的正文都没有，投影里也没有。取法是每行单独读一次
`session.history({ sessionId, maxMessages: 1 })`（上游按消息边界倒着数、切在
`turn/start` 上，拿到的是尾巴），从那一页里挑最后一条 `assistant/message`。

**为什么非要挑 assistant**：倒扫时不分角色的话，用户刚发出一句、模型还没答的那一刻，
副行会翻成用户自己刚打的字——把用户已经知道的东西又念一遍。只有"新会话发了第一句、
还没有任何回复"才退回用户那条。

**缓存要两把钥匙**（少一把就是"preview 永远不变"这个 bug）：

- 按 `updatedAt` 比对 —— 冷会话永不重取；
- 收到 `assistant/message` / `user/message` 时**显式作废那一行** —— `updatedAt`
  未必每条消息都动，只靠它比对会把摘要钉死在第一次取到的那句上。

另有三道闸：

| 闸 | 值 | 为什么 |
|---|---|---|
| 缓存键 | `updatedAt` | 会话没动过就永不重取——这是省掉绝大多数请求的那一条 |
| 并发 | 4 | 首轮 100+ 会话不至于把 apiProxy 一次性打满 |
| 预算 | 每轮 80 条 | 列表再长也有上限，超出的行就先没有摘要（不是错误） |

`blank` 会话一次都不取（没内容可摘）。取回来的文本会**丢掉
`<system-reminder>` 整段**（那是给模型看的脚手架，不是任何人"说"的话）并
**抹平 Markdown 记号**（`flattenMarkdown`）：`## 标题`、`- **状态**`、行内反引号这些原样端上去只是噪音。
抹得很浅，故意的——摘要错一点无所谓，为它引一个 Markdown 解析器才是错的成本。

## 筛选与视图状态

`SidebarFilterState`（Swift 半边，`UserDefaults` 持久化）握着四样东西：

- `mode`：列表的组织轴。**全部 / 按时间 / 待处理**三枚胶囊。
  「按时间」把工作区整个换成日期分段（今天 / 昨天 / 过去 7 天 / 更早），
  副行也随之拆成「工作区 / 摘要」各一行——那边没有分组头兜着。
  「待处理」筛的是 `SidebarSessionStatus.needsAttention`——待批准 / 待回答 /
  出错 / 跑完了，四类都算，见下面「状态点从哪来」。
- `hiddenGroups`：被工具栏「筛选」菜单取消勾选的工作区。
- `showArchived`：同一张菜单里的开关。
- `query`：搜索框内容，**不持久化**（重启后还留着上次的搜索词只会让人以为会话丢了）。

工具栏那枚「筛选」是本插件往 surf-layout 的 `toolbar` 槽投的一条贡献，
走 `menu` 路线拿的是 `NSMenuToolbarItem`。设计稿画的是 NSPopover，落地改成菜单：
贡献槽递不出锚点视图，而"一串带勾的开关"本来就是菜单的母语。

## 搜索框：一点都不自绘，36pt 的开关是 `.controlSize(.extraLarge)`

它是内置的液态玻璃胶囊——点下去会胀一下、有光效、有聚焦动画，外加放大镜、
清除按钮、取消响应、⌘F 语义、无障碍角色、输入法行为。整套东西拼不出来，
所以 `SidebarSearchField` 除了转发文字什么都不做。

**外框高度只跟 `controlSize` 走**：regular=24pt / large=28pt / **extraLarge=36pt**
（离屏渲染逐像素量过）。macOS 26 的 `NSSearchField` 内部是个
`_NSCoreHostingView<AppKitSearchField>` 占满 frame，**根本不走 cell 绘制**——所以
`frame(height:)`、`intrinsicContentSize`、`layout()` 强撑 frame、放大字号一概无效，
覆写 `NSSearchFieldCell` 的那些 rect 方法更是死路。

**而且 `controlSize` 必须设在 SwiftUI 环境里，不能设在 `makeNSView` 里。**
NSViewRepresentable 每轮 update 都会把环境的 `controlSize`（默认 `.regular`）
回写进 NSControl，`makeNSView` 设的 raw 4 到 `updateNSView` 时已被打回 raw 0。
不报错、不警告——这就是"设了没反应"的全部机制。正解是给 representable 贴
`.controlSize(.extraLarge)`：环境值本身就是它，回写反而替我们把值钉住。

绘制路径零改动，所以按压胀缩与光效原样保留。**别为了尺寸去拆这个控件**
（`isBezeled = false` 自己补底板、塞进 `NSGlassEffectView`）——两条都试过，
底板画得再像也没有那一下手感。

## 会话行长什么样

定高：状态指示器（16pt 槽）+ 标题一行 + 副行**恒占两行**
（`lineLimit(2, reservesSpace: true)`，摘要长短不一时列表不跳），
**上下各 16pt 留白**（参照 Messages / Mail：行高的一半花在留白上，
一屏少几行，换来的是能扫）。

- **行内不显示时间**：时间只作为「按时间」视图的分段头出现。
- **选中高亮一律交给 List 自己画，别加 `.listRowBackground`。** 自绘那层内缩量和
  系统那层（10pt）对不上，套成一个"回"字——半透明材质一用立刻露馅（早先没露馅
  只因为填的是不透明纯色）。绕过这一条的代价还不止观感：系统那层白送焦点态
  （有键盘焦点时 accent、失焦转灰）与浅深色适配，自绘就得自己养一套。
  （顺带记一笔：`.tint()` 改不了 sidebar List 的选中色，别在那儿浪费时间。）
- **状态指示器分三级**（`StatusIndicator.swift`）：正在跑 = 系统 spinner
  （静止的点表达不了"正在变化"，且不依赖颜色）；等你动作 = 语义符号 + 系统色
  （叹号/问号的形状本身就能区分，灰度下不丢信息）；空闲 = 什么都不画。
  绿点被删掉不是口味问题——绿点的既有语义是"一切正常"，拿它表示"正在跑"是反的。

## 从壳迁进插件时踩到的坑

- **`#if DEBUG` 在插件里永远不成立**：插件由壳在运行时用命令行 swiftc 编译，没有 `-DDEBUG`。
  插件里要判 Dev 只能看壳的 bundle id 后缀（`io.wenbo.surf.dev`）。
- 选中高亮活过热替换靠 `host.store` 存 `selectedSessionId`。它只是"页面把 `currentSession`
  报回来之前先亮哪一行"的装饰状态，丢了不心疼——真相在 dsh 侧。
- **分叉标题的序号递增必须自己复刻**（`lib/fork-title.js`，用例在 `test/`）：上游把它
  放在 client runtime 的 `fork(increaseTitle: true)` 里，服务/wire 层只有
  fork + rename 两步。两个界面分叉出来的会话必须同名。

## 状态点从哪来

行首那颗指示器有五种，**来源是两处**：

| 状态 | 画成什么 | 谁算出来的 |
|---|---|---|
| `running` | 系统 spinner | 本插件（`session.list` 的 `running`） |
| `pendingApproval` | 橙色感叹号 | 两处都有；本插件订 `approval/asked｜decided` 兜底 |
| `pendingQuestion` | 紫色问号 | **surf-notify**（`surfPending`） |
| `failed` | 红色叉 | **surf-notify** |
| `done` | 空心对勾 | **surf-notify** |

后三样这一侧**推不出来**：`ask_user_question` 在 node 侧既不发 cordis 事件也不落
session log，唯一的观察位 `userQuestions.registerProvider` 是**独占**的，apiproxy
已经占着——抢过来等于把 web UI 的问答面板掐了。正路是订
`ctx.apiProxy.events.mux()`，而 surf-notify 为了发通知**已经养着那条帧流**，
还维护着一份权威的待办表。真相只该有一份，所以这边订它（`lib/index.js` 的
`withPending`），不再自己推一遍。

合并规则是**只升不降**：两边看到的都是真事实，取更该管的那一个（`STATUS_RANK`）。
surf-notify 缺席时整段跳过，退回 `running` / `pendingApproval` / `idle` 三个老取值
——那条路径必须存在，它是侧边栏的独立性。

「跑完了」和「出错」**看一眼就消失**（点开那个会话即可），因为 surf-notify 那边
收到 Swift 报的 `focus` 就把它们从待办里删了。

## 已知缺口

**搜索只搜标题与摘要**，不搜正文——正文要么得全量拉历史，要么得上游给检索接口，
两条都不是"侧边栏"这一层该扛的。

## 测试

```sh
node --test surf-sidebar/test/*.test.js
```

零依赖、约 2s。给 `--test` 一个目录在 node 26 上会 `MODULE_NOT_FOUND`，写通配符。
