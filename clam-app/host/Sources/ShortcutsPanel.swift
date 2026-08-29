import AppKit

/// ⌘/ 打开的「键盘快捷键」面板。
///
/// 内容**不是手写清单，而是现场遍历 `NSApp.mainMenu`** ——手写清单必然与菜单
/// 漂移（加一项忘了补一行，删一项忘了删）。代价是它只认菜单里的东西：
/// 页面自己处理的按键（Esc 停止生成）遍历不到，末尾单列一节补上。
///
/// 隐藏项也要收：⌘1…⌘9 与 ⌘= 都是 `isHidden` 的（菜单里九行"会话 N"没信息量），
/// 但它们恰恰是最需要有个地方能查到的那批快捷键。
@MainActor
final class ShortcutsPanel: NSWindowController {
    private let textView = NSTextView()

    convenience init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "键盘快捷键"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        self.init(window: panel)
        buildContent(in: panel)
    }

    private func buildContent(in panel: NSPanel) {
        textView.isEditable = false
        textView.isSelectable = true
        // 等宽字体：快捷键那一列靠空格对齐，比例字体下会散架。
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.autoresizingMask = [.width]

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let copy = NSButton(title: "拷贝", target: self, action: #selector(copyAll))
        copy.bezelStyle = .rounded
        copy.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(copy)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            copy.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            copy.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            copy.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        panel.contentView = content
    }

    /// 每次打开都重新遍历一次：菜单不是常量（插件换代、用户改配置都可能动它），
    /// 缓存一份就是在准备一张过期的表。
    /// `stopSpec`：页面侧「停止生成」的当前键位（`Keymap.stopSpec`），空串 = 已禁用。
    func present(stopSpec: String) {
        textView.string = Self.renderAll(stopSpec: stopSpec)
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
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

    private static func renderAll(stopSpec: String) -> String {
        var blocks: [String] = []
        for top in NSApp.mainMenu?.items ?? [] {
            guard let submenu = top.submenu else { continue }
            var rows: [Row] = []
            collect(from: submenu, into: &rows)
            guard !rows.isEmpty else { continue }
            blocks.append(render(section: top.title, rows: rows))
        }
        // 页面自己吃掉的按键：不在任何 NSMenu 里，遍历拿不到。键位跟着设置走
        // （`Keymap.stopSpec` 由调用方递进来），不再手写死值——手写的那版在
        // stopGenerating 变成可配置项之后就会与设置漂移。
        // 这一节每加一条都意味着"页面侧实现了一个壳不知道的快捷键"。
        let stopShortcut: String
        if stopSpec.isEmpty {
            stopShortcut = "已禁用"
        } else if let binding = KeymapSpec.parse(stopSpec) {
            stopShortcut = symbols(for: binding.keyEquivalent, modifiers: binding.mask)
        } else {
            stopShortcut = stopSpec // 解析不动就原样展示，至少不骗人
        }
        blocks.append(render(section: "页面内", rows: [
            Row(title: "停止正在生成的回复", shortcut: stopShortcut),
        ]))
        return blocks.joined(separator: "\n")
    }

    /// 深度优先收一棵菜单树。同一节里**按标题去重**：⌘= 那种别名项与正主同名，
    /// 列两遍只会让人以为有两个功能（隐藏别名的存在是实现细节，不是知识点）。
    private static func collect(from menu: NSMenu, into rows: inout [Row]) {
        for item in menu.items {
            if let submenu = item.submenu {
                collect(from: submenu, into: &rows)
                continue
            }
            guard !item.isSeparatorItem, !item.keyEquivalent.isEmpty else { continue }
            guard !rows.contains(where: { $0.title == item.title }) else { continue }
            rows.append(Row(title: item.title,
                            shortcut: symbols(for: item.keyEquivalent,
                                              modifiers: item.keyEquivalentModifierMask)))
        }
    }

    private static func render(section: String, rows: [Row]) -> String {
        // 快捷键列左对齐到同一列：标题列宽取本节最长者，避免整个面板迁就
        // 某一节的长标题（"下一个待处理会话" 比 "放大" 长得多）。
        let width = rows.map { displayWidth($0.title) }.max() ?? 0
        var lines = ["── \(section) ──"]
        for row in rows {
            let pad = String(repeating: " ", count: max(0, width - displayWidth(row.title)) + 3)
            lines.append("  \(row.title)\(pad)\(row.shortcut)")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// 等宽字体下 CJK 占两格、ASCII 占一格。按 `count` 补空格会让中文标题那几行
    /// 短一截，对齐就废了。范围逐条列出而不是"≥ U+1100 就算两格"——省事的那种写法
    /// 会把 `…`（U+2026，"重命名会话…"里就有）也算成两格，反而把行拉歪。
    private static func displayWidth(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { acc, scalar in
            acc + (isWide(scalar) ? 2 : 1)
        }
    }

    private static func isWide(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F,   // 韩文字母
             0x2E80...0xA4CF,   // 部首 / 假名 / CJK 统一表意
             0xAC00...0xD7A3,   // 韩文音节
             0xF900...0xFAFF,   // 兼容表意
             0xFE30...0xFE6F,   // 竖排标点 / 小写变体
             0xFF00...0xFF60,   // 全角
             0xFFE0...0xFFE6,
             0x20000...0x3FFFD: // 扩展表意
            return true
        default:
            return false
        }
    }

    // MARK: - 渲染快捷键

    /// 修饰键顺序固定 ⌃⌥⇧⌘（Apple HIG 的书写顺序，与键盘上从外到内一致）。
    private static func symbols(for key: String, modifiers: NSEvent.ModifierFlags) -> String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        // 大写字母做 keyEquivalent 时 AppKit 隐含要求 shift，掩码里却没有它——
        // 只看掩码会漏掉那个 ⇧。
        let implicitShift = key.count == 1 && key.first!.isLetter && key.first!.isUppercase
        if modifiers.contains(.shift) || implicitShift { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + keyName(key)
    }

    /// 控制字符与功能键没有可读字形，换成系统键帽符号；其余（字母、数字、
    /// [ ] / + - = 这些）原样上大写即可。
    private static func keyName(_ key: String) -> String {
        switch key {
        // 退格键在 keyEquivalent 里是 U+007F（NSEvent 发的就是 DEL，见 KeymapSpec
        // 那段注释）；U+0008 留着只为容错。⌦ 前向删除是功能键 U+F728。
        case "\u{8}", "\u{7f}": return "⌫"
        case String(Character(UnicodeScalar(UInt32(NSDeleteFunctionKey))!)): return "⌦"
        case "\r": return "↩"
        case "\u{3}": return "⌤"      // 小键盘 Enter
        case "\u{1b}": return "⎋"
        case "\t": return "⇥"
        case " ": return "空格"
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
