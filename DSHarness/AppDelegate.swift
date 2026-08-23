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
                + "\n\nDSHarness 需要 Node.js ^22.19.0 或 >=24.0.0 来运行 DeepSeek Harness。"
                + "\n\n安装方式：brew install node"
            alert.addButton(withTitle: "退出")
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowController?.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
