import AppKit

/// 一次性浮条：告诉用户刚刚发生了什么（下载完成、下载失败），说完就走。
///
/// 与 `ShellUpdateBanner` 同一族视觉（毛玻璃 + 单行 + 右上角），语义却相反：
/// 那条是"有件事等你决定"，会一直挂到用户处理；这条是"事情已经发生了"，
/// 超时自己消失。所以两者不共用一个类——共用只会逼出一个既要常驻又要自毁的开关。
///
/// M7（系统通知）已放弃，壳不申请通知权限：所有"刚刚发生了什么"都在窗口里说。
@MainActor
final class ShellToast: NSView {
    struct Content {
        var text: String
        /// 可选的一步跟进（如"在访达中显示"）。点了就收起——浮条不做第二件事。
        var actionTitle: String?
        var action: (() -> Void)?
    }

    /// 带按钮的多给几秒：用户得先读完那句话才知道该不该点。
    private static let plainLifetime: TimeInterval = 5
    private static let actionableLifetime: TimeInterval = 9

    private let content: Content
    private let onDismiss: (ShellToast) -> Void
    private var expiry: DispatchWorkItem?

    init(content: Content, onDismiss: @escaping (ShellToast) -> Void) {
        self.content = content
        self.onDismiss = onDismiss
        super.init(frame: .zero)
        build()
        scheduleExpiry()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        let label = NSTextField(labelWithString: content.text)
        label.font = .systemFont(ofSize: 12)
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingMiddle  // 文件名截中间：扩展名比中段更该留住

        var views: [NSView] = [label]
        if let title = content.actionTitle {
            let button = NSButton(title: title, target: self, action: #selector(actionTapped))
            button.bezelStyle = .rounded
            button.controlSize = .small
            views.append(button)
        }
        let close = NSButton(title: "关闭", target: self, action: #selector(dismissTapped))
        close.bezelStyle = .rounded
        close.controlSize = .small
        views.append(close)

        let row = NSStackView(views: views)
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
            // 一行浮条不该长到横穿整个窗口
            widthAnchor.constraint(lessThanOrEqualToConstant: 520),
        ])
    }

    private func scheduleExpiry() {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.onDismiss(self)
        }
        expiry = work
        let delay = content.actionTitle == nil ? Self.plainLifetime : Self.actionableLifetime
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func retire() {
        expiry?.cancel()
        expiry = nil
        onDismiss(self)
    }

    @objc private func actionTapped() {
        content.action?()
        retire()
    }

    @objc private func dismissTapped() { retire() }
}
