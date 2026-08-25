import AppKit
import DashSDK
import Foundation

/// 插件入口。壳按 image handle `dlsym` 取这个符号（每个插件都叫这个名字）。
@_cdecl("dash_plugin_entry")
public func dash_plugin_entry() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(SettingsPlugin()).toOpaque()
}

/// dash-settings 的 Swift 半身：一扇原生设置窗口，不占任何槽。
///
/// **不占槽**是有意的：设置是自己的窗口，不该跟主窗口的布局抢地方，也不该依赖
/// dash-layout 在不在场——完整网页模式（逃生舱）下 ⌘, 照样能开出原生设置窗口。
///
/// 窗口懒建：`activate` 只订阅菜单命令，第一次 ⌘, 才造窗口和 WebView。
/// 整代退休时 handle 释放 → 窗口关闭、WebView 与消息处理器一并摘掉。
final class SettingsPlugin: DashPlugin {

    func activate(host: DashHost) -> AnyObject? {
        guard let base = host.objects.object(DashObjects.Key.endpoint, as: NSURL.self) as URL? else {
            host.log("保管箱里没有 endpoint，设置窗口缺席（dsh 还没接上）")
            return nil
        }

        let handle = DashPluginHandle()
        var controller: SettingsWindowController?

        // 占住"设置面板的主人"：dash-layout 见有主就不再用页内 modal 响应 ⌘,。
        // 不占的话两边都会响应——原生窗口开出来的同时主窗口里还弹一层网页 modal。
        let owner = NSObject()
        host.objects.setObject(DashObjects.Key.settingsOwner, owner)
        DashDisposable { [weak host] in
            // 只在还是自己占着的时候让位（新一代可能已经接管了这个键）。
            if host?.objects.object(DashObjects.Key.settingsOwner) === owner {
                host?.objects.setObject(DashObjects.Key.settingsOwner, nil)
            }
        }.kept(by: handle)

        host.events.subscribe(DashEventBus.Topic.menuCommand) { payload in
            guard payload["command"] as? String == "openSettings" else { return }
            if controller == nil {
                controller = SettingsWindowController(host: host, endpoint: base)
            }
            controller?.present()
        }.kept(by: handle)

        DashDisposable {
            controller?.close()
            controller = nil
        }.kept(by: handle)

        host.log("设置窗口就绪（\(base.absoluteString)）")
        return handle
    }
}
