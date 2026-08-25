import AppKit
import Foundation
import WebKit

/// 插件自己造 WKWebView 时的装配件。
///
/// **为什么住在 SDK 里**：UA 后缀和外链白名单是全进程一致的策略，不该每个要
/// WebView 的插件抄一遍——抄第二遍的时候就会有人漏掉 scheme 白名单。
/// （插件自己继承 `NSObject` 实现这些 `@objc` 协议本身是安全的：插件 module 名
/// 取自 contentHash，两代的 ObjC 类名因此天然不同，不会撞进同一个 runtime 注册表。）
///
/// 壳自己的主 WebView **不走这里**：它有下载、Toast、同源判定那一整套
/// （`Native/WebPolicy.swift`），比这里厚得多。这里是给"插件要一块次要 WebView"
/// 准备的最小可用件——UA 对齐、页内消息进得来、外链能出去，仅此而已。
public enum DashWeb {

    /// 造一块插件用的 WKWebView。
    ///
    /// - Parameters:
    ///   - messageName: 页内 `window.webkit.messageHandlers.<name>` 的名字。
    ///   - onMessage: 收到页内消息（已解序列化的 JSON 值）。
    ///   - log: 诊断输出。
    /// - Returns: WebView 与撤销句柄；句柄释放时摘掉消息处理器与 delegate，
    ///   否则 `WKUserContentController` 会一直强持有它们（跨代泄漏的经典入口）。
    @MainActor
    public static func makeWebView(messageName: String,
                                   onMessage: @escaping (Any) -> Void,
                                   log: @escaping (String) -> Void = { _ in })
        -> (webView: WKWebView, disposable: DashDisposable) {
        let config = WKWebViewConfiguration()
        // 与壳的主 WebView 同一套 UA 后缀：dash-nativeify / dash-layout 的 client
        // 半边靠它判断"页面跑在壳里"，插件的 WebView 也该享受同样的原生化。
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        config.applicationNameForUserAgent = "Dash/\(shortVersion)"

        let proxy = DashWebProxy(onMessage: onMessage, log: log)
        config.userContentController.add(proxy, name: messageName)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = proxy
        // 不设 uiDelegate = `target="_blank"` / `window.open` 被 WebKit 静默丢弃，
        // 连个回调都没有（壳的 WebPolicy 顶注记着这条）。设置页的"去拿 API key"
        // 之类外链就是这么丢的。
        webView.uiDelegate = proxy

        let disposable = DashDisposable { [weak webView] in
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: messageName)
            webView?.navigationDelegate = nil
            webView?.uiDelegate = nil
        }
        return (webView, disposable)
    }
}

/// 消息与导航的 ObjC 壳子。插件够不着这个类型——它只经 `DashWeb.makeWebView` 使用。
final class DashWebProxy: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    private let onMessage: (Any) -> Void
    private let log: (String) -> Void

    init(onMessage: @escaping (Any) -> Void, log: @escaping (String) -> Void) {
        self.onMessage = onMessage
        self.log = log
    }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        onMessage(message.body)
    }

    /// 新窗口请求（`target="_blank"` / `window.open`）：交给系统浏览器。
    ///
    /// **页面里的链接等同不可信输入**（大半是 LLM 生成的），所以 scheme 走白名单：
    /// `x-某app://` 静默唤起本机应用是真实攻击面，不是理论风险。
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        openExternally(navigationAction.request.url)
        return nil
    }

    /// 同 frame 内跳到站外：也交给系统浏览器（插件的 WebView 只该显示自己那一页）。
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url,
              let host = url.host,
              host != webView.url?.host else {
            decisionHandler(.allow)
            return
        }
        openExternally(url)
        decisionHandler(.cancel)
    }

    private func openExternally(_ url: URL?) {
        guard let url, let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else {
            log("拦下非白名单 scheme 的外链：\(url?.absoluteString ?? "nil")")
            return
        }
        NSWorkspace.shared.open(url)
    }
}
