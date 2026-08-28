import AppKit
import DashSDK
import Foundation
import UserNotifications

/// `UNUserNotificationCenter` 的全部接触面 —— 通知的发、撤、按钮、授权、角标。
///
/// ## delegate 不在这里，在壳里
///
/// 第一版让本插件自己当 `UNUserNotificationCenterDelegate`。**实测不行**
/// （2026-08-27）：插件在 app 启动 3 秒后设 `center.delegate`，读回来与自己
/// 一致，但 `willPresent` / `didReceive` 一次都不进——Apple 文档那句
/// "assign your delegate before your app finishes launching" 是硬约束。
/// 后果很隐蔽：通知照样进通知中心（`getDeliveredNotifications` 找得到）、
/// add 不报错、日志一片祥和，只是 **app 在前台时不弹横幅、所有按钮都没反应**。
///
/// 所以 delegate 归壳：`SystemDelegateRelay` 在 `applicationDidFinishLaunching`
/// 里占住它，把回调原样拍平经 `DashHooks` 转发。壳不解释任何通知语义，
/// 那是个通用的中转站（下一个住户可能是 URL scheme 或 Services 菜单）。
/// 本插件只是**接手 hook 的那个人**，一切判断仍在这边。
///
/// 顺带一个收益：`response` 那条 hook 是 retained 派发的，冷启动时插件还没编完
/// 也丢不了——那一拍从此有人接。
///
@MainActor
final class NotifyCenter {
    /// 壳的 `SystemDelegateRelay` 定的 hook 名。**照抄字符串**——SDK 一个 hook 名
    /// 都不认得，这是壳与插件之间的约定（与槽名、事件主题同纪律）。
    enum Hook {
        static let willPresent = "system.notification.willPresent"
        static let response = "system.notification.response"
    }

    private let center = UNUserNotificationCenter.current()
    private let log: (String) -> Void
    /// 当前挂在系统上的 category 集合（identifier = item.id）。
    private var categories: [String: UNNotificationCategory] = [:]
    /// 已经投递出去的（我们自己记的账；系统那份是异步的，不适合当判据）。
    private var delivered: Set<String> = []

    /// 通知 identifier 的前缀。带实例指纹是为了多 worktree：两个 Dev 实例
    /// bundle id 相同，不带前缀就会互相撤掉对方的通知。
    private let prefix: String

    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    init(log: @escaping (String) -> Void) {
        self.log = log
        self.prefix = "clam.\(Self.instanceTag()).".self
    }

    // MARK: - 授权

    /// 请求授权并回报结果。系统只会为一个 app 弹一次窗；被拒之后**再也弹不出来**，
    /// 只能引导用户去系统设置。
    func requestAuthorization(_ done: @escaping (UNAuthorizationStatus) -> Void) {
        center.getNotificationSettings { [weak self] settings in
            let status = settings.authorizationStatus
            if status == .notDetermined {
                self?.center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    DispatchQueue.main.async {
                        if let error {
                            self?.log("通知授权失败：\(error.localizedDescription)")
                        }
                        let next: UNAuthorizationStatus = granted ? .authorized : .denied
                        self?.authorization = next
                        self?.log("通知授权：\(granted ? "已授予" : "被拒绝")")
                        done(next)
                    }
                }
                return
            }
            DispatchQueue.main.async {
                self?.authorization = status
                // **把明细一起打出来**：`authorizationStatus == .authorized` 只说明
                // "允许通知"，横幅还可能被单独关掉（系统设置里"提醒样式：无"）、
                // 被专注模式压住、或被屏幕共享静音。第一次调通时就栽在这上面——
                // add 没报错、日志一片祥和，右上角什么都没有。
                self?.log("通知授权：\(Self.describe(status))"
                    + "｜横幅 \(Self.describe(settings.alertSetting))"
                    + "｜通知中心 \(Self.describe(settings.notificationCenterSetting))"
                    + "｜声音 \(Self.describe(settings.soundSetting))"
                    + "｜样式 \(Self.describe(settings.alertStyle))")
                done(status)
            }
        }
    }

    static func describe(_ setting: UNNotificationSetting) -> String {
        switch setting {
        case .notSupported: return "不支持"
        case .disabled: return "关"
        case .enabled: return "开"
        @unknown default: return "未知"
        }
    }

    static func describe(_ style: UNAlertStyle) -> String {
        switch style {
        case .none: return "无"
        case .banner: return "横幅"
        case .alert: return "提醒"
        @unknown default: return "未知"
        }
    }

    static func describe(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "未决定"
        case .denied: return "被拒绝"
        case .authorized: return "已授权"
        case .provisional: return "临时授权"
        @unknown default: return "未知"
        }
    }

    // MARK: - delegate

    /// 接上壳转发的两条系统回调。
    ///
    /// `willPresent` 要**同步**答复（app 在前台时这条要不要显示），所以它是
    /// `dispatch`；`response`（点击/按钮）是 `dispatchRetained`，晚接也不丢。
    ///
    /// - Parameters:
    ///   - present: 给 itemId，答"要哪些呈现方式"（空数组 = 不显示）。
    ///   - onOpen: 点了卡片本体或带 foreground 的按钮。
    ///   - onAction: 按了别的按钮（`text` 只在文本输入那颗上有值）。
    func installHooks(host: DashHost,
                      handle: DashPluginHandle,
                      present: @escaping (_ itemId: String) -> [String],
                      onOpen: @escaping (_ itemId: String, _ sessionId: String) -> Void,
                      onAction: @escaping (_ itemId: String, _ actionId: String, _ text: String?) -> Void) {
        host.handle(hook: Hook.willPresent) { payload in
            let info = payload["userInfo"] as? [String: Any] ?? [:]
            let itemId = info["itemId"] as? String ?? ""
            return ["present": present(itemId)]
        }.kept(by: handle)

        host.handle(hook: Hook.response) { payload in
            let info = payload["userInfo"] as? [String: Any] ?? [:]
            let itemId = info["itemId"] as? String ?? ""
            let sessionId = info["sessionId"] as? String ?? ""
            let action = payload["actionIdentifier"] as? String ?? ""
            switch action {
            case UNNotificationDefaultActionIdentifier:
                onOpen(itemId, sessionId)
            case UNNotificationDismissActionIdentifier:
                // 用户把卡片划掉了。**不当成"办完了"**——dsh 那边还在等回答，
                // 待办仍然留在 node 那份表里。划掉只是不想在屏幕上看见它。
                break
            default:
                onAction(itemId, action, payload["userText"] as? String)
            }
            return nil
        }.kept(by: handle)
    }

    // MARK: - 发与撤

    /// 发一条（同 id 重发即替换，这是系统语义，我们不需要记"发过没有"）。
    func present(_ item: NotifyItem, settings: NotifySettings) {
        let identifier = prefix + item.id

        // category 必须先于通知存在：已投递的卡片是按 categoryIdentifier 现查
        // 按钮的，注册晚了那条通知就是一颗光板。
        categories[item.id] = makeCategory(for: item)
        flushCategories()

        let content = UNMutableNotificationContent()
        content.title = item.title
        // 副标题放会话名：横幅上它是第二行，一眼看出是"哪个会话在叫你"。
        // **标题已经是会话名的那几类不重复说**（「回合结束」的标题就是会话名，
        // 照直设的话横幅上同一行字会连着出现两遍）。
        content.subtitle = item.sessionLabel == item.title ? "" : item.sessionLabel
        content.body = item.body
        content.categoryIdentifier = item.id
        // 同一会话的通知在通知中心归成一组。
        content.threadIdentifier = item.sessionId
        content.userInfo = ["itemId": item.id, "sessionId": item.sessionId]
        // `importance` **只管响不响**，不管弹不弹。
        if settings.sound, item.importance == "interrupt" {
            content.sound = .default
        }
        // **一律 `.active`，`passive` 那一档不要碰。**
        //
        // `.passive` 的语义不是"安静一点"，而是**根本不弹横幅**——通知直接躺进
        // 通知中心，用户不主动去翻就永远看不见。早先按 `importance` 把
        // 「回合结束」发成 `.passive`，结果就是那类通知等于没发：屏幕上一点动静
        // 没有，日志里却写着"发通知"，看上去像系统设置出了问题（实际不是）。
        //
        // "跑完了"恰恰是最需要横幅的场景之一——人切去别的窗口干活，就等着被叫回来。
        // 该不该打扰这件事已经在两处判过了（`NotifyPolicy.shouldPresent` 的分类
        // 开关与前台策略），走到这里就是"决定要发"，那就该让人看见。
        // 安静与否交给声音：`.active` + 无声 = 弹一下但不吵。
        //
        // `.timeSensitive` 能穿透专注模式，但要
        // `com.apple.developer.usernotifications.time-sensitive` entitlement，
        // ad-hoc 签名拿不到——别费劲。
        content.interruptionLevel = .active

        log("发通知 \(item.id)：\(item.title) · \(item.actions.count) 颗按钮"
            + (item.textInput == nil ? "" : " + 输入框"))
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) {
            [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async { self?.log("通知发送失败（\(item.id)）：\(error.localizedDescription)") }
        }
        delivered.insert(item.id)
    }

    /// 撤一条。**category 跟着撤**——卡片没了它就没有存在的理由，留着只会让
    /// 那张全量重设的表越来越长。
    func withdraw(_ itemId: String) {
        guard delivered.remove(itemId) != nil || categories[itemId] != nil else { return }
        log("撤通知 \(itemId)")
        center.removeDeliveredNotifications(withIdentifiers: [prefix + itemId])
        center.removePendingNotificationRequests(withIdentifiers: [prefix + itemId])
        if categories.removeValue(forKey: itemId) != nil { flushCategories() }
    }

    /// 撤掉**本实例上一次运行**留在通知中心里的所有卡片。
    ///
    /// app 被 ⌘Q 之后卡片还在，而它们指向的待办多半已经过期；点开一条上辈子的
    /// 通知最好的结果也只是把 app 打开。插件一上线就清干净，再按当前 inbox 重发
    /// ——留下来的每一条都是此刻仍然成立的。
    ///
    /// 只清**自己前缀**的：同 bundle id 的另一个 worktree 实例可能正跑着，
    /// 清了它的等于替它把用户的待办抹了。
    /// **`done` 必须等它跑完再发新通知**：这是个异步查询，若在它返回之前就
    /// present，那条刚发的会出现在快照里、跟着被清掉——通知消失且不再回来。
    func sweepStaleDeliveries(done: @escaping () -> Void) {
        center.getDeliveredNotifications { [weak self] notifications in
            guard let self else {
                DispatchQueue.main.async(execute: done)
                return
            }
            let stale = notifications.map(\.request.identifier).filter { $0.hasPrefix(self.prefix) }
            DispatchQueue.main.async {
                if !stale.isEmpty {
                    self.center.removeDeliveredNotifications(withIdentifiers: stale)
                    self.log("清掉上一次运行留下的 \(stale.count) 条通知")
                }
                done()
            }
        }
    }

    // MARK: - Dock 角标

    /// **每代 activate 时无条件重设一次**：它自己算得出正确值，不依赖上一代的析构。
    func setBadge(_ count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }

    // MARK: - 私有

    /// `setNotificationCategories` 是**全量替换**，所以这里永远交出整张表。
    private func flushCategories() {
        center.setNotificationCategories(Set(categories.values))
    }

    private func makeCategory(for item: NotifyItem) -> UNNotificationCategory {
        var actions: [UNNotificationAction] = item.actions.map { action in
            var options: UNNotificationActionOptions = []
            // 只有「打开查看」带 foreground。其余按钮按下去 app 一动不动，
            // dsh 那边却已经往下走了——这正是"直接办掉，不打断"。
            if action.isForeground { options.insert(.foreground) }
            if action.isDestructive { options.insert(.destructive) }
            return UNNotificationAction(identifier: action.id, title: action.label, options: options)
        }
        if let input = item.textInput {
            actions.append(UNTextInputNotificationAction(
                identifier: input.id,
                title: "其他…",
                options: [],
                textInputButtonTitle: input.button,
                textInputPlaceholder: input.placeholder))
        }
        return UNNotificationCategory(identifier: item.id,
                                      actions: actions,
                                      intentIdentifiers: [],
                                      options: [.customDismissAction])
    }

    /// 实例指纹：拿 bundle 的绝对路径算一个短 hash。
    ///
    /// 多 worktree 时两个 Dev 实例 bundle id 相同、产物路径不同，这是唯一稳定的
    /// 区分依据（壳那边的 `DashPaths.instanceTag` 同源，但它在壳的 Sources 里，
    /// 不随 SDK 分发，插件够不着，只能自己算）。
    private static func instanceTag() -> String {
        let path = Bundle.main.bundleURL.path
        var hash: UInt64 = 5381
        for byte in path.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return String(format: "%08x", UInt32(truncatingIfNeeded: hash))
    }
}
