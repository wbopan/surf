import AppKit
import SurfLayout
import SurfSDK
import SwiftUI

// 原生侧边栏。骨架仍然交给系统：`List(selection:)` + `.listStyle(.sidebar)` 给的是
// 原生 hover、键盘上下键导航、分组缩进；surf-layout 把本视图装进
// `NSSplitViewItem(sidebarWithViewController:)`，材质、分隔条、拖拽调宽、收起动画、
// 宽度记忆全部白送。自绘的只有三样：新建行、会话行、分区头。
//
// **顶部两段 + 列表 + 底栏**：
//
// - 「新建会话」常驻在最上面（`newSessionRow`），落在当前选中会话所属的工作区；
// - 搜索是系统 `NSSearchField`（`SidebarSearchField`），不自绘；
// - 列表按工作区分组、按时间分段、或按状态分段（组织轴 `SidebarFilterState.Mode`，
//   在工具栏那枚「筛选」菜单里切）。**状态只在「按状态」那一档分段**
//   （待处理 / 进行中 / 已结束）——另外两档一条会话都不往外提，
//   按工作区看时项目里的会话是齐的，按时间看时今天的会话都在「今天」里；
// - 工具栏那枚「筛选」（分组方式 + 工作区显隐 + 显示已归档 + 清除筛选）在
//   `SidebarPlugin` 里，是个 `NSMenuToolbarItem`，与这里共读一份 `SidebarFilterState`；
// - 底栏「添加工作区」（`folder.badge.plus`），不画分隔线。
//
// **会话行是单行且定高 32pt**（官方 `Sidebars/*/Medium/Items/Level 0`）：摘要整块
// 拿掉了，标题就是全部。行尾**恒是相对时间**（今天给时刻、7 天内给周几、更早给
// 短日期），状态与归档挤在 leading 那 20pt 的槽里——两边各就各位，不互相顶。
//
// **行与行之间不画分隔线**：位置感来自分区头与选中块的圆角，线压在圆角上会把它
// 切平。列表**不留滚动条**：overlay scroller 在浅色下是半透明纯黑，压在行右缘上
// 是一道扎眼的深色竖条，而这儿的位置感本来就来自分区头。
//
// **右键菜单是操作全集，hover 图标是其中两个高频动作的快捷键**：
// 会话行 hover 出归档、分组头 hover 出加号（在此工作区新建会话）。
// 分组头右缘的 chevron 不算"操作"，是开合状态本身，同样 hover 才显形。

// MARK: - 自动化标识符
//
//   sidebar.newSession                 顶部常驻的「新建会话」
//   sidebar.search                     搜索框（NSSearchField 自己挂的）
//   sidebar.list                       会话列表
//   sidebar.group.<groupId>            分组头
//   sidebar.group.<groupId>.new        分组头的「新建会话」+（hover 才可见）
//   sidebar.group.<groupId>.toggle     分组头的开合 chevron（hover 才可见）
//   sidebar.session.<sessionId>        会话行
//   sidebar.session.<sessionId>.archive 会话行的归档按钮（hover 才可见）
//   sidebar.addWorkspace               底栏的「添加工作区」（folder.badge.plus）
//   sidebar.empty                      空态文案
//
// 右键菜单项按文案定位（AX 里是 NSMenuItem，挂不了 identifier）；
// 工具栏的「筛选」「边栏」是 NSToolbarItem / 系统标准项，按 Title 定位。
//
// **identifier 一个字都不随语言变**：文案全部走 `L`（Strings.swift），
// 上面这些 id 与「按时间」分段的 `TimeBuckets.Bucket` 一样是稳定英文串。

/// 会话行：leading 槽（状态 / 归档）+ 单行标题 + trailing 槽（时间 ⇄ hover 归档）。
/// 选中 / hover 高亮 / 键盘导航一律由 `List` + `.listStyle(.sidebar)` 提供。
///
/// **单行且定高 32pt**（官方 `Sidebars/*/Medium/Items/Level 0` 就是 240×32）：
/// 摘要整块拿掉了——用户在四个密度变体里挑的就是"没有摘要那版"，标题就是全部。
/// 行内**不画分隔线**：位置感来自分区头与选中块的圆角，线只会把它们切平。
struct SessionRow: View {
    let session: SidebarSession
    let strings: L
    let onRename: () -> Void
    let onFork: () -> Void
    let onArchive: () -> Void

    @State private var hovering = false

    /// 行高。官方 Level 0 item 的 32。
    static let height: CGFloat = 32
    /// 槽 → 标题的间隔。官方值（leading icon 20 + 4 = 标题起点 38）。
    static let slotGap: CGFloat = 4
    /// trailing 槽的**最小**宽度。官方同一 symbol 的 Trailing 是 36，设计稿写的也是
    /// `min-width: 36`——**不是定宽**：en 下的「3:09 PM」「Yesterday」比 36 宽，
    /// 钉死就成了「12:4…」这种谁也读不出来的省略号（实测过）。
    static let trailingSlot: CGFloat = 36

    var body: some View {
        HStack(alignment: .center, spacing: Self.slotGap) {
            leading
            // 官方是 Regular 13（两行版为压住摘要加的 Medium 这次不要）。
            Text(session.displayTitle)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .frame(height: Self.height)
        // 已归档整行退一层：它是「翻出来看看」的东西，不该和在役会话抢注意力。
        .opacity(session.archived ? 0.6 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityIdentifier("sidebar.session.\(session.id)")
        .contextMenu {
            Button(strings.renameEllipsis, action: onRename)
            Button(strings.forkSession, action: onFork)
            Divider()
            Button(strings.archiveSession, action: onArchive)
        }
    }

    /// leading 槽：**归档顶掉状态位**——归档本来就是一种终态，两者不会同时成立，
    /// 而 trailing 那格已经归了时间。槽宽恒定，标题左缘因此永远在 38。
    @ViewBuilder
    private var leading: some View {
        if session.archived {
            Image(systemName: "archivebox.fill")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: StatusIndicator.slot, height: StatusIndicator.slot)
                .help(strings.archivedBadge)
                .accessibilityLabel(Text(strings.archivedBadge))
        } else {
            StatusIndicator(status: session.status, strings: strings)
        }
    }

    /// trailing 槽：**恒是相对时间**，hover 时归档按钮**原地**淡入把它换掉
    /// （不是挤开谁）——照分区头「数字 ⇄ chevron」那套写法，左右横跳比多一格更让人分神。
    private var trailing: some View {
        ZStack(alignment: .trailing) {
            Text(SessionTimestamp.text(for: session.updatedAt, locale: strings.locale))
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                // 时间从不省略：宁可标题少几个字，也不要一列读不出来的「12:4…」。
                .fixedSize()
                // 归档行没有 hover 按钮来换它，所以只在"真会被换掉"时才淡出。
                .opacity(hovering && archivable ? 0 : 1)
                // 时间是修饰不是内容：读屏器念完标题接一句"14:36"是噪音，
                // 真要知道就去看行的上下文。
                .accessibilityHidden(true)
            if archivable {
                // 点击即归档、无确认——归档非破坏性，日志留着，只是从列表消失
                //（打开「显示已归档」还能看见）。
                Button(action: onArchive) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: Self.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(strings.archiveSession)
                .accessibilityLabel(Text(strings.archiveSession))
                .accessibilityIdentifier("sidebar.session.\(session.id).archive")
                .opacity(hovering ? 1 : 0)
                // 看不见的时候也别可点：透明按钮照样吃点击，是个隐形雷。
                .allowsHitTesting(hovering)
            }
        }
        .frame(minWidth: Self.trailingSlot, alignment: .trailing)
    }

    /// 这一行有没有归档按钮。blank（还没输入的空会话）与已归档的都没有。
    private var archivable: Bool { !session.blank && !session.archived }
}

/// 分区头的规格。**三处共用**（工作区 / 时间分段 / 状态分段）——
/// 从前一个是 11 semibold secondary、一个是 13 medium primary，同一张列表上
/// 两种分区头长得不一样，看着像两个控件。
///
/// 数值出处是官方 `Sidebars/*/Medium/Header`：高 18、SFPro-Bold 11、
/// 浅色 `rgb(178,178,178)`。**深色不照抄**：官方那档 `rgb(76,76,76)` 是
/// vibrancy 混合后的量测值，直出到我们的材质上太暗，按设计稿提亮到 40% 白。
enum SectionHeaderStyle {
    /// 分区头自己的高度。
    ///
    /// **分区间距不在这儿**：sidebar List 自带的分区留白实测就是 14pt
    /// （截图逐像素量：上一行底缘 → 分区头顶缘 ≈ 13.8），正好是设计稿要的值，
    /// 所以这里一个 `.padding(.top)` 都不加——加了会叠成 27。
    static let height: CGFloat = 18
    static let font: Font = .system(size: 11, weight: .bold)
    /// 计数：同样 11，但不加粗、再退一层颜色。
    static let countFont: Font = .system(size: 11)

    static let color = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.40)
            : NSColor(white: 178.0 / 255.0, alpha: 1)
    })
}

/// 只有标题（+ 可选计数）的分区头：时间分段与状态分段用它。
/// 工作区分组头多了 hover 动作，另见 `GroupHeader`。
struct PlainSectionHeader: View {
    let title: String
    let count: Int?

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(SectionHeaderStyle.font)
                .foregroundStyle(SectionHeaderStyle.color)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let count {
                Text("\(count)")
                    .font(SectionHeaderStyle.countFont)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(height: SectionHeaderStyle.height)
    }
}

/// Workspace 分组头：标题 + 会话计数
/// + hover 显示的加号（在此工作区新建会话）
/// + 右缘 chevron（唯一的开合开关，展开时旋转 90°）。
///
/// **没有文件夹图标**：分区头是标签不是行，图标让它看着像可点的一行；
/// 而且它把标题推到 38，与下面会话行的标题排成同一条竖线——那正是
/// "这是这些行的容器"这层意思丢掉的地方。
struct GroupHeader: View {
    let group: SidebarGroup
    let strings: L
    let count: Int
    let expanded: Bool
    let onToggle: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let surface: SurfConversationSurface

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(group.title)
                    .font(SectionHeaderStyle.font)
                    .foregroundStyle(SectionHeaderStyle.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .help(group.title)
            // .ignore 显式收口：不加的话 SwiftUI 会把容器与标题各算一个 AX 元素
            // 再合并，label 和 identifier 都被拼两遍。
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(group.title))
            .accessibilityIdentifier("sidebar.group.\(group.id)")
            // 右端两个槽位，静止时只有最右边那个是满的：
            //
            //   静止   [        ] [数字]
            //   hover  [   +    ] [ >  ]
            //
            // **chevron 顶掉的是数字的位置，不是另开一格。** 三个槽各占各的
            // （那一版是"空 / 数字 / 空"→"+ / 空 / >"）看着像有个洞在左右横跳。
            // 显隐一律用 .opacity 而不是条件插入：槽位恒定占地，标题不会跳。
            Button {
                surface.startSession(workspaceId: group.workspaceId)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(strings.newSessionInWorkspace)
            .accessibilityLabel(Text(strings.newSessionInWorkspace))
            .accessibilityIdentifier("sidebar.group.\(group.id).new")
            .fixedSize()
            .opacity(hovering ? 1 : 0)
            // 看不见的时候也别可点：透明按钮照样吃点击，是个隐形雷。
            .allowsHitTesting(hovering)

            // 居中而不是右对齐：数字和 chevron 的光学中心因此重合，
            // hover 时是"原地换了个字形"，不是"数字滑走、箭头补位"。
            ZStack {
                // 静止时的常驻信息：这一组有多少条。
                Text("\(count)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 0 : 1)
                Button(action: onToggle) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 20, alignment: .center)
                        .contentShape(Rectangle())
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .animation(.easeInOut(duration: 0.15), value: expanded)
                }
                .buttonStyle(.plain)
                .help(expanded ? strings.collapseGroup : strings.expandGroup)
                .accessibilityLabel(Text(expanded ? strings.collapseGroup : strings.expandGroup))
                .accessibilityIdentifier("sidebar.group.\(group.id).toggle")
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
            }
            .frame(width: 24, alignment: .trailing)
        }
        .frame(height: SectionHeaderStyle.height)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button(strings.newSession) { surface.startSession(workspaceId: group.workspaceId) }
            // 兜底组（未分组）不是真工作区，没有可改可删的账。
            if group.workspaceId != nil {
                Divider()
                Button(strings.renameEllipsis, action: onRename)
                Button(strings.deleteWorkspaceEllipsis, action: onDelete)
            }
        }
    }
}

/// 主视图：搜索 + 列表（按工作区分组、按时间分段、或按状态分段）。
struct SidebarView<Model: SidebarModel>: View {
    @ObservedObject var model: Model
    @ObservedObject var filter: SidebarFilterState
    let surface: SurfConversationSurface
    /// 当前界面语言（`@Observable`，插件与 model 共用同一个实例）。
    /// body 里读一下 `current` 就建立了观察依赖——切语言时整棵视图自动重渲，
    /// **不需要 `withObservationTracking`**（那条路有静默死亡坑，CLAUDE.md）。
    let locale: SurfLocaleStore

    /// 收起的分组（默认全部展开；搜索时强制展开命中组）。
    /// 逗号拼接持久化（组 id 无逗号）。
    @AppStorage("sidebar.collapsedGroups") private var collapsedGroupsCSV = ""

    /// 重命名对话框的目标；会话与工作区共用同一个 alert。
    /// 顶部「新建会话」那条的 hover 态。
    @State private var hoveringNew = false

    @State private var renameTarget: RenameTarget?
    @State private var renameText = ""
    @State private var deleteTarget: DeleteTarget?

    private enum RenameTarget {
        case session(id: String, title: String)
        case workspace(id: String, title: String)

        var currentTitle: String {
            switch self {
            case .session(_, let title), .workspace(_, let title): return title
            }
        }

        func dialogTitle(_ strings: L) -> String {
            switch self {
            case .session: return strings.renameSessionTitle
            case .workspace: return strings.renameWorkspaceTitle
            }
        }

        func fieldLabel(_ strings: L) -> String {
            switch self {
            case .session: return strings.sessionNameField
            case .workspace: return strings.workspaceNameField
            }
        }
    }

    private struct DeleteTarget: Identifiable {
        let id: String
        let title: String
    }

    /// 「按时间」视图的一段。**身份是 `bucket`（稳定英文 id），不是段标题**
    /// ——标题随语言变，拿它当 id 的话切一次语言整个列表就换了身份。
    private struct TimeSection: Identifiable {
        let bucket: TimeBuckets.Bucket
        var id: String { bucket.rawValue }
        /// 段内的会话，按 updatedAt 倒序。**不再带所属工作区**——单行 32pt
        /// 的行里没有副行可写，工作区名只在「按工作区」视图的分区头上出现。
        let rows: [SidebarSession]
    }

    /// 「按状态」视图的一段。同样以稳定英文 id（`StatusBuckets.Bucket`）为身份。
    private struct StatusSection: Identifiable {
        let bucket: StatusBuckets.Bucket
        var id: String { bucket.rawValue }
        let rows: [SidebarSession]
    }

    init(model: Model, filter: SidebarFilterState, surface: SurfConversationSurface,
         locale: SurfLocaleStore) {
        self.model = model
        self.filter = filter
        self.surface = surface
        self.locale = locale
    }

    // MARK: - 数据裁剪

    private var collapsedGroups: Set<String> {
        Set(collapsedGroupsCSV.split(separator: ",").map(String.init))
    }

    private var searching: Bool {
        !filter.query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func isExpanded(_ groupId: String) -> Bool {
        searching || !collapsedGroups.contains(groupId)
    }

    private func toggleGroup(_ groupId: String) {
        withAnimation(.easeInOut(duration: 0.15)) {
            var set = collapsedGroups
            if set.contains(groupId) { set.remove(groupId) } else { set.insert(groupId) }
            collapsedGroupsCSV = set.sorted().joined(separator: ",")
        }
    }

    /// 筛选规则的实现在 `SidebarFilterState`（SidebarFilter.swift）——快捷键导航
    /// 也要按同一份规则数数，这里只留薄委托，调用点不动。
    private func passes(_ session: SidebarSession) -> Bool {
        filter.passes(session)
    }

    private var filteredGroups: [SidebarGroup] {
        filter.filteredGroups(from: model.groups)
    }

    /// 「按时间」视图：把所有过筛的会话摊平、按 updatedAt 倒序、分四段。
    private var timeSections: [TimeSection] {
        var buckets: [TimeBuckets.Bucket: [SidebarSession]] = [:]
        for session in filter.visibleSessions(from: model.groups) {
            buckets[TimeBuckets.of(session.updatedAt), default: []].append(session)
        }
        return TimeBuckets.order.compactMap { bucket in
            guard let rows = buckets[bucket] else { return nil }
            return TimeSection(bucket: bucket,
                               rows: rows.sorted { $0.updatedAt > $1.updatedAt })
        }
    }

    /// 「按状态」视图的三段。分段规则在 `SidebarFilterState`——快捷键导航
    /// 读的是同一份，这里只把它装进 `Identifiable` 的壳里给 `ForEach` 用。
    private var statusSections: [StatusSection] {
        filter.statusSections(from: model.groups)
            .map { StatusSection(bucket: $0.bucket, rows: $0.rows) }
    }

    private var isEmpty: Bool {
        switch filter.mode {
        case .workspace: return filteredGroups.isEmpty
        case .time: return timeSections.isEmpty
        case .status: return statusSections.isEmpty
        }
    }

    /// List 双向选择绑定：读真源；写（用户点选）走 activate。
    private var selection: Binding<String?> {
        Binding(
            get: { model.selectedSessionId },
            set: { if let id = $0 { model.activate(sessionId: id) } }
        )
    }

    // MARK: - 布局

    /// 当前语言下的文案。读它 = 读 `locale.current` = 建立观察依赖。
    private var strings: L { L(locale.current) }

    var body: some View {
        VStack(spacing: 0) {
            newSessionRow
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 6)
            // 36pt 的原生胶囊（开关在 SidebarSearchField 里，是 controlSize 而不是 frame）。
            SidebarSearchField(text: $filter.query, placeholder: strings.searchPlaceholder)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            if isEmpty {
                emptyState
            } else {
                switch filter.mode {
                case .workspace: workspaceList
                case .time: timeList
                case .status: statusList
                }
            }
            addWorkspaceBar
        }
        .alert(renameTarget?.dialogTitle(strings) ?? "", isPresented: renamePresented) {
            TextField(renameTarget?.fieldLabel(strings) ?? "", text: $renameText)
            Button(strings.cancel, role: .cancel) { renameTarget = nil }
            Button(strings.rename) { commitRename() }
        }
        .alert(strings.deleteWorkspaceTitle, isPresented: deletePresented, presenting: deleteTarget) { target in
            Button(strings.cancel, role: .cancel) { deleteTarget = nil }
            Button(strings.delete, role: .destructive) {
                model.deleteWorkspace(id: target.id)
                deleteTarget = nil
            }
        } message: { target in
            Text(strings.deleteWorkspaceMessage(target.title))
        }
        .alert(strings.actionFailedTitle, isPresented: errorPresented, presenting: model.actionError) { _ in
            Button(strings.ok, role: .cancel) { model.actionError = nil }
        } message: { reason in
            Text(reason)
        }
    }

    /// 搜索框上方那条常驻的「新建会话」。
    ///
    /// **它属于头部区，不进 `List`**：进了列表就得是一行 Section，会跟着滚走，
    /// 而这是整个侧边栏最该恒在原地的一个动作。与列表之间留 10pt。
    ///
    /// **高度跟搜索框走（36），不跟会话行走（32）**：它和搜索框是上下紧邻的
    /// 两件头部控件，高度对不齐会看出一节台阶；而它离最近的会话行还隔着分区头。
    /// 其余几何仍与会话行同一套（圆角 8、内容从 14 起、槽 20 + 间隔 4），
    /// 图标与文字也不跟着放大——于是它读起来像"列表最上面那一行"，而不是又一枚按钮。
    ///
    /// **不画常驻底**：搜索框那圈液态玻璃胶囊是"这里可以输入"的承诺，
    /// 这一行不是输入框，静止时就是一行字，hover 才浮出 6% 的底。
    ///
    /// 分区头 hover 出的加号**保留**：那条是"明确指定这个项目"，这条是
    /// "落在我此刻待着的地方"，两件事。
    private var newSessionRow: some View {
        Button {
            surface.startSession(workspaceId: currentWorkspaceId)
        } label: {
            HStack(spacing: SessionRow.slotGap) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 14))
                    .frame(width: StatusIndicator.slot, height: StatusIndicator.slot)
                Text(strings.newSession)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .frame(height: 36)
            // 不用强调色：它是常驻的一行，天天在那儿，蓝色会一直跳着抢注意力。
            // 字重 medium 已经把它和 13 regular 的会话标题分开了。
            .foregroundStyle(.primary)
            // hover 才有底：静止时它是一行字，不是一颗按钮——但按下去之前
            // 总得让人看见"这块地是可点的"。圆角与会话行的选中块同为 8。
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(hoveringNew ? 0.06 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hoveringNew = $0 }
        .help(strings.newSession)
        .accessibilityLabel(Text(strings.newSession))
        .accessibilityIdentifier("sidebar.newSession")
    }

    /// 新建会话落在哪个工作区：**当前选中会话所属的那一组**。没有选中（或那条
    /// 会话不在任何组里）就传 `nil` = 兜底组。规则是"落在你此刻待着的地方"，
    /// 不弹菜单问——要明确指定项目的话，分区头上那枚加号才是干这个的。
    private var currentWorkspaceId: String? {
        guard let id = model.selectedSessionId else { return nil }
        return model.groups.first { group in
            group.sessions.contains { $0.id == id }
        }?.workspaceId
    }

    private var workspaceList: some View {
        List(selection: selection) {
                ForEach(filteredGroups) { group in
                    Section {
                        if isExpanded(group.id) {
                            ForEach(group.sessions) { session in
                                row(session).tag(session.id)
                            }
                        }
                    } header: {
                        GroupHeader(group: group,
                                    strings: strings,
                                    count: group.sessions.count,
                                    expanded: isExpanded(group.id),
                                    onToggle: { toggleGroup(group.id) },
                                    onRename: {
                                        guard let id = group.workspaceId else { return }
                                        beginRename(.workspace(id: id, title: group.title))
                                    },
                                    onDelete: {
                                        guard let id = group.workspaceId else { return }
                                        deleteTarget = DeleteTarget(id: id, title: group.title)
                                    },
                                    surface: surface)
                }
            }
        }
        .listStyle(.sidebar)
        // 侧边栏不留滚动条。macOS 的 overlay scroller 在浅色下是半透明纯黑，
        // 压在会话行右缘上是一道很扎眼的深色竖条——而这里本来就不需要它指位置：
        // 一屏十来行、有搜索有筛选，位置感来自分组头。
        .scrollIndicators(.never)
        .accessibilityIdentifier("sidebar.list")
    }

    private var timeList: some View {
        List(selection: selection) {
            ForEach(timeSections) { section in
                Section {
                    ForEach(section.rows) { session in
                        row(session).tag(session.id)
                    }
                } header: {
                    PlainSectionHeader(title: strings.timeBucket(section.bucket),
                                       count: section.rows.count)
                }
            }
        }
        .listStyle(.sidebar)
        // 侧边栏不留滚动条。macOS 的 overlay scroller 在浅色下是半透明纯黑，
        // 压在会话行右缘上是一道很扎眼的深色竖条——而这里本来就不需要它指位置：
        // 一屏十来行、有搜索有筛选，位置感来自分组头。
        .scrollIndicators(.never)
        .accessibilityIdentifier("sidebar.list")
    }

    /// 「按状态」视图：待处理 / 进行中 / 已结束，段内按最后活动倒序。
    /// **只有这一档看得见状态分段**——分区头与「按时间」同一款（`PlainSectionHeader`），
    /// 一张列表上不该有两种长相的分区头。
    private var statusList: some View {
        List(selection: selection) {
            ForEach(statusSections) { section in
                Section {
                    ForEach(section.rows) { session in
                        row(session).tag(session.id)
                    }
                } header: {
                    PlainSectionHeader(title: strings.statusBucket(section.bucket),
                                       count: section.rows.count)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollIndicators(.never)
        .accessibilityIdentifier("sidebar.list")
    }

    private func row(_ session: SidebarSession) -> some View {
        SessionRow(
            session: session,
            strings: strings,
            onRename: { beginRename(.session(id: session.id, title: session.displayTitle)) },
            onFork: { model.forkSession(id: session.id) },
            onArchive: { model.archive(sessionId: session.id) }
        )
        // **行高与左右边距的唯一开关**。实测（截图逐像素量）sidebar List 自带
        // 上下各 4pt 的行内边距、左右各 16pt 的内容内边距，于是 `.frame(height: 32)`
        // 的行占 40pt、标题左缘落在 40。官方 `Sidebars/*/Medium/Items/Level 0`
        // 是 240×32、标题起点 38（= 14 + 槽 20 + 4），差的就是这一圈。
        //
        // **`listRowInsets` 在这里是叠加的，不是替换**：给 leading 14 量出来是 30
        // （16 + 14），所以要的是 **-2**——把内容从"选中块内缩 6"挪到设计稿的
        // "内缩 4"。上下给 0 就正好是 32。
        // **这不是自绘选中块**：`listRowInsets` 只说内容画在哪，高亮仍由 List 画。
        .listRowInsets(EdgeInsets(top: 0, leading: -2, bottom: 0, trailing: -2))
        // **选中高亮一律交给 List 自己画，别加 `.listRowBackground`。**
        // 自己再画一层就是两层背景：List 那层（内缩 10pt）套在自绘那层里面，
        // 半透明材质一用立刻露成一个"回"字（早先没露馅只因为填的是不透明纯色）。
        // 系统那层还白送焦点态（有键盘焦点时 accent、失焦转灰）与浅深色适配。
    }

    /// 空态。**说清是"筛出来空"还是"本来就空"**——不然用户会以为会话丢了。
    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text(emptyText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            if filter.isNarrowed || searching {
                Button(strings.clearFilters) {
                    filter.query = ""
                    filter.mode = .workspace
                    filter.hiddenGroups = []
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("sidebar.empty")
    }

    private var emptyText: String {
        if searching { return strings.noSearchResults(filter.query) }
        return filter.isNarrowed ? strings.noSessionsInFilter : strings.noSessions
    }

    // MARK: - 对话框

    private var renamePresented: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })
    }

    private func beginRename(_ target: RenameTarget) {
        renameText = target.currentTitle
        renameTarget = target
    }

    /// 空标题 = 取消（host 侧也会拒），标题没变则连请求都不发。
    private func commitRename() {
        guard let target = renameTarget else { return }
        renameTarget = nil
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != target.currentTitle else { return }
        switch target {
        case .session(let id, _): model.renameSession(id: id, title: title)
        case .workspace(let id, _): model.renameWorkspace(id: id, title: title)
        }
    }

    // MARK: - 底栏

    /// 左下角的「添加工作区」。
    ///
    /// 原本它是「工作区」那条区段头右端的一个小加号。整条区段头删掉了——
    /// 分组头自己已经带着文件夹图标，上面再顶一行"工作区"是同义反复，
    /// 白占一行还把列表往下推。加号搬到左下角：**这是侧边栏级别的动作**
    /// （给整个侧边栏加一个工作区），不属于任何一组，左下角正是原生 App
    /// 放这类动作的地方（Music、Photos 的 + 都在那儿）。
    private var addWorkspaceBar: some View {
        VStack(spacing: 0) {
            // 不画分隔线：侧边栏通篇没有线（行与行之间也没有），
            // 单给底栏来一条就成了整面唯一的一道横杠，比 ⊕ 本身还显眼。
            HStack(spacing: 0) {
                Button(action: addWorkspace) {
                    // **不是 `plus.circle`**：那颗圆加号在侧边栏语境里读成
                    // "新建会话"，而它干的是"把一个已存在的目录登记成工作区"。
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(strings.addWorkspace)
                .accessibilityLabel(Text(strings.addWorkspace))
                .accessibilityIdentifier("sidebar.addWorkspace")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
        }
    }

    /// 添加工作区 = 选一个已存在的目录交给 host 登记（`workspace.create`）。
    /// 原生直接用 NSOpenPanel，代价是**默认 app 与 dsh 同机**——当前架构本来就如此。
    private func addWorkspace() {
        let model = self.model
        let strings = self.strings
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = strings.choosePanelPrompt
        panel.message = strings.chooseWorkspaceFolder
        let adopt: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            model.createWorkspace(path: url.path)
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: adopt)
        } else {
            adopt(panel.runModal())
        }
    }

}

/// 「按时间」视图的分段。
///
/// 独立成 enum 而不是塞进 `SidebarView`：**泛型类型里放不了 static 存储属性**
/// （`SidebarView` 对 Model 泛型），swiftc 会直接拒编。
enum TimeBuckets {
    /// 分段的**身份**。rawValue 是稳定英文 id：段的 `Identifiable.id` 与
    /// 将来任何自动化定位都取它，显示名走 `L.timeBucket(_:)`——
    /// 「标识与文案解耦」是本仓库的纪律（CLAUDE.md），换语言后它成了正确性问题。
    enum Bucket: String, CaseIterable {
        case today
        case yesterday
        case lastSevenDays
        case earlier
    }

    /// 固定顺序。照遍历顺序攒会让「更早」插到「昨天」前面。
    static let order: [Bucket] = [.today, .yesterday, .lastSevenDays, .earlier]

    static func of(_ date: Date) -> Bucket {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return .today }
        if calendar.isDateInYesterday(date) { return .yesterday }
        let days = calendar.dateComponents([.day], from: date, to: Date()).day ?? 0
        return days <= 7 ? .lastSevenDays : .earlier
    }
}
