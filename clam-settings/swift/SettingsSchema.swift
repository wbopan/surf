import ClamSDK
import Foundation

/// schemastery 的序列化壳子解成一棵 Swift 树。
///
/// 线上形状是 `{uid, refs: {id: node}}` —— 一张**图**（同一个子 schema 可以被多处
/// 引用），根是 `uid`。这里在解码时把它展成树：设置界面要的是"这个字段长什么样"，
/// 共享节点被复制两份没有任何坏处，而按 id 解引用会让每个渲染点都得带着 refs 走。
///
/// **深度上限是防环不是防深**：schemastery 允许递归 schema（A 的字段里有 A），
/// 图上完全合法，展成树就是无穷。上限一到就退化成 `.unknown`，界面显示成只读文本
/// ——比栈溢出好。
/// `indirect`：`array`/`dict` 的 `inner` 是直接自引用，不加就是无限大小
/// （编译器的原话是 "value type 'NamespaceSnapshot' has infinite size"，
/// 报在持有它的那个 struct 上而不是这里，别被指错的行号带偏）。
indirect enum SchemaNode {
    case const(value: JSONValue, meta: SchemaMeta)
    case number(meta: SchemaMeta)
    case string(meta: SchemaMeta)
    case boolean(meta: SchemaMeta)
    /// 固定字段的对象。`fields` 保持**声明序**（node 半边摊平时保住的，见那边注释）。
    case object(fields: [SchemaField], meta: SchemaMeta)
    /// 若干候选之一。全是 `const` 时就是个下拉框，否则退化成基础控件。
    case union(options: [SchemaNode], meta: SchemaMeta)
    case array(inner: SchemaNode, meta: SchemaMeta)
    case dict(inner: SchemaNode, meta: SchemaMeta)
    /// 认不出来的类型、超深的递归、坏掉的引用。**不隐藏**：显示成只读 JSON，
    /// 让用户至少知道这里有个字段、值是什么，并且能去配置文件里改。
    case unknown(type: String, meta: SchemaMeta)

    var meta: SchemaMeta {
        switch self {
        case .const(_, let m), .number(let m), .string(let m), .boolean(let m),
             .object(_, let m), .union(_, let m), .array(_, let m), .dict(_, let m),
             .unknown(_, let m):
            return m
        }
    }

    /// 顺路径往下走。
    ///
    /// 用在 provider 详情上：一个 ns 可以被好几个 provider 共用
    /// （实测 `llm-pi-ai` 底下挂着 kimi-coding / zai-coding-cn / deepseek 三个），
    /// 各自的配置在 `settingsPath` 指的子树里。**不走这一步就会把整个 ns
    /// 原样渲染给每一个 provider**——三个 provider 看到同样的内容，
    /// 而且互相能改到对方的配置。
    func node(at path: [String]) -> SchemaNode? {
        var current = self
        for key in path {
            switch current {
            case .object(let fields, _):
                guard let field = fields.first(where: { $0.key == key }) else { return nil }
                current = field.node
            // dict 的键是用户定的（provider 名就是键），schema 只描述值的形状。
            case .dict(let inner, _), .array(let inner, _):
                current = inner
            default:
                return nil
            }
        }
        return current
    }

    /// union 的候选全是 const 时，取出它们的值——这是"下拉框"的判据。
    var constOptions: [JSONValue]? {
        guard case .union(let options, _) = self else { return nil }
        var values: [JSONValue] = []
        for option in options {
            guard case .const(let value, _) = option else { return nil }
            values.append(value)
        }
        return values.isEmpty ? nil : values
    }
}

/// 对象的一个字段。
struct SchemaField {
    let key: String
    let node: SchemaNode
}

/// 节点的 meta。**全集就这六个**——上游复核过，没有描述文本，也没有
/// "这个字段该不该给人看"（计划 §2.1）。所以文案与精选只能来自 `FieldNotes`。
struct SchemaMeta {
    var required = false
    var `default`: JSONValue?
    var role: String?
    var min: Double?
    var max: Double?
    var step: Double?

    /// role 全集六种：slider / datetime / credential-ref / secret / table / ms。
    /// **认不出来的一律当没有**——上游随时可能加新 role，退化成基础控件永远安全。
    var isSecret: Bool { role == "secret" }
}

// MARK: - 解码

extension SchemaNode {
    /// 最大展开深度。设置 schema 实测最深 4 层（provider profile 里的 models 数组），
    /// 16 是留足余量后仍能挡住环的数。
    private static let maxDepth = 16

    /// 从线上壳子解出根节点。任何一步不认得就给 `.unknown`，不抛。
    static func decode(envelope: [String: Any]) -> SchemaNode {
        guard let refs = envelope["refs"] as? [String: Any] else {
            return .unknown(type: "no-refs", meta: SchemaMeta())
        }
        let uid = envelope["uid"]
        return decode(ref: uid, refs: refs, depth: 0)
    }

    private static func decode(ref: Any?, refs: [String: Any], depth: Int) -> SchemaNode {
        guard depth < maxDepth else { return .unknown(type: "too-deep", meta: SchemaMeta()) }
        // ref 在 JSON 里是数字，键是字符串——两头都归一成字符串再查。
        let key: String
        switch ref {
        case let n as Int: key = String(n)
        case let n as Double: key = String(Int(n))
        case let s as String: key = s
        default: return .unknown(type: "bad-ref", meta: SchemaMeta())
        }
        guard let node = refs[key] as? [String: Any] else {
            return .unknown(type: "missing-ref", meta: SchemaMeta())
        }

        let meta = SchemaMeta(raw: node["meta"] as? [String: Any] ?? [:])
        let type = node["type"] as? String ?? "?"

        switch type {
        case "const":
            return .const(value: JSONValue(node["value"] ?? NSNull()), meta: meta)
        case "number", "natural", "percent":
            // natural / percent 是 number 的特化（min/step 已经写进 meta），
            // 按 number 渲染即可。
            return .number(meta: meta)
        case "string":
            return .string(meta: meta)
        case "boolean":
            return .boolean(meta: meta)
        case "object":
            let raw = node["fields"] as? [[String: Any]] ?? []
            let fields = raw.compactMap { item -> SchemaField? in
                guard let key = item["key"] as? String else { return nil }
                return SchemaField(key: key, node: decode(ref: item["ref"], refs: refs, depth: depth + 1))
            }
            return .object(fields: fields, meta: meta)
        case "union", "intersect":
            let list = node["list"] as? [Any] ?? []
            return .union(options: list.map { decode(ref: $0, refs: refs, depth: depth + 1) }, meta: meta)
        case "array", "tuple":
            return .array(inner: decode(ref: node["inner"], refs: refs, depth: depth + 1), meta: meta)
        case "dict":
            return .dict(inner: decode(ref: node["inner"], refs: refs, depth: depth + 1), meta: meta)
        default:
            return .unknown(type: type, meta: meta)
        }
    }
}

extension SchemaMeta {
    init(raw: [String: Any]) {
        self.required = raw["required"] as? Bool ?? false
        self.default = raw["default"].map { JSONValue($0) }
        self.role = raw["role"] as? String
        self.min = raw["min"] as? Double ?? (raw["min"] as? Int).map(Double.init)
        self.max = raw["max"] as? Double ?? (raw["max"] as? Int).map(Double.init)
        self.step = raw["step"] as? Double ?? (raw["step"] as? Int).map(Double.init)
    }

    /// 约束的人话，进字段那一行的悬停提示。没有约束就返回 nil（别显示一行空的）。
    ///
    /// `≥` / `≤` 是符号不是文案，两种语言同一个写法；只有「步长」需要翻。
    func constraintText(_ locale: ClamLocale) -> String? {
        var parts: [String] = []
        if let min { parts.append("≥ \(SettingsFormat.number(min))") }
        if let max { parts.append("≤ \(SettingsFormat.number(max))") }
        if let step, step != 1 { parts.append(L(locale).step(SettingsFormat.number(step))) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
