# clam-i18n —— 原生侧语言跟随 dsh（权威计划）

> 状态：**规划中**，一行代码都还没写。动手前先读 §1（上游机制事实）与 §8（坑）。
> 上游事实对着 dsh 0.1.1-rc.2 源码核过（2026-08-28，两个调研子代理逐文件确认）。

## 0. 一句话

本仓库所有面向用户的文案（约 330 处 Swift + clam-notify 的 node 侧通知文案）
双语化（zh / en），语言**完全跟随 dsh 的 `locale` 设置**——不新增任何语言偏好、
不另建语言状态；顺带把现有中文文案按 Apple 简体中文风格**正式化打磨**一遍
（这是用户点名的第二目标：现在的中文口语化，不像原生 App）。

## 0.5 不变量

1. **语言的唯一权威是 dsh 的 `locale.preference`**（`~/.dsh/settings.yaml`）。
   本仓库不注册语言设置项、不把 UserDefaults 当偏好存储（只做缓存，见 §3）。
   设置窗口里那行「语言」早就在编辑这个 ns（`FieldNotes.swift` L59–61），写路径零改动。
2. **原生 UI 的语言 == 页面显示的语言。** 判据取页面侧 `LocaleRuntime` 解析后的
   `active`，因为 `preference` 缺省时的浏览器推导只有它算得准（§1.1）。
   两半永远不许各说各话。
3. **值域跟 dsh：只有 `zh` / `en`。** 不自作主张加语言、加「跟随系统」选项——
   dsh 的「缺省 = 环境推导」本身就是跟随系统。
4. **文案是代码**：每插件一张表（`swift/Strings.swift` / `lib/strings.js`），
   zh 与 en 并排写在同一处；zh 是键集真相（对齐 dsh 约定，§1.2）。
   带插值/复数的条目写成方法，不搞 `{name}` 模板替换。
5. **壳与 ClamSDK 只加通用机制**（locale 类型 + 粘性主题 + 决议链），
   一条具体文案都不进 SDK。
6. **元素定位继续与文案解耦**：AX identifier、`data-slot`、菜单 action selector
   一个都不许换成按文案匹配（CLAUDE.md 已有此纪律，换语言后它从「纪律」变成「正确性」）。

## 1. 上游机制事实清单

真实路径：`/opt/homebrew/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/`
（`~/.dsh/profiles/node_modules/...` 是符号链接场，grep 不加 `-L` 会静默扑空）。

### 1.1 设置本体与决议

- 定义在 `dsh-client-locale/lib/index.js`：ns `"locale"`（L6）、字段 `"preference"`
  （L8）、值域 `["zh","en"]`（L10）、schema `.required(false)` **无 `.default()`**（L12）。
  对比 `ui-theme` 有 `DEFAULT_PREFERENCE="system"`——**locale 的缺省是有语义的**：
  缺省 = 浏览器推导（`navigator.languages` 取 primary subtag，`zh-Hans-CN`→`zh`；
  兜底 `'en'`，`lib/client.js` L1187–1206、L987）。
- 解析后的「当前语言」**只存在于浏览器侧**：`LocaleRuntime`（`lib/client.js`
  L1032–1182），`ctx.provide('locale', …)`。API：`getSnapshot() → { active,
  locales, revision }`、`subscribe(fn)`、`setLocale(id)`、`bind(ns) → t`、
  `register(ns, {zh, en})`。
- node 侧**没有解析器**：只能 `ctx.settings.get(settingsNamespace('locale'))` 拿原始
  `{ preference? }`（可能 undefined），变更走 `ctx.on('settings/updated', (ns, next,
  prev) => …)`。**绝不能重复 `register('locale')`**——ns 单占，重复注册 fails loud，
  且 dsh-client-locale 已占。
- **热切换、不刷新页面**：每个 slot outlet 经 `useSyncExternalStore` 订阅 locale
  revision（`dsh-client-ui-renderer/lib/client.js` L484–487、L744、L853），切换时
  `t` 换新引用穿透 memo。真正切换才 emit cordis 事件 `'locale/change'`（L1175）。
- locale **没有 boot 注入**（theme 有），所以 dsh 页面首帧可能闪一次语言——
  这是上游行为，原生侧用缓存避免同类闪切（§3）。

### 1.2 词典约定与已知限制

- dsh 的翻译资源不是文件，是编进各包 client.js 的平面 `Record<string,string>`，
  激活时 `ctx.locale.register(ns, {zh, en})` 注册；约定 **zh 是键集真相，en 编译期
  核对齐全**（`lib/types/locales/index.d.ts`）。第三方插件可注册（duplicate 即 throw）。
- **schema 的 `.description()` 没有翻译钩子**：注册时定死一种语言，上游 README
  自陈 registry-held text 不追翻。我们的页内 description 同策略（§7）。
- 远程（非 loopback）浏览器的设置镜像是 memory 模式，`set()` 短路——语言切得动
  但不落盘。对我们无影响（壳固定 loopback）。

### 1.3 本仓库既有的「跟随设置」样板

- **client 半边四件套**（照抄即可）：`ctx.inject(["settingsScope"], …)` →
  `bind({ namespace })` → `getSnapshot()`（`status: ready|loading|unavailable`）→
  `subscribe(cb)` 交给 `ctx.effect`，末尾手动 `sync()` 一次。样板：
  `clam-nativeify/lib/client.js` L980–991；**含投影给 Swift 的完整版**：
  `clam-layout/lib/client.js` L239–263（clam-shortcuts 的 keymap 投影，
  `postToShell({type:"keymap", values})`）。
- **node 半边**：`ctx.settings` 宿主服务 + `scope.watch()`（clam-notify 的
  `SETTINGS_NS` 用法，`clam-notify/lib/index.js` L143–176）——但 locale ns
  不许 register，只能 `get` + `settings/updated` 事件（§1.1）。
- **状态型消息 → `ClamEventBus.emitSticky`**（CLAUDE.md 纪律；现有唯一 emit 点
  `MainWindowController.swift` L1023–1024 的 `pageCurrentSession`）。

## 2. 现状盘点（要动的面）

全仓**没有任何本地化设施**（无 `.strings`/`NSLocalizedString`/`.lproj`，
`grep` 零命中）；唯一集中式文案表是 `clam-settings/swift/FieldNotes.swift`。
真正会露给用户的中文约 330 处，按表面：

| 表面 | 位置 | 规模 | 备注 |
|---|---|---|---|
| 壳·菜单栏 | `MainWindowController.setupMenus()` L590–770 | 7 菜单 + ~40 项 | `ShortcutsPanel.collect()` 读菜单 title 生成快捷键面板，文案一改自动跟 |
| 壳·诊断面板正文 | `MainWindowController.diagnosticsText()` L938–996 | 28 行 | 插值密度最高 |
| 壳·引导页/提示条/Toast | `BootstrapViewController` + `MainWindowController` L287–473、`ShellUpdateBanner`、`ShellToast`、`Native/WebPolicy` L267–333 | ~25 | 含 JS 弹窗按钮「好/取消」 |
| clam-sidebar Swift | `SidebarView`（38 处）、`StatusIndicator`、`SidebarFilter`、`SidebarPlugin`（toolbar 贡献）、`AppSidebarModel`（动作名表）、`SidebarShortcuts` | ~45 | 「今天/昨天/前 7 天/更早」在 `SidebarView.swift` L714–721（Swift，不在 node） |
| clam-header Swift | `HeaderPlugin`（四格 label）、`HeaderToolbar`（「N 个子代理」等）、`HeaderFormatting`（时长拼装 L45–67） | ~25 | 时长/复数是最难机械替换的一处 |
| clam-settings Swift | `FieldNotes`（28 条 Note + 7 条 ns 摘要）、`SettingsTabs`、`ModelsPage`（23 处）、`PluginInventoryList`、`SettingsModel` 相位词典、其余散落 | ~90 | FieldNotes 是现成的集中表，双语化最顺 |
| clam-notify node | `lib/inbox.js`（标题/正文/按钮）、`lib/mux-source.js` L225 | ~15 | **唯一写在 JS 里的用户文案**；Swift 侧只有「其他…」「发送」两处 |
| node 错误泄漏路径 | `clam-sidebar/lib/dsh-source.js` 的 `what` 参数 → `push("error")` → `SidebarView` L419 alert；`clam-header/lib/index.js` 同构 | ~10 | 见 §8 第 4 条，要改推结构化 action id |
| dsh 页内 description | `clam-notify`（9 条）、`clam-app`/`clam-shortcuts`（~17 条）、`clam-bridge`（2 条） | ~28 | 到不了原生窗口，只进 dsh 页内设置对话框，§7 处理 |

client.js 注入的文案：**没有**（全是 CSS 规则文本）。node 投影通道里也基本
没有文案——显示词都在 Swift 侧组装，这个分工保持不变。

## 3. 语言的决议链与投影通道

原生侧解析「当前语言」的链条，**逐级降级、上级到达即覆盖**：

1. **页面投影（权威）**：clam-layout 的 client 半边订 `ctx.locale`
   （`inject(["locale"], …)` + `subscribe`，比 settingsScope 高一层——拿到的是
   **解析后的 active**，缺省时的浏览器推导已经算完），
   `postToShell({ type: "locale", locale: active })`，初始一次 + 每次变更。
   页面生命周期天然解决补发（壳重启 = WebView 重载 = 重新投影，与 keymap 同理）。
2. **UserDefaults 缓存**：壳收到投影后写 `clamLocale` 键；冷启动（页面尚未 ready、
   菜单已在建）先用上次已知值，避免「启动是英文、两秒后闪成中文」。缓存不是偏好：
   永远会被 1 覆盖。
3. **系统语言**：首次启动无缓存时取 `Locale.preferredLanguages` primary subtag
   映射 zh/en，否则 en。WKWebView 的 `navigator.languages` 同样来自系统语言，
   所以这一级与页面侧的推导天然一致，不会两半分叉。

壳收到投影后：写缓存 → `ClamEventBus.emitSticky(Topic.locale, ["locale": id])`
（状态型消息，晚装载的插件靠粘性回放拿到）→ 自己重建语言相关表面（§5）。
`handleBridgeMessage` 里给 `locale` 加一个特化分支（壳自己也要用它，
与 `currentSession` 同一待遇）。

**clam-notify 的 node 半边单独走一条**（它的文案在 node，不经过 Swift）：
`ctx.settings.get('locale')` + `ctx.on('settings/updated')` 过滤 `ns === 'locale'`；
`preference` 缺省时用 `Intl.DateTimeFormat().resolvedOptions().locale` 推导——
dsh 进程与壳同机，推出来的就是系统语言，与决议链第 3 级一致。

## 4. ClamSDK 增补（一个文件）

`ClamSDK/ClamLocale.swift`，只有词汇没有文案：

```swift
public enum ClamLocale: String, Sendable {
    case zh, en
    public static func resolve(preferred: [String]) -> ClamLocale  // primary subtag 映射
}
// ClamEventBus.Topic.locale = "clam.locale"（sticky，载荷 ["locale": "zh"|"en"]）

@Observable public final class ClamLocaleStore {
    public private(set) var current: ClamLocale
    public init(bus: ClamEventBus, initial: ClamLocale)  // 自订阅 Topic.locale
}
```

插件在 `activate` 里各自 `ClamLocaleStore(bus: host.events, initial: …)`，
塞进自家 model；SwiftUI 视图读 `model.strings.xxx` 自动建立观察依赖。
**注意**：改 ClamSDK 会让所有插件 contentHash 失效、全量重编（CLAUDE.md），
这是一次性成本，正确且可接受。

## 5. 字符串表的形态与各表面怎么跟着切

**Swift 侧**：每插件一个 `swift/Strings.swift`（壳的放
`clam-app/host/Sources/Strings.swift`），形态：

```swift
struct L {
    var locale: ClamLocale
    var rename: String { locale == .zh ? "重命名…" : "Rename…" }
    func subagents(_ n: Int) -> String {
        locale == .zh ? "\(n) 个子代理" : n == 1 ? "1 subagent" : "\(n) subagents"
    }
}
```

zh/en 并排同一行（审校时一眼对照）；插值/单复数/量词是普通 Swift 代码
（`HeaderFormatting` 的时长拼装照这个路子重写，en 出 "about 2 years 3 months"
这类）；漏写 en 编译不过——**typed struct 就是完备性检查**，不需要 lint。

**node 侧**（仅 clam-notify）：`lib/strings.js` 导出 `strings(locale)`，
`inbox.js` 全部文案改从它取。

各表面的切换机制：

| 表面 | 怎么跟 |
|---|---|
| SwiftUI（sidebar / settings 窗口 / header 弹层） | model 持有 `L(locale:)`，locale 变更时整体替换该属性 → `@Observable` 自动重渲。**不用 `withObservationTracking` 手动观察**（有静默死亡坑，CLAUDE.md） |
| 菜单栏 | 壳订 sticky 主题 → 重跑 `setupMenus()`（要改成可重入：整棵重建再挂回 `NSApp.mainMenu`）。快捷键面板读菜单 title，自动跟 |
| 工具栏贡献 label（header 四格、sidebar「筛选」、layout「新建会话」） | `label` 是拓扑键，各贡献方收到 locale 变更后**重新贡献** metadata → 既有机制整条重建工具栏。切换瞬间闪一下，可接受 |
| 系统通知（clam-notify） | 新通知用新语言；已挂在通知中心的不追改 |
| 诊断面板 / 快捷键面板 / 各种 alert | 打开时现生成，天然新 |
| `window.title/subtitle`、面包屑 | 数据（会话名）不翻；「未命名会话」这类兜底词进表 |

## 6. 文案打磨（与双语化同一次手术做完）

用户点名：现有中文口语化（「出错了」「知道了」「那一套」），不像原生 App。
建表时**不是机械搬运**，逐条按此规范重写：

- **zh**：对照 macOS 系统 App 用词（「设置」「归档」「显示简介」「访达」）；
  菜单项动词开头；省略号用 `…`（U+2026）且仅在「还要再问一步」时用；全角标点；
  不用「您」；描述句直接祈使、不卖萌。
- **en**：菜单与按钮 Title Case（"New Session"、"Hide Others"），描述 Sentence
  case；量词单复数正确；对照系统菜单既有英文（About / Quit / Settings…）。
- **拿不准语气的条目不硬定**：产出一张「原文 → 新 zh → en」三栏审校表
  （放执行日志旁），连同两种语言的截图一起交用户裁决（设计立场第 3 条）。

## 7. dsh 页内表面（`.description()` 与 ns 卡片）

- 各插件 node 侧注册 settings ns 时，description 按**注册时刻**的 node 决议
  locale（§3 末段那条链）选 zh 或 en。运行中切语言不追改——与 dsh 自身
  「registry-held text 不追翻」限制一致，重启 dsh 后对齐。实现：description
  文案也进各插件的 `lib/strings.js`（或内联三目）。
- 不去注册 dsh 的 `settings.plugin.item` 卡片、不接 `ctx.locale.register` 词典
  ——那是把界面伸进 dsh 页内设置对话框，超出本计划范围（原生设置窗口才是我们的
  正门）。留一句：将来要做时样板是 `dsh-client-ui-settings-plugins/lib/client.js`
  L1204–1320。

## 8. 坑（动手前读一遍）

1. **`locale` ns 不许 register**（单占已被 dsh 占用，重复注册 fails loud）；
   node 侧只 `get` + `settings/updated`。
2. **`ShortcutsPanel.displayWidth`（L134–156）按 CJK 宽度对齐**，英文下对齐逻辑
   要跟着改（等宽假设不成立时改用两列布局或 `NSGridView`，实现者定）。
3. **SwiftUI 隐式 `LocalizedStringKey` 歧义坑**：中文字面量在 `TableColumn(value:)`
   等重载点会歧义（`clam-settings/README.md` L69–71 记过案）。改成从 `L` 取值后
   全是 `String` 变量，歧义反而消失——但改动时别顺手把字面量写回去。
4. **node 错误消息泄漏路径要断根**：`call(domain, method, payload, what)` 的中文
   `what` 拼进错误消息推到 Swift alert。改为 push 结构化
   `{ action, message }`（action 是 id），Swift 用自家表组「X 失败：原因」——
   `AppSidebarModel` L65–70 那张动作名表就是现成落点。
5. **别用 `withObservationTracking` 手拉观察**（观察者没人强持有就静默死，且只在
   冷启动露馅——CLAUDE.md 记过案）；一律走 model 属性 + SwiftUI 自动观察。
6. **菜单重建的可重入性**：`setupMenus()` 现在假设只跑一次；重建时注意
   ⌘1–9 动态项、`ShortcutsPanel` 的引用、以及正在打开的菜单（重建延到菜单关闭）。
7. **工具栏 label 变更 = 拓扑变更**，整条重建、丢显示模式外的瞬态；已知且可接受，
   别试图绕过拓扑键去原地改 label。
8. **验收必须截图**，不能看代码——本仓库多条「设了没反应、不报错」的先例
   （CLAUDE.md 踩坑记录），语言切换涉及三种表面（AppKit / SwiftUI / 通知）。

## 9. 里程碑

每个里程碑独立可交付、可并行（i2–i5 互不依赖，适合分头实现）；
完成一个在 §10 追加一行执行日志。

| # | 内容 | 验收 |
|---|---|---|
| i0 | **管线**：SDK `ClamLocale` + sticky 主题；clam-layout client 投影 `locale`；壳特化分支 + UserDefaults 缓存 + 决议链；clam-notify node 侧决议助手 | dsh 设置里切语言，壳日志/诊断面板里看到 sticky 事件与新值；冷启动用缓存值 |
| i1 | **壳**：`Strings.swift` + 菜单可重入重建 + 引导页/提示条/Toast/WebPolicy 弹窗/诊断面板/快捷键面板（含对齐修理） | 两种语言截图：菜单栏、⌘/ 面板、引导页 |
| i2 | **clam-sidebar**：全部 Swift 文案进表 + toolbar 贡献重注册 + 断根 node 错误泄漏（坑 4） | 两种语言截图：侧边栏、右键菜单、空态、alert |
| i3 | **clam-header**：四格 label + 弹层 + `HeaderFormatting` 时长重写 | 两种语言截图：工具栏、子代理 catalog、任务菜单 |
| i4 | **clam-settings**：`FieldNotes` 双语化（Note 表加 en 列）+ 各 Page 散落文案 + 相位词典 | 两种语言截图：设置窗口四栏 |
| i5 | **clam-notify**：`lib/strings.js` + inbox 文案 + Swift 侧两处 + description 按注册时 locale（§7 推广到 clam-app/clam-bridge） | 两种语言各发一轮四类通知截图 |
| i6 | **收尾**：全仓 grep 中文字面量清查（区分注释/日志/UI）；文案审校表 + 全表面双语截图集，交用户裁决语气拿不准的条目 | 审校表 + 截图集 |

## 10. 执行日志

（每完成一个里程碑追加一行：日期、里程碑、结果、偏离计划之处。）

- **2026-08-28 · i0（管线基建）· 完成。** 新增 `ClamSDK/ClamLocale.swift`
  （`ClamLocale` + `ClamLocaleStore`）、`ClamEventBus.Topic.locale = "clam.locale"`；
  `clam-layout/lib/client.js` 加 `ctx.inject(["locale"])` 投影
  （`postToShell({type:"locale", locale: active})`，同值不重推）；
  `MainWindowController` 加 `locale` 特化分支 + `clamLocale` 缓存 + 冷启动决议
  （`init` 第一句就 `emitSticky`，早于建菜单与装插件）；新增
  `clam-notify/lib/locale.js`（`createLocaleSource`，只 `get` + 听
  `settings/updated`，不 register），已在 `lib/index.js` 接上并持有，暂不消费。
  壳 `xcodebuild` Debug BUILD SUCCEEDED，`ClamLocale` 已出现在
  `build-sdk/ClamSDK.swiftinterface`；`node --check` 三个改动文件通过，
  `node --test clam-sidebar/test/*.test.js` 18/18 绿。
  **偏离计划三处**：
  ① `ClamLocale.resolve` 按 **dsh 的 `detectBrowserLocale()` 原样复刻**——
  第一条命中**任一**已支持语言的标签赢（`en` 也算命中），而不是「只认 `zh`、
  其余往后找」。差别只在 `["en","zh"]` 这类序列上，但不变量 2（两半永远不许
  各说各话）要求两边规则逐字一致，所以以上游为准。
  ② 顺手在诊断面板加了一行「界面语言：<id>（来源）」——i0 的验收判据要求
  「壳日志/诊断面板里看到 sticky 事件与新值」，这行是那个判据的落点，
  不是文案翻译。
  ③ clam-notify 启动时用 `log.info` 打一行当前语言（stderr），
  同样是为了让 i0 在终端可验。
- **2026-08-28 · i1（壳文案双语化）· 完成。** 新增
  `clam-app/host/Sources/Strings.swift`（`struct L`，95 条：77 个属性 + 18 个带
  插值的方法），壳的菜单栏 / 引导页 / 提示条 / 浮条 / WebPolicy 弹窗与下载 /
  诊断面板 / 快捷键面板全部改从它取；日志与 wire 载荷仍是中文，一条没动。
  壳持有 `strings`（`L(activeLocale)` 现算，不存快照），语言变更时
  `rebuildLocalizedSurfaces()` 重建：主菜单整棵新建、提示条重画当前态、
  两个面板换 chrome 并重采、引导页照当前"幕"重画。
  **菜单可重入**：新增 `rebuildMenus()` 作为唯一入口 + `observeMenuTracking()`
  盯 `NSMenu.did{Begin,End}TrackingNotification`（只认根菜单是 `NSApp.mainMenu`
  的那些），菜单正张着就记账、`didEndTracking` 后延一拍补做；换键位那条路
  也改走它。菜单 action/selector、AX 一个没动。
  **文案同时按 Apple 简中风格打磨**，改动较大的在 `Strings.swift` 行尾以
  `// 原：…` 标出（共 12 条），供 i6 汇总审校表。
  壳 `xcodebuild` Debug **BUILD SUCCEEDED**，无新增警告；
  `Sources/` 里除注释、日志与 `Strings.swift` 外已无中文字符串字面量（grep 核过）。
  **偏离计划三处**：
  ① §8-2 的 `ShortcutsPanel.displayWidth`（CJK 补空格对齐）**整块删掉**，
  改成 `NSAttributedString` + 按节实测最长标题定 `NSTextTab` 制表位——
  等宽假设在英文下本就不成立，而制表位让布局引擎按真实字形对齐，两种语言
  都齐整；拷出去仍是 `标题\t快捷键`。
  ② `ClamEndpoint.summary` 去掉了"⚠️ 不是本 worktree 那一套"与全角括号，
  变成纯技术标识（`url (profile x, pid 1)`）：那句警告是文案，进了
  `L.diagEndpointNotOwn`，日志那一侧由调用方自己拼中文。
  ③ `BootstrapViewController` 的两个按钮标题（拷贝/重试）改由调用方每次递入，
  `MainWindowController` 新增 `BootstrapPhase` 记"在演哪一幕"而不是记文案
  ——这是"语言变更后能照原样重画"的最小代价，顺带把 `guideShown` 变成计算属性。
- **2026-08-28 · i2（clam-sidebar 文案双语化）· 完成。** 新增
  `clam-sidebar/swift/Strings.swift`（`struct L`，47 条：41 个属性 + 6 个方法，
  其中 `timeBucket` / `actionName` / `failureReason` 三个方法各自收着一小张表，
  实际串数约 60）。侧边栏 Swift 半边的会话行 / 分组头 / 右键菜单 / 搜索框 /
  筛选胶囊 / 时间分段 / 状态 AX label / 三个 alert / NSOpenPanel / 空态 /
  工具栏「筛选」菜单全部改从它取；`host.log` 的中文一条没动。
  插件 `activate` 里建 `ClamLocaleStore(bus: host.events)`，一份实例同时给
  `AppSidebarModel`（投影里的「未分组」「新会话」兜底）与 `SidebarView`
  （body 读 `L(locale.current)`，`@Observable` 自动重渲，没有
  `withObservationTracking`）。工具栏那条贡献不在 SwiftUI 里，另订一次
  `clam.locale` 后**重新贡献**同一个 `(owner, id)`（label 是拓扑键，就地覆盖 +
  整条重建，位置不变）。
  **断根 node 错误泄漏（§8-4）**：`dsh-source.js` 的 `call()` 去掉 `what` 参数，
  只抛上游原话；自己认领得了的失败改抛新增的 `SourceError(code, …)`
  （`apiMissing` / `forkNoChild`），`lib/index.js` 的两处 `push("error")` 统一成
  `{action, code?, message}`，Swift 用 `L.actionFailed` + `L.failureReason`
  组「归档会话失败：X」/「Failed to archive the session: X」。
  桥 `SCHEMA_VERSION` 4 → 5。日志（node 的 `log.warn`、Swift 的 `host.log`）
  仍是中文，失败那行显式取 `L(.zh)`。
  文案同时按 Apple 简中风格打磨，改动较大的 9 条在表里以 `// 原：…` 标出。
  验证：`swiftc` 按壳 `CompilerService` 的参数形状**全量编出 dylib**
  （`-emit-library`，ClamSDK + ClamLayout 世代 module 都接上）**成功、无新增警告**
  （`SidebarFilter.swift` 那条 actor-isolated 警告在 HEAD 上就有，已对照确认）；
  `node --check` 三个改动 JS 通过，`node --test clam-sidebar/test/*.test.js` 18/18 绿
  （改了一条断言：上游错误不再带中文前缀）。
  **偏离计划三处**：
  ① 计划说"塞进现有 @Observable model"，但 `AppSidebarModel` 是 Combine 的
  `ObservableObject`，而 `SidebarModel` 是 **public** 协议、`L` 是 internal 类型
  ——往协议里加 `var strings: L` 过不了访问控制。改成把 `ClamLocaleStore`
  同时传给 model 与视图（视图多一个 `let locale`），观察语义一模一样。
  ② `error` 帧比计划多一个可选的 `code`：计划只写了 `{action, message}`，
  但"数据面尚未就绪"这类**我们自己合成**的失败没有上游原话可转，光留 message
  等于换个地方泄漏中文。`code` 是稳定 id，Swift 查表出文案，认不出就退回 message。
  ③ 顺手把「按时间」分段的 id 从中文段名换成 `TimeBuckets.Bucket` 枚举
  （`today` / `yesterday` / `lastSevenDays` / `earlier`）：它当着
  `Identifiable.id`，中文串会随语言变。AX identifier 一个都没动（`sidebar.group.*`
  取的是 workspaceId，与分段无关），但**本 worktree 没有在跑的实例，没能 dump 一次
  AX 复核分组头的 `.accessibilityElement(children: .ignore)` 收口，留待 i6 截图验收**。
- **2026-08-28 · i3（clam-header 文案双语化）· 完成。** 新增
  `clam-header/swift/Strings.swift`（`struct L`，20 条：9 个属性 + 11 个方法，
  其中 4 个是时长拼装、2 个各带一小张二选一表，实际串数约 24）。四格工具栏 label /
  窗口标识（标题兜底词 + 后台任务副标题）/ 会话谱系菜单（祖先段、子代理项、
  次要行、空态、tooltip）/ 模式菜单（当前 preset、不可用标注、「默认」）全部改从
  它取；`host.log` 与 node 日志的中文一条没动。
  **两条路各走各的，正是「拓扑与流量分家」的直接推论**：四格的 `label` 是拓扑键，
  由 `HeaderPlugin` 订 `clam.locale` 后**重新贡献**同一组 `(owner, id)`（照 i2 的
  写法，四个撤销句柄存在闭包捕获的 `var contributions` 里而不是 `kept(by: handle)`，
  避开那条"订阅与 handle 互相按住、旧世代退不了休"的环；`contribute` 顺带改成
  `static` 并返回句柄）；菜单内容 / tooltip / 副标题是流量，走既有的
  `clam.toolbar.update`——`HeaderToolbarSync.push()` 第一句改读 `model.strings`
  （`HeaderModel` 新增 `locale: ClamLocaleStore` 与**现算不存快照**的 `strings`），
  于是语言变更对那圈**既有的** `withObservationTracking` 就是一次普通的 model 变化，
  **本里程碑没有新增任何观察者**。
  **`HeaderFormatting.duration` 整段重写**：分档算术留在原地（上游阈值一条没改），
  带单位的措辞全部交给 `L`——zh「约 2 年 3 个月」「5 天 4 小时」「30 秒」，
  en "about 2 years 3 months" / "5 days 4 hours" / "30 seconds"，单复数由一个
  `count(_:zh:one:many:)` helper 统一处理。中间两档是纯数字钟面（`3:04:05`），
  不过 `L`。
  **node 错误路径**按 i2 的协议同步：`dsh-source.js` 的 `call()` 去掉 `what` 参数、
  只抛上游原话，新增同形状的 `SourceError(code)`（`apiMissing`）；`index.js` 的
  两处 `push("error")` 统一成 `{action, code?, message}`，桥 `SCHEMA_VERSION` 2 → 3。
  header 的 Swift 侧**只把错误写进日志、不弹界面**（换 preset 失败时下一份投影会把
  选中态纠回去），所以那一侧不查表，只把 `code` 一并记上。
  验证：`swiftc` 按壳 `CompilerService` 的参数形状**全量编出 dylib**
  （`-emit-library`，ClamSDK + 现编的 ClamLayout module 都接上）**成功、无警告**
  （改动前跑过同一条命令做对照）；`node --check` 三个 JS 通过；
  `node --test clam-sidebar/test/*.test.js` 18/18 绿；`clam-header/` 除注释、
  日志与 `Strings.swift` 外已无中文字符串字面量（grep 核过）。
  **偏离计划三处**：
  ① **段控开局那两个名字（`Chat` / `Trajectory`）不进表**，原样留在贡献 metadata 里
  并加注说明：它们只是"页面还没报过"那一瞬的占位，真名单是 `model.tabs`——dsh 的
  ui-conversation 按它自己的 locale 给的字（zh 下 `view.chat` = 「对话」）。
  翻了反而会造出"原生写「对话」、页面写 Chat"的分叉。
  ② **从 `subagentsPatch` 里删掉了 `"label"`**。那一格的 label 是常量，却一直经活通道
  推——而 `ToolbarItemState.label` 是**永久覆盖**，一旦被推过一次，metadata 那份就
  再也说了不算，重新贡献会静默哑火。分界混着的时候看不出问题，i3 要用重新贡献才
  暴露。`mode` 那格的 label 留着（它真的是当前 preset 名，属于流量）。
  ③ **`HeaderFormatting` 的英文措辞不再逐字复刻上游**：上游词典给的是密排指标里的
  缩写（`~2y 3mo` / `5d 4h` / `30s`），而我们这几个数字长在 AppKit 菜单项的次要行上，
  读的是句子。**数字与分档仍然逐字一致**，只是措辞按计划 §5 的要求展开成完整词。
  （zh 那侧本来就已经与上游有空格差异。）另：`一次性` / `可继续` / `子代理` /
  `个后台任务` 这些词与 dsh 词典逐字对齐，en 侧则把上游的小写改成菜单该有的
  首字母大写。打磨改动较大的 3 条在表里以 `// 原：…` 标出——其中
  「未命名会话 → 新会话」是**与 clam-sidebar 对齐**（同一个会话既是侧边栏一行、
  又是窗口标题，两处叫法不同就是明摆着的自相矛盾）。
- **2026-08-28 · i4（clam-settings 文案双语化）· 完成。** 新增
  `clam-settings/swift/Strings.swift`：`struct L` **85 条**（68 个属性 + 17 个方法，
  其中 `tabTitle` / `pluginPhase` / `providerStatus` / `failureMessage` 各自收着一小张表），
  外加一个 `struct LocalizedText`（zh/en 一对，构造器必须给两个参数）。
  四栏标签 / 窗口标题 / 四个页面的空态与提示条 / 模型页整套（凭据栏、添加 sheet、
  状态点 tooltip、引用名）/ 插件列表（表头、搜索框、计数行、相位词典）/ 预设页 /
  七种字段编辑器 / 值摘要 / 约束提示全部改从它取；`host.log` 与 `ctx.logger`
  的中文一条没动。
  **`FieldNotes` 是改造不是推倒**：`Note` 的 title/hint/unit/options 从 `String`
  换成 `LocalizedText`，表体照原样保留，28 条字段注解 + 7 条 ns 注解 + 全部枚举值
  一共 65 对 zh/en。**为什么这里是"两种都存"而不是像 `L` 那样现算**：这张表是
  `static let`，被读到之前就已经存在，那时还不知道语言。写法上用隐式
  `.init("中文", "English")`（参数类型已知），漏写 en 编译不过；两种语言写法真的
  相同的（`中文` / `English` / `API key` / `px`）用显式的 `.same(_:)` 声明"不该翻"，
  而不是把同一个串抄两遍。`SettingsFormat.humanize` 兜底路径**两种语言共用一份**，
  就地加注说明：它出的本来就不是"中文文案的英文版"，而是真 key 拆出来的机械美化，
  zh 界面下露出它反而比编一个中文名更好查（README「字段文案从哪来」的原话）。
  **locale 接线**：`SettingsModel` 持 `ClamLocaleStore`，`strings` / `locale` 两个
  **现算不存快照**的计算属性；视图 body 里读它就建立观察依赖，换语言整扇窗自动重渲
  ——**没有新增任何观察者**。`SettingsPlugin` 在 `activate` 里建那个 store 交给 model
  （model 被窗口按着 = 生命周期锚），跨世代收口那套 `host.objects` 一个字没动。
  验证：`swiftc` 按壳 `CompilerService` 的参数形状**全量编出 dylib**
  （`-emit-library`，只接 ClamSDK——clam-settings 不声明 swiftDeps/sharedModules）
  **成功、无警告**（改动前跑过同一条命令做对照，基线也是零警告）；
  `node --check` 两个改动 JS 通过；`node --test clam-sidebar/test/*.test.js` 18/18 绿；
  `clam-settings/` 除注释、日志、`Strings.swift`、`FieldNotes.swift` 外已无中文
  字符串字面量（grep 核过）。
  **偏离计划四处**：
  ① **窗框那半边另走一条**：`.preference` 工具栏那四个标签与窗口标题由 AppKit 拿着，
  SwiftUI 观察不到，所以 `SettingsPlugin` 另订一次 `clam.locale`，回调里
  `SettingsWindowController.relocalize(_:)` 重贴标签、controller title、符号 AX 描述
  与窗口标题。那个方法**从事件载荷取 locale 而不是读 model**：总线的订阅者存在
  `[UUID: handler]` 字典里、回调顺序未定义，`ClamLocaleStore` 也是个订阅者，
  它可能排在后面——读 model 会让窗框永远慢一次切换，而且不报错。
  ② **插件列表多了一层显示投影 `InventoryRow`**（`PluginInventoryList` 内）。
  状态那一列的排序键就是它的显示文案（README 记过的 `TableColumn` 重载坑），
  而 `KeyPathComparator` 只能指到**存储**属性上；文案一旦跟着语言走，就不能再是
  `InventoryEntry` 上的计算属性。于是把 `statusText` / `phaseLabel` 从那个 struct
  搬进 `L`，在视图里就地算一次落成一行数据。顺带：表头改从 `L` 取（`String` 变量）
  之后，那个 `LocalizedStringKey` 重载歧义本身就消失了。
  ③ **node 半边其实有三处用户文案**（任务书说没有，实测有）：`index.js` 的
  `errorText` 兜底「未知错误」、`models.js` 两处 `throw new Error("凭据服务不在场")`
  ——它们经 ack 的 `error` 直接显示在字段行上。按 i2 的断根办法处理：`errorText`
  只转上游原话、说不出就给 `null`；自己认领的那条改抛带 `code`
  （`CREDENTIALS_UNAVAILABLE`）的错，`setCredential` / `unsetCredential` /
  `documentPath` 三处 ack 一并回执 `code`。Swift 侧新增 `L.failureMessage`
  （**先查 code、再用上游原话、最后兜底**）。`SettingsBridge` 的超时回执同样改成
  只报 `code: "TIMEOUT"`、不带文案。
  ④ `SourceListFooter` 的两段 AX 描述（`添加` / `移除`）**改成必填参数、并挪进
  `updateNSView`**：AX 描述也是用户"看得见"的字，而 `makeNSView` 一个视图只跑一次
  ——留在那儿的话换语言之后旁白还念旧词，且不报错。
  打磨改动较大的 **18 条**以 `// 原：…` 标出（17 条在 `Strings.swift` 里，
  另一条是 `Banner` 那个"关掉提示"的按钮，标在调用点上）（`知道了 → 好`、
  `改不动/填不了 → 无法修改/暂时不可用`、`在 Finder 中显示 → 在访达中显示` 等），
  供 i6 汇总审校表。**「语言」那一行的选项不翻**（`中文` / `English`），
  就地留注说明：照 dsh 的 `LOCALES`，语言选择器列别人的语言时用那门语言的自述名。
- **2026-08-28 · i5（clam-notify 文案 + 页内 description）· 完成。** 新增
  `clam-notify/lib/strings.js`（`strings(locale)`，**16 个键**：14 条串 + 2 个带插值
  的函数，zh/en 两张表共 32 串）。通知的按钮 / 标题 / 正文 / 输入框占位与提交按钮
  全部改从它取；`mux-source.js` 那句「未知错误」**整个删掉**——它现在只转上游原话，
  说不出话就给空串，兜底句由 `inbox.js` 用当前语言补（与 i2 断根 `what` 参数同一条
  纪律：wire 层不组用户文案）。`log.*` 的中文一条没动。
  **每条 item 记下自己的语言**（`item.locale`，组它那一刻定死）：语言变了
  **不重组已有的行**（计划 §5——改文案 = 撤下重发 = 再响一次），
  `refresh()` 重算按钮时按**那一行自己的语言**，不会出现「标题中文、按钮英文」。
  **Swift 侧两处按"让 node 带下来"处理**（任务书优先项）：
  `NotifyTextInput` 加一个 `label` 字段（就是那颗「其他…」按钮的名字），
  `NotifyCenter.makeCategory` 改用 `input.label`；`decode` 里 `button` 的
  `?? "发送"` 兜底一并删掉——`label` / `button` 缺一个就整条 textInput 不解，
  其余按钮照画。桥 `SCHEMA_VERSION` 1 → 2。
  **页内 description 推广到三个包**（§7，共 27 对 zh/en）：clam-notify 9、
  clam-app 的 `Config` 6 + `clam-shortcuts` ns 10、clam-bridge 2，一律行内三目
  （`zh ? … : …`），与各文件现状最贴。共用的只有**纯函数**：新增
  `clam-bridge/lib/locale.js`（`LOCALES` / `FALLBACK` / `localeFromTag` /
  `environmentLocale`），`clam-notify/lib/locale.js` 改成 import 它、只留
  `createLocaleSource`。**放在 clam-bridge 而不是 clam-notify**：本仓库 clam-* 的
  相对 import 箭头全指向 clam-bridge，反过来会把"缺席即无通知"的可选插件变成
  特权插件的硬依赖。接线各家自己写（clam-app 里 12 行的 `resolveLocale(scoped)`）。
  验证：`node --check` 八个 JS 全过；`strings.js` 的键集自校验用一份删掉 `send`
  的副本跑了一遍，确实在 `import` 时 throw（`文案表 en 与 zh 对不上：缺 send`）；
  三个包的模块级求值真 import 过一轮（Config 的 en description 打出来核对）；
  拿假 locale 源跑了一轮 inbox（四类通知 zh → 切 en → `refresh()`，行为如上）；
  `swiftc` 按壳 `CompilerService` 的参数形状全量编出 dylib（ClamSDK + 现编的
  ClamLayout 都接上）**成功**，警告数与 HEAD 基线逐条相同（`NotifyCenter.swift:60`
  那条 actor-isolated 警告改动前就有）；`node --test clam-sidebar/test/*.test.js`
  18/18 绿；`clam-notify/` 与三处 description 里已无残留单语中文（注释/日志除外）。
  **偏离计划三处**：
  ① **模块级 `Config` 的 description 只到得了决议链的第二级**（环境推导）。
  clam-app 与 clam-bridge 的 `Config` 是模块级常量，cordis 实例化插件时就要读它，
  那一刻没有任何 ctx，`ctx.settings.get("locale")` 无从谈起。`clam-shortcuts` /
  `clam-notify` 两个 ns 在 `apply` 里注册，够得着 ctx，走完整决议链。
  只有"系统语言 ≠ dsh 的 locale 设置"时两者才会差一门语言，而它们长在页内设置
  对话框的不同卡片上；对照上游"registry-held text 一门语言都不翻"，这已经更进一步。
  ② **description 不进 `strings.js`**（计划 §7 说"或内联三目"，取了后者）：
  那张表是"通知文案"，有一道键集自校验闸；description 是三个包各自的东西，
  搬进去反而要为 clam-app / clam-bridge 各造一张表。三个包因此写法一致。
  ③ **`inbox.js` 多了一个 `item.locale` 字段**（计划没提）。理由见上：
  没有它，"语言变了 + 设置也变了"会拼出半个语言的通知。它也随 item 上桥，
  Swift 不读——`signatureOf` 不含它，不会造成重发。
