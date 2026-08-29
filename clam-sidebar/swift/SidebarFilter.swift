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
    /// 列表的组织轴。`pending` 只是个过滤器，仍按工作区分组。
    ///
    /// 「待处理」筛的是 `SidebarSessionStatus.needsAttention`——待批准、待回答、
    /// 出错、跑完了都算。**不只是待批准**：后三样来自 clam-notify 供出来的
    /// `clamPending`（它缺席时这枚胶囊就退回只有待批准，仍然可用）。
    enum Mode: String, CaseIterable {
        case all
        case time
        case pending

        var title: String {
            switch self {
            case .all: return "全部"
            case .time: return "按时间"
            case .pending: return "待处理"
            }
        }
    }

    @Published var mode: Mode = .all { didSet { defaults.set(mode.rawValue, forKey: Keys.mode) } }
    /// 被「筛选」菜单取消勾选的工作区 id（兜底组用 `Self.otherGroupKey`）。
    @Published var hiddenGroups: Set<String> = [] {
        didSet { defaults.set(hiddenGroups.sorted().joined(separator: ","), forKey: Keys.hidden) }
    }
    @Published var showArchived = false { didSet { defaults.set(showArchived, forKey: Keys.archived) } }
    /// 搜索框内容。**不持久化**——重启后还留着上次的搜索词只会让人以为会话丢了。
    @Published var query = ""

    /// 兜底组（未分组）在隐藏集合里的键。它没有 workspaceId，借组 id 顶上。
    static let otherGroupKey = "clam.sidebar.other"

    private let defaults: UserDefaults

    private enum Keys {
        static let mode = "clam.sidebar.filter.mode"
        static let hidden = "clam.sidebar.filter.hiddenGroups"
        static let archived = "clam.sidebar.filter.showArchived"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.string(forKey: Keys.mode), let value = Mode(rawValue: raw) {
            mode = value
        }
        let csv = defaults.string(forKey: Keys.hidden) ?? ""
        hiddenGroups = Set(csv.split(separator: ",").map(String.init)).filter { !$0.isEmpty }
        showArchived = defaults.bool(forKey: Keys.archived)
    }

    /// 有没有筛选在生效（工具栏按钮据此挂角标）。搜索词不算——搜索框自己看得见。
    var isNarrowed: Bool { !hiddenGroups.isEmpty || showArchived || mode != .all }

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
    /// 一条会话过不过筛：归档开关 → 待处理模式 → 搜索词。
    /// 搜索匹配标题**与摘要**（摘要是用户真正记得住的那句话）。
    func passes(_ session: SidebarSession) -> Bool {
        if session.archived && !showArchived { return false }
        if mode == .pending && !session.status.needsAttention { return false }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return session.displayTitle.lowercased().contains(q)
            || session.preview.lowercased().contains(q)
    }

    /// 工作区视图的分组（已按筛选裁过；空组不出现，但搜到组名时整组保留）。
    func filteredGroups(from groups: [SidebarGroup]) -> [SidebarGroup] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return groups.compactMap { group in
            if hiddenGroups.contains(group.filterKey) { return nil }
            let hits = group.sessions.filter(passes)
            if !hits.isEmpty {
                return SidebarGroup(id: group.id, workspaceId: group.workspaceId,
                                    title: group.title, sessions: hits)
            }
            // 组名命中搜索：整组留着（但仍要过归档/待处理那两关）。
            if !q.isEmpty && group.title.lowercased().contains(q) {
                let rest = group.sessions.filter { session in
                    if session.archived && !showArchived { return false }
                    if mode == .pending && !session.status.needsAttention { return false }
                    return true
                }
                if rest.isEmpty { return nil }
                return SidebarGroup(id: group.id, workspaceId: group.workspaceId,
                                    title: group.title, sessions: rest)
            }
            return nil
        }
    }

    /// 展示序的扁平会话表——快捷键导航（⌘⇧[ ]、⌘1-9、⌘⌥A）按它数数：
    /// 「按时间」= 全量按 updatedAt 倒序（分段视图段内就是这个序，段与段
    /// 首尾相接）；其余模式 = 分组序 × 组内序。收起的分组不跳过——收起只是
    /// 折叠了显示，行仍是列表成员，⌘1-9 的数法要和「筛选」的世界观一致。
    func orderedSessions(from groups: [SidebarGroup]) -> [SidebarSession] {
        if mode == .time {
            return groups.filter { !hiddenGroups.contains($0.filterKey) }
                .flatMap { $0.sessions.filter(passes) }
                .sorted { $0.updatedAt > $1.updatedAt }
        }
        return filteredGroups(from: groups).flatMap(\.sessions)
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
