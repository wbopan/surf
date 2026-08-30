# P0 解耦执行计划（2026-08-29）

来源：`docs/archive/architecture-coupling-audit.md` §6 的 P0 档。这一批的共同特征是**不动 ClamSDK 任何 public 声明**
——不触发全量重编，不需要 ABI 版本变化；每一项都能单独回退。

## 0. 不变量（每个执行者必读）

1. **不改 `clam-app/host/Sources/ClamSDK/` 下任何 public 声明。** 需要新词汇一律放在插件自己的 module
   里（如 `ClamLayout`）或壳自己的文件里。
2. **用户可见行为不变**：现有菜单项、默认快捷键、⌘/ 面板内容、设置页 `clam-shortcuts` 的条目、
   工具栏「筛选」贡献、`?clam-native-sidebar=1` 门控——改完之后从用户角度看不出差别。
3. **插件缺席时优雅降级**：clam-sidebar 不在 → 会话导航菜单项不出现（而不是灰掉或报错）；
   clam-layout 不在 → 壳不带门控参数、退回全出血 WebView。
4. **壳源码里不再出现任何具体插件的命令名 / 槽名（`root` 除外）/ dsh 私有参数名。**
   验收方式：`grep -n "newSession\|openSettings\|archiveSession\|focusSearch\|clam-native-sidebar\|\"sidebar\"" clam-app/host/Sources/` 应为空。
5. 只用 `Edit` 改既有文件，不整文件重写；不碰自己文件清单之外的文件；不 push；不改 `surfclam/cordis.patch.yml`。
6. 中文注释风格照旧：写"为什么"和"失败长什么样"，不写"做了什么"。

## 1. 分波与文件归属

同一波内的执行者文件集合互斥，可并行；跨波串行。

### Wave 1

**A. 命令注册表（审计 P0 #1）+ sidebar 门控改粘性事件（P0 #3）**

设计：**声明在 node 半边，一处真相，流向两个消费方。**

```
插件 node 半边 createSwiftPlugin({ commands: [...] })
      │ 登记进 clamBridge 的 registry（新字段）
      ├──→ 桥 snapshot（新字段）──→ 壳：建菜单 + 默认键位 + ⌘/ 面板
      └──→ clam-app node 半边：动态拼 clam-shortcuts settings schema
插件 swift 半边照旧订 menuCommand 主题应答（一行不用改）
```

`commands` 每条的形状（定稿，写进 `docs/extend/contracts.md`）：

```js
{
  id: "archiveSession",                  // 命令名 = menuCommand 载荷，本插件内唯一
  menu: "file",                          // app | file | edit | view | window | help | 任意自定义 id
  menuLabel: { zh: "会话", en: "Session" }, // 仅自定义 menu 需要；首个声明者定标题
  label: { zh: "归档会话", en: "Archive Session" },
  order: 20,                             // 同 menu 内排序
  separatorBefore: false,
  key: "cmd+shift+a",                    // 默认键位，KeymapSpec 认的语法；可省略 = 无默认键
  configurable: true,                    // 是否进 clam-shortcuts 设置页
  description: { zh: "…", en: "…" },     // 设置页用；可省略 = 用 label
}
```

`⌘1-9` 这种"一族"命令：允许 `keys: ["cmd+1", …]` + `arg` 或用现有 `session1..9` 逐条声明——由执行者按现有
`Keymap.defaultSpecs` 的形态选最小改动的那种，但**不能**让壳出现 `session` 字样。

要点与已知风险：
- 壳的 `setupMenus()` 拆成"系统惯例段（App / Edit / View 缩放 / Window / Help / ⌘/ 面板，硬编码）+ 贡献遍历段"。
  未知 `menu` id 造顶级菜单，标题取首个声明者的 `menuLabel`。菜单在桥 snapshot 变化时 `rebuildMenus()`（已有幂等入口）。
- `Strings.swift:62-96` 那八条业务文案删掉；`Keymap.defaultSpecs` / `menuCommands` / `configurable` 三个编译期常量改为从 snapshot 现采。
- ⌘/ 面板 `ShortcutsPanel.swift:147` 手工补的 `stopGenerating` 那条，改成由 clam-layout 用同一套 `commands` 声明
  （它是 client 半边实现的页内快捷键，声明时标 `menu: null` / `key: "esc"`、`configurable: false`，面板照列，菜单不放）。
- **clam-app 动态拼 schema 的时序**：clam-app 挂载时其它插件未必已登记。先查 `ctx.settings.register` 能否重复注册 /
  在 `ctx.effect` 里撤销重注册；不能的话用"登记表静默 300ms 后注册一次"（照 clam-sidebar 的去抖模式），并在注释里写明。
  用户已保存的键位覆盖值不能丢。
- 键位真相仍然是 `clam-shortcuts` 设置 → clam-layout client 半边 `clam.page.keymap` → 壳，这条链不动。
- `#3`：删掉 `MainWindowController.swift:406-411` / `:452-470` 对 `"sidebar"` 槽与 `clam-native-sidebar` 的判断，
  改为订阅粘性主题 `clam.web.query`（载荷 `[String: String]`，壳侧常量写在 `MainWindowController` 顶注词汇表里），
  按载荷拼 URL query；不一致才 reload。clam-layout 在 `sidebar` 槽被占/释放时 `emitSticky` 这条（它是 `sidebar` 槽的消费方，
  知道自己的页面需要什么参数）。

文件归属：`clam-app/host/Sources/{MainWindowController,Strings,KeymapSpec,ShortcutsPanel}.swift`、
`clam-app/host/Sources/Native/{NativePluginHost,BridgeClient}.swift`（读 snapshot 新字段）、`clam-app/lib/index.js`、
`clam-bridge/lib/plugin.js`、`clam-bridge/lib/index.js`（**只加** `commands` 字段的登记与 snapshot 透传，别的不动）、
`clam-layout/lib/index.js`、`clam-layout/swift/LayoutPlugin.swift`、`clam-sidebar/lib/index.js`、
`clam-sidebar/swift/SidebarShortcuts.swift`、`clam-settings/lib/index.js`、`clam-settings/swift/SettingsPlugin.swift`。

**B. toolbar metadata 代码化 + 槽名常量（P0 #5）**

- 新建 `clam-layout/swift/LayoutContracts.swift`（或并入现有文件）：`public enum LayoutSlots { static let sidebar = "sidebar" }`
  与 `public struct ToolbarSpec`（12 个键各一个有类型的属性 + `func metadata() -> [String: Any]`），
  `LayoutSplitController.swift:472-540` 那段注释改为指向它、只保留"为什么是字典"的理由。
- `LayoutSplitController.swift:168/640` 的 `"sidebar"` 字面量 → `LayoutSlots.sidebar`；`SidebarPlugin.swift:109` 同。
- `SidebarPlugin.swift:145-151`、`HeaderPlugin.swift:349-358` 的字面量字典 → `ToolbarSpec(...).metadata()`；
  `HeaderPlugin.swift:50` 的 `"toolbar"` → `LayoutToolbar.slot`。
- 消费方（`ToolbarContribution.swift`）**仍然读字典**——SDK 容器中立不变。
- 不碰 `LayoutPlugin.swift`（A 在改它）。

文件归属：`clam-layout/swift/{LayoutContracts,LayoutSplitController,ToolbarContribution}.swift`、
`clam-sidebar/swift/SidebarPlugin.swift`、原生 header 插件的 `swift/{HeaderPlugin,HeaderToolbar}.swift`。

### Wave 2

**C. 外部包 fail-loud（P0 #2）+ 删 request 通道（P0 #4 的前半）**

- `clam-bridge/lib/index.js` `register()`：`moduleName()` 结果必须匹配 `/^[A-Za-z_][A-Za-z0-9_]*$/`，否则抛
  （消息里说"插件名用 kebab-case、不要用 scoped 包名做 name"）；`swiftDir` 不存在或没有 `.swift` 文件 → 抛；
  重复登记同名 → 抛（不再只 warn）。
- `clam-bridge/package.json` exports 加 `"./locale": "./lib/locale.js"`；clam-app / clam-notify 的相对路径 import 保持
  （本仓库内的既定做法），只是出口要存在。
- `surfclam/bin/surfclam.js`：`ensureXcodegen` 在 registry 模式也跑——目标目录改为"装进 profile 的 clam-app 包目录"
  （`installInto` 之后能算出来），PATH 分支已现成；两处都没有就打印 `brew install xcodegen` 的提示并继续。
- `ToolbarContribution.swift:60-70` 的 `clam.window.requestTitle` / `requestTitlebarMetrics` 两条 request 通道删除，
  `clam.window.title` 与 `titlebarMetrics` 改 `emitSticky`；删 `:421` 的订阅、`HeaderPlugin.swift:307`、`HeaderToolbar.swift:65`
  对应的 request 逻辑。**`bridge.app` 保留不动**（它是壳的自更新通道，clam-app 本质是壳的 node 半身，审计判为可接受）。

文件归属：`clam-bridge/lib/index.js`（Wave 1 已合入，可以动全文）、`clam-bridge/package.json`、`surfclam/bin/surfclam.js`、
`clam-layout/swift/ToolbarContribution.swift`、原生 header 插件的 `swift/{HeaderPlugin,HeaderToolbar}.swift`、`clam-layout/swift/LayoutSplitController.swift`（若 title 发布点在这里）。

**D. 文档（P0 #6）**

- 新建 `docs/extend/plugin-author-guide.md`：三种最小骨架（纯 node / 带 Swift / 带 client）、package.json 字段表
  （`exports`、`files` 含 `swift`、peerDependencies 纪律、`dsh.client`）、`name` 命名规则（kebab-case → module 名）、
  `@wenbo/clam-bridge/plugin` 包名 import、profile patch 里 insert 一行、`dsh plugin add link:` 外部热循环、
  `activate` 返回值必须是持有链的根、跨代保管箱只放系统类型、只读别人的设置 ns 的配方。素材位置见审计附录 B。
- 新建 `docs/extend/contracts.md`：`commands` 声明形状（Wave 1 定稿）、toolbar `ToolbarSpec` 各键、`ClamEventBus` 主题表
  （含 `clam.web.query`、粘性与否、发布方/订阅方）、`ClamObjects` 键表、hook 名表、`clam.toolbar.update` 活通道。
  源码里对应的注释改成一句"约定见 docs/extend/contracts.md"，不再各自维护一份长注释。
- 修审计 §5.4 那张过时表里的每一项（各 README、CLAUDE.md、`ClamHooks.swift:99` 那句假话）。
  CLAUDE.md 里 clam-layout 那段"连自家新建会话也是一条普通贡献"改成事实；`macOS 26+` → `27`；
  原生 header 插件的 README 顶部加"已停用"；`clam-app/README.md` 的目录表与配置表补全。
- 审计文档 `docs/archive/architecture-coupling-audit.md` 末尾加"§7 执行日志"，记 P0 各项的落地 commit。

文件归属：`docs/**`、各 `README.md`、`CLAUDE.md`、`clam-app/host/Sources/ClamSDK/ClamHooks.swift`（**只改注释**）。

### Wave 3：集成验证

在本 worktree 跑 `./dev`（profile `surfclam-arch-coupling-audit`，端口 OS 挑），等壳起来后：
`~/Library/Application Support/io.wenbo.surfclam/logs/surfclam.arch-coupling-audit.log` 里不得有 `编译失败`；
`tools/shot.sh --app <本实例 pid>` 截图确认侧边栏 + 工具栏「筛选」在；菜单栏有 文件/会话/显示 及原有各项；
⌘/ 面板内容与改前一致；`node --test clam-sidebar/test/*.test.js` 通过；不变量 4 的 grep 为空。
小问题就地修，大问题回报。

## 2. 验证配方（各执行者自用）

```sh
# JS 语法
for f in clam-*/lib/*.js surfclam/bin/*.js; do node --check "$f"; done
node --test clam-sidebar/test/*.test.js

# 插件 Swift 离线 typecheck（P0 不动 SDK，主 worktree 已构建 App 里的 ClamModules 仍有效）
APP="/Users/wenbopan/Repos/surfclam/clam-app/host/build/Build/Products/Debug/Surfclam Dev.app"
MODS="$APP/Contents/Resources/ClamModules"; TMP="$CLAUDE_JOB_DIR/tmp/tc"; mkdir -p "$TMP"
xcrun swiftc -emit-module -module-name ClamLayout -emit-module-path "$TMP/ClamLayout.swiftmodule" \
  -I "$MODS" -target arm64-apple-macos27.0 -language-mode 5 clam-layout/swift/*.swift
xcrun swiftc -typecheck -module-name ClamSidebar -I "$MODS" -I "$TMP" \
  -target arm64-apple-macos27.0 -language-mode 5 clam-sidebar/swift/*.swift
# clam-notify / clam-settings / clam-nativeify 同理

# 壳（只有 A 需要）：xcodegen + xcodebuild，命令照 clam-app/host/scripts/dev.sh，务必 -derivedDataPath build
```

## 3. 执行日志

（执行者追加：日期 · 波次 · 做了什么 · 验证了什么 · 遗留）

- **2026-08-29 · Wave 1 · B（P0 #5：toolbar metadata 代码化 + 槽名常量）**

  新建 `clam-layout/swift/LayoutContracts.swift`：`public enum LayoutSlots`（眼下只有
  `sidebar`）+ `public struct ToolbarSpec`（12 个 metadata 键各一个有类型的属性，
  `region`/`align`/`kind`/`priority`/`sizing` 收成五个 `String` raw value 枚举，
  `items` 保持 `[[String: Any]]`，`menu` 保持 `@convention(block) (NSMenu) -> Void`）。
  `metadata()` **缺省值一律省略而不是写进字典**——消费方每个键都是"读不到就用缺省"，
  两者等价；而 `kind` 缺席 ≠ `kind: "view"`（缺席是"按 symbol 推断"），
  所以它必须能表达"没说"，整张表就统一成同一条规则。

  改用方：`LayoutSplitController.swift` 那段 99 行的槽约定注释精简成"载荷为什么是字典
  （SDK 容器中立）+ 契约见 `ToolbarSpec`"（四条渲染路线的表、items 元素形状、
  流量 vs 拓扑那几段都搬进了 `ToolbarSpec` 的文档注释，一条都没丢）；
  `isOccupied` / `registry.view(for:)` / `version(of:)` 三处 `"sidebar"` → `LayoutSlots.sidebar`
  （`contributionIdentifiers(in: "sidebar")` **没动**：那是 region 值不是槽名）；
  `SidebarPlugin.swift` 的 `register(slot:)` 与筛选按钮的字面量字典；
  `HeaderPlugin.swift` 删掉 `private static let toolbarSlot = "toolbar"` 改用
  `LayoutToolbar.slot`，`contribute` 辅助改为收 `ToolbarSpec`（`region = .content`
  在辅助里定死，四格不再各写一遍）。ClamSDK 一个字没动。

  验证：三份 metadata 与改前**逐键等价**（唯一差别是 subagents/export 两格不再写
  `spaced: false`，消费方读的是 `== true`，且 `refreshToolbarSnapshot` 的签名走的是
  `Self.spaced(of:)` 归一化后的值，签名也不变）。离线 typecheck 全绿：
  `ClamLayout` `-emit-module` 通过，`ClamSidebar` 与当时那个 header module `-typecheck` 通过
  （sidebar 只剩 `SidebarFilter.swift:79` 那条 Swift 6 actor 隔离警告，先于本次改动存在）。

  遗留：① 没跑 `./dev` 的整合验收（归 Wave 3）；② `ToolbarItemState` 那条**活通道**的
  载荷键还是手写字典，本次只覆盖了拓扑侧——要收的话是同一手法，但它跨插件双向、
  改动面比 metadata 大，留给 Wave 2/C 或后续；③ `LayoutSlots` 眼下只有一个成员，
  `root` 是壳的槽、故意不收进来。

- **2026-08-29 · Wave 1 · A（P0 #1：命令注册表 + P0 #3：sidebar 门控改粘性事件）**

  **命令声明成了一处真相**（形状的权威文档写在 `clam-bridge/lib/plugin.js` 的
  `CommandDeclaration` typedef 里，声明方是插件作者，所以文档跟着声明走）。
  `createSwiftPlugin({ commands: [...] })` → 桥登记表（**不进 contentHash**：
  改一句菜单文案不该让 Swift 半边重编）→ 两个读者：壳（snapshot 的 `commands` 字段）
  与 clam-app（新的 `clamBridge.commands.list()/subscribe()`）。定稿形状与计划一致，
  三处出入：① 增加 `hidden`（⌘1-9 那九项要"藏起来但键照常生效"）；
  ② 一族命令用 `digits: {count, command, argKey}` + `keyChoices`，
  `key` 只写修饰键——这样 `sessionDigits` 仍是**一个**设置项（union 三取值），
  用户存过的值与设置页条目一个不变；③ `stopGenerating` 计划里写 `configurable: false`，
  实际保留可配置——它今天就在 `clam-shortcuts` 里，关掉等于丢用户已存的覆盖，
  与不变量 2 冲突（不变量优先）。

  壳：`setupMenus()` 拆成系统惯例段 + 贡献遍历段（每个系统菜单一处插入点，
  未知 `menu` id 造顶级菜单夹在「显示」与「窗口」之间）；九个 `@objc` 业务 selector
  收成一个 `runCommand(_:)`，命令名挂在 `representedObject`（`MenuCommandBox`）
  ——命令名是插件给的字符串，壳编译期一个都不认得，做不出对应的 `@objc` 方法。
  `Keymap` 从"编译期三张常量表"变成 `resolve(values:commands:)`：默认键位来自声明，
  `menuCommands` / `configurable` / `defaultSpecs` 三个常量删除；`Strings.swift` 的
  十条业务文案删掉（`menuSettings` 也删——⌘, 那一项本就随插件在场与否出现）；
  ⌘/ 面板的手工 `stopGenerating` 行改成"没有 `menu` 的命令"现采（`ShortcutsPanel.ExtraRow`）。
  snapshot 里命令有变就 `applyCommands` → 重算键位 → `rebuildMenus()`。

  **clam-app 的时序**：查过 `dsh-settings` 源码，`register()` 里是
  `this.ctx.effect(() => { registrations.set(ns, …); return () => registrations.delete(ns) })`
  ——重复注册 fails loud，但**撤销调用方 fiber 就能解注册**。所以做法是
  "登记表静默 300ms 后注册一次；之后指纹变了就 dispose 子 fiber 再注册一份"，
  两次安装串一条 Promise 队列（`dispose` 是异步的，叠在一起会撞 already registered）。
  指纹只含影响 schema 的字段，无关登记不会把设置界面上正开着的表原地换掉。
  用户存过的覆盖值不受影响（它们在设置文档里，schema 只管解析与显示）。
  一条可配置命令都没有时**不注册**——不开空卡片。

  **#3**：壳删掉 `isOccupied("sidebar")` 与 `clam-native-sidebar` 字面量，改订粘性主题
  `clam.web.query`（载荷 `[参数名: 值]`，壳侧常量在 `MainWindowController` 顶注、
  插件侧在 `LayoutPlugin.webQueryTopic`）；clam-layout 在 `SplitRepresentable` 的
  make/update 里发布（`sidebarVersion` 本就是它的输入，槽被占/释放时必然重算一次，
  不必另盯 registry），只在值真变了才 `emitSticky`。记忆键随之从
  `clam.nativeSidebar`（Bool）换成 `clam.webQuery`（字典），**代价是升级后首次启动
  会多重载一次页面**（旧键不迁移），之后照常。诊断面板那两行也跟着通用化：
  `原生侧边栏门控` → `页面查询参数`，`sidebar 槽占用者` → `已占用的槽`（照抄 registry），
  另加一行 `命令声明：N 条（owner/id …）`——第三方"我这条注册上了吗"有地方查了。

  验证：`node --check` 六个改过的 JS 全绿；`node --test clam-sidebar/test/*.test.js`
  18/18 通过；离线 typecheck `ClamLayout` `-emit-module`、`ClamSidebar` /
  `ClamSettings` `-typecheck` 全绿（sidebar 仍只有那条先于本次存在的 actor 警告）；
  壳 `xcodegen + xcodebuild -derivedDataPath build` **BUILD SUCCEEDED**；
  不变量 4 的 grep **为空**。整合：`./dev` 起来后
  `surfclam.arch-coupling-audit.log` 无 `编译失败`，五个插件全部装载，
  `页面查询参数变化：（无） → clam-native-sidebar=1，重载页面` 与
  `WebView 加载完成：…/?clam-native-sidebar=1` 证明 #3 通链；
  `快捷键设置面已注册：10 项` 与旧 schema 同一批键；
  `peekaboo menu list` 的菜单结构与改前逐项一致（设置…⌘, / 新建会话⌘N /
  重命名会话⌘⌥R / 归档会话⌘⇧⌫ / 聚焦搜索⌘⌥F / 会话菜单三项 ⌘⇧[ ⌘⇧] ⌘⌥A）；
  点「显示 › 聚焦搜索」后 sidebar 日志出现 `菜单命令：focusSearch`，
  声明 → 菜单 → emit → 插件应答整条链通。

  遗留：① **截图没截成**——`tools/shot.sh` 与 `peekaboo see` 这台机器此刻都在报
  SCK `-3811 / Bridge operation target attribution failed`（与本次改动无关，
  换 `menu list` + 日志取证），Wave 3 补一张；② 首轮 `./dev` 撞上了 CLAUDE.md 记过的
  "别的 worktree 的壳串进来"——主 worktree 那个 `Surfclam Dev` 连上了本 worktree 的
  dsh，两个壳往同一个世代目录写源码，报 `input file … was modified during the build`；
  **我把它 SIGTERM 掉了**（它当时没有自己的 dsh、停在引导页），重跑即全绿——
  需要它的话双击重开即可；③ 设置页字段顺序变成了"声明顺序"（layout 三条在前、
  sidebar 七条在后），条目与默认值一个没变，但顺序与旧版不同；
  ④ 桥的 `rescan` 只在 `swift/` 文件签名变化时 bump 版本，所以**命令声明单独变化
  不会推 snapshot**（插件注册/注销时顺带 bump，实际够用；真要精确得把 commands
  折进 tableHash，那是 Wave 2 动 `clam-bridge/lib/index.js` 时更顺手的事）；
  ⑤ 冷启动那一瞬间菜单只有系统惯例项，声明到齐（毫秒级）才补上业务项——
  声明住在 node 半边就必然如此。

- **2026-08-29 · Wave 2 · C（P0 #2：外部包 fail-loud + P0 #4 前半：删 request 通道）**

  **桥的 `register()` 从"尽量兼容"改成"当场抛"**，三条：module 名不合法
  （`moduleName()` 的结果过不了 `/^[A-Za-z_][A-Za-z0-9_]*$/`，典型是拿 scoped
  包名当 `name`）、`swiftDir` 不是目录、`swiftDir` 里一个 `.swift` 都没有；
  重复登记从 `warn + 后者覆盖前者` 改成抛。判据统一：这三种错的失败模式全是
  "dsh 照常起、HTTP 200、终端一片祥和，只是那个插件的原生半边静默不存在"，
  而登记是启动时发生一次的事——抛出去 cordis 会连插件名一起顶到作者脸上，
  这是唯一能当场看见的时机。错误文案各自带补法。

  **A 留的遗留 ④ 一并收掉**：`rescan` 里算**表** hash 的那一段从 `dirty` 分支里
  提了出来（每轮都算），并把各家的 `commands` 摘要折了进去。contentHash 那段
  仍然只在源码签名变化时重算，**`commands` 也仍然不进 contentHash**——改一句
  菜单文案不该让 Swift 重编。实测（临时脚本，两条）：登记 → 撤销 → 换一份
  commands 再登记，版本 v1→v2→v3 三次都推了，而 `clam-probe@005d40d3` 的
  contentHash 两次逐字相同。**顺带修了一个没人报过的洞**：旧代码里
  `dispose()` 走的 `rescan` 因为 `if (!dirty) return false` 直接早退，
  **插件退场根本不 bump 版本**，壳那边的菜单/世代表停在上一版。

  `clam-bridge/package.json` 的 exports 加 `"./locale": "./lib/locale.js"`
  （clam-app / clam-notify 的相对路径 import 不动——那是本仓库内的既定做法，
  这次只是把出口补上，外部包不必再穿包内路径）。

  `surfclam/bin/surfclam.js` 的 `ensureXcodegen` 两种模式都跑：签名改成
  `(local, repoRoot)`，落点由调用方给——link 模式 `<repo>/clam-app/host/tools/xcodegen`
  （行为一个字没变），registry 模式 `<profile>/node_modules/<clam-app 包名>/host/tools/xcodegen`
  （**在 `installInto` 之后算**，那时包才在位；包名从伞包 dependencies 里按目录名
  `clam-app` 找，不写死）。取件顺序在 registry 模式下只剩 PATH——npx 缓存里的伞包
  既不是 git 仓库也没有兄弟 worktree。两处都没有就打印 `brew install xcodegen`
  并继续（不 fail）。验证：`node -e` 确认那条路径在真实 profile 里指向的正是
  clam-app 自己 spawn 的那个文件（`HOST_DIR = ../host/`，经 node_modules 符号链接
  落到同一个 realpath）；`--install-only` 跑通，link 模式行为不变。

  **request 通道删干净**：`clam.window.requestTitle` 与
  `clam.layout.requestTitlebarMetrics` 两条常量、clam-layout 对后者的订阅、
  header 插件对前者的订阅（`HeaderToolbar.start()`）与对后者的发送
  （`HeaderPlugin` activate 里那句 `emit`）全部删除；两条正向通道
  （`clam.window.title` 在 `HeaderToolbar.emitWindow`、`titlebarMetrics` 在
  `LayoutSplitController.publishTitlebarMetrics`）改 `emitSticky`，
  `publishTitlebarMetrics(force:)` 的 `force` 参数随之删掉（它只有请求那一条
  调用方）。语义等价的判据：request 通道存在的**唯一**理由就是"只在变化时推 +
  晚到的订阅者"，而 `subscribe` 对粘性主题会同步回调最后一份——正是同一件事，
  且不再需要请求方记得喊。计划里提到的"每次装工具栏喊一嗓子"的调用点**本来就
  不存在**（`windowTitleRequestTopic` 全仓库只有一个订阅者、零个发送者，
  CLAUDE.md 那句描述是过时的，已告知 D）。`bridge.app` 原样未动。

  验证：`node --check` 两个改过的 JS 全绿；`node --test clam-sidebar/test/*.test.js`
  18/18；离线 typecheck `ClamLayout` `-emit-module` 通过，`ClamSidebar`
  与当时那个 header module `-typecheck` 通过（sidebar 仍只有 `SidebarFilter.swift:79`
  那条先于本次存在的 actor 警告）；`register()` 的三条 fail-loud 各写了最小
  node 脚本，六种坏输入全部如期抛、合法登记照常通过。

  遗留：① 没跑 `./dev` 的整合验收（归 Wave 3）——特别是"header 已停用但必须能
  编译"只验到 typecheck 这一级；② **粘性标识有一个窄口子**：header 插件退休时
  不推空标识，所以总线上会留着它最后那份 title；此后若 clam-layout 换代，
  新一代会从总线捡回这个属于过气插件的标题（旧代码那时是空标题）。没在
  `dispose` 里补一句"还回标识"是因为热替换的顺序是**新的先启、旧的后清**，
  那句话会把新一代刚摆好的标题擦掉——要修得带世代号判据，不是一行的事，
  而 header 眼下在编排表里是注释掉的；③ `rescan` 每轮多算一次 `topological()`
  加一次 sha256（5 条记录、500ms 一轮，可忽略），若将来登记表变大再谈缓存。

- **2026-08-29 · Wave 2 · D（P0 #6：文档）**

  两份新文档，**分工按"谁在读"切**而不是按主题切：

  - `docs/extend/plugin-author-guide.md` —— 写给**仓库外**的插件作者。三种最小骨架
    （纯 node / 带 Swift / 带 client，`package.json` + `index.js` + `FooPlugin.swift`
    都能直接抄）、`name` → module 名规则与三条 fail-loud、包名 import
    （`@wenbo/clam-bridge/plugin`）vs 本仓库的相对路径、peerDependencies 纪律、
    profile patch insert 一行、`dsh plugin add link:` 的外部热循环（桥轮询的是
    登记进来的绝对路径，**不必 clone 本仓库**）、Swift 半边的五条硬规矩
    （`activate` 返回值是持有链的根 / 保管箱只放系统类型 / 清理按进程收口 /
    不 `@objc` / 跨界只用 SDK 与系统类型）、六条配方（命令、工具栏贡献、占槽、
    只读别人的设置 ns、可选依赖、`ctx.provide` 中性服务名）、一张**症状 → 原因表**、
    一节"已知边界"（ABI 空承诺、metadata 零校验、无错误边界、侧边栏没贡献槽）。
  - `docs/extend/contracts.md` —— 契约总表。每一节都标着"权威在哪"，
    **权威永远是代码**（那里写着"为什么"和"失败长什么样"），这份只是索引，
    回答"我要接一条新的，现有的都有哪些"这类横向问题。含 `commands` 字段表 +
    当前在册的十一条声明、`ToolbarSpec` 12 键 + 四条渲染路线 + `clam.toolbar.update`
    的 patch 键表 + 三条回程主题、替换槽（`root`/`sidebar`）、事件主题总表
    （每条标粘性/发布方/订阅方，含 `clam.web.query`；死通道单列，
    `clam.activateWindow` 注了"P1 删"）、页内桥 `clam.page.*` 表、
    `ClamObjects` 键表（SDK 四个 + 各插件私有的跨代锚）、hook 名表、
    `ClamBridge` 与 `ClamStore`、末尾一张"我想…… → 用什么"速查。

  **源码注释只做了"指向"，没有搬走任何权威定义**：`CommandDeclaration`
  （plugin.js）、`ToolbarSpec`（LayoutContracts.swift）、`ToolbarItemState`
  （ToolbarContribution.swift）、hook 表（SystemDelegateRelay.swift 顶注）
  一个字没动，是文档去指它们。

  修过时项（审计 §5.4 逐项）：根 `README.md`（macOS 26+ → 27+ 并注明部署目标出处；
  仓库结构补 `surfclam/` `clam-notify/` `clam-settings/` `tools/`（当时还有一份 header 插件）；
  加一节指向两份新文档）；`clam-app/README.md`（"通知线已丢弃"改成事实——
  它以 clam-notify 的形态落地了，壳里只剩不认识通知语义的中转站；目录职责表补
  `GenerationLedger` / `WebPolicy` / `SystemDelegateRelay` 并给后两者各写一段
  "不设它会静默失效什么"；SDK 行补四张表；配置表 3 键 → 6 键；新增
  "它还注册一个设置 ns" 一节讲 `clam-shortcuts` 的动态 schema 与注册时序）；
  `clam-bridge/README.md`（帧表补 `app-build` / `app-restart` 并写明"绝不补发"的
  理由；新增"包的出口"表点出 `./plugin` 与 `./locale`；样例补
  `sharedModules` / `schemaVersion` / `Config` / `commands`；新增
  "`register()` 一律 fails loud" 表）；`clam-layout/README.md`
  （metadata 一节重写成"拓扑 `ToolbarSpec` / 流量 `clam.toolbar.update`"两小节，
  指向 `LayoutContracts.swift`；末尾"新建会话不在工具栏上"补上现状——
  整条工具栏眼下只有「筛选」一条，⌘N 走 commands 声明）；
  header 插件的 `README.md` 顶部加停用提示块（并说明"下文全是现在时"）；
  `clam-settings/README.md` 与 `lib/index.js` 顶注的 DSHKit 措辞改成事实
  （随 M10 退役，眼下唯一共享 module 是 ClamSDK）；`ClamHooks.swift:99`
  那句"⌥⌘D 面板会列它"改成"眼下全仓零调用方，遍历它是 P1-11 的事"
  （**只动注释**）。

  `CLAUDE.md`：clam-layout 那段的"连自家新建会话也是一条普通贡献"改成事实并指向
  `ToolbarSpec`；clam-bridge 那行补 `./locale` 与三条 fail-loud；`docs/` 那行加两份
  新文档；`MainWindowController` 那段的快捷键描述整段重写（词汇表不再在
  `setupMenus()` 顶注里，声明在插件的 `commands`、权威在 `CommandDeclaration`；
  顶注现在讲的是"系统惯例段 + 贡献遍历段"怎么拼；九个 `@objc` 收成
  `runCommand(_:)`）；插件门控那条补上"参数名壳不认得，走 `clam.web.query`"；
  SDK 那段的 `clam.window.requestTitle` 描述按 C 落地后的事实改写
  （改 `emitSticky`、两条 request 通道已删）；开发循环表那一行补一句
  "`commands` 声明也在这一行，且不进 contentHash"。

  验证：`node --check clam-settings/lib/index.js` 通过（唯一动过的 JS，只改注释）；
  `ClamHooks.swift` 只改文档注释，`.swiftinterface` 不含 doc comment，
  不触发插件全量重编；两份新文档里的每个常量名、字段名、文件路径都回源码核对过
  （`LayoutPlugin` / `LayoutSplitController` 是 internal，文档里标了"外部照抄字符串"，
  没有把它们写成可 import 的公开常量）。

  遗留：① **CLAUDE.md 里那四处 "macOS 26" 没动**——它们是"在 macOS 26 上实测到
  X"的事实陈述（`screencapture -l` 废了、LaunchServices 按路径去重、scroll edge
  effect、`NSSearchField` 内部结构），不是版本要求；审计表里那条 `macOS 26+`
  说的是根 `README.md:28` 的前置条件，已改。② 审计 §5.4 那张过时表**原样保留**
  （它记录的是审计当时的事实），只在 §7 执行日志里说明这些项已修。
  ③ 两份新文档没有做"每个链接都点一遍"的校验，只核了相对路径存在。

- **2026-08-29 · Wave 3 · 集成验证**

  静态：`node --check` 24 个 JS 全绿；`node --test clam-sidebar/test/*.test.js` 18/18；
  不变量 4 的 grep **为空**（改完那处 bug 之后又跑了一遍，仍为空）。

  整合：`./dev` 起 profile `surfclam-arch-coupling-audit`（端口 53125）。
  五个插件 g1~g5 全部装载（layout / nativeify / sidebar / notify / settings），
  `编译失败` **0 条**，日志里也没有键位冲突或解析失败。
  `快捷键设置面已注册：10 项` 与 A 记的那批键逐字相同；
  `命令声明 10 条：clam-layout/openSettings … clam-sidebar/sessionDigits` 证明
  声明经桥 snapshot 到了壳。

  **补上了 A 记遗留 ① 的截图**：`tools/shot.sh` 这次一切正常（SCK -3811 是环境性的，
  换个时间就好了，与本仓库无关）。`.scratch/wave3-main.png`（原生侧边栏 + 搜索框 +
  全部/按时间/待处理三枚胶囊 + taste-bench 分组 + 两行会话行，右侧是真页面不是引导页）、
  `.scratch/wave3-shortcuts.png`（⌘/ 面板）、`.scratch/wave3-after-fix.png`（修完之后）。
  工具栏经 AX 核过是 `AXMenuButton 筛选` + `AXButton 边栏` 两项，正是 B 记那条
  `ToolbarSpec` 贡献。

  **菜单键符全部画得出来。** 关键那格用 AX 直接量而不是看 peekaboo 的文本输出：
  `AXMenuItemCmdChar` 的 `id` = **8**（U+0008）、`AXMenuItemCmdModifiers` = 1（⌘⇧），
  正是 3802996 那条修复的形态。**peekaboo `menu list` 把这格印成 `[⌘⇧]` 是它自己
  印不出控制字符**，不是菜单空白——差点误判，记在这里省下一次。
  ⌘/ 面板的 `拷贝` 按钮拉出来的全文里是 `归档会话 ⇧⌘⌫`，且末尾有
  `── 页面内 ──｜停止生成 ⎋`（A 把手写那行改成"没有 menu 的命令现采"之后的样子）
  与 `会话 1..9 ⌘1..⌘9`。

  链路实测两条：点「显示 › 聚焦搜索」→ `[clam-sidebar g3] 菜单命令：focusSearch`；
  按 ⌘1 → `菜单命令：selectSessionAt`。后者是特意测的——九个数字项是**隐藏**菜单项，
  而隐藏项的键要靠 `allowsKeyEquivalentWhenHidden` 才生效，A 把它保住了
  （`MainWindowController.swift:902/914`），实测也确实生效。

  **就地修了一个 A 引入的回归**（本次唯一改动，未 commit）：
  `MainWindowController.swift` 的 `applyWebQuery` 少了"等装载稳定"这道闸。
  改前的 `syncNativeSidebarGate()` 是挂在 `nativeHost.onUpdate` 上、且
  `guard nativeHost.didSettle` 的，A 换成纯订阅 `clam.web.query` 之后
  **`onUpdate` 那条线整个没了**，于是装载途中每个插件各自上线时发的半成品状态
  都会触发一次重载：clam-layout 先上线，那一刻 sidebar 槽还空着，它如实报
  "不要参数"，紧接着 clam-sidebar 上线又报回来。症状是**每次冷启动网页整个加载三遍、
  中途闪一下网页侧边栏**（日志里两行 `页面查询参数变化`），与不变量 2 冲突。
  修法照旧：`applyWebQuery` 只记不重载，重载收口到新的 `syncWebQueryGate()`，
  由 `nativeHost.onUpdate` 在 `didSettle` 之后调一次。
  修完重启壳复验：`页面查询参数变化` **0 行**、`WebView 加载完成` **1 行**
  （改前同一段是 3 行），侧边栏与工具栏照常，`focusSearch` 链路照常。

  遗留：① **`会话` 菜单尾部挂着一条孤立的分隔线**（九个数字项隐藏之后它就悬在那儿）
  ——`git show 3c6d3ec` 核过，**改前就是这样**，不是本次引入的，没动；
  ② 邻居 worktree 的壳这次没串台：开跑前把两个残留实例都 `peekaboo app quit` 了，
  之后 `web-header-native-match` 那个被它自己的 dsh（pid 17102）重新拉起并接回了
  自己那套（日志里 `来源 discovery` 且**没有** ⚠️ 标记），全程与本 worktree 无交叉；
  ③ A 记遗留 ③（设置页字段变成声明顺序）与 ⑤（冷启动菜单先只有系统项）本次照旧存在，
  都是设计使然，没管；④ 桥的三条 fail-loud 只做了**读码复核**
  （`clam-bridge/lib/index.js:134/140/150/156`，四条抛错全在 `register()` 主路径上、
  在建 record 之前），没再跑一次 Wave 2 已经跑过的脚本级验证。
