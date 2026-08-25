import SwiftUI
import DashSDK
// 源码写不带世代的名字，世代由编译期 -module-alias 抹平（计划 §6.1）：
//   -module-alias Alpha=Alpha_g1
import Alpha

/// 下游插件：依赖 Alpha 的 module（模拟 dash-sidebar import DashLayout）。
/// 断言 7：先 dlopen Alpha 再 dlopen Beta，符号能否解析。
/// 断言 6：Alpha 换代后，未重编的 Beta 直接跑会发生什么。
final class BetaHandle: DashOpaqueHandle, AlphaFeature {
    weak var host: DashHost?
    init(host: DashHost) { self.host = host }
    var identity: String { "beta-handle" }
    /// 调用上游 Alpha 的 public API：返回值暴露 Beta 实际绑在哪一代。
    func ping() -> String { "beta sees alpha generation \(alphaGeneration())" }
    func poke() {}
    /// 实现的是**编译时那一代** Alpha 的 AlphaFeature。
    func featureName() -> String { "AlphaFeature implemented by beta" }
}

final class BetaPlugin: DashPlugin {
    func activate(host: DashHost) -> AnyObject? {
        let handle = BetaHandle(host: host)
        host.setObject("beta.handle", handle)
        host.note("B0 beta activate: \(handle.ping())")
        return handle
    }
}

@_cdecl("dash_plugin_entry")
public func dash_plugin_entry() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(BetaPlugin()).toOpaque()
}
