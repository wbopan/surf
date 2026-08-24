import SwiftUI

// 原生侧边栏（阶段一）：信息架构与交互语义 1:1 对齐 web 侧边栏，
// 视觉遵循 macOS 原生风格——透明背景，坐在宿主的玻璃层上（壳负责背景）。

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

/// 会话行：状态点 + 标题 + 相对时间；点击 → model.activate（模型负责桥接与高亮）。
struct SessionRow: View {
    let session: SidebarSession
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                StatusDot(status: session.status)
                Text(session.displayTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.85))
                Spacer(minLength: 0)
                Text(relativeTime(session.updatedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.accentColor.opacity(0.22) : Color.clear)
        )
        .hoverHighlight(selected: selected)
    }
}

/// Workspace 分组头（可展开/收起）+ 会话行；展开默认 5 条 + “显示更多”。
struct GroupSection: View {
    let group: SidebarGroup
    let selectedSessionId: String?
    let onSelect: (String) -> Void

    @State private var expanded = true
    @State private var showAll = false
    private let previewCount = 5

    var visibleSessions: [SidebarSession] {
        showAll ? group.sessions : Array(group.sessions.prefix(previewCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text(group.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)

            if expanded {
                ForEach(visibleSessions) { session in
                    SessionRow(session: session,
                               selected: session.id == selectedSessionId) {
                        onSelect(session.id)
                    }
                }
                if group.sessions.count > previewCount && !showAll {
                    Button {
                        withAnimation { showAll = true }
                    } label: {
                        Text("显示更多（\(group.sessions.count - previewCount)）")
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 21)
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(.bottom, 6)
    }
}

/// 收起态 rail（56pt 宽）：展开、New Session、添加、搜索 四个 36pt 控件。
struct CollapsedRail: View {
    let onExpand: () -> Void
    let onNewSession: () -> Void
    let onAddWorkspace: () -> Void
    let onSearch: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            railButton("sidebar.left", onExpand)
            railButton("plus.square", onNewSession)
            railButton("folder.badge.plus", onAddWorkspace)
            Spacer()
            railButton("magnifyingglass", onSearch)
        }
        .padding(.top, 56)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
    }

    private func railButton(_ systemName: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(selected: false)
    }
}

/// 主视图。
public struct SidebarView<Model: SidebarModel>: View {
    @ObservedObject var model: Model
    let surface: ConversationSurface
    /// 顶部让位（红绿灯/拖拽条），由壳传入。
    var topInset: CGFloat = 40
    /// 收起/展开（宽度联动由壳管理）。
    var collapsed: Bool = false
    var onToggleCollapse: (() -> Void)?

    @State private var searchText = ""
    @State private var railSearchWish: Bool = false

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

    public init(model: Model, surface: ConversationSurface,
                topInset: CGFloat = 40, collapsed: Bool = false,
                onToggleCollapse: (() -> Void)? = nil) {
        self.model = model
        self.surface = surface
        self.topInset = topInset
        self.collapsed = collapsed
        self.onToggleCollapse = onToggleCollapse
    }

    public var body: some View {
        Group {
            if collapsed {
                CollapsedRail(
                    onExpand: { onToggleCollapse?() },
                    onNewSession: { surface.startSession(workspaceId: nil) },
                    onAddWorkspace: { surface.openSettings() }, // 阶段一：添加流后置，落到设置面
                    onSearch: {
                        onToggleCollapse?()
                        railSearchWish = true
                    })
            } else {
                expandedBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.clear)
    }

    private var expandedBody: some View {
        VStack(spacing: 0) {
            // 品牌行（上游是 slot，默认鱼形 mark；这里文本占位）
            HStack(spacing: 8) {
                Image(systemName: "fish.fill")
                    .foregroundStyle(.tint)
                Text("DeepSeek")
                    .font(.headline)
                Spacer()
                Button {
                    onToggleCollapse?()
                } label: {
                    Image(systemName: "sidebar.left")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("收起侧边栏")
            }
            .padding(.horizontal, 12)
            .padding(.top, topInset)
            .padding(.bottom, 10)

            // New Session
            Button {
                surface.startSession(workspaceId: nil)
            } label: {
                HStack {
                    Image(systemName: "plus")
                    Text("New Session")
                        .fontWeight(.medium)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.accentColor.opacity(0.18))
                )
            }
            .buttonStyle(.plain)
            .hoverHighlight(selected: false)
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            // 搜索（阶段一：客户端标题过滤）
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                TextField("搜索会话", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.06))
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            // 会话浏览器
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredGroups) { group in
                        GroupSection(group: group,
                                     selectedSessionId: model.selectedSessionId) { id in
                            model.activate(sessionId: id)
                        }
                    }
                }
                .padding(.horizontal, 6)
            }

            // 底部固定：设置
            Divider()
            Button {
                surface.openSettings()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                    Text("设置")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverHighlight(selected: false)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}
