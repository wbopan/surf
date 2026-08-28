# dash-notify —— 可交互桌面通知（权威计划）

> 状态：**规划中**，一行代码都还没写。动手前先读 §1（上游机制事实）与 §9（探针）。
> 探针 P1/P2 任一不过，整条线的形态要改，别先写业务。

## 0. 一句话

一个新插件 `dash-notify`：把 dsh 里「需要人」的四件事（待批准、待回答、回合结束、
出错）变成 **macOS 原生通知**——点一下跳到那个会话，通知上的按钮**直接把它办了**，
人在 app 里看到之后通知自己消失，Dock 图标上有角标。

**（v2 修订）铃铛砍了。** 「app 内通知中心」这个角色由侧边栏那枚胶囊接管：
「待批准」扩成「待处理」，列的是所有需要人看一眼的会话——待批准、待回答、出错、
跑完了。工具栏上因此少一颗按钮，而这些事本来就长在会话上，回到会话列表里才对。
待办表照旧只有一份（在 dash-notify 的 node 半边），经 `dashPending` 服务供出去。

## 0.1 与被放弃的那条线是什么关系

M7（`EventsBridge.swift`，235 行）2026-08-25 整件删除，理由三条
（`phase2-dash-plugin-migration-plan.md` §7.3）。**本计划逐条正面消掉它们，
而不是把同一份东西换个地方存**：

| 当年的病 | 这次怎么治 |
|---|---|
| 冷却与去重是拍脑袋的常数（60s / 300s） | **一个时间常数都没有**。通知的 identifier 就是 `rpcId` / `sessionId`，同 id 自动替换；`approval/resolved` 帧到了就撤下。去重变成身份问题，不是时间问题 |
| 前台过滤过于粗糙（`!NSApp.isActive` 一刀切） | 判据细到「你正在看哪个会话」（§6 那张表）。app 在前台但你在看别的会话，该通知照样通知 |
| app 未运行时静默丢失 | **明确丢弃**（用户决策，见 §11）。不排队、不拉起 app、不走 terminal-notifier。这一条不再是病，是范围 |
| 只能点开，不能处理 | 这次的核心：通知上直接批准/拒绝/选选项/打字回答（§5） |

## 0.5 不变量

1. **壳里零通知代码。** `dash-app/host/` 一行都不加，`DashSDK` 一个声明都不加
   （前提是 §9 的 P2 过；不过的话看 §9 的 Plan B——那时加的也必须是**通用机制**，
   不是通知 API）。
2. **node 管「发生了什么」，Swift 管「要不要打扰」。** 分界线是：需要 dsh 的
   wire 知识 → node；需要知道用户此刻在看什么 → Swift。两边都不越界。
3. **不新开 WebSocket。** 事件源是进程内的 `ctx.apiProxy.events.mux()`，
   零网络（当年 `EventsBridge` 自己连了两条 WS，那是壳还没有 node 半边的年代）。
4. **不抢 web UI 的答。** 我们只是「多开的一个客户端」，先到先得由上游仲裁（§1.2）。
5. 桥上只有全量 snapshot，没有增量帧（与 dash-sidebar 同纪律）。

---

## 1. 上游机制事实清单（对着 0.1.1-rc.2 源码核过，2026-08-27）

### 1.1 事件源：`ctx.apiProxy.events.mux()`

`node_modules/@deepseek-ai/dsh-host-apiproxy/lib/index.js:3524`。签名
`mux(request: RpcRequest<{since?}>, signal: AbortSignal): AsyncIterable<RpcRequest<MuxFrame>>`，
`since` 在 v1 未实现（传了也被忽略）。**是进程内 async iterable，不是 HTTP/WS**
——HTTP 那两条 `/api/events.mux`、`/api/events.host` 只是同一个东西的搬运工。

打开时它会：为每个 attached 会话推 `session/subscribed`，然后**重放所有仍然
pending 的 `question/requested` 与 `approval/requested`，rpcId 逐字复用**
（源码 `:3527~3537`）。这是「刷新恢复基线」，对我们的含义是：
**插件重挂载 / dsh 重启 / app 重连之后，待办不会丢，重新订一次就全回来了。**

分发是**广播**：`muxQueues` 是个 Set，每个订阅者一条队列，帧 push 给所有队列
（`:1782`、`:1889`、`:1953`）。所以多订一条不会让 web UI 少收一帧。

我们要的帧（`lib/types/api/events.d.ts` 的 `MuxFrame`）：

| 帧 | 载荷 | 用途 |
|---|---|---|
| `approval/requested` | `sessionId, approvalId, toolName, callId?, reason?` | 待批准。**信封的 `rpcId` 才是回答用的钥匙**，`approvalId` 只是审计相关性 |
| `approval/resolved` | `sessionId, approvalId, outcome` | 撤下通知。`outcome` 含 `cancelled`/`unavailable`（宿主侧结局） |
| `question/requested` | `sessionId, questions: AskUserQuestionItem[]` | 待回答。同样，钥匙是信封的 `rpcId` |
| `question/resolved` | `sessionId, questionRpcId, outcome: answered｜cancelled` | 撤下通知 |
| `session/event` | `sessionId, event` | `turn/end` 用来判「回合结束」 |

host 流（`events.host()`）另给 `host/session-status(running)` 与
`host/agent-error(message)`。**但我们不订它**——node 侧有等价的 cordis 事件
`agent/status`（在 `dsh-agent`，不在 `dsh-session`；dash-sidebar 已在用），
更省一条流。`host/agent-error` 没有 cordis 等价物，这一条**需要订 host 流**
（或者退而求其次只报 `turn/end` 后的失败态，第一版先订 host 流，简单）。

### 1.2 回答通道：`ctx.apiProxy.respond()`

`ApiProxy.respond(message: ClientResponse): Promise<RpcReceipt>`（`:3727`）。
形状：

```js
await ctx.apiProxy.respond({
  rpcId,                       // 逐字回抄 requested 帧信封上的那个
  result: { ok: true, value: { sessionId, approvalId, outcome: "allowed-once" } },
});
// question:  value: { sessionId, answer: { answers: [{ id, selected: [label], custom? }] } }
// 取消提问:  result: { ok: false, error: { code: "cancelled", ... } }
```

**实现是先到先得**：`respond` 先查 `pendingApprovals` / `pendingQuestions` 两张进程内
表，命中就 settle 并从表里删；晚到的一方拿到 `{accepted:false, reason:"not-pending"}`
——**不是错误，是正常结局**。所以「通知上点了允许」和「网页里点了允许」不需要任何锁，
先点的赢，后点的收到 not-pending，我们据此把通知撤下即可。

校验很严，答错了会被拒（`reason:"bad-response"`）：
- approval：`approvalId` 与 `sessionId` 必须与 pending 表里那条完全一致，
  `outcome` 只接受 `allowed-once` / `rejected`（`cancelled`/`unavailable` 是宿主侧的）。
- question：`matchesQuestions` 会核对答案的问题 id 集合与 `selected` 的合法性，
  **一次 ask 的所有问题必须一起答**（上游：一次 ask、多个问题、一个答案，永不拆）。

### 1.3 提问的形状

`AskUserQuestionItem`：`{ id, question, detail?, header?, options?: [{label, description?}],
multiSelect?, intent? }`。`intent` 目前只有一种：
`{ kind: "plan-review", approve: <某个 option 的 label> }`——**批准与否由 label 指名，
不看顺序**。答案 `AskUserQuestionAnswerItem`：`{ id, selected: string[], custom? }`。

### 1.4 顺带能收的一笔账

`dash-sidebar/lib/dsh-source.js:259` 写着：侧边栏的 `pendingQuestion`（紫点）没做，
因为 `ask_user_question` 在 node 侧既不发 cordis 事件也不落 session log，唯一的观察位
`userQuestions.registerProvider` 是**独占**的（apiproxy 占着），抢过来等于把 web UI 的
问答面板掐了；正路是订 mux，代价是要养一条帧流。

**dash-notify 正好养了这条流。** 所以它可以顺手把 pendingQuestion 供出去
（§8.3），侧边栏那颗紫点是白捡的。

---

## 2. 分层

```
dsh 进程                                     app 进程（壳）
┌─────────────────────────────────────┐      ┌────────────────────────────────┐
│ dash-notify/lib/                    │      │ dash-notify/swift/             │
│  mux-source.js  订 mux + host 流    │ push │  NotifyPlugin   通知的发与撤    │
│  inbox.js       待办模型（进程内）   │─────▶│  Presenter      前台策略        │
│  index.js       桥协议 + 设置 ns     │◀─────│  BellButton     工具栏铃铛      │
│                 respond() 回答      │invoke│  InboxPopover   历史列表        │
└─────────────────────────────────────┘      └────────────────────────────────┘
```

**为什么数据面在 node**：与 dash-sidebar 同一条理由——壳与共享 module 随 app bundle
冻结、用户改不了，而 wire 模型是随 dsh 版本演进最快的那层。而且 `respond()` 只有
node 侧摸得到。

**为什么策略面在 Swift**：「用户此刻在看哪个会话、窗口是不是 key、有没有被别的窗口
盖住」这些事实只在 app 进程里存在，node 侧一个都不知道。旧实现把策略放在壳里但只有
`NSApp.isActive` 一个输入，那不是层错了，是输入太少。

---

## 3. 桥协议

### 3.1 下行（node → Swift，`push(channel, payload)`）

| 频道 | 载荷 | 何时 |
|---|---|---|
| `inbox` | `{version, items: Item[], settings: {…}}` | 待办集合变化时（去抖 30ms），以及被 `inbox` 动作请求时 |
| `resolved` | `{id, outcome}` | 某一条被别处办掉了（web UI 答了 / 超时 / 中断），Swift 据此撤通知 |
| `error` | `{action, message}` | 上行动作失败（如 respond 被拒），Swift 记一行日志，必要时提示 |

`Item` 的形状（**一个字段都不给 Swift 解释权，Swift 收到什么画什么**）：

```jsonc
{
  "id": "approval.<rpcId>",       // 也是通知的 identifier，全局唯一
  "kind": "approval",             // approval | question | done | error
  "sessionId": "session-…",
  "sessionTitle": "重做侧边栏",    // 取不到就 null，Swift 退到 sessionId 短形
  "createdAt": 1756270000000,
  "title": "需要你的批准",         // 通知标题，node 组好
  "body": "运行命令：rm -rf build\n为了清掉上一次的产物",
  "actions": [                    // 通知按钮，见 §5
    {"id": "allow",  "label": "允许一次"},
    {"id": "reject", "label": "拒绝", "style": "destructive"},
    {"id": "open",   "label": "打开查看", "style": "foreground"}
  ],
  "textInput": null,              // 或 {"id": "custom", "placeholder": "…", "button": "发送"}
  "importance": "interrupt",      // interrupt | passive —— **只管响不响**，见 §5.4
  "meta": {"toolName": "bash", "approvalId": "…"}   // Swift 只透传，不解释
}
```

`done` / `error` 两类没有 `actions`（除了「打开查看」），因为没有什么可以在通知上办。

### 3.2 上行（Swift → node，`bridge.send(action:payload:)`，fire-and-forget）

| 动作 | 载荷 | node 做什么 |
|---|---|---|
| `inbox` | `{}` | 全量重推（每代 activate 时问一次，桥不给新世代补发） |
| `act` | `{id, actionId, text?}` | 翻译成 `respond()`；失败推 `error` |
| `dismiss` | `{id}` | 从待办里划掉（只影响铃铛的未读，不回答 dsh） |
| `dismissAll` | `{}` | 同上，批量 |
| `reveal` | `{id}` | 只是打点/标记已读；跳转由 Swift 自己走 `DashConversationSurface` |

**`act` 的翻译表（node 侧，唯一知道 wire 的地方）：**

| kind | actionId | respond 的 value |
|---|---|---|
| approval | `allow` | `{sessionId, approvalId, outcome:"allowed-once"}` |
| approval | `reject` | `{sessionId, approvalId, outcome:"rejected"}` |
| question | `opt.<n>` | `{sessionId, answer:{answers:[{id:<qid>, selected:[<第 n 个 label>]}]}}` |
| question | `custom` + `text` | `{sessionId, answer:{answers:[{id:<qid>, selected:[], custom:text}]}}` |
| question | `cancel` | `result:{ok:false, error:{code:"cancelled"}}` |

`open` 不上行（纯 Swift 侧动作）。

---

## 4. 通知的身份与生命周期

**一条待办 = 一个 identifier**，同 id 重发即替换（UNUserNotificationCenter 的既有语义），
所以不需要任何"我刚才是不是发过"的记账。

| kind | identifier | 谁来撤 | 什么时候撤 |
|---|---|---|---|
| approval | `approval.<rpcId>` | Swift | 收到 `resolved` 频道；用户看到该会话（§6）；本机点了按钮 |
| question | `question.<rpcId>` | 同上 | 同上 |
| done | `done.<sessionId>` | Swift | 用户看到该会话；该会话又开始 running（新回合开始，上一条完成没意义了） |
| error | `error.<sessionId>.<hash>` | Swift | 用户看到该会话 |

**上一进程留下的通知**：app 被 ⌘Q 之后系统通知中心里那些卡片还在，而它们指向的
待办多半已经过期。插件 activate 时**先把自己名下所有已投递通知撤干净**
（`getDeliveredNotifications` → 按 `dash.<instanceTag>.` 前缀过滤 → `remove`），
再按当前 inbox 重新发。这样「点开一条上辈子的通知」最差也只是把 app 打开，
不会跳到一个已经不存在的地方。

**instanceTag**：identifier 一律带 `DashPaths.instanceTag`（多 worktree 那一套已有的
分片键）。Dev 与 Release 的 bundle id 不同、天然分开；但同 bundle id 的两个 Dev 实例
会互相覆盖同名通知，前缀解决它。

---

## 5. 可交互通知怎么落地

### 5.1 category 是动态的

`UNNotificationAction` 挂在 `UNNotificationCategory` 上，而 category 必须**预先注册**。
我们的按钮是每条通知不同的（提问的选项是模型现编的），所以：

- 每条待办生成一个 category，identifier = 该待办的 id；
- `setNotificationCategories(_:)` 是**全量替换**，插件因此维护一份
  `[String: UNNotificationCategory]` 的活集合，增删都全量重设；
- **通知撤下之后才移除它的 category**（已投递的卡片按 categoryIdentifier 现查按钮，
  category 没了按钮就消失）。

### 5.2 按钮的映射

- approval → `允许一次`（默认样式）、`拒绝`（`.destructive`）、`打开查看`（`.foreground`）。
- question 单选 → 前 4 个 option 各一个按钮 + `打开查看`；超过 4 个只给
  `打开查看`（横幅塞不下，硬塞只会让最后一个选项被吞掉）。
- question 带 `intent: plan-review` → 两个按钮：`intent.approve` 那个 label 是批准，
  其余算拒绝（**按 label 认，不按顺序**，§1.3）。
- question `multiSelect: true` → **不给选项按钮**，只给 `打开查看`。多选在横幅上无法表达。
- question 任意形态 → 额外挂一个 `UNTextInputNotificationAction`（"其他…"），
  映射到 `custom`。
- 不带 `.foreground` 的 action **不会把 app 拉到前台**——这正是「直接办掉，不打断」
  想要的行为。

### 5.3 点击（不是按钮）

`didReceive response` 里 `actionIdentifier == UNNotificationDefaultActionIdentifier`：
激活 app、前置窗口、`DashConversationSurface.selectSession(id:)` 跳到那个会话。
`userInfo` 里带 `sessionId`（**只带 JSON 能表达的值**）。

### 5.4 授权与「专注模式」

- 授权：`requestAuthorization([.alert, .sound])`，插件 activate 时调一次（系统自己
  只弹一次窗）。被拒之后**无法再弹**，只能引导到
  `x-apple.systempreferences:com.apple.preference.notifications`——铃铛 popover 顶部
  常驻一条提示。
- macOS 的本地通知**不需要 Info.plist 里的 usage description**（当年那条
  `NSUserNotificationUsageDescription` 是多余的）。需要的是 bundle + 有效签名 → 探针 P1。
- `.timeSensitive`（穿透专注模式）要
  `com.apple.developer.usernotifications.time-sensitive` entitlement，ad-hoc 签名拿不到。
  **一律 `.active`**，等哪天有 Developer ID 再说。

  **`.passive` 那一档不要碰**（实测踩过）：它的语义不是"安静一点"，而是**根本不弹
  横幅**——通知直接躺进通知中心，用户不主动去翻就永远看不见。早先按 `importance`
  把「回合结束」发成 `.passive`，那类通知于是等于没发：屏幕上一点动静没有，日志里
  却写着"发通知"，看上去像系统设置出了问题。`importance` 只该管**响不响**
  （`content.sound`），不该管**弹不弹**。

---

## 6. 要不要打扰：判据表

Swift 侧对每条 inbox item 求一次值。输入只有四个，全部是 app 进程内的事实：

- `A` = `NSApp.isActive`
- `K` = 主窗口是 key 且 `occlusionState.contains(.visible)`
- `S` = 最后已知的当前会话 id（`DashEventBus.Topic.pageCurrentSession`，
  每代把最新值存进 `DashObjects`，跨世代不丢）
- `T` = 该条待办的 sessionId

| 情况 | approval / question | done / error |
|---|---|---|
| `A && K && S == T`（你正看着它） | **不发**（web UI 的审批面板就在眼前）；已发的**撤下** | 不发；已发的撤下 |
| `A && K && S != T`（在 app 里，但看着别的会话） | **发** | 发（可在设置里关成不发） |
| `!A`（app 在后台 / 被最小化 / 被盖住） | 发 | 发 |

**这就是旧实现「过滤太粗」的正解**：旧的只有 `!NSApp.isActive` 一个条件，于是「你在 app 里
盯着 A 会话，B 会话要审批」这个最常见的场景一条通知都收不到。

撤下的触发点（都是插件能自己订的 AppKit 通知，壳不用配合）：
`NSApplication.didBecomeActiveNotification`、`NSWindow.didBecomeKeyNotification`、
`NSWindow.didChangeOcclusionStateNotification`、`pageCurrentSession` 事件。

---

## 7. Dock 角标与铃铛（铃铛部分已作废，见 §0）

### 7.1 角标

`NSApp.dockTile.badgeLabel` = 待批准 + 待回答的条数（0 时设 nil）。
`done`/`error` 默认不计入（设置可开）。**插件退休时要清**：新一代 activate 时无条件
重设一次即可（它自己算得出正确值），不依赖旧代的析构——旧代 handle 的 deinit 实测
很不可靠（CLAUDE.md 踩坑记录第 2 条）。

### 7.2 铃铛（`toolbar` 贡献槽）——**已作废**

> 铃铛做出来了，用了一天就砍了：工具栏上多一颗按钮，而它列的东西本来就长在会话上。
> 下面这一节留着记录当时的判断与那条 `NSMenuToolbarItem` 的结论（对将来往工具栏
> 投贡献的人仍然有用），**但代码已经删干净了**。接替它的是侧边栏的「待处理」胶囊。

照 dash-sidebar 那颗「筛选」的写法贡献一格：

```swift
host.contribute(to: LayoutToolbar.slot, id: "bell", order: -50, metadata: [
    "label": "通知", "symbol": "bell", "tooltip": "待办与最近通知",
])  { AnyView(BellFallback()) }
```

**未读点画在哪**：`symbol` 路线拿的是系统 `NSToolbarItem`，我们够不着它的图层去点一颗
红点。两条路：(a) 未读时把 symbol 换成 `bell.badge`（系统自带带点的字形，零成本，
但点是灰的）；(b) 走兜底的托管 SwiftUI 路线自绘，代价是丢掉玻璃按钮的质感与按压态。
**先用 (a)**，数目靠 Dock 角标表达。

**popover**：贡献槽递不出锚点视图（dash-sidebar 那次就是因此把 popover 改成菜单）。

**实做的结论：不要 popover，走 `menu` 路线**（`NSMenuToolbarItem`，与「筛选」同一条
路子）。理由是"菜单表达不了带按钮的列表"这个前提**不成立**：一行一个子菜单，
子菜单里就是那一行的 `actions`，图标用 attributed title 挂 SF Symbol。
锚点问题因此整个消失，也不需要多一扇 panel 窗口。

未读点按上面 (a)：`bell.badge.fill` / `bell` 两个字形来回换。

### 7.3 列表里的行

每行：kind 图标 + 标题 + 会话名 + 相对时间；点行 = 跳过去；行内按钮与通知上的按钮
**同一份 `actions` 数据**（这就是「同一份数据源」的实际含义——只有一处翻译表，在 node）。
已办的行留在列表里、置灰、可清空。历史只活在 dsh 进程的内存里（§10）。
（实做里"行内按钮"落成了每行的子菜单，见 §7.2。）

---

## 8. 设置

### 8.1 命名空间 `dash-notify`

照 `dash-nativeify/lib/index.js` 的做法：**运行时嵌套 `ctx.inject(["settings"])`**，
不是静态 inject——settings 缺席时插件照常工作（退到默认值），而不是整个通知线消失。
注册一次就同时点亮两个界面（dash-settings 的原生窗口 + dsh 页内设置对话框）。

| 键 | 默认 | 说明 |
|---|---|---|
| `enabled` | `true` | 总开关 |
| `approval` | `true` | 待批准通知 |
| `question` | `true` | 待回答通知 |
| `done` | `true` | 回合结束通知 |
| `error` | `true` | 出错通知 |
| `actionableApproval` | `true` | 通知上直接给「允许一次」（关掉则只剩拒绝 + 打开查看） |
| `sound` | `true` | 声音 |
| `doneWhenForeground` | `false` | app 在前台（看着别的会话）时也报「完成」 |
| `badgeIncludesDone` | `false` | 角标是否把未读的完成计进去 |

`applies: "live"`——node 侧订自己这个 ns，值一变就把新的 settings 随 `inbox` 推下去。

### 8.2 「直接批准」的安全姿态

默认开（用户决策）。通知正文里必须带 `toolName` 与 `reason`，让人在按之前至少知道
自己在批什么。`actionableApproval` 关掉之后，通知上只剩「拒绝」和「打开查看」。

### 8.3 供出去的一笔（可选，M4）

`ctx.provide("dashNotify", { onPending(listener) })`，把 pendingApproval /
pendingQuestion 的会话集合供出去；dash-sidebar 用**运行时嵌套 inject** 接（缺席就
维持现状），那颗紫点就有了（§1.4）。**依赖方向是 sidebar → notify 的可选依赖，
不能反过来**，也不能写进 sidebar 的静态 inject。

---

## 9. 探针（M0）与里程碑

### 探针：两条不过就换形态，别先写业务

| # | 问题 | 怎么验 | 不过怎么办 |
|---|---|---|---|
| **P1** | ad-hoc 签名的 `dash Dev.app` 能不能拿到通知授权 | 临时在壳里加 5 行 `requestAuthorization` + 发一条，看系统弹窗与横幅 | 需要 Developer ID 签名才能做下去；先只做铃铛（app 内通知中心），系统通知推到有签名之后 |
| **P2** | 插件 dylib 里的 `NSObject` 子类当 `UNUserNotificationCenterDelegate`，**跨世代会不会打架** | 写一个最小插件，改一行触发热替换，看控制台有没有 `Class … is implemented in both` 警告，以及新代 delegate 是否真的收到回调 | 见下面 Plan B |
| P3 | 从插件里设 `NSApp.dockTile.badgeLabel` 是否正常、换代后是否要手动清 | 直接试 | 无（几乎不可能不行） |
| P4 | `setNotificationCategories` 全量替换，对**已投递**卡片的按钮有什么影响 | 发两条 → 替换 categories → 看第一条的按钮还在不在 | 影响撤 category 的时机，不影响形态 |
| P5 | 铃铛 popover 的锚点能不能从 toolbar 反查到（§7.2） | 打一行 AX / 直接试 | popover 降级成小 panel 窗口 |

### 探针结论（2026-08-27 实测）

**P1 过。** ad-hoc 签名的 `dash Dev.app` 正常拿到授权，系统设置里读回
「已授权｜横幅 开｜通知中心 开｜声音 开」。不需要 Developer ID。

**P2 的预判对了一半，但真正拦路的是另一件事。** objc 类名确实不打架——module 名
取自 contentHash，两代天然不同名，一次 `Class … is implemented in both` 警告都没有。
**但 delegate 根本收不到回调**：`UNUserNotificationCenter.delegate` 在 app 启动完成
之后再赋值会被**静默忽略**（`center.delegate` 读回来跟设进去的一模一样，
`willPresent` / `didReceive` 永不触发）。Apple 文档那句 "assign before your app
finishes launching" 是硬约束。

这一条对**整类 API** 成立，而运行时编译装载的插件天然在启动之后才存在：
**插件永远不可能自己占这种位子。** 与 objc 类名无关，Plan B 那个 `DashObjCBox`
垫片解决不了它（垫片住在 SDK 里，但赋值动作仍然发生在插件 activate 的时刻）。

**落地的是 Plan C**，判据仍然是那条"未来同类情况不再需要改 SDK"：

- `DashSDK/DashHooks.swift`——一张**应答钩子表**：
  `handle(hook:owner:version:_:)` 登记，`dispatch(hook:payload:) -> [String: Any]?`
  派发，`(owner, version)` 决定谁是当代。**整个文件里没有一个通知相关的词。**
- `Native/SystemDelegateRelay.swift`——壳在 `applicationDidFinishLaunching` 的
  **第一句**占住系统 delegate，把回调拍平成字典问一遍钩子，再把答案翻回系统要的形状；
  没人应答时返回系统默认。

覆盖面与 Plan B 想覆盖的完全一致（URL scheme、Dock 拖放、Services、
`NSUserActivity`），而且不需要插件继承任何 objc 类。为通知一件事改 SDK 是失败，
为这一类改一次是可以的——这一版是后者。

**P3 过**（角标从插件里设正常，换代不需要手动清，reconcile 每次无条件重设）。
**P4**：`setNotificationCategories` 是全集替换，所以每次提交整张表；已投递卡片的按钮
不受影响。**P5 没走 popover**：铃铛落成 `NSMenuToolbarItem`（menu 路线），
锚点问题不存在。

### 里程碑

| # | 交付 | 判据 |
|---|---|---|
| **M0** | 五条探针 + 结论写回 CLAUDE.md | P1/P2 有定论 |
| **M1** | 骨架：`dash-notify` 包 + 编排表加一行 + node 订 mux + 最朴素的通知（无按钮）+ 点击跳会话 | 待批准时弹通知，点一下跳到那个会话 |
| **M2** | 可交互：动态 category + approval 两个按钮 + `respond()` 回答 + `resolved` 撤下 | 在通知上点「允许一次」，dsh 那边真的往下走了；web UI 的面板同时消失 |
| **M3** | 提问：选项按钮 + 文本输入 + plan-review intent | 通知上答一道单选题 |
| **M4** | 前台策略（§6 那张表）+ done/error 两类 + Dock 角标 + 设置 ns | 你盯着 A 会话时 B 会话的审批会响，A 会话的不会 |
| **M5** | 铃铛 + popover 列表（同一份 actions） | 通知消失之后还能在铃铛里把它办了 |
| M6 | 可选：把 pendingQuestion 供给 sidebar（§8.3） | 侧边栏紫点 |

M1 之前先在 `dash/cordis.patch.yml` 加一行 `dash-notify`（在 `dash-sidebar` 之后，
它 inject `dash-layout`）。

---

## 10. 已知边界（写在前面，不算 bug）

1. **app 没运行 = 没有通知。** 用户决策。dsh 照常干活，你回来时铃铛里有待办
   （mux 重放给的），但那段时间不会有任何提示。
2. **历史只活在 dsh 进程内。** 不落盘。dsh 重启后铃铛里只剩 mux 重放回来的
   pending，已完成的历史清零。要持久化的话得给 node 侧加存储，第一版不做。
3. **多选提问、超过 4 个选项的提问，在通知上办不了**，只能「打开查看」。
4. **专注模式挡得住我们**（拿不到 time-sensitive entitlement，§5.4）。
5. **同一台机器上两套 dash 并存时**，两边各自发各自的通知；identifier 带 instanceTag
   所以不互相覆盖，但你会看到两份——这与两个 app 实例并存本来就是同一件事。
6. 通知正文里可能出现模型生成的文本（reason、提问正文）。**当成不可信输入**：
   截断到合理长度、不做任何 markdown/HTML 解释、不把里面的 URL 变成可点的东西。

## 11. 不做什么

- 不给 app 未运行时排队、不调 terminal-notifier / osascript、不为通知拉起 app。
- 不在 session log 里写任何自定义 event（CLAUDE.md 硬约束：会导致
  `SessionFormatUnsupportedError`）。
- 不碰 `userQuestions.registerProvider`（独占位，抢过来会掐掉 web UI 的问答面板）。
- 不订 `approval/request`（那是 waterfall 抢答钩子，插一脚会和 apiproxy 抢着回答）。
- 不做通知的「稍后提醒」/ 定时重发。想不起来就是想不起来，加一个定时器只会制造
  当年那种拍脑袋常数。

## 12. 执行日志

| 日期 | 里程碑 | 提交 | 摘要 |
|---|---|---|---|
| 2026-08-27 | v2 修订 | （本次） | 三处改动：**① 砍掉工具栏铃铛**，「app 内通知中心」这个角色交给侧边栏那枚胶囊——「待批准」扩成「待处理」，筛的是 `needsAttention`（待批准 / 待回答 / 出错 / 跑完了）。**② 待办表经新的 `dashPending` 服务供给 dash-sidebar**（运行时嵌套 inject，缺席则退回 approval-only）；侧边栏因此白拿了它自己推不出来的 `pendingQuestion`。**③ 收录与打扰分层**：四个分类开关从 node 侧（决定进不进待办）搬到 Swift 侧（决定发不发通知）——关掉「跑完了」的通知不该把侧边栏也弄瞎。顺带两条基础设施：`DashEventBus.emitSticky`（粘性事件，插件装载晚于页面时才拿得到"当前在哪个会话"）、`FieldNotes` 给 `dash-notify` 补中文文案（设置窗口里那一页）。 |
| 2026-08-27 | M0～M5 | （本次） | 一次做完。探针结论见 §9：P1/P3/P4 过，**P2 的真正拦路点不是 objc 类名而是「delegate 设晚了被静默忽略」**，于是落成 `DashHooks` + `SystemDelegateRelay`（通用应答钩子，SDK 里不含通知词汇）。端到端实测：真实提问经通知按钮文本回答 → dsh 记 `1/1 answered`、模型继续；真实批准点「允许一次」→ 工具真的执行、通知自动撤下；别处先答 → 通知自己撤下。另修三个只在这类插件上出现的 bug：不占槽插件的生命周期锚（`activate` 返回 presenter）、`sweepStaleDeliveries` 挂在 activate 上会扫掉当前值班的通知（改用 `host.objects` 里的进程级标记）、授权回调与 inbox 首推竞态导致重复发送（`ready` 门 + sweep completion）。 |
| 2026-08-27 | 规划 | （本次） | 计划成文。上游机制对着 0.1.1-rc.2 源码核过（mux 广播 + 重放、respond 先到先得、intent 按 label 认）。四个产品决策定案：能力全在插件、app 未运行丢弃、直接批准默认开、铃铛第一版就做。 |
