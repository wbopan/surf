import AppKit
import DashLayout
import SwiftUI

// 原生侧边栏（阶段二·Mail 风格）：交给系统。
// List(selection:) + .listStyle(.sidebar) 提供原生选中/hover/键盘导航；
// 分组头自绘（文件夹恒定实心，点击 chevron 开合，展开时旋转），
// dash-layout 把本视图装进 NSSplitViewItem(sidebarWithViewController:)，
// 材质、分隔条、拖拽调宽、收起动画、宽度记忆全部由系统处理。
// 顶部操作按钮（收起侧边栏 / 新建会话）在 dash-layout 的 NSToolbar，不在本视图。
//
// **右键菜单是操作全集，hover 图标是其中两个高频动作的快捷键**：
// 会话行 hover 出归档、分组头 hover 出加号（在此工作区新建会话）。
// 二者都只在 hover 时显形，不占常驻像素，列表静止时仍然干净；
// 重命名/分叉/删除工作区这类低频动作只在右键里。
// 分组头右缘的 chevron 不算"操作"，是开合状态本身，同样 hover 才显形。
// 列表级别的新增（添加工作区）落在列表区段头「工作区」那一行的右端——
// 与 web 的 sectionHeader 同位，新增什么就贴着什么的表头。

/// 相对时间已按需求移除（session 行不再显示时间戳）。

// MARK: - 自动化标识符
//
// 本视图给关键元素挂了 `.accessibilityIdentifier`，供 tools/shot.sh 之外的
// GUI 自动化（peekaboo 等走 Accessibility API 的工具）按稳定 ID 定位，
// 而不是靠中文文案模糊匹配——文案一改匹配就断。命名规范：
//
//   sidebar.search                     搜索框
//   sidebar.search.clear               搜索清除按钮
//   sidebar.list                       会话列表
//   sidebar.group.<groupId>            分组头
//   sidebar.group.<groupId>.new        分组头的「新建会话」+（hover 才可见）
//   sidebar.group.<groupId>.toggle     分组头的开合 chevron（hover 才可见）
//   sidebar.session.<sessionId>        会话行
//   sidebar.session.<sessionId>.archive 会话行的归档按钮（hover 才可见）
//   sidebar.section.workspaces         区段头「工作区」标题
//   sidebar.addWorkspace               区段头右端的「添加工作区」+ 号
//
// 右键菜单项按文案定位（AX 里是 NSMenuItem，挂不了 identifier）；
// 顶部工具栏的「新建会话」「边栏」是 NSToolbarItem / 系统标准项，按 Title 定位。

/// 会话状态点（running/pending…/idle 的唯一自绘元素，其余交给系统）。
/// running 用系统 ProgressView（macOS 原生小菊花），其余仍是彩色圆点（9pt）。
struct StatusDot: View {
    let status: SidebarSessionStatus

    var color: Color {
        switch status {
        case .running: return .green
        case .pendingApproval: return .orange
        case .pendingQuestion: return .purple
        case .idle: return .secondary.opacity(0.5)
        }
    }

    var body: some View {
        if status == .running {
            ProgressView()
                .controlSize(.small)
        } else {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
        }
    }
}

/// 会话行：状态点 + 标题；选中/高亮/键盘导航由 List 提供。
/// 对齐规则：状态点槽位宽度 = 分组头图标槽位（20pt，均 leading 对齐），
/// 行内 spacing 同为 6 —— 状态点与文件夹图标对齐、标题与分组名对齐。
/// 重命名/分叉/归档都在右键菜单里；归档另有一个 hover 快捷键（行尾图标）。
struct SessionRow: View {
    let session: SidebarSession
    let onRename: () -> Void
    let onFork: () -> Void
    let onArchive: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            // 固定宽度槽位与 GroupHeader 的图标槽位一致（20pt、居中对齐），
            // 圆点/菊花与文件夹图标光学中心重合；idle 不显示点（对齐 web）。
            Group {
                if session.status != .idle {
                    StatusDot(status: session.status)
                } else {
                    Color.clear
                }
            }
            .frame(width: 20, height: 16, alignment: .center)
            Text(session.displayTitle)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            // hover 且非 blank（对齐 web：空 New Session 行无归档）时行尾出归档；
            // 点击即归档、无确认——归档非破坏性，日志留着，只是从列表消失。
            if !session.blank {
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
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityIdentifier("sidebar.session.\(session.id)")
        .contextMenu {
            Button("重命名…", action: onRename)
            Button("分叉会话", action: onFork)
            Divider()
            // 归档非破坏性（日志留着，只是从列表消失），所以不标 destructive、
            // 也不弹确认——与 web 的行菜单同款。
            Button("归档会话", action: onArchive)
        }
    }
}

/// Workspace 分组头：文件夹图标（恒定描边）+ 标题（纯展示）
/// + hover 显示的加号（在此工作区新建会话）
/// + 右缘 chevron（唯一的开合开关，点击展开/收起，展开时旋转 90°）。
/// 重命名 / 删除工作区只在右键菜单里。
///
/// **图标不随选中变色**：选中态是会话行的事（List 自己画高亮），分组头
/// 跟着染 accent 只会让人以为分组本身被选中了。
struct GroupHeader: View {
    let group: SidebarGroup
    let expanded: Bool
    let onToggle: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let surface: DashConversationSurface

    @State private var hovering = false

    /// 图标恒定描边（非 filled），开合状态只由 chevron 旋转表达。
    private var iconName: String {
        group.workspaceId == nil ? "tray" : "folder"
    }

    var body: some View {
        HStack(spacing: 6) {
            // 图标 + 标题：纯展示（不再触发展开/收起）。
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, alignment: .leading)
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
            // 再合并，label 和 identifier 都被拼两遍（Description 变
            // "X、X"、Identifier 变 "sidebar.group.X-sidebar.group.X"），
            // 精确匹配落空。label 下面显式给了，不依赖子元素推断。
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(group.title))
            .accessibilityIdentifier("sidebar.group.\(group.id)")
            // hover 时加号出现在 chevron 左侧；.opacity 而非条件插入，
            // 槽位恒定占位，显隐不会让标题跳动。
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
            // 右缘 chevron：唯一的开合开关（点击展开/收起），hover 才显示；
            // 展开时旋转 90°（朝下）。固定槽位保证旋转/显隐不改变布局宽度。
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
            .fixedSize()
            .opacity(hovering ? 1 : 0)
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

/// 主视图：搜索框 + 区段头（工作区 + 添加）+ 按 Workspace 折叠分组的会话列表。
public struct SidebarView<Model: SidebarModel>: View {
    @ObservedObject var model: Model
    let surface: DashConversationSurface

    @State private var searchText = ""
    /// 收起的分组（默认全部展开；搜索时强制展开命中组）。
    /// 逗号拼接持久化（对齐 web 的 groupExpansion 记忆；组 id 无逗号）。
    @AppStorage("sidebar.collapsedGroups") private var collapsedGroupsCSV = ""

    /// 重命名对话框的目标；会话与工作区共用同一个 alert。
    @State private var renameTarget: RenameTarget?
    @State private var renameText = ""
    /// 删除确认的目标（只可能是真工作区）。
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

    private var collapsedGroups: Set<String> {
        Set(collapsedGroupsCSV.split(separator: ",").map(String.init))
    }

    public init(model: Model, surface: DashConversationSurface) {
        self.model = model
        self.surface = surface
    }

    /// List 双向选择绑定：读真源；写（用户点选）走 activate。
    private var selection: Binding<String?> {
        Binding(
            get: { model.selectedSessionId },
            set: { if let id = $0 { model.activate(sessionId: id) } }
        )
    }

    private var searching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
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

    /// 客户端过滤：标题 / 组名子串，大小写不敏感、即时。
    var filteredGroups: [SidebarGroup] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return model.groups }
        let lower = q.lowercased()
        return model.groups.compactMap { group in
            // blank（临时 New Session 行）不参与搜索（对齐 web）。
            let hitSessions = group.sessions.filter {
                !$0.blank && $0.displayTitle.lowercased().contains(lower)
            }
            if !hitSessions.isEmpty {
                return SidebarGroup(id: group.id, workspaceId: group.workspaceId,
                                    title: group.title, sessions: hitSessions)
            }
            if group.title.lowercased().contains(lower) {
                return group
            }
            return nil
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            searchField
            sectionHeader
            // 原生 List(selection:) 样式保留；分组头放 Section header——
            // sidebar List 的 header 不是可选行，点击不会有任何高亮。
            List(selection: selection) {
                ForEach(filteredGroups) { group in
                    Section {
                        if isExpanded(group.id) {
                            ForEach(group.sessions) { session in
                                SessionRow(
                                    session: session,
                                    onRename: {
                                        beginRename(.session(id: session.id,
                                                             title: session.displayTitle))
                                    },
                                    onFork: { model.forkSession(id: session.id) },
                                    onArchive: { model.archive(sessionId: session.id) }
                                )
                                .tag(session.id)
                            }
                        }
                    } header: {
                        GroupHeader(group: group,
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
                            // Section header 默认占位高度偏窄，补回接近普通行的行高，
                            // 让 hover 区域和 chevron 点击区不至于太挤。
                            .padding(.vertical, 3)
                            .frame(minHeight: 26)
                            .padding(.top, 4) // 组间呼吸
                    }
                }
            }
            .listStyle(.sidebar)
            .accessibilityIdentifier("sidebar.list")
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

    // MARK: - 对话框

    private var renamePresented: Binding<Bool> {
        Binding(get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } })
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } })
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { model.actionError != nil },
                set: { if !$0 { model.actionError = nil } })
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

    // MARK: - 区段头

    /// 列表区段头：「工作区」标题 + 添加按钮（对齐 web 的 sectionHeader）。
    /// 新增的对象是工作区，按钮就贴着工作区列表的头——比压在列表底栏好找。
    /// 第 3 批的视图选项按钮也落这一行，在加号左边。
    private var sectionHeader: some View {
        HStack(spacing: 0) {
            Text("工作区")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("sidebar.section.workspaces")
            Spacer(minLength: 8)
            Button(action: addWorkspace) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("添加工作区")
            .accessibilityLabel(Text("添加工作区"))
            .accessibilityIdentifier("sidebar.addWorkspace")
        }
        // 左缘与分组头的文件夹图标同列；右缘与分组头 chevron 同列。
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.bottom, 2)
    }

    /// 添加工作区 = 选一个已存在的目录交给 host 登记（`workspace.create`）。
    /// web 那边走的是 directory-picker 插件；原生直接用 NSOpenPanel，代价是
    /// **默认 app 与 dsh 同机**——当前架构本来就如此（endpoint 是本地文件）。
    /// 选中一个已登记的目录不算错：host 回 `created: false` 并回显原有工作区。
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
        // 附在窗口上（sheet）是 macOS 的默认期待；没有 key window 时退回独立面板。
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: adopt)
        } else {
            adopt(panel.runModal())
        }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("搜索会话", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .accessibilityIdentifier("sidebar.search")
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sidebar.search.clear")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(0.06))
        )
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
}
