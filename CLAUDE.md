# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 这个仓库现在是什么

一组 cordis 插件 + 一个极薄的 macOS 壳（**dash**）。正在执行
**阶段二迁移**：`docs/phase2-dash-plugin-migration-plan.md` 是唯一权威计划，
动手前先读它，尤其 §0.5 不变量、§1 上游机制事实清单、§9 里程碑总表。
每完成一个里程碑在计划 §12 追加一行执行日志；发现文档与 dsh 源码冲突，
以源码为准并就地更新计划文档。

**当前进度：M0～M8 已完成，M7（通知）已放弃，下一步 M9（治理硬化）。**
壳里已经没有布局、侧边栏、通知、进程管理代码——业务残留清零，
只剩"定位 dsh、连桥、编译装载插件、给 root 槽兜底"这四件事。

**仓库放在哪里都行**——`./dev` 会补上让 `@deepseek-ai/*` 解析得到的那条符号链接。
（计划 §1.4 说仓库必须待在 `~/.dsh/profiles/` 之下，那条约束已解除，见「dsh 与插件布线」。）

```
dev                一行启动本 worktree 的整套 dash（薄封装，逻辑在 dash/bin/dash.js）
dash/              伞 bundle `@wenbo/dash`：**本仓库唯一的编排表**，不含运行时代码
  cordis.patch.yml 装哪六个插件、什么顺序、什么配置——改编排只改这里
  bin/dash.js      安装器 + 开发启动器（registry / link 两种模式自动判别）
dash-app/          壳源码为载荷的 cordis 插件：构建 + 写 endpoint 发现文件 + 拉起 app
  lib/index.js     node 半边（inject webServer）
  host/            Xcode 工程载荷：project.yml / Sources/ / Packages/DSHKit / scripts/ / tools/
dash-bridge/       唯一特权插件：Swift 载荷登记表 + /dash/bridge WS + 盯文件轮询
                   子出口 `./plugin` = createSwiftPlugin 工厂
dash-layout/       占 root 槽：分栏 + WebView 排版 + sidebar 槽 + 工具栏；
                   client 半边（lib/client.js）装 window.__dash 动作桥 + 收起 web 侧边栏
dash-sidebar/      占 sidebar 槽：原生会话侧边栏（数据面走 DSHKit 镜像）
dash-settings/     原生设置窗口：不占槽、自己一扇窗；数据面在 dsh 进程里直接
                   消费 ctx.settings（权威计划 docs/dash-settings-plan.md）
dash-nativeify/    让 dsh Web UI 摸起来像原生 App：禁橡皮筋、禁选中、原生字体度量、
                   按钮玻璃表面（四态：浅/深 × 窗口激活/失活）
                   （纯 client 半边，几乎全是 CSS，零服务依赖，无构建步骤）
tools/             跨包的开发工具（shot.sh 截图）。**判据是服务范围**：只服务一个插件的
                   工具归那个插件（如 dash-nativeify/tools/dump-css.mjs），谁都不属于的才上这儿
docs/              计划与调研文档（native-abi.md = M2 的 ABI 实测结论，spikes/ 可复跑）
dsh-web-search-firecrawl/   邻居插件：本地运行时所有，已 gitignore，不由本仓库维护
```

六个被编排的插件包名都是 `@wenbo/dash-*`（目录名不带 scope，两者的映射就是
"去掉 scope"）。**它们自己都不再声明 `dsh.bundle`**——编排权集中在伞包那张表上，
一处真相。详见下面「profile 与伞 bundle」。

## 怎么把它跑起来

```sh
./dev              # 就这一行：装好 profile 并启动（端口交给 OS 挑）
./dev --port 3080  # 想要固定端口
./dev --help       # 其余选项
```

`./dev` 幂等，随便重复跑。它会把本 worktree 的六个插件 + 伞包 link 进
profile、校正 `bundles`、然后前台跑 dsh（Ctrl-C 直达 dsh）。dash-app 随之
按需构建并拉起 App。**不需要手动 `dsh plugin add`，也不需要记 profile 名。**

`dsh --profile dash --no-open` 仍然可以直接用——`./dev` 只是替你把安装那步做了。

## 两个截然不同的开发循环

| 改什么 | 怎么生效 | 耗时 |
|---|---|---|
| **插件的 `swift/`** | 存盘即可。桥 500ms 轮询发现 → 壳重编 → 世代热替换 | **1~3s，不重启任何东西** |
| 插件的 `lib/*.js`、`package.json`、增删插件 | **必须重启 dsh**（官方在 web bundle 下 disable 了 node 侧 HMR） | 秒级 |
| `dash/cordis.patch.yml`（编排表） | 同上，**必须重启 dsh** | 秒级 |
| `lib/client.js`（dash-nativeify / dash-layout） | client 半边有 HMR，约 0.5s 自动重载；壳里 ⌘R 也行 | 秒级 |
| **壳源码 `dash-app/host/`** | dash-app 盯着它：改了后台重建，窗口右上角提示「重启生效」，点一下就换代 | 重建 2s + 重启 |

**改 Swift 插件不需要碰 dsh，也不需要重启 App。** 编译失败会带文件行号打进 dsh 终端，
旧世代继续在役，界面不变也不崩。

## 构建与运行

**必须用 `-derivedDataPath build`**——用户从 `build/Build/Products/Debug/` 启动 App，
输出到其它位置（如 `build/DerivedData/`）会导致"BUILD SUCCEEDED 但改动永远不生效"。

**app 由 dsh 拉起**：终端跑 `./dev`，dash-app 插件会按需构建并 open 出 App
（源码没变则跳过构建，App 已在运行则跳过拉起）。`./dev` 总是替你带上 `--no-open`，
免得 dsh 另开一个重复的浏览器标签页。`dev.sh` 仍在，作为同一套逻辑的手动捷径。

**改壳源码不必手动做什么**：dash-app 每 2s 比一次源码签名，变了就后台重建，
经桥播 `app-build`，壳在右上角挂一条「壳有新版本 · 重启 / 稍后」。点重启 = 壳发
`app-restart` 后自己退出，dash-app 等它死透再按新产物拉起。想省掉这一下就在
`dash/cordis.patch.yml` 的 `dash-app` row 里把 `restartOnRebuild` 打开
（代价是每次改壳都丢页面状态）。

**绝不让桥给后来者补发 `app-build`**：新连上来的壳跑的必然是磁盘上最新的产物，
补发等于骗它——`restartOnRebuild` 打开时会变成退出-重拉-又被告知该重启的无限环
（实测过）。壳侧另有一道保险丝：一个进程只自请重启一次。

```bash
# 手动捷径（不想等轮询、或 dsh 没在跑时）：
dash-app/host/scripts/dev.sh [--quit-release]

# Release 构建 + 安装到 /Applications（会退出正在运行的 Release App；
# 注意别在 Release session 里跑）
dash-app/host/scripts/build.sh [--keep-open]
```

无测试套件（`Packages/DSHKit` 里有几个解码单元测试，不在常规流程里跑）。
Debug 与 Release 是两个不同 App，可并存运行：

| | Debug（日常开发） | Release（正式） |
|---|---|---|
| App 名 | dash Dev | dash |
| Bundle ID | io.wenbo.dash.dev | io.wenbo.dash |
| 图标 | 橙色 DEV 徽章 | 原图标 |
| UI 标记 | 标题栏 DEV pill、侧边栏 DEV BUILD 条（含构建时间戳）、bootstrap 斜纹 | 无 |
| 位置 | dash-app/host/build/Build/Products/Debug/ | /Applications/ |

构建时间戳：prebuild 脚本 `scripts/write-build-timestamp.sh` 每次构建把时间写入
`Sources/Resources/BuildTimestamp.txt`（**不入库**，随 bundle 打包）。
Swift 里名字统一走 `AppInfo.displayName`（读 Info.plist，随 PRODUCT_NAME 变化）。

**壳的 Debug/Release 差异用 `#if DEBUG`；插件里不行**——插件由壳在运行时用命令行 swiftc
编译，没有 `-DDEBUG`，要判 Dev 就看 `Bundle.main.bundleIdentifier` 的 `.dev` 后缀。

## 看界面 / 驱动界面

**给 dash 窗口截图**（不需要它在前台，也不怕被别的窗口盖住）：

```bash
tools/shot.sh                 # 省略路径就落 .scratch/shot.png
tools/shot.sh --list          # 看有哪些窗口；--app 换目标，--scale 2 出 Retina
```

首次运行编译 `tools/shot.swift`（约 1s），之后源码没变直接跑缓存二进制
（缓存在 `tools/.cache/shot`）。
WKWebView 的内容照样截得到。三条实测硬事实（都写在源码注释里了）：

1. **`screencapture -l <windowID>` 在 macOS 26 上已经废了**，只会返回
   "could not create image from window"——老的 CGWindowListCreateImage 取图
   路径被移除。按窗口取图的唯一正路是 ScreenCaptureKit。
2. 命令行工具调 SCContentFilter 前**必须先碰一下 `NSApplication.shared`**，
   否则撞 `CGS_REQUIRE_INIT` 断言直接崩。
3. `SCScreenshotManager.captureImage` 的 completionHandler 是 nullable，Swift
   因此保留了"省略 handler"的 Void 重载，直接 `await` 会选中它拿到 Void——
   用 `withCheckedThrowingContinuation` 显式包一层。

**点界面**（peekaboo，`brew install steipete/tap/peekaboo`，需要屏幕录制 +
辅助功能权限）：

```bash
PID=$(pgrep -f "dash Dev.app/Contents/MacOS" | head -1)
peekaboo see   --pid "$PID" --json      # 元素树，JSON 里带 identifier 字段
peekaboo click --pid "$PID" --on elem_140
```

**一定要用 `--pid` 而不是 `--app "dash Dev"`**：按名字解析会撞
"Application inventory was incomplete"（某些进程缺 process-generation
identity），`--pid` 没这问题。点击默认走后台投递，**不抢焦点、不动光标**，
dash 全程不会被拉到前台。

AX 树**同时穿透原生和 Web 两半**——`AXWebArea` 底下是完整的 web 元素树，
所以侧边栏和 dsh Web UI 用同一套 AX 就能驱动，不必为 WebView 另走 JS 注入。

插件的 `swift/` 存盘后热替换一完成，AX 树立刻反映新的 identifier，
所以"改 → 存 → dump AX / 截图"是个几秒级的闭环，不用重启任何东西。

### accessibilityIdentifier

侧边栏关键元素挂了稳定 ID，别靠中文文案模糊匹配（文案一改就断）。命名见
`dash-sidebar/swift/SidebarView.swift` 顶部注释，形如 `sidebar.search`、
`sidebar.list`、`sidebar.group.<groupId>`、`sidebar.session.<sessionId>`。

**SwiftUI 的坑**：identifier 挂在会被合并的容器上会被拼两遍
（`sidebar.group.X-sidebar.group.X`），精确匹配就落空。分组头是靠
`.accessibilityElement(children: .ignore)` + 显式 label 收口的；
加新 identifier 后**务必 dump 一次 AX 确认没被拼重**。

## 共享 module（DashSDK / DSHKit）

这两个 module 必须**全进程只有一份**：壳链接它们，运行时编出来的插件 dylib 也链接同一份
（经 app bundle 内的同一个文件），类型身份才对得上。所以它们不走 SwiftPM 静态链接进壳，
而是：

```
scripts/build-modules.sh   → host/build-sdk/lib<M>.dylib + .swiftmodule + .swiftinterface
scripts/embed-modules.sh   → Contents/Frameworks/lib<M>.dylib（壳按 @rpath 加载）
                           + Contents/Resources/DashModules/（插件编译时 -I 的落点）
                           + 重新 ad-hoc 签名（拷贝晚于 Xcode 的签名步骤）
```

两个脚本都挂在 project.yml 的 pre/postBuildScripts 上，源码没变则秒过。
**改 DashSDK 会让所有插件的 contentHash 失效、全量重编**（工具链指纹里含它的
`.swiftinterface` 摘要），这是对的：`.swiftmodule` 对不上比慢几秒糟得多。

## dsh 与插件布线

dsh 是**全局安装**（`npm i -g @deepseek-ai/dsh@0.1.1-rc.2`，钉版本）。

**仓库可以放在任何地方**（worktree 同理）。计划 §1.4 那条"必须待在
`$DSH_HOME/profiles/` 之下"的硬约束**已经解除**——它的真实机制只是 Node 从插件
目录逐级向上找 `node_modules`、命中 `~/.dsh/profiles/node_modules/@deepseek-ai/`
（那里平铺着近 200 个包）。在仓库根补一条指向那里的符号链接，第一步就命中，
约束即刻消失。`./dev` 会**自动补这条链接**（仓库本来就在 `profiles/` 下时不建，
那时向上查找本来就能命中），`node_modules` 已在 `.gitignore` 里。

实测过：仓库整个搬到 `/tmp` 下，加上这条链接后 dsh 照常起、HTTP 200。
不加则是 `dsh plugin add` 和 `--dump-config` 都过、真 `import` 时才炸
`ERR_MODULE_NOT_FOUND`——**这个失败模式很晚才暴露，别被前两步的绿灯骗了。**

**为什么是符号链接而不是把 `@deepseek-ai/*` 真装进仓库**：cordis 的服务与
Schema 按实例身份认人，插件必须用 dsh 自己进程里的那一份。链接天然保证这点；
装一份版本号相同的副本反而会因为实例不同而出诡异的错。

`@deepseek-ai/*`（以及 `ws`）一律写 peerDependencies。
**dash-\* 之间用相对路径 import**（`../../dash-bridge/lib/plugin.js`）：包名 import 需要
npm workspace 或手工 symlink，那是机器本地状态，新克隆的仓库拿不到。

### profile 与伞 bundle

三层，别混：

- **profile** = 一张 `bundles` 清单（`<profile>/package.json`），零代码。
- **bundle** = 一张编排表（`cordis.patch.yml`），说"装哪些包、什么顺序、什么配置"，
  代码在别处。`@deepseek-ai/dsh-web-app` 就是范本：自己只有 293 行，却编排
  84 个 row、68 个依赖。
- **plugin** = 真正的代码，纯 npm 包，不声明 `dsh.bundle`。

我们的 profile 列三个 bundle，**三者平级**：

```
@deepseek-ai/dsh-base + @deepseek-ai/dsh-web-app + @wenbo/dash
```

前两个是 dsh 自带的 in-box bundle——`resolveBundleDir` 先从 dsh 安装目录解析，
**不用装、也不用列进 dependencies**。所以不存在"我们的 profile 依赖 web profile"
这回事：`web` 本身也只是 `[dsh-base, dsh-web-app]` 这两层的组合而已。

**两个必须知道的坑**（`dash/bin/dash.js` 的 `fixBundles` 就是在收拾它们）：

1. **`@deepseek-ai/dsh-web-app` 得手动列进 `bundles`。** dsh 的 `PROFILE_TEMPLATES`
   只给 `web` 和 `headless` 两个名字配了模板，别的 profile 初始化时只拿到
   `dsh-base`，web 那一层不会自己出现。
2. **六个插件绝不能出现在 `bundles` 里。** 它们已经没有 `dsh.bundle` 声明，
   列上去会让 `loadProfile` 直接 fails loud（"列为 bundle 却没有声明"是配置错误，
   不是"没有 patch"）。从旧结构升级上来的 profile 尤其要清。

### 为什么开发期要单独 link 那六个插件

`./dev` 会把六个插件**和**伞包一起 link 进 profile，看着冗余，其实必要：
**pnpm 对 `link:` 依赖不会去装被 link 目标自己的 dependencies**，而 cordis loader
解析插件包名时的锚点是 **profile 目录**——伞包自带的 `node_modules` 根本不在
Node 的向上查找链上。不 link 它们，启动即炸：

```
Cannot find package '@wenbo/dash-bridge' imported from ~/.dsh/profiles/dash/
```

发布之后没有这个问题：那时六个包是伞包真实的 npm 依赖，pnpm 会把它们平铺进
profile 的 `node_modules`。**两种形态下 `bundles` 都只有那三行**，因为编排权
始终在伞包那张表上——这正是摘掉子包 `dsh.bundle` 声明换来的好处。

### 多 worktree

一个 worktree = 一套插件 + 一个 profile + 一个 dsh + 一个 App 实例。
在任意 worktree 里跑 `./dev` 即可，三件事自动错开：

| | 怎么错开的 |
|---|---|
| profile | 主 worktree 用 `dash`，其余用 `dash-<目录名>`（`bin/dash.js` 比对 `--git-dir` 与 `--git-common-dir` 判定） |
| 端口 | 默认 `--port 0`，OS 挑空闲的。App 不受影响：实际端口由 dash-app 用 `--dash-endpoint` 直接递给它拉起的壳 |
| App 实例 | 产物路径是 `<worktree>/dash-app/host/build/...`，**本就随 worktree 不同**。实测 macOS 26 的 LaunchServices 按 bundle **路径**去重而不是 bundle id，所以同 id 的两个 App 能并存，`open` 连 `-n` 都不用 |

**已知的共享点**：`NSUserDefaults` 按 bundle id 分域，两个实例共享窗口几何与分栏宽度
（互相覆盖，无害）。要彻底隔离就给 `xcodebuild` 传 `PRODUCT_BUNDLE_IDENTIFIER=` 覆盖，
但那样 Dock 里会多一个图标，开发期不值当。

`endpoint` 发现文件**已经按 profile 分片**（`endpoints/<profile>.json`），不再互相覆盖。

### 分发形态

用户装是一行：

```sh
npx @wenbo/dash
```

`bin/dash.js` 靠"伞包的兄弟目录里有没有插件源码"自动判别模式——npx 缓存里没有兄弟，
于是走 registry 模式装 `@wenbo/dash`；在本仓库里跑就走 link 模式。同一个入口，
不需要用户记任何 flag。

**发布前还没解决的一件事**：`dash-app` 的模型是"从源码 xcodebuild 构建壳"，
而用户多半没有 Xcode（`hasXcode()` 失败会优雅缺席，结果就是没有壳）。真要分发
得 ship 预编译产物。包体积已经准备好了——`files` 白名单只收 `HASHED_ROOTS` 那四项，
`.npmignore` 再挡一道，2.8MB（不设的话 `host/build` 一个人就 393MB）。

## 架构速览

Swift/AppKit 壳 + WKWebView。**启动方向是反的**：`dsh web` 先起，其中的 dash-app 插件
构建并拉起 App；App 是 dsh 的客户端外设。App 三级定位 dsh：`--dash-endpoint` flag
（插件拉起时传入）→ endpoint 发现文件（`<AppSupport>/io.wenbo.dash/endpoints/<profile>.json`，
插件写、退出删；**一个 profile 一份**，壳这边是扫目录取候选而不是读单文件）→
都没有 = 引导页。2s 轮询兼管断连发现与自动重连。

flag 永远最优先：它由拉起本进程的那个 dsh 亲手递来，多 worktree 并存时也只指向
"我这一套"。发现文件是给手动双击起来的壳兜底的——**别删它**：用户 ⌘Q 之后 dsh
不会再拉起 App（`launch` 只在 activate 时跑一次），双击是唯一的回来路径，而双击
没有 flag。

**壳的职责一句话**：定位 dsh、连桥、编译装载插件、给 root 槽兜底、
替网页把下载与外链落地。

- `dash-app/lib/index.js`：宿主插件。源码内容 hash 决定是否重建，marker 落
  `host/build/.dash-app-source-hash.<配置>`。
- `dash-app/host/Sources/DashSDK/`：壳↔插件的 ABI 词汇（`DashPlugin` 是唯一的跨 dylib
  协议见证表；registry/objects/store/events/bridge 的实现都在 SDK dylib 里）。
- `dash-app/host/Sources/Native/`：BridgeClient（WS）、CompilerService（内容寻址编译）、
  NativePluginHost（dlopen + activate + 世代账）、GenerationLedger、ShellRootView（root 槽 +
  全出血 WebView 兜底）、WebPolicy（下载 / 外链 / 新窗口，见下条）。
- `dash-app/host/Sources/Native/WebPolicy.swift`：WKWebView 的导航策略与下载。
  **不设它，网页里"能下载的按钮"和"能跳转的链接"全部静默失效**——WKWebView 默认
  既不下载（`Content-Disposition: attachment` 的导航被 policy 中断）也不开新窗口
  （没有 uiDelegate 时 `target="_blank"` / `window.open` 直接被丢弃）。dsh 两类都用：
  会话导出 ZIP 走 `<a download>`，正文 Markdown 外链 / 搜索来源 / trajectory 的
  "打开图片"都是 `target="_blank"`。归壳不归插件：逃生舱模式（layout 缺席）也得能下载。
  隔离验证台在 `docs/spikes/webpolicy/`（可复跑）。
- `dash-app/host/Sources/MainWindowController.swift`：窗口、菜单、连接状态机、
  页内桥消息转 EventBus、壳自身构建的提示条。**没有业务 UI。**
- `dash-app/host/Sources/DiagnosticsPanel.swift`：⌥⌘D 的诊断面板（端点/桥/插件世代/
  module 名/退休 image 数/最近构建播报，可拷贝）。查"我现在跑的到底是哪份代码"用它。
- 插件门控：UA 含 `Dash/`（带斜杠，防普通子串误命中）且 URL 带 `?dash-native-sidebar=1`；
  终端 `dsh web`/普通浏览器不受影响。

### 世代替换的三条硬事实（M2 实测，见 docs/native-abi.md）

1. **旧 dylib 永不 dlclose**（对 Swift 不安全）：代码页泄漏式退休，实例由 ARC 正常回收。
2. **上游换代、下游没重编 = 沉默的认知分裂**：下游不崩不报错，只是继续调旧代的代码。
   所以桥把上游的 contentHash 折进下游的 contentHash——级联重编由数据结构保证，
   不靠任何传播逻辑。
3. **module 名取自 contentHash**（`DashSidebar_h1024d9cf21a2`）：内容寻址缓存与世代类型
   隔离是同一个事实的两面。

## 踩坑记录

- **`.gitignore` 里给构建产物写规则必须带路径锚点**：`tools/`（无斜杠前缀）匹配的是
  **任意层级**的同名目录。那条规则本意只挡 `dash-app/host/tools/` 的 xcodegen 二进制，
  实际把 `dash-nativeify/tools/dump-css.mjs` 这份源码工具一起吞了——README 里教人跑它，
  文件却从来没进过库。**失败是静默的**：`git status` 干净，克隆出来才发现少文件。
  新建 `tools/`、`build/`、`out/` 这类通用名目录后，用 `git check-ignore -v <文件>` 验一次。
- **dsh 的设置 modal 渲染在侧边栏列内部，不是 portal 到 body**：DOM 链是
  `_sidebarCol > … > _settingsArea > _overlay > _panel`。dash-layout 的原生侧边栏模式
  给整列上 `visibility: hidden`，于是 modal 点得中、挂载成功、就是看不见，且不报错
  ——而它正是 dash-settings 缺席时 ⌘, 唯一的入口。client.js 里给 `_overlay` 留了
  `visibility: visible` 的例外（overlay 是 `position: fixed`，不受 frame 平移影响）。
  推论：**给某个容器整体隐形之前，先查清有没有别人往里面挂 portal 之外的浮层。**
- dsh Web UI 类名是 hash 化 CSS module（`Md3f7G_flowItem`），语义后缀稳定，
  选择器用 `[class*="_flowItem"]` 防御式命中；升级 dsh 后失效先核对语义名。
- **WKWebView 对下载与新窗口的默认行为是静默丢弃**，不是报错：不实现
  `decidePolicyFor navigationResponse` 就没有下载，不设 `uiDelegate` 就没有新窗口，
  两者都不给任何回调、日志或视觉反馈。所以"点了没反应"这类报告先查 delegate 是否齐
  （见 `Native/WebPolicy.swift`），别去怀疑页面。
- **client 半边 `__ModuleLoader__.load({ id })` 里的 id 必须逐字等于包名**，
  它不会跟着 `package.json` 的 name 自动变。给包加 scope 那次就栽在这里：
  包名成了 `@wenbo/dash-layout`，client.js 里还写着 `id: "dash-layout"`，
  于是整棵插件树加载失败——
  `bundle …/client.js loaded without registering "@wenbo/dash-layout"`。
  **node 半边一切正常、dsh 终端一个字都没有**，只在浏览器里报，所以改包名后
  一定要真开一次窗口看看。涉及 dash-layout 与 dash-nativeify 两处。
- **client 半边 HMR 的重载顺序是「新实例先启、旧实例后清」**：ctx.effect 的 cleanup
  里无条件清理 documentElement 属性 / window 全局，会砍掉新实例刚装好的那一份。
  写全局状态必须带实例 token，cleanup 只收 token 对得上的（dash-layout/lib/client.js
  的 makeToken）。症状很像"偶发"：web 侧边栏或它的 56px rail 与原生侧边栏并排出现，
  ⌘R 就好——因为整页刷新只剩一个实例。
- **MutationObserver / ResizeObserver 别绑死 SPA 的 DOM 节点**：AppFrame 是 React
  组件，root entry 重注册会把它整个换成新节点，observer 还盯着脱离文档的旧节点，
  守护永久失效（而新的 layout store 从默认 sidebar:280 起步 = 侧边栏完整展开）。
  一次性轮询到首挂就 clearInterval 同理不够——巡检要常驻，每轮比对节点身份并迁移。
- **页面里的链接等同不可信输入**（大半是 LLM 生成的）：scheme 走白名单
  （http/https/mailto），下载目录固定 `~/Downloads` 且不采信页面给的路径分量。
  `<a href="x-某app://…">` 静默唤起本机应用是真实攻击面。
- macOS WKWebView 内部没有 NSScrollView（滚动在 Web 进程），别试图从 AppKit 层
  控制页面滚动；SPI `_setRubberBandingEnabled:` 会引发滚动闪动，已弃用——
  页面滚动全靠插件注入的 CSS。
- **绝不往 session 日志写自定义 event type**：0.1.1-rc.2 会导致
  `SessionFormatUnsupportedError`、会话无法重新读取。桥的流量走自己那条 WS。
- **`ctx.logger` 在 `dsh web` 下没有 exporter**：消息只进环形缓冲，终端一个字看不见。
  要给终端前的人看的进度必须自己写 stderr（dash-app / dash-bridge 都是两边都喂）。
- **别覆写 `NSSplitViewController.loadView()`**：默认实现会把 splitView 装成 view，
  换成空 `NSView` 窗口直接全白。
- **`NSHostingController.sizingOptions` 默认含 `.preferredContentSize`**：槽内插件每换一代
  重建视图都会把分栏拉成 SwiftUI 内容的 fitting 宽度，用户调好的宽度就没了。设成 `[]`。
