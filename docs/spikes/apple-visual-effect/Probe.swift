// P2 spike：`-apple-visual-effect` 在**不透明窗口**里到底采样到什么。
//
// 与手册附录 A 的唯一实质差异：**窗口保持 isOpaque = true**（手册/Raycast 是
// 透明窗口 + 桌面采样）。surfclam 是文档型 App，窗口不打算透明（计划 §4 已明确
// 不采纳透明窗口），所以"材质在不透明窗口里是否还成立"必须单独实测——
// 这正是本 spike 存在的理由。
//
// 三个待答问题（详见同目录 README.md）：
//   ① 不透明窗口里 glass material 采样到什么（身后的页面内容？还是黑块）
//   ② `CSS.supports` 在私有开关打开前后是否翻转
//   ③ 窗口失活时材质自己会不会变哑光（决定 P3 的失活态方案）
//
// 附带产物：右键菜单项 identifier 转储（build/menu-dump.txt）。P5 要按
// `WKMenuItemIdentifier*` 裁菜单，而这些常量没有公开头文件、dlsym 也取不到
// （实测 MISSING），只能从真菜单里读回来。

import AppKit
import WebKit

/// 右键菜单转储：把 WebKit 默认菜单每一项的 identifier / title 写进文件。
/// P5 的白名单靠它对表，不靠记忆里的常量名。
final class MenuDumpWebView: WKWebView {
    /// 本次转储的场景名（plain / selection / link），由 CLAM_SPIKE_DUMP_MENU 决定。
    var dumpLabel = "plain"

    /// CLAM_SPIKE_EMPTY_MENU=1：把菜单裁空。P5 在正文空白处会把 Reload 与两条
    /// 分隔符全裁掉（Release 下连 Inspect Element 都没有），剩下一个 0 项的
    /// NSMenu——要先知道 AppKit 到底是"不显示"还是"露一个空框"。
    var emptyOut = false

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        var lines = ["# 右键菜单转储 · 场景=\(dumpLabel) · \(Date())"]
        for item in menu.items {
            let id = item.identifier?.rawValue ?? "<nil>"
            let sub = item.submenu.map { " submenu(\($0.items.count))" } ?? ""
            lines.append("\(id)\t| \(item.isSeparatorItem ? "---" : item.title)\(sub)")
        }
        let url = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("menu-dump-\(dumpLabel).txt")
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
        super.willOpenMenu(menu, with: event)
        if emptyOut { menu.removeAllItems() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var webView: MenuDumpWebView!

    func applicationDidFinishLaunching(_ note: Notification) {
        let cfg = WKWebViewConfiguration()

        // ② 的对照组：环境变量 CLAM_SPIKE_NO_SYSTEM_APPEARANCE=1 时不开私有开关，
        // 页面上的 CSS.supports 应当从 true 翻回 false。
        let wantSystemAppearance = ProcessInfo.processInfo
            .environment["CLAM_SPIKE_NO_SYSTEM_APPEARANCE"] != "1"
        if wantSystemAppearance,
           cfg.preferences.responds(to: NSSelectorFromString("_setUseSystemAppearance:")) {
            cfg.preferences.setValue(true, forKey: "useSystemAppearance")
        }
        cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")

        webView = MenuDumpWebView(frame: .zero, configuration: cfg)
        webView.isInspectable = true
        // 刻意**不**关 drawsBackground：页面自己画一层彩色渐变，
        // 这样才能看出玻璃采的是不是"身后的页面内容"（问题 ①）。

        let rect = NSRect(x: 0, y: 0, width: 1000, height: 720)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "apple-visual-effect spike（不透明窗口）"
        // 关键差异：窗口不透明。默认就是 true，这里显式写出来当作断言。
        window.isOpaque = true
        webView.frame = rect
        webView.autoresizingMask = [.width, .height]
        window.contentView = webView
        window.center()

        let url = Bundle.main.url(forResource: "index", withExtension: "html")!
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())

        // ③ 的观测手段：只把窗口 key 态打成根节点属性，**页面侧不给材质加任何
        // 失活样式**——这样截图里材质有没有变哑光，就是材质自己的行为。
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                self.webView.evaluateJavaScript(
                    "document.documentElement.removeAttribute('window-blurred')")
            }
        }
        nc.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                self.webView.evaluateJavaScript(
                    "document.documentElement.setAttribute('window-blurred','')")
            }
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // CLAM_SPIKE_DUMP_MENU=plain|selection|link：自己合成一次右键，把默认菜单
        // 转储下来就退出。走进程内 sendEvent 而不是 CGEvent，是因为这个 ad-hoc
        // 签名的 spike 没有可读的 AX 树（peekaboo 够不着），而 CGEvent 又要先知道
        // 窗口的屏幕坐标。
        if let mode = ProcessInfo.processInfo.environment["CLAM_SPIKE_DUMP_MENU"] {
            webView.dumpLabel = mode
            webView.emptyOut = ProcessInfo.processInfo.environment["CLAM_SPIKE_EMPTY_MENU"] == "1"
            // 右键前留够时间：截图前得先把窗口弄到前台（`open -n` 之后它未必是 key）。
            let delay = Double(ProcessInfo.processInfo.environment["CLAM_SPIKE_DUMP_DELAY"] ?? "") ?? 2.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.dumpMenu(mode) }
        }
    }

    private func dumpMenu(_ mode: String) {
        // 光标底下是什么，决定了 WebKit 给哪一套菜单——所以三种场景分别跑一次。
        // 坐标是窗口坐标（AppKit 原点在左下）。
        let prep: String
        let point: NSPoint
        switch mode {
        case "selection":
            prep = "getSelection().selectAllChildren(document.getElementById('panel-text'))"
            point = NSPoint(x: 300, y: 720 - 320)
        case "link":
            prep = "getSelection().removeAllRanges()"
            let r = "document.getElementById('probe-link').getBoundingClientRect()"
            // 链接的位置由页面自己报，别在这里猜排版。
            webView.evaluateJavaScript("\(prep); JSON.stringify([\(r).left + \(r).width/2, \(r).top + \(r).height/2])") { value, _ in
                guard let json = value as? String,
                      let data = json.data(using: .utf8),
                      let xy = try? JSONSerialization.jsonObject(with: data) as? [Double],
                      xy.count == 2 else { return }
                MainActor.assumeIsolated {
                    self.sendRightClick(at: NSPoint(x: xy[0], y: 720 - xy[1]))
                }
            }
            return
        default:
            prep = "getSelection().removeAllRanges()"
            point = NSPoint(x: 500, y: 720 - 120)
        }
        webView.evaluateJavaScript(prep) { _, _ in
            MainActor.assumeIsolated { self.sendRightClick(at: point) }
        }
    }

    private func sendRightClick(at point: NSPoint) {
        guard let event = NSEvent.mouseEvent(
            with: .rightMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1) else { return }
        // 菜单是异步从 web 进程回来的、且会开一个模态跟踪循环，
        // 所以退出的定时器要在发事件**之前**挂上。
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { NSApp.terminate(nil) }
        window.sendEvent(event)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

@main
enum SpikeMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        _ = delegate  // run() 阻塞至退出，这里只是把 delegate 的生命周期钉住
    }
}
