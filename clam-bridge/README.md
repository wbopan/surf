# clam-bridge

原生插件世界的**唯一特权插件**。三件事：

1. **Swift 载荷登记表** —— `ctx.provide('clamBridge')`，各插件经
   `createSwiftPlugin`（子出口 `clam-bridge/plugin`）把自己的 `swift/` 目录登记进来。
2. **一条 WebSocket** —— `/clam/bridge`，与 dsh 同端口（`ctx.webServer.registerUpgrade`）。
   壳连上来拉 snapshot、回报编译结果、收发插件与其 TS 半身之间的信封消息。
3. **盯文件** —— 500ms statSync 轮询各 `swift/` 目录。node 半边在 web bundle 下没有 HMR，
   所以 Swift 的热循环不指望它：桥常驻、自己看着文件变。**TS 半身完全不用重载。**

## 为什么级联重编不需要专门的传播逻辑

M2 实测过一个危险形态：上游插件换代、下游没重编时，下游**不崩不报错**，
只是静默绑在旧代（旧 dylib 按设计不 dlclose，还在内存里），UI 上毫无征兆。

这里的解法是把上游的 `contentHash` 折进下游的 `contentHash`。于是"内容没变就不重编"
这一条判断自带级联：上游一变，下游的 hash 必然跟着变。壳侧不需要再写传播代码，
`docs/native-abi.md` §4 那个坑在数据结构层面就被堵死了。

同一个 hash 还决定 Swift module 名（`ClamSidebar_h9f31c0aa12b4`），
所以"内容寻址缓存"与"世代类型隔离"是同一个事实的两面。

## 帧（协议 v1，计划 §5.4）

| 方向 | 帧 | 字段 |
|---|---|---|
| ↑ app→dsh | `hello` | `protocolVersion, appVersion, clientId` |
| ↓ | `hello` | `protocolVersion, registryVersion` |
| ↑ | `snapshot` | — |
| ↓ | `snapshot-result` | `version, plugins:[{name, module, files, swiftDeps, contentHash, schemaVersion}]`（**拓扑序**） |
| ↓ | `changed` | `version`（只发版本不发载荷） |
| ↑ | `compile-result` | `plugin, contentHash, ok, log` |
| ↓ | `push` | `plugin, channel, payload` |
| ↑ | `invoke` | `plugin, action, payload` |
| ↑ | `restart-dsh` | — |

**未知帧一律忽略不崩**，与 EventsBridge 同纪律。握手前只放行 `hello`；
升级请求的 Host 头必须是 loopback（`/api` 那道栅栏是 dsh-client-connection 自己加的，
自注册路由要自己做，见计划 §1.5）。

## 写一个带 Swift 载荷的插件

```js
import { createSwiftPlugin } from "../../clam-bridge/lib/plugin.js";

export default createSwiftPlugin({
  name: "clam-sidebar",
  provide: "clam-sidebar",          // 空标记服务，供下游 inject（§4.3）
  inject: ["clam-layout"],          // cordis 依赖 = 挂载时序
  swiftDir: new URL("../swift/", import.meta.url),
  swiftDeps: ["clam-layout"],       // Swift module 依赖（源码里 import ClamLayout）
  subscribe: ({ ctx, push }) => { /* 订宿主事件 → push 给 Swift 半身 */ },
  expose: { archive: (payload, { ctx }) => { /* Swift 半身可触发的动作 */ } },
});
```

`clam-*` 之间用**相对路径 import**：`healProfilesModuleFallback` 只镜像 harness 的依赖闭包，
不含用户插件，包名 import 要么靠 npm workspace 要么靠手工 symlink——两者都是机器本地状态，
新克隆的仓库拿不到。相对路径在"所有 clam-\* 是同一仓库里的兄弟目录"这个前提下永远成立。

Swift 半身见 `clam-sidebar/swift/SidebarPlugin.swift`（最小的槽插件入口）与
`clam-app/host/Sources/ClamSDK/`（SDK 本体，含纪律说明）。
