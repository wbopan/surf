# surfclam 分发形态重构：App 成为唯一分发单元

> 计划文档，2026-08-30。执行日志见 §9。
>
> **一句话**：`/Applications/Surfclam.app` 变成签名公证过的唯一分发实体，
> 三半边（node / client / swift）全部随它分发；`~/.dsh/profiles/surfclam` 退化成
> App 启动时的一次幂等自举；npm 那条路只留给开发者。
>
> **本轮不做自动更新**（用户 2026-08-30 裁决：「自动更新可以后加」）。
> Sparkle 是 §8 的最后一个里程碑，本轮只**留好它需要的接口**（版本号、
> bundle 布局、"换了 App 必须重启后端"那条链），不实现。

## §0 目标与非目标

### 目标

一条用户路径，三步，没有第四步：

1. 装 dsh（`npm i -g @deepseek-ai/dsh`）——**这一步我们不接管**；
2. 下载 `Surfclam.dmg`，拖进「应用程序」；
3. 双击。

双击之后发生的事全部由 App 负责：自举 profile、spawn 后端、装载插件、开窗口。
**用户机器上不需要 Xcode、不需要 Command Line Tools、不需要 pnpm 会不会在 PATH 上
这类问题、不需要知道 profile 是什么。**

### 非目标

- **不做自动更新**（本轮）。留接口，见 §8 M6。
- **不接管 dsh 的安装与版本**。我们只是它的壳；把 dsh 塞进 App bundle 意味着开始管
  它的版本和更新，与仓库一贯立场冲突。App 检测不到 dsh 时给一行命令，不代劳。
- **不再是「一个 profile」**（用户 2026-08-30 裁决推翻旧决策，见 §3.6）。
  `surfclam` 收窄成**安装形态专属**，开发形态一律带后缀。会话与设置仍然全局，
  所以分片没有数据代价。
- **不动开发形态**。`./dev` 跑起来的东西和今天逐字一样：link 仓库、本机 xcodebuild
  Debug 壳、Swift 存盘热替换。这次重构对开发循环应当是**零感知**的。
- **不做跨平台**。

## §1 现状事实清单（动手前核对；与源码冲突以源码为准）

### 1.1 今天有两条分发路径，各自都得别扭地管另一半

| | 装什么 | 另一半怎么来 | 病灶 |
|---|---|---|---|
| `npx @wenbo/surfclam`（registry 模式） | 9 个 npm 包进 profile | clam-app 插件**在用户机器上 xcodebuild** 出 App | 需要完整 Xcode（十几 GB）+ PATH 上的 `xcodegen`；两者缺一就**优雅缺席**——dsh 起、HTTP 200、壳一声不响地不存在 |
| `./release`（本机安装） | 同上，但只许主 worktree | `build.sh` 构建 Release 壳装进 `/Applications` | 被定义成开发者动作，registry 模式直接 fails loud（`surfclam.js:435`） |

两条路都要求「先有 dsh 跑起来，才可能有 App」。而 2026-08-30 daemon 退役之后，
**日常使用的方向已经反了**：用户双击 App → 壳按连接偏好 `managed` 自己 spawn 后端。
`CLAM_RELEASE=1` 把那个后端里的 clam-app 降级成「只写一份 endpoint 发现文件」
（`build:false / watch:false / launch:false`），所以不存在循环拉起。

**本计划就是把这个既成事实扶正**：App 是入口，后端是它的子进程，构建 App 不再是
运行期的一环。

### 1.2 实测确认的硬事实（2026-08-30，可复跑）

> 复跑脚本的形状见本节，都是十几行 node，不依赖仓库。

**事实 A：把 node 半边留在 .app 里、profile 只放一条指向它的符号链接——行不通。**

```
ERR_MODULE_NOT_FOUND: Cannot find package '@deepseek-ai/dsh-llm'
  imported from …/FakeApp.app/Contents/Resources/ClamNode/clam-sidebar/lib/index.js
```

node 默认把符号链接解析到 **realpath**，模块查找的锚点因此落进 `.app` 内部，
逐级向上找 `node_modules` 一路找到 `/` 都碰不到 `~/.dsh/profiles/node_modules`
那 187 个 `@deepseek-ai/*`。`node --preserve-symlinks` 能救（实测通过），
但那是个改变**整个 dsh 进程**模块解析语义的启动 flag，不采用。

**这个失败模式很晚才暴露**：`dsh plugin add` 过、`--dump-config` 过、真 `import`
时才炸——和 CLAUDE.md「dsh 与插件布线」里记的那条前科一模一样。

**事实 B：把镜像拷进 profile 内部，解析链天然正确，而且比今天的 `./dev` 更干净。**

```
~/.dsh/profiles/surfclam/
  .surfclam/clam-layout/…                      ← 壳从 .app 拷来的镜像
  node_modules/@wenbo/clam-layout → ../../.surfclam/clam-layout
```

实测全过：包能 `import`、包内的 `@deepseek-ai/dsh-llm` 能解析、
`createRequire(profile目录).resolve("@wenbo/clam-layout/package.json")` 返回 realpath、
client 半边的 `join(dirname(pkgPath), "./lib/client.js")` 推导正确。

命中的原因是 realpath 落在 `~/.dsh/profiles/surfclam/.surfclam/…`，向上查找
**天然经过 `~/.dsh/profiles/node_modules`**。推论：**`./dev` 今天那条补丁符号链接
（`ensureModuleResolution` 往仓库根塞的 `node_modules`）在新形态下不需要**。

### 1.3 dsh 侧的机制事实（2026-08-30 调查，源码为证）

1. **client 半边没有 bundler。** `@deepseek-ai/dsh-client-modules` 是运行期增量扫描：
   `ctx.on("internal/plugin", …)` 收集挂载的 entry（`lib/index.js:272-303`），
   用 `createRequire(profile目录).resolve(pkg + "/package.json")` 定位包，
   再 `join(dirname(pkgPath), exports["./client"])` 拼出文件路径，
   `readFile` 原样吐给浏览器（`lib/index.js:377-404, 459-490`）。
   **无 esbuild / rolldown / vite**。所以镜像里的 `lib/client.js` 直接被读，
   不需要任何构建步骤。
2. **`exports["./client"]` 是裸 `join`，没有包含性检查**——理论上可以指向包外。
   本计划不用这条（事实 A 说明它救不了模块解析），但它解释了为什么镜像方案里
   client 半边不需要特殊处理。
3. **`bundles` 清单只认包名，绝对路径硬阻断。** `resolveBundleDir`
   （`dsh-app-boot/lib/index.js:518-524`）走 `createRequire(anchor).resolve.paths(name)`，
   那个 API 只返回 `node_modules` 目录，`join(searchPath, "/abs/path")` 永远不存在。
   **所以伞包 `@wenbo/surfclam` 必须是个 node-resolve 得到的真包**——镜像方案正好满足，
   **`cordis.patch.yml` 一字不改**。
4. **entry 的 `name` 反而完全敞开**：`isAbsolute(name) ? pathToFileURL(name).href : name`
   （`dsh-app-boot/lib/index.js:965-967`），上游明确预期绝对路径 entry。
   本计划不用，记在这里是因为它是 §7 回滚路径的一条备选。
5. **client bundle 的初次读取在 dsh activation 时**；产物不在位会聚合成一次响亮的
   `ClientPackageCompositionError`（`dsh-client-modules/lib/index.js:104-118, 291-294`），
   **整个 dsh 起不来**。→ 自举必须**先于** spawn 后端完成，见 §3.5。
6. **client bundle 的 `rev` 是 activation 时算的内容 hash，`cache-control: no-cache`**
   （`lib/index.js:147-150`）。而 web bundle 下 node 侧 HMR 被无条件关掉
   （`dsh-web-app/cordis.patch.yml:21-23`）。→ **换了 App 必须重启后端**，
   只重启 App 不够。这条直接决定 §8 M6（自动更新）的形状。
7. **`dsh plugin add` = 在 profile 目录里跑 `pnpm add` + `reconcilePlugins`**
   （`dsh/lib/plugin-9h8shc4d.js:102-127`）：包里声明了 `dsh.bundle` 就自动进
   `bundles`，没声明就只当普通依赖并 warn。**这是用户加插件的正路，我们必须与它共存。**
8. **`~/.dsh/profiles/plugins` 不存在**——dsh 没有这个约定。用户自定义的两个入口是
   `dsh plugin add --profile surfclam` 和 `~/.dsh/profiles/surfclam/cordis.patch.yml`
   （后者文件头自称 "Your patch layer for this dsh profile, applied after every
   bundle layer"，**叠在我们的编排表之上，可以 disable 我们任何一个插件**）。
9. **dsh 没有任何版本协商机制**：无 `apiVersion` / `protocolVersion`，
   profile loader 版本盲（peerDependency 的 range 从没被解析过），
   `host.describe()` 返回硬编码的 `"0.0.1"`——**从 wire 上探测不出 dsh 版本**。
   上游自己的注释写着 *"introduce protocolVersion only when an independently
   released client appears"*。**surfclam 正是那个 client**；这条已记进
   `docs/internals/dsh-upstream-gaps.md`。钉版本 `@deepseek-ai/dsh@0.1.1-rc.2` 不是双保险，
   **它就是全部机制**。

### 1.4 「壳自构建」与「插件热编译」是两件事，必须分开处理

常被混为一谈，但差得很远：

| | 壳自构建 | 插件热编译 |
|---|---|---|
| 工具 | `xcodebuild` | `swiftc` |
| 门槛 | **完整 Xcode**（十几 GB） | **Command Line Tools**（`xcode-select --install`；本机实测 `/Library/Developer/CommandLineTools/usr/bin/swiftc` 存在） |
| 耗时 | 几十秒～几分钟 | 1~3 秒，且有内容寻址缓存 |
| 产出 | 一个**签名实体** | 一个 dlopen 进来的 dylib |
| 本计划 | **正式形态下彻底删除**（§3.3） | **保留**，但正式形态下用预编译产物绕开（§3.2） |

`clam-app` 里 `hasXcode()` 那道门控查的是 `xcodebuild`，管的是前者；
它今天被当成「有没有原生能力」的总开关，是一处概念混淆。

## §2 目标形态

### 2.1 App bundle 布局

```
/Applications/Surfclam.app/Contents/
  MacOS/Surfclam
  Frameworks/
    libClamSDK.dylib                    壳与插件链接的同一份（类型身份）
  Resources/
    ClamModules/                        ClamSDK 的 .swiftmodule / .swiftinterface
                                        （插件编译时 -I 的落点，今天已存在）
    ClamNode/                           ← 新增：node 半边的分发源（拷贝源）
      surfclam/                           package.json + cordis.patch.yml（伞包）
      clam-bridge/                        package.json + lib/
      clam-layout/                        package.json + lib/（含 client.js）+ swift/
      clam-sidebar/  clam-notify/  clam-settings/  clam-nativeify/  clam-memory/
      clam-app/                           package.json + lib/（**不含 host/**）
    ClamPlugins/                        ← 新增：预编译产物（原地用，不拷）
      ClamLayout/prebuilt/<hash12>/{libClamLayout_h<hash12>.dylib, .swiftmodule, .swiftdoc}
      ClamSidebar/ ClamNotify/ ClamSettings/ ClamNativeify/
    ClamPrebuilt.json                   预编译清单（人看的；壳按 hash 直接找路径）
    BuildTimestamp.txt                  （已存在）
```

> **M3 改了两处（2026-08-30）**：①**Swift 源码住在 `ClamNode/<pkg>/swift/`，
> 与 `lib/` 平级**，不再单独放一份进 `ClamPlugins/<Module>/sources/`；
> ②`ClamPlugins/` 因此只剩 `prebuilt/`。理由见 §3.2a。**bundle 里只有一份源码**，
> 预编译流水线读的也是它——"编的就是发的"从此是结构性的，不靠默契。

**`ClamNode/` 里的目录结构与仓库根一一对应**，因为 clam-* 之间用相对路径 import
（`../../clam-bridge/lib/plugin.js`）——保持兄弟关系，那些 import 原样成立。

**体积预算**（2026-08-30 实测，决定这个布局可不可行）：

| | 大小 | 备注 |
|---|---|---|
| 今天的 Release `Surfclam.app` | 3.7 MB | 对照基线 |
| `ClamNode/`（9 个包的 `lib/` + `package.json` + 5 份 `swift/`） | **860 KB** | 拷进 profile 的就是这些，拷贝成本可忽略 |
| `ClamPlugins/*/prebuilt/`（单代 dylib，未 strip） | 5.33 MB | ClamSettings 3.05 MB + ClamSidebar 1.27 MB 占了大头 |
| 同上，`strip -x` 之后 | **2.53 MB** | 5457 KB → 2653 KB |
| `ClamPlugins/` 里的 `.swiftmodule` / `.swiftdoc` / `.abi.json` | 0.58 MB | 下游插件真要现场编译时 `-I` 指向它们，留着 |

**M3 之后实测：`/Applications/Surfclam.app` = 7.90 MB**（表观大小，`du` 报 8.2 MB）。
预算 7.5 MB，超 5%，来源是上表最后一行（原预算没算 `.swiftmodule`）。
dmg 压缩后仍在 3~4 MB 量级。

> **`strip -x` 已验证通过，定案：做**（2026-08-30 实测，原"待验证"作废）。
> 五个 dylib 合计 5457 KB → **2653 KB**，而五个都照常 `dlopen` +
> `dlsym clam_plugin_entry` + 调入口拿到插件对象——在一个**搬到 `/tmp` 的假 bundle**
> 里验的（纯靠 `@loader_path` 解析上游，不预装依赖也成功）。签名也没坏：
> `strip` 会把 linker-signed 的 ad-hoc 签名重新盖一遍，`codesign -v` 仍是
> "valid on disk"。实现在 `scripts/prebuild/Prebuild.swift` 的 `stripLocalSymbols`。
>
> **同一处顺手扔掉两样只对构建机有意义的东西**：`.dSYM`（`swiftc -g` 的副产物，
> 五个加起来 **16 MB**，比 dylib 本身大三倍，运行期一字节不读）与
> `.swiftsourceinfo`（IDE 跳转用，而且里面写着构建机上的源码绝对路径
> ——那不该跟着分发包出门）。

**`ClamPlugins/` 不拷进 profile**：那里只有预编译产物，壳直接按 contentHash
去 bundle 里找（`CompilerService.ProductRoot.prebuilt`）。
**`swiftDir` 则一路跟着镜像走**，指向 `<profile>/.surfclam/<pkg>/swift/`——
node 半边不需要知道 App bundle 在哪（见 §3.2a）。

### 2.2 profile 自举（壳做，在 spawn 后端之前）

```
~/.dsh/profiles/surfclam/
  .surfclam/                    ← 壳维护的镜像，内容 = ClamNode/ 的拷贝
    .stamp                        {appVersion, appPath, sourceHash}
    surfclam/ clam-bridge/ clam-layout/ …
  package.json                  dependencies 多出我们那 N 行 link:./.surfclam/<pkg>
                                dsh.profile.bundles 含那三行
  cordis.patch.yml              ← **用户的地盘，我们一个字都不碰**
  node_modules/@wenbo/*  →  ../../.surfclam/*
```

自举是**增量确保**，不是覆盖重写。三条纪律见 §3.5。

### 2.3 三种运行形态

| | 触发 | profile | node 半边从哪来 | 壳从哪来 | Swift 载荷 |
|---|---|---|---|---|---|
| **正式** | 双击 `/Applications/Surfclam.app` | `surfclam` | **壳自举**的镜像 | dmg 装的（签名公证） | bundle 内预编译 dylib |
| **开发（主）** | `./dev` | `surfclam-dev` | `./dev` 的 `link:` 仓库 | 本机 xcodebuild Debug | 本机 swiftc，存盘热替换 |
| **开发（侧）** | 侧 worktree 的 `./dev` | `surfclam-<目录名>` | 同上 | 同上 | 同上 |
| **缺 App** | 终端 `dsh --profile surfclam` 而 App 没装 | `surfclam` | 上一次自举留下的镜像 | 无 | 无（无壳则无桥） |

**三套可以同时跑**，这是本次重构顺带解锁的（今天 `./release` 与主 worktree 的
`./dev` 互斥）。互不干扰的三条依据：`endpoints/<profile>.json` 按 profile 分片、
两个 App 的 bundle id 不同且 LaunchServices 按路径去重、Release 壳的 `isOwn`
判据走 `appPath`。

第三种形态要**优雅**：没有 App 时 dsh 应当照常起、Web UI 照常可用。
镜像里的插件大多 inject `clamBridge`，桥在但没有壳连上来就是空转——今天已经是这个行为。

### 2.4 首次运行：三道缺失，三种应对

用户第一次双击时，机器上可能缺三样东西。**三种都不能是崩溃或静默无事。**

| 缺什么 | 怎么检测 | 应对 |
|---|---|---|
| **dsh 没装** | `zsh -lc 'command -v dsh'` 失败 | 连接页给一行可拷贝的命令（`npm i -g @deepseek-ai/dsh@<钉住的版本>`）+ 一颗「重新检测」。**不代劳安装**（§0 非目标） |
| **profile 不存在** | `~/.dsh/profiles/surfclam/package.json` 不在 | 自举**自己建**（这是它的正常职责，不是错误） |
| **镜像过期/不在** | `.stamp` 与当前 bundle 对不上 | 自举重拷 |

**PATH 的坑已知**：GUI App 的 PATH 里没有 node/dsh，必须经 `zsh -lc`；
而 `zsh -lc` 读 `.zshenv`/`.zprofile`/`.zlogin` 而**不读 `.zshrc`**——
node 只配在 `.zshrc` 里的机器会解不出来。检测失败时的文案要提到这一点，
否则用户会坚称"我明明装了"。

**一条容易忽略的前提**：`~/.dsh/profiles/node_modules/` 里那 197 个
`@deepseek-ai/*` 包（每个插件都 peer-depend 它们）是**dsh 自己**在启动时用
`healProfilesModuleFallback` 填的，不是我们装的。所以自举只保证"我们的包在位"，
**`@deepseek-ai/*` 在位与否取决于 dsh 至少完整跑过一次**。

> **已验证（M2，2026-08-30，实测）：这个顺序天生成立，不需要任何额外机制。**
> 源码为证：`dsh/lib/profile-boot-DG5t9aNs.js` 的 `prepareProfile`（:140-145）
> **每次启动都先 `healProfilesModuleFallback(INSTALL_ANCHOR)`、再
> `loadProfile(...)`**——填 `profiles/node_modules` 排在解析 bundle 之前，
> 是 dsh 自己的启动顺序，与我们无关。
>
> 端到端实跑（`DSH_HOME=/tmp/dshhome-fresh`，空目录，等价于清空 `~/.dsh`）：
> 自举建 profile → 拷镜像 → 写 `package.json` + 9 条符号链接 → spawn
> `dsh --profile … --port 0 --no-open` → **`profiles/node_modules` 里出现 185 个
> `@deepseek-ai/*`**（dsh 自己填的）→ 五个插件全部登记 → `dsh web` 起来 →
> 壳连上桥。**第一次就没撞空。**
> （用 `DSH_HOME` 而不是 `mv ~/.dsh`：语义等价，且不会打断本机正跑着的那套。）

**dsh 版本对不对无法检测**（§1.3 事实 9：`host.describe()` 硬编码 `"0.0.1"`，
wire 上探不出版本）。所以只检测"在不在"，不检测"对不对"——
**别假装能做版本门**。真出了不兼容，症状会是插件缺席或 CSS 错位，
文档里要写清楚"先核对 dsh 版本"这一条排查路径。

## §3 关键设计决策

### 3.1 镜像拷贝，而不是链接进 .app

见 §1.2 事实 A：链接进 .app 会让 realpath 落在 bundle 内部，`@deepseek-ai/*` 解析不到。
拷贝还顺带买到三样东西：

- **.app 是只读的**（签名过的 bundle 不能改），而 pnpm / dsh 都可能想往包目录里写东西；
- **App 被删掉时 dsh 仍然起得来**（镜像还在），退化成「缺 App 形态」而不是启动失败；
- **`.surfclam/` 里可以放我们自己的 `.stamp`**，自举据此判断要不要重拷。

代价是一份几百 KB 的副本，以及「换了 App 必须重新自举」——后者本来就要做（§1.3 事实 6）。

### 3.2 预编译 dylib 随 bundle 分发；本机 swiftc 退居开发期

正式用户**不该需要任何工具链**。内容寻址缓存机制已经在了，只要 bundle 里那份 dylib 的
`contentHash` 与壳算出来的一致，就直接 dlopen，一次编译都不跑。

**hash 必须由同一套算法产生，不能重新实现一遍。** 做法是构建流水线**真的跑一次编译**
（用壳自己的 `CompilerService` 逻辑，抽成一个可执行入口），把产物按 hash 落进
`ClamPlugins/<Module>/prebuilt/<contentHash>/`。这样：

- hash 里含的 SDK `.swiftinterface` 摘要 —— 就是同一个 bundle 里那份，天然一致；
- hash 里含的源码内容 —— 就是 `ClamPlugins/<Module>/sources/`，天然一致；
- hash 里含的上游 dep contentHash —— 递归一致。

壳侧的查找顺序变成：**用户缓存 → bundle 内预编译 → 现场编译**。
（用户缓存排第一，是为了让"用户自己改了插件源码"这条路仍然赢过 bundle 里的默认实现。）

**M3 已落地（2026-08-30）**。实现要点：

- `CompilerService` 多了一个 `ProductRoot`（`.cache(URL)` / `.prebuilt(URL)`）与
  一对 `searchRoots` / `writeRoot`。**两种布局是同构的**——
  `generations/<Module>/<hash12>/` 与 `ClamPlugins/<Module>/prebuilt/<hash12>/`，
  产物之间永远是"兄弟"——所以 `rpathReference(to:from:)` 那条按真实相对位置算的
  `@loader_path` 在两边都自动成立，一行布局都不用写死。
- **构建期不重新实现编译逻辑**：`scripts/prebuild-plugins.sh` 用 swiftc 现编一个
  小工具，编的时候把壳自己的 `Sources/Native/CompilerService.swift` 原样拉进去
  （另加 `Support/Hashing.swift` `Support/Log.swift` 与 30 行驱动
  `scripts/prebuild/Prebuild.swift`）。构建机与用户机上算 hash、拼参数、写 rpath 的
  **是同一份代码文件**。
- **桥那半边的 hash 也不重算**：`clam-bridge/lib/index.js` 里那段抽成了
  `clam-bridge/lib/swift-payload.js`（`scanSwiftDir` + `swiftContentHash`，零依赖），
  桥与构建脚本 import 同一份——与 M1 抽 `module-name.js` 同一个理由。
- **`swiftDeps` / `sharedModules` / `schemaVersion` 从声明方直接拿**：
  `createSwiftPlugin` 现在往返回的插件对象上挂一个不可枚举的 `clamSwift`，
  构建脚本 `import` 各插件的 node 半边读它。**静态解析源码是不行的**——猜错了
  不报错，只是 hash 差一点、预编译永远命中不了，静默退回现场编译。
- 产物的诞生顺序是 `embed-modules` → `pack-payload` → `prebuild-plugins`，
  每一步吃上一步的产物；预编译读的源码是**刚打包进 bundle 的那一份**。

**两个 showstopper 已修（2026-08-30，只动 `CompilerService.swift`）。**

#### showstopper 1：contentHash 里的本机 `swiftc --version` —— 已删

`CompilerService.toolchainFingerprint()` 曾把 **本机 `swiftc --version` 的输出**
折进每个插件的 contentHash。后果对预编译方案是致命的——**构建机算出的 hash 在用户
机器上永远对不上**，预编译 dylib 一次都命中不了，于是退回现场编译，而用户可能根本
没有 swiftc，结果是**插件全部缺席**。

更糟的是它在无工具链的机器上不是"取不到值"而是**取到垃圾值**——**已实测确认**：

```
$ DEVELOPER_DIR=/nonexistent /usr/bin/xcrun swiftc --version
status=1
output=[xcrun: error: missing DEVELOPER_DIR path: /nonexistent]
```

`/usr/bin/xcrun` 仍在，`Process.run()` 不抛，`runSwiftc` 只是返回非零状态**并把错误
文本当作 `output`**（它根本不看 status），于是那段**带本机路径**的错误文本被原样
哈希进去。

**修法：删掉那一行**，让随 bundle 分发的 `ClamSDK.swiftinterface` 摘要
（`sharedModuleFingerprint`）独自承担"工具链变了"的信号，与 `targetTriple()`
早就在用的模式一致（真相取自随 bundle 走的那份文件，而不是本机环境）。

**信号并没有丢**（复核了一遍，结论比原计划更强）：

1. `.swiftinterface` 的文件头里**就写着编它的那个编译器**——
   `// swift-compiler-version: Apple Swift version 6.4 (swiftlang-6.4.0.23.5 clang-2100.3.23.3)`
   ——以及 `-target arm64-apple-macos27.0`。信息量与 `swiftc --version` 基本重合
   （只差一行 `swift-driver version:`）。
2. `scripts/build-modules.sh` 的跳过判据里**含 `xcrun swiftc --version`**（`sources_hash()`）。
   所以换工具链 → ClamSDK 必然重编 → interface 头必然改写 → 所有插件 contentHash 必然失效。

**残留取舍**（写进代码注释了）：同源码 + 同 ClamSDK、只换 swiftc 而**不重编 ClamSDK**
会被认作同一个 hash。这条路只有手动绕开 `build-modules.sh` 才走得到，而且真出问题也是
响亮的 `.swiftmodule` 版本不匹配，不是沉默的认知分裂。**没有发现"不会反映进
`.swiftinterface` 的真实工具链变化"**，所以不需要退而求其次去哈希
`swift-compiler-version` 那一行。

**实测验收**：改完之后拿 `DEVELOPER_DIR=/nonexistent` 直接起壳（`--clam-endpoint`
指向在跑的后端），五个插件**全部"缓存命中"、module hash 与正常环境下逐字相同**、
一次 swiftc 都没跑。这正是用户机器上要发生的事。

#### showstopper 2：烘焙进 dylib 的绝对 rpath —— 已改成相对

改之前，`CompilerService` 往 swiftc 传的两条 `-rpath` 都是绝对路径：

```
LC_RPATH  path /Users/…/Surfclam Dev.app/Contents/Frameworks        ← 共享 module
LC_RPATH  path /Users/…/native-plugins/generations/ClamLayout/…     ← 插件间依赖
```

**共享 module 那条**改成 `@executable_path/../Frameworks`。`@executable_path` 展开的是
**主可执行文件（壳）**的位置，与这份 dylib 自己躺在用户缓存还是 bundle 内预编译目录
无关，所以两种落点都成立；壳自己链接 ClamSDK 用的也正是这条
（`project.yml` 的 `LD_RUNPATH_SEARCH_PATHS`）。

**插件间依赖那条**（`ClamSidebar` → `ClamLayout`）先要搞清楚一件事：

> **实测（2026-08-30，隔离复跑）：这条 rpath 在正常运行路径上根本不参与解析。**
> dyld 解析 `@rpath/libClamLayout_h….dylib` 之前，先看**已装载的 image 里有没有同名
> install_name**，有就直接复用——与 rpath 能不能解析无关，与 `RTLD_LOCAL` 也无关。
> 探针：把 B 的 rpath 指向一个根本不存在的目录，先 `dlopen(A)` 再 `dlopen(B)` 照样成功；
> 不先装 A 才报 `Library not loaded: @rpath/libA.dylib`。而壳**正是按拓扑序 dlopen**
> （`NativePluginHost.reconcile`，`sources` 已是依赖在前）。

所以这条 rpath 的作用域只是"这份 dylib 被单独装载时"（验证工具、将来的按需装载）。
既然如此就该写成可搬运的：两份产物在同一棵树里的相对位置是**结构性**的——
用户缓存是 `generations/<Module>/<hash12>/`，bundle 内预编译是
`ClamPlugins/<Module>/prebuilt/<hash12>/`，两种布局下依赖都是"兄弟目录"。
实现是一个通用的 `rpathReference(to:from:)`：**按两个产物目录的真实相对位置算出
`@loader_path/…`**（同一棵树 → `../../ClamLayout/<hash12>` 或
`../../../ClamLayout/prebuilt/<hash12>`，自动适配，不写死任何一种布局），
只有两者除了 `/` 没有公共祖先时才退回绝对路径。

**相对路径在任何情形下都不比绝对差**：两棵树一起搬 → 相对还对、绝对已错；
只搬一边 → 两者都错，而那时兜底的是上面那条"依赖先装"。**顺带堵掉一个真实的坑**：
绝对 rpath 会让搬走的产物**悄悄回连构建机的树**——实测把旧产物放进一个搬到
`/tmp` 的假 bundle 里 dlopen，`DYLD_PRINT_LIBRARIES` 显示它取的是
`/Users/…/Repos/surfclam/…/Surfclam Dev.app/Contents/Frameworks/libClamSDK.dylib`
和用户缓存里的 ClamLayout，**而且装载成功**（因为那些路径在本机碰巧存在）——
换一台机器才炸，本机测不出来。新产物在同一场景下取的全是搬运后那棵树里的文件。

**实测验收**：`otool -l` 两条 rpath 都是相对的；把新产物连同 `libClamSDK.dylib`
拷进 `/tmp/port/Relocated.app`（路径与构建时毫无关系）后，**单独 dlopen 依赖方**
（不预装 ClamLayout，纯靠 `@loader_path`）与按拓扑序装两个，都成功且
`clam_plugin_entry` 找得到。

**仍未做、留给 M5 的**：预编译产物要用 Developer ID 签名（现在仍是 ad-hoc /
linker-signed）。顺序上没有障碍——`strip -x` 与整个预编译都发生在
postBuildScripts 段，Xcode 自己的 `CodeSign` 排在它们之后（§4.1），
M5 的 inside-out 逐个签只要插在同一段的末尾即可。

现场编译那条路**不删**：它是第三方 Swift 插件的唯一出路，也是开发循环的地基。
**但它此后是「可选能力」而不是「启动前提」**：`swiftc` 不在就 warn 一句并跳过那个插件，
而不是让整个原生侧缺席。**M3 已落地**：`CompileError.noToolchain` +
`CompilerService.toolchainAvailable()`（判据是 `xcrun --find swiftc` 的**退出码
且结果文件真的可执行**——`/usr/bin/xcrun` 在没有工具链的机器上照样跑得起来，
只是把 `xcrun: error: missing DEVELOPER_DIR path: …` 当 stdout 吐出来）；
`NativePluginHost` 单独 catch 这一档，日志与桥上都走 warn（`reason: "no-toolchain"`）。
**这个探测只在真要编译之前才做**，所以"零编译启动"连 `xcrun` 都不会 spawn。

### 3.2a swiftDir 跟着镜像走，不指向 bundle（M3 定案）

§7.3 记的那个硬阻断（镜像里没有 `swift/`，桥 `register()` fails loud，整个 dsh 起不来）
有两条解法，M3 选了第一条：

| | 做法 | 取舍 |
|---|---|---|
| **✅ 选中** | `swift/` 打进 `ClamNode/<pkg>/swift/`，与 `lib/` 平级 | 各插件写的 `new URL("../swift/", import.meta.url)` **原样成立**；node 半边不需要知道 App bundle 在哪（它本来也不知道）；App 被删掉时镜像还在，"缺 App 形态"更完整 |
| ❌ | `swiftDir` 指向 bundle 的 `Resources/ClamPlugins/<Module>/sources/` | 要让 node 半边先找到 App（`.stamp` 的 `appPath`），多一层机制、多一个会漂移的假设 |

**动手前先验的那件事**：构建期算 contentHash 用的是仓库里的 `swift/`，运行期算的是
镜像里的——两份必须**逐字节相同**，hash 才会一致、预编译才命中。
`pack-payload.mjs` 对 `.swift` 不做任何变换（`readFileSync` → `writeFileSync`，
原始 Buffer），`ProfileBootstrap` 用 `ditto` 整份拷。**实测三方一致**：
`diff -r 仓库/swift 镜像/swift` 与 `diff -r 仓库/swift bundle/ClamNode/<pkg>/swift`
五个插件全部无差异；端到端也印证了——壳先连上一个 dev 形态的 dsh（源码来自仓库）
就已经命中 bundle 里的预编译产物，切到自己那个镜像形态的 dsh 之后 contentHash
一字未变、没有重编。

**代价与收益**：镜像多 ~490 KB（拷贝成本可忽略），换来 bundle 里**只有一份源码**
——`ClamPlugins/<Module>/sources/` 因此从 M1 的布局里删掉了，
预编译流水线直接读 `ClamNode/<pkg>/swift/`。

### 3.3 壳不再自己构建自己

四条理由，最后一条是决定性的：

1. **门槛**：完整 Xcode 十几 GB，加上 `xcodegen` 二进制（`.gitignore` 挡在库外，
   registry 模式只能从 PATH 找）。
2. **失败面向的人不对**：xcodebuild 的一屏报错对用户毫无意义。
3. **好处几乎为零**：唯一受益的是「改了壳源码想快速验证」，而有这个需求的人手里有仓库和
   `./dev`，那条路本来就更好。
4. **签名会自毁**：发布的 App 是 Developer ID 签名 + 公证过的；它自己 xcodebuild
   重建自己，产出的是 ad-hoc 签名，**当场把自己从"公证过"降级成"来路不明"**。
   Hardened Runtime 与 entitlements 也随之对不上，于是**所有热插件突然装载失败**——
   而症状完全不像签名问题。

`CLAM_RELEASE=1` 曾经已经把 `build / watch / launch` 全关了，所以这一步是**把剩下
一半砍干净**：正式形态的包**根本不包含** `host/` 源码和 `build.sh`。
判据从「环境变量说别构建」改成「源码不在包里所以构建不了」——更诚实，也少一个旋钮。

> **M4 已落地（2026-08-30）**，实现与实测见 §9。两处与本节原文不同的落定：
> ① `launch` **没有**跟着关（源码不在场时它仍照 config 走）——正式形态下 App 早就
> 在跑，`launch()` 自己会因为 `isRunning` 跳过；从前强制关它防的是常驻 LaunchAgent
> 在登录时弹窗口，那个 daemon 已经退役。
> ② `clam-app` 里那条"构建成功后 ditto 进 `/Applications`"的支路
> （`installBuiltProduct` / `refreshIconCache`）随 `CLAM_RELEASE` 一起删了——
> 它的唯一入口就是那个环境变量。装进 `/Applications` 此后只有
> `host/scripts/build.sh` 一条路。
> ③ **判据从"运行时看 `host/project.yml` 在不在"升级成"构建代码在不在包里"**
> （用户 2026-08-30 追加裁决："更新完之后的代码里，就不该再包含重新构建壳的部分"）。
> 构建那 389 行搬进了 `clam-app/host-build/`，`files` 白名单只收 `lib/`，
> `pack-payload.mjs` 也只拷 `lib/` 与 `swift/`——于是分发形态里**根本没有那段代码**，
> 而不是"有但不执行"。`lib/index.js` 顶层一次
> `await import("../host-build/index.js").catch(…)`：拿不到就是没有构建能力。
> 顶层 await 是有意的——`apply` 是同步的，而发现文件第一拍就要写对 `appPath`。

### 3.4 版本只有一个：App 的版本

三半边同一个 bundle，**版本握手问题消失**。具体：

- `Info.plist` 的 `MARKETING_VERSION` 是唯一权威版本号；
- `ClamNode/*/package.json` 的 `version` 全部与它对齐（构建时改写，不手工维护）；
- `.surfclam/.stamp` 记录 `{appVersion, appPath, sourceHash}`，自举据此判断是否重拷；
- ⌥⌘D 诊断面板显示这一个版本号。

**不再需要「壳与插件版本不匹配」的检测**——它们不可能不匹配。
（跨 App 版本的旧镜像会被自举覆盖；`sourceHash` 兜住"同版本但内容变了"的开发期情形。）

### 3.5 自举的三条纪律

用户往 `surfclam` profile 里加的东西**必须活下来**。所以自举：

1. **只读-改-写两处**：`package.json` 里我们那 N 个 `@wenbo/*` key，
   和 `dsh.profile.bundles` 里那三行（缺了才补）。
   **绝不整体重写 `package.json`**——用户 `dsh plugin add` 的依赖跟我们那几行
   躺在同一个 `dependencies` 对象里。
2. **绝不碰 `<profile>/cordis.patch.yml`**。那是 dsh 给用户的 patch 层。
   （同一条纪律的先例：`docs/release-install-plan.md` §7 删掉
   `ensureConnectionModeDefault` 而不是改它——安装脚本不写配置。）
3. **对不上就 fails loud，不要"修复"回默认**。判据是 `.stamp`；
   镜像坏了、profile 被手工改乱了，报出来让人看见，不要静默重建。

**清理规则**：`.surfclam/` 里我们上一版留下、这一版不再有的包，连同 `package.json` 里
对应那行一起删——判据是「link 目标在 `.surfclam/` 之内」。用户自己的依赖不满足这个判据，
天然不受影响。

**顺序**：自举必须在 spawn 后端**之前**完成（§1.3 事实 5：镜像不在位 = dsh 起不来）。
`managed` 形态下这条链在壳手里；用户连接一个外部 dsh 时，自举仍然要跑
（那个 dsh 可能是下一次才起的）。

### 3.6 profile 按壳的身份分片（2026-08-30 用户裁决，推翻旧决策）

| profile | 谁用 | 依赖来源 |
|---|---|---|
| `surfclam` | **安装形态专属**（Release App 自举） | `.surfclam/` 镜像 |
| `surfclam-dev` | 主 worktree 的 `./dev` | `link:` 仓库 |
| `surfclam-<目录名>` | 侧 worktree | `link:` 仓库（**不变**） |

**这不是新机制。** worktree 本来就各进各的 profile
（`bin/surfclam.js` 的 `defaultProfile` 比对 `--git-dir` 与 `--git-common-dir`），
唯一的问题是**主 worktree 占用了 `surfclam` 这个名字**，与安装形态撞车。
本节做的全部事情就是**把主 worktree 改名成 `surfclam-dev`，把 `surfclam` 空出来**。
规则反而更好讲：`surfclam` 是本机安装的身份，开发一律带后缀——
今天那条「主 worktree 特殊」的例外没了。

**这推翻了 `docs/release-install-plan.md` §0 的「不设第二个 profile」。**
推翻是对的：那条论证的是**「不需要」**（会话与设置全局、不随 profile 分片，
分开没有数据收益），不是「分开有害」。而现在**两个 profile 的内容不再相同了**
——一个 link 仓库源码、一个 link 自举镜像——这是当时不存在的实质分化理由。
数据代价仍然是零，推翻的成本只有一次改名。

**由此，自举的职责边界变得干净**：

| 壳 | spawn 什么 | profile 谁来备 |
|---|---|---|
| `/Applications/Surfclam.app` | `dsh --profile surfclam` | **壳自举**（它没有 `./dev` 可跑） |
| worktree 的 Dev 壳 | 本 worktree 的 `./dev` | **`./dev` 自己**（今天的样子，一行不改） |

**自举是 Release 壳专有的行为，Dev 壳压根不该有这段代码。**
判据不是「Dev 还是 Release」，而是 `BackendManager` 本来就在区分的「我 spawn 什么」。
连接到一个**外部**后端时（用户在连接页敲地址）也不自举——那个后端已经在跑了，
它的 profile 早就就绪。

## §4 签名与公证

> Sparkle/公证的外部流程调研仍在跑；**本节已确认的部分全部来自本仓库实测**，
> 与调研无关，可以直接照做。

### 4.1 好消息：签名顺序已经是对的，不用重排

计划早期版本（以及 `embed-modules.sh:7-8` 自己的注释）都以为拷贝发生在
Xcode 签名**之后**、所以要重排。**构建日志证明不是**：

```
1273  PhaseScriptExecution Embed shared modules …
1838  …/Frameworks/libClamSDK.dylib: replacing existing signature
1851  CodeSign …/Release/Surfclam.app          ← Xcode 最后才封外层
```

顺序**已经是 inside-out**：脚本摆好并签好嵌套代码 → Xcode 封外层 bundle。
`codesign -d` 也确认封印覆盖到了它（`Sealed Resources … files=7`，
`Frameworks/libClamSDK.dylib` 带 cdhash + requirement）。
**`embed-modules.sh:7-8` 那条注释是错的，顺手改掉**——不改的话下一个读的人会
重新推导出同一个错误结论。

**M1 复核（2026-08-30，实测）**：`pack-payload.sh` 排在 `embed-modules.sh`
**之后**、两者都是 `postBuildScripts`，**不破坏封印，也不需要重签**——

```
$ codesign -v --deep --strict Surfclam.app   → 通过（build/ 与 /Applications 两份都过）
$ codesign -d --verbose=4 Surfclam.app       → Sealed Resources … files=83（打包前是 7）
```

`files` 从 7 涨到 83 正是结论本身：**载荷进了封印**，说明 Xcode 的 `CodeSign`
阶段确实排在全部 postBuildScripts 之后。而且这不是"第一次构建碰巧"——脚本
无 outputs 声明（Xcode 每次构建都会 warn 这一点），所以它每轮都跑，下游的
`CodeSign` 也就每轮都跟着重封。实测把 `ClamPayload.json` 删掉逼它重打一次，
`codesign -v --deep --strict` 照样通过。

**推论**：往 `Contents/` 里塞东西的新 build phase 一律排在 postBuild 段即可，
不用自己 `codesign`。§4.2 要删的那句外层 ad-hoc 重签（`embed-modules.sh:34`）
因此更确定是死动作。

### 4.1a 写 bundle 的脚本阶段必须声明 `outputFiles`（2026-08-30 实测复现）

§4.1 说「顺序已经是对的，不用重排」——**对，但不够**。M1/M3 各自验收时
`codesign -v` 都通过，两者叠加之后却出现了：

```
build/…/Surfclam.app: a sealed resource is missing or invalid
file modified: …/Contents/Resources/ClamPrebuilt.json
```

**根因**：三个 postBuildScript 都往 bundle 里写文件，但**没有一个声明
`outputFiles`**，于是 Xcode 的依赖图里根本没有这些文件。当壳的可执行文件本身
没变时（**只改了插件的 node/swift 半边就是这种情况，而那正是日常**），
`CodeSign` 阶段被判定为不必重跑——可脚本每一轮都跑、每一轮都改 bundle 内容，
**封印就此过期**。

**为什么它特别危险**：`BUILD SUCCEEDED` 一切正常，症状是间歇性的
（取决于 Xcode 那一轮怎么判断），而它砸中的正是发布那一步——**公证会直接拒收
封印不匹配的包**。M1 当时观察到的「脚本无 outputs 声明，Xcode 每次都 warn，
每轮都跑，下游 CodeSign 也每轮重封」，前半句对，**后半句不成立**。

**修法**：三个阶段各声明一个代表性产物即可（Xcode 只需要知道"这个阶段会产出它"，
就会把 `CodeSign` 排到它后面并跟着它的新鲜度走）：

| 阶段 | `outputFiles` |
|---|---|
| `embed-modules.sh` | `$(BUILT_PRODUCTS_DIR)/$(CONTENTS_FOLDER_PATH)/Frameworks/libClamSDK.dylib` |
| `pack-payload.sh` | `…/Resources/ClamPayload.json` |
| `prebuild-plugins.sh` | `…/Resources/ClamPrebuilt.json` |

Debug 配置下后两个脚本直接 `exit 0`、不产出文件，output 缺失会让 Xcode 每轮都
调用它们——**正是想要的**（它们自己两行就退出）。

**验证方法**（复现原始触发条件，别用 clean build——那必然重签、测不出来）：
只改一个插件的 `.swift`，构建，确认日志里 `CodeSign` 出现且 `codesign -v` 通过。

### 4.2 四处必须改的 ✅ 已做（2026-08-30 M5）

| 位置 | 原状 | 现在 |
|---|---|---|
| `embed-modules.sh:30` | `codesign --force --sign -` 给嵌套 dylib **ad-hoc 签名** | `--sign "${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}"`。开发形态照旧 `-`，分发形态自动是 Developer ID |
| `embed-modules.sh:30` | `--timestamp=none` | 身份是 `-` 才 `--timestamp=none`（ad-hoc 拿不到 secure timestamp），真身份一律 `--timestamp`；`ENABLE_HARDENED_RUNTIME=YES` 时再补 `--options runtime` |
| `embed-modules.sh:34` | 外层再 ad-hoc 重签一次 | **已删**。`$APP` 变量随之删掉，顶注也换成了"这里不需要、也不许再签外层"，不再是那条已被证伪的旧说法 |
| `project.yml` | 未设 `CODE_SIGN_INJECT_BASE_ENTITLEMENTS` | 由 `scripts/release-dmg.sh` 在 xcodebuild 命令行上传 `NO`（连同 `CODE_SIGN_IDENTITY` / `ENABLE_HARDENED_RUNTIME=YES` / `OTHER_CODE_SIGN_FLAGS=--timestamp`）。**不写进 project.yml**，见 §4.3 |

关于最后一条：**当时的 Release 产物上确实带着 `get-task-allow`**，实测——

```
$ codesign -dv --entitlements - /Applications/Surfclam.app
Signature=adhoc
  com.apple.security.app-sandbox    → false
  com.apple.security.get-task-allow → true
```

它是 `CODE_SIGN_INJECT_BASE_ENTITLEMENTS` 因为身份是 `-`（"Sign to Run Locally"）
而注入的。**公证对这个 entitlement 是直接拒绝。**

### 4.2a 第五处：`ClamPlugins/**/prebuilt/*.dylib` 也是嵌套代码（M5 新增）

§4.2 那张表是 M3 之前写的，漏了 M3 才出现的那五个预编译 dylib。它们同样是
bundle 里的可执行代码，公证会**递归检查每一个 Mach-O**，ad-hoc 的一律拒。

**签在哪里：`scripts/prebuild/Prebuild.swift` 的编译循环里，`strip -x` 之后。**
另一条路（打包脚本事后 `find … -name '*.dylib'` 扫一遍逐个签）被否掉，三条理由：

1. **inside-out 是结构性的**。预编译是最后一个 postBuildScript，Xcode 的
   `CodeSign` 阶段排在它之后封外层——签完就被封进去，顺序不靠人记。
   事后签嵌套代码则**破坏已封好的印**，必须连外层一起重签，于是
   entitlements / Hardened Runtime / 身份这三样知识就有了第二个副本，
   而 §4.3 刚刚才把它收成一份。
2. **身份从同一个源头来**：`EXPANDED_CODE_SIGN_IDENTITY` 经
   `prebuild-plugins.mjs` 进 spec，和 `embed-modules.sh` 读的是同一个值。
   打包脚本那条路要自己再解析一次身份，两处会漂移。
3. **顺序对**：必须排在 `strip -x` 之后（strip 会把签名打掉重盖），
   而 strip 就在那个循环里。

**签的是每一轮的全部产物，不只是"这次新编的那些"**：增量构建下绝大多数插件
`origin == .reused`，只签新编的等于发一个内层身份混杂的包。`--force` 让重签幂等。

真身份下签失败 = fails loud（那是个会被 Gatekeeper 拦下的坏包，而构建日志没人看）；
ad-hoc 下只警告（strip 已经留了个有效的 ad-hoc 签名）。

打包脚本那边保留的是**验收**而不是签名：`release-dmg.sh` 逐个 dylib 查
`Authority=Developer ID Application`，缺一个就当场停。

### 4.3 entitlements 必须改在 `project.yml` 里，不能改 plist

`project.yml` 声明了 `entitlements.properties`，所以
**每次 `xcodegen generate` 都会重写 `Sources/surfclam.entitlements`**，
手改静默丢失。这正是那种"修好一次、然后神秘地回退"的坑。

现在那张表是（✅ 已做）：

- `com.apple.security.app-sandbox: false`
- `com.apple.security.cs.disable-library-validation: true`
  ——**热插件机制的存亡所系**，M5 实测的控制组见 §4.4a。

**只有一份 entitlements 文件，不是两份**（M5 定案，推翻本节早先那句
"Debug 与分发两份要分开"）。理由：两份的差别只有 `get-task-allow` 一项，
而那一项**从来不是我们写的**——它是 `CODE_SIGN_INJECT_BASE_ENTITLEMENTS`
在身份为 `-` 时替我们注入的。于是：

| | 身份 | 注入开关 | 结果 |
|---|---|---|---|
| 开发形态（`./dev` / `./release` / `build.sh`） | `-` | 默认 YES | 自动带 `get-task-allow`，照旧能挂调试器 |
| 分发形态（`release-dmg.sh`） | Developer ID | 命令行传 `NO` | 没有 `get-task-allow` |

维护两份内容相同、只差一个注入项的 plist，只会让它们互相漂移。
`disable-library-validation` 留在开发形态里无害（那边 Hardened Runtime 是关的）。

**分发形态的四个 build setting 也不写进 project.yml，走 xcodebuild 命令行覆盖**
（命令行传的 build setting 优先级高于 project.yml 里的一切）。这样
**开发形态一个字都不受影响**——不然每台机器都得有那张 Developer ID 证书才编得动。

### 4.4 签名 → 公证 → staple ✅ 已跑通（2026-08-30，两次 Accepted）

实现是 `clam-app/host/scripts/release-dmg.sh`（+ `scripts/dmg-settings.py`）。
用法：

```sh
scripts/release-dmg.sh --notarize-profile surfclam      # 全流程
scripts/release-dmg.sh --skip-notarize                  # 只出未公证的 dmg（退出码 0）
scripts/release-dmg.sh                                  # 同上但退出码 3（"别把忘了公证当成功"）
```

**产物落 `build-dist/`，不碰 `/Applications`、也不碰 `build/`**：用独立的
`-derivedDataPath` 有两个理由——① 开发形态那份 ad-hoc 的 Release 产物
（`./release` 装机用的）不被 Developer ID 产物覆盖；② 顺带保证 `CodeSign`
阶段必然真的跑一遍（增量构建下它可能被判定为不必重跑，§4.1a）。

**顺序（inside-out + 两次公证、两处 staple，一步都不能换）**：

```
1. xcodebuild（Release）
   ├─ embed-modules.sh    → 签 Frameworks/libClamSDK.dylib
   ├─ pack-payload.sh
   ├─ prebuild-plugins.sh → 编 5 个插件 dylib → strip -x → 逐个签（§4.2a）
   └─ Xcode 的 CodeSign   → 封外层，带 entitlements + runtime + timestamp
2. 验：codesign -v --deep --strict；entitlements 有 disable-library-validation、
   没有 get-task-allow；6 个嵌套 dylib 全部 Authority=Developer ID Application
3. ditto -c -k app → zip → notarytool submit --wait → **stapler staple 那个 .app**
4. 用**已 staple 的 app** 打 dmg（§5）→ 签 dmg
5. notarytool submit dmg --wait → stapler staple dmg → stapler validate
6. spctl --assess --type open --context context:primary-signature
```

**第 3 步为什么在第 4 步之前**：stapler 按 cdhash 取票。先打 dmg 再回头 staple
里面的 app，就等于换了一个 dmg，之前那张票对不上号。zip 只是运输容器——
**zip 本身不能 staple**，这正是别的项目那套 "ditto -c -k → 公证 → staple →
再 ditto -c -k" 舞步的由来。

**`--issuer` 的规则**（`notarytool` 1.1.2 / Xcode 27 的帮助文本原话）：
*"Required for Team API Keys. **Do not provide for Individual API Keys.**"*
——个人 key 传了反而报错。本机走的是 keychain profile（`--keychain-profile surfclam`），
绕开了这一条。

**一条让人安心的事实**（2026-08-30 调研，穷举式确认）：把 Apple Developer News
的 142 条 RSS 逐条读完，**2024-09 到 2026-08 之间没有任何一条涉及
notarization / notary service / notarytool / Developer ID / Gatekeeper**。
2026-04-28 那条 SDK 新规**不管我们**——它限定在 "uploaded to App Store Connect"，
而且列表里根本没有 macOS。

#### 实测记录（2026-08-30）

| | submission id | 结果 |
|---|---|---|
| app（zip） | `be1b0d1f-6aa8-4f83-90a6-82c1ec962c4b` | **Accepted**，约 1.5 分钟 |
| dmg | `eeca3454-5dc9-4fbf-bccc-0f7c95e8c19a` | **Accepted**，约 2 分钟 |

`stapler` 两处都是 `The staple and validate action worked!` / `The validate action worked!`。

**`spctl` 公证前后的对照**（同一个 dmg、同一条签名，唯一变量是那张票）：

```
# 公证前
$ spctl --assess --type open --context context:primary-signature --verbose=4 Surfclam-0.1.0.dmg
Surfclam-0.1.0.dmg: rejected
source=Unnotarized Developer ID          ← 退出码 3
$ spctl --assess --type execute --verbose=4 Surfclam.app
Surfclam.app: rejected
source=Unnotarized Developer ID

# 公证 + staple 后
$ spctl --assess --type open --context context:primary-signature --verbose=4 Surfclam-0.1.0.dmg
Surfclam-0.1.0.dmg: accepted
source=Notarized Developer ID            ← 退出码 0
# 从 dmg 里拖出来的那份 app 同样：
$ spctl --assess --type execute --verbose=4 /tmp/…/Surfclam.app
accepted / source=Notarized Developer ID
$ xcrun stapler validate /tmp/…/Surfclam.app   → The validate action worked!
```

**`source=Unnotarized Developer ID` 是个好症状**：它说明签名链本身是对的
（Gatekeeper 已经认出这是 Developer ID），只缺票。签错了会是别的话
（`obsolete resource envelope`、`no usable signature` 之类）。

### 4.4a 控制组：`disable-library-validation` 到底扛不扛得住（M5 实测）

计划里那句"缺了它所有插件装载失败，且完全不像签名问题"一直没人验过。M5 拿
**同一个 app、同一份代码、同一个 Developer ID、同样开着 Hardened Runtime**，
只换 entitlements 重签了一次，跑了对照：

| entitlements | 现场编译（ad-hoc dylib） | bundle 预编译（Developer ID dylib） |
|---|---|---|
| 带 `disable-library-validation` | **五个全部 dlopen 成功** | 五个全部装载 |
| 不带 | **dlopen 全部失败**，见下 | （没测，理论上照常——同 Team ID） |

失败时 dyld 的原话（这条值得记住，因为它**不提"library validation"五个字**）：

```
dlopen 失败：… (code signature in <…> '/…/libClamNativeify_….dylib'
not valid for use in process: mapping process and mapped file (non-platform)
have different Team IDs)
```

"different Team IDs" = 壳有 Team ID（HJDT6NYKJC）、运行时 swiftc 编出来的 dylib
是 `adhoc,linker-signed`（`TeamIdentifier=not set`）。**这就是 library validation
本身**，不是别的什么东西。

## §5 dmg 打包

### 5.1 工具选型：`dmgbuild`

| | 能自定义版式 | headless/CI | 备注 |
|---|---|---|---|
| **`dmgbuild`**（pip） | ✅ 背景图、坐标、图标尺寸全可配 | ✅ 直写 `.DS_Store`，不用 Finder | **选它** |
| npm `create-dmg` 8.1.0 | ❌ 窗口 660×400、icon-size 160、背景图**全部硬编码**（全部 flag 只有 `--overwrite` / `--no-version-in-filename` / `--identity=` / `--dmg-title=` / `--no-code-sign`） | ✅ | 依赖链已停更：`appdmg@0.6.6`(2023) → `ds-store`(**npm 最后发布 2016**) + `fs-xattr`(node-gyp)；`npm audit` 报 3 条 high "No fix available" |
| shell `create-dmg` | ✅ | ❌ **别用** | [#191](https://github.com/create-dmg/create-dmg/issues/191) 仍开着：*"Headless/Actions: Eternally stuck at 'Creating Disk Image...'"*，维护者诊断是 `hdiutil` 卡在 root 授权提示上 |

### 5.2 必须显式覆盖文件系统与格式 ✅ 已做

**两个工具都默认 HFS+ / UDZO**，而 Sparkle 与现代 macOS 推荐 APFS / ULFO。
实现在 `clam-app/host/scripts/dmg-settings.py`：

```python
filesystem = "APFS"
format = "ULFO"
```

实测确认（`hdiutil imageinfo`，2026-08-30）：

```
Format: ULFO
Format Description: UDIF read-only compressed (lzfse)
Name: disk image (Apple_APFS : 4)
```

产物 **3.8 MB**（app 本体 8.3 MB）。挂载、拖出 `Surfclam.app`、`codesign -v
--deep --strict` + `stapler validate` + `spctl` 三项全过。

（`man hdiutil` 在 macOS 27 上已改口说默认是 APFS，但那只管 `hdiutil` 自己，
不管这两个工具。npm `create-dmg` 的硬编码默认值恰好就是 `ULFO`/`APFS`，
是它少数几个正确的写死值。）

HiDPI 背景：`dmgbuild` 默认开（有 `--no-hidpi` 可关）。

### 5.3 `hdiutil` 在 macOS 27 上已弃用——记一笔，本轮不动

本机（macOS 27.0 / Xcode 27.0）实测，`hdiutil create/attach/convert/detach`
全部打印弃用警告，man page 原话：
*"In macOS 27.0, hdiutil is deprecated. Use `diskutil image` instead."*

**但不需要动作**，三条理由：

1. **只是 deprecated，不是 removed。**
2. **警告走 stderr 不走 stdout**，所以解析 `hdiutil attach` 输出的打包工具都没坏。
3. **`diskutil image` 现在还替代不了标准流程**（实测 `diskutil help image`）：
   `create from --format` 只收 `ASIF/RAW/UDRO/UDSB/UDZO/ULFO/ULMO`，**没有 UDRW**
   （做不出可写的暂存镜像）；`create blank --fs` 只收 `APFS/ExFAT/MS-DOS/None`，
   **没有 HFS+**；**没有 `convert` 子命令**。

三个上游打包工具至今无人提 issue。**列进「需要持续盯的事」，不列进本轮工作。**

## §6 交付物清单

> 细节等重构影响面盘点回来补；这里是框架。

**新增**

| 文件 | 作用 |
|---|---|
| `clam-app/host/Sources/Native/ProfileBootstrap.swift` | 自举：建/校 profile、拷镜像、写 `package.json` 与符号链接、`.stamp`。**只在 Release 壳跑** |
| `clam-app/host/scripts/pack-payload.sh` | 门卫：只在 Release 跑、找 node，逻辑在下面那个 `.mjs`（M1） |
| `clam-app/host/scripts/pack-payload.mjs` | 把 `ClamNode/` + `ClamPlugins/*/sources/` 打进 bundle、对齐版本、写 `Resources/ClamPayload.json`（清单 + 跳过判据）（M1） |
| `clam-bridge/lib/module-name.js` | `clam-sidebar` → `ClamSidebar` 的**唯一真相**。原先是 `lib/index.js` 里一个不导出的私有函数，M1 把它抽成零依赖模块——打包脚本要用同一份算法，而 `lib/index.js` 顶上 `import` 了 schemastery 与 ws，build phase 里未必解析得到 |
| `clam-bridge/lib/swift-payload.js` | `scanSwiftDir` + `swiftContentHash` + `.clam-static` 标记的定义。桥与预编译流水线共用同一份算法（M3；与 `module-name.js` 同一个理由）|
| `clam-app/host/scripts/prebuild-plugins.sh` | 门卫：只在 Release 跑；按源码 hash 编出下面那个工具；把活交给 `.mjs`（M3） |
| `clam-app/host/scripts/prebuild-plugins.mjs` | 读 `ClamPayload.json` → `import` 各插件 node 半边取 `clamSwift` → 扫 bundle 里的 `swift/` → 算桥那半边的 hash → 拓扑序递给工具（M3） |
| `clam-app/host/scripts/prebuild/Prebuild.swift` | 预编译工具的驱动（约 200 行）。**编译逻辑不在这里**——它和壳的 `Native/CompilerService.swift` 一起被 swiftc 编成一个命令行工具（M3） |
| `clam-app/host/scripts/release-dmg.sh` | 签名 → 公证 → staple → dmg（M5） |
| `clam-app/host/Sources/surfclam-release.entitlements` | Hardened Runtime 形态的 entitlements（与 Debug 那份分开） |

**大改**

| 文件 | 怎么改 |
|---|---|
| `clam-app/lib/index.js` | 砍构建/盯源码/拉起的正式形态分支（**M4 已做**：构建那 389 行整体搬进新目录 `clam-app/host-build/`，`lib/index.js` 只留发现文件 / 拉起 / `clamApp` / 快捷键设置面，997 → 674 行） |
| **新增** `clam-app/host-build/{index.js, source-hash.js}` | 构建那半边的新家，**不随包分发**。`source-hash.js` 从 `lib/` 搬过来（`host/scripts/build.sh` 那两行引用同步改了） |
| **新增** `clam-app/lib/util.js` | 两半边共用的 `run` / `errorText` / `readTextOrUndefined` / `delay` / `resolveProfileName`。单独成模块只为避免 `lib/index.js` ↔ `host-build/index.js` 的静态循环依赖 |
| `clam-app/package.json` | `files` 白名单去掉 `host/*`，只留 `lib`（**M4 已做**） |
| `surfclam/bin/surfclam.js` | 删 registry 模式；`defaultProfile` 主 worktree 改 `surfclam-dev`（**M2 已做**）；`./release` **不再备 profile**（M2 已做：那个 profile 归 App 自举，`./release` 再 link 一遍仓库源码等于给它埋一份 §7.1 的残留）；`./release` 转薄封装 |
| `clam-app/host/scripts/embed-modules.sh` | 签名顺序重排（今天在 Xcode 签名之后 ad-hoc 重签） |
| `clam-app/host/project.yml` | Release 配置的签名身份、Hardened Runtime、entitlements 分叉 |
| `clam-bridge/lib/index.js` | **M3 已做**：`register()` 对 swiftDir 缺失从 fails loud 改成优雅缺席（§7.3）；扫描与 hash 移进 `swift-payload.js`；轮询按 `.clam-static` 开关（§7.10）|
| `clam-bridge/lib/plugin.js` | **M3 已做**：`createSwiftPlugin` 往插件对象上挂不可枚举的 `clamSwift`（构建流水线的唯一取数口）|
| `clam-app/host/scripts/pack-payload.mjs` | **M3 已做**：`swift/` 改打进 `ClamNode/<pkg>/swift/` + 写 `.clam-static`；不再产出 `ClamPlugins/<Module>/sources/`，`ClamPlugins/` 整个交给预编译那一步 |
| `clam-app/host/Sources/Native/CompilerService.swift` | **M3 已做**：`ProductRoot` + `searchRoots`/`writeRoot`；`CompiledPlugin.origin`；`CompileError.noToolchain` + `toolchainAvailable()` |
| `clam-app/host/Sources/Native/NativePluginHost.swift` | **M3 已做**：装上两个查找根；单独 catch `.noToolchain` 走 warn；日志与 ⌥⌘D 都报产物来路 |
| `CLAUDE.md` | 「分发形态」「两个开发循环」「多 worktree」「构建与运行」四节都要重写 |

**删除**

| 目标 | 依据 |
|---|---|
| `surfclam.js` 的 registry 模式分支 | §3.3 |
| ~~`CLAM_RELEASE` 环境变量旋钮~~ **已删（M4）** | 判据改成"源码在不在包里"，更诚实。连带删掉它唯一的消费者 `installBuiltProduct` / `refreshIconCache`（"构建完 ditto 进 `/Applications`"那条支路），以及 `BackendManager.resolvePlan()` 里那一句 `env CLAM_RELEASE=1` |
| ~~`clam-app` 的 `INSTALLED_RELEASE` 兜底~~ **已收窄（M4）** | 常量留着（源码不在场时它就是 `expectedAppPath`，也是唯一的候选），删的是 `locateExistingProduct` 的**第三跳**：源码在场时退到装好的正式壳，等于让 `surfclam-dev` 的后端去拉起属于 profile `surfclam` 的 App，正是 §3.6 分片要消掉的混线 |
| `embed-modules.sh:34` 的外层 ad-hoc 重签 | §4.2，死动作 + 活陷阱 |
| ~~`CompilerService.swift:215` 的 `swiftc --version`~~ **已删（2026-08-30）** | §3.2 showstopper 1 |
| `NativePluginHost.swift:129-132` `requestRestartDsh()` + `clam-bridge/lib/index.js:326-330` 的 `restart-dsh` 帧 | **已经是死代码**：`requestRestartDsh()` 全仓无调用者，⌘⇧R 早已改成 `reconnect()`（`MainWindowController.swift:461-463`）。顺带简化 `app-build` 那步清理 |
| `surfclam.js:605-607` `sleepMs` / `:610-615` `whichOrFail` | 唯一调用者随 LaunchAgent 一起删了 |

**保留但要改**：`BridgeClient.swift:102` 现在把 `AppInfo.buildTimestamp`
（形如 `2026-08-30 12:49:18` 的墙钟字符串）当作 `appVersion` 发给桥——
桥因此无从判断"跟我说话的是哪个壳"。§3.4 让版本号变成真的之后，
这里应当改发 `CFBundleShortVersionString` + `CFBundleVersion`。

**`./dev` 的 `ensureModuleResolution` 不能删**：新形态下镜像住在 profiles 树内、
解析链天然正确，但**开发形态仍然需要它**（仓库不在 profiles 树下）。
是"正式形态用不到"而不是"可以删"。

**版本号生成有个硬约束**：不要把 `CURRENT_PROJECT_VERSION` 生成进 `project.yml`
——`clam-app/host-build/source-hash.js` 把 `project.yml` 算进源码 hash，
那样每次 commit 都会让 hash 失效、触发全量重建。
要生成就放进 `HASHED_ROOTS` 之外的 `.xcconfig`，或者发布时手工 bump。

## §7 风险与已知坑

### 7.1 旧 `surfclam` profile 的迁移（一次性）

> **本条曾是最高危风险，§3.6 的 profile 分片把它从根上消掉了。**
> 原风险：Release App 与主 worktree 的 `./dev` 共用 `surfclam`，App 一自举就把
> `link:/Users/…/Repos/surfclam/clam-layout` 改写成 `link:./.surfclam/clam-layout`，
> 开发者的仓库当场从运行链上脱钩，症状是「我明明在改代码，怎么一点反应都没有」。
> 分片之后两者不再共用 profile，**不需要 `.stamp` 逐行比对那套防御**。

**残留的是一次性迁移**：本机现有的 `surfclam` profile 是 link 着仓库的
（10 条 `link:/Users/wenbopan/Repos/surfclam/*`）。改名后 `./dev` 会去建新的
`surfclam-dev`，而**旧的 `surfclam` 原地不动、内容是开发形态**——第一次
Release App 自举正好撞上它。

**对策是一个 sanity check，不是重装备**：自举前看一眼 `dependencies` 里我们那几行的
link 目标，**指向 `.surfclam/` 以外的地方就停下来报出去**，不覆盖。
报的话要能照做：「profile `surfclam` 是旧的开发形态残留，删掉它或跑 `./dev` 迁移」。

（`.stamp` 仍然保留，但用途只剩一个：判断镜像要不要重拷，见 §2.2。）

### 7.2 自举不调 pnpm——**已实测定案**

**结论：壳自己写 `package.json` + 手建 `node_modules/@wenbo/*` 符号链接就够了，
pnpm 不是运行时依赖。** 这消掉了 GUI App 的 PATH 问题（不用为了找 pnpm 多绕一层
`zsh -lc`），也消掉了「pnpm 没装怎么办」。

实测（pnpm 11.22.0，2026-08-30，四组）：

| 场景 | 结果 |
|---|---|
| 手写 `link:./.surfclam/<pkg>` + 手建符号链接，**从不跑 pnpm** | ✅ `import` 成功，包内的 `@deepseek-ai/dsh-llm` 也解析得到 |
| 之后用户跑 `dsh plugin add`（= `pnpm add link:…`） | ✅ 我们的链接**原样保留**，pnpm 报 "Already up to date"；用户的包与我们的包共存 |
| 完整 `pnpm install` | ✅ 保留 |
| **`pnpm install --frozen-lockfile`**（pnpm 对 lock 最严的模式） | ✅ 保留，"Already up to date" |

**为什么 lock 不同步不是问题**：pnpm 对 `link:` 依赖**不写 lockfile 条目**——
本地链接没有版本可锁。所以我们往 `package.json` 里加 `link:` 行而不碰
`pnpm-lock.yaml`，在 pnpm 眼里根本不算"不同步"。

顺带验证：`pnpm-workspace.yaml` 的 `packages: [.]` **不会**把 `.surfclam/` 下的包
当成 workspace 成员（那条规则只含当前目录本身，且点号开头的目录被忽略）。

### 7.3 「缺 App 形态」必须优雅

用户删掉 App、或先在终端跑 `dsh --profile surfclam` 时，镜像还在、桥还在、但没有壳。
今天的行为是桥空转，Web UI 正常——这是对的，重构后要保住。
**特别注意**：`ClamPlugins/` 在 bundle 里，App 删了它就没了，
桥登记 Swift 载荷时 `statSync` 会失败而 `register()` 是 **fails loud** 的
（`clam-bridge/lib/index.js:147-158`，三种情况当场抛而不是 warn）。
→ 需要一条「swiftDir 不存在时优雅缺席」的路径，或者让 `createSwiftPlugin` 在
探测不到 bundle 时干脆不 register。**这是本次重构必须改的一处 fails-loud 语义**，
理由是它的前提变了：从前 swiftDir 一定在仓库里，现在它可能随 App 一起消失。

> **M2 实测确认，而且比预想的更早发作**（2026-08-30）：这一条不只在"用户删了 App"
> 时触发——**镜像形态下它是默认状态**。`ClamNode/` 只收 `package.json` + `lib/`
> （`pack-payload.mjs`），而各插件的 `swiftDir` 是
> `new URL("../swift", import.meta.url)`，在镜像里指向一个**不存在**的
> `<profile>/.surfclam/<pkg>/swift/`。于是自举全过、`@deepseek-ai/*` 全解析得到、
> 而 dsh 在 `register()` 那一步整个起不来：
>
> ```
> failed to apply loader entry clam-layout (@wenbo/clam-layout):
>   clam-bridge：插件 "clam-layout" 的 swiftDir 不是一个目录：…/.surfclam/clam-layout/swift/
> ```
>
> 把仓库里的 `swift/` 手工拷进镜像之后，同一条链一次跑通（五个插件全登记、
> `dsh web` 起来、壳连上桥）——**所以卡点确实只在这一处**。
> **M3 已解（2026-08-30），但选的不是这里写的那条路**：`swiftDir` 仍然是
> `../swift/`，改成把 `swift/` 也打进 `ClamNode/<pkg>/`（理由见 §3.2a）。
> 外加"探不到就优雅缺席"：`register()` 的三条 fails loud 里**只有 swiftDir 那条
> 放开**，返回一个空壳 handle（`push`/`dispose` 都是空操作）并 `logger.warn` 一句。
> 另外两条（module 名非法、重复登记）**前提没变，仍然当场抛**——名字与编排表
> 都在作者手里，错了就是配置错误。
>
> **实测（把镜像里五个 `swift/` 全删掉再起 dsh）**：dsh 照常起、五条
> 「原生半边缺席」的 warn、`HTTP 200`、登记表为空、壳连上来拿到一张空 snapshot。

### 7.4 Gatekeeper 与第一次打开

dmg 下载后带 quarantine 属性。签名 + 公证 + staple 齐全时是正常的首次打开流程；
缺任何一环就是"已损坏，无法打开"（这个文案会让人以为下载坏了）。
验收必须在**一台没有开发者证书的机器**（或清干净的用户）上做，
本机测不出来——本机的 `spctl` 状态和 keychain 会让它显得一切正常。

### 7.5 用户缓存优先于 bundle 预编译，可能留下陈旧世代

§3.2 定的查找顺序是「用户缓存 → bundle 预编译 → 现场编译」。
用户缓存里可能躺着上一版 App 时代编出来的同名 module。**contentHash 会救我们**
（源码或 SDK 一变 hash 就变），但 `generations/` 只增不删——磁盘会缓慢长胖。
→ 顺带做一次「保留最近 N 代」的清理，或者按 App 版本分片。

### 7.6 dsh 无版本协商（§1.3 事实 9）

钉版本是唯一机制。dsh 升级后最先断的**不是服务层，是那 69 处 hash 化 CSS 选择器**
（60 处集中在 `clam-nativeify/lib/client.js`），且**任何地方都不报错**。
本重构不改变这个风险面，但它让"更新插件"变得更容易，算是缓解。

### 7.10 桥的 500ms 轮询在正式形态下是纯浪费（**实测数字**）

`clam-bridge` 的 `scanDir`（`lib/index.js:484-504`）在 `:498` **无条件
`readFileSync` 每一个文件**，签名比对发生在之后（`rescan`，`:376`），
比对的是一份**已经包含全部文件内容**的结果。

实测：**45 个 `.swift` 文件、约 507 KB，每 500ms 重读一遍，永远**。
开发形态下 page cache 是热的、无害；**正式形态下源码永远不会变，所以这是
100% 的浪费——而且是对一个签过名的 bundle 持续 ~1 MB/s 的热读循环**。

**M3 已解（2026-08-30）。判据是一个事实标记，不是旋钮**：`pack-payload.mjs`
往打包出来的每个 `ClamNode/<pkg>/swift/` 里写一个 `.clam-static`
（定义在 `clam-bridge/lib/swift-payload.js`），它随镜像一路拷进
`<profile>/.surfclam/<pkg>/swift/`。桥 `register()` 时 `statSync` 一下，
有就把这条登记标成 `static`：**只在登记那一刻扫一次，此后不再重读**；
一张表上全是 static 就干脆不建那个 `setInterval`。

**为什么"可写位置"这个判据不好用**：镜像躺在 `~/.dsh/profiles/` 下，
按 `access(W_OK)` 它是可写的；而 `/Applications` 对 admin 用户也是可写的。
标记文件说的是真正要紧的那件事——**这份源码是 App 打包时写下的，
唯一会改动它的是 App 自举，而自举跑在 dsh 起来之前**。

它也不是"正式形态"的同义词：混进一个开发中的第三方插件时定时器照常在，
只是那几家分发载荷不重读。

**实测**：仓库源码（无标记）改一行 → 511 ms 后登记表 bump（一个轮询周期）；
带标记的同一份源码改一行 → 5 s 内纹丝不动。

### 7.7 卸载与回滚

**卸载**：今天 `./release --uninstall` 删 App、不动 `~/.dsh`。新形态下用户的直觉动作是
**把 App 拖进废纸篓**，那时留下的是 `~/.dsh/profiles/surfclam/`（含 `.surfclam/` 镜像）
和 `~/Library/Application Support/io.wenbo.surfclam/`（日志、插件缓存、endpoint）。

判据应当是**"用户会不会想要它回来"**：会话与设置在 `~/.dsh` 下、是 dsh 的资产，
**一律不动**；`.surfclam/` 镜像与插件缓存是纯产物，可以清。
**但拖进废纸篓这个动作我们拦截不到**——所以不做"自动清理"，只提供一条
`./release --uninstall`（开发者用）和文档里的手动清理路径。**不为此写守护进程。**

**回滚**：M1–M4 每一步都可以单独退回，因为它们不改 wire 契约、不改数据格式。
最坏情况是退到今天的形态：`git revert` + `./dev` 重装 profile。
**M5（签名公证）是唯一有外部副作用的一步**——一旦发出去签名过的 dmg，
用户机器上的 App 就带着那个签名身份了；换证书要走"新版本覆盖"而不是回滚。

### 7.8 发布流水线跑在哪——**待裁决**

两条路，取舍不同：

- **本机跑**（`./release` 直接签名公证）：简单，密钥不出机器，但发布依赖一台特定机器，
  且 `notarytool` 要等 Apple 那边几分钟到几十分钟。
- **GitHub Actions**：可复现、可审计，但要把 Developer ID 证书（.p12）和
  App Store Connect API key 放进 repository secrets。

**本轮建议先做本机那条**（M5 的验收本来就要在本机做一遍），CI 留到自动更新那一轮
——那时才真的需要"每次 tag 自动出包"。

真要上 CI 时的三条硬事实（2026-08-30 调研）：

- **runner 标签必须钉死**：`macos-latest` 已于 2026-06-15 从 15 迁到 26。
  `macos-14` 正在弃用（2026-11-02 完全下线）。`macos-26` 上默认 Xcode 是 26.6，
  **没有 GA 的 Xcode 27**。别用 `maxim-lobanov/setup-xcode`（2024-06 起基本停维护），
  直接 `sudo xcode-select -s`。
- **`xcodegen` 2.46.0 没有 x86_64 Tahoe 的 bottle**——在 `macos-26-intel` 上会从源码
  编 Swift（很慢）。arm64 上是现成 bottle。**这条直接影响我们**
  （`clam-app/lib/index.js` 会 spawn `tools/xcodegen`）。
- **Apple 不支持 OIDC**，签名证书与 App Store Connect API key 只能是长期 secret，
  唯一缓解是定期轮换。GitHub 官方文档
  [Sign Xcode applications](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)
  给了完整配方，其中 **`security set-key-partition-list -S apple-tool:,apple:`**
  那一句是防止 `codesign` 卡在 UI 弹窗上的关键，`security delete-keychain`
  要放在 `if: always()`。

### 7.11 镜像里那些「只对 npm publish 有意义」的字段（M1 发现，已修/已定案）

`ClamNode/<pkg>/package.json` 是从仓库拷过去的，里面有几个字段在**分发形态下
不参与任何解析**，但形状会误导人。逐个定案：

**`bin` —— 已删（打包时）。** 伞包声明 `"bin": {"surfclam": "./bin/surfclam.js"}`，
而 `ClamNode/surfclam/` 里只有 `package.json` + `cordis.patch.yml`
（`bin/` 是开发者的安装器，不随分发走）。**2026-08-30 实测（pnpm 11.22.0）**：
留着这个字段而文件不在，pnpm **不阻断、只 WARN** ——

```
WARN Failed to create bin at …/node_modules/.bin/surfclam.
     ENOENT: no such file or directory, chmod '…/@wenbo/surfclam/bin/surfclam.js'
```

我们的 `link:` 行与符号链接**原样保留**，后续 `pnpm add` 也照常。代价是每次 pnpm
跑都刷这一行（用户会以为装坏了）外加一条常驻的断链 `.bin/surfclam`。
自举本身不调 pnpm（§7.2），所以只在用户跑 `dsh plugin add` 时发作——
**但那正是最不该出现噪音的时刻**。修在 `pack-payload.mjs` 的 `rewriteManifest()`：
带 `bin` 的包退回 parse→stringify（缩进从原文现测），其余包仍走逐字节改写。

**`dependencies` 的 9 行 `^0.1.0` —— 留着，无害。** 版本对齐之后它们与镜像里各包
的真实 version 不再匹配（`^0.1.0` vs `MARKETING_VERSION`），看着自相矛盾。
**但没有任何东西会去解析它**：pnpm 对 `link:` 依赖**不会去装被 link 目标自己的
dependencies**（CLAUDE.md「为什么开发期要单独 link 那些插件」记的就是这条），
而 dsh 的 loader 只读 `dsh.bundle.patch`，`resolveBundleDir` 走 `resolve.paths()`
也不看 dependencies。**清理它反而要多写代码、多一处会漂移的逻辑。**
（真要发 npm 包时那些 caret range 是对的，仓库源文件本来就不该动。）

**`files` 白名单 —— 同上，留着。** 只在 `npm publish` 时有意义。

### 7.9 文档债

这次重构会让 `CLAUDE.md` 的四节直接过时（「分发形态」「两个开发循环」
「多 worktree」「构建与运行」），`docs/release-install-plan.md` 整篇变成历史档案
（它已经有一层 2026-08-30 的大修订说明，这次是第二层）。
**每个里程碑完成时同步改文档，不要攒到最后**——攒着的后果在这个仓库有先例
（`phase2-clam-plugin-migration-plan.md` 至今用着旧名字）。

## §8 里程碑

按「依赖 + 可独立验收」排。**M1–M4 不需要任何证书，可以在开发形态下全部验证完**，
M5 才涉及外部成本。

| | 内容 | 验收 |
|---|---|---|
| **M1** | **bundle 载荷就位**：`build.sh` 新增一步，把各插件的 node 半边打进 `Resources/ClamNode/`、Swift 源码打进 `Resources/ClamPlugins/<Module>/sources/`；`package.json` 的 `version` 构建时对齐 `MARKETING_VERSION` | 构建出的 Release bundle 里三个目录内容正确；`./dev` 与今天逐字一样 |
| **M2** | **profile 分片改名**（`surfclam-dev` / 见 §3.6）+ **profile 自举**（壳侧新增 `Native/ProfileBootstrap.swift`，只在 Release 壳、`BackendManager.start()` 之前跑）+ `.stamp` + 三条纪律 + 7.1 的迁移检查 | ① 清空 profile → 双击 App → 自举 + spawn + 五个插件装载 + 会话列表出来；② 往 `surfclam` 里 `dsh plugin add` 一个包，重启 App，那个包**还在**；③ **常驻 App 与主 worktree `./dev` 同时跑，互不干扰**（今天做不到） |
| ~~**M3**~~ **✅ 2026-08-30** | **预编译 dylib**：编译入口从 `CompilerService` 抽成可执行、构建流水线跑一次真编译落进 `ClamPlugins/<Module>/prebuilt/<hash>/`；壳侧查找顺序加一层；顺带解掉 §7.3 的硬阻断与 §7.10 的轮询浪费 | 全部实跑通过，见 §9 |
| **M4** ✅ | **砍掉壳自构建**：构建那 389 行**整体移出随包分发的部分**（新目录 `clam-app/host-build/`，`files` 白名单只收 `lib/`）；`surfclam.js` 删 registry 模式（`./release` 转 dmg 流水线薄封装那一步**留给 M5**） | ✅ `npm pack` 出来的 `@wenbo/clam-app` 不含 `host/` 也不含构建代码（20.2 KB / 4 文件）；`./dev` 全流程（缓存 + 构建 + 盯源码 + `app-build`）正常；`CLAM_RELEASE` 已删干净。执行日志见 §9 |
| **M5** ✅ **2026-08-30**（流水线部分） | **签名 + 公证 + dmg**：entitlements 加 `disable-library-validation`、`embed-modules.sh` 与预编译工具改用 `EXPANDED_CODE_SIGN_IDENTITY`、新增 `scripts/release-dmg.sh` + `dmg-settings.py`、notarytool + 两处 staple | ✅ 六项本机验收全过（含**控制组**：去掉 `disable-library-validation` 后现场编译的插件 dlopen 全灭，§4.4a）；两次公证 Accepted、`spctl` 由 `Unnotarized` 翻成 `Notarized Developer ID`。**仍欠**：在一台没有开发者证书的机器上下载 dmg → 拖进「应用程序」→ 双击的端到端 |
| **M6** | **Sparkle 自动更新**（本轮不做） | —— |

**M6 的接口在本轮就要留好**（不实现）：
① `MARKETING_VERSION` 是唯一版本号（M1 已定）；
② 「换了 App 必须重启后端」这条链——Sparkle 更新后重启 App，
`managed` 形态下 App 重新 spawn 后端，天然闭合；连着外部 dsh 时需要提示，
提示通道就是今天那条 `app-build` 提示条（M4 里**不要删掉它**，只把触发源留空）。

**M6 动手前先读这四条**（2026-08-30 调研，都是别人踩过的坑）：

1. **EdDSA 签名必须在 `stapler staple` 之后**——`sign_update` 签的是**最终字节**，
   而 stapling 会往产物里加约 5 KB。**先签后 staple = 每个用户都收到
   "The update is improperly signed and could not be validated."**
   这是 2026 年最高发的 Sparkle 故障，四个公开 issue 可查
   （QuMesh#211 的标题直接就是 *"macOS auto-update broken: signed before stapling"*）。
   正确顺序：签 app → 打 dmg → 签 dmg → 公证 → **staple** → **然后才 `sign_update`**
   → 发 release → **最后**才发 appcast（否则 feed 会指向还没上传的资产）。
2. **`sign_update -s` 已是硬失败**，不只是废弃（Sparkle 2.9.6 `sign_update/main.swift:112`
   原话：*"This option is no longer supported for newly generated keys."*）。
   CI 里唯一正确的形式是 `echo "$KEY" | sign_update --ed-key-file - Surfclam.dmg`。
   **alt-tab-macos 的 `update_appcast.sh` 还在用 `-s`，别抄那一段。**
3. **绝不用 `releases/latest/download/appcast.xml`**——一次忘记 `make_latest: true`
   就会让那条固定 URL 永远喂旧版本，**完全静默**（manaflow-ai/cmux#9441）。
4. **appcast 放 GitHub Pages，不放 raw.githubusercontent**——后者被 GitHub 官方
   changelog 点名纳入未认证速率限制（2025-05-08），且有过返回陈旧内容/404 的记录。
   Pages 还白送正确的 `application/xml` MIME 与「appcast 和默认分支解耦」。
   AltTab（16.2k★）2026-04 正是这么搬的，但 **enclosure 仍留在 GitHub Releases**。

**最值得抄的模板**：[`sozercan/kaset`](https://github.com/sozercan/kaset)
的 `.github/workflows/release.yml`（2026-07 仍在维护，appcast 就托管在 GitHub 上，
端到端完整，设计理由写在它的 ADR 0007 里）。

## §9 执行日志

（每完成一个里程碑在此追加一行。）

- **2026-08-30 M5：Developer ID 签名 + Hardened Runtime + dmg + 公证** 完成
  （权威细节在 §4.2 / §4.2a / §4.3 / §4.4 / §4.4a / §5.2，这里只记决策与踩坑）。
  - **改了五处**：`project.yml` 的 entitlements 表加
    `com.apple.security.cs.disable-library-validation`；`embed-modules.sh` 改用
    `EXPANDED_CODE_SIGN_IDENTITY` + 条件化 timestamp/runtime、删掉那句死的外层重签、
    换掉已被证伪的顶注；`scripts/prebuild/Prebuild.swift` 在 `strip -x` 之后加签名
    （身份经 `prebuild-plugins.mjs` 从 spec 递进来）；新增
    `scripts/release-dmg.sh` + `scripts/dmg-settings.py`；`.gitignore` 收 `build-dist/`。
  - **entitlements 只留一份**（推翻 §4.3 早先那句"要两份"）：Debug 与分发的差别
    只有 `get-task-allow`，而那一项是 `CODE_SIGN_INJECT_BASE_ENTITLEMENTS` 注入的，
    不是我们写的。两份只差一个注入项的 plist 必然互相漂移。
  - **分发形态的四个 build setting 走 xcodebuild 命令行覆盖，不进 project.yml**：
    命令行优先级最高，于是**开发形态一个字都不受影响**——不然每台机器都得有
    Developer ID 证书才编得动。
  - **预编译 dylib 签在预编译工具里而不是打包脚本里**（§4.2a 三条理由）。
  - **六项验收全部实跑**：
    ① **现场编译的 ad-hoc dylib 在 Hardened Runtime 下照样 dlopen**——清空用户缓存 +
    从 bundle 里摘掉 `ClamPlugins/` 再重签，逼它走 swiftc，五个插件全部
    「现场编译」并装载（1.41 / 0.55 / 2.49 / 0.94 / 5.10 s），产出的 dylib 实测是
    `flags=0x20002(adhoc,linker-signed)`、`TeamIdentifier=not set`；
    ② 零编译启动：清空用户缓存、原样的 bundle，五个插件全是「bundle 预编译」；
    ③ `codesign -v --deep --strict` 过，entitlements 有 `disable-library-validation`、
    没有 `get-task-allow`，外层 `flags=0x10000(runtime)`；
    ④ 公证前 `spctl` = `rejected / source=Unnotarized Developer ID`，
    公证 + staple 后 = `accepted / source=Notarized Developer ID`（§4.4 有完整对照）；
    ⑤ dmg 挂载、拖出 app、`ULFO` + `Apple_APFS` 确认，3.8 MB；
    ⑥ 开发形态零回归：`./dev` 拉起的 Debug 壳仍是
    `Signature=adhoc` / `TeamIdentifier=not set` / 带 `get-task-allow` / 无 Hardened
    Runtime，嵌套 dylib 也是 ad-hoc，构建日志里
    `embed-modules: ClamSDK → Surfclam Dev.app（签名身份 -）`，插件热编译照常。
  - **顺手把 §4.3 那句"缺了它完全不像签名问题"验成了硬事实**（§4.4a 的控制组）。
    dyld 的原话是 `mapping process and mapped file (non-platform) have different
    Team IDs`——**通篇不提 "library validation"**，所以这条记进计划正文了。
  - **四个踩坑（都不报错或报得驴唇不对马嘴）**：
    ① **bash 3.2 + `set -u` + 全角括号**：`echo "… $WRAPPER_NAME（…）"` 会报
    `WRAPPER_NAME\357: unbound variable`——变量名把多字节字符的首字节吃进去了。
    构建当场失败，而看上去像 Xcode 没传那个环境变量。**这类 echo 一律写 `${VAR}`。**
    ② **`codesign -dv` 不打印 `Authority=` 行**（要 `--verbose=4`）：拿它做
    "是不是 Developer ID 签的"判据，会把**签得好好的**六个 dylib 全判成没签。
    ③ **`codesign … | grep -q` 在 `set -o pipefail` 下必然判失败**：`grep -q` 命中
    即退出，上游吃 SIGPIPE（141），整条管道于是"失败"。先取字符串再 grep。
    ④ **两个壳并发编同一份内容寻址目录会互相拆台**：报的是
    `input file '…/src/X.swift' was modified during the build` 和
    `no such module 'ClamLayout'`——**长得完全像签名/依赖出了问题**，其实只是
    测试环境里多起了一个壳。验这类事情之前先 `ps` 数一遍实例。
  - **公证记录**：app（zip）`be1b0d1f-6aa8-4f83-90a6-82c1ec962c4b`、
    dmg `eeca3454-5dc9-4fbf-bccc-0f7c95e8c19a`，两次都是 **Accepted**，
    各约 1.5～2 分钟。凭据走 keychain profile `surfclam`。
  - **`dmgbuild` 本机是 `uv tool install dmgbuild` 装的**（1.6.7）；系统 python3.9 的
    site-packages 要 sudo，别往那儿装。`release-dmg.sh` 找不到它会 fails loud 并给补法。
  - **还欠一条验收**：在一台没有开发者证书、没装过本 App 的机器上下载 dmg →
    拖进「应用程序」→ 双击。本机测不出 Gatekeeper 首次打开那一幕（§7.4）。

- **2026-08-30 M3：预编译 dylib + 解掉 §7.3 硬阻断 + 关掉 §7.10 轮询** 完成。
  - **A1 选了「`swift/` 打进 `ClamNode/<pkg>/`」**（§3.2a 记了两条路的取舍与
    "三方逐字节一致"的实测）。`ClamPlugins/<Module>/sources/` 随之删掉——
    bundle 里源码只剩一份，预编译读的就是它。
  - **不重新实现任何一段 hash 算法**：桥那半边抽成
    `clam-bridge/lib/swift-payload.js`（桥与构建脚本共用）；壳那半边由
    `scripts/prebuild/` 那个工具把 `Native/CompilerService.swift` **原样编进去**；
    `swiftDeps`/`sharedModules`/`schemaVersion` 由 `createSwiftPlugin` 挂的
    `clamSwift` 直接交出来（静态解析源码会静默出错）。
  - `CompilerService` 的两个落点做成同构的 `ProductRoot`，于是 M3-pre 那条
    `rpathReference(to:from:)` **一行没改就自动产出了 bundle 布局下的正确相对路径**
    ——`otool -l` 实测 `@loader_path/../../../ClamLayout/prebuilt/<hash12>`，
    与 §3.2 showstopper 2 的预言逐字相符。
  - 顺手清掉三样不该发出去的东西：`.dSYM`（五个共 **16 MB**）、
    `.swiftsourceinfo`（里面写着构建机的源码绝对路径）、上一版布局留下的
    `sources/`（prune 改成白名单：`<Module>/` 底下只许有 `prebuilt/`）。
  - **`strip -x` 定案：做**（§2.1 那条"待验证"作废，实测数据见那里）。
  - **七项验收全部实跑**：
    ① 端到端解阻断：清掉 `~/.dsh/profiles/surfclam` → 双击 App → 自举建 profile +
    拷镜像 + spawn 后端 → 五个插件全部登记装载，164 条会话的原生侧边栏出来；
    ② 零编译启动：清空 `native-plugins/` → 五个插件全是「bundle 预编译」，
    日志里「现场编译」**0 次**，`generations/` 目录压根没被创建；
    ③ 无工具链：`DEVELOPER_DIR=/nonexistent` 直接起 Release 壳（该环境下
    `xcrun --find swiftc` 退出码 1），五个插件照样全部装载、零编译；
    ④ `otool -l`：两条 rpath 都是相对的（`@executable_path/../Frameworks` +
    上面那条 `@loader_path`），把整个 bundle 拷到 `/tmp` 之后**单独 dlopen 依赖方**
    （不预装上游）仍然成功；
    ⑤ 优雅缺席：删光镜像里的 `swift/` → dsh 照常起、五条 warn、`HTTP 200`；
    ⑥ 开发循环零回归：改一行 `.swift` → **1.56 s** 完成热替换
    （轮询发现 → 编译 0.54 s → 换代 g2→g6）；桥侧单测：仓库源码 511 ms 发现改动，
    带 `.clam-static` 的同一份 5 s 内不动；
    ⑦ 体积：`/Applications/Surfclam.app` **7.90 MB**（预算 7.5 MB，超 5%，
    差额是原预算没算的 `.swiftmodule`）。
  - **一个测试环境里踩到的坑（不是本轮引入的，但值得记）**：两个壳共用
    `<AppSupport>/native-plugins/generations/`，同时对同一个 hash 现场编译会
    互相踩 `src/`，报 `input file … was modified during the build` 或
    `ld: open() failed`。CLAUDE.md 里"别的 worktree 的壳会串进来"说的就是这件事，
    正式形态下不会发生（那时全部命中预编译，根本不编）。
  - **一个当场修掉的小 bug**：`ensurePolling` 在**登记表变空**时也会打印
    「全是分发载荷，轮询已关闭」——dsh 收摊时各插件逐个撤销登记，最后一轮的表
    是空的，那句话既是假的、又长得恰好像正式形态的正常日志。加了
    `registry.size > 0` 的守卫。

- **2026-08-30 M4：砍掉壳自构建、清理 npm 路径** 完成。
  - **构建代码整体拆出 `lib/`**（用户当天追加裁决："更新完之后的代码里，
    就不该再包含重新构建壳的部分"——不是"运行时不执行"，是**不在包里**）。
    新目录 `clam-app/host-build/`：`index.js`（257 行：`ensureBuilt` / `runBuild` /
    `watchSources` / `hasXcode` / `locateExistingProduct` / `buildLogPath` /
    `productPath` / `XCODEGEN` / 一个 cwd 恒为 `HOST_DIR` 的 `run`）+
    `source-hash.js`（132 行，从 `lib/` 搬过来）。`lib/index.js` **997 → 674 行**。
    新增 `lib/util.js`（75 行）放两半边共用的 `run` / `errorText` /
    `readTextOrUndefined` / `delay` / `resolveProfileName`——单独成模块只为避免
    `lib/index.js` ↔ `host-build/index.js` 的静态循环依赖。
    判据随之从"探 `host/project.yml` 在不在"升级成
    **`await import("../host-build/index.js").catch(…)`**，写在 `lib/index.js`
    的**顶层**（`apply` 是同步的，而发现文件第一拍就要写对 `appPath`；
    dsh 的 loader 本来就是 `await import(entry)`，顶层 await 对它透明）。
    只有 `ERR_MODULE_NOT_FOUND` 算降级，别的错如实报出来——开发期写坏了
    `host-build/`，症状该是一行响亮日志而不是"构建怎么不跑了"。
    连带：`host/scripts/build.sh` 那两行 `node ../lib/source-hash.js` 改成
    `../host-build/source-hash.js`（这是唯一一处越过"别动 host/scripts"的编辑，
    2 个 token，不动别的）。
  - `clam-app/package.json` 的 `files` 白名单去掉 `host/*` 四项，只剩 `lib`：
    `npm pack --dry-run` **20.2 KB / 4 个文件**（`README.md` + `lib/index.js` +
    `lib/util.js` + `package.json`，此前 2.8 MB）——**包里一行构建代码都没有**。
    `.npmignore` 里那些收拾 `host/` 残留的规则也没用了，改成一句"host/ 的缺席是有意的"。
  - **`hostDir` 不再无条件写进发现文件**：没有构建能力就没有 `host/`，
    写一个不存在的绝对路径只会误导读日志的人。Swift 侧 `ClamEndpoint.hostDir`
    本来就是 `String?`，`isOwn` 退到 `appPath` 那条判据（Release 壳本来也只能靠它）。
  - `clam-app/lib/index.js`：形态判据从环境变量 `CLAM_RELEASE` 改成模块级常量
    `HAS_HOST_SOURCES = existsSync(host/project.yml)`。源码不在场时
    `applySourceAbsentForm` 关掉 `build` / `watch` / `restartOnRebuild`，
    **`launch` 不关**（理由见 §3.3 的落定框）。删掉 `isReleaseForm` /
    `applyReleaseForm` / `RELEASE_ENV`，以及它们唯一的下游
    `installBuiltProduct` / `refreshIconCache` / `LSREGISTER`
    （"构建完 ditto 进 `/Applications`"那条支路，连带 `ensureBuilt` 与
    `watchSources` 的 `install` 参数）。`locateExistingProduct` 去掉第三跳。
  - **实测抓到一个不删就发不了车的 bug**：`run()` 的所有调用点都把 `HOST_DIR`
    当 cwd 传，而**源码不在场时那个目录不存在**——`execFile` 的 cwd 不存在会让
    **任何**命令都起不来，报的却是 `spawn open ENOENT`（ENOENT 说的是 cwd，
    不是那个二进制）。症状链很误导：`isRunning` 的 `pgrep` 先静默失败 → 判成
    "App 没在跑" → 去 `open` 一次 → `open` 自己也 ENOENT → 日志里一句
    "拉起 surfclam 失败（不重试）"，而 App 明明好端端地开着。修法是给 `run()` 一个
    中性 cwd 缺省（`homedir()`），`HOST_DIR` 只留给真正需要站在那儿的三条命令
    （xcodegen / xcodebuild / write-build-timestamp.sh）。
  - `Native/BackendManager.swift`：`resolvePlan()` 的 Release 分支不再
    `exec /usr/bin/env CLAM_RELEASE=1 …`（只删那一处，其余不动）。它防的那个
    失败模式——按 dev 形态跑、构建 Debug 产物、**再拉起一个 Surfclam Dev**——
    现在在结构上不可能了：镜像里没有 `host/`。
  - `surfclam/bin/surfclam.js`：删 registry 模式。`detectRepoRoot` 改成
    `resolveRepoRoot`（找不到兄弟插件源码就 fails loud，并给出两条去处：
    开发 `./dev`、日常用 dmg），`installInto` / `provision` / `defaultProfile` /
    `ensureXcodegen` / `findXcodegen` / `releaseInstall` 各自的 registry 分支
    随之消失，`installedXcodegenPath` 与 `XCODEGEN_IN_PACKAGE` 整个删掉，
    usage 与顶注改写。
  - 文档：`CLAUDE.md` 的「怎么把它跑起来」「`./release`」「两个开发循环」
    「构建与运行」「多 worktree」「分发形态」六处按 M2+M4 的既成事实改了
    （profile 改名、壳不再自构建、registry 模式没了、`surfclam` 与 `surfclam-dev`
    可并存）；`docs/extend/contracts.md` §10.3 从"一张环境开关表"改成"一个都没有了"；
    `clam-app/README.md` 同步。`docs/release-install-plan.md` 与
    `docs/archive/clam-connection-plan.md` 里的 `CLAM_RELEASE` **原样留着**——那两份是历史
    档案，正文不追新。
  - 五项验收全部实跑：
    ① `./dev` → profile `surfclam-dev`、Debug 壳构建（3.2s）并拉起、五个插件全部
       编译装载；改一行 `clam-layout/swift/ToolbarContribution.swift` → 登记表
       v6（轮询）→ clam-layout + 下游 clam-sidebar / clam-notify 级联重编，
       壳不重启。拆分之后又整跑了两遍：一遍验缓存路径（`Debug 产物已是最新…跳过构建`
       + `已拉起` + 五个"编译成功"），一遍验**构建路径**——碰一下
       `host/Sources/ClamEndpoint.swift` → `壳源码有变动，后台重建中…` →
       `壳已重建（2.1s）`，壳日志里 `[app-build] 壳构建：building` → `ready 9da6e346ffc0`。
       **`app-build` 那条提示通道原样健在**（§8 M6 要复用它）。
    ② `npm pack --dry-run` 见上（20.2 KB / 4 文件，无 `host/`、无 `host-build/`）。
    ③ **源码不在场**用一份真镜像验的（不是改名）：把 9 个包的
       `package.json` + `lib/` + `swift/` 拷进
       `~/.dsh/profiles/surfclam-m4probe/.surfclam/`（**必须在 profiles 树内**，
       否则撞 §1.2 事实 A：`@deepseek-ai/schemastery` 解析不到，实测复现了一次），
       手写 `link:` 行与 bundles 之后起 dsh。结果：一行
       「壳源码不在包里（…/.surfclam/clam-app/host/）——不构建、不盯源码；
       壳用既有产物 /Applications/Surfclam.app」、发现文件照写（`appPath` 正是
       `/Applications/Surfclam.app`）、五个 Swift 载荷全部登记、`dsh web` 起来、
       壳连上桥、**一次 xcodebuild 都没有**。拆分之后又整跑了一遍，那一行变成
       「这份 clam-app 不带构建能力（没有 host-build/，随包分发的那一半只有 lib/）」，
       发现文件里**没有 `hostDir` 字段**、`appPath` 正确。
       （`swift/` 也拷进去了是为了绕开 §7.3 那条 fails-loud——那是 M3 的地盘，
       不是本次要验的东西。）
    ④ `node --test clam-sidebar/test/*.test.js` 18/18 绿。
    ⑤ 全仓 grep `CLAM_RELEASE`：活代码里一处不剩，只剩两份历史档案与几条
       "这东西曾经存在"的注释。
  - **发现但没动的**：本机那个 `~/.dsh/profiles/surfclam` 仍是 §7.1 说的开发形态
    残留（10 条 `link:` 指向仓库），正跑着的 `/Applications/Surfclam.app` 的后端
    因此加载的是**仓库里**的 clam-app 而不是镜像。那是 M2 记下的一次性迁移，
    照它说的 `rm -rf ~/.dsh/profiles/surfclam` 即可。

- **2026-08-30 M2：profile 分片 + 自举** 完成。
  - `surfclam/bin/surfclam.js`：主 worktree 的 profile 改成 `surfclam-dev`
    （新常量 `MAIN_DEV_PROFILE`），`surfclam` 空出来给安装形态；`./release`
    的"只许主 worktree"检查改比对 `surfclam-dev`，并**删掉了它那一步
    `provision(RELEASE_PROFILE, …)`**——留着的话每跑一次 `./release` 就重新
    埋一份 §7.1 的开发形态残留，下一次自举必然 fails loud。补了一条
    `warnIfNoPayload()`：装完的 App 里没有 `Resources/ClamNode/` 就当场说一句
    （只警告，不拦）。顺带删掉死代码 `sleepMs` / `whichOrFail`（随 LaunchAgent
    退役失去唯一调用者，全仓 grep 确认过）。
  - 新增 `clam-app/host/Sources/Native/ProfileBootstrap.swift`（约 780 行，含一个
    **保序 JSON 编解码 `OrderedJSON`**——`JSONSerialization` 的字典无序，拿它
    读-改-写 `package.json` 会把用户 `dsh plugin add` 的行重排，那正是 §3.5
    纪律 1 禁止的"整体重写"）。`.stamp` 的 `sourceHash` **直接用 M1 那份
    `ClamPayload.json` 里的 `hash`**，不重算一遍。
  - `Native/BackendManager.swift`：`resolvePlan()` 由 `SpawnPlan?` 改成
    `Result<SpawnPlan, Unavailable>`，新增 `Unavailable.bootstrapFailed`；
    Release 分支在 spawn 之前跑自举（`Task.detached`，别占主线程）。
    Dev 壳有两条路都不自举：有 `./dev` 就跑它，没有就退到 `surfclam-dev`。
  - 连接页：缺 dsh 那一态多出**一行可拷贝的安装命令**（钉版本）+ 一句
    "登录 Shell 不读 `~/.zshrc`" 的解释，按钮标题换成「重新检测」。**不代劳安装**。
  - **实测抓到的一个 bug**：符号链接的相对目标多数了一层（`../../../` 而不是
    `../../`），`ls` 看着正常但 node 解析不到，于是 `dsh plugin add` 的
    reconcile **把解析不到的伞包从 `bundles` 里摘掉了**——静默降级成"没有任何
    surfclam 插件"。判据写在代码注释里了：链接在 profile 之下的深度 =
    `node_modules` 一层 + scope 那几层 = 包名的段数。
  - 六项验收全部实跑（结论见 §2.4 的"已验证"框与 §7.3 的实测框）：
    ① `./dev` → profile `surfclam-dev`，五个插件装载、161 条会话的原生侧边栏出来；
    ② 自举连跑两次，第二次 `REFRESHED=false MANIFEST=false LINKS=0`；
    ③ `dsh plugin add link:/tmp/fake-plugin` 之后再自举，那个包与它在
    `dependencies` 里的行都还在（自举那一次一个字节都没写）；
    ④ 把一行 link 改成指向仓库 → 自举 fails loud 并**没有覆盖**；
    ⑤ 全新 `DSH_HOME` 端到端跑通（heal 在 loadProfile 之前，实测 185 个包）；
    ⑥ `node --test clam-sidebar/test/*.test.js` 18/18 绿。
  - **顺带解锁**：常驻 App（profile `surfclam`）与主 worktree 的 `./dev`
    （profile `surfclam-dev`）**同时跑通，两份 endpoint 发现文件并存互不覆盖**
    ——这正是 M2 验收 ③，今天做不到。
  - **本机遗留的一次性迁移**：现有的 `~/.dsh/profiles/surfclam` 仍是开发形态
    （10 条 `link:/Users/wenbopan/Repos/surfclam/*`）。装上带自举的新 Release 壳
    之后第一次打开会撞上 §7.1 的检查并如实报出来；照它说的
    `rm -rf ~/.dsh/profiles/surfclam` 即可（会话与设置在 `~/.dsh` 顶层，不受影响）。

- **2026-08-30 M1 完成：bundle 载荷就位。**
  新增 `host/scripts/pack-payload.sh`（门卫：`$CONFIGURATION != Release` 直接 exit 0）
  + `pack-payload.mjs`（全部逻辑），挂在 `project.yml` 的 `postBuildScripts`
  里 `embed-modules.sh` 之后。装哪些包**解析 `surfclam/cordis.patch.yml`**
  （只认没被注释的 `name: "@wenbo/…"` 行，所以停用的插件自动不进包），
  module 名 `import` 自新抽出的 `clam-bridge/lib/module-name.js`。
  实测产物：**9 个包 / 5 个 Swift module / 75 个文件 / 853 KB**，
  `ClamNode` 516 KB + `ClamPlugins` 492 KB，与 §2.1 的预算（512 KB / ~490 KB）吻合；
  Release bundle **3.7 MB → 4.7 MB**（此步 +1.0 MB，§2.1 预算内，
  加上 M3 strip 后的 2.7 MB 预编译产物正好落在 7.5 MB 上）。
  跳过判据折进了「每个将要写入的文件的目标路径 + 变换后内容」「两个脚本自身」
  「包与 module 清单」三项（`build-modules.sh` 那条教训：判据里要含真正的输入），
  实测改版本号、改任一插件 `lib/` 都会重打，改回去就又跳过。
  Debug 构建打印一行「不打包载荷」后 exit 0，产物 `Resources/` 里没有这两个目录，
  `./dev` 循环耗时不变。签名结论见 §4.1（不破封印，不需重签）。
  副产物：`Contents/Resources/ClamPayload.json`（`{version, hash, packedAt,
  packages, modules}`）既是跳过判据也是给 M2/M3 读的清单。
