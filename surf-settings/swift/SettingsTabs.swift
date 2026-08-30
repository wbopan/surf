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
/// | Agent presets | `.presets` | 预设画廊，数据来自 `ctx.agentPresets` |
///
/// （「智能体预设」一开始被我跳过了，理由是"不由 `ctx.settings` 驱动"——那句话对，
/// 但结论错：它由 `ctx.agentPresets` 驱动，而那也是个 host 服务，我们本来就够得着。
/// **没查就下结论，白丢了一整栏。**）
///
/// **窗框不照抄**：Web 是模态框 + 左侧列表，原生这边是 `.preference` 工具栏
/// （用户给的参考设计是 Mimestream / 系统偏好设置那一路）。编排一致 ≠ 外壳一致。
///
/// **两处有意的分歧**，都是先前定死的决定：
/// 1. Web 每张卡片是 Discard / Save，这里是即时生效（计划 D1，macOS 惯例）。
/// 2. Web 每个 ns 只露手工挑过的几个字段（`shell` 六个只露两个），这里精选的照露、
///    剩下的进「更多设置」折叠。**结构照抄，但不跟着丢字段**——计划 §2.2 的
///    零遗漏不变量比一致性优先级高：看不见的字段等于不存在。
/// **第五栏「连接」不来自 Web**：dsh 的设置对话框里没有这一栏，它管的是"壳去连谁"
/// ——那是壳自己的偏好，dsh 根本不知道有这回事（`docs/archive/surf-connection-plan.md` §11.2）。
/// 编排照抄的纪律管的是"同一个设置别在两个地方长得不一样"，不是"不许有我们自己的设置"。
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, models, plugins, presets, connection

    var id: String { rawValue }

    // 四栏的**名字在 `L.tabTitle(_:)`**（跟着界面语言走），不在这儿。
    // 留在这儿的 `rawValue` 是稳定标识：`NSTabViewItem.identifier` 与
    // `settings.page.<id>` 那些 accessibilityIdentifier 都取它，一个字不随语言变。

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .models: return "cpu"
        case .plugins: return "puzzlepiece.extension"
        case .presets: return "wand.and.stars"
        case .connection: return "network"
        }
    }

    /// **窗口宽度是常量，四页共用。**
    ///
    /// 让每页各报各的宽度看着挺合理，实际效果是切一次标签窗口就横着抽一下
    /// ——macOS 上没有任何一个偏好设置窗口这么干：高度跟着内容变，宽度钉死在
    /// **最宽那页需要的宽度**上。所以取插件页那 720，其余三页在里面排。
    static let windowWidth: CGFloat = 720

    /// 内容区左右各留 26。
    static let contentWidth: CGFloat = windowWidth - 52


    /// 定高的页返回高度，自适应的页返回 nil。
    ///
    /// **判据是"这一页里有没有自己会滚的原生控件"**：`List` 和 `Table` 都要一个
    /// 确定的高度才知道自己能显示几行，而 `SelfSizingScroll` 干的正是相反的事
    /// ——量内容有多高。两个凑一块儿是死循环：列表想问外面多高，外面在问列表多高，
    /// 实测结果是列表塌成一行或者把窗口顶出屏幕。
    ///
    /// 所以主从与表格的三页定高、页内自己滚；只有纯 `Form` 的「通用」页继续跟着
    /// 内容长（那是 `.preference` 窗口本该有的样子，参考设计里 General 就比
    /// Accounts 矮一截）。
    ///
    /// 「插件」取两个子栏里较高的那个：子栏一切换窗口就重新动画一次高度，很晃眼。
    var height: CGFloat? {
        switch self {
        case .general: return nil
        case .models: return 430
        case .plugins: return 520   // 含 TabView 面板的边框与 tab 条
        case .presets: return 360
        // 纯 `Form`，没有会自己滚的控件——跟着内容长（同「通用」）。
        case .connection: return nil
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
        // **一页最多两条线。** 这里只剩一条（语言之前），另一条留给页尾的
        // 「配置文件」——那一条分的是"设置项"与"逃生舱"，比把 Enter 单独划一组要紧。
        // 线多了就不是分组，是把一页切成碎片。
        GeneralRow(ns: "ui-conversation", path: ["busyEnter"], dividerBefore: false),
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
            // **必须是全序**：只按 rank 排的话，表里没有的 ns 彼此 rank 相等，
            // 而 Swift 的 sort 不保证稳定——同一份数据两次渲染能排出不同顺序。
            // 实测后果是卡片会换位，而"默认展开第一张"跟着乱跳。
            .sorted { a, b in
                let (ra, rb) = (rank(a.ns), rank(b.ns))
                return ra == rb ? a.ns < b.ns : ra < rb
            }
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
