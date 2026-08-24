import SwiftUI

// 原生侧边栏（阶段二·Mail 风格）：交给系统。
// List(selection:) + .listStyle(.sidebar) 提供原生选中/hover/键盘导航，
// DisclosureGroup 提供分组折叠与子行缩进；宿主把本视图装进
// NSSplitViewItem(sidebarWithViewController:)，材质、分隔条、拖拽调宽、
// 收起动画、宽度记忆全部由系统处理。
// 顶部操作按钮（收起侧边栏 / 新建会话）在宿主的 NSToolbar，不在本视图。

/// 相对时间（几分钟前 / 几小时前 / 几天前 / 日期）。
func relativeTime(_ date: Date, now: Date = Date()) -> String {
    let sec = now.timeIntervalSince(date)
    if sec < 60 { return "刚刚" }
    if sec < 3600 { return "\(Int(sec / 60)) 分钟前" }
    if sec < 86400 { return "\(Int(sec / 3600)) 小时前" }
    if sec < 86400 * 7 { return "\(Int(sec / 86400)) 天前" }
    let f = DateFormatter()
    f.dateStyle = .short
    f.timeStyle = .none
    return f.string(from: date)
}

/// 会话状态点（running/pending…/idle 的唯一自绘元素，其余交给系统）。
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
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
    }
}

/// 会话行：状态点 + 标题 + 相对时间；选中/高亮/键盘导航/缩进由 List 提供。
struct SessionRow: View {
    let session: SidebarSession

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(status: session.status)
            Text(session.displayTitle)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(relativeTime(session.updatedAt))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

/// Workspace 分组头：图标 + 名称 + hover 显示的 … 菜单（对齐 dsh 原版语义）。
struct GroupHeader: View {
    let group: SidebarGroup
    let surface: ConversationSurface

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: group.workspaceId == nil ? "tray" : "folder")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(group.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Menu {
                Button("在此工作区新建会话") {
                    surface.startSession(workspaceId: group.workspaceId)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
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
    @State private var collapsedGroups: Set<String> = []

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

    private func expandedBinding(_ groupId: String) -> Binding<Bool> {
        guard !searching else { return .constant(true) }
        return Binding(
            get: { !collapsedGroups.contains(groupId) },
            set: { expanded in
                if expanded { collapsedGroups.remove(groupId) }
                else { collapsedGroups.insert(groupId) }
            }
        )
    }

    /// 客户端过滤：标题 / 组名子串，大小写不敏感、即时。
    var filteredGroups: [SidebarGroup] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return model.groups }
        let lower = q.lowercased()
        return model.groups.compactMap { group in
            let hitSessions = group.sessions.filter {
                $0.displayTitle.lowercased().contains(lower)
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
            List(selection: selection) {
                ForEach(filteredGroups) { group in
                    DisclosureGroup(isExpanded: expandedBinding(group.id)) {
                        ForEach(group.sessions) { session in
                            SessionRow(session: session)
                                .tag(session.id)
                        }
                    } label: {
                        GroupHeader(group: group, surface: surface)
                    }
                    .padding(.top, 4) // 组间呼吸
                }
            }
            .listStyle(.sidebar)
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
