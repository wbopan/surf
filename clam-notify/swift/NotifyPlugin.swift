import AppKit
import ClamLayout
import ClamSDK
import Foundation
import SwiftUI

/// 插件入口。壳按 image handle `dlsym` 取这个符号。
@_cdecl("clam_plugin_entry")
public func clam_plugin_entry() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(NotifyPlugin()).toOpaque()
}

/// clam-notify 的 Swift 半身：把 node 推下来的待办变成 macOS 原生通知。
///
/// **不占任何槽，也不贡献任何界面**——它只跟系统通知中心和 Dock 角标打交道，
/// 缺席时什么都不会缺，这也是它敢在 `clam-layout` 之后挂载的原因。
///
/// 这半边只做四件事：
/// 1. 判断**要不要打扰**（`NotifyPolicy`，输入是"用户此刻在看什么"）；
/// 2. 发通知、撤通知、设角标；
/// 3. 把用户在通知上的决定原样发回 node（`act` 动作），由那边翻成 wire；
/// 4. 把"人正看着哪个会话"报给 node（`focus` 动作）——「跑完了」「出错」那两类
///    看见了就该从待办里消失，而侧边栏那枚「待处理」胶囊读的是 node 那份。
///
/// 一条业务判断都不做：哪些事值得通知、通知写什么字、给哪几颗按钮，
/// 全是 node 半边组好的（`lib/inbox.js`）。
final class NotifyPlugin: ClamPlugin {
    /// **返回 presenter 而不是 handle**，这是本插件与别家最大的结构差异，
    /// 也是踩过的第一个坑：
    ///
    /// `activate` 的返回值是壳持有的**唯一**强引用锚点。占槽的插件（sidebar）
    /// 之所以不用操心，是因为它的 model 被注册进 registry 的视图闭包捕获着，
    /// 顺着 handle 里那个 disposable 间接活下来。**不占槽的插件没有这条链**
    /// ——第一版返回 handle，presenter 在 activate 返回的那一瞬就被释放，
    /// 于是"通知线上线"照常打印，然后所有异步回调里的 `weak self` 全是 nil：
    /// 授权请求没有结果、桥推下来的 inbox 没人接、一条通知都不会发，
    /// **而日志里一个字的异常都没有**。
    ///
    /// 所以这里反过来：壳持有 presenter，presenter 持有 handle，
    /// handle 持有全部 disposable。壳一松手，整条链按序拆掉。
    func activate(host: ClamHost) -> AnyObject? {
        // 会话展示面缺席（clam-layout 没装配）**不是致命的**：通知照发照撤，
        // 只是点了之后跳不过去。与 sidebar 不同——那边缺了面就没有存在意义。
        let surface = host.objects.object(ClamObjects.Key.conversationSurface)
            as? ClamConversationSurface
        if surface == nil {
            host.log("保管箱里没有会话展示面，通知仍然会发，但点击不会跳转")
        }
        let presenter = NotifyPresenter(host: host, surface: surface)
        presenter.start()
        return presenter
    }
}

/// 装配与状态。**每代一个新实例**，跨代要活的东西一律放保管箱。
@MainActor
final class NotifyPresenter {
    /// 保管箱：最后一份 inbox（`NSDictionary`，系统类型跨代安全）。
    private static let inboxKey = "clam.notify.inbox"
    /// 保管箱：已经发出去的那些通知的内容签名（`NSDictionary`）。
    /// 不存的话，每次热替换都会把在屏的通知**重发一遍**——响一声、跳一下，
    /// 改一行 Swift 就来一次，很快就会让人把通知关掉。
    private static let presentedKey = "clam.notify.presented"
    /// 保管箱：本进程是否已经清过"上一次运行的残留"（`NSNumber`）。
    ///
    /// **判据必须是"本进程第一次装载"，不是"本代第一次"**——热替换是同一个进程，
    /// 上一代刚发出去的通知此刻仍然有效。第一版没分清，于是每改一行 Swift 就把
    /// 屏幕上的通知全清掉，而恢复出来的 presented 表又说"发过了"，
    /// 结果通知**消失且不会回来**。保管箱随进程存活、随进程消失，正是这个判据。
    private static let sweptKey = "clam.notify.swept"
    /// 保管箱：页内桥最后报上来的当前会话（`NSString`）。
    /// 页面只在**切换时**报，新一代拿不到当前值；不存的话热替换后的头一分钟里
    /// "你正看着它"这条判据是瞎的。
    private static let currentSessionKey = "clam.notify.currentSession"

    private let host: ClamHost
    private let surface: ClamConversationSurface?
    private let center: NotifyCenter
    /// 本代所有注册与订阅。**由 presenter 持有**（见 `NotifyPlugin.activate` 的注释）。
    private let handle = ClamPluginHandle()

    private var items: [NotifyItem] = []
    private var settings = NotifySettings()
    private var focus = NotifyFocus()
    /// item.id → 已发出去那一版的内容签名。
    private var presented: [String: String] = [:]
    /// 授权拿到、上一次运行的残留清完之前，**一条都不发**。
    ///
    /// 没有这道门的话会发两遍：桥推下来的 inbox 比授权回调先到（前者是本进程内
    /// 的一次 WS 往返，后者要问系统），于是 present 一轮；随后授权回调把
    /// presented 清空、再 present 一轮。屏幕上是同一条，但**响两声**。
    private var ready = false

    init(host: ClamHost, surface: ClamConversationSurface?) {
        self.host = host
        self.surface = surface
        self.center = NotifyCenter(log: { host.log($0) })
    }

    func start() {
        // 先捡回上一代的状态，再做任何事——否则下面第一次 reconcile 会把在屏的
        // 通知当成"没发过"重发一遍。
        presented = (host.objects.object(Self.presentedKey, as: NSDictionary.self)
            as? [String: String]) ?? [:]
        focus.currentSessionId = host.objects.object(Self.currentSessionKey, as: NSString.self)
            as String?
        if let seed = host.objects.object(Self.inboxKey, as: NSDictionary.self) as? [String: Any] {
            apply(inbox: seed, reconcile: false)
        }
        recomputeFocus()

        center.requestAuthorization { [weak self] status in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard status == .authorized || status == .provisional else {
                    self.host.log("通知未获授权（\(NotifyCenter.describe(status))），"
                        + "系统横幅不会出现；待办仍然会进侧边栏那枚「待处理」胶囊")
                    return
                }
                // 授权到手才清上一次运行的残留：没授权时这个调用没有意义。
                // 一个进程只清一次（见 `sweptKey`）。
                guard self.host.objects.object(Self.sweptKey) == nil else {
                    self.ready = true
                    self.reconcile()
                    return
                }
                self.host.objects.setObject(Self.sweptKey, NSNumber(value: true))
                self.presented = [:]
                self.center.sweepStaleDeliveries { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.ready = true
                        self.reconcile()
                    }
                }
            }
        }

        center.installHooks(host: host, handle: handle, present: { [weak self] itemId in
            // 通知已经到了系统手上，而 app 此刻在前台——**再判一次**。
            // 发出去到显示出来之间隔着几十毫秒，用户完全可能在这期间切到了
            // 那个会话；这一判把"看到就消失"从"事后撤下"提前成"根本不弹"。
            MainActor.assumeIsolated {
                guard let self, let item = self.items.first(where: { $0.id == itemId }) else {
                    return ["banner", "list"]  // 不认得的通知（上一进程留下的）：照常显示
                }
                guard NotifyPolicy.shouldPresent(item, focus: self.focus, settings: self.settings) else {
                    return []
                }
                return self.settings.sound && item.importance == "interrupt"
                    ? ["banner", "list", "sound"] : ["banner", "list"]
            }
        }, onOpen: { [weak self] _, sessionId in
            MainActor.assumeIsolated { self?.open(sessionId: sessionId) }
        }, onAction: { [weak self] itemId, actionId, text in
            MainActor.assumeIsolated { self?.act(itemId: itemId, actionId: actionId, text: text) }
        })

        // 桥下行两条频道（协议见 lib/index.js 顶部注释）。
        host.bridge.onMessage { [weak self] channel, payload in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch channel {
                case "inbox":
                    self.apply(inbox: payload, reconcile: true)
                case "error":
                    self.host.log("node 侧动作失败（\(payload["action"] ?? "?")）："
                        + "\(payload["message"] ?? "未知原因")")
                default:
                    break // 未知频道忽略（协议向前兼容）
                }
            }
        }.kept(by: handle)

        // 当前会话：页内桥 → 壳 → EventBus。**这是"要不要打扰"最重要的那个输入。**
        host.events.subscribe(ClamEventBus.Topic.pageCurrentSession) { [weak self] payload in
            MainActor.assumeIsolated {
                guard let self, let id = payload["id"] as? String else { return }
                self.noteLooking(at: id)
                self.reconcile()
            }
        }.kept(by: handle)

        // 焦点的另外两个输入。四条系统通知都订上：少订一条就会出现
        // "人明明在看着，通知却不撤"这种让人不信任的行为。
        for name: Notification.Name in [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didChangeOcclusionStateNotification,
        ] {
            let token = NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.recomputeFocus()
                        self?.reconcile()
                    }
                }
            handle.keep(ClamDisposable {
                NotificationCenter.default.removeObserver(token)
            })
        }

        // 每代都要问一次全量：node 半边只在变化时推，不给新连上来的世代补发
        // （与桥不给壳补发 `app-build` 同一条纪律——补发的判断归请求方）。
        host.bridge.send(action: "inbox")

        host.log("通知线上线（种子 \(items.count) 条，已请求全量）")
    }

    // MARK: - 数据

    private func apply(inbox payload: [String: Any], reconcile shouldReconcile: Bool) {
        let rows = payload["items"] as? [[String: Any]] ?? []
        items = rows.compactMap(NotifyItem.decode)
        if let raw = payload["settings"] as? [String: Any] {
            settings = NotifySettings.decode(raw)
        }
        // 先落箱再上屏：下一代取的是这一份。
        host.objects.setObject(Self.inboxKey, payload as NSDictionary)
        if shouldReconcile { reconcile() }
    }

    private func recomputeFocus() {
        focus.appActive = NSApp.isActive
        // 「看得见」= 是 key window **且**没有被别的窗口整个盖住。少了后半句的话，
        // 把别的 app 全屏盖在上面时通知会被当成"你已经看到了"而撤掉。
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        focus.windowVisible = window?.isKeyWindow == true
            && window?.occlusionState.contains(.visible) == true
    }

    /// 把"应该在屏幕上的通知"与"实际在屏幕上的通知"对齐。
    ///
    /// 全量比对，没有增量——一次 reconcile 是几十条 item 的纯遍历，
    /// 而增量协议要两边对账，代价高得多也脆得多（与桥上只有全量 snapshot 同理）。
    private func reconcile() {
        // 角标不需要授权，也不该等 sweep——它就是"有几件事等着你"，
        // 通知发不发得出来跟它没关系。
        center.setBadge(NotifyPolicy.badgeCount(items, settings: settings))

        // 「看一眼就完」的两类：人正盯着那个会话，就让 node 把它从待办里划掉。
        // **放在 `ready` 门之前**——这件事跟通知授权没关系，即使一条通知都发不出去，
        // 侧边栏那枚胶囊也该准。node 侧 `onFocus` 是幂等的（删不掉就不广播），
        // 所以重复发不会来回抖。
        var cleared: Set<String> = []
        for item in items where NotifyPolicy.shouldClear(item, focus: focus) {
            guard cleared.insert(item.sessionId).inserted else { continue }
            host.bridge.send(action: "focus", payload: ["sessionId": item.sessionId])
        }

        guard ready else { return }
        var next: [String: String] = [:]
        for item in items {
            let signature = signatureOf(item)
            if NotifyPolicy.shouldWithdraw(item, focus: focus) {
                center.withdraw(item.id)
                continue
            }
            guard NotifyPolicy.shouldPresent(item, focus: focus, settings: settings) else {
                // 不该发，但也不必撤（可能只是"这一类关掉了"）——保持现状。
                if let old = presented[item.id] { next[item.id] = old }
                continue
            }
            // 内容变了就重发（同 id 是替换语义，不会变成两条）。典型场景：
            // 设置里关掉「直接批准」之后，在屏那条的按钮该跟着变。
            if presented[item.id] != signature {
                center.present(item, settings: settings)
            }
            next[item.id] = signature
        }
        // 上一份里有、这一份里没有的 = node 把它从 inbox 拿掉了（如会话又跑起来，
        // "回合结束"就过期了）。撤。
        for id in presented.keys where next[id] == nil {
            center.withdraw(id)
        }
        presented = next
        host.objects.setObject(Self.presentedKey, presented as NSDictionary)
    }

    /// 记下用户此刻在看哪个会话。
    ///
    /// **只管记，不管清**：告诉 node「这条可以划掉了」在 `reconcile` 里做。
    /// 两处分开是因为触发条件不是"切换会话"而是"正看着 + 有那么一条"
    /// ——待办可能是在你已经盯着那个会话之后才出现的（最常见的场景：你看着它跑，
    /// 它跑完了），那一刻当前会话一个字都没变。早先把发送写在这儿，
    /// 于是恰好这个最常见的场景永远清不掉。
    private func noteLooking(at sessionId: String) {
        guard !sessionId.isEmpty else { return }
        focus.currentSessionId = sessionId
        host.objects.setObject(Self.currentSessionKey, sessionId as NSString)
    }

    /// 内容签名：变了就该重发。**不含 createdAt**（那玩意每次组 item 都在变，
    /// 含进去就是每推一次全量都重发一遍）。
    private func signatureOf(_ item: NotifyItem) -> String {
        let actions = item.actions.map { "\($0.id):\($0.label):\($0.style ?? "")" }
            .joined(separator: "|")
        return "\(item.state)/\(item.title)/\(item.body)/\(actions)/\(item.textInput?.id ?? "")"
    }

    // MARK: - 用户动作

    /// 点了通知本体或「打开查看」：把窗口带到前台、跳到那个会话。
    private func open(sessionId: String) {
        NSApp.activate()
        let window = NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.isVisible })
        window?.makeKeyAndOrderFront(nil)
        guard !sessionId.isEmpty else { return }
        surface?.selectSession(id: sessionId)
        // 跳过去 = 人看到了。焦点的重算要等窗口真的成为 key，所以推迟一拍
        // ——立刻算的话 `NSApp.isActive` 还是老的，那条通知会留在屏幕上。
        noteLooking(at: sessionId)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.recomputeFocus()
                self?.reconcile()
            }
        }
    }

    /// 按了别的按钮：原样发回 node，由那边翻成 `respond()`。
    ///
    /// **不在这里乐观翻牌**：真相在 dsh 侧，node 答完会推一份新的 inbox 下来，
    /// 那时这条自然消失。先撤后答的话，万一答失败（别人先答了、参数被拒），
    /// 屏幕上什么都没了而侧边栏还亮着一条待办，人只会更困惑。
    private func act(itemId: String, actionId: String, text: String?) {
        var payload: [String: Any] = ["id": itemId, "actionId": actionId]
        if let text, !text.isEmpty { payload["text"] = text }
        host.bridge.send(action: "act", payload: payload)
    }
}
