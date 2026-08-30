# apple-kit — Apple 官方 macOS 27 UI Kit 的数值检索

给"要把界面做得像原生"的人（和 agent）用的：Apple 官方设计套件里每个控件的
**精确几何、字体、颜色、材质参数**，命令行可查。web header 贴原生那次改造
（`docs/archive/web-header-native-match-plan.md`）的所有目标数值都出自这里，可当成用法范例。

```sh
tools/apple-kit/fetch.sh                                  # 首次：匿名下载 110MB + 建索引；之后秒过
tools/apple-kit/lookup.py list 'Toolbars/Light'           # 模糊列 symbol：页 / 名 / 尺寸
tools/apple-kit/lookup.py show 'Sidebars/Light/Large/Folders/Level 0 - Selected'
tools/apple-kit/lookup.py colors 'Label'                  # 颜色变量（浅/深两套）
tools/apple-kit/lookup.py text 'Body'                     # 文字样式（字号/字重/行高）
```

`show` 会展开 symbol 的整棵层树：每层的 frame、圆角、填充（含引用的颜色变量名）、
边框、阴影、字体与颜色。例如上面那条侧边栏行给出的就是：行 240×40、选中底
r=8 `rgba(0,0,0,.11)`、标题 SFPro-Medium 15 `rgb(54,54,54)`。

## 数据从哪来、放在哪

- 来源：developer.apple.com/design/resources 的 macOS 27 UI Kit **Sketch 版**。
  它是 sketch.com 公开云文档，`fetch.sh` 走 graphql.sketch.cloud **匿名**拿下载地址
  ——不需要任何账号。选 Sketch 版是因为 `.sketch` = zip 包 JSON，全部可解析；
  Figma 版没有匿名下载，`.fig` 是私有二进制。
- 数据落 `<仓库根>/.scratch/apple-design/`（gitignore，288MB 不入库；`APPLE_KIT_DIR`
  可改落点）。每个 worktree 各自跑一次 `fetch.sh` 即可。
- Apple 出 macOS 28 套件时：到设计资源页抓新的 `sketch.com/s/<id>` 链接，
  换掉 `fetch.sh` 里的 `SHORT_ID`。

## 命名规律（`list`/grep 的钥匙）

- 控件：`<族>/<Light|Dark>/<Content Area|Over-glass>/<变体>/<1 Mn|2 Sm|3 Rg|4 Lg|5 XL>/<状态>`。
  **Content Area vs Over-glass 是一个正经维度**——同一控件在内容区和玻璃上是两套样式。
  状态一般是 `1 - Idle / 3 - Clicked / 4 - Disabled`，按钮族还有 `Active|Inactive`（窗口激活态）。
- 工具栏：页 `Titlebars and Toolbars`，其中 `…/Light/XL/*` 是 52pt 标准工具栏那套
  （项 36×36），`…/Light/Medium/*` 是 40pt 紧凑工具栏那套（项 24×24）。
  窗口整体范例在 `Windows` 页（`Unified Toolbar + Title + Sidebar` 等，含标题落点）。
- 侧边栏：`Sidebars/<Light|Dark>/<Small|Medium|Large>/…`（行高 Small 28 / Medium 34 / Large 40 一族）。
- 文字样式带编号：`01 LargeTitle … 06 Body（13pt/行高16） … 08 Subheadline（11pt） … 11 Caption2`，
  另有 `Tight/Loose Leading` 变体。
- 颜色变量：`System Colors/<Light|Dark>/N <色名>`、`Labels/<Light|Dark>[ Vibrant]/N <级>`、`Fills/…`。
- 材质：共享样式 `Liquid Glass/<Light|Dark>/Regular - Small|Medium|Large`（工具栏胶囊用 Small），
  滚动边缘效果在 `Kit` 页 `Scroll Edge Effect/*`（Hard = 纯色 + 0.67px 底边）。

**坑**：页名前面带 SF Symbols 私有区字符（终端里显示成方块或空白），对 `symbols-index.tsv`
用 `grep -P '^\S+ Buttons\t'` 这类模式匹配页名，别指望肉眼抄。

## 用这些数值的三条家规（与仓库设计立场一致）

1. 数值服务于 **web 半边** 的 CSS 模仿（surf-nativeify、web header）。原生半边不需要它
   ——真 AppKit 就在手边，`tools/shot.sh` 截图量出来的才是本机此刻的真相。
2. 颜色字体落进 CSS 时**引用本体而不是抄快照**：WebKit 支持 `-apple-system-blue` 等
   语义色与 `system-ui` 字体，套件色板只用来核对。
3. 拿不准的视觉决策截图给用户裁决；套件数值是起点，最终以"和真原生并排像不像"为准。
