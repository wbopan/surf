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

/// 主窗口：NSSplitViewController（sidebar 项 + WKWebView 内容项），
/// Mail 式原生侧边栏；材质/分隔条/调宽/收起/宽度记忆全交系统。
/// 并驱动整体状态机（安装 → 启动 → 健康 → 载入 Web UI / 通知桥）。
@MainActor
final class MainWindowController: NSWindowController, WKNavigationDelegate, NSWindowDelegate {

    /// 侧边栏首次显示的默认宽度（之后由 NSSplitViewItem autosave 记忆）。
    static let sidebarDefaultWidth: CGFloat = 280

    // 供 SettingsWindowController 使用
    let harnessManager: HarnessManager

    private let harnessProcess: HarnessProcess
    private var eventsBridge: EventsBridge?
    private var installed: HarnessManager.InstalledHarness?

    // 顶部拖拽条高度：比标准标题栏（28pt）更高更好抓，
    // 需与插件 cordis.patch.yml 的 topInset 保持一致，网页内容才不会钻到条底下。
    static let titleBarHeight: CGFloat = 40

    // 分割视图：侧边栏项 + 内容项。系统负责材质（macOS 26 上即 Liquid Glass）、
    // 分隔条、拖拽调宽、双击复位、宽度 autosave、收起动画与红绿灯布局。
    private let splitViewController = NSSplitViewController()
    /// 侧边栏 split item（loadWebUI 时端口确定后才装配）。
    private var sidebarSplitItem: NSSplitViewItem?
    /// 内容项：WKWebView 直接作为 VC 的 view（全出血，标题栏透明）。
    private lazy var webViewController: NSViewController = {
        let vc = NSViewController()
        vc.view = webView
        return vc
    }()
    private let titleBarDragView = WindowDragRegionView() // 顶部可拖拽条

    // MARK: - 原生侧边栏（阶段二·Mail 风格）

    private var sessionStore: SessionStore?
    /// 当前 sessionStore 的 transport 所指端口；harness 换端口后据此判断是否整件重装。
    private var sessionStorePort = -1
    private var sidebarModel: AppSidebarModel?
    private var conversationSurface: WebViewConversationSurface?
    /// 桥 ready 监视（8s 超时 → 只记日志；不再回退网页侧边栏模式）。
    private var bridgeReady = false
    private var bridgeWarnWork: DispatchWorkItem?
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
        // 网页 → 原生通道：插件 v2 桥（ready / currentSession 上报）
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
        win.center()
    }

    private func setupContentView() {
        // NSSplitViewController 全权负责布局：侧边栏项在 loadWebUI 时端口
        // 确定后才插入，装配前 bootstrap 覆盖整个窗口，不露馅。
        window?.contentViewController = splitViewController

        let contentItem = NSSplitViewItem(viewController: webViewController)
        contentItem.canCollapse = false
        splitViewController.addSplitViewItem(contentItem)

        // 顶部透明拖拽条（titleBarHeight，比标准 28pt 更高更好抓）：
        // fullSizeContentView 下原生标题栏被 WebView 盖住，需要它发起整窗拖拽。
        let drag = titleBarDragView
        drag.translatesAutoresizingMaskIntoConstraints = false
        splitViewController.view.addSubview(drag)
        NSLayoutConstraint.activate([
            drag.topAnchor.constraint(equalTo: splitViewController.view.topAnchor),
            drag.leadingAnchor.constraint(equalTo: splitViewController.view.leadingAnchor),
            drag.trailingAnchor.constraint(equalTo: splitViewController.view.trailingAnchor),
            drag.heightAnchor.constraint(equalToConstant: MainWindowController.titleBarHeight),
        ])
    }

    // MARK: - 原生侧边栏装配

    /// 装配侧边栏：NSHostingController(SidebarView) 塞进 sidebar split item；
    /// 材质/分隔条/调宽/宽度记忆交给系统。
    private func installSidebar() {
        guard sidebarSplitItem == nil else { return }

        conversationSurface = WebViewConversationSurface(webView: webView)
        let store = SessionStore(transport: DSHTransportFactory.live(
            baseURL: URL(string: "http://127.0.0.1:\(harnessProcess.port)")!))
        sessionStore = store
        let model = AppSidebarModel(store: store, surface: conversationSurface!,
                                    logURL: harnessManager.logURL)
        sidebarModel = model

        let hosting = NSHostingController(rootView: SidebarView(model: model,
                                                                surface: conversationSurface!))
        hosting.preferredContentSize = NSSize(width: MainWindowController.sidebarDefaultWidth,
                                              height: 0)
        let item = NSSplitViewItem(sidebarWithViewController: hosting)
        // 宽度记忆（系统级）。默认宽度调整时换 key，否则旧记忆盖住新默认值。
        splitViewController.splitView.autosaveName = "MainSidebar.v2"
        item.minimumThickness = 200
        item.maximumThickness = 420
        item.canCollapse = true
        splitViewController.insertSplitViewItem(item, at: 0)
        sidebarSplitItem = item
        sessionStorePort = harnessProcess.port

        installToolbar()
        Task { await store.start() }
    }

    /// 左上角工具栏（红绿灯同排）：收起侧边栏 + 新建会话。
    /// 依赖 sidebar split item 已就位（tracking separator 需要 divider 0），
    /// 因此在 installSidebar 尾部调用；重复调用幂等。
    private func installToolbar() {
        guard let window, window.toolbar == nil else { return }
        let tb = NSToolbar(identifier: "MainToolbar")
        tb.delegate = self
        tb.displayMode = .iconOnly
        tb.allowsUserCustomization = false
        window.toolbarStyle = .unified // Mail 同款：红绿灯垂直居中、圆形玻璃按钮
        window.toolbar = tb
    }

    @objc private func newSessionFromToolbar() {
        conversationSurface?.startSession(workspaceId: nil)
    }

    /// 卸载侧边栏（harness 重启换端口时整件重装镜像）。
    private func uninstallSidebar() {
        sessionStore?.stop()
        sessionStore = nil
        sessionStorePort = -1
        sidebarModel = nil
        conversationSurface = nil
        if let item = sidebarSplitItem {
            splitViewController.removeSplitViewItem(item)
        }
        sidebarSplitItem = nil
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
        // 插件门控参数：网页侧边栏永久隐藏，原生侧边栏接管。
        components.queryItems = [URLQueryItem(name: "dsharness-native-sidebar", value: "1")]
        guard let url = components.url else { return }
        webView.load(URLRequest(url: url))
        // harness 重启后端口可能变：镜像 transport 持旧端口时整件重装。
        if sessionStore != nil && sessionStorePort != harnessProcess.port {
            uninstallSidebar()
        }
        installSidebar()
        bridgeReady = false
        armBridgeWarn()
    }

    /// 桥 ready 超时：只记日志（插件失效不再自动回退网页侧边栏模式）。
    private func armBridgeWarn() {
        bridgeWarnWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.bridgeReady else { return }
            Log.write("桥 ready 超时（\(Int(self.bridgeReadyTimeout))s）——插件疑似失效，currentSession 同步将不可用",
                      to: self.harnessManager.logURL, tag: "bridge")
        }
        bridgeWarnWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + bridgeReadyTimeout, execute: work)
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
        // 整件卸掉镜像：新进程端口即使碰巧相同，已 stop 的 store 也不会自己复活。
        uninstallSidebar()
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

    // MARK: - 网页 → 原生消息

    /// v2 桥消息（ready / currentSession）。
    func handleBridgeMessage(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        switch message.name {
        case "dsharness":
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

// MARK: - 工具栏

extension NSToolbarItem.Identifier {
    static let newSession = NSToolbarItem.Identifier("dsharness.newSession")
}

extension MainWindowController: NSToolbarDelegate {
    // sidebarTrackingSeparator 之前的项落在侧边栏区域，之后的落在内容区域（留空）。
    // 布局：红绿灯 …弹性… 新建会话 收起侧边栏 | 分隔线（按钮组右对齐贴 divider）。
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .newSession, .toggleSidebar, .sidebarTrackingSeparator]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .newSession:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "square.and.pencil",
                                 accessibilityDescription: "新建会话")
            item.label = "新建会话"
            item.toolTip = "新建会话"
            item.isBordered = true
            item.target = self
            item.action = #selector(newSessionFromToolbar)
            return item
        case .sidebarTrackingSeparator:
            // 让分隔线在标题栏内跟随 split divider（全高侧边栏观感）。
            return NSTrackingSeparatorToolbarItem(identifier: itemIdentifier,
                                                  splitView: splitViewController.splitView,
                                                  dividerIndex: 0)
        default:
            // .toggleSidebar / .flexibleSpace 等系统项由 AppKit 提供行为。
            return NSToolbarItem(itemIdentifier: itemIdentifier)
        }
    }
}
