# DSHarness —— DeepSeek Harness 的 macOS 原生壳应用

Swift/AppKit + WKWebView 的 macOS 应用，把 [`dsh`](https://github.com/deepseek-ai/deepseek-harness)（`@deepseek-ai/dsh`）的 Web UI 包进原生窗口：系统通知（UNUserNotificationCenter）+ 透明 vibrancy 侧边栏（NSVisualEffectView）。

**核心架构决策**：签名后的 .app bundle 只读（改动即破坏签名），所以 harness 装在 **bundle 外**，由 npm 管理；壳应用与 harness 走两条独立更新通道。壳 = 重新 build；harness = npm 版本目录 + 符号链接原子切换（可回滚）。

```
DSHarness.app（Swift/AppKit，ad-hoc 签名，不可变）
 ├─ 窗口: transparent titlebar + fullSizeContentView
 │    ├─ 左: NSVisualEffectView(.sidebar) —— vibrancy 层
 │    └─ WKWebView(透明) → http://127.0.0.1:<port>
 │         + WKUserScript 注入（Resources/SidebarInjection.css|js）
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
# 生成 .xcodeproj + 构建（产物在 build/Build/Products/Debug/DSHarness.app）
./tools/xcodegen generate
xcodebuild -project DSHarness.xcodeproj -scheme DSHarness \
  -configuration Debug -derivedDataPath build build

# 运行
open build/Build/Products/Debug/DSHarness.app
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
 ├─ Support/                     Semver / NodeResolver / Shell / Log
 └─ Resources/
    ├─ SidebarInjection.css      侧边栏透明注入选择器（易改，见下）
    └─ SidebarInjection.js       结构启发式检测 + 宽度回传 Swift
```

## 与 dsh 的接口（对照 0.1.1-rc.2 源码验证）

- 启动：`dsh web --host 127.0.0.1 --port <p> --no-open`；`--port 0` 也可由 OS 分配，但壳用「绑定 0 取端口再释放」自行选择，失败换端口重试。
- 入口探测（npm `--prefix` 布局实测）：`<v>/node_modules/.bin/dsh`（存在）→ `<v>/bin/dsh` → `<v>/node_modules/@deepseek-ai/dsh/lib/bin.js`（纯 JS，用 `node` 跑）。
- **事件流走 WebSocket**（`dsh-client-connection` 对外提供；普通 GET `/api/events.mux` 返回 426 "upgrade required"，进程内 apiproxy 的 SSE 是另一条路径）：`ws://127.0.0.1:<port>/api/events.mux` 与 `ws://.../api/events.host`。每帧一个 JSON 文本消息 `{type:"server-request", rpcId, method, payload}`；纯下行，客户端发消息会被 1008 "downlink only" 关闭。`host/agent-error`、`host/session-status` 只在 host 流；`approval/requested`、`question/requested`、`session/event` 在 mux 流。重连后服务端会重放 pending 的批准/问题（通知侧有 60s 去重）。
- `/api/respond` 服务端应答表在 preview 期仍是 stub → 通知只做「点击唤起窗口」，不做通知内批准。
- loopback 无鉴权（仅需 `Content-Type: application/json` + loopback Host），壳应用零凭据接入。

## 通知策略（EventsBridge）

仅当应用非前台时发送：

| 事件 | 通知 |
|---|---|
| `approval/requested` | 「需要你的批准」（含工具名/原因） |
| `question/requested` | 「需要你的回答」（首问文本） |
| `host/agent-error` | 「Agent 出错」 |
| `session/event` 中 `turn/end` 且会话未运行 | 「任务完成」（每会话 5 分钟冷却，防轰炸） |

断线指数退避重连（1s→30s 封顶），重连后不回填历史（通知只关心此后事件）。点击通知 → 唤起应用并前置窗口。

## Vibrancy 侧边栏的"尽力而为"注入

dsh Web UI 是 hash 化 CSS-module 的 SPA，**没有稳定语义钩子**（已核对 0.1.1-rc.2 dist）。注入策略：

1. `SidebarInjection.css` —— 仓库内单一可编辑文件：文档级透明 + 语义选择器兜底（`aside`/`nav`/`[role=…]`）。
2. `SidebarInjection.js` —— 结构启发式：找「窄宽 40–420px + 近全高 + 贴左 + 非 fixed」的容器，把该容器及其祖先链背景清透明，让原生 vibrancy 透出；并把宽度 `postMessage` 回 Swift 同步 NSVisualEffectView 宽度。

**降级**：选择器/启发式全部失效时页面保留自带背景（功能不受损）；`⌘V` 可切换 vibrancy 层开关。

## 已知限制

- **dsh 处于 developer preview**，明示会有 breaking change：CSS 注入与事件帧解析全部防御式编写（未知帧忽略、注入失败不崩溃）；harness 版本切换保留 N-1 回滚。
- 壳应用无自更新通道（Sparkle 未接入）：自用场景重新 build 即可。
- 首启需 npm install（约 3–6 分钟，网络相关）；引导视图会显示进度。
- 更新检查：启动时 + 每 6 小时（可在设置里改为手动/24h）；发现新版 → 装新目录 → 校验 → 切链接 → 提示重启生效。
- 插件（`dsh plugin`）场景不接管：用户在终端照常操作 `~/.dsh` 下的 profile，壳提供「重启 Harness」菜单项让变更生效。
- Node 需预装（`brew install node`）；v1 不做自动下载官方 Node tarball（免签名固定运行时是后续增强）。

## 菜单

- `⌘,` 设置（Node 路径、更新频率）
- `⌘U` 检查 harness 更新
- `⌘⇧R` 重启 Harness
- `⌘R` 重载页面；`⌘V` 切换 vibrancy
- 「打开日志目录」
