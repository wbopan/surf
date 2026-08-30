# 侧边栏重设计：单行 32pt + 顶部新建行

**权威设计稿**：https://claude.ai/code/artifact/0c8df6e0-671a-4630-a645-9aba583475b0
（三页：方案 / 筛选菜单 / 新建会话。「实现规格」那张画板是数值的权威，
本文的数值与它冲突时以画板为准并回来改本文。）

**设计裁决已经做完**，本文不重开设计讨论，只讲怎么落地：

- 会话行 **单行 32pt，不显示摘要**（用户在四个密度变体里挑的，原话是
  「看的最舒服的还是直接没有摘要」）。
- 新建会话入口用 **② 顶部新建行**（搜索框上方常驻一条 accent 色的行）。
- 筛选菜单按重设计稿改（它不是可选项：三枚胶囊拿掉之后，「按时间」
  分组模式只剩菜单这一个去处）。

## 0. 判据与不变量

0.1 **几何与色值的唯一出处是 Apple macOS 27 UI Kit**，用 `tools/apple-kit/lookup.py`
    复查，别凭记忆估。这一版的落点几乎全部在 kit 里：

    | 用途 | 官方 symbol | 值 |
    |---|---|---|
    | 会话行 | `Sidebars/*/Medium/Items/Level 0` | 240×32，标题 SFPro-Regular 13 |
    | 选中块 | 同上 Selected | 圆角 8，`rgba(0,0,0,.11)` / 深色 `rgba(255,255,255,.11)` |
    | 分区头 | `Sidebars/*/Medium/Header` | 高 18，SFPro-Bold 11，`rgb(178,178,178)` |
    | 行内槽位 | 同一 symbol 的 Leading / Trailing | leading 20、槽→标题 4、trailing 36 |
    | 菜单项 | `Menus/Light/Regular/…` | 高 24，SFPro-Medium 13；分区头 Bold 13 `rgb(115,115,115)`；分隔线 1px `.07` |

    只有两个数不在 kit 里：搜索框 28（= `NSSearchField` 的 `.large`）与底栏 32。

0.2 **选中高亮、hover、键盘导航一律继续交给 `List` + `.listStyle(.sidebar)`**。
    不要加 `.listRowBackground`、不要自绘选中块——这条在
    `SidebarView.swift:602-605` 已经写着，重设计不改变它。上表里的选中块数值
    是**用来核对系统画得对不对**的，不是让你照着画。

0.3 **不替 dsh 补它没有的能力**，也不主动制造原生侧边栏与 dsh 网页端的显示差异。
    （见 §6「不做什么」第 1 条。）

0.4 **每个里程碑做完在 §7 追加一行执行日志。**

## 1. 现状 → 目标，逐项对照

| # | 现状 | 目标 | 位置 |
|---|---|---|---|
| 1 | 会话行两行、`padding(.vertical, 14)`、实高约 74 | 单行、定高 **32** | `SidebarView.swift:51-153` |
| 2 | 摘要 `lineLimit(2, reservesSpace: true)` | **整块删掉** | `:91-95`（工作区视图）、`:85-89`（时间视图） |
| 3 | 每行底部一条 `Divider` overlay | **删掉**，侧边栏不画分隔线 | `:135-140`、可见规则 `:584-588` |
| 4 | 状态槽 `StatusIndicator.slot = 16` | **20**（对齐官方 leading icon） | `StatusIndicator.swift:26` |
| 5 | 行内不显示时间 | trailing 显示**相对时间**，与状态图标**互斥** | 新增，见 §2.2 |
| 6 | 分区头：folder 图标 + 13 Medium `.primary` + 计数 | **无图标**、11 Bold `rgb(178,178,178)`、高 18、计数保留 | `:161-266`（工作区）、`:557-570`（时间段） |
| 7 | 三枚筛选胶囊（全部 / 按时间 / 待处理） | **整块删掉** | `:442-482`、`countFor` `:485-504` |
| 8 | `Mode { all, time, pending }` | `Mode { workspace, time }`；pending 升格为置顶分区 | `SidebarFilter.swift:21-35` |
| 9 | 「筛选」菜单：裸勾选列表 | 两个原生分区头 + 计数 + 全选 + 常显的清除 | `SidebarPlugin.swift:196-232` |
| 10 | 新建会话只有分区头 hover 的加号 | **搜索框上方常驻一条「新建会话」** | 新增，见 §2.5 |
| 11 | 左下角 `plus.circle`（其实是"添加工作区"） | 换成 `folder.badge.plus` | `:684` |

## 2. 里程碑

### M1 — 会话行改单行

`SidebarView.swift` 的 `SessionRow`：

- `HStack(alignment: .top, spacing: 6)` → `alignment: .center`、`spacing: 4`
  （槽→标题 4 是官方值）。
- 删掉 VStack 与其中全部副行（`:80-95`），标题直接进 HStack。
- 标题字体**显式写成 `.system(size: 13)`**，别再继承。官方是 Regular，
  两行版为压住摘要而加的 Medium 这次不要。
- `.padding(.vertical, 14)` → 删；行高改为 `.frame(height: 32)`。
- 删掉 `Divider` overlay（`:135-140`）与 `:584-588` 的可见规则。
- `StatusIndicator.slot` 16 → 20（`StatusIndicator.swift:26,30`）；
  内部图标尺寸不变，只是槽变宽。
- 归档行：`archivebox.fill` 从 trailing **挪到 leading 槽**（顶掉状态位，
  归档本来就是一种终态），trailing 让给时间。整行 `.opacity(0.6)` 保留。
- hover 归档按钮（`:111-126`）保留，但它现在要和时间共用 trailing——
  hover 时时间淡出、归档按钮淡入，**同槽 ZStack 叠放**，照分区头
  `:226-249` 那套"原地换字形"的写法，别左右横跳。
- 顶部注释 `:19-21` 写着「两行且定高 56pt」「行内不显示时间」，两句都要改。

**验收**：`tools/shot.sh` 截图，行高量出来是 32、标题左缘在 38（14 + 槽 20 + 4）。

### M2 — 时间戳

新增，数据面已有 `SidebarSession.updatedAt: Date`（`SidebarModel.swift:39`），
现在只被时间分段与排序用。

- 新增格式化（建议放 `SidebarView.swift` 或单独一个小文件）：
  今天 → `HH:mm`；昨天 → 本地化的「昨天」；7 天内 → `EEE`（周三）；
  更早 → 本地化短日期。
- **本地化走 `DateFormatter` 自己的能力**（`doesRelativeDateFormatting = true`
  给「昨天」，`setLocalizedDateFormatFromTemplate` 给周几），语言用
  `surf-bridge/locale` 决议出来的那个，别往 `Strings.swift` 里手写一堆
  「昨天 / Yesterday」。
- 字体 `.system(size: 10)` + `.monospacedDigit()`，`.foregroundStyle(.tertiary)`。
- **DateFormatter 要缓存**，别每行每帧新建一个（它很贵）。
- 与状态图标互斥：`status == .idle`（或归档）时显示时间，否则显示状态图标。
  ——注意状态图标此刻在 **leading**，所以严格说不是"互斥"而是"各就各位"：
  trailing 恒为时间，leading 恒为状态/归档/空。**按这个来**，设计稿画的就是它。

### M3 — 分区头 + 待处理升格

- 工作区分区头（`:161-266`）：删图标那段（`:173-181`）；标题改
  `.system(size: 11, weight: .bold)`、颜色 `Color(nsColor: .tertiaryLabelColor)`
  一档的灰（对照 kit 的 `rgb(178,178,178)` 截图核一次）；容器高度约束从
  `minHeight: 26` + `padding(.vertical, 3)` + `padding(.top, 4)`（`:533-535`）
  改成高 18 + 分区间距 14。
- 时间分段头（`:557-570`）改成同一套规格——**两处必须长得一样**，
  现在一个 11 semibold secondary、一个 13 medium primary。
- 删 `filterChips`（`:442-482`）与 `countFor`（`:485-504`）。
- `SidebarFilterState.Mode`：`all` → `workspace`，删 `pending`。
  **`rawValue` 是持久化身份**（`SidebarFilter.swift:29` 注释），旧值
  `"all"` / `"pending"` 读回来要落到 `workspace`，别让人重启后掉进空列表。
  （本仓库不写迁移代码，但这一处是"读到不认识的值退默认"，不是迁移。）
- 待处理升格：在两种分组视图**最上面**插一个「待处理」分区，收
  `status.needsAttention` 的会话，并**从下面的分区里移除**（提取式，不重复）；
  空则整个分区不出现。排序按 `updatedAt` 倒序。
- 空态文案（`Strings.swift:124-132`）里 `noPendingSessions` 随 pending 模式
  一起退休。

### M4 — 筛选菜单

`SidebarPlugin.swift:196-232` 的 `populate`：

- 两个 `NSMenuItem.sectionHeader(title:)`（macOS 14+，**原生 API，别自绘**）：
  「分组方式」与「工作区」。`:197-199` 那句"这一段不加分区标题"的注释
  连同判断一起作废——注意它下面那条 `NSMenuToolbarItem` 吃掉第 0 项的坑
  （已由 `padPullDownTitleSlot` 收口）依然成立，**照常从第一项填起**。
- 分组方式两项：按工作区 / 按时间，勾选跟 `filter.mode`。
- 工作区项右侧加计数：`NSMenuItem` 没有原生 trailing 数字，用
  `attributedTitle` 拼（名字 + 右对齐的计数）或退而求其次写进标题。
  **先试 `attributedTitle` + `NSTextTab` 右对齐**，做不出来就降级成不显示计数，
  别硬造一个自绘视图塞进菜单。
- 「显示全部工作区」：全部已显示时 `isEnabled = false`。
- 「显示已归档」右侧同样带归档条数。
- 「清除筛选」**常显**，`isEnabled = filter.isNarrowed`（现在是条件插入，
  菜单长度会跳变）；快捷键 ⌥⌘K **走 `commands` 声明**（node 半边加一条，
  `SidebarShortcuts` 应答），不要只在 `NSMenuItem` 上设 `keyEquivalent`——
  `NSMenuToolbarItem` 的菜单不参与主菜单键位匹配，那样按不出来。

### M5 — 顶部新建行

- 位置：**titlebar 之下、搜索框之上**，`padding(.horizontal, 10)`，行高 32，
  圆角 8（和会话行同一套块几何），内容 = `square.and.pencil`（20 槽）+ gap 4
  + 「新建会话」13 Medium，整体 `Color.accentColor`。
  它属于**头部区**，不进 `List`——设计稿刻意让它和列表之间留 10pt。
- 动作：`surface.startSession(workspaceId:)`（`:207` 已经在用），
  **workspaceId 取当前选中会话所属的组**；没有选中会话时传 `nil`（兜底组）。
  规则照备忘录：新建落在你此刻待着的地方，不弹菜单问。
- `accessibilityIdentifier("sidebar.newSession")`，加 `.help` 与 AX label。
- 分区头 hover 的加号**保留**（它是"明确指定这个项目"的快捷方式）。
- 左下角 `plus.circle` → `folder.badge.plus`（`:684`），
  `sidebar.addWorkspace` 这个 identifier 不变。

### M6 — 收尾

- `SidebarView.swift:31-48` 的 identifier 清单补 `sidebar.newSession`，
  删掉 `sidebar.chips.<mode>`。
- `CLAUDE.md` 里 surf-sidebar 那段（「搜索 + 全部/按时间/待处理三枚胶囊 +
  两行会话行」）已经不成立，改掉。
- `node --test surf-sidebar/test/*.test.js` 跑通（分组/去抖/翻牌那几条应该
  不受影响；受影响就改测试，别改行为）。
- 截图对照设计稿的浅色与深色两张。

## 3. 验收

1. `tools/shot.sh --app <pid> --scale 2` 出图，与设计稿并排比：
   行 32、标题左缘 38、分区头 18 且两种分组视图长得一样、无分隔线、
   底栏细线在、顶部新建行在搜索框上方。
2. 深色：dsh 设置切到深色，再截一张。**主题真相在 dsh**，原生侧只跟随。
3. `peekaboo see --pid <pid> --tree --no-screenshot`：
   `sidebar.newSession` 在、`sidebar.chips.*` 没了、
   `sidebar.group.<id>` 没有被拼两遍（SwiftUI 容器合并的老坑）。
4. 「筛选」菜单：`peekaboo menu list --pid <pid>` 或直接截图，
   看两个分区头画得出来、「清除筛选」无筛选时是灰的而不是消失。
5. `node --test surf-sidebar/test/*.test.js`（**目录要带通配符**，
   给 `--test` 一个目录在 node 26 上直接 `MODULE_NOT_FOUND`）。

## 4. 顺序与耦合

M1 → M2 → M3 → M5 都改 `SidebarView.swift`，**串行做，别并行**。
M4 主要在 `SidebarPlugin.swift` 和 node 半边，但依赖 M3 定下的 `Mode`，
所以排在 M3 之后。M6 最后。

Swift 改动**存盘即热替换**（1~3s），不用重启 dsh 也不用重启 App；
node 半边（M4 的 `commands` 声明）改了**必须重启 dsh**。

## 5. 不做什么

1. **不给 blank 会话在侧边栏占位。** 新建之后侧边栏不会多出一行（`blank`
   在 `AppSidebarModel.swift:113-115` 的 `visible()` 里被过滤），于是"新建"
   这个动作没有落点反馈。这是个真实缺口，但补它就等于让原生侧边栏显示得和
   dsh 网页端不一样——按仓库既定立场，**如实记着，不擅自改**。
2. 不动侧边栏宽度默认值（256）与 min/max（200/420）。
3. 不自绘选中高亮（§0.2）。
4. 不实现 dsh 没有的能力（取消归档之类的老话题不在本次范围）。
5. 不写任何迁移/兼容代码：本项目未发布，旧的 `Mode` rawValue 读不认识就退默认。

## 6. 已知的坑（动手前先读）

- `NSViewRepresentable` 每轮 update 会把环境值回写进 NSControl——搜索框高度
  只能靠 SwiftUI 侧的 `.controlSize`，写在 `makeNSView` 里无效
  （`SidebarSearchField.swift:18,42` 的注释）。本次把 36（extraLarge）改成
  28（large）**也只能改那一处**。
- SwiftUI 的 identifier 挂在会被合并的容器上会被拼两遍；加新 identifier 后
  务必 dump 一次 AX。
- `NSHostingController.sizingOptions` 必须是 `[]`，否则换代重建视图会把
  分栏宽度拉成内容宽度（`LayoutSplitController.swift:180-186` 已经设了，别动)。
- 别把清理逻辑挂在 `SurfPluginHandle` 析构上；`activate` 每次热替换都会跑。

## 7. 执行日志

（每完成一个里程碑追加一行：里程碑 / 日期 / 实际改了哪些文件 / 与计划的偏差）

- **M1 会话行改单行** · 2026-08-30 · `surf-sidebar/swift/SidebarView.swift`
  （`SessionRow` 整体重写、`timeSections`/`TimeSection.rows` 去掉工作区字段、
  删 `dividerVisible`、`row()` 收成一参）、`surf-sidebar/swift/StatusIndicator.swift`
  （`slot` 16 → 20）。
  **与计划的偏差三处**：
  ① 计划只说"删摘要"，实际连「按时间」视图那条**工作区名**副行也一并删了
     ——单行 32pt 里没有第二行可写。代价是按时间分组时看不出会话属于哪个项目，
     如实记在这儿。
  ② `.frame(height: 32)` 不够：sidebar List 自带上下各 4pt 行内边距、左右各 16pt
     内容内边距，实测行占 40、标题左缘落在 40。补 `.listRowInsets`，而且
     **它是叠加不是替换**——leading 给 14 量出来是 30，真正要的是 **-2**
     （把内容从"选中块内缩 6"挪到设计稿的"内缩 4"）。上下 0 正好 32。
  ③ 归档行的 `archivebox.fill` 从 trailing 挪到 leading 后，AX label 一并挪过去。
  **验收**：截图逐像素量，行距 64px@2x = 32pt、标题左缘 38、槽 14–34、
  无分隔线、选中高亮仍是 List 自己画的那枚内缩 10pt 圆角块。
  截图 `.scratch/verify-m1.png`。

- **M2 时间戳** · 2026-08-30 · 新增 `surf-sidebar/swift/SessionTimestamp.swift`；
  `SidebarView.swift` 的 `SessionRow.trailing` 加时间、新增 `archivable`。
  格式实测（`zh_Hans` / `en`）：`16:29`/`4:29 PM`、`昨天`/`Yesterday`、
  `周四`/`Thu`、`2026/7/31`/`7/31/26`——**一个「昨天」都没写进 `Strings.swift`**，
  全走 `DateFormatter`（`doesRelativeDateFormatting` + `setLocalizedDateFormatFromTemplate`）。
  按语言缓存整套格式器。
  **与计划的偏差一处**：trailing 槽 36 **不是定宽而是 minWidth**（设计稿 CSS 写的
  也是 `min-width:36px`）。钉死 36 时 en 下的「3:09 PM」「Yesterday」被截成
  「12:4…」「Yeste…」（截图实测）。时间加 `.fixedSize()`：宁可标题少几个字，
  也不要一列读不出来的省略号。截图 `.scratch/verify-m2.png`。

- **M3 分区头 + 待处理升格** · 2026-08-30 · `SidebarView.swift`（新增
  `SectionHeaderStyle` / `PlainSectionHeader`；`GroupHeader` 去图标、换字体色；
  时间分段头改用同一个 `PlainSectionHeader`；删 `chips`/`chip`/`countFor`；
  两种视图最上面插 `pendingSection`；`isEmpty`/`emptyText` 跟着改）、
  `SidebarFilter.swift`（`Mode` 只剩 `workspace`/`time`；新增 `belongsToSections`
  与 `pendingSessions`；`orderedSessions` 把待处理排在最前）、
  `Strings.swift`（`filterAll`/`filterTime`/`filterPending` → `groupByWorkspace`/
  `groupByTime`/`pendingSection`；删 `noPendingSessions`）、
  `SidebarPlugin.swift`（两处 `.all` → `.workspace`）。
  **与计划的偏差两处**：
  ① 计划说分区间距 14 要自己加 `.padding(.top, 14)`——**加了会叠成 27**。
     sidebar List 自带的分区留白实测就是 13.8pt，正好是设计稿的值，所以一个
     top padding 都不加。`SectionHeaderStyle` 因此没有 `gap` 常量。
  ② 分区头颜色不用 `.tertiaryLabelColor`，用显式的 dynamic `NSColor`：
     浅色 `rgb(178,178,178)`（截图量出来是 180,181,182，误差在抗锯齿里）、
     深色 40% 白。官方深色那档 `rgb(76,76,76)` 是 vibrancy 混合值，直出太暗
     ——Specs 画板自己也标了这一条。
  分区头左缘实测 13.5pt（sidebar List 给 Section header 的默认内容内边距就是 14，
  与会话行那 16 不同，所以头不需要 `listRowInsets`）。
  「待处理」置顶分区用探针（临时把前两条会话灌进去）截图验过，形态与设计稿一致；
  探针已撤。截图 `.scratch/verify-m3.png`。

- **M5 顶部新建行** · 2026-08-30 · `SidebarView.swift`（新增 `newSessionRow` 与
  `currentWorkspaceId`、`hoveringNew`；`body` 的头部区改成"新建行 10/6 + 搜索框 /10"；
  `addWorkspaceBar` 加细线、`plus.circle` → `folder.badge.plus`、定高 32、
  左右 12）、`SidebarSearchField.swift`（`.controlSize(.extraLarge)` → `.large`，
  36 → 28，连同顶部注释改写）。
  **与计划的偏差一处**：新建行给了 **hover 才有的底**（`Color.primary.opacity(0.06)`
  的圆角 8 块）。设计稿只画了静止态，但一条没有任何按下预期的可点区域在 macOS 上
  读不出来。这不属于 §5-3「不自绘选中高亮」——那条管的是 `List` 的选中态。
  **验收**（截图逐像素量）：图标槽中心 24.5（应 24）、标题左缘 39（原点 38）、
  行高 32、titlebar → 行 10、行 → 搜索框 6、搜索框 29px 高（= `.large` 的 28）。
  截图 `.scratch/verify-m5.png`。

- **M4 筛选菜单** · 2026-08-30 · `SidebarPlugin.swift`（`populate` 整体重写；新增
  `countColumnLocation` / `titleWithCount`）、`Strings.swift`（新增
  `groupBySection` / `workspacesSection` / `showAllWorkspaces`）、
  `lib/index.js`（新增 `clearFilters` 命令，menu `view`、⌥⌘K）、
  `SidebarShortcuts.swift`（应答 `clearFilters`）。
  **计划没提、但不写就静默失效的一条**：`menu.autoenablesItems = false`。
  默认 true 时 AppKit 按"target 认不认这个 action"重算 enabled，
  把「显示全部工作区」「清除筛选」设的 `isEnabled = false` 直接抹掉。
  **与计划的偏差一处**：计数右列的制表位**不写死**（计划里说"先试 attributedTitle
  + NSTextTab"，没说位置怎么定）。按当轮最宽标题算 + 34pt——写死的话
  `dsh-web-search-firecrawl` 这种名字一超过定值，右制表位失效、数字跳到下一个
  默认制表位。工作区计数与归档计数共用同一条竖线。
  「清除筛选」上的 ⌥⌘K **只是画给人看的**，真正按得出来的是 node 那条声明
  （`NSMenuToolbarItem` 的菜单不参与主菜单键位匹配）。
  `SidebarShortcuts.clearFilters` 不清搜索词——它在搜索框里看得见，
  一起清掉会让人以为快捷键按错了；已经是默认状态就 beep。
  **验收**（截图 `.scratch/verify-m4-menu.png` / `verify-m4-menu2.png` /
  `verify-m4-menu-clean.png`）：两个原生分区头画得出来、计数右对齐成一列、
  ⌥⌘K 画在右列、无筛选时「显示全部工作区」与「清除筛选」都是**灰的而不是消失**。

- **M6 收尾** · 2026-08-30 · `SidebarView.swift`（顶部注释与 identifier 清单：
  补 `sidebar.newSession`、删 `sidebar.chips.<mode>`、把「顶部三段」改写成
  「新建行 / 搜索 / 列表 / 底栏」）、`README.md` 与 `docs/internals/architecture.md`
  （「待处理」胶囊 → 置顶分区）、`docs/use/install.md`（「界面 › 会话边栏」整条重写）。
  **与计划的偏差一处**：计划说改 `CLAUDE.md` 里 surf-sidebar 那段——**那段已经不在了**
  （根 CLAUDE.md 早前瘦身成一行"数据面在 node 半边，Swift 只管画"，仍然成立）。
  真正过期的三处在 README / architecture / install，改的是它们。
  `docs/archive/` 下的旧计划按惯例不动。

## 8. 验收结果（2026-08-30）

| # | 项 | 结果 |
|---|---|---|
| 1 | 浅色截图 | `.scratch/verify-final-light.png`。逐像素量：行距 32、标题左缘 38、leading 槽 14–34、trailing 与分区头计数右缘都落在 240（= 256 − 16，文字右边距约 14）、分区头 18 且两种分组视图同一套、无分隔线、底栏细线在、新建行在搜索框上方 |
| 2 | 深色截图 | `.scratch/verify-dark.png`（临时把 `~/.dsh/settings.yaml` 的 `ui-theme.preference` 切成 `dark`，量完**已还原成 `system`**）。分区头合成色 `rgb(123,125,125)`，正是 40% 白压在 `rgb(35,38,38)` 上的值 |
| 3 | AX 树 | `peekaboo see --pid --tree --json`：`sidebar.newSession` 在、`sidebar.chips.*` 一条不剩、`sidebar.group.<id>` 没有被拼两遍。**一条既有现象记在这儿**：会话行的 identifier 会同时落在行内每个 AX 叶子上（归档行是 archivebox + 标题两个），所以带图标的行数出来是 2 个同 id 元素——这不是本次引入的（状态图标一直如此），`--on` 定位时要留意 |
| 4 | 筛选菜单 | `.scratch/verify-m4-menu.png` / `-menu2.png` / `-menu-clean.png`：两个原生分区头画得出来、计数右对齐成一列、⌥⌘K 画在右列、无筛选时「显示全部工作区」与「清除筛选」是**灰的而不是消失** |
| 5 | 单测 | `node --test surf-sidebar/test/*.test.js` → 18 passed / 0 failed（分组、去抖、翻牌那几条不受影响，一行没改） |

**「按时间」视图**另截一张 `.scratch/verify-bydate.png` 核对：分段头与工作区分组头
长得一模一样（同一个 `PlainSectionHeader`）。

- **收尾调整（用户当场提的两条）** · 2026-08-30 · `surf-sidebar/swift/SidebarView.swift`
  ① **底栏那条 `Divider()` 去掉**。原本的理由是"没有线，⊕ 就是个孤立符号"，
     但侧边栏通篇不画线（行与行之间也没有），单给底栏来一条就成了整面唯一的
     一道横杠，比 ⊕ 本身还显眼。
  ② **「新建会话」不再用 `Color.accentColor`，改 `.primary`**。它是常驻的一行、
     天天在那儿，强调色会一直跳着抢注意力；字重 medium 已经足够把它和
     13 regular 的会话标题分开。hover 底色（`.primary.opacity(0.06)`）保留。
  顶部导读第 20 行同步改成「底栏「添加工作区」，不画分隔线」。
  热替换即时生效，截图 `.scratch/check-tweak.png`、`.scratch/check-bottom.png`。

- **实机反馈三条** · 2026-08-30 · `SidebarSearchField.swift` / `SidebarView.swift` /
  `SidebarFilter.swift` / `SidebarPlugin.swift` / `SidebarShortcuts.swift` / `Strings.swift`
  ① **搜索框改回 `.extraLarge`（36）**。计划 §2 M5 把它降到 `.large`（28），实机看高度
     不够——它是这面板上唯一的输入控件，28 在 32pt 的行列表上方压不住场。
     改的仍然只有 SwiftUI 侧那一行 `.controlSize`（`makeNSView` 里设会被每轮 update
     回写清掉，那条坑的注释原样留着）。
  ② **「新建会话」行高跟搜索框走 36，不跟会话行走 32**：两件头部控件上下紧邻，
     高度对不齐会看出一节台阶；它离最近的会话行还隔着一个分区头。图标与文字不放大，
     **不画常驻底**——那圈液态玻璃胶囊是"这里可以输入"的承诺，这一行不是输入框。
  ③ **筛选菜单新增「隐藏空工作区」，默认开**（`surf.sidebar.filter.hideEmptyWorkspaces`，
     没设过 = true，所以初始化要先问 `object(forKey:)` 在不在，`bool(forKey:)` 读不到
     时给的 false 正好是反的）。与「显示已归档」同一分区（都是"改变可见集合"的开关，
     先工作区层面再会话层面），带空组计数。**`isNarrowed` 不含它**——关掉它是"看到更多"
     而不是"筛掉"，所以单改它不会点亮「清除筛选」；而「清除筛选」的语义是回到默认，
     所以它把这一项恢复成 true（三个清除点都同步了）。
     **这条与仓库既有立场的关系要写明**：无条件滤掉空组曾被当成 bug 改掉（dsh 的
     `deriveGroups` 是 "Every group shows"），现在它是用户看得见、关得掉的显式筛选，
     可见集合由用户当场决定，不是我们背着人删东西。
  验收：`.scratch/check-4.png`（三条同时生效：搜索框 36、新建行 36 且是标签色、
  surf/dsh-mac 两个空组已收起）。菜单项本身没截到图——多显示器下 peekaboo 的
  按元素点击不稳（CLAUDE.md 记着这条），但开关的效果已在主界面确认。
  设计稿也同步到了实机形态（同一个 artifact 链接）。
