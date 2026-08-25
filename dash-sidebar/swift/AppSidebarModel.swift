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
    /// 最近一次写操作的失败原因（视图弹 alert 后置 nil）。
    @Published var actionError: String?

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
                // 兜底组的标题在 DSHKit 里是英文常量 "Other"（数据层不该管文案）。
                // 显示层收口成 web 同款的「未分组」。
                title: group.workspaceId == nil ? "未分组" : group.title,
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

    /// 归档（对齐 web：无确认弹窗）。store 收到归档集回包后即刻本地剔除该行。
    func archive(sessionId: String) {
        perform("归档会话") { [store] in try await store.archiveSession(id: sessionId) }
    }

    func renameSession(id: String, title: String) {
        perform("重命名会话") { [store] in try await store.renameSession(id: id, title: title) }
    }

    /// 分叉后切到子会话——与 web 的 `fork(...).then(open)` 同序：先拿到 id，
    /// 再走展示面，这样列表刷新到达之前高亮就已经在新行上。
    func forkSession(id: String) {
        perform("分叉会话") { [store, weak self] in
            let childId = try await store.forkSession(id: id)
            self?.activate(sessionId: childId)
        }
    }

    func createWorkspace(path: String) {
        perform("添加工作区") { [store] in try await store.createWorkspace(path: path) }
    }

    func renameWorkspace(id: String, title: String) {
        perform("重命名工作区") { [store] in try await store.renameWorkspace(id: id, title: title) }
    }

    func deleteWorkspace(id: String) {
        perform("删除工作区") { [store] in try await store.deleteWorkspace(id: id) }
    }

    /// 写操作统一收口：失败既进壳日志、也抬到 `actionError` 让视图弹一次 alert。
    /// （web 多数写失败只进浏览器 console；原生用户看不到控制台，
    /// 静默失败会让人以为动作生效了。）
    private func perform(_ what: String,
                         _ body: @escaping @MainActor () async throws -> Void) {
        Task { [log] in
            do {
                try await body()
            } catch {
                let reason = error.localizedDescription
                log("\(what)失败：\(reason)")
                actionError = "\(what)失败：\(reason)"
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
