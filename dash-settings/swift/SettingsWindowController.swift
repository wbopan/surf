import AppKit
import DashSDK
import SwiftUI
import WebKit

/// 设置窗口：左边原生导航，右边一块只画设置面板的 WKWebView。
///
/// **分工**：窗框、导航、选中、关闭、尺寸记忆全归 AppKit；面板内容归 dsh 自己的
/// 组件（Models 的 provider 编辑器、Plugins 的卡片……我们既不复制也不维护，
/// 上游改版自动跟随）。网页半边（`lib/client.js`）负责把面板改造成"整页只有设置"
/// 并把目录报上来。
///
/// **窗口关掉不销毁**：`orderOut` 而已，WebView 与它的页面状态留着，第二次 ⌘,
/// 是秒开而不是再等一次首屏。整代插件退休时才连窗带 WebView 一起收
/// （`SettingsPlugin` 的 handle 释放）。
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    private let host: DashHost
    private let endpoint: URL
    private let nav = SettingsNavModel()
    private var webView: WKWebView!
    private var webDisposable: DashDisposable?
    /// 页面还没就绪时用户就点了导航——记下来，`__dashSettings` 一到位就补投。
    private var pendingSection: String?
    private var pageReady = false

    init(host: DashHost, endpoint: URL) {
        self.host = host
        self.endpoint = endpoint
        super.init(window: nil)
        setupWebView()
        setupWindow()
        nav.onSelect = { [weak self] id in self?.show(section: id) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        webDisposable?.dispose()
    }

    // MARK: - 装配

    private func setupWebView() {
        let (webView, disposable) = DashWeb.makeWebView(
            messageName: "dashSettings",
            onMessage: { [weak self] body in self?.handle(message: body) },
            log: { [host] in host.log($0) })
        self.webView = webView
        self.webDisposable = disposable
        // 背景归网页（它自己铺 --dsw-alias-bg-layer-2）：设置页是内容密集的表单，
        // 主窗口那种透明+原生材质在这里只会让文字发飘。
        webView.load(URLRequest(url: pageURL()))
    }

    /// 面板页地址：dsh 的根路径 + `?dash-settings=1`（网页半边的门控）。
    private func pageURL() -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.path = "/"
        components?.queryItems = [URLQueryItem(name: "dash-settings", value: "1")]
        return components?.url ?? endpoint
    }

    private func setupWindow() {
        let split = NSSplitViewController()

        let navController = NSHostingController(rootView: SettingsNavView(model: nav))
        // 默认含 .preferredContentSize：SwiftUI 内容的 fitting 宽度会反过来
        // 顶开分栏，用户调好的宽度就没了（CLAUDE.md 踩坑记录里那条）。
        navController.sizingOptions = []
        let navItem = NSSplitViewItem(sidebarWithViewController: navController)
        navItem.minimumThickness = 168
        navItem.maximumThickness = 240
        navItem.canCollapse = false
        split.addSplitViewItem(navItem)

        let webController = NSViewController()
        webController.view = NSView()
        webView.translatesAutoresizingMaskIntoConstraints = false
        webController.view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: webController.view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: webController.view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: webController.view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: webController.view.trailingAnchor),
        ])
        let webItem = NSSplitViewItem(viewController: webController)
        webItem.canCollapse = false
        webItem.minimumThickness = 480
        split.addSplitViewItem(webItem)

        let window = NSWindow(contentViewController: split)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "设置"
        window.setContentSize(NSSize(width: 820, height: 600))
        window.minSize = NSSize(width: 680, height: 440)
        // 设置窗口不进 ⌘` 的主窗口轮转，但要能被 ⌘W 关掉。
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("DashSettingsWindow")
        self.window = window
    }

    // MARK: - 打开 / 关闭

    func present() {
        guard let window else { return }
        if !window.isVisible && window.frameAutosaveName.isEmpty {
            window.center()
        }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)
    }

    /// 网页说面板没了（用户按了 Esc，官方 dialog 自己关的）——那就关窗，
    /// 而不是留一个空白窗口在那儿。下次打开会重新点开面板。
    private func dismiss() {
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // 面板留在网页里不动：下次 present 直接就是上次那一页。
    }

    // MARK: - 网页 ↔ 原生

    private func handle(message: Any) {
        guard let payload = message as? [String: Any],
              let type = payload["type"] as? String else { return }
        switch type {
        case "sections":
            let raw = payload["rows"] as? [[String: Any]] ?? []
            let rows = raw.compactMap { item -> SettingsSectionRow? in
                guard let id = item["id"] as? String, !id.isEmpty else { return nil }
                let label = item["label"] as? String ?? id
                return SettingsSectionRow(id: id, label: label)
            }
            pageReady = true
            nav.apply(rows: rows)
            if let pending = pendingSection {
                pendingSection = nil
                show(section: pending)
            }
        case "closed":
            dismiss()
        default:
            host.log("设置页发来不认识的消息：\(type)")
        }
    }

    private func show(section id: String) {
        guard pageReady else {
            pendingSection = id
            return
        }
        webView.evaluateJavaScript("window.__dashSettings?.show(\(jsString(id)))") { [host] _, error in
            if let error { host.log("切页失败（\(id)）：\(error.localizedDescription)") }
        }
    }

    /// 拼进 JS 的字符串字面量。section id 目前都是 slug，但拼串就得转义——
    /// 这条规矩不看当下的取值范围。
    private func jsString(_ raw: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [raw])
        guard let data, let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(text.dropFirst().dropLast())
    }
}
