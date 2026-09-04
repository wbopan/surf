# surfclam → Surf 重命名：命名锚点清单

> 调研产物，**不是计划**。写给「接下来要写重命名计划」的人。
>
> - 基线：共享 checkout `/Users/wenbopan/Repos/surfclam` 的**当前工作区状态**（含未提交改动）。
>   本 worktree 从同一 HEAD 分叉，差别只有 3 项与重命名无关的未提交改动。
> - 方法：全仓 `grep`/`find` + 逐文件源码核实 + 两个并行子代理分别穷举 Swift 类型/module 名
>   与运行时字符串契约。调研期间**未修改任何文件**。
> - 计数口径：「次数」多为**含该字符串的行数**（`grep -c`），不是字面出现次数；逐条核实过的
>   地方给的是精确行号。
> - 🔴 = **跨进程 / 落盘的外部锚点**（改了会影响已存在的本机状态）。

---

## 目录

- [0. 总览与排除项](#0-总览与排除项)
- [1. npm 包名与目录名](#1-npm-包名与目录名)
- [2. Swift 类型与 module 名](#2-swift-类型与-module-名)
- [3. Xcode 工程标识](#3-xcode-工程标识)
- [4. 落盘路径与本机状态](#4-落盘路径与本机状态)
- [5. UserDefaults 键](#5-userdefaults-键)
- [6. 运行时字符串契约](#6-运行时字符串契约)
- [7. 环境变量与 CLI](#7-环境变量与-cli)
- [8. accessibilityIdentifier](#8-accessibilityidentifier)
- [9. 文档与资源](#9-文档与资源)
- [10. 容易误伤的同形字符串](#10-容易误伤的同形字符串)
- [结论 A：改了会让本机已装状态失效的锚点](#结论-a改了会让本机已装状态失效的锚点)
- [结论 B：必须一次性同步改动的原子组](#结论-b必须一次性同步改动的原子组)
- [结论 C：与命名无关但影响施工的既有事实](#结论-c与命名无关但影响施工的既有事实)

---

## 0. 总览与排除项

排除目录：`.git`、`node_modules`、`build`、`build-dist`、`.scratch`、`.cache`。

| 区域 | 状况 |
|---|---|
| 非 archive 的命中文件 | **约 165 个**。命中最密的五个：`clam-nativeify/lib/client.js`(222 行)、`docs/extend/contracts.md`(104)、`clam-app/host/Sources/MainWindowController.swift`(104)、`clam-nativeify/README.md`(78)、`docs/extend/plugin-author-guide.md`(71) |
| `docs/archive/` | **15 个文件、889 行命中**。历史档案，正文保持原貌（其中 `phase2-clam-plugin-migration-plan.md` 用的还是更早的 `dash` / `dash-*` / `Dash*` 旧名）。按 `docs/README.md` §archive 的既定纪律，**这轮不改正文**，只需在 `docs/README.md` 那张旧名映射表里追加一行 `surfclam / clam-* / Clam* → Surf / surf-* / Surf*`。8 个文件名带 clam，见 §9 |

**这个仓库已经改过两次名**（`DSHarness → DeepSeek Harness → dash → Surfclam`）。
`clam-app/host/scripts/build.sh:66-67` 至今留着清理旧安装的那行：

```bash
# 清掉历次改名前的旧安装（DSHarness → DeepSeek Harness → dash → Surfclam）
rm -rf "${INSTALL_DIR}/DSHarness.app" "${INSTALL_DIR}/DeepSeek Harness.app" "${INSTALL_DIR}/dash.app"
```

这轮**必须在这一行追加 `Surfclam.app`**，理由见结论 A.1。

---

## 1. npm 包名与目录名

### 1.1 包名（9 个）

| 包名 | 目录 | 除 `package.json` 的 `name` 外还出现在 | 🔴 |
|---|---|---|---|
| `@wenbo/surfclam` | `surfclam/` | `bin/surfclam.js:63` `UMBRELLA`、`:72` `REQUIRED_BUNDLES`、**profile 的 `bundles` 清单**、`pack-payload.mjs:91/120/127` | 🔴 |
| `@wenbo/clam-bridge` | `clam-bridge/` | 伞包 deps、`cordis.patch.yml:13` | |
| `@wenbo/clam-app` | `clam-app/` | 伞包 deps、`cordis.patch.yml:19` | |
| `@wenbo/clam-layout` | `clam-layout/` | 伞包 deps、`cordis.patch.yml:36`；**`lib/client.js:32` 的 `__ModuleLoader__.load({id})` 必须逐字等于包名** | |
| `@wenbo/clam-sidebar` | `clam-sidebar/` | 伞包 deps、`cordis.patch.yml:39` | |
| `@wenbo/clam-notify` | `clam-notify/` | 伞包 deps、`cordis.patch.yml:44` | |
| `@wenbo/clam-settings` | `clam-settings/` | 伞包 deps、`cordis.patch.yml:47` | |
| `@wenbo/clam-nativeify` | `clam-nativeify/` | 伞包 deps、`cordis.patch.yml:53`（row id 是 `ui-clam-nativeify`）；**`lib/client.js:34` 的 loader id** | |
| `@wenbo/clam-memory` | `clam-memory/` | 伞包 deps、`cordis.patch.yml:61`、`README.md:1/115` | |

`cordis.patch.yml` 里的 **row id** 另有一套（与包名去 scope 后不完全相同）：
`clam-bridge` / `clam-app` / `clam-layout` / `clam-sidebar` / `clam-notify` / `clam-settings` / **`ui-clam-nativeify`** / `clam-memory`。

包名 → 目录名的映射规则写在 `surfclam/bin/surfclam.js:140-143`：

```js
/** `@wenbo/clam-app` → `clam-app`：包名去掉 scope 就是仓库里的目录名。 */
function dirOf(packageName) {
	return packageName.startsWith("@") ? packageName.split("/")[1] : packageName;
}
```

### 1.2 package.json 字段

| 字段 | 含 clam？ | 说明 |
|---|---|---|
| `name` | ✅ 9 处 | 见上表 |
| `bin` | ✅ 1 处 | 只有伞包：`{"surfclam": "./bin/surfclam.js"}`。⚠️ `pack-payload.mjs:122-130` 打包时**会把这个字段删掉**，否则 pnpm 为 `.bin/surfclam` 建软链而目标不存在 |
| `files` | ❌ | 全是 `["lib"]` / `["lib","swift"]` / `["bin","cordis.patch.yml"]` —— **重命名不影响** |
| `description` | ✅ 9 处 | 全部含 "clam" 或 "Surfclam" |
| `dependencies` | ✅ | 伞包列 8 条 `@wenbo/clam-*` |
| `exports` | ❌ | 全是 `./client` `./plugin` `./locale` `./store` `./paths` 这类相对路径 |

### 1.3 插件之间的相对路径 import（11 处代码 + 6 处文档）

```
clam-settings/lib/index.js:22                    ../../clam-bridge/lib/plugin.js
clam-nativeify/lib/index.js:46                   ../../clam-bridge/lib/plugin.js
clam-layout/lib/index.js:13                      ../../clam-bridge/lib/plugin.js
clam-sidebar/lib/index.js:70                     ../../clam-bridge/lib/plugin.js
clam-notify/lib/index.js:43                      ../../clam-bridge/lib/plugin.js
clam-notify/lib/locale.js:24                     ../../clam-bridge/lib/locale.js
clam-notify/lib/strings.js:19                    ../../clam-bridge/lib/locale.js
clam-app/lib/index.js:43                         ../../clam-bridge/lib/locale.js
clam-app/host/scripts/pack-payload.mjs:42        ../../../clam-bridge/lib/module-name.js
clam-app/host/scripts/pack-payload.mjs:43        ../../../clam-bridge/lib/swift-payload.js
clam-app/host/scripts/prebuild-plugins.mjs:39    ../../../clam-bridge/lib/swift-payload.js
```

文档里的同款（改目录名要跟着改）：
`docs/extend/plugin-author-guide.md:253`、`docs/internals/orchestration.md:132`、
`docs/internals/distribution.md:49`、`clam-bridge/README.md:61`、`clam-bridge/lib/plugin.js:10`、
`clam-app/host/scripts/pack-payload.mjs:15`。

spike 里的路径引用：
`docs/spikes/webpolicy/run.sh:6` `HOST=../../../clam-app/host`、
`docs/spikes/backend-spawn/run.sh:9` `.../clam-app/host/Sources/Native/ManagedProcess.swift`。

> 这些相对路径的前提是「所有 clam-* 是同一仓库里的兄弟目录」，而且**这个兄弟关系在分发镜像里
> 也必须成立**（`ClamNode/<pkg>/` → `<profile>/.surfclam/<pkg>/`）。目录一改，三处（源码、
> 打包脚本、镜像布局）都要同时改。

---

## 2. Swift 类型与 module 名

### 2.1 `ClamSDK`（module 名 = 编译参数 + 磁盘路径）

**Swift 常量（唯一）**：`clam-app/host/Sources/Native/CompilerService.swift:71`
`static let abiModule = "ClamSDK"`

**shell 参数**：
- `clam-app/host/scripts/build-modules.sh:74` `build_module ClamSDK Sources/ClamSDK`
- `clam-app/host/scripts/embed-modules.sh:45` `for module in ClamSDK`（`:55` 日志、`:26` `ClamModules` 落点）

**project.yml 三处**：`:38` `sources.excludes: ["ClamSDK"]`、`:61` `OTHER_LDFLAGS: -lClamSDK`、
`:91` `outputFiles: .../Frameworks/libClamSDK.dylib`。

module 名进磁盘路径的**全部位置**：

| 路径 | 出处 | 🔴 |
|---|---|---|
| `clam-app/host/Sources/ClamSDK/`（源码目录名） | project.yml:38、build-modules.sh:74 | |
| `host/build-sdk/libClamSDK.dylib`、`ClamSDK.{swiftmodule,swiftinterface,swiftdoc}`、`.ClamSDK.hash` | build-modules.sh | |
| `<App>.app/Contents/Frameworks/libClamSDK.dylib` | embed-modules.sh:47/53、project.yml:91 | 🔴 |
| `@rpath/libClamSDK.dylib`（install_name） | build-modules.sh:65 | 🔴 |
| `<App>.app/Contents/Resources/ClamModules/ClamSDK.swiftinterface` | embed-modules.sh:26/51、CompilerService.swift:344（运行时读目标三元组） | 🔴 |

各插件 `swift/` 里 **18 处 `import ClamSDK`**，另有 4 处 `import ClamLayout`
（clam-sidebar ×2、clam-notify ×2）。

### 2.2 `Clam*` public 类型（= 跨 dylib ABI 表面，15 个顶层符号）

全部在 `clam-app/host/Sources/ClamSDK/`：

| 类型 | 文件 | 种类 |
|---|---|---|
| `ClamBridge` | `ClamBridge.swift` | class |
| `ClamContributions` (+ `.Contribution`) | `ClamContributions.swift` | class + struct |
| `ClamEventBus` (+ `.Topic`) | `ClamEventBus.swift` | class + enum |
| `ClamHooks` | `ClamHooks.swift` | class |
| `ClamHost` | `ClamHost.swift` | final class |
| `ClamLocale` | `ClamLocale.swift` | enum |
| `ClamLocaleStore` | `ClamLocale.swift` | class |
| `ClamObjects` (+ `.Key`) | `ClamObjects.swift` | class + enum |
| `ClamPlugin` | `ClamPlugin.swift:53` | **protocol（唯一的跨 dylib 协议见证表）** |
| `ClamDisposable` | `ClamPlugin.swift:73` | final class |
| `ClamPluginHandle` | `ClamPlugin.swift:92` | final class |
| `extension ClamDisposable` | `ClamPlugin.swift:114` | extension（`kept(by:)`） |
| `ClamRegistry` (+ `.Entry`) | `ClamRegistry.swift:15` | class + struct |
| `ClamStore` | `ClamStore.swift:10` | final class |

加一个 public 全局常量 **`clamABIVersion`**（`ClamPlugin.swift:38`，mangled 成
`ClamSDK14clamABIVersionSivp`）。

**壳内部（非 ABI）的 Clam* 类型**：
- `ClamEndpoint`（`Sources/ClamEndpoint.swift:5`，struct + `.Source` enum）
- `ClamPaths`（`Sources/ClamPaths.swift:5`，enum）
- `ClamWebView`（`Sources/Native/ClamWebView.swift:35`，WKWebView 子类）
- `ClamCommand`（`Sources/MainWindowController.swift:1647`）
- `ClamPluginEntry`（`Sources/Native/NativePluginHost.swift:19`，typealias）

**构建工具里的副本**：`clam-app/host/scripts/prebuild/Prebuild.swift:301` 另有一个独立的
`enum ClamPaths`（建在工具自己的 `Bundle.main` 上）。

**插件里唯一带 Clam 的类型**：
`clam-layout/swift/ConversationSurface.swift:12` `public protocol ClamConversationSurface`
——跨 dylib，被 clam-sidebar / clam-notify `import ClamLayout` 后消费。

### 2.3 插件 `swift/` 里非 Clam 前缀的类型

| 插件 | 顶层类型（节选，共 100+） |
|---|---|
| clam-layout | `LayoutPlugin`、`LayoutSplitController`、`LayoutSlots`、`LayoutToolbar`、`ToolbarSpec`、`ToolbarItemState`、`ToolbarContribution`、`WebViewConversationSurface`、`SidebarSlotView` |
| clam-sidebar | `SidebarPlugin`、`SidebarView`、`SidebarFilterState`、`SidebarShortcuts`、`AppSidebarModel`、`StatusIndicator`、`L`(Strings) |
| clam-settings | `SettingsPlugin`、`SettingsModel`、`SettingsWindowController`、`SettingsTabs`、`SettingsPage`、`SettingsSchema`、`SettingsBridge`、`ConnectionPage`、`PresetsPage`、`ModelsPage`、`PluginsPage`、`PluginInventoryList`、`GeneralPage`、`FieldRow`、`FieldNotes`、`JSONValue` |
| clam-notify | `NotifyPlugin`、`NotifyPresenter`、`NotifyCenter`、`NotifyModel` |
| clam-nativeify | `NativeifyPlugin` |

**一律以功能域命名、与 "clam" 无关，重命名时全部不动。**

### 2.4 module 名怎么生成（两级）

**第一级** —— `clam-bridge/lib/module-name.js:17-22`（顶注自称「这个映射的唯一真相」）：

```js
/** `clam-sidebar` → `ClamSidebar`。结果必须是一个合法的 Swift 标识符。 */
export function moduleName(plugin) {
	return plugin.split(/[-_]/).filter(Boolean)
		.map((part) => part[0].toUpperCase() + part.slice(1))
		.join("");
}
```

- **输入**：`createSwiftPlugin({ name })` 的**裸 kebab 包名**（不是 scoped 名）。
  `clam-bridge/lib/index.js:150-155` 会对非法结果 fails loud，错误文案里明写
  「别拿 scoped 包名（`@wenbo/clam-sidebar`）当 name」。
- **规则**：按 `-`/`_` 切分 → 每段首字母大写 → 直接 join。**没有前缀规则、没有 hash、没有缩写表。**
- 合法性正则：`clam-bridge/lib/index.js:73` `MODULE_NAME_RE = /^[A-Za-z_][A-Za-z0-9_]*$/`

**第二级** —— `clam-app/host/Sources/Native/CompilerService.swift:158-161`：

```swift
/// module 名后缀用 hash 前 12 位（十六进制，天然是合法标识符字符）。
private func moduleName(_ base: String, _ hash: String) -> String {
    "\(base)_h\(hash.prefix(12))"
}
```

→ 形如 `ClamSidebar_hd3ad2136c6e9`。逆运算 `baseModule()`（`CompilerService.swift:332-335`）
按**最后一个 `_h`** 回溯切分。

**module 名的消费点**：

| 消费点 | 位置 | 🔴 |
|---|---|---|
| `swiftc -module-name <M>_h<hash12>` | CompilerService | |
| dylib 文件名 `lib<M>_h<hash12>.dylib` | CompilerService、prebuild-plugins | 🔴 |
| `.swiftmodule` 文件名 | CompilerService | |
| `-install_name @rpath/lib<M>_h<hash12>.dylib` | CompilerService | 🔴 |
| 下游链接 `-l<M>_h<hash12>` + `-module-alias <M>=<M>_h<hash12>` | CompilerService | |
| **用户缓存** `native-plugins/generations/<Module>/<hash12>/` | NativePluginHost.swift:101/105 | 🔴 |
| **bundle 预编译** `Contents/Resources/ClamPlugins/<Module>/prebuilt/<hash12>/` | NativePluginHost.swift:103、prebuild-plugins.sh:4 | 🔴 |
| `Contents/Resources/ClamPlugins/<Module>/sources/` | pack-payload.sh:5 | 🔴 |
| `ledger.json` 的世代账 | NativePluginHost.swift:106 | 🔴 |
| `ClamPrebuilt.json` 清单 | prebuild-plugins.mjs:155 | 🔴 |
| 临时目录 `/tmp/clam-prebuild-<M>_h<hash12>/` | prebuild-plugins.mjs:163 | |
| ⌥⌘D 诊断面板、clam-settings 的插件清单 UI | DiagnosticsPanel / PluginsPage | |

### 2.5 `@_cdecl` / dlsym 入口符号

**`clam_plugin_entry`** —— 含 clam，是壳与**每一个**插件 dylib（含 bundle 内预编译产物）
之间的硬 ABI。

| 角色 | 位置 |
|---|---|
| 协议文档 | `ClamSDK/ClamPlugin.swift:45-46` |
| 壳侧 typealias | `Native/NativePluginHost.swift:19` `ClamPluginEntry` |
| 壳侧 `dlsym` | `Native/NativePluginHost.swift:333` |
| 插件导出 ×5 | `clam-sidebar/swift/SidebarPlugin.swift:8`、`clam-settings/swift/SettingsPlugin.swift:6`、`clam-layout/swift/LayoutPlugin.swift:7`、`clam-notify/swift/NotifyPlugin.swift:8`、`clam-nativeify/swift/NativeifyPlugin.swift:7` |
| strip 白名单注释 | `scripts/prebuild/Prebuild.swift:162-164`（`-x` 只动局部符号，点名保留它） |
| spike 复刻 | `docs/spikes/m2-abi/host/main.swift:177`、`plugins/alpha/AlphaPlugin.swift:98` |

---

## 3. Xcode 工程标识

| 项 | 值 | 位置 | 🔴 |
|---|---|---|---|
| project 名 / target 名 / scheme 名 | `surfclam` | `project.yml:1`、`:33`；`.xcodeproj` 目录 `clam-app/host/surfclam.xcodeproj/`（被 `.gitignore:2` 的 `*.xcodeproj/` 挡在库外，xcodegen 生成） | |
| `.xcodeproj` 路径硬编码 | `surfclam.xcodeproj` | `clam-app/host-build/index.js:128` `"-project", join(HOST_DIR, "surfclam.xcodeproj")`；`build.sh:38` `xcodebuild -project "${TARGET_NAME}.xcodeproj"` | |
| bundleIdPrefix | `io.wenbo` | `project.yml:3` | |
| **PRODUCT_BUNDLE_IDENTIFIER** | `io.wenbo.surfclam.dev`（Debug）/ `io.wenbo.surfclam`（Release） | `project.yml:18` / `:22` | 🔴 |
| **PRODUCT_NAME** | `Surfclam Dev` / `Surfclam` | `project.yml:17` / `:21` | 🔴 |
| entitlements 文件 | `Sources/surfclam.entitlements` | `project.yml:112`（**xcodegen 每次照 `targets.surfclam.entitlements.properties` 那张表重写它**，手改静默丢失） | |
| 图标资源名 | `AppIcon` / `AppIconDev` | `project.yml:19/23` `APP_ICON_NAME`；`Icons/AppIcon.icon/`、`Icons/AppIconDev.icon/`；内部 `Shape.svg` / `Badge.svg` | ❌ 不含 clam |
| `Info.plist` | **零硬编码** | `Sources/Info.plist` 全走 `$(PRODUCT_NAME)` / `$(PRODUCT_BUNDLE_IDENTIFIER)` / `$(APP_ICON_NAME)` / `$(MARKETING_VERSION)` | ❌ 无需改 |
| 脚本常量 | `APP_NAME="Surfclam"`、`TARGET_NAME="surfclam"` | `build.sh:7-8`；`dev.sh:10-12`（另有 `RELEASE_NAME="Surfclam"`）；`release-dmg.sh:27-28` | |
| dmg 名 | `Surfclam-<版本>.dmg` | `release-dmg.sh:12` | |
| 签名环境变量 | `CLAM_SIGN_IDENTITY` | `release-dmg.sh:33` | |
| 预编译工具名 | `clam-prebuild` | `prebuild-plugins.sh:32` `TOOL="${OUT_DIR}/clam-prebuild"`；`Prebuild.swift:16/22` 用法文案 | |
| bundle 内目录/清单 | `ClamModules/`、`ClamPlugins/`、`ClamNode/`、`ClamPayload.json`、`ClamPrebuilt.json` | pack-payload.{sh,mjs}、prebuild-plugins.{sh,mjs}、project.yml:100/108、ProfileBootstrap.swift:89/101、NativePluginHost.swift:97/103、CompilerService.swift:39/86 | 🔴 |
| App 显示名硬编码 | `"Surfclam"`(fallback)、`"Surfclam Dev"`/`"Surfclam"` | `AppInfo.swift:10`；`host-build/index.js:44`；`clam-app/lib/index.js:65-66` | 🔴 |
| Swift 用户可见文案 | **全部走 `AppInfo.displayName`** | `Strings.swift:49/54/57` 等，零硬编码产品名 | ✅ 无需改 |

---

## 4. 落盘路径与本机状态（🔴 全部是外部锚点）

| 路径 | 定义处 |
|---|---|
| `~/Library/Application Support/**io.wenbo.surfclam**/` | `ClamPaths.swift:12`；`clam-app/lib/index.js:90`；`clam-app/host-build/index.js:39`；`surfclam/bin/surfclam.js:387/397`；`clam-settings/tools/probe.mjs:27` |
| └ `endpoints/<profile>.json` | `ClamPaths.swift:79` `endpointsDir`；`clam-app/lib/index.js:102` `ENDPOINTS_DIR`；`surfclam/bin/surfclam.js:403` |
| └ `logs/**surfclam**.log`（无 tag）/ `**surfclam**.<worktree>.log` | `ClamPaths.swift:61-64` |
| └ `logs/**clam-app**-build.<profile>.<配置>.log` | `clam-app/host-build/index.js:154`（覆盖写） |
| └ `logs/managed-dsh.log` / `managed-dsh.<worktree>.log` | `BackendManager.swift:125-126` |
| └ `native-plugins/generations/<Module>/<hash12>/` | `NativePluginHost.swift:101/105` |
| └ `native-plugins/store/<插件名>.json` | `ClamStore.swift:8/17`、`NativePluginHost.swift:90`（文件名就是 `clam-sidebar.json` 这种） |
| └ `native-plugins/ledger.json` | `NativePluginHost.swift:106` |
| profile 名 `**surfclam**`（安装形态专属） | `ProfileBootstrap.swift:57` `profileName`；`surfclam/bin/surfclam.js:384` `RELEASE_PROFILE` |
| profile 名 `**surfclam-dev**`（主 worktree） | `surfclam/bin/surfclam.js:79` `MAIN_DEV_PROFILE`；`BackendManager.swift:408` `devProfile` |
| profile 名 `**surfclam**-<worktree 目录名>` | `surfclam/bin/surfclam.js:162/165` |
| `~/.dsh/profiles/<profile>/**.surfclam**/`（+ `.surfclam.incoming`、`.surfclam.old`，内含 `.stamp`） | `ProfileBootstrap.swift:61` `mirrorDirName`、`:358-359` |
| `<profile>/package.json` 里的 `link:./.surfclam/<pkg>` 行 | `ProfileBootstrap.swift:18/116` |
| `<profile>/node_modules/@wenbo/<pkg>` → `../../.surfclam/<pkg>` | `ProfileBootstrap.swift:20/501` |
| `/Applications/**Surfclam**.app` | `surfclam/bin/surfclam.js:406` `INSTALLED_APP`；`clam-app/lib/index.js:128`；`build.sh`（`INSTALL_DIR`+`APP_NAME`）；`ClamEndpoint.swift:25`（注释） |
| `/Applications/Surfclam.app/Contents/Resources/ClamNode` | `surfclam/bin/surfclam.js:494` |
| LaunchAgent label `io.wenbo.surfclam.dsh` | **仅剩清理代码**：`surfclam/bin/surfclam.js:394` `DAEMON_LABEL` + `:400` `DAEMON_PLIST`（`removeLegacyDaemon`）；`BackendManager.swift:510` `daemonLabel`（托管 spawn 前查重问一句） |
| GCD queue label `io.wenbo.surfclam.backend-log` / `io.wenbo.surfclam.store` | `BackendManager.swift:577`；`ClamStore.swift:13`（进程内，**无外部影响**） |
| 构建 marker `host/build/.**clam-app**-source-hash.<配置>` | `clam-app/host-build/source-hash.js:44-45` |
| 分发载荷标记 `.**clam**-static` | `clam-bridge/lib/swift-payload.js:39` `STATIC_MARKER`；`pack-payload.mjs:193-195` 写入 |
| xcodegen 落点 `clam-app/host/tools/xcodegen` | `surfclam/bin/surfclam.js:69` `XCODEGEN_REL`（注释点名「clam-app/lib/index.js 与 host/scripts/{dev,build}.sh 都写死这条路径，改它要三处一起改」）；`host-build/index.js:36` |
| clam-memory 的记忆目录 `<dshHome>/memory/<slug>/` 或 `~/.claude/projects/<slug>/memory/` | `clam-memory/lib/paths.js:84-89` —— **不含 clam** ✅ 用户记忆数据不受重命名影响 |

---

## 5. UserDefaults 键（域 `io.wenbo.surfclam[.dev]`，🔴 全部）

| 键 | 定义处 | 备注 |
|---|---|---|
| `clam.connection.mode` | `Native/ConnectionController.swift:176` **+** `clam-settings/swift/ConnectionPage.swift:24` | **两处独立字面量**；键不存在 = `managed` |
| `clam.connection.fixedURL` | `Native/ConnectionController.swift:177` **+** `clam-settings/swift/ConnectionPage.swift:25` | 同上 |
| `clam.pageZoom` | `MainWindowController.swift:237` | ⚠️ `contracts.md` 未收录 |
| `clam.webQuery` | `MainWindowController.swift:483` | ⚠️ `contracts.md` 未收录 |
| `clamLocale` | `MainWindowController.swift:1242` | ⚠️ **驼峰无点号**，只匹配 `clam\.` 的正则会漏掉它 |
| `ClamMainWindow.v1` | `MainWindowController.swift:72` `windowAutosaveName` | 实际键是 `NSWindow Frame ClamMainWindow.v1`（`:327` 显式拼过一次） |
| `ClamMainSidebar.v2` | `clam-layout/swift/LayoutSplitController.swift:22` `sidebarAutosaveName`（`:191` 赋给 `splitView.autosaveName`） | 分栏宽度 |
| `ClamLayoutToolbar` | `clam-layout/swift/LayoutSplitController.swift:297` `NSToolbar(identifier:)` | **`:311` `autosavesConfiguration = true`** → 用户的工具栏显示模式按这个 id 持久化 |
| `clam.contribution.<owner>/<id>` | `clam-layout/swift/LayoutSplitController.swift:440` `contributionPrefix` | `NSToolbarItem.Identifier` 前缀，随上面那份 autosave 配置一起落盘 |
| `AppleActionOnDoubleClick` | `clam-layout/swift/LayoutSplitController.swift:287` | 系统键，**不动** |

另有落在 `host.store`（→ `native-plugins/store/clam-sidebar.json`）里的三个键，
定义于 `clam-sidebar/swift/SidebarFilter.swift:52-54`：
`clam.sidebar.filter.mode`、`clam.sidebar.filter.hiddenGroups`、`clam.sidebar.filter.showArchived`。

---

## 6. 运行时字符串契约

### 6.1 WS 路径

`/clam/bridge` —— 全仓唯一的 `/clam/*` 路径，**没有别的 HTTP 路由**。

| 位置 | 角色 |
|---|---|
| `clam-bridge/lib/index.js:53`（Config `path` 的 default） | **唯一真相**（用户可覆写） |
| `surfclam/cordis.patch.yml:15` `path: /clam/bridge` | 编排表里的显式值 |
| `clam-app/lib/index.js:116` `DEFAULT_BRIDGE_PATH` | 桥缺席时的兜底 |
| `clam-app/host/Sources/ClamEndpoint.swift:94` `defaultBridgePath` | Swift 侧兜底 |
| `clam-settings/tools/probe.mjs:67` | 探针拼 URL |
| `clam-app/host/Sources/Native/BridgeClient.swift:3` | 注释（实现走 `URLComponents`，不拼字符串） |

### 6.2 事件总线主题（`clam.*`）全量 18 条

**SDK 常量**（`ClamSDK/ClamEventBus.swift` 的 `enum Topic`）：

| 主题 | 行 | 粘性 | 备注 |
|---|---|---|---|
| `clam.endpointChanged` | :59 | 否 | 载荷 `["httpBase": String]` |
| `clam.activateWindow` | :61 | 否 | ⚠️ **死词汇，全仓无人收发** |
| `clam.page.`（前缀） | :68 | — | 页内桥消息前缀，**壳不设白名单** |
| `clam.page.currentSession` | :71 | ✅ | |
| `clam.page.ready` | :73 | 否 | |
| `clam.menu.command` | :76 | 否 | 载荷 `["command": String]` |
| `clam.locale` | :84 | ✅ | 值 `zh` / `en` |

**壳 / 插件私有**：

| 主题 | 定义处 | 粘性 |
|---|---|---|
| `clam.web.query` | `MainWindowController.swift:481` **+** `clam-layout/swift/LayoutPlugin.swift:26` | ✅ |
| `clam.app.relaunch` | `MainWindowController.swift:513` **+** `clam-settings/swift/ConnectionPage.swift:28` | 否 |
| `clam.connection.state` | `Native/ConnectionController.swift:532` **+** `clam-settings/swift/ConnectionPage.swift:26` | ✅ |
| `clam.page.keymap` | 动态（`clam-layout/lib/client.js:261` 发 `{type:"keymap"}`） | 否 |

**clam-layout 的 `LayoutToolbar`**（`clam-layout/swift/LayoutSplitController.swift:402-434`）：

| 主题 | 行 | 粘性 |
|---|---|---|
| `clam.toolbar.update` | :412 | 否 |
| `clam.toolbar.activate` | :419 | 否 |
| `clam.toolbar.menuSelect` | :421 | 否 |
| `clam.toolbar.menuOpen` | :423 | 否 |
| `clam.window.title` | :430 | ✅ |
| `clam.layout.titlebarMetrics` | :433 | ✅ |
| `clam.layout.newSession` | `LayoutPlugin.swift:17` | 否 |

> ⚠️ **文档漂移**：`docs/extend/contracts.md` §5 列的 `clam.page.locale` / `clam.page.debug`
> **在代码里不是主题**——`MainWindowController.handleBridgeMessage`(:1476-1521) 对
> `locale` / `debug` / `dragPassthrough` 做了特化分支且**不广播**。动态 `clam.page.<type>`
> 实际只有 `clam.page.keymap` 一条。

### 6.3 hook 名 —— **不含 clam** ✅

| hook | 定义处（壳） | 抄本（插件） |
|---|---|---|
| `system.notification.willPresent` | `Native/SystemDelegateRelay.swift:44` | `clam-notify/swift/NotifyCenter.swift:30` |
| `system.notification.response` | `Native/SystemDelegateRelay.swift:45` | `clam-notify/swift/NotifyCenter.swift:31` |

`ClamSDK/ClamHooks.swift` 里**一个具体 hook 名都没有**（顶注 :18-19 明说这是纪律）。

### 6.4 命令 id —— **不含 clam** ✅

| id | 声明处 | 应答处 |
|---|---|---|
| `openSettings` | `clam-layout/lib/index.js:28` **+** `clam-settings/lib/index.js`（两家各一次，先登记的赢） | `LayoutPlugin.swift:50` / `SettingsPlugin.swift` |
| `newSession` | `clam-layout/lib/index.js:36` | `LayoutPlugin.swift:52/61` |
| `stopGenerating` | `clam-layout/lib/index.js:47`（**无 `menu`**） | `clam-layout/lib/client.js` 的 `escStop` |
| `renameSession` | `clam-sidebar/lib/index.js:145` | `SidebarShortcuts.swift` |
| `archiveSession` | `clam-sidebar/lib/index.js:154` | 同上 |
| `focusSearch` | `clam-sidebar/lib/index.js:162` | 同上（按 `sidebar.search` 这个 AX id 现找） |
| `prevSession` | `clam-sidebar/lib/index.js:176` | 同上 |
| `nextSession` | `clam-sidebar/lib/index.js:189` | 同上 |
| `nextPendingSession` | `clam-sidebar/lib/index.js:200` | 同上 |
| `sessionDigits` → 派生 `selectSessionAt` | `clam-sidebar/lib/index.js:215/223` | 同上 |

自建菜单 id：`session`（`clam-sidebar/lib/index.js:177`）。壳自带菜单 id：
`app` / `file` / `edit` / `view` / `window` / `help`。
第三处抄了这些 id 的地方：`clam-settings/swift/FieldNotes.swift:158-174`（文案表）
与 `:264-266`（featured 排序）。

### 6.5 设置 namespace

| ns | 注册处 | 消费处 | key | 🔴 |
|---|---|---|---|---|
| `clam-shortcuts` | `clam-app/lib/index.js:220` `SHORTCUTS_NAMESPACE`、`:346` | `clam-layout/lib/client.js:49` `SHORTCUTS_NS`、`:247` `scope.bind({namespace})` | 动态 = 命令 id | 🔴 |
| `clam-nativeify` | `clam-nativeify/lib/index.js:114` | `clam-nativeify/lib/client.js:2243`；`clam-settings/swift/FieldNotes.swift:122/248` | `bodyFontSize`、`headerScrollBlur` | 🔴 |
| `clam-notify` | `clam-notify/lib/index.js:66/167` | Swift 半身经桥 | 9 个 bool | 🔴 |
| `clam-memory` | `clam-memory/lib/index.js:56` `SETTINGS_NS`、`:138` | 同文件 | `dir` | 🔴 |
| `ui-theme` | 上游的，**只读不注册** | `clam-nativeify/lib/index.js:58` `THEME_NS`；`clam-settings/swift/SettingsTabs.swift` | `preference` | ❌ 不动 |

> ns 名落在 **dsh 的设置存储**里（不在 profile 里）。改 ns 名 = 用户已保存的这些设置
> 全部静默回到默认值，旧值留在 dsh 设置文件里当孤儿。

### 6.6 URL query 参数

`clam-native-sidebar=1`

| 角色 | 位置 |
|---|---|
| 定义 | `clam-layout/swift/LayoutPlugin.swift:30` `nativeSidebarParam` |
| 生产 | `LayoutPlugin.swift:119-123`（emitSticky 到 `clam.web.query`） |
| 消费 | `clam-layout/lib/client.js:182` |
| 搬运（不认得参数名） | `MainWindowController.swift:429-439` `loadWebUI` |

### 6.7 UA 标记 `Clam/`

| 角色 | 位置 |
|---|---|
| 拼进 UA | `MainWindowController.swift:179` `config.applicationNameForUserAgent = "Clam/\(shortVersion)"` |
| 检测 ①  | `clam-nativeify/lib/client.js:904` `insideClam()` |
| 检测 ②  | `clam-layout/lib/client.js:173` `insideClam()` |
| 文档范例 | `docs/extend/plugin-author-guide.md:191` |
| **伪造（测试工具）** | `clam-nativeify/tools/dump-css.mjs:25` `{ userAgent: "Mozilla/5.0 Clam/1.0" }` |

**两处 `insideClam()` 各写一份、无共享常量**；加上工具里那份伪造 UA，共 4 个成员。
带斜杠是刻意的（防 `clam` 作为普通子串误命中）。

### 6.8 页内桥

| 项 | 值 | 位置 |
|---|---|---|
| WKWebView message handler 名 | **`clam`** | 注册 `MainWindowController.swift:181` `.add(..., name: "clam")`；分发 `:1477`；调用 `clam-layout/lib/client.js:195-196`、`clam-nativeify/lib/client.js:1222/1235` |
| 页内全局 | **`window.__clam`** | `clam-layout/lib/client.js:422`（方法 `selectSession` / `startSession` / `openSettings`） |
| 所有权标记 | `__clamToken` | `clam-layout/lib/client.js:426`、`:455`、`:457` |
| Swift 侧求值 | 拼 `window.__clam.*` 的 JS | `clam-layout/swift/ConversationSurface.swift:50-51` |
| 引用 | `clam-sidebar/swift/AppSidebarModel.swift:118` |

**不存在 `__clamActions` / `__clamReady`。**
`clam-nativeify/lib/client.js` **不装** `window.__clam`（顶注 :17-19 明说那归 clam-layout）。

上报的 `type` 值（都不含 clam）：`ready`、`currentSession`、`keymap`、`locale`、`debug`、
`dragPassthrough`。

### 6.9 CSS / DOM

| 类别 | 清单 |
|---|---|
| `<style>` id（3） | `clam-nativeify-style`（nativeify client:40 `STYLE_ID`，装 :1367 / 摘 :1365,:2212）、`clam-nativeify-font`（:52 `FONT_STYLE_ID`，装 :2222 / 摘 :2220,:2231）、`clam-layout-style`（layout client:38 `STYLE_ID`，装 :583 / 摘 :581,:620） |
| `<html>` data 属性（5） | `data-clam-nofx`（nativeify :148,1296,1300,1313）、`data-clam-blur`（:146,152,874,1297,1298,1312,1671,1682,1971)、`data-clam-reduce`（:152,156,874,1337,1338,1344,1969-1972）、`data-clam-webheader-noblur`（:875,2260,2261）、`data-clam-native-sidebar`（layout :39 `NATIVE_ATTR`，写 :614，清 :627-629，选择器 :591,596,607） |
| CSS 变量（35） | **layout ×1**：`--clam-sidebar-occupancy`（:40 `OCCUPANCY_VAR`，写 :547，清 :629，声明 :590）<br>**nativeify ×34**：`--clam-dur`、`--clam-dur-fast`、`--clam-dur-press`(已退休)、`--clam-ease`、`--clam-glass-blur`、`--clam-glass-drop`、`--clam-glass-edge`、`--clam-glass-edge-w`、`--clam-glass-fill`、`--clam-glass-glow-b`、`--clam-glass-glow-c`、`--clam-glass-glow-d`、`--clam-glass-glow-t`、`--clam-glass-outer`、`--clam-glass-sat`、`--clam-glass-side`、`--clam-menu-header`、`--clam-menu-sep`、`--clam-menu-text`、`--clam-press-a`、`--clam-press-glow`、`--clam-press-r`、`--clam-px`、`--clam-py`、`--clam-s`、`--clam-scroll-edge`、`--clam-surface`、`--clam-tint`、`--clam-tint-hover`、`--clam-tint-press`、`--clam-webheader-seg-fill`、`--clam-webheader-seg-sep`、`--clam-webheader-subtitle`、`--clam-webheader-title` |
| `@property` 注册块（4） | `--clam-tint`(:1861)、`--clam-press-r`(:1866)、`--clam-press-a`(:1871)、`--clam-glass-glow-c`(:1886) |
| 复合门控常量 | `MATERIAL_GATE = ':root:not([data-clam-blur]):not([data-clam-reduce]) '`（nativeify :152） |
| **CSS 类名** | **零** —— 两个 client 都不注入 clam 前缀的 class，靠 `[class*="_x"]` 与 `[data-slot]` 命中 ✅ |
| 实例 token 前缀 | `"dl"`（layout :168）、`"nf"`（nativeify :1174）—— **不含 clam，不用改** |

### 6.10 cordis 服务名（DI）

**含 clam 的驼峰「真服务」3 个**：

| 服务名 | provide 处 | inject 处 |
|---|---|---|
| `clamBridge` | `clam-bridge/lib/index.js:101` | `clam-bridge/lib/plugin.js:119`（工厂自动补给每个插件）、`clam-app/lib/index.js:424/460` |
| `clamApp` | `clam-app/lib/index.js:388` `ctx.provide("clamApp", undefined)`，`:536` `ctx.set("clamApp", {…})` | —— |
| `clamPending` | `clam-notify/lib/index.js:118` | `clam-sidebar/lib/index.js:277-278` |

**kebab-case 空标记服务 4 个**（经 `clam-bridge/lib/plugin.js:133` `ctx.provide(provide, {})` 动态注册）：

| 值 | 声明处 | 被谁 inject |
|---|---|---|
| `"clam-layout"` | `clam-layout/lib/index.js:17` | `clam-sidebar/lib/index.js:133`、`clam-notify/lib/index.js:89` |
| `"clam-sidebar"` | `clam-sidebar/lib/index.js:132` | —— |
| `"clam-notify"` | `clam-notify/lib/index.js:88` | —— |
| `"clam-settings"` | `clam-settings/lib/index.js:77` | —— |

`clam-nativeify` 与 `clam-memory` **不 provide 任何服务**。

同名的 Swift module 依赖声明：`swiftDeps: ["clam-layout"]`
（`clam-sidebar/lib/index.js:135`、`clam-notify/lib/index.js`）。

### 6.11 桥的 wire 帧里带插件名 🔴

桥协议的帧结构里 `plugin` 字段就是**裸插件名**，改包名即改 wire 内容：

| 位置 | 原文 |
|---|---|
| `clam-settings/tools/probe.mjs:86` | `{ type: "invoke", plugin: "clam-settings", action, payload: {...payload, id} }` |
| `clam-settings/tools/probe.mjs:115` | `if (frame.type !== "push" \|\| frame.plugin !== "clam-settings") return;` |
| `clam-settings/tools/probe.mjs:109` | `{ type: "hello", clientId: "clam-settings-probe", protocolVersion: 1 }` |
| `clam-bridge/lib/index.js:88` | `/** @type {Map<string, Registration>} 插件名 → 登记项 */`（登记表按插件名 keyed） |

帧型本身（`hello` / `snapshot` / `changed` / `push` / `invoke` / `action` /
`app-build` / `app-restart` / `announce`）**不含 clam** ✅。

### 6.12 保管箱键、通知前缀与其它

| 类别 | 字符串 | 位置 |
|---|---|---|
| `ClamObjects.Key`（4） | `clam.webView`、`clam.endpoint`、`clam.conversationSurface`、`clam.settingsOwner` | `ClamSDK/ClamObjects.swift:38/40/43/48` |
| clam-sidebar 保管箱 | `clam.sidebar.snapshot` | `clam-sidebar/swift/SidebarPlugin.swift:29` |
| clam-notify 保管箱（4） | `clam.notify.inbox`、`clam.notify.presented`、`clam.notify.swept`、`clam.notify.currentSession` | `clam-notify/swift/NotifyPlugin.swift:59/63/70/74` |
| 通知 identifier 前缀 | `"clam.\(instanceTag())."` | `clam-notify/swift/NotifyCenter.swift:49` |
| 跨 node/Swift 哨兵 id | `clam.sidebar.other` | `clam-sidebar/swift/SidebarFilter.swift:47` **+** `clam-sidebar/lib/dsh-source.js:233` ⚠️ 两边各一份，`contracts.md` 未收录 |
| 插件对象属性 | `clamSwift`（不可枚举） | 定义 `clam-bridge/lib/plugin.js:173`；读者 `clam-app/host/scripts/prebuild-plugins.mjs:86` `mod.default?.clamSwift` |
| **dsh 会话记录里的来源标签** | `clam-memory`（`source.kind`） | `clam-memory/lib/index.js:82` `SOURCE_KIND` —— 界面显示成 `Context injection · clam-memory`，**写进 dsh 会话数据** 🔴 |
| 日志前缀 | **没有 `[clam]`** —— node 侧是 `<包名>: `，Swift 侧 `Log.write(tag:)` 用 `bridge`/`app`/`menu`/`backend` 等，均不含 clam ✅ | |
| 槽名 | `root`、`sidebar`（`LayoutSlots.sidebar`，LayoutContracts.swift:23）、`toolbar`（`LayoutToolbar.slot`，LayoutSplitController.swift:404）—— **不含 clam** ✅ | |

---

## 7. 环境变量与 CLI

| 项 | 位置 | 🔴 |
|---|---|---|
| `CLAM_SIGN_IDENTITY` | `clam-app/host/scripts/release-dmg.sh:33` | |
| `CLAM_NOTIFY_SELFTEST` | `clam-notify/lib/index.js:251/257/259`；`clam-notify/README.md:209` | |
| `CLAM_SPIKE_NO_SYSTEM_APPEARANCE` | `docs/spikes/apple-visual-effect/{run.sh:5, Probe.swift:57, README.md:14/77}`；`docs/spikes/README.md:12` | |
| `CLAM_SPIKE_DUMP_MENU` | `docs/spikes/apple-visual-effect/Probe.swift:103/107`、`README.md:15/17/166` | |
| `CLAM_SPIKE_EMPTY_MENU` | `docs/spikes/apple-visual-effect/Probe.swift:26/109`、`README.md:17/167` | |
| `CLAM_SPIKE_DUMP_DELAY` | `docs/spikes/apple-visual-effect/Probe.swift:111`、`README.md:17` | |
| `CLAM_RELEASE` | **已删**，只在注释/文档里作为历史提及：`clam-app/lib/index.js:27`、`clam-app/README.md:116`、`Native/BackendManager.swift:443`、`docs/internals/distribution.md:175`、`docs/extend/contracts.md:392` | |
| `--clam-endpoint` | 读 `ClamEndpoint.swift:115`（也吃 `--clam-endpoint=`，`:126`）；写 `clam-app/lib/index.js:592` | 🔴 |
| `--clam-bridge-path` | 读 `ClamEndpoint.swift:118`；写 `clam-app/lib/index.js:593` | 🔴 |
| `--clam-backend-command` | `Native/BackendManager.swift:550/555` —— **只有 Dev 壳认**（判据是 bundle id 的 `.dev` 后缀） | |
| `--clam-backend-skip-dedup` | `Native/BackendManager.swift:557/560` —— 同上，只给实测用 | |
| bin 脚本 | `surfclam/bin/surfclam.js`（709 行），bin 名 `surfclam` | |
| `./dev` | 2 处：`exec node "$(dirname "$0")/surfclam/bin/surfclam.js" "$@"` + 注释 | |
| `./release` | 4 处：同上 + `--release`；注释里 2 处 `/Applications/Surfclam.app` | |
| `tools/shot.sh` | 3 行命中（`:2` `给 Surfclam 窗口截图`、`:5`/`:6` 提到 `clam-app`） | |
| `tools/shot.swift` | 3 行：`:24` `var needle = "Surfclam Dev"`（默认目标）、`:45` 帮助文本、`:100` 注释 | |

### `surfclam/bin/surfclam.js` 顶层常量（逐字）

| 行 | 原文 |
|---|---|
| 60 | `const UMBRELLA_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "..");` |
| 63 | `const UMBRELLA = "@wenbo/surfclam";` |
| 69 | `const XCODEGEN_REL = "clam-app/host/tools/xcodegen";` |
| 72 | `const REQUIRED_BUNDLES = ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app", UMBRELLA];` |
| 79 | `const MAIN_DEV_PROFILE = "surfclam-dev";` |
| 384 | `const RELEASE_PROFILE = "surfclam";` |
| 387 | `const APP_BUNDLE_ID = "io.wenbo.surfclam";` |
| 394 | `const DAEMON_LABEL = "io.wenbo.surfclam.dsh";` |
| 397 | `const APP_SUPPORT = join(homedir(), "Library", "Application Support", APP_BUNDLE_ID);` |
| 400 | ``const DAEMON_PLIST = join(homedir(), "Library", "LaunchAgents", `${DAEMON_LABEL}.plist`);`` |
| 403 | ``const ENDPOINT_FILE = join(APP_SUPPORT, "endpoints", `${RELEASE_PROFILE}.json`);`` |
| 406 | `const INSTALLED_APP = "/Applications/Surfclam.app";` |
| 409 | `const BUILD_SCRIPT_REL = "clam-app/host/scripts/build.sh";` |

本文件里出现的全部 profile 名字符串：
`"surfclam-dev"`（:79 定义；文案 :26、:497、:665）、
`` `surfclam-${basename(repoRoot)}` ``（:162、:165；文案 :27、:666）、
`"surfclam"`（:384 定义；文案 :33、:42、:150、:435、:443、:458、:538、
:540 `rm -rf ~/.dsh/profiles/${RELEASE_PROFILE}`、:647、:667、:674）。
`--profile <name>` 覆写口在 :627，`./release` 禁用它在 :646-648。

### 日志文件名模板（定义处）

| 模板 | 定义处 | 原文 |
|---|---|---|
| `surfclam.<instanceTag>.log` / `surfclam.log` | `ClamPaths.swift:62` | `let name = instanceTag.map { "surfclam.\($0).log" } ?? "surfclam.log"` |
| `managed-dsh.<instanceTag>.log` / `managed-dsh.log` | `BackendManager.swift:125` | `let name = ClamPaths.instanceTag.map { "managed-dsh.\($0).log" } ?? "managed-dsh.log"` |
| `clam-app-build.<profile>.<配置>.log` | `clam-app/host-build/index.js:154` | ``return join(APP_SUPPORT, "logs", `clam-app-build.${shard}.${configuration}.log`);`` |

> ⚠️ **已存在的不一致（顺手可修）**：`surfclam/bin/surfclam.js:527` 的 `--status` 打印的是
> **无 worktree 后缀**的 `managed-dsh.log`，而 `BackendManager.swift:125` 实际写的是
> `managed-dsh.<instanceTag>.log`。开发机上 `--status` 指的路径会是空的。

### 源码 hash 与 marker

`clam-app/host-build/source-hash.js`：

```js
35  const HASHED_ROOTS = ["project.yml", "Sources", "scripts", "Icons"];
38  const HASH_EXCLUDED = new Set(["Sources/Resources/BuildTimestamp.txt"]);
41  const HASH_SKIP_DIRS = new Set([".git", ".build", "build", "DerivedData", ".DS_Store"]);
44  export const hashMarkerPath = (configuration) =>
45      join(HOST_DIR, "build", `.clam-app-source-hash.${configuration}`);
```

marker 名：`.clam-app-source-hash.<Debug|Release>`。

| 动作 | 位置 |
|---|---|
| 写 | `clam-app/host-build/index.js:98`、`:193`；`clam-app/host/scripts/build.sh:89`（路径由 `:20` 调 `node ../host-build/source-hash.js marker "${CONFIGURATION}"` 取，`:88` mkdir，`:90` 打印） |
| 读 | `clam-app/host-build/index.js:69`、`:168`；CLI 子命令 `source-hash.js:122-127` |

**`tools/` 被 `HASHED_ROOTS` 明确排除**（注释 :34），所以拷 xcodegen 进去不会触发壳全量重建。

---

## 8. accessibilityIdentifier —— **完全不含 clam** ✅

三个前缀，全部与产品名无关：

| 前缀 | 具体 id |
|---|---|
| `sidebar.*` | `sidebar.search`（`SidebarShortcuts.swift:144` 按它现找）、`sidebar.list`（SidebarView:526/557）、`sidebar.empty`(:605)、`sidebar.group.<groupId>`(:182)、`sidebar.group.<id>.new`(:203)、`sidebar.group.<id>.toggle`(:230)、`sidebar.session.<sessionId>`(:88)、`sidebar.session.<id>.archive`(:130)、`sidebar.chips.<mode>`(:466)、`sidebar.addWorkspace`(:669) |
| `settings.*` | `settings.page.<tab>`（SettingsPage:25）、`settings.field.<ns>.<path>`（GeneralPage:100/158）、`settings.reset.<ns>.<path>`（FieldRow:148）、`settings.connection.mode`(:177)、`.fixedURL`(:198)、`.restart`(:214)、`.status`(:235)、`settings.plugins.section`（PluginsPage:40）、`settings.plugin.<ns>`(:112)、`settings.preset.<id>`（PresetsPage:76）、`settings.preset.default.<id>`(:109)、`settings.provider.<provider>`（ModelsPage:73）、`settings.inventory.search`（PluginInventoryList:95） |
| `toolbar.*` | `toolbar.sidebarFilter`（`clam-sidebar/swift/SidebarPlugin.swift:168`） |

**这一整类零改动**：重命名后 peekaboo 脚本与 AX 定位全部照常。
（两份 `Strings.swift` 的顶注——`clam-sidebar/swift/Strings.swift:17`、
`clam-settings/swift/Strings.swift:42`——都明写「定位标识与文案彻底解耦」。）

---

## 9. 文档与资源

| 文件 | 命中行数 |
|---|---|
| `README.md` | 32 |
| `CLAUDE.md` | 18 |
| `docs/README.md` | 12（含 archive 旧名映射表，**需追加一行**） |
| `docs/extend/contracts.md` | 104 |
| `docs/extend/plugin-author-guide.md` | 71 |
| `docs/extend/native-abi.md` | 17 |
| `docs/extend/dsh-wire-protocol.md` | 1 |
| `docs/extend/webview-native-feel.md` | 0 |
| `docs/internals/distribution.md` | 65 |
| `docs/internals/architecture.md` | 43 |
| `docs/internals/orchestration.md` | 30 |
| `docs/internals/connection.md` | 24 |
| `docs/internals/dsh-upstream-gaps.md` | 1 |
| `docs/use/install.md` | 17 |
| `docs/sidebar-redesign-plan.md` | 5 |
| `docs/design/web-header/Spec.dc.html` | 1 |
| `docs/design/settings-layout/README.md` | 1 |
| `tools/apple-kit/README.md` | 1（`:50` 提到 clam-nativeify） |
| `tools/shot.sh` | 3 |
| `tools/shot.swift` | 3 |
| 各包 README（8 份） | nativeify 78 / app 32 / bridge 24 / notify 18 / sidebar 16 / settings 12 / memory 10 / layout 10 |
| `clam-settings/tools/probe.mjs` | 12 |
| `clam-nativeify/tools/dump-css.mjs` | 3（`:9`、`:10` 命令行；`:25` 伪造 UA） |
| `clam-memory/test/paths.test.js` | 12 |
| `clam-memory/test/store.test.js` | 3（含 `:15` tmpdir 前缀 `clam-memory-<tag>-`） |
| `clam-memory/test/prompt.test.js` | 2 |
| `clam-sidebar/test/dsh-source.test.js` | 2 |
| `clam-sidebar/test/fork-title.test.js` | 1（`:7` 用法注释 `node --test clam-sidebar/test/*.test.js`） |
| `docs/spikes/`（13 个文件） | m2-abi 那套含 **`sdk/ClamSDK.swift`**（文件名）与 `clam_plugin_entry`；`webpolicy/main.swift:10` 提到日志路径；`apple-visual-effect/` 4 个 `CLAM_SPIKE_*` |

### 文件名含 clam / surfclam 的清单

**目录（9）**：`surfclam/`、`clam-app/`、`clam-bridge/`、`clam-layout/`、`clam-sidebar/`、
`clam-notify/`、`clam-settings/`、`clam-nativeify/`、`clam-memory/`
外加 `clam-app/host/Sources/ClamSDK/`。

**文件**：

```
surfclam/bin/surfclam.js
clam-app/host/surfclam.xcodeproj/            （.gitignore:2 挡住，xcodegen 生成）
clam-app/host/Sources/surfclam.entitlements
clam-app/host/Sources/ClamEndpoint.swift
clam-app/host/Sources/ClamPaths.swift
clam-app/host/Sources/ClamSDK/ClamBridge.swift
clam-app/host/Sources/ClamSDK/ClamContributions.swift
clam-app/host/Sources/ClamSDK/ClamEventBus.swift
clam-app/host/Sources/ClamSDK/ClamHooks.swift
clam-app/host/Sources/ClamSDK/ClamHost.swift
clam-app/host/Sources/ClamSDK/ClamLocale.swift
clam-app/host/Sources/ClamSDK/ClamObjects.swift
clam-app/host/Sources/ClamSDK/ClamPlugin.swift
clam-app/host/Sources/ClamSDK/ClamRegistry.swift
clam-app/host/Sources/ClamSDK/ClamStore.swift
clam-app/host/Sources/Native/ClamWebView.swift
docs/spikes/m2-abi/sdk/ClamSDK.swift
docs/archive/clam-connection-plan.md
docs/archive/clam-i18n-copy-review.md
docs/archive/clam-i18n-plan.md
docs/archive/clam-memory-plan.md
docs/archive/clam-notify-plan.md
docs/archive/clam-settings-plan.md
docs/archive/clam-shortcuts-settings-plan.md
docs/archive/phase2-clam-plugin-migration-plan.md
```

`use/`、`extend/`、`internals/` 三层的文件名**一个都不含 clam**。
archive 里不含 clam 的 6 个：`distribution-plan.md`、`architecture-coupling-audit.md`、
`p0-decoupling-plan.md`、`native-feel-upgrade-plan.md`、`web-header-native-match-plan.md`、
`native-subagent-catalog.md`。

### `.gitignore` —— 含 `clam` 共 8 行，含 `surfclam` **零行**

```
 9  clam-app/host/Sources/Resources/BuildTimestamp.txt
12  clam-app/host/build-sdk/
15  # 挡住它是对的，但**缺了它整个壳就没了**（clam-app 只留一句「优雅缺席」）——   ← 注释
19  # 一起吞掉——clam-nativeify/tools/dump-css.mjs 就这么在库外躺了一阵子。        ← 注释
20  /clam-app/host/tools/
66  /clam-app/host/*.png
69  /clam-app/host/build-prebuild/
72  /clam-app/host/build-dist/
```

> `:20` 那条带路径锚点的规则**必须跟着改目录名**，否则 xcodegen 二进制会漏进库；
> `:12`/`:69`/`:72` 漏改则 `build-sdk/`、`build-prebuild/`、393 MB 的 `build-dist/` 会漏进库，
> 而 `git status` 在你注意到之前一直是干净的。

---

## 10. 容易误伤的同形字符串

### 10.1 `clam` 作为普通英文/别的含义（无脑 `sed` 会误伤）

| 字符串 | 位置 | 次数 | 说明 |
|---|---|---|---|
| `clamp` / `clamped` / `clampBody` | `clam-memory/lib/store.js:136`（`function clamp`）、`:216`、`:217`；`clam-memory/test/store.test.js:128`（`tmpDir("clamp")`）；`clam-nativeify/lib/client.js:288`（`const clampBody`）、`:424`、`:2248`；`clam-app/host/Sources/MainWindowController.swift:255-257`（`let clamped`）；`clam-nativeify/README.md:257` | 11 | **真·英文单词** |
| `exclamationmark.*` | `clam-settings/swift/PresetsPage.swift:69/117`、`SettingsPage.swift:121`；`clam-app/host/Sources/ConnectionViewController.swift:146`；`clam-sidebar/swift/StatusIndicator.swift:45` | 5 | **SF Symbol 名，改了图标就没了** |

反向的坑：**`clamLocale` 这个 UserDefaults 键没有点号**，只匹配 `clam\.` 的正则会漏掉它。

### 10.2 `surf` 已在仓库里出现的地方 —— **全部是 `surface` 的子串**

这是本次重命名最大的撞名风险：

| 已有 | 位置 | 无脑替换后 |
|---|---|---|
| `--clam-surface`（nativeify 的核心 CSS 变量） | `clam-nativeify/lib/client.js:692,699,1714,1722,1753,1757,1810,1901,1904,1916,2042,2093`；README 8 处 | `--surf-surface` |
| `ClamConversationSurface`（public 协议） | `clam-layout/swift/ConversationSurface.swift:12` + 消费方 8 处 | `SurfConversationSurface` |
| `WebViewConversationSurface`、`ConversationSurface.swift` | `clam-layout/swift/ConversationSurface.swift:23`、`LayoutPlugin.swift:40` | 不变，但与 `Surf*` 前缀读起来纠缠 |
| `FLOAT_SURFACES`、`inSurf()` | `clam-nativeify/lib/client.js:201,207,208,976,1027,1037` | `inSurf` **已经与新前缀同名** |
| `rebuildLocalizedSurfaces()` | `MainWindowController.swift:1291/1301`、`Strings.swift:23` | 不变 |
| `surface.startSession(...)`、`ClamObjects.Key.conversationSurface` | 多处 | 键值 `clam.conversationSurface` → `surf.conversationSurface` |
| **`session.surface.nodes`** | `clam-memory/lib/index.js:301` | ⚠️ **dsh 上游的 API 字段，碰不得** |
| `--color-surface-*` | `docs/extend/webview-native-feel.md:253-254` | 上游 CSS token |

另有一条产品层面的考虑：**`/Applications/Surf.app` 与第三方产品 Surf（Deta Surf 浏览器）
在 Dock / LaunchServices 里重名**，值得先确认这是不是想要的。

---

## 结论 A：改了会让本机已装状态失效的锚点

### A.1 App 身份（换了就是一个全新的 App）

`io.wenbo.surfclam[.dev]` → 新 bundle id 意味着：

- **整个 UserDefaults 域换新** —— 窗口位置、分栏宽度、页面缩放、连接偏好、
  工具栏显示模式、界面语言全部回到默认；
- **通知授权要重新申请一次**（系统只为一个 app 弹一次窗，用户曾拒绝过的话再也弹不出来
  ——`NotifyCenter.swift:54-55` 记着这条）；
- Dock 图标位置丢失；
- 旧的 `/Applications/Surfclam.app` **不会被新 `build.sh` 认出来**
  ——必须在 `build.sh:67` 那行 legacy 清理里追加 `Surfclam.app`，
  否则用户机器上会同时躺着两个 App、两个托管后端抢同一件事。

### A.2 Application Support 目录

`~/Library/Application Support/io.wenbo.surfclam/` 改名后，下列内容全部「消失」：
endpoint 发现文件、日志（4 类）、插件编译缓存 `native-plugins/generations/`（可达几百 MB）、
`native-plugins/store/*.json`（侧边栏筛选偏好）、`ledger.json`。
缓存丢了只是第一次启动慢；但**旧目录不会自动清理**——要么在安装脚本里迁移，
要么明确留给用户手删。

### A.3 profile 名

`surfclam` / `surfclam-dev` / `surfclam-<worktree>` 三者都是 `~/.dsh/profiles/` 下的
真实目录。改名后：装好的 App 会**自举一个全新的 profile**（旧的 `surfclam/` 连同
`.surfclam/` 镜像成为孤儿），开发者的 `./dev` 也会新建 profile。
**dsh 的会话与设置数据不在 profile 里**（那是 dsh 的资产），所以用户不丢会话
——但插件的设置 ns 值会丢，见 A.4。

### A.4 设置 namespace（最容易被忽略）

`clam-shortcuts` / `clam-nativeify` / `clam-notify` / `clam-memory` 是
**dsh settings 存储里的键**，跟 profile 无关。改 ns 名 = 用户自定义的快捷键、
对话区字号、header 模糊带开关、9 个通知开关、记忆目录**全部静默回到默认值**，
且旧值仍留在 dsh 的设置文件里当孤儿。

### A.5 NSToolbar / autosave 标识

`ClamMainWindow.v1`、`ClamMainSidebar.v2`、`ClamLayoutToolbar` +
`clam.contribution.<owner>/<id>` —— 改了就丢窗口几何、分栏宽度、工具栏显示模式。
这三个本来就带版本后缀，借重命名顺势 bump 是合理的（反正要丢）。

### A.6 `clam-memory` 的 `source.kind`

它写进了 dsh 的**会话记录**。已有会话里那些 `clam-memory` 标签不会变，
界面上会同时出现新旧两种标签。记忆目录本身（`<dshHome>/memory/<slug>/`）不含 clam，
**数据不丢**。

### A.7 桥的 wire 帧

帧里的 `plugin` 字段是裸插件名（§6.11）。改包名 = 改 wire 内容
——`clam-settings/tools/probe.mjs` 这类外部客户端必须同步改，否则 `push` 帧被静默过滤。

### A.8 「不算失效但会静默走错」的一条

`ClamEndpoint.isOwn`（`ClamEndpoint.swift:46-51`）靠
`appPath == Bundle.main.bundlePath` 判定「这是不是我这一套」。
改名过程中如果旧 dsh 还在跑（发现文件里写着旧 `appPath`），新壳会判定「不是我这一套」，
退到邻居端点或连接页。
**重命名后第一次启动前，务必把所有旧 dsh 停掉并清空 `endpoints/`。**

---

## 结论 B：必须一次性同步改动的原子组

| # | 原子组 | 成员 | 拆开的后果 |
|---|---|---|---|
| **1** | **module 名 ↔ 编译缓存 ↔ bundle 布局** | `module-name.js` 的生成规则、`CompilerService.abiModule`、`build-modules.sh:74`、`embed-modules.sh:45`、`project.yml:38/61/91`、`Contents/Frameworks/libClamSDK.dylib`、`Contents/Resources/ClamModules/`、`native-plugins/generations/<Module>/`、`Contents/Resources/ClamPlugins/<Module>/` | **静默失效**：hash 对不上 → 预编译产物永远命中不了 → 退回现场编译；用户机器上没有 swiftc = **所有插件缺席**，日志里没有一句异常。`module-name.js:5-8` 与 `swift-payload.js:5-8` 两处顶注都为这个失败模式写过警告 |
| **2** | **ABI 三件套** | `ClamSDK` 的 15 个 public 符号 + `clamABIVersion` + `clam_plugin_entry` + 5 个插件的 `@_cdecl` 导出 + `ClamConversationSurface` | 改一半 = `dlsym` 找不到符号（响亮）或 `as? ClamPlugin` **静默失败**（不响亮，`NativePluginHost.swift:341-342` 会报「SDK 版本不匹配？」）。好消息：`.swiftinterface` 摘要进了 contentHash，所以改 SDK 会强制全量重编，不会出现新壳配旧插件 |
| **3** | **包名 ↔ 目录名 ↔ 相对 import ↔ 编排表 ↔ client loader id ↔ 服务名 ↔ wire 帧** | 8 个 `@wenbo/clam-*`、8 个目录、11 处 `../../clam-bridge/...`、`cordis.patch.yml` 的 8 个 `name` + 8 个 row id、2 处 `__ModuleLoader__.load({id})`、4 个 kebab 空标记服务、3 个驼峰服务、桥帧的 `plugin` 字段 | loader id 与包名不一致时：**node 终端一个字都没有**，只在浏览器控制台报 `bundle … loaded without registering "@wenbo/clam-layout"`，整棵 client 插件树加载失败。CLAUDE.md 记着上次加 scope 就栽在这儿 |
| **4** | **发现文件 ↔ flag ↔ profile 名 ↔ appPath** | `endpoints/<profile>.json` 目录、`--clam-endpoint` / `--clam-bridge-path`、`RELEASE_PROFILE` / `MAIN_DEV_PROFILE` / `defaultProfile()`、`ProfileBootstrap.profileName`、`BackendManager.devProfile`、`ClamEndpoint.isOwn` | 拆开 = 壳连错 dsh 或连不上，且**失败方向是安静的**：连上邻居 worktree，去编译别人的源码，错误原样落进自己的日志，读日志的人完全看不出它属于别人家 |
| **5** | **镜像目录 ↔ 自举 ↔ 迁移检查** | `.surfclam` / `.surfclam.incoming` / `.surfclam.old`、`ProfileBootstrap.assertNoForeignLinks`（判据是「link 目标在 `.surfclam/` 之内」）、`package.json` 里手写的 `link:./.surfclam/<pkg>` 行、`node_modules/@wenbo/<pkg>` 符号链接 | `assertNoForeignLinks` 会把改名后的 profile 当成「别人的 profile」而 fails loud（这其实是好事——响亮，`ProfileBootstrap.swift:298` 还给了补救命令）。但如果只改一半，符号链接会静默指空：`dsh plugin add` 与 `--dump-config` 都过、真 `import` 时才炸 |
| **6** | **UA `Clam/` ↔ 两处 `insideClam()` ↔ query 参数 ↔ 页内 handler `clam` ↔ `window.__clam` ↔ 伪造 UA** | `MainWindowController.swift:179/181`、`clam-nativeify/lib/client.js:904`、`clam-layout/lib/client.js:171/182/195/422/426`、`clam-nativeify/tools/dump-css.mjs:25` | 拆开 = 原生化 CSS 或原生侧边栏**静默不生效**（页面看着正常，只是「没变原生」）；dump-css 工具则会打出空 CSS |
| **7** | **CSS 变量族 ↔ `@property` 注册块** | 35 个 `--clam-*`，其中 4 个有 `@property` 注册（`--clam-tint`、`--clam-press-r`、`--clam-press-a`、`--clam-glass-glow-c`） | 只改用处不改注册：**未注册的自定义属性不参与插值**，且 `var()` 解析不出来会让**整条 `box-shadow` 失效**——按钮表面整块塌掉（`client.js:1859` 的注释就是这条） |
| **8** | **两地各写一份、无共享常量的若干组** | `"Clam/"`（nativeify + layout + dump-css）、`system.notification.*`（壳 + notify）、`clam.connection.{mode,fixedURL}`（ConnectionController + ConnectionPage）、`clam.connection.state`、`clam.app.relaunch`、`clam.web.query`（各两处）、`clam.sidebar.other`（`dsh-source.js:233` + `SidebarFilter.swift:47`）、`clam-shortcuts`（clam-app + clam-layout client） | 改一处漏一处 = **静默不一致**，界面上表现为「某个功能莫名其妙不生效」 |
| **9** | **`.gitignore` 锚点 ↔ 目录名** | `/clam-app/host/tools/`、`/clam-app/host/build-prebuild/`、`/clam-app/host/build-dist/`、`clam-app/host/build-sdk/`、`clam-app/host/Sources/Resources/BuildTimestamp.txt`、`/clam-app/host/*.png` | 忘了改 = xcodegen 二进制和几百 MB 的构建产物漏进库，而 `git status` 在你注意到之前一直是干净的 |
| **10** | **xcodegen 路径的三处硬编码** | `surfclam/bin/surfclam.js:69` `XCODEGEN_REL`、`clam-app/host-build/index.js:36`、`host/scripts/{dev,build}.sh` | `surfclam.js:66-68` 的注释亲自点名「改它要三处一起改」；缺了会**安静地**毁掉整个壳（dsh 照常起、HTTP 200，只有一句「clam-app 优雅缺席」） |

---

## 结论 C：与命名无关但影响施工的既有事实

1. **`docs/archive/` 是历史档案**，按 `docs/README.md` §archive 的既定纪律不改正文，
   只在那张旧名映射表（`docs/README.md:54-58`）里追加一行
   `surfclam / clam-* / Clam* → Surf / surf-* / Surf*`。
   8 个 archive 文件名带 clam；文件名改不改是独立决定，改了要同步约 20 处交叉引用。

2. **三个「免疫区」**：`accessibilityIdentifier`（§8）、命令 id（§6.4）、
   hook 名与槽名（§6.3、§6.12）——全部不含 clam。
   peekaboo 脚本、快捷键的**用户取值**、AX 定位都不受影响
   （快捷键的 **ns 名**受影响，见 A.4）。

3. **调研中顺带发现 4 处文档/代码漂移**，建议借这次重命名一并修正：
   - `docs/extend/contracts.md` §5 的 `clam.page.locale` / `clam.page.debug` 实际不是主题，
     且漏了 `dragPassthrough`；
   - 同文件 §10.3「环境开关一个都没有了」与仍然存在的 `CLAM_NOTIFY_SELFTEST` 冲突；
   - `clam.sidebar.other` 这个跨 node/Swift 的哨兵 id 未收录进契约表；
   - `surfclam/bin/surfclam.js:527` 的 `--status` 打印无后缀的 `managed-dsh.log`，
     与实际写入的 `managed-dsh.<instanceTag>.log` 不符。

4. **`ClamEventBus.Topic.activateWindow`（`clam.activateWindow`）是死词汇**
   ——全仓无人 emit、无人 subscribe。重命名时可以顺手删掉，而不是跟着改名。
