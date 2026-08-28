import Combine
import ClamLayout
import ClamSDK
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

    private let bridge: ClamBridge
    private let surface: ClamConversationSurface
    /// 当前界面语言（`@Observable`，与视图共用同一个实例）。投影里那几处兜底
    /// 文案（「未分组」「新会话」）随它走；读它的地方都在视图的 body 链上，
    /// 于是切语言时列表自动重渲。
    private let locale: ClamLocaleStore
    /// 写一行进壳的日志（`host.log`）。
    private let log: (String) -> Void
    private var lastLoggedCount = -1
    /// 选中会话变化时的回调（插件用它落 ClamStore，热替换后能还原高亮）。
    var onSelectionChange: ((String?) -> Void)?

    init(snapshot: SidebarSnapshot,
         bridge: ClamBridge,
         surface: ClamConversationSurface,
         locale: ClamLocaleStore,
         log: @escaping (String) -> Void) {
        self.snapshot = snapshot
        self.bridge = bridge
        self.surface = surface
        self.locale = locale
        self.log = log
    }

    /// 当前语言下的文案表。**每次现算**，不存快照——存下来就得有人在语言变化时
    /// 记得换，而现算天生不会漏。
    var strings: L { L(locale.current) }

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
    ///
    /// **协议是结构化的**（`{action, code?, message}`，见 `lib/index.js` 顶部）：
    /// node 那边一个显示文案都不拼——它不知道界面是哪种语言，也不该知道。
    /// `code` 是我们自己认领的失败（数据面没就绪之类），`message` 是上游那句原话。
    ///
    /// 日志固定用中文（`L(.zh)`）：读它的是蹲在终端前的人，跟着界面语言变
    /// 只会让排错时对不上账。
    func reportFailure(action: String, code: String?, message: String) {
        let zh = L(.zh)
        log(zh.actionFailed(action: action,
                            reason: zh.failureReason(code: code, message: message)))
        let ui = strings
        actionError = ui.actionFailed(action: action,
                                      reason: ui.failureReason(code: code, message: message))
    }

    // MARK: - SidebarModel

    var groups: [SidebarGroup] {
        let current = strings
        return snapshot.groups.map { group in
            SidebarGroup(
                id: group.id,
                workspaceId: group.workspaceId,
                // 兜底组在数据层没有标题（文案不归数据层管），显示层收口成
                // web 同款的「未分组」。
                title: group.workspaceId == nil ? current.ungrouped : group.title,
                sessions: group.sessions.filter(visible).map { sessionRow($0, current) }
            )
        }
    }

    /// 可见性规则（**此处刻意偏离 web 的 sessionVisible**）：subagent 子会话
    /// 永不显示；blank 会话一律不显示。web 的做法是"blank 恰好是当前选中时临时
    /// 插一行 New Session"，但那行的存亡挂在选中态上——点走别处它就凭空消失，
    /// 列表里于是有一条随焦点闪进闪出的幽灵行。原生侧边栏的取舍是：没落下第一句
    /// prompt 的会话不算列表成员；上游在首个 prompt 后把 blank 翻成 false，
    /// 那一刻行自然出现，且已经是选中态。
    ///
    /// **规则留在显示层而不是随数据面一起搬去 node**：它是 UI 政策
    /// （"列表里显示什么"），不是数据事实；投影照实带上 `blank` / `isSubagent`。
    ///
    /// 副作用（有意接受）：新建后到首个 prompt 之间，列表无任何高亮行。
    ///
    /// **归档不在这儿滤**：v3 起它随投影原样下来，由视图按「显示已归档」开关决定
    /// ——那是个用户当场能拨的开关，滤在这里的话开关就够不着了。
    private func visible(_ s: SidebarSnapshot.Session) -> Bool {
        !s.isSubagent && !s.blank
    }

    /// **动作面不走桥**：切换会话是页面的事，一直是、也仍然是
    /// clam-layout 的 `conversationSurface`（页内 `window.__clam`）。
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

    /// **没有标题的会话在这里就填好兜底文案**（`SidebarSession` 是个不认识语言的
    /// 值类型，而搜索也拿 `displayTitle` 比对——两处必须是同一个串）。
    private func sessionRow(_ s: SidebarSnapshot.Session, _ strings: L) -> SidebarSession {
        let title = s.title ?? ""
        return SidebarSession(
            id: s.id,
            title: title.isEmpty ? strings.untitledSession : title,
            preview: s.preview ?? "",
            status: Self.statusIcon(s.status),
            updatedAt: s.date,
            blank: s.blank,
            archived: s.archived ?? false
        )
    }

    /// wire 上的状态串 → 状态指示器。未知值当 idle（node 加新状态时旧壳不至于失真成别的）。
    private static func statusIcon(_ raw: String) -> SidebarSessionStatus {
        switch raw {
        case "running": return .running
        case "pendingApproval": return .pendingApproval
        case "pendingQuestion": return .pendingQuestion
        case "failed": return .failed
        case "done": return .done
        default: return .idle
        }
    }
}
