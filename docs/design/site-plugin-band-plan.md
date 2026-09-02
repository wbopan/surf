# 官网插件段重做：一扇窗、八个视角 + 左栏热替换装饰

状态：已完成（2026-09-02）。落地页 `site/` 的 `#plugins` 段。

## 为什么

用户看过页面后的裁决：右侧八块示意图各是一套画法（灰条占位、代码块、薄窗口、图例、
按键表、小设置窗、表格），尺寸悬殊，又漂在一整屏的深色舞台里，看起来像随手做的。
左侧只是八行文字，完全没有传达出「每一个都是 Swift 插件、存盘即热替换」这个最值得
炫耀的事实。

## 右侧：一个窗口模型，八个视角

- 只建**一个** Surf 窗口模型（`<template id="surf-window">`），设计尺寸 **984×636**，
  与 `screen-native@2x.jpg` 同几何（工具栏、侧边栏 260、轨迹行、气泡、composer 卡）。
  `app.js` 把它克隆进每个面板的 `.app-view`，用 `data-*` 决定该面板的状态与取景。
- 每个面板的 `.pane-body` 都是同一个浅色 `.shotarea` 相框（保持 README 的「产品照片
  始终浅色」）。窗口按 `--k` 缩放到相框里，再按 `--zoom` / `--ox` / `--oy` 推近到该功能
  所在的区域。八块视觉因此共享同一台窗口、同一套字号，读起来像同一组照片。
- 视角表：

| 面板 | 取景 / 状态 |
|---|---|
| p0 原生渲染 | 推近 composer 卡 + Chat/Trajectory 分段控件，玻璃材质 |
| p1 Swift 引擎 | 代码块保留、缩窄；下方加 build 条：`swift/ changed → swiftc N s → <module> swapped`，进入时逐段点亮 |
| p2 分栏与工具栏 | 整窗，侧边栏分隔线处于拖动态，工具栏分隔线与插件贡献项各一条 hairline 引线标注 |
| p3 会话 | 推近侧边栏，分组切成「按状态」：Pending / In Progress / Ended；右侧保留图例 |
| p4 通知 | 整窗略压暗，右上角压一条真实几何的通知横幅（三按钮） |
| p5 菜单与快捷键 | 整窗 + 顶部菜单栏，Session 菜单拉开，快捷键靠右 |
| p6 设置 | 设置窗口（Models 面板）压在主窗前 |
| p7 记忆 | 推近轨迹里的 `Context injection · surf-memory` 行，旁边是记忆目录清单 |

- 事实只从代码取：模块命名看 `surf-bridge/lib/module-name.js`，编译耗时沿用页面现有
  数字，快捷键沿用页面现有表（README 说已逐条对过）。

## 左侧：热替换装饰

- 八个按钮左边改成一条贯通的 1px hairline 轨道，2px 强调色游标在行间**滑动**（不再是
  每行各自的 border-left）。
- 每行第二行变成 `SurfUI · a3f9c1`：模块名 + 6 位十六进制世代号（mono，`--ink-3`）。
- 某行被选中（滚动或点击）并稳定 150 ms 后播放一次「重建」：世代号逐字翻动、行底
  一条 1px 强调色进度线从左长到右（约 600 ms）、落定成新世代号，尾随一个短暂的
  `swapped` 标记（强调色，900 ms 后淡出）。`prefers-reduced-motion` 下全部静态。
- 列表上方一行 `.label`：`Swift plugins · swapped in place`（中文页 `Swift 插件 · 原地热替换`）。
- 视觉克制照旧：hairline、裸符号、无发光（见记忆 surf-visual-restraint）。

## 工具

`node tools/site-shot.mjs [--pane N] [--scheme dark] [--url …/index.zh.html] [--width 800]`
用 headless Chromium 逐面板截图到 `/tmp/site-pane-<scheme>-<N>.png`。

## 执行日志

- 2026-09-02 计划成文；截图工具落地；派两路子代理：A 左栏，B 右栏窗口模型。
- 2026-09-02 A（左栏）完成。
  - `site/index.html` / `index.zh.html` 的 tablist 块：开头加 `<p class="label">`
    （`Swift plugins · swapped in place` / `Swift 插件 · 原地热替换`）与
    `<span class="p-rail">` `<span class="p-cursor">` 两个装饰元素；每个 button 的第二行
    变成 `<span class="p-mod">…</span><span class="p-sep">·</span><span class="p-gen">a3f9c1</span>`，
    八个初始世代号写死在 HTML 里。`swapped` 标记由 JS 临时插一个 `.p-swap`。
  - `styles.css` 的 plugin switcher 段：`.plugins` 转 `position: relative`；
    `.p-rail` / `.p-cursor` 绝对定位（app.js 给尺寸）；按钮 `padding-left` 14→12，
    保留 2px 透明 `border-left` 当游标的车道，两种布局因此共用同一条文字左缘；
    `.plugins button::after` 是重建进度线（`is-rebuilding` 扫 600ms linear，
    `is-built` 就地淡出）；`.p-mod/.p-sep/.p-gen/.p-swap` 合并成一条 inline-block 规则，
    元素之间不留空白字符，第二行因此不会折行。
  - 深色带的 `.band .*` 覆盖那节动了三行：`.p-mod` 那条扩到 `.p-sep/.p-gen`；
    删掉 `.band .plugins button[aria-selected] { border-left-color }`（宽屏改由游标表达），
    它挪进了 860px media query；新增 `.band .p-rail/.p-cursor/button::after/.p-swap`
    走 `--band-line` / `--band-accent`（`--line` 与 `--accent` 是浅色页面的值，铺在深色带上
    分别是看不见和太暗）。
  - 860px 以下：`.p-rail, .p-cursor { display: none }`，每行的 `border-left` 高亮回来，
    进度线保留，`.label` 与 note 一起 `grid-column: 1 / -1`。
  - `app.js` 新增第二个 IIFE（紧跟 tab list 那个）：用 MutationObserver 盯
    `aria-selected`，滑游标 + 150ms 稳定期后播一次重建（40ms 一批随机十六进制、600ms
    落定、`swapped` 900ms 后淡出）。选中权仍然只在第一个 IIFE 手里。
    `prefers-reduced-motion` 下游标直接跳、不翻动、不出 `swapped`。
  - 验证（headless，`tools/site-shot.mjs` + 两段临时脚本）：翻动中途/落定、深色、中文、
    800px 两列、reduced-motion 各一次；连续快速滚过 6 行只有停住那行重建，
    没有残留的 class 或 `.p-swap`，游标 offsetTop 与选中行逐像素相等。
  - 未做到：`.label` 英文版在 244px 栏里放不下一行，靠 `text-wrap: balance` 断成
    两行居中；没有为它调字号或字距。
- 2026-09-02 B（右栏）完成，英文页先落地、中文页随后同步。
  - `index.html` / `index.zh.html` 各挂一份完全相同的 `<template id="surf-window">`
    （英文，App 界面跟随系统语言，页面上两张真实截图也是英文）；p0、p2～p7 的
    `.pane-body` 统一成 `.shotarea.mock` + `.app-view[data-view data-state data-zoom data-ox data-oy]`，
    p1 保留代码块加 build 条。`app.js` 第三个 IIFE 把模板克隆进每个 `.app-view`，
    按 `--k × zoom` 缩放、把 `(ox, oy)` 推到相框中心，ResizeObserver 跟随尺寸。
  - 「页面在说话」的东西（图例、菜单栏与菜单、通知横幅、设置窗、记忆卡）是相框像素里的
    `.ov` overlay，不随取景放大。中文页的这些 overlay 用 App 的 zh-Hans 文案
    （`surf-notify/lib/strings.js` 的「允许一次 / 拒绝 / 打开查看」、`surf-sidebar/lib/index.js`
    的菜单标签、`surf-settings` 的面板名）。
  - p5 的菜单项改用 App 里真实的菜单标签（Title Case、带省略号，「上一个 / 下一个会话」
    拆成两行）；图注里「右边的系统快捷键」那句随旧快捷键表一起删掉，改成
    「窗口与 App 的快捷键保持固定」。
  - p7 取景 `ox 540→550, oy 245→290`：原来窗口顶边上方露出一条桌面空白。
  - 窄屏（≤860px）修了一个塌陷：`.pane-body` 的 `height: 320px` 被宽屏的 `flex: 1`
    （flex-basis 0%）压成零高，正文整个消失；补 `flex: none`。p1 单独 420px，
    代码块与 build 条能完整放下。
  - 验证（`tools/site-shot.mjs`）：英文八面板 1440 浅色；中文八面板 1440 浅色、
    p6 深色；中文 800px 窄屏 p1/p3/p4/p5/p7。
