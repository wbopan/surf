import Foundation
import WebKit
import DSHSidebarUI

/// ConversationSurface 协议定义在 DSHSidebarUI（平台无关）；
/// 本文件是 Mac 壳的 WKWebView 实现：经 evaluateJavaScript 调用
/// dash-web-adapter 插件暴露的 `window.__dash`。
/// 全部防御式：桥不存在时静默失败（壳侧有 8s ready 超时自动回退全网页模式兜底）。

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

@MainActor
final class WebViewConversationSurface: ConversationSurface {
    private let webView: WKWebView

    init(webView: WKWebView) {
        self.webView = webView
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
        let script = "(window.__dash && typeof window.__dash.\(fn) === 'function') ? window.__dash.\(fn)(\(args.joined(separator: ","))) : undefined"
        webView.evaluateJavaScript(script) { _, error in
            if let error {
                Log.write("桥调用 \(fn) 失败：\(error.localizedDescription)", tag: "bridge")
            }
        }
    }
}
