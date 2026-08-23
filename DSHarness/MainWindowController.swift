import AppKit
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

/// 主窗口：透明标题栏 + 左侧 vibrancy 侧边栏 + 整幅透明 WKWebView，
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
    private let sidebarView = NSVisualEffectView()  // 左侧 vibrancy
    private let titleBarDragView = WindowDragRegionView() // 顶部可拖拽条

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
        win.title = "DSHarness"
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

        sidebarView.material = .sidebar
        sidebarView.blendingMode = .behindWindow
        sidebarView.state = .followsWindowActiveState
        sidebarView.frame = NSRect(x: 0, y: 0, width: MainWindowController.sidebarDefaultWidth, height: bounds.height)
        sidebarView.autoresizingMask = [.height]

        content.addSubview(backdropView)
        content.addSubview(sidebarView)
        content.addSubview(webView)
        content.addSubview(titleBarDragView)

        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]

        // 顶部透明拖拽条（titleBarHeight，比标准 28pt 更高更好抓），随窗口宽度伸缩、贴顶。
        titleBarDragView.frame = NSRect(x: 0, y: bounds.height - MainWindowController.titleBarHeight,
                                        width: bounds.width, height: MainWindowController.titleBarHeight)
        titleBarDragView.autoresizingMask = [.width, .minYMargin]
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
        guard let url = URL(string: "http://127.0.0.1:\(harnessProcess.port)/") else { return }
        webView.load(URLRequest(url: url))
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

    /// 应用退出前调用：停桥、杀进程组。
    func shutdown() {
        bootTask?.cancel()
        eventsBridge?.stop()
        harnessProcess.terminate(waitTimeout: 5)
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
        appMenu.addItem(withTitle: "关于 DSHarness",
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
        appMenu.addItem(withTitle: "隐藏 DSHarness",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = appMenu.addItem(withTitle: "隐藏其他",
                                             action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "全部显示",
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 DSHarness",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        appItem.title = "DSHarness"

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

        // 显示菜单（⌘R 重载；vibrancy 不再占 ⌘V）
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "显示")
        let reloadItem = viewMenu.addItem(withTitle: "重新载入页面",
                                          action: #selector(reloadPage), keyEquivalent: "r")
        reloadItem.target = self
        let toggleItem = viewMenu.addItem(withTitle: "切换侧边栏 Vibrancy",
                                          action: #selector(toggleVibrancy), keyEquivalent: "")
        toggleItem.target = self
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

    @objc private func toggleVibrancy() {
        let hidden = sidebarView.isHidden
        sidebarView.isHidden = !hidden
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
