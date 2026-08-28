import AppKit

/// ⌥⌘D 打开的诊断面板：一屏纯文本，回答「此刻这个壳到底连着谁、跑着哪几份代码」。
///
/// 计划 §8 原本把这些塞进 BootstrapVC。实做改成独立面板，理由是覆盖面反了——
/// 引导页只在**没连上 dsh** 时露脸，而这些问题（插件是第几代、编译过没有、
/// 退休了多少 image）恰恰只在**连上之后**才有答案。做成随时能开的面板，
/// 蹲在终端前的人和 agent 都能拿它对账。
@MainActor
final class DiagnosticsPanel: NSWindowController {
    private let textView = NSTextView()
    private var collect: (() -> String)?

    convenience init(collect: @escaping () -> String) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "\(AppInfo.displayName) 诊断"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        self.init(window: panel)
        self.collect = collect
        buildContent(in: panel)
    }

    private func buildContent(in panel: NSPanel) {
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.autoresizingMask = [.width]

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let refresh = NSButton(title: "刷新", target: self, action: #selector(refreshNow))
        refresh.bezelStyle = .rounded
        let copy = NSButton(title: "拷贝", target: self, action: #selector(copyAll))
        copy.bezelStyle = .rounded
        let logs = NSButton(title: "打开日志目录", target: self, action: #selector(openLogs))
        logs.bezelStyle = .rounded

        let buttons = NSStackView(views: [refresh, copy, logs])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        panel.contentView = content
    }

    /// 每次打开都重新采一次——面板是快照，不是实时视图。
    func present() {
        refreshNow()
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func refreshNow() {
        textView.string = collect?() ?? ""
    }

    @objc private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
    }

    @objc private func openLogs() {
        NSWorkspace.shared.open(DashPaths.logsDir)
    }
}
