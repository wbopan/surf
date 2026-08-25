import SwiftUI

// 原生侧边栏（阶段二·Mail 风格）：交给系统。
// List(selection:) + .listStyle(.sidebar) 提供原生选中/hover/键盘导航；
// 分组头自绘（文件夹恒定实心，点击图标/标题开合，右缘 chevron 旋转表开合），
// 宿主把本视图装进 NSSplitViewItem(sidebarWithViewController:)，
// 材质、分隔条、拖拽调宽、收起动画、宽度记忆全部由系统处理。
// 顶部操作按钮（收起侧边栏 / 新建会话）在宿主的 NSToolbar，不在本视图。

/// 相对时间已按需求移除（session 行不再显示时间戳）。

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
/// hover 时行尾显示归档按钮（对齐 web 行菜单的 Archive 动作）。
struct SessionRow: View {
    let session: SidebarSession
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
            // hover 且非 blank（对齐 web：空 New Session 行无归档）时，
            // 时间标签让位给归档按钮；点击即归档、无确认。
            if hovering && !session.blank {
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
            }
        }
        .onHover { hovering = $0 }
    }
}

/// Workspace 分组头：文件夹图标（恒定描边）+ 标题（纯展示）
/// + hover 显示的加号（新建会话）和右缘 chevron（唯一的开合开关，
/// 点击展开/收起，展开时旋转 90°）。
struct GroupHeader: View {
    let group: SidebarGroup
    let expanded: Bool
    /// 组内含当前会话时文件夹染 accent 色（对齐 web 的 folderActive）。
    let containsCurrent: Bool
    let onToggle: () -> Void
    let surface: ConversationSurface

    @State private var hovering = false

    /// 图标恒定描边（非 filled），开合状态只由 chevron 旋转表达。
    private var iconName: String {
        group.workspaceId == nil ? "tray" : "folder"
    }

    var body: some View {
        HStack(spacing: 6) {
            // 图标 + 标题：纯展示（不再触发挥开/收起）。
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.system(size: 14))
                    .foregroundStyle(containsCurrent ? AnyShapeStyle(Color.accentColor)
                                                     : AnyShapeStyle(.secondary))
                    .frame(width: 20, alignment: .leading)
                Text(group.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .help(group.title)
            .accessibilityLabel(Text(group.title))
            // hover 时加号出现在 chevron 左侧，占位固定避免标题跳动。
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
            .fixedSize()
            .opacity(hovering ? 1 : 0)
            // 右缘 chevron：唯一的开合开关（点击展开/收起），hover 才显示；
            // 展开时旋转 90°（朝下）。固定槽位保证旋转/显隐不改变布局宽度。
            Button(action: onToggle) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 20, alignment: .center)
                    .contentShape(Rectangle())
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.15), value: expanded)
            }
            .buttonStyle(.plain)
            .help(expanded ? "收起分组" : "展开分组")
            .accessibilityLabel(Text(expanded ? "收起分组" : "展开分组"))
            .fixedSize()
            .opacity(hovering ? 1 : 0)
        }
        .onHover { hovering = $0 }
    }
}

/// 主视图：搜索框 + 按 Workspace 折叠分组的会话列表。
public struct SidebarView<Model: SidebarModel>: View {
    @ObservedObject var model: Model
    let surface: ConversationSurface

    @State private var searchText = ""
    /// 收起的分组（默认全部展开；搜索时强制展开命中组）。
    /// 逗号拼接持久化（对齐 web 的 groupExpansion 记忆；组 id 无逗号）。
    @AppStorage("sidebar.collapsedGroups") private var collapsedGroupsCSV = ""

    private var collapsedGroups: Set<String> {
        Set(collapsedGroupsCSV.split(separator: ",").map(String.init))
    }

    public init(model: Model, surface: ConversationSurface) {
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
            // 原生 List(selection:) 样式保留；分组头放 Section header——
            // sidebar List 的 header 不是可选行，点击不会有任何高亮。
            List(selection: selection) {
                ForEach(filteredGroups) { group in
                    Section {
                        if isExpanded(group.id) {
                            ForEach(group.sessions) { session in
                                SessionRow(session: session,
                                           onArchive: { model.archive(sessionId: session.id) })
                                    .tag(session.id)
                            }
                        }
                    } header: {
                        GroupHeader(group: group,
                                    expanded: isExpanded(group.id),
                                    containsCurrent: group.sessions.contains {
                                        $0.id == model.selectedSessionId
                                    },
                                    onToggle: { toggleGroup(group.id) },
                                    surface: surface)
                            // Section header 默认占位高度偏窄，补回接近普通行的行高，
                            // 让 hover 区域和 chevron/加号点击区不至于太挤。
                            .padding(.vertical, 3)
                            .frame(minHeight: 26)
                            .padding(.top, 4) // 组间呼吸
                    }
                }
            }
            .listStyle(.sidebar)
            #if DEBUG
            devFooter
            #endif
        }
    }

    #if DEBUG
    /// Dev 构建专属：侧边栏底部橙色 DEV 状态条（含构建时间戳），
    /// 一眼区分 Debug/Release，并确认跑的是哪次构建。
    private var devFooter: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.orange)
                .frame(width: 7, height: 7)
            Text("DEV BUILD")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.orange)
                .tracking(0.8)
            Spacer()
            if !buildTimestamp.isEmpty {
                Text(buildTimestamp)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.orange.opacity(0.8))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.08))
    }

    /// 构建时间戳：主 App prebuild 脚本写入 Resources/BuildTimestamp.txt。
    private var buildTimestamp: String { Self.readBuildTimestamp() }
    #endif

    #if DEBUG
    private static func readBuildTimestamp() -> String {
        guard let url = Bundle.main.url(forResource: "BuildTimestamp", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return "" }
        return text
    }
    #endif

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("搜索会话", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
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
