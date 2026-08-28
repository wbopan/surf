import AppKit
import ClamSDK
import Foundation
import WebKit

/// 插件入口。壳按 image handle `dlsym` 取这个符号。
@_cdecl("clam_plugin_entry")
public func clam_plugin_entry() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(NativeifyPlugin()).toOpaque()
}

/// clam-nativeify 的 Swift 半身：**让原生那半边跟着 dsh 的主题走**
/// （计划 `docs/native-feel-upgrade-plan.md` P4）。
///
/// 本包九成的实现在 `lib/client.js` 那段 CSS 里；这半边只补最后一条缝：
/// 系统 `NSAppearance` 与 dsh 的 `ui-theme` 此前互不知情，于是
///
/// - dsh 设浅色而系统是深色时，侧边栏/工具栏深、网页正文浅，一眼穿帮；
/// - 窗口 `backgroundColor` 跟系统而不是跟页面，首帧与 resize 会露底闪错色。
///
/// 真相在 dsh（计划 §0.1「不另建主真相来源」），这里只跟随：
/// 收到投影 → 设 `NSApp.appearance` + 主窗口底色。**一个偏好都不存**，
/// 也不提供任何改主题的入口。
///
/// **不占槽、不贡献界面**，缺席时回到"两套主题源各行其是"，也就是今天的行为。
final class NativeifyPlugin: ClamPlugin {
    /// **返回 follower 而不是 handle**——「不占槽的插件没有生命周期锚」那条坑：
    /// 占槽的插件有 registry → 视图闭包 → model 这条天然强引用链，不占槽的没有，
    /// `activate` 里 new 出来的对象一返回就被 ARC 回收，所有 `[weak self]` 异步
    /// 回调静默变 nil（"上线"日志照常打印，然后什么都不发生）。
    /// 所以壳持有 follower，follower 持有 handle，handle 持有全部订阅。
    func activate(host: ClamHost) -> AnyObject? {
        let follower = ThemeFollower(host: host)
        follower.start()
        return follower
    }
}

/// 把 node 投下来的 dsh 主题偏好落到 AppKit 上。**每代一个新实例。**
///
/// ## 为什么没有"恢复原状"的逻辑
///
/// `NSApp.appearance` 与 `window.backgroundColor` 都是**进程级/窗口级的状态，
/// 不是我们租来的资源**：新一代 `activate` 之后 node 会再投一次（壳每代都问），
/// 按新投影重设即可收敛，换代天然不留残渣。所以这里没有 `deinit`，也不该有
/// ——「别把清理逻辑只挂在析构上」那条坑记着：热替换时旧 handle 的 deinit
/// 实测经常根本不跑，靠它恢复只会得到一个时灵时不灵的行为。
///
/// 真正的"退休"是插件从编排表里摘掉：那时本进程保持最后一次设定，
/// 壳重启即回到 `.windowBackgroundColor` + 系统外观。
@MainActor
final class ThemeFollower {
    private let host: ClamHost
    /// 本代所有订阅。**由 follower 持有**（见 `NativeifyPlugin.activate` 的注释）。
    private let handle = ClamPluginHandle()

    /// 最近一次投影。收到之前**什么都不碰**——没有投影时的正确行为是"维持现状"，
    /// 而不是拿一个猜出来的默认值去覆盖真相。
    private var painted: NSColor?

    init(host: ClamHost) {
        self.host = host
    }

    func start() {
        host.bridge.onMessage { [weak self] channel, payload in
            MainActor.assumeIsolated {
                guard let self, channel == "theme" else { return }  // 未知频道忽略（协议向前兼容）
                self.apply(payload)
            }
        }.kept(by: handle)

        // 窗口底色要重涂的两种时机：投影变了（上面那条），以及**窗口本身换了**。
        // 后者在冷启动时是真的会发生的——`activate` 早于 root 槽把 WebView 装进
        // 窗口时，`webView.window` 还是 nil，此刻涂无处可涂。didBecomeKey 一到就
        // 补上（重涂是幂等的，多来几次不花钱）。
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.paintWindow() }
            }
        handle.keep(ClamDisposable { NotificationCenter.default.removeObserver(token) })

        // 每代都要问一次：node 半边只在设置变化时推，不给新连上来的世代补发
        // （与桥不给壳补发 `app-build` 同一条纪律——补发的判断归请求方）。
        // 这一问还兼着堵一个时序洞：dsh 的 `ui-theme` ns 是别的插件在自己的
        // `inject(["settings"])` 里注册的，node 半边挂载那一刻可能还读不到。
        host.bridge.send(action: "theme")

        host.log("主题跟随上线（已请求投影；在此之前外观维持进程现状）")
    }

    // MARK: - 落地

    private func apply(_ payload: [String: Any]) {
        guard let theme = payload["theme"] as? String,
              ["light", "dark", "system"].contains(theme) else {
            host.log("投影里没有认得的 theme（\(payload["theme"] ?? "nil")），忽略")
            return
        }
        let map = payload["bgBase"] as? [String: String] ?? [:]
        let light = Self.color(hex: map["light"]) ?? .white
        let dark = Self.color(hex: map["dark"]) ?? NSColor(white: 30.0 / 255.0, alpha: 1)

        // ① 外观。**进程级**，一句就把原生侧边栏、工具栏、设置窗口全带过去了。
        //    `system` = 交回给系统（nil 表示"不覆盖"，不是"浅色"）。
        NSApp.appearance = switch theme {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil
        }

        // ② 窗口底色。**做成动态色而不是当场解析成一个静态色**：`system` 档下
        //    系统深浅一翻，动态色自己跟着翻，不需要我们再去订
        //    `AppleInterfaceThemeChangedNotification` 或 KVO `effectiveAppearance`。
        //    显式档下 ① 已经把 appearance 钉死，provider 拿到的必然是钉死的那个，
        //    所以三个档位共用这一条实现。
        painted = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
        paintWindow()

        host.log("跟随 dsh 主题：\(theme)")
    }

    /// 把底色刷到主窗口上。
    ///
    /// 主窗口的判据是**它装着壳那个 WebView**，而不是 `NSApp.mainWindow`
    /// ——后者会在 clam-settings 那扇窗打开时指过去，把设置窗的底色一起改了
    /// （那扇窗该用系统的 `.windowBackgroundColor`，它不显示网页）。
    private func paintWindow() {
        guard let painted,
              let webView = host.objects.object(ClamObjects.Key.webView, as: WKWebView.self),
              let window = webView.window else { return }
        window.backgroundColor = painted
    }

    // MARK: - 工具

    /// `#RRGGBB` / `#RGB`（`#` 可省）→ NSColor。认不出返回 nil，由调用方兜底。
    ///
    /// 用 `sRGB` 而不是 `deviceRGB`：投影里那两个值是从 CSS 抄来的，
    /// CSS 的十六进制色就是 sRGB，换个色彩空间会与网页差出肉眼可见的一点点。
    private static func color(hex: String?) -> NSColor? {
        guard var text = hex?.trimmingCharacters(in: .whitespaces) else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 {
            text = text.map { "\($0)\($0)" }.joined()
        }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255.0,
                       green: CGFloat((value >> 8) & 0xFF) / 255.0,
                       blue: CGFloat(value & 0xFF) / 255.0,
                       alpha: 1)
    }
}
