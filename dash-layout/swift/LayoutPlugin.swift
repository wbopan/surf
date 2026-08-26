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

        // 工具栏上的"新建会话"：**本插件也只是一个普通贡献者**。
        // 消费端（LayoutSplitController）不认得这个按钮，它只会把点击翻译成
        // 下面这条广播——第三方插件加按钮走的是一模一样的路。
        host.events.subscribe(Self.newSessionTopic) { _ in
            surface.startSession(workspaceId: nil)
        }.kept(by: handle)

        host.contribute(to: LayoutSplitController.toolbarSlot,
                        id: "newSession",
                        order: -100, // 排在所有第三方贡献之前
                        metadata: [
                            "label": "新建会话",
                            "symbol": "square.and.pencil",
                            "tooltip": "新建会话",
                            "event": Self.newSessionTopic,
                        ]) {
            // 兜底视图：`symbol` 认不出来时（比如系统没这个 SF Symbol）
            // 消费端会改托管这个 SwiftUI 按钮。两条路线触发的是同一条广播，
            // 行为不会分叉。
            AnyView(
                Button {
                    host.events.emit(LayoutPlugin.newSessionTopic)
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.borderless)
                .help("新建会话")
                .accessibilityIdentifier("toolbar.newSession")
            )
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
