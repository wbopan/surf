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
    private static let sidebarAutosaveName = "DashMainSidebar.v2"

    private let host: DashHost
    private let webView: WKWebView

    private var sidebarItem: NSSplitViewItem?
    /// 自动折叠标记：因窗口收窄而折叠（而非用户手动收起），拉宽后自动恢复。
    private var autoCollapsed = false
    /// 折叠前的厚度，用作自动恢复的宽度阈值。
    private var lastVisibleThickness = LayoutSplitController.sidebarDefaultWidth
    private var resizeObserver: NSObjectProtocol?
    private var ownedToolbar: NSToolbar?
    /// 装了工具栏的那扇窗（deinit 里不能再摸 `view.window`，它是 MainActor 隔离的）。
    private weak var installedWindow: NSWindow?

    /// 工具栏贡献的当前快照。工具栏委托只读它，不读 registry——
    /// NSToolbar 会在任意时刻回调委托要项，读快照才能保证一轮重建里前后一致。
    private var toolbarContributions: [DashContributions.Contribution] = []
    /// 快照签名。变了才重建工具栏（幂等的判据）。
    private var toolbarSignature = ""

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
    }

    deinit {
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        // 只摘自己那一个：换代时新控制器已经装好了它的工具栏，别把它拆了。
        // 不用 MainActor.assumeIsolated——deinit 跑在谁释放的线程上，猜错就是 trap；
        // 把值捞出来派回主线程，最坏也只是晚一拍。
        let toolbar = ownedToolbar
        let window = installedWindow
        DispatchQueue.main.async {
            if let window, window.toolbar === toolbar { window.toolbar = nil }
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
    private func installToolbar() {
        guard let window = view.window, sidebarItem != nil else { return }
        if let ownedToolbar, window.toolbar === ownedToolbar { return }
        let toolbar = NSToolbar(identifier: "DashLayoutToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbarStyle = .unified // Mail 同款：红绿灯垂直居中、圆形玻璃按钮
        window.toolbar = toolbar
        ownedToolbar = toolbar
        installedWindow = window
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
            return "\(item.key)#\(item.version)#\(item.order)#\(symbol)#\(label)"
        }.joined(separator: "|")
        guard signature != toolbarSignature else { return false }
        toolbarContributions = list
        toolbarSignature = signature
        return true
    }

    /// 工具栏项被点了：把它翻译成事件总线上的一条广播。
    /// 本控制器不知道任何按钮"是干什么的"——那是贡献者自己的事。
    @objc fileprivate func activateToolbarContribution(_ sender: Any?) {
        guard let item = sender as? NSToolbarItem,
              let contribution = contribution(for: item.itemIdentifier) else { return }
        let topic = contribution.metadata["event"] as? String ?? Self.toolbarActivateTopic
        host.events.emit(topic, [
            "slot": Self.toolbarSlot,
            "owner": contribution.owner,
            "id": contribution.id,
        ])
    }

    fileprivate func contribution(
        for identifier: NSToolbarItem.Identifier
    ) -> DashContributions.Contribution? {
        guard identifier.rawValue.hasPrefix(Self.contributionPrefix) else { return nil }
        let key = String(identifier.rawValue.dropFirst(Self.contributionPrefix.count))
        return toolbarContributions.first { $0.key == key }
    }
}

// MARK: - 工具栏贡献槽

extension LayoutSplitController {
    /// 本插件认得的贡献槽名。壳一个槽名都不认得，全靠插件之间约定。
    static let toolbarSlot = "toolbar"
    /// 贡献项的 `NSToolbarItem.Identifier` 前缀，后面接 `owner/id`。
    static let contributionPrefix = "dash.contribution."
    /// 没在 metadata 里指定 `event` 时，点击广播的默认主题。
    /// 载荷 `["slot": "toolbar", "owner": String, "id": String]`。
    static let toolbarActivateTopic = "dash.toolbar.activate"
}

/// ## `toolbar` 贡献槽的约定（第三方插件照这个写，不用改壳也不用改本插件）
///
/// ```swift
/// host.contribute(to: "toolbar", id: "myButton", order: 10, metadata: [
///     "label":   "我的按钮",              // 必填：标题 + 无障碍名
///     "symbol":  "sparkles",              // 选填：SF Symbol 名
///     "tooltip": "干点什么",               // 选填，缺省取 label
///     "event":   "myplugin.doSomething",  // 选填，缺省 "dash.toolbar.activate"
/// ]) { AnyView(MyFallbackButton()) }
/// host.events.subscribe("myplugin.doSomething") { _ in ... }
/// ```
///
/// **两条渲染路线，给了 `symbol` 就走原生那条**：`NSToolbarItem` +
/// `isBordered = true`，macOS 26 的圆形玻璃按钮、按下态、红绿灯对齐全是白送的，
/// 拿 SwiftUI 重画只会得到一个更差的仿制品。代价是点击回调必须另有通道——
/// 于是统一走事件总线：消费方只管 emit，贡献者自己 subscribe。
/// 这也顺手解决了"闭包跨世代"的问题：主题名是字符串，热替换后新一代重新订阅即可。
///
/// 没给 `symbol` 的（自定义控件、状态指示器）走兜底路线：`AnyView` 装进
/// `NSHostingView`，尺寸当场冻死（见 `makeContributionItem`）。
///
/// 位置：所有贡献排在 `.flexibleSpace` 之后、`.toggleSidebar` 之前，
/// 组内按 `order` 升序。系统项的位置不开放——它们与红绿灯、分栏分隔线的
/// 对齐关系是 AppKit 的，乱插只会把观感搞坏。
extension LayoutSplitController: NSToolbarDelegate {
    // sidebarTrackingSeparator 之前的项落在侧边栏区域，之后的落在内容区域（留空）。
    // 布局：红绿灯 …弹性… <贡献项…> 收起侧边栏 | 分隔线。
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var identifiers: [NSToolbarItem.Identifier] = [.flexibleSpace]
        identifiers += toolbarContributions.map {
            NSToolbarItem.Identifier(Self.contributionPrefix + $0.key)
        }
        identifiers += [.toggleSidebar, .sidebarTrackingSeparator]
        return identifiers
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

    private func makeContributionItem(
        _ identifier: NSToolbarItem.Identifier,
        _ contribution: DashContributions.Contribution
    ) -> NSToolbarItem {
        let label = contribution.metadata["label"] as? String ?? contribution.id
        let tooltip = contribution.metadata["tooltip"] as? String ?? label
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = tooltip

        if let symbol = contribution.metadata["symbol"] as? String,
           let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) {
            item.image = image
            item.isBordered = true // 玻璃观感白送
            item.target = self
            item.action = #selector(activateToolbarContribution(_:))
            return item
        }

        // 兜底：托管贡献自己的 SwiftUI 视图。**尺寸当场冻死**——
        // NSHostingView 会把内容的 fitting size 一路顶回工具栏，
        // 内容一变（换代重建）工具栏就会自己跳宽度。
        let hosting = NSHostingView(rootView: contribution.make())
        var size = hosting.fittingSize
        if size.width <= 0 { size.width = 32 }
        size.height = min(max(size.height, 1), 28) // 工具栏行高，超了会被裁掉
        hosting.frame = NSRect(origin: .zero, size: size)
        item.view = hosting
        return item
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
