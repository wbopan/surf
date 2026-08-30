# `./release`：把 surfclam 装成本机常驻的正式形态

> 计划文档，2026-08-29。执行日志见 §6。
> 讨论定调：**不设第二个 profile**——`surfclam`（主 worktree 的那个）就是本机安装的身份；
> release 与 dev 的差别用「每次运行的开关」（环境变量）表达，不用第二张编排表。

## §0 目标与非目标

**目标**：一条 `./release` 命令，跑完之后这台机器上有一套「装好了」的 surfclam：

- `/Applications/Surfclam.app`（Release 壳，正式图标、无 DEV 徽章）；
- 一个 LaunchAgent 常驻跑 `dsh --profile surfclam`，登录即起、崩了重拉；
- 随时双击 `/Applications/Surfclam.app` 都能连上它（不再依赖终端里开着 `./dev`）；
- 改了代码想更新：重跑 `./release`（壳与 node 半边），或什么都不做（Swift 插件
  对着常驻 dsh 照样热替换——桥盯 `swift/` 与本计划无关，天然继续工作）。

**非目标**：

- 不做 npm 发布 / 外部用户分发（那是 CLAUDE.md「分发形态」里预编译产物的问题，另案）；
- 不改「App 是 dsh 的客户端外设」的架构方向（壳不自己 spawn dsh）；
- 不做第二个 profile、不复制源码快照——link 模式的主仓库源码就是运行时真相。

## §1 现状事实清单（动手前核对，与源码冲突以源码为准）

1. `./dev` = `surfclam/bin/surfclam.js` link 模式：`ensureModuleResolution`（node_modules
   符号链接）→ `ensureXcodegen` → `installInto`（`dsh plugin add link:…`）→ `fixBundles`
   → 前台 `dsh --profile <名> --port 0 --no-open`。主 worktree 的 profile 名固定 `surfclam`
   （`defaultProfile` 比对 `--git-dir` 与 `--git-common-dir`）。
2. Release 壳的构建与安装**已经存在**：`clam-app/host/scripts/build.sh` = xcodegen →
   xcodebuild Release（`-derivedDataPath build` 硬约束）→ 退出正在跑的 Release 实例 →
   `ditto` 进 `/Applications/Surfclam.app`。它只管壳，不管 dsh。
3. `clam-app/lib/index.js` 的 Config 已有全部所需旋钮：`configuration`（Debug/Release）、
   `build`、`launch`、`watch`、`restartOnRebuild`。`locateExistingProduct` 在 `build` 关闭时
   先探本地 `build/Build/Products/<配置>/`，再兜底 `/Applications/Surfclam.app`
   （常量 `INSTALLED_RELEASE`）。
4. endpoint 发现文件：`~/Library/Application Support/io.wenbo.surfclam/endpoints/<profile>.json`，
   clam-app 写、fiber 卸载删（pid 校验防误删）。载荷含 `httpBase / bridgePath / pid /
   startedAt / profile / hostDir`。**hostDir 是壳认「哪套是我的」的判据**：Swift 侧
   `ClamEndpoint.isOwn` 用自己 bundle 路径反推 `ClamPaths.ownHostDir`
   （bundle 在 `<hostDir>/build/Build/Products/<配置>/` 之下时才推得出）与之比对。
5. **推论（本计划要修的缺口）**：`/Applications/Surfclam.app` 不在任何 worktree 的
   `build/Build/Products/` 之下，`ownHostDir` 推不出来 → `isOwn` 恒 false →
   装好的壳只能按 `startedAt` 倒序挑 dsh。多 worktree 并存时它会连上
   最近启动的邻居 dsh（CLAUDE.md 踩坑记录里"安静地连错"那条的 release 变体）。
6. dsh 可执行文件是全局的：`/opt/homebrew/bin/dsh` →
   `/opt/homebrew/lib/node_modules/@deepseek-ai/dsh/lib/bin.js`，shebang 是
   `#!/usr/bin/env node`。**launchd 的默认 PATH 只有 `/usr/bin:/bin`，找不到 node**——
   plist 必须显式给 PATH（含当前 node 的 dirname 与 `/opt/homebrew/bin`）。
7. 会话与设置是全局的（`~/.dsh/sessions`、`~/.dsh/settings.yaml`），不随 profile 分片
   ——这是"不设第二个 profile 也没有数据代价"的事实基础。
8. 同一个 profile 的两个 dsh 会互抹 endpoint 文件（一个 profile 一份，覆盖写），
   所以「daemon 在跑」与「主 worktree 前台 `./dev`」必须互斥。
9. `resolveProfileName()` 从 argv 反推 `--profile`，LaunchAgent 的 ProgramArguments
   里带 `--profile surfclam` 即可让 endpoint 文件落对名字。

## §2 设计决策

### 2.1 一个 profile，环境变量做形态开关

profile 只有 `surfclam` 一个。LaunchAgent 在 plist 里设 `CLAM_RELEASE=1`；
`clam-app/lib/index.js` 的 `apply` 开头检测到它就把配置**整体覆写**为 release 形态：

```
configuration: "Release", build: false, watch: false, launch: false
```

并打一行日志（"CLAM_RELEASE=1：release 形态——不构建、不盯源码、不自动拉起"）。
编排表 `cordis.patch.yml` 一字不改——同一张表服务两种形态，差别只在每次运行的环境。
`launch: false` 的含义：**daemon 是安静的**，登录时不弹窗口，App 由用户双击
（或 `./release` 收尾那一下 `open`）。`restartOnRebuild` 在 release 形态无意义（不构建）。

### 2.2 endpoint 文件新增 `appPath` 字段，壳的 `isOwn` 认它

修 §1.5 的缺口。契约（写进 `docs/clam-contracts.md` 的保管箱/wire 一节）：

- **node 侧**（`writeEndpointFile`）：新增字段 `appPath` = 本 dsh 期望的 App bundle
  绝对路径。release 形态 = `INSTALLED_RELEASE`（`/Applications/Surfclam.app`）；
  dev 形态 = `productPath(configuration)`。
- **Swift 侧**（`ClamEndpoint.isOwn` 或其调用处）：`isOwn` 的判据扩成
  「hostDir 与 `ownHostDir` 相等」**或**「`appPath` 与自己 `Bundle.main.bundlePath`
  的 realpath 相等」。旧文件没有 `appPath` 字段 → 走原判据，向后兼容。
- 排序逻辑不变：先 isOwn 后 startedAt；「⚠️ 不是本 worktree 那一套」的标注逻辑随之自然正确。

改了壳源码（Swift 侧在 `clam-app/host/Sources/` 下），dev 形态下 clam-app 会自动重建
Debug 壳；Release 壳由 `./release` 的 build.sh 步骤重建。

### 2.3 `./release` 命令

仓库根加薄封装 `release`（照抄 `dev` 的形状）：

```sh
exec node "$(dirname "$0")/surfclam/bin/surfclam.js" --release "$@"
```

逻辑进 `surfclam/bin/surfclam.js` 的一条 release 路径（与现有 main 共享全部安装函数）：

1. **只许主 worktree**：`defaultProfile` 判出的名字不是 `surfclam` 就 fails loud
   （"release 安装以主 worktree 为真相源，去主 worktree 跑"）。registry 模式同样拒绝
   （本机安装是开发者动作）。
2. **互斥检查**：读 `endpoints/surfclam.json`，pid 还活着且不是 launchd 管的那个
   daemon → fails loud（"前台 dsh 在跑，先 Ctrl-C 它"）。判"是不是 daemon"：
   `launchctl print gui/$UID/io.wenbo.surfclam.dsh` 里的 pid 与文件里的比对。
3. **备 profile**：复用 `ensureModuleResolution` + `ensureXcodegen` + `installInto` +
   `fixBundles`，profile 钉死 `surfclam`。
4. **装壳**：spawn `clam-app/host/scripts/build.sh`（stdio inherit——xcodebuild 的
   进度要给人看）。失败即中止，不写 plist。
5. **写并加载 LaunchAgent**：`~/Library/LaunchAgents/io.wenbo.surfclam.dsh.plist`，
   Label `io.wenbo.surfclam.dsh`（`.dsh` 后缀把 daemon 和 App 的 bundle id 区分开）：
   - ProgramArguments：`[<dsh 绝对路径>, --profile, surfclam, --port, 0, --no-open]`
     （dsh 路径 `which dsh` 现场解析，写死进 plist）；
   - EnvironmentVariables：`CLAM_RELEASE=1`；`PATH` = `dirname(process.execPath)` +
     `/opt/homebrew/bin` + `/usr/local/bin:/usr/bin:/bin`（§1.6 的坑）;
   - `RunAtLoad: true`、`KeepAlive: true`、WorkingDirectory = 仓库根；
   - StandardOut/ErrorPath 都指
     `~/Library/Application Support/io.wenbo.surfclam/logs/dsh-daemon.log`。
   加载顺序：`launchctl bootout gui/$UID/io.wenbo.surfclam.dsh`（不存在则忽略失败）
   → `launchctl bootstrap gui/$UID <plist>`。bootout 后立刻 bootstrap 可能撞
   "in flight"，失败时小退避重试两三次。
6. **收尾**：等 `endpoints/surfclam.json` 出现（轮询几秒，等不到只警告不失败——
   壳自己有 2s 重连轮询）→ `open /Applications/Surfclam.app` → 打印摘要
   （plist 路径、日志路径、常用命令）。

子命令（都不走安装流程）：

- `./release --stop`：bootout daemon（plist 留着，下次 `--start` 或重跑 `./release` 恢复）；
- `./release --start`：bootstrap 已有 plist；
- `./release --status`：daemon 在不在（launchctl print 摘要）+ endpoint 文件内容 +
  `/Applications/Surfclam.app` 在不在；
- `./release --uninstall`：bootout + 删 plist + 删 `/Applications/Surfclam.app`
  （profile 与 `~/.dsh` 数据不动，明说）。

### 2.4 `./dev` 的互斥检查

`start()` 之前：profile 是 `surfclam`（只有主 worktree 会撞）且
`launchctl print gui/$UID/io.wenbo.surfclam.dsh` 显示 running → fails loud：

```
常驻 surfclam 在跑（LaunchAgent io.wenbo.surfclam.dsh）。二选一：
  ./release --stop   停掉它再 ./dev（前台开发）
  直接用它           Swift 插件改动对常驻 dsh 一样热生效；
                     改 node 半边后 launchctl kickstart -k gui/$UID/io.wenbo.surfclam.dsh
```

侧 worktree 的 `./dev` 不受影响（profile 不同，天然并存）。

### 2.5 release 形态的哈希重建（2026-08-30 用户裁决，推翻 §2.1 的「不构建不盯源码」）

**动机**：M7（连接计划 §11）落地当天实测踩到——桥把新 clam-settings 热替换进了
正跑的 Release 壳（第五栏出现了），但壳自己的二进制还是旧的，「立即重启」按钮
emit 出去无人订阅、静默没反应。**壳源码落后是静默的，且症状出在别处。**
用户裁决：release 形态也做哈希检查——一致跳过、不一致重建，
和 dev 形态同一套机制，只是配置与落点不同。

**语义**（`CLAM_RELEASE=1` 的覆写从「不构建不盯不拉起」改成）：

- **盯源码照开**（同 dev 的 2s 签名比对），配置用 **Release**，marker 天然分片
  （`.clam-app-source-hash.Release`），与 dev 的 Debug marker 互不打架。
- **门控**：`hasXcode()` 且壳源码目录在（registry/npx 形态没有 host 源码）——
  不满足就退回现状（不构建不盯），最终用户机器行为不变。
- 哈希不一致 → 后台 xcodebuild Release（`-derivedDataPath build`，编译永远发生在
  worktree 的 `build/` 里）→ **安装**到 `/Applications`（拷贝那一步；复用/抽取
  `build.sh` 的安装逻辑均可）→ 经桥播 `app-build`。**绝不 quit 正在跑的 App**
  ——换代由壳右上角既有的「壳有新版本 · 重启」提示条驱动，用户点了才换。
- 壳自请重启后的重拉：release 形态 `launch: false` 指的是「登录时不自动弹窗」，
  **app-restart 的等死透再 `open /Applications/Surfclam.app` 是另一条路径，保留**。
  「绝不给后来者补发 `app-build`」铁律不变。
- **失败语义**：构建失败旧壳继续在役，错误落 `clam-app-build.surfclam.Release.log`；
  **记住失败那次的源码哈希、哈希再变才重试**——不许 2s 一轮空转 xcodebuild
  （dev 形态失败重试怎么处理就照抄，与此冲突时以「不空转」为准）。
- `restartOnRebuild` 在 release 形态**强制视为 false**（daemon 不替用户杀 App）。
- 边界：`/Applications/Surfclam.app` 不存在 → 直接构建安装；marker 不存在但产物在
  （`build.sh` 手跑过、marker 是 node 侧的账）→ 允许多构建一次对齐，或让 build.sh
  顺手写 marker，实现时择一并记录。

**连带一件小事（连接计划 §11.1 预告的衔接点）**：`./release` 安装步骤补写首开偏好
`defaults write io.wenbo.surfclam clam.connection.mode -string auto`——
**仅当该键不存在时**（别覆盖用户已设的 fixed/managed）。不写的话 M7 的 unset 语义
会让装完首开停在引导页，与「装完 open 一次即用」的体验矛盾。

## §3 交付物清单

| 文件 | 改动 |
|---|---|
| `release`（仓库根，新增） | 薄封装，照抄 `dev` |
| `surfclam/bin/surfclam.js` | release 路径（§2.3 六步 + 四个子命令）；`./dev` 互斥检查（§2.4）；`usage()` 更新 |
| `clam-app/lib/index.js` | `CLAM_RELEASE` 形态覆写（§2.1）；`writeEndpointFile` 加 `appPath`（§2.2） |
| `clam-app/host/Sources/…`（ClamEndpoint 所在文件） | `isOwn` 认 `appPath`（§2.2，向后兼容） |
| `docs/clam-contracts.md` | endpoint 文件字段表补 `appPath`；`CLAM_RELEASE` 环境开关登记 |
| `CLAUDE.md` | 「怎么把它跑起来」加 `./release` 一段；「多 worktree」提 daemon 互斥；踩坑记录补 launchd PATH 那条（若实现中再踩新坑一并记） |

## §4 里程碑

- **M1 clam-app 的 release 形态 + `appPath` 字段**（node，改完重启 dsh 验证：
  `CLAM_RELEASE=1 dsh --profile surfclam --no-open` 起来后 endpoint 文件里有
  `appPath: "/Applications/Surfclam.app"`、终端有 release 形态日志、没有 xcodebuild）。
- **M2 Swift `isOwn` 认 `appPath`**（dev 形态下存盘热替换即验：⌥⌘D 诊断面板 /
  接入日志的 isOwn 标注不回归；无法直接验 /Applications 场景就读码 + 单元性小验证）。
- **M3 `./release` 命令**（§2.3；`--stop/--start/--status/--uninstall` 各跑一遍）。
- **M4 `./dev` 互斥检查**（daemon 在跑时 `./dev` 被拦且提示语正确；`--stop` 后放行）。
- **M5 文档 + 端到端验收**：干净跑一遍 `./release`，确认 daemon 起、
  `launchctl print` 是 running、双击（`open`）`/Applications/Surfclam.app` 连上它、
  窗口无 DEV 徽章、`./dev` 被拦。**验收时若发现用户的前台 dsh 正在跑，停下来报告，
  不擅自 kill。**
- **M6 release 形态的哈希重建 + 首开偏好**（§2.5）：改壳源码 → daemon 侧后台重建
  Release 并安装 → 正跑的 Release 壳挂「壳有新版本 · 重启」提示条 → 点了换代；
  源码没变则一轮构建都不发生；构建失败不空转；`./release` 安装步骤补
  `defaults write` 首开偏好（键已存在不覆盖）。

每完成一个里程碑在 §6 追加一行执行日志。

## §5 风险与已知坑

- **launchd PATH**（§1.6）：漏了就是 daemon 秒退、KeepAlive 每 10s 重试一次、
  日志里只有一句 `env: node: No such file or directory`。
- **bootout → bootstrap 的竞态**："Bootstrap failed: 5: Input/output error" 或
  "in flight"，退避重试即可，别误判成 plist 写错。
- **KeepAlive 与坏代码**：daemon 跑的是 link 的仓库源码，node 半边改出语法错会让
  launchd 进入 10s 间隔的重启循环——症状全在 `dsh-daemon.log` 里，属预期行为，
  文档里写明"改 node 半边用侧 worktree 验证，或先 `./release --stop`"。
- **build.sh 会退出正在跑的 Release App**：重跑 `./release` 时窗口会闪断一次，预期内。
- **陈旧 endpoint 文件**：daemon 被 bootout（SIGTERM）时 fiber 清理未必来得及跑，
  留下 pid 已死的文件。壳靠连接失败自然跳过它，不必额外清理逻辑；
  但 `--status` 输出里要把"文件在、pid 已死"这种状态如实标出来。

## §6 执行日志

- **2026-08-29 · M1（clam-app 的 release 形态 + `appPath`）** —— 完成。
  `applyReleaseForm()` 在 `apply` 的第一句整体覆写配置（`Release` / build,watch,launch
  全关）并打日志；`expectedAppPath()` 给出本进程期望的 bundle 路径，写进
  `writeEndpointFile` 的新字段 `appPath`。
  **偏差三处**（都是为了让"期望的产物"只有一份真相）：
  ① `locateExistingProduct(configuration, preferred)` 多收一个"优先认这一份"的参数
  ——不然 release 形态下本地 `build/Build/Products/Release/` 里那份同名产物会先被
  挑中，与发现文件里写的 `/Applications/...` 分家；
  ② `restartApp` 改收 `appPath` 而不是 `configuration`（同一个理由）；
  ③ 计划只说"写进发现文件"，实现里顺手把它接成了 clam-app 自己认产物的判据。
  **实测**：写完后一个 dsh（用户前台那个）自然重启，endpoint 文件里立刻出现
  `"appPath": ".../Debug/Surfclam Dev.app"`，dev 形态行为不变、无 release 日志。
- **2026-08-29 · M2（Swift `isOwn` 认 `appPath`）** —— 完成。
  `ClamEndpoint` 加 `appPath: String?`，`isOwn` 变成"两条判据任一成立"，
  路径比较统一走新的 `samePath()`（先解符号链接再标准化——`/Applications` 与
  worktree 都可能躺在链接后面，纯字符串比会给出假阴性，症状同样是安静地连错）。
  缺字段 = 那条判据不成立，老发现文件走原判据，向后兼容。
  **验证**：`swiftc -typecheck ClamEndpoint.swift ClamPaths.swift` 干净通过
  （没跑 xcodebuild，按本次任务的范围限制）。顺手补了
  `docs/spikes/webpolicy/main.swift` 里那处 `ClamEndpoint(...)` 的参数
  ——**那个 spike 早就编不过了**（缺 `Strings.swift`、且它现在 `import ClamSDK`），
  本次只让 endpoint 那一行跟上，没有整体修它。
- **2026-08-29 · M3（`./release` 命令）** —— 完成。仓库根加薄封装 `release`
  （已 `chmod +x`）；`bin/surfclam.js` 加 release 路径与四个子命令，安装那几步抽成
  共用的 `provision()`（dev 与 release 同一份真相）。
  **偏差**：① `--profile` / `--port` 与 `--release` 同时给会 fails loud
  （plist 里那两个值是写死的，收下一个不生效的旋钮是安静地骗人）；
  ② 等 endpoint 的判据是"文件 mtime 晚于本次 bootstrap"而不是"文件存在"
  ——上一次运行留下的陈旧文件不该算数；③ 超时 15s（计划说"几秒"）。
  **验证**（都不改机器状态）：`--status` 如实报出 daemon 未登记 / plist 不在 /
  endpoint 活着且带 `appPath` / App 不在；`--start` 无 plist 时 fails loud；
  `--stop` 未登记时如实说；`--stop --status` 互斥报错。plist 的**渲染**在 /tmp 里
  单独跑了一遍（把两个落点常量 sed 到 /tmp 的临时副本），`plutil -lint` OK、
  `plutil -p` 反读回来字段齐全，PATH 首项是当前 node 的目录。
  `daemonStatus()` 的两条正则拿真的 `launchctl print` 输出验过
  （取到顶层的 `state = running` 与 `pid`，不会被嵌套的 `state = active` 带偏）。
- **2026-08-29 · M4（`./dev` 互斥）** —— 完成。`assertNoDaemon()` 挂在 `start()` 第一句，
  只在 profile 是 `surfclam` 且 daemon 有活 pid 时拦（loaded 但没跑不拦）。
  反向的 `assertNoForegroundDsh()` 在 release 安装的第二步，判据是"endpoint 文件里的
  pid 还活着且不是 daemon 那个"。**两条都实测过**：当时用户的前台 dsh
  正跑着，`assertNoForegroundDsh()` 如实拦下并报出 pid 与端点；daemon 未登记时
  `assertNoDaemon()` 对主 worktree 与侧 worktree 都放行。
- **2026-08-29 · M5（文档半边）** —— 完成。`docs/clam-contracts.md` 新增
  §10「dsh ↔ 壳：endpoint 发现文件与环境开关」（原先没有这张字段表，所以是新起一节，
  「一句话速查」顺延为 §11）；`CLAUDE.md` 加了 `./release` 一节、多 worktree 的
  daemon 互斥段、`isOwn` 两条判据的更新，踩坑记录补了 launchd PATH + bootout/bootstrap
  竞态那一条。**端到端验收没跑**（本次任务限定只做代码与文档，不改机器状态），
  步骤清单见下。

- **2026-08-29 · M5（端到端验收）** —— 完成（§6.1 的 1～8 步）。停掉前台 dsh 后
  `./release` 一次通过：xcodebuild Release → `/Applications/Surfclam.app` → plist →
  bootstrap → endpoint 就绪（http://127.0.0.1:60305）→ `open`。核实过的硬证据：
  `launchctl print` state=running 且 environment 里有 `CLAM_RELEASE=1` 与
  node 目录打头的 PATH；`dsh-daemon.log` 有 release 形态那一句、**零次 xcodebuild**；
  endpoint 文件 `appPath` = `/Applications/Surfclam.app`；壳日志（无后缀
  `surfclam.log`）里接入行**不带**「⚠️ 不是本 worktree 那一套」——M2 的 `appPath`
  判据在真实 /Applications 场景下成立；截图确认窗口无 DEV 徽章、原生侧边栏与
  会话内容俱全；`./dev` 被拦且提示语完整。**没跑的两步**：§6.1 第 9 步的
  Swift 热替换回归（机制与本计划无关，未动它），第 10 步 `--uninstall`（装好就是
  要用的，不拆）。

### §6.1 留给端到端验收的步骤

前置：主 worktree、没有前台 `./dev` 在跑（有的话先 Ctrl-C，**别 kill 用户的**）。

1. `./release --status` —— 应当是 daemon 未登记 / plist 不在。
2. `./release` —— 看它依次走完：profile 校验 → 互斥检查 → `dsh plugin add` →
   xcodebuild Release（分钟级，进度直通终端）→ 写 plist → bootstrap → 等 endpoint →
   `open`。**壳构建失败时必须停在那里、不写 plist**。
3. `launchctl print gui/$(id -u)/io.wenbo.surfclam.dsh | head -20` —— `state = running`，
   `pid` 有值；`environment` 里有 `CLAM_RELEASE=1` 与带 node 目录的 `PATH`。
4. 看 `<AppSupport>/io.wenbo.surfclam/logs/dsh-daemon.log`：有 clam-app 那句
   「CLAM_RELEASE=1：release 形态——不构建、不盯源码、不自动拉起」，**没有 xcodebuild**。
5. `cat <AppSupport>/io.wenbo.surfclam/endpoints/surfclam.json` ——
   `appPath` 是 `/Applications/Surfclam.app`。
6. 窗口：正式图标、无 DEV 徽章、无 bootstrap 斜纹；⌥⌘D 里端点那行**不带**
   「⚠️ 不是本 worktree 那一套」（这一条就是 M2 的验收）。
7. ⌘Q 退出 App，双击 `/Applications/Surfclam.app` —— 应当自己连回常驻 dsh。
8. `./dev` —— 被拦，提示语给两条出路。`./release --stop` 之后 `./dev` 放行（Ctrl-C 停）。
9. `./release --start` → `--status` → 改一行插件 `swift/` 验热替换仍然工作。
10. 收尾看是否要 `./release --uninstall`（会删 plist 与 `/Applications/Surfclam.app`，
    profile 与 `~/.dsh` 数据不动）。
- 2026-08-30 **M6 计划定稿**（用户裁决）：release 形态从「不构建不盯源码」改成
  哈希重建（§2.5）——动机是 M7 当天实测的「壳二进制静默落后、重启按钮无人应答」。
  连带收编连接计划 §11.1 的首开偏好衔接点。待实现。

- **2026-08-29 · M6（release 形态的哈希重建 + 首开偏好）** —— 完成，活体验过。
  `applyReleaseForm` 现在只覆写**配置与落点**（`Release` / `launch:false` /
  `restartOnRebuild:false`），`build` 与 `watch` 照开；构建成功后多一步
  `installBuiltProduct` 把产物装进 `/Applications`。`./release` 的安装流程多了
  `ensureConnectionModeDefault()`（键不存在才写 `auto`）。

  **与 §2.5 的偏差四处**：
  ① **安装不是 `rm -rf` + `ditto`**，而是 `ditto` 到 `/Applications/.Surfclam.app.clam-staging`
  → 旧的换名到 `.clam-previous` → 暂存换名就位 → 删旧。计划说"参照 build.sh 的
  ditto"，但 build.sh 那一步的前提是**它先 quit 了 App**；这条路径不许 quit，
  于是原地覆写会撞 `ETXTBSY`（正在跑的 Mach-O），而 `rm -rf` 到拷完之间那几秒里
  `/Applications/Surfclam.app` 根本不存在——用户这时点 Dock 就是"找不到应用程序"。
  ② marker 对齐选了计划里的**第二条路**（"让 build.sh 顺手写 marker"）**并且**
  保留第一条兜底：hash 算法抽成零依赖的 `clam-app/lib/source-hash.js`（`hash` /
  `marker <配置>` 两个只读子命令），`build.sh` 装完调它写 marker。于是
  `./release` 之后 kickstart 是零次 xcodebuild；marker 真缺时仍然多编一次对齐
  （本次实测就是这一支：机器上只有 `.Debug` marker）。另加一条不在计划里的支线——
  **marker 对得上但 `/Applications` 那份不在**，直接拷既有产物，不重编。
  ③ **首次构建失败之后继续盯源码**（原来的行为是"首次失败就不盯了"）。常驻 daemon
  一跑就是几天，不盯的话用户改好编译错误也得等到下次 kickstart。空转的防线因此
  从"签名没变"加厚成"记住失败那次的 hash"（`lastFailedHash`）：签名变了而内容
  没变（touch、换分支再换回来）时不会再白编一次。这条对 dev 形态同样生效。
  ④ 失败日志那两句文案从"不重试"改成"改了源码才重试"——旧文案在会重试的语境里
  是错的。

  **实测（都在用户正用着的那套常驻形态上做的，全程没有 quit 过他的 App）**：
  1. **源码没变 = 零次构建**：kickstart 后日志只有
     「Release 产物已是最新（源码 hash 0f9b6976fa8e），跳过构建」，
     `grep -c xcodebuild` = 0。（**首次 kickstart 确实多编了一次**——那台机器上
     只有 `.clam-app-source-hash.Debug`，Release 的账从来没人记过；3.0s 编完、
     装进 `/Applications`，第二轮起就安静了。）
  2. **改壳源码 → 自动重建 + 安装 + 提示条**：给 `DiagnosticsPanel.swift` 加一行
     注释，2s 内 daemon 起编，2.2s 后
     「壳已重建并安装到 /Applications/Surfclam.app」，`/Applications` 的二进制
     inode 与 mtime 都翻新，正跑的 Release 窗口右上角出现
     「New shell build available (16edac0d9a44 · 2.2s) · Restart Surfclam / Later」
     （截图 `.scratch/m6-banner-2.png`；提示条留给用户自己点，没替他点）。
  3. **还原那行注释 → 又一次自动重建**（hash 变回去也是变），marker 与
     `node clam-app/lib/source-hash.js hash` 逐字相等。
  4. **构建失败不空转**：故意写一行类型错误，75 秒（约 37 个轮询拍）里
     「后台重建中」只出现 **1 次**，日志落 `clam-app-build.surfclam.Release.log`
     且带文件行号；`/Applications` 的产物 inode 一动没动，旧壳继续在役。
  5. **首开偏好的门控**：用户机器上 `clam.connection.mode` 已经是 `managed`，
     **真域一个字没动**（只 `defaults read` 过）。判据逻辑拿一个假域
     `io.wenbo.surfclam.m6probe` 演练过：第一次写进 `auto`、第二次报 SKIP，
     测完 `defaults delete` 清掉。

  **两条留给后来者的事实**：
  - **提示条不扛断连**。它是壳的内存状态，daemon 一重启（kickstart 或 KeepAlive
    拉起）壳重连之后就没了，而"绝不给后来者补发 `app-build`"是铁律。于是
    **"daemon 重启过一轮"之后，正跑的窗口可能比 `/Applications` 里的产物旧、
    而界面上什么都不说**——正是 §2.5 动机里那个"静默落后"换了个入口。真要堵，
    得让壳自己拿在跑的 bundle 与磁盘上的产物对账（不是补发），本次没做。
  - 验收途中撞上一次**与本计划无关的 daemon 重启循环**：并行的另一条线往
    `surfclam/cordis.patch.yml` 加了 `clam-memory` 一行但没把包 link 进 profile，
    kickstart 之后就是 `Cannot find package '@wenbo/clam-memory'` + `KeepAlive`
    10s 一轮。按 `./dev` 的 provision 同款补了 profile 里那条符号链接
    （`~/.dsh/profiles/surfclam/node_modules/@wenbo/clam-memory`）就恢复了；
    那条线自己跑一次安装流程即可，不必保留这个手工补丁。
