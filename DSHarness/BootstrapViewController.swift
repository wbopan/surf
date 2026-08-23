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
        self.view = view
    }

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
