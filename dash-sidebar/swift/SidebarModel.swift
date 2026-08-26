import Foundation
import SwiftUI

// 侧边栏的数据面：一个窄协议，AppSidebarModel 把 node 半边推下来的投影适配进来。
// 值类型在本文件定义，让视图不必反向依赖 wire 形状——M10 把数据源从
// DSHKit.SessionStore 换成桥上的 JSON 时，本文件与 SidebarView 一行没动，
// 这道窄口子就是为此存在的。
// （M6 前这些住在 Packages/DSHSidebarUI，随插件化整体迁入。）

/// 会话状态（对齐 web 侧边栏语义）。画成什么样见 `StatusIndicator`——
/// 不都是点：正在跑是系统 spinner，等你动作的两个是语义符号。
public enum SidebarSessionStatus: Equatable {
    case running
    case pendingApproval
    case pendingQuestion
    case idle
}

/// 侧边栏展示的会话行。
public struct SidebarSession: Identifiable, Equatable {
    public let id: String
    public let title: String
    /// 副行摘要。空串 = 还没取到（行仍然占两行的高度，只是不写字）。
    public let preview: String
    public let status: SidebarSessionStatus
    public let updatedAt: Date
    /// 新建未输入的空会话（web 侧显示占位标题）。
    public let blank: Bool
    /// 已归档。默认不显示，「筛选」里打开「显示已归档」才出现（并挂一枚归档符号）。
    public let archived: Bool

    public init(id: String, title: String, preview: String = "",
                status: SidebarSessionStatus, updatedAt: Date,
                blank: Bool = false, archived: Bool = false) {
        self.id = id
        self.title = title
        self.preview = preview
        self.status = status
        self.updatedAt = updatedAt
        self.blank = blank
        self.archived = archived
    }

    public var displayTitle: String {
        if blank || title.isEmpty { return "新会话" }
        return title
    }
}

/// 按 Workspace 分组的会话组（`workspaceId == nil` = 未归组的兜底组）。
public struct SidebarGroup: Identifiable, Equatable {
    public let id: String
    public let workspaceId: String?
    public let title: String
    public let sessions: [SidebarSession]

    public init(id: String, workspaceId: String?, title: String, sessions: [SidebarSession]) {
        self.id = id
        self.workspaceId = workspaceId
        self.title = title
        self.sessions = sessions
    }
}

/// 侧边栏数据 + 选择模型（ObservableObject，由 AppSidebarModel 实现）。
@MainActor
public protocol SidebarModel: ObservableObject {
    /// 按上游顺序排列的分组。**归档行照常在里面**（带 `archived: true`），
    /// 露不露由 `SidebarFilterState.showArchived` 说了算。
    var groups: [SidebarGroup] { get }
    /// 当前选中的会话（点击原生行与页面上报双向同步的唯一真源）。
    var selectedSessionId: String? { get }
    /// 用户点击原生行：更新选中并通过展示面切换 conversation。
    func activate(sessionId: String)
    /// 归档会话（对齐 web 侧行菜单的 Archive：无确认、非破坏性，
    /// 归档集合回包后行从所有分组消失）。blank 行不提供。
    func archive(sessionId: String)
    /// 重命名会话。标题由视图裁掉首尾空白后传入，空标题不会走到这里。
    func renameSession(id: String, title: String)
    /// 在最后一个完成回合处分叉会话，并切到新会话（对齐 web 的
    /// `fork` + `open`，标题的分叉序号递增也在数据层复刻）。
    func forkSession(id: String)
    /// 把一个已存在的目录登记成工作区（`workspace.create`）。
    func createWorkspace(path: String)
    /// 重命名工作区。
    func renameWorkspace(id: String, title: String)
    /// 从工作区列表移除（`workspace.delete`）。非破坏性：目录与会话记录都留着，
    /// 其会话回到「未分组」。视图负责先弹确认。
    func deleteWorkspace(id: String)
    /// 最近一次写操作的失败原因，供视图弹一次 alert；视图关掉时置 nil。
    /// 原生这边没有控制台可看，静默失败等于骗人。
    var actionError: String? { get set }
}
