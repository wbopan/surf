import Foundation

/// 窗口的信息架构——**照抄 dsh Web 设置对话框**。
///
/// 上上一版把 12 个命名空间摊成 12 个导航项（把 host 的配置分区当界面用），
/// 上一版换成我自造的五个主题页（通用/模型/智能体/工具/高级）。两版都错，
/// 错在同一件事上：**dsh Web 已经有一套编排了，用户对着它形成了肌肉记忆**，
/// 原生窗口另立一套只会让"同一个设置在两个地方长得不一样"。
///
/// 所以现在的靶子是 Web 那四栏：General / Models / Plugins / Agent presets。
/// 逐项对齐的结论：
///
/// | Web | 这里 | 说明 |
/// |---|---|---|
/// | General | `.general` | 五项，顺序与分隔线照搬 |
/// | Models | `.models` | 只列已配置的 provider，38 个目录藏在"添加"后面 |
/// | Plugins | `.plugins` | 手风琴卡片，每张一个 ns |
/// | Agent presets | **缺席** | 预设画廊不由 `ctx.settings` 驱动，我们没有那条数据面 |
///
/// **窗框不照抄**：Web 是模态框 + 左侧列表，原生这边是 `.preference` 工具栏
/// （用户给的参考设计是 Mimestream / 系统偏好设置那一路）。编排一致 ≠ 外壳一致。
///
/// **两处有意的分歧**，都是先前定死的决定：
/// 1. Web 每张卡片是 Discard / Save，这里是即时生效（计划 D1，macOS 惯例）。
/// 2. Web 每个 ns 只露手工挑过的几个字段（`shell` 六个只露两个），这里精选的照露、
///    剩下的进「更多设置」折叠。**结构照抄，但不跟着丢字段**——计划 §2.2 的
///    零遗漏不变量比一致性优先级高：看不见的字段等于不存在。
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, models, plugins

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .models: return "模型"
        case .plugins: return "插件"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .models: return "cpu"
        case .plugins: return "puzzlepiece.extension"
        }
    }

    var width: CGFloat {
        switch self {
        case .general: return 620
        case .models: return 660
        case .plugins: return 660
        }
    }
}

enum SettingsTabs {

    /// 「通用」页的五行——**顺序、分组、文案都照 Web**。
    ///
    /// 这是一张 (ns, path) 的投影表而不是 ns 归属表：Web 的 General 页从五个不同的
    /// 命名空间里各挑一个字段拼出来，`agent-presets`/`permission`/`ui-conversation`
    /// 的其余字段（如果将来有）不跟着上来。
    struct GeneralRow {
        let ns: String
        let path: [String]
        /// 这一行前面是否要一条分隔线（照 Web 的分组）。
        let dividerBefore: Bool
    }

    static let generalRows: [GeneralRow] = [
        GeneralRow(ns: "agent-presets", path: ["default"], dividerBefore: false),
        GeneralRow(ns: "permission", path: ["defaultPreset"], dividerBefore: false),
        GeneralRow(ns: "locale", path: ["preference"], dividerBefore: true),
        GeneralRow(ns: "ui-theme", path: ["preference"], dividerBefore: false),
        GeneralRow(ns: "ui-conversation", path: ["busyEnter"], dividerBefore: true),
    ]

    /// 「插件」页的卡片顺序。Web 就这三张，其余 ns 按名字排在后面
    /// ——**排在后面而不是不出现**，见类注释里那条零遗漏。
    static let pluginCardOrder = ["shell", "agent-loop", "web-search-deepseek"]

    /// 「模型」页吃掉的 ns：provider 各自那段 + 默认模型。
    static let defaultModelNs = "agent-default-model"

    /// 「插件」页要显示的 ns：既不属于模型页、也没被通用页整段用掉的那些。
    ///
    /// 注意判据是**整段**：`ui-theme` 只有一个字段且被通用页用了，所以不必再出现；
    /// 而如果某个 ns 通用页只用了它的一个字段、它还有别的字段，那它仍旧要在这儿露面。
    static func pluginNamespaces(_ namespaces: [NamespaceSnapshot],
                                 providers: [ProviderRow]) -> [NamespaceSnapshot] {
        let modelNs = Set(providers.filter { $0.settingsPath.isEmpty }.map(\.settingsNs))
            .union([defaultModelNs])
        return namespaces
            .filter { snapshot in
                if modelNs.contains(snapshot.ns) { return false }
                return !fullyConsumedByGeneral(snapshot)
            }
            .sorted { rank($0.ns) < rank($1.ns) }
    }

    private static func fullyConsumedByGeneral(_ snapshot: NamespaceSnapshot) -> Bool {
        let used = Set(generalRows.filter { $0.ns == snapshot.ns }.map { $0.path.joined(separator: "/") })
        guard !used.isEmpty else { return false }
        guard case .object(let fields, _) = snapshot.schema else { return false }
        return fields.allSatisfy { used.contains($0.key) }
    }

    private static func rank(_ ns: String) -> Int {
        pluginCardOrder.firstIndex(of: ns) ?? pluginCardOrder.count
    }

    /// 模型页详情里那段"自定义设置"要渲染哪个 ns。
    static func providerNamespace(_ row: ProviderRow,
                                  in namespaces: [NamespaceSnapshot]) -> NamespaceSnapshot? {
        namespaces.first { $0.ns == row.settingsNs }
    }
}
