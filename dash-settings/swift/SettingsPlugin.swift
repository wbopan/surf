import AppKit
import DashSDK
import Foundation

/// 插件入口。壳按 image handle `dlsym` 取这个符号（每个插件都叫这个名字）。
@_cdecl("dash_plugin_entry")
public func dash_plugin_entry() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(SettingsPlugin()).toOpaque()
}

/// dash-settings 的 Swift 半身：一扇原生设置窗口，**不占任何槽**。
///
/// 不占槽是有意的：设置是自己的窗口，不该跟主窗口的布局抢地方，也不该依赖
/// dash-layout 在不在场——完整网页模式（逃生舱）下 ⌘, 照样能开出原生设置窗口。
///
/// 窗口懒建：`activate` 只订菜单命令，第一次 ⌘, 才造窗口。整代退休时 handle
/// 释放 → 让出 `settingsOwner`、关窗。
final class SettingsPlugin: DashPlugin {

    func activate(host: DashHost) -> AnyObject? {
        let handle = DashPluginHandle()
        var controller: SettingsWindowController?

        // 占住"设置面板的主人"：dash-layout 见有主就不再用页内 modal 响应 ⌘,。
        // 不占的话两边都会响应——原生窗口开出来的同时主窗口里还弹一层网页 modal。
        let owner = NSObject()
        host.objects.setObject(DashObjects.Key.settingsOwner, owner)
        DashDisposable {
            // 只在还是自己占着的时候让位：新一代先注册、旧代后退休（世代替换的
            // 正常顺序），无条件清理会把新一代刚占好的那一份抹掉。
            //
            // **强持 host，不用 `[weak host]`**：壳的 `LoadedPlugin` 同时强持 handle
            // 与 host，退休时是同一次释放，字段析构顺序是实现细节。赌它 = 赌一个
            // 沉默的失败——owner 没让出去，⌘, 从此既不开原生窗口也不弹页内 modal，
            // 而且不留任何痕迹。这里的强持不成环（host 不持有 handle），
            // 且 handle 本就与本世代同生共死。
            if host.objects.object(DashObjects.Key.settingsOwner) === owner {
                host.objects.setObject(DashObjects.Key.settingsOwner, nil)
                host.log("让出 settingsOwner，⌘, 回落页内 modal")
            }
        }.kept(by: handle)

        host.events.subscribe(DashEventBus.Topic.menuCommand) { payload in
            guard payload["command"] as? String == "openSettings" else { return }
            if controller == nil {
                controller = SettingsWindowController(host: host)
            }
            controller?.present()
        }.kept(by: handle)

        DashDisposable {
            controller?.close()
            controller = nil
        }.kept(by: handle)

        host.log("设置窗口就绪")
        return handle
    }
}
