import SurfSDK
import Foundation

/// 桥上那些 `Any` 的一个有类型的家。
///
/// 为什么不直接用 `Any`：设置编辑器满篇都是"这个值和默认值一样吗"、"用户层里有没有
/// 这个键"、"把它原样送回去写"。`Any` 上做这三件事要么写一串 `as?` 阶梯，
/// 要么靠 `NSObject.isEqual` ——后者对 `NSNull`、对 Int/Double 混用会给出意外答案。
///
/// `Hashable` 是给 `Picker` 的 tag 用的（SwiftUI 的选中值必须可哈希）。
///
/// **数字统一成 Double**：JSON 本来就只有一种数字。写回去时按需还原成整数
/// （见 `anyValue`），否则 `timeoutMs: 120000` 会变成 `120000.0` 写进 YAML。
enum JSONValue: Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(_ any: Any) {
        switch any {
        case is NSNull: self = .null
        // **顺序有讲究**：NSNumber 装的 Bool 也能 `as? Double` 成功，所以先问 Bool。
        // 反过来写的话 `true` 会变成 1，开关全部退化成数字输入框。
        case let value as Bool where CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID():
            self = .bool(value)
        case let value as NSNumber where CFGetTypeID(value) == CFBooleanGetTypeID():
            self = .bool(value.boolValue)
        case let value as Double: self = .number(value)
        case let value as Int: self = .number(Double(value))
        case let value as NSNumber: self = .number(value.doubleValue)
        case let value as String: self = .string(value)
        case let value as [Any]: self = .array(value.map(JSONValue.init))
        case let value as [String: Any]:
            self = .object(value.mapValues(JSONValue.init))
        default: self = .null
        }
    }

    /// 送回桥上的形状。
    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value):
            // 整数值还原成 Int：JSON 那头 120000 和 120000.0 是同一个数，
            // 但写进 settings.yaml 是两个样子，用户会看见。
            return value == value.rounded() && abs(value) < 9.007e15 ? Int(value) : value
        case .string(let value): return value
        case .array(let items): return items.map(\.anyValue)
        case .object(let fields): return fields.mapValues(\.anyValue)
        }
    }

    /// 按路径取子值。任何一段走不通都给 nil——"没有"和"是 null"是两回事，
    /// 而"用户层里有没有这个键"正是覆盖判据（计划 §4.1）。
    func value(at path: [String]) -> JSONValue? {
        var node: JSONValue = self
        for key in path {
            guard case .object(let fields) = node, let next = fields[key] else { return nil }
            node = next
        }
        return node
    }

    /// 单行摘要，给只读展示与折叠标题用。**「重置为 X」也复用它**。
    ///
    /// 是函数而不是属性，因为它要出文案（`开` / `On`）：值本身没有语言，
    /// 描述它的那几个词有。数字与非空字符串照原样，那两种是数据。
    func summary(_ locale: SurfLocale) -> String {
        let strings = L(locale)
        switch self {
        // 「没有值」。破折号不是文案，两种语言同一个字形。
        case .null: return "—"
        case .bool(let value): return value ? strings.on : strings.off
        case .number(let value): return SettingsFormat.number(value)
        case .string(let value): return value.isEmpty ? strings.emptyString : value
        case .array(let items): return strings.itemCount(items.count)
        case .object(let fields): return strings.fieldCount(fields.count)
        }
    }

    /// 多行 JSON，给 `.unknown` 节点的只读显示用。
    func prettyJSON(_ locale: SurfLocale) -> String {
        let object = anyValue
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return summary(locale)
        }
        return text
    }

    var stringValue: String? { if case .string(let value) = self { return value }; return nil }
    var numberValue: Double? { if case .number(let value) = self { return value }; return nil }
    var boolValue: Bool? { if case .bool(let value) = self { return value }; return nil }
    var isNull: Bool { self == .null }
}

/// 格式化的小工具，散在各处会飘。
enum SettingsFormat {
    /// 数字：整数不带小数点，小数最多六位且不留尾随零。
    static func number(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 9.007e15 { return String(Int(value)) }
        return String(format: "%g", value)
    }

    /// 字段 key 的机械美化：`maxOutputBytes` → `Max Output Bytes`。
    ///
    /// **这是零注解时的默认标签**（计划 §2.2）。它不好看，但它诚实：
    /// 认不出来的字段显示成这样，总比不显示强，也比编一个中文名强。
    static func humanize(_ key: String) -> String {
        var words: [String] = []
        var current = ""
        for character in key {
            if character == "_" || character == "-" || character == "." {
                if !current.isEmpty { words.append(current); current = "" }
            } else if character.isUppercase && !current.isEmpty && !(current.last?.isUppercase ?? false) {
                words.append(current)
                current = String(character)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
