# dash-app

dash macOS 壳的宿主插件。载荷是 `host/` 里的整个 Xcode 工程——壳源码不是特权目录，
只是本插件的一份资产，如同 `swift/` 之于后续的 dash-sidebar。

## 它做三件事

`dsh web` 加载到本行时（`inject: ["webServer"]`，端口已定）：

1. **写 endpoint 发现文件** `~/Library/Application Support/io.wenbo.dash/endpoint.json`
   （`{httpBase, bridgePath, pid, startedAt, profile}`，原子写）。先于构建落地，
   一个已经开着的 app 立刻就能接入，不必等分钟级的首次构建。fiber 卸载时按 pid
   匹配删除——两个 dsh 并存时，先退的那个不会把后来者的文件删掉。
2. **按需构建**：源码 hash 变了或产物缺失 → `write-build-timestamp.sh` +
   `xcodegen generate` + `xcodebuild -derivedDataPath build`（与 `scripts/dev.sh`
   同一套步骤）。hash 只看内容不看 mtime，换 git 分支不会被误判成"改过"。
3. **拉起**：产物就绪且 app 未运行 → `open <app> --args --dash-endpoint <httpBase>`。

然后 provide `dashApp = {appPath, freshness, configuration, httpBase, bridgePath}`。

## 优雅缺席

构建失败、没装完整 Xcode、连既有产物都找不到——都只在终端留一句话就收手，
**不重试、不成环**（防的是构建风暴）。dsh 照常服务浏览器，只是没有 macOS 壳。
没有 Xcode 时退化为只探测既有产物：先 `host/build/Build/Products/<配置>/`，
再 `/Applications/dash.app`。

## 配置（`cordis.patch.yml`，可被 profile 的 patch 层覆写）

| 键 | 默认 | 含义 |
|---|---|---|
| `configuration` | `Debug` | `Debug` 产物是 `dash Dev.app`（`io.wenbo.dash.dev`），`Release` 是 `dash.app`；两者可并存运行 |
| `build` | `true` | 关掉则只探测既有产物，从不调用 xcodebuild |
| `launch` | `true` | 关掉则只构建、只写发现文件，由用户自己开 app |

开发期默认 `Debug`；日常使用者应在自己 profile 的 `cordis.patch.yml` 里覆写成 `Release`。

## 已知毛刺

`dsh web` 自己会另开一个浏览器标签页（`web-app` 行的 `openBrowser` 默认 `true`），
和壳窗口重复。眼下用 `dsh web --no-open`；插件不去改 web-app 的行配置，
因为 patch 的 `{id, config}` 是整体替换而非深合并，动它会连带抹掉该行其余的键。

## 日志

进度写终端（`dash-app: …`，仿 dsh 自己的 `dsh web: …`），同时喂 `ctx.logger`。
**`dsh web` 默认不装 logger exporter**，只走 logger 的消息进环形缓冲、终端上看不见——
这就是本插件另外直写 stderr 的原因。完整 xcodebuild 输出落
`~/Library/Application Support/io.wenbo.dash/logs/dash-app-build.<配置>.log`，
终端只留结论与失败时的最后 20 行。
