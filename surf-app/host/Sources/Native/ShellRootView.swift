import SurfSDK
import SwiftUI
import WebKit

/// 壳挂在窗口上的那一个 SwiftUI 根：把 `root` 槽的视图搬上屏；没人占就露出
/// **终极逃生舱**——全出血的 WKWebView，即完整网页模式。
///
/// 这是 §0.5-5 的落地点：surf-layout 被禁用、编译失败、或者根本没装，
/// surf 都还是一个能用的 dsh 客户端，只是没有原生外壳而已。
///
/// `.id(version)` 是世代替换的落地点（§6.3-2）：插件换代 → 版本号跳变 →
/// SwiftUI 整棵重建、`@State` 归零，需要活过替换的状态由 `SurfStore`
/// 或 TS 半身 rehydrate。registry 是 `@Observable`，body 里读它即建立依赖。
struct ShellRootView: View {
    let registry: SurfRegistry
    let webView: WKWebView

    var body: some View {
        if let view = registry.view(for: "root") {
            view.id(registry.version(of: "root"))
        } else {
            FullBleedWebView(webView: webView)
                .ignoresSafeArea()
        }
    }
}

/// 逃生舱：把壳自己那个 WKWebView 铺满窗口。
///
/// 与 surf-layout 借用的是**同一个实例**（保管箱里那个），所以在
/// "插件模式 ↔ 逃生舱"之间来回切换时页面不重载、JS 状态存活。
struct FullBleedWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.removeFromSuperview()
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
