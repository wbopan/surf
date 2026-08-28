# clam-app

Surfclam macOS 壳的宿主插件。载荷是 `host/` 里的整个 Xcode 工程——壳源码不是特权目录，
只是本插件的一份资产，如同 `swift/` 之于 clam-sidebar。

## 它做三件事

`dsh web` 加载到本行时（`inject: ["webServer"]`，端口已定）：

1. **写 endpoint 发现文件** `~/Library/Application Support/io.wenbo.surfclam/endpoints/<profile>.json`
   （`{httpBase, bridgePath, pid, startedAt, profile, hostDir}`，原子写）。先于构建落地，
   一个已经开着的 app 立刻就能接入，不必等分钟级的首次构建。fiber 卸载时按 pid
   匹配删除——两个 dsh 并存时，先退的那个不会把后来者的文件删掉。
   `hostDir` 是本插件所在的 `clam-app/host` 绝对路径：没拿到 flag 的壳靠它认出
   "哪一份是我这一套"（壳的 bundle 就在 `<hostDir>/build/Build/Products/<配置>/`），
   否则多 worktree 时它会连上邻居的 dsh 并编译邻居的插件源码。
2. **按需构建**：源码 hash 变了或产物缺失 → `write-build-timestamp.sh` +
   `xcodegen generate` + `xcodebuild -derivedDataPath build`（与 `scripts/dev.sh`
   同一套步骤）。hash 只看内容不看 mtime，换 git 分支不会被误判成"改过"。
   共享 module（眼下只有 ClamSDK）由工程自己的 pre/postBuild 脚本管，本插件不用操心。
3. **拉起**：产物就绪且 app 未运行 → `open <app> --args --clam-endpoint <httpBase>`。

然后 provide `clamApp = {appPath, freshness, configuration, httpBase, bridgePath}`。

## 壳里还剩什么（M6 之后）

界面已经全在插件里，通知线也已丢弃（计划 §7.3），壳只保留"让插件能跑起来"的那部分：

| 目录 | 职责 |
|---|---|
| `host/Sources/ClamSDK/` | 壳↔插件的 ABI 词汇。编成独立 dylib 随 bundle 分发，全进程只有一份 |
| `host/Sources/Native/` | BridgeClient（连 clam-bridge 的 WS）、CompilerService（内容寻址地跑 swiftc）、NativePluginHost（dlopen + activate + 世代账）、ShellRootView（root 槽 + 全出血 WebView 兜底） |
| `host/Sources/MainWindowController.swift` | 窗口、菜单、连接状态机、页内桥消息转 EventBus。没有业务 UI |

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
没有 Xcode 时退化为只探测既有产物：先 `host/build/Build/Products/<配置>/`，
再 `/Applications/Surfclam.app`。

## 配置（`cordis.patch.yml`，可被 profile 的 patch 层覆写）

| 键 | 默认 | 含义 |
|---|---|---|
| `configuration` | `Debug` | `Debug` 产物是 `Surfclam Dev.app`（`io.wenbo.surfclam.dev`），`Release` 是 `Surfclam.app`；两者可并存运行 |
| `build` | `true` | 关掉则只探测既有产物，从不调用 xcodebuild |
| `launch` | `true` | 关掉则只构建、只写发现文件，由用户自己开 app |

开发期默认 `Debug`；日常使用者应在自己 profile 的 `cordis.patch.yml` 里覆写成 `Release`。

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
