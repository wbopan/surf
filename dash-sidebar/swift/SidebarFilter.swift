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
    enum Mode: String, CaseIterable {
        case all
        case time
        case pending

        var title: String {
            switch self {
            case .all: return "全部"
            case .time: return "按时间"
            case .pending: return "待批准"
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
    static let otherGroupKey = "dash.sidebar.other"

    private let defaults: UserDefaults

    private enum Keys {
        static let mode = "dash.sidebar.filter.mode"
        static let hidden = "dash.sidebar.filter.hiddenGroups"
        static let archived = "dash.sidebar.filter.showArchived"
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
