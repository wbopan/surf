import AppKit
import ClamSDK
import SwiftUI
import WebKit

/// 顶部透明拖拽条：命中后整窗可拖，
/// 弥补 fullSizeContentView 下原生标题栏被 WebView 盖住、无拖拽区的问题。
/// 用 `performDrag(with:)`（标题栏内部同款 API）手动发起拖拽，
/// 比只靠 `mouseDownCanMoveWindow` 更可靠（后者在该窗口形态下实测不生效）。
private final class WindowDragRegionView: NSView {
    /// 页面上报的「这里有个可点的东西，别当拖窗」矩形表。
    /// 坐标是**页面 CSS px、视口左上为原点**——换算成本地坐标是 `pagePoint` 的事，
    /// 页面那边因此不需要知道 WebView 在窗口里的位置，也不需要知道 pageZoom。
    /// 空表 = 整条带子照旧全是拖动区（页面没上报、壳没连页面、插件缺席都落在这儿）。
    var passthroughRects: [NSRect] = []

    /// superview 坐标的点 → 页面 CSS px 坐标。返回 nil = 这个点根本不在页面上。
    /// 由 `MainWindowController` 装上（它才拿得到 WKWebView）。
    var pagePoint: ((NSPoint) -> NSPoint?)?

    /// **放行才是这块视图存在的代价**：它盖在 WebView 上，不覆写 hitTest 的话
    /// 网页顶部 40pt 里的一切点击都变成拖窗（新 header 的三枚胶囊正在 y=8–44）。
    /// 命中任一上报矩形就 `return nil` 把这一下让给底下的 WebView；
    /// 其余空地照旧归自己 → 拖窗与双击放大一点没变。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil else { return nil }
        if !passthroughRects.isEmpty, let p = pagePoint?(point) {
            for rect in passthroughRects where rect.contains(p) { return nil }
        }
        return self
    }

    override var mouseDownCanMoveWindow: Bool { true }
    /// 窗口非激活时第一次点击也直接拖拽（与原生标题栏手感一致）。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        // 双击标题栏 = 缩放（最大化/还原），与原生标题栏一致。
        if event.clickCount >= 2 {
            window?.performZoom(nil)
            return
        }
        window?.performDrag(with: event)
    }
}

/// WKScriptMessageHandler 的弱引用代理：userContentController.add 会强持有
/// handler，直接传 self（NSWindowController）会造成引用循环。
private final class WKScriptMessageHandlerProxy: NSObject, WKScriptMessageHandler {
    weak var target: MainWindowController?
    init(_ target: MainWindowController) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.handleBridgeMessage(message)
    }
}

/// 主窗口。M5 起壳只剩窗口与 root 槽：
/// 布局、分栏、侧边栏装配全部搬进 clam-layout 插件，这里负责
/// "定位 dsh、连桥、把 root 槽的视图挂上去、没人占 root 时兜底全出血 WebView"。
@MainActor
final class MainWindowController: NSWindowController, WKNavigationDelegate, NSWindowDelegate {

    /// 窗口最小宽度。sidebar 的自适应折叠归 clam-layout 管，
    /// 这里只兜住"折叠之后窗口还能多窄"。
    static let contentMinWidth: CGFloat = 432

    /// 默认窗口大小（按屏幕可见区域收缩后应用，之后由 autosave 记忆）。
    static let defaultWindowSize = NSSize(width: 1200, height: 800)

    /// 窗口 frame / 分隔条宽度的 autosave key。AppKit 的记忆会盖住代码里的
    /// 默认值，调整默认值时需换 key 才能对已有用户生效。
    private static let windowAutosaveName = "ClamMainWindow.v1"

    /// 启动时的目标窗口 frame（默认或 autosave 恢复值）。赋
    /// contentViewController / 插入侧边栏项时 AppKit 会把窗口收缩成内容
    /// fitting size（连 autosave 恢复的 frame 都保不住），布局跑完后用它
    /// 断言拉回；有用户记忆时记忆值优先。
    private var launchWindowFrame: NSRect = .zero

    /// 显式连接状态机（`Native/ConnectionController.swift`）。**"我此刻连着谁"
    /// 的唯一真相在它那儿**，壳这边只是消费者：装页面、连桥、盖/撤连接页。
    private lazy var connection = ConnectionController(events: nativeHost.events)

    /// 托管后端（`Native/BackendManager.swift`）。AppDelegate 持有并递进来——
    /// 它得活得和进程一样久，而窗口是可以关掉的。
    let backend: BackendManager

    /// 原生插件宿主：桥 ↔ 编译机 ↔ 装载器 ↔ registry。壳对插件世界的全部认知都在它那儿。
    let nativeHost = NativePluginHost()

    /// 窗口内容容器：root 宿主 / 顶部拖拽条 / 按需的引导页，三层叠在这里。
    private let containerController = NSViewController()
    /// root 槽的宿主。它内部自己在"插件视图"与"全出血 WebView 兜底"之间切换，
    /// 所以整个 App 生命周期只装配一次。
    private lazy var rootHostingController = NSHostingController(
        rootView: ShellRootView(registry: nativeHost.registry, webView: webView))

    /// 上次载入页面时用的那份 URL 查询参数。插件说要别的了就重载一次页面
    /// （§7.2 第一版接受"切换需重载页面"）。

    // 顶部拖拽条高度：比标准标题栏（28pt）更高更好抓，
    // 只管拖拽，不再与网页内容对齐：原生分栏接管排版后，WebView 装在分栏右侧，
    // 网页侧边栏够不着标题栏区域（旧的 clam-nativeify topInset 让位已随之删除）。
    static let titleBarHeight: CGFloat = 40

    private let titleBarDragView = WindowDragRegionView() // 顶部可拖拽条

    /// 桥 ready 监视（8s 超时 → 只记日志；不再回退网页侧边栏模式）。
    private var bridgeReady = false
    private var bridgeWarnWork: DispatchWorkItem?
    private let bridgeReadyTimeout: TimeInterval = 8

    /// 连接页（覆盖层）。nil = 没盖着，也就是连上了。
    private var connectionVC: ConnectionViewController?

    private var diagnosticsPanel: DiagnosticsPanel?

    private var shortcutsPanel: ShortcutsPanel?

    /// 此刻装在菜单上的那份键位表。它是 `commands`（默认键位）与 `keymapValues`
    /// （设置里的覆盖）算出来的，两个输入哪个变了都重算（见 `resolveKeymap`）。
    private var activeKeymap = Keymap.default

    /// 插件声明的命令。启动时空的——第一份桥 snapshot 到了才有。
    private var commands: [ClamCommand] = []

    /// 设置里那份键位覆盖的原文（`clam-shortcuts` 经页面投影过来）。
    /// **要存原文而不是解析结果**：命令表晚于它到达时得能拿它重算一次。
    private var keymapValues: [String: String] = [:]

    /// 键位订阅句柄。**必须有人接住**：`ClamDisposable` 在 deinit 里就把订阅撤了，
    /// 不存下来等于订完当场退订——不报错、不打日志，只是键位设置永远不生效。
    private var keymapSubscription: ClamDisposable?

    /// 页面查询参数的订阅句柄。同上，不接住就等于没订。
    private var webQuerySubscription: ClamDisposable?
    private var relaunchSubscription: ClamDisposable?

    /// 壳有新版时右上角那条浮动提示（clam-app v1 播报，§7.5）。
    /// 用户点"稍后"就收起，直到下一次播报——不缠人。
    private var updateBanner: ShellUpdateBanner?

    /// 右上角提示区：壳更新提示条与一次性浮条竖着排，谁也别盖谁。
    private lazy var bannerStack: NSStackView = {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = containerController.view
        content.addSubview(stack, positioned: .above, relativeTo: nil)
        // 贴着拖拽条下沿的右上角：底部是网页的输入框与发送按钮，盖不得。
        NSLayoutConstraint.activate([
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor,
                                       constant: MainWindowController.titleBarHeight + 8),
        ])
        return stack
    }()

    /// 导航策略与下载（Native/WebPolicy.swift）。同源判定要现取 endpoint：
    /// 壳会重连、会换端口，快照会把重连后的自家页面误判成外链。
    /// 文案同理现取（用户可能在下载途中换语言）。
    private lazy var webPolicy = WebPolicy(
        currentEndpoint: { [weak self] in self?.connection.activeEndpoint },
        currentStrings: { [weak self] in self?.strings ?? L(.en) },
        presentToast: { [weak self] content in self?.presentToast(content) })

    // MARK: - WebView

    private lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        // UA 追加 "Clam/<version>"（带斜杠，防 "clam" 作为普通子串误命中）：
        // clam-nativeify / clam-layout 的 client 半边以此判断页面运行在壳内（终端 dsh web /
        // 普通浏览器共用同一 profile，不受影响）。
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        config.applicationNameForUserAgent = "Clam/\(shortVersion)"
        // 网页 → 原生通道：插件 v2 桥（ready / currentSession 上报）
        config.userContentController.add(WKScriptMessageHandlerProxy(self), name: "clam")
        applyAppearancePreferences(config.preferences)
        // 用子类而不是 WKWebView：它覆写 willOpenMenu，把右键菜单里 Reload /
        // 前进后退 / 在新窗口打开这类浏览器味的导航项裁掉（Native/ClamWebView.swift）。
        let wv = ClamWebView(frame: .zero, configuration: config)
        wv.setValue(false, forKey: "drawsBackground") // 透明 WebView
        wv.underPageBackgroundColor = .clear
        wv.navigationDelegate = self
        // 下载 / 外链 / 新窗口全在 uiDelegate 与导航策略里，不设 = WebKit 静默丢弃
        // （详见 Native/WebPolicy.swift 顶注）。
        wv.uiDelegate = webPolicy
        wv.allowsMagnification = true
        #if DEBUG
        // Safari → 开发 → 本机 里能开 Inspector。调材质/查 computed style 必备。
        // 只在 Debug 开：Release 里开着等于把整个页面交给任何人翻，
        // 而且 WebKit 的右键菜单只有 inspectable 时才加 Inspect Element。
        wv.isInspectable = true
        #endif
        // 主 frame 橡皮筋不在原生侧处理：页面滚动由插件注入的
        // overflow:hidden + overscroll-behavior 控制（页面本就不可滚动，
        // 触摸板过度滚动残留的 elastic 拉伸可接受）。曾试过 SPI
        // _setRubberBandingEnabled: 全关四边，会在底部滚动时引发内容闪动。

        // 恢复上次的页面缩放：pageZoom 是 WebView 实例属性，重载页面不会丢，
        // 但换进程会——所以自己记一份。设在 load 之前，首帧就是对的。
        wv.pageZoom = MainWindowController.rememberedPageZoom
        return wv
    }()

    /// 两个 WebKit 私有偏好开关，都带 `responds(to:)` 守卫，探测失败就静默跳过。
    ///
    /// **为什么敢用私有 API**：本仓库不上架、ad-hoc 签名（计划 §0.2）。风险只剩
    /// WebKit 升级改名，而**两个开关的失效方向都是安全的**——
    ///
    /// - `useSystemAppearance` 打开的是 `-apple-visual-effect` 那组平台钩子
    ///   （真材质、系统 vibrancy）。没打开时页面侧 `@supports
    ///   (-apple-visual-effect: …)` 探测为假，clam-nativeify 的手绘玻璃栈照常生效。
    ///   实测这是干脆的全有全无：关着时 `CSS.supports` 九个值全 false、
    ///   computed 回读成空串，材质层什么都不画（docs/spikes/apple-visual-effect）。
    ///   所以两层探测各自独立降级，谁失效都不会留下"画了一半"的表面。
    /// - `shouldAllowUserInstalledFonts` 关掉用户自装字体（手册 §1.4）。dsh 走的是
    ///   `-apple-system` 系统字体栈，用户装了同名字体会把正文渲染换掉。
    ///   WKPreferences 没有对应的公开 API（SDK 头文件里没有，只有 tbd 里的
    ///   `_WKPreferencesSetShouldAllowUserInstalledFonts` 私有符号），所以走 KVC。
    ///   守卫失败就是维持 WebKit 默认（允许），只是回到现状。
    private func applyAppearancePreferences(_ prefs: WKPreferences) {
        if prefs.responds(to: NSSelectorFromString("_setUseSystemAppearance:")) {
            prefs.setValue(true, forKey: "useSystemAppearance")
        }
        if prefs.responds(to: NSSelectorFromString("_setShouldAllowUserInstalledFonts:")) {
            prefs.setValue(false, forKey: "shouldAllowUserInstalledFonts")
        }
    }

    // MARK: - 页面缩放

    private static let pageZoomDefaultsKey = "clam.pageZoom"
    /// 缩放上下限。放太小页面会挤成一团、放太大失去意义，与 Safari 的档位区间一致。
    private static let pageZoomRange: ClosedRange<CGFloat> = 0.5...3.0
    private static let pageZoomStep: CGFloat = 1.1

    /// 上次退出时的缩放比例。没存过 / 存了个越界值都退到 1.0。
    private static var rememberedPageZoom: CGFloat {
        get {
            guard let raw = UserDefaults.standard.object(forKey: pageZoomDefaultsKey) as? Double else { return 1 }
            let value = CGFloat(raw)
            return pageZoomRange.contains(value) ? value : 1
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: pageZoomDefaultsKey) }
    }

    /// 缩放是**壳本地动作**，不走 menuCommand：它作用在壳自己拥有的 WKWebView 上，
    /// 没有插件能替它做，也不该在插件缺席时失效。
    private func applyPageZoom(_ value: CGFloat) {
        let clamped = min(max(value, Self.pageZoomRange.lowerBound), Self.pageZoomRange.upperBound)
        webView.pageZoom = clamped
        Self.rememberedPageZoom = clamped
    }

    init(backend: BackendManager) {
        self.backend = backend
        super.init(window: nil)
        // **语言要在一切之前定下来**：菜单、引导页都在下面几行里建，而插件装载得
        // 更晚——粘性广播先发一份，谁来订都拿得到（见 publishLocale）。
        publishLocale(Self.startupLocale)
        setupWindow()
        setupContentView()
        // 先把只有系统惯例的那版菜单建起来：**业务菜单项一条都还没有**——它们的
        // 声明随桥的第一份 snapshot 才到（`applyCommands`），键位表更要等
        // clam-layout 的 client 半边投影过来（`clam.page.keymap`）。两者各自到齐时
        // 都会重建整条菜单，所以这里不必等谁。
        setupMenus()
        observeMenuTracking()
        observeKeymap()
        observeWebQuery()
        observeRelaunch()
        // WKWebView 归壳所有（终极逃生舱要用同一个实例），插件只从保管箱借用：
        // 换代后 makeNSView 返回同一实例 → 页面不重载、JS 状态存活（M2 断言 9）。
        nativeHost.objects.setObject(ClamObjects.Key.webView, webView)
        nativeHost.onCommands = { [weak self] commands in self?.applyCommands(commands) }
        nativeHost.onAppBuild = { [weak self] state in self?.applyAppBuild(state) }
        // 装载稳定了再核对一次页面参数：装载途中每个插件各自上线、各自发一份要求，
        // 中间那些半成品状态不该让页面跟着重载一次（见 syncWebQueryGate）。
        nativeHost.onUpdate = { [weak self] in self?.syncWebQueryGate() }
        // 桥的两条事实喂给状态机：握手成不成（翻 `.connected` 那一幕）、
        // 失败是哪一类（诊断面板那一行）。以前两者都只进日志。
        nativeHost.onBridgeConnected = { [weak self] connected in
            self?.connection.noteBridge(connected: connected)
        }
        nativeHost.onBridgeFailure = { [weak self] failure in
            self?.connection.noteBridgeFailure(failure)
        }
        // 状态机不认得 WebView 也不认得 AppKit：副作用全在这三个回调里。
        connection.onAttach = { [weak self] endpoint in self?.attach(endpoint) }
        connection.onDetach = { [weak self] in self?.detach() }
        connection.onPhaseChange = { [weak self] phase in self?.applyPhase(phase) }
        // 托管的后端刚拉起来：催一轮探测。**连接归位本身不需要新机制**——
        // 子 dsh 照常写 endpoint 发现文件，状态机 2s 一轮的轮询自然接上；
        // 这一句只是省掉那最多 2 秒的空等。
        backend.onStateChange = { [weak self] state in
            if case .running = state { self?.connection.probeNow() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 窗口

    private func setupWindow() {
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultWindowSize),
                           styleMask: style, backing: .buffered, defer: false)
        win.title = AppInfo.displayName
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        // 最小宽度 = 主内容最小宽度（sidebar 已自动折叠的前提下）。
        win.minSize = NSSize(width: Self.contentMinWidth, height: 480)
        win.backgroundColor = .windowBackgroundColor
        // 关窗只隐藏、不销毁窗口：dsh 在终端持续运行，点 Dock 图标可原样恢复页面。
        win.isReleasedWhenClosed = false
        win.delegate = self
        self.window = win
        // 记忆窗口位置/大小。注意 setFrameAutosaveName 只要设置成功就返回
        // true（不代表恢复了存档），有没有存档要自己查 defaults。
        let hasSavedFrame = UserDefaults.standard
            .string(forKey: "NSWindow Frame \(Self.windowAutosaveName)") != nil
        win.setFrameAutosaveName(Self.windowAutosaveName)
        if !hasSavedFrame {
            win.setContentSize(Self.defaultWindowSize)
            win.center()
        }
        launchWindowFrame = win.frame
    }

    private func setupContentView() {
        // 壳自己不排版：一个空容器 + 一个 SwiftUI 宿主，剩下的交给 root 槽的占用者。
        containerController.view = NSView()
        window?.contentViewController = containerController
        assertLaunchWindowFrame()

        containerController.addChild(rootHostingController)
        let rootView = rootHostingController.view
        rootView.translatesAutoresizingMaskIntoConstraints = false
        containerController.view.addSubview(rootView)
        NSLayoutConstraint.activate([
            rootView.topAnchor.constraint(equalTo: containerController.view.topAnchor),
            rootView.bottomAnchor.constraint(equalTo: containerController.view.bottomAnchor),
            rootView.leadingAnchor.constraint(equalTo: containerController.view.leadingAnchor),
            rootView.trailingAnchor.constraint(equalTo: containerController.view.trailingAnchor),
        ])

        // 顶部透明拖拽条（titleBarHeight，比标准 28pt 更高更好抓）：
        // fullSizeContentView 下原生标题栏被内容盖住，需要它发起整窗拖拽。
        // 它是窗口 chrome，不随插件换代，所以留在壳里、盖在 root 之上。
        let drag = titleBarDragView
        drag.translatesAutoresizingMaskIntoConstraints = false
        containerController.view.addSubview(drag)
        NSLayoutConstraint.activate([
            drag.topAnchor.constraint(equalTo: containerController.view.topAnchor),
            drag.leadingAnchor.constraint(equalTo: containerController.view.leadingAnchor),
            drag.trailingAnchor.constraint(equalTo: containerController.view.trailingAnchor),
            drag.heightAnchor.constraint(equalToConstant: MainWindowController.titleBarHeight),
        ])

        // 页面 CSS px ↔ 拖动条本地坐标的换算。三件事一处做完：
        // 1. **AppKit 不是翻转坐标系**（原点在左下角），页面是左上——y 要翻一次。
        // 2. WebView 相对窗口有 x/y 偏移（原生分栏的侧边栏宽度）——走 convert，不硬编码。
        // 3. `pageZoom`（⌘±）把 CSS px 拉成了别的点数——除回去，否则缩放一改就整体错位。
        drag.pagePoint = { [weak self, weak drag] point in
            guard let self, let drag, let host = drag.superview, self.webView.window != nil else { return nil }
            let inWindow = host.convert(point, to: nil)
            let local = self.webView.convert(inWindow, from: nil)
            guard self.webView.bounds.contains(local) else { return nil }
            let zoom = max(self.webView.pageZoom, 0.01)
            let y = self.webView.isFlipped ? local.y : self.webView.bounds.height - local.y
            return NSPoint(x: local.x / zoom, y: y / zoom)
        }
    }

    /// 首次布局完成后，若窗口被 AppKit 收缩成内容 fitting size，拉回启动
    /// frame（默认值或 autosave 记忆）。注意需在 main runloop 一拍之后
    /// 调用，布局发生在当前 runloop 内。
    private func assertLaunchWindowFrame() {
        DispatchQueue.main.async { [weak self] in
            self?.assertLaunchWindowFrameNow()
        }
    }

    private func assertLaunchWindowFrameNow() {
        guard let win = window else { return }
        if win.frame.size != launchWindowFrame.size {
            win.setFrame(launchWindowFrame, display: true)
        }
    }

    // MARK: - 连接状态机（消费者）

    /// 装上状态机。它自己会立刻探一轮并每 2s 探一次——壳不是后端的父进程，
    /// 拿不到退出信号，只能靠周期性 GET 发现它走了、也发现它回来了。
    func start() {
        // **先把连接页盖上再启动状态机**：冷启动第一幕就是 `.searching`，
        // 而 `setPhase` 只在幕**变了**的时候回调，等它是等不来的。
        applyPhase(connection.phase)
        connection.start()
        // 托管模式 = "打开即有后端"（Docker Desktop 语义）。`start()` 自己会先
        // 查重，已经有人在管这个 profile 时不会 spawn（计划 §5）。
        // 之后的每一次"后端没了"由 `ensureManagedBackend()` 接手。
        if connection.mode == .managed { backend.start() }
    }

    /// `ensureManagedBackend()` 的节流账。
    private var lastManagedNudge: Date?
    private static let managedNudgeInterval: TimeInterval = 15

    /// 状态机选中了一个端点：装页面 + 连桥。
    private func attach(_ endpoint: ClamEndpoint) {
        loadWebUI(endpoint)
        nativeHost.connect(baseURL: endpoint.httpBase, bridgePath: endpoint.bridgePath)
    }

    /// 状态机放开了当前端点：停桥、停加载。**窗口与 WebView 都留着**——
    /// 后端回来时轮询自动把页面重新载上，用户不必重开 App。
    private func detach() {
        nativeHost.disconnect()
        webView.stopLoading()
    }

    private func loadWebUI(_ endpoint: ClamEndpoint) {
        guard var components = URLComponents(url: endpoint.httpBase, resolvingAgainstBaseURL: false)
        else { return }
        components.path = "/"
        // 查询参数由插件说了算（`clam.web.query`，见 observeWebQuery）。壳不认得
        // 任何一个参数名——它们是 dsh 网页那一侧的私有词汇，定义权在占槽的插件那儿。
        // 排序只为稳定：同一份参数不该因为字典遍历顺序不同而被判成"变了"。
        let query = webQuery
        queryInUse = query
        components.queryItems = query.isEmpty
            ? nil : query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { return }
        webView.load(URLRequest(url: url))
        bridgeReady = false
        connection.notePageReady(false)
        armBridgeWarn()
    }

    /// 桥 ready 超时：只记日志（插件失效不再自动回退网页侧边栏模式）。
    private func armBridgeWarn() {
        bridgeWarnWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.bridgeReady else { return }
            Log.write("桥 ready 超时（\(Int(self.bridgeReadyTimeout))s）——插件疑似失效，currentSession 同步将不可用",
                      to: ClamPaths.logURL, tag: "bridge")
        }
        bridgeWarnWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + bridgeReadyTimeout, execute: work)
    }

    // MARK: - 重连 / 清理

    /// ⌘⇧R：忘掉当前端点，立刻重走定位。归状态机做，壳只是转发。
    func reconnect() {
        connection.reconnect()
    }

    /// 应用退出前调用。收尾只剩自己这一侧的连接——托管后端的收尾归
    /// `BackendManager`（AppDelegate 那边问它要不要等）。
    func shutdown() {
        connection.stop()
        bridgeWarnWork?.cancel()
        nativeHost.disconnect()
    }

    // MARK: - 页面查询参数（插件的门控）

    /// 插件用来告诉壳"我这套界面要页面带哪些查询参数"的粘性主题。
    /// 载荷是 `[参数名: 值]`，**壳对参数名不设白名单也不做任何解释**——
    /// 它们是 dsh 网页那一侧的私有词汇（今天是原生侧边栏的门控），
    /// 定义权在占槽的那个插件手里。**粘性**：插件晚于壳启动，不粘的话壳要等到
    /// 下一次变化才知道该带什么，而那个状态多半一直不变。
    private static let webQueryTopic = "clam.web.query"

    private static let webQueryDefaultsKey = "clam.webQuery"

    /// 上次运行时页面带的那份参数。**页面必须在插件编译完成之前就开始加载**
    /// （预热 WebView），那一刻还没有任何插件说过话，只能先按上次的答案来。
    private static var rememberedWebQuery: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: webQueryDefaultsKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: webQueryDefaultsKey) }
    }

    /// 插件此刻要求的那份参数。
    private var webQuery = MainWindowController.rememberedWebQuery
    /// 上次载入页面时真正用上的那份。与 `webQuery` 不符就重载一次。
    private var queryInUse = MainWindowController.rememberedWebQuery

    // MARK: - 壳自我重启（`clam.app.relaunch`）

    /// 谁都可以喊一嗓子"把壳重启一下"。**眼下唯一的喊话方是 clam-settings 的
    /// 「连接」栏**：那一页只写 UserDefaults、不当场切后端，改完得重启才生效。
    ///
    /// **不复用 `app-restart` 那条桥路径**：那条是"clam-app 编出了新产物、
    /// 你退出我来拉你"，全程要 dsh 在场，而且壳侧那道"一个进程只自请重启一次"
    /// 的保险丝是为构建环设的。这里没有 dsh 参与（改完偏好多半正断着连），
    /// 所以自己 spawn 一个等本进程死透再 `open` 自己的小助手。
    private func observeRelaunch() {
        relaunchSubscription = nativeHost.events.subscribe(Self.relaunchTopic) { [weak self] _ in
            MainActor.assumeIsolated { self?.relaunchSelf() }
        }
    }

    /// 主题名。**壳这边是权威**（订阅方定义），登记在 docs/clam-contracts.md §4。
    static let relaunchTopic = "clam.app.relaunch"

    /// 已经安排过一次重启。**按钮点两下不该起两个助手**——第二个会在第一个
    /// 已经把 App 拉回来之后再 `open` 一次，看上去像窗口自己抖了一下。
    private var relaunchScheduled = false

    private func relaunchSelf() {
        guard !relaunchScheduled else { return }
        relaunchScheduled = true
        let bundlePath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        // 助手必须**自成进程组**：它得比壳活得久，而壳退出时那一发信号是按组走的
        // （`ManagedProcess` 存在的全部理由，见它的顶注）。`kill -0` 轮询到本进程
        // 消失为止再 open——立刻 open 会撞上 LaunchServices 认为"它还在运行"，
        // 于是只是把将死的窗口带到前台，然后什么都没发生。
        let escaped = bundlePath.replacingOccurrences(of: "'", with: "'\\''")
        let command = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open '\(escaped)'"
        do {
            _ = try ManagedProcess.spawn(command: command, onOutput: { _ in }, onExit: { _ in })
            Log.write("按请求重启壳：助手已就位（pid \(pid) 退出后 open）",
                      to: ClamPaths.logURL, tag: "app")
        } catch {
            relaunchScheduled = false
            Log.write("重启壳失败，助手起不来：\(error)", to: ClamPaths.logURL, tag: "app")
            return
        }
        // 给日志一拍落盘，也给点击那一下一个可见的收尾。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.terminate(nil)
        }
    }

    /// 订插件的参数要求。变了就记住并重载页面（网页侧边栏随之回归或让位）。
    private func observeWebQuery() {
        webQuerySubscription = nativeHost.events.subscribe(Self.webQueryTopic) { [weak self] payload in
            // 总线的回调类型不带隔离，得自己声明一次（与 observeKeymap 同款）。
            MainActor.assumeIsolated {
                self?.applyWebQuery(payload.compactMapValues { $0 as? String })
            }
        }
    }

    private func applyWebQuery(_ next: [String: String]) {
        guard next != webQuery else { return }
        webQuery = next
        Self.rememberedWebQuery = next
        // **装载途中不重载**：插件一个接一个上线，先上线的那个说的是"此刻"的话，
        // 而不是"最终"的话——clam-layout 先于 clam-sidebar 上线，那一刻 sidebar 槽
        // 还空着，它如实报了"不要参数"，紧接着 sidebar 上线又报回来。照着中间态重载
        // 的症状是：每次冷启动网页整个加载三遍，中途还闪一下网页侧边栏。
        // 装载稳定后由 syncWebQueryGate() 统一核对一次。
        guard nativeHost.didSettle else { return }
        syncWebQueryGate()
    }

    /// 核对"插件要的参数"与"页面正用着的参数"，不符就重载一次。
    /// 装载稳定（`didSettle`）之后才做——途中的半成品状态不算数。
    private func syncWebQueryGate() {
        guard nativeHost.didSettle, let endpoint = connection.activeEndpoint,
              webQuery != queryInUse else { return }
        Log.write("页面查询参数变化：\(describe(queryInUse)) → \(describe(webQuery))，重载页面",
                  to: ClamPaths.logURL, tag: "layout")
        loadWebUI(endpoint)
    }

    /// 参数字典的一行式写法，只给日志与诊断面板用。
    private func describe(_ query: [String: String]) -> String {
        query.isEmpty ? "（无）"
            : query.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
    }

    // MARK: - 连接页（覆盖层）

    /// 幕变了：该盖就盖，该撤就撤。**只认 `showsOverlay` 一个判据**——
    /// 哪一页（引导 / 中断）由页面自己按 phase 选，壳不参与。
    private func applyPhase(_ phase: ConnectionPhase) {
        if phase.showsOverlay {
            mountConnectionScreen()
            // 连接页在场 = 此刻没有后端。托管模式下这就是"该把它拉起来"的信号
            // ——`start()` 里的查重会挡住"其实有人在管"的情形。
            ensureManagedBackend()
        } else {
            hideConnectionScreen()
        }
    }

    /// 托管模式下保证有一个后端在跑。**"打开即有"不能只保证打开那一瞬**：
    /// `start()` 里那句 `backend.start()` 只在 App 启动时跑一次，后端事后消失
    /// （被 kill、daemon 被清掉、机器睡醒）就再没有人去拉它，壳只会永远停在
    /// 断连页——实测踩过。幕一变成"要盖连接页"就补一次，才算真的托管。
    ///
    /// **BackendManager 自己的退避管不了这一段**：那套只监护它亲手 spawn 的
    /// 子进程；后端是外部的（或还没有）时它停在 `.unavailable`，没有子进程可监护。
    private func ensureManagedBackend() {
        guard connection.mode == .managed, backend.state.canStart else { return }
        // 节流：幕会在 connecting ↔ disconnected 之间来回跳（后端起了又死时尤其
        // 频繁），每跳一次都重跑一遍查重就是在刷屏。间隔取 BackendManager 最长
        // 退避那一档，两套节奏对得上。
        let now = Date()
        if let last = lastManagedNudge, now.timeIntervalSince(last) < Self.managedNudgeInterval {
            return
        }
        lastManagedNudge = now
        backend.start()
    }

    /// 连接页盖在 contentView 之上、铺满窗口。
    ///
    /// **排在拖动条之下**：`WindowDragRegionView` 是窗口 chrome，连接页在场时
    /// 标题栏那 40pt 照样要能拖窗、双击要能放大。旧的 bootstrap 覆盖层是
    /// `positioned: .above, relativeTo: nil`（排在最上面），靠的是
    /// `isMovableByWindowBackground` 兜底——那条路对 NSHostingView 不成立。
    private func mountConnectionScreen() {
        dismissUpdateBanner()
        guard connectionVC == nil else { return }
        let vc = ConnectionViewController(connection: connection, backend: backend,
                                          strings: strings, actions: connectionActions())
        connectionVC = vc
        containerController.addChild(vc)
        let v = vc.view
        v.translatesAutoresizingMaskIntoConstraints = false
        let content = containerController.view
        content.addSubview(v, positioned: .below, relativeTo: titleBarDragView)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: content.topAnchor),
            v.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
    }

    private func hideConnectionScreen() {
        guard let vc = connectionVC else { return }
        vc.view.removeFromSuperview()
        vc.removeFromParent()
        connectionVC = nil
    }

    /// 页面能发起的动作。**壳这一侧一句业务逻辑都没有**：连接归状态机、
    /// 托管归 BackendManager、面板与日志是壳本地动作。
    private func connectionActions() -> ConnectionActions {
        ConnectionActions(
            connect: { [weak self] endpoint, remember in
                guard let self else { return }
                // 顺序不能反：先把偏好落下去，再发起这一次连接。反过来的话
                // `setMode` 会清掉刚记下的一次性目标语义、白探一轮。
                if remember { self.connection.rememberFixed(endpoint.httpBase) }
                self.connection.connect(to: endpoint)
            },
            submitAddress: { [weak self] text, remember in
                guard let self else { return false }
                // 落盘要的是**规范化之后**那个地址（裸端口号补全过的），
                // 不是用户敲进框里的原文——否则下次启动会拿一个连不了的串去连。
                if remember, let url = ConnectionController.normalizedURL(from: text) {
                    self.connection.rememberFixed(url)
                }
                return self.connection.connect(toURLString: text)
            },
            setAutoAdopt: { [weak self] on in self?.connection.setMode(on ? .auto : nil) },
            startManaged: { [weak self] in self?.startManaged() },
            stopManaged: { [weak self] in self?.stopManaged() },
            chooseOther: { [weak self] in self?.connection.abandonTarget() },
            openDiagnostics: { [weak self] in self?.showDiagnostics() },
            openLogs: { [weak self] in self?.openLogs() })
    }

    /// "开启托管"：**同时落偏好**。托管的承诺是"打开 App 就有后端"，
    /// 只拉起这一次而不记住的话，下次开 App 又回到空空的引导页。
    private func startManaged() {
        connection.setMode(.managed)
        backend.start()
    }

    /// "停止托管"：杀进程 + 清回未设置（计划 §5，§11.1 修订）。留在 managed
    /// 模式的话下次启动又会自己拉起来——那不是用户按这颗按钮的意思。
    ///
    /// **清回 unset 而不是 auto**：切成 auto 等于替用户选了"随便接本机发现的一个"，
    /// 而他刚刚表达的是"别自动起后端"。停掉之后停在引导页，接不接他自己点。
    private func stopManaged() {
        backend.stop()
        connection.setMode(nil)
    }

    // MARK: - 壳自身的构建（clam-app v1）

    /// 壳重建不是插件热替换那个档位：它要重启进程、丢页面状态。所以默认只提示，
    /// 动手归用户（clam-app 配了 `restartOnRebuild` 才自动走）。
    private func applyAppBuild(_ state: AppBuildState) {
        // 连接页在场 = 此刻连后端都没有，"壳有新版"不是当下该操心的事。
        guard connectionVC == nil else { return }
        switch state.status {
        case "building":
            mountUpdateBanner().show(.building)
        case "ready":
            guard !state.autoRestart else {
                Log.write("壳有新版且配置了自动重启，立即重启", to: ClamPaths.logURL, tag: "app-build")
                nativeHost.requestRestartApp()
                return
            }
            var parts: [String] = []
            if let hash = state.hash { parts.append(hash) }
            if let ms = state.durationMs { parts.append(String(format: "%.1fs", Double(ms) / 1000)) }
            mountUpdateBanner().show(.ready(detail: parts.joined(separator: " · ")))
        case "failed":
            mountUpdateBanner().show(.failed)
        default:
            dismissUpdateBanner()
        }
    }

    private func mountUpdateBanner() -> ShellUpdateBanner {
        if let banner = updateBanner { return banner }
        let banner = ShellUpdateBanner(
            strings: strings,
            onPrimary: { [weak self] kind in
                guard let self else { return }
                switch kind {
                case .ready:
                    self.dismissUpdateBanner()
                    self.nativeHost.requestRestartApp()
                case .failed:
                    NSWorkspace.shared.open(ClamPaths.logsDir)
                case .building:
                    break
                }
            },
            onDismiss: { [weak self] in self?.dismissUpdateBanner() })
        updateBanner = banner
        banner.translatesAutoresizingMaskIntoConstraints = false
        bannerStack.insertArrangedSubview(banner, at: 0)  // 要决定的事排在"已发生"的浮条之上
        return banner
    }

    private func dismissUpdateBanner() {
        if let banner = updateBanner {
            bannerStack.removeArrangedSubview(banner)
            banner.removeFromSuperview()
        }
        updateBanner = nil
    }

    /// 一次性浮条：下载完成/失败这类"已经发生了"的事，说完自己走。
    private func presentToast(_ content: ShellToast.Content) {
        let toast = ShellToast(content: content, strings: strings, onDismiss: { [weak self] view in
            self?.bannerStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        })
        bannerStack.addArrangedSubview(toast)
    }

    // MARK: - 菜单

    /// 标准 macOS 菜单：应用 / 文件 / 编辑 / 显示 / 会话 / 窗口 / 帮助。
    /// 编辑菜单把 ⌘A/⌘C/⌘V/⌘X/⌘Z 等以标准 selector（cut:/copy:/paste:/selectAll:…）
    /// 挂到 nil target（走响应链）——WKWebView 与原生文本框（设置窗口）都会正确响应，
    /// 不再依赖 Web 内容层对裸按键的偶发处理。
    ///
    /// ## 两段：系统惯例段 + 贡献遍历段
    ///
    /// **壳里没有任何一条业务命令的名字**（曾经有整整一张会话菜单）。业务菜单项
    /// 由插件的 node 半边声明（`createSwiftPlugin({ commands })`，形状见
    /// `clam-bridge/lib/plugin.js` 的 CommandDeclaration），经桥 snapshot 到
    /// `nativeHost.commands`，这里照着装：
    ///
    /// - `menu` 落在 `app`/`file`/`edit`/`view`/`window`/`help` 就插进对应的系统菜单
    ///   （每个菜单有一处固定的插入点，见下面各段），其余 id 造一个新的顶级菜单，
    ///   标题取首个声明者的 `menuLabel`，夹在「显示」与「窗口」之间；
    /// - 没有 `menu` 的命令不进菜单栏（执行在页面里的键），只上 ⌘/ 面板；
    /// - 按下去只 `events.emit(.menuCommand, ["command": id, …])`，**壳只喊命令，
    ///   不做业务**。没人应答就静默无事：事件总线是广播，没有订阅者不是错误。
    ///   插件缺席时那条菜单项根本不会出现——它连声明都没到过。
    ///
    /// 反过来，**壳本地动作**（缩放、重载、诊断、快捷键面板、退出、关窗口）留在
    /// 系统惯例段硬编码：它们作用在壳自己拥有的东西上，任何插件配置下都必须可用。
    ///
    /// ## 哪些键位可配
    ///
    /// 只有插件声明里带 `key` 的那些从 `keymap` 里取（默认值也来自声明），其余
    /// （⌘W/⌘Q/编辑菜单/⌘R/⌥⌘S/缩放/⌥⌘D/⌘⇧R/⌘/）是 macOS 系统惯例，硬编码不动
    /// ——它们改了只会更难用，不值得摆进设置里。
    ///
    /// **整个函数是幂等的**：换键位、换命令表、换界面语言时原样再跑一遍、连
    /// `NSApp.mainMenu` 一起换新（入口统一走 `rebuildMenus()`，它替这里避开
    /// "菜单正张着"那一刻）。`windowsMenu` / `helpMenu` 的重新赋值 AppKit 自己会把
    /// 托管项（窗口列表、帮助搜索框）迁到新菜单上，不需要先拆旧的。
    ///
    /// 壳自己的文案全部现取（`strings`），一个字面量都不留在这里——见 Strings.swift；
    /// 贡献项的文案则来自声明，壳不认得它们该怎么翻。
    private func setupMenus() {
        let s = strings
        let mainMenu = NSMenu()

        // 应用菜单（⌘Q 退出、⌘H 隐藏）
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: s.menuAbout,
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        // 应用菜单的插入点：「关于」之下、壳自己那几项之上。⌘, 就落在这儿
        // （壳自己已无偏好可设，设置窗口归 clam-settings / 页内 modal 归 clam-layout）。
        addContributions("app", to: appMenu)
        let reconnectItem = appMenu.addItem(withTitle: s.menuReconnect,
                                            action: #selector(reconnectNow),
                                            keyEquivalent: "r")
        reconnectItem.keyEquivalentModifierMask = [.command, .shift]
        reconnectItem.target = self
        let logsItem = appMenu.addItem(withTitle: s.menuOpenLogs,
                                       action: #selector(openLogs), keyEquivalent: "")
        logsItem.target = self
        let diagItem = appMenu.addItem(withTitle: s.menuDiagnostics,
                                       action: #selector(showDiagnostics), keyEquivalent: "d")
        diagItem.keyEquivalentModifierMask = [.command, .option]
        diagItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: s.menuHide,
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = appMenu.addItem(withTitle: s.menuHideOthers,
                                             action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: s.menuShowAll,
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: s.menuQuit,
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        appItem.title = AppInfo.displayName

        // 文件菜单：贡献在上（会话的增删改名之类），⌘W 关闭窗口永远垫底。
        // 一条贡献都没有时不留那条孤零零的分隔线。
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: s.menuFile)
        if addContributions("file", to: fileMenu) > 0 { fileMenu.addItem(.separator()) }
        fileMenu.addItem(withTitle: s.menuCloseWindow,
                         action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        fileItem.title = s.menuFile

        // 编辑菜单（⌘Z/⌘⇧Z/⌘X/⌘C/⌘V/⌘A）
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: s.menuEdit)
        editMenu.addItem(withTitle: s.menuUndo, action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: s.menuRedo, action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: s.menuCut, action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: s.menuCopy, action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: s.menuPaste, action: Selector(("paste:")), keyEquivalent: "v")
        editMenu.addItem(withTitle: s.menuDelete, action: Selector(("delete:")), keyEquivalent: "")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: s.menuSelectAll, action: Selector(("selectAll:")), keyEquivalent: "a")
        // 编辑菜单的插入点在末尾（眼下没人贡献；要分隔线由声明自己带 separatorBefore）。
        addContributions("edit", to: editMenu)
        editItem.submenu = editMenu
        editItem.title = s.menuEdit

        // 显示菜单（⌘R 重载；⌘⌥S 收起/展开侧边栏——系统标准行为）
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: s.menuView)
        let reloadItem = viewMenu.addItem(withTitle: s.menuReloadPage,
                                          action: #selector(reloadPage), keyEquivalent: "r")
        reloadItem.target = self
        let sidebarItem = viewMenu.addItem(withTitle: s.menuToggleSidebar,
                                           action: Selector(("toggleSidebar:")), keyEquivalent: "s")
        sidebarItem.keyEquivalentModifierMask = [.command, .option]
        // 显示菜单的插入点：重载/边栏之下、缩放那组之上。
        addContributions("view", to: viewMenu)
        viewMenu.addItem(.separator())
        let zoomInItem = viewMenu.addItem(withTitle: s.menuZoomIn,
                                          action: #selector(zoomIn), keyEquivalent: "+")
        zoomInItem.target = self
        // ⌘= 的别名：键盘上 + 与 = 同一个键，用户多半不按 shift。macOS 惯例是
        // 菜单里只显示 ⌘+，另挂一个隐藏项接住 ⌘=。隐藏项的快捷键默认不生效，
        // 必须显式 allowsKeyEquivalentWhenHidden。
        let zoomInAlias = viewMenu.addItem(withTitle: s.menuZoomIn,
                                           action: #selector(zoomIn), keyEquivalent: "=")
        zoomInAlias.target = self
        zoomInAlias.isHidden = true
        zoomInAlias.allowsKeyEquivalentWhenHidden = true
        let zoomOutItem = viewMenu.addItem(withTitle: s.menuZoomOut,
                                           action: #selector(zoomOut), keyEquivalent: "-")
        zoomOutItem.target = self
        let zoomResetItem = viewMenu.addItem(withTitle: s.menuActualSize,
                                             action: #selector(zoomReset), keyEquivalent: "0")
        zoomResetItem.target = self
        viewItem.submenu = viewMenu
        viewItem.title = s.menuView

        // 插件自造的顶级菜单（如 clam-sidebar 的「会话」）。全部夹在这儿：
        // 「显示」之后、「窗口」之前——右边那两个是 macOS 的固定尾巴。
        for menuId in customMenuIds() {
            let item = NSMenuItem()
            mainMenu.addItem(item)
            let title = customMenuTitle(menuId)
            let menu = NSMenu(title: title)
            addContributions(menuId, to: menu)
            item.submenu = menu
            item.title = title
        }

        // 窗口菜单（⌘M 最小化）
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: s.menuWindow)
        windowMenu.addItem(withTitle: s.menuMinimize,
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: s.menuZoomWindow,
                           action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        addContributions("window", to: windowMenu)
        windowItem.submenu = windowMenu
        windowItem.title = s.menuWindow
        NSApp.windowsMenu = windowMenu

        // 帮助菜单。设 NSApp.helpMenu 才会被系统摆到标准位置（最右）
        // 并挂上那个搜索框；只当普通菜单加进去位置就不对。
        let helpItem = NSMenuItem()
        mainMenu.addItem(helpItem)
        let helpMenu = NSMenu(title: s.menuHelp)
        let shortcutsItem = helpMenu.addItem(withTitle: s.menuKeyboardShortcuts,
                                             action: #selector(showShortcuts), keyEquivalent: "/")
        shortcutsItem.target = self
        addContributions("help", to: helpMenu)
        helpItem.submenu = helpMenu
        helpItem.title = s.menuHelp
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - 贡献的菜单项

    /// 壳自带的那几个菜单。**这不是白名单**：不在这张表里的 `menu` id 会造一个
    /// 新的顶级菜单，第三方插件想要一个自己的菜单不用改壳。
    private static let systemMenuIds: Set<String> = ["app", "file", "edit", "view", "window", "help"]

    /// 落在某个菜单里的贡献，按 `order` 排；同序按 id 排（稳定，不受登记顺序影响）。
    private func contributions(in menuId: String) -> [ClamCommand] {
        commands.filter { $0.menu == menuId }
            .sorted { ($0.order, $0.id) < ($1.order, $1.id) }
    }

    /// 插件自造的顶级菜单 id，按 `menuOrder` 排；同序按首次出现的顺序。
    private func customMenuIds() -> [String] {
        var seen: [String: (order: Int, index: Int)] = [:]
        for (index, command) in commands.enumerated() {
            guard let menu = command.menu, !Self.systemMenuIds.contains(menu) else { continue }
            if seen[menu] == nil { seen[menu] = (command.menuOrder, index) }
        }
        return seen.sorted { ($0.value.order, $0.value.index) < ($1.value.order, $1.value.index) }
            .map(\.key)
    }

    /// 自定义菜单的标题取**首个声明者**的 `menuLabel`；谁都没写就退回 id
    /// （难看，但比一个没有标题的菜单强，而且一眼看得出是谁忘了写）。
    private func customMenuTitle(_ menuId: String) -> String {
        for command in commands where command.menu == menuId {
            if let title = command.menuTitle(activeLocale) { return title }
        }
        return menuId
    }

    /// 把某个菜单 id 的贡献装进菜单，返回装了几项。
    ///
    /// `separatorBefore` 只在菜单**当时非空**时才画——否则第一条贡献会给菜单
    /// 顶一条孤零零的分隔线（自定义菜单的第一项尤其容易撞上）。
    @discardableResult
    private func addContributions(_ menuId: String, to menu: NSMenu) -> Int {
        var added = 0
        for command in contributions(in: menuId) {
            if command.separatorBefore, menu.numberOfItems > 0 { menu.addItem(.separator()) }
            if let digits = command.digits {
                // 一族：一个设置键装 count 个数字键项。全隐藏时快捷键仍要生效，
                // 必须显式 allowsKeyEquivalentWhenHidden（不设则隐藏项的键一并失效）。
                let mask = activeKeymap.digits[command.id] ?? nil
                for n in 1...max(1, digits.count) {
                    let item = menu.addItem(withTitle: command.title(activeLocale, index: n),
                                            action: #selector(runCommand(_:)), keyEquivalent: "")
                    if let mask {
                        item.keyEquivalent = "\(n)"
                        item.keyEquivalentModifierMask = mask
                    }
                    item.target = self
                    item.representedObject = MenuCommandBox(command: digits.command,
                                                            payload: [digits.argKey: n])
                    item.isHidden = command.hidden
                    item.allowsKeyEquivalentWhenHidden = true
                    added += 1
                }
                continue
            }
            let item = menu.addItem(withTitle: command.title(activeLocale),
                                    action: #selector(runCommand(_:)), keyEquivalent: "")
            bind(item, command.id, activeKeymap)
            item.target = self
            item.representedObject = MenuCommandBox(command: command.id, payload: [:])
            if command.hidden {
                item.isHidden = true
                item.allowsKeyEquivalentWhenHidden = true
            }
            added += 1
        }
        return added
    }

    // MARK: - 菜单重建（换键位 / 换语言共用一条路）

    /// 此刻有几层由主菜单发起的菜单正张着。**菜单张开时不许换 `NSApp.mainMenu`**：
    /// 用户眼前那份会被抽走，轻则菜单当场收起、重则点下去落在已经不存在的项上。
    private var menuTrackingDepth = 0

    /// 菜单张着时来的重建请求记在这儿，等它关了再补做。
    /// 只记"要不要做"不记"做什么"——重建总是照当下的键位与语言整棵新建。
    private var pendingMenuRebuild = false

    private var menuTrackingObservers: [NSObjectProtocol] = []

    /// 重建主菜单的**唯一入口**。菜单正张着就先记账，等 `didEndTracking` 再补。
    private func rebuildMenus() {
        guard menuTrackingDepth == 0 else {
            pendingMenuRebuild = true
            return
        }
        setupMenus()
    }

    /// 盯住主菜单的张合。只认根菜单是 `NSApp.mainMenu` 的那些——
    /// 弹出菜单（工具栏贡献、右键菜单）与主菜单无关，不该拦住重建。
    private func observeMenuTracking() {
        let center = NotificationCenter.default
        func rooted(_ note: Notification) -> Bool {
            guard var menu = note.object as? NSMenu else { return false }
            while let sup = menu.supermenu { menu = sup }
            return menu === NSApp.mainMenu
        }
        // **必须 weak**：block 版 addObserver 会一直持有这个闭包，强捕 self
        // 就是 self → observers → block → self 的循环。
        menuTrackingObservers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification,
                               object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, rooted(note) else { return }
                    self.menuTrackingDepth += 1
                }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification,
                               object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, rooted(note) else { return }
                    self.menuTrackingDepth = max(0, self.menuTrackingDepth - 1)
                    guard self.menuTrackingDepth == 0, self.pendingMenuRebuild else { return }
                    self.pendingMenuRebuild = false
                    // 延到下一拍：AppKit 这会儿还在收尾这次 tracking。
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.setupMenus()
                    }
                }
            },
        ]
    }

    deinit {
        for token in menuTrackingObservers { NotificationCenter.default.removeObserver(token) }
    }

    /// 给一条菜单项装上键位。**掩码必须显式设**：`NSMenuItem` 的默认掩码是
    /// `[.command]`，用户把键位配成不带 ⌘ 的组合而这里不重设掩码，
    /// 按下去的仍是加了 ⌘ 的那个——设了没反应，且不报错。
    private func bind(_ item: NSMenuItem, _ command: String, _ keymap: Keymap) {
        let binding = keymap.bindings[command] ?? .disabled
        item.keyEquivalent = binding.keyEquivalent
        item.keyEquivalentModifierMask = binding.mask
    }

    // MARK: - 键位表（设置项 `clam-shortcuts`）

    /// 订上设置里那份键位表。链路：dsh settings → clam-layout 的 client 半边订值
    /// → `postToShell({type:"keymap", values})` → 页内桥广播 `clam.page.keymap`。
    ///
    /// **不需要粘性补发**：页面每次加载都会重推一份，而壳重启必然重载页面。
    /// 这跟 currentSession 那种"可能永远不再变"的状态不是一回事。
    private func observeKeymap() {
        keymapSubscription = nativeHost.events
            .subscribe(ClamEventBus.Topic.pagePrefix + "keymap") { [weak self] payload in
                // 总线的约定是"只在主线程 emit/subscribe"，但它的回调类型不带隔离，
                // 得自己声明一次（与 clam-header 那边同款）。
                MainActor.assumeIsolated {
                    // 载荷就是页面 postMessage 的那个字典本身（含 type 字段）。
                    self?.applyKeymap(payload["values"] as? [String: Any] ?? [:])
                }
            }
    }

    /// 插件的命令声明到了（或变了）。**菜单必然要重建**：菜单项本身就是这张表。
    /// 键位也跟着重算——默认键位就住在声明里。
    private func applyCommands(_ next: [ClamCommand]) {
        commands = next
        resolveKeymap()
        rebuildMenus()
        shortcutsPanel?.refreshIfVisible(strings: strings, inPage: inPageShortcuts)
    }

    /// 设置里那份覆盖到了。**只在真变了的时候重建**：页面每次加载、每次设置回调都会
    /// 推一份，绝大多数与在役的那份一模一样，无脑重建等于反复把整条主菜单换掉。
    private func applyKeymap(_ raw: [String: Any]) {
        // 非字符串的值（JS 侧的 null / 未设置）一律当"没配"处理，退默认。
        keymapValues = raw.compactMapValues { $0 as? String }
        resolveKeymap()
    }

    /// 用当前的命令声明 + 设置覆盖算一份键位表，变了就重建菜单。
    private func resolveKeymap() {
        let values = keymapValues
        let (keymap, failed) = Keymap.resolve(values, commands: commands)
        let changed = keymap != activeKeymap
        if changed {
            activeKeymap = keymap
            rebuildMenus()
            // ⌘/ 面板开着的话，它列的键位这会儿已经过期了。
            shortcutsPanel?.refreshIfVisible(strings: strings, inPage: inPageShortcuts)
        }
        // **解析失败要无条件落日志**：坏 spec 退回默认之后，算出来的表可能与在役的
        // 那份一模一样（把默认值打错一个字母就是这种情形），只按"变了没"记日志的话
        // 用户永远不知道自己写错了什么。
        guard changed || !failed.isEmpty else { return }

        let failedNames = Set(failed.map(\.command))
        // 默认键位来自命令声明，"壳认得的可配置键"因此就是声明的那一批
        // ——设置里多出来的键（插件下线了、或用户手改过配置文件）不计账。
        let defaults = Dictionary(commands.map { ($0.id, $0.key ?? "") },
                                  uniquingKeysWith: { first, _ in first })
        // 快照会把没动过的字段也填上默认值一起推下来，"在场"不等于"用户改过"
        // ——与默认表不同才算覆盖，否则这行账永远是满打满算的一整张表。
        let applied = values.filter { key, value in
            defaults[key] != nil && !failedNames.contains(key) && value != defaults[key]
        }.count
        var line = "键位表\(changed ? "已应用" : "无变化")"
            + "（设置覆盖 \(applied) 项，解析失败退默认 \(failed.count) 项）"
        if !failed.isEmpty {
            // 失败的原文必须落日志：用户看不到解析器，只能从这一行知道自己写错了什么。
            line += "：" + failed.map { "\($0.command)=\"\($0.raw)\"" }.joined(separator: " ")
        }
        Log.write(line, to: ClamPaths.logURL, tag: "menu")
        warnConflicts(keymap)
    }

    /// 撞键只警告、不纠正：两条命令配成同一个键是用户的选择，壳没资格替他挑
    /// 该留哪条（AppKit 自己按菜单顺序取第一个命中的）。禁用掉一条反而更难查。
    private func warnConflicts(_ keymap: Keymap) {
        var groups: [String: [String]] = [:]
        for (command, binding) in keymap.bindings where !binding.keyEquivalent.isEmpty {
            groups["\(binding.mask.rawValue)|\(binding.keyEquivalent)", default: []].append(command)
        }
        // 一族命令占的是 N 个数字键，得逐个摊开才比得出撞没撞。
        for command in commands {
            guard let digits = command.digits, let mask = keymap.digits[command.id] ?? nil else { continue }
            for n in 1...max(1, digits.count) {
                groups["\(mask.rawValue)|\(n)", default: []].append("\(command.id)(\(n))")
            }
        }
        for key in groups.keys.sorted() {
            guard let names = groups[key], names.count > 1 else { continue }
            Log.write("键位冲突：\(names.sorted().joined(separator: " / ")) 配成了同一个键，"
                      + "AppKit 只会触发菜单里靠前的那条",
                      to: ClamPaths.logURL, tag: "menu")
        }
    }

    // MARK: - 界面语言（跟随 dsh 的 `locale` 设置）

    /// 缓存键。**这不是偏好**——语言的唯一权威是 dsh 的 `locale.preference`
    /// （`~/.dsh/settings.yaml`），这里只记住上次已知的解析结果。
    /// 页面投影一到就覆盖，永远不反向写回 dsh。
    private static let localeDefaultsKey = "clamLocale"

    /// 此刻在役的语言。真相来自页面（`clam.page.locale`）；
    /// 页面还没说话时是 `startupLocale` 那一级的猜测。
    private(set) var activeLocale: ClamLocale = .en

    /// 壳自己那张文案表，按当前语言现算。**别把它存成属性**：存下来就多了一份
    /// 要跟着语言更新的状态，而它本来就只是 `activeLocale` 的一个视图。
    var strings: L { L(activeLocale) }

    /// 冷启动时的决议：**缓存 → 系统语言 → en**。
    ///
    /// 为什么要缓存这一级：菜单在 `init` 里就建好了，而页面侧的投影要等
    /// WebView 载入 + 插件树挂载，中间隔着一两秒。没有缓存的话每次冷启动都会
    /// "先英文、两秒后闪成中文"。缓存不是偏好：页面一说话就被覆盖。
    ///
    /// 系统语言这一级与页面侧天然一致——WKWebView 的 `navigator.languages`
    /// 同样来自系统语言，而 `ClamLocale.resolve` 复刻的就是 dsh 的推导规则。
    private static var startupLocale: ClamLocale {
        if let raw = UserDefaults.standard.string(forKey: localeDefaultsKey),
           let cached = ClamLocale(rawValue: raw) {
            return cached
        }
        return ClamLocale.resolve(preferred: Locale.preferredLanguages)
    }

    /// 广播当前语言。**粘性**：插件装载晚于壳启动，不粘的话它要等到用户下一次
    /// 切语言才知道现在是哪一种，而那个状态很可能一直不变
    /// （见 `ClamEventBus.emitSticky`）。
    private func publishLocale(_ next: ClamLocale) {
        activeLocale = next
        nativeHost.events.emitSticky(ClamEventBus.Topic.locale, ["locale": next.rawValue])
    }

    /// 页面投影来的语言（`clam.page.locale`，clam-layout 的 client 半边订
    /// `ctx.locale` 后推）。这是决议链的最高一级，无条件覆盖前两级。
    ///
    /// 取的是页面**解析后**的 `active` 而不是设置里的原始 `preference`：
    /// `preference` 缺省时的推导只有浏览器侧算得准，而不变量是
    /// "原生 UI 的语言 == 页面显示的语言"。
    private func applyProjectedLocale(_ raw: String) {
        guard let next = ClamLocale(rawValue: raw) else {
            Log.write("页面投影的语言 \"\(raw)\" 不在值域内，忽略", to: ClamPaths.logURL, tag: "locale")
            return
        }
        // 缓存无条件刷新（哪怕值没变）：便宜，而且能修好手改过 defaults 的机器。
        UserDefaults.standard.set(next.rawValue, forKey: Self.localeDefaultsKey)
        guard next != activeLocale else { return }
        publishLocale(next)
        rebuildLocalizedSurfaces()
        Log.write("界面语言切到 \(next.rawValue)（来自 dsh 设置）", to: ClamPaths.logURL, tag: "locale")
    }

    /// 语言变了，把壳自己画的每一处语言相关表面重来一遍。
    ///
    /// **只有"活着且长期在场"的表面需要出现在这里**：菜单栏、提示条、两个面板、
    /// 引导页。诊断正文、快捷键正文、各种 alert 与浮条都是**打开/生成那一刻**
    /// 才取文案的，天然就是新的；插件那半边自己订 `clam.locale` 粘性主题
    /// （`ClamLocaleStore`），也不归这里管。
    private func rebuildLocalizedSurfaces() {
        let s = strings
        rebuildMenus()
        updateBanner?.apply(strings: s)
        diagnosticsPanel?.apply(strings: s)
        shortcutsPanel?.refreshIfVisible(strings: s, inPage: inPageShortcuts)
        connectionVC?.apply(strings: s)
    }

    // MARK: - 菜单动作：喊命令

    /// **贡献的菜单项全部走这一个 selector**：命令名是插件给的字符串，壳编译期
    /// 一个都不认得，所以既做不出一堆 `@objc` 方法，也不能拿 tag 当命令名。
    /// 该喊什么挂在菜单项的 `representedObject` 上（`MenuCommandBox`）。
    /// 只 emit，不做事——"没人应答会怎样"见 setupMenus() 顶注。
    @objc private func runCommand(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? MenuCommandBox else { return }
        emitMenuCommand(box.command, box.payload)
    }

    /// 总线是同步同线程派发，主线程 emit 即可，不需要跳队列。
    private func emitMenuCommand(_ command: String, _ extra: [String: Any] = [:]) {
        var payload: [String: Any] = ["command": command]
        for (k, v) in extra { payload[k] = v }
        nativeHost.events.emit(ClamEventBus.Topic.menuCommand, payload)
    }

    // MARK: - 菜单动作：壳本地

    @objc private func zoomIn() {
        applyPageZoom(webView.pageZoom * Self.pageZoomStep)
    }

    @objc private func zoomOut() {
        applyPageZoom(webView.pageZoom / Self.pageZoomStep)
    }

    @objc private func zoomReset() {
        applyPageZoom(1)
    }

    /// ⌘/：把当前主菜单里所有带快捷键的项摊成一张表，外加那些不在菜单里的。
    @objc private func showShortcuts() {
        let panel = shortcutsPanel ?? ShortcutsPanel(strings: strings)
        shortcutsPanel = panel
        panel.present(strings: strings, inPage: inPageShortcuts)
    }

    /// 没有 `menu` 的命令：执行在页面里（Esc 停止生成那类），主菜单遍历不到，
    /// 由面板单列一节。**它们照样从同一份键位表取键位**，不与设置漂移。
    private var inPageShortcuts: [ShortcutsPanel.ExtraRow] {
        commands.filter { $0.menu == nil }.map {
            ShortcutsPanel.ExtraRow(title: $0.title(activeLocale),
                                    spec: activeKeymap.specs[$0.id] ?? "")
        }
    }

    @objc private func reconnectNow() {
        reconnect()
    }

    @objc private func reloadPage() {
        webView.reload()
    }

    @objc private func openLogs() {
        NSWorkspace.shared.open(ClamPaths.logsDir)
    }

    /// ⌥⌘D：把壳此刻的全部认知摊平成一屏可拷贝的文本。
    @objc private func showDiagnostics() {
        // 采集闭包返回 nil = 窗口已销毁，面板自己用文案表里那句话兜底。
        let panel = diagnosticsPanel ?? DiagnosticsPanel(strings: strings, collect: { [weak self] in
            self?.diagnosticsText()
        })
        diagnosticsPanel = panel
        panel.present(strings: strings)
    }

    /// 诊断正文。顺序按"离用户多远"排：先是它连着谁，再是它跑着什么。
    private func diagnosticsText() -> String {
        let s = strings
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        var lines: [String] = []
        lines.append("\(AppInfo.displayName)  \(version)  (\(Bundle.main.bundleIdentifier ?? "?"))")
        lines.append(s.diagBuildTime(AppInfo.buildTimestamp))
        lines.append("")
        lines.append(s.diagSectionConnection)
        // **开发者细节全在这儿**：worktree、profile、pid、isOwn、候选健康态
        // 一个都不上主界面（计划 §3 口径 1），它们的去处就是这一屏与日志。
        lines.append(s.diagPhase(connection.phase.key))
        lines.append(s.diagMode(connection.mode?.rawValue ?? "unset", target: connection.targetAddress))
        if let endpoint = connection.activeEndpoint {
            // "不是本 worktree 那一套"是警告，得跟着端点这一行走（见 ClamEndpoint.summary）。
            lines.append(s.diagEndpoint(endpoint.summary + (endpoint.isOwn ? "" : s.diagEndpointNotOwn)))
            lines.append(s.diagEndpointSource(endpoint.source.rawValue))
        } else {
            lines.append(s.diagEndpointNone)
        }
        if let failure = connection.lastFailure {
            lines.append(s.diagLastFailure(ConnectionController.failureKey(failure)))
        }
        if connection.attempts > 0 {
            lines.append(s.diagAttempts(connection.attempts))
        }
        let candidateText = connection.candidates.isEmpty
            ? s.diagDiscoveredNone
            : connection.candidates.map { status in
                let health = status.failure.map { ConnectionController.failureKey($0) } ?? "ok"
                return "\(status.endpoint.summary) \(health) \(String(format: "%.0fms", status.elapsed * 1000))"
                    + (status.endpoint.isOwn ? "" : " ⚠️")
            }.joined(separator: ", ")
        lines.append(s.diagCandidates(candidateText))
        lines.append(s.diagBackendManager(backend.diagnosticSummary))
        lines.append(s.diagBridge(connected: nativeHost.isBridgeConnected))
        lines.append(s.diagPageBridge(ready: bridgeReady))
        lines.append(s.diagWebQuery(describe(queryInUse)))
        // 页面还没投影过来时，显示的是缓存/系统语言那两级的猜测——分得清才好查
        // "原生和网页各说各话"这类问题。
        let localeSource = UserDefaults.standard.string(forKey: Self.localeDefaultsKey) == nil
            ? s.diagLocaleFromSystem : s.diagLocaleFromCache
        lines.append(s.diagLocale(activeLocale.rawValue, source: localeSource))
        lines.append("")
        lines.append(s.diagSectionPlugins)
        lines.append(s.diagPluginCounts(loaded: nativeHost.loadedCount, retired: nativeHost.retiredThisRun))
        if nativeHost.diagnostics.isEmpty {
            lines.append(s.diagPluginsNone)
        } else {
            lines.append(contentsOf: nativeHost.diagnostics.map { "  \($0)" })
        }
        lines.append(s.diagRootOwner(nativeHost.registry.owner(of: "root")))
        // 其余槽名壳一个都不认得（`root` 是唯一例外，那是壳自己的兜底），
        // 所以这里只把 registry 现有的占用照抄一遍——第三方插件"我注册上了吗"
        // 在这一行里有答案。
        let slots = nativeHost.registry.entries.keys.sorted()
            .map { "\($0) → \(nativeHost.registry.owner(of: $0) ?? "?")" }
        lines.append(s.diagSlots(slots.isEmpty ? s.diagDiscoveredNone : slots.joined(separator: ", ")))
        lines.append(s.diagCommands(commands.count,
                                    detail: commands.isEmpty
                                        ? s.diagDiscoveredNone
                                        : commands.map { "\($0.owner)/\($0.id)" }.joined(separator: ", ")))
        lines.append("")
        lines.append(s.diagSectionShellBuild)
        if let build = nativeHost.appBuild {
            lines.append(s.diagLastBuild(build.status
                         + (build.hash.map { "  \($0)" } ?? "")
                         + (build.durationMs.map { String(format: "  %.1fs", Double($0) / 1000) } ?? "")))
            if let log = build.log, !log.isEmpty {
                lines.append(s.diagBuildLogTail)
                lines.append(contentsOf: log.split(separator: "\n").map { "  \($0)" })
            }
        } else {
            lines.append(s.diagNoBuild)
        }
        lines.append("")
        lines.append(s.diagSectionPaths)
        // 日志一个实例一份，写全路径而不是目录——多 worktree 时"我该看哪个文件"
        // 正是最容易搞错的一步。
        lines.append(s.diagLogPath(ClamPaths.logURL.path))
        lines.append(s.diagEndpointsPath(ClamPaths.endpointsDir.path))
        // 一个 profile 一份，所以这一行同时回答了"这台机器上现在有几套 surfclam 在跑"。
        let discovered = EndpointLocator.discoveredEndpoints()
        let discoveredText = discovered.isEmpty
            ? s.diagDiscoveredNone
            : discovered.map { "\($0.profile ?? "?") → \($0.httpBase.absoluteString)" }
                .joined(separator: ", ")
        lines.append(s.diagDiscovered(discoveredText))
        return lines.joined(separator: "\n")
    }

    // MARK: - 网页 → 原生消息

    /// v2 桥消息（ready / currentSession / locale）。
    func handleBridgeMessage(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        switch message.name {
        case "clam":
            guard let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                bridgeReady = true
                connection.notePageReady(true)
                bridgeWarnWork?.cancel()
                bridgeWarnWork = nil
                let caps = body["capabilities"] as? [String] ?? []
                var diag = ""
                if let d = body["diag"] as? [String: Any] {
                    diag = " diag=\(d)"
                }
                Log.write("页内桥就绪：\(caps.joined(separator: ", "))\(diag)", to: ClamPaths.logURL, tag: "bridge")
                nativeHost.events.emit(ClamEventBus.Topic.pageReady, ["capabilities": caps])
            case "currentSession":
                if let id = body["id"] as? String {
                    // **粘性**：插件装载晚于页面，不粘的话它拿不到"现在在哪个会话"
                    // ——而这恰恰是它最需要的那个输入（见 ClamEventBus.emitSticky）。
                    nativeHost.events.emitSticky(ClamEventBus.Topic.pageCurrentSession,
                                                 ["id": id])
                }
            case "locale":
                // 留特化分支的理由与 currentSession 同款：**壳自己也要用它**
                // （菜单栏、引导页、诊断面板都是壳画的），而且它还要落缓存。
                if let raw = body["locale"] as? String {
                    applyProjectedLocale(raw)
                }
            case "dragPassthrough":
                // 留特化分支的理由与 currentSession / locale 同款：**壳自己要用它**。
                // 顶部拖动条是壳自己的 chrome（`WindowDragRegionView`），没有插件
                // 替得了它，也不该在插件缺席时失效——所以这份数据不经事件总线中转，
                // 页面直接说给壳听。收不到（旧页面、普通浏览器）= 空表 = 今天的行为。
                applyDragPassthrough(body["rects"] as? [[String: Any]] ?? [])
            case "debug":
                Log.write("页内诊断：\(body["msg"] ?? "?")", to: ClamPaths.logURL, tag: "bridge")
            default:
                // 去白名单：壳不认得的 type 一律原样广播成 `clam.page.<type>`。
                // 上面三条留特化分支是因为壳自己也要用（ready 关掉超时警告、
                // debug 落日志），不是因为它们特殊到需要壳批准。
                // 第三方插件接一条新页内消息 = 页面 postMessage + 插件 subscribe，
                // 壳与 SDK 一个字都不用改（壳是预编译产物，第三方改不了它）。
                // 防御式仍在：body 不是字典、type 不是字符串，上面两个 guard 已经拦掉。
                nativeHost.events.emit(ClamEventBus.Topic.pagePrefix + type, body)
            }

        default:
            break
        }
    }

    /// 把页面上报的「可点矩形」装进拖动条。
    ///
    /// 防御式解析：字段缺失或不是数字就整条丢掉——宁可少放行一块（退回今天的
    /// "点了变成拖窗"），也不要拿一个 NaN 矩形去 `contains`（那会让整条带子失去拖动）。
    private func applyDragPassthrough(_ raw: [[String: Any]]) {
        let rects: [NSRect] = raw.compactMap { item in
            guard let x = item["x"] as? Double, let y = item["y"] as? Double,
                  let w = item["w"] as? Double, let h = item["h"] as? Double,
                  x.isFinite, y.isFinite, w.isFinite, h.isFinite, w > 0, h > 0
            else { return nil }
            return NSRect(x: x, y: y, width: w, height: h)
        }
        titleBarDragView.passthroughRects = rects
    }

    // MARK: - NSWindowDelegate

    /// 窗口重新成为关键窗口时（首次显示、从 Dock 恢复、关掉设置窗口后），
    /// 若焦点没有落在更具体的控件上，就把键盘焦点还给 WebView——
    /// 否则 ⌘A/⌘C/⌘V 等快捷键要等用户点进页面才会响应。
    func windowDidBecomeKey(_ notification: Notification) {
        guard let window else { return }
        let fr = window.firstResponder
        if fr === window || fr === window.contentView {
            window.makeFirstResponder(webView)
        }
    }

    // MARK: - 提示

    /// 异步 NSAlert；返回 0 = 第一个按钮。必须在主线程调用。
    /// `buttons` 传 nil = 只有一个"好"（按当前语言）。
    @discardableResult
    private func presentAlert(title: String, message: String, buttons: [String]? = nil) async -> Int {
        let titles = buttons ?? [strings.ok]
        return await withCheckedContinuation { cont in
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            for b in titles { alert.addButton(withTitle: b) }
            let idx = alert.runModal() == .alertFirstButtonReturn ? 0 : 1
            cont.resume(returning: idx)
        }
    }

    // MARK: - WKNavigationDelegate

    // 策略判定转发给 WebPolicy（次级窗口的 WebView 整个归它，两条路同一套判定）。
    // 壳这边留着 delegate 是因为下面几个回调还连着连接状态机与焦点。

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(webPolicy.decide(webView, action: navigationAction))
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(webPolicy.decide(webView, response: navigationResponse))
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        webPolicy.adopt(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        webPolicy.adopt(download)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Log.write("WebView 加载完成：\(webView.url?.absoluteString ?? "?")", to: ClamPaths.logURL, tag: "web")
        // 页面就绪后把键盘焦点交给 WebView，快捷键/输入立即可用
        if let window, window.firstResponder === window || window.firstResponder === window.contentView {
            window.makeFirstResponder(webView)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Log.write("WebView 导航失败：\(error.localizedDescription)", to: ClamPaths.logURL, tag: "web")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Log.write("WebView 加载失败：\(error.localizedDescription)", to: ClamPaths.logURL, tag: "web")
        // dsh 可能正在换端口或还没起完：催一次探测。端点没变就是真加载失败，
        // 延迟重载一次；端点变了/没了，apply 会接管（重装或盖引导页）。
        let before = connection.activeEndpoint
        connection.probeNow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let endpoint = self.connection.activeEndpoint,
                  endpoint == before else { return }
            self.webView.reload()
        }
    }
}

/// 菜单项上挂的"按下去要喊什么"。
///
/// 用 `representedObject` 而不是 selector 或 tag：命令名是插件给的字符串，
/// 壳编译期一个都不认得——做不出对应的 `@objc` 方法，tag 也只装得下一个 Int。
final class MenuCommandBox: NSObject {
    let command: String
    /// 除 `command` 之外要一起带走的载荷（一族命令的序号就装在这儿）。
    let payload: [String: Any]

    init(command: String, payload: [String: Any]) {
        self.command = command
        self.payload = payload
    }
}

/// 插件声明的一条命令，来自桥 snapshot 的 `commands` 字段。
///
/// **形状的权威文档在 `clam-bridge/lib/plugin.js` 的 `CommandDeclaration`**
/// ——声明的一方是插件作者，壳只是读者，所以文档跟着声明走。这里只解析壳用得上的
/// 那几个键：`description` / `keyChoices` 是给 clam-app 拼设置 schema 的，壳不看。
///
/// 缺字段一律有兜底、不整条丢掉（`id` 例外——没有 id 的声明喊不出任何命令）：
/// 一条声明写漏了 `order` 不该让整个菜单消失。
struct ClamCommand: Equatable {

    /// 一族命令：一个设置键装 `count` 个数字键菜单项。
    struct Digits: Equatable {
        let count: Int
        /// 真正 emit 的命令名（`id` 是设置键，两者不是一回事）。
        let command: String
        /// 序号装进载荷的哪个键。
        let argKey: String
    }

    /// 声明者插件名。只用于日志与"同一条被两家声明"的对账。
    let owner: String
    let id: String
    /// nil = 不进菜单栏（执行在页面里的键），只上 ⌘/ 面板。
    let menu: String?
    let menuLabel: [String: String]
    let menuOrder: Int
    let label: [String: String]
    let order: Int
    let separatorBefore: Bool
    /// 默认键位；nil = 没有默认键。
    let key: String?
    let hidden: Bool
    let digits: Digits?

    init?(owner: String, raw: [String: Any]) {
        guard let id = raw["id"] as? String, !id.isEmpty else { return nil }
        self.owner = owner
        self.id = id
        self.menu = raw["menu"] as? String
        self.menuLabel = (raw["menuLabel"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
        self.menuOrder = raw["menuOrder"] as? Int ?? 100
        self.label = (raw["label"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
        self.order = raw["order"] as? Int ?? 100
        self.separatorBefore = raw["separatorBefore"] as? Bool ?? false
        self.key = raw["key"] as? String
        self.hidden = raw["hidden"] as? Bool ?? false
        if let group = raw["digits"] as? [String: Any],
           let command = group["command"] as? String,
           let argKey = group["argKey"] as? String {
            self.digits = Digits(count: group["count"] as? Int ?? 9,
                                 command: command, argKey: argKey)
        } else {
            self.digits = nil
        }
    }

    /// 菜单项文案。`index` 非空时替换 `{n}` 占位（一族命令的第 N 项）。
    /// 一门语言都没给就退回 id——难看，但一眼看得出是谁漏了文案。
    func title(_ locale: ClamLocale, index: Int? = nil) -> String {
        let text = label[locale.rawValue] ?? label[ClamLocale.en.rawValue] ?? id
        guard let index else { return text }
        return text.replacingOccurrences(of: "{n}", with: "\(index)")
    }

    /// 自定义顶级菜单的标题；没声明就是 nil（由调用方决定怎么兜）。
    func menuTitle(_ locale: ClamLocale) -> String? {
        menuLabel[locale.rawValue] ?? menuLabel[ClamLocale.en.rawValue]
    }
}

/// 装在菜单上的那份键位表。
///
/// **默认值不住在这里**：它在插件的命令声明里（`ClamCommand.key`），
/// 与 ns `clam-shortcuts` 的 schema 是同一个上游（clam-app 现拼那张 schema）。
/// 从前壳与 clam-app 各存一份默认表、要求逐字一致而没有任何校验——
/// 分家了不报错，只会变成"设置界面写着 ⌘N，按下去却不是"，那种账极难对。
///
/// 三种形态：
///
/// - 普通命令：spec 字符串 → `bindings`，格式见 `KeymapSpec`；
/// - 一族命令（⌘1-9 那种）：只有修饰键 → `digits`，`off`/空 = 不挂键；
/// - 不进菜单的命令（Esc 停止生成）：壳**不消费它的键**，执行在页面侧，
///   `specs` 里存一份只为 ⌘/ 面板那节不与设置漂移。
struct Keymap: Equatable {

    /// 命令 id → 绑定（一族命令不在这里）。
    var bindings: [String: KeymapSpec.Binding]

    /// 一族命令 id → 修饰键。**双层可选是有意的**：外层缺席 = 没这条命令，
    /// 内层 `nil` = 声明在、但用户关掉了那组键。
    var digits: [String: NSEvent.ModifierFlags?]

    /// 命令 id → 真正生效的 spec 原文。⌘/ 面板列"页面内"那节要用；
    /// 空串 = 禁用（用户显式配空，或声明里就没有默认键）。
    var specs: [String: String]

    /// 一条命令都没有的样子。壳启动时先装它——那一刻插件的声明还没到。
    static let `default` = Keymap(bindings: [:], digits: [:], specs: [:])

    struct Failure {
        let command: String
        /// 用户写的原文。日志要带上它，否则没人知道该去改什么。
        let raw: String
    }

    /// 把设置里那份 `[命令: spec]` 按当前的命令声明解析成键位表。
    ///
    /// **失败不传染**：坏的那条退回声明里的默认、记进 `failed`，其余照常生效
    /// ——一个错别字不该让整套快捷键失灵。**空串是合法值 = 显式禁用**，
    /// 尊重它、不退默认（与页面侧 clam-layout client 的 readKeySpec 同一套语义）。
    ///
    /// 设置里有、声明里没有的键**一律忽略**：插件下线了它的设置值还躺在文件里，
    /// 那时壳按不出那条命令，装上去只会凭空多出一个撞键的幽灵。
    static func resolve(_ values: [String: String],
                        commands: [ClamCommand]) -> (keymap: Keymap, failed: [Failure]) {
        var bindings: [String: KeymapSpec.Binding] = [:]
        var digits: [String: NSEvent.ModifierFlags?] = [:]
        var specs: [String: String] = [:]
        var failed: [Failure] = []

        for command in commands {
            var spec = command.key ?? ""
            if let raw = values[command.id] {
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    spec = ""
                } else if command.digits != nil ? (parseDigits(text) != nil) : (KeymapSpec.parse(text) != nil) {
                    spec = text
                } else {
                    failed.append(Failure(command: command.id, raw: raw))
                }
            }
            specs[command.id] = spec
            if command.digits != nil {
                // 声明里的默认值也可能是错的（插件作者打错字）；那时退到"不挂键"，
                // 菜单项还在，比崩掉整条菜单强。
                digits[command.id] = parseDigits(spec) ?? .some(nil)
            } else {
                bindings[command.id] = KeymapSpec.parse(spec) ?? .disabled
            }
        }

        return (Keymap(bindings: bindings, digits: digits, specs: specs), failed)
    }

    /// 一族命令的修饰键。**双层可选是有意的**：外层 `nil` = 值非法，
    /// 内层 `nil` = `off`（不挂键）——两者都要能表达，而它们不是一回事。
    private static func parseDigits(_ raw: String) -> (NSEvent.ModifierFlags?)? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.isEmpty || text == "off" { return .some(nil) }
        // 空掩码等于"光按数字键就触发"——页面里数字是正常输入，这不能算合法值。
        guard let mask = KeymapSpec.parseModifiers(text), !mask.isEmpty else { return nil }
        return .some(mask)
    }
}
