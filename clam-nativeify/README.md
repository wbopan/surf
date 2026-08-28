# clam-nativeify

clam（macOS 壳应用）专用的 dsh Web UI 原生化插件。**三面包**：

- `dsh.client`（`lib/client.js`）：浏览器半边，dsh-client-modules 的 node 半边扫描后经 `/plugins/clam-nativeify/client.js` 送达页面。**九成实现在这里**。
- `lib/index.js`（node 半边）：两件事——① 注册设置命名空间 `clam-nativeify`（唯一一项是「对话区字号」），走运行时嵌套 `ctx.inject(["settings"])`，缺席即退到默认值；② 登记 `swift/` 载荷，并把 dsh 的 `ui-theme` 偏好投影下去（见「原生侧跟随 dsh 主题」）。
- `swift/`（原生半边）：不占槽、不贡献界面，只按投影设 `NSApp.appearance` 与主窗口底色。缺席即回到"系统外观与 dsh 主题各行其是"。

**本包自己不声明 `dsh.bundle`、包内也没有 `cordis.patch.yml`。** 编排权集中在伞包
`@wenbo/surfclam` 的那张表上（`surfclam/cordis.patch.yml` 里的 `ui-clam-nativeify` row），
一处真相；子包各自带一份 patch 是旧结构，早已作废。

## 职责边界

**只做「让 dsh Web UI 摸起来像原生 macOS App」这一件事**，页面一侧的实现基本是注入
一段 CSS（外加一段十行的 JS 把窗口焦点态映射到 `<html data-clam-blur>`，见「四态」
一节），零跨插件契约。**唯一的设置项是对话区字号**，见下面「字体」一节；除它之外
没有配置，页面一侧的服务依赖也只有那一个可选的 `settings` / `settingsScope`
（缺席即退到默认值，见同一节）。

**唯一越出页面的一件事是主题**：原生侧的 `NSAppearance` 与窗口底色此前跟系统走，
与 dsh 的 `ui-theme` 互不知情，一撞就穿帮——见下面「原生侧跟随 dsh 主题」。
那条线的代价是本包多了一个薄 Swift 载荷（因而多一条硬依赖 `clamBridge`），
但它仍然只读不写：**主题的真相始终在 dsh，这里一个偏好都不存。**

门控只有一条：`navigator.userAgent` 含
`Clam/`（带斜杠，防普通子串误命中；壳经 `applicationNameForUserAgent` 声明）。
终端 `dsh web` / 普通浏览器共用同一 web profile 时零影响。

功能：

1. **禁掉 document 橡皮筋**：`overflow:hidden` 在 WebKit 里不禁用 elastic 滚动——
   内层滚动容器滚到底后惯性仍会链到 document，把整页拉走。`overscroll-behavior:none`
   禁 document 橡皮筋，内层元素 `contain` 切断滚动链（自身仍可滚、边界仍有原生回弹）。
2. **UI 文本不可选中**：全局关掉 `user-select`，输入类控件（composer 等）与
   会话消息流 / trajectory 内容列 / `pre`·`code` 恢复可选，对话历史照常可复制。
   配套的光标姿态见下面「四条姿态」。
3. **按钮按压手感**（macOS 26 / Tahoe）：按下时容器 `scale: 1.09`，**内容跟着容器
   一起走**——`scale` 会往下继承，不需要也不该给图标再写一层，图标现在什么都不额外做。
   缓动走 Apple 全系基准曲线 `cubic-bezier(.32,.72,0,1)`，**按下 0s、松开 320ms**
   （见下面「按下即时、松开缓动」）。悬停另加整片着色（浅色变暗 / 深色提亮，数见
   下面那节）和一层极轻的浮起投影。遵循 `prefers-reduced-motion` 与
   `prefers-reduced-transparency`。

   > **窗口激活 ↔ 失活必须是瞬时的。** 系统换焦点是重绘不是动画；而按钮上挂着
   > `box-shadow` / `background-color` / `filter` 的过渡（给 hover 和按下用的），
   > 焦点一变就会顺带把整摞玻璃层做成 160ms 淡入淡出，一眼假。`watchWindowFocus()`
   > 里用的是经典跳过法：挂 `data-clam-nofx`（配套 CSS `transition: none !important`）
   > → 改 `data-clam-blur` → **读一次 `offsetHeight` 强制刷新样式** → 摘掉标记。
   > 那次读取是关键，删了等于没加 —— 不强制刷新，浏览器会把加标记、改值、摘标记
   > 合成一次样式计算，过渡照旧发生。

   > 这里曾经给图标写过一条反向的 `scale: 0.88`，注释还称"容器涨、图标缩是
   > Liquid Glass 手感的全部秘密"。**没有这种说法，那条是错的**，仓库里也从来
   > 没有任何实测支持它。反向缩放的净效果是图标只有 1.06 × 0.88 = 0.93 倍，
   > 按下去像被捏了一把，不是被按下去。已删除。

   另加**按压亮光**：按下时手指底下泛起一块光，松手摊开淡掉。位置由
   `watchPressPoint()` 写成 `--clam-px/--clam-py`（本插件的第二段、也是最后一段 JS）。
   三件事值得记：

   - **定稿只让不透明度变**：半径两态都是 150%，整面泛光而不收拢成一小块，
     渐变中心仍跟着指针。半径这个旋钮留着 —— **"散开"必须写进闲时那一态**才做得出来：
     transition 只有两态，闲时 = 摊开 + 全透明、按住 = 收拢 + 亮起来，按下就是
     "光聚到手指底下"，松手自动成为"摊开并淡掉"。反过来写松手就成了"缩回去"。
   - **半径和颜色必须 `@property` 注册**成 `<percentage>` / `<color>`，
     没注册的自定义属性不参与插值，会直接跳变。
   - **走 `background-image` 而不是 `::after`。** 伪元素盖在内容之上，浅色档那点白光
     会把标签一起冲淡（实测 "Session log" 直接发虚）。`background-image` 这一层在
     `background-color` 之上、内容之下，文字纹丝不动。必须带 `!important`：
     `background` 简写会把 `background-image` 一起清掉，而且是静默的。

   **亮光只留在深色档**（`--clam-press-glow`：深 `rgba(255,255,255,.17)`、浅 `transparent`）。
   浅色档取消了，两条理由都站得住：系统实测浅色按下就是整体压暗、一点白光都没有；
   而且浅色玻璃本体已经 248/255，头顶只剩 7 级，白光实测只抬得动 **+1 级**
   （深色档同一个值抬 +31）——物理上就做不出来。浅色的按下反馈改由下面那套
   整片着色承担。

### hover / 按下：整片着色（实测见 `docs/spikes/hover/`）

macOS 27 的按钮反馈是**两级、且深浅两档方向相反**。下面这组是激活窗口下、
同一张截图里左右两枚同款按钮的差分（左列没人碰 = 基准），不是跨截图比：

| | 闲时 | hover | 按下 |
|---|---|---|---|
| `.glass` 浅色 | 248.1 | 239.5（**−8.6**） | 230.8（**−17.3**） |
| `.glass` 深色 | 66.6 | 88.5（**+21.9**） | 88.5（**与 hover 逐像素完全一致**） |
| `.glassProminent` 浅色 | (0,131,255) | **零变化** | (0,110,241) |
| `.glassProminent` 深色 | (0,135,255) | **零变化** | (0,155,255) |

据此落成 `--clam-tint-hover` / `--clam-tint-press`，做成 `--clam-surface` 里的一层整片
inset。三条是从数据直接读出来的、别凭手感改回去：

- **浅色变暗、深色提亮。** alpha 直接由 Δ 除以底色算：8.6/248.1 = .035、
  17.3/248.1 = .070（黑）；深色 21.9/(255−61.1) = .113（白）。
- **深色的按下不再加码。** 系统那一档 hover 就到顶了，`--clam-tint-press` 与
  `--clam-tint-hover` 同值。深色档多出来的层次由按压亮光提供（那是自己要的第三级，
  系统只有两级）。
- **实心强调键（发送键）不参与 hover。** `.glassProminent` 悬停零变化是实测结论，
  不是取样点没找准 —— 探针上挂了 `.onHover` 指示灯，截图里能看见它变绿，
  确认游标确实在按钮上，而按钮本身逐像素没动。所以 `_primary` 单独把 tint 清零。

  > 浅色档 `.glassProminent` 的按下不是"叠黑"：从 (0,131,255) 到 (0,110,241)，
  > G 掉 21 而 B 只掉 14，是**往深蓝里压**（约等于叠 `rgba(0,0,170,.16)`）。
  > 我们用的是通用那档黑，色相偏移没有复刻——记在这，别当成没量过。

- **着色层放在高光层之下。** 上下那两道高光是镜面反射，不该被"鼠标移上去"改掉；
  系统那组 Δ 也是量按钮腰部得来的，所以 alpha 也只该按腰部算。
- `--clam-tint` **必须 `@property` 注册**（`<color>`，initial `transparent`）：
  闲时它解析不出来会让**整条 `box-shadow` 失效**，玻璃表面直接消失，而且是静默的。

4. **字体收到 macOS 原生度量**：控件 13px/18px、对话正文 15px/21px（dsh 原本
   16px/28px，问题在行高不在字号）。见下节。
5. **深色档页面底色定成 `#1E1E1E`**：dsh 的 `body` 规则是
   `background: var(--dsw-alias-bg-base, #fff)`，所以**改这一个 token 就等于改整页
   底色**——不用去猜哪个容器在画背景，也不用打 `!important`。和字体那层是同一个
   「token 重映射」套路。写在 `html body[data-ds-dark-theme]`（0,1,2）而不是
   `body[…]`（0,1,1）：dsh 自己在哪一层定义这个 token 没查到（不在前端 `dist` 里，
   是运行时注入的），多垫一个 `html` 是便宜的保险。
6. **四条姿态**：字形渲染、光标、`color-scheme`、选中/插入点。见下节。

### 四条姿态：字形渲染 / 光标 / color-scheme / 选中

这四条各自只有一两行 CSS，共同点是**都在补 dsh 根本没管的那一层**（grep 过它的
构建产物：`color-scheme` 0 处、`caret-color` 0 处、`::selection` 0 处、
`cursor` 在 html/body/`*` 上 0 处）。所以它们不是覆盖，是补课，不与 dsh 打架。

**一、`-webkit-font-smoothing: subpixel-antialiased`。** 这条是覆盖：dsh 在 `body`
上写死了 `antialiased`（构建产物 `index-*.css` 里唯一一条）。那个关键字强制灰度抗
锯齿并把字干整体抽细一档，于是 WebView 那半边的字比壳的原生侧边栏细，并排就是两套
字——本插件存在的理由当场作废一半。`subpixel-antialiased` 的实效是**"别动，交给
系统"**：Mojave 之后 macOS 全局就是灰度 AA，这个关键字不会真去做次像素渲染，只是
把 WebKit 从"强制抽细"那条路上放下来，渲染结果与 `auto` 一致。
写 `html body`（0,0,2）压 dsh 的 `body`（0,0,1），**不打 `!important`**——和字体那层
token 重映射是同一个取胜办法。

**二、`body { cursor: default }` + 可选区 `cursor: text`。** 原生 App 的 chrome 上光标
永远是箭头，只有可编辑/可选的文字才给 I 型。cursor 是可继承的，但**元素自己身上的
声明永远压过继承来的值**——`a:any-link` 的 UA `cursor: pointer`、`input`/`textarea`
的 UA `cursor: auto`、dsh 给按钮写的 `cursor: pointer` 全不受影响，这一条只咬"没人管
过的纯文字"。`cursor: text` 补在**已有的可选中白名单**上（`_flowItem` /
`_contentColumn` / `pre` / `code`）：能选的文字就得给 I 型光标，否则"看着不能选、
其实能选"，比不改更糟。输入类控件不用补，浏览器默认就是。

**三、`color-scheme` 跟 dsh 主题，不跟系统。** 表单控件、原生滚动条、默认 `::selection`
底色这些归 UA 画，认的是 `color-scheme`；不设就等于跟系统外观走。**dsh 设浅色而系统
是深色时，页面里会冒出一个深色的下拉菜单/滚动条，正文却是白的**——一眼穿帮。
写法是 `html { color-scheme: light }` + `html:has(body[data-ds-dark-theme]) { … dark }`；
`:has()` 的特异性取参数里最具体的那条算，后者 (0,1,2) 稳压前者 (0,0,1)，不靠源码顺序。

**四、选中色与插入点从「前景」派生，不从强调色。** 这是手册 §3.3 的配方，也是 macOS
的实际做法（非 key 窗口里的选中就是一层中性淡底）：

```css
::selection { background-color: rgb(from var(--dsw-alias-label-primary) r g b / 20%); }
input, textarea, [contenteditable] { caret-color: var(--dsw-alias-label-primary); }
```

`--dsw-alias-label-primary` 是 dsh 的正文前景 alias（浅 `#0f1115` / 深 `#f9fafb`，
两档都在 `dsh-client-ui-theme` 里核过存在且随主题翻面），所以这两行自己不带任何颜色
常量，dsh 换主题它们跟着换。插入点看着像多余的（`caret-color` 默认 `auto` =
currentColor，多数输入框里已经对了），但 dsh 有几处输入框自己把 `color` 调淡，那时
插入点会跟着变灰，而 macOS 的插入点从来是全对比度的——所以钉死，不靠 currentColor
撞运气。**失效方向见「已知脆弱点」，`::selection` 那条不是无害的。**

### 按下即时、松开缓动

手册量原生控件得到的时序是：**按下那一刻状态直接落定，只有松手才走曲线**。所以
`:active` 那条写的是 `transition-duration: 0s`，只压住"进入按下"这一个方向；松手时
规则不再命中，`--clam-dur`（320ms）/ `--clam-dur-fast`（160ms）原样接管，余韵不变。

这里原来有第三个常数 `--clam-dur-press: 90ms`。短，但仍是一段补间，按下去总差着
一帧的"黏"。**一个恒等于 0 的旋钮没有存在价值**，所以那个变量退休了，`0s` 直接写在
用它的那条规则里。

### `prefers-reduced-transparency`：把玻璃摊成不透明

系统设置 → 辅助功能 → 显示里的那个开关，语义是**"别让我透过控件看背景"**。玻璃的
两根支柱都得让位：材质那层 `backdrop-filter` 直接关掉，半透明的 `--clam-glass-fill`
换成不透明近似色。

**四态的变量结构一个字不动**，只在媒体查询里把四处 fill 各自换成它在自己那档背景上
的合成结果——所以关掉透明之后颜色是"看起来一样"，不是"变成另一块灰"：

| | 原值 | 压在 | 不透明近似 |
|---|---|---|---|
| 浅·激活 | `rgba(252,252,252,.5272)` | 白底 255 | 253.5 → `#FDFDFD` |
| 浅·失活 | `rgba(0,0,0,.059)` | 白底 255 | 240.0 → `#F0F0F0` |
| 深·激活 | `rgba(255,255,255,.137)` | `#1E1E1E`(30) | 60.8 → `#3D3D3D` |
| 深·失活 | `rgba(255,255,255,.094)` | `#1E1E1E`(30) | 51.2 → `#333333` |

四条选择器与它们各自覆盖的那条**同特异性**，靠源码顺序取胜——这个 `@media` 块排在
整张表最后，所以稳赢。`_primary` 不管：它本来就没有 `backdrop-filter`，底色也是 dsh
自己画的实色。

### 字体：两个档位，别混为一谈

**这一节的第一版是错的，错法值得记下来**：当时把 `NSFont.systemFontSize` = 13pt
当成了正文字号，把整条对话列压到 13px。13pt 是 **chrome 度量**——菜单、工具栏、
列表行、次级标签——不是阅读面度量。把它套到一列 700px 宽的长文上，等于把邮件
正文调成菜单栏字号。

两条实测反证：

1. **macOS 27 的新 Siri App**（同一代系统里 Apple 自己的对话面）消息文字明显在
   17pt 一档，远高于 systemFontSize。
2. **System Settings 的档位实测**（本机 2x 截图逐像素量墨高，用同字串在已知 pt 下
   渲染做标定）：

   | | 墨高(2x 设备px) | 换算 |
   |---|---|---|
   | 侧栏项 / 行标签 / 右侧值 | 19–24 | **13pt** |
   | 组标题「Energy Mode」 | 25（粗） | 13pt semibold |
   | 说明文字 | 20 | **11pt** |

   13pt 是**整个设置面板里最大的字**。对话列压到同一档，读起来就像在读设置页的
   说明文字——这正是当时的观感反馈。

所以现在是两个独立旋钮：

| 旋钮 | 值 | 管什么 |
|---|---|---|
| `CONTROL` | 13px（`NSFont.systemFontSize`） | 工具调用行 / 时间戳 / 控件文字。壳的原生侧边栏就是这一档，两边才是同一套字。 |
| `BODY` | 15px（**可配置，12~22**） | 对话阅读列：markdown 全族、**用户气泡**、composer 输入框都跟它走。**改字号只动这一个数**，其余全部派生。 |

#### `BODY` 是一个真正的设置项，`CONTROL` 不是

`BODY` 由设置命名空间 `clam-nativeify` 的 `bodyFontSize` 驱动（设置 → 插件 →
原生观感 → 对话区字号，滑杆）。**`CONTROL` 不给调，这是有意的**：13 是
`NSFont.systemFontSize`，它不是口味而是"像原生"这件事的定义本身；调它等于让
WebView 那半边和壳的原生侧边栏用两套字，本插件存在的理由当场作废。阅读列不一样
——那是长文，字号是纯口味。

布线两句话：node 半边 `ctx.settings.register("clam-nativeify", …)` 注册 ns，
浏览器半边 `ctx.settingsScope.bind({namespace})` 订阅它，值一变就重写字体那张 style。
注册一个 ns 就同时点亮了两个界面（clam-settings 那扇原生窗口、dsh 页内设置对话框），
两边都不用改一行——它们把 `describe()` 里的每个 ns 一视同仁地列出来。

**两处都是可选依赖，走运行时嵌套 `ctx.inject` 而不是静态声明**：静态依赖会让服务
缺席时整个插件不挂载，而这个插件的全部价值是那段 CSS。缺席（以及远程浏览器——
设置 RPC 只走 loopback，那边永远缺席）时字号停在默认 15，其余一切照旧。同理，
字体那张 style **首帧就用默认值装上**，不等任何服务就绪：用户看到的最差情况是
"字号跳一下"，而不是"整页字先是 dsh 的原样、过一会儿才原生化"。

**12~22 这个范围是被行高表的边界卡死的**，不是随手定的：`BODY` 会派生出 `BODY-4`
（12 → 8，正好是 `NATIVE_LINE_HEIGHT` 的下界）与标题档 26（22 → 26，在上界 28 之内）。
表里没有的字号 `lh()` 直接抛，而它跑在构造 CSS 的路上，**一抛就是整段字体规则消失**。
要放宽范围先补测行高。client 半边另有一道 `clampBody()`：设置文档是用户能拿编辑器
手改的文本文件，越界值宁可默默夹住。

**字体那一层是单独一张 `<style id="clam-nativeify-font">`**，与其余 CSS 分开。合在
一起也能工作，代价是改一次字号要把整摞玻璃 CSS 连带重建——`@property` 重新注册会让
已注册的自定义属性瞬时回到 `initial-value`，按钮表面在那一帧塌掉。

**用户气泡跟 `BODY` 而不是 `CONTROL`**：它是对话内容，不是 chrome——和助手回复是同一场
对话的两半，必须同号，否则自己说的话比对面说的小一档。dsh 给它硬编码 16px/24px 且不走
token，内层 `_text` 是 `font: inherit`，所以只需把气泡本身从会话流兜底里摘出去、单独按
`BODY` 给一条。

### 行高：不是 1.23

常说的"原生行高倍数 1.23"只对纯拉丁成立（SF 13pt → 16pt）。dsh 界面是中英混排，
CoreText 一行取各 run 的最大行高，中文 run 落到 PingFang SC，它高得多。本机实测
（`NSLayoutManager.defaultLineHeight`，macOS 26）：

| 字号 | 11 | 12 | 13 | 14 | 15 | 16 | 17 | 20 | 22 | 26 |
|---|---|---|---|---|---|---|---|---|---|---|
| SF | 13 | 15 | 16 | 17 | 18 | 18 | 20 | 23 | 26 | 30 |
| PingFang SC | 16 | 17 | 18 | 20 | 21 | 22 | 24 | 28 | 30 | 37 |
| **混排取大者** | **16** | **17** | **18** | **20** | **21** | **22** | **24** | **28** | **30** | **37** |

照 1.23 做出来的中文会上下行碰字。插件里所有行高都查 `NATIVE_LINE_HEIGHT`，
表里没有的字号直接抛异常，逼着补测而不是随手算个倍数。

**dsh 原本 16px/28px 的问题从来不是字号，是行高**（倍数 1.75，而 16px 的原生行高
是 22px）。这一层要做的是收行高，不是砍字号。

**CSS px 与 AppKit pt 的等价性是逐像素验过的**：同一句中英混排，NSTextField 13pt
与 WKWebView 13px 的汉字墨高都是 26 设备px（2x 屏），16pt/16px 都是 32。所以上面
的 px 可以和 pt 直接对读。

**层级靠字重和颜色，不靠字号跳变**（macOS headline 与 body 同号，只差 semibold）。
所以 strong 一律 600（dsh 原本 500），markdown 标题走 `HEADINGS` 里 macOS 的语义
阶梯（largeTitle 26 / title1 22 / title2 17 / title3 15）取正文之上的四档，
h4 与正文同号只差字重。

### 实现分三层

| 层 | 做法 | 覆盖 | 风险 |
|---|---|---|---|
| **token 重映射** | 改 dsh 自己的 30 个 `--dsw-font-*`，写在 `html body`（0,0,2）稳压 dsh 的 `body`（0,0,1） | markdown 全族 + 所有走 token 的控件文字 | 不碰类名、不打 `!important`、深浅主题自动跟随 |
| **会话流兜底** | `[class*="_flowItem"]` 子树内、`_markdown` 子树外，钉 `CONTROL` | 工具调用摘要行 / 文件名 / 时间戳（占会话流可见文字 62%） | 见下 |
| **三处点修** | 行内 `code` 钉 `BODY-2`；用户气泡与 composer 卡片钉 `BODY` | — | 气泡和 composer 是仅有的两处越过「控件区不动」的地方，理由都是「同一场对话必须同号」 |

**为什么方案「`html { font-size }` 全局等比缩放」不成立**：dsh 全站零 rem
（65KB 静态 CSS + 45 个插件内联 CSS 里 `rem` 出现 **0** 次、`px` 3069 次）。那行
仍然写着（值为 `CONTROL`），但它只是兜底——只影响「自己没声明 font-size、靠继承
吃基准值」的元素。

**为什么会话流那层用容器作用域而不是类名白名单**：硬编码字号有 309 条规则、61 个
不同语义后缀，而且后缀互相打架——`_title` 在 12/13/14/15/16px 五档里都出现，
`_input`、`_label`、`_item` 同样跨档，按后缀白名单必然误伤。改用结构事实：这批
文字全在 `_flowItem` 里、全在 `_markdown` 外（实测该范围 129 个带文字元素里 126 个
是 14px/24px，其余 2 个 16px/24px + 1 个隐藏节点）。

已知失效方向：dsh 若在会话流里新增一种 10~12px 的小标签，会被顶到 `CONTROL`
（变大，不是变乱）；发现了往 `FLOW_EXCLUDED` 加一条。轨迹面（`_contentColumn`）
整个不走 token 也不在 `_flowItem` 里，**完全不受影响**，仍是 dsh 原度量。

**颜色一律走 dsh 的 alias，别自己编 token 名**。本插件只引用这六个，都在 dsh 的 78 个
`--dsw-alias-*` 里核对过存在、且深浅主题都翻面：

| token | 浅色 | 深色 |
|---|---|---|
| `--dsw-font-family` | `-apple-system, …` | 同 |
| `--ds-font-family-code` | `"SF Mono", …` | 同（注意是 `--ds-` 前缀，不是 `--dsw-`） |

**教训**（来自一个临时调参面板，那东西已经拆了，教训留着）：曾写过
`--dsw-alias-bg-elevated` 和 `--dsw-alias-bg-primary`，这两个 dsh 根本没有——CSS
变量不存在时**静默走 fallback，不报错**，所以浅色下看着完全正常、只有深色主题才
暴露。加 token 前先在页面控制台核一次：
`getComputedStyle(document.body).getPropertyValue('--dsw-alias-xxx')`。核实存在之后
**不要留 fallback**，留着只会把将来的改名继续掩盖过去。

**别动字体栈**：`--dsw-font-family` 第一位已经是 `-apple-system`，这是对的。写死
`"SF Pro Text"` 反而丢掉系统的光学尺寸切换和动态字距。

### 按钮效果只给「实体按钮」

**判据：normal 态自己画了背景色或边框的才算按钮**，全透明的只是「可点的图标」。
这与 macOS 自身的分野一致——Finder 工具栏的按钮有玻璃底，列表行里的展开箭头没有。
内联图标（复制、点赞、点踩、thinking 折叠）加了按压形变会显得聒噪，那不是按钮。

实测 dsh 0.1.1-rc.2 的可点元素分布：

| | 元素 | 自绘背景/边框 |
|---|---|---|
| ★ 在册 | `_primary` 发送 · `_sessionLogButton` 下载 · `_add` 命令 · `_newSession` 新建会话 · `_older > button` 加载更早 · `_toBottom` 回到底部 | 有 |
| 不在册 | `_action` 复制/点赞/点踩/分支 · `_trigger` 访问模式/模型/上下文 · `_tab` · `_crumb` · `_iconButton` · `_searchButton` | 全透明 |
| 不在册 | thinking 行、重试折叠 | 连 `<button>` 都不是（`DIV` / `SUMMARY`） |

名单在 `lib/client.js` 的 `SOLID_BUTTONS`。**用白名单而非「排除幽灵」的黑名单**，
因为两者失效方向不同：dsh 改版后白名单失配 = 效果消失（退回现状，无害），
黑名单失配 = 效果乱加到内联图标上。宁可漏，不可滥。

新增实体按钮不会自动获得效果，需手工登记；查漏网的控制台脚本见 `SOLID_BUTTONS`
的注释。

### 材质在表面之下：背景模糊 σ ≈ 13pt，饱和度 ×1.97

下面那一大段讲的都是**表面**（描边、高光、暗带）。但玻璃首先是**材质**：它先把
背后的东西糊掉、把颜色提饱和，然后才谈边缘。缺了这一层，按钮放在会话气泡、
代码块、渐变上就是一块贴纸——四层表面调得再准也救不回来。

```css
backdrop-filter: blur(13px) saturate(1.95);
```

数值实测自 `.glassEffect(.regular)`，探针与完整推导在
[`docs/spikes/glass-blur/`](../docs/spikes/glass-blur/)。做法是给玻璃底下垫一条
竖直硬边，从透过玻璃看到的边缘展宽反推高斯 σ（`W(10→90) = 2.5631 σ`，只看曲线
形状，所以玻璃自己的提亮和描边不干扰）。

**模糊半径不随控件尺寸缩放** —— 96 / 48 / 32pt 三档量出来是 26.28 / 26.02 /
25.88 图像 px（2x 截图），几乎重合。这和下面「剖面不随尺寸缩放」是同一条事实的
两面：**玻璃的所有度量都是绝对量**。

四条要点：

- CSS 的 `blur(<length>)` 参数按规范就是标准差，13pt 可以原样填 `13px`。
- **系统的模糊在线性光里做**，CSS 的在 sRGB 里做。这条复刻不了，代价是过渡带
  比系统略暗。在 sRGB 码值上直接量会把 σ 高估约 2%，要先解码回线性光。
- **底色的合成确实在 sRGB 里**：黑白两点定出的直线预测中灰 199.3、实测 199.2。
  所以 `--clam-glass-fill` 用普通 alpha 合成就对。（那两点解出的是
  `rgba(253,253,253,0.5725)`，比定稿的 `0.5272` 略实；两者在白底上等价，
  只在深色背景上分得出。）
- `saturate` 只给 `--clam-glass-fill` 那一组，**不给 `_primary`**：强调键是实色，
  背后糊什么都看不见，给它上 `backdrop-filter` 只是白白多一个合成层。

**深色档沿用同一组数**，没有单独实测——材质是同一个 `.glassEffect(.regular)`，
翻面的只是那层 tint。这个推断合理但未验证，见 spike README 的「没有量到的」。

### 玻璃表面：四层，且上下与左右正交

按「四周一圈暗带、中间干净」（Fresnel 直觉）做，怎么调都不像。让系统亲自渲染
`.glassEffect` 胶囊、3x 截图后逐像素量，推翻了三次模型才对。

**一、必须用窗口激活态当基准。** 失活时 macOS 把玻璃整个换成一块 −12 的平灰 ——
没有描边层次、没有渐变、没有边缘发光，剖面从头到尾一条直线：

| 白底 255 | ACTIVE | 失活 |
|---|---|---|
| 描边 | −12.4 | −26.7 |
| 内 1~2px | −1.6 | −15.7 |
| 上暗带 | −4.8 | −12.0 |
| 底色 | −1.6 | −12.0 |

探针默认后台启动，截到的正是失活态，照它调只会越调越灰（几版「偏深」都是这么来的）。
refs 探针加 `--hold` 反复抢回 key，并把 `NSApp.isActive` / `isKeyWindow` 回显进窗口
标题，截图里可直接验明截到了哪一态。

**二、上下和左右是正交的两回事。** 只量垂直剖面会整个漏掉水平维度。把整枚胶囊打成
二维亮度图（相对白底 255）才看得出：

```
 y \ x     0pt    3     10    …    56    63    66
  1pt             −1.6 一路平           ← 上内侧发光，最亮
  5pt     −4.8  −4.8  −4.8   …  −4.8  −4.8  −4.4
  8pt     −4.8  −4.8  −4.8   …  −4.8  −4.8  −4.8   ← 上部暗带横向贯通
 11pt     −4.8  −4.0  −2.4   …  −2.4  −3.2  −4.0
 15pt     −4.8  −2.4  −1.6   …  −1.6  −2.8  −4.8   ← 只剩两端暗
 20pt     −2.4  −2.0  −1.6   …  −1.6  −1.6  −2.4
```

暗是**沿内缘走一圈的环带**：上半部横向贯通（整行 −4.8），下半部只剩左右两端，中间
回到底色 −1.6。上下边缘各 2px 的发光把边缘提回底色。左右端描边 −32.5，比上下的
−12.4 深得多（圆弧处抗锯齿叠上描边）。

**三、剖面不随尺寸缩放。** 32/40/64pt 三档数值差 ≤0.2 阶。暗度是绝对量，不是按钮
高度的比例，所以大胶囊上量到的可以原样搬到 32px 按钮。（早先「blur 8px 在 64pt
探针上调好、套到 32px 按钮上糊成一片」，错的是宽度跟着尺寸走了。）

落到 CSS 是描边 + 8 条发光 + 左右阴影的一摞 inset，压在**底色**之上，再加一层
外投影。层序自上而下（`box-shadow` 里先写的盖后写的）：

```
描边          inset 0 0 0 var(--edge-w)     仅无 border 那组
上发光 ×4     inset 0 kpx 0                 k = 1..4
下发光 ×4     inset 0 -kpx 0
hover/按下着色 inset 0 0 0 100px            --clam-tint，闲时 transparent
左内侧阴影    inset 14px 0 8px -15px
右内侧阴影    inset -14px 0 8px -15px
────────────  以上是 --clam-surface  ────────────
底色          background-color              --clam-glass-fill，**唯一的给色处**
外投影        0 1px 2px                     非 inset，在 --clam-surface 之外
```

### 给色只能有一处，那一处是 `background-color`

底色**不是阴影层**。这条是被一个真 bug 换来的：

底色以前是一层 `inset 0 0 0 100px var(--clam-glass-body)`，理由写在注释里 ——
「不碰 `background`，dsh 自己的底色照常生效」。听着像优点，实际后果是
**同时存在两个给色的地方**：dsh 给发送键 `_primary` 画的强调蓝，加上我们这层
半透明白（浅色 `.5272`）。两者叠起来把饱和蓝洗成 (138,195,253) 那种藕荷色 ——
而系统的 `.glassProminent` 内部实测是 **(0,131,255)**，饱和的。**我们把强调键洗白了。**

现在：底色就是元素的 `background-color`，半透明时页面透上来，压到 1 就是实色。
**`_primary` 不在这条规则里** —— 它的色由 dsh 自己画，我们一个字都不碰，只补结构层。
少一个能给色的地方，这个 bug 在结构上就不可能再出现。

`!important` 是必须的：dsh 在更具体的规则里用 `background` 简写，不加会被静默清掉。

### 带色按钮的高光必须跟着它自己的色走

**改底色不改高光等于没修。** 同一组 alpha，落差取决于脚下那块颜色：

| 底色 | 逐行合成 R | 相邻行落差 |
|---|---|---|
| 浅色玻璃 248 | 254 → 250 → 249 → 248 | **3.1 / 1.4 / 0.6 / 0.5** |
| 饱和强调蓝 | 231 → 180 → 156 → 146 | **51.3 / 23.1 / 10.4 / 8.5** |

第一行差 **17 倍**。硬边几何叠层之所以在玻璃上看着连续，纯粹因为高光和底色本来就
只差几级；底色一饱和，同样的层立刻是肉眼可见的条带 —— 那圈"像贴上去的白帽子"就是
这么来的。所以 `_primary` 单独一套：峰值 `.6`、衰减 `.5`、颜色取**同色系更亮一档**
（**不是白**：蓝键的 R 通道从头到尾是 0，掺白会把 R 拉起来，对不上）。

#### 色相来源是 dsh 自己，不是写死的常量

这里曾经写死两行青色（浅 `0 192 255` / 深 `0 203 255`，抄自系统 `.glassProminent`
蓝键的实测峰值 `#00C0FF` / `#00CBFF`），理由是"高光变量吃通道三元组，塞不进一个
`var(--色)`"。**那个借口现在没了，而且它本来就是错的**：

```
button[class*="_primary"] 的 background 走 --dsw-alias-button-info-fill
  → --dsw-static-deepseek-500 #4176e6（浅）/ -400 #679efe（深）
```

dsh 的发送键根本不是系统那支饱和蓝，所以写死的青色高光**今天就已经偏色**，不是
"dsh 哪天换主题色才会出问题"的隐患。（注意**不是** `--dsw-alias-button-primary-fill`
——那条走 `--dsw-alias-brand-primary` → `neutral-bluish`，浅色下是近黑的 `#0f1115`，
dsh 的发送键没在用它。这是从 `dsh-client-ui-conversation` 的构建产物里读出来的。）

现在的写法是相对颜色派生，保色相保彩度、只抬感知亮度：

```css
--clam-glass-glow-c: oklch(from var(--dsw-alias-button-info-fill) calc(l + 0.12) c h);
```

`+0.12` 这个数是从系统实测反推的，两组数都对得上：

| | 本体 | 峰值 | ΔL(OKLCh) |
|---|---|---|---|
| 蓝·浅 | `#0092FF` (L .646) | `#00C0FF` (L .765) | **+0.12** |
| 蓝·深 | `#009EFF` (L .673) | `#00CBFF` (L .792) | **+0.12** |

它顺带解释了"R 通道从头到尾是 0"这条实测：抬亮之后彩度出了 sRGB 色域，CSS 的色域映射
沿 OKLCh 收彩度、落在 R=0 那面边界上，R 于是自然留在 0。白色叠加做不到这一点——
所以那条路本来就不通，不是没调好。

**深色档不再单独给一行**：dsh 的 token 自己随主题翻面，派生式跟着翻。峰值/衰减两个
旋钮原样不动（`.6` / `.5`）。

为此 `--clam-glass-glow-c` 从「通道三元组」改成了普通 `<color>`，发光层写成
`rgb(from var(--clam-glass-glow-c) r g b / calc(…))`。**它必须 `@property` 注册**
（`<color>`、`inherits: true`、initial `#fff`），理由和 `--clam-tint` 一样、而且更硬：
派生式一旦无效（dsh 改名、token 没注入）会一路传染到引用它的 `rgb(from …)`，
**整条 `box-shadow` 连带失效、玻璃表面直接消失，且静默无报错**。注册之后无效值只会退到
白，也就是退回无色玻璃的高光——失效方向安全。`inherits: true` 不能省：这个变量声明在
`:root` 上、用在按钮上。

**发光是 4 条等宽硬边叠出来的几何衰减，不是一层。** 系统的发光是条渐变：边缘
−1.6 → −2.4 → −3.0 → 本体 −3.2，跨 ~4px。两条死路都试过：

- `inset 0 3px 0 白`（blur 0）＝一条 3px 纯白硬边直接盖住边缘，y1/y2 都被打成 0.0，
  y3 又突然掉回 −3.2。是白块，不是发光。
- 单层加 blur 也够不到。inset 阴影模糊后模糊核有一半落在元素外，**最外那一两个像素
  反而最弱**，y1 卡在 −2.4 上不去（g1~g8 八个候选全部撞这个天花板）。

所以第 k 条填最外 k 像素、alpha = 峰值 × 衰减^(k-1)。因为先写的盖后写的，第 n 行的
累积不透明度是第 n..4 层的合成 —— 单调递减是数据结构保证的，不靠调参。两个旋钮：

**当前定稿值**（无色玻璃那组；带色的 `_primary` 另有一套，见上）：

| 变量 | 管什么 | 浅色 | 深色 | `_primary` |
|---|---|---|---|---|
| `--clam-glass-glow-t` | 上缘最外一像素的峰值 | **.795** | **.06** | .6 |
| `--clam-glass-glow-b` | 下缘峰值 | **.795** | **.06** | .6 |
| `--clam-glass-glow-d` | 每向内一像素乘的衰减，越小掉得越快 | **.45** | **.5** | .5 |

早期扫描时的剖面（相对各自本体）——保留下来是为了记住这两个旋钮各自的作用方向，
**数值本身早已不是定稿值**（定稿见上表，是后来在校准台上眼调出来的）：

| | 第 1 行 | 2 | 3 | 4 |
|---|---|---|---|---|
| 浅色 .55/.45 | −1.0 | −3.0 | −4.0（本体） | |
| 浅色 .55/.55 | −1.0 | −2.0 | −3.0 | −4.0 |
| 深色 .025/.45 | +8.0 | +4.0 | +2.0 | +1.0 |
| 系统（浅色） | −1.6 | −2.4 | −3.0 | −3.2 |

浅色档整个发光只活在 255 里的 4 个灰阶内，所以两个旋钮在浅色下都很粗；真正看得出
分别的是深色档。**系统在深色下上下不等强**（+4.7 vs +8.0，与浅色反过来），但定稿在
校准台上眼调回了等强——深色玻璃本体已经比背景亮 37，上下差那 3 级看不出来，反倒是
整体发光强度和衰减速度更要紧。峰值仍然分上下两个变量给，随时能拆开。

alpha 里的 calc 连乘（`rgb(from #fff r g b / calc(var(--a)*var(--d)*var(--d)))`）在
WKWebView 里实测可用，三次连乘的结果和字面量逐位对得上。

**最终值是肉眼在校准台上对着系统胶囊调的，不是扫描的最优解。** 扫描能把六个特征点
都压进 0.5 阶内（顶内 −1.6 / 上暗带 −4.3 / 底色 −1.6 / 端内 −4.8 / 端内 10px −1.6 /
描边 −12.0，对系统的 −1.6 / −4.8 / −1.6 / −4.8 / −1.6 / −12.4），看着仍不对 ——
特征点没覆盖到的地方（描边的锐度、发光的宽窄）也在影响观感。定稿有两处有意偏离（发光的两层结构不是偏离，是复刻系统渐变的唯一办法，见上）：

| | 扫描最优 | 定稿 | 为什么 |
|---|---|---|---|
| 描边 | 0.5px / .048 | **0.25px / .197** | 等墨量下更窄更浓＝更锐。玻璃边缘要"实"，摊薄了散成一圈灰雾 |
| 上部暗带 | 有 | **整层删掉** | 发光加强后它只让上半发浑；改用更深的底色（.0063→.0147）整体压一档 |

代价是放弃了系统那 2.8 倍的上下差。定稿实测：描边 −40.6（系统 −12.4）、内部均匀
−3.2、端内 −4.0 对中间 −3.2（左右阴影因 `spread -15` 几乎被内缩掉，只剩 0.8 阶）。
**数字上离系统更远，肉眼比对下更像** —— 这两件事不总是一致，最终以眼睛为准。

**深色不是把浅色翻个面，是另一套结构。** 同一支探针在 `#1E1E20` 上量 ACTIVE 态
（背景实测 37.5），二维图横向**完全平**：没有暗描边（+0.0）· **没有左右阴影** ·
**没有上部暗带** · 本体比背景**亮 +37.3** · 只有上下两条发光，且**下比上强**
（+8 vs +4.7，与浅色反过来）。深色玻璃靠整体提亮和边缘发光站住，不靠明暗渐变，
所以 side 层在深色下归零（top 层已随浅色定稿一并删除）。

**改这几个值必须重测，别凭肉眼调**：差异都在 1~5 阶（255 里的 0.5~2%），肉眼分辨不了
方向，但叠错了整块表面就散。方法是「让系统在**激活**窗口里渲染真相 → 3x 截图 →
**二维**亮度图 → CSS 候选扫描 → 同一把尺子对表」。交互式调参台见会话里发布的
「玻璃按钮校准台」artifact。

### 四态：{浅色, 深色} × {激活, 失活}

**失活时 macOS 把玻璃整个换成一块平色，零结构。** 四格实测：

| | 浅色 | 深色 |
|---|---|---|
| 激活 | 描边 −16.0 · 有发光 / 左右阴影 / 渐变 | 提亮 +37.3 · 上下发光 |
| 失活 | **整块 −12.0** · 描边 −34.8 | **整块 +25.7** · 无描边 |

失活那两格从头到尾一个值。所以失活不是「把值调淡」，是**把四层里的三层直接关掉**，
只留底色（浅色再留一条描边）。层数（真正有贡献的）：浅色激活 13、浅色失活 3、深色激活 10、深色失活 2。

**表面换平色只做了一半 —— 内容也得褪色。** 系统在失活窗口里把控件整个去饱和
（带色玻璃实测连色相都不剩），发送键那圈强调蓝还亮着就穿帮。所以失活时给白名单里
那几条选择器（`SOLID_BUTTONS`，眼下 **6** 条）加一条 `filter: grayscale(1)`：
对已经中性的玻璃层是空操作，只咬有色的内容。
**只给控件，不给整页** —— 系统灰的是控件，正文该什么色还是什么色。

**描边在失活时反过来走「更宽更淡」**：0.6px/.095（墨量 .057）对激活的 0.25px/.197
（墨量 .049）。墨量略重，但摊开成一圈灰雾而不是一道锐线，正是失活该有的"退到背景里"。
这也了结了之前那个悬案 —— 我们的失活描边曾经比激活还淡，方向和系统相反。

### 带色玻璃（蓝键 / 红键）是另一套数，不是给无色玻璃刷层颜色

同一支探针加上 tint 再量一遍（`TintProbe.swift`，ACTIVE 态，3x）。四条硬事实：

**一、`.buttonStyle(.glassProminent)` 与 `.glassEffect(.regular.tint(_))` 逐像素相同。**
只有圆角不一样（前者圆角矩形、后者胶囊）。系统只有一种带色玻璃表面。

**二、边缘的高光不是白色，是同色系更亮的一档。** 蓝键本体 `#0092FF`、峰值 `#00C0FF` ——
**R 通道从头到尾是 0**。白色叠加无论 alpha 多少都会把 R 拉起来，对不上。红键同理
（本体 `#FF2038` → 峰值 `#FF5762`，G 和 B 的推算 alpha 差着 16%，也不是同一次白色叠加）。
所以发光的颜色抽成了 `--clam-glass-glow-c`，默认白，带色时要换掉——**换法是从 dsh
自己的按钮色相对派生，不是抄下面这张表里的常量**，见上面「色相来源是 dsh 自己」。
下表是系统实测参考值，用来校验派生式的方向，不是我们写进 CSS 的数。

| | 描边行 | 峰值 | 本体 |
|---|---|---|---|
| 蓝·浅 | `#008EFE` | `#00C0FF` | `#0092FF` |
| 红·浅 | `#FF1A32` | `#FF5762` | `#FF2038` |
| 蓝·深 | 无 | `#00CBFF` | `#009EFF` |
| 红·深 | 无 | `#FF6872` | `#FF404E` |

深色档跟无色玻璃一样**没有暗描边**，峰值和本体都更亮一档。

**三、衰减比无色档陡得多，而且几乎全在 1px 以内。** 蓝键在 3x 下逐行是
192 → 173 → 155 → 153 → 151 → 150 → 149 → 148 → 147，也就是**头三个设备行掉了 37 级、
后八行只掉 8 级**。折成逻辑像素（每 3 个设备行）是 +27 → +5.3 → +2.7 → +1.3。
1px 一档的层叠不够细，真要贴上去得用小数 px 的层宽。

**四、失活时整个 tint 被丢掉。** 不是去饱和一点，是连色相都不剩：浅色下变成平灰
`#DCDCDC`（描边 `#C2C3C2`），深色下 `#545455`（描边 `#111112`，比背景还暗）。
这和无色玻璃"失活即平色"是同一条规则，只是丢的东西更多。

这四档（蓝/红 × 浅/深 × 激活/失活）的系统参考图已经嵌进校准台，可以直接对着调。

**焦点态怎么来的**：`watchWindowFocus()` 监听 `window` 的 focus/blur，把结果写成
`<html data-clam-blur>`。WKWebView 会把承载窗口的激活/失活转成页面的 focus/blur
（Safari 里切 app 也是同一套）。这是本插件唯一一段 JS。

**属性值是实例 token，不是空串。** client 半边 HMR 的重载顺序是「新实例先启、旧实例
后清」（CLAUDE.md 踩坑记录），而 cleanup 原来无条件 `removeAttribute` —— 换代时会砍掉
新实例刚打上的 `data-clam-blur`，于是页面明明失焦、按钮却停在激活态那摞玻璃上，
**要等到下一次 focus/blur 才自愈**（窗口一直待在后台就永远不自愈）。现在 `sync()` 把
一个随机 token 写进属性值，cleanup 只清 token 对得上的那份。CSS 那边一律是
`[data-clam-blur]` 存在性匹配、不看值，所以选择器一个字都不用改。
（同文件里字体那张 style 用的是 `fontStyle === style` 的对象身份守卫——同一条纪律的
另一种写法；属性值存不了对象引用，才改用随机串，思路同 clam-layout 的 `makeToken`。）

**刻意不走「让壳注入」那条路**：壳的窗口通知要经 clam-layout 的 Swift 半边才够得着
WebView，那会给 clam-nativeify 添一条跨插件契约。收不到事件的后果只是永远停在激活态
那套值 = 加这段之前的行为，无害，所以宁可要零依赖。

特异性靠 `:root[data-clam-blur] body`（0,2,2）稳压 `body[data-ds-dark-theme]`（0,1,1），
深色失活再多一个属性选择器压住浅色失活。

**一处没解决的矛盾**：定稿的浅色激活态描边比系统浓 2.5 倍（−40.6 对 −16.0，肉眼调的
有意选择）；而失活态按系统绝对值走（−37.3 对 −34.8）。结果是激活→失活时我们的描边
**变浅**，系统却是**变深**（−16.0 → −34.8），方向相反。要么把失活描边也按 2.5 倍放大
（约 −87，失活按钮反而比激活更抢眼，与"退到背景里"的语义相悖），要么把激活态描边收回
系统值。两条路都有代价，当前选了前一半 —— 各自对齐各自的绝对值，接受方向不一致。

**校准值全部按实测反推，别用理论公式**：`alpha × (目标 − 底色)` 算出来的值渲染出来
系统性偏低（浅色）或偏高（深色）—— 合成在线性空间做、结果转回 sRGB，两头都不是线性的。
四态的值都是「先按公式估、渲染、量、按实测比例校正」得来的。

**已知缺口**：hover / active 两态的投影仍是激活态那套，失活时没有单独处理（系统失活
窗口里控件通常也不响应 hover，实际撞不上，但没验证过）。


### 真材质路线：把无色玻璃交给系统渲染

计划 `docs/native-feel-upgrade-plan.md` P3。上面整节讲的手绘四态**一个字都没改**，
它现在的身份是**降级路径**；在壳里、且几个条件都成立时，`neutral` 那组（白名单去掉
实色的 `_primary`，眼下 5 条选择器）的表面改由 WebKit 的私有材质
`-apple-visual-effect: -apple-system-glass-material-media-controls` 画。

这条路建立在 `docs/spikes/apple-visual-effect/` 的三条实测上：

1. **不透明窗口里材质照常采样身后的页面内容**，不是黑块——透明窗口不是前提。
   我们要的正是"胶囊控件采样身下那块页面"。
2. **探测是干脆的全有全无**：壳侧私有开关一关，`CSS.supports` 九个值全 ✘，
   材质层什么都不画。所以 `@supports` 块外必须留着**完整**的手绘栈，不能写成
   "块外留一半、指望材质补另一半"。
3. **窗口失活时材质自己一个像素都不变**（激活/失活两张截图取样值逐位相同）。
   所以"失活时把材质关掉"是**必需项而非优化**——系统不会替我们表达失活。
   `-subdued` 与 `media-controls` 在同一背景上只差几个色阶，也担不起这个差事。

#### 结构：三层门控，全是「进入条件」

```css
@supports (-apple-visual-effect: -apple-system-glass-material-media-controls) {
  :root:not([data-clam-blur]):not([data-clam-reduce]) <neutral 五条> {
    background-color: transparent !important;   /* 给色处让位 */
    backdrop-filter: none;                      /* 材质自己糊背景 */
    position: relative; isolation: isolate;     /* 给 fx 层备好锚与层叠上下文 */
    --clam-surface: inset 0 0 0 100px var(--clam-tint);   /* 只留交互态那一层 */
    --clam-glass-drop: transparent;             /* 外投影一并交出去 */
  }
  :root:not([data-clam-blur]):not([data-clam-reduce]) <neutral 五条>::before {
    content: ""; position: absolute; inset: 0; border-radius: inherit;
    z-index: -1; pointer-events: none; overflow: hidden;
    -apple-visual-effect: -apple-system-glass-material-media-controls;
  }
}
```

**材质挂在 `::before` fx 层上，不挂按钮自身**——挂自身画出来的是材质自己的圆角
矩形，**不认元素的 `border-radius`**（真 App 实测：圆形 + 按钮当场变"胖方形"）。
`.fx` 空子层是 Raycast 的模式（playbook §1.1），spike 里材质胶囊是圆的正因为
它挂在这样一层上；我们用 `::before` 代替真子元素，`border-radius: inherit` 拿到
按钮的圆角，`isolation` 让 `z-index: -1` 落在按钮自己的层叠上下文底部。

**减少透明度那道门是根属性 `data-clam-reduce`，不是媒体查询**——本机 WebKit
**不认识 `prefers-reduced-transparency`**（真 App 角标实测：系统设置明明关着，
`no-preference` 照样不命中；未知特性让媒体查询两个分支双双恒假），写成 CSS 媒体
查询等于把材质和降级路径各锁死一半。属性由 `watchReduceTransparency()` 用
`matchMedia` 打上：不认识时 `matches` 恒 false = 门常开，方向恰好安全；引擎哪天
认识了还能吃到 change 事件活更新。同一批手绘侧的降透明度覆写也一并改成
`:root[data-clam-reduce]` 前缀（特异性高于被覆盖的那条，不再依赖源码顺序）。

| 门 | 不成立时 | 落到哪 |
|---|---|---|
| `@supports` | 普通浏览器 / 壳侧 `useSystemAppearance` 没开 | 手绘四态，原样 |
| `:not([data-clam-reduce])` | 系统"降低透明度"开着（JS matchMedia 判定） | 手绘 + 已有的不透明近似色 |
| `:root:not([data-clam-blur])` | 窗口失活 | 手绘失活那两格（平色 + 描边 + `grayscale(1)`） |

**计划里写的是"块内覆写 `-apple-visual-effect: none` 再让手绘层重新生效"，这里改成了
进入条件。** 两者的计算值完全等价，代价差得远：覆写那条路要在块内把
`--clam-surface` 整摞重新列一遍（还得分 plain / bordered 两组，只有前者带描边层），
并按浅深两档复述一遍 `--clam-glass-drop` 的常量——等于给同一份真相开第二个抄本。
而抄错抄漏的后果不是"少一层"：任何一条 `var()` 解析不出来会让**整条 `box-shadow`
失效、玻璃表面直接消失、且静默无报错**（见「已知脆弱点」，这个形状踩过）。
写成进入条件之后，失活态与降透明度态的计算值与加这段之前**逐字节相同**
（`tools/dump-css.mjs` 的输出 diff 是纯新增），一条回滚规则都不需要。

#### 四条设计裁决

- **只留 tint 那一层，别的整摞退休。** 材质自带完整外观（模糊、提饱和、边缘一圈
  高光描边——那圈高光是液态玻璃的造型语言，关不掉），8 层发光 + 描边 + 左右侧影
  再叠上去就是两套边缘打架。**但 `--clam-tint` 必须留**：材质不提供任何交互态
  （它连窗口失活都不变，更不会响应 hover / 按下），那两级层次只能由我们出。
  按压那片跟着指针走的径向光走 `background-image`，不在 `--clam-surface` 里，原样保留。
- **外投影也去掉**（`--clam-glass-drop: transparent`）。它本来是"让一块手绘的半透明白
  在页面上站住"的拐杖；材质是真实合成层，接地关系是它自己的事，两份贴地阴影叠起来
  只会脏。代价是 hover 少掉"浮起来"那一级（1px→2px→0 三档一起没了），**只剩 tint
  一级层次**。真觉得反馈不够，把那一行删掉就整套回来，不牵动别的。
- **`_primary` 不上材质。** 实色强调键，色由 dsh 自己画，背后糊什么都看不见——
  和它本来就没有 `backdrop-filter` 是同一个理由。它的相对颜色高光（P1 那条
  `oklch(from --dsw-alias-button-info-fill …)`）原样不动。
- **材质挂 `::before` fx 层**（最初直接挂按钮自身，真 App 一开就露馅：材质不认
  元素圆角，圆钮变胖方形——所以这不是可选项，是硬约束）。选 `::before` 不选
  `::after` 纯粹保守：给 dsh 将来用 `::after` 画徽标之类留着位置。
- **玻璃不嵌套**（HIG + Raycast 实测：材质套材质出合并伪影）。白名单这几枚都直接浮在
  页面上，没有一枚坐在另一块材质里，天然满足；**往 `SOLID_BUTTONS` 加按钮时要自己
  确认这一条**。

#### 真 App 验证账（2026-08）

已验：

- **材质生效**（三枚角标法：顶层 / `@supports` 内 / 媒体查询内各放一枚 `::after`
  角标，冷启动看哪枚在）。也是这一验揪出了 `prefers-reduced-transparency`
  在本机 WebKit 是未知特性——`@supports` 那枚在、媒体查询那枚不在，而系统
  设置里"降低透明度"明明关着。
- **圆角**：材质不认元素 `border-radius`，圆钮变胖方形（用户当场看穿）。
  修法 = `::before` fx 层，见上。
- **修完的「+」是正圆**，带材质自带的一圈边缘高光。

待验（按"先看有没有、再看对不对"）：

1. **绘制次序**：`--clam-tint`（inset box-shadow）与按压泛光（`background-image`）
   如今在按钮自身、材质在 `z-index:-1` 的 fx 层——理论上必在材质之上，hover 按一遍确认。
2. **`SOLID_BORDERED` 那三枚的双描边**：dsh 自己画着 `1px rgba(0,0,0,.1)`，材质又
   自带一圈高光。看着重就在块内补 `border-color: transparent`。
3. **深浅两档**：材质认 `NSAppearance`。P4 之后跟 dsh `ui-theme` 走，
   **dsh 深色 + 系统浅色**那一格专门看一眼。
4. **hover / 按下层次够不够**：只剩 tint 两级。不够先恢复 `--clam-glass-drop`。
5. **对照组**：壳侧关掉 `useSystemAppearance`（或把 `@supports` 条件改成必假）
   截一张，确认降级路径完好。
6. **`-apple-system-vibrancy-label` 给按钮文字**：未做，要动先出并排截图。

## 原生侧跟随 dsh 主题

计划 `docs/native-feel-upgrade-plan.md` P4。缺口是**两套主题源互不知情**：

- dsh 设浅色而系统是深色时，原生侧边栏、工具栏、设置窗口是深的，网页正文是浅的
  ——一眼穿帮，而且没有任何办法在 dsh 里把它掰过来。
- 窗口 `backgroundColor` 是壳设的 `.windowBackgroundColor`（跟系统），
  首帧与 resize 时会从窗口底下漏出一条与页面不同的颜色。

**方向：dsh 是权威，原生侧跟随**（计划 §0.1「不另建主真相来源」）。所以这里既不
提供改主题的入口，也不存任何偏好——用户改主题的地方仍然只有 dsh 设置里那一处
（原生设置窗口里的「外观」读的也是同一个 ns）。

### 读法（权威坐标）

| 项 | 值 | 核实处 |
|---|---|---|
| 设置 ns | `ui-theme` | `@deepseek-ai/dsh-client-ui-theme/lib/index.js` 的 `THEME_SETTINGS_NAMESPACE` |
| 键名 | `preference` | 同上 `THEME_PREFERENCE_FIELD` |
| 取值 | `light` / `dark` / `system`（默认 `system`） | 同上 `THEME_PREFERENCES` / `DEFAULT_PREFERENCE` |
| 现成消费者 | clam-settings 通用页 | `clam-settings/swift/SettingsTabs.swift` 的 `GeneralRow(ns: "ui-theme", path: ["preference"])` |

我们**只读不注册**（ns 的主人是那个插件，重复 register 会 fail loud）：
`ctx.get("settings")?.get("ui-theme")` 现读现算，变化订全局的 `settings/updated`
事件按 ns 过滤——非 owner 拿不到 `SettingsScope`，那是 `register` 的返回值。

### 桥协议

| 方向 | 频道/动作 | 载荷 |
|---|---|---|
| 下行 `push` | `theme` | `{theme: "light"｜"dark"｜"system", bgBase: {light, dark}}` |
| 上行 `send` | `theme` | `{}`（现读现推一份） |

**Swift 每代 activate 问一次**，node 只在设置变化时推。这不只是照抄「桥不给新世代
补发」那条纪律，还堵着一个真实的时序洞：`ui-theme` 是别的插件在它自己的
`inject(["settings"])` 里注册的，跟我们的挂载没有先后保证——挂载那一刻读完全可能
读到"尚未注册"，而 `settings/updated` 只在**变化**时发，用户不动设置就永远等不到。
壳的 activate 远晚于整棵插件树挂载完，那一刻现读必然读得到。

### `bgBase` 为什么由 node 投而不是两边各写一份

窗口底色要跟的是**页面实际画出来的那个色**：

- 浅色 `#FFFFFF`：dsh 的 `--dsw-alias-bg-base` → `--dsw-static-neutral-bluish-00` = `#fff`，我们不覆盖。
- 深色 `#1E1E1E`：dsh 自己是 `--dsw-static-neutral-bluish-950` = `#151517`，
  但 `client.js` 把它**重映射**成了 `#1E1E1E`（见上面「深色档页面底色定成 #1E1E1E」）。
  跟 dsh 的原值就会差出一条肉眼可见的边。

所以值走投影，Swift 那边不写死。**改 client.js 里那条重映射时，`lib/index.js` 的
`BG_BASE` 必须同步改。**

### Swift 那边的两条纪律

- **`activate` 返回 follower 而不是 handle**：不占槽的插件没有 registry → 视图闭包
  → model 那条天然强引用链，返回 handle 的话 follower 当场被 ARC 回收，
  日志照常打印"上线"、然后所有 `[weak self]` 回调静默变 nil。
- **没有 deinit、没有"恢复原状"**：`NSApp.appearance` 与 `window.backgroundColor`
  是进程/窗口级状态而不是租来的资源，新一代 activate 按新投影重设即可收敛。
  （「别把清理逻辑只挂在析构上」——热替换时旧 handle 的 deinit 实测经常根本不跑。）

窗口底色做成 `NSColor(name:dynamicProvider:)` 的**动态色**而不是当场解析成静态色：
`system` 档下系统深浅一翻，它自己跟着翻，不用再去订
`AppleInterfaceThemeChangedNotification` 或 KVO `effectiveAppearance`。

刷色的目标窗口判据是「**它装着壳那个 WebView**」（`ClamObjects.Key.webView` 的
`.window`），不是 `NSApp.mainWindow`——后者会在 clam-settings 那扇窗打开时指过去，
把一扇不显示网页的窗户也刷成页面底色。

### 退休语义

把 `ui-clam-nativeify` 从伞包的编排表里摘掉，**当前那个壳进程会保持最后一次设定**
（我们不在析构里恢复，理由见上）。壳重启即回到 `.windowBackgroundColor` + 系统外观。

## 不在这里的

- **`window.__clam` 动作桥、收起 web 侧边栏、rail 轨道抵消**：那些是原生分栏接管
  排版的一部分，住在 clam-layout 的 client 半边（协议两端同包：Swift 侧
  `WebViewConversationSurface` 是它们唯一的调用方）。
- **网页侧边栏的任何外观调整**（顶部让位 `topInset`、把 `sidebarCol` 刷成透明
  以透出壳的 `NSGlassEffectView`）。这是「网页侧边栏坐在原生玻璃上」那个旧世界的
  产物，已随原生侧边栏落地作废——现在只有两种形态：

  | 形态 | 谁在画侧边栏 | WebView 位置 |
  |---|---|---|
  | 原生侧边栏（常态） | clam-sidebar 占 sidebar 槽 | `NSSplitViewItem` 右侧，够不着侧边栏那一栏 |
  | 完整网页模式（逃生舱） | dsh 自己 | 全出血铺满窗口，**原样展示，不修** |

  「用网页侧边栏、但把它打扮成原生」这个中间态不存在，别再往回加。

## 安装

**跟着伞包走，没有单装路径。** 仓库根 `./dev` 会把本包连同其余 clam-* 一起 link
进 profile；装哪些、什么顺序由伞包 `@wenbo/surfclam` 的 `cordis.patch.yml` 决定
（本包是那张表里的 `ui-clam-nativeify` row）。

> **P4 之后本包不能再单独塞进一个普通 web profile 了**：它现在带 Swift 载荷，
> 因而硬依赖同一张表里的 `clamBridge`（`createSwiftPlugin` 自动加的）。桥不在
> = 整个插件不挂载 = 连 CSS 都没有。这是有意的取舍：桥不在就意味着没有壳，
> 而没有壳的话这段 CSS 本来也无处施展（UA 门控挡着，普通浏览器里一行都不生效）。
> 与 clam-layout 同一个赌注。

装/删/改 node 半边或编排表后必须重启 dsh（官方在 web bundle 下 disable 了 node 侧
HMR）；只改 `lib/client.js` 有 HMR，约 0.5s 自动重载；只改 `swift/` 存盘即热替换。

## 看真正注入的那段 CSS

```bash
node clam-nativeify/tools/dump-css.mjs              # 全量
node clam-nativeify/tools/dump-css.mjs nofx _primary  # 只看含关键字的规则块
```

整段样式是**拼字符串**拼出来的，`node --check` 只看 JS 语法，看不出 CSS 括号有没有
配对、选择器前缀有没有漏加。这个脚本用一组最小 DOM 桩跑一遍 `apply()`，抓下
`style.textContent` 并数括号 —— 不用起 dsh、不用开壳。

> **桩收的是两张 style**（主样式 + 字体那张）。这里踩过一个静默坑：桩原来把
> `textContent` 存进一个标量，于是后写的字体 style 把主样式整个盖掉，dump 出来只有
> 6 条规则 —— 而括号平衡、前缀完整这些**恰恰全在主样式那边**，等于校验器什么都没
> 校验到，还一路打印"括号配对正确"。现在每个 style 元素各存各的、最后按创建顺序拼。
> 桩里另外两处也是必需品：`documentElement.getAttribute`（`watchWindowFocus` 的实例
> token 守卫要读）与 `ctx.inject`（设置那条运行时嵌套 inject 要调），缺任一都会抛。
> `inject` 故意是**空实现**：不回调 = 设置服务缺席，正是该模拟的那一档。

> **逗号串上的前缀只写一次只命中第一条**（`:root[x] a, b, c` 里 b/c 没有前缀）。
> 这个坑踩过两次（`blurSolid`、`nofxSolid`），所以那两处都是 `.map()` 逐条加的。
> 改完拿上面的脚本 dump 一次，选择器列表会原样打出来。

## 已知脆弱点

- 选择器 `[class*="_flowItem"]` / `[class*="_contentColumn"]` 依赖 dsh Web UI 的
  CSS module 语义类名后缀（hash 会变、后缀通常稳定）。升级 dsh 后若对话历史突然
  不能复制，先核对 `@deepseek-ai/dsh-client-ui-conversation` / `-ui-trajectory` 的类名。
- `overflow:hidden` 强加于 html/body：与全屏/滚动类未来特性可能冲突。
- 字体那层依赖 dsh 的 `--dsw-font-*` token 名（30 个）。dsh 改名 = 那个 token 悄悄
  退回原值（**变回原样，不会变乱**）。核对办法：页面控制台跑
  `getComputedStyle(document.body).getPropertyValue('--dsw-font-markdown-base')`，
  应当是 `15px/21px ...`（即 `BODY`/`lh(BODY)`）。另：dsh 目前只引用 token 的
  `font` 简写、五个长手零引用，
  插件两者都写，就是防它哪天改用长手时一半新一半旧地分裂。
- **`::selection` 那条依赖 `--dsw-alias-label-primary`，失效方向不是无害的。**
  按 README 的既定纪律这里不留 fallback（留着只会把将来的改名掩盖过去），代价是
  token 一旦消失，`rgb(from var(…) …)` 在计算值时无效 → `background-color` 退到
  `initial` = `transparent` → **选中高亮直接看不见**（而不是退回 UA 默认色）。
  同理 `caret-color` 会退成 `auto`（那一档倒是无害）。升级 dsh 后如果"选中文字没反应"，
  先在控制台跑
  `getComputedStyle(document.body).getPropertyValue('--dsw-alias-label-primary')`。
- **`_primary` 的高光依赖 `--dsw-alias-button-info-fill`**（发送键自己的底色）。
  这条的失效方向是安全的：`--clam-glass-glow-c` 注册成了 `@property <color>`，
  派生式无效就退到白，也就是退回无色玻璃的高光。dsh 哪天给发送键换个 token，
  症状是"那圈边变白了"，不是玻璃消失。
- 完整网页模式（逃生舱）下红绿灯会压在网页侧边栏顶部——**这是刻意接受的**：
  逃生舱的定位是「clam-layout 挂了也还能用」的降级路径，不为它做外观修补。
