import Foundation

/// 进程内事件总线：壳与插件之间、插件与插件之间的松耦合广播。
///
/// 载荷是 `[String: Any]`，**约定只放 JSON 能表达的值**
/// （String / Int / Double / Bool / 数组 / 字典）。放引用类型就等于让引用过桥，
/// 换代后另一头拿到的会是一个新 module 认不出来的旧类型。
///
/// 订阅句柄绑插件世代（攒进 `ClamPluginHandle`），旧代退休时一并吊销，
/// 防幽灵监听。线程约定：只在主线程 emit/subscribe。
public final class ClamEventBus {
    private var handlers: [String: [UUID: ([String: Any]) -> Void]] = [:]
    /// 粘性主题的最后一次载荷（见 `emitSticky`）。
    private var sticky: [String: [String: Any]] = [:]

    public init() {}

    /// 订阅一个主题。**主题是粘性的话，这里会同步回调一次最后那份载荷。**
    @discardableResult
    public func subscribe(_ topic: String,
                          _ handler: @escaping ([String: Any]) -> Void) -> ClamDisposable {
        let token = UUID()
        handlers[topic, default: [:]][token] = handler
        if let last = sticky[topic] { handler(last) }
        return ClamDisposable { [weak self] in
            self?.handlers[topic]?.removeValue(forKey: token)
        }
    }

    public func emit(_ topic: String, _ payload: [String: Any] = [:]) {
        // 先快照再分发：监听器内部再订阅/退订不会打乱本轮。
        for handler in (handlers[topic] ?? [:]).values {
            handler(payload)
        }
    }

    /// 广播，**并记住这一份**：此后每个新订阅者一订上就先收到它。
    ///
    /// 为什么需要这个：插件是运行时编译装载的，**它必然晚于壳的启动，也可能晚于
    /// 页面第一次报告状态**。纯广播的语义下，晚到的订阅者对"当前是什么状态"
    /// 一无所知，而且要等到下一次变化才知道——如果那个状态恰好不再变（用户
    /// 打开 app 之后就一直待在同一个会话里），它就永远不知道。这不是某一条消息的
    /// 毛病，是"广播 + 晚到的订阅者"这个组合的固有缺口。
    ///
    /// 判据与 registry / contributions 一致：**总线本身不认识任何具体主题**，
    /// 粘不粘由 emit 的一方按那条消息的语义决定——描述**状态**的（当前会话、
    /// 当前端点）该粘，描述**瞬间**的（菜单被按了一下）不该粘。
    public func emitSticky(_ topic: String, _ payload: [String: Any] = [:]) {
        sticky[topic] = payload
        emit(topic, payload)
    }

    /// 某个粘性主题的最后一份载荷（没有就是 nil）。想主动问一次而不订阅时用。
    public func last(_ topic: String) -> [String: Any]? { sticky[topic] }

    /// 壳与插件共用的主题名。
    public enum Topic {
        /// 壳完成一次 dsh 接入或换端点。载荷 `["httpBase": String]`。
        public static let endpointChanged = "clam.endpointChanged"
        /// 请求把窗口带到前台。载荷可带 `["sessionId": String]`。
        public static let activateWindow = "clam.activateWindow"
        /// 页内桥消息的主题前缀。**壳对页内消息不设白名单**：
        /// `window.webkit.messageHandlers.clam.postMessage({type, ...})` 里的
        /// 任意 `type` 都会原样广播成 `clam.page.<type>`，载荷就是那个字典本身。
        /// 想接一条新页内消息的插件订阅 `pagePrefix + "yourType"` 即可，
        /// 不必改壳。动态主题不逐个加常量——只有壳自己也要 emit 的那几条
        /// （下面两个）才配常量。
        public static let pagePrefix = "clam.page."
        /// 页内桥上报当前会话。载荷 `["id": String]`。**粘性**（`emitSticky`）
        /// ——插件装载得比页面晚，不粘的话它得等到用户下一次切会话才知道当前是哪个。
        public static let pageCurrentSession = pagePrefix + "currentSession"
        /// 页内桥就绪。载荷 `["capabilities": [String]]`。
        public static let pageReady = pagePrefix + "ready"
        /// 壳的菜单/快捷键触发了一个命令。载荷 `["command": String]`。
        /// 壳只负责喊，具体做什么归拥有相应能力的插件（如 layout 拥有会话展示面）。
        public static let menuCommand = "clam.menu.command"
    }
}
