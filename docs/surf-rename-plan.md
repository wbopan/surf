# Surf 重命名计划

把整个项目从 **surfclam / clam-\* / Clam\*** 改名为 **Surf**。

**两份文档配套读**：本文是「怎么干」（决策、映射、里程碑、验证、收尾），
`surf-rename-anchors.md` 是「有什么」（866 行的全量锚点清单 + 10 个原子组）。
动手前先读本文 §1 与清单的「结论 B」，每完成一个里程碑在 §9 追加一行执行日志。

**这是本仓库第二次整体更名**（更早：DSHarness → dash → surfclam），
所以 §6.3 的档案处理照抄上一次的先例，不发明新办法。

## 0. 决策（2026-08-30 用户拍板）

| 问题 | 决定 |
|---|---|
| 命名映射 | **全线 surf**：两级名字（`surfclam` + `clam-`）合并成一个词 |
| 运行时字符串契约 | **一起改**，不留 clam 化石：UserDefaults 键、事件主题、WS 路径、UA 标记、页内桥全局名、URL 参数 |
| 本机旧状态 | **一次性清掉，不写任何迁移代码**（铁律 4） |
| 仓库目录 | 连根目录一起改成 `~/Repos/surf` |

**零外部约束**，这次可以一刀切：

- npm 上**从未发布过任何包**（`@wenbo/surfclam`、`@wenbo/clam-app` 全是 404），
  `@wenbo/surf` 也没被占。没有下游消费者。
- 只有 `origin` 一个远端，本地 `main` 领先它 3 个提交。
- 本机没有 LaunchAgent 残留（那一层 2026-08-30 已退役）。

### 四个待拍板的小决定（不阻塞开工）

1. **GitHub 仓库现在叫 `wbopan/dsh`**——不是 surfclam，是比 surfclam 还早一代的
   名字残留（DSHarness 时期）。要不要一并改成 `surf`？见 §6.2。这是唯一一件
   **仓库外**的动作，需要单独批准。
2. **`docs/archive/` 里 8 个文件名带 clam**，改不改是独立决定；改了要同步约 20 处
   交叉引用。默认不改（正文本来就不改）。
3. **`/Applications/Surf.app` 与第三方产品 Deta Surf 在 Dock / LaunchServices 里重名**
   ——只是本机观感问题，不影响功能。
4. **三个顺手项**（见 §附注）：删死词汇、修 4 处既有文档漂移、删 `removeLegacyDaemon`。

## 1. 映射总表

### 1.1 包与目录

| 现在 | 之后 |
|---|---|
| 伞包 `@wenbo/surfclam`（目录 `surfclam/`） | `@wenbo/surf`（目录 `surf/`） |
| `@wenbo/clam-app` … `@wenbo/clam-memory`（8 个） | `@wenbo/surf-app` … `@wenbo/surf-memory` |
| 目录 `clam-app/` `clam-bridge/` `clam-layout/` `clam-sidebar/` `clam-notify/` `clam-settings/` `clam-nativeify/` `clam-memory/` | `surf-app/` `surf-bridge/` … |
| bin 名 `surfclam` → `surfclam/bin/surfclam.js` | `surf` → `surf/bin/surf.js` |
| 插件间相对 import `../../clam-bridge/lib/plugin.js`（11 处） | `../../surf-bridge/lib/plugin.js` |
| client 半边 `__ModuleLoader__.load({ id: "@wenbo/clam-layout" })`（2 处） | `@wenbo/surf-layout` |

### 1.2 Swift

| 现在 | 之后 | 备注 |
|---|---|---|
| module `ClamSDK`（`Sources/ClamSDK/`，13 个文件） | `SurfSDK`（`Sources/SurfSDK/`） | 手写，必须手改 |
| `libClamSDK.dylib` | `libSurfSDK.dylib` | `Contents/Frameworks/` |
| `Clam*` public 类型（15 个顶层符号：`ClamPaths` `ClamEndpoint` `ClamEventBus` `ClamLocale` `ClamDisposable` `ClamHost` `ClamContributions` `ClamObjects` `ClamPlugin` `ClamRegistry` `ClamHooks` `ClamPluginHandle` `ClamStore` `ClamPayload` `ClamConversationSurface` …） | `Surf*` | 跨 dylib ABI 表面 |
| **`clam_plugin_entry`**（`@_cdecl` + `dlsym`）、`clamABIVersion` | `surf_plugin_entry`、`surfABIVersion` | **硬 ABI**：壳侧 typealias + dlsym + 5 个插件导出 + strip 白名单注释 + spike 复刻，同批 |
| 插件 module `ClamSidebar` / `ClamLayout` | `SurfSidebar` / `SurfLayout` | **自动推导**，见 §3 |

### 1.3 App 身份

| 现在 | 之后 |
|---|---|
| App 名 `Surfclam` / `Surfclam Dev` | `Surf` / `Surf Dev` |
| bundle id `io.wenbo.surfclam` / `.dev` | `io.wenbo.surf` / `.dev` |
| xcodeproj / target / scheme `surfclam` | `surf` |
| `Sources/surfclam.entitlements` | `Sources/surf.entitlements` |
| `/Applications/Surfclam.app` | `/Applications/Surf.app` |
| bundle 内 `Resources/ClamNode/` `Resources/ClamPlugins/` `Resources/ClamModules/` | `SurfNode/` `SurfPlugins/` `SurfModules/` |
| autosave 标识 `ClamMainWindow.v1`、`ClamMainSidebar.v2`、`ClamLayoutToolbar` | `SurfMainWindow.v1` … | 反正要丢，顺势 bump 版本后缀也行 |

### 1.4 落盘路径与本机状态

| 现在 | 之后 |
|---|---|
| `~/Library/Application Support/io.wenbo.surfclam/` | `…/io.wenbo.surf/` |
| profile `surfclam` / `surfclam-dev` / `surfclam-<worktree>` | `surf` / `surf-dev` / `surf-<worktree>` |
| 自举镜像 `<profile>/.surfclam/`（含 `.incoming` / `.old` 两个中间态） | `<profile>/.surf/` |
| 日志 `surfclam.<tag>.log` | `surf.<tag>.log` |
| 日志 `clam-app-build.<profile>.<配置>.log` | `surf-app-build.<profile>.<配置>.log` |
| 源码 hash marker `.clam-app-source-hash.<配置>` | `.surf-app-source-hash.<配置>` |
| UserDefaults 域 `io.wenbo.surfclam` / `.dev` | `io.wenbo.surf` / `.dev` |

### 1.5 运行时字符串契约

| 类别 | 现在 | 之后 |
|---|---|---|
| WS 路径 | `/clam/bridge` | `/surf/bridge` |
| 桥 wire 帧 | `{ plugin: "clam-settings" }` | `{ plugin: "surf-settings" }` |
| dlsym 入口 | `clam_plugin_entry` | `surf_plugin_entry` |
| cordis 服务 | `clamBridge` `clamApp` `clamPending` + 4 个 kebab 空标记 `clam-layout` `clam-sidebar` `clam-notify` `clam-settings`（含 `inject: [...]` 侧） | `surf*` / `surf-*` |
| 插件对象属性 | `clamSwift`（桥定义、prebuild 读） | `surfSwift` |
| UserDefaults 键 | `clam.connection.mode/state/fixedURL`、`clam.webQuery`、`clam.pageZoom`、`clam.sidebar.filter.*`，**外加没有点号的 `clamLocale`** | `surf.*` / `surfLocale` |
| 事件主题（18 条） | `clam.page.<type>`、`clam.toolbar.*`、`clam.window.title`、`clam.web.query`、`clam.app.relaunch`、`clam.menu.command`、`clam.locale`、`clam.notify.*`、`clam.sidebar.*`、`clam.layout.*`、`clam.endpoint*`、`clam.conversationSurface`、`clam.settingsOwner`、`clam.contribution.*` | `surf.*` |
| 保管箱键 | `clam.webView`、`clam.endpoint`、`clam.conversationSurface`、`clam.settingsOwner`、`clam.sidebar.snapshot`、`clam.notify.{inbox,presented,swept,currentSession}` | `surf.*` |
| 通知 identifier 前缀 | `"clam.<instanceTag>."` | `"surf.<instanceTag>."` |
| 跨 node/Swift 哨兵 id | `clam.sidebar.other`（**两地各一份**，契约表未收录） | `surf.sidebar.other` |
| 设置 ns | `clam-nativeify`、`clam-shortcuts`、`clam-notify`、`clam-memory` | `surf-*` |
| URL 参数 | `?clam-native-sidebar=1` | `?surf-native-sidebar=1` |
| UA 标记 | `Clam/1.0`，两处 `insideClam()` 判据 + dump-css 伪造 UA | `Surf/1.0` |
| 页内桥 | `window.__clam*`、页内 handler 名 `clam` | `window.__surf*` |
| CLI flag | `--clam-endpoint`、`--clam-bridge-path` | `--surf-*` |
| 环境变量 | `CLAM_SPIKE_*`、`CLAM_NOTIFY_SELFTEST` | `SURF_*` |
| CSS 自定义属性 | 35 个 `--clam-*`，**其中 4 个有 `@property` 注册块**（`--clam-tint`、`--clam-press-r`、`--clam-press-a`、`--clam-glass-glow-c`） | `--surf-*` |
| CSS 类 / data 属性 | `clam-blur` `clam-reduce` `clam-nofx` `clam-static` 等 | `surf-*` |
| 截图工具默认目标 | `tools/shot.swift` 的 `"Surfclam Dev"` | `"Surf Dev"` |

**三个免疫区，一个字都不用改**：`accessibilityIdentifier`（`sidebar.*`）、
命令 id、hook 名与槽名（`root` / `sidebar` / `toolbar`）——全部本来就不含 clam。
所以 peekaboo 脚本、AX 定位、快捷键的**用户取值**都不受影响（快捷键的 **ns 名**受影响）。

## 2. 规模

排除 `.git` / `node_modules` / `build` / `.scratch` / `docs/archive` 后：

| 形态 | 次数 |
|---|---|
| `clam-*`（含 CSS 变量与包名） | ~1800 |
| `Clam*` | ~1055 |
| `surfclam` / `Surfclam` | ~420 / ~117 |
| 含 clam 的文件/目录名 | 24 |
| `.gitignore` 含 clam 的行 | 8（含 6 条真锚点路径） |

## 3. 原子组

**全量 10 组在 `surf-rename-anchors.md` 的「结论 B」**，每组都写明了拆开之后的
失败症状——**十组里有七组是静默失败**，所以别指望编译器兜底。这里只提三件
最容易在施工时想漏的：

1. **改包名 = 改一切。** `clam-bridge/lib/module-name.js` 是「插件名 → Swift module 名」
   的唯一真相（`clam-sidebar` → `ClamSidebar`），所以改一个包名会**自动**带动
   module 名、编译缓存目录 `native-plugins/generations/<Module>/`、bundle 内预编译
   落点 `Resources/SurfPlugins/<Module>/`、桥 wire 帧的 `plugin` 字段。
   自动是好事，但意味着**任何一处手写的 `ClamSidebar` 字面量都会当场对不上**。
2. **`@property` 注册块**：4 个 CSS 变量注册过；只改用处不改注册，`var()` 解析不出来
   会让**整条 `box-shadow` 失效**，按钮表面整块塌掉——不是渐变失灵，是没了。
3. **xcodegen 路径三处硬编码**（`bin/surfclam.js:69`、`host-build/index.js:36`、
   `scripts/{dev,build}.sh`）。缺了会**安静地**毁掉整个壳：dsh 照常起、HTTP 200，
   只有一句「clam-app 优雅缺席」。

## 4. 里程碑

**动手前先停掉所有实例**（`pkill -f Surfclam`，Ctrl-C 掉在跑的 `./dev`）：
桥 500ms 轮询 `swift/`，改名过程中会触发大量无意义重编。

| # | 内容 | 判据 |
|---|---|---|
| M1 | **CSS**（原子组 7）：35 个 `--clam-*` → `--surf-*`，**含 4 个 `@property` 注册块**；`clam-blur` / `clam-reduce` / `clam-nofx` / `clam-static` 等类名 | `./dev` 起，玻璃按钮表面、字号、滚动模糊带照旧；client HMR 即可验 |
| M2 | **运行时字符串**（组 6、8 + 事件主题 + UserDefaults 键 + 保管箱键 + 服务名 + 设置 ns + flag + 环境变量）：Swift / node / client 三边同批 | 桥连上、侧边栏有数据、通知能弹、设置窗口能开、⌘N 有反应 |
| M3 | **ABI 与 SDK module**（组 1、2）：`ClamSDK` → `SurfSDK`、15 个 public 符号、`clam_plugin_entry`、`clamABIVersion`、bundle 内 `ClamModules` / `ClamPlugins` / `ClamNode` → `Surf*` | 全量重编后 8 个插件全部装载；⌥⌘D 里 module 名是 `Surf*`；**没有一句「SDK 版本不匹配？」** |
| M4 | **包名与目录**（组 3、9）：`git mv` 8 个插件目录 + 伞包目录，改 `package.json`、11 处相对 import、2 处 loader id、`cordis.patch.yml`、bin、`.gitignore` 6 条锚点 | `./dev` 重装 profile 后照常起；**浏览器控制台无 `loaded without registering`**；`git check-ignore -v surf-app/host/tools/xcodegen` 命中 |
| M5 | **App 身份与分发**（组 4、5、10）：bundle id、App 名、xcodeproj / target、entitlements、AppSupport 根、日志名、profile 名、镜像目录与 `assertNoForeignLinks` 判据、xcodegen 三处、`./dev` / `./release`、图标、`tools/shot.swift` | Debug 与 Release 都构建通过；`./release --status` 说得对 |
| M6 | **文档**：`CLAUDE.md`、`README.md`、`docs/**`（archive 正文除外）、`tools/*/README.md`、design 画板；`docs/README.md` 的旧名映射表追加一行 | §8 自检归零 |
| M7 | **收尾**：本机清理（§5）→ 端到端验证（§7）→ 本地目录改名（§6.1） | 双击 `/Applications/Surf.app` 能用 |

M1–M6 每步做完都应保持「`./dev` 能起、App 能用」。跨里程碑的中间态不保证。

## 5. 本机清理（一次性，不写迁移代码）

在 M7 执行。`~/.dsh` 下的**会话数据不动**，只清 surfclam 自己的东西：

```sh
pkill -f "Surfclam"                                          # 先停干净
rm -rf /Applications/Surfclam.app
rm -rf ~/.dsh/profiles/surfclam ~/.dsh/profiles/surfclam-dev
rm -rf ~/.dsh/profiles/surfclam-arch-coupling-audit           # 侧 worktree 的
rm -rf ~/Library/"Application Support"/io.wenbo.surfclam
defaults delete io.wenbo.surfclam
defaults delete io.wenbo.surfclam.dev
```

**顺序有讲究**：重命名后第一次启动之前，旧 dsh 必须全停、`endpoints/` 必须清空。
否则发现文件里写着旧 `appPath`，新壳按 `ClamEndpoint.isOwn` 判定「不是我这一套」，
退到邻居端点或连接页——而这个失败是安静的。

清掉的后果，全部可接受：

- **编译缓存全丢** → 首次启动全量重编 8 个插件（几十秒），别误判成卡死。
- **窗口几何、分栏宽度、工具栏显示模式回到默认**（autosave 标识变了）。
- **用户在 dsh 设置里改过的东西静默回默认**：自定义快捷键、对话区字号、header 模糊带
  开关、9 个通知开关、记忆目录——因为设置 ns 改名了，旧值留在 dsh 设置文件里当孤儿。
  连接偏好不用管，默认就是 `managed`。
- 旧 App 必须**先删再装新的**：bundle id 变了，LaunchServices 把两个当成不同 App，
  不删就会在 Dock 里并存。装完照例 `touch <bundle> && lsregister -f`。

### 一处不可回改的残留（接受）

`clam-memory` 把 `source.kind = "clam-memory"` **写进了 dsh 的会话记录**。已有会话里
那些标签不会变，界面上会同时出现 `clam-memory` 与 `surf-memory` 两种署名。
按铁律 1（我们只是壳）不去改 dsh 的数据。**记忆目录本身不含 clam，数据不丢。**

## 6. 仓库位置：本地目录、remote、GitHub

三样东西各自独立，别以为改一个就带动另外两个。

### 6.1 本地目录与 worktree

M7 最后一步，**必须在所有 worktree 都不在使用时做**：

```sh
mv ~/Repos/surfclam ~/Repos/surf
cd ~/Repos/surf && git worktree repair            # 修所有 worktree 的绝对路径
```

- 现存另一个 worktree `.claude/worktrees/arch-coupling-audit` 跟着走，`repair` 会把它的
  `.git` 指针与主仓库 `.git/worktrees/*/gitdir` 一起修好。
- profile 里的 `link:` 行是**绝对路径**（`link:/Users/wenbopan/Repos/surfclam/clam-app`），
  改名后全废——但 `./dev` 幂等重建，新 profile 名本来就是全新的，不用管旧的。
- 终端、IDE、shell 历史里的旧路径要自己重开。

### 6.2 GitHub 仓库与 remote（**仓库外动作，需单独批准**）

远程现在是 `https://github.com/wbopan/dsh.git`，GitHub 上的仓库名叫 **`dsh`**
——不是 surfclam，是**比 surfclam 还早一代**的名字残留（DSHarness 时期）。
仓库内容里一处都 grep 不到它，所以 §2 那张规模表不含这一项。

```sh
gh repo rename surf                                # 在 wbopan/dsh 上执行
git remote set-url origin https://github.com/wbopan/surf.git
```

- GitHub 会为旧名字保留**永久重定向**，克隆和 push 都不会立刻断——但 remote URL
  该改还是要改，否则以后看 `git remote -v` 会以为项目叫 dsh。
- 私有仓库，没有外部协作者，**改名不影响别人**。
- 另一个 worktree 的 remote 与主仓库共用同一份 config，改一次就够。
- 与本地目录名、profile 名、bundle id 全都不耦合，**什么时候改都行**，也可以不改。

### 6.3 archive 的处理

**`docs/archive/` 不改正文**（照 dash → clam 那次的先例）：它是历史档案，正文用的是
当时的写法。在 `docs/README.md` 的旧名映射表里追加一行
`surfclam / clam-* / Clam* → Surf / surf-* / Surf*`，叠在既有的 dash → clam 那条之上。

## 7. 端到端验证清单（M7）

1. `./dev` 起来，终端无 `ERR_MODULE_NOT_FOUND`，8 个插件全部装载。
2. **浏览器控制台干净**——没有 `bundle … loaded without registering`（loader id 那条）。
3. ⌥⌘D 诊断面板：端点、桥、插件世代、module 名全是 `Surf*`，无「SDK 版本不匹配？」。
4. 侧边栏有会话、搜索可用、三枚胶囊可切、「筛选」菜单在。
5. **页面是原生化的**（UA 门控那组拆开的症状就是「页面正常、只是没变原生」）：
   玻璃按钮、web header 52pt 单行、原生侧边栏取代 web 侧边栏。
6. 通知：触发一次待办，横幅弹得出来，按钮答案回得去。
7. 设置窗口 ⌘, 五栏都在，第五栏「连接」读写的是 `surf.connection.*`。
8. 快捷键：⌘N、⌘⇧[ ]、⌘⌥A、⌘⇧⌫（**焦点在输入框里也要好使**——影子菜单那条路）。
9. 下载与外链：会话导出 ZIP、正文外链。
10. `./release` 装 `/Applications/Surf.app`，⌘Q 后双击能自己起后端（托管形态）。
11. 改一行插件 `swift/` 存盘 → 1~3s 热替换生效。
12. `node --test surf-sidebar/test/*.test.js` 通过。

## 8. 收尾自检

```sh
# 正向：仓库里不该再有 clam（archive 与 README 换算说明除外）
grep -rIn --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=build \
     --exclude-dir=.scratch --exclude-dir=archive -i 'clam' .
```

**这条 grep 会剩下三类合法命中，别去动它们**：

| 保留 | 为什么 |
|---|---|
| `clamp` / `clamped` / `clampBody`（11 处） | 真·英文单词 |
| `exclamationmark.*`（5 处） | **SF Symbol 名**，改了图标就没了 |
| `docs/README.md` 的旧名映射表 | 那行就是用来解释 clam 的 |

**反向自检也有噪声**：`surface` / `Surface` / `SURFACES` 约 106 处，另有一个
`inSurf()` 函数（"in Surface" 的缩写）——它**恰好与新前缀同名**。反向查要写
`\bsurf\b` 或显式排除 `surface`。另有一处**碰不得**：`session.surface.nodes`
是 dsh 上游的 API 字段。

再核三件容易漏的：

- `git check-ignore -v surf-app/host/tools/xcodegen` —— `.gitignore` 那 6 条带锚点的
  规则必须跟着改名，否则 xcodegen 二进制和几百 MB 构建产物漏进库，而 `git status`
  在你注意到之前一直是干净的。
- `surf-app/host/tools/xcodegen` 在每个 worktree 里都得在（不入库，`./dev` 补）。
- `codesign -v` 一次 Debug 产物：`project.yml` 里各构建脚本的 `outputFiles` 跟着改了名
  ——漏了会间歇性跳过 `CodeSign`，症状是 `BUILD SUCCEEDED` 但封印过期，砸中的是公证。

## 附注：三个顺手项（默认不做，单独拍板）

1. **死词汇**：`ClamEventBus.Topic.activateWindow`（`clam.activateWindow`）全仓无人
   emit、无人 subscribe。与其跟着改名，不如删掉。
2. **4 处既有文档漂移**（调研顺带发现，与命名无关）：`docs/extend/contracts.md` §5 的
   `clam.page.locale` / `clam.page.debug` 实际不是主题且漏了 `dragPassthrough`；
   同文件 §10.3「环境开关一个都没有了」与仍然存在的 `CLAM_NOTIFY_SELFTEST` 冲突；
   `clam.sidebar.other` 未收录进契约表；`bin/surfclam.js:527` 的 `--status` 打印无后缀的
   `managed-dsh.log`，与实际写入的 `managed-dsh.<instanceTag>.log` 不符。
3. **`removeLegacyDaemon`**（清理已退役的 LaunchAgent `io.wenbo.surfclam.dsh`）：
   本机已无残留、从未对外分发，按铁律 4 可整段删。**但这不属于重命名。**

## 9. 执行日志

| 日期 | 里程碑 | 结果 |
|---|---|---|
| 2026-08-30 | 计划成文 | 本文 + `surf-rename-anchors.md`（866 行锚点清单）；决策见 §0 |
| 2026-08-30 | 补 §6.2 | 发现 GitHub 仓库名是 `wbopan/dsh`（比 surfclam 还早一代的残留），原计划只覆盖了本地目录 |
