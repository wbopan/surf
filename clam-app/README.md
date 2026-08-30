# clam-app

Surfclam macOS 壳的宿主插件。载荷是 `host/` 里的整个 Xcode 工程——壳源码不是特权目录，
只是本插件的一份资产，如同 `swift/` 之于 clam-sidebar。

## 它做三件事

`dsh web` 加载到本行时（`inject: ["webServer"]`，端口已定）：

1. **写 endpoint 发现文件** `~/Library/Application Support/io.wenbo.surfclam/endpoints/<profile>.json`
   （`{httpBase, bridgePath, pid, startedAt, profile, hostDir, appPath}`，原子写；
   字段表在 `docs/clam-contracts.md` §10.1）。先于构建落地，
   一个已经开着的 app 立刻就能接入，不必等分钟级的首次构建。fiber 卸载时按 pid
   匹配删除——两个 dsh 并存时，先退的那个不会把后来者的文件删掉。
   `hostDir` 是本插件所在的 `clam-app/host` 绝对路径、`appPath` 是本进程期望伺候的
   App bundle：没拿到 flag 的壳靠这两条认出"哪一份是我这一套"
   （开发期壳的 bundle 就在 `<hostDir>/build/Build/Products/<配置>/`；
   **装到 `/Applications` 的 Release 壳不在任何 worktree 之下，只能靠 `appPath`**），
   否则多 worktree 时它会连上邻居的 dsh 并编译邻居的插件源码。
2. **按需构建**：源码 hash 变了或产物缺失 → `write-build-timestamp.sh` +
   `xcodegen generate` + `xcodebuild -derivedDataPath build`（与 `scripts/dev.sh`
   同一套步骤）。hash 只看内容不看 mtime，换 git 分支不会被误判成"改过"。
   共享 module（眼下只有 ClamSDK）由工程自己的 pre/postBuild 脚本管，本插件不用操心。
3. **拉起**：产物就绪且 app 未运行 → `open <app> --args --clam-endpoint <httpBase>`。

然后 provide `clamApp = {appPath, freshness, configuration, httpBase, bridgePath}`。

## 壳里还剩什么（M6 之后）

界面已经全在插件里，壳只保留"让插件能跑起来"的那部分。
**通知本身没有丢弃**——计划 §7.3 那条早期决定后来以 `clam-notify` 插件的形态落地了
（权威计划 `docs/clam-notify-plan.md`）；壳这边只剩一个不认识通知语义的中转站，见下表
的 `SystemDelegateRelay`。

| 目录 | 职责 |
|---|---|
| `host/Sources/ClamSDK/` | 壳↔插件的 ABI 词汇。编成独立 dylib 随 bundle 分发，全进程只有一份。四张表：`ClamRegistry`（替换槽，一槽一主）、`ClamContributions`（贡献槽，一槽 N 条）、`ClamHooks`（应答钩子表）、`ClamEventBus`（事件总线，含 `emitSticky`），外加 `ClamObjects` / `ClamStore` / `ClamBridge` |
| `host/Sources/Native/` | BridgeClient（连 clam-bridge 的 WS）、CompilerService（内容寻址地跑 swiftc）、NativePluginHost（dlopen + activate + 世代账）、GenerationLedger（世代与退休 image 的账本）、ShellRootView（root 槽 + 全出血 WebView 兜底）、WebPolicy（下载 / 外链 / 新窗口，见下）、SystemDelegateRelay（占住系统 delegate，经 `ClamHooks` 转交插件，见下） |
| `host/Sources/MainWindowController.swift` | 窗口、菜单、连接状态机、页内桥消息转 EventBus、壳自身构建的提示条。没有业务 UI |

两个容易被漏掉的：

- **`WebPolicy.swift`**：WKWebView 对下载与新窗口的默认行为是**静默丢弃**——不实现
  `decidePolicyFor navigationResponse` 就没有下载，不设 `uiDelegate` 就没有新窗口，
  两者都不给任何回调、日志或视觉反馈。dsh 两类都用（会话导出 ZIP 走 `<a download>`，
  正文外链走 `target="_blank"`）。归壳不归插件：逃生舱模式也得能下载。
  scheme 走白名单（http/https/mailto），下载目录固定 `~/Downloads`——页面里的链接
  等同不可信输入。
- **`SystemDelegateRelay.swift`**：在 `applicationDidFinishLaunching` 的第一句占住那些
  **必须在启动完成前装好**的系统 delegate（眼下只有 `UNUserNotificationCenter`），
  把回调拍平成字典经 `ClamHooks` 问一遍插件。运行时装载的插件永远不可能自己占这些
  位子，这里是唯一的转交点。壳侧只有转发，没有业务判断（hook 名与载荷见
  `docs/clam-contracts.md` §7）。

**壳里没有任何一条业务命令的名字。** 菜单项、默认键位、⌘/ 面板、`clam-shortcuts`
设置页四样东西共用插件 node 半边的一份 `commands` 声明（形状见
`clam-bridge/lib/plugin.js` 的 `CommandDeclaration`，汇总见 `docs/clam-contracts.md` §1）。
页面 URL 带什么查询参数也一样：壳只订粘性主题 `clam.web.query`，参数名的定义权在
占 `root` 槽的插件那里。

没有任何插件占 `root` 槽时（没装 clam-layout、或它编译失败还没有过成功世代），
ShellRootView 退化成整窗 WebView——功能不缺，只是没有原生分栏和侧边栏。

## 两个构建脚本

`project.yml` 上挂着一对脚本，把共享 module 做成"全进程一份"：

- **preBuild `scripts/build-modules.sh`** → `host/build-sdk/lib<M>.dylib` + `.swiftmodule` +
  `.swiftinterface`（`-enable-library-evolution -language-mode 5`，内容 hash 命中则秒过）。
- **postBuild `scripts/embed-modules.sh`** → 拷进 `Contents/Frameworks/`（壳按 `@rpath` 加载）
  和 `Contents/Resources/ClamModules/`（插件运行时编译的 `-I` 落点），然后**重新 ad-hoc 签名**——
  拷贝发生在 Xcode 自己的签名步骤之后，不补签会起不来。

改 ClamSDK 会让所有插件的 contentHash 失效、全量重编，这是有意的：`.swiftmodule` 对不上
比慢几秒糟得多。

## 优雅缺席

构建失败、没装完整 Xcode、连既有产物都找不到——都只在终端留一句话就收手，
**不重试、不成环**（防的是构建风暴）。dsh 照常服务浏览器，只是没有 macOS 壳。
没有 Xcode 时退化为只探测既有产物：先本形态期望的那一份（release 形态就是
`/Applications/Surfclam.app`，见上面的 `CLAM_RELEASE`），再
`host/build/Build/Products/<配置>/`，最后 `/Applications/Surfclam.app`。

## 配置（`cordis.patch.yml`，可被 profile 的 patch 层覆写）

| 键 | 默认 | 含义 |
|---|---|---|
| `configuration` | `Debug` | `Debug` 产物是 `Surfclam Dev.app`（`io.wenbo.surfclam.dev`），`Release` 是 `Surfclam.app`；两者可并存运行 |
| `build` | `true` | 关掉则只探测既有产物，从不调用 xcodebuild |
| `launch` | `true` | 关掉则只构建、只写发现文件，由用户自己开 app |
| `watch` | `true` | dsh 运行期间盯着壳源码，变了就后台重建并经桥提示「有新版」。需要 `build` 也开着 |
| `watchIntervalMs` | `2000` | 盯壳源码的轮询间隔（下限 300）。先比 mtime/size 签名，签名变了才读内容算 hash |
| `restartOnRebuild` | `false` | 重建成功后不等用户点，直接让壳退出并重拉。开发期省事，代价是每次改壳都丢页面状态 |

开发期默认 `Debug`；日常使用者应在自己 profile 的 `cordis.patch.yml` 里覆写成 `Release`。

**环境变量 `CLAM_RELEASE`（非空且非 `0`）把上面几项整体覆写**成
`configuration: Release`、`launch: false`、`restartOnRebuild: false`，
`build`/`watch` 则**照开**（壳源码目录在的话），并打一行日志。仓库根的
`./release` 装出来的那个 LaunchAgent 在 plist 里设它——于是**同一张编排表服务
两种形态**，差别只在配置与落点：

- 编译永远发生在 worktree 的 `build/Build/Products/Release/`（`-derivedDataPath build`
  是硬约束），成功后多一步**安装**——先 `ditto` 到 `/Applications/.Surfclam.app.clam-staging`，
  再换名就位。**绝不 quit 正在跑的实例**（那是 `host/scripts/build.sh` 干的事，
  它是用户亲手跑的一条命令）：换代由壳右上角那条「壳有新版本 · 重启」提示条驱动。
  先拷后换名不是讲究——正在跑的 Mach-O 不能被原地覆写，而 `rm -rf` 到 `ditto` 之间
  那几秒里 `/Applications/Surfclam.app` 根本不存在，用户这时候点 Dock 就是一句
  "找不到应用程序"。
- **不自动拉起**：登录时不弹窗口，App 由用户双击（或 `./release` 收尾那一下 `open`）。
  壳自请重启后的重拉是另一条路径（`app-restart`），不受这一项管。
- 构建失败：旧壳继续在役，错误落 `clam-app-build.<profile>.Release.log`，
  **记住失败那次的源码 hash、hash 再变才重试**——不许 2s 一轮空转 xcodebuild。
- 门控：壳源码目录不在（registry 形态只带 `lib/`）就退回"不构建不盯源码"；
  没有完整 Xcode 时构建这一步本来就降级成"只探测既有产物"，盯源码也就不会启动。

计划见 `docs/release-install-plan.md` §2.1 与 §2.5。

## 它还注册一个设置 ns

`clam-shortcuts`（键位覆盖）。**schema 不是写死的**，而是按桥的登记表现拼——
`clamBridge.commands.list()` 里 `configurable` 的那些各成一项，
默认值取声明里的 `key`。登记表静默 300ms 后注册一次；之后指纹变了就 dispose
子 fiber 再注册一份（`dsh-settings` 的 `register` 重复注册 fails loud，但撤销调用方
fiber 就能解注册）。一条可配置命令都没有时**不注册**——不开空卡片。
用户存过的覆盖值不受影响：它们躺在设置文档里，schema 只决定怎么解析与显示。

## 已知毛刺

`dsh web` 自己会另开一个浏览器标签页（`web-app` 行的 `openBrowser` 默认 `true`），
和壳窗口重复。眼下用 `dsh web --no-open`；插件不去改 web-app 的行配置，
因为 patch 的 `{id, config}` 是整体替换而非深合并，动它会连带抹掉该行其余的键。

## 日志

进度写终端（`clam-app: …`，仿 dsh 自己的 `dsh web: …`），同时喂 `ctx.logger`。
**`dsh web` 默认不装 logger exporter**，只走 logger 的消息进环形缓冲、终端上看不见——
这就是本插件另外直写 stderr 的原因。完整 xcodebuild 输出落
`~/Library/Application Support/io.wenbo.surfclam/logs/clam-app-build.<profile>.<配置>.log`，
终端只留结论与失败时的最后 20 行。**文件名带 profile 是必须的**：这份日志是覆盖写，
多 worktree 各跑各的 dsh 时，共用文件名就会让你打开终端指的那条路径、读到邻居的编译错误。
