import AppKit
import DashSDK
import SwiftUI

/// 设置窗口：**窗框与标签栏归 AppKit，页面内容是 SwiftUI**。
///
/// 上一版是一扇固定 860×620 的窗口里塞一个 `NavigationSplitView`——那是 iPad 的
/// 形状，不是 macOS 偏好设置的形状。macOS 的惯例是这三件事凑起来的：
///
/// 1. `NSWindow.toolbarStyle = .preference` —— 图标在上、标题在下、整排居中的工具栏。
///    这个样式**只有 AppKit 有**，SwiftUI 的 `TabView` 在 macOS 上给的是分段控件，
///    长得完全不是一回事。
/// 2. `NSTabViewController.tabStyle = .toolbar` —— 它自己去建那排工具栏项，
///    并且**在切页时把窗口动画到新页的尺寸**。这正是参考设计里 General 矮、
///    Accounts 高的来源，不是各页硬凑一个统一高度。
/// 3. 每页一个 `NSHostingController`，**保留默认的 `.preferredContentSize`**。
///    CLAUDE.md 那条踩坑记录（槽内插件必须设 `sizingOptions = []`）在这里正好反过来：
///    槽里是"别让内容顶飞用户调好的分栏宽度"，这里是"窗口本就该跟着内容走"。
///    同一个开关，两种场景，结论相反——照抄那条会得到一扇不会自适应的窗。
///
/// 窗口不可缩放：每页的尺寸由内容定死，用户没有能调的东西，也就没有"调乱了"这一说。
@MainActor
final class SettingsWindowController: NSWindowController {

    private let model: SettingsModel
    private let log: (String) -> Void

    init(model: SettingsModel, log: @escaping (String) -> Void) {
        self.model = model
        self.log = log
        super.init(window: nil)
        setupWindow()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupWindow() {
        let tabs = PreferenceTabController()
        tabs.tabStyle = .toolbar

        for tab in SettingsTab.allCases {
            let page = SettingsPage(model: model, tab: tab, openPath: { [weak self] path in
                self?.open(path: path)
            })
            let controller = NSHostingController(rootView: page)
            // 显式写出来：窗口跟着内容走正是 preference 窗口该有的行为
            // （与槽内插件那条 `sizingOptions = []` 正好相反，见类注释）。
            controller.sizingOptions = [.preferredContentSize]
            controller.title = tab.title
            let item = NSTabViewItem(viewController: controller)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            item.identifier = tab.rawValue
            tabs.addTabViewItem(item)
        }

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.toolbarStyle = .preference
        window.title = SettingsTab.general.title
        // 关掉只是 orderOut，所以窗口必须留着——否则第二次 ⌘, 会对着一个已释放的窗口。
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("settings.window")
        self.window = window
    }

    /// 有没有摆过位置。**不能用 `frame.origin == .zero` 当判据**：
    /// `NSWindow(contentViewController:)` 会按 cascading 给一个非零的初始位置，
    /// 于是那个判断永远为假、`center()` 永远不执行。实测结果是窗口落在
    /// y = -32——标题栏顶出屏幕外，拖不动也点不着。
    private var placed = false

    func present() {
        guard let window else { return }
        if !placed {
            placed = true
            window.center()
        }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)
        // 每次打开都对一次账：窗口关着的这段时间里 dsh 可能重启过。
        model.refresh()
    }

    /// 打开配置文件。
    ///
    /// **路径来自 dsh、由壳来 open**：只有 `NSWorkspace` 认用户的默认编辑器。
    private func open(path: String) {
        let url = URL(fileURLWithPath: path)
        if !NSWorkspace.shared.open(url) {
            log("打开配置文件失败：\(path)")
            model.notice = "打开失败：\(path)"
        }
    }
}

/// 切页时把窗口标题换成页名。
///
/// 参考设计里标题栏写的是「General」「Accounts」，不是一个恒定的「设置」
/// ——`.preference` 工具栏样式下标题与标签是一体的，标题不跟着换会显得标签栏没接线。
private final class PreferenceTabController: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        view.window?.title = item?.label ?? "设置"
    }
}
