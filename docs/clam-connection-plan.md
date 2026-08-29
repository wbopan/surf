# 连接系统：断连页重做 + 连接偏好 + App 托管后端 + settings.pane 贡献槽

> 计划文档，2026-08-29。执行日志见 §7。
> 讨论定调（用户 2026-08-29 三裁决）：
> ① **托管 = 壳 spawn dsh 子进程**，后端生命周期随 App（打开即有、⌘Q 即退，Docker
>   Desktop 语义）。这**推翻**了 `docs/release-install-plan.md` §0 与 `AppDelegate`
>   注释里「壳不自己 spawn dsh」的既定立场——那条立场就此作废，本计划是新权威。
>   release 计划的 LaunchAgent 常驻形态仍是**另一个**合法形态（另案），两者互斥要认。
> ② **第一期只服务本机开发者**：前提是 dsh 已全局装好、仓库在本机。
>   「Release 用户从零安装」（装 node / 装 dsh / 装 profile）与分发形态未解题绑定，另案。
> ③ **手动连接收完整 URL**（`http(s)://host:port`），裸端口号做成输入便利
>   （`3080` → `http://127.0.0.1:3080`）。
>
> **2026-08-29 设计定稿修订**（同日晚，用户逐轮裁决后收窄）：
> 页面方案定为**两页**——引导连接页 + 连接中断页（§3 已按定稿重写）；
> **设置 pane（§6 / M5）缓议**（用户：「设置我们先不管」）；界面**面向最终用户**
> （不出现 ./dev、worktree、profile、pid 等开发者概念，文案称「后端」不称 dsh），
> 文案贴系统 App 密度（短句、事实性、无安抚性废话）；实现时**优先用 Apple 原生
> 符号与样式**（SF Symbols、系统字体/颜色/控件），不手绘模拟。
> 设计稿权威：Artifact「Surfclam 连接控制台」与 `.scratch/design-connection/*.dc.html`。

## §0 目标与非目标

**目标**：

- 断连/引导页从「一句话 + 重试按钮」重做成**连接控制台**：状态区、发现的后端列表、
  手动连接、托管后端四个分区（§3）；
- 壳侧建立**显式连接状态机**，收拢现在散在四个变量、三条时间线里的隐式状态，
  失败原因分类上报（§2）；
- **连接偏好模型**：`auto`（现状）/ `fixed`（钉死 URL）/ `managed`（App 托管后端）
  三种模式，住壳的 UserDefaults（§4）；
- **托管后端**：壳 spawn 本 worktree 的 `./dev`（或全局 dsh），监护、日志、退避重启、
  ⌘Q 即杀（§5）；
- clam-settings 开 **`settings.pane` 贡献槽**（照 toolbar 槽的样子），壳自己往里
  贡献一个「连接」pane，和断连页复用同一份视图与状态（§6）。

**非目标**：

- 不做从零安装引导（裁决②，托管区检测不到 dsh 时只给指引文案）；
- 不做多后端收藏夹 / 同时连多个 dsh；
- 不改桥协议（`protocolVersion` 不动；`restart-dsh` 帧维持无调用方原状，
  托管重启走杀子进程重拉，不走桥）；
- 不实现 release 计划本身（LaunchAgent 那套另案；本计划只做**互斥检查**：
  检测到 `io.wenbo.surfclam.dsh` daemon 在跑就不 spawn、如实显示）。

## §1 现状事实清单（2026-08-29 实测，动手前核对，与源码冲突以源码为准）

1. **断连页是覆盖层**：`clam-app/host/Sources/BootstrapViewController.swift`（185 行），
   `MainWindowController.mountBootstrap()` 把它 `addSubview` 到 `contentView` 之上铺满。
   断连时壳**不清 WebView、不清 registry**（`NativePluginHost` 明确「桥断不动 registry」），
   界面变化 100% 来自这一层。三态 API `setBusy / setGuide / setError`，
   其中 `setError` 与文案 `bootstrapErrorTitle` **零调用方**。
2. **四幕已有**：`BootstrapPhase = searching / reconnecting / disconnected / notFound`
   （`MainWindowController.swift` 568 行附近），但渲染共用一段、`command: "dsh web"` 硬编码。
3. **连接状态是隐式的**：没有状态枚举，散在 `endpoint: ClamEndpoint?`、`bootstrapPhase`、
   `nativeHost.isBridgeConnected`、`bridgeReady` 四处；三条互不知情的时间线驱动：
   2s HTTP 轮询（`probeNow` 单飞）、桥 WS 指数退避（0.5s 起翻倍封顶 8s，
   `BridgeClient.swift`）、页内 `ready` 帧 8s 超时（`armBridgeWarn`）。
4. **候选定位**：flag（`--clam-endpoint`，永远第一且 `isOwn` 恒真）→ 扫
   `endpoints/*.json` 按 httpBase 去重追加。`discoveredEndpoints()` 排序 = 先 isOwn
   后 startedAt 倒序。**健康探测是串行的**（`locateHealthy` 逐个 GET，单个超时 1.5s），
   候选多且有死候选时线性变慢。
5. **endpoint 文件字段**（`clam-app/lib/index.js` `writeEndpointFile`）：
   `httpBase / bridgePath / pid / startedAt / profile / hostDir / appPath`。原子写、
   退出时只删 `pid === process.pid` 的那份。
6. **壳零 spawn**：全仓 Swift 唯一 `Process()` 是 `CompilerService` 的 `xcrun swiftc`。
   `AppDelegate` 注释「M1 起壳不再探测 Node、不再 spawn dsh」——本计划废除该立场。
7. **GUI App 的 PATH 只有 `/usr/bin:/bin:/usr/sbin:/sbin`**，没有 node、没有
   `/opt/homebrew/bin`（与 release 计划 §1.6 launchd 同坑）。壳 spawn 任何依赖用户
   环境的东西都要走 login shell 或显式解析路径。
8. **壳侧够得着贡献槽**：`ClamContributions.shared` / `ClamHooks.shared` 是 SDK dylib
   进程级单例，壳链接同一份、`MainWindowController` 已 `import ClamSDK`；`ClamHost`
   默认用的就是这两个 `.shared`。壳直接 `register(contributionTo:owner:id:…)` 零接线。
   跨 dylib 递 `AnyView` 已被 toolbar 槽验证（clam-sidebar → clam-layout）。
9. **clam-settings 无任何扩展机制**：`SettingsTab` 是闭合 `CaseIterable` 枚举四栏，
   `SettingsPage.page` 穷举 switch；`SettingsPlugin` 从不碰 `host.contributions`。
   窗口 `NSTabViewController(tabStyle: .toolbar)`、`toolbarStyle = .preference`、
   窗口宽 720 固定、每页高度各自定（nil = 自适应）；换语言走 `relocalize(_ locale:)`
   重贴标签；热替换时「先关上一代窗口」（存 `NSWindow` 进保管箱）。
10. **`./dev` = `surfclam/bin/surfclam.js` link 模式**：装 profile 后
    `spawnSync("dsh", […, "--no-open"], { stdio: "inherit" })` 前台跑。`--release`
    分支**尚未落地**（parseArgs 没有它），只有 node 半边 `CLAM_RELEASE` 形态覆写在。
11. **同一个 profile 的两个 dsh 会互抹 endpoint 文件**（release 计划 §1.8）——
    托管 spawn 前必须查重。
12. **`nativeHost.requestRestartDsh()`（`restart-dsh` 桥帧）已实现、无调用方**，
    且没查证 dsh 侧有没有处理者。本计划不用它。
13. UserDefaults 现有键：`clam.pageZoom` / `clam.webQuery` / `clamLocale` +
    AppKit 托管的窗口/分栏 frame + clam-sidebar 三个筛选键。无连接相关键。
14. 断连页在场时 `applyAppBuild` **整个跳过**壳更新提示条——重做后保持该行为。

## §2 M1：显式连接状态机 `ConnectionController`

新文件 `clam-app/host/Sources/Native/ConnectionController.swift`，`@Observable`。
把 §1.3 的四变量三时间线收拢成单一真相，`MainWindowController` 瘦身成消费者。

```swift
enum ConnectionPhase {
    case searching                       // 正在扫描/探测候选
    case connecting(ClamEndpoint)        // 选中候选，装页面 + 桥握手中
    case connected(ClamEndpoint)         // 桥 hello 已到（页 ready 是附加布尔）
    case disconnected(DisconnectReason)  // 曾连上，丢了
    case unreachable(ConnectFailure)     // 有明确目标（fixed/手动/托管）但连不上
    case idle                            // 没有任何候选（原 notFound 幕）
}
enum ConnectFailure { case refused, timeout, httpError(Int), bridgeRejected }
enum DisconnectReason { case processGone, bridgeLost, userRequested }
```

要点：

- **并行探测**：`locateHealthy` 改成 TaskGroup 并发 probe 全部候选（单个仍 1.5s 超时），
  同时产出 `candidates: [CandidateStatus]`（endpoint + 健康态 + probe 耗时）给页面列表用。
  选取规则不变（flag > isOwn > startedAt），只是等待时间从 N×1.5s 变 max 1.5s。
- **失败分类**：URLSession 错误码映射成 `ConnectFailure`（`.cannotConnectToHost`
  → refused、`.timedOut` → timeout…）；桥侧把「WS 握手被拒」「hello 超时」上报给
  controller（`BridgeClient` 加一个失败回调，现在只有静默退避）。
- **对外出口三个**：`MainWindowController`（驱动页面与 WebView 装载）、
  `DiagnosticsPanel`（⌥⌘D 改读它，替掉现在东拼西凑的字段）、M6 的设置 pane。
  另 `emitSticky("clam.connection.state", …)` 一份 JSON 化投影，插件想听也听得到
  （状态型消息一律 emitSticky 的家规）。
- **行为回归约束**：M1 结束时四幕的外在表现与现在逐帧一致（文案、时机、⌘⇧R），
  纯内部重构——这样 M2 的视觉改动才能单独归因。

## §3 M2：两页方案（设计已定稿，2026-08-29）

设计稿权威：Artifact「Surfclam 连接控制台」+ 源文件
`.scratch/design-connection/{Onboarding,Main,MainDark}.dc.html`（数值出自 Apple
macOS 27 UI Kit：Body 13/16、按钮 24 常规 / 28 首要、标签梯、系统色板）。
`BootstrapViewController` 整个退休，换 `NSHostingController` + SwiftUI。仍是覆盖层，
挂载/卸载点位不变（§1.14 的更新提示条互斥、Debug 斜纹水印都保留）。

**三条实现口径**（用户裁决，全部强制）：

1. **面向最终用户**：界面上不出现 `./dev`、worktree、profile、pid、hash 等
   开发者概念；文案称「后端」不称 dsh。开发者细节只活在 ⌥⌘D 诊断面板与日志。
   多 worktree 候选排序等逻辑照旧，只是不再作为界面概念上屏。
2. **文案贴系统 App 密度**：短句、事实性，无安抚性废话（「无需操作」「发现即
   自动接入」这类一律不写）。全部进 `Strings.swift` 双语，换语言路径照接。
3. **优先 Apple 原生符号与样式**：SF Symbols（如 `wifi.slash`）而不是自绘路径；
   系统字体/动态颜色（`labelColor` / `secondaryLabelColor` / `controlAccentColor`
   等语义色）而不是抄设计稿 hex——设计稿的 hex 是这些语义色的浅色快照；
   能用系统控件（按钮、输入框、spinner）就不用自定义视图。
   深浅色自动成立（跟随系统外观与 clam-nativeify 的 ui-theme 投影）。

**引导连接页**（无目标后端时）：居中 560 版心。
图标徽章（wifi.slash）→ 标题「尚未连接后端」→ spinner +「正在查找本机的后端…」；
两张等宽卡片：**让 Surfclam 托管**（描述「后端随 Surfclam 自动启动和退出。」+
蓝色首要按钮「开启托管」）与 **连接到已有的后端**（描述「通过地址接入正在运行的
后端。」+ 直接内嵌的 URL 输入框，placeholder `http://127.0.0.1:3080`，回车即连，
裸端口号按裁决③补全）；**发现的后端**列表（每行：绿点 + 「端口 N」+ 启动时间 +
「连接」按钮；数据 = 并行 probe 的健康候选，只显示活的）；
页脚「诊断面板 ⌥⌘D · 打开日志目录」。无「推荐」徽标、无终端命令行。

**连接中断页**（曾连上又断了）：居中 560 版心，**纯诊断、不堆操作**。
橙色图标徽章 → 标题「已与后端断开连接」→ spinner +「正在尝试重新连接…」；
只读诊断卡五行：后端（如「本机 · 由 Surfclam 托管」）/ 地址（等宽字）/
原因（分类后的人话，如「连接被拒绝 · 后端进程已退出」）/ 断开于（时刻 +
此前连接时长）/ 自动重连（已试 N 次 · 下一次 N 秒后）；
**唯一按钮「连接其他后端…」**：放弃当前目标、切回引导连接页选择态；页脚同上。

searching / reconnecting 两幕并进各自页面的 spinner 行，不再单独成幕。

## §4 M3：连接偏好模型

壳侧 UserDefaults 三键（登记进 `docs/clam-contracts.md` 保管箱/键位一节）：

| 键 | 值 | 语义 |
|---|---|---|
| `clam.connection.mode` | `auto` \| `fixed` \| `managed` | 缺省 `auto` = 现状行为 |
| `clam.connection.fixedURL` | 完整 URL 字符串 | fixed 模式的目标；bridgePath 用默认 `/clam/bridge` |
| （日志/托管细节键见 §5） | | |

优先级与语义：

- **`--clam-endpoint` flag 永远压过一切**（它来自拉起本进程的 dsh，语义不变）。
- `auto`：现状（扫发现文件、并行 probe、择优）。
- `fixed`：候选就是那一个 URL，连不上进 `unreachable` 幕如实报错，**不**回退
  auto 发现（钉死就是钉死；页面上仍显示发现列表，点一下即临时改道）。
- `managed`：等价 auto 的发现逻辑 + `BackendManager` 负责「保证有一个自己的后端在跑」。
- 模式切换入口：断连页（③④分区的「记住」「托管」）与设置「连接」pane（M6），
  写的都是同一份 UserDefaults、走同一个 `ConnectionController.setMode()`。

## §5 M4：托管后端 `BackendManager`

新文件 `clam-app/host/Sources/Native/BackendManager.swift`，壳强持有（AppDelegate）。

**spawn 什么**：

- Dev 壳（`ClamPaths.ownHostDir` 推得出 worktree）：跑**本 worktree 的 `./dev`**——
  白捡全部安装逻辑（link、profile 判定、xcodegen 兜底）。
- Release 壳（ownHostDir 为 nil）：`dsh --profile surfclam --port 0 --no-open`。
- 两者都经 login shell 拉起（`/bin/zsh -lc 'exec …'`）解决 §1.7 的 PATH 坑
  （nvm / homebrew 的 node 都在用户 shell 环境里）。spawn 前先
  `/bin/zsh -lc 'command -v dsh'` 探测，失败即进「缺 dsh」态，不盲拉。

**监护语义**：

- spawn 前查重（§1.11）：并行 probe 发现健康的 isOwn endpoint、或
  `launchctl print gui/$UID/io.wenbo.surfclam.dsh` 是 running → 不 spawn，
  显示「后端已由外部管理」。
- 子进程 stdout/stderr 合流：落
  `<AppSupport>/logs/managed-dsh.<instanceTag>.log`（沿用壳日志的 worktree 分片键）
  + 内存环形缓冲喂托管区日志尾巴。
- 意外退出 → 退避重启（1s/4s/15s 三次），60s 内三连败进「已放弃」态摊开日志
  （避免 KeepAlive 式坏代码死循环，release 计划 §5 同款教训）；
  「重启后端」按钮 = 计数清零重来。
- **⌘Q**：`applicationShouldTerminate` 里 SIGTERM 子进程、限时等 2s、`.terminateLater`
  收尾（dsh 的 fiber 清理要跑完才会删 endpoint 文件）。「停止托管」= 杀进程 + 切回 auto。
- **连接归位不需要新机制**：子 dsh 的 clam-app 照常写 endpoint 文件（isOwn 命中）、
  照常想 `open` App（`isRunning` 查重会跳过），壳现有的发现轮询自然接上。
  spawn 之后 `ConnectionController` 立刻 probeNow 一轮即可。
- 注意 `./dev` 是 `node → spawnSync dsh` 两层，壳杀的是外层，SIGTERM 会经
  `stdio: inherit` 的进程组传达；实现时验证信号真的到 dsh（不到就 spawn 时
  `setsid` + 杀进程组）。

## §6 M5：`settings.pane` 贡献槽 + 壳的「连接」pane —— **缓议**

**2026-08-29 用户裁决：「设置我们先不管」。本节整体缓议，设计保留备后续启用；
以下内容在启用前不实现、不派工。**

**契约**（权威落在 `clam-settings/swift/`，汇总登记 `docs/clam-contracts.md` §2）：

- 槽名 `"settings.pane"`，走 `ClamContributions`。metadata 键（消费方定义）：
  `label`（中文）、`labelEn`、`symbol`（SF Symbol 名）、`height`（Double，可选，
  缺省自适应）；排序用贡献自带的 `order`（内建四栏视作 order 0~3，贡献从 10 起）。
  **壳是预编译产物 import 不了插件 module**，所以这个槽的贡献方写字面量字典
  （注释指向权威文件），不做 ToolbarSpec 那种类型化 struct——SDK 容器中立不变。
- **消费方**：`SettingsWindowController` 建 tab 时改成「四个内建 + 遍历
  `contributions(for: "settings.pane")`」，tab identifier 用贡献 `key`；
  观察 `contributions.revision` 增删重建 tab（热替换语义 ClamContributions 自带：
  同 (owner,id) 覆盖保位）；`relocalize` 按 metadata 的 label/labelEn 重贴贡献页标签。
- **壳的贡献**：owner `"shell"`、id `"connection"`，`make` 返回 `ConnectionPaneView`
  ——和断连页④分区 + 模式切换**同一个 SwiftUI 视图族**，直接读写壳内的
  `ConnectionController` / `BackendManager`（贡献闭包住在壳里，够得着）。
  内容：当前连接（端点、桥状态、页 ready、时长）· 模式三选 · fixed URL 编辑 ·
  托管起停与日志入口 · 「重新连接」（= ⌘⇧R 同款）。
- 断连时 clam-settings 不在（设置窗口开不了），连接管理由断连页兜底——双入口、
  一份状态，这是接受的设计而不是缺口。

## §7 交付物清单

| 文件 | 改动 |
|---|---|
| `clam-app/host/Sources/Native/ConnectionController.swift`（新） | §2 状态机 + 并行 probe |
| `clam-app/host/Sources/Native/BackendManager.swift`（新） | §5 托管 |
| `clam-app/host/Sources/ConnectionViewController.swift`（新） | §3 页面；`BootstrapViewController.swift` 退休删除 |
| `clam-app/host/Sources/MainWindowController.swift` | 瘦身成 ConnectionController 消费者；挂卸覆盖层；⌘⇧R 改道 |
| `clam-app/host/Sources/DiagnosticsPanel.swift` | 改读 ConnectionController |
| `clam-app/host/Sources/Strings.swift` | 新文案双语 |
| `clam-app/host/Sources/AppDelegate.swift` | 持有 BackendManager；⌘Q 收尾；删「不 spawn dsh」旧注释 |
| `clam-settings/swift/SettingsWindowController.swift` `SettingsTabs.swift` | §6 消费贡献（**缓议**） |
| `docs/clam-contracts.md` | `settings.pane` metadata 键表；`clam.connection.*` UserDefaults 键；`clam.connection.state` 粘性主题 |
| `CLAUDE.md` | 架构速览改「三级定位」为「偏好模型」；踩坑视实现补 |
| `docs/release-install-plan.md` | 顶部加一行：「壳不 spawn dsh」非目标已被本计划推翻，互斥语义见本计划 §5 |

## §8 里程碑

- **M1 显式状态机**（重构，行为逐帧回归；⌥⌘D 能看到分类后的失败原因即验收）。
- **M2 两页实现**（按 §3 定稿；杀 dsh 看中断页、无候选看引导页、URL 框连回、
  「连接其他后端…」切回引导页；**截图与设计稿并排给用户裁决**）。
- **M3 偏好模型**（fixed 钉死语义、flag 压制、模式切换落盘重启仍在）。
- **M4 托管后端**（开托管 → ⌘Q → 重开 App 后端自动拉起；杀 dsh 看退避重启；
  三连败看「已放弃」+ 日志；外部 dsh 在跑时托管按钮禁用）。
- **M5 settings.pane + 连接 pane**（**缓议**，见 §6）。
- **M6 文档 + 端到端验收**。

依赖：M1 → M2 → M3（M2/M3 同属壳内一条改动线，宜同一代理连做）；
M4 只依赖 M1/M3。
每完成一个里程碑在 §9 追加执行日志。

## §9 风险与已知坑

- **login shell 拉起的环境差异**：`zsh -lc` 读的是用户 `.zprofile`/`.zshrc`，
  慢几百毫秒且可能有副作用输出混进日志——spawn 只做一次，可接受；日志解析别假设首行。
- **并行 probe 改掉了 `probeInFlight` 单飞语义**：重写时保证同一轮不重入、
  轮与轮不叠罗汉（TaskGroup 整体算一次在飞）。
- **SwiftUI 覆盖层与拖动条**：覆盖层铺满含标题栏区，列表/输入框要避开
  `WindowDragRegionView` 的 40pt（或覆盖层自己处理拖动）——实现时截图验证顶部可拖。
- **clam-settings 消费贡献的热替换**：窗口重建时 tab 得从 contributions 重读；
  壳的贡献不换代（壳只有一代），但 clam-settings 换代会重建窗口——已有
  「先关上一代窗口」逻辑兜着，验一次即可。
- **`./dev` 两层进程的信号传递**（§5 末条）：实测 SIGTERM 到不到 dsh，
  不到就进程组杀。dsh 收不到 SIGTERM 会留陈旧 endpoint 文件（pid 已死），
  壳靠健康探测自然跳过，无需清理逻辑。
- **fixed 模式钉着一个死地址**会让页面永远 unreachable——页面上发现列表常显 +
  一键切回 auto，别把用户锁死。
- **托管与 LaunchAgent 并存**（将来 release 计划落地后）：同 profile 互抹 endpoint
  文件，§5 的查重把 launchctl 检查也算进去了，两边文档互相指认。

## §10 执行日志

（实现时逐里程碑追加：日期、里程碑、一句话结果、与计划的偏差。）

- 2026-08-29 设计定稿：两页方案经用户四轮裁决收敛（去开发者概念、系统级文案密度、
  托管卡无徽标中性底、URL 输入框内嵌、发现列表保留只剩端口+时间）；设计稿在
  Artifact「Surfclam 连接控制台」与 `.scratch/design-connection/`；§3 重写、§6 缓议。
- 2026-08-29 **M1 显式状态机**：`Native/ConnectionController.swift` 落地
  （`@Observable`，六幕 + `ConnectFailure` / `DisconnectReason` 分类 + `ConnectionMode`），
  `MainWindowController` 瘦成消费者（`onAttach` / `onDetach` / `onPhaseChange` 三个回调），
  ⌥⌘D 改读它（新增幕/模式/最近失败/失败轮次/候选健康表/托管态六行）。
  **与计划的偏差三条**：① `EndpointLocator.locateHealthy()` 删掉，并行化以
  `probeAll(_:)`（TaskGroup + 按下标回填保序）落地——选取规则要认"目标段"
  （手动/fixed），塞不进原来那个无参签名；② `probe` 由返 `Bool` 改成返
  `ConnectFailure?`（nil = 健康），失败分类因此在探测那一层就成形；
  ③ 桥失败上报做成 `BridgeClient.Failure` 三态（`handshakeRejected` /
  `helloTimeout` / `connectionLost`）经 `NativePluginHost` 转给状态机，
  另加一个 5s hello 看门狗——**只上报，不改退避行为**。
  行为回归：连接/断连/⌘⇧R 时序不变（幕的翻转点与旧实现逐帧对齐：
  `.connecting` 一到就撤覆盖层 = 旧 `enterRunning()` 第一句 `hideBootstrap()`）。
- 2026-08-29 **M2 两页**：`BootstrapViewController.swift` 删除，
  `ConnectionViewController.swift`（NSHostingController + SwiftUI）按 §3 定稿实现；
  文案 zh 逐字照设计稿、双语进 `Strings.swift`（旧 `bootstrap*` 七条删净）。
  三条口径全部落实：界面零开发者概念（worktree/profile/pid/hash 全部退进 ⌥⌘D）；
  符号走 SF Symbols 且**带存在性回退**（`ConnSymbol.first(_:)`——`Image(systemName:)`
  撞上不存在的名字是静默空白）；颜色一律语义色，深浅色自动成立。
  **两处与旧实现不同**：① 覆盖层改挂在 `WindowDragRegionView` **之下**
  （旧的排在最上层，靠 `isMovableByWindowBackground` 兜拖窗——那条路对
  NSHostingView 不成立，标题栏会拖不动）；② 更新提示条互斥、Debug 斜纹水印、
  换语言重画（`connectionVC?.apply(strings:)`）三条照旧。
  实测两页：引导页（fixed 指死地址）、中断页（临时 HTTP 服务连上再杀）截图各一张。
  **实测抓到一个真 bug 并已修**：掉线进 `.disconnected` 后，下一轮探测因为
  `activeEndpoint` 已放开而落进 `.unreachable`，中断页 2s 后自己跳回引导页——
  断连幕现在会留住（重连尝试只更新 `attempts`）。
- 2026-08-29 **M3 偏好模型**：`clam.connection.mode` / `clam.connection.fixedURL`
  两键（坏值退缺省），语义按 §4；地址规范化收在
  `ConnectionController.normalizedURL(from:)`（裸端口 → `http://127.0.0.1:<port>`、
  无 scheme 补 `http://`、**只认 http/https**）。**与计划的偏差一条**：优先级实做成
  「用户当场点的一次性目标 > flag > 偏好」——§4 那句"flag 永远压过一切"约束的是
  **偏好**，一次性点击是当场的指令，让 flag 压住它会让"连接"按钮看上去没反应。
  「连接其他后端…」= 把当前目标记进 `abandoned` 再切回引导页（不记的话下一轮
  轮询会把同一个端点原样接回来）。模式切换入口暂只有偏好键本身（设置 pane 缓议）。
- 2026-08-29 **M4 只落公共面**：`Native/BackendManager.swift`（`@Observable`，
  六态 `idle/starting/running/retrying/gaveUp/unavailable` + `start/stop/restart/
  prepareForTermination` + `logURL` 按 worktree 分片），**内核未实现**：`start()`
  置 `.unavailable` 并记日志，引导页托管卡按状态通用渲染（那一行如实写
  "托管功能尚未启用。"）。AppDelegate 持有它、`applicationShouldTerminate` 已按
  `prepareForTermination()` 走 `.terminateLater` 的分支（眼下恒 false）。
- 2026-08-29 **M4 托管内核**：`Native/ManagedProcess.swift`（新，零依赖的 spawn 原语）
  + `Native/BackendManager.swift` 填满。spawn / 查重 / 退避 / ⌘Q 四件事按 §5 落地，
  接线三处：`MainWindowController.start()` 里 `mode == .managed` 即 `backend.start()`；
  「开启托管」= `setMode(.managed)` + `start()`（**要落偏好**，不然"打开即有后端"
  只兑现一次），「停止托管」= `stop()` + `setMode(.auto)`；`backend.onStateChange`
  在 `.running` 时催一轮 `probeNow`（连接归位本身仍靠现有轮询）。
  ⌥⌘D 那行改读 `backend.diagnosticSummary`（带 pid 与失败原因）。
  **三条实测结论**（都写进了源码注释）：
  ① **`Foundation.Process` 做不了托管**——它不设 `POSIX_SPAWN_SETPGROUP`，
  子进程继承壳自己的进程组，于是 `killpg` 会杀壳、`kill` 又漏掉孙子进程。
  实测：只 TERM 外层，内层立刻被 init 收养（PPID 1）继续跑，端口照占，
  壳这边毫无异样。改用 posix_spawn + `posix_spawnattr_setpgroup(&attr, 0)` 让
  子进程自成组，`killpg` 一发覆盖整棵子树（隔离验证台
  `docs/spikes/backend-spawn/`，六条断言可复跑）。macOS 没有 `setsid(1)` 可借。
  ② **`zsh -lc` 够用**：本机 `command -v dsh` 解出 `/opt/homebrew/bin/dsh`
  （login shell 读 `.zprofile`，不读 `.zshrc`——nvm 那种只装在 `.zshrc` 里的
  形态会解不出来，那时如实进"未找到后端程序"）。
  ③ **这个工程里 `#if DEBUG` 是死代码**：project.yml 从没设过
  `SWIFT_ACTIVE_COMPILATION_CONDITIONS`，Debug 产物里整块不存在（`strings` 查得到）。
  实测钩子因此改用 bundle id 的 `.dev` 后缀当门（CLAUDE.md 已补一条踩坑；
  连带受害的还有 WebView 的 `isInspectable` 与连接页的 Dev 斜纹，**没动它们**）。
  **与计划的偏差两条**：① `.unavailable(reason: String)` 改成了带类型的
  `Unavailable`（`missingRuntime` / `externalBackend` / `launchFailed`）——
  "缺 dsh"和"已经有人在管"是两件事，混成一句"不可用"会把人带去查错方向，
  界面文案也跟着分成三句；② §5 那句"1s/4s/15s 三次 + 60s 三连败"读成
  **三次退避重启**（第 4 次意外退出才进 `.gaveUp`），实测时序 1.0s / 4.1s / 15.7s。
  **实测覆盖**（全部用假进程，绝不在真 profile 上 spawn）：查重两条路各触发一次
  （launchctl 那条 58ms、健康端点那条命中本机正跑着的 daemon，两次都没 spawn，
  用户的 dsh 毫发无损）；假后端拉起 → `.running` + 输出落 `managed-dsh.*.log`；
  秒退的假后端跑满退避三连败 → `.gaveUp`；⌘Q 0.12s 退净、组内零残留；
  点「开启托管」→ 偏好落盘 → spawn → probeNow → 页面归位（截图
  `.scratch/m4-{before,after}.png`）。**真 spawn `./dev` 的端到端留给用户验收**
  ——这台机器上 daemon 正占着 `surfclam` profile，查重会（正确地）拦下它。- 2026-08-29 端到端验收（用户在场，杀真后端）：kill daemon dsh → 中断页出现（诊断五行、
  倒计时）→ bootstrap 拉回 → 12s 内自动重连归位。发现并修复一处：后端干净退出会删
  endpoint 文件，重试轮无候选可 probe、`lastFailure` 恒空，「原因」落到「未知」——
  `reason()` 现在在无 probe 级失败时退回用 `DisconnectReason` 兜底（新增文案
  connReasonProcessGone /connReasonBridgeLost），复验显示「后端进程已退出」。
  另注：daemon 的 KeepAlive 会秒拉 dsh，普通 kill 只能看到中断页一闪而过（这本身
  就是自动重连在工作）；要按住中断态观察得 launchctl bootout。
- 2026-08-29 不兼容后端判定（用户提出：`dsh web` + 手动输端口会连上一个没有 clam
  插件的裸后端且不报错）：桥握手连续 3 次被拒（HTTP 仍健康）→ 判定「该后端不含
  Surfclam 组件」，放弃该端点、回引导页，状态行附正确启动命令
  `dsh --profile surfclam`（等宽字）；已判定的地址从「发现的后端」列表滤掉、
  不再自动接回。阈值 3 给"dsh 起桥比起 HTTP 晚一拍"的正常启动窗口留了余地。
  用假 HTTP 服务器（python http.server，WS 一律拒）+ 隔离实例实测通过。
