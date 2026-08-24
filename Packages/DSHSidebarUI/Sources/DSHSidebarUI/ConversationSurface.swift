import Foundation

/// 原生侧边栏 → 会话展示面（conversation/details）的唯一动作通道。
/// 协议定义在本包（平台无关）；Mac 壳用 WKWebView 实现（evaluateJavaScript
/// 调用 dsharness-web-adapter 插件暴露的 `window.__dsharness`），
/// 未来 iOS 壳对远程会话展示面另行实现。
@MainActor
public protocol ConversationSurface: AnyObject {
    /// 切换 conversation 显示的会话。
    func selectSession(id: String)
    /// 新建会话（复用 web 的 Session Intent 流；runtime 自行推导目标 Workspace）。
    func startSession(workspaceId: String?)
    /// 打开 web 设置面。
    func openSettings()
}
