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
/// **数据面住在 node 半边**（M10）：会话与工作区的镜像、写操作、事件订阅全在
/// `lib/index.js`，经桥推 JSON 下来。这半边只做三件事——把投影渲染成列表、
/// 把用户动作发上去、把选中状态收敛。
///
/// 为什么数据面不在这儿：壳与共享 module 随 app bundle 冻结、用户改不了，
/// 而会话/工作区的 wire 模型是随 dsh 版本演进最快的那一层——层放错了。
/// node 半边住在 dsh 进程里，随 npm 可更新，且 Swift 插件怎么热替换它都不动。
///
/// **跨代不闪列表**：每代把收到的最后一份 snapshot 原样（`NSDictionary`，
/// 系统类型跨代安全）存进保管箱；下一代 activate 时先拿它渲染，再请求 fresh
/// 全量，到了就替换。**箱里绝不放本 module 定义的类型**——新旧两代的同名类型
/// 互不认识，取出来 `as?` 只会安静地得到 nil（M2 断言 4）。
final class SidebarPlugin: DashPlugin {
    /// 保管箱里那份最后的快照（`NSDictionary`）。
    private static let snapshotKey = "dash.sidebar.snapshot"

    func activate(host: DashHost) -> AnyObject? {
        guard let surface = host.objects.object(DashObjects.Key.conversationSurface)
                as? DashConversationSurface else {
            host.log("保管箱里没有会话展示面，sidebar 缺席（dash-layout 没装配？）")
            return nil
        }

        let handle = DashPluginHandle()

        // 先用上一代留下的快照开局（没有就是空列表），换代时列表不闪。
        let seed = host.objects.object(Self.snapshotKey, as: NSDictionary.self)
            .flatMap { $0 as? [String: Any] }
            .flatMap(SidebarSnapshot.decode) ?? .empty

        let model = AppSidebarModel(snapshot: seed, bridge: host.bridge,
                                    surface: surface, log: { host.log($0) })
        // 选中高亮活过热替换：真相在 dsh 侧（页面会把 currentSession 报回来），
        // 这里存的只是"页面还没报之前先亮哪一行"的装饰状态。
        model.selectedSessionId = host.store.string("selectedSessionId")
        model.onSelectionChange = { host.store.setString("selectedSessionId", $0) }

        // 桥下行三条频道（协议见 lib/index.js 顶部注释）。
        host.bridge.onMessage { [weak model] channel, payload in
            guard let model else { return }
            switch channel {
            case "snapshot":
                guard let snapshot = SidebarSnapshot.decode(payload) else {
                    host.log("收到解不动的 snapshot，保留上一份")
                    return
                }
                // 先落箱再上屏：下一代取的是这一份。
                host.objects.setObject(Self.snapshotKey, payload as NSDictionary)
                model.apply(snapshot: snapshot)

            case "forked":
                // 分叉完成：切到子会话（与 web 的 fork().then(open) 同序）。
                guard let childId = payload["sessionId"] as? String else { return }
                model.activate(sessionId: childId)

            case "error":
                model.reportFailure(action: payload["action"] as? String ?? "",
                                    reason: payload["message"] as? String ?? "未知原因")

            default:
                break // 未知频道忽略（协议向前兼容，同桥的纪律）
            }
        }.kept(by: handle)

        // 页内桥上报的当前会话（壳收到 WKScriptMessage 后转成 EventBus 事件）。
        host.events.subscribe(DashEventBus.Topic.pageCurrentSession) { payload in
            guard let id = payload["id"] as? String else { return }
            model.pageDidSelect(sessionId: id)
        }.kept(by: handle)

        host.register(slot: "sidebar") {
            AnyView(SidebarView(model: model, surface: surface))
        }.kept(by: handle)

        // 请求一份 fresh 全量。**每代都要问**：node 半边只在数据变化时推，
        // 不为新连上来的世代补发（补发逻辑归请求方，与桥不给壳补发 app-build 同理）。
        host.bridge.send(action: "snapshot")

        host.log("sidebar 上线（种子快照 v\(seed.version)，已请求全量）")
        return handle
    }
}
