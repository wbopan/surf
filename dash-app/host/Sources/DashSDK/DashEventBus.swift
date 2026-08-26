import Foundation

/// 进程内事件总线：壳与插件之间、插件与插件之间的松耦合广播。
///
/// 载荷是 `[String: Any]`，**约定只放 JSON 能表达的值**
/// （String / Int / Double / Bool / 数组 / 字典）。放引用类型就等于让引用过桥，
/// 换代后另一头拿到的会是一个新 module 认不出来的旧类型。
///
/// 订阅句柄绑插件世代（攒进 `DashPluginHandle`），旧代退休时一并吊销，
/// 防幽灵监听。线程约定：只在主线程 emit/subscribe。
public final class DashEventBus {
    private var handlers: [String: [UUID: ([String: Any]) -> Void]] = [:]

    public init() {}

    @discardableResult
    public func subscribe(_ topic: String,
                          _ handler: @escaping ([String: Any]) -> Void) -> DashDisposable {
        let token = UUID()
        handlers[topic, default: [:]][token] = handler
        return DashDisposable { [weak self] in
            self?.handlers[topic]?.removeValue(forKey: token)
        }
    }

    public func emit(_ topic: String, _ payload: [String: Any] = [:]) {
        // 先快照再分发：监听器内部再订阅/退订不会打乱本轮。
        for handler in (handlers[topic] ?? [:]).values {
            handler(payload)
        }
    }

    /// 壳与插件共用的主题名。
    public enum Topic {
        /// 壳完成一次 dsh 接入或换端点。载荷 `["httpBase": String]`。
        public static let endpointChanged = "dash.endpointChanged"
        /// 请求把窗口带到前台。载荷可带 `["sessionId": String]`。
        public static let activateWindow = "dash.activateWindow"
        /// 页内桥消息的主题前缀。**壳对页内消息不设白名单**：
        /// `window.webkit.messageHandlers.dash.postMessage({type, ...})` 里的
        /// 任意 `type` 都会原样广播成 `dash.page.<type>`，载荷就是那个字典本身。
        /// 想接一条新页内消息的插件订阅 `pagePrefix + "yourType"` 即可，
        /// 不必改壳。动态主题不逐个加常量——只有壳自己也要 emit 的那几条
        /// （下面两个）才配常量。
        public static let pagePrefix = "dash.page."
        /// 页内桥上报当前会话。载荷 `["id": String]`。
        public static let pageCurrentSession = pagePrefix + "currentSession"
        /// 页内桥就绪。载荷 `["capabilities": [String]]`。
        public static let pageReady = pagePrefix + "ready"
        /// 壳的菜单/快捷键触发了一个命令。载荷 `["command": String]`。
        /// 壳只负责喊，具体做什么归拥有相应能力的插件（如 layout 拥有会话展示面）。
        public static let menuCommand = "dash.menu.command"
    }
}
