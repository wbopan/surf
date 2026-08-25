import SwiftUI
import WebKit
import DashSDK

// 世代号由编译期 -D 给：同一份源码编出 g1/g2 两代（计划 §6.1 的 module-alias 方案，
// 这里用不同 module-name + 同一源码来模拟"改了源码重编一代"）。
#if GEN2
let generation = 2
#else
let generation = 1
#endif

/// 插件自定义协议——**不进 SDK**（模拟 dash-layout 的 DashSidebarProvider）。
/// 每一代 module 各有一份同名类型，用来验证断言 4：两代类型隔离的失败形态。
public protocol AlphaFeature: AnyObject {
    func featureName() -> String
}

/// 供下游插件（beta）调用的 public API——断言 6 用它看清"A 换代后旧 B 绑在哪一代"。
public func alphaGeneration() -> Int { generation }

/// 断言 1 的核心：Observation 宏在命令行 swiftc 下是否可用、跨 dylib 是否工作。
@Observable
final class AlphaModel {
    var tick: Int = 0
}

/// 宿主保管箱里的 WKWebView 借来排版（计划 §7.1：实例归壳，插件只借用）。
struct WebPane: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct AlphaView: View {
    let model: AlphaModel
    let gen: Int
    let webView: WKWebView?
    var body: some View {
        VStack(spacing: 10) {
            Text("Alpha gen \(gen)")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(gen == 1 ? Color.blue : Color.orange)
            Text("tick = \(model.tick)")
                .font(.system(size: 16, design: .monospaced))
            Button("bump") { model.tick += 1 }
            if let webView {
                WebPane(webView: webView).frame(height: 60)
            }
        }
        .padding(24)
        .frame(width: 300, height: 230)
        .background(gen == 1 ? Color.blue.opacity(0.18) : Color.orange.opacity(0.18))
    }
}

/// activate 返回的 handle：壳持有 = 该世代在役，壳释放 = 退休。
/// deinit 经 host.note 报回宿主，验证 ARC 真的回收（断言 3）。
final class AlphaHandle: DashOpaqueHandle, AlphaFeature {
    let gen: Int
    weak var host: DashHost?
    let model = AlphaModel()
    init(gen: Int, host: DashHost) { self.gen = gen; self.host = host }
    func poke() { model.tick += 1 }
    var identity: String { "alpha-handle-g\(gen)" }
    func ping() -> String { "pong from alpha g\(gen)" }
    func featureName() -> String { "AlphaFeature g\(gen)" }
    deinit { host?.note("DEINIT alpha handle g\(gen)") }
}

final class AlphaPlugin: DashPlugin {
    func activate(host: DashHost) -> AnyObject? {
        let handle = AlphaHandle(gen: generation, host: host)
        let webView = host.object("shell.webview") as? WKWebView
        host.register(slot: "main", version: generation) { [model = handle.model] in
            AnyView(AlphaView(model: model, gen: generation, webView: webView))
        }
        host.setObject("alpha.handle.g\(generation)", handle)

        if generation != 1, let prevAny = host.object("alpha.handle.g1") {
            // 断言 5：经 SDK existential（世代无关词汇）跨代调用上一代的对象。
            if let prev = prevAny as? DashOpaqueHandle {
                host.note("A5 sdk-existential-cross-gen: \(prev.ping())")
            } else {
                host.note("A5 FAIL: 上一代对象 as? DashOpaqueHandle 失败")
            }
            // 断言 4：拿上一代对象 as? **本代**的 AlphaFeature（同名、不同 module）。
            // 期望 nil（干净失败），而不是崩溃或错误命中。
            let casted = prevAny as? AlphaFeature
            host.note("A4 cross-gen-cast AlphaFeature => " +
                      (casted == nil ? "nil" : "NON-NIL(\(casted!.featureName()))"))
        }
        return handle
    }
    deinit { /* 世代退休 */ }
}

/// ABI 入口（计划 §4.1）：返回 DashPlugin 实现的不透明指针。
@_cdecl("dash_plugin_entry")
public func dash_plugin_entry() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(AlphaPlugin()).toOpaque()
}
