# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 这个仓库现在是什么

一组 cordis 插件 + 一个极薄的 macOS 壳（**dash**）。正在执行
**阶段二迁移**：`docs/phase2-dash-plugin-migration-plan.md` 是唯一权威计划，
动手前先读它，尤其 §0.5 不变量、§1 上游机制事实清单、§9 里程碑总表。
每完成一个里程碑在计划 §12 追加一行执行日志；发现文档与 dsh 源码冲突，
以源码为准并就地更新计划文档。

**当前进度：M0（固化 + 搬家 + 改名）已完成，下一步 M1（启动反转）。**

仓库根就是 `~/.dsh/profiles/plugins/`（这不是巧合，是 §1.4 布线硬约束的要求）。

```
dash-app/          壳源码为载荷的插件（M1 起有 lib/index.js；现在只有 host/）
  host/            Xcode 工程：project.yml / Sources/ / Packages/ / scripts/ / tools/
dash-web-adapter/  注入 dsh Web UI 的 cordis 插件（纯 client 半边，无构建步骤）
docs/              计划与调研文档
dsh-web-search-firecrawl/   邻居插件：本地运行时所有，已 gitignore，不由本仓库维护
```

## 构建与运行

**必须用 `-derivedDataPath build`**——用户从 `build/Build/Products/Debug/` 启动 App，
输出到其它位置（如 `build/DerivedData/`）会导致"BUILD SUCCEEDED 但改动永远不生效"。

```bash
# Debug 构建并重启 Dev App（默认不影响 Release App，两者可并存运行；
# 如确需先退出 Release App 用 --quit-release）
dash-app/host/scripts/dev.sh [--quit-release]

# Release 构建 + 安装到 /Applications（会退出正在运行的 Release App；
# 注意别在 Release session 里跑）
dash-app/host/scripts/build.sh [--keep-open]

# 等价的手动 Debug 流程（cd dash-app/host 之后；project.yml 改过时先
# ./tools/xcodegen generate；时间戳文件不入库，generate 前先跑一次生成脚本）
./scripts/write-build-timestamp.sh && ./tools/xcodegen generate
xcodebuild -project dash.xcodeproj -scheme dash \
  -configuration Debug -derivedDataPath build build
osascript -e 'tell application "dash Dev" to quit'
open "build/Build/Products/Debug/dash Dev.app"
```

无测试套件。Debug 与 Release 是两个不同 App，可并存运行：

| | Debug（日常开发） | Release（正式） |
|---|---|---|
| App 名 | dash Dev | dash |
| Bundle ID | io.wenbo.dash.dev | io.wenbo.dash |
| 图标 | 橙色 DEV 徽章 | 原图标 |
| UI 标记 | 标题栏 DEV pill、侧边栏 DEV BUILD 条（含构建时间戳）、bootstrap 斜纹 | 无 |
| 位置 | dash-app/host/build/Build/Products/Debug/ | /Applications/ |

构建时间戳：prebuild 脚本 `scripts/write-build-timestamp.sh` 每次构建把时间写入
`Sources/Resources/BuildTimestamp.txt`（**不入库**，随 bundle 打包），Dev 侧边栏底部显示，
用于确认跑的是哪次构建；Swift 侧读 `AppInfo.buildTimestamp`。

Swift 里名字统一走 `AppInfo.displayName`（读 Info.plist，随 PRODUCT_NAME 变化），
UI 差异全在 `#if DEBUG`，改图标设置看 project.yml 的 `configs:` 段。

## dsh 与插件布线

dsh 从 M0 起是**全局安装**（`npm i -g @deepseek-ai/dsh@0.1.1-rc.2`，钉版本），
终端 `dsh web` 直接可用；壳内 npm 管理的那份即将随 M1 启动反转退役。

插件注册：`dsh plugin --profile web add link:<path>`（参数直接透传给 pnpm，
`remove <name>` 同理）。**硬约束**：插件真实路径必须在 `~/.dsh/profiles/` 之下，
否则 `@deepseek-ai/*` 解析不到（详见计划 §1.4）——这正是仓库要迁往
`~/.dsh/profiles/plugins/` 的原因。`@deepseek-ai/*` 一律写 peerDependencies。

node 半边（`lib/index.js`、`package.json`、增删插件）改动后**必须重启 dsh**（官方在
web bundle 下 disable 了 node 侧 HMR）；client 半边（`lib/client.js`）有 HMR，
约 0.5s 自动重载，壳里 ⌘R 也行。

## 架构速览

Swift/AppKit 壳 + WKWebView，当前仍由壳 spawn `dsh web`（M1 反转为 dsh 先起、
由 dash-app 插件拉起壳）。详见 README.md（M8 随收尾重写）。

- `dash-app/host/Sources/`：壳应用。MainWindowController 是主枢纽（窗口/WebView/状态机/菜单）；
  HarnessProcess spawn `dsh web` 并选端口；EventsBridge 走 WebSocket 事件流发通知。
  （后三者按计划 §3 将在 M1 退役。）
- `dash-app/host/Packages/DSHKit`：仅 Foundation 的 dsh API 层（SessionStore 镜像会话列表）；
  `Packages/DSHSidebarUI`：SwiftUI 原生侧边栏（M6 迁入 dash-sidebar 插件）。
- `dash-web-adapter/`：注入 dsh Web UI 的 cordis 插件（隐藏网页侧边栏、注入 CSS、
  `window.__dash` 页内桥）。经 `~/.dsh/profiles/web/node_modules/dash-web-adapter`
  **符号链接**到本 repo——改 `lib/client.js` 后在 App 里 ⌘R 重载页面即生效，无需构建。
- 插件门控：UA 含 `Dash/`（带斜杠，防普通子串误命中）且 URL 带 `?dash-native-sidebar=1`；
  终端 `dsh web`/普通浏览器不受影响。

## 踩坑记录

- dsh Web UI 类名是 hash 化 CSS module（`Md3f7G_flowItem`），语义后缀稳定，
  选择器用 `[class*="_flowItem"]` 防御式命中；升级 dsh 后失效先核对语义名。
- macOS WKWebView 内部没有 NSScrollView（滚动在 Web 进程），别试图从 AppKit 层
  控制页面滚动；SPI `_setRubberBandingEnabled:` 会引发滚动闪动，已弃用——
  页面滚动全靠插件注入的 CSS。
- **绝不往 session 日志写自定义 event type**：0.1.1-rc.2 会导致
  `SessionFormatUnsupportedError`、会话无法重新读取。
