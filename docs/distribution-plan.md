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
   `docs/dsh-upstream-gaps.md`。钉版本 `@deepseek-ai/dsh@0.1.1-rc.2` 不是双保险，
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
      clam-layout/                        package.json + lib/（含 client.js）
      clam-sidebar/  clam-notify/  clam-settings/  clam-nativeify/  clam-memory/
      clam-app/                           package.json + lib/（**不含 host/**）
    ClamPlugins/                        ← 新增：Swift 载荷（原地用，不拷）
      ClamLayout/{sources/*.swift, prebuilt/<contentHash>/libClamLayout.dylib}
      ClamSidebar/ ClamNotify/ ClamSettings/ ClamNativeify/
    BuildTimestamp.txt                  （已存在）
```

**`ClamNode/` 里的目录结构与仓库根一一对应**，因为 clam-* 之间用相对路径 import
（`../../clam-bridge/lib/plugin.js`）——保持兄弟关系，那些 import 原样成立。

**体积预算**（2026-08-30 实测，决定这个布局可不可行）：

| | 大小 | 备注 |
|---|---|---|
| 今天的 Release `Surfclam.app` | 3.7 MB | 对照基线 |
| `ClamNode/`（9 个包的 `lib/` + `package.json`） | **512 KB** | 拷进 profile 的就是这些，拷贝成本可忽略 |
| `ClamPlugins/*/sources/`（5 个在役插件的 `swift/`） | ~490 KB | clam-header 停用，不打包 |
| `ClamPlugins/*/prebuilt/`（单代 dylib，未 strip） | 5.3 MB | ClamSettings 3.1 MB + ClamSidebar 1.3 MB 占了大头 |
| 同上，`strip -x` 之后 | **~2.7 MB** | 实测 ClamSidebar 1304 KB → 628 KB |

**新 bundle ≈ 7.5 MB，dmg 压缩后 3~4 MB。**

> **strip 是待验证项，不是既定动作**：`strip -x` 只去局部符号，理论上保留 dlopen /
> dlsym 需要的全局符号（`ClamPlugin` 协议见证表的入口），但**必须实测**装载仍然成功。
> 省下的 2.6 MB 不值得赌，验不过就不 strip。

**`ClamPlugins/` 不拷进 profile**：`swiftDir` 支持任意绝对路径（桥只 `statSync`
校验它是个非空目录，`clam-bridge/lib/index.js:147-158`），指向 bundle 内部即可。

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
→ M2 的验收必须包含**全新机器语义**（清空 `~/.dsh` 重来一次），确认
「自举 → spawn → dsh 填 node_modules → 插件加载」这个顺序不会在第一次就撞空。

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

**M3 的先决条件（showstopper，必须第一个修）**：
`CompilerService.toolchainFingerprint()`（`CompilerService.swift:211-220`）
把 **本机 `swiftc --version` 的输出**折进每个插件的 contentHash（`:215`）。
后果对预编译方案是致命的——**构建机算出的 hash 在用户机器上永远对不上**，
预编译 dylib 一次都命中不了，于是退回现场编译，而用户可能根本没有 swiftc，
结果是**插件全部缺席**。

更糟的是它在无 Xcode 的机器上不是"取不到值"而是**取到垃圾值**：
`/usr/bin/xcrun` 仍然存在，`runSwiftc` 不抛异常，而是返回非零状态**并把错误文本
当作 `output`**，那段错误文本被原样哈希进去。

**修法：删掉 `swiftc --version` 那一行**，让随 bundle 分发的
`ClamSDK.swiftinterface` 摘要（`:216`，`sharedModuleFingerprint`）独自承担
"工具链变了"的信号。它两边一致（就是同一个 bundle 里那份文件），
而且 `targetTriple()`（`:185-203`，直接从 `.swiftinterface` 头里抄目标三元组）
**已经在演示这个模式**。取舍：同源码 + 同 SDK、不同 swiftc 编出的产物会被认作同一
hash；但 `.swiftinterface` 里带着目标三元组与 Swift 版本，大部分工具链变化仍会反映
进去，可接受。

**第二个先决条件**：编译出的 dylib 今天烘焙着**绝对 rpath**
（`CompilerService.swift:142`、`:151`）。实测一份本机产物：

```
LC_RPATH  path /Users/…/.claude/worktrees/clam-i18n-plan/clam-app/host/build/…/
                Surfclam Dev.app/Contents/Frameworks
flags=0x20002(adhoc, linker-signed)
```

指向**另一个 worktree 的构建目录**，且是 ad-hoc / linker-signed。
要随 bundle 分发就必须改写成 `@executable_path/../Frameworks` 并用 Developer ID 签名。

现场编译那条路**不删**：它是第三方 Swift 插件的唯一出路，也是开发循环的地基。
**但它此后是「可选能力」而不是「启动前提」**：`swiftc` 不在就 warn 一句并跳过那个插件，
而不是让整个原生侧缺席。

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

`CLAM_RELEASE=1` 今天已经把 `build / watch / launch` 全关了，所以这一步是**把剩下
一半砍干净**：正式形态的包**根本不包含** `host/` 源码和 `build.sh`。
判据从「环境变量说别构建」改成「源码不在包里所以构建不了」——更诚实，也少一个旋钮。

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

### 4.2 四处必须改的（都很小，但缺一不可）

| 位置 | 现状 | 改成 |
|---|---|---|
| `embed-modules.sh:30` | `codesign --force --sign -` 给嵌套 dylib **ad-hoc 签名** | `--sign "${EXPANDED_CODE_SIGN_IDENTITY}"`。外层 Developer ID + 内层 ad-hoc = 公证直接拒 |
| `embed-modules.sh:30` | `--timestamp=none` | **去掉**。公证要求 secure timestamp |
| `embed-modules.sh:34` | 外层再 ad-hoc 重签一次 | **删掉**。今天是死动作（Xcode 13 行之后就替换掉了），但它是个活陷阱——写死了 `-`，阶段一旦被重排或脚本被单独执行，就会**静默把整个 App 降级成 ad-hoc** |
| `project.yml` | 未设 `CODE_SIGN_INJECT_BASE_ENTITLEMENTS`（默认 YES） | 分发配置显式设 **NO** |

关于最后一条：**当前 Release 产物上确实带着 `get-task-allow`**，实测——

```
$ codesign -dv --entitlements - /Applications/Surfclam.app
Signature=adhoc
  com.apple.security.app-sandbox    → false
  com.apple.security.get-task-allow → true
```

它是 `CODE_SIGN_INJECT_BASE_ENTITLEMENTS` 因为身份是 `-`（"Sign to Run Locally"）
而注入的。**公证对这个 entitlement 是直接拒绝**。
**要显式设 NO，不要指望"配了真身份 Xcode 就会自己去掉"。**

### 4.3 entitlements 必须改在 `project.yml` 里，不能改 plist

`project.yml:76-79` 声明了 `entitlements.properties`，所以
**每次 `xcodegen generate` 都会重写 `Sources/surfclam.entitlements`**，
手改静默丢失。这正是那种"修好一次、然后神秘地回退"的坑。

分发配置需要的 entitlements（Hardened Runtime 形态）：

- `com.apple.security.app-sandbox: false`（已有）
- `com.apple.security.cs.disable-library-validation: true`
  ——**热插件机制的存亡所系**。开了 Hardened Runtime（公证的前提）之后
  library validation 会拒绝 dlopen 非同 Team ID 签名的 dylib，
  而运行时 swiftc 编出来的正是这种。缺了它的症状是**所有插件装载失败**，
  且完全不像签名问题。
- **不要** `get-task-allow`（见 4.2）

Debug 与分发两份 entitlements 要分开（Debug 那份留着 `get-task-allow` 才能调试）。

### 4.4 剩下的（等调研）

`notarytool` 的命令序列、staple、以及 dmg 本身要不要签名公证。

## §5 dmg 打包

> 待填：调研进行中。

## §6 交付物清单

> 细节等重构影响面盘点回来补；这里是框架。

**新增**

| 文件 | 作用 |
|---|---|
| `clam-app/host/Sources/Native/ProfileBootstrap.swift` | 自举：建/校 profile、拷镜像、写 `package.json` 与符号链接、`.stamp`。**只在 Release 壳跑** |
| `clam-app/host/scripts/pack-payload.sh` | 把 `ClamNode/` + `ClamPlugins/*/sources/` 打进 bundle（M1） |
| `clam-app/host/scripts/prebuild-plugins.swift`（或复用 CompilerService 的可执行入口） | 构建期真编译一次，产出 `ClamPlugins/*/prebuilt/<hash>/`（M3） |
| `clam-app/host/scripts/release-dmg.sh` | 签名 → 公证 → staple → dmg（M5） |
| `clam-app/host/Sources/surfclam-release.entitlements` | Hardened Runtime 形态的 entitlements（与 Debug 那份分开） |

**大改**

| 文件 | 怎么改 |
|---|---|
| `clam-app/lib/index.js` | 砍构建/盯源码/拉起的正式形态分支；`host/` 不在包里时自然降级 |
| `clam-app/package.json` | `files` 白名单去掉 `host/*` |
| `surfclam/bin/surfclam.js` | 删 registry 模式；`defaultProfile` 主 worktree 改 `surfclam-dev`；`./release` 转薄封装 |
| `clam-app/host/scripts/embed-modules.sh` | 签名顺序重排（今天在 Xcode 签名之后 ad-hoc 重签） |
| `clam-app/host/project.yml` | Release 配置的签名身份、Hardened Runtime、entitlements 分叉 |
| `clam-bridge/lib/index.js` | `register()` 对 swiftDir 缺失从 fails loud 改成优雅缺席（§7.3） |
| `clam-app/host/Sources/Native/CompilerService.swift` | 查找顺序加「bundle 内预编译」一层 |
| `CLAUDE.md` | 「分发形态」「两个开发循环」「多 worktree」「构建与运行」四节都要重写 |

**删除**

| 目标 | 依据 |
|---|---|
| `surfclam.js` 的 registry 模式分支 | §3.3 |
| `CLAM_RELEASE` 环境变量旋钮 | 判据改成"源码在不在包里"，更诚实 |
| `clam-app` 的 `INSTALLED_RELEASE` 兜底 | 正式形态下产物路径是确定的 |
| `embed-modules.sh:34` 的外层 ad-hoc 重签 | §4.2，死动作 + 活陷阱 |
| `CompilerService.swift:215` 的 `swiftc --version` | §3.2 showstopper |
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
——`clam-app/lib/source-hash.js:32` 把 `project.yml` 算进源码 hash，
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

→ 正式形态必须关掉这个轮询（判据同样是"源码在不在可写位置"，
不是新加一个旋钮）。

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
| **M3** | **预编译 dylib**：编译入口从 `CompilerService` 抽成可执行、构建流水线跑一次真编译落进 `ClamPlugins/<Module>/prebuilt/<hash>/`；壳侧查找顺序加一层 | 清空 `~/Library/Application Support/io.wenbo.surfclam/native-plugins/` → 双击 App → **零次 swiftc 调用**（日志验证）→ 插件全部装载 |
| **M4** | **砍掉壳自构建**：`clam-app` 瘦身（`host/` 出 `files` 白名单、build/watch 只在源码在场时启用）；`surfclam.js` 删 registry 模式；`./release` 改成 dmg 流水线的薄封装 | `npm pack` 出来的 `@wenbo/clam-app` 不含 `host/`；`./dev` 全流程正常；`CLAM_RELEASE` 这个旋钮可以删掉 |
| **M5** | **签名 + 公证 + dmg**：entitlements 重写、`embed-modules.sh` 签名顺序重排、inside-out 逐个签、notarytool、staple、dmg 打包脚本 | **在一台没有开发者证书的机器上**下载 dmg → 拖进「应用程序」→ 双击 → 全流程跑通 |
| **M6** | **Sparkle 自动更新**（本轮不做） | —— |

**M6 的接口在本轮就要留好**（不实现）：
① `MARKETING_VERSION` 是唯一版本号（M1 已定）；
② 「换了 App 必须重启后端」这条链——Sparkle 更新后重启 App，
`managed` 形态下 App 重新 spawn 后端，天然闭合；连着外部 dsh 时需要提示，
提示通道就是今天那条 `app-build` 提示条（M4 里**不要删掉它**，只把触发源留空）。

## §9 执行日志

（每完成一个里程碑在此追加一行。）
