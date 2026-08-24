import SwiftUI

// 原生侧边栏（阶段二·Mail 风格）：交给系统。
// List(selection:) + .listStyle(.sidebar) 提供原生选中/hover/键盘导航，
// 宿主把本视图装进 NSSplitViewItem(sidebarWithViewController:)，
// 材质、分隔条、拖拽调宽、收起动画、宽度记忆全部由系统处理。

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

/// 会话行：状态点 + 标题 + 相对时间；选中/高亮/键盘导航由 List 提供。
struct SessionRow: View {
    let session: SidebarSession

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(status: session.status)
            Text(session.displayTitle)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Text(relativeTime(session.updatedAt))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

/// 主视图：Mail 式侧边栏列表。
public struct SidebarView<Model: SidebarModel>: View {
    @ObservedObject var model: Model
    let surface: ConversationSurface

    @State private var searchText = ""

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
        List(selection: selection) {
            ForEach(filteredGroups) { group in
                Section(group.title) {
                    ForEach(group.sessions) { session in
                        SessionRow(session: session)
                            .tag(session.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText, prompt: "搜索会话")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
        }
    }

    /// 底部固定操作区（Mail 工具栏位置）：New Session + 设置。
    private var bottomBar: some View {
        HStack(spacing: 4) {
            Button {
                surface.startSession(workspaceId: nil)
            } label: {
                Label("New Session", systemImage: "plus")
            }
            .help("新建会话")
            Spacer(minLength: 0)
            Button {
                surface.openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .help("设置")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
