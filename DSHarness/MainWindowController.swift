import AppKit
import SwiftUI
import WebKit
import DSHKit
import DSHSidebarUI

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

/// 原生侧边栏右缘拖拽分隔条：cursor 提示 + 拖拽调宽（onDrag 回调返回 dx）。
private final class SidebarDividerView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    private let onDrag: (CGFloat) -> Void
    private var dragging = false

    init(onDrag: @escaping (CGFloat) -> Void) {
        self.onDrag = onDrag
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        dragging = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        // deltaX 是屏幕坐标增量，直接给回调（窗口未移动，等价于本地增量）。
        onDrag(event.deltaX)
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
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

/// 主窗口：透明标题栏 + 左侧 Liquid Glass 侧边栏（NSGlassEffectView）+ 整幅透明 WKWebView，
/// 并驱动整体状态机（安装 → 启动 → 健康 → 载入 Web UI / 通知桥）。
@MainActor
final class MainWindowController: NSWindowController, WKNavigationDelegate, NSWindowDelegate {

    static let sidebarDefaultWidth: CGFloat = 232

    // 红绿灯微调：默认位置紧贴窗口左上角（close 按钮距左/上约 12pt），
    // 往右下挪一点视觉上更自然。当前 (12,12) 使上边距与左边距对齐（均约 24pt）。
    // AppKit 会在窗口 resize / 重新布局时把它们复位到默认位置，
    // 因此 windowDidResize / windowDidBecomeKey 里会重新应用。
    private let trafficLightOffset = NSPoint(x: 12, y: 12)

    // 供 SettingsWindowController 使用
    let harnessManager: HarnessManager

    private let harnessProcess: HarnessProcess
    private var eventsBridge: EventsBridge?
    private var installed: HarnessManager.InstalledHarness?

    // 顶部拖拽条高度：比标准标题栏（28pt）更高更好抓，
    // 需与插件 cordis.patch.yml 的 topInset 保持一致，网页内容才不会钻到条底下。
    static let titleBarHeight: CGFloat = 40

    private let backdropView = NSVisualEffectView() // 右侧普通背景
    // 左侧侧边栏：NSGlassEffectView（macOS 26 Liquid Glass，部署目标 26.0 可直用）。
    // WWDC25「Build an AppKit app with the new design」：新设计里侧边栏直接坐在
    // glass 上，旧的 NSVisualEffectView(.sidebar) 材质会挡住 glass，应移除；
    // 需要自绘 glass 区域时用 NSGlassEffectView（cornerRadius/tint 可调）。
    // 这里不设 contentView：玻璃层只做背景，交互内容是上方透明 WebView。
    private let sidebarView = NSGlassEffectView()
    private let titleBarDragView = WindowDragRegionView() // 顶部可拖拽条

    // MARK: - 原生侧边栏（阶段一）

    /// 是否使用原生侧边栏（逃生舱：显示菜单可翻转；UserDefaults 记忆）。
    private var useNativeSidebar: Bool {
        get { UserDefaults.standard.object(forKey: "useNativeSidebar") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "useNativeSidebar") }
    }
    /// 原生侧边栏宽度（拖拽调宽，UserDefaults 记忆）。
    private var sidebarWidth: CGFloat {
        get {
            let raw = UserDefaults.standard.double(forKey: "nativeSidebarWidth")
            return raw > 0 ? raw : MainWindowController.sidebarDefaultWidth
        }
        set {
            let clamped = min(max(newValue, 180), 420)
            UserDefaults.standard.set(clamped, forKey: "nativeSidebarWidth")
        }
    }
    /// 原生侧边栏收起态。
    private var sidebarCollapsed = false
    private var sidebarCollapsedWidth: CGFloat = 56

    private var sessionStore: SessionStore?
    private var sidebarModel: AppSidebarModel?
    private var conversationSurface: WebViewConversationSurface?
    private var sidebarHostingView: NSHostingView<AnyView>?
    /// 侧边栏右侧拖拽分隔条。
    private lazy var sidebarDividerView: SidebarDividerView = SidebarDividerView { [weak self] dx in
        self?.sidebarDividerDragged(dx: dx)
    }
    /// 桥 ready 监视（8s 超时 → 自动回退全网页模式）。
    private var bridgeReady = false
    private var bridgeFallbackWork: DispatchWorkItem?
    private let bridgeReadyTimeout: TimeInterval = 8

    private var bootstrapVC: BootstrapViewController?
    private var settingsWC: SettingsWindowController?
    private var updateTimer: Timer?
    private var bootTask: Task<Void, Never>?
    private var healthCheckInFlight = false

    // MARK: - WebView

    private lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        // UA 追加 "DSHarness/<version>"：dsharness-web-adapter 插件以此判断
        // 页面运行在壳内（终端 dsh web / 普通浏览器共用同一 profile，不受影响）。
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        config.applicationNameForUserAgent = "DSHarness/\(shortVersion)"
        // 网页 → 原生通道：
        //  - "dsharness"：插件 v2 桥（ready / currentSession 上报）
        //  - "dsharnessSidebar"：v1 玻璃宽度上报（网页侧边栏模式下仍使用）
        config.userContentController.add(WKScriptMessageHandlerProxy(self), name: "dsharnessSidebar")
        config.userContentController.add(WKScriptMessageHandlerProxy(self), name: "dsharness")
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.setValue(false, forKey: "drawsBackground") // 透明 WebView
        wv.underPageBackgroundColor = .clear
        wv.navigationDelegate = self
        wv.allowsMagnification = true
        return wv
    }()

    init(harnessManager: HarnessManager) {
        self.harnessManager = harnessManager
        self.harnessProcess = HarnessProcess(logURL: harnessManager.logURL)
        super.init(window: nil)
        setupWindow()
        setupContentView()
        setupMenus()
        harnessProcess.onState = { [weak self] state in
            DispatchQueue.main.async { self?.handleProcessState(state) }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 窗口

    private func setupWindow() {
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                           styleMask: style, backing: .buffered, defer: false)
        win.title = "DeepSeek Harness"
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.minSize = NSSize(width: 720, height: 480)
        win.backgroundColor = .windowBackgroundColor
        // 关窗只隐藏、不销毁窗口：harness 后台持续运行，点 Dock 图标可原样恢复页面。
        win.isReleasedWhenClosed = false
        win.delegate = self
        self.window = win
        applyTrafficLightOffset()
        win.center()
    }

    private func setupContentView() {
        guard let content = window?.contentView else { return }
        let bounds = content.bounds

        // 注意：contentView 层刻意不用 Auto Layout 约束——
        // 约束解算器会在窗口首次可见时把窗口尺寸解算为 0×0
        // （-[NSWindow _changeWindowFrameFromConstraintsIfNecessary] 经典坑），
        // 全出血布局用 autoresizing 掩码即可。

        backdropView.material = .windowBackground
        backdropView.blendingMode = .behindWindow
        backdropView.state = .followsWindowActiveState
        backdropView.frame = bounds
        backdropView.autoresizingMask = [.width, .height]

        sidebarView.style = .regular
        sidebarView.cornerRadius = 0 // 侧边栏贴窗口左缘全出血，不要圆角
        // 玻璃 tint 随外观动态切换（对齐官方侧边栏观感）：
        // - 浅色：regular 玻璃默认几乎全白，叠一层半透明灰白压成「透的白灰」；
        // - 深色：实测 32% 纯黑会把玻璃压成 rgb(36,39,44)（偏暗偏蓝），
        //   系统深色侧边栏约 rgb(50,50,55) 中性——改用低 alpha 白微提亮。
        sidebarView.tintColor = NSColor(name: "dsharness-sidebar-glass") { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(calibratedWhite: 1, alpha: 0.06)
                : NSColor(calibratedWhite: 0.62, alpha: 0.30)
        }
        sidebarView.frame = NSRect(x: 0, y: 0, width: MainWindowController.sidebarDefaultWidth, height: bounds.height)
        sidebarView.autoresizingMask = [.height]

        content.addSubview(backdropView)
        content.addSubview(sidebarView)
        content.addSubview(webView)
        content.addSubview(titleBarDragView)

        // WebView 不再全出血：原生侧边栏模式下只占侧边栏右侧区域
        //（autoresizing 手动布局，沿用现有风格）。
        // 注意：原生侧边栏的装配推迟到 loadWebUI（此时端口才确定），
        // 这里只按当前模式摆初始 frame。
        if useNativeSidebar {
            let sidebarW = sidebarCollapsed ? sidebarCollapsedWidth : sidebarWidth
            webView.frame = NSRect(x: sidebarW, y: 0,
                                   width: bounds.width - sidebarW, height: bounds.height)
        } else {
            webView.frame = bounds // v1 全出血（网页侧边栏透明化 + 玻璃跟随）
        }
        webView.autoresizingMask = [.width, .height]

        // 顶部透明拖拽条（titleBarHeight，比标准 28pt 更高更好抓），随窗口宽度伸缩、贴顶。
        titleBarDragView.frame = NSRect(x: 0, y: bounds.height - MainWindowController.titleBarHeight,
                                        width: bounds.width, height: MainWindowController.titleBarHeight)
        titleBarDragView.autoresizingMask = [.width, .minYMargin]
    }

    // MARK: - 原生侧边栏装配

    /// 装配原生侧边栏：NSHostingView(SidebarView) 叠在玻璃层上，同宽联动；
    /// 分隔条贴在右缘供拖拽调宽。WebView 移到侧边栏右侧。
    private func installNativeSidebar(width: CGFloat) {
        guard sidebarHostingView == nil,
              let content = window?.contentView else { return }

        conversationSurface = WebViewConversationSurface(webView: webView)
        let store = SessionStore(transport: DSHTransportFactory.live(
            baseURL: URL(string: "http://127.0.0.1:\(harnessProcess.port)")!))
        sessionStore = store
        let model = AppSidebarModel(store: store, surface: conversationSurface!,
                                    logURL: harnessManager.logURL)
        sidebarModel = model

        let rootView = AnyView(SidebarView(
            model: model,
            surface: conversationSurface!,
            topInset: MainWindowController.titleBarHeight,
            collapsed: sidebarCollapsed,
            onToggleCollapse: { [weak self] in
                self?.toggleSidebarCollapsed()
            }))
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: content.bounds.height)
        hosting.autoresizingMask = [.height]
        sidebarHostingView = hosting

        // 侧边栏右侧拖拽分隔条（在 WebView 之下、玻璃之上）
        content.addSubview(sidebarDividerView, positioned: .below, relativeTo: webView)
        sidebarDividerView.frame = NSRect(x: width - 4, y: 0, width: 8, height: content.bounds.height)
        sidebarDividerView.autoresizingMask = [.height]

        layoutNativeSidebar()
        Task { await store.start() }
    }

    /// 移除原生侧边栏（切回网页侧边栏模式）。
    private func uninstallNativeSidebar() {
        sessionStore?.stop()
        sessionStore = nil
        sidebarModel = nil
        conversationSurface = nil
        sidebarHostingView?.removeFromSuperview()
        sidebarHostingView = nil
        sidebarDividerView.removeFromSuperview()
    }

    /// 布局三件套：玻璃 / SidebarView / 分隔条 同宽，WebView 移到右侧。
    private func layoutNativeSidebar() {
        guard let content = window?.contentView else { return }
        let w = sidebarCollapsed ? sidebarCollapsedWidth : sidebarWidth
        var f = sidebarView.frame
        f.size.width = w
        sidebarView.frame = f
        sidebarHostingView?.frame = NSRect(x: 0, y: 0, width: w, height: content.bounds.height)
        sidebarDividerView.frame = NSRect(x: w - 4, y: 0, width: 8, height: content.bounds.height)
        webView.frame = NSRect(x: w, y: 0, width: content.bounds.width - w, height: content.bounds.height)
    }

    private func toggleSidebarCollapsed() {
        sidebarCollapsed.toggle()
        withAnimation(.easeInOut(duration: 0.2)) {
            layoutNativeSidebar()
        }
        refreshSidebarRootView()
    }

    /// collapsed 状态变化后重建 SwiftUI root（简单起见不搞双向绑定桥）。
    private func refreshSidebarRootView() {
        guard let model = sidebarModel, let surface = conversationSurface,
              let hosting = sidebarHostingView else { return }
        hosting.rootView = AnyView(SidebarView(
            model: model,
            surface: surface,
            topInset: MainWindowController.titleBarHeight,
            collapsed: sidebarCollapsed,
            onToggleCollapse: { [weak self] in
                self?.toggleSidebarCollapsed()
            }))
    }

    private func sidebarDividerDragged(dx: CGFloat) {
        guard !sidebarCollapsed else { return }
        let newWidth = min(max(sidebarWidth + dx, 180), 420)
        guard abs(newWidth - sidebarWidth) > 0.5 else { return }
        sidebarWidth = newWidth
        layoutNativeSidebar()
    }

    // MARK: - 红绿灯微调

    /// 各按钮上一次应用后的 frame；用于判断 AppKit 是否已把按钮复位回默认位置。
    private var trafficLightAppliedFrames: [NSWindow.ButtonType: NSRect] = [:]

    /// 把三个红绿灯从系统默认位置往右下挪 trafficLightOffset（幂等）。
    /// 不存固定基准：按钮 frame 是窗口坐标系（原点左下）里的绝对坐标，
    /// resize 后系统复位到的位置会随窗口高度变化，因此每次以「当前 frame + 偏移」重算；
    /// 若当前 frame 仍是我们上一次应用的位置，说明系统没动过它，直接跳过。
    private func applyTrafficLightOffset() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for type in types {
            guard let button = window.standardWindowButton(type) else { continue }
            let current = button.frame
            if trafficLightAppliedFrames[type] == current { continue } // 未被复位，跳过
            // 视觉方向换算：按钮 frame 位于非翻转坐标系（原点左下），“向下”要减 y。
            let flipped = button.superview?.isFlipped ?? false
            let dy = flipped ? trafficLightOffset.y : -trafficLightOffset.y
            let target = NSRect(x: current.minX + trafficLightOffset.x,
                                y: current.minY + dy,
                                width: current.width,
                                height: current.height)
            button.setFrameOrigin(target.origin)
            trafficLightAppliedFrames[type] = target
        }
    }

    // MARK: - 状态机

    func start() {
        showBootstrap("准备启动…")
        bootTask = Task { [weak self] in
            guard let self else { return }
            await self.boot()
        }
    }

    private func boot() async {
        do {
            let installed = try await harnessManager.ensureInstalled()
            self.installed = installed
            showBootstrap("正在启动 harness v\(installed.version)…")
            let port = HarnessProcess.pickFreePort()
            guard port > 0 else { return fail("无法分配空闲端口") }
            try harnessProcess.start(entry: installed.entry,
                                     node: harnessManager.node,
                                     runWithNode: installed.runWithNode,
                                     home: FileManager.default.homeDirectoryForCurrentUser,
                                     port: port)
        } catch {
            fail("安装失败：\(error.localizedDescription)")
        }
    }

    private func handleProcessState(_ state: HarnessProcess.State) {
        switch state {
        case .starting:
            guard !healthCheckInFlight else { return }
            healthCheckInFlight = true
            HarnessProcess.waitUntilHealthy(port: harnessProcess.port, timeout: 60) { [weak self] ok in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.healthCheckInFlight = false
                    if ok {
                        self.enterRunning()
                    } else {
                        self.handleHealthTimeout()
                    }
                }
            }
        case .restarting(let attempt):
            showBootstrap("harness 意外退出，正在重启（第 \(attempt) 次）…")
        case .failed(let reason):
            fail("harness 启动失败：\(reason)")
        case .stopped:
            break
        default:
            break
        }
    }

    private func enterRunning() {
        hideBootstrap()
        loadWebUI()
        startEventsBridge()
        scheduleUpdateCheck()
    }

    private func handleHealthTimeout() {
        if harnessProcess.isRunning() {
            // 进程活着但端口不健康：大概率端口被占，换端口重试
            terminateAsync(wait: 2)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.restartWithNewPort()
            }
        } else {
            fail("harness 启动超时（60s 内未就绪）")
        }
    }

    /// terminate 会轮询等待，放到后台队列避免卡主线程。
    private func terminateAsync(wait: TimeInterval) {
        DispatchQueue.global().async { [weak self] in
            self?.harnessProcess.terminate(waitTimeout: wait)
        }
    }

    private func restartWithNewPort() {
        guard let installed else { return }
        let port = HarnessProcess.pickFreePort()
        guard port > 0 else { return fail("无法分配空闲端口") }
        do {
            try harnessProcess.start(entry: installed.entry,
                                     node: harnessManager.node,
                                     runWithNode: installed.runWithNode,
                                     home: FileManager.default.homeDirectoryForCurrentUser,
                                     port: port)
        } catch {
            fail("重启失败：\(error.localizedDescription)")
        }
    }

    private func loadWebUI() {
        var components = URLComponents(string: "http://127.0.0.1:\(harnessProcess.port)/")!
        if useNativeSidebar {
            // 插件 v2 门控参数：网页侧边栏隐藏，原生侧边栏接管。
            components.queryItems = [URLQueryItem(name: "dsharness-native-sidebar", value: "1")]
        }
        guard let url = components.url else { return }
        webView.load(URLRequest(url: url))
        // 原生模式下启动 DSHKit 镜像 + 桥 ready 超时监视
        if useNativeSidebar {
            bridgeReady = false
            armBridgeFallback()
            // harness 重启后端口会变：镜像若已停则整件重装（transport 持旧端口）。
            if sessionStore == nil { uninstallNativeSidebar() }
            installNativeSidebar(width: sidebarCollapsed ? sidebarCollapsedWidth : sidebarWidth)
        }
    }

    /// 桥 ready 超时：页面加载完成 8s 未见 ready → 插件失效（上游 breaking change 等），
    /// 自动回退网页侧边栏模式并记录原因。
    private func armBridgeFallback() {
        bridgeFallbackWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.useNativeSidebar, !self.bridgeReady else { return }
            Log.write("桥 ready 超时（\(Int(self.bridgeReadyTimeout))s）——插件疑似失效，自动回退网页侧边栏模式",
                      to: self.harnessManager.logURL, tag: "bridge")
            self.setNativeSidebar(false, reason: "auto-fallback")
        }
        bridgeFallbackWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + bridgeReadyTimeout, execute: work)
    }

    /// 切换原生/网页侧边栏（菜单开关与自动回退共用）。
    private func setNativeSidebar(_ enabled: Bool, reason: String) {
        guard useNativeSidebar != enabled else { return }
        useNativeSidebar = enabled
        bridgeFallbackWork?.cancel()
        bridgeFallbackWork = nil
        if enabled {
            installNativeSidebar(width: sidebarCollapsed ? sidebarCollapsedWidth : sidebarWidth)
        } else {
            uninstallNativeSidebar()
            // 恢复玻璃宽度跟随网页侧边栏
            var f = sidebarView.frame
            f.size.width = MainWindowController.sidebarDefaultWidth
            sidebarView.frame = f
            webView.frame = contentBounds()
        }
        Log.write("侧边栏模式 → \(enabled ? "原生" : "网页")（\(reason)）", to: harnessManager.logURL, tag: "bridge")
        loadWebUI()
    }

    private func contentBounds() -> NSRect {
        window?.contentView?.bounds ?? .zero
    }

    private func startEventsBridge() {
        eventsBridge?.stop()
        let bridge = EventsBridge(port: harnessProcess.port)
        eventsBridge = bridge
        bridge.start()
    }

    // MARK: - 更新检查

    func scheduleUpdateCheck() {
        let hours = Settings.updateIntervalHours
        guard hours > 0 else { return }
        rescheduleUpdateTimer()
        // 启动时静默检查一次
        Task { await self.checkUpdates(force: false, silent: true) }
    }

    func rescheduleUpdateTimer() {
        updateTimer?.invalidate()
        updateTimer = nil
        let hours = Settings.updateIntervalHours
        guard hours > 0 else { return }
        let t = Timer(timeInterval: hours * 3600, repeats: true) { [weak self] _ in
            Task { await self?.checkUpdates(force: false, silent: true) }
        }
        RunLoop.main.add(t, forMode: .common)
        updateTimer = t
    }

    func checkUpdates(force: Bool, silent: Bool) async {
        let result = await harnessManager.checkForUpdates(force: force)
        switch result {
        case .upToDate(let current):
            if force && !silent {
                await presentAlert(title: "已是最新", message: "当前 harness 版本：\(current)")
            }
        case .updated(let from, let to):
            UserDefaults.standard.set(to, forKey: "pendingUpdateVersion")
            let action = await presentAlert(
                title: "harness 已更新：\(from) → \(to)",
                message: "旧版本已保留用于回滚。重启 harness 后生效。",
                buttons: ["立即重启", "稍后"]
            )
            if action == 0 { restartHarness() }
        case .failed(let reason):
            if force || !silent {
                await presentAlert(title: "检查更新失败", message: reason)
            } else {
                Log.write("后台更新检查失败：\(reason)", tag: "update")
            }
        }
    }

    // MARK: - 重启 / 清理

    func restartHarness() {
        eventsBridge?.stop()
        sessionStore?.stop()
        webView.stopLoading()
        showBootstrap("正在重启 harness…")
        let port = HarnessProcess.pickFreePort()
        terminateAsync(wait: 4)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, let installed = self.installed else { return }
            do {
                try self.harnessProcess.start(entry: installed.entry,
                                              node: self.harnessManager.node,
                                              runWithNode: installed.runWithNode,
                                              home: FileManager.default.homeDirectoryForCurrentUser,
                                              port: port)
            } catch {
                self.fail("重启失败：\(error.localizedDescription)")
            }
        }
    }

    /// 应用退出前调用：停桥、杀进程组。terminate 阻塞轮询（最长 5s + 1s），
    /// 同 terminateAsync 放后台队列，收完再回主线程 completion 放行退出。
    func shutdown(completion: @escaping () -> Void) {
        bootTask?.cancel()
        eventsBridge?.stop()
        sessionStore?.stop()
        let process = harnessProcess
        DispatchQueue.global(qos: .userInitiated).async {
            process.terminate(waitTimeout: 5)
            DispatchQueue.main.async(execute: completion)
        }
    }

    // MARK: - 引导视图

    private func showBootstrap(_ text: String) {
        if bootstrapVC == nil {
            let vc = BootstrapViewController()
            bootstrapVC = vc
            if let content = window?.contentView {
                let v = vc.view
                v.frame = content.bounds
                v.autoresizingMask = [.width, .height]
                content.addSubview(v, positioned: .above, relativeTo: nil)
            }
        }
        bootstrapVC?.setBusy(text)
    }

    private func hideBootstrap() {
        bootstrapVC?.view.removeFromSuperview()
        bootstrapVC = nil
    }

    private func fail(_ reason: String) {
        Log.write("FAIL：\(reason)", to: harnessManager.logURL)
        showBootstrapError(reason)
    }

    private func showBootstrapError(_ reason: String) {
        if bootstrapVC == nil {
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
        }
        bootstrapVC?.setError(reason) { [weak self] in
            self?.start()
        }
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
        appMenu.addItem(withTitle: "关于 DeepSeek Harness",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = appMenu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        let checkItem = appMenu.addItem(withTitle: "检查 harness 更新",
                                        action: #selector(checkForUpdatesNow), keyEquivalent: "u")
        checkItem.target = self
        let restartItem = appMenu.addItem(withTitle: "重启 Harness",
                                          action: #selector(restartHarnessNow),
                                          keyEquivalent: "r")
        restartItem.keyEquivalentModifierMask = [.command, .shift]
        restartItem.target = self
        let logsItem = appMenu.addItem(withTitle: "打开日志目录",
                                       action: #selector(openLogs), keyEquivalent: "")
        logsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 DeepSeek Harness",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = appMenu.addItem(withTitle: "隐藏其他",
                                             action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "全部显示",
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 DeepSeek Harness",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        appItem.title = "DeepSeek Harness"

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

        // 显示菜单（⌘R 重载；玻璃切换无快捷键，避免占用 ⌘V 粘贴）
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "显示")
        let reloadItem = viewMenu.addItem(withTitle: "重新载入页面",
                                          action: #selector(reloadPage), keyEquivalent: "r")
        reloadItem.target = self
        let toggleItem = viewMenu.addItem(withTitle: "切换侧边栏玻璃效果",
                                          action: #selector(toggleSidebarGlass), keyEquivalent: "")
        toggleItem.target = self
        let nativeItem = viewMenu.addItem(withTitle: "使用原生侧边栏",
                                          action: #selector(toggleNativeSidebar), keyEquivalent: "")
        nativeItem.target = self
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

    @objc private func openSettings() {
        if settingsWC == nil {
            settingsWC = SettingsWindowController(mainController: self)
        }
        settingsWC?.showWindow(nil)
    }

    @objc private func checkForUpdatesNow() {
        Task { await self.checkUpdates(force: true, silent: false) }
    }

    @objc private func restartHarnessNow() {
        restartHarness()
    }

    @objc private func reloadPage() {
        webView.reload()
    }

    @objc private func openLogs() {
        let dir = harnessManager.appSupport.appendingPathComponent("logs", isDirectory: true)
        NSWorkspace.shared.open(dir)
    }

    @objc private func toggleSidebarGlass() {
        let hidden = sidebarView.isHidden
        sidebarView.isHidden = !hidden
    }

    /// 逃生舱开关：翻转 → 隐藏原生侧边栏 + 去参数重载 WebView（恢复完整 Web UI）。
    @objc private func toggleNativeSidebar() {
        setNativeSidebar(!useNativeSidebar, reason: "menu-toggle")
    }

    // MARK: - 网页 → 原生消息

    /// v1 玻璃宽度跟随（网页侧边栏模式）+ v2 桥消息（ready / currentSession）。
    func handleBridgeMessage(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        switch message.name {
        case "dsharnessSidebar":
            // 插件 v1 上报网页侧边栏列宽度（px）。网页 1px ≈ 屏幕 1pt（WKWebView
            // 默认无缩放），直接同步 NSGlassEffectView 宽度；钳制在合理区间防异常值。
            guard let raw = body["width"] as? Double else { return }
            let width = min(max(CGFloat(raw), 0), 600)
            guard abs(width - sidebarView.frame.width) > 0.5 else { return }
            var frame = sidebarView.frame
            frame.size.width = width
            sidebarView.frame = frame
            // 网页侧边栏模式下 WebView 仍需全出血（宽度跟随）
            if !useNativeSidebar {
                webView.frame = NSRect(x: width, y: 0,
                                       width: contentBounds().width - width,
                                       height: contentBounds().height)
            }

        case "dsharness":
            guard let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                bridgeReady = true
                bridgeFallbackWork?.cancel()
                bridgeFallbackWork = nil
                let caps = body["capabilities"] as? [String] ?? []
                var diag = ""
                if let d = body["diag"] as? [String: Any] {
                    diag = " diag=\(d)"
                }
                Log.write("页内桥就绪：\(caps.joined(separator: ", "))\(diag)", to: harnessManager.logURL, tag: "bridge")
            case "currentSession":
                if let id = body["id"] as? String {
                    sidebarModel?.pageDidSelect(sessionId: id)
                }
            case "debug":
                Log.write("页内诊断：\(body["msg"] ?? "?")", to: harnessManager.logURL, tag: "bridge")
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
        // 首次显示/从 Dock 恢复时标题栏可能被 AppKit 重新布局，红绿灯会复位，重新应用偏移。
        applyTrafficLightOffset()
        guard let window else { return }
        let fr = window.firstResponder
        if fr === window || fr === window.contentView {
            window.makeFirstResponder(webView)
        }
    }

    /// 窗口尺寸变化时 AppKit 会把红绿灯复位到默认位置，这里重新应用偏移。
    func windowDidResize(_ notification: Notification) {
        applyTrafficLightOffset()
        if useNativeSidebar {
            layoutNativeSidebar()
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

    // MARK: - WKNavigationDelegate（防御式：注入失败不影响功能）

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Log.write("WebView 加载完成：\(webView.url?.absoluteString ?? "?")", to: harnessManager.logURL, tag: "web")
        // 页面就绪后把键盘焦点交给 WebView，快捷键/输入立即可用
        if let window, window.firstResponder === window || window.firstResponder === window.contentView {
            window.makeFirstResponder(webView)
        }
        // 诊断：SPA 异步挂载，延迟再查一次 DOM（仅日志，不影响功能）
        let script = """
        JSON.stringify({
            title: document.title,
            rootChildren: (document.getElementById('root') ? document.getElementById('root').children.length : -1),
            bodyTextLen: document.body ? document.body.innerText.length : -1,
            bodyText: document.body ? document.body.innerText.slice(0, 400) : '',
            interactiveEls: document.querySelectorAll('button,a,input,textarea,[role]').length,
            url: location.href
        })
        """
        webView.evaluateJavaScript(script) { result, _ in
            if let s = result as? String {
                Log.write("WebView DOM(0s)：\(s)", to: self.harnessManager.logURL, tag: "web")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            webView.evaluateJavaScript(script) { result, _ in
                if let s = result as? String {
                    Log.write("WebView DOM(3s)：\(s)", to: self.harnessManager.logURL, tag: "web")
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Log.write("WebView 导航失败：\(error.localizedDescription)", to: harnessManager.logURL, tag: "web")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Log.write("WebView 加载失败：\(error.localizedDescription)", to: harnessManager.logURL, tag: "web")
        // 页面尚未载入过且进程可能刚重启：延迟重载一次
        if harnessProcess.isRunning() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.webView.reload()
            }
        }
    }
}
