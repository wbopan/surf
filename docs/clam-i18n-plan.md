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
