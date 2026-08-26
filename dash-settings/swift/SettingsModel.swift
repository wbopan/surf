import Combine
import DashSDK
import Foundation

/// 一个 ns 的快照：schema、三层取值、乐观锁读数。
struct NamespaceSnapshot: Identifiable {
    let ns: String
    let schema: SchemaNode
    /// 解析后的值（schema 默认 ← base ← user）。
    let value: JSONValue
    /// 编排层。有它才能说清"重置会退回到什么"。
    let base: JSONValue?
    /// **原始用户段**。某个键在不在这里就是"用户是否覆盖"的判据
    /// ——不是"值不等于默认"（等于默认的覆盖仍然是覆盖，计划 §4.1）。
    let user: JSONValue?
    let revision: Int
    /// `live` / `restart`。restart 的要标出来，否则用户以为没写进去。
    let applies: String
    /// schema 声明的 secret 位置 + 当前配没配。值永远不过桥。
    let secrets: [SecretSlot]

    var id: String { ns }

    /// 这个路径的值有没有被用户覆盖。
    func isOverridden(path: [String]) -> Bool {
        user?.value(at: path) != nil
    }

    /// 重置后会退回到的值：base 层有就是 base，否则 schema 默认。
    func inheritedValue(path: [String], node: SchemaNode) -> JSONValue? {
        base?.value(at: path) ?? node.meta.default
    }

    func secretSlot(path: [String]) -> SecretSlot? {
        secrets.first { $0.path == path }
    }
}

/// 一个被 redact 掉的 secret 位置。
struct SecretSlot {
    let path: [String]
    /// 当前有没有值。**这是 Swift 侧能知道的全部**——值永不下发。
    let isSet: Bool
}

/// 一条 provider 记录（模型页）。
struct ProviderRow: Identifiable {
    let provider: String
    let displayName: String
    let settingsNs: String
    let settingsPath: [String]
    /// 适配器不做"自带/用户加的"区分时为 nil。
    let declared: Bool?
    /// 路由活着 = 配置完整到 llm 愿意注册它。**上游没有启停开关**，
    /// live 是配置的结果而不是一个可写字段。
    let live: Bool
    let keyRef: String
    /// keyRef 是配置里存着的，还是我们按 web 的约定猜的。
    let keyRefStored: Bool
    let credentialConfigured: Bool?
    let credentialWritable: Bool
    let credentialSource: String?

    var id: String { provider }
}

/// 一个字段当前的写入状态。失败时**保留用户输入**并显示原因，不清空重来
/// （计划 §4.3）。
struct FieldStatus {
    var saving = false
    var error: String?
    /// 用户敲了但还没提交成功的文本。提交成功后清掉，回读的值接管显示。
    var draft: String?
}

/// 设置窗口的领域态。
///
/// **真相在 dsh 那边**：这里存的一切都是快照的投影，写入一律经桥、写完等 host
/// 重推（计划 §4.2 "不预测结果"）。所以这个类里没有任何一处直接改 `namespaces`
/// 里的值——改的只有 `status`（谁在转圈、谁报了错）。
@MainActor
final class SettingsModel: ObservableObject {

    @Published private(set) var namespaces: [NamespaceSnapshot] = []
    @Published private(set) var providers: [ProviderRow] = []
    /// 文档可写吗。false = 整页禁用并说明原因（计划 §4.5）。
    @Published private(set) var writable = true
    /// 有没有可打开的配置文件。非文件型 provider 没有——那就别给按钮。
    @Published private(set) var hasDocument = false
    /// `llm` 在不在场。不在 = 模型页整个不出现。
    @Published private(set) var modelsAvailable = false
    /// 首帧到了没有。没到就显示"连接中"，而不是显示一个空列表说"没有设置"。
    @Published private(set) var loaded = false
    /// 每个字段（ns + 路径）的写入状态。
    @Published private(set) var status: [FieldKey: FieldStatus] = [:]
    /// 整窗级别的提示条（冲突、写失败等）。
    @Published var notice: String?

    /// 字段的身份：ns + 路径。
    struct FieldKey: Hashable {
        let ns: String
        let path: [String]
    }

    private let bridge: SettingsBridge
    private let log: (String) -> Void

    init(bridge: SettingsBridge, log: @escaping (String) -> Void) {
        self.bridge = bridge
        self.log = log
    }

    func namespace(_ ns: String) -> NamespaceSnapshot? {
        namespaces.first { $0.ns == ns }
    }

    // MARK: - 收快照

    func apply(channel: String, payload: [String: Any]) {
        switch channel {
        case "settings": applySettings(payload)
        case "providers": applyProviders(payload)
        case "ack": bridge.handleAck(payload)
        default: log("不认识的频道：\(channel)")
        }
    }

    private func applySettings(_ payload: [String: Any]) {
        let raw = payload["namespaces"] as? [[String: Any]] ?? []
        namespaces = raw.compactMap { item in
            guard let ns = item["ns"] as? String else { return nil }
            let envelope = item["schema"] as? [String: Any] ?? [:]
            let secrets = (item["secrets"] as? [[String: Any]] ?? []).map {
                SecretSlot(path: $0["path"] as? [String] ?? [], isSet: $0["set"] as? Bool ?? false)
            }
            return NamespaceSnapshot(
                ns: ns,
                schema: SchemaNode.decode(envelope: envelope),
                value: JSONValue(item["value"] ?? NSNull()),
                base: item["base"].map { JSONValue($0) }?.nonNull,
                user: item["user"].map { JSONValue($0) }?.nonNull,
                revision: item["revision"] as? Int ?? 0,
                applies: item["applies"] as? String ?? "live",
                secrets: secrets)
        }
        writable = payload["writable"] as? Bool ?? true
        hasDocument = payload["hasDocument"] as? Bool ?? false
        // 只在首帧与"ns 数量变了"时说一句：设置一改就推一次，每次都记等于刷屏。
        // 但"到底连上没有、解出几个 ns"是查问题时第一个要问的，所以这行得留着。
        if !loaded || namespaces.count != lastLoggedCount {
            lastLoggedCount = namespaces.count
            let fields = namespaces.reduce(0) { sum, item in
                if case .object(let list, _) = item.schema { return sum + list.count }
                return sum
            }
            log("收到快照：\(namespaces.count) 个命名空间 / \(fields) 个字段"
                + "，可写=\(writable) 有文档=\(hasDocument)")
        }
        loaded = true
    }

    private var lastLoggedCount = -1

    private func applyProviders(_ payload: [String: Any]) {
        modelsAvailable = payload["available"] as? Bool ?? false
        let raw = payload["providers"] as? [[String: Any]] ?? []
        providers = raw.compactMap { item in
            guard let provider = item["provider"] as? String else { return nil }
            let credential = item["credential"] as? [String: Any]
            return ProviderRow(
                provider: provider,
                displayName: item["displayName"] as? String ?? provider,
                settingsNs: item["settingsNs"] as? String ?? "",
                settingsPath: item["settingsPath"] as? [String] ?? [],
                declared: item["declared"] as? Bool,
                live: item["live"] as? Bool ?? false,
                keyRef: item["keyRef"] as? String ?? "",
                keyRefStored: item["keyRefStored"] as? Bool ?? false,
                credentialConfigured: credential?["configured"] as? Bool,
                credentialWritable: credential?["writable"] as? Bool ?? false,
                credentialSource: credential?["source"] as? String)
        }
    }

    // MARK: - 写入

    func status(_ ns: String, _ path: [String]) -> FieldStatus {
        status[FieldKey(ns: ns, path: path)] ?? FieldStatus()
    }

    /// 本地就能判定的错（比如数字框里敲了字母）。不往返一趟，输入照样留着。
    func setLocalError(_ ns: String, _ path: [String], _ message: String) {
        var current = status(ns, path)
        current.saving = false
        current.error = message
        status[FieldKey(ns: ns, path: path)] = current
    }

    func setDraft(_ ns: String, _ path: [String], _ text: String?) {
        var current = status(ns, path)
        current.draft = text
        status[FieldKey(ns: ns, path: path)] = current
    }

    /// 写一个字段。
    ///
    /// **即时生效**（计划 D1）：开关/下拉一动就走这儿，文本框失焦或 ⏎ 走这儿。
    /// 代价是每个控件都要能回滚——所以失败时 draft 留着、错误挂在字段上，
    /// 而不是弹一个模态框然后把输入清掉。
    func set(ns: String, path: [String], value: JSONValue) {
        write(ns: ns, path: path, action: "set", extra: ["value": value.anyValue])
    }

    /// 退回继承。
    func unset(ns: String, path: [String]) {
        write(ns: ns, path: path, action: "unset", extra: [:])
    }

    private func write(ns: String, path: [String], action: String, extra: [String: Any]) {
        guard writable else {
            notice = "配置文档只读，改不动"
            return
        }
        let key = FieldKey(ns: ns, path: path)
        var current = status[key] ?? FieldStatus()
        current.saving = true
        current.error = nil
        status[key] = current

        var payload: [String: Any] = ["ns": ns, "path": path]
        // 乐观锁：带上读到这份快照时的 revision，host 那边发现自己走远了就拒绝
        // 而不是覆盖（计划 §4.6）。
        if let revision = namespace(ns)?.revision { payload["expectedRevision"] = revision }
        payload.merge(extra) { _, new in new }

        bridge.invoke(action, payload) { [weak self] ack in
            guard let self else { return }
            var next = self.status[key] ?? FieldStatus()
            next.saving = false
            if ack.ok {
                next.error = nil
                // 成功了才丢掉 draft：让回读的值接管显示。
                next.draft = nil
            } else {
                next.error = ack.error ?? "写入失败"
                if ack.code == "SETTINGS_CONFLICT" {
                    self.notice = "设置在别处被改过，已重新读取——请确认后再改一次"
                }
            }
            self.status[key] = next
        }
    }

    // MARK: - 凭据

    func setCredential(ref: String, value: String, completion: @escaping (String?) -> Void) {
        bridge.invoke("setCredential", ["ref": ref, "value": value]) { ack in
            completion(ack.ok ? nil : (ack.error ?? "写入失败"))
        }
    }

    func unsetCredential(ref: String, completion: @escaping (String?) -> Void) {
        bridge.invoke("unsetCredential", ["ref": ref]) { ack in
            completion(ack.ok ? nil : (ack.error ?? "清除失败"))
        }
    }

    // MARK: - 杂项

    func refresh() {
        bridge.fire("refresh")
    }

    /// 打开配置文件。路径由 dsh 那边给（`prepareDocument` 会先把文件落地），
    /// **由壳来 open**——只有 `NSWorkspace` 认用户的默认编辑器。
    func openDocument(_ open: @escaping (String) -> Void) {
        bridge.invoke("documentPath") { [weak self] ack in
            guard let path = ack.value?.stringValue, !path.isEmpty else {
                self?.notice = ack.error ?? "这个配置源没有可打开的文件"
                return
            }
            open(path)
        }
    }
}

private extension JSONValue {
    /// `null` 当"没有"看：node 半边把缺席的 base/user 写成 null 过桥。
    var nonNull: JSONValue? { isNull ? nil : self }
}
