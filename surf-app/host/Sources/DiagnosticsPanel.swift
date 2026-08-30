import AppKit

/// ⌥⌘D 打开的诊断面板：一屏纯文本，回答「此刻这个壳到底连着谁、跑着哪几份代码」。
///
/// 计划 §8 原本把这些塞进 BootstrapVC。实做改成独立面板，理由是覆盖面反了——
/// 引导页只在**没连上 dsh** 时露脸，而这些问题（插件是第几代、编译过没有、
/// 退休了多少 image）恰恰只在**连上之后**才有答案。做成随时能开的面板，
/// 蹲在终端前的人和 agent 都能拿它对账。
///
/// 正文由 `collect` 现采（`MainWindowController.diagnosticsText()`，文案已按
/// 当前语言拼好）；面板自己的 chrome（标题、三颗按钮）存一份 `L`，
/// 换语言时由壳调 `apply(strings:)` 换掉——面板可能一直开着。
@MainActor
final class DiagnosticsPanel: NSWindowController {
    private let textView = NSTextView()
    /// 返回 nil = 窗口已销毁，用文案表里那句话兜底。
    private var collect: (() -> String?)?
    private var strings: L
    private let refreshButton = NSButton()
    private let copyButton = NSButton()
    private let logsButton = NSButton()

    init(strings: L, collect: @escaping () -> String?) {
        self.strings = strings
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        super.init(window: panel)
        self.collect = collect
        buildContent(in: panel)
        applyStrings()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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

        for (button, action) in [(refreshButton, #selector(refreshNow)),
                                 (copyButton, #selector(copyAll)),
                                 (logsButton, #selector(openLogs))] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
        }

        let buttons = NSStackView(views: [refreshButton, copyButton, logsButton])
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
    func present(strings: L) {
        apply(strings: strings)
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    /// 换语言：chrome 换文案，正文重采一次（`collect` 那边已经是新语言了）。
    func apply(strings: L) {
        self.strings = strings
        applyStrings()
        refreshNow()
    }

    private func applyStrings() {
        window?.title = strings.diagnosticsTitle
        refreshButton.title = strings.diagnosticsRefresh
        copyButton.title = strings.copy
        logsButton.title = strings.menuOpenLogs
    }

    @objc private func refreshNow() {
        textView.string = collect.flatMap { $0() } ?? strings.diagnosticsWindowGone
    }

    @objc private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
    }

    @objc private func openLogs() {
        NSWorkspace.shared.open(SurfPaths.logsDir)
    }
}
