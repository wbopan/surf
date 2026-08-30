# surf

一组 [cordis](https://github.com/shigma/cordis) 插件，外加一个极薄的 macOS 壳。
它们一起把 [`dsh`](https://github.com/deepseek-ai/deepseek-harness) 变成一个原生 Mac 应用——
但不是"用原生外壳包一层网页"那种做法：**界面本身就是插件**，用 Swift 写，
存盘一两秒后就在运行中的窗口里换掉，不重启任何进程。

```
┌─ Surf.app ───────────────────────────────────────┐
│  窗口 + 一个 root 槽 + swiftc 编译机                 │
│    root  ← surf-layout（分栏、工具栏、WebView 排版） │
│      sidebar ← surf-sidebar（原生会话列表）          │
│      主区    ← WKWebView（dsh 自己的 Web UI）        │
└──────────────────────────────────────────────────────┘
        ↑ 壳是 dsh 的客户端外设，不是宿主
┌─ dsh 后端 ───────────────────────────────────────────┐
│  加载插件树 → surf-app 写下 endpoint、供壳发现       │
│  正式形态：App 打开时自己把它拉起来（打开即有）      │
│  开发形态：终端先跑起 dsh，由它构建并拉起 App        │
└──────────────────────────────────────────────────────┘
```

支点是这个方向：**壳的源码、构建、拉起全都收进一个普通插件（`surf-app`）**，
仓库里没有"特权目录"这种东西。

## 装

三步，没有第四步。用户机器上**不需要 Xcode、不需要 pnpm、不需要懂 cordis**。

```bash
npm i -g @deepseek-ai/dsh@0.1.1-rc.2     # 这一步我们不接管
```

然后下载 `Surf-<版本>.dmg`，拖进「应用程序」，双击。App 自己托管后端，
打开即有、⌘Q 即退。

详见 [`docs/use/install.md`](docs/use/install.md)——连接偏好、诊断、日志、卸载都在那儿。

## 改

前置：macOS 27+（部署目标钉在 `27.0`）、完整 Xcode（`xcodebuild` 需要它，
Command Line Tools 不够）、Node `^22.19.0 || >=24.0.0`。

**仓库放在哪里都行**，克隆下来跑一行：

```bash
./dev              # 装好 profile 并前台起 dsh，端口交给 OS 挑
```

`./dev` 幂等，随便重复跑：它把各插件与伞包 link 进 profile、校正 `bundles`、
补上让 `@deepseek-ai/*` 解析得到的那条符号链接，然后前台跑 dsh。首次会构建壳
（分钟级），之后源码没变就秒起。窗口没弹出来就看终端——`surf-app:` 开头那几行
会说清卡在哪。

想让这台机器上随时双击就能用：

```bash
./release             # Release 壳进 /Applications，装完打开一次
./release --status    # 后端与 App 各在什么状态
./release --uninstall # 删掉 App（会话与设置不动）
```

## 三个开发循环，快慢差两个数量级

| 改什么 | 怎么生效 | 耗时 |
|---|---|---|
| 插件的 `swift/` | 存盘即可。桥轮询发现 → 壳重编 → 世代热替换 | **1~3s，不重启任何东西** |
| 插件的 `lib/client.js` | 浏览器侧有 HMR，自动重载 | 秒级 |
| 插件的 `lib/*.js`、`package.json`、编排表 | 必须重启 dsh（官方在 web bundle 下关了 node 侧 HMR） | 秒级 |
| 壳源码 `surf-app/host/` | surf-app 盯着它，改了后台重建，窗口右上角提示「重启生效」 | 重建 2s + 重启 |

第一行是这个项目存在的理由。改 `surf-sidebar/swift/SidebarView.swift` 存盘，
一两秒后侧边栏就变了，**选中态和列表内容都还在**——因为数据面存在跨世代的保管箱里，
换的只是代码。编译失败会带文件行号打进 dsh 终端，旧世代继续在役，界面不变也不崩。

## 仓库里都有什么

```
surf/          伞 bundle @wenbo/surf：**本仓库唯一的编排表**（cordis.patch.yml
                   决定装哪些插件、什么顺序、什么配置），外加启动器 bin/surf.js
surf-app/          壳源码为载荷的插件：构建 + 写 endpoint 发现文件 + 拉起 App
  host/            Xcode 工程（project.yml / Sources/ / scripts/）
  host-build/      构建能力，**不随包分发**——正式形态的 App 因此天然不构建自己
surf-bridge/       唯一的特权插件：Swift 载荷登记表 + /surf/bridge WS + 盯 swift/ 目录
surf-layout/       占 root 槽：分栏、WebView 排版、sidebar 槽、开放的 toolbar 贡献槽
surf-sidebar/      占 sidebar 槽：原生会话侧边栏。数据面在 node 半边，Swift 只管画
surf-notify/       桌面通知：不占槽、不贡献界面，缺席即无通知。同时是「有什么在等着你」
                   的唯一真相，供给侧边栏那个置顶的「待处理」分区
surf-settings/     原生设置窗口：不占槽、自己一扇窗，前四栏编排照抄 dsh 的 Web 设置对话框
surf-nativeify/    让 dsh Web UI 摸起来像原生 App：主力是 client 半边那段 CSS，
                   另有一个薄 Swift 载荷让原生侧跟随 dsh 的 ui-theme
surf-memory/       跨会话持久记忆：一目录 markdown，索引每步注入、正文按需读。
                   **纯 node、零 macOS 依赖**，装到任何一台有 dsh 的机器上都跑得动
tools/             跨包的开发工具。只服务一个插件的工具归那个插件
docs/              文档，按受众分四层，见下
```

## 文档

| 你是谁 | 从哪读起 |
|---|---|
| 想用它 | [`docs/use/install.md`](docs/use/install.md) |
| 想给它写插件 | [`docs/extend/plugin-author-guide.md`](docs/extend/plugin-author-guide.md) → [`docs/extend/contracts.md`](docs/extend/contracts.md) |
| 想改这个仓库 | [`docs/internals/`](docs/internals/) |

完整索引与每篇一句话说明在 [`docs/README.md`](docs/README.md)。

## 写一个插件

外部作者不必读本仓库源码。一个"带 Swift 载荷的插件"长这样——node 半边通常只有几行：

```js
import { createSwiftPlugin } from "@wenbo/surf-bridge/plugin";
export default createSwiftPlugin({
  name: "surf-sidebar",
  provide: "surf-sidebar",
  inject: ["surf-layout"],      // cordis：layout 没挂好就不挂我
  swiftDir: new URL("../swift/", import.meta.url),
  swiftDeps: ["surf-layout"],   // 桥：上游换代时我自动跟着重编
});
```

Swift 半边导出一个 C 入口，拿到 `host` 就往槽里塞视图：

```swift
@_cdecl("surf_plugin_entry")
public func surf_plugin_entry() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(SidebarPlugin()).toOpaque()
}

final class SidebarPlugin: SurfPlugin {
    func activate(host: SurfHost) -> AnyObject? {
        let handle = SurfPluginHandle()
        host.register(slot: "sidebar") { AnyView(SidebarView(...)) }.kept(by: handle)
        return handle   // 壳松手 = 这一代退休，注册与订阅一并撤销
    }
}
```

数据面放在 node 半边是有意的——壳随 app bundle 冻结，node 半边随包可更新。

## 热替换是怎么成立的

桥把每个插件的 `swift/` 目录扫成一份内容 hash，壳按这个 hash 做内容寻址编译：
**module 名就是 hash**（`SurfSidebar_ha502d7516810`）——缓存命中与世代类型隔离
是同一个事实的两面。装载走 `dlopen` + `dlsym` 拿到入口，`activate` 里的新注册
覆盖旧槽，然后壳松开旧 handle，旧的那一代自行退场。

三条硬事实，都是实测出来的（[`docs/extend/native-abi.md`](docs/extend/native-abi.md)）：

1. **旧 dylib 永不 `dlclose`**——对 Swift 不安全（类型元数据还被引用着）。
   代码页泄漏式退休，实例由 ARC 正常回收。
2. **上游换代、下游没重编 = 沉默的认知分裂**：下游不崩不报错，只是继续调旧代的代码。
   所以桥把上游的 hash 折进下游的 hash——级联重编由数据结构保证，不靠传播逻辑。
3. 共享 module（眼下只有 `SurfSDK`）必须**全进程只有一份 dylib**，壳和插件链同一个
   文件，类型身份才对得上。

坏插件不许拖垮系统：编译失败保持上一代在役；没有任何插件占 `root` 槽时，
壳退化成整窗 WebView——功能不缺，只是没有原生外壳。

## 兼容性

`dsh` 处于 developer preview，明示会有 breaking change：帧解析一律防御式
（未知帧忽略、异常不崩），CSS 选择器优先锚 `[data-slot]` 这类一等契约、
退而用语义后缀模糊匹配。验证于 `0.1.1-rc.2`。

已知缺口——dsh 缺、而我们**决定不替它补**的那些——记在
[`docs/internals/dsh-upstream-gaps.md`](docs/internals/dsh-upstream-gaps.md)。
立场是：我们只是它的壳，遇到上游缺失如实报告，不绕过公开 API 替它补实现。
