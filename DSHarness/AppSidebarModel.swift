import Foundation
import Combine
import Observation
import DSHKit
import DSHSidebarUI

/// Mac 壳的侧边栏模型：把 DSHKit.SessionStore（协议客户端镜像）适配成
/// DSHSidebarUI 需要的 SidebarModel（窄 UI 协议）。
/// 选中状态在此收敛：原生点击与页面上报都汇到 selectedSessionId。
@MainActor
final class AppSidebarModel: ObservableObject, SidebarModel {
    @Published var selectedSessionId: String?

    private let store: SessionStore
    private let surface: ConversationSurface
    /// 数据真源在 store（另一个 ObservableObject）；SidebarView 观察的是本模型，
    /// 必须把 store 的 objectWillChange 转发过来，否则列表永远不刷新（首帧为空）。
    private var storeChangeForwarder: AnyCancellable?
    private var lastLoggedCount = -1
    /// 诊断日志落点（harness.log），nil 则只 print。
    private let logURL: URL?

    init(store: SessionStore, surface: ConversationSurface, logURL: URL? = nil) {
        self.store = store
        self.surface = surface
        self.logURL = logURL
        storeChangeForwarder = store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.objectWillChange.send()
                // objectWillChange 在变更前发出，读的是上一帧值；只用于变更日志。
                let count = self.store.groups.reduce(0) { $0 + $1.sessions.count }
                if count != self.lastLoggedCount {
                    self.lastLoggedCount = count
                    Log.write("侧边栏镜像更新：\(count) 条会话", to: self.logURL, tag: "sidebar")
                }
            }
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
