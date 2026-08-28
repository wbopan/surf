import AppKit
import DashSDK
import SwiftUI
import WebKit

/// 主布局：`NSSplitViewController`（sidebar 项 + WebView 项）。
///
/// 为什么是 AppKit 而不是 SwiftUI 的 `HSplitView`：材质（macOS 26 的 Liquid Glass）、
/// 分隔条、拖拽调宽、双击复位、宽度 autosave、收起动画、以及工具栏里跟随 divider 的
/// `NSTrackingSeparatorToolbarItem`——这些全是 `NSSplitViewItem(sidebarWithViewController:)`
/// 白送的。用 SwiftUI 重画一遍只会得到一个更差的仿制品。
///
/// 它经 `NSViewControllerRepresentable` 装进 root 槽（AppKit 包在 SwiftUI 里包在
/// AppKit 里），是本插件唯一一处"绕回 AppKit"的地方。
final class LayoutSplitController: NSSplitViewController {
    /// 侧边栏首次显示的默认宽度（之后由 autosave 记忆）。
    static let sidebarDefaultWidth: CGFloat = 256
    /// 主内容最小宽度。窗口收窄时优先自动折叠 sidebar 保住它。
    static let contentMinWidth: CGFloat = 432

    /// 分隔条宽度的 autosave key（系统级记忆；改默认宽度时换 key 才对已有用户生效）。
    private static let sidebarAutosaveName = "ClamMainSidebar.v2"

    let host: DashHost
    private let webView: WKWebView

    private var sidebarItem: NSSplitViewItem?
    /// 自动折叠标记：因窗口收窄而折叠（而非用户手动收起），拉宽后自动恢复。
    private var autoCollapsed = false
    /// 折叠前的厚度，用作自动恢复的宽度阈值。
    private var lastVisibleThickness = LayoutSplitController.sidebarDefaultWidth
    private var resizeObserver: NSObjectProtocol?
    var ownedToolbar: NSToolbar?
    /// 装了工具栏的那扇窗（deinit 里不能再摸 `view.window`，它是 MainActor 隔离的）。
    private weak var installedWindow: NSWindow?

    /// 工具栏贡献的当前快照。工具栏委托只读它，不读 registry——
    /// NSToolbar 会在任意时刻回调委托要项，读快照才能保证一轮重建里前后一致。
    var toolbarContributions: [DashContributions.Contribution] = []
    /// 每条贡献的"流量"状态（徽标 / 选中 / 菜单 / 显隐）。**跟着 key 记账**：
    /// 项会被重造，状态得比项活得久，否则热替换一次徽标就没了。
    /// 见 `ToolbarContribution.swift`。
    var toolbarStates: [String: ToolbarItemState] = [:]
    /// 菜单打开钩子的强持有者（`NSMenu.delegate` 是 weak）。键同贡献的 key。
    var menuOpenRelays: [String: ToolbarMenuOpenRelay] = [:]
    /// 活通道的订阅句柄。随控制器（也就是随世代）走。
    private var toolbarUpdates: DashDisposable?
    /// 标题栏拖动的接管钩子（见 `installTitlebarDrag`）。
    private var titlebarDragMonitor: Any?
    /// 上一次广播出去的标题栏厚度。只在变了时才 emit。
    private var lastTitlebarInset: CGFloat = -1
    /// 盯着显示模式（用户右键能改它，改完带子的厚度就变了）。
    private var displayModeObservation: NSKeyValueObservation?
    /// 快照签名。变了才重建工具栏（幂等的判据）。
    private var toolbarSignature = ""
    /// 贡献项的菜单代理。`NSMenu.delegate` 是 **unowned(unsafe)**，
    /// 不在这儿留一份强引用就会在下一次弹出时野指针崩掉。键是贡献的 `key`。
    var toolbarMenuDelegates: [String: ContributionMenuDelegate] = [:]

    init(host: DashHost, webView: WKWebView) {
        self.host = host
        self.webView = webView
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 装配

    // 不覆写 loadView：NSSplitViewController 的默认实现会把自己的 splitView
    // 装成 view，换成一个空 NSView 等于把分栏整个丢了（窗口会白给）。

    override func viewDidLoad() {
        super.viewDidLoad()
        // WebView 项：全出血，标题栏透明。WKWebView 实例归壳所有，这里只借用排版
        // ——换代时同一实例被重新 addSubview，页面不重载、JS 状态存活（M2 断言 9）。
        // 它的 navigationDelegate/uiDelegate 也归壳（避开 R5 的跨代重设时序问题）。
        let webContainer = NSViewController()
        webContainer.view = NSView()
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.removeFromSuperview()
        webContainer.view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: webContainer.view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: webContainer.view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: webContainer.view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: webContainer.view.trailingAnchor),
        ])
        let contentItem = NSSplitViewItem(viewController: webContainer)
        contentItem.canCollapse = false
        addSplitViewItem(contentItem)

        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: nil, queue: .main) { [weak self] note in
                guard let self, let window = note.object as? NSWindow,
                      window === self.view.window else { return }
                MainActor.assumeIsolated { self.adaptToWindowWidth() }
            }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        syncToolbar()
        adaptToWindowWidth()
        publishTitlebarMetrics()
    }

    /// 标题栏那条带子的厚度会跟着**显示模式**变（Icon and Text 比 Icon Only 高
    /// 一截），而显示模式是用户右键就能改的。所以厚度不是装配时量一次的常量，
    /// 得有人一直盯着。
    ///
    /// **盯 `viewDidLayout` 而不是 KVO `displayMode`**：厚度真正变的时刻是布局
    /// 落定之后，KVO 到属性变化时窗口还没重排，量出来的还是旧值；而显示模式、
    /// 窗口缩放、全屏切换、工具栏显隐——凡是会改厚度的，最终都会走到这里。
    /// 一条路盯住全部，比几条 KVO 拼起来还更难漏。
    override func viewDidLayout() {
        super.viewDidLayout()
        publishTitlebarMetrics()
    }

    /// 量一次 `contentLayoutGuide`，变了才广播。
    ///
    /// `force` 是给**后到的订阅者**用的：厚度只在变化时才发，晚一步上线的插件
    /// 等不来第二次（和"node 半边不给新世代补发投影"是同一条纪律——补发归
    /// 请求方）。它自己喊一声 `clam.layout.requestTitlebarMetrics` 就能要到。
    func publishTitlebarMetrics(force: Bool = false) {
        guard let window = view.window,
              let layoutGuide = window.contentLayoutGuide as? NSLayoutGuide,
              let contentView = window.contentView else { return }
        // **坐标系是左下原点**（contentView 默认 `isFlipped == false`）：
        // guide 的 minY 贴着窗口底边，顶上那条带子的厚度是
        // `contentView.maxY - guide.maxY`。写成 `guide.minY` 会恒等于 0。
        let inset = contentView.bounds.maxY - layoutGuide.frame.maxY
        guard inset.isFinite, inset > 0 else { return }
        guard force || abs(inset - lastTitlebarInset) > 0.5 else { return }
        lastTitlebarInset = inset
        host.events.emit(Self.titlebarMetricsTopic, ["inset": Double(inset)])
    }

    deinit {
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        // 监视器必须自己摘：它不随控制器回收，留着就是每换一代堆一个僵尸。
        if let titlebarDragMonitor { NSEvent.removeMonitor(titlebarDragMonitor) }
        // 只摘自己那一个：换代时新控制器已经装好了它的工具栏，别把它拆了。
        // 不用 MainActor.assumeIsolated——deinit 跑在谁释放的线程上，猜错就是 trap；
        // 把值捞出来派回主线程，最坏也只是晚一拍。
        let toolbar = ownedToolbar
        let window = installedWindow
        DispatchQueue.main.async {
            guard let window, window.toolbar === toolbar else { return }
            window.toolbar = nil
            // 标识也一起还给壳。**判据借的是上面那句 `toolbar ===`**：
            // 换代时新控制器早已装好自己的工具栏并重设了标题，那时这个条件
            // 不成立，于是不会出现"旧代 deinit 把新代刚摆好的标题擦掉"
            // ——client 半边 HMR 那条坑（新实例先启、旧实例后清）的同款。
            window.titleVisibility = .hidden
            window.title = ""
            window.subtitle = ""
            window.titlebarAppearsTransparent = true
        }
    }

    // MARK: - sidebar 槽

    /// registry 的 sidebar 槽占用状态变了就装上/摘掉。槽内插件自己换代不走这里——
    /// `SidebarSlotView` 观察 registry，版本号跳变时自己整棵重建。
    func syncSidebar() {
        let occupied = host.registry.isOccupied("sidebar")
        if occupied && sidebarItem == nil {
            installSidebar()
        } else if !occupied, let item = sidebarItem {
            removeSplitViewItem(item)
            sidebarItem = nil
        }
    }

    private func installSidebar() {
        let hosting = NSHostingController(
            rootView: SidebarSlotView(registry: host.registry))
        // 不让 SwiftUI 内容反过来决定分栏宽度：sizingOptions 默认含
        // .preferredContentSize，槽内插件每换一代重建视图时都会把 split 拉成
        // 内容的 fitting 宽度，用户调好的宽度就没了。宽度归 autosave 与下面那次
        // setPosition 管。
        hosting.sizingOptions = []

        // 无存档时首次布局会把它钳到最小厚度，布局后补回默认宽度。
        let hadArchive = UserDefaults.standard
            .string(forKey: "NSSplitView Subview Frames \(Self.sidebarAutosaveName)") != nil
        splitView.autosaveName = Self.sidebarAutosaveName

        let item = NSSplitViewItem(sidebarWithViewController: hosting)
        item.minimumThickness = 200
        item.maximumThickness = 420
        item.canCollapse = true
        insertSplitViewItem(item, at: 0)
        sidebarItem = item
        syncToolbar()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !hadArchive {
                self.splitView.setPosition(Self.sidebarDefaultWidth, ofDividerAt: 0)
            }
            self.adaptToWindowWidth()
        }
    }

    // MARK: - 自适应折叠

    /// 窗口收窄、主内容宽度不够 `contentMinWidth` 时优先自动折叠 sidebar
    /// （Web UI 同款设计）；拉宽到能同时容纳 sidebar + 主内容最小宽度时自动恢复。
    /// 用户手动收起的不会被自动恢复。
    private func adaptToWindowWidth() {
        guard let item = sidebarItem, let window = view.window else { return }
        let width = window.contentView?.bounds.width ?? 0
        let divider = splitView.dividerThickness
        if !item.isCollapsed {
            let thickness = item.viewController.view.bounds.width
            if width - thickness - divider < Self.contentMinWidth {
                toggleSidebar(nil)
                autoCollapsed = true
            } else {
                lastVisibleThickness = thickness
            }
        } else if autoCollapsed, width >= Self.contentMinWidth + lastVisibleThickness + divider {
            toggleSidebar(nil)
            autoCollapsed = false
        }
    }

    // MARK: - 工具栏

    /// 左上角工具栏（红绿灯同排）。
    /// 依赖 sidebar item 已就位（tracking separator 需要 divider 0），
    /// 所以 installSidebar 尾部也调一次；重复调用幂等。
    /// 把「拖标题栏移动窗口 / 双击放大」接回来。
    ///
    /// **装了 `NSToolbar` 就会把壳的拖动条压死**：壳在 contentView 顶部放了一块
    /// `WindowDragRegionView`（见 `MainWindowController.swift`），可 titlebar 容器
    /// 排在 contentView **之上**，`NSToolbarTitleView` 铺满整个内容区宽度
    /// （实测 764×52）把它整个遮住，那块视图再也收不到事件。而 AppKit 自己也
    /// 不接手——壳的注释里记过同一条实测：`fullSizeContentView` +
    /// `titlebarAppearsTransparent` 这个形态下 `mouseDownCanMoveWindow` 不生效
    /// （我们复核过：从 `NSThemeFrame` 到 `NSToolbarTitleView` 整条链都是 `true`，
    /// 照样拖不动）。两边同时失效，症状就是**标题栏完全没反应、且不报任何错**。
    ///
    /// 所以谁遮住的谁补：只接管标题文字那块地，工具栏按钮一律放行。
    private func installTitlebarDrag() {
        guard titlebarDragMonitor == nil else { return }
        titlebarDragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) {
            [weak self] event in
            guard let self, let window = event.window, window === self.view.window,
                  // 事件路由的起点是 frameView（contentView 的父）：工具栏住在
                  // titlebar 容器里，`contentView.hitTest` 根本探不到它们。
                  let hit = window.contentView?.superview?.hitTest(event.locationInWindow),
                  Self.isTitleArea(hit)
            else { return event }
            if event.clickCount >= 2 {
                Self.performDoubleClickAction(on: window)
            } else {
                window.performDrag(with: event)
            }
            return nil // 吃掉：标题视图自己不需要这一下
        }
    }

    /// 命中点算不算「标题栏空地」。
    ///
    /// 判据是**向上找 `NSToolbarTitleView`**（`window.title` / `subtitle` 那块地），
    /// 路上先撞见任何 `NSControl` 就放行——按钮、段控、菜单项照常工作。
    /// 私有类名比对失败时一律放行，宁可不接管也不吞掉别人的点击。
    private static func isTitleArea(_ hit: NSView) -> Bool {
        var view: NSView? = hit
        while let v = view {
            if v is NSControl { return false }
            if String(describing: type(of: v)) == "NSToolbarTitleView" { return true }
            view = v.superview
        }
        return false
    }

    /// 双击标题栏干什么**由系统偏好决定**（设置 > 桌面与程序坞 > 连按标题栏时）。
    /// 缺省是放大，但别写死——用户可能设成最小化或什么都不做。
    private static func performDoubleClickAction(on window: NSWindow) {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.miniaturize(nil)
        case "None": break
        default: window.performZoom(nil) // 含缺省（键不存在）
        }
    }

    private func installToolbar() {
        guard let window = view.window, sidebarItem != nil else { return }
        if let ownedToolbar, window.toolbar === ownedToolbar { return }
        let toolbar = NSToolbar(identifier: "ClamLayoutToolbar")
        toolbar.delegate = self
        // 初始值。**不是最终值**——`allowsDisplayModeCustomization` 在 macOS 15+
        // 默认就是 YES，用户右键工具栏就能改成 Icon and Text / Text Only。
        // 我们能定的只有开局长什么样。
        // **只是开局值，改不动用户的选择**：`allowsDisplayModeCustomization`
        // 在 macOS 15+ 默认就是 YES，头文件原话是"这时 displayMode 是一个用户
        // 可改的属性"——存过配置之后再赋值会被当场弹回（实测：设完立刻读还是
        // 旧值）。想让用户看见别的默认值，只能在他还没选过时给。
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        // 用户改过的显示模式要留下来。头文件原话：「用户的选择会用 toolbar 的
        // identifier 持久化，**前提是开了 autosavesConfiguration**」。不开就是
        // 每次启动都弹回 .iconOnly，用户以为自己的设置没生效。
        toolbar.autosavesConfiguration = true
        window.toolbarStyle = .unified // Mail 同款：红绿灯垂直居中、圆形玻璃按钮
        window.toolbar = toolbar
        ownedToolbar = toolbar
        installedWindow = window
        if toolbarUpdates == nil { toolbarUpdates = installToolbarUpdates() }
        installTitlebarDrag()
        // 显示模式换了，带子的厚度就换了。`viewDidLayout` 多半也会跟着响，
        // 但那是间接的——这条直接盯着源头，两条一起兜住。
        // **推迟一拍再量**：KVO 响的时候窗口还没重排，当场量到的是旧厚度。
        displayModeObservation = toolbar.observe(\.displayMode, options: [.new]) {
            [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.publishTitlebarMetrics() }
            }
        }
    }

    /// 贡献槽有变（热替换、新插件上线/下线）就重建工具栏。
    ///
    /// 由 `SplitRepresentable.updateNSViewController` 驱动——`RootLayoutView`
    /// 读了 `contributions.revision`，值一跳 SwiftUI 就会调下来。
    /// 幂等：签名没变什么都不做；只动 `ownedToolbar`（换代时新控制器已经装好了
    /// 它自己那一个，见 deinit 的纪律）。
    func syncToolbar() {
        let changed = refreshToolbarSnapshot()
        // 已经在窗上的工具栏才需要"重建"；installToolbar 新造的那一个
        // 会直接按刚刷新的快照问委托要项，不必再拆一遍。
        let hadToolbar = ownedToolbar != nil && installedWindow?.toolbar === ownedToolbar
        installToolbar()
        guard changed, hadToolbar, let toolbar = ownedToolbar else { return }
        while !toolbar.items.isEmpty { toolbar.removeItem(at: 0) }
        for (index, identifier) in toolbarDefaultItemIdentifiers(toolbar).enumerated() {
            toolbar.insertItem(withItemIdentifier: identifier, at: index)
        }
    }

    /// 重取快照；有实质变化返回 true。
    ///
    /// 签名只折进"会影响工具栏长相"的那几项：身份、世代、排序、图标、标题。
    /// 世代号在里面，所以贡献者热替换（身份不变、闭包变了）也会重建。
    @discardableResult
    private func refreshToolbarSnapshot() -> Bool {
        let list = host.contributions.contributions(for: Self.toolbarSlot)
        let signature = list.map { item in
            let symbol = item.metadata["symbol"] as? String ?? ""
            let label = item.metadata["label"] as? String ?? ""
            // region / sizing 也折进来：它们决定项排在哪一段、用哪条渲染路线，
            // 漏了就会出现"改了 metadata 但工具栏纹丝不动"。
            return "\(item.key)#\(item.version)#\(item.order)#\(symbol)#\(label)"
                + "#\(Self.region(of: item))#\(Self.sizing(of: item))"
                + "#\(Self.align(of: item))#\(Self.spaced(of: item))"
                // kind 决定用哪个 NSToolbarItem 子类，items 决定段控有几段
                // ——漏了它们就会出现"改了 metadata 但工具栏纹丝不动"。
                + "#\(Self.kind(of: item))#\(Self.itemsDigest(of: item))"
                + "#\(Self.priority(of: item).rawValue)"
        }.joined(separator: "|")
        guard signature != toolbarSignature else { return false }
        toolbarContributions = list
        toolbarSignature = signature
        return true
    }

    /// 工具栏项被点了：把它翻译成事件总线上的一条广播。
    /// 本控制器不知道任何按钮"是干什么的"——那是贡献者自己的事。
    @objc func activateToolbarContribution(_ sender: Any?) {
        guard let item = sender as? NSToolbarItem,
              let contribution = contribution(for: item.itemIdentifier) else { return }
        let topic = contribution.metadata["event"] as? String ?? Self.toolbarActivateTopic
        host.events.emit(topic, [
            "slot": Self.toolbarSlot,
            "owner": contribution.owner,
            "id": contribution.id,
        ])
    }

    func contribution(
        for identifier: NSToolbarItem.Identifier
    ) -> DashContributions.Contribution? {
        guard identifier.rawValue.hasPrefix(Self.contributionPrefix) else { return nil }
        let key = String(identifier.rawValue.dropFirst(Self.contributionPrefix.count))
        return toolbarContributions.first { $0.key == key }
    }
}

// MARK: - 工具栏贡献槽

/// 工具栏贡献槽的公开门面。
///
/// `LayoutSplitController` 自己是 internal（它是本插件的实现细节），
/// 但槽名与默认主题是**跨插件的约定**，下游得能按名字引用而不是抄字符串。
public enum LayoutToolbar {
    /// 贡献槽名。壳一个槽名都不认得，全靠插件之间约定。
    public static let slot = "toolbar"

    // MARK: 贡献者 → 消费方（改活项的状态）

    /// 改活项的**流量**通道：徽标、选中态、菜单内容、显隐、标题。
    ///
    /// **别拿 metadata 传这些**——metadata 是拓扑，一变就重建整条工具栏，
    /// 状态会跟着项一起没。载荷见 `ToolbarItemState`。
    public static let updateTopic = "clam.toolbar.update"

    // MARK: 消费方 → 贡献者（回来的动作）

    /// 没在 metadata 里指定 `event` 时，点击广播的默认主题。
    /// 载荷 `["slot": "toolbar", "owner": String, "id": String]`，
    /// group 另带 `index` 与 `itemId`。
    public static let activateTopic = "clam.toolbar.activate"
    /// 菜单项被选中。载荷同上，另带被选项的 `itemId`。
    public static let menuSelectTopic = "clam.toolbar.menuSelect"
    /// 菜单**将要打开**。给贡献者一个预热的机会（拉数据、刷新勾选态）。
    public static let menuOpenTopic = "clam.toolbar.menuOpen"

    // MARK: 窗口标识与标题栏几何

    /// 设置 `window.title` / `window.subtitle`。载荷 `title` / `subtitle`。
    /// 空标题 = 交回给壳。
    public static let windowTitleTopic = "clam.window.title"
    /// 请求重发一次标识。**只在变化时推，所以后到的订阅者得自己喊一嗓子**。
    public static let windowTitleRequestTopic = "clam.window.requestTitle"
    /// 标题栏当前厚度（`inset`，pt）。显示模式一变就跟着变。
    public static let titlebarMetricsTopic = "clam.layout.titlebarMetrics"
    /// 请求重发一次厚度。理由同 `windowTitleRequestTopic`。
    public static let titlebarMetricsRequestTopic = "clam.layout.requestTitlebarMetrics"
}

extension LayoutSplitController {
    /// 本插件认得的贡献槽名。壳一个槽名都不认得，全靠插件之间约定。
    static let toolbarSlot = LayoutToolbar.slot
    /// 贡献项的 `NSToolbarItem.Identifier` 前缀，后面接 `owner/id`。
    static let contributionPrefix = "clam.contribution."
    /// 没在 metadata 里指定 `event` 时，点击广播的默认主题。
    /// 载荷 `["slot": "toolbar", "owner": String, "id": String]`。
    static let toolbarActivateTopic = LayoutToolbar.activateTopic

    /// 贡献落在分隔线的哪一侧。缺省 `sidebar`——**老贡献一个字都不用改**。
    static func region(of contribution: DashContributions.Contribution) -> String {
        (contribution.metadata["region"] as? String) == "content" ? "content" : "sidebar"
    }

    /// 兜底视图路线的尺寸策略。缺省 `fixed`（当场冻死，见 `makeContributionItem`）。
    static func sizing(of contribution: DashContributions.Contribution) -> String {
        (contribution.metadata["sizing"] as? String) == "dynamic" ? "dynamic" : "fixed"
    }

    /// 贡献靠哪一边。缺省 `leading`——**老贡献一个字都不用改**。
    ///
    /// 只有 `content` 区认这个键：`leading` 与 `trailing` 之间夹一个
    /// `.flexibleSpace`，于是 trailing 那组被推到窗口右缘、位置钉死。
    /// 中间那段空白是设计的一部分（会话正文列的正中不放东西），不是没排满。
    static func align(of contribution: DashContributions.Contribution) -> String {
        (contribution.metadata["align"] as? String) == "trailing" ? "trailing" : "leading"
    }

    /// 本项之前要不要插一个系统标准间距。缺省不插。
    ///
    /// **这就是分组语法**：macOS 26 把相邻的工具栏项合成一枚玻璃胶囊，
    /// 一个 `.space` 就把胶囊断开成两枚。想让自己这一项单独成一枚就打开它。
    static func spaced(of contribution: DashContributions.Contribution) -> Bool {
        (contribution.metadata["spaced"] as? Bool) == true
    }
}

/// ## `toolbar` 贡献槽的约定（第三方插件照这个写，不用改壳也不用改本插件）
///
/// ```swift
/// host.contribute(to: "toolbar", id: "myButton", order: 10, metadata: [
///     "label":   "我的按钮",              // 必填：标题 + 无障碍名
///     "symbol":  "sparkles",              // 选填：SF Symbol 名
///     "tooltip": "干点什么",               // 选填，缺省取 label
///     "event":   "myplugin.doSomething",  // 选填，缺省 "clam.toolbar.activate"
///     "region":  "content",               // 选填，缺省 "sidebar"（见下）
///     "align":   "trailing",              // 选填，缺省 "leading"（见下）
///     "spaced":  true,                    // 选填，缺省 false（见下）
///     "sizing":  "dynamic",               // 选填，缺省 "fixed"（只对 view 路线有意义）
///     "kind":    "button",                // 选填，见下；缺省由 symbol 推断
///     "priority": "low",                  // 选填，缺省 "standard"（窗口收窄谁先让）
///     "items":   [[...]],                 // group 的分段 / menu 的初始菜单（数据路线）
///     // 选填：菜单的**另一条**路线——自己现场建。给了它就不看 `kind`/`items`，
///     // 点开是菜单而不是发事件。类型必须是
///     // `@convention(block) (NSMenu) -> Void`（跨 dylib 装箱只有 ObjC block 稳）。
///     "menu":    buildMenu as @convention(block) (NSMenu) -> Void,
/// ]) { AnyView(MyFallbackButton()) }
/// host.events.subscribe("myplugin.doSomething") { _ in ... }
/// ```
///
/// ### 四条渲染路线（`kind`）
///
/// **能走原生就别自己画**：`NSToolbarItem` 那身系统皮——macOS 26 的圆形玻璃
/// 按钮、按下态、红绿灯对齐——全是白送的，拿 SwiftUI 重画只会得到一个更差的
/// 仿制品。代价是点击回调必须另有通道，于是统一走事件总线：消费方只管 emit，
/// 贡献者自己 subscribe。这也顺手解决了"闭包跨世代"的问题：主题名是字符串，
/// 热替换后新一代重新订阅即可。
///
/// | kind | 造出来的东西 | 白送什么 |
/// |---|---|---|
/// | `button`（给了 `symbol` 时的缺省） | `NSToolbarItem` + `isBordered` | 圆形玻璃按钮、按下态、红绿灯对齐 |
/// | `group` | `NSToolbarItemGroup`（`.selectOne` + `.expanded`） | 段控外观、选中态、键盘、无障碍 |
/// | `menu` | `NSMenuToolbarItem` | 下拉 indicator、菜单定位、键盘导航 |
/// | `view`（没给 `symbol` 时的缺省） | `NSHostingView` 装 `AnyView` | **什么都不送，宽度间距自己算** |
///
/// **能用前三条就别用第四条。** 自定义视图路线里 AppKit 只看见一块不透明的
/// 矩形：显示模式（Icon Only / Icon and Text / Text Only）、玻璃胶囊分组、
/// 溢出退让、徽标全都失效，而且算错是静默的。
///
/// `group` / `menu` 的 `items` 元素：
///
/// ```swift
/// ["id": "chat", "label": "Chat", "symbol": "text.bubble"]          // group 的一段
/// ["id": "std", "label": "标准模式", "state": true, "enabled": true] // menu 的一项
/// ["separator": true]                                                // menu 的分隔线
/// ```
///
/// ### 回调统一走事件总线
///
/// 原生项拿不到闭包（`NSToolbarItem` 的 target/action 必须是 `@objc`，而闭包
/// 跨不了世代），所以点击一律翻译成广播：`button` / `group` 发
/// `clam.toolbar.activate`（`group` 额外带 `index` 与 `itemId`），菜单项发
/// `clam.toolbar.menuSelect`（带 `itemId`）。主题名是字符串，热替换后新一代
/// 重新订阅即可。
///
/// ### 流量不走 metadata，走 `clam.toolbar.update`
///
/// metadata 是**拓扑**，一变就重建整条工具栏。徽标数字、菜单内容、选中态、
/// 显隐是**流量**，一秒能变好几次——走 metadata 等于每次把工具栏拆了重装
/// （按钮会闪、popover 会掉）。所以：
///
/// ```swift
/// host.events.emit("clam.toolbar.update", [
///     "owner": "dash-header", "id": "jobs",   // 认人，必填
///     "hidden": false, "badge": 3,            // 以下都是选填，没提到的原样保留
///     "enabled": true, "selectedIndex": 1,
///     "label": "标准模式", "tooltip": "...",
///     "menu": [["id": "a", "label": "A", "state": true]],
/// ])
/// ```
///
/// 消费方把 patch 记进 `ToolbarItemState` **并**就地改活着的那一项。记账是
/// 必须的：项会因换代/溢出而重造，那时得把状态补回去。只有 `items`
/// （段控的分段）会触发那一项重建——images/labels 是构造时给的，改不了。
///
/// **`region` 选边**：`sidebarTrackingSeparator` 把工具栏切成两段，分隔线跟着
/// 分栏 divider 走。`"sidebar"`（缺省）排在分隔线左边，与红绿灯同区；
/// `"content"` 排在右边，与主内容区对齐——想跟会话内容对齐的东西选它。
/// 组内按 `order` 升序。
///
/// **`align` 选左右（只对 `content` 区有意义）**：`leading`（缺省）跟着内容区
/// 起排，`trailing` 被一个 `.flexibleSpace` 推到窗口右缘。中间那段空白是设计
/// 的一部分——会话正文列的正中不放东西，视线从标题落下去一路无遮挡。
/// 想守住它就别给第三方开 `center`：只有两组，就没有「往中间挤」这个选项。
///
/// **`spaced` 断胶囊**：macOS 26 把相邻的工具栏项合成一枚玻璃胶囊，
/// 一个 `.space` 把它断成两枚。空隙就是分组语法——想单独成一枚就打开它，
/// 想和前一项挤在同一枚玻璃里就别开。
///
/// 除此之外系统项（`.flexibleSpace` / `.toggleSidebar` / 分隔线）的位置不开放：
/// 它们与红绿灯、分栏分隔线的对齐关系是 AppKit 的，乱插只会把观感搞坏。
///
/// **`sizing` 只对 `view` 路线有意义**：缺省 `"fixed"` 把
/// 尺寸当场冻死，适合长相固定的控件；`"dynamic"` 交给 Auto Layout，
/// 适合内容本来就会变的（段控的标签随会话/语言变、带计数的徽标）。
/// 选 `dynamic` 就等于接受"工具栏会跟着内容变宽"——对这类控件那是对的行为。
extension LayoutSplitController: NSToolbarDelegate {
    // sidebarTrackingSeparator 把工具栏切成两段：之前的项落在侧边栏区域，
    // 之后的落在内容区域。贡献用 `region` 选边（缺省 sidebar）。
    //
    // 布局：
    //   红绿灯 …弹性… <sidebar 区贡献…> 收起侧边栏 │ 分隔线
    //   <content·leading…> …弹性… <content·trailing…>
    //
    // content 区那个 `.flexibleSpace` **无条件插**：没有 trailing 贡献时它什么
    // 都不改变（项照样贴左），所以不写 `align` 的老贡献观感一模一样。
    //
    // **窗口有标题时 `content·leading` 基本没法用**（实测）：`window.title`
    // 在 unified 工具栏里是贪心的——它要为长标题留出截断空间，于是把分隔线
    // 右边的 leading 项一路顶到 flexibleSpace 那一侧去。日志打出来的顺序完全
    // 正确，界面上那一格却贴着右边一组，很容易误判成"align 没生效"。
    // 想紧挨标题放东西，正路是 `window.subtitle`，不是 leading 贡献。
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var identifiers: [NSToolbarItem.Identifier] = [.flexibleSpace]
        identifiers += contributionIdentifiers(in: "sidebar")
        identifiers += [.toggleSidebar, .sidebarTrackingSeparator]
        identifiers += contributionIdentifiers(in: "content", align: "leading")
        identifiers += [.flexibleSpace]
        identifiers += contributionIdentifiers(in: "content", align: "trailing")
        return identifiers
    }

    /// 一个区域（可再按 align 过滤）内的贡献识别符，保持快照里的顺序
    /// （已按 order 排好）。带 `spaced` 的项前面多插一个 `.space`。
    private func contributionIdentifiers(in region: String,
                                         align: String? = nil) -> [NSToolbarItem.Identifier] {
        var out: [NSToolbarItem.Identifier] = []
        for contribution in toolbarContributions where Self.region(of: contribution) == region {
            if let align, Self.align(of: contribution) != align { continue }
            if Self.spaced(of: contribution) { out.append(.space) }
            out.append(NSToolbarItem.Identifier(Self.contributionPrefix + contribution.key))
        }
        return out
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if let contribution = contribution(for: itemIdentifier) {
            return makeContributionItem(itemIdentifier, contribution)
        }
        switch itemIdentifier {
        case .sidebarTrackingSeparator:
            // 让分隔线在标题栏内跟随 split divider（全高侧边栏观感）。
            return NSTrackingSeparatorToolbarItem(identifier: itemIdentifier,
                                                  splitView: splitView, dividerIndex: 0)
        default:
            // .toggleSidebar / .flexibleSpace 等系统项由 AppKit 提供行为。
            return NSToolbarItem(itemIdentifier: itemIdentifier)
        }
    }

}


/// sidebar 槽的容器视图：谁占了就画谁，`.id(version)` 让它随占用者换代整棵重建。
struct SidebarSlotView: View {
    let registry: DashRegistry

    var body: some View {
        if let view = registry.view(for: "sidebar") {
            view.id(registry.version(of: "sidebar"))
        } else {
            Color.clear
        }
    }
}

/// 贡献项菜单的代理：把重建这件事转给贡献方的 block。
///
/// 用 `@convention(block)` 而不是裸 Swift 闭包，是因为它要穿过 dylib 边界
/// 装在 `[String: Any]` 里——ObjC block 是个货真价实的对象，装箱取箱都稳；
/// 裸闭包的函数类型元数据跨 image 取回来是碰运气。
final class ContributionMenuDelegate: NSObject, NSMenuDelegate {
    private let build: @convention(block) (NSMenu) -> Void

    init(build: @escaping @convention(block) (NSMenu) -> Void) {
        self.build = build
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        build(menu)
    }
}
