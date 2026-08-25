import SwiftUI

// 设置窗口的导航列。数据来自网页半边上报的 `settings.section` ledger，
// 这里只负责画成一列原生 sidebar。
//
// 自动化标识符（同 dash-sidebar 的规矩，别靠中文/英文文案模糊匹配）：
//   settings.nav              导航列表
//   settings.nav.<sectionId>  某一行

/// 导航的一行。`id` 是 dsh 那边的 section key（`general` / `models` / …）。
struct SettingsSectionRow: Identifiable, Equatable {
    let id: String
    let label: String
}

/// 导航的数据面。
///
/// **真相在网页那边**：目录是 dsh 的 slot ledger 投影，选中页是面板的组件局部
/// state。这里存的两样都是投影——目录来自上报，选中来自用户点击后回写，
/// 丢了不心疼（重开窗口会重新上报）。
final class SettingsNavModel: ObservableObject {
    @Published var rows: [SettingsSectionRow] = []
    @Published var selection: String?

    /// 用户点了某一行（视图 → 控制器 → 网页）。
    var onSelect: ((String) -> Void)?

    /// 收到新目录。
    ///
    /// 选中页尽量保持不动：设置页的目录会随插件装卸变化，用户正看着 Models 时
    /// 来一次上报就跳回 General 是最烦人的那种"自作主张"。选中的那页真没了才换。
    func apply(rows: [SettingsSectionRow]) {
        self.rows = rows
        if let current = selection, rows.contains(where: { $0.id == current }) { return }
        selection = rows.first?.id
    }

    /// 视图侧的选中回写。相同值不重复通知（List 的 selection binding 会重复写入）。
    func select(_ id: String?) {
        guard let id, id != selection else { return }
        selection = id
        onSelect?(id)
    }
}

/// 导航列。
///
/// `List(selection:)` + `.listStyle(.sidebar)` 白送选中态、hover、键盘上下导航
/// 与系统材质——这正是"原生设置窗口"体感的大头，自绘一份只会更差。
struct SettingsNavView: View {
    @ObservedObject var model: SettingsNavModel

    var body: some View {
        List(selection: Binding(get: { model.selection },
                                set: { model.select($0) })) {
            ForEach(model.rows) { row in
                Label(row.label, systemImage: Self.symbol(for: row.id))
                    .accessibilityIdentifier("settings.nav.\(row.id)")
                    .tag(row.id)
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("settings.nav")
    }

    /// section key → SF Symbol。
    ///
    /// 网页那边的图标进不了 ledger（`settings.section` 的注册选项只有
    /// id/order/label），所以按 key 认。**认不出来的一律给通用滑块图标**：
    /// 第三方插件随时会往里加段，宁可图标平庸也不能让新段没有图标、行高不齐。
    static func symbol(for id: String) -> String {
        switch id {
        case "general": return "gearshape"
        case "models": return "cube"
        case "plugins": return "puzzlepiece.extension"
        case "agent-presets": return "person.crop.rectangle.stack"
        default: return "slider.horizontal.3"
        }
    }
}
