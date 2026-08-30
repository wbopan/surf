import SurfSDK
import Foundation
import Observation

/// 一次连接尝试的失败原因（`docs/archive/surf-connection-plan.md` §2）。
///
/// **分类不是为了好看**：连接页那一行"原因"、诊断面板每个候选后面的标注、
/// 以及"要不要继续退避重试"三处都读它。认不出来的错误一律归 `.refused`
/// ——界面上"连接被拒绝"比"未知错误"更接近事实（后端不在那儿）。
enum ConnectFailure: Equatable, Sendable {
    case refused
    case timeout
    case httpError(Int)
    /// HTTP 活着但桥握手没成——后端在，插件通道不通。
    case bridgeRejected
}

/// 曾经连上又断了的原因。
enum DisconnectReason: Equatable, Sendable {
    /// 健康探测连不上了：后端进程多半已经退出。
    case processGone
    /// HTTP 还在但桥掉了（眼下不单独进断连幕，只作为诊断信息记着）。
    case bridgeLost
    /// 用户按了 ⌘⇧R 或"连接其他后端…"。
    case userRequested
}

/// 显式连接状态机的六幕。**这是壳里"我此刻连着谁"的唯一真相**——
/// 以前它散在 `endpoint` / `bootstrapPhase` / `isBridgeConnected` / `bridgeReady`
/// 四个变量、三条互不知情的时间线里。
enum ConnectionPhase: Equatable, Sendable {
    case searching                       // 正在扫描/探测候选
    case connecting(SurfEndpoint)        // 选中候选，装页面 + 桥握手中
    case connected(SurfEndpoint)         // 桥 hello 已到（页 ready 是附加布尔）
    case disconnected(DisconnectReason)  // 曾连上，丢了
    case unreachable(ConnectFailure)     // 有明确目标（fixed / 手动）但连不上
    case idle                            // 没有任何候选

    /// 页面此刻该不该盖上去。connecting 一到就撤——与旧实现
    /// （`enterRunning()` 里第一句 `hideBootstrap()`）逐帧一致。
    var showsOverlay: Bool {
        switch self {
        case .connecting, .connected: return false
        default: return true
        }
    }

    /// 断连页 = 曾经连上过；引导连接页 = 其余各幕。
    var isDisconnected: Bool {
        if case .disconnected = self { return true }
        return false
    }

    /// 诊断面板与 `surf.connection.state` 投影用的稳定标识（不随界面语言变）。
    var key: String {
        switch self {
        case .searching: return "searching"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .disconnected: return "disconnected"
        case .unreachable: return "unreachable"
        case .idle: return "idle"
        }
    }
}

/// 连接偏好（`docs/archive/surf-connection-plan.md` §4，M7 §11.1 修订）。
///
/// **没有"缺省"这一档**：偏好用 `ConnectionMode?` 表达，`nil` = 未设置（unset）。
/// 早先把 unset 读成 `auto`，于是壳一开机就去扫本机所有端口并接入最近启动的那个
/// ——用户裁决："也许这个机器上会有多个端口，但我们并不应该乱 attach"。
/// unset 的语义因此是**照常发现、照常探活、但绝不 adopt**：列表要显示，
/// 接不接由用户在引导页上点一下说了算。
///
/// **但 unset 不再是首次运行的默认**（2026-08-30 用户裁决："设置默认是自管理
/// 后端，这样我们才能更好在以后管理生命周期"）：没设过这个键时读成 `managed`。
/// 这不违背上面那条裁决——它否的是"隐式去接别人的后端"，而 managed 是
/// **壳自己起一个、自己监护、⌘Q 自己收走**，接入的是它亲手拉起来的那一个。
enum ConnectionMode: String, Sendable, CaseIterable {
    case auto      // 扫发现文件、并行 probe、择优接入
    case fixed     // 钉死一个 URL，连不上如实报错，不回退 auto
    case managed   // auto 的发现逻辑 + BackendManager 保证有一个自己的后端在跑
}

/// 一个候选的健康态。连接页的"发现的后端"列表与诊断面板都读它。
struct CandidateStatus: Equatable, Sendable {
    let endpoint: SurfEndpoint
    /// nil = 健康。
    let failure: ConnectFailure?
    /// 这一次 probe 花了多久（诊断用）。
    let elapsed: TimeInterval

    var isHealthy: Bool { failure == nil }
}

/// 壳的连接状态机：定位 → 并行探测 → 接入 → 盯着它别走。
///
/// **副作用不在这里**：装页面、连桥、盖/撤连接页三件事由
/// `MainWindowController` 通过 `onAttach` / `onDetach` / `onPhaseChange`
/// 三个回调接手。这个类只认得"端点"与"状态"，不认得 WebView 也不认得 AppKit。
@MainActor
@Observable
final class ConnectionController {

    // MARK: - 对外状态

    private(set) var phase: ConnectionPhase = .searching
    /// 此刻接着的那个端点。nil = 连接页在场。
    private(set) var activeEndpoint: SurfEndpoint?
    /// 最后一次接上的那个端点。**断连页要它**——那一页说的全是"刚才那个后端"
    /// 的事（地址、原因、断开于），而 `activeEndpoint` 那时已经放开了。
    private(set) var lastEndpoint: SurfEndpoint?
    /// 最近一轮并行探测的全部候选（含死的；页面只显示活的）。
    private(set) var candidates: [CandidateStatus] = []
    /// nil = 未设置。见 `ConnectionMode` 的注释：unset ≠ auto。
    private(set) var mode: ConnectionMode?
    private(set) var fixedURL: URL?

    /// 桥握手状态（由 `MainWindowController` 喂进来）。
    private(set) var bridgeConnected = false
    /// 页内桥 ready（同上）。
    private(set) var pageReady = false

    /// 本次连接是什么时候建立的（断连页的"此前已连接 N"）。
    private(set) var connectedSince: Date?
    /// 上一次连接持续了多久。
    private(set) var lastSessionDuration: TimeInterval?
    private(set) var disconnectedAt: Date?
    /// 掉线之后连着失败了几轮。连上就清零。
    private(set) var attempts = 0
    /// 最近一轮探测发生在什么时候（断连页的"下一次 N 秒后"由它推）。
    private(set) var lastAttemptAt: Date?
    /// 最近一次失败的分类。
    private(set) var lastFailure: ConnectFailure?

    /// 轮询周期。壳不是后端的父进程，拿不到退出信号，只能靠周期性 GET
    /// 发现它走了、也发现它回来了。
    static let pollInterval: TimeInterval = 2

    // MARK: - 对外回调（副作用交给壳）

    /// 选中了一个端点：装页面 + 连桥。
    var onAttach: ((SurfEndpoint) -> Void)?
    /// 放开当前端点：停桥、停加载。
    var onDetach: (() -> Void)?
    /// 幕变了：盖上/撤掉连接页、重画。
    var onPhaseChange: ((ConnectionPhase) -> Void)?

    // MARK: - 内部

    private let events: SurfEventBus
    private var timer: Timer?
    /// 整轮算一次在飞：并行探测之后"单飞"的单位从"一个候选"变成"一轮"，
    /// 轮与轮不叠罗汉（计划 §9）。
    private var roundInFlight = false

    /// 用户刚在页面上点的那个目标（一次性，不落偏好）。
    private var manualTarget: SurfEndpoint?
    /// 用户明确放弃过的目标：自动发现不再挑它们，否则"连接其他后端…"
    /// 会在下一轮轮询里被原样接回去。任何一次显式连接都清空这张表。
    private var abandoned: Set<URL> = []

    /// 桥握手连续被拒的计数与"判定为不兼容后端"的那个地址。
    /// 典型场景：用户手动连了 `dsh web`——HTTP 一切健康、页面也装得出来，
    /// 但那个 profile 里没有任何 surf 插件，桥永远 404。不判定的话 App 会
    /// 停在一个没有原生功能的裸页面上，且不报错（用户实测提出）。
    /// 阈值取 3 是给正常启动窗口留余地：dsh 起桥比起 HTTP 晚一拍是合法的。
    private var bridgeRejectStreak = 0
    private(set) var incompatibleBase: URL?

    /// 最近一次投影出去的载荷摘要，用来去重（轮询每 2s 打一次，值没变就别播）。
    private var lastProjection: String?

    // MARK: - UserDefaults（计划 §4）

    static let modeDefaultsKey = "surf.connection.mode"
    static let fixedURLDefaultsKey = "surf.connection.fixedURL"

    /// 没设过 `surf.connection.mode` 时用哪一档。**managed 而不是 unset**：
    /// 后端的生命周期该归壳管（起、监护、⌘Q 收走），不该要用户先在引导页上
    /// 点一下、更不该靠 launchd 那类壳够不着的外部常驻服务（见 `ConnectionMode`）。
    static let fallbackMode: ConnectionMode = .managed

    init(events: SurfEventBus) {
        self.events = events
        // **认不出来的值退到默认档**：这两个键用户手改得到，也可能是旧版本留下的。
        // 退 managed 不违背"别乱 attach"那条裁决——managed 接的是壳自己拉起来的
        // 那一个，不是本机随便一个端口（详见 `ConnectionMode` 的注释）。
        let rawMode = UserDefaults.standard.string(forKey: Self.modeDefaultsKey) ?? ""
        self.mode = ConnectionMode(rawValue: rawMode) ?? Self.fallbackMode
        self.fixedURL = Self.normalizedURL(from:
            UserDefaults.standard.string(forKey: Self.fixedURLDefaultsKey) ?? "")
    }

    // MARK: - 生命周期

    /// 装上轮询并立刻探一次。
    func start() {
        setPhase(.searching)
        guard timer == nil else { return }
        let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.probeNow() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        probeNow()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - 用户动作

    /// ⌘⇧R：忘掉当前端点，立刻重走定位。
    ///
    /// 连上过就落在断连页（原因 = 用户请求），没连上过就还是引导页那一幕转圈
    /// ——"从没连上"的人不该看到"已断开"。
    func reconnect() {
        let wasConnected = activeEndpoint != nil
        releaseEndpoint()
        if wasConnected {
            disconnectedAt = Date()
            setPhase(.disconnected(.userRequested))
        } else {
            setPhase(.searching)
        }
        probeNow()
    }

    /// 页面上点了某个后端的"连接"，或敲完地址回车。**一次性，不改偏好**
    /// （计划 §3：发现列表那一行点击"不改偏好"）。
    ///
    /// **不当场装页面**：先把它记成目标，探一轮再说。乐观接入的代价是
    /// 敲错一个地址就会白装一次页面、再掉进断连页——而它其实从没连上过。
    func connect(to endpoint: SurfEndpoint) {
        abandoned.removeAll()          // 显式动作 = 新的意图，之前放弃过的既往不咎
        incompatibleBase = nil
        bridgeRejectStreak = 0
        manualTarget = endpoint
        releaseEndpoint()
        setPhase(.searching)
        probeNow()
    }

    /// 引导页 URL 框回车。返回 false = 地址不成立（页面就地提示，不弹窗）。
    @discardableResult
    func connect(toURLString raw: String) -> Bool {
        guard let url = Self.normalizedURL(from: raw) else {
            Log.write("手动连接的地址不成立：\(raw)", to: SurfPaths.logURL, tag: "connection")
            return false
        }
        Log.write("手动连接：\(url.absoluteString)", to: SurfPaths.logURL, tag: "connection")
        connect(to: EndpointLocator.manualEndpoint(url, source: .manual))
        return true
    }

    /// 断连页的"连接其他后端…"：放弃当前目标，切回引导页的选择态。
    ///
    /// **必须记住"放弃过谁"**：不记的话下一轮轮询会把同一个端点原样接回来，
    /// 按钮看上去像没反应。
    func abandonTarget() {
        // **`lastEndpoint` 那一项不能少**：这个按钮长在断连页上，而那一页在场时
        // `activeEndpoint` 早就放开了——只看它的话什么都没记住，下一轮轮询
        // 又把同一个后端接回来。
        if let url = activeEndpoint?.httpBase ?? manualTarget?.httpBase ?? lastEndpoint?.httpBase {
            abandoned.insert(url)
        }
        if mode == .fixed, let fixedURL { abandoned.insert(fixedURL) }
        manualTarget = nil
        incompatibleBase = nil
        releaseEndpoint()
        setPhase(.idle)
        probeNow()
    }

    /// 切换连接偏好。传 nil = 清回未设置（引导页那枚"自动接入"取消勾选走这条）。
    func setMode(_ next: ConnectionMode?) {
        guard next != mode else { return }
        mode = next
        if let next {
            UserDefaults.standard.set(next.rawValue, forKey: Self.modeDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.modeDefaultsKey)
        }
        abandoned.removeAll()
        incompatibleBase = nil
        Log.write("连接模式切到 \(next?.rawValue ?? "unset")", to: SurfPaths.logURL, tag: "connection")
        probeNow()
    }

    /// "记住这个地址"：一次落两个键。引导页勾着「设为默认方式」再点连接走这条
    /// ——两个键得一起改，只改 mode 会钉向上一次的地址。
    func rememberFixed(_ url: URL) {
        setFixedURL(url.absoluteString)
        setMode(.fixed)
    }

    /// `fixed` 模式的目标。传 nil / 坏值 = 清掉。
    func setFixedURL(_ raw: String?) {
        let url = raw.flatMap { Self.normalizedURL(from: $0) }
        fixedURL = url
        if let url {
            UserDefaults.standard.set(url.absoluteString, forKey: Self.fixedURLDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.fixedURLDefaultsKey)
        }
        probeNow()
    }

    // MARK: - 桥那一侧喂进来的事实

    func noteBridge(connected: Bool) {
        bridgeConnected = connected
        guard let endpoint = activeEndpoint else { return }
        if connected {
            bridgeRejectStreak = 0
            incompatibleBase = nil
            setPhase(.connected(endpoint))
        } else if case .connected = phase {
            // **桥掉了不进断连幕**：HTTP 还活着说明后端在，桥自己会退避重连。
            // 断连与否只由健康探测说了算（与旧实现一致）。
            setPhase(.connecting(endpoint))
        }
    }

    func notePageReady(_ ready: Bool) {
        pageReady = ready
    }

    /// 桥握手失败/hello 超时。HTTP 探测多半还是绿的，所以这里只记分类，
    /// 不改幕——**除非连拒三次**：那说明这个后端根本没有 surf 桥（比如
    /// `dsh web`），再等下去就是把用户留在裸页面上（见 bridgeRejectStreak 注释）。
    func noteBridgeFailure(_ failure: BridgeClient.Failure) {
        switch failure {
        case .handshakeRejected, .helloTimeout:
            lastFailure = .bridgeRejected
            bridgeRejectStreak += 1
            if bridgeRejectStreak >= 3 { declareIncompatible() }
        case .connectionLost:
            break
        }
        projectState()
    }

    /// 判定当前后端不含 Surf 组件：放弃它、回引导页、把原因留在
    /// `.bridgeRejected` 上（页面据此附上正确的启动命令提示）。
    private func declareIncompatible() {
        guard let endpoint = activeEndpoint else { return }
        Log.write("桥连续被拒，判定后端不含 surf 组件：\(endpoint.summary)",
                  to: SurfPaths.logURL, tag: "connection")
        incompatibleBase = endpoint.httpBase
        abandoned.insert(endpoint.httpBase)   // 别在下一轮把它原样接回来
        bridgeRejectStreak = 0
        releaseEndpoint()
        setPhase(.unreachable(.bridgeRejected))
        probeNow()
    }

    // MARK: - 探测

    /// 探一轮。同一时刻只允许一轮在飞。
    func probeNow() {
        guard !roundInFlight else { return }
        roundInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let (best, statuses) = await self.probeRound()
            self.roundInFlight = false
            self.candidates = statuses
            self.apply(best)
        }
    }

    /// 一轮 = 目标（可能是手动/钉死的）+ 发现列表，一起并行探。
    /// 返回"该连谁"与"全部候选的健康态"。
    private func probeRound() async -> (SurfEndpoint?, [CandidateStatus]) {
        let targets = targetCandidates()
        // 发现列表始终要探：`fixed` 模式下页面上仍然显示它，点一下即临时改道
        // （计划 §4：别把用户锁死在一个死地址上）。
        var list = targets
        for disc in EndpointLocator.candidates()
        where !list.contains(where: { $0.httpBase == disc.httpBase }) {
            list.append(disc)
        }
        let statuses = await EndpointLocator.probeAll(list)
        // 只在"目标"那一段里选；发现列表在 fixed / 手动模式下只是展示。
        // **unset 时发现列表也只是展示**（§11.1）：探活照做、列表照显，
        // 但一个都不接——那一下由用户在引导页上点。
        let selectable: [CandidateStatus]
        if !targets.isEmpty {
            selectable = Array(statuses.prefix(targets.count))
        } else if adoptsDiscovered {
            selectable = statuses
        } else {
            selectable = []
        }
        let best = selectable.first {
            $0.isHealthy && !abandoned.contains($0.endpoint.httpBase)
        }?.endpoint
        return (best, statuses)
    }

    /// 这一刻的连接目标，按优先级排。空数组 = auto（发现列表本身就是目标）。
    ///
    /// **顺序**：用户刚点的一次性目标 > `--surf-endpoint` flag > 偏好模式。
    /// flag 压过偏好（它由拉起本进程的那个后端亲手递来，多 worktree 并存时
    /// 也只指向"我这一套"）；但压不过用户此刻手点的那一下——那不是偏好，
    /// 是一条当场的指令，否则界面上的"连接"按钮会看上去没反应。
    private func targetCandidates() -> [SurfEndpoint] {
        if let manualTarget { return [manualTarget] }
        if EndpointLocator.flagEndpoint() != nil { return [] }
        if mode == .fixed, let fixedURL {
            return [EndpointLocator.manualEndpoint(fixedURL, source: .fixed)]
        }
        return []
    }

    /// 发现列表里的候选能不能被自动接入。
    ///
    /// **flag 在这儿也算数**：`--surf-endpoint` 由拉起本进程的那个后端亲手递来，
    /// 它不是"本机随便一个端口"，语义上等同于一条当场的指令——`./dev` 的开发
    /// 循环因此完全不受 unset 影响（dev 壳总是带 flag 被拉起）。
    private var adoptsDiscovered: Bool {
        if mode == .auto || mode == .managed { return true }
        return EndpointLocator.flagEndpoint() != nil
    }

    /// 明确目标的地址（连接页那句"无法连接到 …"用它）。nil = 没有明确目标。
    var targetAddress: String? {
        if let manualTarget { return manualTarget.httpBase.absoluteString }
        if mode == .fixed, let fixedURL { return fixedURL.absoluteString }
        return nil
    }

    /// 有没有一个"明确目标"。有 = 连不上时如实报错（unreachable 幕），
    /// 没有 = 只是还没找到（idle 幕，照旧转圈等它出现）。
    private var hasExplicitTarget: Bool {
        if manualTarget != nil { return true }
        return mode == .fixed && fixedURL != nil
    }

    /// 把一轮探测的结果落成状态。四种去向：稳定、接入、换端点重接、断开。
    private func apply(_ found: SurfEndpoint?) {
        lastAttemptAt = Date()
        guard let found else {
            attempts += 1
            // 不兼容后端 HTTP 是健康的，firstFailure() 探不出东西——原因得留在
            // 桥那一层的判定上，否则界面会退回「连接被拒绝」这种错话。
            lastFailure = firstFailure() ?? (incompatibleBase != nil ? .bridgeRejected : nil)
            if activeEndpoint != nil {
                enterDisconnected(.processGone)
            } else if phase.isDisconnected {
                // **断连页要待着**：这一轮只是又一次没成的重连尝试，不是
                // "从没连上过"。不留住的话，掉线一秒后页面就会自己跳回引导页，
                // 而那一页说的是另一件事（实测过）。
                projectState()
            } else {
                setPhase(hasExplicitTarget ? .unreachable(lastFailure ?? .refused) : .idle)
                projectState()
            }
            return
        }
        attempts = 0
        lastFailure = nil
        guard found != activeEndpoint else {
            projectState()
            return
        }
        adopt(found, isReconnect: activeEndpoint != nil)
    }

    /// 目标那一段里的第一条失败原因（没有目标时取任意候选的）。
    private func firstFailure() -> ConnectFailure? {
        candidates.first(where: { !$0.isHealthy })?.failure
    }

    private func adopt(_ endpoint: SurfEndpoint, isReconnect: Bool) {
        activeEndpoint = endpoint
        lastEndpoint = endpoint
        connectedSince = Date()
        bridgeRejectStreak = 0
        // 日志一律中文（Strings.swift 顶注）：读它的是终端前的人和 agent，
        // 跟着界面语言变只会让排错时对不上账。
        Log.write("接入 dsh：\(endpoint.summary)，来源 \(endpoint.source.rawValue)"
                  + (endpoint.isOwn ? "" : " ⚠️ 不是本 worktree 那一套"),
                  to: SurfPaths.logURL, tag: "endpoint")
        if isReconnect {
            Log.write("端点变化，插件将随重连的桥重新对齐", to: SurfPaths.logURL, tag: "endpoint")
        }
        setPhase(.connecting(endpoint))
        onAttach?(endpoint)
    }

    private func enterDisconnected(_ reason: DisconnectReason) {
        guard activeEndpoint != nil else { return }
        Log.write("与 dsh 断开连接（\(reason)）", to: SurfPaths.logURL, tag: "endpoint")
        disconnectedAt = Date()
        releaseEndpoint()
        setPhase(.disconnected(reason))
    }

    /// 放开当前端点（停桥、停加载归壳），只动自己这边的账。
    private func releaseEndpoint() {
        if let since = connectedSince, activeEndpoint != nil {
            lastSessionDuration = Date().timeIntervalSince(since)
        }
        connectedSince = nil
        activeEndpoint = nil
        bridgeConnected = false
        pageReady = false
        onDetach?()
    }

    private func setPhase(_ next: ConnectionPhase) {
        guard next != phase else {
            projectState()
            return
        }
        phase = next
        Log.write("连接状态：\(next.key)", to: SurfPaths.logURL, tag: "connection")
        onPhaseChange?(next)
        projectState()
    }

    // MARK: - 对插件的投影

    /// 粘性主题 `surf.connection.state`。**状态型消息一律 emitSticky**
    /// （壳的家规）：插件必然晚于壳启动，不粘的话它要等到下一次状态变化
    /// 才知道此刻连着谁，而那个状态可能一直不变。
    static let stateTopic = "surf.connection.state"

    private func projectState() {
        var payload: [String: Any] = [
            "phase": phase.key,
            // **未设置也要有个值**：订阅者拿字符串比对，缺键与 "unset" 是两件事。
            "mode": mode?.rawValue ?? "unset",
            // `managed` 与 `url` 是给 surf-settings 那一栏的"当前连接"行用的
            // ——它 import 不了壳里的类型，只能读字符串与布尔。
            "managed": mode == .managed,
            "attempts": attempts,
            "bridgeConnected": bridgeConnected,
            "pageReady": pageReady,
        ]
        // 此刻**生效中**的偏好（不是 UserDefaults 里那份）：设置页拿它跟盘上的值
        // 比对，不一致就是"改了还没重启"，那颗 [立即重启] 按钮据此出现。
        if let fixedURL { payload["fixedURL"] = fixedURL.absoluteString }
        if let activeEndpoint {
            payload["url"] = activeEndpoint.httpBase.absoluteString
            payload["endpoint"] = activeEndpoint.httpBase.absoluteString
            payload["endpointSource"] = activeEndpoint.source.rawValue
            payload["isOwn"] = activeEndpoint.isOwn
        }
        if case .disconnected(let reason) = phase {
            payload["reason"] = String(describing: reason)
        }
        if let lastFailure {
            payload["failure"] = Self.failureKey(lastFailure)
            if case .httpError(let code) = lastFailure { payload["statusCode"] = code }
        }
        payload["candidates"] = candidates.map { status -> [String: Any] in
            var row: [String: Any] = [
                "url": status.endpoint.httpBase.absoluteString,
                "healthy": status.isHealthy,
                "source": status.endpoint.source.rawValue,
            ]
            if let port = status.endpoint.port { row["port"] = port }
            if let startedAt = status.endpoint.startedAt { row["startedAt"] = startedAt }
            if let failure = status.failure { row["failure"] = Self.failureKey(failure) }
            return row
        }
        // 轮询每 2s 打一轮，值没变就别播——总线是同步派发，订阅者不该被
        // 一份没变化的载荷叫醒。
        let digest = String(describing: payload as NSDictionary)
        guard digest != lastProjection else { return }
        lastProjection = digest
        events.emitSticky(Self.stateTopic, payload)
    }

    static func failureKey(_ failure: ConnectFailure) -> String {
        switch failure {
        case .refused: return "refused"
        case .timeout: return "timeout"
        case .httpError: return "httpError"
        case .bridgeRejected: return "bridgeRejected"
        }
    }

    // MARK: - 地址规范化

    /// 用户敲进来的东西 → 一个能连的 URL。
    ///
    /// 三条（计划裁决③）：裸端口号补成 `http://127.0.0.1:<port>`；
    /// 没写 scheme 的补 `http://`；**只认 http / https**——
    /// 别的 scheme 一律不成立（页面里的地址等同不可信输入，家规）。
    static func normalizedURL(from raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // 裸端口号
        if text.allSatisfy({ $0.isNumber }), let port = Int(text), (1...65535).contains(port) {
            return URL(string: "http://127.0.0.1:\(port)")
        }
        let withScheme = text.contains("://") ? text : "http://" + text
        guard let url = URL(string: withScheme),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}
