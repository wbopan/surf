import AppKit
import SurfSDK
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

    /// 四栏的标签项。**存下来只为换语言时重贴文字**（见 `relocalize()`）。
    private var items: [(tab: SettingsTab, item: NSTabViewItem)] = []

    private func setupWindow() {
        let tabs = PreferenceTabController()
        tabs.tabStyle = .toolbar

        let strings = model.strings
        tabs.fallbackTitle = strings.settingsWindow
        for tab in SettingsTab.allCases {
            let page = SettingsPage(model: model, tab: tab, openPath: { [weak self] path in
                self?.open(path: path)
            })
            let controller = NSHostingController(rootView: page)
            // 显式写出来：窗口跟着内容走正是 preference 窗口该有的行为
            // （与槽内插件那条 `sizingOptions = []` 正好相反，见类注释）。
            controller.sizingOptions = [.preferredContentSize]
            let item = NSTabViewItem(viewController: controller)
            // **identifier 用 rawValue，不是标签文字**：它是这一项的身份，
            // 换语言时身份不该跟着变（计划 §0.5 不变量 6）。
            item.identifier = tab.rawValue
            apply(strings, to: tab, item: item)
            tabs.addTabViewItem(item)
            items.append((tab, item))
        }

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.toolbarStyle = .preference
        window.title = strings.tabTitle(.general)
        // 关掉只是 orderOut，所以窗口必须留着——否则第二次 ⌘, 会对着一个已释放的窗口。
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("settings.window")
        self.window = window
    }

    /// 一项的三处文字：工具栏标签、hosting controller 的 title、符号的 AX 描述。
    ///
    /// 符号**整个重造**而不是改现成那张的 `accessibilityDescription`：
    /// `NSImage(systemSymbolName:)` 拿到的可能是共享实例，就地改等于改了所有
    /// 用同一个符号的地方。重造一张是几微秒的事，别为它省。
    private func apply(_ strings: L, to tab: SettingsTab, item: NSTabViewItem) {
        let title = strings.tabTitle(tab)
        item.label = title
        item.viewController?.title = title
        item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: title)
    }

    /// 换语言时把窗框那半边重贴一遍。
    ///
    /// **页面内容不用管**：那是 SwiftUI，读 `model.strings` 就自己重渲了。
    /// 这里要收拾的是 AppKit 拿着的那几处——`.preference` 工具栏的四个标签
    /// 与窗口标题。由 `SettingsPlugin` 订 `surf.locale` 后调用（AppKit 不在
    /// SwiftUI 的观察范围里，而 `withObservationTracking` 那条路有静默死亡坑）。
    /// - Parameter locale: **由调用方从事件载荷里取，不读 model**。
    ///   总线的订阅者存在字典里，回调顺序未定义——`SurfLocaleStore` 也是一个订阅者，
    ///   它可能排在这次回调**后面**，那时 `model.strings` 还是旧语言，
    ///   窗框就会永远慢一次切换（而且不报错）。
    func relocalize(_ locale: SurfLocale) {
        let strings = L(locale)
        for entry in items { apply(strings, to: entry.tab, item: entry.item) }
        // 标题跟着**当前选中**那一项走。工具栏是 `NSTabViewController` 自己建的，
        // 标签一改它会自己重排。
        guard let window else { return }
        let tabs = contentViewController as? PreferenceTabController
        tabs?.fallbackTitle = strings.settingsWindow
        let index = tabs?.selectedTabViewItemIndex ?? -1
        let selected = (tabs?.tabViewItems.indices.contains(index) ?? false)
            ? tabs?.tabViewItems[index] : nil
        window.title = selected?.label ?? strings.settingsWindow
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
            // 日志留中文（读它的是蹲在终端前的人），界面那句跟语言走。
            log("打开配置文件失败：\(path)")
            model.notice = model.strings.openFailed(path)
        }
    }
}

/// 切页时把窗口标题换成页名。
///
/// 参考设计里标题栏写的是「General」「Accounts」，不是一个恒定的「设置」
/// ——`.preference` 工具栏样式下标题与标签是一体的，标题不跟着换会显得标签栏没接线。
private final class PreferenceTabController: NSTabViewController {
    /// 一项都没选中时的窗口标题。**由外面按当前语言灌进来**：
    /// 这个类不认识 `L`，也不该为了一个兜底词去认识它。
    var fallbackTitle = ""

    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        view.window?.title = item?.label ?? fallbackTitle
    }
}
