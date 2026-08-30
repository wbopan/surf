import AppKit
import SwiftUI

/// 没连上后端时铺满窗口的那一层：**两页**（`docs/clam-connection-plan.md` §3）。
///
/// - **引导连接页**（searching / idle / unreachable / connecting）：托管卡 +
///   手动地址卡 + 发现的后端列表。
/// - **连接中断页**（disconnected）：纯诊断五行 + 一个"连接其他后端…"。
///
/// 三条实现口径（用户裁决，全部强制）：面向最终用户（界面上没有 ./dev、
/// worktree、profile、pid、hash——那些只活在 ⌥⌘D 与日志里）；文案贴系统 App
/// 的密度且逐字来自设计稿；**优先 Apple 原生符号与样式**——SF Symbols 而不是
/// 自绘路径，语义色（`.primary` / `.secondary` / `.quinary` / `separatorColor`）
/// 而不是抄设计稿的 hex（那些 hex 只是这些语义色的浅色快照），能用系统控件就
/// 不做自定义视图。深浅色因此自动成立。
@MainActor
final class ConnectionViewController: NSViewController {

    private let connection: ConnectionController
    private let backend: BackendManager
    private let actions: ConnectionActions
    private var hosting: NSHostingController<ConnectionScreen>!

    init(connection: ConnectionController, backend: BackendManager, strings: L,
         actions: ConnectionActions) {
        self.connection = connection
        self.backend = backend
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
        hosting = NSHostingController(rootView: makeScreen(strings: strings))
        // **别让它上报 preferredContentSize**：这一层是覆盖层，尺寸由约束说了算；
        // 默认的 `.preferredContentSize` 会让宿主把自己的 fitting size 顶给窗口。
        hosting.sizingOptions = []
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func makeScreen(strings: L) -> ConnectionScreen {
        ConnectionScreen(strings: strings, connection: connection,
                         backend: backend, actions: actions)
    }

    /// 语言变了：换一份文案重画。状态照旧由 `@Observable` 自己推。
    func apply(strings: L) {
        hosting.rootView = makeScreen(strings: strings)
    }

    override func loadView() {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        #if DEBUG
        // Dev 构建：背景加淡橙色斜纹水印，连接页即区分 Debug/Release。
        let stripe = DevStripeView()
        stripe.frame = view.bounds
        stripe.autoresizingMask = [.width, .height]
        view.addSubview(stripe)
        #endif
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(hosting)
        let content = hosting.view
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }
}

/// 连接页能发起的动作。**全部是闭包**：这一层不认得 WebView、不认得桥，
/// 也不该认得——它只管画，动手归 `MainWindowController`。
struct ConnectionActions {
    /// 第二个参数 = 「设为默认方式」勾着没有：勾着就把这个地址落成 `fixed` 偏好。
    var connect: (ClamEndpoint, Bool) -> Void = { _, _ in }
    /// 返回 false = 地址不成立，页面就地标红（不弹窗）。第二个参数同上。
    var submitAddress: (String, Bool) -> Bool = { _, _ in false }
    /// 面板底部那枚「自动接入发现的后端」：true = `auto`，false = 清回未设置。
    var setAutoAdopt: (Bool) -> Void = { _ in }
    var startManaged: () -> Void = {}
    var stopManaged: () -> Void = {}
    var chooseOther: () -> Void = {}
    var openDiagnostics: () -> Void = {}
    var openLogs: () -> Void = {}
}

#if DEBUG
/// 淡橙色斜纹平铺层，铺满连接页背景（Dev 构建标记）。
private final class DevStripeView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let tile = CGSize(width: 12, height: 12)
        let image = NSImage(size: tile)
        image.lockFocusFlipped(false)
        NSColor.systemOrange.withAlphaComponent(0.10).setFill()
        for offset in [CGFloat(-6), 0] {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: offset, y: 0))
            p.line(to: NSPoint(x: offset + 6, y: 12))
            p.line(to: NSPoint(x: offset + 12, y: 12))
            p.line(to: NSPoint(x: offset + 6, y: 0))
            p.close()
            p.fill()
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let cg = rep.cgImage,
              let pattern = CGPattern(image: cg,
                                      contentRect: CGRect(origin: .zero, size: tile),
                                      matrix: .identity,
                                      xStep: tile.width, yStep: tile.height,
                                      tiling: .constantSpacingMinimalDistortion,
                                      isColored: true),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        ctx.saveGState()
        ctx.setFillColor(CGColor(pattern: pattern, colorSpace: space, components: [1, 1, 1, 1]))
        ctx.fill(bounds)
        ctx.restoreGState()
    }
}
#endif

// MARK: - SF Symbols

/// 页面用到的符号名。**先查这台机器上有没有，再用**——`Image(systemName:)`
/// 撞上不存在的名字是静默的（画一片空白），而符号名随系统版本增删。
@MainActor
private enum ConnSymbol {
    static func first(_ names: String...) -> String {
        for name in names
        where NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil {
            return name
        }
        return names.last ?? "questionmark"
    }

    static let notConnected = first("wifi.slash")
    static let interrupted = first("cable.connector.slash", "powerplug.slash",
                                   "bolt.horizontal.circle", "exclamationmark.triangle")
    static let managed = first("play.circle", "play.circle.fill")
    static let manual = first("link", "network")
}

// MARK: - 页面

struct ConnectionScreen: View {
    let strings: L
    let connection: ConnectionController
    let backend: BackendManager
    let actions: ConnectionActions

    var body: some View {
        Group {
            if connection.phase.isDisconnected {
                InterruptedPage(strings: strings, connection: connection, actions: actions)
            } else {
                OnboardingPage(strings: strings, connection: connection,
                               backend: backend, actions: actions)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - 引导连接页

/// 上下布局（M7 §11.3，画板 `Onboarding.dc.html`）：
/// 上 = 托管横条卡，下 = 「连接到已有的后端」一整个面板。
///
/// **为什么合并成一个面板**：地址输入与发现列表本来就是同一种方式（接入一个
/// 已经在跑的后端），拆成两张并排的卡片时用户得先在两张卡之间选一次，
/// 而那个选择没有意义。
private struct OnboardingPage: View {
    let strings: L
    let connection: ConnectionController
    let backend: BackendManager
    let actions: ConnectionActions

    @State private var address = ""
    @State private var addressInvalid = false

    /// 「设为默认方式」。**默认勾上**：unset 语义下不落盘就意味着下次打开又停在
    /// 这一屏，而用户刚刚已经明确挑过一个后端了。定稿画板里它也是勾着的。
    @State private var remember = true

    /// 只显示活着的候选：死的那些是排错信息，归 ⌥⌘D。
    /// 已判定"不含 Surfclam 组件"的也滤掉——它 HTTP 上是绿的，挂着「连接」
    /// 按钮会和上方"缺组件"的结论打架，点了也只会再判定一次。
    private var healthy: [CandidateStatus] {
        connection.candidates.filter {
            $0.isHealthy && $0.endpoint.httpBase != connection.incompatibleBase
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            header
            managedCard
            joinPanel
            rememberBox
            ConnFooter(strings: strings, actions: actions)
        }
        .frame(maxWidth: 560)
        .padding(.top, 68)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var header: some View {
        VStack(spacing: 9) {
            ConnBadge(symbol: ConnSymbol.notConnected, diameter: 56, iconSize: 26,
                      tint: Color.secondary)
            Text(strings.connIdleTitle)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.primary)
            // 扫描那一行搬进了面板里的发现小节（整屏只留一处转圈）；这里只剩
            // "有明确目标却连不上"那句事实——它说的是别的事，没地方可去。
            if case .unreachable(let failure) = connection.phase { unreachableLine(failure) }
        }
    }

    private func unreachableLine(_ failure: ConnectFailure) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(nsColor: .systemOrange))
                    .frame(width: 8, height: 8)
                Text(ConnFormat.unreachable(connection: connection, failure: failure,
                                            strings: strings))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            // 缺组件时把正确的启动命令递到眼前——这是用户唯一能自救的动作。
            if case .bridgeRejected = failure {
                (Text(strings.connProfileHintPrefix)
                    + Text(strings.connProfileCommand)
                        .font(.system(size: 12, design: .monospaced))
                    + Text(strings.connProfileHintSuffix))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 上：托管

    private var managedCard: some View {
        ConnPanel {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: ConnSymbol.managed)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(strings.connManagedCardTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                    // 说明与状态**同一格**：没起来时说它是干什么的，起来之后说它在
                    // 干什么。两行都常驻的话这张横条会比下面整个面板还高。
                    Text(ConnFormat.managedNote(backend.state, strings: strings)
                         ?? strings.connManagedCardDetail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if backend.state.isActive {
                    Button(strings.connManagedStop) { actions.stopManaged() }
                } else {
                    Button(strings.connManagedStart) { actions.startManaged() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!backend.state.canStart)
                }
            }
        }
    }

    // MARK: 下：连接到已有的后端

    private var joinPanel: some View {
        ConnPanel {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 12) {
                    Image(systemName: ConnSymbol.manual)
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(.secondary)
                    Text(strings.connManualCardTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        TextField("", text: $address,
                                  prompt: Text(strings.connManualPlaceholder))
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.large)
                            .onSubmit { submit() }
                            .onChange(of: address) { addressInvalid = false }
                        Button(strings.connConnect) { submit() }
                            .controlSize(.large)
                            .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if addressInvalid {
                        Text(strings.connManualInvalid)
                            .font(.system(size: 11))
                            .foregroundStyle(Color(nsColor: .systemRed))
                    }
                }
                discovered
                // 这枚勾是 `mode == auto` 的**直接投影**，不是本地状态：
                // 勾上当场落偏好并接入，取消清回未设置（§11.3）。
                Toggle(strings.connAutoAdopt, isOn: Binding(
                    get: { connection.mode == .auto },
                    set: { actions.setAutoAdopt($0) }))
                    .toggleStyle(.checkbox)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func submit() {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        addressInvalid = !actions.submitAddress(text, remember)
    }

    private var discovered: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(strings.connDiscoveredHeader)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                // 轮询是常驻的，所以这一行也常驻——它说的是"还在找"，
                // 不是某一次动作的进度。
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 12, height: 12)
                Text(strings.connSearchingShort)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 6)
            // 空列表不画那个圆角框：一个空盒子看上去像"坏了"，而这一刻的事实
            // 只是"还没找到"——上面那行已经把它说清楚了。
            if !healthy.isEmpty {
                ConnRows {
                    ForEach(Array(healthy.enumerated()), id: \.offset) { index, status in
                        if index > 0 { Divider() }
                        row(for: status.endpoint)
                    }
                }
            }
        }
    }

    private func row(for endpoint: ClamEndpoint) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(nsColor: .systemGreen))
                .frame(width: 8, height: 8)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(ConnFormat.portLabel(endpoint, strings: strings))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                if let started = ConnFormat.startedAt(endpoint, strings: strings) {
                    Text(started)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button(strings.connConnect) { actions.connect(endpoint, remember) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 40)
    }

    // MARK: 面板下方：设为默认方式

    /// **托管卡不受这枚勾影响**：开启托管本就必须落偏好，不然"打开即有后端"
    /// 只兑现一次（M4 接线注记）。所以这里说的是"这一次的连接动作"。
    private var rememberBox: some View {
        HStack(spacing: 7) {
            Toggle(strings.connRememberDefault, isOn: $remember)
                .toggleStyle(.checkbox)
            Text(strings.connRememberDefaultHint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - 连接中断页

private struct InterruptedPage: View {
    let strings: L
    let connection: ConnectionController
    let actions: ConnectionActions

    var body: some View {
        VStack(spacing: 24) {
            header
            diagnostics
            HStack {
                Spacer()
                Button(strings.connChooseOther) { actions.chooseOther() }
                Spacer()
            }
            ConnFooter(strings: strings, actions: actions)
        }
        .frame(maxWidth: 560)
        .padding(.top, 108)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var header: some View {
        VStack(spacing: 8) {
            ConnBadge(symbol: ConnSymbol.interrupted, diameter: 44, iconSize: 21,
                      tint: Color(nsColor: .systemOrange),
                      fill: Color(nsColor: .systemOrange).opacity(0.14))
            Text(strings.connDisconnectedTitle)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(strings.connReconnecting)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(strings.connSectionDiagnostics)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.bottom, 6)
            ConnRows {
                labelRow(strings.connRowBackend) {
                    Text(ConnFormat.backendLabel(connection: connection, strings: strings))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Divider()
                labelRow(strings.connRowAddress) {
                    Text(connection.lastEndpoint?.httpBase.absoluteString ?? "—")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Divider()
                labelRow(strings.connRowReason) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color(nsColor: .systemOrange))
                            .frame(width: 8, height: 8)
                        Text(ConnFormat.reason(connection: connection, strings: strings))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
                Divider()
                labelRow(strings.connRowDisconnectedAt) {
                    Text(ConnFormat.disconnectedAt(connection: connection, strings: strings))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Divider()
                labelRow(strings.connRowRetry) {
                    // 倒计时得自己走：状态机每 2s 才动一次，靠它推的话
                    // "下一次 N 秒后"会一直停在 2。
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(strings.connRetryStatus(
                            attempts: connection.attempts,
                            nextIn: ConnFormat.nextRetryIn(connection: connection,
                                                           now: context.date)))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func labelRow<Value: View>(_ label: String,
                                       @ViewBuilder value: () -> Value) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            value()
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }
}

// MARK: - 复用件

/// 圆形图标徽章。
private struct ConnBadge: View {
    let symbol: String
    let diameter: CGFloat
    let iconSize: CGFloat
    let tint: Color
    /// 缺省是一层极淡的中性底（语义色，深浅色自动成立）。
    var fill: Color = Color(nsColor: .quaternaryLabelColor).opacity(0.4)

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: iconSize, weight: .regular))
            .foregroundStyle(tint)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(fill))
    }
}

/// 一块内嵌面板：淡底 + 细边 + 内边距。引导页的托管横条与「连接到已有的后端」
/// 用的是同一块（`ConnRows` 是它的无内边距、带行分隔线的兄弟）。
private struct ConnPanel<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6))
            )
    }
}

/// 圆角容器 + 行间分隔线（发现列表与诊断表共用）。
private struct ConnRows<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6))
            )
    }
}

/// 两页共用的页脚：诊断面板 · 打开日志目录。
private struct ConnFooter: View {
    let strings: L
    let actions: ConnectionActions

    var body: some View {
        HStack(spacing: 10) {
            Button(strings.connFooterDiagnostics) { actions.openDiagnostics() }
                .buttonStyle(.link)
            Text("·")
                .foregroundStyle(.tertiary)
            Button(strings.connFooterLogs) { actions.openLogs() }
                .buttonStyle(.link)
        }
        .font(.system(size: 11))
    }
}

// MARK: - 取值与格式化

/// 状态 → 界面上那句话。**全部经 `L`**：这里一个中文字面量都不写。
@MainActor
private enum ConnFormat {

    static func locale(_ strings: L) -> Locale {
        Locale(identifier: strings.locale == .zh ? "zh-Hans" : "en-US")
    }

    static func portLabel(_ endpoint: ClamEndpoint, strings: L) -> String {
        // 没有端口号（默认端口）就退到主机名——总得有个称呼。
        guard let port = endpoint.port else { return endpoint.httpBase.host ?? "—" }
        return strings.connPort(port)
    }

    /// "30 分钟前启动" / "昨天 20:14 启动"。拿不到启动时刻就不显示这一段。
    static func startedAt(_ endpoint: ClamEndpoint, strings: L) -> String? {
        guard let date = endpoint.startedAtDate else { return nil }
        let now = Date()
        let moment: String
        if now.timeIntervalSince(date) < 24 * 3600 {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = locale(strings)
            formatter.unitsStyle = .full
            moment = formatter.localizedString(for: date, relativeTo: now)
        } else {
            moment = dayAndTime(date, strings: strings)
        }
        return strings.connStartedAt(moment)
    }

    /// "今天 14:32" / "昨天 20:14"（系统自己的相对日期格式）。
    static func dayAndTime(_ date: Date, strings: L) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale(strings)
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func duration(_ seconds: TimeInterval, strings: L) -> String? {
        guard seconds >= 1 else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.calendar?.locale = locale(strings)
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = seconds < 60 ? [.second] : [.hour, .minute]
        return formatter.string(from: seconds)
    }

    static func backendLabel(connection: ConnectionController, strings: L) -> String {
        guard let host = connection.lastEndpoint?.httpBase.host else { return strings.connBackendLocal }
        let isLocal = host == "127.0.0.1" || host == "localhost" || host == "::1"
        guard isLocal else { return strings.connBackendRemote(host) }
        return connection.mode == .managed ? strings.connBackendManaged : strings.connBackendLocal
    }

    /// `short` = 还没连上过的场合（引导页那一行）。**"后端进程已退出"只在
    /// 断连页成立**——那一页说的是"刚才还连着的那个"，引导页说的是"从没连上"。
    static func failureText(_ failure: ConnectFailure, strings: L, short: Bool = false) -> String {
        switch failure {
        case .refused: return short ? strings.connReasonRefusedShort : strings.connReasonRefused
        case .timeout: return strings.connReasonTimeout
        case .httpError(let code): return strings.connReasonHTTP(code)
        case .bridgeRejected: return strings.connReasonBridge
        }
    }

    static func reason(connection: ConnectionController, strings: L) -> String {
        if case .disconnected(.userRequested) = connection.phase {
            return strings.connReasonUserRequested
        }
        if let failure = connection.lastFailure {
            return failureText(failure, strings: strings)
        }
        // 后端干净退出会删掉 endpoint 文件，重试轮无候选、产不出 ConnectFailure；
        // 这时 DisconnectReason 才是仅有的（也是准确的）原因来源。
        if case .disconnected(.processGone) = connection.phase {
            return strings.connReasonProcessGone
        }
        if case .disconnected(.bridgeLost) = connection.phase {
            return strings.connReasonBridgeLost
        }
        return strings.connReasonUnknown
    }

    static func unreachable(connection: ConnectionController, failure: ConnectFailure,
                            strings: L) -> String {
        let address = connection.targetAddress ?? connection.lastEndpoint?.httpBase.absoluteString ?? ""
        let head = address.isEmpty ? strings.connIdleTitle : strings.connUnreachable(address)
        return head + " · " + failureText(failure, strings: strings, short: true)
    }

    static func disconnectedAt(connection: ConnectionController, strings: L) -> String {
        guard let at = connection.disconnectedAt else { return "—" }
        let previous = connection.lastSessionDuration.flatMap { duration($0, strings: strings) }
        return strings.connDisconnectedAt(dayAndTime(at, strings: strings), previous: previous)
    }

    /// 下一轮探测还有几秒。轮询周期固定，倒计时由界面自己走。
    static func nextRetryIn(connection: ConnectionController, now: Date) -> Int {
        guard let last = connection.lastAttemptAt else { return Int(ConnectionController.pollInterval) }
        let remaining = ConnectionController.pollInterval - now.timeIntervalSince(last)
        return max(0, Int(remaining.rounded(.up)))
    }

    /// 托管卡里那一行状态。`.idle` 时不显示（卡片的说明已经讲清楚了）。
    static func managedNote(_ state: BackendManager.State, strings: L) -> String? {
        switch state {
        case .idle: return nil
        case .starting: return strings.connManagedStarting
        case .running: return strings.connManagedRunning
        case .retrying(let attempt): return strings.connManagedRetrying(attempt)
        case .gaveUp: return strings.connManagedGaveUp
        case .unavailable(.missingRuntime): return strings.connManagedNoRuntime
        case .unavailable(.externalBackend): return strings.connManagedExternal
        case .unavailable(.externalBackendUnreachable): return strings.connManagedExternalUnreachable
        case .unavailable(.launchFailed): return strings.connManagedFailed
        }
    }
}
