import AppKit
import DashSDK
import SwiftUI
import WebKit

/// 插件入口。壳按 image handle `dlsym` 取这个符号（每个插件都叫这个名字）。
@_cdecl("dash_plugin_entry")
public func dash_plugin_entry() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(LayoutPlugin()).toOpaque()
}

/// dash-layout 的 Swift 半身：占 `root` 槽，摆好 WebView 与 sidebar 槽，
/// 并把会话展示面放进保管箱供下游使用。
final class LayoutPlugin: DashPlugin {
    /// 本插件那条工具栏贡献被点击时广播的主题。
    /// 主题名是字符串而不是闭包，所以它天然跨得过世代替换。
    static let newSessionTopic = "dash.layout.newSession"

    func activate(host: DashHost) -> AnyObject? {
        guard let webView = host.objects.object(DashObjects.Key.webView, as: WKWebView.self) else {
            // WKWebView 归壳所有；它不在说明壳还没造好窗口，这时不该装配。
            host.log("保管箱里没有 WKWebView，layout 缺席（壳会回落全出血网页模式）")
            return nil
        }

        let handle = DashPluginHandle()
        let surface = WebViewConversationSurface(webView: webView, log: { host.log($0) })
        host.objects.setObject(DashObjects.Key.conversationSurface, surface)

        // 壳的菜单只喊命令，不做事——会话展示面在这里，所以由本插件接。
        host.events.subscribe(DashEventBus.Topic.menuCommand) { payload in
            switch payload["command"] as? String {
            case "openSettings": surface.openSettings()
            case "newSession": surface.startSession(workspaceId: nil)
            default: break
            }
        }.kept(by: handle)

        // 「新建会话」不再占工具栏：那一格让给了 dash-sidebar 的「筛选」。
        // 入口还有三个——⌘N（菜单）、侧边栏分组头 hover 出的加号、页面自己的按钮，
        // 所以这条主题保留：第三方要往工具栏放一颗新建按钮，emit 它即可。
        host.events.subscribe(Self.newSessionTopic) { _ in
            surface.startSession(workspaceId: nil)
        }.kept(by: handle)

        host.register(slot: "root") {
            AnyView(RootLayoutView(host: host, webView: webView))
        }.kept(by: handle)

        host.log("layout 上线")
        return handle
    }
}

/// root 槽的视图。
///
/// 这一层是 SwiftUI 的，只为了做一件事：**读 registry / contributions 建立观察依赖**。
/// `sidebarVersion` 一变，SwiftUI 就会调 `updateNSViewController`，
/// 由 `LayoutSplitController` 去装上/摘掉 sidebar 分栏项；
/// `contributionRevision` 一变则去重建工具栏。
struct RootLayoutView: View {
    let host: DashHost
    let webView: WKWebView

    var body: some View {
        SplitRepresentable(host: host, webView: webView,
                           sidebarVersion: host.registry.version(of: "sidebar"),
                           contributionRevision: host.contributions.revision)
            .ignoresSafeArea()
    }
}

struct SplitRepresentable: NSViewControllerRepresentable {
    let host: DashHost
    let webView: WKWebView
    /// 只为触发 `updateNSViewController`；值本身在控制器里重新读一遍 registry。
    let sidebarVersion: Int
    /// 同上，对应贡献槽。任何一条贡献增删改都会让它跳，控制器据此重扫 `toolbar` 槽。
    let contributionRevision: Int

    func makeNSViewController(context: Context) -> LayoutSplitController {
        let controller = LayoutSplitController(host: host, webView: webView)
        controller.syncSidebar()
        return controller
    }

    func updateNSViewController(_ controller: LayoutSplitController, context: Context) {
        controller.syncSidebar()
        controller.syncToolbar()
    }
}
