import Foundation
import WebKit

/// 会话展示面：原生 UI → 网页会话区的唯一动作通道。
///
/// **协议住在消费者侧**（1×N 规则）：拥有 WebView 排版的是 dash-layout，
/// 所以协议定义在这里，随 `DashLayout.swiftmodule` 传给下游。
/// SDK 只放内核词汇，这种生态词汇不进 SDK（计划 §4.1 结尾）。
///
/// 下游（dash-sidebar）从保管箱按 `DashObjects.Key.conversationSurface` 取，
/// 转型成本协议使用。上游换代时下游会被级联重编，转型永远对得上。
public protocol DashConversationSurface: AnyObject {
    /// 切换会话区显示的会话。
    func selectSession(id: String)
    /// 新建会话（复用 web 的 Session Intent 流；runtime 自行推导目标 Workspace）。
    func startSession(workspaceId: String?)
    /// 打开 dsh 自己的设置面板。
    func openSettings()
}

/// WKWebView 实现：经 `evaluateJavaScript` 调用本包 client 半边（lib/client.js）装的 `window.__dash`。
/// 全部防御式——桥不在（普通浏览器、页面还没加载完）时静默失败，不弹窗不报错。
final class WebViewConversationSurface: DashConversationSurface {
    private weak var webView: WKWebView?
    private let log: (String) -> Void

    init(webView: WKWebView, log: @escaping (String) -> Void) {
        self.webView = webView
        self.log = log
    }

    func selectSession(id: String) {
        call("selectSession", args: [jsStringLiteral(id)])
    }

    func startSession(workspaceId: String?) {
        if let workspaceId {
            call("startSession", args: [jsStringLiteral(workspaceId)])
        } else {
            call("startSession", args: [])
        }
    }

    func openSettings() {
        call("openSettings", args: [])
    }

    private func call(_ fn: String, args: [String]) {
        guard let webView else { return }
        let script = "(window.__dash && typeof window.__dash.\(fn) === 'function')"
            + " ? window.__dash.\(fn)(\(args.joined(separator: ","))) : undefined"
        webView.evaluateJavaScript(script) { [log] _, error in
            if let error { log("桥调用 \(fn) 失败：\(error.localizedDescription)") }
        }
    }
}

/// JS 字符串字面量转义（反斜杠、引号、控制字符），防注入。
private func jsStringLiteral(_ raw: String) -> String {
    var out = "\""
    for scalar in raw.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if scalar.value < 0x20 {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    return out + "\""
}
