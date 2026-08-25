# dash-nativeify

dash（macOS 壳应用）专用的 dsh Web UI 原生化插件。**双面包**：

- `dsh.bundle`（`cordis.patch.yml`）：安装进 profile 后自动加入 `dsh.profile.bundles`，patch 层插入自己的浏览器插件 row（`ui-dash-nativeify`），无需手改 profile 的 `cordis.patch.yml`。
- `dsh.client`（`lib/client.js`）：浏览器半边，dsh-client-modules 的 node 半边扫描后经 `/plugins/dash-nativeify/client.js` 送达页面。

## 职责边界

**只做「让 dsh Web UI 摸起来像原生 macOS App」这一件事**，实现是注入一段 CSS，
零服务依赖、零跨插件契约、无配置项。门控只有一条：`navigator.userAgent` 含
`Dash/`（带斜杠，防普通子串误命中；壳经 `applicationNameForUserAgent` 声明）。
终端 `dsh web` / 普通浏览器共用同一 web profile 时零影响。

功能：

1. **禁掉 document 橡皮筋**：`overflow:hidden` 在 WebKit 里不禁用 elastic 滚动——
   内层滚动容器滚到底后惯性仍会链到 document，把整页拉走。`overscroll-behavior:none`
   禁 document 橡皮筋，内层元素 `contain` 切断滚动链（自身仍可滚、边界仍有原生回弹）。
2. **UI 文本不可选中**：全局关掉 `user-select`，输入类控件（composer 等）与
   会话消息流 / trajectory 内容列 / `pre`·`code` 恢复可选，对话历史照常可复制。
3. **按钮按压手感**（macOS 26 / Tahoe）：按下时容器 `scale: 1.06`、图标
   `scale: 0.88` + `opacity: .7`，两个方向相反的形变一起做——这是 Liquid Glass
   `.interactive` 手感的全部秘密，只做其中一个都不像。缓动走 Apple 全系基准曲线
   `cubic-bezier(.32,.72,0,1)`，按下 80ms 跟手、松开 320ms 留余韵。悬停另加一层
   极轻的浮起投影。遵循 `prefers-reduced-motion`。

4. **字体收到 macOS 原生度量**：控件 13px/18px、对话正文 15px/21px（dsh 原本
   16px/28px，问题在行高不在字号）。见下节。

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
| `BODY` | 15px | 对话阅读列：markdown 全族、**用户气泡**、composer 输入框都跟它走。**改字号只动这一个数**，其余全部派生。 |

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
| ★ 在册 | `_primary` 发送 · `_sessionLogButton` 下载 · `_add` 命令 · `_newSession` 新建会话 · `_older > button` 加载更早 | 有 |
| 不在册 | `_action` 复制/点赞/点踩/分支 · `_trigger` 访问模式/模型/上下文 · `_tab` · `_crumb` · `_iconButton` · `_searchButton` | 全透明 |
| 不在册 | thinking 行、重试折叠 | 连 `<button>` 都不是（`DIV` / `SUMMARY`） |

名单在 `lib/client.js` 的 `SOLID_BUTTONS`。**用白名单而非「排除幽灵」的黑名单**，
因为两者失效方向不同：dsh 改版后白名单失配 = 效果消失（退回现状，无害），
黑名单失配 = 效果乱加到内联图标上。宁可漏，不可滥。

新增实体按钮不会自动获得效果，需手工登记；查漏网的控制台脚本见 `SOLID_BUTTONS`
的注释。

### 玻璃表面：三个反直觉的事实

按「四周一圈暗带、中间干净」（Fresnel 直觉）做，怎么调都不像。让系统亲自渲染
`.glassEffect` 胶囊，3x 截图后逐列剔除图标再平均取垂直剖面，量出三件事：

**一、必须用窗口激活态当基准。** 失活时 macOS 把玻璃整个换成一块 −12 的平灰 ——
没有描边层次、没有上下渐变、没有边缘亮边，剖面从头到尾一条直线：

| 白底 255 | ACTIVE | 失活 |
|---|---|---|
| 描边 | −12.4 | −26.7 |
| 内 1~2px | −1.9 | −15.7 |
| 上本体 | −4.8 | −12.0 |
| 下本体 | −1.7 | −12.0 |
| 上/下 | 2.8 | 1.0 |

探针默认后台启动，截到的正是失活态，照它调只会越调越灰（早先几版「偏深」就是这么来的）。
`docs/spikes/` 的 refs 探针加 `--hold` 反复抢回 key，并把 `NSApp.isActive` /
`isKeyWindow` 回显进窗口标题，截图里可直接验明截到了哪一态。

**二、紧贴边缘那 1~2px 是整块玻璃最亮的地方**（−1.9），越往里越暗，到 6pt 后稳定。
真实结构是「本体一层灰＋上下两条内侧亮边把边缘提回来」，不是「中间干净＋四周压暗」。
并且上下不对称：上本体是下本体的 2.8 倍 —— 光从上方来，上缘内侧被遮蔽、下缘受
底面反射提亮。做成中心对称就少了立体感。

**三、剖面不随尺寸缩放。** 32/40/64pt 三档数值差 ≤0.2 阶。暗度是绝对量，不是按钮
高度的比例，所以大胶囊上量到的可以原样搬到 32px 按钮。（早先「blur 8px 在 64pt
探针上调好、套到 32px 按钮上糊成一片」，错的是宽度跟着尺寸走了。）

落到 CSS 是四层，层序自上而下（`box-shadow` 里先写的盖后写的）：

```
描边          inset 0 0 0 .5px          仅无 border 那组
上内侧亮边    inset 0 var(--spec-w) 0
下内侧亮边    inset 0 calc(-1 * var(--spec-w)) 0
上部加深层    inset 0 16px 14px -8px    向下偏移 → 只压上半
本体底噪      inset 0 0 0 100px         spread 撑满 = 纯色填充
```

本体用 `inset 0 0 0 100px` 而不是 `background-image: linear-gradient`：前者不碰
`background`，dsh 自己的底色/渐变照常生效；后者会把它覆盖掉。

**深色不是把浅色翻个面，是另一套结构。** 同一支探针在 `#1E1E20` 上量 ACTIVE 态
（背景实测 37.5）：描边 **+0.0**（根本没有暗描边）· 上下亮边等强 **+70** 且宽 2px ·
本体比背景 **亮 +38**（不是压暗）· 上/下 **1.03**（几乎对称）。深色玻璃靠整体提亮
和边缘亮边站住，不靠明暗渐变 —— 所以「上部加深层」在深色下归零，描边也归零。
亮边宽度因此走 `--dash-glass-spec-w` 变量（浅色 1px / 深色 2px）。

装回 App 后量线上的 Session log（剥掉 dsh 自带的 1px border）：上本体 −4.8、
下本体 −1.6，对上系统的 −4.8 / −1.7。

**改这几个值必须重测，别凭肉眼调**：差异都在 1~5 阶（255 里的 0.5~2%），肉眼分辨不了
方向，但叠错了整块表面就散。方法是「让系统在**激活**窗口里渲染真相 → 3x 截图 →
逐像素剖面 → CSS 候选扫描 → 同一把尺子对表」。交互式调参台见会话里发布的
「玻璃按钮校准台」artifact，参考图是系统 ACTIVE 态直出、与我们的按钮等大紧贴。

**已知缺口**：窗口失活时系统控件会变灰，我们的 CSS 按钮不会 —— 页面拿不到窗口焦点态。
要补的话得由壳往 body 上打一个 class，属于另一件事。

## 不在这里的

- **`window.__dash` 动作桥、收起 web 侧边栏、rail 轨道抵消**：那些是原生分栏接管
  排版的一部分，住在 dash-layout 的 client 半边（协议两端同包：Swift 侧
  `WebViewConversationSurface` 是它们唯一的调用方）。
- **网页侧边栏的任何外观调整**（顶部让位 `topInset`、把 `sidebarCol` 刷成透明
  以透出壳的 `NSGlassEffectView`）。这是「网页侧边栏坐在原生玻璃上」那个旧世界的
  产物，已随原生侧边栏落地作废——现在只有两种形态：

  | 形态 | 谁在画侧边栏 | WebView 位置 |
  |---|---|---|
  | 原生侧边栏（常态） | dash-sidebar 占 sidebar 槽 | `NSSplitViewItem` 右侧，够不着侧边栏那一栏 |
  | 完整网页模式（逃生舱） | dsh 自己 | 全出血铺满窗口，**原样展示，不修** |

  「用网页侧边栏、但把它打扮成原生」这个中间态不存在，别再往回加。

## 安装（web profile）

```bash
# 装了 pnpm 的话，用官方入口（自动 reconcile 进 bundles）：
dsh plugin --profile web add link:~/.dsh/profiles/plugins/dash-nativeify

# 没有 pnpm：在 profile 目录手动等价操作
cd ~/.dsh/profiles/web
npx pnpm add link:~/.dsh/profiles/plugins/dash-nativeify
# 然后把 "dash-nativeify" 追加进 package.json 的 dsh.profile.bundles
```

装/删/改后重启 harness（壳应用菜单 ⌘⇧R）。

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
- 完整网页模式（逃生舱）下红绿灯会压在网页侧边栏顶部——**这是刻意接受的**：
  逃生舱的定位是「dash-layout 挂了也还能用」的降级路径，不为它做外观修补。
