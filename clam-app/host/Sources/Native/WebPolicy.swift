import AppKit
import WebKit

/// WebView 的导航策略与下载：网页想"下载一个文件"或"开一个新窗口"时，
/// 由这里决定那件事到底怎么发生。
///
/// **为什么必须有这一层**：WKWebView 默认对这两类动作是**静默丢弃**——
/// 不实现 `decidePolicyFor navigationResponse` 就没有下载（`Content-Disposition:
/// attachment` 的响应被 policy 中断，页面毫无变化）；不设 `uiDelegate` 就没有
/// 新窗口（`target="_blank"` / `window.open` / ⌘点击全部无声消失）。dsh Web UI
/// 恰好两类都用：会话导出 ZIP 走 `<a download>`，正文里的 Markdown 外链、
/// 搜索来源、trajectory 的"打开图片"都是 `target="_blank"`。
///
/// **为什么归壳而不归插件**：WKWebView 归壳所有（LayoutSplitController 里
/// 已把 navigationDelegate/uiDelegate 的归属写死，避开跨代重设的时序问题），
/// 而且下载与外链是**逃生舱也得有**的能力——clam-layout 缺席、全出血网页兜底时，
/// 导出 ZIP 照样要能下来。
///
/// **一条安全边界**：页面里的链接大多是 LLM 生成的内容，等同不可信输入。所以
/// scheme 走**白名单**（http/https/mailto 才交给系统），下载目录固定在 ~/Downloads
/// 且绝不采信页面给的路径分量。`<a href="x-某app://…">` 静默唤起本机应用是真实的
/// 攻击面，不是洁癖。
@MainActor
final class WebPolicy: NSObject {

    /// 一条 URL 的三种归宿。
    private enum Route {
        /// 留在 WebView 里（同源页面、about:/blob:/data: 这类页内资源）。
        case inPlace
        /// 交给系统（外部浏览器 / 邮件客户端）。
        case external(URL)
        /// 拒绝，并说明理由（只进日志——页面无权知道壳的判断依据）。
        case blocked(String)
    }

    /// 当前连着的 dsh。**每次现取**：壳会重连、会换端口，同源判定不能吃快照。
    private let currentEndpoint: () -> ClamEndpoint?
    /// 当前界面语言下的文案表。同样**现取**——下载可能跨越一次语言切换，
    /// 而这一层活得和窗口一样久。
    private let currentStrings: () -> L
    private let presentToast: (ShellToast.Content) -> Void

    /// `target="_blank"` 开出来的次级窗口，按其 WKWebView 索引。
    private var auxWindows: [ObjectIdentifier: AuxWebWindow] = [:]
    /// 每个在途下载的落点（完成时要拿它去访达里高亮）。
    private var destinations: [ObjectIdentifier: URL] = [:]

    init(currentEndpoint: @escaping () -> ClamEndpoint?,
         currentStrings: @escaping () -> L,
         presentToast: @escaping (ShellToast.Content) -> Void) {
        self.currentEndpoint = currentEndpoint
        self.currentStrings = currentStrings
        self.presentToast = presentToast
        super.init()
    }

    // MARK: - 给主 WebView 的转发入口
    //
    // 主 WebView 的 navigationDelegate 是 MainWindowController（它还管连接状态机
    // 与焦点），策略判定转发到这里；次级窗口的 WebView 则整个归本类（见下方
    // WKNavigationDelegate 扩展），两条路走同一套判定。

    func decide(_ webView: WKWebView, action: WKNavigationAction) -> WKNavigationActionPolicy {
        // `<a download>` 与 ⌥点击：WebKit 已经判定这是一次下载意图，直接接住。
        if action.shouldPerformDownload { return .download }
        guard let url = action.request.url else { return .allow }
        switch route(for: url) {
        case .inPlace:
            return .allow
        case .external(let target):
            openExternally(target)
            // window.open 先建窗后导航：外链被截走后那扇窗是空的，别留在屏幕上。
            closeAuxIfBlank(webView)
            return .cancel
        case .blocked(let reason):
            Log.write("拦下导航 \(url.absoluteString)：\(reason)", to: ClamPaths.logURL, tag: "web")
            closeAuxIfBlank(webView)
            return .cancel
        }
    }

    func decide(_ webView: WKWebView, response: WKNavigationResponse) -> WKNavigationResponsePolicy {
        // WebView 显示不了的类型（zip/dmg/…）一律转下载：不转的话 WebKit 会
        // 中断这次导航，用户看到的就是"点了没反应"。
        if !response.canShowMIMEType { return .download }
        if let http = response.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().contains("attachment") {
            return .download
        }
        return .allow
    }

    /// 认领一个 WebKit 交出来的下载（两条 didBecome 回调都汇到这里）。
    func adopt(_ download: WKDownload) {
        download.delegate = self
    }

    // MARK: - 判定

    private func route(for url: URL) -> Route {
        switch url.scheme?.lowercased() ?? "" {
        case "http", "https":
            return isSameOrigin(url) ? .inPlace : .external(url)
        case "about", "blob", "data":
            // 页内资源：图片预览、iframe、srcdoc。顶层 data: 导航 WebKit 自己就禁。
            return .inPlace
        case "mailto":
            return .external(url)
        case let other:
            return .blocked(other.isEmpty ? "缺少 scheme" : "scheme \(other) 不在白名单")
        }
    }

    /// scheme + host + port 三项全等才算同源（port 缺省按 scheme 补）。
    private func isSameOrigin(_ url: URL) -> Bool {
        guard let base = currentEndpoint()?.httpBase else { return false }
        guard let lhs = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rhs = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return false }
        let lhsScheme = lhs.scheme?.lowercased()
        let rhsScheme = rhs.scheme?.lowercased()
        func port(_ c: URLComponents, _ scheme: String?) -> Int? {
            c.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : nil)
        }
        return lhsScheme == rhsScheme
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && port(lhs, lhsScheme) == port(rhs, rhsScheme)
    }

    private func openExternally(_ url: URL) {
        Log.write("外链交给系统：\(url.absoluteString)", to: ClamPaths.logURL, tag: "web")
        NSWorkspace.shared.open(url)
    }

    // MARK: - 次级窗口

    private func closeAuxIfBlank(_ webView: WKWebView) {
        guard let aux = auxWindows[ObjectIdentifier(webView)], webView.url == nil else { return }
        aux.close()
    }

    fileprivate func forget(_ webView: WKWebView) {
        auxWindows.removeValue(forKey: ObjectIdentifier(webView))
    }

    // MARK: - 下载落点

    /// 把页面给的文件名收进 ~/Downloads：只取最后一段、剥掉分隔符，
    /// 页面无权决定目录，也无权用 `..` 往上爬。
    private func destination(for suggested: String) -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        return unique(downloads.appendingPathComponent(sanitized(suggested)))
    }

    private func sanitized(_ name: String) -> String {
        let last = (name as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if last.isEmpty || last == "." || last == ".." { return "download" }
        return last
    }

    /// 同名不覆盖：`x.zip` → `x-1.zip`。覆盖用户已有的文件是不可逆的。
    private func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        for n in 1...999 {
            let name = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }
}

// MARK: - WKNavigationDelegate（次级窗口的 WebView 整个归本类）

extension WebPolicy: WKNavigationDelegate {
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(decide(webView, action: navigationAction))
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(decide(webView, response: navigationResponse))
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        adopt(download)
        // 为下载而生的空窗（⌥点击链接开出来的那种）没有内容可显示。
        closeAuxIfBlank(webView)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        adopt(download)
        closeAuxIfBlank(webView)
    }
}

// MARK: - WKUIDelegate

extension WebPolicy: WKUIDelegate {
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // 外链在这一步就分流走：开一扇窗再由 navigation 策略把它清掉是绕远路。
        if let url = navigationAction.request.url {
            switch route(for: url) {
            case .external(let target):
                openExternally(target)
                return nil
            case .blocked(let reason):
                Log.write("拦下新窗口 \(url.absoluteString)：\(reason)", to: ClamPaths.logURL, tag: "web")
                return nil
            case .inPlace:
                break
            }
        }
        // 同源的新窗口开一扇真窗，而不是在主 WebView 里 load —— 后者会把
        // 会话页顶掉，而壳没有后退 UI，用户就回不来了（trajectory 的"打开图片"
        // 正是这种：一张图换掉整个 dsh 界面）。
        let aux = AuxWebWindow(configuration: configuration, policy: self, features: windowFeatures)
        auxWindows[ObjectIdentifier(aux.webView)] = aux
        aux.show()
        // 返回新 WebView 即可：这次导航由 WebKit 自己在它上面完成
        // （blob: 之类绑 document 的 URL 也因此照样成立）。
        return aux.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        auxWindows[ObjectIdentifier(webView)]?.close()
    }

    /// `<input type="file">`。dsh 目前的附件只走拖放/粘贴，用不上这条；
    /// 但缺了它一旦页面改用 file input 就又是"点了没反应"，成本近乎零，先堵上。
    func webView(_ webView: WKWebView,
                 runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        guard let window = webView.window else {
            completionHandler(panel.runModal() == .OK ? panel.urls : nil)
            return
        }
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    // JS 的三个原生弹窗。不实现的话 alert 无声、confirm 恒为 false ——
    // 同样是"页面以为自己做到了、其实没有"那一类沉默失败。

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: currentStrings().ok)
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        let s = currentStrings()
        alert.messageText = message
        alert.addButton(withTitle: s.ok)
        alert.addButton(withTitle: s.cancel)
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        let s = currentStrings()
        alert.messageText = prompt
        alert.addButton(withTitle: s.ok)
        alert.addButton(withTitle: s.cancel)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        let ok = alert.runModal() == .alertFirstButtonReturn
        completionHandler(ok ? field.stringValue : nil)
    }
}

// MARK: - WKDownloadDelegate

extension WebPolicy: WKDownloadDelegate {
    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let url = destination(for: suggestedFilename)
        destinations[ObjectIdentifier(download)] = url
        Log.write("开始下载 → \(url.path)", to: ClamPaths.logURL, tag: "download")
        completionHandler(url)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = destinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        Log.write("下载完成 \(url.path)", to: ClamPaths.logURL, tag: "download")
        // Dock 的下载堆栈靠这条分布式通知弹跳——系统下载体验的那一半，
        // 不发的话文件是到了，但看起来像什么都没发生。
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.apple.DownloadFileFinished"),
            object: url.path, userInfo: nil, deliverImmediately: true)
        let s = currentStrings()
        presentToast(ShellToast.Content(
            text: s.downloadFinished(url.lastPathComponent),
            actionTitle: s.showInFinder,
            action: { NSWorkspace.shared.activateFileViewerSelecting([url]) }))
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let url = destinations.removeValue(forKey: ObjectIdentifier(download))
        // 用户自己取消的不必再提醒一次。
        if (error as NSError).code == NSURLErrorCancelled { return }
        let s = currentStrings()
        let name = url?.lastPathComponent ?? s.downloadFallbackName
        Log.write("下载失败 \(name)：\(error.localizedDescription)", to: ClamPaths.logURL, tag: "download")
        presentToast(ShellToast.Content(text: s.downloadFailed(name), actionTitle: nil, action: nil))
    }
}

// MARK: - 次级窗口

/// `target="_blank"` / `window.open` 开出来的普通窗口。
///
/// 刻意朴素：标准标题栏、⌘W 可关、内容就是一个铺满的 WKWebView。它承载的是
/// "看一眼就关掉"的东西（一张图、一份 raw 文本），不该长得像第二个 surfclam。
@MainActor
private final class AuxWebWindow: NSObject, NSWindowDelegate {
    let webView: WKWebView
    private let window: NSWindow
    private unowned let policy: WebPolicy
    private var titleObservation: NSKeyValueObservation?

    init(configuration: WKWebViewConfiguration, policy: WebPolicy, features: WKWindowFeatures) {
        self.policy = policy
        // 必须用 WebKit 给的这份 configuration 建 WebView，opener 关系才成立。
        webView = WKWebView(frame: .zero, configuration: configuration)
        let width = features.width?.doubleValue ?? 900
        let height = features.height?.doubleValue ?? 700
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        webView.navigationDelegate = policy
        webView.uiDelegate = policy
        webView.allowsMagnification = true
        webView.allowsBackForwardNavigationGestures = true
        window.contentView = webView
        window.delegate = self
        window.isReleasedWhenClosed = false  // 生命周期归 auxWindows 字典，不归 AppKit
        window.title = AppInfo.displayName
        window.center()
        // 标题跟随页面：次级窗口经常同时开着好几扇，标题是唯一的区分。
        titleObservation = webView.observe(\.title, options: [.new]) { [weak window] _, change in
            guard let title = change.newValue ?? nil, !title.isEmpty else { return }
            MainActor.assumeIsolated { window?.title = title }
        }
    }

    func show() { window.makeKeyAndOrderFront(nil) }
    func close() { window.close() }

    func windowWillClose(_ notification: Notification) {
        titleObservation?.invalidate()
        titleObservation = nil
        policy.forget(webView)
    }
}
