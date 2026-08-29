# P0 解耦执行计划（2026-08-29）

来源：`docs/architecture-coupling-audit.md` §6 的 P0 档。这一批的共同特征是**不动 ClamSDK 任何 public 声明**
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

`commands` 每条的形状（定稿，写进 `docs/clam-contracts.md`）：

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
`clam-sidebar/swift/SidebarPlugin.swift`、`clam-header/swift/{HeaderPlugin,HeaderToolbar}.swift`。

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
`clam-layout/swift/ToolbarContribution.swift`、`clam-header/swift/{HeaderPlugin,HeaderToolbar}.swift`、`clam-layout/swift/LayoutSplitController.swift`（若 title 发布点在这里）。

**D. 文档（P0 #6）**

- 新建 `docs/plugin-author-guide.md`：三种最小骨架（纯 node / 带 Swift / 带 client）、package.json 字段表
  （`exports`、`files` 含 `swift`、peerDependencies 纪律、`dsh.client`）、`name` 命名规则（kebab-case → module 名）、
  `@wenbo/clam-bridge/plugin` 包名 import、profile patch 里 insert 一行、`dsh plugin add link:` 外部热循环、
  `activate` 返回值必须是持有链的根、跨代保管箱只放系统类型、只读别人的设置 ns 的配方。素材位置见审计附录 B。
- 新建 `docs/clam-contracts.md`：`commands` 声明形状（Wave 1 定稿）、toolbar `ToolbarSpec` 各键、`ClamEventBus` 主题表
  （含 `clam.web.query`、粘性与否、发布方/订阅方）、`ClamObjects` 键表、hook 名表、`clam.toolbar.update` 活通道。
  源码里对应的注释改成一句"约定见 docs/clam-contracts.md"，不再各自维护一份长注释。
- 修审计 §5.4 那张过时表里的每一项（各 README、CLAUDE.md、`ClamHooks.swift:99` 那句假话）。
  CLAUDE.md 里 clam-layout 那段"连自家新建会话也是一条普通贡献"改成事实；`macOS 26+` → `27`；
  clam-header README 顶部加"已停用"；`clam-app/README.md` 的目录表与配置表补全。
- 审计文档 `docs/architecture-coupling-audit.md` 末尾加"§7 执行日志"，记 P0 各项的落地 commit。

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
# clam-header / clam-notify / clam-settings / clam-nativeify 同理

# 壳（只有 A 需要）：xcodegen + xcodebuild，命令照 clam-app/host/scripts/dev.sh，务必 -derivedDataPath build
```

## 3. 执行日志

（执行者追加：日期 · 波次 · 做了什么 · 验证了什么 · 遗留）
