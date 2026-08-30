// WebPolicy 的隔离验证台（可复跑，见同目录 run.sh；多文件编译下顶层代码必须落在 main.swift）。
//
// 为什么需要它：外链与新窗口的入口都在 dsh 的**页面内容**里（助手回复的
// Markdown 链接、搜索来源、trajectory 的"打开图片"），而一个干净的开发会话
// 里往往一条外链都没有——为了点一下链接去发一条真消息不划算。这里把壳里
// 那份 WebPolicy 原样装到一个空 WKWebView 上，用一页手写 HTML 把四条分支
// 全走一遍。
//
// 判定看两处：进程 stdout 的 [harness] 行，以及壳日志里的 [web] 行
// （~/Library/Application Support/io.wenbo.surf/logs/surf.log）。
import AppKit
import WebKit

let base = URL(string: "http://127.0.0.1:3080")!

let html = """
<html><body style="font:14px -apple-system">
<a id="ext-blank" target="_blank" href="https://example.com/ext-blank">外链 · 新窗口</a><br>
<a id="ext-same" href="https://example.com/ext-same">外链 · 当前 frame</a><br>
<a id="bad" href="x-evil://boom">非法 scheme</a><br>
<a id="local-blank" target="_blank" href="http://127.0.0.1:3080/?aux=1">同源 · 新窗口</a>
</body></html>
"""

@MainActor
final class Harness: NSObject {
    let webView: WKWebView
    let policy: WebPolicy
    private var step = 0

    override init() {
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        policy = WebPolicy(
            currentEndpoint: {
                SurfEndpoint(httpBase: base, bridgePath: "/surf/bridge",
                             pid: nil, startedAt: nil, profile: nil,
                             hostDir: nil, appPath: nil, source: .flag)
            },
            presentToast: { print("[harness] toast: \($0.text)") })
        super.init()
        webView.uiDelegate = policy
        webView.navigationDelegate = policy
    }

    func run() {
        webView.loadHTMLString(html, baseURL: base)
        // 页面就绪后逐条点击，每条之间留出策略跑完的时间。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.next() }
    }

    private func next() {
        let ids = ["ext-blank", "ext-same", "bad", "local-blank"]
        guard step < ids.count else {
            let aux = NSApp.windows.filter { $0.isVisible }.count
            print("[harness] 收尾：可见窗口 \(aux) 扇（同源新窗口应留下 1 扇）")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
            return
        }
        let id = ids[step]
        step += 1
        print("[harness] 点击 #\(id)")
        webView.evaluateJavaScript("document.getElementById('\(id)').click()") { _, err in
            if let err { print("[harness] JS 出错：\(err)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.next() }
        }
    }
}

// 命令行进程碰 AppKit 前必须先初始化 NSApplication（同 tools/shot.swift 的教训）。
// main.swift 的顶层不是 MainActor 上下文，AppKit 那几步得显式跳进去。
nonisolated(unsafe) var live: AnyObject?   // 保活：否则 harness 出了作用域就被回收

let app = NSApplication.shared
MainActor.assumeIsolated {
    app.setActivationPolicy(.accessory)
    let harness = Harness()
    live = harness
    harness.run()
}
app.run()
