import AppKit
import DashSDK
import SwiftUI

/// 设置窗口：窗框归 AppKit，内容整个是 SwiftUI。
///
/// **窗口关掉不销毁**：`orderOut` 而已，视图与滚动位置留着，第二次 ⌘, 是秒开。
/// 整代插件退休时才连窗一起收（`SettingsPlugin` 的 handle 释放）。
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
        let root = SettingsRootView(model: model, openPath: { [weak self] path in
            self?.open(path: path)
        })
        let content = NSHostingController(rootView: root)
        // 默认含 .preferredContentSize：SwiftUI 内容的 fitting 尺寸会反过来顶窗口，
        // 用户调好的大小就没了（CLAUDE.md 踩坑记录里那条）。
        content.sizingOptions = []

        let window = NSWindow(contentViewController: content)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = false
        window.title = "设置"
        window.setContentSize(NSSize(width: 860, height: 620))
        window.minSize = NSSize(width: 700, height: 460)
        // 关掉只是 orderOut，所以窗口必须留着——否则第二次 ⌘, 会对着一个已释放的窗口。
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("DashSettingsWindow")
        window.identifier = NSUserInterfaceItemIdentifier("settings.window")
        self.window = window
    }

    func present() {
        guard let window else { return }
        if !window.isVisible && window.frame.origin == .zero { window.center() }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)
        // 每次打开都对一次账：窗口关着的这段时间里 dsh 可能重启过。
        model.refresh()
    }

    /// 打开配置文件。
    ///
    /// **路径来自 dsh、由壳来 open**：只有 `NSWorkspace` 认用户的默认编辑器。
    /// 这里不采信页面/远端给的任何路径分量之外的东西——它就是 host 报的绝对路径。
    private func open(path: String) {
        let url = URL(fileURLWithPath: path)
        if !NSWorkspace.shared.open(url) {
            log("打开配置文件失败：\(path)")
            model.notice = "打开失败：\(path)"
        }
    }
}
