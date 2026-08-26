import Combine
import DashLayout
import DashSDK
import Foundation

/// 侧边栏模型：把 node 半边推下来的 `SidebarSnapshot` 适配成 SidebarView 需要的
/// `SidebarModel`（窄 UI 协议），并把用户动作原样转成桥上的 `invoke` 帧。
///
/// **它不再持有任何数据源。**（M6~M9 时这里握着 DSHKit 的 `SessionStore`，
/// 自己开 WS、自己重试、自己合并。M10 把那一整套搬进了 node 半边——壳与共享
/// module 随 app bundle 冻结，而它们装的偏偏是随 dsh 版本演进最快的 wire 模型。）
/// 现在这里只剩三件事：投影 → UI 值类型、UI 动作 → 桥、选中状态收敛。
///
/// 选中状态在此收敛：原生点击与页面上报都汇到 selectedSessionId。
@MainActor
final class AppSidebarModel: ObservableObject, SidebarModel {
    @Published var selectedSessionId: String?
    /// 最近一次写操作的失败原因（视图弹 alert 后置 nil）。node 半边经
    /// `error` 频道推下来——原生这边没有控制台可看，静默失败等于骗人。
    @Published var actionError: String?

    /// 最近一份全量投影。上一代留在保管箱里的旧快照会作为初值传进来，
    /// 于是换代时列表不闪；fresh 快照到了原样替换。
    @Published private(set) var snapshot: SidebarSnapshot

    private let bridge: DashBridge
    private let surface: DashConversationSurface
    /// 写一行进壳的日志（`host.log`）。
    private let log: (String) -> Void
    private var lastLoggedCount = -1
    /// 选中会话变化时的回调（插件用它落 DashStore，热替换后能还原高亮）。
    var onSelectionChange: ((String?) -> Void)?

    init(snapshot: SidebarSnapshot,
         bridge: DashBridge,
         surface: DashConversationSurface,
         log: @escaping (String) -> Void) {
        self.snapshot = snapshot
        self.bridge = bridge
        self.surface = surface
        self.log = log
    }

    // MARK: - 桥下行

    /// 收下一份新投影。数量变了才记一行日志（否则每次 running 翻牌都刷屏）。
    func apply(snapshot: SidebarSnapshot) {
        self.snapshot = snapshot
        let count = snapshot.groups.reduce(0) { $0 + $1.sessions.count }
        if count != lastLoggedCount {
            lastLoggedCount = count
            log("侧边栏投影更新：\(count) 条会话（v\(snapshot.version)）")
        }
    }

    /// node 半边报回来的写操作失败。
    func reportFailure(action: String, reason: String) {
        let what = Self.actionLabels[action] ?? action
        log("\(what)失败：\(reason)")
        actionError = "\(what)失败：\(reason)"
    }

    /// 动作名 → 中文说法。桥上传的是动作名（机器可读），文案归显示层。
    private static let actionLabels: [String: String] = [
        "archive": "归档会话",
        "renameSession": "重命名会话",
        "fork": "分叉会话",
        "createWorkspace": "添加工作区",
        "renameWorkspace": "重命名工作区",
        "deleteWorkspace": "删除工作区",
    ]

    // MARK: - SidebarModel

    var groups: [SidebarGroup] {
        snapshot.groups.map { group in
            SidebarGroup(
                id: group.id,
                workspaceId: group.workspaceId,
                // 兜底组在数据层没有标题（文案不归数据层管），显示层收口成
                // web 同款的「未分组」。
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
    /// 那一刻行自然出现，且已经是选中态。归档已在 node 半边的投影里滤除。
    ///
    /// **规则留在显示层而不是随数据面一起搬去 node**：它是 UI 政策
    /// （"列表里显示什么"），不是数据事实；投影照实带上 `blank` / `isSubagent`。
    ///
    /// 副作用（有意接受）：新建后到首个 prompt 之间，列表无任何高亮行。
    private func visible(_ s: SidebarSnapshot.Session) -> Bool {
        !s.isSubagent && !s.blank
    }

    /// **动作面不走桥**：切换会话是页面的事，一直是、也仍然是
    /// dash-layout 的 `conversationSurface`（页内 `window.__dash`）。
    func activate(sessionId: String) {
        selectedSessionId = sessionId
        onSelectionChange?(sessionId)
        surface.selectSession(id: sessionId)
    }

    /// 归档（对齐 web：无确认弹窗）。node 半边写完即重推投影，该行随之消失。
    func archive(sessionId: String) {
        bridge.send(action: "archive", payload: ["sessionId": sessionId])
    }

    func renameSession(id: String, title: String) {
        bridge.send(action: "renameSession", payload: ["sessionId": id, "title": title])
    }

    /// 分叉。与 web 的 `fork(...).then(open)` 同序：node 分叉完把子会话 id 经
    /// `forked` 频道推回来，插件再调 `activate`——所以这里只管发出去。
    /// 标题的序号递增在 node 半边复刻（`lib/fork-title.js`）。
    func forkSession(id: String) {
        bridge.send(action: "fork", payload: ["sessionId": id])
    }

    func createWorkspace(path: String) {
        bridge.send(action: "createWorkspace", payload: ["path": path])
    }

    func renameWorkspace(id: String, title: String) {
        bridge.send(action: "renameWorkspace", payload: ["workspaceId": id, "title": title])
    }

    func deleteWorkspace(id: String) {
        bridge.send(action: "deleteWorkspace", payload: ["workspaceId": id])
    }

    /// 页面反向上报当前会话变化（ConversationSurface 桥的 currentSession 消息）。
    func pageDidSelect(sessionId: String) {
        guard sessionId != selectedSessionId else { return }
        selectedSessionId = sessionId
        onSelectionChange?(sessionId)
    }

    // MARK: - 转换

    private func sessionRow(_ s: SidebarSnapshot.Session) -> SidebarSession {
        SidebarSession(
            id: s.id,
            title: s.title ?? "",
            status: Self.statusDot(s.status),
            updatedAt: s.date,
            blank: s.blank
        )
    }

    /// wire 上的状态串 → 状态点。未知值当 idle（node 加新状态时旧壳不至于失真成别的）。
    private static func statusDot(_ raw: String) -> SidebarSessionStatus {
        switch raw {
        case "running": return .running
        case "pendingApproval": return .pendingApproval
        case "pendingQuestion": return .pendingQuestion
        default: return .idle
        }
    }
}
