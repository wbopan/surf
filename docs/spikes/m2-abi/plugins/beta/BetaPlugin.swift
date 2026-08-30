import SwiftUI
import SurfSDK
// 源码写不带世代的名字，世代由编译期 -module-alias 抹平（计划 §6.1）：
//   -module-alias Alpha=Alpha_g1
import Alpha

/// 下游插件：依赖 Alpha 的 module（模拟 surf-sidebar import SurfLayout）。
/// 断言 7：先 dlopen Alpha 再 dlopen Beta，符号能否解析。
/// 断言 6：Alpha 换代后，未重编的 Beta 直接跑会发生什么。
final class BetaHandle: SurfOpaqueHandle, AlphaFeature {
    weak var host: SurfHost?
    init(host: SurfHost) { self.host = host }
    var identity: String { "beta-handle" }
    /// 调用上游 Alpha 的 public API：返回值暴露 Beta 实际绑在哪一代。
    func ping() -> String { "beta sees alpha generation \(alphaGeneration())" }
    func poke() {}
    /// 实现的是**编译时那一代** Alpha 的 AlphaFeature。
    func featureName() -> String { "AlphaFeature implemented by beta" }
}

final class BetaPlugin: SurfPlugin {
    func activate(host: SurfHost) -> AnyObject? {
        let handle = BetaHandle(host: host)
        host.setObject("beta.handle", handle)
        host.note("B0 beta activate: \(handle.ping())")
        return handle
    }
}

@_cdecl("surf_plugin_entry")
public func surf_plugin_entry() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(BetaPlugin()).toOpaque()
}
