import AppKit
import ClamSDK
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

    /// 当前连上的 dsh。nil = 没找到/已断开（引导页在场）。
    private var endpoint: ClamEndpoint?
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
    // 网页侧边栏够不着标题栏区域（旧的 clam-nativeify topInset 让位已随之删除）。
    static let titleBarHeight: CGFloat = 40

    private let titleBarDragView = WindowDragRegionView() // 顶部可拖拽条

    /// 桥 ready 监视（8s 超时 → 只记日志；不再回退网页侧边栏模式）。
    private var bridgeReady = false
    private var bridgeWarnWork: DispatchWorkItem?
    private let bridgeReadyTimeout: TimeInterval = 8

    private var bootstrapVC: BootstrapViewController?

    private var diagnosticsPanel: DiagnosticsPanel?

    private var shortcutsPanel: ShortcutsPanel?

    /// 此刻装在菜单上的那份键位表。启动时是默认表，页面推来 `clam.page.keymap`
    /// 之后可能被换掉（见 `applyKeymap`）。
    private var activeKeymap = Keymap.default

    /// 键位订阅句柄。**必须有人接住**：`ClamDisposable` 在 deinit 里就把订阅撤了，
    /// 不存下来等于订完当场退订——不报错、不打日志，只是键位设置永远不生效。
    private var keymapSubscription: ClamDisposable?

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
    private lazy var webPolicy = WebPolicy(
        currentEndpoint: { [weak self] in self?.endpoint },
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

    init() {
        super.init(window: nil)
        setupWindow()
        setupContentView()
        // 先用默认表把菜单建起来：页面还没加载完，设置里那份键位表要等
        // clam-layout 的 client 半边投影过来（`clam.page.keymap`），届时重建。
        setupMenus(activeKeymap)
        observeKeymap()
        // WKWebView 归壳所有（终极逃生舱要用同一个实例），插件只从保管箱借用：
        // 换代后 makeNSView 返回同一实例 → 页面不重载、JS 状态存活（M2 断言 9）。
        nativeHost.objects.setObject(ClamObjects.Key.webView, webView)
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
    private func apply(_ found: ClamEndpoint?) {
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
                  to: ClamPaths.logURL, tag: "endpoint")
        if isReconnect {
            Log.write("端点变化，插件将随重连的桥重新对齐", to: ClamPaths.logURL, tag: "endpoint")
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
        Log.write("与 dsh 断开连接", to: ClamPaths.logURL, tag: "endpoint")
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
        // 不带则完整网页模式（clam-sidebar 缺席时的样子）。
        let native = Self.rememberedNativeSidebar
        nativeSidebarParamInUse = native
        components.queryItems = native
            ? [URLQueryItem(name: "clam-native-sidebar", value: "1")] : nil
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
                      to: ClamPaths.logURL, tag: "bridge")
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

    private static let nativeSidebarDefaultsKey = "clam.nativeSidebar"

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
                  to: ClamPaths.logURL, tag: "layout")
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

    // MARK: - 壳自身的构建（clam-app v1）

    /// 壳重建不是插件热替换那个档位：它要重启进程、丢页面状态。所以默认只提示，
    /// 动手归用户（clam-app 配了 `restartOnRebuild` 才自动走）。
    private func applyAppBuild(_ state: AppBuildState) {
        // 引导页在场 = 此刻连 dsh 都没有，"壳有新版"不是当下该操心的事。
        guard bootstrapVC == nil else { return }
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
        let toast = ShellToast(content: content, onDismiss: { [weak self] view in
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
    /// ## menuCommand 词汇表
    ///
    /// 业务性的菜单项一律只 `events.emit(.menuCommand, ["command": …])`，
    /// **壳只喊命令，不做业务**。谁消费：
    ///
    /// | command | 消费方 |
    /// |---|---|
    /// | `openSettings` | clam-layout |
    /// | `newSession` | clam-layout |
    /// | `prevSession` / `nextSession` | clam-sidebar |
    /// | `selectSessionAt`（带 `index`，1 起） | clam-sidebar |
    /// | `nextPendingSession` | clam-sidebar |
    /// | `archiveSession` / `renameSession` | clam-sidebar |
    /// | `focusSearch` | clam-sidebar |
    ///
    /// **没人应答就静默无事**：事件总线是广播，没有订阅者不是错误——
    /// 插件缺席（逃生舱模式、或某个插件编译失败退休）时这些快捷键优雅失效，
    /// 菜单项照常在、按下去什么都不发生，壳不该替它们报错或禁用。
    ///
    /// 反过来，**壳本地动作**（缩放、重载、诊断、快捷键面板）不走 emit：
    /// 它们作用在壳自己拥有的东西上，任何插件配置下都必须可用。
    ///
    /// ## 哪些键位可配
    ///
    /// 只有 `Keymap.menuCommands` 那八条 + ⌘1-9 的修饰键从 `keymap` 里取，
    /// 其余（⌘W/⌘Q/编辑菜单/⌘R/⌥⌘S/缩放/⌥⌘D/⌘⇧R/⌘/）是 macOS 系统惯例，
    /// 硬编码不动——它们改了只会更难用，不值得摆进设置里。
    ///
    /// **整个函数是幂等的**：换键位时原样再跑一遍、连 `NSApp.mainMenu` 一起换新。
    /// `windowsMenu` / `helpMenu` 的重新赋值 AppKit 自己会把托管项（窗口列表、
    /// 帮助搜索框）迁到新菜单上，不需要先拆旧的。
    private func setupMenus(_ keymap: Keymap) {
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
        let settingsItem = appMenu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: "")
        bind(settingsItem, "openSettings", keymap)
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

        // 文件菜单（会话的增删改名 + ⌘W 关闭窗口）
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "文件")
        let newSessionItem = fileMenu.addItem(withTitle: "新建会话",
                                              action: #selector(newSession), keyEquivalent: "")
        bind(newSessionItem, "newSession", keymap)
        newSessionItem.target = self
        fileMenu.addItem(.separator())
        let renameItem = fileMenu.addItem(withTitle: "重命名会话…",
                                          action: #selector(renameSession), keyEquivalent: "")
        bind(renameItem, "renameSession", keymap)
        renameItem.target = self
        let archiveItem = fileMenu.addItem(withTitle: "归档会话",
                                           action: #selector(archiveSession), keyEquivalent: "")
        bind(archiveItem, "archiveSession", keymap)
        archiveItem.target = self
        fileMenu.addItem(.separator())
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
        viewMenu.addItem(.separator())
        let focusSearchItem = viewMenu.addItem(withTitle: "聚焦搜索",
                                               action: #selector(focusSearch), keyEquivalent: "")
        bind(focusSearchItem, "focusSearch", keymap)
        focusSearchItem.target = self
        viewMenu.addItem(.separator())
        let zoomInItem = viewMenu.addItem(withTitle: "放大",
                                          action: #selector(zoomIn), keyEquivalent: "+")
        zoomInItem.target = self
        // ⌘= 的别名：键盘上 + 与 = 同一个键，用户多半不按 shift。macOS 惯例是
        // 菜单里只显示 ⌘+，另挂一个隐藏项接住 ⌘=。隐藏项的快捷键默认不生效，
        // 必须显式 allowsKeyEquivalentWhenHidden。
        let zoomInAlias = viewMenu.addItem(withTitle: "放大",
                                           action: #selector(zoomIn), keyEquivalent: "=")
        zoomInAlias.target = self
        zoomInAlias.isHidden = true
        zoomInAlias.allowsKeyEquivalentWhenHidden = true
        let zoomOutItem = viewMenu.addItem(withTitle: "缩小",
                                           action: #selector(zoomOut), keyEquivalent: "-")
        zoomOutItem.target = self
        let zoomResetItem = viewMenu.addItem(withTitle: "实际大小",
                                             action: #selector(zoomReset), keyEquivalent: "0")
        zoomResetItem.target = self
        viewItem.submenu = viewMenu
        viewItem.title = "显示"

        // 会话菜单（前后切换 + ⌘1…⌘9 直达）
        let sessionItem = NSMenuItem()
        mainMenu.addItem(sessionItem)
        let sessionMenu = NSMenu(title: "会话")
        let prevItem = sessionMenu.addItem(withTitle: "上一个会话",
                                           action: #selector(prevSession), keyEquivalent: "")
        bind(prevItem, "prevSession", keymap)
        prevItem.target = self
        let nextItem = sessionMenu.addItem(withTitle: "下一个会话",
                                           action: #selector(nextSession), keyEquivalent: "")
        bind(nextItem, "nextSession", keymap)
        nextItem.target = self
        let nextPendingItem = sessionMenu.addItem(withTitle: "下一个待处理会话",
                                                  action: #selector(nextPendingSession), keyEquivalent: "")
        bind(nextPendingItem, "nextPendingSession", keymap)
        nextPendingItem.target = self
        sessionMenu.addItem(.separator())
        // ⌘1…⌘9 直达第 N 个会话。全部隐藏：九行"会话 N"占满菜单却什么信息都不给，
        // 而快捷键本身照常生效（allowsKeyEquivalentWhenHidden，不设则隐藏项的
        // 快捷键一并失效）。序号经 tag 带过去，九项共用一个 selector。
        // 九项一把抓：修饰键由 `sessionDigits` 一个设置项决定，nil = 不挂键
        // （数字键在页面里是正常输入，这条比别的更该留一个关掉的口子）。
        for n in 1...9 {
            let item = sessionMenu.addItem(withTitle: "会话 \(n)",
                                           action: #selector(selectSessionAt(_:)),
                                           keyEquivalent: "")
            if let digits = keymap.digitsMask {
                item.keyEquivalent = "\(n)"
                item.keyEquivalentModifierMask = digits
            }
            item.tag = n
            item.target = self
            item.isHidden = true
            item.allowsKeyEquivalentWhenHidden = true
        }
        sessionItem.submenu = sessionMenu
        sessionItem.title = "会话"

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

        // 帮助菜单。设 NSApp.helpMenu 才会被系统摆到标准位置（最右）
        // 并挂上那个搜索框；只当普通菜单加进去位置就不对。
        let helpItem = NSMenuItem()
        mainMenu.addItem(helpItem)
        let helpMenu = NSMenu(title: "帮助")
        let shortcutsItem = helpMenu.addItem(withTitle: "键盘快捷键",
                                             action: #selector(showShortcuts), keyEquivalent: "/")
        shortcutsItem.target = self
        helpItem.submenu = helpMenu
        helpItem.title = "帮助"
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
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

    /// 解析 + 按需重建。**只在真变了的时候重建**：页面每次加载、每次设置回调都会
    /// 推一份，绝大多数与在役的那份一模一样，无脑重建等于反复把整条主菜单换掉。
    private func applyKeymap(_ raw: [String: Any]) {
        // 非字符串的值（JS 侧的 null / 未设置）一律当"没配"处理，退默认。
        let values = raw.compactMapValues { $0 as? String }
        let (keymap, failed) = Keymap.resolve(values)
        let changed = keymap != activeKeymap
        if changed {
            activeKeymap = keymap
            setupMenus(keymap)
        }
        // **解析失败要无条件落日志**：坏 spec 退回默认之后，算出来的表可能与在役的
        // 那份一模一样（把默认值打错一个字母就是这种情形），只按"变了没"记日志的话
        // 用户永远不知道自己写错了什么。
        guard changed || !failed.isEmpty else { return }

        let failedNames = Set(failed.map(\.command))
        // 快照会把没动过的字段也填上默认值一起推下来，"在场"不等于"用户改过"
        // ——与默认表不同才算覆盖，否则这行账永远是满打满算的 10 项。
        let applied = values.filter { key, value in
            Keymap.configurable.contains(key) && !failedNames.contains(key)
                && value != Keymap.defaultSpecs[key]
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
        if let digits = keymap.digitsMask {
            for n in 1...9 {
                groups["\(digits.rawValue)|\(n)", default: []].append("selectSessionAt(\(n))")
            }
        }
        for key in groups.keys.sorted() {
            guard let names = groups[key], names.count > 1 else { continue }
            Log.write("键位冲突：\(names.sorted().joined(separator: " / ")) 配成了同一个键，"
                      + "AppKit 只会触发菜单里靠前的那条",
                      to: ClamPaths.logURL, tag: "menu")
        }
    }

    // MARK: - 菜单动作：喊命令

    // 以下这些只 emit，不做事——词汇表与"没人应答会怎样"见 setupMenus() 顶注。

    /// ⌘,：壳只负责喊一声，谁有能力谁去做（layout 拥有会话展示面）。
    @objc private func openSettings() {
        emitMenuCommand("openSettings")
    }

    @objc private func newSession() {
        emitMenuCommand("newSession")
    }

    @objc private func renameSession() {
        emitMenuCommand("renameSession")
    }

    @objc private func archiveSession() {
        emitMenuCommand("archiveSession")
    }

    @objc private func prevSession() {
        emitMenuCommand("prevSession")
    }

    @objc private func nextSession() {
        emitMenuCommand("nextSession")
    }

    @objc private func nextPendingSession() {
        emitMenuCommand("nextPendingSession")
    }

    @objc private func focusSearch() {
        emitMenuCommand("focusSearch")
    }

    /// ⌘1…⌘9 共用的入口：序号从菜单项的 tag 上取（1 起，不是下标）。
    @objc private func selectSessionAt(_ sender: NSMenuItem) {
        emitMenuCommand("selectSessionAt", ["index": sender.tag])
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

    /// ⌘/：把当前主菜单里所有带快捷键的项摊成一张表。
    @objc private func showShortcuts() {
        let panel = shortcutsPanel ?? ShortcutsPanel()
        shortcutsPanel = panel
        panel.present(stopSpec: activeKeymap.stopSpec)
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
        lines.append("原生侧边栏门控：\(nativeSidebarParamInUse ? "开（?clam-native-sidebar=1）" : "关（完整网页模式）")")
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
            lines.append("本次连接期间没有重建过（clam-app 没播报过 app-build）")
        }
        lines.append("")
        lines.append("── 路径 ──")
        // 日志一个实例一份，写全路径而不是目录——多 worktree 时"我该看哪个文件"
        // 正是最容易搞错的一步。
        lines.append("日志：\(ClamPaths.logURL.path)")
        lines.append("发现文件：\(ClamPaths.endpointsDir.path)")
        // 一个 profile 一份，所以这一行同时回答了"这台机器上现在有几套 surfclam 在跑"。
        let discovered = EndpointLocator.discoveredEndpoints()
        let discoveredText = discovered.isEmpty
            ? "无"
            : discovered.map { "\($0.profile ?? "?") → \($0.httpBase.absoluteString)" }
                .joined(separator: "，")
        lines.append("发现的 dsh：\(discoveredText)")
        return lines.joined(separator: "\n")
    }

    // MARK: - 网页 → 原生消息

    /// v2 桥消息（ready / currentSession）。
    func handleBridgeMessage(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        switch message.name {
        case "clam":
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
                Log.write("页内桥就绪：\(caps.joined(separator: ", "))\(diag)", to: ClamPaths.logURL, tag: "bridge")
                nativeHost.events.emit(ClamEventBus.Topic.pageReady, ["capabilities": caps])
            case "currentSession":
                if let id = body["id"] as? String {
                    // **粘性**：插件装载晚于页面，不粘的话它拿不到"现在在哪个会话"
                    // ——而这恰恰是它最需要的那个输入（见 ClamEventBus.emitSticky）。
                    nativeHost.events.emitSticky(ClamEventBus.Topic.pageCurrentSession,
                                                 ["id": id])
                }
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
        let before = endpoint
        probeNow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let endpoint = self.endpoint, endpoint == before else { return }
            self.webView.reload()
        }
    }
}

/// 装在菜单上的那份键位表，以及它的**默认值真相**。
///
/// ## 默认值住在这里
///
/// ns `clam-shortcuts` 的 schema（`clam-app/lib/index.js`）里那些 `default`
/// 只为了让两套设置界面显示"默认是什么"，**真正决定按下去会怎样的是下面这张表**
/// （用户没配的项走的就是它）。改一处必须同步改另一处——不同步不会报错，
/// 只会变成"设置界面写着 ⌘N，按下去却不是"，而这种账极难对。
///
/// ## 十项，三种形态
///
/// - 八条菜单项键位：普通 spec 字符串，格式见 `KeymapSpec`；
/// - `sessionDigits`：⌘1-9 那九个隐藏项的修饰键，`cmd` / `cmd+alt` / `off`
///   （九项一把抓——单独配九条既啰嗦又没人会去改）；
/// - `stopGenerating`：**壳不消费**。Esc 停止生成在 clam-layout 的 client 半边
///   就地匹配 keydown，压根不过壳。默认值列在这儿只为"一处真相"这一条。
struct Keymap: Equatable {

    /// 归菜单项的那八条：命令名 → 绑定。命令名与 `menuCommand` 词汇表同名
    /// （见 `MainWindowController.setupMenus` 顶注）。
    var bindings: [String: KeymapSpec.Binding]

    /// ⌘1…⌘9 的修饰键；`nil` = 那九项不挂键。
    var digitsMask: NSEvent.ModifierFlags?

    /// `stopGenerating` 的**展示用** spec：执行在页面侧（clam-layout client 半边），
    /// 壳存这份只为 ⌘/ 面板那行"页面内"不与设置漂移。空串 = 用户显式禁用。
    var stopSpec: String

    /// 默认键位。改这里记得同步 `clam-app/lib/index.js` 的 ns schema。
    static let defaultSpecs: [String: String] = [
        "newSession": "cmd+n",
        "openSettings": "cmd+,",
        "renameSession": "cmd+alt+r",
        "archiveSession": "cmd+shift+backspace",
        "prevSession": "cmd+shift+[",
        "nextSession": "cmd+shift+]",
        "nextPendingSession": "cmd+alt+a",
        "focusSearch": "cmd+alt+f",
        "sessionDigits": "cmd",
        "stopGenerating": "esc",
    ]

    /// 装在菜单项上的那八条（顺序无关，只用来筛）。
    static let menuCommands = [
        "newSession", "openSettings", "renameSession", "archiveSession",
        "prevSession", "nextSession", "nextPendingSession", "focusSearch",
    ]

    /// 壳认得的全部可配置键。`stopGenerating` 的**执行**归页面，但壳也消费它
    /// （⌘/ 面板展示），计入"设置覆盖了几项"的账。
    static let configurable = Set(menuCommands + ["sessionDigits", "stopGenerating"])

    /// 谁都没配时的样子。壳启动时先装它。
    static let `default` = resolve([:]).keymap

    struct Failure {
        let command: String
        /// 用户写的原文。日志要带上它，否则没人知道该去改什么。
        let raw: String
    }

    /// 把设置里那份 `[命令: spec]` 解析成键位表。**失败不传染**：坏的那条退回
    /// 默认、记进 `failed`，其余照常生效——一个错别字不该让整套快捷键失灵。
    static func resolve(_ values: [String: String]) -> (keymap: Keymap, failed: [Failure]) {
        var bindings: [String: KeymapSpec.Binding] = [:]
        var failed: [Failure] = []

        for command in menuCommands {
            if let raw = values[command] {
                if let parsed = KeymapSpec.parse(raw) {
                    bindings[command] = parsed
                    continue
                }
                failed.append(Failure(command: command, raw: raw))
            }
            // 默认表里的 spec 是代码常量，解析不出来说明这张表写错了；
            // 退到"不挂键"至少菜单还在，比崩掉整条菜单强。
            bindings[command] = KeymapSpec.parse(defaultSpecs[command] ?? "") ?? .disabled
        }

        var digits = parseDigits(defaultSpecs["sessionDigits"] ?? "") ?? .some([.command])
        if let raw = values["sessionDigits"] {
            if let parsed = parseDigits(raw) {
                digits = parsed
            } else {
                failed.append(Failure(command: "sessionDigits", raw: raw))
            }
        }

        // stopGenerating 与页面侧（clam-layout client 的 readKeySpec）同一套语义：
        // 空串 = 显式禁用（尊重，不退默认）；解析不动 = 退默认并记失败。
        var stop = defaultSpecs["stopGenerating"] ?? "esc"
        if let raw = values["stopGenerating"] {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                stop = ""
            } else if KeymapSpec.parse(text) != nil {
                stop = text
            } else {
                failed.append(Failure(command: "stopGenerating", raw: raw))
            }
        }

        return (Keymap(bindings: bindings, digitsMask: digits, stopSpec: stop), failed)
    }

    /// `sessionDigits` 的三个取值。**双层可选是有意的**：外层 `nil` = 值非法，
    /// 内层 `nil` = `off`（不挂键）——两者都要能表达，而它们不是一回事。
    private static func parseDigits(_ raw: String) -> (NSEvent.ModifierFlags?)? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.isEmpty || text == "off" { return .some(nil) }
        // 空掩码等于"光按数字键就切会话"——页面里数字是正常输入，这不能算合法值。
        guard let mask = KeymapSpec.parseModifiers(text), !mask.isEmpty else { return nil }
        return .some(mask)
    }
}
