import AppKit

/// 壳自身构建状态的浮动提示条（计划 §7.5 v1）。
///
/// 这是壳 chrome，不是业务 UI：插件热替换是秒级、不重启的轻循环，而**壳重建
/// 必须重启进程**——页面状态会丢、要几秒钟。所以它只提示，不擅自动手；
/// 什么时候重启归用户（`restartOnRebuild` 打开时才自动走）。
///
/// 浮在右上角、可随手关掉，因为它永远不是当下最要紧的事。
@MainActor
final class ShellUpdateBanner: NSView {
    enum Kind {
        case building
        case ready(detail: String)
        case failed
    }

    // 三态共用同一行控件，按态显隐——提示条不该因为换了句话就重排。
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    private let primary = NSButton()
    private let dismiss = NSButton()
    /// 主按钮在三态里做的事不同（重启 / 看日志），所以回调带上当前态，
    /// 由壳一处 switch 决定，视图本身不认识"重启"这件事。
    private var primaryHandler: ((Kind) -> Void)?
    private var dismissHandler: (() -> Void)?
    private var kind: Kind = .building

    init(onPrimary: @escaping (Kind) -> Void, onDismiss: @escaping () -> Void) {
        primaryHandler = onPrimary
        dismissHandler = onDismiss
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        // 毛玻璃底 + 圆角，与 macOS 的临时提示一族保持一致。
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        label.font = .systemFont(ofSize: 12)
        label.maximumNumberOfLines = 1  // 永远一行：提示条不该因为一句长话把自己撑成两层

        primary.bezelStyle = .rounded
        primary.controlSize = .small
        primary.target = self
        primary.action = #selector(primaryTapped)

        dismiss.bezelStyle = .rounded
        dismiss.controlSize = .small
        dismiss.title = "稍后"   // ready 态的默认文案；failed 态会改成「知道了」
        dismiss.target = self
        dismiss.action = #selector(dismissTapped)

        let row = NSStackView(views: [spinner, label, primary, dismiss])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(row)

        NSLayoutConstraint.activate([
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: effect.topAnchor),
            row.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
        ])
    }

    func show(_ kind: Kind) {
        self.kind = kind
        switch kind {
        case .building:
            spinner.startAnimation(nil)
            label.stringValue = "正在重建壳…"
            primary.isHidden = true
            dismiss.isHidden = true
        case .ready(let detail):
            spinner.stopAnimation(nil)
            label.stringValue = "壳有新版本\(detail.isEmpty ? "" : "（\(detail)）")"
            primary.title = "重启 \(AppInfo.displayName)"
            primary.isHidden = false
            primary.keyEquivalent = ""
            dismiss.title = "稍后"
            dismiss.isHidden = false
        case .failed:
            spinner.stopAnimation(nil)
            label.stringValue = "壳重建失败"
            primary.title = "看日志"
            primary.isHidden = false
            dismiss.title = "知道了"
            dismiss.isHidden = false
        }
    }

    @objc private func primaryTapped() { primaryHandler?(kind) }
    @objc private func dismissTapped() { dismissHandler?() }
}
