# clam-notify

macOS 桌面通知。**不占任何槽，也不贡献任何界面**——缺席时什么都不缺。

一句话：dsh 那边有事要问你（工具要批准、模型要提问、一轮跑完了、出错了），这个
插件把它变成一条**能直接按按钮答掉**的系统通知；你正看着那个会话时它不打扰，
你在别处时它才响；别人先答了它自己撤下去。

它还是「有什么在等着你」这件事的**唯一真相**：侧边栏那枚「待处理」胶囊读的就是
这里那份表（经 `clamPending` 服务）。

## 两半各管什么

| | 谁 | 干什么 |
|---|---|---|
| node 半边 | `lib/mux-source.js` + `lib/inbox.js` + `lib/index.js` | **数据面**：订 `ctx.apiProxy.events`，维护一份待办清单，经桥推 JSON、经 `clamPending` 供给侧边栏；把按钮翻回 wire 答给 dsh |
| Swift 半边 | `swift/` | 发通知、收按钮、判"要不要打扰"、报"人在看哪个会话"。**零 wire 知识** |

分层跟 clam-sidebar 同源同理由：wire 模型随 dsh 版本演进最快，而壳与共享 module
随 app bundle 冻结、用户改不了。**跟 dsh 打交道的代码全部关在 `lib/mux-source.js`
一个文件里，dsh 升级后先核对它。**

## 数据从哪来——三条路只有一条能走

| 路子 | 为什么不行 |
|---|---|
| `ctx.approval.request` 挂个 hook | 那是**瀑布式的答题钩子**，挂上去就等于跟 apiproxy 抢答；谁先返回谁定生死，UI 会随机失灵 |
| `ctx.userQuestions.registerProvider` | **独占**，位子被 apiproxy 占着 |
| `ctx.apiProxy.events.mux()` ✅ | 广播式**只读**流，想订几路订几路，谁都不影响 |

`mux()` 还白送两件关键的事：

1. **打开时会把仍然 pending 的 `approval/requested` / `question/requested` 重放一遍**，
   且 `rpcId` 逐字复用。所以流断了随便重开——`pump()` 最多重开 5 次，重开的代价是零，
   待办不会丢也不会重。
2. 答案走 `apiProxy.respond()`，**先到先得**。晚到的回答拿到
   `{accepted: false, reason: "not-pending"}`——**那不是错误**，那是"别人先答了"。
   代码里把它和成功一样对待：照样翻牌，把通知撤下去。

`approval/resolved` 帧上**没有 rpcId**，只能拿 `{sessionId, approvalId}` 配对；
`question/resolved` 上是 `questionRpcId`。两条配对规则都写在 `mux-source.js` 里，
别按直觉猜。

## 收录与打扰是两件事

**node 照单全收**，`settings` 里那四个分类开关（批准 / 提问 / 跑完 / 出错）一个都
不看；开关在 Swift 侧的 `NotifyPolicy.shouldPresent` 生效。

这条纪律有个直接后果，也正是要的：**把「回合结束」的通知关掉之后，侧边栏那枚
「待处理」胶囊里照样看得见它**——关的是打扰，不是事实。早先那版把开关写在收录
这一侧，于是关掉通知连带把侧边栏也弄瞎了。

## 供给侧边栏：`clamPending`

```js
ctx.inject(["clamPending"], (scoped) => {
    scoped.clamPending.snapshot();      // { [sessionId]: ["approval", "done", …] }
    scoped.clamPending.subscribe(cb);   // 变了叫一声，返回退订函数
});
```

原因数组**按重要性排好序**（`PENDING_ORDER`，定义只在这一处），消费方取 `[0]`
就是"该画哪个指示器"。服务名里没有 "notify" 二字是故意的：它表达的是"有事等着你"
这个事实，通知只是这个事实的一个消费者。

消费方一律走**运行时嵌套 inject**——clam-notify 缺席时侧边栏退回它自己那份
approval-only 的状态点，不能不挂载。

## 「看一眼就完」的两类怎么消失

`done` / `error` 不需要回答，看见了就该没了。Swift 侧在 `reconcile` 里判：
人正盯着那个会话（app 前台 + 窗口可见 + 当前会话对得上）就给 node 发一条 `focus`，
node 把那两类从待办里删掉。

**判据是"正看着 + 有那么一条"，不是"切换了会话"。** 最常见的场景恰恰是你看着它跑、
它跑完了——那一刻当前会话一个字都没变。早先把发送写在"切换会话"那条路径上，
于是这个最常见的场景永远清不掉。

配套的一条在壳那边：`clam.page.currentSession` 是**粘性事件**
（`ClamEventBus.emitSticky`）。插件是运行时装载的，必然晚于页面第一次报告状态；
不粘的话它得等到用户下一次切会话才知道"现在在哪"，而如果用户打开 app 之后就一直
待在同一个会话里，它就永远不知道。

## 待办的身份与生命周期

| 事件 | 身份 | 什么时候消失 |
|---|---|---|
| 工具要批准 | `approval.<rpcId>` | 你答了 / 别人答了 / 会话被取消 |
| 模型提问 | `question.<rpcId>` | 同上 |
| 一轮跑完 | `done.<sessionId>` | 你点开那个会话，或手动清 |
| Agent 出错 | `error.<sessionId>` | 同上 |

去重按**身份**，不按时间——同一个 rpcId 再来一次就是同一条，不会叠出两条通知。
`dismissAll()` **绝不清掉仍然 pending 的批准与提问**：那两类清掉了就再也没有入口。

系统通知的 identifier 前缀是 `clam.<instanceTag>.`，`instanceTag` 是 bundle 路径的
djb2 哈希——多 worktree 并存时两个实例的 bundle id 相同，不分片的话互相撤对方的通知。

## 打扰政策

`NotifyModel.swift` 里的 `NotifyPolicy` 是一张纯函数表，三条：

| 情形 | 结果 |
|---|---|
| app 在前台**且**你正看着那条通知所属的会话 | 不弹（`willPresent` 返回 `[]`） |
| app 在前台但你在别的会话 | 弹横幅，不响 |
| app 不在前台 / 窗口被藏起来 | 弹横幅；`importance == "interrupt"` 时响一声 |

**四类通知都弹横幅**（`interruptionLevel` 一律 `.active`）。`importance` 只管
**响不响**，不管**弹不弹**——`.passive` 那一档的语义是"根本不弹横幅、直接躺进通知
中心"，用在"跑完了"上等于没通知。"跑完了"恰恰是最需要横幅的场景之一：人切去别的
窗口干活，就等着被叫回来。安静与否交给声音。

**判两次**：发之前判一次，`willPresent` 里再判一次。发出去到显示出来隔着几十毫秒，
用户完全可能在这期间切过去了——第二次判把"看到就消失"从事后撤下提前成根本不弹。

**app 没在跑（dsh 还活着、壳被 ⌘Q 了）= 丢弃。** 不排队、不落盘、不借
terminal-notifier、更不自动把 app 拉起来。回来时看 dsh 自己的界面就是了。

## 通知上的按钮

`UNNotificationAction` 三种选项，我们各用各的：

| 按钮 | option | 效果 |
|---|---|---|
| 允许一次 / 各个选项 | 无 | **后台处理**，通知消失，app 不前台 |
| 拒绝 / plan-review 的否定项 | `.destructive` | 同上，红字 |
| 打开查看 | `.foreground` | 激活 app 并跳到那个会话 |

自由文本的提问额外挂一个 `UNTextInputNotificationAction`。

**category 是动态的、每条一个**（identifier 就是 item.id），因为按钮文案来自模型。
`setNotificationCategories` 是**全集替换**语义，所以每次都提交整张表
（`flushCategories()`），别想着增量加。

降级规则（`inbox.js`）——**这些情形只留「打开查看」**：多问题批次、`multiSelect`、
选项超过 4 个。系统最多显示 4 个动作，硬塞会截断成"看不见的选项"，那比不给按钮糟。
`plan-review` 意图下按**标签**（不是顺序）把否定项标红。

## 两个把人坑惨的地方

### 1. 系统 delegate 必须在启动完成前装上

`UNUserNotificationCenter.delegate` 在 app 启动完成之后再赋值会被**静默忽略**：
`center.delegate` 读回来跟你设的一模一样，`willPresent` / `didReceive` 就是永远不触发。
Apple 文档那句 "assign before your app finishes launching" 是硬约束，不是建议。

运行时编译装载的插件天然在启动之后才存在，所以插件**永远不可能**自己占这个 delegate。

解法**不是**往 SDK 里塞通知词汇，而是加了一张通用的应答钩子表：

- `ClamSDK/ClamHooks.swift`——`handle(hook:owner:version:_:)` 登记、`dispatch` 派发，
  **整个文件里没有一个通知相关的词**。
- `Native/SystemDelegateRelay.swift`——壳在 `applicationDidFinishLaunching` 的第一句
  就占住系统 delegate，把回调拍平成字典，经钩子问一遍插件，再把答案翻回系统要的形状。
  没人应答时返回系统默认（前台不显示）。

于是"必须在启动前占位、但实现在插件里"这一类事情——URL scheme、Dock 拖放、
Services、NSUserActivity——**以后不用再改 SDK 一行**。这是这个插件对 SDK 提的唯一要求，
提法本身是为了不再有下一次。

### 2. 不占槽的插件没有生命周期锚

clam-sidebar 那样占槽的插件，registry → 视图闭包 → model 有一条天然的强引用链。
这个插件不占槽：`activate` 里 new 出来的 presenter **没有任何人持有**，函数一返回就被
ARC 回收，所有 `[weak self]` 的异步回调静默变成 nil。症状极其误导——"通知线上线"
照常打印，然后什么都不发生，像是数据没来。

`activate` 因此**返回 presenter 而不是 handle**（presenter 自己持有 handle）：

```swift
func activate(host: ClamHost) -> AnyObject? {
    let presenter = NotifyPresenter(host: host, surface: ...)
    presenter.start()
    return presenter          // ← 壳按住这个返回值，它就是生命周期锚
}
```

### 顺带一条：清理上一次运行留下的通知只能做一次

`sweepStaleDeliveries` 清的是**上一个进程**留在通知中心里的僵尸。它挂在每次
`activate` 上的话，改一行 Swift 热替换就会把屏幕上正当值班的通知一起扫掉，而恢复出来的
`presented` 表还记着"发过了"，于是它们再也不会回来。用 `host.objects` 里的一个
`sweptKey` 标记按进程收口（保管箱天然是进程级的）。

它还必须带 completion：授权回调是异步的，不等 sweep 拿完快照就开始发，会出现同一条
通知响两声。`ready` 门 + completion 两道一起才干净。

## 设置

注册在 `clam-notify` 这个 ns 下，九个开关，全部 `applies: "live"`（改完立刻生效，
新值随下一次 inbox 推给 Swift）：

| 键 | 默认 | 管什么 |
|---|---|---|
| `enabled` | 开 | 总开关（只关打扰；侧边栏那枚胶囊照旧） |
| `approval` / `question` / `done` / `error` | 全开 | 四类事件**通知与否**的开关（收录不受影响） |
| `actionableApproval` | 开 | 通知上给不给「允许一次」。关掉后只剩「拒绝」与「打开查看」 |
| `sound` | 开 | 提示音 |
| `doneWhenForeground` | 关 | app 在前台时也报「回合结束」。**待批准/待回答不受它影响** |
| `badgeIncludesDone` | 关 | 角标算不算未读的「回合结束」「出错」 |

注册走**运行时嵌套 `ctx.inject(["settings"])`**——`settings` 服务缺席时退到默认值，
通知照常工作。

## 自测

```sh
CLAM_NOTIFY_SELFTEST=1 ./dev
```

启动 3 秒后塞两条假待办（一条批准、一条带输入框的提问），用来看版式与按钮。
假 rpcId 在 `act` 时会被上游判成 `not-pending`——**那条路径同样是真的**，
翻牌与撤通知的行为跟真件逐字相同。

不想动 UI 也能验：桥的 `invoke` 帧可以直接发（`{type:"invoke", plugin:"clam-notify",
action:"act", payload:{id, actionId, text?}}`），桥支持多客户端，不影响正在跑的壳。

## 已知边界

- **横幅显不显示最终归系统管。** 「定时摘要」开着、专注模式开着、通知样式设成"无"，
  我们这边一切正常（`willPresent` 照常触发、通知照常进通知中心、角标照常变），
  就是不弹。排查顺序：⌥⌘D 看插件世代 → 日志里有没有「发通知」→ 系统设置里那三项。
- 通知中心里的按钮点了之后 macOS 会自己收起那条通知，我们不需要（也没办法）控制
  这个动画。
- 角标默认只数**待办**（批准 + 提问），不数"跑完了"那类——后者是信息，不是欠你的事；
  想数就打开 `badgeIncludesDone`。
