import AppKit
import UserNotifications

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?
    private var harnessManager: HarnessManager?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        requestNotificationAuthorization()

        switch NodeResolver.resolve() {
        case .success(let node):
            let manager = HarnessManager(appSupport: appSupportURL(), node: node)
            harnessManager = manager
            let wc = MainWindowController(harnessManager: manager)
            windowController = wc
            wc.showWindow(nil)
            NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
            wc.start()
        case .failure(let error):
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "未找到可用的 Node.js"
            alert.informativeText = error.localizedDescription
                + "\n\nDeepSeek Harness 需要 Node.js ^22.19.0 或 >=24.0.0 来运行。"
                + "\n\n安装方式：brew install node"
            alert.addButton(withTitle: "退出")
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    /// 收 harness 要 SIGTERM 整个进程组再轮询等它退（MCP 子进程未必秒退，
    /// 最长 5s + 1s）。在主线程等会冻住 UI，所以走 .terminateLater：
    /// 后台收完再放行退出，退出期间窗口和 Dock 保持响应。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let windowController else { return .terminateNow }
        windowController.shutdown {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// macOS 14+ 要求显式声明安全的状态恢复，否则启动时打 Secure coding 警告。
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 关窗 ≠ 退出：harness 在后台持续运行，只有真正退出 App 才被杀。
        false
    }

    /// 关窗后再点 Dock 图标：把主窗口原样带回前台（窗口未销毁，页面状态不变）。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let window = windowController?.window {
            window.makeKeyAndOrderFront(nil)
        } else {
            windowController?.showWindow(nil)
        }
        return true
    }

    private func appSupportURL() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("io.wenbo.dsharness", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Log.write("通知授权失败：\(error.localizedDescription)", tag: "notify")
            } else if !granted {
                Log.write("通知权限未授予", tag: "notify")
            }
        }
    }
}
