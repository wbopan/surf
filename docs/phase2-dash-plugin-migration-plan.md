# 阶段二计划:dash —— 壳最小化,一切皆插件,dsh 为先

> 本文档面向执行者(人或模型),假设对本仓库无前置了解。所有上游事实均已对照
> harness `0.1.1-rc.2`(`~/Library/Application Support/io.wenbo.dsharness/harness/current`)
> 的已安装源码实地验证(2026-08-25 两次调查);执行时如与源码冲突,以源码为准并更新本文档。
> 阶段一(原生侧边栏)已完成,见 `docs/phase1-native-sidebar-plan.md`;本阶段在其之上。

## 0. 目标与终态

### 0.1 一句话

把 DSHarness 这个 macOS 壳应用改名为 **dash**,并把整个项目拆解为一组住在
`~/.dsh/profiles/plugins/` 下的 cordis 插件。**启动方向反转**:不再是 app spawn dsh,
而是 `dsh web` 先启动、加载插件树,其中的 dash-app 插件负责构建并拉起 dash.app(带 endpoint flag);
app 是 dsh 的客户端外设——一个极薄的原生壳(窗口 + registry + 桥客户端 + swiftc 编译机),
其余一切能力(布局、侧边栏、页内适配)都是"带 Swift 载荷的 cordis 插件",
由壳内编译机现场编译、热替换。迁移完成后 `~/Repos/dsh-mac` 退役,
`~/.dsh/profiles/plugins/` 成为唯一仓库。

### 0.2 终态目录(= 新的 git 仓库根)

```
~/.dsh/profiles/plugins/            ← git 仓库根(继承 dsh-mac 全部历史;可设 npm workspace 供 dash-* 互引)
├── dash-app/                       ← 壳源码为载荷的插件:xcodebuild 构建 + 拉起 + provide 'dashApp'(§7.5)
│   ├── package.json  lib/index.js  cordis.patch.yml
│   └── host/                       ← Xcode 工程载荷:project.yml、Sources/(含 DashSDK module)、
│                                      Packages/、scripts/、build/(gitignore)
├── dash-bridge/                    ← 特权 TS 插件:WS + 登记表 + snapshot/changed + 审批;
│                                      子出口 `dash-bridge/plugin` = createSwiftPlugin 工厂(§4.2)
├── dash-layout/                    ← TS 半身 + swift/(root 槽、WebView 排版、sidebar 槽)
├── dash-sidebar/                   ← TS 半身 + swift/(现 DSHSidebarUI 迁入)
├── dash-web-adapter/               ← 现 dsharness-web-adapter 搬家改名(页内 CSS/桥)
├── docs/                           ← 本文档等
└── dsh-web-search-firecrawl/       ← 已存在的邻居插件,收编入库或 gitignore(执行时二选一)
```

**用户体验 = 把 dash-\* 插件放进自己的 `profiles/plugins/`、逐个 `dsh plugin add`、运行
`dsh web`,macOS app 就出现了**(首次由 dash-app 现场构建,分钟级;此后源码没变秒起)。
仓库里不存在任何非插件的特权目录——壳源码只是 dash-app 的载荷。

每个插件用 `dsh plugin --profile web add link:~/.dsh/profiles/plugins/<name>` 注册。
**真实路径在 `~/.dsh/profiles/` 之下**是硬约束(见 §1.4),仓库根选在这里正是为了满足它,
从此所有插件都可以自由 import `@deepseek-ai/*`(写进 `peerDependencies`)。

### 0.3 终态运行时拓扑(启动方向:自上而下)

```
dsh web(用户从终端启动;后续可 launchd 化)
 ├─ Cordis 内核 + 官方插件树
 ├─ dash-bridge(node 半边,特权):
 │    1. ctx.webServer.registerUpgrade('/dash/bridge')  ← WS,同 dsh 端口
 │    2. Swift 载荷登记表 + snapshot/changed 广播 + 写路径
 ├─ dash-app:host/ 内壳源码 → xcodebuild(内容寻址,源码没变不重编)→ 检测未运行则
 │    open -n 拉起(--dash-endpoint = webServer 端口 + 桥路径;endpoint 发现文件也由它写)
 │    → provide 'dashApp'(§7.5)
 ├─ dash-layout/sidebar 的 TS 半身
 │    (inject dashBridge 登记 Swift 源码;订阅宿主事件)
 └─ dash-web-adapter(client 半边:页内 CSS/桥)

dash.app(壳,被拉起的客户端外设)
 ├─ 启动定位 dsh:--dash-endpoint flag → endpoint 发现文件 → 都没有=引导页("请运行 dsh web")
 ├─ BridgeClient ◀──ws://127.0.0.1:<port>/dash/bridge──▶ dash-bridge
 ├─ CompilerService/Loader:swiftc 现场编译 → dylib 世代 → dlopen(泄漏式退休)
 ├─ Registry(@Observable,只放拓扑)+ 宿主对象保管箱 + PluginStore + EventBus
 └─ 窗口 + root 槽(NSHostingView)
      ├─ dash-layout 在场:HSplitView[原生 sidebar 槽 | WKWebView]
      └─ 缺席/失败:壳 fallback = 全出血 WKWebView(完整网页模式,终极逃生舱)
```

**壳不再包含**:spawn dsh、端口选择、npm 安装/自更新 harness、Node 探测——这一整层
(HarnessProcess/HarnessManager/NodeResolver/Shell/Semver,约 710 行)随反转退役。
dsh 自身的安装与版本管理回归终端(`npm i -g @deepseek-ai/dsh@0.1.1-rc.2`,钉版本)。

### 0.4 命名

App 叫 **dash**。插件前缀 `dash-*`。Swift module 前缀 `Dash*`。改名波及面见 §2.4。

### 0.5 不变量(全程遵守)

1. **真相在 harness 侧**:会话/选中/配置的唯一真相是 dsh(服务 + append-only 日志);原生 UI 只是投影加输入设备;Swift 侧 store 只存"丢了不心疼"的装饰状态(`try?` decode,失败=冷启动)。
2. **壳只留残留层**:窗口/root 槽、Registry、桥客户端、编译机、终极逃生舱(全出血 WebView)、entitlement 权能预算。任何业务 UI/业务逻辑不许新增进壳。壳源码本身也不特权——它只是 dash-app 插件的载荷(`host/`),构建与拉起归 dsh 侧;"残留"指的是 app **进程**运行时不可被 Cordis 挂载这一事实,不是某个目录的特权地位。
3. **数据过桥,引用不过桥**:TS↔Swift 只传序列化数据;Swift 插件间只经 SDK 类型/系统类型 + registry 间接层交互。
4. **Registry 只放拓扑不放流量**:槽占用、世代号、协议对象;高频业务数据住各插件自己的 model。
5. **每个里程碑可构建可运行**,且任一 dash 插件被禁用/编译失败时,系统降级到纯网页模式而不是坏掉;dsh 不在时 app 降级为引导页。
6. **绝不往 session 日志写自定义 event type**(0.1.1-rc.2 会导致 `SessionFormatUnsupportedError`、会话无法重新读取)。桥的一切流量走自己的 WS。

### 0.6 本阶段明确不做(防执行者跑偏)

- iOS / 远程接入(仅在桥协议里保留 `clientId`/seat 字段,M9);`__DSH_TRANSPORT__` 接管。
- SDUI 通用渲染器——仅作为 R1 证伪后的 Plan B,不预先建设。
- widget extension / 编译期贡献接口(dash-app v2)、壳自更新(Sparkle)。
- 多 seat / 多客户端并发语义;launchd 化 dsh。
- **原生通知**(2026-08-25 决策,见 §7.3):连同现有实现一并丢弃,不在本阶段范围内。
- sidebar 数据面迁 TS 半身、DSHKit 退役(M10);设置面板插件化;`session.search` 内容搜索等 phase1 已后置项。
- 性能优化:拓扑同层并行编译、registry 按键精细观察——先糙后精,验收只看功能与门控预算。

---

## 1. 上游机制事实清单(执行者必读,均已源码验证)

### 1.1 cordis(`@deepseek-ai/cordis` 4.0.1,vendored fork,带完整 TS 源码与类型)

- 插件导出:`export default` 优先,否则整个 module namespace 即插件对象。dsh 惯用具名导出
  `export { Config, apply, inject, name }`(函数插件)或 `class X extends Service`(类插件,`super(ctx, "服务名")`)。
- `ctx.provide(name, value)` 注册服务(归当前 fiber,卸载自动注销),返回 dispose;`ctx.set` 只有 provide 方能调。
- `inject` 是数组或对象,**没有 optional 语法**;可选依赖的官方姿势 = 不进 inject、用 `ctx.get(name)` + undefined 检查;
  迟到接线用 `ctx.inject([names], cb)`(服务出现即启动子 fiber、消失即卸载)。未声明就摸 `ctx.xxx` 会被 Guard 拒绝。
- `ctx.effect(() => {...; return 清理})` 或 generator(逐个 `yield` disposer,逆序销毁),带 label 进诊断树。
- `ctx.on(event, listener)` 随 fiber 自动摘除;事件类型经 declaration merging 声明;waterfall 监听器必须 `return next()`。
- `ctx.plugin(pluginObj, config?)` 挂子插件,随父卸载。

### 1.2 双面包与 client 半边

`package.json` 的 `dsh.bundle.patch` 指向自带的 `cordis.patch.yml`(insert 自己的 row);`dsh.client = {platform:"web", inject:[包名]}` + `exports["./client"]` 声明浏览器半边。client 半边是手写 lazy-CJS(`window.__ModuleLoader__.load({id, factory})`),无构建步骤。浏览器可 require:`react`、`@deepseek-ai/cordis`、`dsh-client-ui-primitives`、`dsh-client-ui-slots` 及各插件行。

### 1.3 HMR 边界(决定开发循环设计)

- **node 半边 HMR 在 web bundle 下被官方 disabled**(`dsh-web-app/cordis.patch.yml`:`id: hmr, disabled: true`)。
  改 `lib/index.js`/`package.json`/增删插件行 → **必须重启 dsh**。
- **client 半边 HMR 常开**(`dsh-client-hmr`,500ms statSync 轮询 + SSE `/plugins/events`):改 `lib/client.js` ≈0.5s 自动单插件重载。
- **推论(本计划的关键设计)**:Swift 源码的热循环**不依赖 node HMR**——dash-bridge 常驻,自己以同款 statSync 轮询盯各插件 `swift/` 目录,内容变了就 bump 登记表版本并广播;TS 半身完全不用重载。TS 半身逻辑本身的改动接受"重启 dsh"的代价(低频)。

### 1.4 out-of-tree 插件解析契约(memory:`dsh-out-of-tree-plugin-resolution`)

`healProfilesModuleFallback()` 每次启动把 harness 依赖闭包(含 peerDependencies,197 个 `@deepseek-ai/*`)扁平 symlink 到 `~/.dsh/profiles/node_modules/`。插件对 `@deepseek-ai/*` 的解析靠 Node 从**真实路径**向上遍历命中该目录——所以:

- 插件真实路径必须在 `~/.dsh/profiles/` 之下(pnpm `link:` 会被 realpath);
- `@deepseek-ai/*` 写 **peerDependencies**(版本 `^0.1.1-rc.2`),**不写 dependencies**、不用 pnpm 装——运行时解析到 harness 内同一份模块实例(cordis 服务/Symbol 身份匹配的前提;profile 的 `autoInstallPeers: false` 正为此);
- `dsh plugin --profile web add link:<path>` 之后,凡包声明了 `dsh.bundle.patch`,包名自动 reconcile 进 profile `package.json` 的 `dsh.profile.bundles`。

### 1.5 webServer 服务(桥的挂载点)

`ctx.webServer`(`dsh-host-webserver`):`register(route)`(exact/prefix)、`registerUpgrade(route)`(**WS 升级,exact pathname**)、`tapIndex`、`.port/.host`。匹配 exact → 最长 prefix → fallback,重复路径抛错。注意:`/api` 的 loopback Host/Origin 信任栅栏是 `dsh-client-connection` 自己做的,**自注册路由要自查**(仿 `src/api-request-trust.ts`:Host 必须 loopback)。

### 1.6 与本计划相关的服务/事件(宿主 node 侧)

- 服务:`sessions`(SessionStore:`create/get/list/fork/flush`)、`workspaceRegistry`、`sessionProjections`(列表行投影:title 等)、`approval`、`userQuestions`、`agents`、`webServer`、`webStartup`、`appExit`、`settings`、`storage`。
- 事件:`session/created|disposed|event|flush`、`approval/request`、`agent/error|status`(**原通知插件的候选事件源,该插件已放弃**;**确切名字与 payload 执行时对照 `dsh-approval`/`dsh-agent` 源码及 `dsh-host-apiproxy` 帧转译处**,mux 帧 `approval/requested` 等即由宿主事件转译而来)。
- 浏览器侧 runtime(`dsh-client-runtime` 一包五服务):`ctx.sessions`(`open(id)`、`list.subscribe/getSnapshot`,快照含 `current/currentAddress`)、`ctx.workspaces`(`startSession/archiveSession/rename/...`)、`ctx.layout`(仅 `toggleSidebar/openDetails/closeDetails`)、`ctx.slots`。现有 web-adapter 用的全部核对无误。

### 1.7 其他已核实的边界

- 隐藏网页侧边栏**没有官方开关**:`ui-sidebar` 行可 disable,但 56px rail 是 `ui-layout` AppFrame 无条件渲染的;现有 CSS 平移方案是唯一解,保留。
- 唯一官方 query 参数是 `?fixture`;`?dsharness-native-sidebar=1` 是我们自造的(改名后 `?dash-native-sidebar=1`)。
- `globalThis.__DSH_TRANSPORT__` 是官方传输层替换接缝——本阶段不用,记为 iOS 远程线储备。
- patch 层叠顺序:空根 → bundles 各自 patch → profile `cordis.patch.yml` → `$DSH_HOME/cordis.patch.yml` → `--patch`;`{id, config}` 是**整体替换**不是深合并。
- 别在 agent preset 里 provide 服务(会撞进程全局 realm);dash 系插件全部住 profile/web bundle 层。
- ~~目前系统 PATH 上没有 `dsh` 命令~~ → M0 已全局安装 `@deepseek-ai/dsh@0.1.1-rc.2`(`npm i -g`,钉版本),终端 `dsh web` 直接可用;
  壳内 npm 管理的那份随 M1 启动反转废弃(`<AppSupport>/harness/` 目录可手动删)。
- **`ctx.logger` 在 `dsh web` 下没有 exporter**(M1 实测):cordis 的 LoggerService 不自带默认 sink,
  没人 `ctx.logger.exporter(...)` 时消息只进环形缓冲,终端上一个字都看不见。要给蹲在终端的人看的进度,
  必须自己写 stdout/stderr——仿 dsh 自己的 `dsh web: <url>`(那是 `console.log`,不是 logger)。
  dash-app 的做法是两边都喂:`logger[level]` + `process.stderr.write("dash-app: …")`。
- **`dsh web` 会自己开一个浏览器标签页**:`dsh-web-app` 行的 `openBrowser` 默认 `true`,与壳窗口重复。
  眼下靠 `dsh web --no-open` 规避。插件不去 patch 该行的 config——`{id, config}` 是**整体替换**不是深合并(见上),
  改一个键会连带抹掉 `printUrl` 等其余键。M8 打磨时再定(候选:壳拉起成功后由 dash-app 自己 tapIndex 提示,或让用户在 profile 层覆写整段 config)。

---

## 2. M0:固化、搬家、改名(先于一切改造)

### 2.1 工作区固化

1. **当前 HEAD(`4f561f4`)编译不过**(`MainWindowController.setupWindow()` 缺结尾大括号,工作区已修)。
   先把工作区三个改动提交掉(编译修复 + 窗口收窄自动折叠 + SidebarView 分组头重做)。
2. `DSHarness/Resources/BuildTimestamp.txt` 移出版本控制(gitignore + 保证 prebuild 脚本在文件缺失时创建),
   消灭"每次构建必脏"。
3. 顺手删除已确认的死代码可以推迟到 M8,此处不阻塞。

### 2.2 目录重排(git mv,历史保留)

| 现路径 | 新路径 |
|---|---|
| `DSHarness/` `project.yml` `scripts/` `tools/` | `dash-app/host/`(源码目录可改名 `Sources/`,project.yml 同步) |
| `Packages/DSHKit` `Packages/DSHSidebarUI` | `dash-app/host/Packages/`(暂留原名,M6/M8 再迁移/退役) |
| `plugins/dsharness-web-adapter/` | `dash-web-adapter/` |
| `docs/` `CLAUDE.md` `README.md` | 仓库根照旧(内容 M8 重写) |
| `skills/` `.firecrawl/` `build/` | gitignore 已覆盖,随缘;`build/` 挪进 `dash-app/host/build/` |

### 2.3 仓库搬家

```bash
# 1. 确认干净后整体移动(新家即仓库根)
mv ~/Repos/dsh-mac ~/.dsh/profiles/plugins
# 2. 重布 profile 依赖(旧 link 指向已消失的 repo 路径)
dsh plugin --profile web remove dsharness-web-adapter   # 已实测：参数直接透传 pnpm
dsh plugin --profile web add link:~/.dsh/profiles/plugins/dash-web-adapter
```

- 若 `~/.dsh/profiles/plugins/` 已存在(内有 `dsh-web-search-firecrawl`):先 `git init` 化整个目录再把 dsh-mac 历史合并进来(`git remote add old ~/Repos/dsh-mac && git fetch && git merge --allow-unrelated-histories`),或反向"mv 仓库进来 + 把 firecrawl 目录收编/加 gitignore"。二选一,以保 firecrawl 插件不断线为准。
- 搬家后 Claude Code 的项目目录/memory 路径随之变化,属预期。
- 验收:`dsh web` 正常起、壳 App `scripts/dev.sh` 全流程可构建可运行、web-adapter 功能不变。

### 2.4 改名清单(跨层硬耦合常量,必须一次全换)

| 项 | 旧值 | 新值 |
|---|---|---|
| PRODUCT_NAME / 显示名 | `DeepSeek Harness` / `DSHarness Dev` | `dash` / `dash Dev` |
| Bundle id | `io.wenbo.dsharness(.dev)` | `io.wenbo.dash(.dev)` |
| Application Support | `~/Library/Application Support/io.wenbo.dsharness/` | `io.wenbo.dash/`(仅存编译缓存/账本/endpoint 文件;旧目录里的 npm harness 安装随 §2.5 废弃,无迁移) |
| UA 片段(门控) | `DSHarness/<ver>` | `Dash/<ver>`(client.js 检测 `Dash/`,带斜杠防误命中) |
| WKScriptMessageHandler | `dsharness` | `dash` |
| 页内桥 | `window.__dsharness` | `window.__dash` |
| URL 参数 | `dsharness-native-sidebar=1` | `dash-native-sidebar=1` |
| patch row id | `ui-dsharness-adapter` | `ui-dash-adapter` |
| 插件包名 | `dsharness-web-adapter` | `dash-web-adapter` |
| 窗口/分栏 autosave key | `MainWindow.v3` / `MainSidebar.v3` | `DashMainWindow.v1` / `DashMainSidebar.v1`(顺势重置) |
| 日志/通知 threadIdentifier 等 | `dsharness` | `dash` |
| 死常量 `dsharnessSidebar` handler(client.js) | — | 顺手删除 |

改名与搬家在同一里程碑内完成,避免两套名字并存。

### 2.5 dsh 安装方式切换(启动反转的前置)

```bash
npm i -g @deepseek-ai/dsh@0.1.1-rc.2   # 钉版本;从此终端 `dsh web` 可用
```

验证 `dsh --version`、`dsh web` 起得来、profile 照常加载后,壳内 npm 安装的那份
(`.../harness/versions/`)即废弃。升级 dsh = 手动改全局安装版本 + 跑回归清单(§9-R2)。

### 2.6 M0 执行顺序与回滚点(逐步验证,任一步失败先回滚再排查)

1. 提交工作区(§2.1)→ `xcodebuild` 过、`scripts/dev.sh` 全流程过。**回滚点 α**。
2. 全局安装 dsh(§2.5)→ 终端 `dsh web` 起、浏览器可用、`dsh plugin --profile web` 子命令探明
   (确切增删语法以 `dsh plugin --help` 为准,文档假设处更新)。
3. 仓库内 git mv 重排 + 全部改名(§2.2/§2.4,可拆多个 commit:重排一个、改名一个)→ 原地重新构建跑通
   (此时仍在 `~/Repos/dsh-mac`,web-adapter 的 profile link 临时断开属预期)。**回滚点 β**(git reset)。
4. 整仓 mv 到 `~/.dsh/profiles/plugins/` + 处理 firecrawl 邻居(§2.3)。
5. profile 重布线(remove 旧 add 新)→ `dsh web` 起、`cat ~/.dsh/profiles/web/package.json` 确认
   bundles 含 `dash-web-adapter`、页内适配生效(壳里 ⌘R 检查侧边栏隐藏)。
   **回滚**:mv 回原路径 + 恢复旧 link。
6. **在新仓库根写 `CLAUDE.md`**(执行 agent 的会话指引会因搬家丢失):构建命令与
   `-derivedDataPath build` 硬约束、§1.4 布线契约摘要、指向本计划文档、当前推进到的里程碑。
7. Application Support 新目录 `io.wenbo.dash/` 建立;旧 `io.wenbo.dsharness/` 保留一个版本周期后手动删。

每个里程碑完成后在 §12 执行日志记一行;发现文档与源码冲突,以源码为准并**就地更新本文档**。

---

## 3. M1:启动反转(app 变客户端外设)

拆解为三件事,交付后 app 功能等价现状但少约 710 行、时序反转:

1. **壳退役 spawn 层**:删 `HarnessProcess`、`HarnessManager`、`NodeResolver`、`Semver`,
   `Shell` 视余量保留;`SettingsWindowController` 里 Node 路径/更新频率/检查更新全部退役
   (窗口保留为壳偏好占位或一并删除);菜单 ⌘U 删除,⌘⇧R 语义改为"经桥请求 dsh 重启"
   (dsh 侧有 `appExit` 服务;若终端前台跑 dsh 则退出即止,由用户重启——记入引导文案)。
2. **app 启动定位 dsh(三级)**:`--dash-endpoint http://127.0.0.1:<port>` flag →
   endpoint 发现文件(`Application Support/io.wenbo.dash/endpoint.json`,内容
   `{httpBase, bridgePath, pid, startedAt, profile}`)→ 都失败=引导页
   ("未检测到 dsh,请运行 `dsh web`",带重试;dsh 起来后发现文件出现即自动接入)。
   健康检查退化为"对 httpBase 发一次 GET 确认",状态机大幅简化。
3. **dash-app 插件 v0(壳源码入插件,构建+拉起;桥通信是 dash-bridge 的事,M4 再加)**:
   - 壳 Xcode 工程即插件载荷 `dash-app/host/`;`apply(ctx)` 里 `ctx.inject(['webServer'], ...)`:
     产物缺失或源码 hash 变化 → `xcodegen + xcodebuild -derivedDataPath build`(即 dev.sh 逻辑
     入插件;构建日志落 dsh 终端)→ provide `dashApp = {appPath, freshness}`;
   - `ctx.effect` 写 endpoint 发现文件(卸载/退出删除);检测 dash.app 是否已运行(按 bundle id
     `pgrep`/`lsappinfo`),未运行则 `open -n <appPath> --args --dash-endpoint ...` 拉起;
   - **防双开/防风暴**:已运行则跳过;构建/拉起失败只记日志与终端提示,不重试循环;
     无 Xcode → 只探测既有产物(`/Applications/dash.app` 等),再无 → 终端提示、优雅缺席
     (dsh 照常服务浏览器);
   - `scripts/dev.sh` 保留为同一逻辑的手动捷径,M8 后视冗余退役。

验收:终端 `dsh web` → app 自动弹出并正常工作;直接双击 app(dsh 已活)→ 发现文件接入;
dsh 未起时双击 → 引导页;dsh 退出 → app 显示断连状态不崩,dsh 回来自动恢复。

### 3.1 M1 实做与本节的偏差(已交付,以此段为准)

- **⌘⇧R 的语义**:计划写"经桥请求 dsh 重启",但桥是 M4 的东西,M1 没有反向通道。
  实做为**"重新连接 dsh"**——忘掉当前端点、立刻重走三级定位。M4 有桥之后再升级成请求 dsh 重启自己。
- **⌘U 与设置窗口**:⌘U(检查 harness 更新)按计划删除;`SettingsWindowController` 走了"一并删除"这一支
  (Node 路径与更新频率两项皆已失效,壳再无偏好可设)。⌘, 没有空置,改为经页内桥调 `window.__dash.openSettings()`
  打开 dsh 自己的设置面板——该 capability 页内早就有,此前壳没用上。
- **`Shell.swift` 也删了**:计划写"视余量保留",实测除 `HarnessManager` 外无任何引用面。`Log.swift` 保留。
- **健康检查是 2s 周期轮询,不是一次性的**:壳已不是 dsh 的父进程,拿不到它的退出信号,
  "断开"和"回来"都只能靠周期性 GET 发现。同一时刻只允许一个探测在飞。
  轮询同时兼任三级定位的重试,引导页上的"立即重试"只是催一次,不重试也会自己接回来。
- **端点变化 = 整件重装镜像**:`sessionStorePort: Int` 换成 `sessionStoreBase: URL?`;
  dsh 换端口回来时先 `uninstallSidebar()` 再重装(已 stop 的 store 不会自己复活)。实测 0 → 24 条会话正常。
- **endpoint 发现文件由插件按 pid 匹配删除**:fiber dispose 时先读回文件,`pid` 不是自己就不动——
  两个 dsh 并存时,先退的那个不该把后来者的文件删掉。dsh 被 SIGKILL 时文件会残留,
  这正是壳侧那次 GET 健康检查存在的理由(残留文件 → 探测失败 → 引导页)。
- **构建日志**:计划写"落 dsh 终端"。实做为终端只留结论(仿 `dsh web:` 的 `dash-app: …` 行),
  完整 xcodebuild 输出落 `<AppSupport>/logs/dash-app-build.<配置>.log`,失败时终端补最后 20 行。
  理由见 §1.7 新增的 logger 事实。
- **源码 hash 覆盖面**:`project.yml` + `Sources/` + `Packages/` + `scripts/`,内容摘要(不看 mtime,
  换 git 分支不误判)。排除 `Sources/Resources/BuildTimestamp.txt`(prebuild 每次重写,进 hash 会让
  "源码没变"永远不成立)与 `tools/`(xcodegen 二进制)。marker 存 `build/.dash-app-source-hash.<配置>`——
  与产物同生共死,`build/` 被清时它一起消失,语义自洽。
- **未覆盖**:无完整 Xcode 的降级路径(只探测既有产物)是照着写的,**没有实测**——本机装着 Xcode,
  短期内不打算卸。M8 收尾前找一台干净机器或临时 `xcode-select` 到 CLT 验一次。

---

## 4. SDK 的物理归宿(无独立 dash-sdk 目录)

SDK 作为**概念**存在(壳↔插件的 ABI 词汇 + 插件作者的 TS 工厂),但不设独立目录——
两半各自住进已有的家,仓库里不留"只因别人需要才存在"的包。

### 4.1 Swift 半:`DashSDK` module,住 `dash-app/host/Sources/DashSDK/`(编译进壳;插件编译时 `-I` 指向 App bundle 内分发的 `.swiftmodule`/`.swiftinterface`)

内容(全部是"世代无关"的类型,即插件间、代际间传递安全的词汇):

- **ABI 入口**:每个插件 dylib 导出 `@_cdecl("dash_plugin_entry")`,返回指向 `DashPlugin` 实现的不透明指针
  (`Unmanaged.passRetained`;确切签名 M2 spike 定稿后写进 `docs/native-abi.md`)。
- `protocol DashPlugin`:`activate(host: DashHost)`,返回可选 handle;**无强制的快照方法**(状态外置见下)。
- `DashHost`(壳实现,递给插件):
  - `registry`:`@Observable` 槽注册表——`register(slot:factory:)`(effect 式,返回撤销闭包)、`view(for:)`、每键版本号。**只放拓扑**。
  - `objects`:宿主对象保管箱(`[String: AnyObject]`,只放系统/SDK 类型实例——WKWebView、DSHKit SessionStore 等,跨代直通存活)。
  - `store`:per-plugin 命名空间的 `persist/recall`(`Data` + `try?` JSONDecoder,尽力而为;真卸载清空、替换保留)。
  - `events`:进程内 EventBus(几十行;subscribe token 绑插件世代,替换时由壳批量吊销,防幽灵监听)。
  - `bridge`:向自己的 TS 半身收发信封消息(`send(channel:payload:)` / `onMessage`,MainActor 派发)。
- **纪律**(写进 SDK 文档,编译机可部分静态检查):不 `@objc`、不继承 NSObject、跨界只用 SDK/系统类型、
  `@State` 只放丢了不心疼的、想活过热替换的状态进 `store` 或 TS 半身。

SDK module 以 `-enable-library-evolution` 编译进壳并随 bundle 分发 `.swiftinterface`;插件本身不必开 evolution(同机同 toolchain)。它与壳必须严格同版本(壳实现 `DashHost`),住在壳源码里让"SDK 版本 = 壳版本"成为结构事实而非纪律。**插件间协议不进 SDK**(如 `DashSidebarProvider` 住 dash-layout,随 `.swiftmodule` 传递):SDK 只是内核词汇,生态词汇由插件自带。

#### 4.1.1 M3 实做与本节的偏差(已交付,以此段为准)

- **SDK 不能编进壳的 app module**,必须是**独立 dylib**:壳与插件要共用同一份类型身份,
  就得链接同一个文件。做法 = `scripts/build-modules.sh` 用 spike 那套 swiftc 命令把
  `Sources/DashSDK/` 编成 `host/build-sdk/libDashSDK.dylib`,`postBuildScripts` 的
  `embed-modules.sh` 摆进 `Contents/Frameworks/`(壳按 `@rpath` 加载)与
  `Contents/Resources/DashModules/`(插件编译时 `-I` 的落点),然后重新 ad-hoc 签名
  (拷贝晚于 Xcode 的签名步骤,不重签会破 CodeResources 封印)。
  app target 的 `sources` 必须 `excludes: DashSDK`,否则类型身份一分为二。
- **DSHKit 一并升为共享 module**(计划原本要它留在壳里当 SwiftPM 包)。理由是 §7.2 的
  数据面方案要求 sidebar 插件能 `import DSHKit` 并从保管箱取壳造的 `SessionStore`——
  跨 dylib 用同一个类型,就必须和 DashSDK 同等待遇。顺带删掉了 DSHSidebarUI 对 DSHKit
  的 SwiftPM 依赖(M2 已确认源码层面根本没用),否则会静态链进来第二份。
  `Packages/DSHKit/` 目录保留(它的单元测试还在),只是不再作为 SwiftPM 依赖进壳。
- **`DashHost` 是 final class 不是协议**:壳只需要构造它、填好闭包。这样跨 dylib 的协议
  见证表只剩 `DashPlugin` 一处,ABI 面越窄换代时越不容易出意外。
  `DashRegistry`/`DashObjects`/`DashEventBus`/`DashStore`/`DashBridge` 的实现全在 SDK dylib 里,
  壳不重复实现。
- **不加 `@MainActor`**:M2 没有覆盖跨 dylib 的 actor 边界,少一个未验证的变量比多一层
  静态保证划算。线程约定写在文档注释里(只在主线程用)。
- `DashDisposable` 的撤销**带 token 校验**:旧世代析构时若槽已被新世代接管,撤销是空操作。
  没有这一条,"新代先注册、壳再松手放旧代"的替换时序会被旧代的析构反手清掉。

### 4.2 TS 半:`createSwiftPlugin` 工厂,住 dash-bridge 的子出口 `dash-bridge/plugin`

工厂做的事本就是与桥的登记表 API 对话——契约两端(服务实现与客户端工厂)同住一包,永不漂移;
各插件 `import { createSwiftPlugin } from 'dash-bridge/plugin'`。八成插件的 node 半边就是一段配置:

```ts
export default createSwiftPlugin({
  name: 'dash-sidebar',
  inject: ['dashBridge', 'dash-layout'],      // cordis 依赖 = 挂载时序 = Swift 编译拓扑序,一份声明两层消费
  swiftDir: new URL('../swift/', import.meta.url),
  swiftDeps: ['dash-layout'],                  // Swift module 依赖(import DashLayout)
  subscribe: { /* 可选:向 Swift 推的数据流,如 ctx.on(...) 转发 */ },
  expose:    { /* 可选:Swift 可回调的动作 */ },
})
```

工厂内部:`ctx.get('dashBridge')`(可选依赖姿势,桥缺席则本插件的 Swift 载荷优雅不登记)→ `ctx.effect` 登记
`{plugin, swiftDir, swiftDeps, schemaVersion}`,卸载自动撤销;subscribe/expose 统一走桥信封,插件永不直接摸 WS。

**解析定案(M3)**:走**相对路径 import**——`import { createSwiftPlugin } from "../../dash-bridge/lib/plugin.js"`。
`healProfilesModuleFallback` 只镜像 harness 闭包,不含用户插件;包名 import 要么靠仓库根的
npm workspace、要么靠手工 symlink,两者都是**机器本地状态,新克隆的仓库拿不到**,
与 §0.2 "把 dash-\* 放进 plugins/、逐个 add、跑 dsh web 就能用"的体验目标冲突。
相对路径在"所有 dash-\* 是同一仓库里的兄弟目录"这个前提下永远成立,零配置。
(不影响 dsh 对各插件本身的解析,那走 profile 的 `link:`。)

### 4.3 各插件为满足时序还需 provide 一个空标记服务

`dash-layout` 的 TS 半身 `ctx.provide('dash-layout', {})`,让 `dash-sidebar` 能 `inject: ['dash-layout']`——
Cordis 依赖解析由此保证:layout 未挂好 sidebar 不挂载、layout 替换时 sidebar 级联重载,桥照此顺序重编。

---

## 5. dash-bridge:唯一特权插件

### 5.1 node 半边(标准函数插件:`export { name, inject, apply, Config }`)

- 拉起与构建归 dash-app(§3-3、§7.5),本插件纯通信;M4 交付:
  1. `ctx.provide('dashBridge', api)`——登记表 API(`registerSwiftPayload/unregister`)。
  2. `ctx.effect(() => ctx.webServer.registerUpgrade({ path: '/dash/bridge', ... }))` 挂 WS(同端口)。
     握手校验:Host 必须 loopback(仿 `api-request-trust`)+ 简单版本协商帧。
  3. **Swift 源码轮询**:对登记表中每个 `swiftDir` 做 500ms statSync(mtime+size,变了再 hash 文件集)——
     与 `dsh-client-hmr` 同款、纯 polling、无 watcher 依赖。内容 hash 变化 → 登记表版本(全表 hash)bump → 广播 `changed{version}`。
  4. 读路径(pull 模型,桥对客户端零状态):`snapshot` 请求 → 按拓扑序(由各插件 inject/swiftDeps 排序)返回
     `[{plugin, files:{path:content}, deps, contentHash, schemaVersion}]` + 总版本号。
     **级联重编是硬约束**(M2 断言 6 实测,见 `docs/native-abi.md` §4):上游 `contentHash` 变化时,
     所有传递依赖它的下游插件必须一并重编重装载——否则下游**不崩、不报错**,只是静默绑在旧代
     (旧 dylib 按设计不 dlclose,仍在内存),两个插件对世界的认知分裂而 UI 上毫无征兆。
     因此新鲜度判断必须沿依赖边传播,不能按插件独立计算。
  5. 写路径(上行信封 `{clientId, plugin, channel, payload}`):`compile-result`(成功/失败+日志,供诊断与 agent 迭代)、
     expose 动作转发、审批应答、`restart-dsh` 请求(转 `appExit`)。多客户端各自带 clientId;**单 active seat**语义后置(M9 只留字段)。
- **不往 session 写任何自定义事件**(§0.5-6)。

#### 5.1.1 M4 实做与本节的偏差(已交付,以此段为准)

- **`ws` 可以直接用**:它是 dsh-client-connection 的依赖,已被
  `healProfilesModuleFallback` 扁平 symlink 进 `~/.dsh/profiles/node_modules/ws`,
  插件从真实路径向上遍历即可命中。写进 `peerDependencies`(同 `@deepseek-ai/*` 纪律),
  不必手写 RFC 6455 握手与分帧。
- **`createSwiftPlugin` 把 `dashBridge` 放进 `inject` 而不是 `ctx.get`**:本计划原文取的是
  "可选依赖姿势",但各插件的 TS 半身除了登记 Swift 载荷之外无事可做,桥缺席时它们
  本就该整体不挂载——这正是 cordis 对 inject 的处理(等着,不报错),已经是优雅缺席。
  `swiftDeps` 会被自动并入 `inject`(编译拓扑序与挂载时序一份声明两层消费)。
- **级联重编不需要专门的传播逻辑**:把上游的 `contentHash` 折进下游的 `contentHash` 即可
  ——"内容没变就不重编"这一条判断自带级联。第 4 点原文说的"登记表版本 bump 必须传播
  到下游"由此在数据结构层面自动成立,壳侧一行传播代码都不用写。
- **`snapshot` 不做增量**(`sinceVersion` 字段未实现):`changed` 只发版本号,壳收到就重新拉
  全量。桥对客户端零状态,全量是几十 KB 的文本,增量的复杂度换不来什么。
- **握手前只放行 `hello` 帧**;升级请求的 Host 头必须是 loopback(自注册路由要自查,见 §1.5)。

### 5.2 Mac 半边(壳内 `BridgeClient`)

`URLSessionWebSocketTask` 连 `ws://127.0.0.1:<port>/dash/bridge`;指数退避重连(复用 EventsBridge 现成实现模式);
连上即拉 snapshot → 交给编译机;收 `changed` → 拉增量;把 subscribe 数据写进对应插件 model(统一 `MainActor.run`);
断连 → registry 不动(UI 保持最后状态),诊断视图亮"桥断开"。

### 5.3 安全(M9 硬化,M4 起先留钩子)

- 编译前对每个插件的 `contentHash` 查审计账本:首次出现/变化 → 记录;**非本仓库路径来源的插件**弹确认(个人开发期,
  `~/.dsh/profiles/plugins/` 仓库内路径进白名单免弹)。账本落 `Application Support/io.wenbo.dash/native-plugins/ledger.json`。
- 桥是提权点的完整论证见对话记录:提交源码=以宿主全部 TCC 身份执行任意代码;白名单收窄 + hash 审计是底线。

### 5.4 桥协议 v1 帧草表(M4 定稿;JSON 文本帧,未知帧一律忽略不崩——与 EventsBridge 同纪律)

| 方向 | 帧 | 字段 | 说明 |
|---|---|---|---|
| ↑ app→dsh | `hello` | `protocolVersion, appVersion, clientId` | 首帧;版本不匹配 → 服务端回 `hello` 后 app 只读降级 |
| ↓ dsh→app | `hello` | `protocolVersion, dshVersion, registryVersion` | 握手应答 |
| ↑ | `snapshot` | `sinceVersion?` | 请求快照(全量或增量) |
| ↓ | `snapshot-result` | `version, plugins:[{name, files:{relPath:utf8}, swiftDeps, contentHash, schemaVersion}]` | **按拓扑序排列** |
| ↓ | `changed` | `version` | 登记表失效信号,只发版本不发载荷 |
| ↑ | `compile-result` | `plugin, contentHash, ok, log` | 编译回执(诊断 + agent 迭代反馈) |
| ↓ | `push` | `plugin, channel, payload` | TS 半身 subscribe 数据下行 |
| ↑ | `invoke` | `plugin, action, payload` | Swift 侧触发 expose 动作 |
| ↑ | `restart-dsh` | — | 转宿主 `appExit`(§3-1) |
| ↓ | `app-build` | `status, log?` | dash-app v1 的壳构建进度(M8) |

审批帧(M9)与 seat 字段后置;`files` 用 utf8 文本(Swift 源码),暂不需要二进制通道。

---

## 6. 编译机(壳内 CompilerService / Loader / 世代管理)

### 6.1 swiftc 命令形状(M2 spike 定稿,此处为出发点)

```bash
xcrun swiftc \
  swift/*.swift(递归收集,插件内文件无序,一次原子编译) \
  -module-name DashSidebar_g42 \
  -emit-library -o .../DashSidebar/<hash>/libDashSidebar_g42.dylib \
  -emit-module -emit-module-path .../DashSidebar/<hash>/DashSidebar_g42.swiftmodule \
  -I <AppBundle>/.../DashSDK/ \
  -I .../DashLayout/<depHash>/ -L 同 -lDashLayout_g17 \
  -module-alias DashLayout=DashLayout_g17 \      # 源码写 import DashLayout,世代对作者透明
  -target arm64-apple-macosXX -Onone -g
```

- 插件间顺序 = Cordis inject 拓扑序(桥已排好);插件内无序。
- 加载:`dlopen(path, RTLD_NOW | RTLD_LOCAL)` → `dlsym(image, "dash_plugin_entry")` → activate。
  **`RTLD_LOCAL` + 按 image handle 取符号是必需的**——每个插件都导出同名 entry。
- **拓扑序不是 dlopen 的要求**(M2 实测):`install_name = @rpath/lib<M>.dylib` + 消费者带
  `-rpath`,dyld 会自动把依赖带起来(只 dlopen 下游、完全不碰上游也能跑)。拓扑序真正约束的是
  **编译顺序**与 **activate 顺序**。
- 依赖 dylib 定位方案已定稿(同上),不需要 install_name_tool 后处理。

### 6.2 内容寻址缓存与产物布局

```
~/Library/Application Support/io.wenbo.dash/
├── endpoint.json                          # dash-bridge 写的发现文件(§3-2)
└── native-plugins/
    ├── generations/<Plugin>/<contentHash>/   # dylib + swiftmodule + build.log
    └── ledger.json                            # 世代账本:装载历史、退休 image 计数、hash 审计
```

`contentHash = H(源文件集 + 各依赖插件的 contentHash + DashSDK 版本 + swiftc --version)`。
命中即跳过编译直接 dlopen(重启/重连后秒载,这也是启动门控能"等编译"的前提)。

**M4 实做补充**:前半段(源文件集 + 依赖 hash)由桥算,后半段(工具链指纹 = swiftc 版本
+ bundle 内 `.swiftinterface` 的内容摘要 + ABI 版本)由壳算并折进去——换 Xcode 或重编 DashSDK
之后必须全量重编,否则 `.swiftmodule` 会对不上。

**module 名直接取自 contentHash**:`DashSidebar_h<hash 前 12 位>`。于是
"内容寻址缓存"与"世代类型隔离"变成同一个事实的两面——内容一样就是同一个 module
(缓存命中且不必重新装载),内容一变就是新 module(与旧代天然隔离)。
省掉了单调计数器和随之而来的"缓存命中时旧世代号是多少"的账。
`-module-alias DashLayout=DashLayout_h<上游 hash>` 让插件作者只写 `import DashLayout`。
目标三元组从 `DashSDK.swiftinterface` 的 `// swift-module-flags:` 行抄,
而不是写死常量(写死迟早与 build-modules.sh 漂移)。

### 6.3 世代替换时序

1. 新 dylib dlopen 成功、entry 返回 → 壳吊销旧世代的 EventBus 订阅 → registry 各槽重指向新工厂 + 版本 bump。
2. layout 对每个槽视图挂 `.id(version)`:版本跳变 → SwiftUI 整棵重建(`@State` 归零,由 `store`/TS 半身 rehydrate)。
3. 旧 dylib **不 dlclose**(对 Swift 不安全):代码页与类型元数据泄漏式退休,实例由 ARC 正常释放。
4. WKWebView 等重资源在 `objects` 保管箱(系统类型,跨代直通),新世代 makeNSView 返回同一实例,页面不重载。

### 6.4 世代账本与回收

双阈值提醒:退休 image 数 > ~150 **或** RSS 相对启动增量超限 → 空闲(无编译任务且用户无操作)时静默自重启
(`open -n` 自己 + terminate;Swift 侧本就只有装饰状态,代价≈0),失败才弹窗。内容寻址已把"重连全量重编"的世代膨胀消掉。

### 6.5 M2 spike 必须验证的断言清单(逐条打勾进 `docs/native-abi.md`,不许抽象带过)

1. `swiftc -emit-library` 编含 SwiftUI View + `@Observable` model 的模块 → 宿主 `dlopen` +
   `dlsym("dash_plugin_entry")` → AnyView 进 NSHostingView 正常渲染、可交互(Observation 宏
   在命令行 swiftc 下可用,确认无需额外 flag)。
2. 入口内存管理约定成立:`Unmanaged.passRetained` / `takeRetainedValue` 往返无泄漏、无过释放。
3. 世代替换:同一源码以 `_g2` module 名再编再 dlopen → registry 换指向 + `.id(version)` →
   新视图上屏、旧实例 `deinit` 确被调用(ARC 回收验证)、进程不崩。
4. 两代类型隔离的失败形态:旧代对象 `as?` 新代同名协议返回 nil(而非崩溃)。
5. SDK 词汇跨代:经壳内 protocol existential 传递的引用,新旧两代都能安全调用。
6. `.swiftmodule` 跨插件 import:B `import A`(`-I` + `-L -lA_gX` + `-module-alias`)可编译可运行;
   **A 换代后旧 B 不重编直接跑**,记录实际失败形态(cast 失败/崩溃)——以此确认桥必须强制级联重编。
7. dylib 依赖定位:先 dlopen A 再 dlopen B 是否即可满足符号解析,不行则定 install_name/rpath 方案。
8. `-enable-library-evolution` 的 DashSDK `.swiftinterface` 能被插件从 app bundle 路径 import。
9. WKWebView 实例跨代/跨挂载:dismantle 后重新 makeNSView 返回同一实例 → 页面不重载、JS 状态在。
10. 编译耗时基线:单文件 hello 与 DSHSidebarUI 体量(~420 行)各自的 swiftc 秒数 → 校准门控预算(§7.1)。

---

## 7. 功能插件设计

### 7.1 dash-layout

- Swift 载荷:向 registry 注册 `root`:`HSplitView { if let sidebar = registry.view(for:"sidebar") {...} ; WebPane }`;
  定义并导出 `public protocol DashSidebarProvider`(接口住消费者侧,1×N 规则);注册 `conversationSurface`
  (现 `WebViewConversationSurface` 逻辑迁入:`evaluateJavaScript("__dash.selectSession(...)")`)。
- **WebView 归属**:WKWebView 实例由**壳**创建并放保管箱——layout 只借用排版。
  理由:layout 插件全灭时壳的 fallback(全出血网页模式)仍需同一实例,页面不重载;插件热替换也不打断页面。
- TS 半身:`createSwiftPlugin` + `ctx.provide('dash-layout')` 标记服务;桥转发页内桥上行
  (`ready/currentSession`——由 dash-web-adapter 的 client 半边 postMessage,壳收到转 EventBus)。
- 窗口收窄自动折叠(未提交新功能):随布局迁入 layout 插件(它现在拥有分栏);壳里对应代码删除。
- 门控与启动时序(壳与 layout 协作;反转后 app 被拉起时 dsh 必然已活,时序更短):
  t0 窗口 + boot 视图(桥连接/编译进度/诊断) → **立即后台预热 WebView**(endpoint 已知) →
  snapshot 全部编译完成 **或** 超时(冷启动预算 **10s**——M2 实测 408 行 SwiftUI 插件
  编译仅 1.03s,四插件全量 3–5s;原 60s 的估计高了一个数量级)/失败 → root 槽切换
  (有 layout=原生布局;无=fallback 全网页)。缓存命中的热启动此门控近乎零等待。

#### 7.1.1 M5 实做与本节的偏差(已交付,以此段为准)

- **root 槽的载荷是 `NSViewControllerRepresentable` 包着的 `NSSplitViewController`**,不是
  SwiftUI `HSplitView`。材质(macOS 26 的 Liquid Glass)、分隔条、拖拽调宽、双击复位、
  宽度 autosave、收起动画、工具栏里跟随 divider 的 `NSTrackingSeparatorToolbarItem`
  ——这些全是 `NSSplitViewItem(sidebarWithViewController:)` 白送的,用 SwiftUI 重画一遍
  只会得到一个更差的仿制品。于是 root 槽的形状是"AppKit 包在 SwiftUI 里包在 AppKit 里",
  丑但值。**注意别覆写 `loadView()`**(踩过:默认实现会把 splitView 装成 view,
  换成空 `NSView` 窗口直接全白)。
- **工具栏归 layout**,不是 §8 写的"留壳"。理由很简单:`NSTrackingSeparatorToolbarItem`
  要 splitView,而 splitView 现在归 layout。壳只留菜单;⌘, 改为经 EventBus 广播
  `dash.menu.command`,layout 收到再调会话展示面——壳喊话,有能力的插件干活。
- **`NSHostingController.sizingOptions = []`**:默认含 `.preferredContentSize`,
  槽内插件每换一代重建视图时都会把分栏拉成 SwiftUI 内容的 fitting 宽度,
  用户调好的宽度就没了。
- **门控没做超时状态机**。原设计是"等编译完成或 10s 超时再切 root 槽";实做发现不需要
  ——壳的 root 槽本来就是"没人占就画全出血 WebView",编译那 1~3 秒里用户看到的就是
  fallback,切换是无缝的。再加一层超时状态机只是多一个会出错的东西。
- **`navigationDelegate`/`uiDelegate` 留在壳里**(WKWebView 归壳所有),
  §10-R5 说的"新世代 activate 时必须重设 delegate"因此不存在——插件从头到尾不碰 delegate。
- **网页侧边栏的显隐门控**:壳按 `UserDefaults` 里记的"上次有没有原生侧边栏"决定
  首次加载要不要带 `?dash-native-sidebar=1`(页面必须在插件编译完之前就开始预热,
  那时还不知道 sidebar 槽会不会被占),插件稳定后核对一次,不符就更新记忆并重载页面。
  稳态下不会有多余的重载。

### 7.2 dash-sidebar

- Swift 载荷:`Packages/DSHSidebarUI` 四个文件基本原样迁入 `dash-sidebar/swift/`,改为
  `import DashLayout` 实现 `DashSidebarProvider`;`AppSidebarModel` 一并迁入(它是 view-model)。
- **数据面(分两步,降低单里程碑变量数)**:
  - M6(本阶段):保留 DSHKit——壳构造 `SessionStore`(现成、已验证,baseURL 来自 endpoint)放进保管箱;
    sidebar 从保管箱取(DSHKit 类型属"壳/SDK 侧定义",跨代安全)。DSHKit 包暂留 `dash-app/host/Packages/`。
  - M10(后续可选):数据面迁 TS 半身(宿主服务 `sessions.list()`/`sessionProjections`/`workspaceRegistry` +
    `session/*` 事件,经桥推送),DSHKit 镜像退役。收益是架构一致与 iOS 远程线地基;风险是内部服务 preview 稳定性。
- 动作面:`activate` → layout 的 `conversationSurface`(registry 取);`archive` → 现 DSHKit
  `workspace.archiveSession`;新建 → `conversationSurface.startSession`。选中真相在 harness 侧,
  页内 `currentSession` 上报回流高亮(现有机制不变);store 只存滚动/展开 hint。
- 显隐联动:sidebar 插件在场 ↔ 网页侧边栏隐藏。机制沿用 URL 参数(壳拼 `?dash-native-sidebar=1`);
  第一版接受"切换需重载页面";后续给 `__dash` 桥加 `setNativeSidebar(bool)` 免重载(改 dash-web-adapter client 半边)。

#### 7.2.1 M6 实做与本节的偏差(已交付,以此段为准)

- **数据面比本节的 M6 方案更进一步:`SessionStore` 由插件自己创建**,而不是壳构造后
  放进保管箱。M3 已把 DSHKit 升成随 bundle 分发的共享 module,它的类型身份跨世代稳定,
  所以插件把 store 存进保管箱、下一代再取出来转型照样成立——热替换时列表不闪、
  WS 事件流不断,而壳保持 0 行业务代码(比原方案更符合 §0.5-2)。端点变了就丢旧重建
  (base URL 也记在箱里供比对)。
- **`#if DEBUG` 在插件里永远不成立**:插件由壳在运行时编译,命令行里没有 `-DDEBUG`。
  侧边栏底部那条 DEV BUILD 改看壳的 bundle id 后缀(`io.wenbo.dash.dev`)。
  这是所有"从壳迁进插件"的代码都要过的一道坎。
- **选中高亮活过热替换**靠 `host.store`(DashStore)存 `selectedSessionId`;
  它只是"页面把 currentSession 报回来之前先亮哪一行"的装饰状态,丢了不心疼(§0.5-1)。
- `ConversationSurface` 协议换成 dash-layout 导出的 `DashConversationSurface`;
  `Packages/DSHSidebarUI` 整包删除(本计划原写 M8 删,既然内容全迁走了就没必要留)。
- **级联重编实测成立**:只改 dash-layout 一行,dash-sidebar 也跟着重编换代
  (g3→g5),不需要任何额外机制——上游 hash 折进下游 hash 就够了(§5.1.1)。
- **SDK 里唯一一处 `@MainActor` 是 `DashPlugin.activate`**,M6 才补上:插件要碰
  `@MainActor` 的 `SessionStore` 与 AppKit,不标就得到处写 `assumeIsolated`。
  类本身不能标——`dash_plugin_entry` 是 nonisolated 的 C 入口,构造不了隔离类型。

### 7.3 ~~dash-notifications~~ —— 已放弃(2026-08-25)

**决策**:通知这条线整体丢掉,不迁移、不重写。现有 `EventsBridge.swift`(235 行,两条
WS + 四类通知 + 去重/冷却)连同 `AppDelegate` 的授权请求、Info.plist 的
`NSUserNotificationUsageDescription` 一并删除。

理由:现有实现本身就不好用(冷却与去重是拍脑袋的常数、前台过滤过于粗糙、
app 未运行时静默丢失),迁一份不好用的东西过去只是把债换个地方存。
需要通知的时候从需求重新设计,那时插件流水线(M4~M6 已验证)现成可用,
写一个新的 `dash-notifications` 比改造这份遗产便宜。

留给将来的两条事实,免得重新调研:

- 事件源在 `/api/events.mux` 与 `/api/events.host` 两条 **WebSocket**(普通 GET 收 426;
  纯下行,客户端发消息会被 1008 "downlink only" 关掉)。帧型:`approval/requested`、
  `question/requested`、`session/event`(mux);`host/agent-error`、`host/session-status`(host)。
  重写时更该走 TS 半身直接 `ctx.on(...)` 订宿主事件,而不是再去解 Web API 的帧。
- **app 未运行时的通知**是启动反转后才有的新可能(dsh 活着、app 关了):TS 半身可经
  `terminal-notifier`/AppleScript 兜底。这是新设计该先回答的问题。

删除的代码在 git 历史里(`d4a1614` 及之前),需要时可捞。

### 7.4 dash-web-adapter

M0 搬家改名(§2.4 常量同步),功能不动。它保持独立插件(纯 client 半边,无 Swift 载荷);
`ready/currentSession/debug` 上行与 CSS 治理照旧。后续(M10+)可考虑并入 dash-layout 家族,本阶段不动。

### 7.5 dash-app(壳源码与编译过程的插件化)

启动反转的直接推论:dsh 既然先于 app 存在,它就是壳天然的 bootstrapper——壳的源码、构建、
拉起全部收进一个插件,不需要额外引导程序,仓库里也不存在非插件的特权目录。壳的 Xcode 工程
就是本插件的载荷(`dash-app/host/`),如同 `swift/` 之于 dash-sidebar;本插件 provide
`dashApp = {appPath, freshness}`,并负责拉起(§3-3)。

- **v0(M1)**:构建+拉起——产物缺失或源码 hash 变化时跑 `xcodegen + xcodebuild
  -derivedDataPath build`(沿用 CLAUDE.md 硬约束;构建日志落 dsh 终端),然后按 §3-3 拉起。
  用户体验:add 插件 → `dsh web` → 首次构建(分钟级)→ app 弹出;源码没变则秒起。
- **v1(M8)**:运行中自动重建——statSync 轮询 `host/` 源码 hash(与桥盯 `swift/` 同款),
  变化时后台重建,经桥通知诊断视图"壳有新版,重启生效"(dev 模式可配自动退出重拉);
  构建日志经桥 `compile-result` 通道回显。至此 agent 的自我迭代覆盖面从插件延伸到壳本身。
- **降级**:无完整 Xcode(xcodebuild 需要 Xcode,CLT 不够)→ 只探测既有产物
  (`/Applications/dash.app`、上次构建);再无 → 终端提示、优雅缺席(dsh 照常服务浏览器)。
- **边界要诚实**:壳重建-重启是"重循环"(进程退出、WebView 页面状态丢失、分钟级),与 Swift
  插件热替换(秒级、不重启)是两个档位;v1 默认"构建好 + 提示",不激进自动重启。运行中的
  app bundle 被覆盖在 macOS 上安全(旧进程继续跑旧映像),重启时机归用户/配置。
- **v2(远期,M10+)**:编译期贡献接口(`dashAppBuild` 登记表:widget extension 等 target
  由其他插件注入工程)——"编译期插件维度"的完整形态,本阶段不做。

---

## 8. 壳(dash-app/host)终态清单

| 保留(客户端残留) | 迁出 | 删除 |
|---|---|---|
| AppDelegate、窗口 + root 槽、boot/诊断视图(BootstrapVC 扩建:桥状态/编译进度/账本/引导页) | 布局/分栏/侧边栏装配(→ dash-layout) | **HarnessProcess/HarnessManager/NodeResolver/Semver**(启动反转,§3) |
| endpoint 定位(flag/发现文件)、BridgeClient | SidebarView 等全部(→ dash-sidebar) | 死代码:`dsharnessSidebar` 分支、DOM DIAG 探针(双侧) |
| Registry/保管箱/PluginStore/EventBus/CompilerService/Loader/账本(新增) | —— | `EventsBridge.swift`(✅ 已删,通知线整体放弃,§7.3) |
| 菜单骨架(⌘R/⌘⇧R 改语义/编辑组)、工具栏(动作改经 registry) | `WebViewConversationSurface`(→ layout) | `SettingsWindowController`(Node/更新项皆失效;视余量删或缩为壳偏好) |
| 终极逃生舱:全出血 WebView fallback、WKWebView 实例创建 | 窗口收窄自动折叠(→ dash-layout) | `AppSidebarModel`(随 sidebar 迁走) |
| AppInfo/BuildTimestamp/DEV 标记、entitlement/签名、Log | | DSHSidebarUI 包(M8;DSHKit 视 M10 决定) |

定性验收:壳内 0 行侧边栏/布局/进程管理业务代码,也不再有通知代码。壳职责一句话说完:
"定位 dsh、连桥、编译装载插件、给 root 槽兜底"。

---

## 9. 里程碑总表

| # | 内容 | 关键产出 | 验收标准 |
|---|---|---|---|
| M0 | 固化+搬家+改名(§2) | 新仓库根 `~/.dsh/profiles/plugins/`;dash 命名全换;dsh 全局安装 | dev.sh 全流程可跑;终端 `dsh web` 起得来;web-adapter 功能不变;旧 repo 退役 |
| M1 | 启动反转(§3) | ✅ **已完成** 壳退役 spawn 层(-867 行);三级 endpoint 定位;dash-app v0(壳源码入插件,构建+拉起) | ✅ 五条全过:`dsh web` → 构建 → app 自动弹出;已运行则跳过拉起;dsh 未起双击 app → 引导页;dsh 退出 → 断连不崩;dsh 换端口回来 → 自动重接且侧边栏镜像整件重装 |
| M2 | ABI spike(独立 scratch 工程) | ✅ **已完成** `docs/native-abi.md` + `docs/spikes/m2-abi/`(可复跑) | ✅ §6.5 十条断言全通过（runner 14 项检查）,全链跑通,**R1 解除、不走 Plan B**;附带修正:编译比预期快一个数量级(§7.1 预算)、级联重编成硬约束(§5.1) |
| M3 | SDK 骨架(§4) | ✅ **已完成** DashSDK + DSHKit 升为随 bundle 分发的共享 dylib;`dash-bridge/plugin` 工厂 | ✅ registry/objects/store/EventBus/bridge 全部可用;dash-hello 经相对路径 import 工厂成功挂载 |
| M4 | dash-bridge 通信面 + 编译机 + hello 世代循环 | ✅ **已完成** 桥 WS/登记表/snapshot/changed/500ms 轮询;CompilerService/装载器/账本/内容寻址缓存;dash-hello | ✅ 改 hello 源码 → **2.2s** 换代、界面更新不重启;编译失败带文件行号进 dsh 终端、旧代留任、壳不崩;重启缓存命中(0 编译);push/invoke 双向通 |
| M5 | dash-layout 接管 root | ✅ **已完成** layout 插件(396 行 Swift);壳交出分栏/工具栏/自适应折叠;fallback = 全出血 WebView | ✅ 三条全过:移除 dash-layout → 完整网页模式(网页 sidebar 回归、渲染与插件模式一致);装回 → 原生布局;插件换代时**页面无重载**(日志无新的加载完成事件) |
| M6 | dash-sidebar 迁移 | ✅ **已完成** DSHSidebarUI + AppSidebarModel → `dash-sidebar/swift/`(577 行);数据面 SessionStore 进保管箱跨世代复用;显隐联动 | ✅ 功能与迁移前等价(材质/工具栏/tracking separator/宽度记忆/搜索/分组/归档全在);改 SidebarView.swift **1.4s** 热更新且选中高亮与列表都不闪;移除插件 → 优雅回退网页侧边栏 |
| ~~M7~~ | ~~dash-notifications 迁移~~ | 🗑 **已放弃**(2026-08-25):通知线整体丢弃,`EventsBridge.swift` 直接删除,不迁移(§7.3) | —— |
| M8 | 壳收缩收尾 | §8 清单落实;dash-app v1(源码变更自动构建);README/CLAUDE.md 重写;死代码清理 | 职责清单达标;改壳源码 → 自动构建 + 提示重启;全功能回归(启动/新建/切换/归档/设置/逃生舱/引导页) |
| M9 | 治理硬化 | 审批+hash 审计;账本阈值+空闲自重启;协议 clientId/seat 字段 | 外来插件首编弹确认;账本可查;阈值触发自重启验证 |
| M10+ | 后续(不阻塞收官) | sidebar 数据面迁 TS 半身、DSHKit 退役;`setNativeSidebar` 免重载;dash-app v2(编译期贡献接口,§7.5);launchd 化 dsh;iOS 远程线(复用桥协议) | 各自独立验收 |

顺序:M0 → M1 → M2 → M3 → M4 → M5 → M6 → ~~M7~~ → M8 → M9;
M2 是唯一的"证伪点"(可与 M1 并行),其余为工程量。每个里程碑单独提交(M0 可拆多个)。

**迁移期共存策略**:每个里程碑内,旧路径保留到新路径验收通过后、于同一里程碑内删除;
新旧切换点必须可回退(disable 对应插件即回旧态/fallback 态)。禁止跨里程碑遗留双实现。

## 10. 风险与开放问题

1. ~~**R1 SwiftUI 跨 dylib ABI**~~ **已解除**(2026-08-25 M2 实测,macOS 27.0 / Swift 6.4):
   SwiftUI View + `@Observable` 跨 dylib 渲染、交互、换代、WKWebView 实例跨代复用全部成立,
   §6.5 十条断言无一失败。Plan B(SDUI 降级)不启用。**再次出现风险的触发条件是升级 Xcode/macOS**——
   届时重跑 `docs/spikes/m2-abi/`(一条命令)即可复验。
2. **R2 dsh preview 破坏**:全局安装钉 `0.1.1-rc.2`;桥/TS 半身对内部服务一律 `ctx.get` 防御;
   升级 dsh 前跑冒烟清单(§9-M8 回归表)。注意反转后失去 HarnessManager 的 N-1 目录回滚,
   回滚=`npm i -g` 装回旧版(npm cache 命中,分钟级),可接受。
3. **R3 node 半边无 HMR**:TS 半身改动=重启 dsh。接受(低频);高频的 Swift 迭代由桥自盯文件,不受影响。
   反转后重启 dsh 也会经拉起逻辑"找回"app(app 已在则只重连),体验闭环。
4. ~~**R4 `registerUpgrade` 未实测**~~ **已解除**(M4 实测):`registerUpgrade({path, handler(req, socket, head)})`
   给的是**裸升级**,协议协商归自己;用 `ws` 的 `WebSocketServer({noServer:true}).handleUpgrade`
   即可,壳侧 `URLSessionWebSocketTask` 直连同端口的 `/dash/bridge` 一次成功。
   独立端口的 fallback 未启用(endpoint 文件仍携带 bridgePath,随时可切)。
5. **R5 WKWebView 跨代细节**:navigationDelegate/uiDelegate 是插件对象(weak,旧代释放后自动 nil)——
   新世代 activate 时必须重设;进程池/inspectable 等配置归壳。写进 SDK 纪律。
6. **R6 搬家断裂**:profile 布线校验(`dsh plugin list`);留一次性回滚指引(mv 回原路径 + 恢复 link)。
7. ~~**R7 编译时延**~~ **不成立**(M2 实测):真实 DSHSidebarUI 体量(408 行 SwiftUI)编译 1.03s,
   四插件全量冷编译 3–5s。boot 视图的 per-plugin 进度仍值得做(诊断价值),但它不再是可用性前提;
   并行编译优先级进一步下调。内容寻址缓存(§6.2)的价值转为"重连不重编",非启动可用性依赖。
8. ~~**R8 事件名/服务名假设**~~ 大部分随 §7.3 放弃而消失;§1.6 服务语义仍以源码复核为准。
9. **R9 会话日志污染**:重申 §0.5-6——桥与插件永不 append 自定义 session event(0.1.1-rc.2 硬坑)。
10. **R10 反转后的运维语义**:dsh 生命周期归用户终端(退出=app 变引导页);⌘⇧R 依赖外层重启机制;
    多 profile/多 dsh 实例时 endpoint 文件的归属(v1 假设单实例,文件带 pid/profile 供校验);
    (通知相关的运维问题随 §7.3 放弃而不再存在)。launchd 化是这些问题的统一解,列 M10+。

## 11. 现存代码资产去向速查

| 资产 | 行数 | 去向 |
|---|---|---|
| MainWindowController.swift | 882→799→**665** | M1 换成"三级定位+2s 健康轮询";M5 交出布局:分栏/侧边栏装配/工具栏/自适应折叠全部移入 dash-layout,壳只剩窗口 + 菜单 + 连接状态机 + root 槽挂载 + 页内桥转 EventBus |
| HarnessProcess/Manager + NodeResolver/Semver/Shell | 711 | ✅ M1 全部退役删除(`Shell` 实测无其它引用面,一并删;`Log` 保留)。新增 `DashPaths`(28)+`DashEndpoint`(105)接手 |
| EventsBridge.swift | 223→235→**0** | M1 把 `init(port:)` 改成 `init(baseURL:)`;WS 重连模式已被 BridgeClient 借鉴。**2026-08-25 整件删除**——通知线放弃,不迁 dash-notifications(§7.3) |
| DSHKit | 686 | ✅ M3 升为随 bundle 分发的**共享 dylib**(壳与插件链同一份);源码仍在 `Packages/DSHKit/`(单元测试还在那儿),但不再是 SwiftPM 依赖。M10 视 TS 数据面进展退役 |
| DSHSidebarUI + AppSidebarModel | 525 | ✅ M6 迁入 `dash-sidebar/swift/`(577 行,近原样;`ConversationSurface`→`DashConversationSurface`,`#if DEBUG`→bundle id 判定),`Packages/DSHSidebarUI` 整包删除 |
| dsharness-web-adapter | 466 | →dash-web-adapter(改名搬家,功能不动) |
| BootstrapViewController | 123→178 | M1 已扩建出 guide 态(标题+说明+可拷贝 `dsh web`+重试);M4/M8 再补桥状态/编译进度/账本 |
| SettingsWindowController | 156 | ✅ M1 整件退役删除(Node 路径/更新频率两项皆随 spawn 层失效,壳已无偏好可设);⌘, 改为经页内桥打开 dsh 自己的设置面板 |
| git 历史 dsh-web-search-firecrawl | — | node 半边写法范本(peerDeps/静态 inject/Config/设置卡),bridge 实现参考 |
| wire-notes.md / phase1 计划 | — | 保留;M8 随 README 一起校正漂移 |

## 12. 执行日志(每完成一个里程碑追加一行:日期、里程碑、commit、偏差与文档更新)

| 日期 | 里程碑 | commit | 备注(与计划的偏差、更新了文档哪节) |
|---|---|---|---|
| 2026-08-25 | M2 | `5361621` | **提前于 M1 执行**(§9 允许并行,且它是唯一证伪点)。§6.5 十条断言全通过,R1 解除。就地更新:§5.1-4(级联重编硬约束)、§6.1(dlopen 不需拓扑序、RTLD_LOCAL 必需)、§7.1(门控预算 60s→10s)、§10(R1 解除/R7 不成立)、§9(M2 行)。产出 `docs/native-abi.md` + 可复跑的 `docs/spikes/m2-abi/`。|
| 2026-08-25 | M0 | `6b20dbb`…`81ed9a4`(6 个) | 按 §2.6 顺序执行，无偏差。补充事实：`dsh plugin --profile web <args>` 直接透传 pnpm（add link:/remove 语法确认）；firecrawl 走 gitignore；旧路径彻底删除不留链接（§2.3 已就地更新）。改名后壳的 Application Support 换成 `io.wenbo.dash/`，壳按既有逻辑自动重装了一份 harness（M1 启动反转后这份即废弃）。|
| 2026-08-25 | M3 | `2dc23d0` | SDK 骨架。就地更新:§4.1.1(五条实做偏差——SDK 必须是独立 dylib、DSHKit 一并升共享 module、DashHost 改 final class、不加 @MainActor、Disposable 带 token 校验)、§4.2(dash-* 互引定案走相对路径)、§9(M3 行)。|
| 2026-08-25 | M4 | `0eddda5` | 桥 + 编译机 + hello 世代循环,五条验收全过:改源码 **2.2s** 换代不重启;编译失败带文件行号进 dsh 终端、旧代留任、壳不崩;重启缓存命中 0 编译;push/invoke 双向通;**R4 解除**(`registerUpgrade` 是裸升级,用 `ws` 的 noServer 模式,`ws` 已在 profiles/node_modules 里)。就地更新:§5.1.1(四条偏差)、§6.2(module 名取自 contentHash,世代隔离与内容寻址合一)、§9(M4 行)、§10-R4。|
| 2026-08-25 | M5 | `de995de` | dash-layout 接管 root。就地更新:§7.1.1(六条偏差——root 槽用 AppKit NSSplitViewController、工具栏归 layout、sizingOptions=[]、门控不做超时状态机、delegate 留壳因而 R5 不存在、网页侧边栏门控靠 UserDefaults 记忆 + 稳定后核对)、§9(M5 行)、§11。踩坑:覆写 `NSSplitViewController.loadView()` 会让窗口全白。|
| 2026-08-25 | M6 | `d4a1614` | dash-sidebar 迁移,壳内 0 行侧边栏代码。就地更新:§7.2.1(六条偏差——SessionStore 归插件且跨世代复用、`#if DEBUG` 在插件里不成立、选中高亮走 DashStore、协议换 DashConversationSurface、级联重编实测成立、SDK 补 `DashPlugin.activate` 的 @MainActor)、§9(M6 行)、§11(DSHKit/DSHSidebarUI 两行)。|
| 2026-08-25 | ~~M7~~ 放弃 | (本次) | **通知线整体丢弃**(用户决策):`EventsBridge.swift` 235 行 + `AppDelegate` 授权请求 + Info.plist `NSUserNotificationUsageDescription` 全部删除,壳不再 import UserNotifications。就地更新:§7.3(改写成"已放弃",留下事件源与"app 未运行"两条事实备将来重做)、§0(概述/目录树/插件树/非目标)、§1.6、§8、§9(M7 行划掉 + M8 回归清单去掉"通知")、§10(R8/R10)、§11。下一个里程碑改为 M8。|
| 2026-08-25 | M1 | `94471c2` | 启动反转交付。壳 -867 行(spawn 层四文件 + Shell + SettingsWindowController),新增 `DashPaths`/`DashEndpoint`/`dash-app` 插件。就地更新:§1.7(logger 无 exporter、`dsh web` 另开浏览器两条新事实,并修掉"PATH 上没有 dsh"这条过时项)、§3.1(实做偏差九条)、§9(M1 行)、§11(五行资产去向)。**未实测**:无 Xcode 的降级路径。|
