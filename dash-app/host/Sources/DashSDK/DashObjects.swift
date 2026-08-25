import Foundation

/// 宿主对象保管箱：**只放系统类型或 SDK 类型的实例**，跨世代直通存活。
///
/// 典型住户是壳创建的 `WKWebView`——它昂贵（一个 Web 进程 + 一份已加载的页面），
/// 插件换代时若跟着重建，页面会重载、JS 状态会丢。放这里，插件只是借用；
/// M2 实测换代后 `window` 上的 JS 状态原样还在。
///
/// **禁止放插件自己定义的类型**：新一代 module 里的同名类型与旧一代互不认识，
/// 取出来 `as?` 只会安静地得到 nil（M2 断言 4）。
/// 线程约定同 `DashRegistry`：**只在主线程使用**，不加 `@MainActor`
/// （M2 没有覆盖跨 dylib 的 actor 边界，少一个未验证的变量比多一层静态保证划算）。
public final class DashObjects {
    private var storage: [String: AnyObject] = [:]

    public init() {}

    public func object(_ key: String) -> AnyObject? {
        storage[key]
    }

    public func setObject(_ key: String, _ value: AnyObject?) {
        if let value {
            storage[key] = value
        } else {
            storage.removeValue(forKey: key)
        }
    }

    /// 取并转型的糖：`host.objects.object("dash.webView", as: WKWebView.self)`。
    public func object<T>(_ key: String, as type: T.Type) -> T? {
        storage[key] as? T
    }

    /// 壳与各插件共用的键名。字符串键天生易漂移，集中在这里对一次。
    public enum Key {
        /// 壳创建并持有的 `WKWebView`（终极逃生舱也用它，故不归任何插件）。
        public static let webView = "dash.webView"
        /// 当前 dsh 的 HTTP base，`NSURL`。壳在接入/换端点时更新。
        public static let endpoint = "dash.endpoint"
        /// 会话展示面。协议由 dash-layout 定义（`DashConversationSurface`），
        /// 消费者需 `import DashLayout` 后转型。
        public static let conversationSurface = "dash.conversationSurface"
    }
}
