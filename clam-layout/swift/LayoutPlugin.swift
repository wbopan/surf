import AppKit
import ClamSDK
import SwiftUI
import WebKit

/// 插件入口。壳按 image handle `dlsym` 取这个符号（每个插件都叫这个名字）。
@_cdecl("clam_plugin_entry")
public func clam_plugin_entry() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(LayoutPlugin()).toOpaque()
}

/// clam-layout 的 Swift 半身：占 `root` 槽，摆好 WebView 与 sidebar 槽，
/// 并把会话展示面放进保管箱供下游使用。
final class LayoutPlugin: ClamPlugin {
    /// 本插件那条工具栏贡献被点击时广播的主题。
    /// 主题名是字符串而不是闭包，所以它天然跨得过世代替换。
    static let newSessionTopic = "clam.layout.newSession"

    /// 告诉壳"页面 URL 要带哪些查询参数"的粘性主题（壳侧同名常量在
    /// `MainWindowController.webQueryTopic`）。
    ///
    /// **参数名是 dsh 网页那一侧的私有词汇，定义权在这儿**：壳既不认得
    /// `clam-native-sidebar`，也不认得 `sidebar` 这个槽名——它从前两样都认得，
    /// 于是第三方写一个占 `sidebar` 槽的替代品必须沿用这两个字符串，
    /// 换个槽名就永远拿不到门控（网页侧边栏被藏、原生侧边栏又不存在）。
    static let webQueryTopic = "clam.web.query"

    /// 原生侧边栏在场时页面要带的那个参数：网页自己的侧边栏让位。
    /// clam-layout 的 client 半边认这一个（`?clam-native-sidebar=1`）。
    static let nativeSidebarParam = "clam-native-sidebar"

    func activate(host: ClamHost) -> AnyObject? {
        guard let webView = host.objects.object(ClamObjects.Key.webView, as: WKWebView.self) else {
            // WKWebView 归壳所有；它不在说明壳还没造好窗口，这时不该装配。
            host.log("保管箱里没有 WKWebView，layout 缺席（壳会回落全出血网页模式）")
            return nil
        }

        let handle = ClamPluginHandle()
        let surface = WebViewConversationSurface(webView: webView, log: { host.log($0) })
        host.objects.setObject(ClamObjects.Key.conversationSurface, surface)

        // 壳的菜单只喊命令，不做事——会话展示面在这里，所以由本插件接。
        host.events.subscribe(ClamEventBus.Topic.menuCommand) { payload in
            switch payload["command"] as? String {
            case "openSettings":
                // 有原生设置窗口就让它来（clam-settings 在场时占着 settingsOwner）。
                // 两边都响应的话，原生窗口开出来的同时主窗口里还会弹一层网页 modal。
                if host.objects.object(ClamObjects.Key.settingsOwner) == nil {
                    surface.openSettings()
                }
            case "newSession": surface.startSession(workspaceId: nil)
            default: break
            }
        }.kept(by: handle)

        // 「新建会话」不再占工具栏：那一格让给了 clam-sidebar 的「筛选」。
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
    let host: ClamHost
    let webView: WKWebView

    var body: some View {
        SplitRepresentable(host: host, webView: webView,
                           sidebarVersion: host.registry.version(of: "sidebar"),
                           contributionRevision: host.contributions.revision)
            .ignoresSafeArea()
    }
}

struct SplitRepresentable: NSViewControllerRepresentable {
    let host: ClamHost
    let webView: WKWebView
    /// 只为触发 `updateNSViewController`；值本身在控制器里重新读一遍 registry。
    let sidebarVersion: Int
    /// 同上，对应贡献槽。任何一条贡献增删改都会让它跳，控制器据此重扫 `toolbar` 槽。
    let contributionRevision: Int

    func makeNSViewController(context: Context) -> LayoutSplitController {
        let controller = LayoutSplitController(host: host, webView: webView)
        controller.syncSidebar()
        publishWebQuery()
        return controller
    }

    func updateNSViewController(_ controller: LayoutSplitController, context: Context) {
        controller.syncSidebar()
        controller.syncToolbar()
        publishWebQuery()
    }

    /// 告诉壳页面该带哪些查询参数。**发布点在这儿是有理由的**：`sidebarVersion`
    /// 是这个 representable 的输入，槽被占/被释放时 SwiftUI 必然重新算它一次
    /// ——不必再另外盯 registry。
    ///
    /// **只在真变了的时候发**：`emitSticky` 是广播，每轮 update 都发一遍会让壳
    /// 反复比对（虽然它也去重，但那是它的好意，不该指望）。
    private func publishWebQuery() {
        let query = host.registry.isOccupied(LayoutSlots.sidebar)
            ? [LayoutPlugin.nativeSidebarParam: "1"] : [:]
        let last = host.events.last(LayoutPlugin.webQueryTopic)?.compactMapValues { $0 as? String }
        guard last != query else { return }
        host.events.emitSticky(LayoutPlugin.webQueryTopic, query)
    }
}
