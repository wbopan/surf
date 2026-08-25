# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 这个仓库现在是什么

一组 cordis 插件 + 一个极薄的 macOS 壳（**dash**）。正在执行
**阶段二迁移**：`docs/phase2-dash-plugin-migration-plan.md` 是唯一权威计划，
动手前先读它，尤其 §0.5 不变量、§1 上游机制事实清单、§9 里程碑总表。
每完成一个里程碑在计划 §12 追加一行执行日志；发现文档与 dsh 源码冲突，
以源码为准并就地更新计划文档。

**当前进度：M0～M6 已完成，下一步 M7（dash-notifications）。**
壳里已经没有布局、侧边栏、进程管理代码；剩下的业务残留是 `EventsBridge.swift`（M7 迁走）。

仓库根就是 `~/.dsh/profiles/plugins/`（这不是巧合，是 §1.4 布线硬约束的要求）。

```
dash-app/          壳源码为载荷的 cordis 插件：构建 + 写 endpoint 发现文件 + 拉起 app
  lib/index.js     node 半边（inject webServer）
  host/            Xcode 工程载荷：project.yml / Sources/ / Packages/DSHKit / scripts/ / tools/
dash-bridge/       唯一特权插件：Swift 载荷登记表 + /dash/bridge WS + 盯文件轮询
                   子出口 `./plugin` = createSwiftPlugin 工厂
dash-layout/       占 root 槽：分栏 + WebView 排版 + sidebar 槽 + 工具栏
dash-sidebar/      占 sidebar 槽：原生会话侧边栏（数据面走 DSHKit 镜像）
dash-hello/        原生插件流水线的冒烟样例（占 root 槽，与 layout 互斥，默认不注册）
dash-web-adapter/  注入 dsh Web UI 的 cordis 插件（纯 client 半边，无构建步骤）
docs/              计划与调研文档（native-abi.md = M2 的 ABI 实测结论，spikes/ 可复跑）
dsh-web-search-firecrawl/   邻居插件：本地运行时所有，已 gitignore，不由本仓库维护
```

## 两个截然不同的开发循环

| 改什么 | 怎么生效 | 耗时 |
|---|---|---|
| **插件的 `swift/`** | 存盘即可。桥 500ms 轮询发现 → 壳重编 → 世代热替换 | **1~3s，不重启任何东西** |
| 插件的 `lib/*.js`、`package.json`、增删插件 | **必须重启 dsh**（官方在 web bundle 下 disable 了 node 侧 HMR） | 秒级 |
| dash-web-adapter 的 `lib/client.js` | client 半边有 HMR，约 0.5s 自动重载；壳里 ⌘R 也行 | 秒级 |
| **壳源码 `dash-app/host/`** | 重新构建 + 重启 App（`dsh web` 会自动做，或手动 `dev.sh`） | 分钟级→秒级 |

**改 Swift 插件不需要碰 dsh，也不需要重启 App。** 编译失败会带文件行号打进 dsh 终端，
旧世代继续在役，界面不变也不崩。

## 构建与运行

**必须用 `-derivedDataPath build`**——用户从 `build/Build/Products/Debug/` 启动 App，
输出到其它位置（如 `build/DerivedData/`）会导致"BUILD SUCCEEDED 但改动永远不生效"。

**app 由 dsh 拉起**：终端跑 `dsh web --no-open`，dash-app 插件会按需构建并 open 出 App
（源码没变则跳过构建，App 已在运行则跳过拉起）。`--no-open` 是为了不让 dsh 另开一个重复的
浏览器标签页。`dev.sh` 仍在，作为同一套逻辑的手动捷径。

```bash
# 常规循环：改 Swift 壳源码 → 退出 App → dsh web（插件自动重建重拉）
# 或者不重启 dsh，直接用手动捷径：
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

dsh 是**全局安装**（`npm i -g @deepseek-ai/dsh@0.1.1-rc.2`，钉版本），终端 `dsh web` 直接可用。

插件注册：`dsh plugin --profile web add link:<path>`（参数直接透传给 pnpm，
`remove <name>` 同理）。**硬约束**：插件真实路径必须在 `~/.dsh/profiles/` 之下，
否则 `@deepseek-ai/*` 解析不到（详见计划 §1.4）——这正是仓库在
`~/.dsh/profiles/plugins/` 的原因。`@deepseek-ai/*`（以及 `ws`）一律写 peerDependencies。
**dash-\* 之间用相对路径 import**（`../../dash-bridge/lib/plugin.js`）：包名 import 需要
npm workspace 或手工 symlink，那是机器本地状态，新克隆的仓库拿不到。

## 架构速览

Swift/AppKit 壳 + WKWebView。**启动方向是反的**：`dsh web` 先起，其中的 dash-app 插件
构建并拉起 App；App 是 dsh 的客户端外设。App 三级定位 dsh：`--dash-endpoint` flag
（插件拉起时传入）→ endpoint 发现文件（`<AppSupport>/io.wenbo.dash/endpoint.json`，
插件写、退出删）→ 都没有 = 引导页。2s 轮询兼管断连发现与自动重连。

**壳的职责一句话**：定位 dsh、连桥、编译装载插件、给 root 槽兜底。

- `dash-app/lib/index.js`：宿主插件。源码内容 hash 决定是否重建，marker 落
  `host/build/.dash-app-source-hash.<配置>`。
- `dash-app/host/Sources/DashSDK/`：壳↔插件的 ABI 词汇（`DashPlugin` 是唯一的跨 dylib
  协议见证表；registry/objects/store/events/bridge 的实现都在 SDK dylib 里）。
- `dash-app/host/Sources/Native/`：BridgeClient（WS）、CompilerService（内容寻址编译）、
  NativePluginHost（dlopen + activate + 世代账）、GenerationLedger、ShellRootView（root 槽 +
  全出血 WebView 兜底）。
- `dash-app/host/Sources/MainWindowController.swift`：窗口、菜单、连接状态机、
  页内桥消息转 EventBus。**没有业务 UI。**
- `dash-app/host/Sources/EventsBridge.swift`：WebSocket 事件流发通知（M7 迁去 dash-notifications）。
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

- dsh Web UI 类名是 hash 化 CSS module（`Md3f7G_flowItem`），语义后缀稳定，
  选择器用 `[class*="_flowItem"]` 防御式命中；升级 dsh 后失效先核对语义名。
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
