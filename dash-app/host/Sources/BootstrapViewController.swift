import AppKit

/// 首启/错误引导视图：安装中、启动中、失败（带重试）。
@MainActor
final class BootstrapViewController: NSViewController {
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
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
        spinner.translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: 14)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        retryButton.title = "重试"
        retryButton.bezelStyle = .rounded
        retryButton.target = self
        retryButton.action = #selector(retryTapped)
        retryButton.isHidden = true
        retryButton.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(spinner)
        view.addSubview(label)
        view.addSubview(retryButton)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -24),

            label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 16),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 40),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -40),
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            retryButton.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 16),
            retryButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
    }

    func setBusy(_ text: String) {
        label.stringValue = text
        spinner.startAnimation(nil)
        retryButton.isHidden = true
    }

    func setError(_ text: String, retry: @escaping () -> Void) {
        spinner.stopAnimation(nil)
        label.stringValue = text
        retryHandler = retry
        retryButton.isHidden = false
    }

    @objc private func retryTapped() {
        retryHandler?()
    }
}
