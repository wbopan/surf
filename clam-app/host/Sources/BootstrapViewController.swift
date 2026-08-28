import AppKit

/// 覆盖整个窗口的引导视图，三态：
/// - busy：转圈 + 一行状态（正在寻找 dsh / 正在连接）
/// - guide：标题 + 说明 + 可复制命令 + 重试（未检测到 dsh、连接断开）
/// - error：标题 + 说明 + 重试（guide 的无命令版）
@MainActor
final class BootstrapViewController: NSViewController {
    private let spinner = NSProgressIndicator()
    private let titleLabel = NSTextField(labelWithString: "")
    private let label = NSTextField(labelWithString: "")
    /// 可选中的等宽命令行（`dsh web`），配一个拷贝按钮。
    private let commandField = NSTextField(labelWithString: "")
    private let copyButton = NSButton()
    private let commandRow = NSStackView()
    private let retryButton = NSButton()
    private var retryHandler: (() -> Void)?

    override func loadView() {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        #if DEBUG
        // Dev 构建：背景加淡橙色斜纹水印，启动页即区分 Debug/Release。
        if let stripe = makeDevStripes() {
            stripe.frame = view.bounds
            stripe.autoresizingMask = [.width, .height]
            view.addSubview(stripe)
        }
        #endif
        self.view = view
    }

    #if DEBUG
    /// 淡橙色斜纹平铺层，铺满 bootstrap 背景。
    private func makeDevStripes() -> NSView? {
        final class StripeView: NSView {
            override func draw(_ dirtyRect: NSRect) {
                guard let ctx = NSGraphicsContext.current?.cgContext else { return }
                let tile = CGSize(width: 12, height: 12)
                let image = NSImage(size: tile)
                image.lockFocusFlipped(false)
                NSColor.systemOrange.withAlphaComponent(0.10).setFill()
                for offset in [CGFloat(-6), 0] {
                    let p = NSBezierPath()
                    p.move(to: NSPoint(x: offset, y: 0))
                    p.line(to: NSPoint(x: offset + 6, y: 12))
                    p.line(to: NSPoint(x: offset + 12, y: 12))
                    p.line(to: NSPoint(x: offset + 6, y: 0))
                    p.close()
                    p.fill()
                }
                image.unlockFocus()
                guard let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let cg = rep.cgImage else { return }
                ctx.saveGState()
                ctx.setFillColor(CGColor(pattern: CGPattern(
                    image: cg,
                    contentRect: CGRect(origin: .zero, size: tile),
                    matrix: CGAffineTransform.identity,
                    xStep: tile.width, yStep: tile.height,
                    tiling: .constantSpacingMinimalDistortion,
                    isColored: true)!,
                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                    components: [1, 1, 1, 1]))
                ctx.fill(bounds)
                ctx.restoreGState()
            }
        }
        let v = StripeView()
        return v
    }
    #endif

    override func viewDidLoad() {
        super.viewDidLoad()

        spinner.style = .spinning
        spinner.controlSize = .regular

        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.maximumNumberOfLines = 0
        titleLabel.isHidden = true

        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.alignment = .center

        commandField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        commandField.isSelectable = true
        commandField.drawsBackground = true
        commandField.backgroundColor = .textBackgroundColor
        commandField.isBordered = true
        commandField.bezelStyle = .roundedBezel

        // 按钮文案（拷贝 / 重试）由 setGuide 每次带进来：引导页可能跨越一次
        // 语言切换，写死在这里就换不掉了。
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.target = self
        copyButton.action = #selector(copyCommand)

        commandRow.orientation = .horizontal
        commandRow.spacing = 8
        commandRow.addArrangedSubview(commandField)
        commandRow.addArrangedSubview(copyButton)
        commandRow.isHidden = true

        retryButton.bezelStyle = .rounded
        retryButton.target = self
        retryButton.action = #selector(retryTapped)
        retryButton.isHidden = true

        // 单列居中栈：转圈 / 标题 / 说明 / 命令行 / 重试，各态按需隐藏。
        let stack = NSStackView(views: [spinner, titleLabel, label, commandRow, retryButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 40),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -40),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            commandField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
    }

    /// 转圈态：一行状态文本，无标题无按钮。
    func setBusy(_ text: String) {
        titleLabel.isHidden = true
        commandRow.isHidden = true
        retryButton.isHidden = true
        label.stringValue = text
        spinner.isHidden = false
        spinner.startAnimation(nil)
    }

    /// 引导态：标题 + 说明 +（可选）可复制命令 + 重试按钮。
    /// 停转圈——这一态不是"在等"，是"等你做点什么"。
    ///
    /// **文案一概由调用方递进来**（含两个按钮的标题）：这个 VC 不认识语言，
    /// 换语言时壳照着当前那一幕再调一次就行（`MainWindowController.renderBootstrap`）。
    func setGuide(title: String, detail: String, command: String? = nil,
                  copyTitle: String, retryTitle: String, retry: @escaping () -> Void) {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        titleLabel.stringValue = title
        titleLabel.isHidden = false
        label.stringValue = detail
        if let command {
            commandField.stringValue = command
            commandRow.isHidden = false
        } else {
            commandRow.isHidden = true
        }
        copyButton.title = copyTitle
        retryButton.title = retryTitle
        retryButton.isHidden = false
        retryHandler = retry
    }

    /// error 态 = guide 的无命令版。眼下没有调用方（连接失败都归到 guide 那两幕），
    /// 留着是因为它是三态之一，且成本为零。
    func setError(title: String, detail: String, retryTitle: String, retry: @escaping () -> Void) {
        setGuide(title: title, detail: detail, command: nil,
                 copyTitle: "", retryTitle: retryTitle, retry: retry)
    }

    @objc private func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commandField.stringValue, forType: .string)
    }

    @objc private func retryTapped() {
        retryHandler?()
    }
}
