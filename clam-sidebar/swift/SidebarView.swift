import AppKit
import ClamLayout
import SwiftUI

// 原生侧边栏。骨架仍然交给系统：`List(selection:)` + `.listStyle(.sidebar)` 给的是
// 原生 hover、键盘上下键导航、分组缩进；clam-layout 把本视图装进
// `NSSplitViewItem(sidebarWithViewController:)`，材质、分隔条、拖拽调宽、收起动画、
// 宽度记忆全部白送。自绘的只有三样：会话行、分组头、筛选胶囊。
//
// **顶部三段**（搜索 / 胶囊 / 列表）：
//
// - 搜索是系统 `NSSearchField`（`SidebarSearchField`），不自绘；
// - 胶囊是列表的组织轴：全部 / 按时间 / 待处理。「按时间」把工作区整个换成日期分段，
//   「待处理」仍按工作区分组、只留需要人看一眼的行（待批准 / 待回答 / 出错 / 跑完了）；
// - 工具栏那枚「筛选」按钮（工作区显隐 + 显示已归档）在 `SidebarPlugin` 里，
//   是个 `NSMenuToolbarItem`，与这里共读一份 `SidebarFilterState`。
//
// **会话行是两行且定高 56pt**：副行（尾部消息摘要）用
// `lineLimit(2, reservesSpace: true)` 恒占两行的位置，摘要长短不一时列表不跳。
// 行内**不显示时间**——时间只作为「按时间」视图的分段头出现。
//
// **行与行之间一条细分隔线**（缩进到标题那条竖线上），每段最后一行不画、
// 紧挨选中行的那条也不画。列表**不留滚动条**：overlay scroller 在浅色下是半透明
// 纯黑，压在行右缘上是一道扎眼的深色竖条，而这儿的位置感本来就来自分组头。
//
// **右键菜单是操作全集，hover 图标是其中两个高频动作的快捷键**：
// 会话行 hover 出归档、分组头 hover 出加号（在此工作区新建会话）。
// 分组头右缘的 chevron 不算"操作"，是开合状态本身，同样 hover 才显形。

// MARK: - 自动化标识符
//
//   sidebar.search                     搜索框（NSSearchField 自己挂的）
//   sidebar.chips.<mode>               筛选胶囊（all / time / pending）
//   sidebar.list                       会话列表
//   sidebar.group.<groupId>            分组头
//   sidebar.group.<groupId>.new        分组头的「新建会话」+（hover 才可见）
//   sidebar.group.<groupId>.toggle     分组头的开合 chevron（hover 才可见）
//   sidebar.session.<sessionId>        会话行
//   sidebar.session.<sessionId>.archive 会话行的归档按钮（hover 才可见）
//   sidebar.addWorkspace               左下角的「添加工作区」圆圈加号
//   sidebar.empty                      空态文案
//
// 右键菜单项按文案定位（AX 里是 NSMenuItem，挂不了 identifier）；
// 工具栏的「筛选」「边栏」是 NSToolbarItem / 系统标准项，按 Title 定位。

/// 会话行：状态指示器 + 标题 + 两行摘要；选中/hover/键盘导航由 List 提供。
struct SessionRow: View {
    let session: SidebarSession
    /// 所属工作区。**只在「按时间」视图里给**——那边没有分组头兜着，
    /// 不写出来就看不出这条会话是哪个项目的。给了它，两行的副行拆成
    /// 「工作区 / 摘要」各一行；不给就是完整的两行摘要。
    let workspace: String?
    let onRename: () -> Void
    let onFork: () -> Void
    let onArchive: () -> Void
    /// 行间细分隔线画不画，由列表那边定（见 `dividerVisible`）：
    /// 每段最后一行不画，紧挨选中行的那条也不画。
    let showsDivider: Bool

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            StatusIndicator(status: session.status)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                // 副行**恒占两行**：不足留白、超出省略。行高因此是定值，
                // 摘要长短不一时列表不会上下跳——扫起来是一条稳定的节奏。
                // 别加 `.fixedSize(vertical:)`：它让 Text 按理想高度铺开，
                // lineLimit 当场失效，三行的摘要就把行撑高了（栽过一次）。
                if let workspace {
                    Text(workspace)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(session.preview)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text(session.preview)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2, reservesSpace: true)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 4)
            // 已归档：行尾一枚灰符号（不占状态槽——归档是修饰，不是状态）。
            // **竖直方向对整行居中**，不跟标题那一行对齐：它说的是"这条会话"，
            // 不是"这个标题"，贴着第一行看起来像标题的角标。
            if session.archived {
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxHeight: .infinity)
                    .help("已归档")
            }
            // hover 且非 blank 时行尾出归档；点击即归档、无确认——归档非破坏性，
            // 日志留着，只是从列表消失（打开「显示已归档」还能看见）。
            if !session.blank && !session.archived {
                Button(action: onArchive) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("归档会话")
                .accessibilityLabel(Text("归档会话"))
                .accessibilityIdentifier("sidebar.session.\(session.id).archive")
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
                .frame(maxHeight: .infinity)
            }
        }
        // 上下各 14pt。**这一条是这次改版里最值钱的一行**：原来是 3pt，
        // 三行内容挤成一坨，扫起来像一堵墙。参照 Messages / Mail 的侧边栏
        // ——它们把行高的一半花在留白上，代价是一屏少几行，换来的是能扫。
        .padding(.vertical, 14)
        // 行与行之间一条系统分隔线，左端缩进到与标题同一条竖线上——
        // 状态槽那 16pt 是留给"这条会话怎么样了"的，分隔线跨过去会把它切成两半。
        // **画在 padding 之外**：内缩的话线就浮在行里，不落在两行的交界上。
        .overlay(alignment: .bottom) {
            if showsDivider {
                Divider()
                    .padding(.leading, StatusIndicator.slot + 6)
            }
        }
        // 已归档整行退一层：它是「翻出来看看」的东西，不该和在役会话抢注意力。
        .opacity(session.archived ? 0.6 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityIdentifier("sidebar.session.\(session.id)")
        .contextMenu {
            Button("重命名…", action: onRename)
            Button("分叉会话", action: onFork)
            Divider()
            Button("归档会话", action: onArchive)
        }
    }
}

/// Workspace 分组头：文件夹图标 + 标题 + 会话计数
/// + hover 显示的加号（在此工作区新建会话）
/// + 右缘 chevron（唯一的开合开关，展开时旋转 90°）。
///
/// **图标不随选中变色**：选中态是会话行的事（List 自己画高亮），分组头
/// 跟着染 accent 只会让人以为分组本身被选中了。
struct GroupHeader: View {
    let group: SidebarGroup
    let count: Int
    let expanded: Bool
    let onToggle: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let surface: ClamConversationSurface

    @State private var hovering = false

    private var iconName: String { group.workspaceId == nil ? "tray" : "folder" }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: StatusIndicator.slot, alignment: .center)
                // sidebar List 给 Section header 默认涂 secondary，工作区名于是
                // 看着像被禁用。这里是用户维护的账（能改名能删），不是分类标签，
                // 显式扳回 primary 才与会话行同一个"可操作"的层级。
                Text(group.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .help(group.title)
            // .ignore 显式收口：不加的话 SwiftUI 会把图标/标题各算一个 AX 元素
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
            .help("在此工作区新建会话")
            .accessibilityLabel(Text("在此工作区新建会话"))
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
                .help(expanded ? "收起分组" : "展开分组")
                .accessibilityLabel(Text(expanded ? "收起分组" : "展开分组"))
                .accessibilityIdentifier("sidebar.group.\(group.id).toggle")
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
            }
            .frame(width: 24, alignment: .trailing)
        }
        // sidebar List 给 Section header 的右侧 inset 比普通行少 14pt（实测），
        // 补回来，chevron 槽位才落在会话行右缘的同一条竖线上。
        .padding(.trailing, 14)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("新建会话") { surface.startSession(workspaceId: group.workspaceId) }
            // 兜底组（未分组）不是真工作区，没有可改可删的账。
            if group.workspaceId != nil {
                Divider()
                Button("重命名…", action: onRename)
                Button("删除工作区…", action: onDelete)
            }
        }
    }
}

/// 主视图：搜索 + 筛选胶囊 + 列表（按工作区分组，或按时间分段）。
struct SidebarView<Model: SidebarModel>: View {
    @ObservedObject var model: Model
    @ObservedObject var filter: SidebarFilterState
    let surface: ClamConversationSurface

    /// 收起的分组（默认全部展开；搜索时强制展开命中组）。
    /// 逗号拼接持久化（组 id 无逗号）。
    @AppStorage("sidebar.collapsedGroups") private var collapsedGroupsCSV = ""

    /// 重命名对话框的目标；会话与工作区共用同一个 alert。
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

        var dialogTitle: String {
            switch self {
            case .session: return "重命名会话"
            case .workspace: return "重命名工作区"
            }
        }

        var fieldLabel: String {
            switch self {
            case .session: return "会话名称"
            case .workspace: return "工作区名称"
            }
        }
    }

    private struct DeleteTarget: Identifiable {
        let id: String
        let title: String
    }

    /// 「按时间」视图的一段。
    private struct TimeSection: Identifiable {
        let id: String
        let title: String
        /// (会话, 所属组标题)
        let rows: [(session: SidebarSession, workspace: String)]
    }

    init(model: Model, filter: SidebarFilterState, surface: ClamConversationSurface) {
        self.model = model
        self.filter = filter
        self.surface = surface
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
        var buckets: [String: [(session: SidebarSession, workspace: String)]] = [:]
        for group in model.groups where !filter.hiddenGroups.contains(groupKey(group)) {
            for session in group.sessions where passes(session) {
                buckets[TimeBuckets.of(session.updatedAt), default: []]
                    .append((session, group.title))
            }
        }
        return TimeBuckets.order.compactMap { key in
            guard let rows = buckets[key] else { return nil }
            return TimeSection(id: key, title: key,
                               rows: rows.sorted { $0.session.updatedAt > $1.session.updatedAt })
        }
    }

    private func groupKey(_ group: SidebarGroup) -> String {
        group.filterKey
    }

    private var isEmpty: Bool {
        filter.mode == .time ? timeSections.isEmpty : filteredGroups.isEmpty
    }

    /// List 双向选择绑定：读真源；写（用户点选）走 activate。
    private var selection: Binding<String?> {
        Binding(
            get: { model.selectedSessionId },
            set: { if let id = $0 { model.activate(sessionId: id) } }
        )
    }

    // MARK: - 布局

    var body: some View {
        VStack(spacing: 0) {
            // 36pt 的原生胶囊（开关在 SidebarSearchField 里，是 controlSize 而不是 frame）。
            SidebarSearchField(text: $filter.query)
                .padding(.horizontal, 10)
                .padding(.top, 12)
                .padding(.bottom, 14)
            chips
            if isEmpty {
                emptyState
            } else if filter.mode == .time {
                timeList
            } else {
                workspaceList
            }
            addWorkspaceBar
        }
        .alert(renameTarget?.dialogTitle ?? "", isPresented: renamePresented) {
            TextField(renameTarget?.fieldLabel ?? "", text: $renameText)
            Button("取消", role: .cancel) { renameTarget = nil }
            Button("重命名") { commitRename() }
        }
        .alert("删除工作区", isPresented: deletePresented, presenting: deleteTarget) { target in
            Button("取消", role: .cancel) { deleteTarget = nil }
            Button("删除", role: .destructive) {
                model.deleteWorkspace(id: target.id)
                deleteTarget = nil
            }
        } message: { target in
            Text("将把「\(target.title)」从工作区列表中移除。文件夹与会话记录会保留，"
                 + "其会话将显示在「未分组」下。")
        }
        .alert("操作失败", isPresented: errorPresented, presenting: model.actionError) { _ in
            Button("好", role: .cancel) { model.actionError = nil }
        } message: { reason in
            Text(reason)
        }
    }

    /// 筛选胶囊。**它是组织轴，不是又一处过滤器**——「按时间」换的是分组方式。
    private var chips: some View {
        HStack(spacing: 6) {
            ForEach(SidebarFilterState.Mode.allCases, id: \.self) { mode in
                chip(mode)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        // 「工作区」那条区段头删掉之后，胶囊底下直接就是第一个分组头，
        // 原来的 14 是留给区段头的，现在多出来了。
        .padding(.bottom, 6)
    }

    private func chip(_ mode: SidebarFilterState.Mode) -> some View {
        let on = filter.mode == mode
        let count = countFor(mode)
        return Button {
            filter.mode = mode
        } label: {
            HStack(spacing: 4) {
                Text(mode.title)
                    .font(.system(size: 11, weight: .medium))
                if let count {
                    Text("\(count)")
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .opacity(0.62)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 21)
            .background(
                Capsule().fill(on ? AnyShapeStyle(Color.accentColor)
                                  : AnyShapeStyle(Color.primary.opacity(0.06)))
            )
            .foregroundStyle(on ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar.chips.\(mode.rawValue)")
    }

    /// 胶囊上的计数。「按时间」不带——那儿的数字没有意义（就是全部）。
    private func countFor(_ mode: SidebarFilterState.Mode) -> Int? {
        switch mode {
        case .time:
            return nil
        case .all:
            return model.groups
                .filter { !filter.hiddenGroups.contains(groupKey($0)) }
                .reduce(0) { sum, group in
                    sum + group.sessions.filter { !$0.archived || filter.showArchived }.count
                }
        case .pending:
            return model.groups
                .filter { !filter.hiddenGroups.contains(groupKey($0)) }
                .reduce(0) { sum, group in
                    sum + group.sessions.filter {
                        $0.status.needsAttention && (!$0.archived || filter.showArchived)
                    }.count
                }
        }
    }

    private var workspaceList: some View {
        List(selection: selection) {
                ForEach(filteredGroups) { group in
                    Section {
                        if isExpanded(group.id) {
                            ForEach(Array(group.sessions.enumerated()), id: \.element.id) { index, session in
                                row(session,
                                    workspace: nil,
                                    showsDivider: dividerVisible(group.sessions, index))
                                    .tag(session.id)
                            }
                        }
                    } header: {
                        GroupHeader(group: group,
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
                            .padding(.vertical, 3)
                            .frame(minHeight: 26)
                            .padding(.top, 4)
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
                    ForEach(Array(section.rows.enumerated()), id: \.element.session.id) { index, entry in
                        row(entry.session,
                            workspace: entry.workspace,
                            showsDivider: dividerVisible(section.rows.map(\.session), index))
                            .tag(entry.session.id)
                    }
                } header: {
                    HStack(spacing: 0) {
                        Text(section.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text("\(section.rows.count)")
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.trailing, 14)
                    .padding(.top, 4)
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

    /// 分隔线画在**两条会话之间**，所以每段最后一行不画（往下是分组头的留白，
    /// 再补一条就成了双线）。**任一侧被选中时也不画**：选中高亮是一枚内缩的
    /// 圆角矩形，分隔线压在它的上下缘上会把圆角切平。
    private func dividerVisible(_ sessions: [SidebarSession], _ index: Int) -> Bool {
        guard index + 1 < sessions.count else { return false }
        let selected = model.selectedSessionId
        return sessions[index].id != selected && sessions[index + 1].id != selected
    }

    private func row(_ session: SidebarSession,
                     workspace: String?,
                     showsDivider: Bool) -> some View {
        SessionRow(
            session: session,
            workspace: workspace,
            onRename: { beginRename(.session(id: session.id, title: session.displayTitle)) },
            onFork: { model.forkSession(id: session.id) },
            onArchive: { model.archive(sessionId: session.id) },
            showsDivider: showsDivider
        )
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
                Button("清除筛选") {
                    filter.query = ""
                    filter.mode = .all
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
        if searching { return "没有匹配「\(filter.query)」的会话" }
        switch filter.mode {
        case .pending: return "没有待处理的会话"
        default:
            return filter.isNarrowed ? "当前筛选下没有会话" : "还没有会话"
        }
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
        HStack(spacing: 0) {
            Button(action: addWorkspace) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("添加工作区")
            .accessibilityLabel(Text("添加工作区"))
            .accessibilityIdentifier("sidebar.addWorkspace")
            Spacer(minLength: 0)
        }
        .padding(.leading, 10)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
    }

    /// 添加工作区 = 选一个已存在的目录交给 host 登记（`workspace.create`）。
    /// 原生直接用 NSOpenPanel，代价是**默认 app 与 dsh 同机**——当前架构本来就如此。
    private func addWorkspace() {
        let model = self.model
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "添加"
        panel.message = "选择要作为工作区的文件夹"
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
    /// 固定顺序。照遍历顺序攒会让「更早」插到「昨天」前面。
    static let order = ["今天", "昨天", "前 7 天", "更早"]

    static func of(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        let days = calendar.dateComponents([.day], from: date, to: Date()).day ?? 0
        return days <= 7 ? "前 7 天" : "更早"
    }
}
