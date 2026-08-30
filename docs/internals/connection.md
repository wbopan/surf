# 壳连着哪个后端

这份文档写给**本仓库的维护者**：讲"我此刻连着哪个后端"这件事是怎么决定的——
定位顺序、状态机、连接偏好、endpoint 发现文件、托管后端的生命周期。

字段表在 [`../extend/contracts.md` §10](../extend/contracts.md)，这里讲**为什么是这样**。

## 先知道一件事

**App 是后端的客户端外设，不是宿主**，但谁先启动要看形态：

- **装好的正式形态**：双击 App，它自己 spawn 一个后端并盯着它
  （连接偏好缺省就是 `managed`）。
- **仓库开发形态**：后端（`dsh web`）先起，其中的 `clam-app` 插件构建并拉起 App，
  在命令行上把本次的地址亲手递过去。

所以壳从来不能假设"我的后端就在那儿"——它要么被后端亲手拉起（命令行上带着地址），
要么自己去找，要么自己拉起一个。这三条路的收口就是本文的主题。

---

## 1. 唯一真相：`ConnectionController`

**`clam-app/host/Sources/Native/ConnectionController.swift` 是壳里"我此刻连着谁"
的唯一真相**，一个显式状态机。曾经这件事散在 `endpoint` / `bootstrapPhase` /
`isBridgeConnected` / `bridgeReady` 四个变量、三条互不知情的时间线里——
"页面装上了没有"和"桥握上了没有"各自为政，合起来是什么状态没有人说得清。

这个类**只认得端点与状态**，不认得 WebView 也不认得 AppKit。副作用全部经三个回调
交给 `MainWindowController`：

| 回调 | 壳做什么 |
|---|---|
| `onAttach(endpoint)` | 装页面（`webView.load`）+ 连桥 |
| `onDetach()` | 停桥、停加载。**窗口与 WebView 都留着**——后端回来时轮询自动把页面重新载上 |
| `onPhaseChange(phase)` | 盖上/撤掉连接页 |

反方向只有两条：`noteBridge(connected:)` 与 `notePageReady(_:)`，由壳把桥那侧的
事实喂回来。

状态还经粘性主题 `clam.connection.state` 投影给插件（clam-settings 的「连接」栏读它）。
**状态型消息一律 `emitSticky`**：插件必然晚于壳启动，不粘的话它要等到下一次状态
变化才知道此刻连着谁，而那个状态可能一直不变。

---

## 2. 六幕与失败分类

`ConnectionPhase` 六幕：

| 幕 | 含义 | 盖连接页 |
|---|---|---|
| `searching` | 正在扫描 / 探测候选 | 是 |
| `connecting(endpoint)` | 选中候选，装页面 + 桥握手中 | **否** |
| `connected(endpoint)` | 桥 hello 已到 | 否 |
| `disconnected(reason)` | 曾连上，丢了 | 是（断连页） |
| `unreachable(failure)` | 有明确目标却连不上 | 是 |
| `idle` | 没有任何候选 | 是 |

**`connecting` 一到就撤连接页**，不等 `connected`：页面此刻已经在加载了，
再盖一层就是让用户盯着一张"正在连接"看已经连上的东西。

`idle` 与 `unreachable` 的分界是**有没有一个明确目标**（用户手点的 / `fixed` 钉死的）。
有目标而连不上要如实报错；没目标只是"还没找到"，照旧转圈等它出现。

失败分类 `ConnectFailure` 有四档：`refused` / `timeout` / `httpError(code)` /
`bridgeRejected`。**分类不是为了好看**——连接页那一行"原因"、诊断面板每个候选后面
的标注、以及"要不要继续退避重试"三处都读它。**认不出来的错误一律归 `refused`**：
界面上"连接被拒绝"比"未知错误"更接近事实（后端不在那儿）。

**分类发生在探测那一层**：`EndpointLocator.probe` 返回的是 `ConnectFailure?`
（**nil = 健康**），不是 Bool。桥那侧另有一套三分类（`BridgeClient.Failure`：
`handshakeRejected` / `helloTimeout`（5s 看门狗）/ `connectionLost`），
经 `NativePluginHost` 上报给状态机——**只上报，不改桥自己的退避行为**。

`bridgeRejected` 是唯一一条不由 HTTP 探测得出的：HTTP 活着、页面也装得出来，
但那个后端的 profile 里没有任何 clam 插件（典型场景是用户手动连了一个普通的
`dsh web`），桥永远握不上。**连拒三次就判定这个后端不含 Surfclam 组件**，放弃它、
退回引导页。阈值取 3 是给正常启动窗口留余地——后端起桥比起 HTTP 晚一拍是合法的。
不判定的话 App 会停在一个没有任何原生功能的裸页面上，且不报错。

**桥掉了不进断连幕**：HTTP 还活着说明后端在，桥自己会退避重连，幕退回 `connecting`。
断连与否只由健康探测说了算。

---

## 3. 定位顺序

四级，从高到低（`ConnectionController.targetCandidates` 与 `adoptsDiscovered`）：

1. **用户当场点的一次性目标**——连接页上点某个后端的「连接」，或敲完地址回车。
   **不落偏好**，只活到下一次显式动作。
2. **`--clam-endpoint` flag**——由拉起本进程的那个后端亲手递来。
3. **连接偏好 `clam.connection.mode`**（§4）。
4. **endpoint 发现文件**（§5）。
5. 都没有 = 连接页。

**flag 压过偏好**：它不是"本机随便一个端口"，是拉起本进程的那个后端指名道姓
说的"连我"，多 worktree 并存时也只指向"我这一套"。所以 `./dev` 的开发循环完全
不受偏好影响——dev 壳总是带 flag 被拉起。

**但 flag 压不过用户当场点的那一下**：那不是偏好，是一条当场的指令。反过来的话
界面上的「连接」按钮会看上去没反应。

一条相关的纪律：**用户明确放弃过的目标要记住**（断连页的「连接其他后端…」）。
不记的话下一轮轮询会把同一个端点原样接回来，按钮看上去像没反应。任何一次显式
连接都清空这张放弃表——显式动作 = 新的意图，既往不咎。

**手点一个地址不当场装页面**，而是先记成目标、探一轮再说。乐观接入的代价是
敲错一个地址就白装一次页面、再掉进断连页——而它其实从没连上过。

---

## 4. 连接偏好四档

UserDefaults 键 `clam.connection.mode`（域 `io.wenbo.surfclam[.dev]`），
四档 + 一个"未设置"：

| 值 | 语义 |
|---|---|
| *（键不存在）* | 读成 **`managed`**（`ConnectionController.fallbackMode`） |
| `unset` | 发现轮询照跑、列表照显，**但绝不自动接入**。接不接由用户在引导页上点 |
| `auto` | 扫发现文件、并行探测、择优接入 |
| `fixed` | 钉死 `clam.connection.fixedURL` 那一个，连不上如实报错，**不回退 auto** |
| `managed` | auto 的发现逻辑 + `BackendManager` 保证有一个自己的后端在跑（§6） |

**坏值退 `managed`**，不是退 `unset`：认不出来的偏好该退到"起一个自己的"，
而不是"随便接一个"。

`unset` 这一档存在，是因为一台机器上可能同时开着好几个后端，壳不该乱接别人的。
但它**不是首次运行的默认**——后端的生命周期归壳管（§7），不该要用户先在引导页上
点一下。`managed` 与那条纪律不冲突：它接入的是壳**亲手拉起来的**那一个。

`fixed` 模式下发现列表**仍然要探、仍然要显示**，点一下即临时改道:别把用户锁死
在一个死地址上。

改偏好有两个入口，语义不同：

- **引导页的两枚勾选框**（`setMode` / `rememberFixed`）——当场生效。
  「记住这个地址」一次落两个键：只改 `mode` 会钉向上一次的地址。
- **设置窗口第五栏「连接」**（`clam-settings/swift/ConnectionPage.swift`）——
  **只写盘，不当场切**。这一栏说的是"下次打开 App 时"，当场把用户正在用的连接
  换掉不是他按那几个段控的意思。盘上那份与粘性投影里"此刻生效中"的那份并排放着，
  不一致就是"改了还没重启"，那颗「立即重启」按钮据此出现（emit `clam.app.relaunch`，
  壳自我重启）。

设置窗口那一栏**不直接调 `ConnectionController`**：clam-settings 的 Swift 半边虽然
与壳同进程，但它是运行时编出来的 dylib，`import` 不到壳里的类型（壳是预编译产物，
不导出 module）。所以它只有两种数据面：`UserDefaults` 直接读写偏好，订
`clam.connection.state` 读状态。

---

## 5. endpoint 发现文件

落点 `~/Library/Application Support/io.wenbo.surfclam/endpoints/<profile>.json`，
**一个 profile 一份**。写在 `clam-app/lib/index.js` 的 `writeEndpointFile`（原子写：
先临时文件再 rename，壳永远读不到半截 JSON），fiber 卸载时删（带 pid 校验，
只删自己那份）。读在 `ClamEndpoint.swift` 的 `decodeEndpoint`。

字段表见 [`../extend/contracts.md` §10.1](../extend/contracts.md)。

**为什么按 profile 分片**：一台机器上同时跑好几个后端是常态（一个 worktree 一套
插件、一个 profile、一个 App 实例）。共用一份文件的话后启动的会把先启动的抹掉,
被抹的那套再也接不到手动双击起来的壳。所以壳这边是**扫目录取候选**，不是读单文件。

**别删这份文件**：用户 ⌘Q 之后后端不会再拉起 App（`launch` 只在 activate 时跑一次），
双击是唯一的回来路径，而双击没有 flag。

死活由一次 GET 判定（`EndpointLocator.probe`，超时 1.5s，2xx/3xx 即健康）。
被 `kill -9` 的后端会留下陈旧的一份——那不需要额外的清理逻辑，探不通自然跳过。
健康检查到此为止：端口能应答就够，进程监督归后端自己（壳已不是它的父进程）。

**一轮把全部候选并行探完**（`probeAll`）。串行版在有死候选时线性变慢：三个死候选
就是 4.5s，而轮询周期只有 2s——轮与轮会叠起来。并行之后整轮的最坏耗时就是单个超时。
`TaskGroup` 的完成顺序是先到先得，所以结果**按下标回填**，不然选取规则就被搅乱了。

### 5.1 候选排序：判据是硬事实，不是名字推断

`ClamEndpoint.isOwn` —— "这套后端是不是我这一套"。两条判据，任一成立即算：

1. **`appPath` == `Bundle.main.bundlePath`**（解符号链接后比）。开发期与安装期都成立，
   是首选。
2. **`hostDir` == `ClamPaths.ownHostDir`**。壳从自己的 bundle 路径里反推
   `<worktree>/clam-app/host`。

**第 2 条对装到 `/Applications` 的 Release 壳必然失败**——那份 bundle 不在任何
worktree 的 `build/Build/Products/` 之下，`ownHostDir` 根本推不出来。`appPath`
就是为它加的。

排序**先按 `isOwn`、再按 `startedAt` 倒序**。只按 `startedAt` 排会**安静地连错**：
双击起来的壳挑中邻居 worktree 最近启动的那个后端，于是去编译**邻居的**插件源码——
编译失败时那条错误原样落进自己的日志，读日志的人完全看不出它属于别人家
（症状：日志里冒出本 worktree 根本没有的插件名，而 `git diff` 干干净净）。

自己那套没在跑时仍然会退到邻居（总比连接页有用），但接入那行日志与 ⌥⌘D 都会标出
「⚠️ 不是本 worktree 那一套」。

---

## 6. 托管后端

`mode = managed` 时壳自己 spawn 一个后端并盯着它。语义照 Docker Desktop——
**打开即有、⌘Q 即退**。实现是 `Native/BackendManager.swift` +
`Native/ManagedProcess.swift`。

### 6.1 spawn 什么

| 壳 | 命令 |
|---|---|
| Dev（bundle 路径推得出 worktree） | `cd <worktree> && exec ./dev` |
| Release | 先跑 `ProfileBootstrap`，再 `exec dsh --profile surfclam --port 0 --no-open` |

Dev 壳借 `./dev` 白捡 link / profile 判定 / xcodegen 兜底那一整套安装逻辑，
壳一件都不必抄。**Dev 壳不自举 profile**：开发形态的 profile 由 `./dev` 自己备
（link 仓库源码），自举一插手就把仓库从运行链上摘掉了；两者的 profile 名也不同
（`surfclam-dev` vs `surfclam`）。

Release 那条路上**自举必须排在 spawn 之前**：镜像不在位时后端会因为
`ClientPackageCompositionError` 整个起不来，顺序反了就是必崩。

两者都经 `/bin/zsh -lc`：**GUI App 的 PATH 里只有 `/usr/bin:/bin:/usr/sbin:/sbin`**，
node 与 homebrew 都不在里面，而 `dsh` 的 shebang 是 `#!/usr/bin/env node`——解不出
node 就是"起不来"，且看上去像后端坏了，其实它一次都没被执行到。
（`zsh -lc` 读 `.zshenv`/`.zprofile`/`.zlogin`，**不读 `.zshrc`**。）
两条命令都 `exec`，让 pid 落在真身上——多一层 zsh 只会让日志里的 pid 对不上人。

**命令行上没有任何形态环境变量。** 形态由 clam-app 自己看"壳源码在不在包里"判定
（见 [`distribution.md` §4](distribution.md)），判据在包的内容里，不在这条命令行上。

### 6.2 spawn 之前必须查重

**同一个 profile 的两个后端会互抹 endpoint 发现文件**，抢起来是安静的数据损坏，
所以查重必须先于任何 spawn 生效。两条判据（并行跑）：

- 发现文件里 `isOwn` 的端点**探得通** → `.externalBackend`（"不用你管了"）；
- 那个已退役的常驻 LaunchAgent 还在跑 → `.externalBackendUnreachable`（"它在，只是
  连不上"）。

**这两态必须分开**：混成一句"不可用"是实打过的坑——daemon 活着、发现文件却被同
profile 的另一个后端覆盖后带走，壳既发现不了它、又因为"daemon 在跑"拒绝 spawn，
而界面上写的是「后端已在运行，无需托管」，用户面前明明是一个都没连上的引导页。

### 6.3 进程组：为什么不能用 `Foundation.Process`

`Process` 没有任何办法让子进程自成进程组——它内部 `posix_spawn` 时不设
`POSIX_SPAWN_SETPGROUP`，子进程继承的是**壳自己**的进程组。那种形态下两条路都是死的：
`killpg` 会把壳一起杀，只 `kill` 子进程又漏掉孙子进程。托管跑的 `./dev` 正是
`node → spawnSync(dsh)` 两层：只 TERM 外层的话内层立刻被 init 收养、继续跑、继续
占端口，**而壳这边毫无异样**——下次启动的查重反而会因为"已经有个健康端点"而不
spawn（症状是"托管好像没生效"，原因在上一次退出）。macOS 也没有 `setsid(1)` 可借。

所以 `ManagedProcess` 直接调 `posix_spawn`，用
`posix_spawnattr_setpgroup(&attr, 0)` 让子进程自己当组长（pgid == pid），
之后 `killpg` 精确覆盖整棵子树、一个信号也落不到壳身上。
隔离验证台在 [`../spikes/backend-spawn/`](../spikes/backend-spawn/)（可复跑）。

### 6.4 监护与收尾

- **输出**落 `logs/managed-dsh.<instanceTag>.log`（跟着**产物**分片，与壳日志同一个键；
  超过 4MB 下次启动时从头来过）。
- **意外退出退避重启**：1s / 4s / 15s 三次；60s 窗口里连着败完这三次就进 `.gaveUp`
  摊开日志等人来看。KeepAlive 式的死循环比"停下来摊开日志"糟得多。
- **⌘Q**：SIGTERM 整个进程组，限时等 2s（配合 AppDelegate 的 `.terminateLater`），
  超时补 SIGKILL。**为什么要等**：后端收到 SIGTERM 之后要跑完 fiber 清理才会删掉
  endpoint 发现文件，不等的话磁盘上会留一份指向死进程的陈旧文件。

**每个子进程带一个 `spawnToken`**：退避重启、用户 stop 之后又 start，都会让上一代的
尸体晚一步回来，认错代就会把新一代的账算错。"还没 spawn 的那次拉起"另有一个
`launchToken`——stop 要作废它，但不能顺手把"已经在跑的那个子进程的退出回调"一起
作废掉，⌘Q 正等着那个回调来答复系统。

### 6.5 "打开即有"不能只保证打开那一瞬

`MainWindowController.start()` 里那句 `backend.start()` 只在 App 启动时跑一次。
后端事后消失（被 kill、机器睡醒）就再没有人去拉它，壳只会永远停在断连页。

补在 `ensureManagedBackend()`：**幕一变成"要盖连接页"就喊一次托管**，15s 节流
（幕会在 connecting ↔ disconnected 之间来回跳，每跳一次都重跑一遍查重就是在刷屏；
间隔取 `BackendManager` 最长退避那一档，两套节奏对得上）。

`BackendManager` 自己那套退避管不了这一段——它只监护自己亲手 spawn 的子进程；
后端是外部的（或还没有）时它停在 `.unavailable`，没有子进程可监护。

**连接归位不靠新机制**：子后端照常写 endpoint 发现文件，那 2s 轮询自然接上
（壳这边只在拉起后催一轮）。

---

## 7. 后端的生命周期归壳，不归 launchd

这是一条设计立场，不是实现细节。

壳自托管时，后端的启动、退避重启、⌘Q 收尾都在 `BackendManager` **一处可见可控**。
交给外部常驻服务（launchd 之类）之后，壳对它只有观测权没有控制权；更糟的是两者
会抢同一个 profile、互抹 endpoint 发现文件——那正是"双击 App 连不上、点开启托管
什么也没发生"那类死锁的一半原因。

历史上确实有过一个 `io.wenbo.surfclam.dsh` LaunchAgent，已经退役。留下的只有两处：
`./release` 跑一次会自动清掉旧安装（`removeLegacyDaemon`），托管查重还会问它一句
（万一那台机器上还残留着）。

---

## 8. 连接页

没连上时铺满窗口的是 `ConnectionViewController.swift`（SwiftUI 覆盖层），两页：

- **引导连接页**（searching / idle / unreachable / connecting）：托管卡 + 手动地址卡
  + 发现的后端列表；
- **连接中断页**（disconnected）：纯诊断五行 + 一个「连接其他后端…」。

三条口径，全部强制：

1. **面向最终用户**——界面上一个 worktree / profile / pid / hash 都没有，一律称"后端"，
   一个后端只以端口称呼（"端口 3080"）。那些开发者细节的去处是 **⌥⌘D 诊断面板与日志**。
2. 文案贴系统 App 的密度：短、事实性，不写安抚性废话。
3. **优先 Apple 原生符号与样式**：SF Symbols 而不是自绘路径，语义色而不是抄设计稿的
   hex。深浅色因此自动成立。

一条布局约束：连接页那一层挂在 `WindowDragRegionView` **之下**。覆盖层排在拖动条
上面的话标题栏就拖不动了。

用户敲进来的地址走 `ConnectionController.normalizedURL`：裸端口号补成
`http://127.0.0.1:<port>`，没写 scheme 的补 `http://`，**只认 http / https**——
页面里的地址等同不可信输入。

---

## 9. 排错入口

| 想知道 | 去哪 |
|---|---|
| 我现在连着谁、幕是什么、候选各是死是活 | **⌥⌘D 诊断面板**（也写着本进程日志的全路径） |
| 托管后端起没起来、为什么没起来 | `logs/managed-dsh.<instanceTag>.log`；`BackendManager.diagnosticSummary` 那一行 |
| 壳自己在干什么 | `logs/surfclam.<instanceTag>.log`（tag `connection` / `endpoint` / `backend`） |
| 装好的那套是什么状态 | `./release --status` |

**日志一律中文、一律不随界面语言变**：读它的是终端前的人和 agent，跟着界面语言变
只会让排错时对不上账。同理，幕与失败分类都另有一个稳定 `key`（`searching`、
`bridgeRejected`…），投影与日志用它。
