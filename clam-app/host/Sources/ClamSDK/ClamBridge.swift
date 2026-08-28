import Foundation

/// 插件与**它自己的 TS 半身**之间的信封通道。
///
/// 插件永不直接摸 WebSocket：帧的收发、重连、路由都归壳的 BridgeClient，
/// 这里只有两个动作——把动作发上去、把推下来的数据接住。
/// 载荷同 `ClamEventBus`：只放 JSON 能表达的值。
///
/// 桥断开时 `send` 静默丢弃（不排队、不报错）：真相在 dsh 侧，
/// 补发一个过期动作比丢掉它更糟。
public final class ClamBridge {
    private let sender: (String, [String: Any]) -> Void
    private var handlers: [UUID: (String, [String: Any]) -> Void] = [:]

    /// 壳构造，插件只使用。
    public init(send: @escaping (String, [String: Any]) -> Void) {
        self.sender = send
    }

    /// 触发 TS 半身 `expose` 的一个动作（桥协议的 `invoke` 帧）。
    public func send(action: String, payload: [String: Any] = [:]) {
        sender(action, payload)
    }

    /// 订阅 TS 半身 `subscribe` 推下来的数据（桥协议的 `push` 帧）。
    @discardableResult
    public func onMessage(_ handler: @escaping (_ channel: String,
                                                _ payload: [String: Any]) -> Void) -> ClamDisposable {
        let token = UUID()
        handlers[token] = handler
        return ClamDisposable { [weak self] in
            self?.handlers.removeValue(forKey: token)
        }
    }

    /// 壳收到本插件的 `push` 帧后调用。
    public func deliver(channel: String, payload: [String: Any]) {
        for handler in handlers.values { handler(channel, payload) }
    }
}
