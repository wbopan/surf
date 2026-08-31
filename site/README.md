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
  **984×636**——正好等于 `screen-web@2x.png` / `screen-native@2x.png` 的一半，截图原样
  放进去，一个像素都不重采样。这三个数是量出来的（机身图里屏幕黑区 x 194..2212、
  y 8..1373，内容层水平居中于画布、顶边内缩 26px@2x），改素材就得重量。
  `mac-screen-mask@2x.png` 提供屏幕的圆角与刘海缺口，`mac-shape-mask@2x.png` 提供整机
  轮廓——后者是给 `.lockup` 的 `drop-shadow` 用的，没有它阴影会是个矩形。
  **这两张遮罩在 `styles.css` 里是 base64 内联的**（遮罩是最容易在各种打开方式下悄悄
  失效的一类资源，失效时元素不是回退成"没遮罩"，而是整个消失）。目录里的 `.png` 是
  源文件，改了它得重新内联：

  ```sh
  python3 -c "import base64;print('data:image/png;base64,'+base64.b64encode(open('site/mac-screen-mask@2x.png','rb').read()).decode())"
  ```
- **字体是系统栈**（`-apple-system` 打头），不引 web font。给一个原生 Mac App 做官网，
  用平台自己的字最诚实。
- **侧边栏几何**按 `docs/sidebar-redesign-plan.md` 的目标形态画：行高 32、标题 13pt
  regular、状态槽 20、分区头 11pt Bold `rgb(178,178,178)`、搜索框 28、顶部常驻新建行、
  待处理升格为置顶分区、无分隔线。**是重设计后的形态，不是当前 HEAD。**
- **快捷键、编译耗时、包大小**逐条对过源码。改文案时请一起复查，别让页面跑在代码前面。

## 已知待办

- 页脚 `[LICENCE]` 是占位：**仓库没有 LICENSE 文件，也没有一个 `package.json` 带
  `license` 字段**。页面上挂着「View source」，上线前必须先补。
- 所有 `href="#"` 都是占位，等仓库地址与 dmg 下载地址确定后填。
- 页面上的插件模块名有四个是**提案**，与仓库实际不符：`SurfUI` 实为 `SurfNativeify`、
  `SurfKit` 实为 `SurfBridge`、`SurfSessions` 实为 `SurfSidebar`、`SurfShell` 没有对应的包
  （菜单与快捷键分散在 layout / app 两侧）。`SurfLayout` / `SurfNotify` / `SurfSettings` /
  `SurfMemory` 与实际一致。模块名由 `surf-bridge/lib/module-name.js` 从包名推导。
- **`screen-web@2x.png` 里有旧名**：侧边栏第四项写着 `surfclam`。它出现在首屏那台
  MacBook 的屏幕上，是全站最显眼的位置，上线前必须重截。
- `desktop-light@2x.jpg` / `desktop-dark@2x.jpg` 现在没有被任何地方引用。它们是给
  「窗口截图垫一张桌面」那条路线准备的，而两张 `screen-*.png` 本身已经是整屏内容，
  用不上了——重截时如果仍然截整屏，可以直接删掉这两张。
- 窗口大图与通知横幅里的会话内容是示意数据。

## 宽度

**页面本体在任何宽度下都不横滚。** reveal 段靠 `--k` 缩放整台机器来适配——`app.js` 的
`fit()` 同时按可用宽度和可用高度算，取小的那个，所以窄窗口下机身变小而不是被切掉。
`.scene` 的 `width` 跟着 `--k` 走（而 `.lockup` 固定 1204×736 再 scale），布局盒子和视觉
尺寸才不会脱节——只给 `.lockup` 加 transform 会在缩小时留下一圈空白。
