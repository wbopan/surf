# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 构建与运行

**必须用 `-derivedDataPath build`**——用户从 `build/Build/Products/Debug/` 启动 App，输出到其它位置（如 `build/DerivedData/`）会导致"BUILD SUCCEEDED 但改动永远不生效"。

```bash
# Debug 构建并重启 Dev App（默认不影响 Release App，两者可并存运行；
# 如确需先退出 Release App 用 --quit-release）
scripts/dev.sh [--quit-release]

# Release 构建 + 安装到 /Applications（会退出正在运行的 Release App；
# 同样注意别在 Release session 里跑）
scripts/build.sh [--keep-open]

# 等价的手动 Debug 流程（project.yml 改过时先 ./tools/xcodegen generate）
xcodebuild -project DSHarness.xcodeproj -scheme DSHarness \
  -configuration Debug -derivedDataPath build build
osascript -e 'tell application "DSHarness Dev" to quit'
open "build/Build/Products/Debug/DSHarness Dev.app"
```

无测试套件。Debug 与 Release 是两个不同 App，可并存运行：

| | Debug（日常开发） | Release（正式） |
|---|---|---|
| App 名 | DSHarness Dev | DeepSeek Harness |
| Bundle ID | io.wenbo.dsharness.dev | io.wenbo.dsharness |
| 图标 | 橙色 DEV 徽章 | 原图标 |
| UI 标记 | 标题栏 DEV pill、侧边栏 DEV BUILD 条（含构建时间戳）、bootstrap 斜纹 | 无 |
| 位置 | build/Build/Products/Debug/ | /Applications/ |

构建时间戳：prebuild 脚本 `scripts/write-build-timestamp.sh` 每次构建把时间写入 `Resources/BuildTimestamp.txt`（随 bundle 打包），Dev 侧边栏底部显示，用于确认跑的是哪次构建；Swift 侧读 `AppInfo.buildTimestamp`。

Swift 里名字统一走 `AppInfo.displayName`（读 Info.plist，随 PRODUCT_NAME 变化），UI 差异全在 `#if DEBUG`，改图标设置看 project.yml 的 `configs:` 段。

## 架构速览

Swift/AppKit 壳 + WKWebView，包住 npm 管理的 `dsh` harness（装在 `~/Library/Application Support/io.wenbo.dsharness/harness/`，bundle 外，与壳独立更新）。详见 README.md。

- `DSHarness/`：壳应用。MainWindowController 是主枢纽（窗口/WebView/状态机/菜单）；HarnessProcess spawn `dsh web` 并选端口；EventsBridge 走 WebSocket 事件流发通知。
- `Packages/DSHKit`：仅 Foundation 的 dsh API 层（SessionStore 镜像会话列表）；`Packages/DSHSidebarUI`：SwiftUI 原生侧边栏。
- `plugins/dsharness-web-adapter/`：注入 dsh Web UI 的 cordis 插件（隐藏网页侧边栏、注入 CSS、`window.__dsharness` 页内桥）。经 `~/.dsh/profiles/web/node_modules/dsharness-web-adapter` **符号链接**到本 repo——改 `lib/client.js` 后在 App 里 ⌘R 重载页面即生效，无需构建。
- 插件门控：UA 含 `DSHarness` 且 URL 带 `?dsharness-native-sidebar=1`；终端 `dsh web`/普通浏览器不受影响。

## 踩坑记录

- dsh Web UI 类名是 hash 化 CSS module（`Md3f7G_flowItem`），语义后缀稳定，选择器用 `[class*="_flowItem"]` 防御式命中；升级 dsh 后失效先核对语义名。
- macOS WKWebView 内部没有 NSScrollView（滚动在 Web 进程），别试图从 AppKit 层控制页面滚动；SPI `_setRubberBandingEnabled:` 会引发滚动闪动，已弃用——页面滚动全靠插件注入的 CSS。
