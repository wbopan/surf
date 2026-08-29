# web header 贴合 macOS 27 工具栏——计划

> 2026-08-29。clam-header（原生重画）已在编排表里停用，主内容区回到 dsh 自己的 web header。
> 本计划不再重做原生，而是**只用 CSS** 把 web header 调到 Apple 官方工具栏的几何、字体与控件形态。
> 官方数值全部来自 Apple 的 macOS 27 UI Kit（Sketch 版，`.scratch/apple-design/`，`lookup.py` 可查），
> 现状数值来自 dsh 0.1.1-rc.2 的 CSS 源码与运行中 App 的截图。设计稿见本文末尾的画布链接。

## 0. 为什么走 CSS 而不是原生

- 原生重画（clam-header）要自己复刻 dsh header 的**全部内容**——面包屑、子代理目录、preset、后台任务、导出——
  内容一变就漂移、一升级就过时。CSS 只改**形**，内容和行为仍归 dsh。
- 页面里已经能画出接近原生的质感：clam-nativeify 的玻璃胶囊四态（浅/深 × 激活/失活）、
  `-apple-visual-effect` 真材质（`docs/spikes/apple-visual-effect/`）。剩下的差距是几何与字体，正是 CSS 的事。
- 判据不变：**圆胶囊是"可操作"的承诺**。不可点的东西（锁定的 preset）退成副标题，不做假按钮。

## 1. 现状 vs 目标（数值）

坐标以内容区左上角为原点，pt。现状来自 `dsh-client-ui-conversation/lib/client.js:7118` 的 CSS 与截图；
目标来自套件 `Windows/Light/Unified Toolbar + Title + Sidebar/Active → Right Pane/Titlebar and Toolbar`。

| 项 | 现状（web header） | Apple（Unified Toolbar + Title） |
|---|---|---|
| 栏高 | **76**（44 标题行 + 32 标签行），底边 1px 线 | **52**，无线；内容从底下穿过，边缘效果由 Scroll Edge Effect 承担 |
| 垂直节奏 | `padding-top: 12`，标题行 `min-height: 32`，标签 `margin-top: 4`、`padding-bottom: 11` | 项高 36，上下各 **8**；标题/副标题叠 30 高、顶部 11 |
| 左右边距 | `padding: 12px 28px 0 20px`（左 20 + 面包屑自带 8 = 文字 28） | 首项 x=8，末项右侧留 8；标题紧跟前一项 8 |
| 标题 | 面包屑按钮：14px/20px，weight 500，`label-primary` | **SF Pro Bold 15**，`rgb(54,54,54)`（Labels/Light Vibrant/1 Primary） |
| 副标题 | 无；preset 是 12px 灰 `<span>`（填充 token 未定义，实际透明） | **SF Pro Medium 11**，`rgb(178,178,178)`，紧贴标题下方 2pt |
| 视图切换 | 下划线 tab：13px/16px，gap 36，2px 蓝线 | **分段控件 75×36** 玻璃胶囊；每段 32×28，选中底 `rgba(0,0,0,.07)` r=? 内缩 4；分隔 1×16 `rgba(0,0,0,.05)`；符号 SF Pro Medium 13 |
| 子代理 / 后台任务 | 无边框触发器 min-height 28，12px | **下拉胶囊 50×36**：符号 Medium 13 + 角标 + chevron Bold 13 |
| 导出 | 描边药丸 111×32，r=18，13px 文字 "Session log" | **图标按钮 36×36**（`square.and.arrow.down`，Medium 13），文字进 tooltip |
| 材质 | 白底 + 1px `border-l2` 线 | 胶囊 = Liquid Glass/Regular-Small；栏 = Scroll Edge Effect Hard（底色 + 0.67px `rgba(0,0,0,.05)` 底边） |
| 项间距 | actions gap 8，utilities `margin-left: 20` | **8** 一律 |

紧凑模式（Unified Compact，40 高、项 24×24、符号 10pt）也在套件里，但壳的原生侧
（侧边栏那半）此刻是 52pt 标准模式，右半必须同高，**不考虑紧凑**。

## 2. 目标规格（一句话：一行 52pt，标题叠副标题在左，三枚胶囊在右）

```
x:  16 ─ 标题簇（自适应）── … 弹性 … ──[对话|轨迹]─8─[⌘ 2 ▾]─8─[⬇]─ 8
y:  ┌──────────────────────────────────────────────────────────────┐ 0
    │  hi                                 ┌───────┐ ┌──────┐ ┌──┐ │ 8
    │  标准模式 · 3 个子代理               │对话|轨迹│ │◎ 2 ▾ │ │⬇ │ │
    │                                     └───────┘ └──────┘ └──┘ │ 44
    └──────────────────────────────────────────────────────────────┘ 52
```

### 2.1 几何

- `header`：`height: 52px; padding: 8px 8px 8px 16px; display: grid`（见 §3.3 的 grid 方案），
  底边线去掉（`::after` 隐藏），背景见 §2.4。
- 标题簇：两行叠放，整体垂直居中（Apple：30 高、y=11）。只有标题时单行居中（y=18.5）。
- 三枚胶囊：高 36，垂直居中，间距 8，右缘留 8。

### 2.2 字体（都是 `-apple-system`，页面已是；行高按 clam-nativeify 的原生度量表）

| 角色 | 规格 |
|---|---|
| 标题 | 15px / 600（AppKit 的 Bold 标题在 web 里用 600 更接近 `.headline` 度量；700 偏重，落地时截图比） |
| 副标题 | 11px / 500，颜色 `rgb(178,178,178)` 浅色 / `rgb(138,138,138)` 深色（Labels/Dark Vibrant/2 Secondary） |
| 胶囊文字/符号 | 13px / 500 |
| 角标数字 | 11px / 600 |

标题颜色：浅色 `rgb(54,54,54)`；深色 `rgba(255,255,255,.96)`（Labels/Dark Vibrant/1 Primary）。
不用 dsh 的 `label-primary`（`#0f1115`）——那是正文黑，工具栏标题在 Apple 那里是 vibrant 深灰。

### 2.3 控件

- **分段控件**（视图切换）：容器 = 玻璃胶囊（r=18），内 padding 4；段 = 28 高、水平 padding 10、r=14，
  文字 13/500；选中段底 `rgba(0,0,0,.07)`（深色 `rgba(255,255,255,.08)`）；段间 1px 分隔
  `rgba(0,0,0,.05)`，**选中段两侧不画分隔**（Apple 的分隔只在两个未选段之间）。
  文字色：未选 `rgb(54,54,54)`，选中同色（Apple 的工具栏段控不用强调色，靠底板区分；
  dsh 现在的蓝色 `state-business-primary` 去掉）。
- **子代理**（lineage 槽）：下拉胶囊 = 符号 + 计数 + `chevron.down`；有计数时才显示（现状即如此）。
- **后台任务**（jobs）：同上形态；0 个任务时隐藏（现状即如此）。
- **导出**：36×36 图标按钮，文字 `Session log` 用 CSS 收成 0 宽（`font-size:0` 保留在 AX 树里做 tooltip/label），
  只留图标。图标 = 现有 SVG，尺寸拉到 16。
- **preset**：不再是胶囊，退成副标题第一段，保留 preset 自己的图标（11px，随副标题灰）——
  这是 web header，不受原生 `window.subtitle` 塞不进图标那条限制；若同时有子代理，副标题 = `标准模式 · 3 个子代理`？
  **不要**——子代理已经是可点的胶囊，副标题只放 preset；没有 preset 时副标题行整个消失。
- 面包屑（子代理会话里的父级链）：保留文字形态，13px，父级可点（现状），`/` 分隔改成 `chevron.right` 9px。

### 2.4 材质与状态

- 胶囊复用 clam-nativeify 现成的 `--clam-glass-*` 四态（浅/深 × 窗口激活/失活 + 减少透明度回退），
  不另起一套。段控容器与下拉胶囊只是把 `_tabs` / `_trigger` / `_switcherTrigger` 加入玻璃白名单
  （`SOLID_BORDERED`），选中段自己画底。
- 栏背景：**第一步不动**（白底），只把底边线去掉——在纯白内容上和 Apple 的 Hard 边缘效果几乎一样。
  滚动穿透（§3.5）留到最后一步。
- 窗口失活：标题 `rgb(178,178,178)`，胶囊走现有失活态（`[data-clam-blur]`）。

## 3. 实施步骤

### 3.0 前提：壳的拖动条会吃掉 y<40 的点击

`clam-app/host/Sources/MainWindowController.swift:258-270`：`WindowDragRegionView`（40pt）
`addSubview` 在 root 之上、铺满容器宽、不覆写 `hitTest`。它压在 WKWebView 上，
**web 内容顶部 40pt 里的 mouseDown 全部变成拖窗**。现状能活是因为那 40pt 里只有一个
disabled 的面包屑和一个 span；"Session log" 按钮只有下半截（40–54）可点，没人注意到。
新 header 的三枚胶囊在 y=8–44，不解决这条就是三枚假按钮。

方案（壳侧 ~30 行 + client 侧 ~20 行）：
1. client 半边用 `ResizeObserver` + `MutationObserver` 收集 header 里可交互元素
   （`button, [role=tab], [role=button], a`）的 `getBoundingClientRect()`，经页内桥
   `postMessage({type:"dragPassthrough", rects:[...]})` 上报（页内桥不设白名单，
   自动广播成 `clam.page.dragPassthrough`）。壳把最新一份存进 `ClamEventBus.emitSticky`。
2. `WindowDragRegionView.hitTest(_:)`：点落在任一 rect 内就 `return nil`（放行给 WebView），
   否则 `self`。坐标：页面 CSS px → 窗口 pt 需要加上 WebView 在容器里的 x 偏移
   （分栏宽度），壳从 `webView.frame` 取，client 不必知道侧边栏宽。
3. 双击标题空地放大、单击空地拖窗照旧。

替代方案（不改壳）：把拖动条降到 8pt 高只盖上边距——不行，胶囊之间的空地也该能拖，
而且 8pt 抓不住。**先做 3.0，再做别的。**

验证：`peekaboo see --pid <pid> --tree` 拿到段控的 `elem_N`，`click --on` 后截图看选中态是否切换。

### 3.1 几何（一行 52，一次到位）

落在 `clam-nativeify/lib/client.js`（新增一段 `HEADER`，与现有玻璃段同一个 `<style>`）。
选择器一律 `[data-slot="conversation.session.header"] > header` 打头，类名用
`[class*="_titleRow"]` 这种语义后缀（hash 前缀会变）。

关键一招：`_titleRow`、`_titleCluster`、`_headerActions` 三层容器全部 `display: contents`，
让 `header` 直接看到六个孩子（面包屑 nav、lineage 槽内容、preset span、jobs 触发器、
utilities div、tablist），然后用 **grid** 排：

```
grid-template-columns: auto 1fr auto auto auto;   /* 标题 | 弹性 | 段控 | 子代理/任务 | 导出 */
grid-template-rows: auto auto;                     /* 标题 | 副标题 */
align-content: center;
nav(面包屑)         → 1/1
preset span         → 2/1        （变副标题）
tablist             → 1/3 span 2 （order 由 grid-column 决定，DOM 顺序无关）
lineage、jobs       → 1/4 span 2 （两者并列时用一个 `display:flex; gap:8px` 的隐式行——
                                  它们不同父，做不到；退而求其次：lineage 4 列，jobs 5 列，导出 6 列）
utilities           → 最后一列 span 2
```

`display: contents` 对 `_titleRow` 的副作用：它自己的 `min-height: 32` 与 `gap` 失效——正是想要的。
lineage 槽的 outlet 本来就是 `display: contents`，不用碰。

### 3.2 字体与颜色

按 §2.2 覆盖 `_crumb` / `_crumbCurrent` / `SVAs4q_label`（preset）/ `_tab` 的
`font-size` / `line-height` / `font-weight` / `color`。这些在 dsh 里是**硬编码 px 不是 token**，
clam-nativeify 现有的字号层（`typeTokens()`）够不着它们，必须逐条覆盖。

### 3.3 控件形态

- tablist → 分段控件：`_tabs` 进玻璃白名单当容器；`_tab` 去下划线（`::after` 隐藏）、
  `padding: 0 10px; height: 28px; border-radius: 14px`；`_tabActive` 画选中底；
  分隔线用 `_tab + _tab::before`，`aria-selected=true` 的段及其后一个段不画。
- lineage / jobs 触发器：进玻璃白名单，`height: 36; padding: 0 10px 0 8px; border-radius: 18px`；
  chevron 若现 DOM 没有就用 `::after` 画一个 6×6 的 mask（`-webkit-mask` 内嵌 SVG）。
- 导出按钮：`width: 36; min-width: 0; padding: 0; border-radius: 18`，文字 `font-size: 0`。
  它已在白名单里（`button[class*="_sessionLogButton"]`），只改几何。

### 3.4 状态

复用现有 `--clam-tint-hover` / `--clam-tint-press`；段控选中底在深色/失活/减少透明度下各给一值。
窗口失活标题变灰：`:root[data-clam-blur]` 下覆盖标题色。

### 3.5 （最后、可选）滚动穿透

把 header 从文档流拿出来：`position: absolute; top: 0; left: 0; right: 0; z-index: 10`，
`[data-conversation-scroll] { padding-top: 52px }`（只改滚动起点，不 inset 内容——
`docs/native-header-plan.md` §6.5 的裁定沿用），背景 = `bg-base` 55% + `backdrop-filter: blur(8px) saturate(180%)`
（clam-header client 半边那条带子的配方原样搬来，`:269-292`），底边 1px `rgba(0,0,0,.05)`。
套件的 Hard 风格是**纯色**；Soft（渐变糊）是 Safari 专用 SPI，页面里 backdrop-filter 就是最接近的。
风险：内容穿过时 header 上的胶囊与文字要保证对比度——胶囊有玻璃底没问题，标题需要
`text-shadow: 0 0 8px var(--bg)` 之类兜底；做完截图看长回复滚过标题时的可读性再决定留不留。

## 4. 验收

1. `peekaboo see --pid <pid> --no-elements --path .scratch/header-after.png`，与 `.scratch/header-before.png` 并排。
2. 量：header 底 = 52；胶囊 36 高、顶 8；标题 cap 高与原生侧边栏那两枚 36 胶囊的中线对齐
   （两半共用一条 y=26 的中线，这是最直观的"像不像"判据）。
3. 深色（dsh 设置里切）、窗口失活（点别的窗口再截）、减少透明度（系统设置）各截一张。
4. 点击：段控两段、子代理菜单、导出（会真的下载，最后测）——都在 y<40 区域，验证 §3.0。
5. AX：`peekaboo see --tree` 里导出按钮仍有可读 label（`font-size:0` 不能让它从 AX 树里消失）。

## 5. 已知坑与假设

- **标题起点 16pt 是假设**。套件里标题总是跟在一个前导项后面（8 间距）；没有前导项时 Apple 自己的
  App（Mail/Notes）里标题离分隔线多远，落地时开一个 Mail 量一下再定。
- `display: contents` 会让容器从 AX 树里消失——这三层本来就是纯布局 div，无 role，无损。
  但 `_headerActions` 若哪天被 dsh 加了 role 就要换方案。
- dsh 的 `_tab` 没有 `data-view`，只有本地化文案和 `aria-selected`——CSS 只认 `aria-selected`，够用。
- preset 的填充 token `--dsw-alias-fill-tsp-secondary` 在 dsh 里**从未定义**，现状实际透明；
  改成副标题后无所谓，但别去"修"它。
- 胶囊落在 y<40 的拖动条里——§3.0 不做，一切白搭。这是全计划唯一要动壳的地方（重建 + 重启一次）。
- 玻璃胶囊压在纯白上几乎看不见边（真原生也是这样）；别为了"看得见"加重描边。

## 6. 执行日志

- 2026-08-29：计划成文；套件数值抠取（`.scratch/apple-design/lookup.py`）；设计稿画布
  https://claude.ai/code/artifact/b9a465e2-7a9d-4ad1-ae23-577ea6630205
  （画板源在 `docs/design/web-header/`：Current / Main / Dark / Spec）。
