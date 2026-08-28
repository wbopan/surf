import ClamSDK
import Foundation

/// 本插件与自己 TS 半身之间的请求/响应层。
///
/// **桥本身是单向的**：`ClamBridge.send` 只管发，`invoke` 的返回值在 clam-bridge
/// 那边被丢弃。所以每条动作自带一个 `id`，TS 半身把结果经 `ack` 频道推回来，
/// 这里按 id 找到等着的那个回调。
///
/// 超时是必须的，不是防御性编程：桥断开时 `send` **静默丢弃**（不排队不报错），
/// 没有超时的话界面会永远显示"保存中…"。
@MainActor
final class SettingsBridge {

    /// 一次 invoke 的结果。`value` 只有 `documentPath` 用得上。
    struct Ack {
        let ok: Bool
        let error: String?
        let code: String?
        let value: JSONValue?
    }

    private let bridge: ClamBridge
    private let log: (String) -> Void
    private var pending: [String: (Ack) -> Void] = [:]
    private var counter = 0

    /// 等多久算丢了。设置的写入都是本机 loopback，正常在毫秒级；8 秒还没回来
    /// 就是桥断了或者 dsh 卡住了，两种情况都该告诉用户而不是继续转圈。
    private let timeout: TimeInterval = 8

    init(bridge: ClamBridge, log: @escaping (String) -> Void) {
        self.bridge = bridge
        self.log = log
    }

    /// 收到 `ack` 频道的推送时调用。
    func handleAck(_ payload: [String: Any]) {
        guard let id = payload["id"] as? String, let callback = pending.removeValue(forKey: id) else { return }
        callback(Ack(ok: payload["ok"] as? Bool ?? false,
                     error: payload["error"] as? String,
                     code: payload["code"] as? String,
                     value: payload["value"].map { JSONValue($0) }))
    }

    /// 发一个动作，等回执。
    func invoke(_ action: String,
                _ payload: [String: Any] = [:],
                completion: @escaping (Ack) -> Void) {
        counter += 1
        let id = "\(counter)"
        pending[id] = completion
        var body = payload
        body["id"] = id
        bridge.send(action: action, payload: body)

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.timeout ?? 8))
            guard let self, let callback = self.pending.removeValue(forKey: id) else { return }
            self.log("动作 \(action) 超时（桥断了？）")
            callback(Ack(ok: false, error: "没有响应，dsh 可能断开了", code: "TIMEOUT", value: nil))
        }
    }

    /// 发一个动作，不关心结果（目前只有 `refresh` 这么用）。
    func fire(_ action: String, _ payload: [String: Any] = [:]) {
        invoke(action, payload) { _ in }
    }
}
