import AppKit
import SurfSDK
import Foundation
import UserNotifications

/// 系统 delegate 的中转站 —— 壳替插件占住那些**必须在 app 完成启动前就位**的
/// objc delegate，把回调原样拍平成字典，经 `SurfHooks` 交给接手的插件。
///
/// ## 为什么这件事非壳不可
///
/// 插件是运行时编出来 `dlopen` 的，最快也要在启动后几秒才存在。而系统的若干
/// delegate 只认 `applicationDidFinishLaunching` 之前装上的那个对象。
/// **实测（2026-08-27）**：插件在启动 3 秒后设
/// `UNUserNotificationCenter.current().delegate`，读回来与自己一致，
/// 但 `willPresent` / `didReceive` 一次都不进——Apple 文档那句
/// "assign your delegate before your app finishes launching" 是硬约束。
///
/// ## 壳在这里做什么、不做什么
///
/// **做**：占位、把参数拍平成 `[String: Any]`、把答复拍回系统要的类型。
/// **不做**：任何语义判断。这条通知该不该显示、按钮按了要干嘛，壳一概不知道
/// ——它只是个电话总机。所以 §0.5「壳里零业务」仍然成立：
/// 这里没有一行"通知策略"，只有"UserNotifications 的方法签名长什么样"。
///
/// ## 加一个住户要改什么
///
/// 在这里多 conform 一个系统协议、多两行拍平代码，给它起一个 hook 名。
/// **SDK 与插件协议一个字不动。** 可预见的后续住户：URL scheme 打开
/// （`application(_:open:)`）、Dock 拖放、Services 菜单、`NSUserActivity` 接力。
///
/// ## hook 名与载荷（壳与插件的字符串约定，SDK 不认得它们）
///
/// | hook | 载荷 | 答复 | 时机 |
/// |---|---|---|---|
/// | `system.notification.willPresent` | `identifier`、`userInfo` | `["present": ["banner","list","sound"]]`；没人接 = 系统默认（app 在前台时**不显示**） | 通知到达且 app 在前台 |
/// | `system.notification.response` | `identifier`、`userInfo`、`actionIdentifier`、`userText?` | 不看 | 用户点了通知或它的按钮。**用 retained 派发**——冷启动时插件还没装完，这一拍不能丢 |
///
/// `actionIdentifier` 原样透传，包含系统的两个常量
/// （`UNNotificationDefaultActionIdentifier` = 点了卡片本体、
/// `UNNotificationDismissActionIdentifier` = 划掉了）。壳不翻译它们。
final class SystemDelegateRelay: NSObject, UNUserNotificationCenterDelegate {
    /// hook 名。壳这边的定义处；插件那边照抄字符串（与槽名同纪律）。
    enum Hook {
        static let willPresent = "system.notification.willPresent"
        static let notificationResponse = "system.notification.response"
    }

    private let hooks: SurfHooks

    init(hooks: SurfHooks = .shared) {
        self.hooks = hooks
    }

    /// **必须在 `applicationDidFinishLaunching` 里调用。**
    func install() {
        UNUserNotificationCenter.current().delegate = self
        Log.write("系统 delegate 中转站已就位（UNUserNotificationCenter）", to: SurfPaths.logURL, tag: "relay")
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        let request = notification.request
        let answer = hooks.dispatch(Hook.willPresent, [
            "identifier": request.identifier,
            "userInfo": jsonSafe(request.content.userInfo),
        ])
        completionHandler(Self.options(from: answer?["present"] as? [String]))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let request = response.notification.request
        var payload: [String: Any] = [
            "identifier": request.identifier,
            "userInfo": jsonSafe(request.content.userInfo),
            "actionIdentifier": response.actionIdentifier,
        ]
        if let text = (response as? UNTextInputNotificationResponse)?.userText {
            payload["userText"] = text
        }
        // retained：冷启动时插件还没装完，这一拍留着等它来认领。
        hooks.dispatchRetained(Hook.notificationResponse, payload)
        completionHandler()
    }

    // MARK: - 私有

    /// 没人接（`nil`）时返回空集 = 系统默认：app 在前台时**不显示**。
    /// 这是刻意的——壳不替任何人决定"该不该打扰"。
    private static func options(from names: [String]?) -> UNNotificationPresentationOptions {
        guard let names else { return [] }
        var options: UNNotificationPresentationOptions = []
        for name in names {
            switch name {
            case "banner": options.insert(.banner)
            case "list": options.insert(.list)
            case "sound": options.insert(.sound)
            case "badge": options.insert(.badge)
            default: break // 不认得的名字忽略（协议向前兼容）
            }
        }
        return options
    }

    /// `userInfo` 是 `[AnyHashable: Any]`，而钩子的载荷约定只放 JSON 能表达的值。
    /// 键拍成字符串，值原样带（我们自己塞进去的本来就是字符串）。
    private func jsonSafe(_ info: [AnyHashable: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in info {
            guard let key = key as? String else { continue }
            out[key] = value
        }
        return out
    }
}
