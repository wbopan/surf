> [!WARNING]
> **本文描述的是阶段二迁移之前的架构，已大面积过时**（改名前的 DSHarness、壳 spawn dsh、
> npm 管理的 harness 自更新、Node 探测、设置窗口——这些代码在 M1 已经删除）。
> 按计划 §9，README 由 **M8 收尾时重写**。在那之前，以
> [`CLAUDE.md`](CLAUDE.md)、[`docs/phase2-dash-plugin-migration-plan.md`](docs/phase2-dash-plugin-migration-plan.md)
> 和 [`dash-app/README.md`](dash-app/README.md) 为准。
>
> 一句话现状：App 改名 **dash**，启动方向已反转——`dsh web` 先起，其中的 dash-app 插件
> 构建并拉起 App；App 三级定位 dsh（flag → endpoint 发现文件 → 引导页）。

# DeepSeek Harness —— dsh 的 macOS 原生壳应用

Swift/AppKit + WKWebView 的 macOS 应用，把 [`dsh`](https://github.com/deepseek-ai/deepseek-harness)（`@deepseek-ai/dsh`）的 Web UI 包进原生窗口：系统通知（UNUserNotificationCenter）+ 透明 vibrancy 侧边栏（NSVisualEffectView）。

**核心架构决策**：签名后的 .app bundle 只读（改动即破坏签名），所以 harness 装在 **bundle 外**，由 npm 管理；壳应用与 harness 走两条独立更新通道。壳 = 重新 build；harness = npm 版本目录 + 符号链接原子切换（可回滚）。

```
DeepSeek Harness.app（Swift/AppKit，ad-hoc 签名，不可变）
 ├─ 窗口: transparent titlebar + fullSizeContentView
 │    ├─ 左: NSGlassEffectView —— Liquid Glass 层（macOS 26+）
 │    ├─ 顶: 28pt 透明拖拽条（WindowDragRegionView）
 │    └─ WKWebView(透明) → http://127.0.0.1:<port>
 ├─ HarnessManager: npm 管理的 dsh 安装 + 自更新
 ├─ HarnessProcess: posix_spawn `dsh web`，进程组隔离 + 监督重启
 └─ EventsBridge: SSE 订阅 /api/events.mux + /api/events.host → 原生通知

~/Library/Application Support/io.wenbo.dsharness/
 ├─ harness/versions/<semver>/   （npm --prefix 安装）
 ├─ harness/current → versions/<semver>   （符号链接原子切换，保留 N-1 回滚）
 ├─ npm-cache/                    （独立 npm 缓存，绕开 ~/.npm 属主问题）
 └─ logs/                         （harness.log、npm-<v>.log）

~/.dsh/   ← dsh 自己的数据根，壳应用完全不动
```

## 构建

前置：Xcode 27+、Node.js `^22.19.0 || >=24.0.0`（本机 Homebrew `/opt/homebrew/bin/node`）、XcodeGen（本机 brew 目录属主异常，可从 [GitHub Releases](https://github.com/yonaskolb/XcodeGen/releases) 下载 zip 放入 `tools/`）。

```bash
# 生成 .xcodeproj + 构建（产物在 build/Build/Products/Debug/DeepSeek Harness.app）
./tools/xcodegen generate
xcodebuild -project DSHarness.xcodeproj -scheme DSHarness \
  -configuration Debug -derivedDataPath build build

# 运行
open "build/Build/Products/Debug/DeepSeek Harness.app"
```

Release 构建 + 安装到 /Applications（生成工程 → Release 编译 → 退出运行中实例 → `ditto` 复制；`--keep-open` 装完自动启动）：

```bash
scripts/build.sh [--keep-open]
```

签名：ad-hoc（`CODE_SIGN_IDENTITY: "-"`，无 Team），不开启沙盒（需要 spawn Node 子进程 + 写 Application Support）。如需分发/公证，在 `project.yml` 换成自己的开发证书并调整 entitlements。

## 目录布局（仓库）

```
project.yml                     XcodeGen 声明式工程
DSHarness/
 ├─ AppDelegate.swift            入口：Node 解析、通知授权、窗口装配
 ├─ MainWindowController.swift   窗口/vibrancy/WKWebView、状态机、菜单、更新流程
 ├─ HarnessManager.swift         版本化安装、symlink 切换、registry 更新检查
 ├─ HarnessProcess.swift         posix_spawn + 进程组、健康检查、退避重启
 ├─ EventsBridge.swift           WebSocket 双流解析、通知策略、断线重连
 ├─ BootstrapViewController.swift 首启/错误引导视图
 ├─ SettingsWindowController.swift Node 路径、更新频率设置
 └─ Support/                     Semver / NodeResolver / Shell / Log
```

## 与 dsh 的接口（对照 0.1.1-rc.2 源码验证）

- 启动：`dsh web --host 127.0.0.1 --port <p> --no-open`；`--port 0` 也可由 OS 分配，但壳用「绑定 0 取端口再释放」自行选择，失败换端口重试。
- 入口探测（npm `--prefix` 布局实测）：`<v>/node_modules/.bin/dsh`（存在）→ `<v>/bin/dsh` → `<v>/node_modules/@deepseek-ai/dsh/lib/bin.js`（纯 JS，用 `node` 跑）。
- **事件流走 WebSocket**（`dsh-client-connection` 对外提供；普通 GET `/api/events.mux` 返回 426 "upgrade required"，进程内 apiproxy 的 SSE 是另一条路径）：`ws://127.0.0.1:<port>/api/events.mux` 与 `ws://.../api/events.host`。每帧一个 JSON 文本消息 `{type:"server-request", rpcId, method, payload}`；纯下行，客户端发消息会被 1008 "downlink only" 关闭。`host/agent-error`、`host/session-status` 只在 host 流；`approval/requested`、`question/requested`、`session/event` 在 mux 流。重连后服务端会重放 pending 的批准/问题（通知侧有 60s 去重）。
- `/api/respond` 服务端应答表在 preview 期仍是 stub → 通知只做「点击唤起窗口」，不做通知内批准。
- loopback 无鉴权（仅需 `Content-Type: application/json` + loopback Host），壳应用零凭据接入。

## 原生侧边栏（阶段一）

左侧为 **SwiftUI 原生侧边栏**（坐在 NSGlassEffectView 上），WebView 只渲染 conversation + details：

```
dsh server
   ↑ POST /api（unary，朴素 JSON 包封，见 docs/wire-notes.md）
   ↓ WS /api/events.mux、/api/events.host（只下行）
DSHKit（Packages/DSHKit，仅 Foundation，iOS 就绪）
   → DSHSidebarUI（Packages/DSHSidebarUI，仅 SwiftUI+DSHKit）
   → Mac 壳（NSHostingView 承载）── WKWebView（网页侧边栏经插件隐藏）
```

- 状态经服务端收敛；唯一页内桥是 `window.__dsharness`（`plugins/dsharness-web-adapter` v2 提供：
  `selectSession`/`startSession`/`openSettings` + `currentSession` 反向上报），门控 = UA 含
  `DSHarness` **且** URL 带 `?dsharness-native-sidebar=1`。终端 `dsh web` / 普通浏览器零影响。
- 会话列表/状态点由 DSHKit.SessionStore 镜像（事件流驱动增量）；「当前选中会话」为页面本地状态，经桥双向同步。
- **逃生舱**：显示菜单「使用原生侧边栏」开关；页面加载 8s 未见桥 `ready`（插件被上游 breaking change 打坏）自动回退完整网页模式并记日志。
- 插件改动经 `~/.dsh/profiles/web/node_modules/dsharness-web-adapter` 符号链接生效，改后需重启 harness（⌘⇧R）。验证于 harness 0.1.1-rc.2。

## 通知策略（EventsBridge）

仅当应用非前台时发送：

| 事件 | 通知 |
|---|---|
| `approval/requested` | 「需要你的批准」（含工具名/原因） |
| `question/requested` | 「需要你的回答」（首问文本） |
| `host/agent-error` | 「Agent 出错」 |
| `session/event` 中 `turn/end` 且会话未运行 | 「任务完成」（每会话 5 分钟冷却，防轰炸） |

断线指数退避重连（1s→30s 封顶），重连后不回填历史（通知只关心此后事件）。点击通知 → 唤起应用并前置窗口。

## 已知限制

- **dsh 处于 developer preview**，明示会有 breaking change：事件帧解析全部防御式编写（未知帧忽略、异常不崩溃）；harness 版本切换保留 N-1 回滚。
- 壳应用无自更新通道（Sparkle 未接入）：自用场景重新 build 即可。
- 首启需 npm install（约 3–6 分钟，网络相关）；引导视图会显示进度。
- 更新检查：启动时 + 每 6 小时（可在设置里改为手动/24h）；发现新版 → 装新目录 → 校验 → 切链接 → 提示重启生效。
- 插件（`dsh plugin`）场景不接管：用户在终端照常操作 `~/.dsh` 下的 profile，壳提供「重启 Harness」菜单项让变更生效。
- Node 需预装（`brew install node`）；v1 不做自动下载官方 Node tarball（免签名固定运行时是后续增强）。

## 菜单

标准 macOS 菜单结构（应用 / 文件 / 编辑 / 显示 / 窗口）：

- `⌘,` 设置（Node 路径、更新频率）；`⌘U` 检查 harness 更新；`⌘⇧R` 重启 Harness；`⌘R` 重载页面
- `⌘W` 关闭窗口；`⌘M` 最小化；`⌘Q` 退出；`⌘H` 隐藏
- 编辑快捷键（作用于 WebView 与设置窗口的文本框）：`⌘Z` 撤销 / `⌘⇧Z` 重做 / `⌘X` 剪切 / `⌘C` 拷贝 / `⌘V` 粘贴 / `⌘A` 全选
- 「切换侧边栏玻璃效果」在显示菜单内（无快捷键，避免占用 `⌘V` 粘贴）；「打开日志目录」在应用菜单内
