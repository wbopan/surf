# clam 契约总表

surfclam 的跨插件契约**全是字符串**——槽名、事件主题、保管箱键、metadata 键、
hook 名、命令 id。这是有意的：壳是预编译产物，第三方改不了它，所以任何"把词汇冻进
ABI"的做法都会把生态钉死（判据写在 `ClamContributions.swift` 顶注）。

代价是**抄错一个字母是静默失败**：注册进一个没人消费的槽、订一个没人发的主题、
把 metadata 键拼错，界面上什么都不会发生，没有编译错误，也没有日志。
所以需要一张人能读的清单——就是这一份。

> **谁是权威**：每一节都标着"权威在哪"。**权威永远是代码**（那里写着"为什么"和
> "失败长什么样"），这份文档只是汇总与索引，方便"我要接一条新的，现有的都有哪些"
> 这类横向问题。两边对不上时以代码为准，并顺手改这里。

写插件的完整上手路径见 [`plugin-author-guide.md`](plugin-author-guide.md)。

---

## 1. 命令声明 `commands`

**权威**：`clam-bridge/lib/plugin.js` 的 `CommandDeclaration` typedef。

菜单项、默认键位、⌘/ 面板、`clam-shortcuts` 设置页，**四样东西一份声明**。
声明方是插件的 node 半边，读者两个：

```
createSwiftPlugin({ commands: [...] })
   └→ 桥的登记表
        ├→ 壳（snapshot 的 commands 字段）：建菜单项 + 装默认键位 + ⌘/ 面板
        └→ clam-app（clamBridge.commands.list/subscribe）：拼 clam-shortcuts 的 schema
Swift 半边照旧订 ClamEventBus.Topic.menuCommand 应答。
```

**壳一个 id 都不认得。** 插件缺席时那条菜单项根本不出现（不是灰着，也不是报错）。

| 字段 | 类型 | 必填 | 含义 |
|---|---|---|---|
| `id` | string | ✅ | 命令名 = `menuCommand` 载荷里的 `command`，同时是设置项键名。全局唯一，同 id 由多家声明时**先登记的赢** |
| `menu` | string | | `app`/`file`/`edit`/`view`/`window`/`help` = 系统菜单；其余 id 造一个新顶级菜单。**省略 = 不进菜单**（页内执行的键） |
| `menuLabel` | `{zh,en}` | | 自定义菜单的标题（首个声明者定） |
| `menuOrder` | number | | 自定义菜单在菜单栏里的位置，都夹在「显示」与「窗口」之间 |
| `label` | `{zh,en}` | ✅ | 菜单项文案。`digits` 形态里可用 `{n}` 占位 |
| `order` | number | | 同一菜单内排序，越小越靠上 |
| `separatorBefore` | bool | | 本项之前插一条分隔线（菜单当时为空则不插） |
| `key` | string | | 默认键位，语法见壳的 `KeymapSpec`（`cmd+shift+]`、`cmd+alt+a`、`esc`）。省略 = 没有默认键 |
| `keyChoices` | string[] | | 键位只允许这几个值（设置页画成下拉而不是文本框） |
| `configurable` | bool | | 进不进 `clam-shortcuts` 设置页，默认 `true` |
| `description` | `{zh,en}` | | 设置页上的说明，省略则用 `label` |
| `hidden` | bool | | 菜单项藏起来但快捷键照常生效（⌘1-9 那九项） |
| `digits` | `{count,command,argKey}` | | **一族**命令：一个设置键装 `count` 个数字菜单项，第 N 项 emit `command` 并带 `{[argKey]: N}`。这时 `key` 只写修饰键（`cmd` / `cmd+alt` / `off`） |

### 当前在册的声明

| 插件 | id |
|---|---|
| clam-layout | `openSettings`（⌘,）、`newSession`（⌘N）、`stopGenerating`（Esc，无 `menu`） |
| clam-settings | `openSettings`（与 layout 同一条：谁在场都有这一项，所以两边文案与默认键必须一致） |
| clam-sidebar | `renameSession`、`archiveSession`、`focusSearch`、`prevSession`、`nextSession`、`nextPendingSession`、`sessionDigits`（digits 形态，⌘1-9） |

### 一条已知的时序毛刺

桥的 `rescan` 只在 `swift/` 目录的文件签名变化时 bump 登记表版本，
所以**只改 `commands` 不改 Swift 源码时不会推 snapshot**（插件注册/注销时顺带 bump，
实际够用）。改了菜单文案没反应就重启 dsh——反正改 `lib/*.js` 本来就要重启。

另外：冷启动那一瞬间菜单只有系统惯例项，声明到齐（毫秒级）才补上业务项。
声明住在 node 半边就必然如此。

---

## 2. `toolbar` 贡献槽

**权威**：`clam-layout/swift/LayoutContracts.swift` 的 `ToolbarSpec`（生产端）
与 `clam-layout/swift/ToolbarContribution.swift`（消费端）。

槽名 `LayoutToolbar.slot`（值 `"toolbar"`）。别抄字面量——`import ClamLayout`
按名字引，拼错就编不过。

```swift
host.contribute(to: LayoutToolbar.slot, id: "filter", order: -100,
                metadata: ToolbarSpec(label: "筛选",
                                      symbol: "line.3.horizontal.decrease",
                                      menu: buildMenu).metadata()) {
    AnyView(EmptyView())   // 只有 kind == .view 那条路线用得上
}
```

### 2.1 拓扑：`ToolbarSpec` 的键

**这一节的每个键一变就重建整条工具栏。** 消费方读的是字典（SDK 的贡献槽只收容器
不收词汇），`ToolbarSpec` 给的是生产端的类型安全；`metadata()` **缺省值一律省略
而不是写进字典**——两者等价，而 `kind` 必须能表达"没说"（缺席 = 按 symbol 推断）。

| 键 | 类型 | 缺省 | 含义 |
|---|---|---|---|
| `label` | String | — | 标题 + 无障碍名。**必填**，缺了退化成贡献的 `id` |
| `symbol` | String | — | SF Symbol 名。给了它而没写 `kind` 时渲染路线推断成 `button` |
| `tooltip` | String | `label` | 悬停提示 |
| `event` | String | `clam.toolbar.activate` | 点击时广播的主题 |
| `region` | `sidebar` \| `content` | `sidebar` | 落在分栏分隔线哪一侧 |
| `align` | `leading` \| `trailing` | `leading` | 夹在 `flexibleSpace` 哪边。**只有 `content` 区认它** |
| `spaced` | Bool | `false` | 本项之前插一个系统标准间距 = 把玻璃胶囊断开成两枚 |
| `sizing` | `fixed` \| `dynamic` | `fixed` | 只有 `view` 路线看它 |
| `kind` | `button` \| `group` \| `menu` \| `view` | 由 `symbol` 推断 | 用哪条渲染路线，见下表 |
| `priority` | `low` \| `standard` \| `high` | `standard` | 窗口收窄时谁先进 `»` 溢出菜单 |
| `items` | `[[String: Any]]` | `[]` | `group` 的分段 / `menu` 的初始菜单 |
| `menu` | `@convention(block) (NSMenu) -> Void` | — | 菜单的**另一条**路线：贡献方现场建。给了它就不看 `kind`/`items` |

四条渲染路线：

| `kind` | 造出来的东西 | 白送什么 |
|---|---|---|
| `button` | `NSToolbarItem` + `isBordered` | 圆形玻璃按钮、按下态、红绿灯对齐 |
| `group` | `NSToolbarItemGroup`（`.selectOne` + `.expanded`） | 段控外观、选中态、键盘、无障碍 |
| `menu` | `NSMenuToolbarItem` | 下拉 indicator、菜单定位、键盘导航 |
| `view` | `NSHostingView` 装贡献自己的 `AnyView` | **什么都不送**，宽度间距自己算 |

**能用前三条就别用第四条。** `items` 的元素形状（`ToolbarSpec.items` 的文档注释里
有完整版）：

```swift
["id": "chat", "label": "Chat", "symbol": "text.bubble"]            // group 的一段
["id": "std", "label": "标准模式", "state": true, "enabled": true]   // menu 的一项
["separator": true]                                                  // menu 的分隔线
["label": "父会话", "detail": "3 分钟前", "submenu": [...]]           // 两行 + 子菜单
```

### 2.2 流量：`clam.toolbar.update` 活通道

**权威**：`ToolbarContribution.swift` 的 `ToolbarItemState`。

徽标数字、菜单内容、段控选中态、显隐是**流量**，一秒能变好几次。走 metadata 等于
每次把工具栏拆了重装（按钮会闪、popover 会掉），所以走事件：

```swift
host.events.emit(LayoutToolbar.updateTopic,
                 ["owner": host.plugin, "id": "filter", "badge": 3])
```

| patch 键 | 类型 | 含义 |
|---|---|---|
| `owner` / `id` | String | 定位哪一条贡献（必带） |
| `hidden` | Bool | `NSToolbarItem.isHidden` |
| `enabled` | Bool | |
| `badge` | Int | 0 = 不显示徽标 |
| `selectedIndex` | Int | `group` 的选中下标；-1 = 不选 |
| `label` / `tooltip` | String | 覆盖 metadata 里的那份 |
| `menu` | `[[String: Any]]` | `menu` 路线的菜单内容 |
| `items` | `[[String: Any]]` | `group` 的分段覆盖。**改它会重建整项**（images/labels 是构造时给的） |

消费方把 patch **记账**（跟着 `(owner, id)` 而不是跟着项），所以换代、显示模式变化、
溢出进出之后状态会被补回去。

唯一的例外是 `label` 这类拓扑值：**换语言的正路是重新贡献同一组 `(owner, id)`**
（就地覆盖、位置不变），不是发 patch。

### 2.3 回程：消费方 → 贡献方

| 主题 | 常量 | 载荷 |
|---|---|---|
| `clam.toolbar.activate` | `LayoutToolbar.activateTopic` | `slot` / `owner` / `id`；`group` 另带 `index` 与 `itemId` |
| `clam.toolbar.menuSelect` | `LayoutToolbar.menuSelectTopic` | 同上 + 被选项的 `itemId` |
| `clam.toolbar.menuOpen` | `LayoutToolbar.menuOpenTopic` | `owner` / `id`。菜单**将要打开**，给贡献方一次预热机会 |

原生项拿不到闭包（`NSToolbarItem` 的 target/action 必须是 `@objc`，而闭包跨不了世代），
所以点击一律翻译成广播。

---

## 3. 替换槽（`ClamRegistry`）

一槽一主，后来者覆盖。

| 槽名 | 常量 | 谁开的 | 谁占 | 没人占会怎样 |
|---|---|---|---|---|
| `root` | 壳里的字面量 | **壳**（唯一一个壳认得的槽名） | clam-layout | 壳退化成全出血 WebView（逃生舱） |
| `sidebar` | `LayoutSlots.sidebar` | clam-layout | clam-sidebar | 不装那个 `NSSplitViewItem`，分栏退化成单栏 |

想写一个替代 clam-sidebar 的插件：占 `LayoutSlots.sidebar` 即可。**壳不认得这个槽名**
——网页那侧的门控参数由占 `root` 的插件经 `clam.web.query` 说了算（见 §4）。

---

## 4. 事件主题总表（`ClamEventBus`）

载荷一律只放 JSON 能表达的值。放引用类型 = 让引用过桥，换代后另一头拿到的是新 module
认不出的旧类型。线程约定：只在主线程 emit/subscribe。

**粘不粘由 emit 的一方按语义决定**：描述**状态**的（当前会话、当前语言）该粘，
描述**瞬间**的（菜单被按了一下）不该粘。新写状态型消息一律 `emitSticky`——
广播 + 运行时装载的插件 = 晚到的订阅者什么都不知道，而那个状态可能不再变。

| 主题 | 常量 | 粘性 | 发布方 | 订阅方 | 载荷 |
|---|---|---|---|---|---|
| `clam.menu.command` | `Topic.menuCommand` | 否 | 壳 | layout / sidebar / settings | `command`（+ `digits` 的 arg） |
| `clam.locale` | `Topic.locale` | ✅ | 壳 | layout / sidebar / settings / header | `locale`（`zh`\|`en`） |
| `clam.web.query` | 两侧各有一份 internal 常量：壳的 `MainWindowController.webQueryTopic`、layout 的 `LayoutPlugin.webQueryTopic` | ✅ | 占 `root` 的插件 | 壳 | `[参数名: 值]`。壳不设白名单也不解释，只拼进 URL；变了就重载页面 |
| `clam.endpointChanged` | `Topic.endpointChanged` | 否 | 壳 | **当前无人** | `httpBase` |
| `clam.page.<type>` | `Topic.pagePrefix + type` | 视消息 | 壳（页内桥转发） | 各插件 | 见 §5 |
| `clam.toolbar.update` | `LayoutToolbar.updateTopic` | 否 | 贡献方 | clam-layout | 见 §2.2 |
| `clam.toolbar.activate` / `.menuSelect` / `.menuOpen` | `LayoutToolbar.*` | 否 | clam-layout | 贡献方 | 见 §2.3 |
| `clam.window.title` | `LayoutToolbar.windowTitleTopic` | ✅ | 标识生产方（clam-header，**已停用**） | clam-layout | `title` / `subtitle`。空标题 = 交回给壳 |
| `clam.layout.titlebarMetrics` | `LayoutToolbar.titlebarMetricsTopic` | ✅ | clam-layout | 标识生产方 | `inset`（pt）。显示模式一变就变 |
| `clam.layout.newSession` | `LayoutPlugin.newSessionTopic`（internal，外部照抄字符串） | 否 | 任何人 | clam-layout | — |
| `clam.activateWindow` | `Topic.activateWindow` | — | **无** | **无** | **死词汇**，P1 清 SDK 时删 |

> **注**：这两条原先是纯广播 + 两条 request 通道（`clam.window.requestTitle` /
> `clam.layout.requestTitlebarMetrics`）让后到的订阅者自己喊一嗓子补发。
> P0 #4 把它们改成 `emitSticky` 并删掉了那两条 request 通道——粘性总线就是为这件事
> 设计的，纯减法。**新写这类"状态型"消息别再配 request 通道。**

死通道别当成活的读：`clam.activateWindow` 无发无收；`clam.endpointChanged`、
`clam.page.ready`、保管箱键 `clam.endpoint` 只发不收；`clam.layout.newSession` 只订不发
（⌘N 现在走 `commands` 声明 → `menuCommand`，这条主题留给第三方按钮）。

---

## 5. 页内桥 `clam.page.*`

**壳对页内消息不设白名单。** 网页里

```js
window.webkit.messageHandlers.clam.postMessage({ type: "yourType", ... })
```

的任意 `type` 一律原样广播成 `clam.page.<type>`，载荷就是那个字典本身。
**想接一条新页内消息不用改壳**，订 `ClamEventBus.Topic.pagePrefix + "yourType"` 即可。

当前在用的：

| type | 主题 | 发送方 | 接收方 |
|---|---|---|---|
| `ready` | `Topic.pageReady` | 壳注入的引导脚本 | 壳自用（`capabilities`） |
| `currentSession` | `Topic.pageCurrentSession`（**粘性**） | clam-layout 的 client 半边 | clam-notify / clam-header |
| `keymap` | `clam.page.keymap` | clam-layout 的 client 半边（真相是 `clam-shortcuts` 设置） | 壳 |
| `locale` | `clam.page.locale` | clam-layout 的 client 半边（真相是 dsh 的 `locale` 设置） | 壳（转成 `clam.locale` 粘性广播） |
| `debug` | `clam.page.debug` | 各 client 半边 | 壳（写日志） |
| `headerTabs` / `headerReady` / `headerDiag` | `clam.page.header*` | clam-header 的 client 半边（**已停用**） | clam-header 的 Swift 半边 |

`pageCurrentSession` / `pageReady` 之所以在 SDK 里有常量，只因为壳自己也要用它们；
其余动态主题不逐个加常量。

---

## 6. 保管箱键（`ClamObjects`）

**只放系统类型或 SDK 类型的实例。** 插件自己定义的类型跨世代取出来 `as?` 只会安静地
得到 nil（新旧 module 里的同名类型互不认识）。

| 键 | 常量 | 类型 | 谁写 | 谁读 |
|---|---|---|---|---|
| `clam.webView` | `ClamObjects.Key.webView` | `WKWebView` | 壳 | layout / nativeify / header |
| `clam.endpoint` | `.endpoint` | `NSURL` | 壳 | **当前无人** |
| `clam.conversationSurface` | `.conversationSurface` | `ClamConversationSurface`（协议定义在 **clam-layout**，读者要 `import ClamLayout`） | clam-layout | sidebar / notify / header |
| `clam.settingsOwner` | `.settingsOwner` | `NSWindow`（**只看在不在**） | clam-settings | clam-layout（有主就不弹页内 modal） |

上面四个是 SDK 里有常量的。**其余键是插件私有的跨代锚**，键名写在各自的 Swift 文件里，
别人不该读：

| 键 | 主人 | 用途 |
|---|---|---|
| `clam.sidebar.snapshot` | clam-sidebar | 上一代收到的最后一份 snapshot（`NSDictionary`），新代先拿它渲染再要 fresh |
| `clam.notify.inbox` / `.presented` / `.currentSession` / `.swept` | clam-notify | 待办清单、已发通知账、当前会话、"这个进程已经清过一次"的标记 |
| `clam.header.snapshot` / `.tabs` | clam-header | 同 sidebar |

> **`.conversationSurface` 与 `.settingsOwner` 是业务词汇寄居 SDK**（协议本身都不在
> SDK 里），P1 清 SDK 时会挪进 clam-layout 的 `.swiftmodule`。别再往 `ClamObjects.Key`
> 里加新的业务键——纪律是"只放壳自己创建并持有的对象"。

**不占槽的插件用保管箱做"按进程收口"的动作**：Swift 热替换每改一行就 `activate` 一次，
"清掉上一次运行留下的东西"这类动作挂在 `activate` 上会每代都执行一遍。往
`host.objects` 插一个标记键即可——保管箱天然是进程级的（`clam.notify.swept` 就是它）。

---

## 7. hook 名（`ClamHooks`）

**权威**：`clam-app/host/Sources/Native/SystemDelegateRelay.swift` 顶注。

给"系统要求在启动完成前就注册好、而实现在插件里"这一类事情用。壳在
`applicationDidFinishLaunching` 的第一句占住系统 delegate，把回调**原样拍平**成字典，
经钩子问一遍插件，再把答案翻回系统要的形状。壳侧只有转发，没有业务判断。

| hook | 载荷 | 答复 | 时机 | 派发方式 |
|---|---|---|---|---|
| `system.notification.willPresent` | `identifier`、`userInfo` | `["present": ["banner","list","sound"]]`；没人接 = 系统默认（前台**不显示**） | 通知到达且 app 在前台 | `dispatch` |
| `system.notification.response` | `identifier`、`userInfo`、`actionIdentifier`、`userText?` | 不看 | 用户点了通知或它的按钮 | `dispatchRetained`（冷启动时插件还没装完，这一拍不能丢） |

要答复的用 `dispatch`；"必须送达、但可以晚几秒"的用 `dispatchRetained`
（未认领的早鸟事件留最多 8 条，满了丢最老的）。

加一个住户 = 壳的 relay 多 conform 一个系统协议 + 两行拍平 + 起一个 hook 名，
**SDK 与插件协议一个字不动**。可预见的后续住户：URL scheme、Dock 拖放、Services、
`NSUserActivity`。

---

## 8. node 半边 ↔ Swift 半身（`ClamBridge`）

**不是全局词汇**：`push` 的 channel 名与 `expose` 的 action 名由每个插件自己定义，
只在自己两个半边之间成立，别人不该也不需要认得。

```js
// node 半边
createSwiftPlugin({
  subscribe: ({ ctx, push }) => { ctx.on("session/created", () => push("sessions", {...})); },
  expose:    { archive: (payload, { ctx }) => { /* Swift 半身触发的动作 */ } },
});
```

```swift
// Swift 半边
host.bridge.onMessage { channel, payload in ... }   // 收 push
host.bridge.send(action: "archive", payload: [...]) // 触发 expose
```

桥断开时 `send` **静默丢弃**（不排队、不报错）：真相在 dsh 侧，补发一个过期动作比
丢掉它更糟。WS 帧本身的形状见 `clam-bridge/README.md`——那是壳与桥之间的事，
插件作者用不到。

---

## 9. 持久化（`ClamStore`）

每插件一个命名空间（落 `<AppSupport>/native-plugins/store/<插件名>.json`），
键名插件私有。**尽力而为**：读失败一律当没有，等同冷启动。真相在 dsh 侧，这里存的
都是"丢了不心疼"的装饰状态；一旦需要它可靠，说明那份数据放错地方了。

现有用法示例：`clam.sidebar.filter.mode` / `.showArchived` / `.hiddenGroups`
（侧边栏的筛选状态）。

---

## 10. 一句话速查

| 我想…… | 用什么 | 在哪一节 |
|---|---|---|
| 加一条菜单项 / 全局快捷键 | node 半边 `commands` 声明 | §1 |
| 往工具栏加一格 | `host.contribute(to: LayoutToolbar.slot, metadata: ToolbarSpec(...).metadata())` | §2.1 |
| 改那一格的徽标 / 选中态 / 菜单内容 | `emit(LayoutToolbar.updateTopic, patch)` | §2.2 |
| 整个替换侧边栏 | `host.register(slot: LayoutSlots.sidebar)` | §3 |
| 让页面 URL 带一个参数 | 占 `root` 的插件 `emitSticky("clam.web.query", …)` | §4 |
| 接一条新的页内消息 | 网页 `postMessage({type})` + 订 `pagePrefix + type` | §5 |
| 让状态活过热替换 | `host.objects`（只放系统类型）或 `host.store` | §6 §9 |
| 接一个系统 delegate | `ClamHooks` + 壳的 `SystemDelegateRelay` 多两行 | §7 |
| node 半边给 Swift 半边送数据 | `subscribe`/`push` 与 `expose`/`send` | §8 |
