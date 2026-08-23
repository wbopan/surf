import AppKit

/// 应用设置。
enum Settings {
    static let nodePathKey = "nodePath"
    static let updateIntervalKey = "updateIntervalHours"

    static var updateIntervalHours: Double {
        get { UserDefaults.standard.double(forKey: updateIntervalKey) }
        set { UserDefaults.standard.set(newValue, forKey: updateIntervalKey) }
    }

    static let intervals: [(title: String, hours: Double)] = [
        ("手动（仅启动时检查）", 0),
        ("每 6 小时", 6),
        ("每 24 小时", 24),
    ]
}

/// 设置窗口：Node 路径、更新频率、harness 安装信息。
@MainActor
final class SettingsWindowController: NSWindowController {
    private let nodeField = NSTextField(string: "")
    private let intervalPopup = NSPopUpButton()
    private let versionLabel = NSTextField(labelWithString: "")
    private let dirLabel = NSTextField(labelWithString: "")
    private let checkButton = NSButton(title: "立即检查更新", target: nil, action: nil)
    private let restartButton = NSButton(title: "重启 Harness", target: nil, action: nil)

    private weak var mainController: MainWindowController?

    init(mainController: MainWindowController) {
        self.mainController = mainController
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 280),
                           styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.title = "DSHarness 设置"
        win.isReleasedWhenClosed = false
        super.init(window: win)
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildContent() {
        guard let content = window?.contentView else { return }

        let nodeLabel = NSTextField(labelWithString: "Node.js 路径")
        nodeLabel.font = .systemFont(ofSize: 12)
        nodeField.placeholderString = "/opt/homebrew/bin/node"
        nodeField.translatesAutoresizingMaskIntoConstraints = false

        let browseButton = NSButton(title: "浏览…", target: self, action: #selector(browseNode))
        browseButton.bezelStyle = .rounded

        let intervalLabel = NSTextField(labelWithString: "检查更新频率")
        intervalLabel.font = .systemFont(ofSize: 12)
        intervalPopup.addItems(withTitles: Settings.intervals.map { $0.title })
        intervalPopup.selectItem(at: Settings.intervals.firstIndex { $0.hours == Settings.updateIntervalHours } ?? 0)
        intervalPopup.target = self
        intervalPopup.action = #selector(intervalChanged)

        versionLabel.font = .systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        dirLabel.font = .systemFont(ofSize: 11)
        dirLabel.textColor = .tertiaryLabelColor
        dirLabel.lineBreakMode = .byTruncatingMiddle

        checkButton.target = self
        checkButton.action = #selector(checkNow)
        checkButton.bezelStyle = .rounded

        restartButton.target = self
        restartButton.action = #selector(restartNow)
        restartButton.bezelStyle = .rounded

        let nodeRow = NSStackView(views: [nodeField, browseButton])
        nodeRow.orientation = .horizontal
        nodeRow.spacing = 8

        let intervalRow = NSStackView(views: [intervalPopup])
        intervalRow.orientation = .horizontal

        let actionsRow = NSStackView(views: [checkButton, restartButton])
        actionsRow.orientation = .horizontal
        actionsRow.spacing = 8

        let stack = NSStackView(views: [nodeLabel, nodeRow, intervalLabel, intervalRow,
                                        versionLabel, dirLabel, actionsRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            nodeField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            intervalRow.widthAnchor.constraint(equalTo: nodeField.widthAnchor, multiplier: 1, constant: 40),
        ])

        nodeField.stringValue = UserDefaults.standard.string(forKey: Settings.nodePathKey) ?? ""
        refreshInfo()
    }

    private func refreshInfo() {
        guard let main = mainController else { return }
        let manager = main.harnessManager
        versionLabel.stringValue = "当前 harness：\(manager.currentVersion() ?? "未安装")"
        dirLabel.stringValue = "安装目录：\(manager.harnessRoot.path)"
    }

    override func showWindow(_ sender: Any?) {
        refreshInfo()
        super.showWindow(sender)
    }

    // MARK: - actions

    @objc private func browseNode() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "选择 Node.js 可执行文件"
        if panel.runModal() == .OK, let url = panel.url {
            nodeField.stringValue = url.path
        }
    }

    @objc private func intervalChanged() {
        let idx = intervalPopup.indexOfSelectedItem
        guard idx >= 0, idx < Settings.intervals.count else { return }
        Settings.updateIntervalHours = Settings.intervals[idx].hours
        mainController?.rescheduleUpdateTimer()
    }

    @objc private func checkNow() {
        saveNodePath()
        Task { await mainController?.checkUpdates(force: true, silent: false) }
    }

    @objc private func restartNow() {
        saveNodePath()
        mainController?.restartHarness()
    }

    private func saveNodePath() {
        let p = nodeField.stringValue.trimmingCharacters(in: .whitespaces)
        UserDefaults.standard.set(p, forKey: Settings.nodePathKey)
        Log.write("Node 路径已设置：\(p)")
    }
}
