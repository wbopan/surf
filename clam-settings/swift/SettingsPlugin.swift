import AppKit
import ClamSDK
import Foundation

/// 插件入口。壳按 image handle `dlsym` 取这个符号（每个插件都叫这个名字）。
@_cdecl("clam_plugin_entry")
public func clam_plugin_entry() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(SettingsPlugin()).toOpaque()
}

/// clam-settings 的 Swift 半身：一扇原生设置窗口，**不占任何槽**。
///
/// 不占槽是有意的：设置是自己的窗口，不该跟主窗口的布局抢地方，也不该依赖
/// clam-layout 在不在场——完整网页模式（逃生舱）下 ⌘, 照样能开出原生设置窗口。
///
/// 窗口懒建：`activate` 只订菜单命令与桥，第一次 ⌘, 才造窗口。整代退休时 handle
/// 释放 → 让出 `settingsOwner`、关窗。
///
/// **model 不随窗口懒建**：桥的推送在窗口开出来之前就在流，先攒着，
/// 第一次 ⌘, 才是秒开而不是等一轮往返。
final class SettingsPlugin: ClamPlugin {

    func activate(host: ClamHost) -> AnyObject? {
        let handle = ClamPluginHandle()
        let bridge = SettingsBridge(bridge: host.bridge, log: { host.log($0) })
        // 界面语言。真相是 dsh 的 `locale` 设置，壳把它当粘性事件广播
        // （`clam.locale`），所以这一句订上的瞬间就已经是当前值——初值只兜住
        // "壳还没发过"那一刻（决议链见 docs/clam-i18n-plan.md §3）。
        let locale = ClamLocaleStore(bus: host.events)
        let model = SettingsModel(bridge: bridge, locale: locale, log: { host.log($0) })
        var controller: SettingsWindowController?

        // **先收拾上一代留下的窗口**。
        //
        // 实测：退休世代的 `ClamPluginHandle` 常常**不 deinit**（壳里 `loaded[name]`
        // 换掉之后本该是最后一个强引用，但四十多次换代里只析构过三次），于是靠
        // 析构去关窗根本不可靠——每改一次 Swift 就多叠一扇设置窗口。
        //
        // 所以改成不依赖析构的自愈：把窗口本身存进 `objects`，新一代 activate 时
        // 先把存着的那扇关掉。**存 `NSWindow` 而不是自定义类型是关键**——世代之间
        // 类型身份是隔离的（module 名取自 contentHash），`as? 自定义类` 跨代必然失败；
        // `NSWindow` 来自壳链接的同一份 AppKit，跨代 `as?` 才成立。
        if let stale = host.objects.object(ClamObjects.Key.settingsOwner) as? NSWindow {
            host.log("关掉上一代留下的设置窗口")
            stale.orderOut(nil)
            stale.close()
        }

        // 占住"设置面板的主人"：clam-layout 见有主就不再用页内 modal 响应 ⌘,。
        // 不占的话两边都会响应——原生窗口开出来的同时主窗口里还弹一层网页 modal。
        // 窗口还没建，先放一个占位；建好之后换成窗口本身（见下面菜单回调）。
        let owner = NSObject()
        host.objects.setObject(ClamObjects.Key.settingsOwner, owner)
        ClamDisposable {
            // 只在还是自己占着的时候让位：新一代先注册、旧代后退休（世代替换的
            // 正常顺序），无条件清理会把新一代刚占好的那一份抹掉。
            //
            // **强持 host，不用 `[weak host]`**：壳的 `LoadedPlugin` 同时强持 handle
            // 与 host，退休时是同一次释放，字段析构顺序是实现细节。赌它 = 赌一个
            // 沉默的失败——owner 没让出去，⌘, 从此既不开原生窗口也不弹页内 modal，
            // 而且不留任何痕迹。这里的强持不成环（host 不持有 handle），
            // 且 handle 本就与本世代同生共死。
            // 占位可能已经被换成窗口了，两种都算"还是自己占着"。
            let current = host.objects.object(ClamObjects.Key.settingsOwner)
            if current === owner || (current as? NSWindow) === controller?.window {
                host.objects.setObject(ClamObjects.Key.settingsOwner, nil)
                host.log("让出 settingsOwner，⌘, 回落页内 modal")
            }
        }.kept(by: handle)

        // 桥的推送直接喂给 model。窗口在不在无所谓——快照攒着就是了。
        host.bridge.onMessage { channel, payload in
            MainActor.assumeIsolated {
                model.apply(channel: channel, payload: payload)
            }
        }.kept(by: handle)

        // 主动要一次：TS 半身的首推可能早于本代装载（换代时必然如此）。
        model.refresh()

        host.events.subscribe(ClamEventBus.Topic.menuCommand) { payload in
            guard payload["command"] as? String == "openSettings" else { return }
            if controller == nil {
                let created = SettingsWindowController(model: model, log: { host.log($0) })
                controller = created
                // 把占位换成窗口本身，好让下一代能找到它并关掉。
                // 仍然只在自己还占着的时候换，理由同下面的让位分支。
                if host.objects.object(ClamObjects.Key.settingsOwner) === owner,
                   let window = created.window {
                    host.objects.setObject(ClamObjects.Key.settingsOwner, window)
                }
            }
            controller?.present()
        }.kept(by: handle)

        // 换语言时把**窗框**重贴一遍。页面内容是 SwiftUI，读 `model.strings` 就自己
        // 重渲了；`.preference` 工具栏那四个标签与窗口标题归 AppKit 拿着，够不着
        // SwiftUI 的观察，只能这么推一下（`withObservationTracking` 那条路有静默
        // 死亡坑，CLAUDE.md 记过案）。
        //
        // 窗口还没建出来时什么都不用做：`setupWindow` 本来就按当前语言贴标签。
        // 闭包只捕获 `controller` 那个盒子，**没捕获 `handle`**，所以不成环
        // （clam-header 那条"订阅与 handle 互相按住"的坑，在这里天然不存在）。
        host.events.subscribe(ClamEventBus.Topic.locale) { payload in
            guard let raw = payload["locale"] as? String,
                  let next = ClamLocale(rawValue: raw) else { return }
            MainActor.assumeIsolated { controller?.relocalize(next) }
        }.kept(by: handle)

        ClamDisposable {
            // **先 orderOut 再 close**：只调 close 的话窗口会留在屏幕上变成幽灵。
            // 控制器是窗口的唯一持有者，退休时它在同一轮里就被释放了；而 close
            // 走的是"本轮结束再收尾"那条路，收尾时持有者已经没了，窗口就卡在
            // ordered-in 状态由 AppKit 自己拿着，谁也关不掉它。
            // 症状：每改一次 Swift 就多一扇一模一样的设置窗口叠在后面。
            // 先 orderOut 再 close：控制器是窗口的唯一持有者，退休时两者同一轮释放，
            // 显式 order out 保证屏幕上不留东西。
            controller?.window?.orderOut(nil)
            controller?.close()
            controller = nil
        }.kept(by: handle)

        host.log("设置窗口就绪")
        return handle
    }
}
