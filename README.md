# surfclam

一组 [cordis](https://github.com/shigma/cordis) 插件，外加一个极薄的 macOS 壳。
它们一起把 [`dsh`](https://github.com/deepseek-ai/deepseek-harness) 变成一个原生 Mac 应用——
但不是"用原生外壳包一层网页"那种做法：**界面本身就是插件**，用 Swift 写，
存盘一两秒后就在运行中的窗口里换掉，不重启任何进程。

```
┌─ 终端 ───────────────────────────────────────────────┐
│ $ dsh web --no-open                                  │
│   dsh 起来 → 加载插件树 → clam-app 构建并拉起 App    │
└──────────────────────────────────────────────────────┘
                        ↓ 它是 dsh 的客户端外设，不是宿主
┌─ Surfclam.app ───────────────────────────────────────┐
│  窗口 + 一个 root 槽 + swiftc 编译机                 │
│    root  ← clam-layout（分栏、工具栏、WebView 排版） │
│      sidebar ← clam-sidebar（原生会话列表）          │
│      主区    ← WKWebView（dsh 自己的 Web UI）        │
└──────────────────────────────────────────────────────┘
```

启动方向是反的，这是整件事的支点：dsh 先于 App 存在，于是它就是壳天然的
bootstrapper——壳的源码、构建、拉起全都收进一个插件（`clam-app`），
仓库里没有"特权目录"这种东西。

## 跑起来

前置：macOS 27+（部署目标钉在 `27.0`，见 `clam-app/host/project.yml`）、
完整 Xcode（`xcodebuild` 需要它，Command Line Tools 不够）、
Node `^22.19.0 || >=24.0.0`。

```bash
npm i -g @deepseek-ai/dsh@0.1.1-rc.2
```

用：

```bash
npx @wenbo/surfclam
```

改：**仓库放在哪里都行**，克隆下来跑一行——

```bash
./dev              # 装好 profile（名叫 surfclam）并前台起 dsh，端口交给 OS 挑
```

`./dev` 幂等，随便重复跑：它把本仓库的各插件 + 伞包 link 进 profile、校正 `bundles`、
补上让 `@deepseek-ai/*` 解析得到的那条符号链接，然后前台跑 dsh（总是带 `--no-open`，
免得 dsh 另开一个重复的浏览器标签页）。

首次会构建壳（分钟级），之后源码没变就秒起。窗口没弹出来就看终端——`clam-app:`
开头的那几行会说清卡在哪。

## 三个开发循环，快慢差两个数量级

| 改什么 | 怎么生效 | 耗时 |
|---|---|---|
| 插件的 `swift/` | 存盘即可。桥轮询发现 → 壳重编 → 世代热替换 | **1~3s，不重启任何东西** |
| 壳源码 `clam-app/host/` | clam-app 盯着它，改了后台重建，窗口右上角提示「重启生效」 | 重建 2s + 重启 |
| 插件的 `lib/*.js`、`package.json`、增删插件 | 必须重启 dsh（官方在 web bundle 下关了 node 侧 HMR） | 秒级 |

第一行是这个项目存在的理由。改 `clam-sidebar/swift/SidebarView.swift` 存盘，
一两秒后侧边栏就变了，**选中态和列表内容都还在**——因为数据面存在跨世代的保管箱里，
换的只是代码。编译失败会带文件行号打进 dsh 终端，旧世代继续在役，界面不变也不崩。

## 仓库里都有什么

```
surfclam/          伞 bundle @wenbo/surfclam：**本仓库唯一的编排表**（cordis.patch.yml
                   决定装哪些插件、什么顺序、什么配置），外加安装器/启动器 bin/surfclam.js
clam-app/          壳源码为载荷的插件：构建 + 写 endpoint 发现文件 + 拉起 App + 盯壳源码
  host/            Xcode 工程（project.yml / Sources/ / scripts/ / tools/）
clam-bridge/       唯一的特权插件：Swift 载荷登记表 + /clam/bridge WS + 盯 swift/ 目录
clam-layout/       占 root 槽：分栏、WebView 排版、sidebar 槽、开放的 toolbar 贡献槽；
                   client 半边装 window.__clam 动作桥 + 收起 web 侧边栏
clam-sidebar/      占 sidebar 槽：原生会话侧边栏。数据面在 node 半边
                   （订 dsh 的内部 API，投影经桥推给 Swift；Swift 只管画）
clam-notify/       桌面通知：不占槽、不贡献界面，缺席即无通知。同时是「有什么在等着你」
                   的唯一真相，经 clamPending 服务供给侧边栏那枚「待处理」胶囊
clam-settings/     原生设置窗口：不占槽、自己一扇窗，编排照抄 dsh 的 Web 设置对话框
clam-header/       原生会话 header（标识走 window.title/subtitle + 四格工具栏贡献）。
                   **2026-08-29 起在编排表里注释停用**，代码原样保留
clam-nativeify/    让 dsh Web UI 摸起来像原生 App：主力是 client 半边那段 CSS（有 HMR），
                   另有一个薄 Swift 载荷让原生侧跟随 dsh 的 ui-theme
tools/             跨包的开发工具（shot.sh 截图）。只服务一个插件的工具归那个插件
docs/              计划、ABI 实测结论、可复跑的 spike，以及下面这两份契约文档
```

写插件从这两份开始（外部作者不必读本仓库源码）：

- [`docs/plugin-author-guide.md`](docs/plugin-author-guide.md) —— 三种最小骨架、
  package.json 字段、命名规则、接进编排、外部热循环、五条硬规矩、失败症状表。
- [`docs/clam-contracts.md`](docs/clam-contracts.md) —— 契约总表：命令声明、
  toolbar 的 `ToolbarSpec` 与活通道、事件主题、保管箱键、hook 名、页内桥。

一个"带 Swift 载荷的插件"长这样——node 半边通常只有几行：

```js
import { createSwiftPlugin } from "../../clam-bridge/lib/plugin.js";
export default createSwiftPlugin({
  name: "clam-sidebar",
  provide: "clam-sidebar",
  inject: ["clam-layout"],      // cordis：layout 没挂好就不挂我
  swiftDir: new URL("../swift/", import.meta.url),
  swiftDeps: ["clam-layout"],   // 桥：上游换代时我自动跟着重编
});
```

（真正的 `clam-sidebar` 比这多一截：它的 node 半边还拿着整个数据面，
经 `subscribe`/`expose` 与 Swift 半身对话。数据放在这一侧是有意的——
壳随 app bundle 冻结，node 半边随 npm 可更新。）

Swift 半边导出一个 C 入口，拿到 `host` 就往槽里塞视图：

```swift
@_cdecl("clam_plugin_entry")
public func clam_plugin_entry() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(SidebarPlugin()).toOpaque()
}

final class SidebarPlugin: ClamPlugin {
    func activate(host: ClamHost) -> AnyObject? {
        let handle = ClamPluginHandle()
        host.register(slot: "sidebar") { AnyView(SidebarView(...)) }.kept(by: handle)
        return handle   // 壳松手 = 这一代退休，注册与订阅一并撤销
    }
}
```

## 热替换是怎么成立的

桥把每个插件的 `swift/` 目录扫成一份内容 hash，壳按这个 hash 做内容寻址编译：
**module 名就是 hash**（`ClamSidebar_ha502d7516810`）——缓存命中与世代类型隔离
是同一个事实的两面。装载走 `dlopen` + `dlsym` 拿到入口，`activate` 里的新注册
覆盖旧槽，然后壳松开旧 handle，旧的那一代自行退场。

三条硬事实，都是实测出来的（`docs/native-abi.md`）：

1. **旧 dylib 永不 `dlclose`**——对 Swift 不安全（类型元数据还被引用着）。
   代码页泄漏式退休，实例由 ARC 正常回收。
2. **上游换代、下游没重编 = 沉默的认知分裂**：下游不崩不报错，只是继续调旧代的代码。
   所以桥把上游的 hash 折进下游的 hash——级联重编由数据结构保证，不靠传播逻辑。
3. 共享 module（眼下只有 `ClamSDK`）必须**全进程只有一份 dylib**，壳和插件链同一个
   文件，类型身份才对得上。

坏插件不许拖垮系统：编译失败保持上一代在役；没有任何插件占 `root` 槽时，
壳退化成整窗 WebView——功能不缺，只是没有原生外壳。

## 诊断

`⌥⌘D` 打开诊断面板：连着哪个 dsh、桥通不通、每个插件是第几代跑的哪个 module、
退休了多少 image、壳自己最近有没有重建过。可拷贝。

日志在 `~/Library/Application Support/io.wenbo.surfclam/logs/`。

## Debug 与 Release

两个不同的 App，可并存运行：

| | Debug（日常开发） | Release（正式） |
|---|---|---|
| App 名 | Surfclam Dev | Surfclam |
| Bundle ID | io.wenbo.surfclam.dev | io.wenbo.surfclam |
| 标记 | 橙色 DEV 徽章（App 图标） | 无 |
| 位置 | `clam-app/host/build/Build/Products/Debug/` | `/Applications/` |

日常使用者应在自己 profile 的 `cordis.patch.yml` 里把 `clam-app` 的
`configuration` 覆写成 `Release`。手动构建走
`clam-app/host/scripts/dev.sh` 与 `build.sh`（`dsh web` 做的是同一套步骤）。

## 状态

阶段二迁移进行中，**M0～M8 已完成**。
唯一权威计划是 [`docs/phase2-clam-plugin-migration-plan.md`](docs/phase2-clam-plugin-migration-plan.md)
——它是**历史档案**，正文里的 `dash` / `dash-*` / `Dash*` 都是更名前的写法，
读之前先看 [`CLAUDE.md`](CLAUDE.md) 开头那张新旧名字映射。
给 agent 的工作须知也在 `CLAUDE.md`。

`dsh` 处于 developer preview，明示会有 breaking change：帧解析一律防御式
（未知帧忽略、异常不崩），CSS 选择器用语义后缀模糊匹配。验证于 `0.1.1-rc.2`。
