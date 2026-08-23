import AppKit
import WebKit

/// 主窗口：透明标题栏 + 左侧 vibrancy 侧边栏 + 整幅透明 WKWebView，
/// 并驱动整体状态机（安装 → 启动 → 健康 → 载入 Web UI / 通知桥）。
@MainActor
final class MainWindowController: NSWindowController, WKNavigationDelegate, WKScriptMessageHandler, NSWindowDelegate {

    static let sidebarDefaultWidth: CGFloat = 232

    // 供 SettingsWindowController 使用
    let harnessManager: HarnessManager

    private let harnessProcess: HarnessProcess
    private var eventsBridge: EventsBridge?
    private var installed: HarnessManager.InstalledHarness?

    private let backdropView = NSVisualEffectView() // 右侧普通背景
    private let sidebarView = NSVisualEffectView()  // 左侧 vibrancy
    private var currentSidebarWidth: CGFloat = MainWindowController.sidebarDefaultWidth

    private var bootstrapVC: BootstrapViewController?
    private var settingsWC: SettingsWindowController?
    private var updateTimer: Timer?
    private var bootTask: Task<Void, Never>?
    private var healthCheckInFlight = false

    // MARK: - WebView（lazy：注入脚本需先配好 userContentController）

    private lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.add(self, name: "sidebar")
        if let script = Self.buildInjectionScript() {
            ucc.addUserScript(script)
        }
        config.userContentController = ucc
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
        win.delegate = self
        self.window = win
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
        sidebarView.frame = NSRect(x: 0, y: 0, width: currentSidebarWidth, height: bounds.height)
        sidebarView.autoresizingMask = [.height]

        content.addSubview(backdropView)
        content.addSubview(sidebarView)
        content.addSubview(webView)

        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
    }

    // MARK: - 注入脚本

    /// 组装注入脚本：SidebarInjection.js + 内嵌 CSS（base64 防转义问题）。
    static func buildInjectionScript() -> WKUserScript? {
        let bundle = Bundle.main
        guard let jsURL = bundle.url(forResource: "SidebarInjection", withExtension: "js"),
              let cssURL = bundle.url(forResource: "SidebarInjection", withExtension: "css"),
              let js = try? String(contentsOf: jsURL, encoding: .utf8),
              let css = try? String(contentsOf: cssURL, encoding: .utf8) else {
            return nil
        }
        let cssB64 = css.data(using: .utf8)!.base64EncodedString()
        let combined = js.replacingOccurrences(of: "__CSS_B64__", with: cssB64)
        return WKUserScript(source: combined, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }

    // MARK: - WKScriptMessageHandler（侧边栏宽度同步）

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "sidebar",
              let dict = message.body as? [String: Any],
              let type = dict["type"] as? String, type == "width",
              let width = dict["width"] as? Double else { return }
        let w = min(max(CGFloat(width), 120), 480)
        guard abs(w - currentSidebarWidth) > 4 else { return }
        setSidebarWidth(w)
    }

    private func setSidebarWidth(_ width: CGFloat) {
        currentSidebarWidth = width
        var f = sidebarView.frame
        f.size.width = width
        sidebarView.frame = f
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

    private func setupMenus() {
        let mainMenu = NSMenu()

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
        appMenu.addItem(withTitle: "退出 DSHarness",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        appItem.title = "DSHarness"

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "显示")
        let reloadItem = viewMenu.addItem(withTitle: "重新载入页面",
                                          action: #selector(reloadPage), keyEquivalent: "r")
        reloadItem.target = self
        let toggleItem = viewMenu.addItem(withTitle: "切换侧边栏 Vibrancy",
                                          action: #selector(toggleVibrancy), keyEquivalent: "v")
        toggleItem.target = self
        viewItem.submenu = viewMenu
        viewItem.title = "显示"

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

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Log.write("WebView 导航失败：\(error.localizedDescription)", tag: "web")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Log.write("WebView 加载失败：\(error.localizedDescription)", tag: "web")
        // 页面尚未载入过且进程可能刚重启：延迟重载一次
        if harnessProcess.isRunning() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.webView.reload()
            }
        }
    }
}
