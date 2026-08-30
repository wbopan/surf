import AppKit

/// 键位 spec 的解析器：把 `"cmd+shift+]"` 这样一个字符串翻成 `NSMenuItem` 要的
/// `(keyEquivalent, keyEquivalentModifierMask)` 两件套。
///
/// **这个格式是设置项的公开契约**——ns `surf-shortcuts` 里用户亲手打的就是它，
/// 所以这里只认"全小写、`+` 连接"的最朴素形态，不做花式容错：认得越多，
/// 能写出来的形态就越多，两套设置界面与壳三处对格式的理解就越难保持一致。
///
/// 三条硬约定：
///
/// - **空串是合法值 = 禁用**（菜单项还在，只是没有键），不是解析失败；
/// - 解析失败返回 `nil`，由调用方退回默认——配置写错该降级，不该失能；
/// - 字母一律小写。AppKit 表达 ⇧ 组合的正路是"小写字符 + `.shift` 掩码"，
///   写 `"A"` 走的是"大写字符隐含 shift"的另一条路（掩码里查不到那个 ⇧，
///   见 ShortcutsPanel 的 implicitShift）；两条路并存只会让人对不上账。
///
/// 全是静态纯函数：不碰菜单、不碰设置，好读也好在 REPL 里试。
enum KeymapSpec {

    /// 一条键位。`keyEquivalent` 为空串 = 不挂键。
    struct Binding: Equatable {
        let keyEquivalent: String
        let mask: NSEvent.ModifierFlags

        static let disabled = Binding(keyEquivalent: "", mask: [])
    }

    /// 解析一条完整键位（修饰键 + 键）。
    static func parse(_ raw: String) -> Binding? {
        let spec = normalize(raw)
        if spec.isEmpty { return .disabled }
        guard var tokens = split(spec) else { return nil }
        guard let keyToken = tokens.popLast(), let key = keyEquivalent(for: keyToken) else { return nil }
        guard let mask = modifiers(tokens) else { return nil }
        return Binding(keyEquivalent: key, mask: mask)
    }

    /// 只解析修饰键（`sessionDigits` 那种"只给一串修饰键、键由别处决定"的值）。
    /// 空串 = 无修饰键，仍是合法结果。
    static func parseModifiers(_ raw: String) -> NSEvent.ModifierFlags? {
        let spec = normalize(raw)
        if spec.isEmpty { return [] }
        guard let tokens = split(spec) else { return nil }
        return modifiers(tokens)
    }

    // MARK: - 内部

    private static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 按 `+` 切开。**键本身可以就是 `+`**（`cmd++`、光一个 `+`），那时
    /// `components` 会在末尾留下两个空段——它不是错误，是"分隔符 + 加号键"。
    /// 不特判的话用户根本写不出"放大"那类键位。其它位置的空段（`cmd++n`、`+n`、
    /// 末尾光一个 `cmd+`）一律是错。
    private static func split(_ spec: String) -> [String]? {
        var parts = spec.components(separatedBy: "+")
        if parts.count >= 2, parts[parts.count - 1].isEmpty, parts[parts.count - 2].isEmpty {
            parts.removeLast()
            parts[parts.count - 1] = "+"
        }
        guard !parts.contains(where: \.isEmpty) else { return nil }
        return parts
    }

    private static func modifiers(_ tokens: [String]) -> NSEvent.ModifierFlags? {
        var mask: NSEvent.ModifierFlags = []
        for token in tokens {
            switch token {
            case "cmd", "command": mask.insert(.command)
            case "shift": mask.insert(.shift)
            case "alt", "option", "opt": mask.insert(.option)
            case "ctrl", "control": mask.insert(.control)
            default: return nil
            }
        }
        return mask
    }

    /// 键名 → `keyEquivalent` 字符。**这张表就是 spec 里键名的全集**：
    /// 单字符原样收下，多字符只认下面这几个名字（ns schema 的说明文案照它写）。
    private static func keyEquivalent(for token: String) -> String? {
        if token.count == 1 { return token }
        switch token {
        // ⌫ 退格键的 keyEquivalent 必须写 **U+0008（BS）**，尽管它按下去 NSEvent 的
        // `characters` 是 U+007F（DEL）——AppKit 菜单匹配在这里**做了归一化**：
        // keyEq 0x08 ↔ 退格键（keyCode 51，事件字符 0x7F），keyEq 0x7F ↔ **前向删除 ⌦**
        // （keyCode 117，事件字符 NSDeleteFunctionKey U+F728）。IB 里选 ⌫ 存的也是 0x08。
        // 反过来写 0x7F 的话：菜单里键符那格是空白（DEL 不可打印），⌘⇧⌫ 按下去永远
        // 不触发，⌘⇧⌦ 反而会。实测方法见 CLAUDE.md 踩坑记录（用 `CGEvent` 造
        // 真实键码事件再 `NSEvent(cgEvent:)`；手拼 `NSEvent.keyEvent(...)` 会绕过这层
        // 归一化，正是上一版结论出错的原因）。
        case "backspace": return "\u{08}"
        case "delete": return functionKey(NSDeleteFunctionKey)
        case "esc", "escape": return "\u{1b}"
        case "space": return " "
        // 方向键住在 Unicode 私用区，常量是 Int，只能算出来。
        case "left": return functionKey(NSLeftArrowFunctionKey)
        case "right": return functionKey(NSRightArrowFunctionKey)
        case "up": return functionKey(NSUpArrowFunctionKey)
        case "down": return functionKey(NSDownArrowFunctionKey)
        default: return nil
        }
    }

    private static func functionKey(_ code: Int) -> String? {
        guard let scalar = UnicodeScalar(UInt32(code)) else { return nil }
        return String(Character(scalar))
    }
}
