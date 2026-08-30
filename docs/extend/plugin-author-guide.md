# 写一个 clam 插件

这份文档写给**不在本仓库里**的插件作者：你有自己的 npm 包、自己的 git 仓库，
想给 surfclam 加一格工具栏按钮、一条快捷键、一扇窗口，或者干脆换掉侧边栏。

契约的字段表在 [`contracts.md`](contracts.md)，这里讲怎么把东西跑起来。

## 先知道三件事

1. **插件就是一个普通的 cordis 插件**（npm 包），跑在 dsh 进程里。
   没有插件 SDK、没有脚手架、没有构建步骤。
2. **壳（`Surfclam.app`）是预编译产物，你改不了它。** 所有跨插件的约定都是
   **字符串**——槽名、事件主题、metadata 键。抄错一个字母是静默失败：
   界面上什么都不发生，没有编译错误也没有日志。
3. **Swift 半边是运行时编译装载的**：你的 `swift/` 目录经桥传给壳，壳用
   `xcrun swiftc` 编成 dylib 再 `dlopen`。所以你**不需要 Xcode**（Command Line
   Tools 就够，ClamSDK 的 `.swiftinterface` 随 app bundle 分发），
   但你需要一台已经跑起来过 surfclam 的机器。

**App 是 dsh 的客户端外设，不是宿主**，但两种形态下谁先起是反过来的：

- **装好的正式形态**（用户的机器）：双击 `Surfclam.app`，它自己 spawn 一个 dsh
  并盯着它（连接偏好默认 `managed`，打开即有、⌘Q 即退）。
- **仓库开发形态**：终端先跑起 dsh，其中的 `clam-app` 插件按需构建并拉起 App。

对你没有区别——两种形态下你的插件都跑在 dsh 进程里，Swift 半边都由壳在运行时编译装载。

---

## 1. 你的插件是哪一种

| 形态 | 有什么 | 例子 |
|---|---|---|
| **纯 node** | 只有 `lib/index.js`。不碰界面，提供服务或订 dsh 事件 | 给别人喂数据的服务提供方 |
| **带 Swift 载荷** | 多一个 `swift/` 目录。占槽、贡献工具栏、开窗口、发通知 | clam-sidebar、clam-notify、clam-settings |
| **带 client 半边** | 多一个 `lib/client.js`。改 dsh 网页那一侧 | clam-nativeify（CSS）、clam-layout（动作桥） |

三者可叠加。**这三个半边彼此独立**：Swift 半边靠桥与 node 半边说话（`push`/`invoke`），
client 半边靠页内桥与壳说话（`postMessage` → `clam.page.<type>`），
node 半边与 client 半边之间没有直连通道。

---

## 2. 骨架 A：纯 node

```jsonc
// package.json
{
  "name": "@acme/clam-hello",
  "version": "0.1.0",
  "type": "module",
  "main": "lib/index.js",
  "exports": { ".": "./lib/index.js", "./package.json": "./package.json" },
  "files": ["lib"],
  "peerDependencies": { "@deepseek-ai/schemastery": "^3.18.1" }
}
```

```js
// lib/index.js
import z from "@deepseek-ai/schemastery";

export const name = "clam-hello";
export const inject = [];
export const Config = z.object({ greeting: z.string().default("hi") });

export function apply(ctx, config) {
  ctx.on("session/created", (session) => {
    process.stderr.write(`clam-hello: ${config.greeting} ${session.id}\n`);
  });
}
```

**为什么写 stderr 而不是 `ctx.logger`**：`dsh web` 下 logger 没有 exporter，
消息只进环形缓冲，终端一个字都看不见。要给终端前的人看的进度自己写 stderr
（两边都喂最保险）。

---

## 3. 骨架 B：带 Swift 载荷

node 半边通常就是一段配置——`createSwiftPlugin` 替你做完登记、时序、撤销。

```jsonc
// package.json —— 注意 files 里的 "swift"
{
  "name": "@acme/clam-hello",
  "version": "0.1.0",
  "type": "module",
  "main": "lib/index.js",
  "exports": { ".": "./lib/index.js", "./package.json": "./package.json" },
  "files": ["lib", "swift"],
  "peerDependencies": { "@wenbo/clam-bridge": "^0.1.0" }
}
```

```js
// lib/index.js
import { createSwiftPlugin } from "@wenbo/clam-bridge/plugin";

export default createSwiftPlugin({
  name: "clam-hello",                       // ← 决定 Swift module 名，见 §5
  swiftDir: new URL("../swift/", import.meta.url),

  // 想 import ClamLayout（占 sidebar 槽 / 用 LayoutToolbar 那些常量）就加这两行。
  // 只写一半不行：swiftDeps 是 Swift 编译拓扑序，inject 是 cordis 挂载时序，
  // 两者必须是同一份声明（漏了会被自动补上并 warn）。
  inject: ["clam-layout"],
  swiftDeps: ["clam-layout"],

  // 想让壳给你装菜单项 / 快捷键就声明在这里（形状见 contracts.md §1）。
  commands: [{
    id: "sayHello", menu: "view", order: 50, key: "cmd+alt+h",
    label: { zh: "打个招呼", en: "Say Hello" },
  }],

  // node → Swift：登记完成后调用一次，在这里订宿主事件并 push。
  subscribe: ({ ctx, push }) => {
    ctx.on("session/created", (s) => push("sessions", { id: s.id }));
  },
  // Swift → node：Swift 半身 `host.bridge.send(action:)` 能触发的动作。
  expose: {
    refresh: (payload, { ctx }) => { /* … */ },
  },
});
```

```swift
// swift/HelloPlugin.swift
import AppKit
import ClamSDK
import SwiftUI

@_cdecl("clam_plugin_entry")
public func clam_plugin_entry() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(HelloPlugin()).toOpaque()
}

final class HelloPlugin: ClamPlugin {
    func activate(host: ClamHost) -> AnyObject? {
        let handle = ClamPluginHandle()

        // 菜单命令：壳只喊命令名，谁应答谁干活。
        host.events.subscribe(ClamEventBus.Topic.menuCommand) { payload in
            guard payload["command"] as? String == "sayHello" else { return }
            NSSound.beep()
        }.kept(by: handle)

        // 收 node 半边 push 下来的东西。
        host.bridge.onMessage { channel, payload in
            guard channel == "sessions" else { return }
            host.log("新会话 \(payload["id"] as? String ?? "?")")
        }.kept(by: handle)

        return handle          // ← 壳按住它 = 本代在役；松手 = 本代退休
    }
}
```

**`swift/` 目录里只放 `.swift` 文件**（别的扩展名不进 snapshot），
且**至少要有一个**——空目录会被桥当场拒绝登记。

---

## 4. 骨架 C：带 client 半边

client 半边是**手写的 lazy-CJS 经典脚本**，没有构建步骤。

```jsonc
// package.json 里多两处
{
  "exports": {
    ".": "./lib/index.js",
    "./client": "./lib/client.js",          // ← 必须有这一条
    "./package.json": "./package.json"
  },
  "dsh": { "client": { "platform": "web", "inject": [] } }
}
```

```js
// lib/client.js
window.__ModuleLoader__.load({
  id: "@acme/clam-hello",     // ← 必须逐字等于 package.json 的 name
  factory: () => {
    var module = { exports: {} };
    var exports = module.exports;
    Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });

    /** 只在壳里生效：UA 含 "Clam/"（带斜杠，防普通子串误命中）。 */
    const insideClam = () => navigator.userAgent.includes("Clam/");

    exports.apply = (ctx) => {
      if (!insideClam()) return;
      ctx.effect(() => {
        const style = document.createElement("style");
        style.textContent = `/* … */`;
        document.head.appendChild(style);
        return () => style.remove();
      });
    };
    return module.exports;
  },
});
```

三条只能踩过才知道的：

- **`id` 必须逐字等于包名。** 它不会跟着 `package.json` 的 name 自动变。
  对不上时整棵 client 插件树加载失败，报
  `bundle …/client.js loaded without registering "<name>"`——
  **node 半边一切正常、dsh 终端一个字都没有**，只在浏览器控制台里报。
- **`ctx.inject` 会抛。** 裸调一次（不包 try、放在 `apply` 顶层）就赔掉整个插件。
  走作用域 inject、包 try、**装在 `ctx.effect` 内部**。
- **HMR 的重载顺序是「新实例先启、旧实例后清」。** cleanup 里无条件清理
  `documentElement` 属性 / window 全局，会砍掉新实例刚装好的那一份。
  写全局状态必须带实例 token，cleanup 只收 token 对得上的。

想给壳送一条消息就 `window.webkit.messageHandlers.clam.postMessage({ type, ... })`
——**壳不设白名单**，任意 `type` 都会广播成 `clam.page.<type>`，你的 Swift 半边订它即可。

---

## 5. `name` → Swift module 名

`createSwiftPlugin({ name })` 里的 `name` 有三个身份：cordis 插件名、桥登记表的键、
**Swift module 名的唯一出处**。规则只有一条：

```
kebab-case 拆开，每段首字母大写，拼起来
clam-hello       → ClamHello
acme_status_bar  → AcmeStatusBar
```

**别拿 scoped 包名当 `name`**：`@acme/clam-hello` 会算出 `@acme/ClamHello`，
不是合法的 Swift 标识符。桥在登记这一刻就会抛错并告诉你怎么改
（从前它一路放行，直到壳去 `swiftc -module-name` 才炸，而那条错误落在**壳的日志里**、
长得像编译器的毛病）。

同样 fail-loud 的还有两条：`swiftDir` 不是目录（多半是 `files` 白名单漏了 `"swift"`）、
`name` 重复登记（检查编排表里是不是列了两行）。

`name` 与包名不必相同，但**必须全局唯一**——它是登记表的键。
包名的 scope 建议留给你自己（`@acme/clam-hello`），`name` 写裸名（`clam-hello`）。

---

## 6. import：包名还是相对路径

| 你在哪 | 怎么 import `createSwiftPlugin` |
|---|---|
| **外部包**（你的情形） | `import { createSwiftPlugin } from "@wenbo/clam-bridge/plugin";`，并把 `@wenbo/clam-bridge` 写进 **peerDependencies** |
| 本仓库内的 `clam-*` | `import … from "../../clam-bridge/lib/plugin.js";`（相对路径） |

本仓库用相对路径是因为包名 import 需要 npm workspace 或手工 symlink，
那是机器本地状态，新克隆的仓库拿不到；而"所有 clam-\* 是同一仓库里的兄弟目录"永远成立。
**你没有这个问题**——你的包被装进 profile 时，`@wenbo/clam-bridge` 会平铺在
profile 的 `node_modules` 里。

`clam-bridge` 的公开出口只有两个：`./plugin`（`createSwiftPlugin`）与
`./locale`（语言决议的小工具）。别 deep import `lib/` 里的其它文件。

**`@deepseek-ai/*`（以及 `ws`、`@deepseek-ai/schemastery`）一律写 peerDependencies。**
理由不是包体积：cordis 的服务与 Schema 按**实例身份**认人，你必须用 dsh 自己进程里的
那一份。装一份版本号相同的副本反而会因为实例不同而出诡异的错。

`@wenbo/clam-bridge` 也建议写 peerDependencies，不过它宽容一些：`createSwiftPlugin`
是无状态纯工厂（只用 `ctx.clamBridge` 这个**服务名**接头，不比对模块实例），
拿到第二份副本也不会出事——真正要求单例的是 `clamBridge` 服务的提供者，
它由伞包只挂一次。

---

## 7. 接进编排：profile patch 里 insert 一行

三层结构，别混：

- **profile** = 一张 `bundles` 清单（`<profile>/package.json`），零代码。
- **bundle** = 一张编排表（`cordis.patch.yml`），说"装哪些包、什么顺序、什么配置"。
  surfclam 那张住在伞包 `@wenbo/surfclam` 里。
- **plugin** = 真正的代码，纯 npm 包，**不声明 `dsh.bundle`**。

**你不需要改伞包。** profile 自己的 `cordis.patch.yml` 在所有 bundle 层之后应用：

```yaml
# ~/.dsh/profiles/surfclam/cordis.patch.yml
- insert:
    - id: clam-hello
      name: "@acme/clam-hello"
      config:
        greeting: hello
```

挂载顺序不用你操心：`createSwiftPlugin` 自动补上 `inject: ["clamBridge"]`，
cordis 的依赖解析保证桥先于你挂载（**行序不带加载语义**，只影响诊断树的可读性）。

**别把自己列进 `bundles`。** 那一栏只收 bundle；列一个没有 `dsh.bundle` 声明的包上去，
`loadProfile` 会直接 fails loud。`surfclam/bin/surfclam.js` 的 `fixBundles` 会把
clam-\* 从 `bundles` 里清掉，但**保留你自己 add 的其它条目**，不会动你的 patch 层。

---

## 8. 外部开发的热循环

**你不需要 clone 本仓库。** 桥轮询的是登记进来的**绝对路径**，壳从不读插件目录
（源码经 WS 传过去）。

```sh
# 一次性：把你的仓库 link 进 surfclam 的 profile
# （`--profile` 是必填项；spec 原样交给 pnpm add，所以 link:/ file: 都能用）
dsh plugin add --profile surfclam link:/path/to/your/clam-hello
# 然后在 profile 的 cordis.patch.yml 里 insert 一行（§7）

# 日常
dsh --profile surfclam --no-open
```

之后：

| 改什么 | 怎么生效 | 耗时 |
|---|---|---|
| **`swift/`** | 存盘即可。桥 500ms 轮询发现 → 壳重编 → 世代热替换 | **1~3s，不重启任何东西** |
| `lib/*.js`、`package.json`、`commands` 声明 | **必须重启 dsh**（官方在 web bundle 下 disable 了 node 侧 HMR） | 秒级 |
| `lib/client.js` | client 半边有 HMR，约 0.5s 自动重载；壳里 ⌘R 也行 | 秒级 |

编译失败会带文件行号打进 **dsh 终端的 stderr**，旧世代继续在役，界面不变也不崩。
完整日志埋在世代目录的 `build.log`（`<AppSupport>/io.wenbo.surfclam/native-plugins/generations/`）。
想确认"我现在跑的到底是哪份代码"就开 ⌥⌘D 诊断面板——那里列着每个插件的世代、
module 名（module 名就是内容 hash），以及命令声明的条数与来源。

---

## 9. Swift 半边的五条硬规矩

这五条都**不报错、不警告**，只是"设了没反应"。

### 9.1 `activate` 的返回值必须是持有链的根

占槽的插件有 registry → 视图闭包 → model 这条天然的强引用链。
**不占槽的插件没有生命周期锚**：`activate` 里 new 出来的对象没人持有，
函数一返回就被 ARC 回收，所有 `[weak self]` 异步回调静默变 nil。
症状极其误导——"上线"日志照常打印，然后什么都不发生，像是数据没来。

```swift
func activate(host: ClamHost) -> AnyObject? {
    let presenter = Presenter(host: host)   // presenter 自己持有 ClamPluginHandle
    presenter.start()
    return presenter                        // ← 壳按住这个返回值，它就是锚
}
```

### 9.2 跨代保管箱只放系统类型

想活过热替换的状态放 `host.objects`（进程级）或 `host.store`（落盘）。
**箱里只能放系统类型或 SDK 类型**：世代之间类型身份是隔离的（module 名取自 contentHash），
`as? 自定义类` 跨代必然得到 nil。

```swift
host.objects.setObject("clam.hello.snapshot", payload as NSDictionary)   // ✅
host.objects.setObject("clam.hello.model", MyModel())                    // ❌ 下一代取不出来
```

窗口这类资源同理：存 `NSWindow`，新一代 `activate` 时主动收拾上一代留下的那份。
**别把清理逻辑只挂在 `ClamPluginHandle` 的析构上**——实测四十多次换代里 handle 只
deinit 过三次；注册撤销之所以没出事，是因为 registry 用 token 兜住了"新的赢"。
没有 token 兜底的东西（窗口是典型）会积累：每改一次 Swift 多叠一扇窗口。

### 9.3 "清掉上一次运行留下的东西"按进程收口

热替换每改一行就 `activate` 一次，把这类动作挂在 `activate` 上会每代都执行一遍
（然后把当前正当值班的东西一起扫掉）。往 `host.objects` 插一个标记键即可——
保管箱天然是进程级的。

### 9.4 不 `@objc`、不继承 `NSObject`

Objective-C runtime 按名字注册类，两代同名类会打架。

### 9.5 跨界只用 SDK 类型与系统类型

你自己定义的类型只能留在自己家里，或者经 `.swiftmodule` 交给**明确声明了 `swiftDeps`、
因而会被级联重编**的下游插件。事件总线与桥的载荷只放 JSON 能表达的值。

线程约定：SDK 的所有表**只在主线程使用**。`ClamPlugin.activate` 是唯一标了
`@MainActor` 的地方，所以你可以直接用 AppKit / SwiftUI。

---

## 10. 常用配方

### 10.1 加一条菜单项 / 全局快捷键

声明在 node 半边的 `commands`（§3 的骨架里有），Swift 半边订
`ClamEventBus.Topic.menuCommand` 应答。壳不认得你的 id，你的插件缺席时那条菜单项
干脆不出现。字段表见 [`contracts.md` §1](contracts.md)。

### 10.2 往工具栏加一格

需要 `inject`/`swiftDeps` 都带上 `clam-layout`：

```swift
import ClamLayout

host.contribute(to: LayoutToolbar.slot, id: "hello", order: 10,
                metadata: ToolbarSpec(label: "打招呼",
                                      symbol: "hand.wave",
                                      region: .content,
                                      align: .trailing).metadata()) {
    AnyView(EmptyView())        // kind 推断成 .button，这个工厂用不上
}.kept(by: handle)

host.events.subscribe(LayoutToolbar.activateTopic) { payload in
    guard payload["owner"] as? String == host.plugin,
          payload["id"] as? String == "hello" else { return }
    // …
}.kept(by: handle)
```

`id` 只需在**你自己名下**唯一——`(owner, id)` 才是身份，不会撞上别人。
徽标、选中态、菜单内容这类会变的东西**别放 metadata**，走
`LayoutToolbar.updateTopic` 活通道（[`contracts.md` §2.2](contracts.md)）。

**能用 `button`/`group`/`menu` 就别用 `view`**：自定义视图路线里 AppKit 只看见一块
不透明矩形，显示模式、玻璃分组、徽标、溢出退让全部失效，而且算错是静默的。

### 10.3 占一个槽（换掉侧边栏）

```swift
host.register(slot: LayoutSlots.sidebar) { AnyView(MySidebar()) }.kept(by: handle)
```

一槽一主，后来者覆盖。想让 dsh 网页那侧配合（比如收起它自带的侧边栏），
那是**占 `root` 槽的插件**的事——它经 `clam.web.query` 告诉壳页面该带什么参数，
壳对参数名不设白名单也不解释。

### 10.4 只读别人的设置 ns

ns 的主人是注册它的那个插件，**重复 `register` 会 fail loud**。只读的正确姿势：

```js
ctx.inject(["settings"], (scoped) => {
  // 订全局事件按 ns 过滤——非 owner 拿不到 SettingsScope，那是 register 的返回值。
  scoped.on("settings/updated", (ns) => { if (ns === "ui-theme") read(ctx); });
  read(ctx);   // 就绪即读一次
});

function read(ctx) {
  const settings = ctx.get("settings");        // 现读现算，别在闭包里存服务句柄
  if (settings === undefined) return undefined;
  try { return settings.get("ui-theme")?.preference; } catch { return undefined; }
}
```

两个要点：

- **现读现算**躲得开"读的时候那个 ns 还没注册"的时序洞——它由别的插件在它自己的
  `inject(["settings"])` 里注册，跟你的挂载没有先后保证，而 `settings/updated`
  只在**变化**时发，用户不动设置就永远等不到。
- **读不到就什么都不做**，别推一个猜出来的默认值——那是拿默认值覆盖真相。

### 10.5 可选依赖

这个 cordis fork 的 `inject` 只有数组与 intercept-config 两种形态，
**没有 `{required, optional}`**。静态 `inject` 的语义是"服务不在就整个插件不挂载"。
要表达"它不在也别连累我"，唯一的方式是运行时嵌套：`ctx.inject([...], (scoped) => {...})`。

### 10.6 让别人能扩展你

`ctx.provide("<中性服务名>", impl)`——**服务名描述事实，不要描述插件**。
clam-notify 提供的是 `clamPending`（"有什么在等着你"）而不是 `clamNotify`，
所以 clam-sidebar 消费它时并不知道对面是谁，换一个实现方也不用改代码。

---

## 11. 失败长什么样

| 症状 | 多半是 |
|---|---|
| 插件在 dsh 里挂上了，界面上什么都没有 | Swift 编译失败（看 dsh 终端 stderr 与世代目录的 `build.log`），或者贡献进了一个没人消费的槽 |
| "上线"日志打印了，然后什么都不发生 | `activate` 返回值不是持有链的根（§9.1） |
| 换代后状态没了 / `as?` 拿到 nil | 保管箱里放了自定义类型（§9.2） |
| 每改一次 Swift 多叠一扇窗口 | 清理只挂在析构上（§9.2） |
| 工具栏那一格凭空消失 | `view` 路线 + SwiftUI 的 `.frame(maxWidth:)`（贪心，会把别人挤进溢出）。**先怀疑宽度，再怀疑数据** |
| metadata 改了但界面没变 | 键名拼错（静默退化到缺省）。用 `ToolbarSpec` 而不是手写字典 |
| 徽标一热替换就没了 | 徽标写进了 metadata（拓扑）而不是活通道（流量） |
| node 半边一切正常，浏览器里整棵 client 树没加载 | `__ModuleLoader__.load({id})` 与包名对不上（§4） |
| `dsh plugin add` 与 `--dump-config` 都过，真 `import` 时炸 `ERR_MODULE_NOT_FOUND` | `@deepseek-ai/*` 没写 peerDependencies，或 profile 里没装上 |
| App 打开了，却一直连不上后端 | 登录 shell 的 PATH 上找不到 `dsh`。GUI App 走 `zsh -lc`，它读 `.zshenv`/`.zprofile`/`.zlogin` 而**不读 `.zshrc`**——node 装在 nvm / fnm 下的机器最常撞，那两个的安装脚本默认就写进 `.zshrc` |
| 你的 Swift 载荷一个都没装上，报 `mapping process and mapped file (non-platform) have different Team IDs` | 去查 App 的 entitlements，不是查签名身份——见 §12 第一条 |

**别往 session 日志写自定义 event type**：0.1.1-rc.2 会导致
`SessionFormatUnsupportedError`、会话无法重新读取。你的流量走桥自己那条 WS。

---

## 12. 已知边界（发布前还没解决的）

- **预编译只覆盖仓库内置的插件，你的不在其中。** 分发的 `Surfclam.app` 是
  Developer ID 签名 + 公证的实体，内置插件的 dylib 已经预编译进 bundle，用户机器上
  零次 swiftc。但**第三方插件的 `swift/` 仍然是运行时现场编译的**，所以你的用户
  需要 Command Line Tools（不需要完整 Xcode）。

  这些现场编出来的 dylib 之所以能被一个签名过的 App 装载，靠的是 bundle 带着
  `com.apple.security.cs.disable-library-validation`——App 开了 Hardened Runtime，
  而现场产物是 ad-hoc、`TeamIdentifier=not set`。跑过对照组：去掉那条 entitlement
  后全部装载失败，报错是 `mapping process and mapped file (non-platform) have
  different Team IDs`，**字面上一个字都没提 library validation**。
  撞见这句话要去查 entitlements，不是查签名身份。
- **ABI 版本号是空承诺**：`clamABIVersion` 眼下没有装载期比对，
  SDK 语义变更对老插件是静默漂移。
- **部署目标钉死 `arm64-apple-macos27.0`**，SDK 较旧的机器编不过。
- **贡献的 metadata 零校验**，键名拼错静默降级到缺省。
- **没有错误边界**：`make()` / hook body / event handler 全是裸调用，
  一个贡献者崩了整个进程走人。
- **侧边栏没有贡献槽**：想给会话行加一列装饰/筛选，眼下必须改 clam-sidebar 本身
  （`clamPending` 是唯一现成的扩展点，但只喂 `status` 一个字段）。

这几条的路线图在 [`architecture-coupling-audit.md` §6](../archive/architecture-coupling-audit.md)。
