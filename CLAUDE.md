# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 这个仓库现在是什么

一组 cordis 插件 + 一个极薄的 macOS 壳（**surfclam**）。

**曾用名 dash（更早为 DSHarness）**，2026-08 整体更名：项目与 App 叫 surfclam，
伞包 `@wenbo/surfclam`，内部插件 `@wenbo/clam-*`，Swift 类型 `Clam*`。
`docs/phase2-clam-plugin-migration-plan.md` 里的 `dash` / `dash-*` / `Dash*` 均为
**当时的命名**，那份文档是历史档案，正文没有跟着改名。

**阶段二迁移**的唯一权威计划就是上面那份档案，
动手前先读它，尤其 §0.5 不变量、§1 上游机制事实清单、§9 里程碑总表。
每完成一个里程碑在计划 §12 追加一行执行日志；发现文档与 dsh 源码冲突，
以源码为准并就地更新计划文档。**读它时把里面的旧名字按上面那张映射换算过来。**

**当前进度：M0～M8 已完成，下一步 M9（治理硬化）。**（M7 曾被放弃，后来以
`clam-notify` 插件的形态做成了，权威计划见 `docs/clam-notify-plan.md`。）
壳里已经没有布局、侧边栏、通知、进程管理代码——业务残留清零，
只剩"定位 dsh、连桥、编译装载插件、给 root 槽兜底、替系统 delegate 转交给插件"
这五件事。

**仓库放在哪里都行**——`./dev` 会补上让 `@deepseek-ai/*` 解析得到的那条符号链接。
（计划 §1.4 说仓库必须待在 `~/.dsh/profiles/` 之下，那条约束已解除，见「dsh 与插件布线」。
凡本文提到「计划 §x」，指的都是上面那份**历史档案**里的章节号。）

```
dev                一行启动本 worktree 的整套 surfclam（薄封装，逻辑在 surfclam/bin/surfclam.js）
surfclam/          伞 bundle `@wenbo/surfclam`：**本仓库唯一的编排表**，不含运行时代码
  cordis.patch.yml 装哪些插件、什么顺序、什么配置——改编排只改这里
  bin/surfclam.js  安装器 + 开发启动器（registry / link 两种模式自动判别）
clam-app/          壳源码为载荷的 cordis 插件：构建 + 写 endpoint 发现文件 + 拉起 app
  lib/index.js     node 半边（inject webServer）
  host/            Xcode 工程载荷：project.yml / Sources/ / scripts/ / tools/
clam-bridge/       唯一特权插件：Swift 载荷登记表 + /clam/bridge WS + 盯文件轮询
                   子出口 `./plugin` = createSwiftPlugin 工厂（`CommandDeclaration`
                   的权威文档也在那个文件里）、`./locale` = 语言决议小工具。
                   **register() 一律 fails loud**：module 名非法（scoped 包名当 name）、
                   swiftDir 不存在/空、重复登记，三种都当场抛而不是 warn
clam-layout/       占 root 槽：分栏 + WebView 排版 + sidebar 槽 + 开放的 `toolbar` 贡献槽
                   （工具栏按钮全部来自贡献，本插件自己一颗都不放；**眼下整条工具栏
                   只有 clam-sidebar 的「筛选」这一条**——clam-header 停用后它那四格
                   也没了，⌘N「新建会话」是 commands 声明的菜单项而不是工具栏按钮。
                   贡献的拓扑用 `ToolbarSpec`（clam-layout/swift/LayoutContracts.swift，
                   契约的权威；汇总表在 docs/clam-contracts.md）：
                   region=sidebar|content 决定落在分隔线哪侧、align=leading|trailing
                   决定夹在 flexibleSpace 哪边、spaced 决定要不要断开玻璃胶囊、
                   sizing=fixed|dynamic 决定要不要冻死宽度，全部缺省成老行为；
                   四条渲染路线由 kind 选：button / group / menu / view，另有一条
                   `menu` block 路线给"内容由贡献方本地状态决定"的菜单）；
                   client 半边（lib/client.js）装 window.__clam 动作桥 + 收起 web 侧边栏
clam-sidebar/      占 sidebar 槽：原生会话侧边栏（搜索 + 全部/按时间/待处理三枚胶囊 +
                   两行会话行 + 工具栏「筛选」菜单）。**数据面在 node 半边**
                   （订宿主服务与事件，投影经桥推 JSON；Swift 只管画和发动作）
clam-header/       **2026-08-29 起在编排表里注释停用**（效果不满意，退回 web header；
                   代码原样保留，解开 cordis.patch.yml 那两行即恢复）。
                   把主内容区的 web header 搬进原生：**标识走 window.title/subtitle**
                   （Mail / Notes 那条裸文字），工具栏只剩四格可操作的原生
                   `NSToolbarItem` 子类（段控=ItemGroup / 子代理与 mode=MenuToolbarItem
                   +badge / 导出=按钮），排版、显示模式、溢出全归 AppKit。
                   **判据是一条设计原则：圆胶囊是"可操作"的承诺**——锁定后的
                   agent preset、只读的后台任务都退进 subtitle，不做成假按钮。
                   **两条通道同时用**：
                   active view 走页内桥（真相在浏览器），会话与 preset 走 node 半边
                   （真相在 dsh）。web header 由 client 半边折叠，插件退休就自动还原。
                   面包屑不只是文字：末段带**子代理计数下拉**、子代理段是**兄弟切换器**，
                   点开是原生重画的 catalog 树——**子代理会话不进侧边栏，这是唯一入口**
                   （docs/native-subagent-catalog.md）
clam-notify/       桌面通知：不占槽、不贡献界面，缺席即无通知。**数据面在 node 半边**
                   （订 apiProxy.events.mux 的只读广播流，维护一份待办清单；按钮答案
                   经 apiProxy.respond 回去，先到先得）；Swift 只管发通知、判"要不要
                   打扰"、报"人在看哪个会话"。它同时是**「有什么在等着你」的唯一真相**
                   ——经 `clamPending` 服务供给 clam-sidebar 那枚「待处理」胶囊
clam-settings/     原生设置窗口：不占槽、自己一扇窗；四栏编排照抄 dsh Web 设置对话框。
                   数据面在 dsh 进程里直接消费 ctx.settings / llm / credentials /
                   agentPresets / pluginInventory（权威计划 docs/clam-settings-plan.md）
clam-nativeify/    让 dsh Web UI 摸起来像原生 App。**三半边**：client 半边是主力
                   （禁橡皮筋、禁选中、原生字体度量、按钮玻璃表面——四态：浅/深 ×
                   窗口激活/失活；HEADER 段把 web header 调成 macOS 27 工具栏形态
                   ——52pt 单行、玻璃胶囊、可点矩形上报给壳的拖动条放行，权威计划
                   docs/web-header-native-match-plan.md；全是 CSS，无构建步骤）；
                   node 半边注册设置 ns
                   `clam-nativeify`（两项：对话区字号、header 滚动模糊带开关
                   headerScrollBlur——关掉退 Hard 形态不透明底，细线不受开关管；
                   client 半边订它）并把
                   **dsh 的 `ui-theme` 投影给 swift 半边**；swift 半边不占槽、不贡献
                   界面，只按投影设 `NSApp.appearance` 与主窗口 `backgroundColor`
                   （消首帧/resize 露底闪色）。**主题的真相始终是 dsh，原生侧只跟随**，
                   不另建第二偏好源。读法：ns `ui-theme` / 键 `preference`，值
                   light|dark|system（权威在 `@deepseek-ai/dsh-client-ui-theme`）。
                   settings 缺席即不投影 = 原生侧维持系统外观，CSS 照常首帧生效
tools/             跨包的开发工具（shot.sh 截图；apple-kit/ = Apple 官方 macOS 27 UI Kit
                   的数值检索——**做"像原生"的设计前先查它**，用法见其 README）。
                   **判据是服务范围**：只服务一个插件的
                   工具归那个插件（如 clam-nativeify/tools/dump-css.mjs），谁都不属于的才上这儿
docs/              计划与调研文档（native-abi.md = M2 的 ABI 实测结论，spikes/ 可复跑）。
                   **两份契约文档**：clam-contracts.md（跨插件字符串约定的汇总表——
                   commands / ToolbarSpec / 事件主题 / 保管箱键 / hook 名 / 页内桥；
                   **权威始终在代码里**，这份只是索引）与 plugin-author-guide.md
                   （写给仓库外的插件作者：三种骨架、命名规则、接进编排、外部热循环）
dsh-web-search-firecrawl/   邻居插件：本地运行时所有，已 gitignore，不由本仓库维护
```

被编排的插件包名都是 `@wenbo/clam-*`（目录名不带 scope，两者的映射就是
"去掉 scope"）。**它们自己都不再声明 `dsh.bundle`**——编排权集中在伞包那张表上，
一处真相。详见下面「profile 与伞 bundle」。

## 怎么把它跑起来

```sh
./dev              # 就这一行：装好 profile 并启动（端口交给 OS 挑）
./dev --port 3080  # 想要固定端口
./dev --help       # 其余选项
```

`./dev` 幂等，随便重复跑。它会把本 worktree 的各插件 + 伞包 link 进
profile、校正 `bundles`、然后前台跑 dsh（Ctrl-C 直达 dsh）。clam-app 随之
按需构建并拉起 App。**不需要手动 `dsh plugin add`，也不需要记 profile 名。**

`dsh --profile surfclam --no-open` 仍然可以直接用——`./dev` 只是替你把安装那步做了。

## 两个截然不同的开发循环

| 改什么 | 怎么生效 | 耗时 |
|---|---|---|
| **插件的 `swift/`** | 存盘即可。桥 500ms 轮询发现 → 壳重编 → 世代热替换 | **1~3s，不重启任何东西** |
| 插件的 `lib/*.js`、`package.json`、增删插件 | **必须重启 dsh**（官方在 web bundle 下 disable 了 node 侧 HMR）。**菜单项/快捷键的 `commands` 声明也在这一行**——它住在 node 半边，而且不进 contentHash，所以单独改它连 snapshot 都不会推 | 秒级 |
| `surfclam/cordis.patch.yml`（编排表） | 同上，**必须重启 dsh** | 秒级 |
| `lib/client.js`（clam-nativeify / clam-layout） | client 半边有 HMR，约 0.5s 自动重载；壳里 ⌘R 也行 | 秒级 |
| **壳源码 `clam-app/host/`** | clam-app 盯着它：改了后台重建，窗口右上角提示「重启生效」，点一下就换代 | 重建 2s + 重启 |

**改 Swift 插件不需要碰 dsh，也不需要重启 App。** 编译失败会带文件行号打进 dsh 终端，
旧世代继续在役，界面不变也不崩。

## 构建与运行

**必须用 `-derivedDataPath build`**——用户从 `build/Build/Products/Debug/` 启动 App，
输出到其它位置（如 `build/DerivedData/`）会导致"BUILD SUCCEEDED 但改动永远不生效"。

**app 由 dsh 拉起**：终端跑 `./dev`，clam-app 插件会按需构建并 open 出 App
（源码没变则跳过构建，App 已在运行则跳过拉起）。`./dev` 总是替你带上 `--no-open`，
免得 dsh 另开一个重复的浏览器标签页。`dev.sh` 仍在，作为同一套逻辑的手动捷径。

**改壳源码不必手动做什么**：clam-app 每 2s 比一次源码签名，变了就后台重建，
经桥播 `app-build`，壳在右上角挂一条「壳有新版本 · 重启 / 稍后」。点重启 = 壳发
`app-restart` 后自己退出，clam-app 等它死透再按新产物拉起。想省掉这一下就在
`surfclam/cordis.patch.yml` 的 `clam-app` row 里把 `restartOnRebuild` 打开
（代价是每次改壳都丢页面状态）。

**绝不让桥给后来者补发 `app-build`**：新连上来的壳跑的必然是磁盘上最新的产物，
补发等于骗它——`restartOnRebuild` 打开时会变成退出-重拉-又被告知该重启的无限环
（实测过）。壳侧另有一道保险丝：一个进程只自请重启一次。

```bash
# 手动捷径（不想等轮询、或 dsh 没在跑时）：
clam-app/host/scripts/dev.sh [--quit-release]

# Release 构建 + 安装到 /Applications（会退出正在运行的 Release App；
# 注意别在 Release session 里跑）
clam-app/host/scripts/build.sh [--keep-open]
```

无测试套件。唯一一处单元测试在 clam-sidebar 的 node 半边（分叉标题规则 +
会话数据源的分组/去抖/翻牌行为，后者拿假 apiProxy 跑，不需要 dsh）：

```sh
node --test clam-sidebar/test/*.test.js   # 零依赖、约 2s，不在常规流程里跑
```

给 `--test` 一个**目录**在 node 26 上会直接 `MODULE_NOT_FOUND`（它去 require 那个
目录本身而不是遍历），别省那个通配符。
Debug 与 Release 是两个不同 App，可并存运行：

| | Debug（日常开发） | Release（正式） |
|---|---|---|
| App 名 | Surfclam Dev | Surfclam |
| Bundle ID | io.wenbo.surfclam.dev | io.wenbo.surfclam |
| 图标 | 橙色 DEV 徽章 | 原图标 |
| UI 标记 | bootstrap 斜纹 | 无 |
| 位置 | clam-app/host/build/Build/Products/Debug/ | /Applications/ |

构建时间戳：prebuild 脚本 `scripts/write-build-timestamp.sh` 每次构建把时间写入
`Sources/Resources/BuildTimestamp.txt`（**不入库**，随 bundle 打包）。
Swift 里名字统一走 `AppInfo.displayName`（读 Info.plist，随 PRODUCT_NAME 变化）。

**壳的 Debug/Release 差异用 `#if DEBUG`；插件里不行**——插件由壳在运行时用命令行 swiftc
编译，没有 `-DDEBUG`，要判 Dev 就看 `Bundle.main.bundleIdentifier` 的 `.dev` 后缀。

## 看界面 / 驱动界面

**给 surfclam 窗口截图**（不需要它在前台，也不怕被别的窗口盖住）：

```bash
tools/shot.sh                 # 省略路径就落 .scratch/shot.png
tools/shot.sh --list          # 看有哪些窗口（带 pid）；--app 换目标，--scale 2 出 Retina
tools/shot.sh --app 60435     # **多 worktree 并存时只有 pid 分得开**
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
PID=$(pgrep -f "Surfclam Dev.app/Contents/MacOS" | head -1)
peekaboo see   --pid "$PID" --tree --no-screenshot   # 元素树 → elem_N
peekaboo click --pid "$PID" --on elem_140
```

**一定要用 `--pid` 而不是 `--app "Surfclam Dev"`**：按名字解析会撞
"Application inventory was incomplete"（某些进程缺 process-generation
identity）。但 `--pid` 只救得了 `see` 和 `click`——**`verify` 内部仍会全量枚举
应用**，照样撞、返回 `unknown`。要确认状态就截图，别指望 verify。

**别用文本 query 点击**（`peekaboo click "会话"`）：它把文案解析成*坐标*，经常落在
死点上，报 "No pressable accessibility element was found"。这句极易被误读成"这个
控件不可访问"，其实控件好好的、只是坐标错了——**先 `--tree` 拿 `elem_N` 再
`--on`**。`--json` 在 4.2.2 是坏的（整个 `data` 回来是 `null`），所以上面用 `--tree`。

点击默认走后台投递，**不抢焦点、不动光标**，surfclam 全程不会被拉到前台。

AX 树**同时穿透原生和 Web 两半**——`AXWebArea` 底下是完整的 web 元素树，
所以侧边栏和 dsh Web UI 用同一套 AX 就能驱动，不必为 WebView 另走 JS 注入。

插件的 `swift/` 存盘后热替换一完成，AX 树立刻反映新的 identifier，
所以"改 → 存 → dump AX / 截图"是个几秒级的闭环，不用重启任何东西。

### accessibilityIdentifier

侧边栏关键元素挂了稳定 ID，别靠中文文案模糊匹配（文案一改就断）。命名见
`clam-sidebar/swift/SidebarView.swift` 顶部注释，形如 `sidebar.search`、
`sidebar.list`、`sidebar.group.<groupId>`、`sidebar.session.<sessionId>`。

**SwiftUI 的坑**：identifier 挂在会被合并的容器上会被拼两遍
（`sidebar.group.X-sidebar.group.X`），精确匹配就落空。分组头是靠
`.accessibilityElement(children: .ignore)` + 显式 label 收口的；
加新 identifier 后**务必 dump 一次 AX 确认没被拼重**。

### 苹果官方设计数值（tools/apple-kit）

做"贴原生"的视觉工作（尺寸、字号、颜色、材质参数）**先查 Apple 官方 macOS 27
UI Kit，别凭记忆估**：`tools/apple-kit/fetch.sh` 一次匿名下载（110MB，落
`.scratch/`），`lookup.py list|show|colors|text` 按名字检索到每个控件的层级几何。
命名规律、用法范例和"数值只服务 web 半边、原生半边截图量真 AppKit、CSS 引用
`-apple-system-*` 而不抄 hex"三条家规都写在 `tools/apple-kit/README.md`。
成功案例：web header 贴原生（`docs/web-header-native-match-plan.md` §1 的目标列全部出自它）。

## 共享 module（ClamSDK）

共享 module 必须**全进程只有一份**：壳链接它，运行时编出来的插件 dylib 也链接同一份
（经 app bundle 内的同一个文件），类型身份才对得上。所以它不走 SwiftPM 静态链接进壳，
而是：

```
scripts/build-modules.sh   → host/build-sdk/lib<M>.dylib + .swiftmodule + .swiftinterface
scripts/embed-modules.sh   → Contents/Frameworks/lib<M>.dylib（壳按 @rpath 加载）
                           + Contents/Resources/ClamModules/（插件编译时 -I 的落点）
                           + 重新 ad-hoc 签名（拷贝晚于 Xcode 的签名步骤）
```

两个脚本都挂在 project.yml 的 pre/postBuildScripts 上，源码没变则秒过。
机制本身是多 module 的，**但眼下只剩 ClamSDK 一个**：另一个曾经的住户 DSHKit
（dsh 的 wire 模型 + 会话镜像）随 M10 整体退役——数据面搬进 clam-sidebar 的 node
半边了。`embed-modules.sh` 只拷不删，所以在旧的 `build/` 里可能还躺着
`libDSHKit.dylib` 的残骸；`rm -rf build` 重来一次就干净了。

**`build-modules.sh` 的跳过判据里含构建参数（TARGET、swiftc 版本），不只是源码 hash**
——只按源码算的话，改了部署目标而源码没动会被判成"未变动，跳过"，`.swiftinterface`
里还写着旧三元组，插件跟着用旧目标编，新 API 报 "only available in macOS 27.0 or
newer"，而脚本刚刚打印了"跳过"。**报错在插件那边，原因在这个脚本的缓存里。**
**改 ClamSDK 会让所有插件的 contentHash 失效、全量重编**（工具链指纹里含它的
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
**clam-\* 之间用相对路径 import**（`../../clam-bridge/lib/plugin.js`）：包名 import 需要
npm workspace 或手工 symlink，那是机器本地状态，新克隆的仓库拿不到。

### profile 与伞 bundle

三层，别混：

- **profile** = 一张 `bundles` 清单（`<profile>/package.json`），零代码。
  我们这张叫 `surfclam`（多 worktree 时是 `surfclam-<目录名>`）。
- **bundle** = 一张编排表（`cordis.patch.yml`），说"装哪些包、什么顺序、什么配置"，
  代码在别处。我们这张是伞包 `@wenbo/surfclam`（目录 `surfclam/`）。
  `@deepseek-ai/dsh-web-app` 就是范本：自己只有 293 行，却编排 84 个 row、68 个依赖。
- **plugin** = 真正的代码，纯 npm 包，不声明 `dsh.bundle`。我们这些叫 `@wenbo/clam-*`。

我们的 profile 列三个 bundle，**三者平级**：

```
@deepseek-ai/dsh-base + @deepseek-ai/dsh-web-app + @wenbo/surfclam
```

前两个是 dsh 自带的 in-box bundle——`resolveBundleDir` 先从 dsh 安装目录解析，
**不用装、也不用列进 dependencies**。所以不存在"我们的 profile 依赖 web profile"
这回事：`web` 本身也只是 `[dsh-base, dsh-web-app]` 这两层的组合而已。

**两个必须知道的坑**（`surfclam/bin/surfclam.js` 的 `fixBundles` 就是在收拾它们）：

1. **`@deepseek-ai/dsh-web-app` 得手动列进 `bundles`。** dsh 的 `PROFILE_TEMPLATES`
   只给 `web` 和 `headless` 两个名字配了模板，别的 profile 初始化时只拿到
   `dsh-base`，web 那一层不会自己出现。
2. **被编排的插件绝不能出现在 `bundles` 里。** 它们已经没有 `dsh.bundle` 声明，
   列上去会让 `loadProfile` 直接 fails loud（"列为 bundle 却没有声明"是配置错误，
   不是"没有 patch"）。从旧结构升级上来的 profile 尤其要清。

### 为什么开发期要单独 link 那些插件

`./dev` 会把各插件**和**伞包一起 link 进 profile，看着冗余，其实必要：
**pnpm 对 `link:` 依赖不会去装被 link 目标自己的 dependencies**，而 cordis loader
解析插件包名时的锚点是 **profile 目录**——伞包自带的 `node_modules` 根本不在
Node 的向上查找链上。不 link 它们，启动即炸：

```
Cannot find package '@wenbo/clam-bridge' imported from ~/.dsh/profiles/surfclam/
```

发布之后没有这个问题：那时它们是伞包真实的 npm 依赖，pnpm 会把它们平铺进
profile 的 `node_modules`。**两种形态下 `bundles` 都只有那三行**，因为编排权
始终在伞包那张表上——这正是摘掉子包 `dsh.bundle` 声明换来的好处。

### 多 worktree

一个 worktree = 一套插件 + 一个 profile + 一个 dsh + 一个 App 实例。
在任意 worktree 里跑 `./dev` 即可，三件事自动错开：

| | 怎么错开的 |
|---|---|
| profile | 主 worktree 用 `surfclam`，其余用 `surfclam-<目录名>`（`bin/surfclam.js` 比对 `--git-dir` 与 `--git-common-dir` 判定） |
| 端口 | 默认 `--port 0`，OS 挑空闲的。App 不受影响：实际端口由 clam-app 用 `--clam-endpoint` 直接递给它拉起的壳 |
| App 实例 | 产物路径是 `<worktree>/clam-app/host/build/...`，**本就随 worktree 不同**。实测 macOS 26 的 LaunchServices 按 bundle **路径**去重而不是 bundle id，所以同 id 的两个 App 能并存，`open` 连 `-n` 都不用 |

**已知的共享点**：`NSUserDefaults` 按 bundle id 分域，两个实例共享窗口几何与分栏宽度
（互相覆盖，无害）。要彻底隔离就给 `xcodebuild` 传 `PRODUCT_BUNDLE_IDENTIFIER=` 覆盖，
但那样 Dock 里会多一个图标，开发期不值当。

**`<AppSupport>/io.wenbo.surfclam/` 下的三样东西都已经按实例分片**，别再假设"日志只有一份"：

| 文件 | 分片键 | 不分片会怎样 |
|---|---|---|
| `endpoints/<profile>.json` | profile | 后启动的抹掉先启动的，被抹的那套再也接不到手动双击的壳 |
| `logs/surfclam.<worktree>.log`（壳自己写） | **产物所在 worktree 目录名**（`ClamPaths.instanceTag` 从 bundle 路径里抠） | 两个 App 实例 bundle id 相同、追加写同一文件，**邻居 worktree 的插件编译错误混进你的日志**，长得和自己的一模一样 |
| `logs/clam-app-build.<profile>.<配置>.log`（node 侧写） | profile | 这份是**覆盖写**：邻居一构建就把你整份换掉，终端指给你的路径里躺着别人的错误 |

壳的日志跟着**产物**分片而不是跟着连上的 dsh：断连重连可以换 dsh，跑的代码始终是自己那份。
装到 `/Applications` 的 Release 全机只有一份，仍是无后缀的 `surfclam.log`。
拿不准该看哪个文件就开 ⌥⌘D，「路径」一栏写的是本进程日志的**全路径**。
（分片是新增的，老的 `surfclam.log` / `clam-app-build.<配置>.log` 还躺在目录里，删掉即可。）

**新 worktree 有两样本地状态不在库里，`./dev` 替你补齐**，别手动折腾：

1. `node_modules` 那条符号链接（解析 `@deepseek-ai/*`，见上一节）。
2. **`clam-app/host/tools/xcodegen`**——二进制，被 `.gitignore` 那条带锚点的
   `/clam-app/host/tools/` 挡在库外（规则是对的，二进制不该入库），于是新克隆和
   新 worktree 里都没有它，而 `clam-app/lib/index.js` 与
   `host/scripts/{dev,build}.sh` 都直接 spawn 它。

第 2 条缺了会**安静地**毁掉整个壳：dsh 照常起、HTTP 200，只是
`spawn …/tools/xcodegen ENOENT` 埋在
`~/Library/Application Support/io.wenbo.surfclam/logs/clam-app-build.<profile>.Debug.log` 里，
终端只留一句"clam-app 优雅缺席"。`bin/surfclam.js` 的 `ensureXcodegen` 现在按
**同仓库的其它 worktree → PATH 上的 `xcodegen`** 的顺序取件并拷过来；两处都没有
就打印补法（`brew install xcodegen`）而不是让它静默缺席。三个调用点也各自加了
存在性检查，报错直接说补法。

拷贝而不是链接，是为了"主 worktree 被删掉也不会突然变回 ENOENT"；
**拷进去不会触发壳的全量重建**——`HASHED_ROOTS` 明确把 `tools/` 排除在源码 hash 之外。

### 分发形态

用户装是一行：

```sh
npx @wenbo/surfclam
```

`bin/surfclam.js` 靠"伞包的兄弟目录里有没有插件源码"自动判别模式——npx 缓存里没有兄弟，
于是走 registry 模式装 `@wenbo/surfclam`；在本仓库里跑就走 link 模式。同一个入口，
不需要用户记任何 flag。

**发布前还没解决的一件事**：`clam-app` 的模型是"从源码 xcodebuild 构建壳"，
而用户多半没有 Xcode（`hasXcode()` 失败会优雅缺席，结果就是没有壳）。真要分发
得 ship 预编译产物。包体积已经准备好了——`files` 白名单只收 `HASHED_ROOTS` 那几项，
`.npmignore` 再挡一道，2.8MB（不设的话 `host/build` 一个人就 393MB）。

## 架构速览

Swift/AppKit 壳 + WKWebView。**启动方向是反的**：`dsh web` 先起，其中的 clam-app 插件
构建并拉起 App；App 是 dsh 的客户端外设。App 三级定位 dsh：`--clam-endpoint` flag
（插件拉起时传入）→ endpoint 发现文件（`<AppSupport>/io.wenbo.surfclam/endpoints/<profile>.json`，
插件写、退出删；**一个 profile 一份**，壳这边是扫目录取候选而不是读单文件）→
都没有 = 引导页。2s 轮询兼管断连发现与自动重连。

flag 永远最优先：它由拉起本进程的那个 dsh 亲手递来，多 worktree 并存时也只指向
"我这一套"。发现文件是给手动双击起来的壳兜底的——**别删它**：用户 ⌘Q 之后 dsh
不会再拉起 App（`launch` 只在 activate 时跑一次），双击是唯一的回来路径，而双击
没有 flag。

**没有 flag 时，候选先按"是不是我这一套"排，再按 `startedAt` 倒序。**
判据是硬事实而不是名字推断：clam-app 把自己的 `clam-app/host` 绝对路径写进发现文件
（`hostDir`），壳从自己的 bundle 路径算出同一个值比对（`ClamPaths.ownHostDir` ↔
`ClamEndpoint.isOwn`）。只按 `startedAt` 排会**安静地连错**：双击起来的壳挑中邻居
worktree 最近启动的那个 dsh，于是去编译**邻居的**插件源码——编译失败时那条错误
原样落进自己的日志，读日志的人完全看不出它属于别人家（实测过，日志里冒出本
worktree 根本没有的插件名）。自己那套没在跑时仍然会退到邻居（总比引导页有用），
但接入那行日志与 ⌥⌘D 都会标出「⚠️ 不是本 worktree 那一套」。

**壳的职责一句话**：定位 dsh、连桥、编译装载插件、给 root 槽兜底、
替网页把下载与外链落地。

- `clam-app/lib/index.js`：宿主插件。源码内容 hash 决定是否重建，marker 落
  `host/build/.clam-app-source-hash.<配置>`。
- `clam-app/host/Sources/ClamSDK/`：壳↔插件的 ABI 词汇（`ClamPlugin` 是唯一的跨 dylib
  协议见证表；registry/contributions/objects/store/events/bridge 的实现都在 SDK dylib 里）。
  **两种槽，别混**：`ClamRegistry` 是单占用"替换槽"（一槽一主，后来者覆盖，
  给 root/sidebar 这种独占表面用）；`ClamContributions` 是多占用"贡献槽"
  （一槽 N 条，`(owner, id)` 是身份，各家追加互不影响，给工具栏按钮这种
  "谁都可以来一条"的表面用）。贡献槽只收容器不收词汇——载荷就是视图工厂
  加一份 `metadata: [String: Any]`，键名由占槽的消费方自己定义并写在自己家里
  （`toolbar` 槽的**权威是 `clam-layout/swift/LayoutContracts.swift` 的
  `public struct ToolbarSpec`**——有类型的属性 + `metadata()`，贡献方按名字引，
  拼错就编不过；加键改那个 struct，别再手写字面量字典。
  消费方仍然读字典：SDK 容器中立不变。汇总表在 `docs/clam-contracts.md` §2）。
  窗口标识另有一条通道：`clam.window.title`（载荷 `title` / `subtitle`），
  由 clam-layout 消费；空标题 = 交回给壳。它和 `titlebarMetrics` 一样是**状态型**
  消息，走 `emitSticky`——粘性总线会替晚到的订阅者补一份。
  （曾经各配过一条 `clam.window.requestTitle` / `clam.layout.requestTitlebarMetrics`
  让后到者自己喊，P0 #4 一并删了。**新写这类消息一律 `emitSticky`，别再配 request 通道。**）
  拓扑键：`label` / `order` / `region` / `align` / `spaced` / `kind` /
  `symbol` / `items` / `priority` / `sizing`，**一变就重建整条工具栏**。
  会变的东西（徽标数字、菜单内容、段控选中态、显隐）不走 metadata，走活通道
  `clam.toolbar.update`，实现在 `clam-layout/swift/ToolbarContribution.swift`。
  `kind` 决定用哪个 `NSToolbarItem` 子类（`button`/`group`/`menu`），
  缺省 `view` = 塞一个 `NSHostingView`——**能用前三个就别用它**，
  自定义视图拿不到显示模式、玻璃分组、徽标和溢出退让。
  另有 `ClamHooks`：**应答钩子表**，给"系统要求在启动完成前就注册好、而实现在插件里"
  这类事情用（`handle(hook:owner:version:_:)` 登记，壳侧 `dispatch` 派发，没人应答
  就走系统默认）。表里没有任何具体业务的词汇——第一个用户是通知，但 URL scheme、
  Dock 拖放、Services、NSUserActivity 都是同一个形状，**再来一个不需要改 SDK**。
- `clam-app/host/Sources/Native/`：BridgeClient（WS）、CompilerService（内容寻址编译）、
  NativePluginHost（dlopen + activate + 世代账）、GenerationLedger、ShellRootView（root 槽 +
  全出血 WebView 兜底）、WebPolicy（下载 / 外链 / 新窗口，见下条）、
  SystemDelegateRelay（占住系统 delegate，经 `ClamHooks` 转交插件，见下条）。
- `clam-app/host/Sources/Native/SystemDelegateRelay.swift`：在
  `applicationDidFinishLaunching` 的第一句就占住那些**必须在启动完成前装好**的系统
  delegate（眼下是 `UNUserNotificationCenter`），把回调拍平成字典经 `ClamHooks` 问一遍
  插件，再把答案翻回系统要的形状。**运行时装载的插件永远不可能自己占这些位子**
  （见「踩坑记录」那条），这里是唯一的转交点。壳侧只有转发，没有业务判断。
- `clam-app/host/Sources/Native/WebPolicy.swift`：WKWebView 的导航策略与下载。
  **不设它，网页里"能下载的按钮"和"能跳转的链接"全部静默失效**——WKWebView 默认
  既不下载（`Content-Disposition: attachment` 的导航被 policy 中断）也不开新窗口
  （没有 uiDelegate 时 `target="_blank"` / `window.open` 直接被丢弃）。dsh 两类都用：
  会话导出 ZIP 走 `<a download>`，正文 Markdown 外链 / 搜索来源 / trajectory 的
  "打开图片"都是 `target="_blank"`。归壳不归插件：逃生舱模式（layout 缺席）也得能下载。
  隔离验证台在 `docs/spikes/webpolicy/`（可复跑）。
- `clam-app/host/Sources/MainWindowController.swift`：窗口、菜单、连接状态机、
  页内桥消息转 EventBus、壳自身构建的提示条。**没有业务 UI。**
  **壳里没有任何一条业务命令的名字**（曾经有整整一张会话菜单硬编码在四处）。
  业务菜单项由插件的 node 半边声明——`createSwiftPlugin({ commands: [...] })`，
  **形状的权威是 `clam-bridge/lib/plugin.js` 的 `CommandDeclaration` typedef**
  （汇总在 docs/clam-contracts.md §1），经桥 snapshot 到壳。一份声明喂四样东西：
  菜单项、默认键位、⌘/ 面板、clam-app 现拼的 `clam-shortcuts` 设置 schema。
  `setupMenus()` 因此拆成**系统惯例段（硬编码：⌘W/⌘Q/编辑菜单/⌘R/缩放/⌥⌘D/⌘⇧R/⌘/）
  + 贡献遍历段**；顶注讲的是这两段怎么拼，不再是命令词汇表。
  按下去只 `emit(menuCommand, ["command": id, …])`，谁声明谁应答：
  newSession/openSettings/stopGenerating 归 clam-layout（openSettings 由
  clam-settings 也声明一次，先登记的赢），会话导航（⌘⇧[ ]、⌘1-9、⌘⌥A）与
  归档/重命名/聚焦搜索归 clam-sidebar（`SidebarShortcuts`，顺序真相 =
  `SidebarFilterState.orderedSessions`，和列表画的是同一份）；没人应答就静默无事。
  **插件缺席时那条菜单项根本不出现**（不是灰着）——它连声明都没到过。
  九个 `@objc` 业务 selector 收成了一个 `runCommand(_:)`，命令名挂在
  `representedObject`：命令名是插件给的字符串，壳编译期一个都不认得。
  缩放（⌘±，`pageZoom` + UserDefaults）与 ⌘/ 快捷键面板是壳本地动作，不走 emit。
  Esc 停止生成在 clam-layout 的 **client 半边**（走停止按钮同款的
  scoped `conversation.cancel()` 服务路径，不点 DOM；dsh 页面自己不绑 Esc）。
  页内桥**不设白名单**：`postMessage({type, ...})` 的任意 type 一律广播成
  `clam.page.<type>`（`ClamEventBus.Topic.pagePrefix`），插件订阅即可，不用改壳。
  ready/currentSession/debug 留特化分支只因为壳自己也要用它们。
- `clam-app/host/Sources/DiagnosticsPanel.swift`：⌥⌘D 的诊断面板（端点/桥/插件世代/
  module 名/退休 image 数/最近构建播报，可拷贝）。查"我现在跑的到底是哪份代码"用它。
- 插件门控：UA 含 `Clam/`（带斜杠，防普通子串误命中）且 URL 带 `?clam-native-sidebar=1`；
  终端 `dsh web`/普通浏览器不受影响。
  **那个参数名壳不认得**：壳只订粘性主题 `clam.web.query`（载荷 `[参数名: 值]`），
  按载荷拼 URL、不一致才 reload；定义权在占 `root` 槽的插件手里
  （clam-layout 的 `LayoutPlugin.webQueryTopic` / `nativeSidebarParam`）。
  壳侧还记着上次那份（UserDefaults `clam.webQuery`）——页面必须在插件编译完成之前
  就开始加载，那一刻还没有任何插件说过话。

### 世代替换的三条硬事实（M2 实测，见 docs/native-abi.md）

1. **旧 dylib 永不 dlclose**（对 Swift 不安全）：代码页泄漏式退休，实例由 ARC 正常回收。
2. **上游换代、下游没重编 = 沉默的认知分裂**：下游不崩不报错，只是继续调旧代的代码。
   所以桥把上游的 contentHash 折进下游的 contentHash——级联重编由数据结构保证，
   不靠任何传播逻辑。
3. **module 名取自 contentHash**（`ClamSidebar_h1024d9cf21a2`）：内容寻址缓存与世代类型
   隔离是同一个事实的两面。

## 踩坑记录

- **`.gitignore` 里给构建产物写规则必须带路径锚点**：`tools/`（无斜杠前缀）匹配的是
  **任意层级**的同名目录。那条规则本意只挡 `clam-app/host/tools/` 的 xcodegen 二进制，
  实际把 `clam-nativeify/tools/dump-css.mjs` 这份源码工具一起吞了——README 里教人跑它，
  文件却从来没进过库。**失败是静默的**：`git status` 干净，克隆出来才发现少文件。
  新建 `tools/`、`build/`、`out/` 这类通用名目录后，用 `git check-ignore -v <文件>` 验一次。
  反过来，**被正确挡住的构建输入也要有人补**：`clam-app/host/tools/xcodegen` 就是
  这样一份"该挡、但缺了整个壳就没了"的文件，兜底在 `./dev` 里（见「多 worktree」）。
- **广播式事件总线 + 运行时装载的插件 = 晚到的订阅者什么都不知道**：插件必然晚于
  壳启动，也可能晚于页面第一次报告状态。描述**状态**的消息（当前会话、当前端点）
  必须用 `ClamEventBus.emitSticky` 而不是 `emit`——不粘的话订阅者要等到下一次变化
  才知道，而那个状态**可能不再变**（用户打开 app 就一直待在同一个会话里），于是
  它永远不知道。描述**瞬间**的消息（菜单被按了一下）不该粘。粘不粘由 emit 的一方
  按语义决定，总线本身不认识任何具体主题。
- **退格键的菜单 keyEquivalent 要写 U+0008，不是它按下去发出的 U+007F**：AppKit 的
  菜单匹配在这一处**做了归一化**——keyEq 0x08 ↔ 退格键 ⌫（事件字符 0x7F），
  keyEq 0x7F ↔ **前向删除 ⌦**（事件字符 NSDeleteFunctionKey U+F728）。写成 0x7F 的
  症状：菜单里键符那格是空白（`[⌘⇧]`），⌘⇧⌫ 永远不触发，⌘⇧⌦ 反而会。曾经用
  `NSEvent.keyEvent(...)` 手拼事件得出"必须写 0x7F"的相反结论——那条路绕过了
  归一化。**验菜单键位一律用 `CGEvent(keyboardEventSource:virtualKey:keyDown:)` 造
  真实键码事件再 `NSEvent(cgEvent:)`**，然后 `menu.performKeyEquivalent(with:)`；
  看 `peekaboo menu list --pid` 里键符是不是画得出来也是个快速判据。
- **`UNNotificationInterruptionLevel.passive` 的意思是"不弹横幅"，不是"安静一点"**：
  设成它的通知直接躺进通知中心，屏幕上一点动静都没有，而日志里照常写着"已发送"
  ——看上去像系统设置（定时摘要 / 专注模式）出了问题，实际是自己配的。要静就把
  `content.sound` 留空，别动 interruptionLevel。
- **`UNUserNotificationCenter.delegate` 在启动完成之后再设会被静默忽略**：
  `center.delegate` 读回来跟你设的一模一样，`willPresent` / `didReceive` 就是永远
  不触发。Apple 那句 "assign before your app finishes launching" 是硬约束。
  推论对整类 API 成立——**运行时编译装载的插件天然在启动之后才存在，所以它永远
  不可能自己占这种位子**。转交机制是 `ClamHooks` + `Native/SystemDelegateRelay.swift`：
  壳在启动第一句占位、经钩子问插件。再遇到同形状的东西（URL scheme、Dock 拖放、
  Services）照这个套，别去改 SDK 的词汇。
- **不占槽的插件没有生命周期锚**：占槽的插件有 registry → 视图闭包 → model 这条
  天然强引用链，不占槽的（clam-notify 这种）在 `activate` 里 new 出来的对象没人持有，
  函数一返回就被 ARC 回收，所有 `[weak self]` 异步回调静默变 nil。症状极其误导——
  "上线"日志照常打印，然后什么都不发生，像是数据没来。**让 `activate` 返回那个对象**
  （它自己再持有 `ClamPluginHandle`），壳按住返回值就是锚。
- **"清掉上一次运行留下的东西"这类动作不能挂在 `activate` 上**：Swift 热替换每改一行
  就 activate 一次，于是每次都把当前正当值班的东西一起扫掉（clam-notify 是屏幕上的
  通知）。按进程收口的办法是往 `host.objects` 里插一个标记键——保管箱天然是进程级的。
- **别把清理逻辑只挂在 `ClamPluginHandle` 的析构上**。壳换代时 `loaded[name]` 一换、
  旧 `LoadedPlugin` 本该是最后一个强引用，但实测四十多次换代里 handle 只 deinit 过三次
  ——注册撤销之所以没出事，是因为 registry 用 token 校验兜住了"新的赢"，跟析构没关系。
  **没有 token 兜底的东西（窗口是典型）就会积累**：每改一次 Swift 多叠一扇设置窗口。
  可靠的做法是把资源放进 `host.objects`，新一代 `activate` 时主动收拾上一代留下的那份。
  **存 AppKit 类型而不是自定义类型**——世代之间类型身份隔离（module 名取自 contentHash），
  `as? 自定义类` 跨代必然失败，`as? NSWindow` 才成立。
- **SwiftUI 在 `NSTabViewController(tabStyle: .toolbar)` 里够不着工具栏**：`.searchable`
  于是一个像素都不画，且不报错。要原生搜索框只能包 `NSSearchField`
  （clam-settings/swift/SettingsChrome.swift）。同一处还记着另外三条 `Form` 版式的坑
  （`Divider()` 在 `LabeledContent` 里变竖线、`EmptyView()` label 让整行塌成全宽、
  `.safeAreaInset` 塞不进 bordered list 的边框）——写偏好设置版式前先读那份 README。
- **多显示器下 peekaboo 的按元素点击会间歇失灵**（`Bridge operation target attribution
  failed` / `axElementNotFound`），尤其当同 App 还有一扇无标题的"自动填充"面板时。
  截图不受影响。卡住时重启 App 通常能恢复；别在这上面耗，改用探针从数据面验。
- **dsh 的设置 modal 渲染在侧边栏列内部，不是 portal 到 body**：DOM 链是
  `_sidebarCol > … > _settingsArea > _overlay > _panel`。clam-layout 的原生侧边栏模式
  给整列上 `visibility: hidden`，于是 modal 点得中、挂载成功、就是看不见，且不报错
  ——而它正是 clam-settings 缺席时 ⌘, 唯一的入口。client.js 里给 `_overlay` 留了
  `visibility: visible` 的例外（overlay 是 `position: fixed`，不受 frame 平移影响）。
  推论：**给某个容器整体隐形之前，先查清有没有别人往里面挂 portal 之外的浮层。**
- dsh Web UI 类名是 hash 化 CSS module（`Md3f7G_flowItem`），语义后缀稳定，
  选择器用 `[class*="_flowItem"]` 防御式命中；升级 dsh 后失效先核对语义名。
  **但优先找 `[data-slot="<槽名>"]`**：每个槽 outlet 都带这个属性（`display: contents`，
  不产生盒子），它是槽系统的一等契约而不是样式副产物，比任何类名都稳。
  主内容区 header 的锚点就是 `[data-slot="conversation.session.header"]`，
  header 本体是它的 `firstElementChild`。
- **AppKit 的 contentView 不是翻转坐标系**（原点在左下角，UIKit 才是左上）：
  `window.contentLayoutGuide.frame.minY` 恒为 ~0，量标题栏高度要写
  `contentView.bounds.maxY - guide.frame.maxY`。症状是"算出来永远是 0"，
  很容易误判成 layoutGuide 没生效。顺带：`NSLayoutGuide` 的属性叫 `.frame`，
  `layoutFrame` 是 UIKit 的名字。
- **`Label` 放进 `Menu` 的 label 位会被 macOS 折叠成 icon-only**（文字消失）。
  换成显式 `HStack { Image(systemName:); Text(...) }`。`labelStyle` 救不了——
  那个改的是渲染样式，这里是 `Menu` 对 `Label` 的特化处理。
- **`pointer-events: none` 不挡合成事件**：对零尺寸、已禁指针的元素
  `dispatchEvent(new MouseEvent("click"))` 照样生效。所以"把 web 控件折叠掉"
  和"仍然用它来驱动"不冲突，不需要临时恢复可见性。
- **别的 worktree 的壳会串进来**：endpoint 发现是"扫目录取候选"，另一个 worktree
  里跑着的 `Surfclam Dev` 会连上本 worktree 的 dsh，拿它自己那份 ClamSDK 编译本仓库的
  Swift 源码，刷出一串对不上号的 `编译失败：… @ <陌生 hash>`，而本地 `git diff`
  干干净净。**判据是 hash**：自己那套的 hash 会留在
  `~/Library/Application Support/io.wenbo.surfclam/native-plugins/generations/<Module>/`
  底下，陌生的不会。`pgrep -af "Surfclam Dev.app/Contents/MacOS"` 数一下实例数即可确认。
- **工具栏底下那条带子只能由页面画**（原生三条路全试过，都不给"纯模糊无装饰"）：
  `titlebarAppearsTransparent = false` 给的是**不透明**背景，模糊就没了；
  `NSVisualEffectView` **采不到** WKWebView 那层 remote layer 的像素（和
  `NSGlassEffectView` 并排压在 WebView 上实测，只有后者糊得动网页文字）；
  `NSGlassEffectView` 采得到，但自带一圈边缘高光，那是液态玻璃的造型语言、关不掉。
  所以带子是 `clam-header/lib/client.js` 的 `backdrop-filter` ——
  **页面 compositor 是唯一看得见内层滚动的东西**，这不是将就。
- **macOS 26 的 scroll edge effect 不是"一条带子"，是"浮元素的形状"**：
  Apple 原话是效果 "applied underneath toolbar items / titlebar accessories"、
  "varies the size and shape based on the content floating above it"。载体是私有类
  `NSScrollPocket`，由**滚动内容视图自己画**（`NSScrollView` 与 WKWebView 各自实现
  pocket 协作方法），标题栏只做外观协调——**盯着标题栏找开关就是找错了地方**。
  三条实测：① 给一个**真实可见**、6000pt 内容、滚到 2600 的 `NSScrollView`，
  它确实造出了 pocket、`hasScrolledContentsUnderTitlebar=1`，**条纹照样原样穿过
  带子**，只有工具栏胶囊底下被糊；② `NSTitlebarAccessoryViewController` 的
  `preferredScrollEdgeEffectStyle`（26.1）只给**已存在**的效果选软硬，自己不召唤，
  装上 `.soft` 逐像素零变化；③ `webView.obscuredContentInsets`（公开，26.0）真能
  造出 pocket，但风格默认 `Hard` = 纯色（`Soft` 是 Safari 专用 SPI），且只认
  **主 frame** 的 scrollOffset——dsh 滚的是内层 div，主 frame 永远在顶，
  而且设了 insets 之后 layout viewport 会缩小、内容根本不会渲染进带子区域。
  **"toolbar 天然有效果"是对的，而且它此刻就在生效**——只是长在工具栏项的胶囊里。
- **`window.title` 是贪心的，会把 content·leading 的工具栏项顶走**：它要为长标题
  留截断空间，于是分隔线右边那些 leading 贡献被一路推到 flexibleSpace 那侧。
  日志打出来的顺序完全正确、界面上却贴着右边一组，极易误判成"align 没生效"。
  想紧挨标题放东西，正路是 `window.subtitle`，不是 leading 贡献。
  （Mail / Notes 本来也不在标题右边放按钮——标题一侧只有文字，动作全在另一头。）
- **`window.subtitle` 里放不了图标**：macOS 的 SF Symbols 是图片资源
  （`NSImage(systemSymbolName:)`），不是可嵌进字符串的字体——遍历系统字体两段 PUA，
  `cube` / `gearshape.2` 一个都查不到，整个 Plane 15 只有 1 个码点有 glyph。
  而 `subtitle` 只吃 `String`，连 `NSAttributedString` 都不收。几何字符替代也试过
  一排（⬢ ⬡ ◆ ❖ ▣ ⧉ ◈ ⬧），11pt 下六边形糊成圆点、空心的站不住——都只像噪点。
- **窗口被完全遮挡或不在当前 Space 时，AppKit 暂停绘制**，`tools/shot.sh`（SCK）
  返回的是**冻结的陈旧帧**——"能截到"不等于"是新的"。验新鲜度：改一个
  `window.subtitle` 之类的可见值再截一张比对。
- **装上 `NSToolbar` 会把壳的拖动条压死**，标题栏一下子拖不动、双击也不放大。
  壳在 contentView 顶部放了块 `WindowDragRegionView`（40pt，见
  `MainWindowController.swift`）来补 `fullSizeContentView` 的拖动区，可
  **titlebar 容器排在 contentView 之上**，`NSToolbarTitleView` 铺满整个内容区
  宽度（实测 764×52）把它整个遮住。而 AppKit 自己也不接手——壳注释里那条
  实测是对的：这个窗口形态下 `mouseDownCanMoveWindow` **不生效**（复核过，
  从 `NSThemeFrame` 到 `NSToolbarTitleView` 整条链都是 `true`，照样纹丝不动）。
  两边同时失效，**不报任何错**。最坑的是它只坏一半：侧边栏那半照常能拖
  （title view 从 x=260 起，够不着），最顶 4pt 也能拖——"有时能拖"极易
  误判成偶发。修在 `clam-layout` 的 `installTitlebarDrag()`：用
  local monitor 只接管 `NSToolbarTitleView` 那块地，路上撞见 `NSControl` 就放行。
- **CGEvent 合成事件送不进不在当前 Space（或非前台）的窗口**：光标照样会动
  （`mouseMoved` 生效、`AXIsProcessTrusted()` 也是 `true`），但 `leftMouseDown`
  根本不进 App，于是每个采样点都"拖不动"——**纯假阴性**，会把人带到完全错误的
  方向去查。判据是在 App 里装一个 `NSEvent.addLocalMonitorForEvents`：一条都收不到
  就说明事件没到，先把窗口弄到当前 Space 再测。`osascript` 设 `frontmost` 返回
  `true` 也**不代表**真的切过去了。同理，任何"改代码前后对比"的结论都必须
  跑一次关掉修复的对照组，否则分不清是修复生效还是窗口位置变了。
- **`NSMenu.delegate` 是 weak，而菜单内容一变就会原地重建一份 NSMenu**：挂在
  toolbar item 上的那份 delegate 不会跟过来。钩子必须挂在**造菜单的地方**
  （`buildMenu`），并且由控制器强持有——否则第一次活更新之后就静默失效。
- **`NSToolbar.displayMode` 改不动**：`allowsDisplayModeCustomization` 在 macOS 15+
  默认 YES，头文件原话是「这时 displayMode 是一个用户可改的属性」——存过配置之后
  再赋值会被当场弹回（设完立刻读还是旧值，实测）。代码里那句只是**开局值**，
  要记住用户的右键选择就得开 `autosavesConfiguration`。
- **`withObservationTracking` 的观察者没人强持有就静默死掉**，而且**只在冷启动
  露馅**：热替换时 model 从保管箱拿到种子，构造时那一次同步 push 就把该显示的
  都显示了，看起来完全正常；冷启动没有种子，第一推全是「藏起来」，界面一片空白，
  日志却写着「上线 5 格」。见 clam-header 的 `HeaderToolbarSync.start()`。
- **`NSHostingView` 的默认压缩阻力（750）会把别的工具栏项挤进溢出菜单**：
  这块矩形一步不让，AppKit 只好去收别人。要它先自己截断就把
  compressionResistance 降到 `.defaultLow`、hugging 拉到 `.defaultHigh`。
- **SwiftUI 的 `.frame(maxWidth:)` 会让工具栏项凭空消失**：`maxWidth` 是贪心的，
  NSHostingView 把它当理想宽度顶回工具栏，那一格就真要那么宽；加上同区其它项
  超出内容区，整项被挤进溢出，界面上一个字都不剩。症状极像"数据没到"
  （node 半边日志明明写着投影已发）。**先怀疑宽度，再怀疑数据。**
- **WKWebView 对下载与新窗口的默认行为是静默丢弃**，不是报错：不实现
  `decidePolicyFor navigationResponse` 就没有下载，不设 `uiDelegate` 就没有新窗口，
  两者都不给任何回调、日志或视觉反馈。所以"点了没反应"这类报告先查 delegate 是否齐
  （见 `Native/WebPolicy.swift`），别去怀疑页面。
- **`openSubagent` 有前置状态，不是纯导航**：它校验目标是不是 "healthy catalog
  child"，认的是 client runtime 自己那份 `subagentsByParent`。没让 runtime 先拉过
  `subagents.list`（`setSubagentCatalogOpen` + `refreshSubagents`，后者返回 Promise，
  await 它才是可靠的"加载完了"信号）就导航，一律被挡。所以上游 `setCatalogOpen`
  的作用不止是文档里写的"上报可见分支做去抖刷新"。
- **subagent 的 id 形态是混合的**：`subagents.list` 要的 `parentSessionId` 必须带
  `session-` 前缀，而它回的 catalog 里 child 是**光 uuid**。两个 id 同步翻转前缀去
  试，四种组合恰好会跳过唯一正确的那种——症状是"两种都试了、两种都被拒"，
  极像数据坏了。别猜：`session.list` 行里的原始 `sessionId` 就是上游认的那个，
  投影时一起带上。
- **client 半边的 `ctx.inject` 会抛**：裸调一次（不包 try、放在 apply 顶层）就赔掉
  整个插件——页面上连 `window.__clam*` 都没有，而 node 终端一个字都没有。照
  clam-layout 的 `installBridge` 办：走作用域 inject、包 try、**装在 effect 内部**
  （每代重装接线，沿用上一代的服务句柄等于留一个 fiber 已卸载的僵尸桥）。
- **client 半边 `__ModuleLoader__.load({ id })` 里的 id 必须逐字等于包名**，
  它不会跟着 `package.json` 的 name 自动变。给包加 scope 那次就栽在这里：
  包名成了 `@wenbo/clam-layout`，client.js 里还写着 `id: "clam-layout"`，
  于是整棵插件树加载失败——
  `bundle …/client.js loaded without registering "@wenbo/clam-layout"`。
  **node 半边一切正常、dsh 终端一个字都没有**，只在浏览器里报，所以改包名后
  一定要真开一次窗口看看。涉及 clam-layout 与 clam-nativeify 两处。
- **client 半边 HMR 的重载顺序是「新实例先启、旧实例后清」**：ctx.effect 的 cleanup
  里无条件清理 documentElement 属性 / window 全局，会砍掉新实例刚装好的那一份。
  写全局状态必须带实例 token，cleanup 只收 token 对得上的（clam-layout/lib/client.js
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
  要给终端前的人看的进度必须自己写 stderr（clam-app / clam-bridge 都是两边都喂）。
- **别覆写 `NSSplitViewController.loadView()`**：默认实现会把 splitView 装成 view，
  换成空 `NSView` 窗口直接全白。
- **`NSViewRepresentable` 每轮 update 会把环境值回写进 NSControl**，`makeNSView` 里
  设的同名属性被悄悄抹掉，不报错不警告。`NSSearchField` 的高度就栽在这上面：
  `field.controlSize = .extraLarge` 写在 `makeNSView` 里永远是 24pt，贴成 SwiftUI 的
  `.controlSize(.extraLarge)` 立刻 36pt（regular=24 / large=28 / extraLarge=36，量过）。
  连带一条：macOS 26 的 `NSSearchField` 内部是 `_NSCoreHostingView<AppKitSearchField>`
  占满 frame，**不走 cell 绘制**——`frame(height:)`、`intrinsicContentSize`、
  `layout()` 强撑、放大字号、覆写 `NSSearchFieldCell` 的 rect 方法全是死路。
  **别为了尺寸去拆这个控件**（`isBezeled = false` 补底板 / 塞进 `NSGlassEffectView`）：
  按压胀缩和光效是控件自带的，拆了就是拿质感换尺寸。
- **sidebar List 的选中高亮别自己画**：`.tint()` 改不动它，而拿 `.listRowBackground`
  盖一层的话，系统那层（内缩 10pt）会套在自绘那层里面，半透明一用就露成"回"字
  （填不透明纯色时看不出来，所以**必须截图量而不是看代码**）。系统那层白送焦点态
  与浅深色适配，让它画就是了。
  两处都**不报错、不警告**，只是设了没反应，所以改完一定要截图量一次而不是看代码。
- **`NSHostingController.sizingOptions` 默认含 `.preferredContentSize`**：槽内插件每换一代
  重建视图都会把分栏拉成 SwiftUI 内容的 fitting 宽度，用户调好的宽度就没了。设成 `[]`。
