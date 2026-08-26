import AppKit
import DashSDK
import SwiftUI

/// 设置窗口。
///
/// M0 只有窗框与生命周期：内容是一块占位视图，快照与表单从 M1 起长进来。
///
/// **窗口关掉不销毁**：`orderOut` 而已，视图与状态留着，第二次 ⌘, 是秒开。
/// 整代插件退休时才连窗一起收（`SettingsPlugin` 的 handle 释放）。
final class SettingsWindowController: NSWindowController {

    private let host: DashHost

    init(host: DashHost) {
        self.host = host
        super.init(window: nil)
        setupWindow()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupWindow() {
        let content = NSHostingController(rootView: SettingsPlaceholderView())
        // 默认含 .preferredContentSize：SwiftUI 内容的 fitting 尺寸会反过来顶窗口，
        // 用户调好的大小就没了（CLAUDE.md 踩坑记录里那条）。
        content.sizingOptions = []

        let window = NSWindow(contentViewController: content)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "设置"
        window.setContentSize(NSSize(width: 820, height: 600))
        window.minSize = NSSize(width: 680, height: 440)
        // 设置窗口不进 ⌘` 的主窗口轮转，但要能被 ⌘W 关掉。关掉只是 orderOut，
        // 所以必须自己留着——否则第二次 ⌘, 会对着一个已释放的窗口。
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("DashSettingsWindow")
        window.identifier = NSUserInterfaceItemIdentifier("settings.window")
        self.window = window
    }

    func present() {
        guard let window else { return }
        // frameAutosaveName 有记录时别居中：那会覆盖用户上次摆好的位置。
        if !window.isVisible && window.frame.origin == .zero {
            window.center()
        }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)
    }
}

/// M0 的占位内容。M1 把它换成 ns 快照的只读列表。
struct SettingsPlaceholderView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "gearshape")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text("设置")
                .font(.title3)
            Text("接线已通，内容从 M1 起长进来。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("settings.placeholder")
    }
}
