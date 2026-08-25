import AppKit
import DashSDK
import SwiftUI
import WebKit

/// 顶部透明拖拽条：命中后整窗可拖，
/// 弥补 fullSizeContentView 下原生标题栏被 WebView 盖住、无拖拽区的问题。
/// 用 `performDrag(with:)`（标题栏内部同款 API）手动发起拖拽，
/// 比只靠 `mouseDownCanMoveWindow` 更可靠（后者在该窗口形态下实测不生效）。
private final class WindowDragRegionView: NSView {
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
/// 布局、分栏、侧边栏装配全部搬进 dash-layout 插件，这里负责
/// "定位 dsh、连桥、把 root 槽的视图挂上去、没人占 root 时兜底全出血 WebView"。
@MainActor
final class MainWindowController: NSWindowController, WKNavigationDelegate, NSWindowDelegate {

    /// 窗口最小宽度。sidebar 的自适应折叠归 dash-layout 管，
    /// 这里只兜住"折叠之后窗口还能多窄"。
    static let contentMinWidth: CGFloat = 432

    /// 默认窗口大小（按屏幕可见区域收缩后应用，之后由 autosave 记忆）。
    static let defaultWindowSize = NSSize(width: 1200, height: 800)

    /// 窗口 frame / 分隔条宽度的 autosave key。AppKit 的记忆会盖住代码里的
    /// 默认值，调整默认值时需换 key 才能对已有用户生效。
    private static let windowAutosaveName = "DashMainWindow.v1"

    /// 启动时的目标窗口 frame（默认或 autosave 恢复值）。赋
    /// contentViewController / 插入侧边栏项时 AppKit 会把窗口收缩成内容
    /// fitting size（连 autosave 恢复的 frame 都保不住），布局跑完后用它
    /// 断言拉回；有用户记忆时记忆值优先。
    private var launchWindowFrame: NSRect = .zero

    /// 当前连上的 dsh。nil = 没找到/已断开（引导页在场）。
    private var endpoint: DashEndpoint?
    /// 定位/健康轮询。壳已不是 dsh 的父进程，拿不到退出信号，
    /// 只能靠周期性 GET 发现它走了、也靠它发现它回来了。
    private var connectTimer: Timer?
    private var probeInFlight = false
    private let connectPollInterval: TimeInterval = 2

    /// 原生插件宿主：桥 ↔ 编译机 ↔ 装载器 ↔ registry。壳对插件世界的全部认知都在它那儿。
    let nativeHost = NativePluginHost()

    /// 窗口内容容器：root 宿主 / 顶部拖拽条 / 按需的引导页，三层叠在这里。
    private let containerController = NSViewController()
    /// root 槽的宿主。它内部自己在"插件视图"与"全出血 WebView 兜底"之间切换，
    /// 所以整个 App 生命周期只装配一次。
    private lazy var rootHostingController = NSHostingController(
        rootView: ShellRootView(registry: nativeHost.registry, webView: webView))

    /// 上次载入页面时用的原生侧边栏门控值。插件装载完成后若与实际不符就重载一次页面
    /// （§7.2 第一版接受"切换需重载页面"）。
    private var nativeSidebarParamInUse = MainWindowController.rememberedNativeSidebar

    // 顶部拖拽条高度：比标准标题栏（28pt）更高更好抓，
    // 只管拖拽，不再与网页内容对齐：原生分栏接管排版后，WebView 装在分栏右侧，
    // 网页侧边栏够不着标题栏区域（旧的 dash-nativeify topInset 让位已随之删除）。
    static let titleBarHeight: CGFloat = 40

    private let titleBarDragView = WindowDragRegionView() // 顶部可拖拽条

    /// 桥 ready 监视（8s 超时 → 只记日志；不再回退网页侧边栏模式）。
    private var bridgeReady = false
    private var bridgeWarnWork: DispatchWorkItem?
    private let bridgeReadyTimeout: TimeInterval = 8

    private var bootstrapVC: BootstrapViewController?

    private var diagnosticsPanel: DiagnosticsPanel?

    /// 壳有新版时右上角那条浮动提示（dash-app v1 播报，§7.5）。
    /// 用户点"稍后"就收起，直到下一次播报——不缠人。
    private var updateBanner: ShellUpdateBanner?

    // MARK: - WebView

    private lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        // UA 追加 "Dash/<version>"（带斜杠，防 "dash" 作为普通子串误命中）：
        // dash-nativeify / dash-layout 的 client 半边以此判断页面运行在壳内（终端 dsh web /
        // 普通浏览器共用同一 profile，不受影响）。
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        config.applicationNameForUserAgent = "Dash/\(shortVersion)"
        // 网页 → 原生通道：插件 v2 桥（ready / currentSession 上报）
        config.userContentController.add(WKScriptMessageHandlerProxy(self), name: "dash")
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.setValue(false, forKey: "drawsBackground") // 透明 WebView
        wv.underPageBackgroundColor = .clear
        wv.navigationDelegate = self
        wv.allowsMagnification = true
        // 主 frame 橡皮筋不在原生侧处理：页面滚动由插件注入的
        // overflow:hidden + overscroll-behavior 控制（页面本就不可滚动，
        // 触摸板过度滚动残留的 elastic 拉伸可接受）。曾试过 SPI
        // _setRubberBandingEnabled: 全关四边，会在底部滚动时引发内容闪动。
        return wv
    }()

    init() {
        super.init(window: nil)
        setupWindow()
        setupContentView()
        setupMenus()
        // WKWebView 归壳所有（终极逃生舱要用同一个实例），插件只从保管箱借用：
        // 换代后 makeNSView 返回同一实例 → 页面不重载、JS 状态存活（M2 断言 9）。
        nativeHost.objects.setObject(DashObjects.Key.webView, webView)
        nativeHost.onUpdate = { [weak self] in self?.syncNativeSidebarGate() }
        nativeHost.onAppBuild = { [weak self] state in self?.applyAppBuild(state) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 窗口

    private func setupWindow() {
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultWindowSize),
                           styleMask: style, backing: .buffered, defer: false)
        win.title = AppInfo.displayName
        #if DEBUG
        // Dev 构建窗口标题旁常驻 DEV 徽标，与 Release 一眼区分。
        let devBadge = NSTextField(labelWithString: "DEV")
        devBadge.font = .systemFont(ofSize: 10, weight: .semibold)
        devBadge.textColor = .white
        devBadge.alignment = .center
        devBadge.wantsLayer = true
        devBadge.layer?.cornerRadius = 4
        devBadge.layer?.masksToBounds = true
        devBadge.layer?.backgroundColor = NSColor.systemOrange.cgColor
        devBadge.layer?.opacity = 0.92
        devBadge.translatesAutoresizingMaskIntoConstraints = false
        win.contentView?.addSubview(devBadge)
        NSLayoutConstraint.activate([
            devBadge.topAnchor.constraint(equalTo: win.contentView?.topAnchor, constant: 8),
            devBadge.centerXAnchor.constraint(equalTo: win.contentView?.centerXAnchor),
        ])
        #endif
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

    // MARK: - 连接状态机

    /// 三级定位 → 健康探测 → 接入。同时装上轮询：壳已不是 dsh 的父进程，
    /// 拿不到它的退出信号，只能靠周期性 GET 发现它走了、也发现它回来了。
    func start() {
        showBootstrap("正在寻找 dsh…")
        startConnectPolling()
        probeNow()
    }

    private func startConnectPolling() {
        guard connectTimer == nil else { return }
        let t = Timer(timeInterval: connectPollInterval, repeats: true) { [weak self] _ in
            self?.probeNow()
        }
        RunLoop.main.add(t, forMode: .common)
        connectTimer = t
    }

    /// 探一次。同一时刻只允许一个在飞，慢探测不叠罗汉。
    private func probeNow() {
        guard !probeInFlight else { return }
        probeInFlight = true
        Task { @MainActor [weak self] in
            let found = await EndpointLocator.locateHealthy()
            guard let self else { return }
            self.probeInFlight = false
            self.apply(found)
        }
    }

    /// 把一次探测结果落到界面上。四种去向：稳定（什么都不做）、
    /// 接入、换端点重接、断开。
    private func apply(_ found: DashEndpoint?) {
        guard let found else {
            if endpoint != nil {
                enterDisconnected()
            } else if !guideShown {
                showSearchGuide()
            }
            return
        }
        guard found != endpoint else { return }
        let isReconnect = endpoint != nil
        endpoint = found
        Log.write("接入 dsh：\(found.summary)，来源 \(found.source.rawValue)",
                  to: DashPaths.logURL, tag: "endpoint")
        if isReconnect {
            Log.write("端点变化，插件将随重连的桥重新对齐", to: DashPaths.logURL, tag: "endpoint")
        }
        enterRunning()
    }

    private func enterRunning() {
        hideBootstrap()
        loadWebUI()
        if let endpoint {
            nativeHost.connect(baseURL: endpoint.httpBase, bridgePath: endpoint.bridgePath)
        }
    }

    /// dsh 不见了：停桥、卸镜像、盖引导页。窗口与 WebView 都留着——
    /// dsh 回来时轮询自动把页面重新载上，用户不必重开 App。
    private func enterDisconnected() {
        guard endpoint != nil else { return }
        Log.write("与 dsh 断开连接", to: DashPaths.logURL, tag: "endpoint")
        endpoint = nil
        nativeHost.disconnect()
        webView.stopLoading()
        showBootstrapGuide(
            title: "与 dsh 断开连接",
            detail: "dsh 已退出或不再应答。重新运行下面的命令，\(AppInfo.displayName) 会自动接回。")
    }

    private func showSearchGuide() {
        showBootstrapGuide(
            title: "未检测到 dsh",
            detail: "\(AppInfo.displayName) 是 dsh 的客户端外设，需要 dsh 先在终端跑起来；"
                  + "启动后本页会自动接入，无需重开 App。")
    }

    private func loadWebUI() {
        guard let base = endpoint?.httpBase,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return }
        components.path = "/"
        // 插件门控参数：带上它则网页侧边栏隐藏，由原生 sidebar 槽接管；
        // 不带则完整网页模式（dash-sidebar 缺席时的样子）。
        let native = Self.rememberedNativeSidebar
        nativeSidebarParamInUse = native
        components.queryItems = native
            ? [URLQueryItem(name: "dash-native-sidebar", value: "1")] : nil
        guard let url = components.url else { return }
        webView.load(URLRequest(url: url))
        bridgeReady = false
        armBridgeWarn()
    }

    /// 桥 ready 超时：只记日志（插件失效不再自动回退网页侧边栏模式）。
    private func armBridgeWarn() {
        bridgeWarnWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.bridgeReady else { return }
            Log.write("桥 ready 超时（\(Int(self.bridgeReadyTimeout))s）——插件疑似失效，currentSession 同步将不可用",
                      to: DashPaths.logURL, tag: "bridge")
        }
        bridgeWarnWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + bridgeReadyTimeout, execute: work)
    }

    // MARK: - 重连 / 清理

    /// ⌘⇧R：忘掉当前端点，立刻重走三级定位。
    /// M4 加桥后这里会升级为"经桥请求 dsh 重启自己"（dsh 侧有 appExit 服务）；
    /// M1 还没有反向通道，能做的只是壳这一侧重新接入——dsh 自身的重启归终端。
    func reconnect() {
        nativeHost.disconnect()
        webView.stopLoading()
        endpoint = nil
        showBootstrap("正在重新连接 dsh…")
        probeNow()
    }

    /// 应用退出前调用。M1 起壳不拥有 dsh 进程，收尾只剩自己这一侧的连接，
    /// 不再需要 .terminateLater 等一个进程组死透。
    func shutdown() {
        connectTimer?.invalidate()
        connectTimer = nil
        bridgeWarnWork?.cancel()
        nativeHost.disconnect()
    }

    // MARK: - 原生侧边栏门控

    private static let nativeSidebarDefaultsKey = "dash.nativeSidebar"

    /// 上次运行时是否有原生侧边栏。页面必须在插件编译完成之前就开始加载
    /// （预热 WebView），那时还不知道 sidebar 槽会不会被占，只能先按上次的答案来。
    private static var rememberedNativeSidebar: Bool {
        get { UserDefaults.standard.object(forKey: nativeSidebarDefaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: nativeSidebarDefaultsKey) }
    }

    /// 插件装载稳定后核对一次：实际有没有原生侧边栏与页面加载时的假设不符，
    /// 就更新记忆并重载页面（网页侧边栏随之回归或让位）。
    private func syncNativeSidebarGate() {
        guard nativeHost.didSettle, endpoint != nil else { return }
        let actual = nativeHost.registry.isOccupied("sidebar")
        guard actual != nativeSidebarParamInUse else { return }
        Log.write("原生侧边栏门控变化：\(nativeSidebarParamInUse) → \(actual)，重载页面",
                  to: DashPaths.logURL, tag: "layout")
        Self.rememberedNativeSidebar = actual
        loadWebUI()
    }

    // MARK: - 引导视图

    /// 引导页当前在场且处于 guide 态（非转圈）。轮询每 2s 打一次，
    /// 靠它避免把同一段文案反复重设。
    private var guideShown = false

    /// 引导页盖在 contentView 之上，铺满窗口；重复调用只换文案。
    private func mountBootstrap() -> BootstrapViewController {
        if let vc = bootstrapVC { return vc }
        let vc = BootstrapViewController()
        bootstrapVC = vc
        if let content = window?.contentView {
            let v = vc.view
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v, positioned: .above, relativeTo: nil)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: content.topAnchor),
                v.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                v.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            ])
        }
        return vc
    }

    private func showBootstrap(_ text: String) {
        guideShown = false
        dismissUpdateBanner()
        mountBootstrap().setBusy(text)
    }

    /// 引导态：告诉用户在终端跑 `dsh web`，附可拷贝命令与"重试"。
    /// 重试只是催一次探测——轮询本来就会自己接回来。
    private func showBootstrapGuide(title: String, detail: String) {
        guideShown = true
        dismissUpdateBanner()
        mountBootstrap().setGuide(title: title, detail: detail, command: "dsh web",
                                  retryTitle: "立即重试") { [weak self] in
            self?.showBootstrap("正在寻找 dsh…")
            self?.probeNow()
        }
    }

    private func hideBootstrap() {
        guideShown = false
        bootstrapVC?.view.removeFromSuperview()
        bootstrapVC = nil
    }

    // MARK: - 壳自身的构建（dash-app v1）

    /// 壳重建不是插件热替换那个档位：它要重启进程、丢页面状态。所以默认只提示，
    /// 动手归用户（dash-app 配了 `restartOnRebuild` 才自动走）。
    private func applyAppBuild(_ state: AppBuildState) {
        // 引导页在场 = 此刻连 dsh 都没有，"壳有新版"不是当下该操心的事。
        guard bootstrapVC == nil else { return }
        switch state.status {
        case "building":
            mountUpdateBanner().show(.building)
        case "ready":
            guard !state.autoRestart else {
                Log.write("壳有新版且配置了自动重启，立即重启", to: DashPaths.logURL, tag: "app-build")
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
            onPrimary: { [weak self] kind in
                guard let self else { return }
                switch kind {
                case .ready:
                    self.dismissUpdateBanner()
                    self.nativeHost.requestRestartApp()
                case .failed:
                    NSWorkspace.shared.open(DashPaths.logsDir)
                case .building:
                    break
                }
            },
            onDismiss: { [weak self] in self?.dismissUpdateBanner() })
        updateBanner = banner
        banner.translatesAutoresizingMaskIntoConstraints = false
        let content = containerController.view
        content.addSubview(banner, positioned: .above, relativeTo: nil)
        // 右上角、贴着拖拽条下沿：底部是网页的输入框与发送按钮，盖不得。
        NSLayoutConstraint.activate([
            banner.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            banner.topAnchor.constraint(equalTo: content.topAnchor,
                                        constant: MainWindowController.titleBarHeight + 8),
        ])
        return banner
    }

    private func dismissUpdateBanner() {
        updateBanner?.removeFromSuperview()
        updateBanner = nil
    }

    // MARK: - 菜单

    /// 标准 macOS 菜单：应用 / 文件 / 编辑 / 显示 / 窗口。
    /// 编辑菜单把 ⌘A/⌘C/⌘V/⌘X/⌘Z 等以标准 selector（cut:/copy:/paste:/selectAll:…）
    /// 挂到 nil target（走响应链）——WKWebView 与原生文本框（设置窗口）都会正确响应，
    /// 不再依赖 Web 内容层对裸按键的偶发处理。
    private func setupMenus() {
        let mainMenu = NSMenu()

        // 应用菜单（⌘Q 退出、⌘H 隐藏）
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 \(AppInfo.displayName)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        // 壳自己已无偏好可设（Node 路径/更新频率随 spawn 层退役）；
        // ⌘, 改为经页内桥打开 dsh 自己的设置面板。
        let settingsItem = appMenu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        let reconnectItem = appMenu.addItem(withTitle: "重新连接 dsh",
                                            action: #selector(reconnectNow),
                                            keyEquivalent: "r")
        reconnectItem.keyEquivalentModifierMask = [.command, .shift]
        reconnectItem.target = self
        let logsItem = appMenu.addItem(withTitle: "打开日志目录",
                                       action: #selector(openLogs), keyEquivalent: "")
        logsItem.target = self
        let diagItem = appMenu.addItem(withTitle: "诊断信息…",
                                       action: #selector(showDiagnostics), keyEquivalent: "d")
        diagItem.keyEquivalentModifierMask = [.command, .option]
        diagItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 \(AppInfo.displayName)",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = appMenu.addItem(withTitle: "隐藏其他",
                                             action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "全部显示",
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 \(AppInfo.displayName)",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        appItem.title = AppInfo.displayName

        // 文件菜单（⌘W 关闭窗口）
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(withTitle: "关闭窗口",
                         action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        fileItem.title = "文件"

        // 编辑菜单（⌘Z/⌘⇧Z/⌘X/⌘C/⌘V/⌘A）
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: Selector(("paste:")), keyEquivalent: "v")
        editMenu.addItem(withTitle: "删除", action: Selector(("delete:")), keyEquivalent: "")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "全选", action: Selector(("selectAll:")), keyEquivalent: "a")
        editItem.submenu = editMenu
        editItem.title = "编辑"

        // 显示菜单（⌘R 重载；⌘⌥S 收起/展开侧边栏——系统标准行为）
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "显示")
        let reloadItem = viewMenu.addItem(withTitle: "重新载入页面",
                                          action: #selector(reloadPage), keyEquivalent: "r")
        reloadItem.target = self
        let sidebarItem = viewMenu.addItem(withTitle: "切换侧边栏",
                                           action: Selector(("toggleSidebar:")), keyEquivalent: "s")
        sidebarItem.keyEquivalentModifierMask = [.command, .option]
        viewItem.submenu = viewMenu
        viewItem.title = "显示"

        // 窗口菜单（⌘M 最小化）
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放",
                           action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        windowItem.title = "窗口"
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    /// ⌘,：壳只负责喊一声，谁有能力谁去做（layout 拥有会话展示面）。
    @objc private func openSettings() {
        nativeHost.events.emit(DashEventBus.Topic.menuCommand, ["command": "openSettings"])
    }

    @objc private func reconnectNow() {
        reconnect()
    }

    @objc private func reloadPage() {
        webView.reload()
    }

    @objc private func openLogs() {
        NSWorkspace.shared.open(DashPaths.logsDir)
    }

    /// ⌥⌘D：把壳此刻的全部认知摊平成一屏可拷贝的文本。
    @objc private func showDiagnostics() {
        let panel = diagnosticsPanel ?? DiagnosticsPanel(collect: { [weak self] in
            self?.diagnosticsText() ?? "（窗口已销毁）"
        })
        diagnosticsPanel = panel
        panel.present()
    }

    /// 诊断正文。顺序按"离用户多远"排：先是它连着谁，再是它跑着什么。
    private func diagnosticsText() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        var lines: [String] = []
        lines.append("\(AppInfo.displayName)  \(version)  (\(Bundle.main.bundleIdentifier ?? "?"))")
        lines.append("构建时间：\(AppInfo.buildTimestamp.isEmpty ? "未知" : AppInfo.buildTimestamp)")
        lines.append("")
        lines.append("── dsh 连接 ──")
        if let endpoint {
            lines.append("端点：\(endpoint.summary)")
            lines.append("来源：\(endpoint.source.rawValue)")
        } else {
            lines.append("端点：未连接（引导页在场）")
        }
        lines.append("桥：\(nativeHost.isBridgeConnected ? "已连接" : "未连接")")
        lines.append("页内桥：\(bridgeReady ? "已就绪" : "未就绪")")
        lines.append("原生侧边栏门控：\(nativeSidebarParamInUse ? "开（?dash-native-sidebar=1）" : "关（完整网页模式）")")
        lines.append("")
        lines.append("── 原生插件 ──")
        lines.append("在役 \(nativeHost.loadedCount) 个，本次运行退休 \(nativeHost.retiredThisRun) 个 image")
        if nativeHost.diagnostics.isEmpty {
            lines.append("（一个都没有：root 槽由壳的全出血 WebView 兜底）")
        } else {
            lines.append(contentsOf: nativeHost.diagnostics.map { "  \($0)" })
        }
        lines.append("root 槽占用者：\(nativeHost.registry.owner(of: "root") ?? "无（兜底 WebView）")")
        lines.append("sidebar 槽占用者：\(nativeHost.registry.owner(of: "sidebar") ?? "无")")
        lines.append("")
        lines.append("── 壳自身构建 ──")
        if let build = nativeHost.appBuild {
            lines.append("最近播报：\(build.status)"
                         + (build.hash.map { "  \($0)" } ?? "")
                         + (build.durationMs.map { String(format: "  %.1fs", Double($0) / 1000) } ?? ""))
            if let log = build.log, !log.isEmpty {
                lines.append("日志尾巴：")
                lines.append(contentsOf: log.split(separator: "\n").map { "  \($0)" })
            }
        } else {
            lines.append("本次连接期间没有重建过（dash-app 没播报过 app-build）")
        }
        lines.append("")
        lines.append("── 路径 ──")
        lines.append("日志：\(DashPaths.logsDir.path)")
        lines.append("发现文件：\(DashPaths.endpointURL.path)")
        return lines.joined(separator: "\n")
    }

    // MARK: - 网页 → 原生消息

    /// v2 桥消息（ready / currentSession）。
    func handleBridgeMessage(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        switch message.name {
        case "dash":
            guard let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                bridgeReady = true
                bridgeWarnWork?.cancel()
                bridgeWarnWork = nil
                let caps = body["capabilities"] as? [String] ?? []
                var diag = ""
                if let d = body["diag"] as? [String: Any] {
                    diag = " diag=\(d)"
                }
                Log.write("页内桥就绪：\(caps.joined(separator: ", "))\(diag)", to: DashPaths.logURL, tag: "bridge")
                nativeHost.events.emit(DashEventBus.Topic.pageReady, ["capabilities": caps])
            case "currentSession":
                if let id = body["id"] as? String {
                    nativeHost.events.emit(DashEventBus.Topic.pageCurrentSession, ["id": id])
                }
            case "debug":
                Log.write("页内诊断：\(body["msg"] ?? "?")", to: DashPaths.logURL, tag: "bridge")
            default:
                break // 防御式：未知消息忽略
            }

        default:
            break
        }
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
    @discardableResult
    private func presentAlert(title: String, message: String, buttons: [String] = ["好"]) async -> Int {
        await withCheckedContinuation { cont in
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            for b in buttons { alert.addButton(withTitle: b) }
            let idx = alert.runModal() == .alertFirstButtonReturn ? 0 : 1
            cont.resume(returning: idx)
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Log.write("WebView 加载完成：\(webView.url?.absoluteString ?? "?")", to: DashPaths.logURL, tag: "web")
        // 页面就绪后把键盘焦点交给 WebView，快捷键/输入立即可用
        if let window, window.firstResponder === window || window.firstResponder === window.contentView {
            window.makeFirstResponder(webView)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Log.write("WebView 导航失败：\(error.localizedDescription)", to: DashPaths.logURL, tag: "web")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Log.write("WebView 加载失败：\(error.localizedDescription)", to: DashPaths.logURL, tag: "web")
        // dsh 可能正在换端口或还没起完：催一次探测。端点没变就是真加载失败，
        // 延迟重载一次；端点变了/没了，apply 会接管（重装或盖引导页）。
        let before = endpoint
        probeNow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let endpoint = self.endpoint, endpoint == before else { return }
            self.webView.reload()
        }
    }
}
