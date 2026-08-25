# dash 原生插件 ABI：M2 spike 实测结论

> 本文是计划 §6.5 断言清单的执行结果，**全部结论来自本机实跑**，不是推理。
> 复跑方式见文末。spike 工程在 `docs/spikes/m2-abi/`。
> 实测日期 2026-08-25，环境：macOS 27.0 (26A5416b) / arm64 / Apple Swift 6.4
> (swiftlang-6.4.0.23.5) / Xcode-beta SDK MacOSX.sdk。

## 0. 结论

**R1（SwiftUI 跨 dylib ABI）不成立为风险——赌注赢了，不需要 Plan B。**

16 条断言全部通过：SwiftUI 视图 + `@Observable` model 从命令行 `swiftc -emit-library`
编出的 dylib 里 `dlopen` 装载、`AnyView` 进 `NSHostingView` 正常渲染、可交互；同一份源码
换代重编再装载，`.id(version)` 触发整棵重建、新视图上屏、旧世代 ARC 正常回收、进程不崩；
壳保管箱里的 WKWebView 跨代复用后页面未重载、JS 状态存活。

附带一个对计划有实质影响的意外收获：**编译比预期快一个数量级**（真实 DSHSidebarUI
体量 408 行 SwiftUI 代码 = 1.03s），启动门控预算可以从 60s 收到 10s 量级。

## 1. 入口 ABI（定稿）

每个插件 dylib 导出一个 C 符号：

```swift
@_cdecl("dash_plugin_entry")
public func dash_plugin_entry() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(AlphaPlugin()).toOpaque()
}
```

壳侧：

```swift
typealias EntryFn = @convention(c) () -> UnsafeMutableRawPointer

// RTLD_LOCAL 是必需的：每个插件都导出同名 dash_plugin_entry，
// 必须按 image handle 取符号，不能走 RTLD_DEFAULT 全局查找。
let image = dlopen(path, RTLD_NOW | RTLD_LOCAL)!
let sym   = dlsym(image, "dash_plugin_entry")!
let raw   = unsafeBitCast(sym, to: EntryFn.self)()
let obj   = Unmanaged<AnyObject>.fromOpaque(raw).takeRetainedValue()
let plugin = obj as? DashPlugin        // 跨 dylib 的协议 cast 成立
```

`passRetained` / `takeRetainedValue` 往返实测无过释放、无泄漏（后续 `activate`
正常返回，handle 释放时 `deinit` 准时触发）。

`activate(host:)` 返回一个 handle 交壳保管：**壳持有 handle = 该世代在役，壳释放 = 退休**。
这是世代生命周期的唯一抓手，实测释放后 `deinit` 立即被调用。

## 2. 编译命令（定稿）

### SDK（`-enable-library-evolution`，随 app bundle 分发 `.swiftinterface`）

```bash
xcrun swiftc sdk/DashSDK.swift \
  -module-name DashSDK \
  -emit-library -o libDashSDK.dylib \
  -emit-module -emit-module-path DashSDK.swiftmodule \
  -emit-module-interface -emit-module-interface-path DashSDK.swiftinterface \
  -enable-library-evolution -language-mode 5 \
  -Xlinker -install_name -Xlinker "@rpath/libDashSDK.dylib" \
  -target arm64-apple-macos27.0 -Onone -g
```

> **`-language-mode 5` 是硬要求**：Swift 6.4 下不给它，`-emit-module-interface`
> 直接报 `emitting module interface files requires '-language-mode'`。

### 插件（含跨插件依赖）

```bash
xcrun swiftc <plugin>/swift/*.swift \
  -module-name Alpha_g1 \
  -emit-library -o libAlpha_g1.dylib \
  -emit-module -emit-module-path Alpha_g1.swiftmodule \
  -I <sdk 目录> -L <sdk 目录> -lDashSDK \
  -I <依赖插件目录> -L <依赖插件目录> -lAlpha_g1 \
  -module-alias Alpha=Alpha_g1 \          # 源码写 import Alpha，世代对作者透明
  -Xlinker -rpath -Xlinker "@loader_path/../sdk" \
  -Xlinker -rpath -Xlinker "@loader_path/../alpha_g1" \
  -Xlinker -install_name -Xlinker "@rpath/libAlpha_g1.dylib" \
  -target arm64-apple-macos27.0 -language-mode 5 -Onone -g
```

**依赖定位方案定稿：`install_name = @rpath/lib<Module>.dylib` + 消费者带 `-rpath`。**
实测 dyld 会**自动**把依赖 dylib 带起来 —— 只 `dlopen` 下游插件、完全不碰上游，
上游照样出现在 image 列表、符号照样解析。

> 推论（修正计划 §6.1 的假设）：拓扑序**不是** `dlopen` 的要求，而是
> **编译顺序**和 **`activate` 顺序**的要求。桥按拓扑序排 snapshot 仍然必要，
> 但壳的装载器不必strict 按序 dlopen。

## 3. 断言清单结果

| # | 断言 | 结果 | 证据 |
|---|---|---|---|
| 1 | `-emit-library` 编 SwiftUI View + `@Observable` → dlopen → AnyView 进 NSHostingView 渲染 | ✅ | 69000 不透明像素 / 54 distinct 色，截图 `01-alpha-g1.png`。Observation 宏在命令行 swiftc 下**无需任何额外 flag** |
| 1b | `@Observable` 跨 dylib 驱动重绘 | ✅ | 壳经 SDK existential 调 `poke()` 改插件内部 model → 297 像素变化 |
| 1c | 可交互（真实事件链） | ✅ | 合成 `NSEvent` 点击 SwiftUI Button → 59560 像素变化 |
| 2 | `Unmanaged.passRetained`/`takeRetainedValue` 往返无泄漏无过释放 | ✅ | 往返后 activate 正常、handle 释放时 deinit 准时 |
| 3 | 世代替换：换 module 名重编 → dlopen → registry 换指向 + `.id(version)` → 新视图上屏 | ✅ | 与 g1 差异 274880 像素，截图 `06-alpha-g2.png`（蓝 gen1 → 橙 gen2） |
| 3b | 旧实例 ARC 回收、进程不崩 | ✅ | 释放旧 handle → `deinit` 调用计数 0→1；旧 dylib **不 dlclose**，进程存活 |
| 4 | 两代类型隔离的失败形态 | ✅ | 旧代对象 `as?` 新代同名协议 `AlphaFeature` → **nil**（干净失败，不崩、不误命中） |
| 5 | SDK 词汇跨代传递 | ✅ | g1 留在保管箱的对象，g2 经 `DashOpaqueHandle` existential 调用成功（`pong from alpha g1`） |
| 6 | 上游换代后未重编的下游直接跑 | ✅（**危险形态已确认**） | Beta 不崩、正常运行，但 `alphaGeneration()` 仍返回 1 —— **绑在旧代的沉默语义分裂**。见 §4 |
| 7 | dylib 依赖定位 | ✅ | `@rpath` + `-rpath`，dyld 自动加载；不必先 dlopen 上游 |
| 8 | SDK 只以 `.swiftinterface` 分发（模拟 app bundle 内路径） | ✅ | 去掉 `.swiftmodule` 只留 `.swiftinterface` + dylib，插件编译通过（0.68s），且运行时 `as? DashPlugin` / SDK existential 全部成立 —— **类型身份跨 interface 重建一致** |
| 9 | WKWebView 实例跨代/跨挂载 | ✅ | 壳创建实例放保管箱，插件 `NSViewRepresentable` 借用；换代后 `window.__spikeState` 与种子值完全一致 = **页面未重载、JS 状态存活** |
| 10 | 编译耗时基线 | ✅ | 见 §5 |

## 4. 断言 6 的失败形态（对桥设计的硬约束）

上游 Alpha 已换到 g2、下游 Beta 未重编时，Beta **不崩溃、不报错**，只是继续调用 g1 的代码
（`beta sees alpha generation 1`）—— 因为旧 dylib 按设计不 `dlclose`，仍在内存里。

这比崩溃更危险：UI 上看不出任何异常，但两个插件对世界的认知已经分裂。

**结论：桥必须强制级联重编。** 上游插件 `contentHash` 变化时，所有（传递地）依赖它的下游
插件一律重编、重装载，不允许"只换上游"。计划 §5.1-4 按拓扑序返回 snapshot 的设计是对的，
但要补一条：**登记表版本 bump 必须传播到下游**，不能按插件独立判断新鲜度。

## 5. 编译耗时基线（大幅优于计划假设）

| 载荷 | `-Onone -g` 耗时 |
|---|---|
| hello（6 行 SwiftUI） | 0.45s |
| spike 插件（82 行，含 @Observable + View + WKWebView 桥接） | 0.60s |
| **真实 DSHSidebarUI（408 行 SwiftUI）** | **1.03s** |
| SDK 从 `.swiftinterface` 重建 + 编插件 | 0.68s |
| spike 宿主（197 行 AppKit+SwiftUI） | 0.72s |

四个 dash 插件全量冷编译的现实预期是 **3–5 秒**，不是计划 §7.1 假设的分钟级。

**对计划的修正**：
- §7.1 的冷启动门控预算 60s → 收到 **10s** 足够宽裕；超时即降级 fallback。
- §10-R7「冷启动首编串行可 >30s」**不成立**，并行编译（拓扑同层并发）的优化优先级
  可以进一步下调，先糙后精完全够用。
- 内容寻址缓存（§6.2）的价值仍在（重连不重编），但它不再是"启动可用性"的前提。

## 6. 顺带确认的两件事

1. **真实 DSHSidebarUI 只 import Foundation + SwiftUI 就能独立编成 dylib** ——
   它的 `Package.swift` 声明的 `DSHKit` 依赖在源码层面并未使用。M6 迁移时
   `dash-sidebar/swift/` 不需要把 DSHKit 拖进插件的编译闭包（数据面仍按计划走保管箱）。
2. **Observation 宏无需额外 flag**，命令行 swiftc 直接可用（曾担心宏插件在非 SwiftPM
   场景需要 `-load-plugin-executable` 之类，实测不需要）。

## 7. 本 spike **没有**覆盖的边界（诚实清单）

- **多代累积的内存增长**：只验证了单次换代的 `deinit`，没做 150 代压力测试，
  §6.4 的双阈值自重启策略仍是未经校准的估计。
- **`-O` 优化级别**：全部实测在 `-Onone -g` 下。Release 级别的跨 dylib 泛型特化/内联
  是否引入新问题未知（热循环本来就用 -Onone，影响面小）。
- **R5 的 delegate 重设**：WKWebView 实例跨代复用已验证，但 `navigationDelegate`/
  `uiDelegate` 是插件对象、旧代释放后自动 nil 的具体时序没测。M5 落地时补。
- **并发**：全部断言在主线程按序执行，跨 dylib 的 actor/Sendable 边界未测。
- **深层 NSViewRepresentable 嵌套**与真实 dsh 数据量下的渲染性能。

## 8. 复跑

```bash
cd docs/spikes/m2-abi
./build.sh          # SDK + 两代 alpha + beta + 宿主，顺带打印编译耗时
./out/spike-host out   # 跑全部断言，截图落在 out/*.png
```

宿主会开一个可见窗口（SwiftUI 渲染需要真正上屏），跑完自动退出，
退出码 0 = 全通过。升级 Xcode / macOS 后建议重跑一次。
