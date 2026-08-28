# 原生感升级计划（对照 webview-native-feel-playbook）

> 权威计划。输入是 `docs/webview-native-feel-playbook.md`（Raycast 2.1.0 逆向手册，
> 2026-08-28 从桌面拷入归档）。每完成一个里程碑在 §7 追加执行日志；
> 发现本文与源码冲突，以源码为准并就地更新本文。

## §0 立场（先读这个，它决定所有裁决）

1. **自然延伸 dsh，不另建主真相来源。** 主题、强调色、字体栈的权威都是 dsh；
   我们做投影与适配，不做第二偏好源。
2. **能用官方/系统原生渲染（含私有 API）就不手绘。** 本仓库不上架、ad-hoc 签名、
   部署目标 27.0，私有 API 无合规障碍；风险只剩 WebKit 升级改名，一律
   `CSS.supports` / `responds(to:)` 探测 + 保留现有手绘实现为降级路径。
3. **视觉拿不准就截图请用户裁决**，其余可逆决策自主推进。

## §1 本机验证过的事实（不是照抄手册）

| 事实 | 验证方式 | 对计划的影响 |
|---|---|---|
| `UseSystemAppearance` 私有 feature 存在（601 个 feature，默认关） | 附录 B 探测脚本在本机跑通 | P2 的开关有的放矢 |
| dsh 全局写死 `-webkit-font-smoothing: antialiased` | grep dsh-web-frontend 构建产物 | 字重偏细是 dsh 造成的，P1 必须覆盖回 `subpixel-antialiased` |
| dsh 字体栈是 `-apple-system` 系统栈（仅 KaTeX 是 web 字体） | 同上 | 手册 §3.2 的 40 条 Inter 光学字距表**不适用**，白捡 |
| 发送键 `_primary` 的底色走 `--dsw-alias-button-info-fill` → `--dsw-static-deepseek-500 #4176e6`（浅）/ `-400 #679efe`（深） | grep `dsh-client-ui-conversation` + `dsh-client-ui-theme` 的构建产物 | `_primary` 高光写死蓝色的死结可用相对颜色解（P1）。**不是 `--dsw-alias-button-primary-fill`**——那条走 `--dsw-alias-brand-primary` → `neutral-bluish`，浅色下是近黑的 `#0f1115`，发送键没在用它 |
| `--dsw-alias-label-primary` 存在且随主题翻面（浅 `#0f1115` / 深 `#f9fafb`） | 同上 | P1 的 `::selection` / `caret-color` 从它派生 |
| dsh 无 `color-scheme` / `caret-color` / `::selection`，滚动条仅两处局部样式 | 同上 | P1 的补课项不与 dsh 冲突 |
| 壳侧无 Inspector、无外观处理、无 document-start 注入、右键菜单未动 | 通读 clam-app/host/Sources | P2/P4/P5 的落点 |

现状两句话：clam-nativeify 在玻璃表面（8 层 box-shadow 几何衰减、四态矩阵）和字体
度量两个维度做到了极深，但手册里的其余「姿态」维度（smoothing/cursor/color-scheme/
selection/焦点环/降透明度适配）一条都没有；壳侧 WKWebView 只配了 6 行，
系统 NSAppearance 与 dsh `ui-theme` 是两套互不知情的主题源。

## §2 里程碑总表

| # | 名字 | 依赖 | 风险 | 一句话 |
|---|---|---|---|---|
| P1 | 姿态与文字补课 + bug 修 | 无 | 低 | 纯标准 CSS，全在 clam-nativeify/lib/client.js |
| P2 | 壳侧开关 + 真材质 spike | 无 | 低（开关有守卫） | 壳 3 行 + 可复跑 spike，产出四态对比截图 |
| P3 | 真材质接管玻璃表面 | P2 | 中（私有 API） | `@supports` 门控渐进增强，手绘栈降级保留 |
| P4 | 原生侧跟随 dsh 主题 | 无 | 中（新 swift 半边） | nativeify 长出 node 投影 + 薄 swift 半边 |
| P5 | 右键菜单薄版 | 无 | 低 | WKWebView 子类裁默认菜单 |

P1、P2、P5 相互独立可并行；P3 等 P2 的截图结论（拿不准就停下来给用户看）；
P4 独立于材质线。

## §3 里程碑详情

### P1 姿态与文字补课 + bug 修（clam-nativeify）

全部落在 `clam-nativeify/lib/client.js` 主 style（个别进字体 style），改完同步 README
（README 数值已多处与代码脱节，见下「顺手账」）。

1. **`html body { -webkit-font-smoothing: subpixel-antialiased; }`**——覆盖 dsh 的
   `antialiased`。实效是去掉「字变细」、与 AppKit 字重一致（Mojave 后系统全局灰度
   AA，`subpixel-antialiased` 实际渲染等同 auto）。注入顺序上我们的 style 晚于 dsh
   构建产物，同特异性后者胜，核实后**不加** `!important`（README 的既定纪律：核实
   存在后不留 fallback，同理不留保险）。
2. **cursor 姿态**：`body { cursor: default }`；已有的可选中白名单
   （`_flowItem` / `_contentColumn` / pre / code / input / textarea /
   contenteditable）补 `cursor: text`（输入类控件浏览器默认即 text，只补内容区）。
3. **`color-scheme`**：`html:has(body[data-ds-dark-theme]) { color-scheme: dark }`、
   else light。让 UA 层（表单控件、原生滚动条、默认 `::selection` 底色）跟着 dsh
   主题翻面，而不是跟系统。
4. **`::selection` / `caret-color`**：手册配方是从前景派生——
   `::selection { background: rgb(from var(--dsw-alias-label-primary) r g b / 20%) }`、
   `input, textarea { caret-color: var(--dsw-alias-label-primary) }`（token 名先
   核实存在，README 纪律）。
5. **`_primary` 高光解死结**：`--clam-glass-glow-c` 眼下写死 `0 192 255` / `0 203 255`
   （dsh 换主题色会偏色，README 自认）。**动手时核出计划这条写错了 token**：发送键
   的底色是 `--dsw-alias-button-info-fill`（`#4176e6` / `#679efe`），不是
   `--dsw-alias-button-primary-fill`（那条是近黑的 neutral-bluish）——也就是说写死的
   青色**今天就已经偏色**，不是将来才会踩的隐患。
   做法：`--clam-glass-glow-c` 从「通道三元组」改成普通 `<color>` 并 `@property`
   注册（`inherits: true`，initial `#fff`，失效即退回白 = 无色玻璃高光），发光层写
   `rgb(from var(--clam-glass-glow-c) r g b / calc(…))`；`_primary` 那条派生成
   `oklch(from var(--dsw-alias-button-info-fill) calc(l + 0.12) c h)`。
   `+0.12` 由系统实测反推（蓝浅 L .646→.765、蓝深 .673→.792，两组都是 +0.12），
   并顺带解释了「R 通道恒为 0」：抬亮后彩度出域，CSS 色域映射沿 OKLCh 收彩度、
   落在 R=0 那面边界。峰值/衰减两个旋钮不变；**深色档那行常量删掉**——dsh 的 token
   自己翻面，派生式跟着翻。
6. **按压时序**：手册量的原生行为是「按下即时、松开缓动」——按下态
   `transition-duration: 0s`（现在是 90ms），松开沿用 `--clam-dur-fast`。
   `--clam-dur-press` 变量随之退休或归零。
7. **`prefers-reduced-transparency`**：`@media (prefers-reduced-transparency: reduce)`
   里关 `backdrop-filter`、把 `--clam-glass-fill` 提到不透明近似色。
   四态变量结构不动，只在媒体查询里覆写。
8. **bug 修：`watchWindowFocus` 的 HMR 实例守卫**。cleanup 现在无条件
   `removeAttribute("data-clam-blur"/"data-clam-nofx")`，撞 CLAUDE.md 记过的
   「新实例先启、旧实例后清」坑（字体 style 那处已有 `fontStyle === style` 守卫，
   这处漏了）。照 clam-layout 的 makeToken 思路：属性值写实例 token，cleanup 只清
   token 对得上的。
9. **顺手账（README 修正）**：发光表 peak/decay 数值、左右阴影 12→14px、
   「五个按钮」实为 6 条选择器、README:5 声称包内有 `cordis.patch.yml`（实在伞包）。

**明确不做**：letter-spacing 表（系统字体栈自带光学字距）；`:focus-visible` 焦点环
（dsh 有无自己的 focus 样式未核实，单列成 backlog 待查）；滚动条隐藏+自绘（backlog，
dsh 已有局部样式、回归面大）。

**验收**：`tools/dump-css.mjs` 括号平衡；`./dev` 起真 App 后 `tools/shot.sh` 截
浅/深 × 激活/失活四张；普通浏览器打开 dsh 确认零影响（UA 门控本就挡着，но
color-scheme 等新规则都在门控内）。

### P2 壳侧开关 + 真材质 spike

**壳（`clam-app/host/Sources/MainWindowController.swift` webView 懒加载处）**：

1. `#if DEBUG` 下 `wv.isInspectable = true`——现在 Inspector 完全开不出来，调材质必备。
2. 开系统外观私有开关，带守卫：
   ```swift
   let prefs = config.preferences
   if prefs.responds(to: NSSelectorFromString("_setUseSystemAppearance:")) {
       prefs.setValue(true, forKey: "useSystemAppearance")
   }
   ```
   守卫失败即静默不开——页面侧 `@supports` 探测本来就兜底，两层各自独立降级。
3. 同样带守卫地关 `shouldAllowUserInstalledFonts`（用户自装字体不污染渲染）。

**spike（`docs/spikes/apple-visual-effect/`，可复跑）**，回答三个手册没答的问题：

- **不透明窗口里 glass material 采样什么？** 我们窗口 `isOpaque=true`（Raycast 透明）。
  预期采样身后页面内容（对胶囊控件正是想要的），但必须实测。
- **开关对 dsh 页面其余渲染有无副作用？** 全页走查一遍（表单、代码块、图片）。
- **失活时材质自己会不会变哑光？** 从 Raycast 手工复刻失焦态推断不会，
  需确认——决定 P3 的失活态方案。

方法：`isInspectable` 开着，在 Inspector 里对 neutral 组任一按钮手工换
`-apple-visual-effect: -apple-system-glass-material-media-controls`（以及
`-subdued`、`-apple-system-glass-material` 各试），`tools/shot.sh` 截四态对比图
（手绘版 vs 材质版并排）。spike 目录里落一份最小 HTML + 结论 README。

**产出即停点**：对比截图交给用户看（立场 §0.3）。用户裁决前 P3 不动工。

### P3 真材质接管玻璃表面（gate on P2 + 用户裁决）

结构（方向，细节按 P2 结论定）：

- 主 style 里加 `@supports (-apple-visual-effect: -apple-system-glass-material-media-controls)`
  块，块内对 neutral 组：`backdrop-filter` + `--clam-glass-fill` 让位给材质；
  8 层发光/描边/侧影按对比结论裁——材质自带高光描边就整层退休，
  只保留 hover/press 的 tint 与按压径向光。
- `_primary`（实色）不上材质，维持 P1 后的相对颜色高光。
- **失活态**：沿用 `data-clam-blur` 切换——blur 时 `-apple-visual-effect: none`
  并回落到现有失活 3 层（Raycast 同款做法）；若 P2 发现 `-subdued` 更像系统失活，
  用它。
- 手绘四态栈**原样保留**在 `@supports` 块外，是普通浏览器与未开开关时的降级路径。
- 玻璃不嵌套（HIG + Raycast 实测：材质套材质出伪影）——我们的按钮都直接浮在
  页面上，天然满足，写进注释即可。
- 可选：按钮文字 `-apple-visual-effect: -apple-system-vibrancy-label`（dsh 控制
  文字颜色，覆盖前截图比对，拿不准就不做）。

**验收**：四态截图 vs P2 对比图一致；关掉开关（或普通浏览器）走降级路径截图
确认手绘栈完好；`prefers-reduced-transparency` 下材质也退（媒体查询在
`@supports` 块内同样生效，需覆写）。

### P4 原生侧跟随 dsh 主题

缺口：系统 NSAppearance 与 dsh `ui-theme` 互不知情——dsh 设 light + 系统 dark 时
原生侧边栏/工具栏深、网页正文浅，一眼穿帮；窗口 `backgroundColor` 跟系统而非 dsh
主题，首帧与 resize 露底闪错色。

**方向（立场 §0.1）**：dsh `ui-theme` 是权威，原生侧跟随。

**归属**：clam-nativeify——「摸起来像原生」正是它的宪章，缺席即回到现状（两套
主题源各行其是），符合「缺席即退化」。代价是它不再纯 CSS：长出 swift 半边。

- **node 半边**（lib/index.js）：运行时嵌套 inject 订 dsh 的 `ui-theme` 设置，
  经 `createSwiftPlugin`（clam-bridge 的 `./plugin` 出口）投影
  `{ theme: "light"|"dark"|"system", bgBase: { light, dark } }`。设置服务缺席时
  不投影 = swift 半边保持系统外观，无害降级。
  **动手时核出的权威坐标**（`@deepseek-ai/dsh-client-ui-theme/lib/index.js`）：
  ns `ui-theme`、键 `preference`、值 `light|dark|system`、默认 `system`；
  clam-settings 通用页读的是同一处（`swift/SettingsTabs.swift` 的 `GeneralRow`）。
  **只读不注册**（ns 的主人是那个插件），因而拿不到 `SettingsScope`：读走
  `ctx.get("settings")?.get(ns)`，变化订全局 `settings/updated` 按 ns 过滤。
  另：`settings/updated` 只在变化时发，而 `ui-theme` 的注册与我们的挂载没有先后
  保证——所以还要一条「Swift 每代 activate 问一次、node 现读现推」，否则
  "挂载时读不到 + 用户不动设置" 这一格永远投不出去。
- **swift 半边**（新增 swift/）：收投影设
  `NSApp.appearance = nil | NSAppearance(named: .aqua / .darkAqua)`；同时把
  `window.backgroundColor` 设成 dsh 主题 base 底色（深色 `#1E1E1E`，与 client.js
  写死的 `--dsw-alias-bg-base` 同源，投影里带值不再两处写死），消首帧闪色。
  注意「不占槽的插件没有生命周期锚」坑：`activate` 返回持有者对象；
  「清理别挂析构」坑:appearance 是进程级状态,新一代 activate 时按投影重设即可,
  换代天然收敛。
- ~~**顺手（可选子项）**：swift 半边订 `didBecomeKey/didResignKey`，把窗口 key 态
  打到页面供 `data-clam-blur` 用。~~ **已砍**（理由见 §7 的 P4 条第 4 点）：
  `data-clam-blur` 归 client.js 的 `watchWindowFocus` 用实例 token 管着（P1 第 8 项
  刚修的 HMR 坑），再开一条壳侧写入路径就是两个写者共用一个属性——要么把 token
  送出页面（契约变重），要么"壳到了就以壳为准"（token 语义破掉，坑原样回来）。
  而收益只是把 `document.hasFocus()` 换成语义更准的窗口 key 态，今天的行为已经对。

**验收**：dsh 设 dark + 系统 light（及反向）各截一张——侧边栏、工具栏、正文
同色温；设置滑到 `system` 跟系统翻面；杀掉 nativeify（从 patch 表摘行）回现状。

### P5 右键菜单薄版

现状 WebKit 默认菜单带 Reload / Back 这类穿帮项。做薄版：

- 新建 `WKWebView` 薄子类（落点 `Native/`），覆写 `willOpenMenu(_:with:)` 按
  `NSMenuItem.identifier`（`WKMenuItemIdentifier*`）白名单裁项：保留
  Copy / Look Up / Translate / Services / Share / Inspect Element（Debug），
  裁掉 Reload、Back/Forward、Open Link in New Window 类导航项。
- `MainWindowController.swift` 创建处换用子类，一行。
- 全版（`contextmenu → NSMenu` 桥、真 Services/Share 注入 web 元素）进 backlog——
  dsh 页内右键需求少，薄版已消穿帮。

**验收**：正文/链接/选中文字/输入框四种右键各弹一次，无导航类穿帮项，
复制粘贴查词照常。

## §4 明确不采纳（手册条目 → 理由）

| 手册条目 | 理由 |
|---|---|
| 透明窗口 + 桌面采样（§1.2） | 文档型 app，内容不透明，无收益；牵动整条背景链 |
| `NSThemeFrame` 圆角 swizzle（§1.3） | 标准 titled 窗口默认圆角就是对的 |
| `window.open` 劫持成原生弹层架构（§2.1） | 我们的路线更激进：整面 UI 原生化（sidebar/header/settings 已是真 AppKit）；dsh 页内小弹层随 dsh |
| `ipc://` 图像 scheme（§2.4） | 聊天内容无 app 图标/QuickLook 需求 |
| 键盘布局推送 / ⌘⌘ / 强制 ASCII（§2.5） | 无全局快捷键录制场景 |
| 预热窗口 / 禁 App Nap / 禁定时器节流（§1.4） | 常驻窗口非呼出型；后台节流反而省电 |
| `--spx` / `round()` 全站 token（§3.1） | 设计系统归 dsh，不归我们；自家注入值本就整数 px |
| Inter 光学字距表（§3.2） | dsh 是系统字体栈，SF 自带光学字距 |
| 拖拽改 `data-draggable-region` 桥（§2.2） | 标题栏是原生 toolbar，`installTitlebarDrag` 已解决 |

**Backlog**（不进本期，条件成熟再议）：滚动条全隐藏+自绘 overlay；右键菜单全版
NSMenu 桥；`:focus-visible` 焦点环（先核实 dsh 自己的 focus 样式）；
`text-box: trim-both` 行盒对齐。

## §5 风险

- **私有 API 漂移**（P2/P3）：WebKit 升级可能改名 `UseSystemAppearance` /
  `-apple-visual-effect` 值。两层探测（swift `responds(to:)` + CSS `@supports`）
  各自静默降级到手绘栈，失效方向安全。dsh 钉版本、macOS 大版本升级前跑一次
  spike 目录即可回归。
- **`color-scheme` 翻面副作用**（P1）：UA 层控件换肤可能与 dsh 自绘控件混搭出
  不协调，截图走查表单区。
- **nativeify 身份变化**（P4）：从「纯 CSS 免构建」变成三半边插件。CLAUDE.md
  的插件简介要同步改口。
- **README/代码脱节**是本包已有病灶，P1 顺手修一轮，后续改动带上 README。

## §6 验证方法（通用）

- `./dev` 起真 App；改 swift 存盘热替换 1~3s，改 client.js HMR ~0.5s。
- `tools/shot.sh` 截图（失活态用 `--app <pid>` 点别的窗口再截；注意「遮挡窗口
  返回陈旧帧」坑，先改个可见值验新鲜度）。
- `clam-nativeify/tools/dump-css.mjs` 验 CSS 括号/前缀。
- 每条视觉改动做对照组：关掉修复截一张（CLAUDE.md 纪律）。
- 拿不准的视觉差异：并排截图停下来给用户看。

## §7 执行日志

- 2026-08-28 计划定稿。立场三条由用户定调（跟随 dsh / 优先原生渲染 / 截图裁决）。
- 2026-08-28 **P2 完成**（壳侧开关 + spike）。壳：`MainWindowController` 的 webView
  懒加载处加 `#if DEBUG isInspectable`，并抽出 `applyAppearancePreferences(_:)`
  带 `responds(to:)` 守卫开 `useSystemAppearance`、关
  `shouldAllowUserInstalledFonts`（WKPreferences 无公开 API，SDK 头文件里没有，
  只有 tbd 的私有符号，所以走 KVC；两个 selector 本机实测都 responds）。
  spike 在 `docs/spikes/apple-visual-effect/`，三个问题的答案：
  ① **不透明窗口里材质照常采样身后的页面内容**（不是黑块）——透明窗口不是前提，
  P3 可以走；② `CSS.supports` 干脆翻转（关掉时九个值全 false、材质层什么都不画），
  **但 `-apple-system-*` 颜色关键字不受这个开关管**（手册 §1.1 那句在本机不成立），
  对 P4 是白捡；③ **失活时材质自己一个像素都不变**（两张图取样值逐位相同），
  所以 P3 的 `data-clam-blur` → `-apple-visual-effect: none` 回落是必需项而非优化，
  且 `-subdued` 与 `media-controls` 只差几个色阶、不足以表达失活。
  **"开关对 dsh 页面其余渲染有无副作用"没答**——spike 是自造静态页，
  待 `./dev` 起真 App 走查表单/代码块/图片。**P3 仍等用户看过对比截图再动工。**
- 2026-08-28 **P5 完成**（右键菜单薄版）。新增
  `clam-app/host/Sources/Native/ClamWebView.swift`，覆写 `willOpenMenu` 裁掉
  Reload / GoBack / GoForward / Open*InNewWindow 七项，其余（含 identifier 为
  nil 的）一律保留——**黑名单而非白名单，失效方向才安全**。
  identifier 字面量从真菜单转储里读回来（spike 的 `CLAM_SPIKE_DUMP_MENU`），
  因为这些常量没有公开头文件、`dlsym` 也取不到。三条实测：Services / Ask Siri
  是 AppKit 在 `willOpenMenu` **之后**自己加的（不经我们的手）；AppKit 会自己
  折叠连续分隔符（我们仍收一轮，为的是行首那种没验过的情形）；**把菜单裁空不会
  露出空框**，所以 Release 下空白处右键什么都不弹，正是原生行为。
- 2026-08-28 **P1 完成**（`clam-nativeify/lib/client.js` + `tools/dump-css.mjs` +
  README）。9 个条目全做，另有三处偏离/顺手，都已就地更新本文与 README：
  1. 计划第 5 项的 token 名写错了：发送键走 `--dsw-alias-button-info-fill` 而不是
     `--dsw-alias-button-primary-fill`（源码为准，§1 与 §3 已改）。
  2. **`tools/dump-css.mjs` 在 P1 之前就是坏的**，两处：① `ctx.inject` 不在桩里，
     `apply()` 最后一行必抛 TypeError、脚本 exit 1（"验收：dump-css 括号平衡"这条
     此前根本跑不通）；② 桩把 `textContent` 存进一个标量，后写的字体 style 把主样式
     整个盖掉，dump 出来只有 6 条规则、却照常打印"括号配对正确"——**校验器在假绿**。
     两处都修了（外加 `getAttribute`，第 8 项的 token 守卫要读）。现在 417 行 45 条规则。
  3. 第 9 项「顺手账」多修了两处同源脱节：README 的发光旋钮表（`.55/.012/.025` →
     定稿的 `.795/.06`）连带下面那段"深色上下不等强、现在恢复了"的叙述（代码里早已
     眼调回等强）；client.js 里"那五个按钮"的同一处笔误。
  未做：`caret-color` 一条在多数输入框里是 no-op（`auto` = currentColor 已经对了），
  仍然按计划加了——理由写在代码注释里（dsh 有几处输入框把 color 调淡）。
  视觉验收（四态截图 + 普通浏览器零影响）交由用户跑真 App。
- 2026-08-28 **P4 完成**（原生侧跟随 dsh 主题）。clam-nativeify 从"双半边"长成
  **三半边**：`lib/index.js` 改用 `createSwiftPlugin` 登记新增的 `swift/` 载荷，
  新增 `swift/NativeifyPlugin.swift`（不占槽、不贡献界面，`activate` 返回 follower
  当锚），配套改 `package.json`（`files` 加 `swift`）、伞包编排表那行的注释、
  CLAUDE.md 的插件简介、根 README、本包 README（新增「原生侧跟随 dsh 主题」一节）。
  **`ui-theme` 的权威读法**（核实自 `@deepseek-ai/dsh-client-ui-theme/lib/index.js`
  与 `clam-settings/swift/SettingsTabs.swift`）：ns `ui-theme` / 键 `preference` /
  值 `light|dark|system`（默认 `system`）。我们**只读不注册**——ns 的主人是那个插件，
  重复 register 会 fail loud；非 owner 也拿不到 `SettingsScope`（那是 register 的
  返回值），所以变化订全局 `settings/updated` 按 ns 过滤，读走 `ctx.get("settings")
  ?.get("ui-theme")`（正是 dsh 自己 `readPreference(ctx)` 的写法）。
  四处偏离/补充：
  1. **计划说"就绪即投影"不够**——`ui-theme` 是别的插件在它自己的
     `inject(["settings"])` 里注册的，与我们的挂载无先后保证；挂载那一刻读完全
     可能读到"尚未注册"，而 `settings/updated` **只在变化时发**，用户不动设置就
     永远等不到。补法照 clam-notify 的纪律：Swift 每代 activate 发一个 `theme`
     动作，node 现读现推。壳的 activate 远晚于插件树挂载完，那一刻必然读得到。
  2. **`bgBase` 的浅色值不是 dsh 的原值。** 深色 dsh 自己是 `#151517`
     （`--dsw-static-neutral-bluish-950`），而 client.js 早就把 `--dsw-alias-bg-base`
     重映射成了 `#1E1E1E`；窗口要跟的是页面**实际画出来的**那个色，所以投影里
     写的是我们的覆盖值。浅色 `#FFFFFF`（`neutral-bluish-00`，我们没覆盖）。
     两处同源，README 里记了"改一处必须改另一处"。
  3. 窗口底色做成 `NSColor(name:dynamicProvider:)` 的**动态色**，`system` 档下
     系统翻面它自己跟着翻，省掉一条 `AppleInterfaceThemeChangedNotification`
     或 `effectiveAppearance` KVO。刷色目标窗口的判据是「装着壳那个 WebView」
     而不是 `NSApp.mainWindow`（后者在 clam-settings 开窗时会指过去）。
  4. **可选子项（窗口 key 态经壳打到页面）砍掉。** 理由是协调不干净：
     `data-clam-blur` 现在由 client.js 的 `watchWindowFocus` 用**实例 token**
     管着（P1 第 8 项刚修的 HMR 坑），再开一条壳侧写入路径就是两个写者共用一个
     属性——要么壳侧也得懂 token（把 token 送出页面，契约立刻变重），要么改成
     "壳到了就以壳为准"（token 语义破掉，HMR 坑原样回来）。收益又只是把
     `document.hasFocus()` 换成语义更准的窗口 key 态，而 WKWebView 本来就把承载
     窗口的激活/失活映射成页面 focus/blur——今天的行为已经对。client.js 里那段
     "刻意不走让壳注入那条路、零依赖"的注释因此原样保留，没有自相矛盾。
  验证：`node --check` 过；Swift 用真 ClamSDK 全量类型检查过
  （`swiftc -typecheck -I clam-app/host/build-sdk -target arm64-apple-macos27.0`）。
  **留给真 App 的**：dsh 设 dark + 系统 light（及反向）各截一张看侧边栏/工具栏/正文
  同色温；滑到 `system` 跟系统翻面；resize 与冷启动首帧不闪底色；clam-settings
  那扇窗没被刷成页面底色。
