import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?
    /// 系统 delegate 中转站。**壳持有它**：那些 delegate 属性多半是 weak 的，
    /// 而且它必须活得和进程一样久。
    private let systemDelegates = SystemDelegateRelay()

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        // **必须在这里、必须在启动结束之前**：若干系统 delegate 只认
        // 启动期装上的那个对象，晚设无效（实测见 SystemDelegateRelay 顶部注释）。
        // 壳只占位与转发，语义归接手的插件。
        systemDelegates.install()

        // M1 起壳不再探测 Node、不再 spawn dsh：dsh 先于 App 存在，
        // 窗口起来后自己去找它（flag → 发现文件 → 引导页）。
        let wc = MainWindowController()
        windowController = wc
        wc.showWindow(nil)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        wc.start()
    }

    /// 收尾只剩壳自己这一侧（停轮询、停桥、停会话镜像），
    /// 都是同步的——dsh 是别人的进程，不归我们杀，也不必等。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        windowController?.shutdown()
        return .terminateNow
    }

    /// macOS 14+ 要求显式声明安全的状态恢复，否则启动时打 Secure coding 警告。
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 关窗 ≠ 退出：dsh 在终端持续运行，关掉壳窗口只是收起这个客户端。
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
}
