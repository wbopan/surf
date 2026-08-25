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
    private let surface: DashConversationSurface

    private var sidebarItem: NSSplitViewItem?
    /// 自动折叠标记：因窗口收窄而折叠（而非用户手动收起），拉宽后自动恢复。
    private var autoCollapsed = false
    /// 折叠前的厚度，用作自动恢复的宽度阈值。
    private var lastVisibleThickness = LayoutSplitController.sidebarDefaultWidth
    private var resizeObserver: NSObjectProtocol?
    private var ownedToolbar: NSToolbar?
    /// 装了工具栏的那扇窗（deinit 里不能再摸 `view.window`，它是 MainActor 隔离的）。
    private weak var installedWindow: NSWindow?

    init(host: DashHost, webView: WKWebView, surface: DashConversationSurface) {
        self.host = host
        self.webView = webView
        self.surface = surface
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
        installToolbar()
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
        installToolbar()

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

    /// 左上角工具栏（红绿灯同排）：新建会话 + 收起侧边栏。
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

    @objc fileprivate func newSessionFromToolbar() {
        surface.startSession(workspaceId: nil)
    }
}

// MARK: - 工具栏项

private extension NSToolbarItem.Identifier {
    static let newSession = NSToolbarItem.Identifier("dash.newSession")
}

extension LayoutSplitController: NSToolbarDelegate {
    // sidebarTrackingSeparator 之前的项落在侧边栏区域，之后的落在内容区域（留空）。
    // 布局：红绿灯 …弹性… 新建会话 收起侧边栏 | 分隔线。
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
