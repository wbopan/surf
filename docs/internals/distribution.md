# surfclam 是怎么变成一个 App 的

这份文档写给**本仓库的维护者**：讲 surfclam 的分发形态——App bundle 里装着什么、
用户第一次双击时发生了什么、为什么壳不构建自己、签名与公证有哪些结构性约束。
跨包字符串的字段表在 [`../extend/contracts.md` §10.5](../extend/contracts.md)，
这里讲**为什么是这样**。

## 核心主张

**`/Applications/Surfclam.app` 是唯一分发实体。** 三半边（node / client / swift）
全部随它走，用户机器上**不需要 Xcode、不需要 pnpm、不需要知道 profile 是什么**。
用户路径三步，没有第四步：装 dsh（`npm i -g @deepseek-ai/dsh@0.1.1-rc.2`，
**这一步我们不接管**）→ 下载 `Surfclam.dmg` 拖进「应用程序」→ 双击。
之后由壳自己把 profile 备好、把后端拉起来（见 [`connection.md` §6](connection.md)）。
整包 8 MB 出头，dmg 压缩后 4 MB 上下。

曾经还有一条 `npx @wenbo/surfclam` 的 registry 路径，已经删掉：它要求用户机器上有完整
Xcode（十几 GB）加一个不入库的 `xcodegen` 二进制，缺一样就**优雅缺席**——dsh 起、
HTTP 200、壳一声不响地不存在。`surfclam/bin/surfclam.js` 此后只服务开发者，
不在仓库里跑就当场 fails loud。

---

## 1. bundle 里装着什么

```
Surfclam.app/Contents/
  MacOS/surfclam                       壳（预编译，Developer ID 签名）
  Frameworks/libClamSDK.dylib          共享 module 的运行时那一份（壳按 @rpath 加载）
  Resources/
    ClamModules/                       ClamSDK 的 .swiftmodule / .swiftinterface / .swiftdoc
                                       （运行时编译插件时 -I 的落点）
    ClamNode/<pkg>/                    各插件的 node 半边：package.json + lib/ + swift/
    ClamPayload.json                   载荷清单 + 跳过判据（含 version 与内容 hash）
    ClamPlugins/<Module>/prebuilt/<hash12>/lib<Module>_h<hash12>.dylib
                                       预编译的 Swift 半边（**原地用，不进 profile 镜像**）
    ClamPrebuilt.json                  预编译清单（给人看的，没有程序读它）
```

写它们的是三个 postBuild 脚本，**顺序固定，每一步吃上一步的产物**：
`embed-modules.sh`（`Frameworks/` + `ClamModules/`）→ `pack-payload.sh`（`ClamNode/` +
`ClamPayload.json`）→ `prebuild-plugins.sh`（`ClamPlugins/` + `ClamPrebuilt.json`）。
后两个**只在 Release 跑**，Debug 下直接 `exit 0`——开发形态里 node 半边从仓库 link、
Swift 存盘热替换，打进 bundle 的那份没有任何人读，纯粹拖慢 `./dev` 的循环。

### 1.1 `ClamNode/` 的两条不变量

**目录结构与仓库根一一对应。** clam-\* 之间用相对路径 import
（`../../clam-bridge/lib/plugin.js`），兄弟关系一破那些 import 全部落空。
`clam-app/host/` 不进包——那是壳自己的源码，进 bundle 就是自我嵌套。

**`swift/` 与 `lib/` 平级。** 各插件的 node 半边写着
`swiftDir: new URL("../swift/", import.meta.url)`，保持这层兄弟关系，那条相对路径在
镜像里天然成立——node 半边不需要知道 App bundle 在哪（它本来也不知道）。
**源码在 bundle 里只有这一份**：预编译流水线也读它，"编的就是发的"因此是结构性的。

装哪些包**以 `surfclam/cordis.patch.yml` 为准**（编排表是唯一真相），注释掉的行不算。
module 名**不自己算**，用 `clam-bridge/lib/module-name.js`——桥登记时算出的名字与预编译
产物的目录名必须逐字一致，否则壳按 module 名去 bundle 里找永远落空，而且是静默落空。
打进去的 `package.json` 改两处：`version` 对齐 `MARKETING_VERSION`（只改 bundle 里那份
拷贝），`bin` 字段删掉（那是开发者的安装器入口，不随分发走；留着而文件不在，pnpm 每次
跑都会刷一行建 `.bin` 垫片失败的 WARN）。

载荷里还夹一个 `swift/.clam-static` 标记：「这份源码是分发载荷，进程活着的时候不会变」。
桥见到它就**只在登记那一刻扫一次、不做 500ms 轮询**——否则正式形态下会对一个签过名的
bundle 持续做约 1 MB/s 的热读循环，而那份源码永远不会变。它不是 `.swift`，
所以既不进桥的扫描结果也不进任何 contentHash。

### 1.2 版本只有一个

三半边同一个 bundle，**版本握手问题因此消失**：`Info.plist` 的 `MARKETING_VERSION` 是
唯一权威，`ClamNode/*/package.json` 构建时全部对齐，⌥⌘D 显示的也是它。不需要"壳与插件
版本不匹配"的检测——它们不可能不匹配。**别把版本号生成进 `project.yml`**：
`host-build/source-hash.js` 把它算进源码 hash，那样每次 commit 都触发壳的全量重建。

---

## 2. profile 自举

App 首次打开时把 `Contents/Resources/ClamNode/` 拷进
`~/.dsh/profiles/surfclam/.surfclam/`，并手写 `link:` 行与符号链接。实现是
`clam-app/host/Sources/Native/ProfileBootstrap.swift`，**只在 Release 壳跑**
（Dev 壳的 profile 由 `./dev` 自己备，link 的是仓库源码）。

`surfclam` 这个 profile 名**归安装形态专属**：开发一律带后缀（主 worktree
`surfclam-dev`，侧 worktree `surfclam-<目录名>`），于是"装好的那套日常用 + 主 worktree
开发"天然并存，两份 endpoint 发现文件互不覆盖。这条规则比从前那条好讲——
「主 worktree 特殊」的例外没了。

### 2.1 为什么是拷贝，不是把 `.app` 链进 profile

**node 默认把符号链接解析到 realpath。** 链进去的话模块查找锚点落在 `.app` 内部，逐级
向上找 `node_modules` 一路到 `/` 都碰不到 `~/.dsh/profiles/node_modules/` 底下那一百多个
`@deepseek-ai/*`，于是 `ERR_MODULE_NOT_FOUND`。拷进 profile 内部之后 realpath 落在
`.surfclam/` 里，向上查找**天然经过**那个目录。拷贝还额外买到三样：`.app` 是只读的而
pnpm / dsh 可能想往包目录写；App 被删掉时后端仍起得来（退化成「缺 App 形态」而不是启动
失败）；镜像目录里可以放我们自己的 `.stamp`。

相关的一条：**`bundles` 里必须是包名而不是绝对路径**。dsh 的 `resolveBundleDir` 走
`resolve.paths(name)`，那个 API 只返回 `node_modules` 目录，拼绝对路径进去永远不存在。
伞包必须是个 node 解析得到的真包——镜像方案正好满足。

### 2.2 五步，全部增量确保

1. **profile 骨架**——不在就按 dsh 自己 `initProfile` 的模板建三样文件（`package.json` /
   `cordis.patch.yml` / `pnpm-workspace.yaml`）。**绝不写 `cordis.yml`**：dsh 每次启动都
   无条件重写它，我们写了也是白写。
2. **迁移检查**（先于任何写盘）——我们那几行的 link 目标指到 `.surfclam/` 以外去了 =
   这个 profile 是别的形态留下的。**停下来报出去，不覆盖**：覆盖等于把开发者的仓库从
   运行链上摘掉，症状是"我明明在改代码，怎么一点反应都没有"。
3. **镜像**——`ditto` 到 `.surfclam.incoming/` 再原子换代（换不上就把旧的放回去，半个
   镜像比旧镜像糟得多）。整体换而不是就地合并：上一版打进去、这一版不再在册的包必须消失。
   判据是镜像根上的 `.stamp`（`{appVersion, appPath, sourceHash}`，`sourceHash` 直接取
   `ClamPayload.json` 里那个 hash），对得上就一个字节都不动。**不能用 mtime 当判据**——
   `ditto` 连同源目录的 mtime 一起拷，而 bundle 里那个目录的 mtime 停在它被创建的那一刻。
4. **`package.json`**——给每个镜像里的包补一行 `link:./.surfclam/<pkg>`，并把
   `dsh.profile.bundles` 补齐成那三行（`dsh-base` + `dsh-web-app` + 伞包）。
   **`dsh-web-app` 必须手动列**（dsh 的 `PROFILE_TEMPLATES` 只给 `web` / `headless` 配了
   模板）；**被编排的插件绝不能出现在 `bundles` 里**（它们没有 `dsh.bundle` 声明，
   列上去 `loadProfile` 当场 fails loud）。
5. **符号链接**——`<profile>/node_modules/@wenbo/<pkg>` → `../../.surfclam/<pkg>`。
   相对目标要从**链接所在目录**数回 profile 根：多数一层是个安静的错，链接指到
   `profiles/` 去，`ls -l` 看着完全正常而 node 解析不到，于是 `dsh plugin add` 的
   reconcile 把解析不到的伞包从 `bundles` 里摘掉，全程无人报错。判据不是看 `ls`，
   是 `node -e 'import("@wenbo/surfclam")'`。

`$DSH_HOME` **必须经 login shell 问一遍**：GUI App 继承的环境里没有用户的 `.zprofile`，
而我们 spawn 的那个后端走的正是 `zsh -lc`——两边算出不同的 home 就会自举到一个没人读
的目录去，而且完全不报错。

### 2.3 为什么不调 pnpm

**pnpm 对 `link:` 依赖不写 lockfile 条目**（本地链接没有版本可锁），所以我们加 `link:`
行而不碰 `pnpm-lock.yaml`，在 pnpm 眼里根本不算"不同步"。之后用户跑 `dsh plugin add` /
`pnpm install` / 甚至 `--frozen-lockfile`，手建的链接都原样保留。这顺带消掉了"GUI App
的 PATH 里找不到 pnpm"这一整类问题。**但第 4 步不能省**：pnpm 会 prune 掉
`package.json` 里没有的 `node_modules` 条目；写了它，用户误跑 pnpm 时才是**重建**同样的
布局，而不是删掉我们的链接。

### 2.4 三条纪律

用户往这个 profile 里加的东西必须活下来：

1. **只读-改-写我们那几个 key 和 `bundles` 那三行**，绝不整体重写 `package.json`——
   用户 `dsh plugin add` 的依赖跟我们那几行躺在同一个 `dependencies` 对象里。保序保缩进：
   所以 `ProfileBootstrap` 自带一个保序的 JSON 编解码，而不是无序的 `JSONSerialization`。
2. **绝不碰 `<profile>/cordis.patch.yml`**——那是 dsh 给用户的 patch 层，叠在我们的编排表
   之上，用户可以用它 disable 我们任何一个插件。只有"profile 整个不存在"时才建一份空的。
3. **对不上就 fails loud，不要"修复"回默认**。失败被翻成
   `BackendManager.Unavailable.bootstrapFailed` 摆到连接页上，不静默降级。

**自举必须排在 spawn 之前**：镜像不在位时后端会因为 `ClientPackageCompositionError`
整个起不来，顺序反了就是必崩。

---

## 3. 壳不构建自己，判据是结构性的

**构建那一整套代码不随包分发。** 它住在 `clam-app/host-build/`（`index.js` +
`source-hash.js`），而 `clam-app` 的 `files` 白名单只收 `lib/`，`ClamNode/` 载荷也只拷
`lib/` 与 `swift/`（`npm pack --dry-run` 实测 20.2 KB / 4 个文件；收 `host/` 那几项是
2.8 MB，不设白名单的话 `host/build` 一个人就 393 MB）。

判据因此**不是"探一下 `host/` 在不在"，更不是任何旋钮，而是"`host-build/` 这个模块
import 得到吗"**（`clam-app/lib/index.js` 顶层的 `hostBuild` 常量）。拿不到就是这份
clam-app 没有构建能力：`build` / `watch` / `restartOnRebuild` 一律关掉，只剩"探测既有
产物 + 写 endpoint 发现文件 + provide `clamApp`"。只有"模块不在"
（`ERR_MODULE_NOT_FOUND`）才算降级——语法错之类如实报出来再降级，开发期真写坏了
`host-build/` 应当是一行响亮的日志，而不是"构建怎么不跑了"。

**为什么必须是结构性的**：发布的 App 是 Developer ID 签名 + 公证过的。它自己
`xcodebuild` 重建自己产出的是 **ad-hoc 签名**，当场把自己从"公证过"降级成"来路不明"，
Hardened Runtime 与 entitlements 随之对不上，于是**所有热插件突然装载失败**——而症状
完全不像签名问题。正式形态根本不该有"要不要构建"这个开关，而不是有一个默认关掉的开关：
曾经的环境变量 `CLAM_RELEASE` 就是那种开关，缺了它 clam-app 会按 dev 形态跑，构建 Debug
产物、再拉起一个 Surfclam Dev——于是双击 `/Applications` 里的 Release 却多出一个 Dev
窗口。**现在这个失败模式在结构上不可能了**：镜像里没有 `host/`。

顺带把两件事分清楚，它们曾被同一个 `hasXcode()` 当成一个总开关：**壳自构建**要完整
Xcode（十几 GB）、产出一个签名实体，正式形态下**不存在**；**插件热编译**只要 Command
Line Tools、产出一个 dlopen 进来的 dylib，保留但用预编译产物绕开（§4）。`launch` 那一项
**不跟着关**：正式形态下 App 早就在跑（后端正是它 spawn 的），`launch()` 自己会因
`isRunning` 跳过；而用户手动 `dsh --profile surfclam` 时，把装好的 App 带起来正是他要的。

---

## 4. 预编译 dylib：本机 swiftc 退居开发期

**正式用户不该需要任何 Swift 工具链。** 内容寻址缓存的机制本来就在
（`Native/CompilerService.swift`）——只要 bundle 里那份 dylib 的 contentHash 与壳在用户
机器上算出来的一致，壳就直接 `dlopen`，一次 swiftc 都不跑。查找顺序
（`NativePluginHost` 构造 `CompilerService` 时定的 `searchRoots`）：

1. **用户缓存** `<AppSupport>/native-plugins/generations/<Module>/<hash12>/`
2. **bundle 内预编译** `Contents/Resources/ClamPlugins/<Module>/prebuilt/<hash12>/`
3. **现场编译**（写回用户缓存）

**用户缓存排第一**：用户自己改了插件源码、壳现场编出来的那一份，必须赢过 bundle 里随
分发走的默认实现；正式形态下它本来就是空的，第一轮就落到预编译上（`CompiledPlugin.Origin`
三档 `.cache` / `.prebuilt` / `.compiled` 会记进日志与 ⌥⌘D，「零编译启动」的证据就是那
一栏）。现场编译此后是**可选能力**而不是启动前提：没有工具链时缺的是"这一个插件的原生
半边"（`CompileError.noToolchain`），不是整个原生侧；而这个探测只在真要编译之前才做。

### 4.1 两边算出的 hash 必须逐字相同

整件事的成败只有这一条，所以预编译流水线（`scripts/prebuild-plugins.mjs` +
`scripts/prebuild/Prebuild.swift`）**一处都不重算**：桥那半边的 hash 调
`clam-bridge/lib/swift-payload.js` 的 `swiftContentHash`（与桥同一份代码）；壳那半边的
hash 与全部 swiftc 参数交给 `scripts/prebuild/` 那个工具，**它把壳自己的
`Native/CompilerService.swift` 原样编进去**，不是第二个编译器；`swiftDeps` /
`sharedModules` / `schemaVersion` 靠 `import` 各插件的 node 半边读 `clamSwift`
（**静态解析源码是不行的**）；源码读**打包进 bundle 的那一份**，不读仓库。

抄一份"构建期专用的编译逻辑"会得到一个静默的失败模式：两边算出的 hash 差一点，退回
现场编译，而用户机器上多半根本没有 swiftc——症状是"插件全部缺席"，而两边的代码看着
都对。同一个道理管着两条硬约束：**contentHash 里不能有本机 `swiftc --version`**
（那个值构建机与用户机必然不同；工具链变了的信号改由随 bundle 走的
`ClamSDK.swiftinterface` 摘要承担——**真相取自随 bundle 走的文件，不取自本机环境**，
这是这里的通则）；**rpath 必须是相对的**（共享 module 走 `@executable_path/../Frameworks`，
插件间依赖走 `@loader_path/…` 按真实相对位置算；绝对 rpath 会让搬走的产物**悄悄回连
构建机的树**，而且在构建机上装载成功、换一台机器才炸）。

因为这些失败模式太贵，**两个 Release 脚本一律 fails loud，不优雅缺席**：Xcode 的 build
phase 继承的是启动 `xcodebuild` 那个进程的 PATH，从 Finder 起的 Xcode 里可能没有 node，
找不到就退出而不是跳过。缺了载荷或预编译产物的 Release 是个坏包，装到用户机器上表现为
"插件全部缺席"，而后端照常起、没人会去看构建日志。

---

## 5. 签名与公证

流水线是 `scripts/release-dmg.sh`，产物全落 `build-dist/`——**不碰 `/Applications`，
也不碰 `build/`**：用独立的 `derivedDataPath` 既保证开发形态那份 ad-hoc 的 Release 产物
不被覆盖，也顺带保证 `CodeSign` 阶段必然真的跑一遍。它**不做任何事后重签**（那会破坏
Xcode 已封好的印，还会把身份 / entitlements 复制出第二份），只负责把身份和三个开关递给
`xcodebuild`、验、打包、签 dmg：

```
CODE_SIGN_IDENTITY=<Developer ID Application: …>
ENABLE_HARDENED_RUNTIME=YES              ← 公证的前提
CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO    ← 摘掉 get-task-allow（公证直接拒它）
OTHER_CODE_SIGN_FLAGS=--timestamp        ← 外层也要 secure timestamp
```

命令行传的 build setting 优先级高于 `project.yml` 里的一切，所以**开发形态一个字都不受
影响**——不然每台机器都得有那张 Developer ID 证书才编得动。

### 5.1 嵌套代码必须单独签，身份要和外层一致

公证会递归检查 bundle 里每一个 Mach-O，**外层 Developer ID、内层 ad-hoc 的包直接拒收**。
眼下有六个：一个 `libClamSDK.dylib` 加五个插件 dylib。两处都在构建过程中就地签好，
身份都取 Xcode 解析出来的同一个 `EXPANDED_CODE_SIGN_IDENTITY`：`libClamSDK.dylib` 由
`embed-modules.sh` 拷进去之后立刻签；插件 dylib 由 `prebuild/Prebuild.swift` 在
**`strip -x` 之后**签（strip 会把签名打掉重盖，顺序不能反），而且**每一轮都签，不管是刚
编的还是命中缓存复用的**——增量构建里绝大多数插件都是复用，只签新编的那些就等于发出一个
内层身份混杂的包。两处都在 Hardened Runtime 开着时补 `--options runtime`，ad-hoc 时显式
`--timestamp=none`（ad-hoc 拿不到 secure timestamp）。

**inside-out 是结构性的，不需要也不许再签外层**：Xcode 的 `CodeSign` 阶段排在**全部
postBuildScripts 之后**，封外层时把这些 dylib 的 cdhash 一起封进去，往 `Resources/` 里塞
东西因此不破坏封印。任何"事后补签外层"都是活陷阱——它把身份写死，阶段一旦被重排就
**静默把整个 App 降级成 ad-hoc**。`release-dmg.sh` 那边做的是**验收而不是签名**。

### 5.2 entitlements 只能改在 `project.yml` 里

`xcodegen generate` 每次都会照 `targets.surfclam.entitlements.properties` 那张表重写
`Sources/surfclam.entitlements`——**手改那个文件是静默丢失的**。

**只有一份 plist，Debug 与分发的差别由注入决定**：`get-task-allow` 从来不写在表里，
它是 `CODE_SIGN_INJECT_BASE_ENTITLEMENTS` 在身份为 `-` 时替我们注入的；开发形态照旧拿
得到它（能挂调试器），分发形态由 `release-dmg.sh` 传 `=NO` 摘掉。维护两份内容相同、
只差一个注入项的 plist 只会让它们互相漂移。表里两条：

| entitlement | 为什么 |
|---|---|
| `com.apple.security.app-sandbox: false` | 要 spawn node 子进程并读写 Application Support |
| `com.apple.security.cs.disable-library-validation: true` | **热插件机制的存亡所系**。Hardened Runtime 默认打开 library validation，dyld 拒绝 `dlopen` 不是同一 Team ID 签名的 dylib——而壳在用户机器上现编出来的插件正是这种（linker 给的 ad-hoc 签名）。控制组实测过：摘掉它，五个现场编译的插件**全部 dlopen 失败**，而 dyld 的报错一个字都不提 "library validation"，只说 `different Team IDs` |

`release-dmg.sh` 收尾会把这两条各验一次（有没有前者、还有没有 `get-task-allow`），
外加逐个查嵌套 dylib 的 `Authority=Developer ID Application` 行，任一不对当场退出。

### 5.3 写 bundle 的构建脚本必须声明 `outputFiles`

这是一条结构性约束，不是洁癖。不声明的后果**间歇性、而且正好砸在发布那一步**：Xcode 的
依赖图里没有那些文件，于是当壳的可执行文件本身没变时（**只改了插件的 node/swift 半边就是
这种情况，而那正是日常**），`CodeSign` 阶段被判定为不必重跑——可脚本每一轮都跑、每一轮
都改 bundle 内容，封印就此过期。症状是 `BUILD SUCCEEDED` 一切正常，`codesign -v` 才报
`a sealed resource is missing or invalid`，而**公证直接拒收这种包**。

声明各自的代表性产物就够了：三个 postBuildScripts 各一条 `libClamSDK.dylib` /
`ClamPayload.json` / `ClamPrebuilt.json`。验的时候**别用 clean build**（那必然重签、
测不出来）：改一个插件的 `.swift` 再构建，看日志里有没有 `CodeSign`。

### 5.4 公证要做两次，staple 两处，顺序不能换

先把 **app** 交公证（`ditto -c -k --keepParent` 成 zip 提交——zip 只是运输容器，**本身
不能 staple**）→ staple 那个 `.app`；然后拿**已经 staple 过的 app** 打 dmg → 签 dmg →
交公证 → staple dmg。反过来是做不到的：stapler 按 **cdhash** 取票，改了 app 就等于换了
一个 dmg，之前那张票对不上号。提交一律带 `--wait --timeout 2h`。

**没有公证凭据时脚本非零退出**（除非显式 `--skip-notarize`）：未公证的 dmg 在别人机器上
会被 Gatekeeper 拦下，只在本机能用——不让"忘了公证"混成一次成功的发布。**验收必须在一台
没有开发者证书的机器（或清干净的用户）上做**，本机的 keychain 会让一切显得正常。
缺任何一环的症状是「已损坏，无法打开」，那句文案会让人以为是下载坏了；而
`spctl --assess` 报 `source=Unnotarized Developer ID` 反而是个好症状——签名链是对的，只缺票。

---

## 6. dmg

用 `dmgbuild`（`pip install dmgbuild`），设置文件 `scripts/dmg-settings.py`：一个 App
图标加一条 `/Applications` 符号链接，背景用它自带的箭头。选它是因为它**直写 `.DS_Store`、
不驱动 Finder**，版式又全可配。**两行是硬要求，不是口味**：

```python
filesystem = "APFS"
format = "ULFO"
```

dmgbuild 的默认还是 HFS+ / UDZO，而现代 macOS（以及将来接自动更新用的 Sparkle）都要
APFS / ULFO。写死在设置文件里，命令行不必记。打完之后
`codesign --force --timestamp --sign <identity>` 签它，再走 §5.5 的第二轮公证。

---

## 7. 两个 App 形态并存

Debug 与 Release 是两个不同的 App，可以同时跑：

| | Debug（日常开发） | Release（正式） |
|---|---|---|
| `PRODUCT_NAME` | Surfclam Dev | Surfclam |
| Bundle ID | `io.wenbo.surfclam.dev` | `io.wenbo.surfclam` |
| 图标（`APP_ICON_NAME`） | `AppIconDev`（橙色 DEV 徽章） | `AppIcon` |
| 位置 | `clam-app/host/build/Build/Products/Debug/` | `/Applications/` 或 `build-dist/` |
| 载荷与预编译 | 无（脚本 `exit 0`） | 有 |
| profile 自举 | 不跑 | 跑 |
| profile | `surfclam-dev` / `surfclam-<worktree>` | `surfclam` |
| 签名 | ad-hoc，Hardened Runtime 关，自动带 `get-task-allow` | Developer ID，Hardened Runtime 开 |

**判 Dev 一律看 `Bundle.main.bundleIdentifier` 的 `.dev` 后缀，不要用 `#if DEBUG`**——
这个工程的 `project.yml` 从来没设过 `SWIFT_ACTIVE_COMPILATION_CONDITIONS`，所以连 Debug
产物里 `#if DEBUG` 整块都不存在。`<AppSupport>/io.wenbo.surfclam/` 是两者共用的（endpoint
发现文件由后端写，两个构建都要读到同一份），所以那底下的东西都按实例分片，
详见 [`connection.md` §5](connection.md)。

`./release` 装机走 `scripts/build.sh`，收尾会写下 clam-app 认的那份源码 hash marker
（算法的唯一真相是 `host-build/source-hash.js`）。不记的话开发形态的后端一起来就发现
marker 与源码对不上，把刚装好的这份原样再编一遍，还会朝用户的窗口挂一条「壳有新版本」。

---

## 8. 缺 App 形态：优雅缺席

这条不只在"用户删了 App"时触发：镜像里的 `swiftDir` 一旦不在，后端会在 `register()`
那一步**整个起不来**。两条一起兜——`swift/` 也打进镜像（§1.1），并且**桥的
`register()` 三条 fails loud 里只放开 `swiftDir` 那一条**，改成返回一个空壳 handle 加
一句 warn。放开它的理由是它的**前提变了**：从前 swiftDir 一定在仓库里，现在它可能随
App 一起消失。另外两条（module 名非法、重复登记）前提没变，仍当场抛——名字与编排表都在
作者手里，错了就是配置错误。

壳侧同理：clam-app 拿不到产物时只留一句「未找到可用的 `<配置>` 产物，clam-app 优雅缺席
——dsh 照常服务浏览器」，然后照常写 endpoint 发现文件。首次构建失败**不重试、不成环**
（防的是构建风暴）。**三个地方反而必须 fails loud**：Release 的两个打包脚本找不到 node
（产出的是坏包）；profile 自举的任何一条纪律被触碰（静默"修复"等于把仓库从运行链上摘
掉）；桥登记的另外两条。

`./release` 装完会查一句 `Contents/Resources/ClamNode/` 在不在，**只警告不拦**：缺了它
App 自举不出插件——症状是"起来了，但界面上什么原生东西都没有"。排错的落点是
`<AppSupport>/io.wenbo.surfclam/logs/clam-app-build.<profile>.<配置>.log`。

---

## 9. 已知边界

- **尚无自动更新机制**：装好的 App 不会自己发现新版本，换版本靠重新下载 dmg
  （或在仓库里跑一次 `./release`）。发布流水线也还在本机跑，不在 CI 上。
- **dsh 的版本探测不出来**：它没有 `apiVersion` / `protocolVersion`，`host.describe()`
  返回硬编码的 `"0.0.1"`。所以只检测"在不在"，不检测"对不对"——**钉版本不是双保险，
  它就是全部机制**。dsh 升级后最先断的也不是服务层，是那些 hash 化 CSS 选择器。
- **`generations/` 只增不删**：用户缓存排在预编译之前，磁盘会缓慢长胖。contentHash 保证
  不会用错代码，但没有人清理旧代。
- **部署目标钉死 `macOS 27.0`**，SDK 较旧的机器编不过。
- **卸载拦截不到**：用户把 App 拖进废纸篓时，`~/.dsh/profiles/surfclam/` 与
  `<AppSupport>/io.wenbo.surfclam/` 都会留下。会话与设置是 dsh 的资产，一律不动；
  镜像与插件缓存是纯产物，可以清。只提供 `./release --uninstall` 与文档里的手动路径，
  **不为此写守护进程**。
