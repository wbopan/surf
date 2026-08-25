import Foundation
import SwiftUI

// 侧边栏的数据面：一个窄协议，AppSidebarModel 把 DSHKit.SessionStore 适配进来。
// 值类型在本文件定义，让视图不必反向依赖协议客户端的实现细节。
// （M6 前这些住在 Packages/DSHSidebarUI，随插件化整体迁入。）

/// 会话状态点（对齐 web 侧边栏语义）。
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
    public let status: SidebarSessionStatus
    public let updatedAt: Date
    /// 新建未输入的空会话（web 侧显示占位标题）。
    public let blank: Bool

    public init(id: String, title: String, status: SidebarSessionStatus,
                updatedAt: Date, blank: Bool = false) {
        self.id = id
        self.title = title
        self.status = status
        self.updatedAt = updatedAt
        self.blank = blank
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

/// 侧边栏数据 + 选择模型（ObservableObject，由宿主适配 DSHKit.SessionStore）。
@MainActor
public protocol SidebarModel: ObservableObject {
    /// 按上游顺序排列的分组（已滤除归档）。
    var groups: [SidebarGroup] { get }
    /// 当前选中的会话（点击原生行与页面上报双向同步的唯一真源）。
    var selectedSessionId: String? { get }
    /// 用户点击原生行：更新选中并通过展示面切换 conversation。
    func activate(sessionId: String)
    /// 归档会话（对齐 web 侧行菜单的 Archive：无确认、非破坏性，
    /// 归档集合回包后行从所有分组消失）。blank 行不提供。
    func archive(sessionId: String)
}
