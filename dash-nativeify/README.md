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
- 完整网页模式（逃生舱）下红绿灯会压在网页侧边栏顶部——**这是刻意接受的**：
  逃生舱的定位是「dash-layout 挂了也还能用」的降级路径，不为它做外观修补。
