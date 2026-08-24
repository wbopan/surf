# 阶段一计划：原生侧边栏 + Web 主体（conversation/details）

> 本文档面向执行者（人或模型），假设对本仓库无前置了解。所有上游事实均已对照
> `~/Library/Application Support/io.wenbo.dsharness/harness/current/node_modules/@deepseek-ai/`
> 下已安装的 dsh（0.1.1-rc.x 系列）源码与 README 验证过；执行时如与源码冲突，以源码为准并更新本文档。

## 0. 背景与目标架构

DSHarness 目前是 Swift/AppKit 壳 + 单个全出血 WKWebView（加载 `http://127.0.0.1:<port>/` 的 dsh Web UI），
侧边栏视觉靠"原生玻璃层 + 网页侧边栏透明化"合成。

阶段一目标：

1. Web UI **不再渲染侧边栏**（通过我们的客户端插件隐藏），WebView 只呈现 conversation + details 两列；
2. 左侧改为**原生侧边栏**，在信息架构与交互上 1:1 对齐 Web 侧边栏（视觉遵循 macOS 原生风格，不做像素级复刻 CSS）;
3. 项目结构为**未来 iPhone/iPad 部署做好准备**：共享逻辑放进平台无关的 Swift Package，UI 用 SwiftUI，Mac 壳仅做宿主。

目标数据流（三端同构，iOS 后续复用）：

```
dsh server（Mac 本地 spawn；iOS 未来远程连接）
   ↑ HTTP POST /api（unary 调用）      ↓ WS /api/events.mux、/api/events.host（只下行）
   │                                   │
DSHKit（Swift Package：协议客户端 + Session/Workspace 镜像模型）
   │
DSHSidebarUI（Swift Package：SwiftUI 侧边栏）
   │
Mac 壳（AppKit，NSHostingView 承载）── WKWebView（只渲染 conversation + details）
```

**关键设计原则：状态经服务端收敛，不做 WebView 间/原生-WebView 间的状态同步。**
唯一例外是 "当前选中哪个 session"——这是页面本地状态（上游称 page-local frontend Session Intent），
不经过服务端，必须通过一条很小的原生↔页面桥来传递（见 Workstream A）。

## 1. 现有项目判定（不需要重建）

当前项目**已经是标准 Xcode 原生应用**：`project.yml`（XcodeGen）生成标准 `.xcodeproj`，Swift/AppKit，
ad-hoc 签名。不要重建工程；需要做的是结构化改造：

- 在仓库根新建 `Packages/DSHKit`、`Packages/DSHSidebarUI` 两个本地 Swift Package，在 `project.yml`
  里以 local package 依赖接入（XcodeGen `packages:` + target `dependencies:`）。
- **iOS 就绪硬约束（现在就强制执行）**：
  - `DSHKit`：只 import Foundation（网络用 URLSession，两平台通用）。禁止 AppKit/UIKit。
  - `DSHSidebarUI`：只 import SwiftUI + DSHKit。禁止 AppKit/UIKit；确需平台分支时集中在单个
    `PlatformShims.swift`，用 `#if os(macOS)`。
  - 原生↔WebView 桥定义为协议（如 `protocol ConversationSurface { func selectSession(id:); func startSession(workspaceId:?) }`），
    Mac 壳用 WKWebView 实现；iOS 壳以后另实现。
  - `DSHKit` 不得假设 loopback：server base URL 注入式传入，预留鉴权 header 挂载点（阶段一不实现鉴权）。
  - 服务端能力以 `host.describe` 握手结果为准做能力降级，不硬编码"方法一定可用"
    （配置面等特权方法服务端只对 loopback 开放）。

## 2. Workstream A：dsharness-web-adapter 插件 v2（页内改造）

现有插件位于 `plugins/dsharness-web-adapter/`（双面包：`cordis.patch.yml` patch 层 + `lib/client.js` 浏览器半边），
已实现 topInset 让位与侧边栏玻璃透明化，UA 含 `DSHarness` 时生效。在此基础上新增：

### A1. "隐藏侧边栏"模式
- 门控：UA 含 `DSHarness` **且** URL query 含 `dsharness-native-sidebar=1`（壳加载时拼接；
  逃生舱=去掉该参数重载）。终端 `dsh web`/普通浏览器零影响。
- 实现路径（按优先级）：
  1. 首选公开接口：`@deepseek-ai/dsh-client-ui-layout` 的 `/client` 出口导出了 `LayoutController`
     与四个 owner-share 接口（sidebar owner share 仅含 `collapsed`/`width`）。用它把侧边栏置为 collapsed。
  2. 折叠后残留 56px 控制 rail：补一条 CSS 把 rail 隐藏、列宽压 0
     （选择器参考现有做法 `[class*="_sidebarCol"]`，脆弱点已知，锁定在插件内）。
- 同时使现有"玻璃宽度上报"（ResizeObserver → `dsharnessSidebar` postMessage）在此模式下停用。

### A2. 页内动作桥（唯一必须的页内配合面）
- 插件在页面暴露 `window.__dsharness`：
  - `selectSession(sessionId)`：切换 conversation 显示的 session。具体调用 runtime 哪个动作
    需从源码确认：入口在 `@deepseek-ai/dsh-client-runtime/lib/client.js` 的 SessionRuntime /
    Session Intent 相关代码（sidebar 包注入的 `startSession` 与 session 行点击处理可作为逆向线索，
    见 `dsh-client-ui-sidebar` / `dsh-client-ui-workspace` 的 client.js）。
  - `startSession(workspaceId?)`：复用 web 的 New Session intent 流（sidebar README：runtime 的
    Session Intent 会自行推导目标 Workspace）。
  - `openSettings()`：打开 web 设置面（本阶段原生侧边栏"设置"按钮先落到这里）。
- 反向通道：页内当前 session 变化时（含用户在 conversation 内部导航引起的变化），
  经 `webkit.messageHandlers.dsharness.postMessage({type:'currentSession', id})` 上报，
  原生据此同步高亮。监听点同样在 runtime 的 session 状态处，写成防御式（拿不到就不报，不抛错）。
- 桥就绪时上报一次 `{type:'ready', capabilities:[...]}`；壳侧超时未收到 → 自动回退全网页模式（见 D4）。

### A3. 插件开发环境约束（重要，见仓库 memory）
**插件真实路径必须位于 `~/.dsh/profiles/` 之下，否则 dsh 启动失败、窗口打不开。**
开发流程：源码留在本仓库 `plugins/dsharness-web-adapter/`，通过同步脚本复制到
`~/.dsh/profiles/web/` 下的实际安装位置（或真实文件放 profile、仓库内放符号链接——沿用当前已验证可行的那种布局）。
改动后需重启 harness（壳菜单 ⌘⇧R）生效。

## 3. Workstream B：DSHKit（Swift 协议客户端）

### B0. Spike：摸清 wire 格式（先行，半天）
README 只给了架构；动手前用最小实验确定：
1. `/api` unary 请求包封格式（method/payload 怎么编码、响应包封、错误形态）。
   源码参考：`@deepseek-ai/dsh-client-connection/lib/client.js` 的 browser carrier（HTTP POST 部分）；
   或直接在 Safari 连 `dsh web` 页面抓 `/api` 请求。loopback 无鉴权，curl 可直接重放
   （需 `Content-Type: application/json` + loopback Host）。
2. 打通并记录以下方法的实际请求/响应样例（方法名已从 `@deepseek-ai/dsh-host-apiproxy/lib` 源码确认存在）：
   `host.describe`、`session.list`、`workspace.list`、`session.create`、`session.rename`、
   `session.cancel`、`session.search`（后两个阶段一可暂不接）。
3. 确认 `session.list` 是否分页/是否含状态字段，以及 mux/host 流上哪些事件驱动列表增量更新
   （已知：`host/session-status`、`host/agent-error` 在 host 流；`session/event`、`approval/requested`、
   `question/requested` 在 mux 流；帧格式 `{type:"server-request", rpcId, method, payload}`，
   客户端上行会被 1008 关闭——EventsBridge.swift 已有完整解析实现可参考）。
产出：`docs/wire-notes.md`，记录样例 + harness 版本号。

### B1. 模块内容
- `DSHTransport`：POST unary（async/await）+ 两条 WS 下行流（URLSessionWebSocketTask），
  指数退避重连（1s→30s，参考 EventsBridge 现有实现），重连成功后全量 refetch 列表。
- 模型：`SessionSummary`（id、title、workspaceId、状态、更新时间等，以 B0 实测字段为准）、`Workspace`。
  解码防御式：未知字段忽略、缺字段给默认值、解不出的行跳过不崩。
- `SessionStore`（`@MainActor ObservableObject` 或 actor+AsyncStream）：
  启动时 `session.list` + `workspace.list` 建立镜像 → 订阅事件流做增量更新（状态变化、新建、改名、归档）。
  暴露给 UI：按 workspace 分组的列表、平铺列表、每行状态。
- 动作：`createSession(workspaceId:?)`、`renameSession`、`cancelSession`（后两个可后置）。
- **与 EventsBridge 的关系（决策：阶段一不合并）**：EventsBridge（通知）保持原样，DSHKit 另开自己的
  WS 连接。同服务器两套连接完全合法（多客户端是上游一等支持）。合并留给后续重构。

### B2. 可测性
- 加一个 macOS 命令行 target（或 XCTest）：连上本地 harness，打印列表、订阅事件流打印增量。
  这是 M2 的验收载体，不依赖 UI。

## 4. Workstream C：DSHSidebarUI（SwiftUI 原生侧边栏，1:1 还原）

"1:1"的定义：**信息架构、交互语义与 Web 侧边栏一致；视觉用 macOS 原生控件风格**（透明背景，
坐在壳的 NSGlassEffectView 上）。上游侧边栏的构成（对照 `dsh-client-ui-sidebar`、`dsh-client-ui-workspace` README）：

### C1. 阶段一必做（对齐项）
- **品牌行**：logo + 名称（上游是 slot，默认鱼形 mark；我们用 DeepSeek 品牌资源或文本占位）。
- **New Session** 按钮：调 `ConversationSurface.startSession()`（走 A2 桥，复用 web 的 intent 流）。
- **会话浏览器**：
  - 按 Workspace 分组的 Session 行；Workspace 头可展开/收起；展开默认显示 5 条 + "显示更多"。
  - Session 行：标题 + 状态点（运行中/待批准/待回答/空闲，数据来自 SessionStore 的事件驱动状态）+ 相对时间。
  - 点击行 → `selectSession(id)`（桥）→ 同时本地高亮；页面反向上报时同步高亮（防止 conversation 内部导航导致失联）。
- **搜索**：header 的搜索控件，阶段一只做客户端标题/Workspace 名子串过滤（大小写不敏感、即时）；
  `session.search` 的内容搜索（250ms 防抖、片段展示）后置。
- **收起态**：收起为 56px rail（36px 控件：展开、New Session、添加、搜索），与 layout 的收起交互对齐；
  动画近似即可（上游 150ms 淡出 + 300ms 列滑动）。
- **底部固定"设置"**：阶段一动作 = 桥 `openSettings()` 打开 web 设置面。
- **宽度**：默认 232pt（沿用 `MainWindowController.sidebarDefaultWidth`），原生拖拽调宽，钳制合理区间。

### C2. 明确后置（不做，防执行者跑偏）
- Session/Workspace 拖拽排序、Manual/Last updated 视图选项、Workspace 改名/添加流、
  内容搜索片段、"显示更多"的记忆细节、动画曲线逐帧对齐。
- 这些 Web 侧边栏仍具备——用户可用逃生舱切回（D4）。

## 5. Workstream D：Mac 壳集成（MainWindowController 改造）

### D1. 布局改动
- WebView 不再全出血：改为只占侧边栏右侧区域（autoresizing 手动布局，沿用现有风格；
  **注意代码里记录的坑：contentView 层禁用 Auto Layout 约束，否则窗口首显被解算成 0×0**）。
- 原生侧边栏 = `NSHostingView(rootView: SidebarView(...))`，叠在现有 `NSGlassEffectView` 上，同宽联动。
- 删除：网页侧边栏宽度上报的消费逻辑（`handleSidebarMessage` 的 width 分支）；玻璃宽度改为原生侧边栏驱动。
- 保留：顶部 40pt 拖拽条、红绿灯偏移、topInset（现在作用于原生侧边栏内边距而非网页）。

### D2. 加载参数
- `loadWebUI()` 拼接 `?dsharness-native-sidebar=1`；壳持有开关状态（UserDefaults）。

### D3. 桥接线
- `WKScriptMessageHandler` 增加对 `{type:'ready'|'currentSession'}` 的处理；
- `ConversationSurface` 的 Mac 实现 = `webView.evaluateJavaScript("__dsharness.selectSession('\(id)')")` 等，
  注意 id 做 JS 字符串转义。

### D4. 逃生舱与自动回退
- 显示菜单加"使用网页侧边栏"开关：翻转 → 隐藏原生侧边栏 + 去参数重载 WebView（恢复完整 Web UI）。
- 自动回退：页面加载完成后 N 秒（建议 8s）未收到桥 `ready` → 视为插件失效（上游 breaking change 等），
  自动切回网页侧边栏模式并在日志记录原因。这是 developer preview 环境下的必备保险。

## 6. 里程碑与验收

| # | 内容 | 验收标准 |
|---|------|----------|
| M0 | Wire spike | `docs/wire-notes.md` 含 host.describe/session.list/workspace.list/session.create 的 curl 实测样例 |
| M1 | 插件 v2 | 壳内加参数加载：网页侧边栏完全不可见、conversation 顶到左缘；`evaluateJavaScript` 手动调 `selectSession` 能切换会话；终端浏览器打开同 profile 页面完全不受影响 |
| M2 | DSHKit | 命令行/测试 target 连本地 harness：打印分组列表；另开终端 `dsh` 里新建/改名会话，10s 内镜像跟上 |
| M3 | 原生侧边栏（只读+选择） | 壳内点原生行 → conversation 切换；conversation 内部导航 → 原生高亮跟随 |
| M4 | 对齐项补全 | New Session、状态点、标题过滤、收起 rail、设置入口全部可用 |
| M5 | 逃生舱 | 菜单开关双向切换正常；人为破坏插件（改坏 client.js）后重启 → 8s 自动回退全网页且不崩 |

顺序建议：M0 → M1 与 M2 并行 → M3 → M4 → M5。每个里程碑单独提交。

## 7. 风险与开放问题

1. **`/api` 包封格式未验证**（M0 解决）。若 unary 走的是 Typert 特殊编码而非朴素 JSON-RPC，
   DSHKit 传输层工作量上调，但方法语义不变。
2. **`selectSession` 的 runtime 动作名未定位**（A2 解决；线索：runtime 的 page-local Session Intent、
   sidebar 注入的 `startSession`）。若 runtime 未导出可用动作，兜底方案是插件内直接复用
   sidebar 行点击的同一内部函数引用（脆弱度上升，记录进插件已知脆弱点清单）。
3. **上游 preview 破坏性变更**：开发期锁定 harness 版本（HarnessManager 本就支持版本目录+回滚）；
   插件 README 记录"验证于版本 X"；D4 自动回退兜底。
4. **session 列表规模**：若 `session.list` 无分页且列表很大，首屏加载与镜像内存需实测（M2 顺带观察）。
5. **iOS 远程鉴权**：阶段一不涉及（纯 loopback），但 DSHKit 的 URL/鉴权注入点按第 1 节约束预留。

## 8. 本仓库现存代码的参考价值（执行者请先读）

- `DSHarness/EventsBridge.swift`：WS 帧解析、重连退避、双流订阅的现成实现——DSHKit 传输层直接参考。
- `DSHarness/MainWindowController.swift`：窗口布局、玻璃层、桥接 handler、菜单——D 全部改动落点。
- `plugins/dsharness-web-adapter/`：插件双面包结构、UA 门控、CSS 注入模式——A 的改造基础。
- `README.md`「与 dsh 的接口」一节：已验证过的启动方式、事件流行为、`/api/respond` stub 状态。
