# 壳与插件的运行时架构

这篇讲 **surf 在一台机器上跑起来之后，进程里到底是什么形状**：谁先启动、
壳负责哪几件事、插件靠什么机制上屏、热替换为什么成立、哪里坏了会怎么坏。
写给要动壳源码或要新增一层机制的**本仓库维护者**。

只想写一个插件的人不必读它——[`../extend/plugin-author-guide.md`](../extend/plugin-author-guide.md)
加 [`../extend/contracts.md`](../extend/contracts.md) 就够，那两份是"用户手册"，
这份是"它为什么长这样"。

---

## 1. 启动方向是反的

常见做法是"原生 App 起来，再去拉一个后端"。这里正好相反：

```
dsh web 起来
  └─ 加载插件树
       └─ surf-app（一个普通的 cordis 插件）
            ├─ 写 endpoint 发现文件
            ├─ 需要时构建壳
            └─ open Surf.app --surf-endpoint <本次的地址>
                 └─ App 连回这个 dsh，拉 snapshot，编译并装载各插件的 Swift 载荷
```

**App 是 dsh 的客户端外设，不是宿主。** 这一条不是风格选择，它换来两样东西：

- **壳源码不是特权目录。** 它只是 `surf-app` 这个插件的一份载荷（`surf-app/host/`），
  与 `surf-sidebar/swift/` 之于 surf-sidebar 是同一种关系。仓库里因此没有
  "主工程 + 一堆附属包"的层级，只有一排平级的 cordis 插件。
- **壳有一个天然的 bootstrapper。** 构建、拉起、"有新版了"的播报都归 dsh 侧那半边，
  壳自己不必长出自更新机制。

代价是壳必须能独立活着——用户 ⌘Q 之后 dsh 不会再拉起它，双击是唯一的回来路径，
而双击没有 flag。所以壳自己也要会找 dsh（endpoint 发现文件、连接偏好），
甚至会自己托管一个（`Native/BackendManager.swift`）。

**上面画的是仓库开发形态。装好的正式形态方向是反的**：双击 App，它自己 spawn 一个
后端（连接偏好缺省 `managed`），打开即有、⌘Q 即退。两种形态下 App 都只是客户端，
差别只在"这一次是谁先起、谁把地址递给谁"——收口在
[`connection.md`](connection.md)。

---

## 2. 壳只做五件事

1. **定位 dsh**（`managed` 偏好下还负责把它拉起来）
2. **连桥**（`/surf/bridge` 那条 WebSocket）
3. **编译并装载插件**
4. **给 `root` 槽兜底**（没人占就是一整扇 WebView）
5. **替插件占住那些必须在启动期就位的系统 delegate**

**壳里没有任何业务 UI，也没有任何业务命令的词汇。** 后半句是可以验的：
菜单项由插件的 node 半边用 `commands` 声明，经桥 snapshot 到壳
（形状见 `surf-bridge/lib/plugin.js` 的 `CommandDeclaration`）；
`MainWindowController.setupMenus()` 因此拆成**系统惯例段**（⌘W/⌘Q/编辑菜单/⌘R/
缩放/⌥⌘D/⌘/，硬编码）与**贡献遍历段**（照着 snapshot 摆）。按下去只
`emit(menuCommand, ["command": id, …])`，命令名挂在 `NSMenuItem.representedObject` 上
——壳编译期一个 id 都不认得，插件缺席时那条菜单项**根本不出现**，而不是灰着。

一份声明喂四样东西：菜单项、默认键位、⌘/ 面板、以及 surf-app 现拼出来的
`surf-shortcuts` 设置 schema。从前这四样在壳里各硬编码一份，分家了不报错。

---

## 3. `surf-app/host/Sources/` 的分工

| 目录 / 文件 | 是什么 |
|---|---|
| `SurfSDK/` | **壳 ↔ 插件的 ABI 词汇**。编成一个 dylib 随 bundle 分发，壳与所有插件链接同一份 |
| `Native/` | 壳的机器房：连接、桥、编译机、装载器、Web 策略、系统 delegate 中转 |
| `MainWindowController.swift` | 窗口、菜单、页内桥转 EventBus、壳自身构建的提示条 |
| `AppDelegate.swift` | 启动期占位（`SystemDelegateRelay.install()`）、持有托管后端、⌘Q 收尾 |
| `ConnectionViewController.swift` | 没连上时铺满窗口的连接页（SwiftUI 覆盖层） |
| `DiagnosticsPanel.swift` | ⌥⌘D：端点、桥、插件世代、module 名、退休 image 数 |

`Native/` 里值得单独点名的几个：

- **`ConnectionController.swift`** —— "我此刻连着谁"的**唯一真相**：一台显式状态机，
  六幕（searching / connecting / connected / disconnected / unreachable / idle）
  加一张失败分类表。`MainWindowController` 只是它的消费者，接三个回调
  （装页面+连桥 / 停桥 / 盖或撤连接页）。这个位置从前散在四个布尔与三条互不知情的
  时间线里，收成状态机之后"该不该盖连接页"才有单一判据。完整一篇在
  [`connection.md`](connection.md)。
- **`BridgeClient.swift`** —— 一条 WebSocket，JSON 文本帧，**未知帧一律忽略不崩**
  （协议向前兼容）。断线指数退避重连；重连即重新拉全量 snapshot——桥对客户端零状态，
  所以"重连 = 重新握手 + 重新拉全量"永远安全。
- **`CompilerService.swift`** —— 内容寻址编译，见 §7。
- **`NativePluginHost.swift`** —— 桥 ↔ 编译机 ↔ 装载器 ↔ registry 的接线板。
  壳对插件世界的全部认知都在这里。
- **`ShellRootView.swift`** —— 壳挂在窗口上的那一个 SwiftUI 根，见 §8。
- **`WebPolicy.swift`** —— WKWebView 的导航策略与下载。**它归壳不归插件**，
  因为下载与外链是"逃生舱也得有"的能力：surf-layout 缺席、整窗网页兜底时，
  会话导出 ZIP 照样要能落地。这里还有一条安全边界——页面里的链接大半是模型生成的，
  等同不可信输入，所以 scheme 走白名单、下载目录固定且不采信页面给的路径分量。
- **`SystemDelegateRelay.swift`** —— 见 §6。

---

## 4. 两种槽

SDK 里有两张注册表，**基数不同，别混**。

### 4.1 `SurfRegistry`：单占用的"替换槽"

一槽一主，后来者覆盖前者。适合 `root`、`sidebar` 这种独占表面——两个插件同时画
侧边栏是没有意义的。撤销语义是"**如果还是我**就摘掉"（`Entry` 里那个 token 就为此存在），
所以旧世代析构时不会顺手删掉新世代刚装好的注册。

**只放拓扑，不放流量**：槽占用、世代号、视图工厂。registry 是 `@Observable`，
每次变动都会驱动整棵 SwiftUI 重建，把高频业务数据放进来等于每帧重建。
业务数据住各插件自己的 model。

### 4.2 `SurfContributions`：多占用的"贡献槽"

一槽 N 条，各家追加互不影响，`(owner, id)` 是身份。适合工具栏按钮、状态栏指示器
这种"谁都可以来一条"的表面。撤销语义是"只摘我这一条"。同 `order` 时按首次注册序号
稳定排列，而且**换代保留旧序号**——热替换不会让按钮跳位置。

两者没有合并成"给 registry 加个数组"，正是因为撤销语义与观察粒度都不一样；
混进一个类型，两边的 API 都会变成要看注释才敢用。

### 4.3 贡献槽只收容器，不收词汇

SDK **不定义** `ToolbarItemSpec` 之类的具体 UI 类型。那会把"工具栏长什么样"冻进
ABI，而壳是预编译产物、第三方改不了它。贡献的载荷因此只有两样东西：一个视图工厂，
一份 `metadata: [String: Any]`（约定只放 JSON 能表达的值）。

**键名由占槽的消费方定义并写在自己家里。** `toolbar` 槽的权威是
`surf-layout/swift/LayoutContracts.swift` 的 `ToolbarSpec`——有类型的属性加一个
`metadata()`，贡献方按名字引用、拼错就编不过；消费方那侧仍然读字典，SDK 保持中立。
汇总索引在 [`../extend/contracts.md`](../extend/contracts.md) §2，**权威始终在代码里**。

同一条纪律贯穿三张表：槽名、事件主题名、hook 名全是插件之间的字符串约定，
SDK 一个具体名字都不认得。

---

## 5. 事件总线与 `emitSticky`

`SurfEventBus` 是进程内广播，载荷 `[String: Any]`，约定只放 JSON 能表达的值
——放引用类型等于让引用过桥，换代后另一头拿到的是新 module 认不出来的旧类型。

关键的一条是**粘性**：

> 插件是运行时编译装载的，**它必然晚于壳的启动，也可能晚于页面第一次报告状态**。

纯广播的语义下，晚到的订阅者对"当前是什么状态"一无所知，还要等下一次变化才知道
——而那个状态可能不再变（用户打开 App 之后一直待在同一个会话里），于是它永远不知道。
这不是某一条消息的毛病，是"广播 + 晚到的订阅者"这个组合的固有缺口。

所以：**描述状态的消息用 `emitSticky`（当前会话、当前端点、窗口标题、主题投影），
描述瞬间的消息用 `emit`（菜单被按了一下）。** 判据在 emit 的一方，
总线本身不认识任何具体主题。

推论：**新写这类消息不要再配"请求当前值"的 request 通道**——那是同一个缺口的
另一种补法，两条通道并存就是两处真相。

---

## 6. `SurfHooks`：应答式钩子表

事件总线是广播 + 无返回值 + 谁在听谁听。有三类需求它表达不了：

1. **要答复**——系统 delegate 的方法往往要同步返回一个值。
2. **一槽一主**——delegate 的语义是"唯一负责人"，不是"所有听众"。
3. **早鸟事件**——回调可能在插件装载之前就到达（冷启动那几秒里 dylib 还没编完）。
   广播出去没人听就是丢了；这里留着等人认领（有界，满了丢最老的）。

**为什么这件事非壳不可**：若干系统 delegate 只认
`applicationDidFinishLaunching` 之前装上的那个对象，晚设无效——读回来与自己一致，
回调就是不进。而插件是运行时 `dlopen` 出来的，最快也要在启动后几秒才存在。
**运行时装载的插件永远不可能自己占这些位子**，必须有一个转交点。

那个转交点是 `Native/SystemDelegateRelay.swift`：壳在启动第一句占位，
把回调**原样拍平**成字典经 hook 问一遍插件，再把答复翻回系统要的形状。
**壳在这里没有一行语义判断**——这条通知该不该显示、按钮按了要干嘛，壳一概不知道，
它只是个电话总机。§2 的"壳里零业务"因此仍然成立。

**表里一个具体的 hook 名都没有。** 加一个住户（URL scheme、Dock 拖放、Services、
`NSUserActivity` 接力都是同一个形状）= relay 多 conform 一个协议 + 多两行拍平代码，
**SDK 与插件协议一个字不动**。

---

## 7. 共享 module：全进程只有一份 SurfSDK

壳链接 SurfSDK，运行时编出来的每一个插件 dylib 也链接 SurfSDK。**必须是同一份文件**，
类型身份才对得上——否则 `as? SurfPlugin` 会安静地失败。所以它不走 SwiftPM 静态链接进壳，
而是编成 dylib 随 bundle 分发：

```
scripts/build-modules.sh   → host/build-sdk/libSurfSDK.dylib + .swiftmodule + .swiftinterface
scripts/embed-modules.sh   → Contents/Frameworks/libSurfSDK.dylib     ← 壳按 @rpath 加载
                           + Contents/Resources/SurfModules/          ← 插件编译时 -I 的落点
```

两个脚本挂在 `project.yml` 的 pre/postBuildScripts 上，源码没变则秒过。
机制本身是多 module 的（`build_module` 再加一行即可），眼下只剩 SurfSDK 一个住户。
插件只拿到 `.swiftinterface`，这已经足够编译——SDK 编译时带 `-enable-library-evolution`。

**改 SurfSDK 会让所有插件的 contentHash 失效、全量重编。这是有意的。**
编译指纹里含 `SurfSDK.swiftinterface` 的摘要（`CompilerService.toolchainFingerprint`），
所以 SDK 一变，每个插件的 hash 必然跟着变。`.swiftmodule` 对不上比慢几秒糟得多。

顺带一提，这个指纹**不含本机 swiftc 的版本号**，取的是随 bundle 走的那份
`.swiftinterface`。理由有两条：本机版本号会让预编译分发不可能成立（构建机与用户机
必须算出同一个数），而信号并没有丢——换工具链必然重编 SurfSDK、必然改写这份 interface。
**真相取自随 bundle 走的文件，而不是本机环境**，是这一层反复出现的模式。

---

## 8. 热替换与世代

三条硬事实，实测出处是 [`../extend/native-abi.md`](../extend/native-abi.md)，
这里只讲它们如何塑形了架构：

### 8.1 内容寻址：module 名就是 hash

完整 contentHash = 桥算的 hash（源码 + 依赖 + 共享 module 声明）+ 工具链指纹
+ 本插件声明用到的共享 module 的接口摘要。module 名取它的前 12 位：
`SurfSidebar_h9f31c0aa12b4`。

于是**内容寻址缓存与世代类型隔离是同一个事实的两面**：内容一样就是同一个 module
（缓存命中、不重编），内容一变就是新 module（新旧两代同名类型互不认识）。
不需要另一套版本号。

产物按三档顺序取件（`NativePluginHost.init`）：
**用户缓存 → bundle 内预编译（`Resources/SurfPlugins/`）→ 现场 swiftc**。
用户缓存排第一，是为了让"用户自己改了插件源码"那一份赢过随分发走的默认实现。
现场编译因此是**可选能力而不是启动前提**：没有工具链时缺的是这一个插件的原生半边，
不是整个原生侧。

### 8.2 旧 dylib 永不 `dlclose`

对 Swift 不安全（类型元数据仍被引用）。代码页泄漏式退休，实例由 ARC 正常回收，
`GenerationLedger` 记着装载与退休的账，⌥⌘D 读它。

装载走 `dlopen(path, RTLD_NOW | RTLD_LOCAL)` + `dlsym(image, "surf_plugin_entry")`。
**`RTLD_LOCAL` 是必需的**：每个插件都导出同名的入口符号，必须按 image handle 取，
不能走全局查找。

换代时序是：装载 → `activate`（新注册覆盖旧槽）→ 松手放旧代。
**壳持有 `activate` 的返回值 = 本代在役，壳松手 = 本代退休**——它析构时把
activate 期间攒下的注册与订阅一并撤销。这是世代生命周期的唯一抓手。

### 8.3 级联重编由数据结构保证，不靠传播逻辑

上游换代、下游没重编时，下游**不崩不报错**，只是继续调旧代的代码——UI 上毫无征兆的
认知分裂。这比崩溃危险得多。

解法不是在壳里写一段"通知下游"的传播代码，而是**把上游的 contentHash 折进下游的
contentHash**（算法在 `surf-bridge/lib/swift-payload.js` 的 `swiftContentHash`，桥每轮重扫时按拓扑序应用一遍）。于是"内容没变就不重编"
这一条判断自带级联：上游一变，下游的 hash 必然跟着变。壳侧一行传播逻辑都不需要。

---

## 9. 失败姿态

这一层的设计判据始终是**失效方向**——坏掉时应该退化成什么，而不是报什么错。

| 出什么事 | 结果 |
|---|---|
| 某个插件编译失败 | 带文件行号打进 dsh 终端的 stderr，**旧世代继续在役**，界面不变也不崩 |
| 没人占 `root` 槽（surf-layout 缺席 / 被禁用 / 编译失败） | 壳露出**整窗 WebView**——仍是一个能用的 dsh 客户端，只是没有原生外壳 |
| 桥断开 | **registry 不动**，界面保持最后状态；重连后重新拉全量 |
| 插件从登记表消失 | 那一代退休，占的槽跟着空出来，消费方走各自的 fallback |
| 本机没有 Swift 工具链，且 bundle 里也没有预编译产物 | 缺的是那一个插件的原生半边，不是整个原生侧 |
| dsh 整个不在 | 壳盖上连接页；`managed` 偏好下它会自己去拉起一个后端 |

逃生舱那一档还有一个细节：`ShellRootView` 的兜底 WebView 与 surf-layout 借用的
**是同一个实例**（放在 `SurfObjects` 保管箱里），所以在"插件模式 ↔ 逃生舱"之间
来回切换时页面不重载、JS 状态存活。

**逃生舱不是"等超时才降级"的产物，它是第一帧就在的默认值**：`ShellRootView` 每次
求值都问一次 registry，有人占 `root` 就用那份视图，没人占就是整窗 WebView。
换句话说降级路径不需要触发条件，它是插件没上线时的自然形态。

另有一条与之相关的门控：`NativePluginHost.didSettle`（首次 snapshot 处理完毕，
成功失败都算）。它不拦界面，只收口那些"半成品状态不算数"的动作——典型是页面查询
参数：插件一个接一个上线，先上线的那个说的是"此刻"的话而不是"最终"的话，
照着中间态重载的结果是冷启动把网页加载好几遍。

---

## 10. 插件名录

| 插件 | 一句话 |
|---|---|
| `surf-app` | 宿主插件。壳源码是它的载荷：写 endpoint 发现文件、按需构建壳、拉起 App、provide `surfApp` 服务、把 `commands` 拼成 `surf-shortcuts` 设置面 |
| `surf-bridge` | **唯一的特权插件**。Swift 载荷登记表 + `/surf/bridge` WebSocket + 500ms 盯各 `swift/` 目录。`createSwiftPlugin` 工厂也住这儿 |
| `surf-layout` | 占 `root` 槽：分栏、WebView 排版、开出 `sidebar` 槽与 `toolbar` 贡献槽。client 半边装 `window.__surf` 动作桥并收起 web 侧边栏 |
| `surf-sidebar` | 占 `sidebar` 槽：原生会话侧边栏。**数据面在 node 半边**（订宿主服务与事件，投影经桥推 JSON；Swift 只管画和发动作） |
| `surf-notify` | 桌面通知。不占槽、不贡献界面，缺席即无通知。同时是"有什么在等着你"的**唯一真相**，经 `surfPending` 服务供给侧边栏的会话状态（缺席则退回只有「待批准」） |
| `surf-settings` | 原生设置窗口。不占槽、自己一扇窗；数据面在 dsh 进程里直接消费 `ctx.settings` / `llm` / credentials / `agentPresets` / `pluginInventory` |
| `surf-nativeify` | 让 dsh Web UI 摸起来像原生 App。三半边，主力是 client 那段 CSS；薄 Swift 载荷把 dsh 的 `ui-theme` 投给原生侧（`NSAppearance` + 窗口底色） |
| `surf-memory` | 跨会话持久记忆。**纯 node、零 macOS 依赖**——不占槽、不贡献界面、不碰桥，装到任何一台有 dsh 的机器上都跑得动 |

三条模式贯穿这张表：

- **数据面尽量放 node 半边。** 壳与共享 module 随 app bundle 冻结、用户改不了，
  而 dsh 的 wire 模型是演进最快的那一层——层放错了就得靠发新版 App 来跟进。
  surf-sidebar 与 surf-notify 都是这么分的，两者的 dsh 交互也都关在**一个文件**里
  （`lib/dsh-source.js` / `lib/mux-source.js`），dsh 升级后先核对它。
- **不占槽的插件缺席即无损。** notify、settings、memory 都是这样：装上多一样能力，
  不装什么都不缺。
- **谁定义槽，谁写这个槽的词汇。** SDK 只提供容器。

---

## 延伸阅读

- [`../extend/native-abi.md`](../extend/native-abi.md) —— 入口 ABI、编译命令、
  世代替换的断言清单，全部本机实测，spike 可复跑。
- [`../extend/contracts.md`](../extend/contracts.md) —— 跨插件字符串约定的汇总索引。
- [`../extend/plugin-author-guide.md`](../extend/plugin-author-guide.md) —— 三种骨架与
  Swift 半边的硬规矩。
- [`orchestration.md`](orchestration.md) —— 这些包是怎么被装进 dsh 的。
- [`connection.md`](connection.md) —— 壳连着哪个后端：定位顺序、状态机、托管。
- [`dsh-upstream-gaps.md`](dsh-upstream-gaps.md) —— 上游缺口清单。
- [`../spikes/`](../spikes/) —— 可复跑的隔离验证台。
