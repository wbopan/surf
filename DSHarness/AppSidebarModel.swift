import Foundation
import Observation
import DSHKit
import DSHSidebarUI

/// Mac 壳的侧边栏模型：把 DSHKit.SessionStore（协议客户端镜像）适配成
/// DSHSidebarUI 需要的 SidebarModel（窄 UI 协议）。
/// 选中状态在此收敛：原生点击与页面 currentSession 上报都汇到 selectedSessionId。
@MainActor
final class AppSidebarModel: ObservableObject, SidebarModel {
    @Published var selectedSessionId: String?

    private let store: SessionStore
    private let surface: ConversationSurface

    init(store: SessionStore, surface: ConversationSurface) {
        self.store = store
        self.surface = surface
    }

    // MARK: - SidebarModel

    var groups: [SidebarGroup] {
        store.groups.map { group in
            SidebarGroup(
                id: group.id,
                workspaceId: group.workspaceId,
                title: group.title,
                sessions: group.sessions.map(sessionRow)
            )
        }
    }

    func activate(sessionId: String) {
        selectedSessionId = sessionId
        surface.selectSession(id: sessionId)
    }

    /// 页面反向上报当前会话变化（ConversationSurface 桥的 currentSession 消息）。
    func pageDidSelect(sessionId: String) {
        guard sessionId != selectedSessionId else { return }
        selectedSessionId = sessionId
    }

    // MARK: - 转换

    private func sessionRow(_ s: SessionSummary) -> SidebarSession {
        SidebarSession(
            id: s.id,
            title: s.title ?? "",
            status: statusDot(s),
            updatedAt: s.updatedAt,
            blank: s.blank
        )
    }

    private func statusDot(_ s: SessionSummary) -> SidebarSessionStatus {
        if store.pendingApproval.contains(s.id) { return .pendingApproval }
        if store.pendingQuestion.contains(s.id) { return .pendingQuestion }
        if s.running { return .running }
        return .idle
    }
}
