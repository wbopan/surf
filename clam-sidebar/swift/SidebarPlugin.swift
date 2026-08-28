import AppKit
import ClamLayout
import ClamSDK
import Foundation
import SwiftUI

/// 插件入口。壳按 image handle `dlsym` 取这个符号。
@_cdecl("clam_plugin_entry")
public func clam_plugin_entry() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(SidebarPlugin()).toOpaque()
}

/// clam-sidebar 的 Swift 半身：占 clam-layout 的 `sidebar` 槽。
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
final class SidebarPlugin: ClamPlugin {
    /// 保管箱里那份最后的快照（`NSDictionary`）。
    private static let snapshotKey = "clam.sidebar.snapshot"

    func activate(host: ClamHost) -> AnyObject? {
        guard let surface = host.objects.object(ClamObjects.Key.conversationSurface)
                as? ClamConversationSurface else {
            host.log("保管箱里没有会话展示面，sidebar 缺席（clam-layout 没装配？）")
            return nil
        }

        let handle = ClamPluginHandle()

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
        host.events.subscribe(ClamEventBus.Topic.pageCurrentSession) { payload in
            guard let id = payload["id"] as? String else { return }
            model.pageDidSelect(sessionId: id)
        }.kept(by: handle)

        // 筛选 / 视图状态。列表（SwiftUI）与工具栏那枚菜单（AppKit）共读这一份。
        let filter = SidebarFilterState()

        host.register(slot: "sidebar") {
            AnyView(SidebarView(model: model, filter: filter, surface: surface))
        }.kept(by: handle)

        // 工具栏的「筛选」。**clam-layout 那格原本是「新建会话」**——新建的入口
        // 还有三个（⌘N、分组头的加号、页面自己的按钮），而"哪些工作区显示、
        // 归档要不要露出来"没有别的地方可放，这一格给了它更值。
        //
        // 走 `menu` 路线拿的是 `NSMenuToolbarItem`：玻璃按钮 + 系统菜单，
        // 勾选态、键盘操作、深浅色、缩到窄窗口时的溢出全归系统。
        // 设计稿里画的是 NSPopover，落地改成菜单——贡献槽递不出锚点视图，
        // 而"一串带勾的开关"本来就是菜单的母语。
        let buildMenu: @convention(block) (NSMenu) -> Void = { menu in
            MainActor.assumeIsolated {
                Self.populate(menu: menu, model: model, filter: filter)
            }
        }
        host.contribute(to: LayoutToolbar.slot,
                        id: "filter",
                        order: -100,
                        metadata: [
                            "label": "筛选",
                            "symbol": "line.3.horizontal.decrease",
                            "tooltip": "筛选会话",
                            "menu": buildMenu,
                        ]) {
            // 兜底视图：系统认不出那个 SF Symbol 时才用得上。菜单路线走不了，
            // 退化成"把筛选清空"这一个动作——比一颗点不动的按钮有用。
            AnyView(
                Button {
                    MainActor.assumeIsolated {
                        filter.hiddenGroups = []
                        filter.showArchived = false
                        filter.mode = .all
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .buttonStyle(.borderless)
                .help("清除筛选")
                .accessibilityIdentifier("toolbar.sidebarFilter")
            )
        }.kept(by: handle)

        // 请求一份 fresh 全量。**每代都要问**：node 半边只在数据变化时推，
        // 不为新连上来的世代补发（补发逻辑归请求方，与桥不给壳补发 app-build 同理）。
        host.bridge.send(action: "snapshot")

        host.log("sidebar 上线（种子快照 v\(seed.version)，已请求全量）")
        return handle
    }

    /// 现场填「筛选」菜单。**每次弹出前重建**（`ContributionMenuDelegate`），
    /// 所以这里读到的分组、勾选态都是当场的。
    @MainActor
    private static func populate(menu: NSMenu, model: AppSidebarModel, filter: SidebarFilterState) {
        let groups = model.groups
        if !groups.isEmpty {
            // 这一段**不加分区标题**：四个带勾的工作区名自己已经说清是什么，
            // 而 AppKit 在菜单**首项**上的分区标题不渲染（`.sectionHeader` 和
            // disabled 的普通项都试过，一个都不出来）。
            for group in groups {
                let key = group.workspaceId ?? SidebarFilterState.otherGroupKey
                menu.addItem(MenuActionTarget.item(group.title, checked: filter.isShown(key)) {
                    MainActor.assumeIsolated { filter.toggleGroup(key) }
                })
            }
            menu.addItem(.separator())
        }

        menu.addItem(MenuActionTarget.item("显示已归档", checked: filter.showArchived) {
            MainActor.assumeIsolated { filter.showArchived.toggle() }
        })

        if filter.isNarrowed {
            menu.addItem(.separator())
            menu.addItem(MenuActionTarget.item("清除筛选") {
                MainActor.assumeIsolated {
                    filter.hiddenGroups = []
                    filter.showArchived = false
                    filter.mode = .all
                }
            })
        }
    }
}
