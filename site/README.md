# Surf 的项目官网

纯静态：`index.html` + `styles.css` + `app.js` + 几张图。没有构建步骤，没有依赖，
直接丢进任何静态托管（GitHub Pages 之类）就能跑。

```sh
python3 -m http.server -d site 8000   # 然后开 http://localhost:8000
```

**要用 `http://` 看，别双击 `index.html`。** Safari 在 `file://` 下会拦掉页面自己去加载
的本地图片，主视觉那台 MacBook 连同屏幕里的截图会整个不显示——页面其余部分照常，
所以这个故障看起来像"reveal 段坏了"，其实只是打开方式不对。

## 结构

导航 → 状态条 → 主视觉 → 应用窗口大图 → 「壳，不是分叉」→
**Swift 插件深色段**（引擎 + 代码 + 三条事实）→ **插件切换区**（左 8 项、右示意）→
规格 → 源码/写插件/报缺口 → 页脚

## 三条纪律

1. **一个字号阶梯、一个 8px 间距节奏、一个强调色。** 字号档位在 `styles.css` 顶部
   （`.display` / `.title` / `.subtitle` / `.lead` / `.copy` / `.note` / `.label`），
   加新样式前先看能不能用现成的那一档。
2. **左对齐的区块共用一个左边缘**（`.wrap-wide`，1200）。`.wrap`（980）只给居中的
   主视觉用。两种容器混在相邻区块里会露出来。
3. **插件区的界面示意始终是浅色。** 它是产品的照片，不该跟着页面深浅色反转——`.mock`
   自带一套固定色板。例外是 reveal 段的 MacBook：机身随 `prefers-color-scheme` 在
   银色与深空灰之间切换，屏幕里的截图不换。

## 数值从哪来

- **强调色 `#0E8A94`** 取自 `surf-app/host/Icons/AppIcon.icon/icon.json` 的
  `automatic-gradient`。它只是图标的颜色，不承载任何主题含义。
- **MacBook 是照片，不是 CSS**。`mac-light@2x.jpg` / `mac-dark@2x.jpg` 是 2408×1472 的
  机身图，所以 reveal 段的设计空间是 **1204×736**；屏幕坐落在 **(110, 17)**，尺寸
  **984×636**——正好等于 `screen-web@2x.jpg` / `screen-native@2x.jpg` 的一半，截图原样
  放进去，一个像素都不重采样。这三个数是量出来的（机身图里屏幕黑区 x 194..2212、
  y 8..1373，内容层水平居中于画布、顶边内缩 26px@2x），改素材就得重量。
  `mac-screen-mask@2x.png` 提供屏幕的圆角与刘海缺口，`mac-shape-mask@2x.png` 提供整机
  轮廓——后者是给 `.lockup` 的 `drop-shadow` 用的，没有它阴影会是个矩形。
  遮罩失效时元素不是回退成"没遮罩"，而是整个消失——所以 reveal 段一片空白时，先确认
  是不是用 `file://` 打开的（见开头）。
- **两张屏幕截图是同一个会话的对照**：`screen-web@2x.jpg` 是它在 Chrome 里的样子，
  `screen-native@2x.jpg` 是同一个会话在 Surf 窗口里的样子。整屏截（含菜单栏与 Dock），
  两次的窗口位置要尽量一致——wipe 扫过去时对不齐会很明显。原始截图是 3024×1964，
  从**底部**（Dock 下方的空隙）裁到 3024×1955 才是 1968:1272 的比例，再缩到
  1968×1272，最后用 `sips` 编码成 JPEG（PNG 存的话两张各自超过 1.2 MB，不划算）：

  ```sh
  sips -s format jpeg -s formatOptions 90 mid.png --out screen-web@2x.jpg
  ```
- **`.shot` 这个类名在 `styles.css` 里只能有一处定义。** 全局是 `box-sizing: border-box`，
  reveal 段的 `.shot` 又靠 `height: 636px` 精确对位——文件前半段一旦另有一条 `.shot`
  带 `padding`，图就被压进内容盒里，下方露出 `.screen` 的黑底，看起来像图片被垂直
  压扁了。这个坑排查起来极贵，因为症状长得像浏览器的解码 bug。
- **字体是系统栈**（`-apple-system` 打头），不引 web font。给一个原生 Mac App 做官网，
  用平台自己的字最诚实。
- **侧边栏几何与状态符号**照 `surf-sidebar/swift/` 画，改那边就要回来改这里：行高 32、
  标题 13pt regular、分区头 18 高 11pt Bold `rgb(178,178,178)`（`SidebarView.swift` 的
  `SessionRow` / `SectionHeaderStyle`）、状态槽 20（`StatusIndicator.slot`）、搜索框 28、
  顶部常驻新建行、无分隔线。**状态不置顶提行**：默认分组是按工作区，状态只是行首那个符号；
  分成待处理 / 进行中 / 已结束是「筛选」里「按状态」那一档的事（`SidebarFilter.swift`
  的 `Mode`、`SidebarModel.swift` 的 `StatusBuckets`）。
- **五个状态符号**是页面顶部那张 `<svg class="sprite">`，用 `<use>` 引。四个是从系统符号
  实描下来的（`hand.raised` / `questionmark` / `exclamationmark.triangle` 13pt、
  `checkmark` 12pt，按 `StatusIndicator.swift` 要的字号排进 20pt 槽），颜色取 Apple UI Kit
  的浅色系统色；「正在运行」是手画的系统转轮，那是个控件、不是符号。**不画彩色圆底**。
- **快捷键、编译耗时、包大小**逐条对过源码。改文案时请一起复查，别让页面跑在代码前面。

## 已知待办

- **两张屏幕截图是真实会话，不是示意数据**，上线前逐项过一遍：会话标题、`Home` 路径里的
  用户名、浏览器标签栏、菜单栏上挂的第三方工具、composer 上显示的模型名，全都会随页面
  公开。
- 插件切换区里的界面示意与通知横幅仍是示意数据。

## 上线

`.github/workflows/pages.yml` 把 `site/` 整个发到 GitHub Pages
（`https://wbopan.github.io/surf/`），push 到 main 且动了 `site/**` 就跑。仓库设置里
Pages 的 source 要选 GitHub Actions。**站点挂在 `/surf/` 子路径下**，所以两页里的资源
与页内链接一律相对（`styles.css`、`surf.png`、`index.zh.html`、logo 是 `./`），
一条都不能以 `/` 开头。

## 宽度

**页面本体在任何宽度下都不横滚。** reveal 段靠 `--k` 缩放整台机器来适配——`app.js` 的
`fit()` 同时按可用宽度和可用高度算，取小的那个，所以窄窗口下机身变小而不是被切掉。
`.scene` 的 `width` 跟着 `--k` 走（而 `.lockup` 固定 1204×736 再 scale），布局盒子和视觉
尺寸才不会脱节——只给 `.lockup` 加 transform 会在缩小时留下一圈空白。
