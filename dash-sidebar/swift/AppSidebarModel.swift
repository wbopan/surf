import Combine
import DSHKit
import DashLayout
import Foundation
import Observation

/// 侧边栏模型：把 DSHKit.SessionStore（协议客户端镜像）适配成
/// SidebarView 需要的 SidebarModel（窄 UI 协议）。
/// 选中状态在此收敛：原生点击与页面上报都汇到 selectedSessionId。
/// （M6 前住在壳里叫同一个名字，随插件化整体迁入。）
@MainActor
final class AppSidebarModel: ObservableObject, SidebarModel {
    @Published var selectedSessionId: String?

    private let store: SessionStore
    private let surface: DashConversationSurface
    /// 数据真源在 store（另一个 ObservableObject）；SidebarView 观察的是本模型，
    /// 必须把 store 的 objectWillChange 转发过来，否则列表永远不刷新（首帧为空）。
    private var storeChangeForwarder: AnyCancellable?
    private var lastLoggedCount = -1
    /// 写一行进壳的日志（`host.log`）。
    private let log: (String) -> Void
    /// 选中会话变化时的回调（插件用它落 DashStore，热替换后能还原高亮）。
    var onSelectionChange: ((String?) -> Void)?

    init(store: SessionStore, surface: DashConversationSurface,
         log: @escaping (String) -> Void) {
        self.store = store
        self.surface = surface
        self.log = log
        storeChangeForwarder = store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.objectWillChange.send()
                // objectWillChange 在变更前发出，读的是上一帧值；只用于变更日志。
                let count = self.store.groups.reduce(0) { $0 + $1.sessions.count }
                if count != self.lastLoggedCount {
                    self.lastLoggedCount = count
                    self.log("侧边栏镜像更新：\(count) 条会话")
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
                sessions: group.sessions.filter(visible).map(sessionRow)
            )
        }
    }

    /// 可见性规则（**此处刻意偏离 web 的 sessionVisible**）：subagent 子会话
    /// 永不显示；blank 会话一律不显示。web 的做法是"blank 恰好是当前选中时临时
    /// 插一行 New Session"，但那行的存亡挂在选中态上——点走别处它就凭空消失，
    /// 列表里于是有一条随焦点闪进闪出的幽灵行。原生侧边栏的取舍是：没落下第一句
    /// prompt 的会话不算列表成员；上游在首个 prompt 后把 blank 翻成 false，
    /// 那一刻行自然出现，且已经是选中态。归档已在 SessionStore 镜像层滤除。
    ///
    /// 副作用（有意接受）：新建后到首个 prompt 之间，列表无任何高亮行，
    /// 分组头的文件夹也不再染 accent（containsCurrent 查的就是这份可见行）。
    private func visible(_ s: SessionSummary) -> Bool {
        !s.isSubagent && !s.blank
    }

    func activate(sessionId: String) {
        selectedSessionId = sessionId
        onSelectionChange?(sessionId)
        surface.selectSession(id: sessionId)
    }

    /// 归档（对齐 web：失败只记日志、列表不动）。store 收到归档集回包后
    /// 即刻本地剔除该行，无确认弹窗。
    func archive(sessionId: String) {
        Task { [store, log] in
            do {
                try await store.archiveSession(id: sessionId)
            } catch {
                log("归档会话 \(sessionId) 失败：\(error.localizedDescription)")
            }
        }
    }

    /// 页面反向上报当前会话变化（ConversationSurface 桥的 currentSession 消息）。
    func pageDidSelect(sessionId: String) {
        guard sessionId != selectedSessionId else { return }
        selectedSessionId = sessionId
        onSelectionChange?(sessionId)
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
