# surfclam 架构耦合审计（2026-08-29）

审计问题只有三个：

1. 二次开发者什么时候会被迫**重新编译 macOS App**（壳 + ClamSDK）？
2. 插件之间有没有"A 为 B 特地留的口子"？新插件接入要不要改别人？
3. 整体形状是否**匹配 dsh / cordis 的设计方式**？

方法：四路并行只读审计（壳↔插件、插件↔插件矩阵、dsh 源码调研、外部二次开发者路径），
结论逐条回到源码核实；文中所有 `文件:行` 都是 main 分支 `3c6d3ec` 上的位置。
本文只审计不改代码，建议部分给出具体做法与涉及文件。

---

## 0. 结论摘要

**机制层是干净的，词汇层是脏的。**

- ClamSDK 的四张表（`ClamRegistry` 替换槽 / `ClamContributions` 贡献槽 / `ClamHooks` 应答钩子 /
  `ClamEventBus` 事件总线）**一个具体业务词汇都没有**，且每张表都写下了拒绝业务词汇的判据
  （`ClamContributions.swift:22-29`、`ClamHooks.swift:18`）。这与 dsh 的槽系统高度同构，是该保留的骨架。
- 插件之间**几乎零直接引用**：所有跨插件箭头都指向 clam-bridge（工厂）或 clam-layout（槽消费方）；
  client 半边三家完全零耦合。这是对的。
- 真正的耦合集中在 **4 个点**，按严重程度：
  1. **壳焊死了整张"会话业务菜单 + 快捷键 + 双语文案"词汇表**——任何插件加一条菜单命令或全局快捷键
     都必须改壳、重编 App。这是"被迫重编 App"的唯一高频原因。
  2. **`ClamObjects.Key` / `ClamEventBus.Topic` 两个字符串常量集市混进了业务词汇**
     （`conversationSurface`、`settingsOwner`、`pageCurrentSession`、死掉的 `activateWindow`）——
     每加一个常量的代价是"全部插件重编 + App 重构建"。
  3. **侧边栏没有任何贡献槽**：想给会话行加一列装饰/筛选，是全仓唯一必须改别人代码的场景。
  4. **外部 npm 包今天跑不起来**，但不是架构原因：registry 模式下壳产不出来（xcodegen 不在 `files`
     白名单、`ensureXcodegen` 只在 link 模式跑），scoped 包名会被 `moduleName()` 生成非法 Swift 标识符。
- 与 dsh 相比，surfclam **缺的不是类型，是运行期的槽声明、可选依赖、metadata 校验与错误边界**。
  另有一处结构性分歧：dsh 把"活数据"放在 slot entry 的 store 与 owner props 里，surfclam 把它们
  压进了一条扁平字符串总线（`clam.toolbar.update` 那一类）。

| 维度 | 评分 | 一句话 |
|---|---|---|
| SDK 容器设计 | ★★★★★ | 零业务词汇，判据写在注释里，与 dsh single/list 槽同构 |
| 插件间耦合 | ★★★★☆ | 只指向 bridge/layout；四处小口子可全部通用化 |
| 壳的业务无知 | ★★☆☆☆ | 菜单/快捷键/文案三张表焊死在壳里 |
| 外部二次开发 | ★★☆☆☆ | 架构允许，工具链与文档不允许 |
| 与 dsh 同构度 | ★★★☆☆ | 编排表、槽形状同构；缺声明/校验/可选依赖 |

---

## 1. 现状地图

```
                 ┌──────────── 壳（预编译产物，第三方改不了）────────────┐
                 │ MainWindowController / ShellRootView / WebPolicy /     │
                 │ SystemDelegateRelay / NativePluginHost / Compiler       │
                 └───────────────────────┬────────────────────────────────┘
                                         │ 唯一 ABI：ClamPlugin 协议 + ClamHost 七个字段
                 ┌───────────────────────┴────────────────────────────────┐
                 │ ClamSDK dylib（全进程一份）                             │
                 │ registry(1槽1主) contributions(1槽N条) hooks events     │
                 │ objects(保管箱) store(持久化) bridge(与 node 半身通道)   │
                 └───────────────────────┬────────────────────────────────┘
                                         │ 字符串约定：槽名 / 主题名 / hook 名 / metadata 键
   clam-layout ──占 root 槽、消费 sidebar 槽、消费 toolbar 贡献槽
   clam-sidebar ──占 sidebar 槽、贡献 toolbar 一条、订 menuCommand
   clam-notify ──不占槽、应答 system.notification.* hook、provide clamPending
   clam-settings ──不占槽、写 clam.settingsOwner
   clam-nativeify ──不占槽、读 clam.webView
   clam-header（停用）──贡献 toolbar 四条、订 clam.page.currentSession
```

五条跨插件通道及其当前用量：

| 通道 | 机制 | 当前跨插件用法 |
|---|---|---|
| cordis `inject` / `ctx.provide` | 声明式依赖、按名注入 | `clam-layout` 空标记服务（挂载时序）；`clamPending`（notify → sidebar）；`clamBridge` |
| 相对路径 `import ../../clam-bridge/lib/*` | 模块 | 6 处 `plugin.js`（公开出口）+ 3 处 `locale.js`（**不在 exports 里**） |
| `ClamRegistry` 槽 | 1 槽 1 主 | `root`（layout ↔ 壳）、`sidebar`（sidebar ↔ layout） |
| `ClamContributions` 槽 | 1 槽 N 条 + `[String: Any]` metadata | `toolbar`（sidebar/header → layout） |
| `ClamEventBus` 主题 | 扁平字符串广播（可粘性） | `menuCommand`、`clam.window.title`、`clam.toolbar.update/activate`、`clam.page.*`、`clam.locale` |
| `ClamObjects` 键 | 裸 `[String: AnyObject]` | `clam.conversationSurface`（layout → sidebar/header/notify）、`clam.settingsOwner`（settings → layout） |
| `ClamHooks` | 1 hook 1 主、壳侧 dispatch | `system.notification.*`（壳 → notify） |

---

## 2. 问题一：什么时候必须重编 macOS App

壳的 `WebPolicy.swift` / `ClamWebView.swift` / `CompilerService.swift` / `BridgeClient.swift` /
`GenerationLedger.swift` 里**零具体插件知识**。真实行为分支级别的耦合按强度排序：

### 2.1 加一条菜单命令 / 全局快捷键 ★ 最高频、最严重

同一张词汇表在**四处**硬编码，三处在 Swift 里：

| 处 | 位置 | 内容 |
|---|---|---|
| 菜单结构 + 8 个 `@objc` selector | `MainWindowController.swift:679-846`、`:1071-1105` | 文件→新建/重命名/归档、会话→上一个/下一个/下一个待处理、显示→聚焦搜索、⌘1-9 |
| 默认键位 + 命令白名单 | `MainWindowController.swift:1381-1402` | `Keymap.defaultSpecs` 十条、`menuCommands` 八条 |
| 双语文案 | `Strings.swift:62-96` | "新建会话 / 归档会话 / 下一个待处理会话 / 会话 N" |
| 设置 schema | `clam-app/lib/index.js:154-192` | `clam-shortcuts` ns 九个键 |

而这些命令的**实现方全在插件里**：`newSession`/`openSettings` 归 clam-layout（`LayoutPlugin.swift:31-40`），
七条会话导航归 clam-sidebar（`SidebarShortcuts.swift:32-39`），`openSettings` 由 clam-settings 应答
（`SettingsPlugin.swift:81`）。壳替它们记账，却不知道它们是谁。

两处默认值表**必须逐字一致且无任何校验**——源码自己承认（`MainWindowController.swift:1349-1352`、
`lib/index.js:141-145`："分家了不报错"）。这是现成的漂移源。

⌘/ 面板本身是现场遍历 `NSApp.mainMenu`（`ShortcutsPanel.swift:154-167`），但遍历不到的"页内快捷键"
要在 `:147` 手工补（`stopGenerating` 就是这么补的）。

**解法**：开一个 `commands`（或 `menu`）贡献槽，metadata 承载
`{menu, label, labelEn, order, command, defaultKey, description}`；`setupMenus()` 拆成
"系统惯例段（硬编码）+ 贡献遍历段"；`Keymap.defaultSpecs` 从 contributions 现采；`Strings.swift:62-96`
八条业务文案随贡献走（插件自带 `swift/Strings.swift` 已是既定做法）。node 侧 `createSwiftPlugin` 加一个
`shortcuts` 字段，clam-app 从桥的登记表**动态拼** `clam-shortcuts` schema，顺带消灭"两张表逐字一致"这条无人校验的纪律。
`rebuildMenus()`（`:868-874`）已经是幂等入口，重建时机问题已解决。
**这是唯一一件需要改壳、但改完之后第三方永远不用再改壳的事。**

### 2.2 壳对 `sidebar` 槽名与 `?clam-native-sidebar=1` 的行为判断

`MainWindowController.swift:406-411` + `:452-470`：壳按 `registry.isOccupied("sidebar")` 决定 URL
带不带 `clam-native-sidebar=1`，不符就**重载整个页面**。但 `ClamRegistry.swift:36` 明说"壳只认得 root"，
`sidebar` 槽名的定义权在 clam-layout，`clam-native-sidebar` 更是 dsh web 侧（clam-layout client 半边）的私有参数。
第三方写一个占 `sidebar` 槽的替代品必须沿用这两个字符串；写别的槽名就永远拿不到门控——网页侧边栏被藏、原生侧边栏又不存在。

**解法**：改成粘性事件。占 root 槽的插件 `emitSticky("clam.web.query", ["clam-native-sidebar": "1"])`，
壳只订阅这条主题决定 URL 参数。壳从此不认得 `sidebar` 槽名，也不认得那个 dsh 参数。半天工作量。

### 2.3 动 ClamSDK 任何 public 声明

`CompilerService.swift:211-220` 的 `toolchainFingerprint` 折进 `ClamSDK.swiftinterface` 摘要 →
**每个插件的 contentHash 全变 → 全量重编**；SDK 又住在壳源码里（`ClamPlugin.swift:11-12`），改它必然 xcodebuild 整个 App。
这本身是正确的（`.swiftmodule` 对不上比慢几秒糟得多），所以问题变成：**SDK 里有哪些东西不该在那里、会被业务需求持续拉扯**。

| 声明 | 分类 | 判据 |
|---|---|---|
| `ClamPlugin` / `ClamDisposable` / `ClamPluginHandle` / `ClamHost` | ✅ 机制 | 唯一跨 dylib 协议见证表 |
| `ClamRegistry` / `ClamContributions` / `ClamHooks` / `ClamStore` / `ClamBridge` | ✅ 机制 | 槽名/hook 名是参数不是常量 |
| `ClamEventBus` 类体 + `emitSticky` + `Topic.pagePrefix` | ✅ 机制 | 前缀而非具体主题 |
| `Topic.endpointChanged` / `Topic.menuCommand` / `Topic.locale` | ⚠️ 边界 | 壳自己 emit，算壳的接口；但 `menuCommand` 载荷值域是纯业务 |
| `Topic.pageCurrentSession` / `Topic.pageReady`（`ClamEventBus.swift:71-73`） | ⚠️ 业务 | dsh 特有概念，本可只是 `pagePrefix + "..."` 的普通用法 |
| `ClamLocale` 值域写死 `zh`/`en`（`ClamLocale.swift:11-13`） | ⚠️ 业务 | 加第三门语言 = 改 SDK = 全量重编 + App 重构建 |
| `Topic.activateWindow`（`ClamEventBus.swift:61`） | ❌ 死词汇 | 全仓零 emit / 零 subscribe（已核实） |
| `ClamObjects.Key.conversationSurface`（`ClamObjects.swift:43`） | ❌ 业务进 ABI | 协议本身定义在 clam-layout（要 `import ClamLayout` 才能转型），只有键名寄居 SDK |
| `ClamObjects.Key.settingsOwner`（`ClamObjects.swift:48`） | ❌ 业务进 ABI | 纯插件间协议，SDK 完全不需要知道 |
| `ClamObjects.Key.webView` / `.endpoint` | ✅ 机制 | 壳拥有的对象，壳有权命名 |

**解法**：把 `conversationSurface` / `settingsOwner` 移进 clam-layout 的 `.swiftmodule`（照 `LayoutToolbar.slot` 的样子），
删 `activateWindow`，并在 `ClamObjects.Key` 上立一条纪律："只放壳自己创建并持有的对象"。
代价是一次全量重编 + App 重构建，**应与下一次必须动 SDK 的改动合并做**（见 §6 P1）。

### 2.4 接一个新的系统 delegate（URL scheme / Dock 拖放 / Services）

`SystemDelegateRelay.swift:41` 只 conform 了 `UNUserNotificationCenterDelegate`。加一个要多 conform 一个协议 +
两行拍平 + 起个 hook 名。**这是设计上已接受的成本，且成本极低**（`:25-29` 明确写了 SDK 一字不动、不引发全量重编）。
建议保持现状，只把 hook 名表从 Swift 注释挪进文档，并把 `system.notification.*` 这两个字面量
（`SystemDelegateRelay.swift:43-46` ↔ `NotifyCenter.swift:29-32` 各写一遍）收成一处常量。

### 2.5 诊断面板加一行

`diagnosticsText()`（`MainWindowController.swift:1180-1215`）是硬编码行列表，插件没有办法往 ⌥⌘D 里加一行。
`ClamHooks.occupancy` 已实现但**全仓零调用方**——`ClamHooks.swift:99` 的注释"⌥⌘D 面板会列它"是假的。
**解法**：面板遍历 `contributions.entries` 的 owner 与 `hooks.occupancy`，第三方"我注册上了吗"就有地方查。

### 2.6 右键菜单黑名单 / 下载与外链策略

`ClamWebView.swift:43-54`、`WebPolicy.swift:102-111`（scheme 白名单 http/https/mailto）在壳里。
**这是安全边界，放壳里是对的**（逃生舱模式也得能下载），不建议解耦。

### 2.7 clam-app 的私有帧

壳认得 `app-build` / `app-restart` / `restart-dsh`（`NativePluginHost.swift:114-163`），桥为它单开了 `bridge.app`
子 API（`clam-bridge/lib/index.js:126-143`、`:225-234`）。可接受——clam-app 是"壳的 node 半身"而非普通插件，
这是壳的自更新通道。但它是特权插件里**唯一为一个具体插件开的命名 API**；桥已有 `push/invoke` 信封与 `expose`，
把它降级成 clam-app 的普通 `expose`/`push` 频道即可消掉这个特例。

---

## 3. 问题二：插件为插件留的口子

### 3.1 依赖矩阵

行 = 依赖方，列 = 被依赖方。

| ↓ 依赖 \ 被依赖 → | bridge | 壳 / app | layout | sidebar | notify | settings | nativeify |
|---|---|---|---|---|---|---|---|
| **app** | 相对 import `locale.js`（`lib/index.js:30`，**非 exports 路径**）；inject `clamBridge` | — | 壳订 `clam.page.keymap`（生产方是 layout 的 client 半边） | 壳注册 `clam-shortcuts` ns、菜单命令全是 sidebar 的 | 壳占 UN delegate 经 hook 转交（唯一用户） | | |
| **layout** | 相对 import `plugin.js` | `clam.webView` / `menuCommand` / `clam.locale` | — | 消费 `sidebar` 槽（`LayoutSplitController.swift:168/640`） | | 读 `clam.settingsOwner`（`LayoutPlugin.swift:36`） | |
| **sidebar** | 相对 import `plugin.js` | 订 `menuCommand` 七条（`SidebarShortcuts.swift:32-39`） | inject `clam-layout` + swiftDeps + `import ClamLayout`；取 `clam.conversationSurface`；贡献 `LayoutToolbar.slot` | — | inject `clamPending`（`lib/index.js:185`），`kind` 词汇由 notify 定义、sidebar 映射（`:96-109`） | | |
| **header**（停用） | 相对 import `plugin.js` | 订 `clam.page.currentSession` | 同 sidebar 三件套；槽名是**自己硬写的字面量** `"toolbar"`（`HeaderPlugin.swift:50`） | | | | |
| **notify** | 相对 import `plugin.js` + `locale.js`（`strings.js:19`、`locale.js:24`） | hook `system.notification.*`（名字与壳各写一遍） | inject `clam-layout` + swiftDeps；取 `clam.conversationSurface`；订 `clam.page.currentSession` | | — | | |
| **settings** | 相对 import `plugin.js` | 订 `menuCommand` openSettings | 写 `clam.settingsOwner`（`SettingsPlugin.swift:53/66/90`） | | **文案表硬编码 ns**（`FieldNotes.swift:128/254`） | — | **文案表硬编码 ns**（`FieldNotes.swift:122/248`） |
| **nativeify** | 相对 import `plugin.js` | 读 `clam.webView`（`NativeifyPlugin.swift:132`） | | | | | — |

**client 半边三家零耦合**：各自 `exports.inject = []`，无 import、无共享全局，`data-clam-*` 属性命名空间不相交；
收起 web 侧边栏与 `_overlay` 例外都只在 layout（`client.js:596/607`），nativeify 文件头 `:11-18` 明确声明不碰。
三家各自复制了 `insideClam()` / `postToShell()` / `makeToken()`——重复但无耦合。

**死通道**（会让读代码的人误以为存在联动）：`clam.activateWindow`（无发无收）、`clam.endpointChanged` /
`clam.page.ready` / objects 键 `clam.endpoint`（只发不收）、`clam.layout.newSession`（只订不发）。
header 停用后 `clam.toolbar.*` 与 `clam.window.title` 五条通道当前只有 layout 一端在场。

### 3.2 "特地为某插件留的口子"清单

| # | 位置 | 为谁 | 那个插件不在会怎样 | 能否通用化 |
|---|---|---|---|---|
| 1 | `clam-bridge/lib/index.js:126-141` `bridge.app.{announce,onRestartRequest}` + `:225` `app-restart` 帧分支 | clam-app | 无害（warn 一句） | **可以**：降级成普通 `expose`/`push` 频道 |
| 2 | `clam-app/lib/index.js:154-192` 九个快捷键 + `MainWindowController.swift:1379-1398` 默认表 + `:630-650` 词汇 + `:1072-1105` 九个发布点 | layout(2) / sidebar(7) / settings(1) | 静默无事（设计如此） | **可以**：§2.1 的命令注册表 |
| 3 | `clam-layout/swift/ToolbarContribution.swift:60-70` `clam.window.title` + `requestTitle` / `requestTitlebarMetrics` 两条 request 通道 | clam-header（注释 `:64` 直接点名） | 通道空转 | **可以**：`emitSticky` 就是为此设计的，迁过去即可删掉两条 request 通道，纯减法 |
| 4 | `clam-layout/swift/LayoutPlugin.swift:36` `settingsOwner == nil` 才弹页内 modal | clam-settings | 退回 dsh 页内 modal（正确降级） | 已是通用机制（存在性令牌，非插件名），保留 |
| 5 | `SystemDelegateRelay.swift:43-46` 两个 hook 名 | clam-notify | 走系统默认 | 机制已通用；只需把名字收成一处常量 |
| 6 | `clam-settings/swift/FieldNotes.swift:122/128/248/254` 为 `clam-nativeify`/`clam-notify` 写死的中英文案 | 那两个插件 | 退回机械美化（`humanize`） | **可以**：schema 已有 `.description()`，缺 ns 级 title/summary/featured 三个元数据字段，加上即可让插件自带文案 |
| 7 | `clam-sidebar/lib/index.js:96-109` `REASON_STATUS` + `STATUS_RANK` | clam-notify 的 `kind` 词汇 | 退回 approval-only（源码 `:268-281` 保留了这条路径） | 现状可接受：`clamPending` 是"事实"服务而非"notify"服务（notify `index.js:112-116` 刻意去插件化），未知 kind 被忽略、前向兼容 |
| 8 | `clam-layout/swift/LayoutSplitController.swift:472-540` toolbar metadata 12 个键，**唯一文档是这段注释** | 所有贡献方 | — | 贡献方各写字面量（`HeaderPlugin.swift:349-358`、`SidebarPlugin.swift:145-151`），写错键**静默退化**。应在 ClamLayout module 里加 `public struct ToolbarSpec`（或 `enum Key`）+ `toMetadata()`，消费方仍读字典（保持 SDK 容器中立） |

### 3.3 三个假想新插件走查

| 新插件 | 需要改谁 | 摩擦 |
|---|---|---|
| (i) 工具栏按钮 + 弹原生面板 | **谁都不用改**：`createSwiftPlugin({inject:["clam-layout"], swiftDeps:["clam-layout"]})` + `host.contribute(to: LayoutToolbar.slot, …)` + 自己 new `NSWindow`（照 `SettingsPlugin.swift:43-53` 用 `host.objects` 做世代锚） | metadata 键无共享常量无类型，全靠照抄注释 |
| (ii) node 半边订 dsh 事件 → 原生状态徽标 | **谁都不用改**：`subscribe/push` + `host.contribute` 一格 + `LayoutToolbar.updateTopic` 发 `{owner,id,badge}` patch；想被别人复用就 `ctx.provide` 一个中性服务名（`clamPending` 模式） | 徽标要落在 title 上则受限于口子 #3 |
| (iii) 给侧边栏会话行加筛选/装饰 | **必须改 clam-sidebar 本身**：snapshot JSON 由 node 半边一次性组好（`lib/index.js:251`），`status` 值域写死在 `STATUS_RANK` 与 Swift `SidebarSnapshot`/`StatusIndicator`，三枚胶囊硬编码 `.all/.time/.pending`；要动 `dsh-source.js` → `REASON_STATUS` → `SidebarSnapshot.swift` → `SidebarView.swift` 四层 | `clamPending` 是唯一现成扩展点，但只喂 `status` 一个字段、映射表在 sidebar 里 |

**(iii) 是全仓最缺贡献槽的地方。** 最小方案：snapshot 的 session 行留一个
`decorations: [{owner, id, symbol, tint, tooltip}]` 数组，由 `ctx.provide("clamSessionDecorations")`
之类的可选服务聚合（复刻 `clamPending` 的模式，`clam-notify/lib/index.js:118-140` 是现成模板）；Swift 侧渲染未知
owner 也不炸。这样 `clamPending` 自己也退成一个普通装饰提供方，`REASON_STATUS`/`STATUS_RANK` 随之消失。

### 3.4 对 dsh 内部细节的耦合（单列，dsh 升级时会断的）

`clam-*/lib/dsh-source.js` 与 `mux-source.js` 三份文件共 1399 行，**全部是 dsh 耦合的隔离层**——分层本身是对的
（换 dsh 只改这三个文件），但 sidebar 与 header 两份之间有明显重复（`SOURCE_SERVICES`、`canonicalId`、`call()`、信封）。

| 风险 | 耦合 | 位置 |
|---|---|---|
| 高 | `apiProxy.events.mux()/.host()` 进程内 async iterable + `apiProxy.respond({rpcId})`；帧类型 `host/session-status` 逐条判 | `clam-notify/lib/mux-source.js:69-87/230-234` |
| 高 | session id 前缀 `session-<uuid>` vs subagent 光 uuid | `sidebar/dsh-source.js:287`、`header/dsh-source.js:532` |
| 高 | dsh CSS module 类名 `_sidebarCol/_frame/_overlay/_flowItem/_markdown/_bubble/_composerSeat` | `layout/client.js:409/473/596/607`、`nativeify/client.js:83-96/136/367-376/678` |
| 高 | `body[data-ds-dark-theme]`、`--dsw-*` token 重写 | `nativeify/client.js:300-345/653/670/884/1019-1023` |
| 中 | cordis 事件名 `session/created|disposed|event`、`agent/status`、`domain/changed`（有 10s 哨兵 warn） | `sidebar/dsh-source.js:115-119` |
| 中 | ns/字段字面量 `ui-theme.preference`、`locale.preference`、`agent-presets.default`、`permission.defaultPreset`…（降级良好） | `nativeify/lib/index.js:58`、`settings/swift/SettingsTabs.swift:97-113` |
| 中 | `llm.listConfigurableProviders` / `credentials.*` / `agentPresets.*` / `pluginInventory.list`（嵌套 inject，缺一页少一页） | `settings/lib/{models,presets,inventory}.js` |
| 中 | `button[aria-haspopup="dialog"]` = 页内设置入口（settings 缺席时 ⌘, 唯一路径） | `layout/client.js:411` |
| 低但致命 | `__ModuleLoader__.load({id})` 必须逐字等于包名 | `layout/client.js:32`、`nativeify:28`、`header:45` |

---

## 4. 问题三：与 dsh / cordis 设计方式的对照

### 4.1 dsh 的解耦公式

dsh 源码随包发布，`~/.dsh/profiles/node_modules/@deepseek-ai/cordis/src/` 与
`dsh-client-runtime/lib/types/client/slots.d.ts` 是最权威的两份文档。核心机制：

- **cordis**：Context 树（原型链 + Proxy）；Service 按字符串名注册、owning fiber 卸载自动注销；`inject` 是"等待"不是"报错"
  （依赖服务出现前不 apply、消失时卸掉）；`ctx.effect` 可逆副作用；事件五种派发模式（`emit/parallel/serial/bail/waterfall`）。
  类型靠 TS **声明合并**收口（`declare module '@deepseek-ai/cordis' { interface Context { locale: … } }`）——
  **字符串键 + 全局类型表**是整个体系最重要的一招。
- **编排**：profile（bundles 清单）→ bundle（`cordis.patch.yml`）→ plugin（纯代码）。**行序不带加载语义**
  （`dsh-base/cordis.patch.yml` 顶注："activation is service-availability driven"）；配置里的 `!!js ctx.xxx`
  表达式也参与依赖排序。
- **槽系统**（`dsh-client-ui-slots`）：`SlotMap` 声明合并出全局表，`kind: single|list|keyed|chain`，
  `scope: root|session|session-maybe`，`owner` 是消费方传给贡献方的**类型化 props**。
  `ctx.slots.register(spec)` 时用 `children` **声明自己开的洞**（占槽即声明）。
  **`ctx.slots.inject(key, cb)` = 可选依赖**：槽还没被人声明，贡献静静等着；声明出现了自动装上；消失自动卸下。
  register 选项 = 元数据 + 生命周期托管：`id/order/label(函数)/locale/store(独占 store 工厂)/inject/children`。
  框架级保障：`onEntryError` 错误边界 + 退位（abdicate）、优先级选举、`data-slot` 一等 DOM 契约。

**dsh 官方插件之间的耦合风格**：包依赖只用来拿"类型 + 基座服务"，装配一律靠槽名字符串 + `slots.inject`，
没有任何一个插件为另一个具体插件留口子。三个例子：

1. `dsh-client-ui-theme` 往设置面板 General 页塞一行"外观"，`dsh.client.inject` 里**没有** `dsh-client-ui-settings-general`
   （真正渲染那个槽的插件），只靠 `ctx.slots.inject("settings.general.item", …)`。
2. `settings-plugins` 与 `settings-plugin-inventory` 在同一 Plugins 页协作、互不依赖；类型住在共同基座包
   `dsh-client-ui-settings/…/contract/slots.d.ts`（注释原文："the type lives here so inventory and configuration
   plugins collaborate without depending on one another"）。
3. `dsh-client-ui-sidebar` 占 `sidebar` 槽并声明 `sidebar.brand.mark / sidebar.workspaces / sidebar.settings /
   sidebar.footer.action` 四个洞——sidebar 里**没有一行会话列表代码**。依赖图是被刻意维护的 DAG。

### 4.2 同构 / 分歧 / 缺口

| dsh | surfclam | 评价 |
|---|---|---|
| `kind: single` 槽 | `ClamRegistry` | 同构；dsh 有优先级选举 + 退位，surfclam 是后来者覆盖 |
| `kind: list` 槽，`(registrant, id)` + `order` | `ClamContributions`，`(owner, id)` + `order` | **高度同构**；surfclam 多一条 `seq` 保位（热替换不跳位） |
| `ctx.effect` + fiber 卸载 | `ClamDisposable` / `ClamPluginHandle` / `activate` 返回值锚 | 同构 |
| cordis `bail` | `ClamHooks.dispatch`（1 hook 1 主） | 另起炉灶重造了 `bail` 的单主特例 |
| `slots.inject` 声明期效果 + store 快照 | `emitSticky` | 同一问题（运行时装载必然晚到）的更简单但更弱的解法 |
| `data-slot` | `accessibilityIdentifier` | 同构 |
| 伞 bundle + `dsh.bundle.patch` | `surfclam/cordis.patch.yml` | **完全同构**，这层做得对 |
| owner props（消费方 → 贡献方）+ register `store`/`inject`（贡献方 → 消费方） | **`ClamEventBus` 扁平字符串主题 + `[String: Any]`** | **最大分歧**：dsh 把"活数据"放在 entry 的 store 与 owner props 里，surfclam 把两个方向都压进总线（`clam.toolbar.update/activate`），总线同时是配置通道、状态通道和事件通道，顺序未定义、无命名空间 |
| cordis 服务（有类型、有 owner、自动撤销） | `host.objects` 裸 `[String: AnyObject]` | 无 owner、无撤销、任何插件可读写任何键 |

**dsh 有而 surfclam 没有**（按价值排序）：

1. **槽的声明与可选依赖**：surfclam 的 `contribute(to:)` 是无条件写入共享表。贡献先于消费方出现**不会丢**
   （`ClamContributions` 是 `@Observable` 进程级单例，消费方后到照样读到），但没有任何"这个槽有没有人在消费、
   是 single 还是 list、给贡献方什么数据"的声明；往一个永远没人消费的槽贡献是零反馈的。
2. **贡献的 schema 化 / 校验**：`metadata: [String: Any]` 零校验，键名拼错静默降级到缺省。
3. **错误边界与退位**：`make()` / hook body / event handler 全是裸调用，一个贡献者崩了整个进程走人。
4. **owner props**：sidebar 的 `wide`、settings 的 `close` 这类"消费方状态"在 surfclam 里只能走总线绕一圈。
5. **贡献级 store 托管**：`toolbarStates` 是 clam-layout 手搓的私有实现，换个槽要再造一遍。
6. **i18n 绑到贡献上**：dsh 的 `label` 是函数、`locale` 是一等选项；surfclam 文案是裸字符串，换语言要手写重新贡献。

**明确不建议照抄的**：dsh 的 `SlotMap` 靠 TS 声明合并做全局类型表，Swift 跨 dylib 类型身份按 contentHash 隔离，
没有等价物——别去造跨插件共享的 Swift 类型注册表，那正是 M10 退役 DSHKit 的理由。
**surfclam 的"字符串槽名 + 各家自己写文档"在这个约束下是合理的；缺的不是类型，是运行期的声明、校验与可选依赖。**

---

## 5. 问题四：外部二次开发者路径

### 5.1 架构层面：可行

- **包名 import 可行**：`clam-bridge/package.json` exports 已含 `"./plugin"`；`createSwiftPlugin` 是无状态纯工厂
  （`plugin.js:52-108`），只用 `ctx.clamBridge` 服务名 + `ctx.provide` + `ctx.effect`，不比对模块实例。外部包即便拿到
  第二份 `clam-bridge` 副本也没事——真正要求单例的是 `clamBridge` 服务提供者，它由伞包只挂一次。
  真正的实例身份风险在 `@deepseek-ai/schemastery`：外部包必须写 peerDependencies。
- **编排接入不用改伞包**：profile 自己的 `cordis.patch.yml` 在所有 bundle 层之后应用，insert 一行即可；
  `dsh plugin add` 对无 `dsh.bundle` 的包只 warn 不污染 `bundles`，`fixBundles` 也保留用户自己 add 的条目。
  挂载顺序由 `inject` 保证（`plugin.js:70-71` 自动补 `clamBridge`）。
- **热替换不要求 clone 本仓库**：桥轮询的是登记进来的绝对路径（`clam-bridge/lib/index.js:281-289`），
  壳从不读插件目录（源码经 WS 传过去，`CompilerService.swift:120-126`）。`dsh plugin add link:<自己的仓库>` 即可。
- **只写 Swift 插件不需要 Xcode**：编译子进程是 `/usr/bin/xcrun swiftc`（`CompilerService.swift:246-247`），CLT 足够；
  ClamSDK 的 `.swiftinterface` + dylib 随 App bundle 分发（`embed-modules.sh:19-29`）。

### 5.2 硬阻碍（直接跑不起来）

1. **registry 模式产不出壳**：`clam-app/package.json` 的 `files` 是 `["lib","host/project.yml","host/Sources","host/scripts"]`，
   不含 `host/tools/xcodegen`；`surfclam/bin/surfclam.js:66-70` 的 `ensureXcodegen` 只在 link 模式跑。
   `npx @wenbo/surfclam` 在干净机器上必然命中"缺 xcodegen"→ 无产物 → "优雅缺席"。**没有 App 就没有任何 Swift 插件的运行环境。**
   CLAUDE.md 承认"真要分发得 ship 预编译产物"，但没记录 xcodegen 这条更早的断点。
2. **scoped 包名生成非法 module 名**：`moduleName()`（`clam-bridge/lib/index.js:361-365`）只 `split(/[-_]/)`，
   `@acme/foo` → `@acme/Foo`，swiftc 直接失败，错误只在 dsh 终端末 20 行。无校验。
3. **部署目标钉死 `arm64-apple-macos27.0`**（`build-modules.sh:21`），SDK 较旧的机器编不过。

### 5.3 软阻碍（能跑但体验差）

4. **ABI 版本号是空承诺**：`ClamPlugin.swift:22-23` 写"壳装载插件前比对；不匹配即拒绝装载"，但 `NativePluginHost.swift`
   全文不引用 `clamABIVersion`；唯一消费者是 `CompilerService.swift:263` 那个手抄副本 `clamABIVersionForFingerprint = 1`。
   桥的 `PROTOCOL_VERSION` 同样只记日志不比对（`clam-bridge/lib/index.js:190-195`）。语义变更对老插件是静默漂移。
5. **编译失败零界面反馈**：只打 dsh 终端 stderr（`clam-bridge/lib/index.js:203-208`），完整日志埋在世代目录 `build.log`。
   症状是"插件不出现"。
6. **插件名即全局注册键**，重复只 warn 不拒（`:88-89`）。
7. **不占槽的插件 `activate` 必须返回持有链的根**（返回裸 handle 静默失效）——SDK 注释没写
   （`ClamPlugin.swift:62-64` 只说"壳持有它=在役"），只在 `clam-notify/README.md:169-177` 与两个插件源码里。
8. **`clam-bridge/lib/locale.js` 不在 exports 里**却被 clam-app、clam-notify 相对路径引用——发布形态下是引用内部实现。

### 5.4 文档：全仓只有一份写给插件作者的 README

`clam-bridge/README.md:42-63` 是唯一一份；其余 7 份是实现志；`surfclam/`（编排表所在）和 `ClamSDK/`
（`ClamPlugin.swift:15` 自称"插件作者必读"）都没有 README。约定的**注释质量极高**（每条都有"为什么"和"失败长什么样"），
但 100% 埋在 Swift 与 JS 注释里，对外不可发现。

只能从源码挖的信息：`./plugin` 子出口、`name → module 名`推导、`files` 必须含 `swift`、peerDependencies 纪律、
`dsh.client` + `exports["./client"]` 强制契约、`__ModuleLoader__` id 逐字等于包名、`activate` 返回值规则、
壳只认 `root`、toolbar 12 个 metadata 键、`clam.toolbar.update` 才是活通道、事件/保管箱/hook/menuCommand 四张词汇表、
跨代保管箱只能放系统类型、cordis fork 的 `inject` 无可选形态（`clam-settings/README.md:152-154` 唯一一处）。

**过时 / 矛盾项**：

| 项 | 位置 |
|---|---|
| `macOS 26+` vs 实际部署目标 `27.0`（`project.yml:5`） | `README.md:28`、CLAUDE.md 通篇 |
| "通知线也已丢弃（计划 §7.3）"与事实相反 | `clam-app/README.md:27` |
| 壳目录职责表漏 `WebPolicy` / `SystemDelegateRelay` / `GenerationLedger`；SDK 行只字未提 `ClamContributions` / `ClamHooks` / `ClamEventBus` | `clam-app/README.md:31-33` |
| 配置表 3 键 vs 实际 6 键 | `clam-app/README.md:58-66` |
| 桥帧表漏 `app-build` / `app-restart`；`createSwiftPlugin` 样例漏 `sharedModules` / `Config`；只教相对路径未提 `./plugin` | `clam-bridge/README.md:24-60` |
| toolbar metadata 只列 4 键（实际 12），全文未提 `clam.toolbar.update` | `clam-layout/README.md:50-55` |
| **"连自家新建会话也是一条普通贡献"**：`clam-layout/swift/` 里一个 `contribute` 调用都没有，工具栏眼下只剩 sidebar 的「筛选」一条 | CLAUDE.md |
| `clam-header/README.md` 通篇现在时，从不说自己已停用 | 全文 |
| DSHKit 作为现行选项出现 | `clam-settings/README.md:142`、`lib/index.js:6`、`docs/clam-settings-plan.md:136` |
| `ClamHooks.swift:99` "⌥⌘D 面板会列它"——零调用方 | `ClamHooks.swift:99` |
| 根 README 仓库结构漏 `clam-notify/` `clam-settings/` `clam-header/` **`surfclam/`** `tools/` | `README.md:68-79` |

---

## 6. 建议路线图

四路审计各自的 top 5 去重合并后按"收益 / 是否要动 SDK"分三档。**动 SDK 的项合并成一次做**（每次动 SDK = 全量重编 + App 重构建）。

### P0 —— 不动 SDK，现在就做

| # | 事 | 做法 | 涉及文件 |
|---|---|---|---|
| 1 | **命令 / 快捷键改成运行时聚合的注册表**（消掉壳最大耦合点 §2.1） | 开 `commands` 贡献槽，metadata `{menu,label,labelEn,order,command,defaultKey,description}`；`setupMenus` 拆成"系统惯例段 + 贡献遍历段"；`Keymap.defaultSpecs` 现采；`createSwiftPlugin` 加 `shortcuts` 字段，clam-app 动态拼 `clam-shortcuts` schema；`Strings.swift:62-96` 删 | `MainWindowController.swift:630-650/679-846/1071-1105/1379-1402`、`Strings.swift`、`clam-app/lib/index.js:154-192`、`clam-bridge/lib/plugin.js`、`LayoutPlugin.swift:31`、`SidebarShortcuts.swift`、`SettingsPlugin.swift:81` |
| 2 | **让外部包跑得起来**（§5.2） | `ensureXcodegen` 在 registry 模式也跑（PATH 分支已现成）或把 `.xcodeproj` 发布期生成入 `files`；`register()` 校验 `moduleName()` 是合法 Swift 标识符（否则抛并附提示）、`swiftDir` 存在非空、重复登记升为拒绝；`clam-bridge/package.json` exports 加 `"./locale"` | `surfclam/bin/surfclam.js:66-70`、`clam-app/package.json`、`clam-bridge/lib/index.js:87-104/361-365`、`clam-bridge/package.json` |
| 3 | **`sidebar` 门控改粘性事件**（§2.2） | 占 root 槽的插件 `emitSticky("clam.web.query", …)`，壳只订这条决定 URL 参数 | `MainWindowController.swift:406-411/452-470`、`LayoutPlugin.swift` |
| 4 | **删 request 通道、降级 `bridge.app`**（§3.2 #1 #3） | `clam.window.title` / `titlebarMetrics` 改 `emitSticky`，删 `ToolbarContribution.swift:60-70` 两条 request 与 `:421` 订阅、`HeaderPlugin.swift:307`、`HeaderToolbar.swift:65`；`bridge.app` 改成 clam-app 的普通 `expose`/`push` | `ToolbarContribution.swift`、`clam-bridge/lib/index.js:126-143/225-234`、`NativePluginHost.swift:114-163` |
| 5 | **toolbar metadata 代码化** | ClamLayout module 加 `public struct ToolbarSpec` + `toMetadata()`，`HeaderPlugin.swift:50` 的 `"toolbar"` 字面量换 `LayoutToolbar.slot`；槽名 `"root"` / `"sidebar"` 各给一个 public 常量 | `clam-layout/swift/LayoutSplitController.swift:472-540`、`SidebarPlugin.swift:109/145-151` |
| 6 | **文档** | 新建 `docs/plugin-author-guide.md`（三种骨架、package.json 字段表、命名规则、`files` 白名单、peerDependencies、profile patch 一行、`dsh plugin add link:` 热循环）与 `docs/clam-contracts.md`（toolbar metadata、`Topic`、`Key`、hook 名、`menuCommand` 四张词汇表，源码注释改为指向它）；修 §5.4 那张过时表；把 `ClamPlugin.swift:22-23` 的 ABI 承诺改成事实描述（或做成真的，见 P1） | `docs/`、各 README、CLAUDE.md |

### P1 —— 动 SDK，合并成一次

| # | 事 | 做法 |
|---|---|---|
| 7 | **`ClamContributions` 加声明 + 可选依赖 + 校验 + 错误边界**（对标 `slots.inject`，§4.2 缺口 1-3） | `declare(slot:owner:kind:expects:)` 让"槽存在"成为可观测事实；`inject(slot:_:) -> ClamDisposable`：槽未声明时挂起、声明后立即执行、槽消失时 dispose；`register` 时按 `expects: [String: 类型]` 比对 metadata，未知键/类型错打警告不拒绝；`make()` / hook body / event handler 包 try + 日志 + 从表里摘掉那一条（退位） |
| 8 | **owner props** | `make: ([String: Any]) -> AnyView`，消费方枚举贡献时把自己的状态（`wide`、`close`）传下去；随之把 `clam.toolbar.update` 这类"活数据"从总线迁到贡献级 store / owner props，总线只留真正的广播事件 |
| 9 | **清 SDK 业务常量**（§2.3） | 删 `Topic.activateWindow`；`Key.conversationSurface` / `Key.settingsOwner` 移进 ClamLayout module；`system.notification.*` hook 名收成一处；`ClamObjects.Key` 立纪律"只放壳自己创建并持有的对象" |
| 10 | **ABI 检查名副其实**（§5.3 #4） | 插件导出第二个 `@_cdecl("clam_plugin_abi") -> Int`，`NativePluginHost.swift:263-269` 在 `dlsym` 后比对 `clamABIVersion`，不匹配拒绝装载并报明确日志；删 `CompilerService.swift:263` 手抄副本改从 SDK 引入 |
| 11 | **诊断面板遍历式**（§2.5） | `diagnosticsText()` 增加贡献槽占用（含声明方）与 `hooks.occupancy` 两节；编译失败经桥回推粘性事件，面板设"最近编译失败"区 |

### P2 —— 结构对齐，成本高

| # | 事 |
|---|---|
| 12 | 侧边栏 `decorations` 贡献槽（§3.3 iii），`clamPending` 退成普通装饰提供方 |
| 13 | 贡献级 store 托管提到 SDK（按 `(owner,id) × 世代` 保管，热替换保状态），`toolbarStates` 退休 |
| 14 | i18n 绑到贡献：`label` 改 `() -> String` + `locale` 命名空间，`ClamLocaleStore` 变化自动 bump revision |
| 15 | `host.objects` 记录 owner（⌥⌘D 可见）；`ClamHooks` 加 bail 语义（N 个 handler 按注册序取首个非 nil） |
| 16 | 合并 sidebar / header 两份 `dsh-source.js` 的重复（`SOURCE_SERVICES`、`canonicalId`、`call()`）成一份共享隔离层 |
| 17 | 长期：ship 预编译 App，插件作者只需 CLT |

### 明确不建议做的

- 把 `WebPolicy` / 右键黑名单挪出壳——那是安全边界。
- 造跨插件共享的 Swift 类型注册表——DSHKit 退役的理由仍然成立。
- 给 `SystemDelegateRelay` 做"零改壳"抽象——每加一个 delegate 两行拍平的成本已经低到不值得抽象。

---

## 附录 A：dsh 参考

- [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)（"Everything is a Plugin"）—
  `docs/architecture.md`、`docs/cordis-primer.md`、`docs/cordis-tutorial/`
- [Cordis Meta-Framework（koishi 文档）](https://deepwiki.com/koishijs/docs/3.1-cordis-meta-framework)
- 本地必读：`~/.dsh/profiles/node_modules/@deepseek-ai/cordis/src/{context,service,registry,fiber,events}.ts`、
  `dsh-app-boot/lib/index.js`（`loadProfile` / `resolveBundleDir` / `PROFILE_TEMPLATES`）、
  `dsh-base/cordis.patch.yml`、`dsh-web-app/cordis.patch.yml`、
  `dsh-client-runtime/lib/types/client/slots.d.ts`（槽系统最完整的一份文档）、
  `dsh-client-ui-settings/lib/types/client/contract/slots.d.ts`（槽契约范本）、
  `dsh-client-ui-layout/lib/client.js`（19KB，可全文读的 root 槽实现）

## 附录 B：散落但高价值、写作者指南时直接搬的段落

- `clam-nativeify/README.md:813-832` —— "读别人的设置 ns"完整配方（只读不注册、非 owner 拿不到 `SettingsScope`）
- `clam-settings/README.md:152-154` —— cordis fork 的 `inject` 无可选形态，嵌套 inject 是唯一表达方式
- `clam-notify/README.md:150-160 / 169-177 / 216-217` —— `ClamHooks` 外推、生命周期锚、裸 `invoke` 帧验插件
- `clam-sidebar/README.md:29-41` —— 跨代保管箱只放系统类型
