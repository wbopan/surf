import Foundation

/// SurfSDK —— 壳↔原生插件的 ABI 词汇。
///
/// 这里只有"世代无关"的类型：插件之间、插件的前后两代之间传递它们是安全的。
/// 判据很简单——SDK 的 dylib 全进程只有一份（随 app bundle 分发、壳与插件都
/// 链接它），而插件 dylib 每换一代就是一个新 module，新旧两代同名类型互不认识
/// （M2 实测断言 4）。所以凡是要跨插件、跨世代活着的东西，类型必须出自这里
/// 或系统框架。
///
/// SDK 与壳严格同版本：它住在壳源码里（`surf-app/host/Sources/SurfSDK/`），
/// "SDK 版本 = 壳版本"是结构事实，不靠纪律维持。
///
/// 纪律（计划 §4.1，插件作者必读）：
/// - 不 `@objc`、不继承 `NSObject`（Objective-C runtime 按名字注册类，
///   两代同名类会打架）。
/// - 跨界只用 SDK 类型与系统类型。插件自己定义的类型只能留在自己家里，
///   或者经 `.swiftmodule` 交给明确声明了依赖、因而会被级联重编的下游插件。
/// - `@State` 里只放丢了不心疼的东西。想活过热替换的状态写进 `SurfStore`，
///   或者干脆放回 TS 半身。

/// ABI 版本。壳装载插件前比对；不匹配即拒绝装载而不是崩在半路。
/// 改动 SDK 里任何 public 声明的语义时 +1。
///
/// **v1 之后的纯追加（不 bump）**——已有声明的语义一个字没变，老插件原样能跑：
/// - `SurfContributions`（多占用"贡献槽"注册表）+ `SurfHost.contributions`
///   + `SurfHost.contribute(to:id:order:metadata:make:)`。给"N 个插件各往一个
///   表面加一条"用（工具栏按钮是第一个消费者，在 surf-layout）。
/// - `SurfEventBus.Topic.pagePrefix`：页内桥的未知消息不再被壳白名单挡掉，
///   一律以 `surf.page.<type>` 广播。
/// - `SurfHooks`（应答式钩子表）+ `SurfHost.hooks` + `SurfHost.handle(hook:_:)`。
///   给"系统要求在 app 启动早期就位、实现方却是运行时装载的插件"那一类接线用
///   （第一个住户：`UNUserNotificationCenter.delegate`，实测晚设无效）。
///   与 registry/contributions 同纪律——**表里一个具体 hook 名都没有**。
///
/// 注意：dylib 里的 `contentHash` 指纹含 SurfSDK 的 `.swiftinterface` 摘要，
/// 所以追加声明照样会让全部插件重编一次——这跟 ABI 版本号是两回事。
public let surfABIVersion = 1

/// 插件的唯一入口协议。
///
/// 每个插件 dylib 必须导出这个 C 符号（`@_cdecl` 保证不被名字修饰）：
///
/// ```swift
/// @_cdecl("surf_plugin_entry")
/// public func surf_plugin_entry() -> UnsafeMutableRawPointer {
///     Unmanaged.passRetained(MyPlugin()).toOpaque()
/// }
/// ```
///
/// 壳 `dlopen` + `dlsym` 拿到函数指针、调用、`takeRetainedValue` 收下所有权
/// （M2 实测往返无泄漏无过释放）。
public protocol SurfPlugin: AnyObject {
    /// 装载后立即调用一次。
    ///
    /// `@MainActor` 是这里唯一一处 actor 标注：插件干的全是 UI 的活，壳也确实只在
    /// 主线程调它，标出来能让插件直接使用 AppKit / SwiftUI 等 `@MainActor`
    /// 类型而不必到处写 `assumeIsolated`。SDK 的那些 class（registry /
    /// objects / events）仍然不标——从隔离上下文调非隔离代码永远合法，
    /// 而反过来（在 dylib 之间跨 actor 边界）是 M2 没验证过的领域。
    ///
    /// 返回值是这一代插件的"命根子"：壳持有它 = 本代在役，壳释放它 = 本代退休。
    /// 约定把 `activate` 期间拿到的所有 `SurfDisposable` 攒进这个对象，
    /// 它 `deinit` 时注册与订阅一并撤销——这样插件不需要实现任何 deactivate。
    @MainActor
    func activate(host: SurfHost) -> AnyObject?
}

/// 一次性撤销句柄。`dispose()` 幂等；不显式调用时随对象析构自动撤销。
///
/// 世代替换的正常路径就是后者：新一代先注册好，壳再松手放掉旧 handle，
/// 旧注册在析构里自行退场（且只退自己那一份，见 `SurfRegistry.register`）。
public final class SurfDisposable {
    private var body: (() -> Void)?

    public init(_ body: @escaping () -> Void) {
        self.body = body
    }

    public func dispose() {
        let body = self.body
        self.body = nil
        body?()
    }

    deinit {
        body?()
    }
}

/// 一组 `SurfDisposable` 的容器——插件 `activate` 的标准返回值。
public final class SurfPluginHandle {
    private var disposables: [SurfDisposable] = []

    public init() {}

    public func keep(_ disposable: SurfDisposable) {
        disposables.append(disposable)
    }

    /// 便于链式写：`host.registry.register(...).kept(by: handle)`。
    public func adopt(_ disposables: SurfDisposable...) {
        self.disposables.append(contentsOf: disposables)
    }

    deinit {
        for disposable in disposables { disposable.dispose() }
    }
}

extension SurfDisposable {
    /// `host.registry.register(...).kept(by: handle)`
    @discardableResult
    public func kept(by handle: SurfPluginHandle) -> SurfDisposable {
        handle.keep(self)
        return self
    }
}
