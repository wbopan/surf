import AppKit

/// **整个类都在主 actor 上**：它持有的东西（窗口控制器、托管后端）都是
/// `@MainActor` 的，而 AppKit 的每一个回调本来也只在主线程来。
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?
    /// 系统 delegate 中转站。**壳持有它**：那些 delegate 属性多半是 weak 的，
    /// 而且它必须活得和进程一样久。
    private let systemDelegates = SystemDelegateRelay()
    /// 托管后端（`docs/archive/surf-connection-plan.md` §5）。**AppDelegate 持有**：
    /// 它得活得和进程一样久，而窗口是可以关掉的（关窗 ≠ 退出）。
    private let backend = BackendManager()

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

        // 窗口起来后自己去找后端（一次性目标 → flag → 连接偏好 → 发现文件）。
        // 连接偏好是 `managed` 时它还会顺手拉起一个自己的后端
        // （`MainWindowController.start()` → `BackendManager.start()`）。
        let wc = MainWindowController(backend: backend)
        windowController = wc
        wc.showWindow(nil)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        wc.start()
    }

    /// 收尾：壳自己那一侧（停轮询、停桥）永远是同步的；托管的后端是**我们的**
    /// 子进程，得给它收尾的时间——`prepareForTermination` 说要等就走
    /// `.terminateLater`，2 秒内（或它先死透）由 BackendManager 自己
    /// `reply(toApplicationShouldTerminate:)` 把退出流程接回去。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        windowController?.shutdown()
        return backend.prepareForTermination() ? .terminateLater : .terminateNow
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
