import AppKit

/// ⌘/ 打开的「键盘快捷键」面板。
///
/// 内容**不是手写清单，而是现场遍历 `NSApp.mainMenu`** ——手写清单必然与菜单
/// 漂移（加一项忘了补一行，删一项忘了删）。代价是它只认菜单里的东西：
/// 页面自己处理的按键（Esc 停止生成）遍历不到，末尾单列一节补上。
///
/// 隐藏项也要收：⌘1…⌘9 与 ⌘= 都是 `isHidden` 的（菜单里九行"会话 N"没信息量），
/// 但它们恰恰是最需要有个地方能查到的那批快捷键。
///
/// 菜单文案跟着界面语言走，所以这张表天然是双语的；面板自己的 chrome
/// （标题、拷贝按钮、"页面内"那一节）由 `L` 供给，换语言时壳来调
/// `refreshIfVisible`。
@MainActor
final class ShortcutsPanel: NSWindowController {
    private let textView = NSTextView()
    private let copyButton = NSButton()
    private var strings: L
    /// 最近一次展示时的「停止生成」键位，换语言重画时要照旧。
    private var stopSpec = ""

    init(strings: L) {
        self.strings = strings
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        super.init(window: panel)
        buildContent(in: panel)
        applyStrings()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildContent(in panel: NSPanel) {
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.autoresizingMask = [.width]

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        copyButton.bezelStyle = .rounded
        copyButton.target = self
        copyButton.action = #selector(copyAll)
        copyButton.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(copyButton)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            copyButton.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            copyButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            copyButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        panel.contentView = content
    }

    /// 每次打开都重新遍历一次：菜单不是常量（插件换代、用户改配置都可能动它），
    /// 缓存一份就是在准备一张过期的表。
    /// `stopSpec`：页面侧「停止生成」的当前键位（`Keymap.stopSpec`），空串 = 已禁用。
    func present(strings: L, stopSpec: String) {
        self.strings = strings
        self.stopSpec = stopSpec
        applyStrings()
        render()
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    /// 换语言 / 换键位：面板开着才重画。**关着的不用管**——下次打开本来就是现采的。
    func refreshIfVisible(strings: L, stopSpec: String) {
        self.strings = strings
        self.stopSpec = stopSpec
        applyStrings()
        guard window?.isVisible == true else { return }
        render()
    }

    private func applyStrings() {
        window?.title = strings.shortcutsTitle
        copyButton.title = strings.copy
    }

    private func render() {
        textView.textStorage?.setAttributedString(renderAll())
    }

    @objc private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
    }

    // MARK: - 采集

    private struct Row {
        let title: String
        let shortcut: String
    }

    // MARK: - 排版
    //
    // **两列靠制表位对齐，不靠补空格。** 旧版按"CJK 占两格、ASCII 占一格"数出
    // 一个宽度再补空格，那套等宽假设换成英文菜单就散架（英文标题全是窄字符，
    // 补出来的列宽忽宽忽窄），何况中英混排本来就不是整数倍关系。
    // 制表位由**实测文本宽度**定：每节量一次本节最长标题，把制表位摆在它右边，
    // 布局引擎照着真实字形推——任何语言、任何字体都对得齐。
    // 拷贝出去的仍是 `标题\t快捷键`，粘到别处照样是两列。

    private static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let headerFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
    /// 标题列与快捷键列之间的空隙。
    private static let columnGap: CGFloat = 24

    private func renderAll() -> NSAttributedString {
        let out = NSMutableAttributedString()
        for top in NSApp.mainMenu?.items ?? [] {
            guard let submenu = top.submenu else { continue }
            var rows: [Row] = []
            Self.collect(from: submenu, into: &rows, spaceName: strings.keySpace)
            guard !rows.isEmpty else { continue }
            out.append(Self.render(section: top.title, rows: rows))
        }
        // 页面自己吃掉的按键：不在任何 NSMenu 里，遍历拿不到。键位跟着设置走
        // （`Keymap.stopSpec` 由调用方递进来），不再手写死值——手写的那版在
        // stopGenerating 变成可配置项之后就会与设置漂移。
        // 这一节每加一条都意味着"页面侧实现了一个壳不知道的快捷键"。
        let stopShortcut: String
        if stopSpec.isEmpty {
            stopShortcut = strings.shortcutsDisabled
        } else if let binding = KeymapSpec.parse(stopSpec) {
            stopShortcut = Self.symbols(for: binding.keyEquivalent, modifiers: binding.mask,
                                        spaceName: strings.keySpace)
        } else {
            stopShortcut = stopSpec // 解析不动就原样展示，至少不骗人
        }
        out.append(Self.render(section: strings.shortcutsInPage, rows: [
            Row(title: strings.shortcutsStopGenerating, shortcut: stopShortcut),
        ]))
        return out
    }

    /// 深度优先收一棵菜单树。同一节里**按标题去重**：⌘= 那种别名项与正主同名，
    /// 列两遍只会让人以为有两个功能（隐藏别名的存在是实现细节，不是知识点）。
    private static func collect(from menu: NSMenu, into rows: inout [Row], spaceName: String) {
        for item in menu.items {
            if let submenu = item.submenu {
                collect(from: submenu, into: &rows, spaceName: spaceName)
                continue
            }
            guard !item.isSeparatorItem, !item.keyEquivalent.isEmpty else { continue }
            guard !rows.contains(where: { $0.title == item.title }) else { continue }
            rows.append(Row(title: item.title,
                            shortcut: symbols(for: item.keyEquivalent,
                                              modifiers: item.keyEquivalentModifierMask,
                                              spaceName: spaceName)))
        }
    }

    private static func render(section: String, rows: [Row]) -> NSAttributedString {
        // 快捷键列的制表位取本节最长标题，避免整个面板迁就某一节的长标题
        // （"下一个待处理会话" 比 "放大" 长得多）。
        // 量的是**整段行首**（含那两格缩进），制表位是相对行首算的。
        let width = rows
            .map { ("  \($0.title)" as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: width + columnGap)]
        // 制表位之后再有内容（超长标题把制表位挤没了）就按固定间隔续排，
        // 至少不会两列糊在一起。
        style.defaultTabInterval = columnGap
        style.lineHeightMultiple = 1.15

        let out = NSMutableAttributedString(
            string: "── \(section) ──\n",
            attributes: [.font: headerFont, .foregroundColor: NSColor.secondaryLabelColor])
        for row in rows {
            out.append(NSAttributedString(
                string: "  \(row.title)\t\(row.shortcut)\n",
                attributes: [.font: font, .foregroundColor: NSColor.labelColor,
                             .paragraphStyle: style]))
        }
        out.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        return out
    }

    // MARK: - 渲染快捷键

    /// 修饰键顺序固定 ⌃⌥⇧⌘（Apple HIG 的书写顺序，与键盘上从外到内一致）。
    /// `spaceName`：空格键的键帽写法，唯一需要翻译的键名（其余都是符号）。
    private static func symbols(for key: String, modifiers: NSEvent.ModifierFlags,
                                spaceName: String) -> String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        // 大写字母做 keyEquivalent 时 AppKit 隐含要求 shift，掩码里却没有它——
        // 只看掩码会漏掉那个 ⇧。
        let implicitShift = key.count == 1 && key.first!.isLetter && key.first!.isUppercase
        if modifiers.contains(.shift) || implicitShift { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + keyName(key, spaceName: spaceName)
    }

    /// 控制字符与功能键没有可读字形，换成系统键帽符号；其余（字母、数字、
    /// [ ] / + - = 这些）原样上大写即可。
    private static func keyName(_ key: String, spaceName: String) -> String {
        switch key {
        // 退格键在 keyEquivalent 里是 U+007F（NSEvent 发的就是 DEL，见 KeymapSpec
        // 那段注释）；U+0008 留着只为容错。⌦ 前向删除是功能键 U+F728。
        case "\u{8}", "\u{7f}": return "⌫"
        case String(Character(UnicodeScalar(UInt32(NSDeleteFunctionKey))!)): return "⌦"
        case "\r": return "↩"
        case "\u{3}": return "⌤"      // 小键盘 Enter
        case "\u{1b}": return "⎋"
        case "\t": return "⇥"
        case " ": return spaceName
        default: break
        }
        // 方向键等功能键住在 Unicode 私用区（NSUpArrowFunctionKey…），
        // 常量是 Int，写不进 switch 的字面量分支，单独比一次。
        if key.unicodeScalars.count == 1, let scalar = key.unicodeScalars.first {
            switch Int(scalar.value) {
            case NSUpArrowFunctionKey: return "↑"
            case NSDownArrowFunctionKey: return "↓"
            case NSLeftArrowFunctionKey: return "←"
            case NSRightArrowFunctionKey: return "→"
            default: break
            }
        }
        return key.uppercased()
    }
}
