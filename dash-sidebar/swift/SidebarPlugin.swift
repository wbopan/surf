import DSHKit
import DashLayout
import DashSDK
import Foundation
import SwiftUI

/// 插件入口。壳按 image handle `dlsym` 取这个符号。
@_cdecl("dash_plugin_entry")
public func dash_plugin_entry() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(SidebarPlugin()).toOpaque()
}

/// dash-sidebar 的 Swift 半身：占 dash-layout 的 `sidebar` 槽。
///
/// **数据面**（计划 §7.2 的 M6 方案，实做略有出入见 README）：`SessionStore` 由本插件创建，
/// 但存进保管箱、跨世代复用——`SessionStore` 出自 DSHKit，而 DSHKit 是随 bundle 分发的
/// **共享 module**，类型身份跨世代稳定，所以从箱里取出来的旧实例转型仍然成立。
/// 这样热替换时列表不闪、WS 事件流不断，也不必让壳替插件管数据。
///
/// 端点变了（dsh 换端口回来）就丢掉旧的重建：base URL 也记在箱里供比对。
final class SidebarPlugin: DashPlugin {
    private static let storeKey = "dash.sidebar.sessionStore"
    private static let storeBaseKey = "dash.sidebar.sessionStoreBase"

    func activate(host: DashHost) -> AnyObject? {
        guard let base = host.objects.object(DashObjects.Key.endpoint, as: NSURL.self) as URL? else {
            host.log("保管箱里没有 endpoint，sidebar 缺席（layout 只画会话区）")
            return nil
        }
        guard let surface = host.objects.object(DashObjects.Key.conversationSurface)
                as? DashConversationSurface else {
            host.log("保管箱里没有会话展示面，sidebar 缺席（dash-layout 没装配？）")
            return nil
        }

        let handle = DashPluginHandle()
        let store = reuseOrCreateStore(host: host, base: base)

        let model = AppSidebarModel(store: store, surface: surface, log: { host.log($0) })
        // 选中高亮活过热替换：真相在 dsh 侧（页面会把 currentSession 报回来），
        // 这里存的只是"页面还没报之前先亮哪一行"的装饰状态。
        model.selectedSessionId = host.store.string("selectedSessionId")
        model.onSelectionChange = { host.store.setString("selectedSessionId", $0) }

        // 页内桥上报的当前会话（壳收到 WKScriptMessage 后转成 EventBus 事件）。
        host.events.subscribe(DashEventBus.Topic.pageCurrentSession) { payload in
            guard let id = payload["id"] as? String else { return }
            model.pageDidSelect(sessionId: id)
        }.kept(by: handle)

        host.register(slot: "sidebar") {
            AnyView(SidebarView(model: model, surface: surface))
        }.kept(by: handle)

        host.log("sidebar 上线（\(base.absoluteString)）")
        return handle
    }

    /// 端点没变就复用箱里那个 store；变了（或第一次）就新建并接管箱位。
    /// 标 `@MainActor` 是因为 `SessionStore` 是主线程类；类本身不能标——
    /// `dash_plugin_entry` 是 nonisolated 的 C 入口，构造不了隔离类型。
    @MainActor
    private func reuseOrCreateStore(host: DashHost, base: URL) -> SessionStore {
        let recorded = host.objects.object(Self.storeBaseKey, as: NSString.self) as String?
        if recorded == base.absoluteString,
           let existing = host.objects.object(Self.storeKey, as: SessionStore.self) {
            return existing
        }
        if let stale = host.objects.object(Self.storeKey, as: SessionStore.self) {
            stale.stop()
        }
        let store = SessionStore(transport: DSHTransportFactory.live(baseURL: base))
        host.objects.setObject(Self.storeKey, store)
        host.objects.setObject(Self.storeBaseKey, base.absoluteString as NSString)
        Task { await store.start() }
        return store
    }
}
