import Foundation

/// 桥上那份 `inbox` 的 Swift 侧形状。
///
/// **一个字段都不解释**：`title` / `body` / `actions` 全是 node 半边组好的，
/// 这边收到什么画什么。加一类通知 = 改 node，这个文件不动。
/// 解不动的字段一律退到中性值而不是抛——协议向前兼容，新 node 配旧壳时
/// 最坏是少显示点东西，不是崩。
struct NotifyItem {
    let id: String
    /// `approval` | `question` | `done` | `error`。**当字符串用，不转枚举**：
    /// node 哪天加一类，旧的 Swift 半身会当成"不认得的一类"照常显示，而不是解码失败。
    let kind: String
    let sessionId: String
    let sessionTitle: String?
    let createdAt: Double
    /// `pending` | `resolved`。
    let state: String
    let outcome: String?
    let title: String
    let body: String
    let actions: [NotifyAction]
    let textInput: NotifyTextInput?
    /// `interrupt`（该响）| `passive`（可以安静些）。
    let importance: String

    var isPending: Bool { state == "pending" }
    /// 通知副行上的会话名。取不到标题就用 id 的短形（`session-<uuid>` 的头 8 位）。
    var sessionLabel: String {
        if let sessionTitle, !sessionTitle.isEmpty { return sessionTitle }
        let bare = sessionId.hasPrefix("session-")
            ? String(sessionId.dropFirst("session-".count)) : sessionId
        return String(bare.prefix(8))
    }

    static func decode(_ raw: [String: Any]) -> NotifyItem? {
        guard let id = raw["id"] as? String, !id.isEmpty,
              let kind = raw["kind"] as? String,
              let sessionId = raw["sessionId"] as? String else { return nil }
        return NotifyItem(
            id: id,
            kind: kind,
            sessionId: sessionId,
            sessionTitle: raw["sessionTitle"] as? String,
            createdAt: (raw["createdAt"] as? NSNumber)?.doubleValue ?? 0,
            state: raw["state"] as? String ?? "pending",
            outcome: raw["outcome"] as? String,
            title: raw["title"] as? String ?? "",
            body: raw["body"] as? String ?? "",
            actions: (raw["actions"] as? [[String: Any]] ?? []).compactMap(NotifyAction.decode),
            textInput: (raw["textInput"] as? [String: Any]).flatMap(NotifyTextInput.decode),
            importance: raw["importance"] as? String ?? "interrupt")
    }
}

/// 通知上的一颗按钮。
struct NotifyAction {
    let id: String
    let label: String
    /// `destructive`（红）| `foreground`（会把 app 拉到前台）| nil（后台办掉，不打断）。
    let style: String?

    /// **只有它把 app 拉到前台。** 其余按钮不带 `.foreground`，按下去 dsh 那边
    /// 就往下走了，app 一动不动——这正是"直接办掉"想要的。
    var isForeground: Bool { style == "foreground" }
    var isDestructive: Bool { style == "destructive" }

    static func decode(_ raw: [String: Any]) -> NotifyAction? {
        guard let id = raw["id"] as? String, let label = raw["label"] as? String else { return nil }
        return NotifyAction(id: id, label: label, style: raw["style"] as? String)
    }
}

/// 通知上的自由输入（`UNTextInputNotificationAction`）。
///
/// **三个字都由 node 下发，这边一个都不自己编**（`label` 是展开输入框那颗按钮的
/// 名字）：界面语言的真相在 node 半边那张 `lib/strings.js`，这里编一个兜底词就是
/// 在中文界面上冒出英文、或者反过来。所以 `label` / `button` 缺一个就整条不解
/// ——其余按钮照画，只是少了「其他…」那一颗，比画一颗语言不对的强。
struct NotifyTextInput {
    let id: String
    /// 展开输入框那颗按钮的名字（`UNTextInputNotificationAction.title`）。
    let label: String
    let placeholder: String
    /// 输入框右边那颗提交按钮。
    let button: String

    static func decode(_ raw: [String: Any]) -> NotifyTextInput? {
        guard let id = raw["id"] as? String,
              let label = raw["label"] as? String, !label.isEmpty,
              let button = raw["button"] as? String, !button.isEmpty else { return nil }
        return NotifyTextInput(id: id,
                               label: label,
                               placeholder: raw["placeholder"] as? String ?? "",
                               button: button)
    }
}

/// Swift 侧用得着的那几项设置。其余项（哪一类通不通知、按钮给不给）在 node 侧
/// 就已经生效了——那边直接不把这条 item 放进 inbox，这边根本看不到。
struct NotifySettings {
    var enabled = true
    /// 四个分类开关。**它们在这一侧生效**——node 那边照单全收，关掉的只是打扰，
    /// 侧边栏那枚「待处理」胶囊照样看得见（见 lib/inbox.js 顶部那条纪律）。
    var approval = true
    var question = true
    var done = true
    var error = true
    var sound = true
    var doneWhenForeground = false
    var badgeIncludesDone = false

    static func decode(_ raw: [String: Any]) -> NotifySettings {
        var settings = NotifySettings()
        settings.enabled = raw["enabled"] as? Bool ?? true
        settings.approval = raw["approval"] as? Bool ?? true
        settings.question = raw["question"] as? Bool ?? true
        settings.done = raw["done"] as? Bool ?? true
        settings.error = raw["error"] as? Bool ?? true
        settings.sound = raw["sound"] as? Bool ?? true
        settings.doneWhenForeground = raw["doneWhenForeground"] as? Bool ?? false
        settings.badgeIncludesDone = raw["badgeIncludesDone"] as? Bool ?? false
        return settings
    }
}

/// 用户此刻的注意力所在。**只有 app 进程知道这三件事**，这也是"要不要打扰"
/// 必须在 Swift 侧判的全部理由。
struct NotifyFocus {
    /// `NSApp.isActive`。
    var appActive = false
    /// 主窗口是 key **且**没有被别的窗口整个盖住（`occlusionState`）。
    var windowVisible = false
    /// 页内桥报上来的当前会话（`surf.page.currentSession`）。
    var currentSessionId: String?

    /// 你正看着这条待办所属的会话吗。
    func isLooking(at item: NotifyItem) -> Bool {
        appActive && windowVisible && currentSessionId == item.sessionId
    }
}

/// 打扰判据。
///
/// 这张表是整个插件最该被质问的地方，所以它是一个纯函数、没有任何副作用，
/// 输入全在参数里：
///
/// | 情况 | approval / question | done | error |
/// |---|---|---|---|
/// | 你正看着它 | 不发，已发的撤下 | 不发，撤下 | 不发，撤下 |
/// | 在 app 里但看着别的会话 | **发** | 看 `doneWhenForeground` | 发 |
/// | app 在后台 | 发 | 发 | 发 |
///
/// 第二行是与旧实现（已废弃的 `EventsBridge.swift`）唯一的、也是最重要的分歧：
/// 旧的判据只有 `!NSApp.isActive`，于是"你盯着 A 会话时 B 会话要审批"——
/// 最常见的那个场景——一条通知都收不到。
enum NotifyPolicy {
    static func shouldPresent(_ item: NotifyItem,
                              focus: NotifyFocus,
                              settings: NotifySettings) -> Bool {
        guard settings.enabled, item.isPending else { return false }
        // 已经在看了就别再响一声——web UI 的审批面板此刻就在他眼前。
        if focus.isLooking(at: item) { return false }
        // **四个分类开关在这里生效，不在 node 那边。** node 照单全收（侧边栏那枚
        // 「待处理」胶囊读的是同一份），关掉的只是打扰。见 lib/inbox.js 顶部。
        switch item.kind {
        case "approval":
            return settings.approval
        case "question":
            return settings.question
        case "error":
            return settings.error
        case "done":
            guard settings.done else { return false }
            return focus.appActive ? settings.doneWhenForeground : true
        default:
            // 将来 node 新加的任何一类：没有对应开关就照发。
            return true
        }
    }

    /// 该不该把已经发出去的那条撤下来。
    ///
    /// 只有一条判据：**人看到了**。别的撤下时机（别处答了、会话又跑起来了）
    /// 由 node 侧从 inbox 里移除或翻成 resolved 来表达，不在这里判。
    static func shouldWithdraw(_ item: NotifyItem, focus: NotifyFocus) -> Bool {
        !item.isPending || focus.isLooking(at: item)
    }

    /// 该告诉 node「这条可以从待办里划掉了」吗。
    ///
    /// **只有"看一眼就完"的那两类**：人正盯着那个会话，回合结束与出错就算看见了。
    /// 待批准与待回答不在此列——那两类要真答了才算完，光看着不作数。
    ///
    /// 为什么不能只撤屏幕上的通知：侧边栏那枚「待处理」胶囊读的是 node 那份待办
    /// （经 `surfPending`），通知撤了而待办还在的话，胶囊会一直亮着一条用户
    /// 明明已经看过的行。
    static func shouldClear(_ item: NotifyItem, focus: NotifyFocus) -> Bool {
        guard item.isPending, item.kind == "done" || item.kind == "error" else { return false }
        return focus.isLooking(at: item)
    }

    /// Dock 角标的数目。0 表示不显示角标。
    static func badgeCount(_ items: [NotifyItem], settings: NotifySettings) -> Int {
        guard settings.enabled else { return 0 }
        return items.filter { item in
            guard item.isPending else { return false }
            switch item.kind {
            case "approval", "question": return true
            default: return settings.badgeIncludesDone
            }
        }.count
    }
}
