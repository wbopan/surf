import AppKit
import Foundation
import SwiftUI

/// 侧边栏的筛选 / 视图状态。
///
/// **它是 UI 政策，不是数据**——node 半边照实推全量（含归档），显示什么由这里说了算。
/// 之所以单独成一个 ObservableObject 而不是塞进 `AppSidebarModel`：工具栏那枚
/// 「筛选」按钮是 AppKit 的 `NSMenuToolbarItem`，和 SwiftUI 列表两边都要读写它，
/// 谁也不该是谁的子状态。
///
/// **跨世代靠 UserDefaults 而不是保管箱**：三个字段都是用户当场拨的偏好
/// （拨完就该记住，重启也该记住），保管箱只活到进程结束。
@MainActor
final class SidebarFilterState: ObservableObject {
    /// 列表的组织轴。**只剩两档**：按工作区分组，或按时间分段。
    ///
    /// 曾经还有个 `pending`（当过滤器用，仍按工作区分组）。它升格成了**置顶分区**
    /// ——「有什么在等着你」是恒常要看见的东西，不该是一个要先切过去才看得到的档位。
    /// 收的仍是 `SidebarSessionStatus.needsAttention`：待批准、待回答、出错、跑完了
    /// （后三样来自 surf-notify 的 `surfPending`，它缺席时退回只有待批准）。
    enum Mode: String, CaseIterable {
        case workspace
        case time

        /// 「筛选」菜单里那两行字。**rawValue 才是身份**（UserDefaults 存它），
        /// 显示名随语言走。
        func title(_ strings: L) -> String {
            switch self {
            case .workspace: return strings.groupByWorkspace
            case .time: return strings.groupByTime
            }
        }
    }

    @Published var mode: Mode = .workspace { didSet { defaults.set(mode.rawValue, forKey: Keys.mode) } }
    /// 被「筛选」菜单取消勾选的工作区 id（兜底组用 `Self.otherGroupKey`）。
    @Published var hiddenGroups: Set<String> = [] {
        didSet { defaults.set(hiddenGroups.sorted().joined(separator: ","), forKey: Keys.hidden) }
    }
    @Published var showArchived = false { didSet { defaults.set(showArchived, forKey: Keys.archived) } }
    /// 一条会话都没有的**真**工作区要不要连组头一起收起来。**默认收起（true）**。
    ///
    /// 这条曾经是无条件的，后来当成 bug 改掉过——dsh 网页端的 `deriveGroups` 是
    /// "Every group shows"，我们私自滤掉就是在制造显示差异。现在它是筛选菜单里
    /// 一枚**用户看得见、关得掉**的开关，性质和「显示已归档」一样：
    /// 可见集合由用户当场决定，不是我们背着人删东西。
    @Published var hideEmptyWorkspaces = true {
        didSet { defaults.set(hideEmptyWorkspaces, forKey: Keys.hideEmpty) }
    }
    /// 搜索框内容。**不持久化**——重启后还留着上次的搜索词只会让人以为会话丢了。
    @Published var query = ""

    /// 兜底组（未分组）在隐藏集合里的键。它没有 workspaceId，借组 id 顶上。
    static let otherGroupKey = "surf.sidebar.other"

    private let defaults: UserDefaults

    private enum Keys {
        static let mode = "surf.sidebar.filter.mode"
        static let hidden = "surf.sidebar.filter.hiddenGroups"
        static let archived = "surf.sidebar.filter.showArchived"
        static let hideEmpty = "surf.sidebar.filter.hideEmptyWorkspaces"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // **读到不认识的值就退默认**（旧的 `"all"` / `"pending"` 都会落到
        // `.workspace`）。这不是迁移代码，是"陌生输入退默认"——本仓库不写迁移。
        if let raw = defaults.string(forKey: Keys.mode), let value = Mode(rawValue: raw) {
            mode = value
        }
        let csv = defaults.string(forKey: Keys.hidden) ?? ""
        hiddenGroups = Set(csv.split(separator: ",").map(String.init)).filter { !$0.isEmpty }
        showArchived = defaults.bool(forKey: Keys.archived)
        // 没设过 = 默认收起。`bool(forKey:)` 读不到时给 false，
        // 那正好是反的，所以先问一句这个键在不在。
        if defaults.object(forKey: Keys.hideEmpty) != nil {
            hideEmptyWorkspaces = defaults.bool(forKey: Keys.hideEmpty)
        }
    }

    /// 有没有筛选在生效（工具栏按钮据此挂角标）。搜索词不算——搜索框自己看得见。
    var isNarrowed: Bool { !hiddenGroups.isEmpty || showArchived || mode != .workspace }

    func toggleGroup(_ key: String) {
        if hiddenGroups.contains(key) { hiddenGroups.remove(key) } else { hiddenGroups.insert(key) }
    }

    func isShown(_ key: String) -> Bool { !hiddenGroups.contains(key) }
}

extension SidebarGroup {
    /// 分组在「隐藏」集合里的键：真工作区用 workspaceId，兜底组用固定键。
    var filterKey: String { workspaceId ?? SidebarFilterState.otherGroupKey }
}

/// 筛选规则的唯一实现。列表（SidebarView）与菜单快捷键导航（SidebarShortcuts）
/// 都从这里取"用户此刻看到的会话及其顺序"——规则分两份的话，⌘1-9 跳到的
/// 就不是屏幕上数出来的那一条。
extension SidebarFilterState {
    /// 一条会话过不过筛：归档开关 → 搜索词。
    /// 搜索匹配标题**与摘要**（摘要是用户真正记得住的那句话）。
    func passes(_ session: SidebarSession) -> Bool {
        if session.archived && !showArchived { return false }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return session.displayTitle.lowercased().contains(q)
            || session.preview.lowercased().contains(q)
    }

    /// 工作区视图的分组（已按筛选裁过）。
    ///
    /// **真工作区组恒显示，一条会话都没有也显示**——对齐 dsh Web 的
    /// `deriveGroups`（注释原话 "Every group shows"，它对每个 workspace 记录
    /// 无条件出一个组）。曾经是"空组不出现"，那让「添加工作区」变成一个**看上去
    /// 毫无反应**的按钮：新建的工作区 `sessionIds` 必然是空的（dsh 的
    /// `createCanonical` 写死 `sessionIds: []`，不认领该目录下已有的会话），
    /// 于是请求成功了、记录也落盘了，屏幕上却一点动静都没有。
    /// 会话全被归档掉的组同理——组头消失会让人以为工作区被删了。
    ///
    /// 兜底组（未分组）不适用：它是个桶，没东西就不该有桶。
    ///
    /// **「查询」模式下也不摆空组头**（搜索词在场，或按待处理筛）：那两种模式下
    /// 用户问的是"哪些符合"，一排空组头是噪音。dsh 没有这两个模式，这条取舍是
    /// 我们自己的。
    func filteredGroups(from groups: [SidebarGroup]) -> [SidebarGroup] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let querying = !q.isEmpty
        return groups.compactMap { group in
            if hiddenGroups.contains(group.filterKey) { return nil }
            let hits = group.sessions.filter(belongsToSections)
            if !hits.isEmpty {
                return SidebarGroup(id: group.id, workspaceId: group.workspaceId,
                                    title: group.title, sessions: hits)
            }
            // 组名命中搜索：整组留着（但仍要过归档/待处理那两关）。
            if !q.isEmpty && group.title.lowercased().contains(q) {
                let rest = group.sessions.filter { session in
                    if session.archived && !showArchived { return false }
                    // 待处理的行归置顶分区，这儿不重复。
                    return !session.status.needsAttention
                }
                if rest.isEmpty { return nil }
                return SidebarGroup(id: group.id, workspaceId: group.workspaceId,
                                    title: group.title, sessions: rest)
            }
            // 空的真工作区：组头留着（见上面的整段说明）——除非用户在筛选菜单里
            // 让它收起来，那是默认档。
            if !querying, group.workspaceId != nil, !hideEmptyWorkspaces {
                return SidebarGroup(id: group.id, workspaceId: group.workspaceId,
                                    title: group.title, sessions: [])
            }
            return nil
        }
    }

    /// 一条会话进不进**下面那些分区**。过筛之外还要不是待处理——
    /// 待处理的行被置顶分区**提走**了（提取式，不重复）。
    func belongsToSections(_ session: SidebarSession) -> Bool {
        passes(session) && !session.status.needsAttention
    }

    /// 置顶「待处理」分区收的行：过筛 + `needsAttention`，按 updatedAt 倒序。
    /// 空数组 = 整个分区不出现（没有"恭喜，没有待办"这种空态）。
    ///
    /// **两种分组视图共用它**：待处理是"有什么在等着你"，与你此刻按什么分组无关。
    func pendingSessions(from groups: [SidebarGroup]) -> [SidebarSession] {
        groups.filter { !hiddenGroups.contains($0.filterKey) }
            .flatMap { group in group.sessions.filter { passes($0) && $0.status.needsAttention } }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 展示序的扁平会话表——快捷键导航（⌘⇧[ ]、⌘1-9、⌘⌥A）按它数数。
    /// **置顶的待处理分区排在最前**，和列表画出来的一模一样；其后
    /// 「按时间」= 全量按 updatedAt 倒序（分段视图段内就是这个序，段与段首尾相接），
    /// 「按工作区」= 分组序 × 组内序。收起的分组不跳过——收起只是折叠了显示，
    /// 行仍是列表成员，⌘1-9 的数法要和「筛选」的世界观一致。
    func orderedSessions(from groups: [SidebarGroup]) -> [SidebarSession] {
        let pending = pendingSessions(from: groups)
        if mode == .time {
            return pending + groups.filter { !hiddenGroups.contains($0.filterKey) }
                .flatMap { $0.sessions.filter(belongsToSections) }
                .sorted { $0.updatedAt > $1.updatedAt }
        }
        return pending + filteredGroups(from: groups).flatMap(\.sessions)
    }
}

/// 把闭包挂到 `NSMenuItem` 上的小把手。
///
/// `NSMenuItem.target` 是 **weak**，所以 handler 还得由 menu item 自己强持有一份
/// ——`representedObject` 就是那份。少了它，菜单弹出来点下去必崩。
final class MenuActionTarget: NSObject {
    private let run: () -> Void

    init(run: @escaping () -> Void) { self.run = run }

    @objc func fire() { run() }

    /// 造一条带动作的菜单项（`state` 决定勾不勾）。
    static func item(_ title: String, checked: Bool = false,
                     run: @escaping () -> Void) -> NSMenuItem {
        let target = MenuActionTarget(run: run)
        let item = NSMenuItem(title: title, action: #selector(MenuActionTarget.fire), keyEquivalent: "")
        item.target = target
        item.representedObject = target // target 是 weak，这份强引用不能省
        item.state = checked ? .on : .off
        return item
    }
}
