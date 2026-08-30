# spike：`-apple-visual-effect` 在**不透明窗口**里成不成立

P2 的实测台。权威计划 `docs/archive/native-feel-upgrade-plan.md` §3 P2 列了三个问题，
这份 README 就是答案；手册背景见 `docs/extend/webview-native-feel.md` §1.1、附录 A。

**和手册附录 A 的唯一实质差异：窗口 `isOpaque = true`。** Raycast 那套是透明窗口 +
桌面采样（计划 §4 已明确不采纳），surf 是文档型 App，窗口不打算透明——
所以"材质在不透明窗口里还成不成立、采样到什么"必须自己测，这就是本 spike 的理由。

## 怎么复跑

```sh
./run.sh                                    # 开私有开关（默认）
SURF_SPIKE_NO_SYSTEM_APPEARANCE=1 ./run.sh  # 对照组：不开开关
SURF_SPIKE_DUMP_MENU=plain ./run.sh         # 转储右键菜单（还有 selection / link）
                                            # → build/menu-dump-<场景>.txt，转储完自动退出
SURF_SPIKE_DUMP_MENU=plain SURF_SPIKE_EMPTY_MENU=1 SURF_SPIKE_DUMP_DELAY=8 ./run.sh
                                            # 把菜单裁空，看 AppKit 露不露空框
                                            # （DELAY 留出把窗口弄到前台的时间）

swiftc -O sample.swift -o build/sample      # 量各胶囊平均色的小工具
./build/sample shot-active.png
```

产物全在 `build/`（gitignore）。截图用 peekaboo 而不是 `tools/shot.sh`——
后者要跑它的终端有屏幕录制权限，这台机器上没给：

```sh
peekaboo see --app "VisualEffect Spike" --no-elements --path shot-active.png
```

**两条踩坑，别重复踩**：

1. **`open -n` 之后 App 未必是 key**（终端把焦点抢回去了）。三张截图里有两张一开始
   都拍成了失活态，而页面上写着"窗口：失活"——**判据在页面自己身上**，不是靠回忆
   自己有没有点过。要真的激活就 `open <bundle>`（不带 `-n`），`osascript … activate`
   实测时灵时不灵（CLAUDE.md 早记过这条）。
2. **peekaboo 截激活态与失活态时带的阴影厚度不一样**（实测 2000×1504 vs 2110×1598），
   两张图直接按像素比就错位。所以页面画了两枚品红基准方块（`.fid`），
   `sample.swift` 靠它们定位视口原点，取样区写成**归一化比例**——
   committed 的截图为了控体积缩到 1200px 宽，写死像素的话工具对自己的产物就失效了。

## 三个问题的实测答案

### ① 不透明窗口里 glass material 采样到什么？

**采样身后的页面内容，不是黑块。** 见 `shot-active.png`：页面自己画了一层
彩色渐变 + 45° 斜条纹，四枚玻璃胶囊与大面板底下的条纹被**抹平/折射**掉了，
颜色则是身后渐变的模糊平均——胶囊左边偏橙、面板右段转青，跟着背景走。
边缘还带着液态玻璃自己的一圈高光描边（那是材质造型语言的一部分，关不掉）。

数值（`build/sample shot-active.png`，视口归一化取样，1200px 宽的 committed 图）：

| 取样区 | R | G | B |
|---|---|---|---|
| 材质 media-controls | 255.00 | 204.68 | 182.71 |
| 材质 subdued | 255.00 | 208.67 | 168.53 |
| 材质 glass-material | 254.91 | 226.02 | 174.02 |
| 材质 clear | 222.24 | 212.95 | 163.13 |
| 材质 blur-material | 255.00 | 233.42 | 221.78 |
| 参照 纯 CSS 手绘 | 243.95 | 205.63 | 159.79 |
| 参照 纯色 28% 黑 | 164.27 | 162.28 | 130.85 |
| 参照 裸背景（右侧） | 90.48 | 191.68 | 191.55 |

**对 P3 的意义：不透明窗口不是障碍。** 我们要的正是"胶囊控件采样身后的页面内容"，
而这恰好是不透明窗口能给的全部——透明窗口那条路（采样桌面）本来也不想要。

顺带两条：

- `-apple-system-vibrancy-label` 生效，文字在材质上照常可读。
- 材质是真实合成层：`clear` 明显比其它三档透，`blur-material`（传统
  NSVisualEffectView 那套）比 glass 家族更白更糊——五个值在同一张图里区分得开。

### ② `CSS.supports` 在开关打开前后是否翻转？

**翻转，而且是干脆的全有全无。** 对照组 `shot-switch-off.png`
（`SURF_SPIKE_NO_SYSTEM_APPEARANCE=1`）里：

- `CSS.supports('-apple-visual-effect', …)` 九个值**全部 ✘**（打开时全部 ✔）。
- `getComputedStyle(...).getPropertyValue('-apple-visual-effect')` 回读成 `""`
  （打开时回读成 `"-apple-system-glass-material-media-controls"`）。
- 视觉上四枚玻璃胶囊**整个消失**——`.fx` 层没有任何 background，材质不生效就什么
  都不画，只剩文字浮在渐变上。数值上材质取样区退回裸渐变色（media-controls
  244.72/158.18/132.57，与身后背景一致），而两个参照（纯 CSS 手绘、纯色）纹丝不动。

**一条计划里没有的发现**：`-apple-system-*` **颜色关键字不受这个开关管**——
`CSS.supports('color', '-apple-system-label' / '-apple-system-blue' /
'-apple-system-control-background')` 在开关关闭时**照样是 ✔**。手册 §1.1 说
"同一开关还解锁 `-apple-system-*` 颜色关键字"，在本机 WebKit 上**不成立**。
对 P3/P4 是好消息：想用系统语义色不必绑私有开关。

**对 P3 的意义**：`@supports (-apple-visual-effect: …)` 门控是可靠的——探测为假时
材质**什么都不画**，所以 `@supports` 块外必须留着完整的手绘栈（计划里本来就是这么写的），
不能写成"块外只留一半、指望材质补另一半"。

**"开关对 dsh 页面其余渲染有无副作用"这一问答不了**——本 spike 是一张自造的静态页，
没有 dsh 的表单、代码块、图片。**待真 App 验证**：P2 的壳侧改动落地后，
`./dev` 起真 App 走查一遍（表单控件、代码块、图片、滚动条），那才是这条的答案。

### ③ 失活时材质自己会不会变哑光？

**不会，一个像素都不变。** 这是本 spike 最硬的一条结论。

页面**刻意没有给材质写任何 `[window-blurred]` 覆盖规则**（只把窗口 key 态显示在
副标题上），所以 `shot-active.png` 与 `shot-inactive.png` 的差别只应该来自材质自己。
实测两张图的取样值**逐位相同**（上表那八行，两张图一字不差），而两个文件的 md5
不同、副标题一张写"激活"一张写"失活"、红绿灯一张有色一张灰——**图是新鲜的，
材质就是没动**。

**对 P3 的意义**：计划 §3 P3 里"失活态沿用 `data-surf-blur` 切换、blur 时
`-apple-visual-effect: none` 回落到现有失活 3 层"的方案是**必须的**，不是可选的
优化——系统不会替我们做这件事。至于用 `-subdued` 当失活态，本机实测它与
`media-controls` 在同一背景上只差几个色阶（208.67 vs 204.68 的 G），
**不足以表达"失活"**，别指望它。

## 附带产物：右键菜单 identifier 转储（给 P5）

P5 要按 `WKMenuItemIdentifier*` 裁菜单，而这些常量**没有公开头文件**，
`dlsym` 也取不到（本机实测全部 MISSING，SDK 的 `WebKit.tbd` 里倒是列着 45 个符号）。
所以从真菜单里读回来——`MenuDumpWebView` 覆写 `willOpenMenu` 把每项打出来：

```
# 场景=plain（正文空白处）
WKMenuItemIdentifierReload           | Reload
<nil>                                | ---
<nil>                                | ---
WKMenuItemIdentifierInspectElement   | Inspect Element

# 场景=selection（选中一段文字）
WKMenuItemIdentifierLookUp                | Look Up “…”
WKMenuItemIdentifierTranslate             | Translate “…”
<nil>                                     | ---
WKMenuItemIdentifierSearchWeb             | Search with Google
<nil>                                     | ---
WKMenuItemIdentifierCopy                  | Copy
WKMenuItemIdentifierCopyLinkWithHighlight | Copy Link with Highlight
<nil>                                     | ---
WKMenuItemIdentifierShareMenu             | Share…
<nil>  <nil>  <nil>                       | ---
WKMenuItemIdentifierSpeechMenu            | Speech submenu(2)
<nil>                                     | ---
WKMenuItemIdentifierInspectElement        | Inspect Element

# 场景=link（链接上）
WKMenuItemIdentifierOpenLink              | Open Link
WKMenuItemIdentifierOpenLinkInNewWindow   | Open Link in New Window
WKMenuItemIdentifierDownloadLinkedFile    | Download Linked File
WKMenuItemIdentifierCopyLink              | Copy Link
<nil>                                     | ---
WKMenuItemIdentifierShareMenu             | Share…
<nil>                                     | ---
WKMenuItemIdentifierInspectElement        | Inspect Element
```

五条给 P5 的事实：

1. **identifier 的字面量就等于常量名**（`WKMenuItemIdentifierReload` 而不是
   `com.apple.WebKit.reload` 之类）——白名单可以直接写字符串，不必去链私有符号。
2. **分隔符的 identifier 是 nil**，而且 WebKit 会留下**连着好几条**分隔符
   （selection 场景里有连着三条）。所以裁完之后必须再收一轮"首尾与连续的分隔符"，
   否则菜单里会出现空档。
3. **"Services" 和 "Ask Siri" 是 AppKit 在 `willOpenMenu` 之后自己加的**——转储里
   一个都没有，屏幕上（`selection` 场景实拍）却有：顶上一条 Ask Siri、
   底下一条 Services 子菜单。**所以 P5 不需要、也没法"保留 Services"**，
   它压根不经过我们的手；上面那几条连续 nil 分隔符正是给它们留的位子。
4. **把菜单裁空不会露出空框**。实拍验证过（`SURF_SPIKE_DUMP_MENU=plain
   SURF_SPIKE_EMPTY_MENU=1`，正文空白处右键 → `menu.removeAllItems()`）：
   屏幕上一个菜单框都没有，就像没右键过。这条很关键——**Release 下正文空白处
   的默认菜单只有 Reload + 两条分隔符**（`isInspectable` 只在 Debug 开，
   所以 Release 连 Inspect Element 都没有），P5 裁完就是空的，
   而"空 = 什么都不弹"正是原生文档 App 的行为，不必为它写特例。
   *但*菜单跟踪的模态循环照样进（进程在那 3 秒里 `asyncAfter` 不触发），
   所以是"看不见的菜单开着"，下一次点击把它关掉——观感上无差别。
5. 转储用的是**进程内合成 NSEvent**（`window.sendEvent` 一个 rightMouseDown），
   不是 CGEvent 也不是 peekaboo：这个 ad-hoc 签名的 spike 没有可读的 AX 树
   （`peekaboo see --tree` 报 "AX tree incomplete"），而 CGEvent 得先知道窗口的屏幕坐标。

## 文件

| 文件 | 是什么 |
|---|---|
| `Probe.swift` | demo app：不透明窗口 + 私有开关 + 菜单转储 |
| `index.html` | 彩色渐变背景 + 五档材质胶囊 + 两个对照组 + `CSS.supports` 探测表 |
| `run.sh` | 编译成 .app 并打开 |
| `sample.swift` | 从截图里量各胶囊平均色（靠品红基准方块对齐） |
| `shot-active.png` | 开关打开 · 窗口激活 |
| `shot-inactive.png` | 开关打开 · 窗口失活（与上一张材质逐位相同） |
| `shot-switch-off.png` | 开关关闭 · 窗口激活（材质全灭，`CSS.supports` 全 ✘） |
