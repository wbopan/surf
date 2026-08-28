# WebView 套壳 App 的"原生感"实战手册

> 基于对 Raycast 2.1.0（macOS 26/27）安装包的逆向读取整理。所有数值、选择器、API 名均来自实际二进制与打包资源，未经猜测的项目会明确标注。
> 目标读者：在 macOS 上用 WKWebView 承载 Web UI（React/Vue/…）并希望它看起来、摸起来像原生 AppKit 应用的工程师。
> 整理日期：2026-08-28

---

## 0. TL;DR —— 立竿见影的 5 件事

| # | 做什么 | 代价 | 效果 |
|---|---|---|---|
| 1 | `WKPreferences._useSystemAppearance = true`，然后在 CSS 里写 `-apple-visual-effect: -apple-system-glass-material` | 3 行私有 API | 真正的 Liquid Glass / 系统 vibrancy 材质，非 CSS 模拟 |
| 2 | 窗口 `isOpaque=false; backgroundColor=.clear`，WebView `drawsBackground=false` | 3 行 | 玻璃能采样窗口后面的桌面/其他窗口 |
| 3 | `[macos]:root { -webkit-font-smoothing: subpixel-antialiased }` | 1 行 CSS | 文字字重与 AppKit 一致，去掉最大的"这是网页"破绽 |
| 4 | 所有尺寸走 `round(calc(N * var(--spx)), 1px)`，`--spx: calc(1px * var(--zoom, 1))` | 设计系统改造 | 任何缩放下不落半像素 |
| 5 | `html { user-select:none; cursor:default; overscroll-behavior:none; overflow:hidden }` + 隐藏原生滚动条 | 5 行 CSS | 输入姿态从"网页"变成"应用" |

再往上一层（架构级、收益最大）：弹出层、菜单、拖拽、图标全部交给 AppKit（第 2 章）。

---

## 1. 私有 API 层：直接借用系统渲染

### 1.1 `-apple-visual-effect`：WebKit 内置的系统材质

WebKit 为苹果自家 App（App Store、Music/TV/Podcasts 商店页、News、Safari 视频控件……）内置了一组平台钩子，默认关闭。打开方式（已在 macOS 27 beta / WebKit 当前版本实测验证）：

```swift
let cfg = WKWebViewConfiguration()
// 私有属性 _useSystemAppearance；KVC 会命中 _setUseSystemAppearance:
cfg.preferences.setValue(true, forKey: "useSystemAppearance")
// 等价做法：枚举 WKPreferences._features，找到 key == "UseSystemAppearance"，
// 调 -[WKPreferences _setEnabled:forFeature:]
```

验证：

```js
CSS.supports('-apple-visual-effect', '-apple-system-glass-material')  // 打开前 false，打开后 true
```

**本机 WebKit 接受的全部值（实测 10 个）：**

| 值 | 用途 |
|---|---|
| `-apple-system-blur-material-ultra-thin` / `-thin` / `-apple-system-blur-material` / `-thick` / `-chrome` | 传统 NSVisualEffectView 五档模糊材质 |
| `-apple-system-glass-material` | Liquid Glass 面板（侧栏、popover、toast、alert、HUD） |
| `-apple-system-glass-material-subdued` | 带 tint 的玻璃（Raycast 用于 tinted 控件） |
| `-apple-system-glass-material-media-controls` | 胶囊控件玻璃（Safari 视频控件同款；Raycast `.macos__control`） |
| `-apple-system-glass-material-media-controls-subdued` | 上者的弱化版 |
| `-apple-system-glass-material-clear` | 透明玻璃 |
| `-apple-system-vibrancy-label` / `-secondary-label` / `-tertiary-label` / `-quaternary-label` | 文字 vibrancy（在任何材质上可读） |
| `-apple-system-vibrancy-fill` / `-secondary-fill` / `-tertiary-fill` / `-separator` | 填充/分割线 vibrancy |

同一开关还解锁 `-apple-system-*` 颜色关键字：`-apple-system-label`、`-apple-system-secondary-label`、`-apple-system-blue/red/…`、`-apple-system-control-background` 等，自动跟随深浅模式与系统强调色。

**Raycast 的使用模式——材质挂在空子元素上，内容浮在上面：**

```html
<div class="panel">
  <div class="fx"></div>      <!-- 只负责材质 -->
  …content…
</div>
```
```css
.panel      { position: relative; isolation: isolate; border-radius: 16px; }
.panel > .fx{ position: absolute; inset: 0; z-index: -1; border-radius: inherit;
              pointer-events: none; -apple-visual-effect: -apple-system-glass-material;
              will-change: transform; overflow: hidden; }   /* 提升为独立合成层 */
```

**失焦态（macOS 原生窗口失焦时玻璃变哑光、内容变灰）——Raycast 逐条复刻：**

```css
:root { --tahoe-base-dimmed-bg: color-mix(in srgb, var(--bg) 50%, var(--bg-secondary)); }
[dark]:root  { --tahoe-dimmed-bg: hsla(from var(--tahoe-base-dimmed-bg) h calc(s * .35) 15%); }
[light]:root { --tahoe-dimmed-bg: hsla(from var(--tahoe-base-dimmed-bg) h calc(s * .85) 95%); }

[macos][window-blurred] .panel > .fx { -apple-visual-effect: none;
  background-color: var(--tahoe-dimmed-bg); backdrop-filter: blur(24px); box-shadow: none; }
[macos][window-blurred] .control > *  { opacity: .4 !important; }
[window-blurred] .pill > .fx { -apple-visual-effect: -apple-system-glass-material-subdued; }
```
`window-blurred` 属性由宿主在 `NSWindow.didResignKey / didBecomeKey` 时通过 `evaluateJavaScript` 打到 `document.documentElement` 上（Raycast 还在自家 popover 打开时用 `has-active-native-window` class 抑制它，避免主窗口误显示失焦态）。

**实测经验：**
- **玻璃不要嵌套。** 玻璃卡片里再放玻璃胶囊会出现材质合并伪影；Raycast 的胶囊控件都直接放在背景上。Apple HIG 对 Liquid Glass 也是同样要求。
- 文字用 `-apple-visual-effect: -apple-system-vibrancy-label`，在任何材质/壁纸上都可读。
- 深浅模式由 `NSAppearance` 决定，材质自动切换；CSS 侧再配合 `color-scheme: dark|light`。
- 材质是真实 CoreMaterial 层：拖动窗口、后面内容变化时会实时折射。

**风险：** 私有 API，App Store 审核可能拒；WebKit 升级可能改名。用 `CSS.supports()` 做运行时探测，并保留第 3 章的纯 CSS fallback（Raycast 的 Windows 版就是那套）。

### 1.2 透明窗口 + 原生背景视图

```swift
window.isOpaque = false
window.backgroundColor = .clear
window.titlebarAppearsTransparent = true
window.titleVisibility = .hidden
window.styleMask.insert(.fullSizeContentView)
window.isMovableByWindowBackground = true

webView.setValue(false, forKey: "drawsBackground")     // 私有 KVC，页面背景透明
webView.underPageBackgroundColor = .clear
```
Raycast 在 WebView 底下还垫了一层原生 `NSGlassEffectView`（macOS 26 API，且用了私有扩展 `NSGlassEffectView+Private.swift`：`_adaptiveAppearance`、`setContentTintColor:`）或旧式 `NSVisualEffectView`（`setMaterial:` / `setBlendingMode:`），并用**动态 NSColor** `raycastWindowTint` / `raycastPopoverTint` / `raycastViewShadowTint` 给玻璃上色——这就是 Sky/Sunset 等彩色主题下玻璃还是"原生玻璃"的原因。前端通过 IPC `settings.previewThemeBackgroundColors({background, backgroundSecondary})` 把主题底色送给宿主。

### 1.3 窗口/弹层圆角：swizzle，不是 CSS

- `NSWindow+CustomizableCornerRadius.swift`：swizzle `NSThemeFrame.cornerRadius`（`raycast_NSThemeFrame_cornerRadius`、`_getCachedDefaultWindowCornerRadius`）→ 主窗口 26px。
- `NSPopover+CustomizableCornerRadius.swift`：`NSPopoverFrame._copyFrameMaskPathInRect:`。
- CSS 里没有 `corner-shape` / squircle；圆角形状由原生 frame 决定，Web 只做 `border-radius: var(--radius-window)`（`[macos] 26px` / `[windows] 8px`）。
- 红绿灯是真 AppKit 按钮，宿主 swizzle `NSThemeFrame.updateButtons` 调位置/隐藏（`NSWindow+TrafficLightButtonsLayout.swift`）。

### 1.4 WKWebView 其他调优（全部来自宿主字符串）

| 项 | 作用 |
|---|---|
| `developerExtrasEnabled = true` | 右键 Inspect Element（调材质必备） |
| 禁用 WebContent 进程 App Nap | 后台不降频 |
| `shouldAllowUserInstalledFonts = false` | 用户装的字体不会污染渲染 |
| 禁用 async overflow scrolling | 滚动与玻璃层同步合成 |
| `hiddenPageDOMTimerThrottlingEnabled = false` | 隐藏时定时器不节流 |
| 保持 ProMotion 120Hz（`PreferPageRenderingUpdatesNear60FPS` 是可选项） | 动画流畅度 |
| 自定义 process pool + 预热窗口（`warmupMainWindow`）| 呼出零延迟 |

---

## 2. 架构层：凡是 Web 做不像的，就交给 AppKit

### 2.1 弹出层 = 真 NSWindow（`window.open` 劫持）

Raycast 所有 popover / select / dropdown / tooltip / dialog / alert / HUD / action panel 都是原生子窗口：

```js
// 前端（NativeView 组件）
const u = new URL('about:blank');
u.searchParams.set('feature', 'popover');      // 完整列表：action-panel popover dialog tooltip info-card alert hud dictation-hud performance-hud focus-panel workspace-badge
u.searchParams.set('id', id); u.searchParams.set('parentId', parentId);
const child = window.open(u, '');              // 宿主 WKUIDelegate 拦截 → 返回 NSWindow + 子 WKWebView
// 镜像 <base href>、所有 <style>/<link>、@font-face、theme class、[macos|windows|light|dark|window-blurred]
// 然后 React createPortal 到 child.document 的 #native-view-root
new ResizeObserver(([e]) => child.resizeTo(e.contentRect.width, e.contentRect.height)).observe(root);
```
宿主注入到子文档的合约：`window.resizeTo / animateOut / cancelAnimateOut / makeKey / bounce / startDrag / resetPosition`（web→host），`window.onAnimateOutComplete / onPointerDownOutside / onPlace(side) / onFocusPanelMouseEntered`（host→web）。

为什么值得这么做：popover 可以超出主窗口边界、有真 NSPopover 箭头与圆角遮罩、系统级窗口动画（`bounce`）、Space/全屏切换行为正确、主窗口不会因为自己的 popover 拿到 key 而变灰。

同样思路的两套 alert：`InWindowAlerts`（portal 到父窗口，带遮罩）和 `SystemAlerts`（每个是独立 NSWindow，用于 launcher 隐藏时弹出的系统提示）。

### 2.2 窗口拖拽 / 缩放 / 激活

不用 `-webkit-app-region`（全包 0 处）。一个全局 mousedown：

```js
window.addEventListener('mousedown', async e => {
  const t = e.target;
  if (t.closest('[data-raycast-window-draggable-region="true"]')
   && !t.closest('[data-raycast-window-draggable-region="false"]')
   && !t.closest("a[href], button, input, textarea, select, [contenteditable='true']")
   && e.button === 0) {
    e.preventDefault(); e.stopImmediatePropagation();
    await ipc.host.raycast.dragStart({ x: e.clientX, y: e.clientY });   // 宿主: NSWindow.performDrag(with:)
  }
});
window.addEventListener('dblclick', … => ipc.host.raycast.toggleZoom());  // 宿主: _handlePossibleDoubleClickForEvent:
```
细节：alert 的遮罩可拖、内容不可拖——和 NSAlert 一样。宿主还实现 `acceptsFirstMouse:`（点未激活窗口同时激活+送达点击），并在显示前注入 1×1 焦点 sink（`__raycastPrepareInitialRevealFocus`）避免出现一帧未聚焦态。

### 2.3 右键菜单 = 真 NSMenu

```js
el.addEventListener('contextmenu', async e => {
  e.preventDefault();
  const { actionId } = await ipc.host.contextMenu.open({ items, x: e.screenX, y: e.screenY });
  actionsById.get(actionId)?.();     // 回调不能过 IPC，用整数 id 回查
});
```
item schema：`item | checkbox | submenu | separator | services | share | role`，带 `enabled/visible/checked/icon`。`services`（系统 Services 子菜单）和 `share`（`NSSharingServicePicker`）只有 AppKit 能画——这是判断"真原生"的铁证。WebKit 自带菜单不是全局禁用，而是白名单（`WKMenuItemIdentifierInspectElement/Reload/CopyLinkWithHighlight`）+ `data-raycast-context-menu-region="true"` 区域开关。

### 2.4 图像全部由系统渲染（自定义 URL scheme）

`WKURLSchemeHandler` 注册 `ipc://` 家族，前端当普通 `<img src>` 用：

| URL | 来源 |
|---|---|
| `ipc://image?path=…&width=W*2&trimTransparentPadding=1` | NSWorkspace App/文件图标（2× 请求，裁透明边） |
| `ipc://file-preview` | QuickLook 缩略图 |
| `ipc://emoji-glyph?symbol=…&width=…` | **emoji 也由 OS 画**，不用 Web 字体 |
| `ipc://contactThumbnail` | 联系人头像 |
| `ipc://raycast-sprite/<name>#s` | 自家 SVG sprite（宿主解析） |

响应头 `max-age=31536000, immutable`，配两级版本号（全局 `IpcIconCacheVersion` + 按路径 `IpcPerPathIconVersions`）做失效。反向通道：前端 OffscreenCanvas worker 把菜单栏图标渲染成 base64 回传给 `NSStatusItem`（`setTemplate:` 让系统着色）。SF Symbols 只在 NSMenu item 的 `icon:` 里用了 4 个名字（`doc.on.doc` 等）。

### 2.5 外观 / 强调色 / 键盘布局注入

- 宿主在 **document start** 注入 `window.initialAppearance / initialThemes / systemAccentColor / osVersion / osName`，JS 同步应用，随后异步校验（"Host-injected initial theme was stale; re-injected"）。
- 零闪烁：`:root:not(.transitions-ready) *, ::before, ::after { transition: none !important }`，首屏两次 rAF 后加 `transitions-ready`。
- 系统强调色：宿主监听 `AppleAccentColor/controlAccentColor` → IPC → `html.style.setProperty('--color-system-accent', hex)`；CSS `--accent: var(--color-system-accent, var(--theme-accent))` 再派生 `--accent-5/10/20/40/60/80`。
- 根节点属性一览：`macos="26"` / `windows` / `light` / `dark` / `window-blurred` / `window-hovered`（宿主打）/ class `has-active-native-window` / `no-transparency`（`prefers-reduced-transparency`）/ `transitions-ready` / `scaled-tokens` / `theme-root`。
- 键盘布局由宿主推送（`TISInputSource`，`scanCodeToEquivalent`，`asciiCapableLayout` 兜底 → 俄文布局下 ⌘Z 照常）；录制快捷键时 `hotkey.toggleRecording({suppress:true})` 吞掉系统按键；⌘⌘ 双击检测；呼出时强制切 ASCII 输入法（`enforcedInputSourceId`，Spotlight 同款）。
- 触觉：`NSHapticFeedbackManager.defaultPerformer.perform(_:performanceTime:)`；声音：`NSSound(named:)` / `NSSound(contentsOf:)`。

---

## 3. CSS 层：复制即用的数值

### 3.1 像素对齐与缩放

```css
.scaled-tokens { --spx: calc(1px * var(--zoom, 1)); }
:root {
  --space-2: round(calc(2 * var(--spx)), 1px);  --space-4: …;  --space-6: …;  --space-8: …;
  --space-12: …; --space-16: …; --space-24: …; --space-32: …; --space-40: …; --space-48: …; --space-56: …;
  --font-size-8/11/13/16/18/24: round(calc(N * var(--spx)), 1px);
  --icon-12/16/22/32: …;
  --radius-2/4/6/8/10/12/16/18/20/26: Npx;  --radius-full: 9999px;
  --radius-window: 26px;            /* [windows]: 8px */
  --blur-1: 6px; --blur-2: 12px; --blur-3: 24px; --blur-4: 36px;   /* [windows]: 15/35/60/120 */
}
```
`--zoom` 由 JS 写在 `<div class="scaled-tokens" style="display:contents; --zoom: 1.1">` 上（用户设置 1.0–1.2，步进 0.1），不读 `devicePixelRatio`。发丝线用 `.5px`（`box-shadow: inset 0 0 0 .5px …`）。

### 3.2 文字

```css
:root { font-family: InterVariable, sans-serif;   /* 内嵌 woff2；Windows 上 Segoe UI Variable */
        font-feature-settings: "liga" 1, "calt" 1, "kern" 1, "ss03" 1;
        font-synthesis: none; font-optical-sizing: none; }
[macos]:root { -webkit-font-smoothing: subpixel-antialiased; }   /* 关键一行 */
/* 复刻 SF Pro 的光学字距（节选，共 40 条 size×weight） */
.text.size-8.w400  { letter-spacing: calc(.1  * var(--spx)); }
.text.size-11.w500 { letter-spacing: calc(.04 * var(--spx)); }
.text.size-13.w400 { letter-spacing: 0; }
.text.size-18.w600 { letter-spacing: calc(-.12 * var(--spx)); }
.text.size-24.w400 { letter-spacing: calc(-.15 * var(--spx)); }
/* 行盒对齐基线（leading-trim） */
.title { text-box: trim-both cap alphabetic; }
```

### 3.3 颜色系统：3 个基色 + relative color

```css
:root { --bg: #000; --bg-secondary: #000; --fg: #fff; }
:root {
  --fg-5:  rgb(from var(--fg) r g b / 5%);   --fg-10: … 10%;  --fg-20: … 20%;
  --fg-40: … 40%;  --fg-60: … 60%;  --fg-80: … 80%;      /* bg-*、accent-*、red-* 同理 */
  --color-text-primary: var(--fg);   --color-text-secondary: var(--fg-60);
  --color-text-tertiary: var(--fg-40); --color-text-placeholder: var(--fg-40); --color-text-disabled: var(--fg-40);
  --color-border-separator: var(--fg-10); --color-border-secondary: var(--fg-20);
  --color-surface-control: var(--fg-10); --color-surface-input-field: #ffffff0d; --color-surface-inner-panel: #ffffff1a;
  --color-surface-list-hover: var(--selection-5); --color-surface-list-selection: var(--selection-10);
  --color-text-selection: var(--fg-20);      /* ::selection */
  --focus-ring-width: 2px;                   /* [windows]: 1px */
  --color-border-focus-ring: rgb(from var(--fg) r g b / 30%);   /* 从前景派生，不是强调色 */
  --focus-ring: var(--focus-ring-width) solid var(--color-border-focus-ring);
  --shadow-panel-border: inset 0 0 0 1px var(--fg-20);
  --shadow-panel-shadow: 0 1px 1px -1px #0000000d, 0 4px 2px -3px #0000000d, 0 8px 4px -6px #0000000d,
                         0 12px 40px -12px #0000001a, 0 24px 64px -24px #0003;
}
.theme-root[dark]  { color-scheme: dark; }
.theme-root[light] { color-scheme: light; }
```
嵌套圆角约定：每个容器重新发布 `--radius-closest: var(--radius-N)`，子元素 `border-radius: var(--radius-closest)`。

### 3.4 纯 CSS 玻璃 fallback（Raycast 的 Windows 路径，也是 `CSS.supports` 失败时的兜底）

```css
.panel {
  background-image: linear-gradient(#ffffff1a, #ffffff1a),
                    linear-gradient(to bottom, var(--bg-secondary-40), var(--bg-secondary-40));
  background-color: #333;               /* light: #e6e6e6 */
  -webkit-backdrop-filter: blur(36px); backdrop-filter: blur(36px);
  box-shadow: var(--shadow-panel-border), var(--shadow-panel-shadow);
}
.alert { box-shadow: inset 0 0 0 .5px var(--fg-5), inset 0 1px 0 var(--fg-5), 0 20px 24px #00000052; }
.toast { background: var(--bg-40); backdrop-filter: blur(6px); }
.toast::after { content:""; position:absolute; inset:0; border-radius:inherit;
                box-shadow: inset 0 .5px 0 0 var(--fg-10), inset 0 0 0 1px var(--fg-10); }
/* 微玻璃 */
.keycap { box-shadow: inset 0 .913px .913px .913px #fff3, inset 0 1.826px .913px .913px #00000040,
                      0 0 .457px .913px #000, 0 1.37px 3px 2.283px #0000004d; }
.orb    { background: var(--bg-60); backdrop-filter: blur(3.877px);
          box-shadow: 0 .362px .362px .362px var(--fg-20) inset, 0 .723px .362px .362px var(--bg-20) inset;
          filter: drop-shadow(2px 1px 6px var(--bg-20)); }
```

### 3.5 输入姿态与滚动

```css
html { overscroll-behavior: none; -webkit-user-select: none; user-select: none; cursor: default; overflow: hidden; }
[data-raycast-selectable-region="true"] { cursor: text; -webkit-user-select: text; user-select: text; }
input, textarea { caret-color: var(--fg); }
* { scrollbar-width: none; } *::-webkit-scrollbar { display: none; }
/* 自绘 overlay 滚动条 */
.scrollbar { --thumb-size: 6px; --fade-timings: .3s ease-out; --widen-timings: .18s var(--widen-delay, 2s) ease-out;
             transition: opacity var(--fade-timings), width var(--widen-timings), background-color var(--widen-timings); }
```

### 3.6 动效（量过原生控件的数值）

```css
:root { --easing-ease-out-expo: cubic-bezier(.16, 1, .3, 1); }
/* NSSwitch */
[macos] .switch { --switch-transition: background-color .216s ease-out;
                  --switch-thumb-transition: transform .366s cubic-bezier(.16, -.12, .29, 1.31); }
/* 按下即时、松开缓动 */
.button:active, .button[data-state=pressed] { opacity: .8; transition-duration: 0s; }
.button:focus-visible { outline: var(--focus-ring); transition-duration: 0s; }
/* popover */
.popover[data-state=open] { animation: .25s cubic-bezier(.3, .7, 0, 1.26) both popover-open; }
@keyframes popover-open { from { opacity: .6; transform: scale(.97) } to { opacity: 1; transform: scale(1) } }
@media (prefers-reduced-motion: reduce) { .popover { animation: none } }
```

### 3.7 组件几何

| 组件 | 数值 |
|---|---|
| Button 高度 | mini 16 / small 24 / medium 32 / large 40；padding-inline 8/12/16/24；macOS 一律 `radius-full` |
| Button 变体 | primary: bg `fg` 字 `bg`；secondary: `fg-10 → hover fg-20`；tertiary: `0 → hover fg-5 → active fg-10`；destructive: `red` on `red-20`；standout: `accent-5` + 渐变 `accent-5→accent-20` + `0 0 24px 1px accent-10` |
| Icon button | 36 / 28 / 24 |
| Button group | `radius-full`，padding 4 |
| Switch | medium 36×16 / padding 1 / 拇指 21；large 54×24 / 2 / 32；轨道 `fg-20 → accent`；拇指 `#ffffffe6 → #fffffff2` |
| Input / Dropdown | 高 32（small 24），padding-x 12，bg `#ffffff0d`，`box-shadow: 0 0 0 1px fg-20`，focus 时去 ring 改 `outline: 2px solid fg-30` |
| Segmented | 项 32 高 / padding 12 / gap 8；选中底 `fg-10`，用 CSS anchor positioning 滑动（`anchor-name: --active-item`，`.3s ease-out-expo`） |
| Checkbox | 14×14，`0 0 0 1px fg-20` |
| List row | padding-x 8，icon 16/22，选中 `selection-10`，hover `selection-5`，title 13/500，subtitle 13 `fg-60`，右侧类型 `fg-40` |
| Keycap | 20 高，`radius-4`，bg `fg-10`，字 11/500 `fg-60` |
| Launcher 窗口 | 750×475，header 64/66，footer 42，搜索框 32，圆角 26 |

### 3.8 现代 CSS 的用量（供参考）

`:has()` 120、`rgb(from …)` 203、`round()` 800、`color-mix()` 33（15 处 oklab）、`@property` 17、anchor positioning 3、`text-wrap: balance` 13、`will-change` 47、`isolation: isolate` 19。未用：`corner-shape`、`light-dark()`、`@starting-style`、`view-transition`、`@container`。

---

## 4. 检查清单

**宿主（Swift）**
- [ ] `preferences.setValue(true, forKey: "useSystemAppearance")`
- [ ] `webView.setValue(false, forKey: "drawsBackground")`，窗口 `isOpaque=false` + `.clear`
- [ ] `developerExtrasEnabled`（调试期）
- [ ] `didBecomeKey / didResignKey` → 根节点 `window-blurred`
- [ ] document-start 注入 appearance / accent / osVersion；监听 `AppleAccentColor`
- [ ] 弹出层：拦截 `window.open` → 子 NSWindow（或至少 popover/tooltip/select）
- [ ] `contextMenu.open` → NSMenu
- [ ] `dragStart` → `performDrag(with:)`；双击 → zoom；`acceptsFirstMouse`
- [ ] `ipc://` scheme handler 出 App 图标 / QuickLook / emoji
- [ ] 键盘布局推送；haptics；`NSSound`
- [ ] 禁 App Nap、user-installed fonts、async overflow scrolling；预热窗口

**Web（CSS/JS）**
- [ ] 根属性 `[macos] [light|dark] [window-blurred]`，`color-scheme`
- [ ] `-apple-visual-effect` + `CSS.supports` 探测 + 纯 CSS fallback
- [ ] `--spx` / `round()` 全覆盖；`.5px` 发丝线
- [ ] `-webkit-font-smoothing: subpixel-antialiased`；光学字距；`text-box`
- [ ] `html { user-select:none; cursor:default; overscroll-behavior:none; overflow:hidden }` + 自绘滚动条
- [ ] 3 基色 + opacity ramp；focus ring 从前景派生；`--radius-closest`
- [ ] 按下 `transition-duration: 0s`；switch/popover 曲线；`prefers-reduced-motion`
- [ ] 玻璃不嵌套；文字 `vibrancy-label`；玻璃层 `will-change: transform; isolation: isolate`
- [ ] 首屏 `transitions-ready` 门控

---

## 5. 风险与合规

- 本文 1.1–1.3 与 2.x 中标注的 `_`-前缀 API、KVC 私有 key、swizzle 均属**私有 API**。Raycast 不走 App Store，自行分发。若你需要上架，至少 `-apple-visual-effect` / `drawsBackground` / `NSThemeFrame` swizzle 有被拒风险；其余（`window.open` 劫持、NSMenu、scheme handler、NSWindow 子窗口、haptics）全是公开 API，可放心用。
- WebKit 版本差异：`-apple-visual-effect` 的 glass 值需要 macOS 26+；blur/vibrancy 值更早就有。始终 `CSS.supports` 探测并降级。
- 材质是真实合成层，大量玻璃元素（尤其列表里每行一个）会有 GPU 成本；Raycast 只在面板/胶囊级别用，列表行用普通 `fg-10`。

---

## 附录 A：最小可运行 demo（已在 macOS 27 beta 实测）

**main.swift**
```swift
import AppKit
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!; var webView: WKWebView!
    func applicationDidFinishLaunching(_ n: Notification) {
        let cfg = WKWebViewConfiguration()
        cfg.preferences.setValue(true, forKey: "useSystemAppearance")     // ← 私有开关
        cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")
        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear

        let rect = NSRect(x: 0, y: 0, width: 1120, height: 780)
        window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.isOpaque = false; window.backgroundColor = .clear
        window.isMovableByWindowBackground = true; window.center()
        webView.frame = rect; webView.autoresizingMask = [.width, .height]
        window.contentView = webView

        let url = Bundle.main.url(forResource: "index", withExtension: "html")!
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())

        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { _ in
            self.webView.evaluateJavaScript("document.documentElement.removeAttribute('window-blurred')") }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { _ in
            self.webView.evaluateJavaScript("document.documentElement.setAttribute('window-blurred','')") }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}
let app = NSApplication.shared; app.setActivationPolicy(.regular)
let delegate = AppDelegate(); app.delegate = delegate; app.run()
```

**index.html（节选）**
```html
<style>
  html, body { margin: 0; background: transparent; }
  body { font-family: -apple-system, system-ui; color: -apple-system-label; -webkit-font-smoothing: subpixel-antialiased; user-select: none; cursor: default; }
  .glass { position: relative; isolation: isolate; border-radius: 16px; padding: 20px; }
  .glass > .fx { position: absolute; inset: 0; z-index: -1; border-radius: inherit; pointer-events: none; -apple-visual-effect: -apple-system-glass-material; }
  .pill { position: relative; isolation: isolate; display: inline-flex; align-items: center; height: 36px; padding: 0 16px; border-radius: 9999px; font-weight: 500; }
  .pill > .fx { position: absolute; inset: 0; z-index: -1; border-radius: inherit; -apple-visual-effect: -apple-system-glass-material-media-controls; }
  [window-blurred] .glass > .fx { -apple-visual-effect: none; background: hsla(0 0% 15%); backdrop-filter: blur(24px); }
  .label { -apple-visual-effect: -apple-system-vibrancy-label; }
</style>
<div class="glass"><div class="fx"></div><span class="label">Panel</span></div>
<span class="pill"><span class="fx"></span>Button</span>
<script>console.log(CSS.supports('-apple-visual-effect','-apple-system-glass-material'));</script>
```

构建：
```bash
mkdir -p GlassDemo.app/Contents/{MacOS,Resources}
# Info.plist: CFBundleExecutable=GlassDemo, CFBundleIdentifier, NSHighResolutionCapable, NSPrincipalClass=NSApplication
swiftc -O main.swift -o GlassDemo.app/Contents/MacOS/GlassDemo -framework AppKit -framework WebKit
open GlassDemo.app
```

## 附录 B：探测脚本——枚举 WebKit 私有 feature

```swift
import WebKit
let feats = (WKPreferences.self as NSObject.Type).perform(NSSelectorFromString("_features"))?.takeUnretainedValue() as? [NSObject]
for f in feats ?? [] { print(f.value(forKey: "key") ?? "", f.value(forKey: "defaultValue") ?? "") }
// 本机 601 个；相关：UseSystemAppearance(false), HostedBlurMaterialInMediaControlsEnabled(true), CSSAppearanceBaseEnabled(false)
```

## 附录 C：自己挖 Raycast 的方法

- 前端资源（未加密）：`/Applications/Raycast.app/Contents/Resources/macos-app_RaycastDesktopApp.bundle/Contents/Resources/frontend/`（`main-window.html` 等 7 个入口，114 个 CSS，JS chunk 带 `sourceMappingURL` 但不附 `.map`）
- 宿主：`strings /Applications/Raycast.app/Contents/MacOS/Raycast | grep -E '\.swift$'` 可列出全部 Swift 源文件名；`grep -iE 'NSGlassEffect|VisualEffect|_set'` 找私有 selector
- 实时看 computed style：`defaults write com.raycast.macos WebKitDeveloperExtras -bool true`，重启 Raycast，Safari → 开发 → 本机 → Raycast
- 主题色板明文在 `bundled-themes-*.js`；token 定义集中在 `css-DgKN_mFk.css`（`:root` / `[macos]:root` / `[windows]:root` / `.scaled-tokens`）
