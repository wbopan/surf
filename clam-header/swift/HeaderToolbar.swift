import AppKit
import ClamLayout
import ClamSDK
import Foundation
import Observation

/// 把 `HeaderModel` 的状态推成 clam-layout 认得的工具栏 patch。
///
/// ## 为什么需要这么一层
///
/// 五格里有四格现在是**原生** `NSToolbarItem` 子类（段控 / 两个菜单 / 一个按钮），
/// 不再是 SwiftUI 视图——好处是排版、显示模式、玻璃分组、徽标、溢出全归 AppKit 管，
/// 代价是它们不会自己观察 model。所以得有人盯着 model，把变化翻译成
/// `clam.toolbar.update` 广播。
///
/// ## 盯的方式：`withObservationTracking` 自续期
///
/// `HeaderModel` 是 `@Observable`，但这里没有 SwiftUI 的 body 来建立依赖。
/// `withObservationTracking` 的 `onChange` **只响一次**（而且是在值真正改变
/// *之前*），所以每次响完都要重新武装一遍，并且推迟到下一拍再读——当场读到的
/// 还是旧值。这两点错一个，症状都是"只更新了第一次"。
///
/// ## 只推变化的那几条
///
/// 每条 patch 存一份摘要，一样就不发。工具栏的活更新虽然便宜（就地改属性，
/// 不重建），但 `items` 变化会触发那一项重造——把"没变也发"和"变了才重造"
/// 叠在一起，段控就会在每次投影到来时闪一下。
@MainActor
final class HeaderToolbarSync {
    private let host: ClamHost
    private let model: HeaderModel
    /// 上一次发出去的 patch 摘要，按贡献 id 记。
    private var sent: [String: String] = [:]
    /// 停了就别再续期（插件退休后 model 还活着，但没人该再听它了）。
    private var stopped = false

    init(host: ClamHost, model: HeaderModel) {
        self.host = host
        self.model = model
    }

    /// 开始盯。返回的 disposable **强持有自己**——这是它唯一的主人。
    ///
    /// 写成 `[weak self]` 会安静地毁掉整条通道：`HeaderToolbarSync` 是
    /// `activate` 里的一个局部变量，没人强引用它，函数一返回就被回收，于是只有
    /// `start()` 里那次同步 `push()` 生效过。症状极其误导——**换代时看起来是好的**
    /// （model 从保管箱拿到了种子，第一推就把该显示的都显示了），只有冷启动
    /// （没有种子、第一推全是 `hidden: true`）才露馅：工具栏内容区一片空白，
    /// 而日志里"header 上线 5 格"写得清清楚楚。
    ///
    /// 不构成循环：handle → disposable → sync，sync 不持有 handle。
    func start() -> ClamDisposable {
        arm()
        // 布局那边换代重装工具栏时会喊一声要标识。**必须把去重账擦掉再推**，
        // 否则摘要一样就被当成"没变化"给吞了——而窗口那头其实已经空了。
        let request = host.events.subscribe(LayoutToolbar.windowTitleRequestTopic) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                self.sent["__window"] = nil
                self.pushWindowIdentity()
            }
        }
        return ClamDisposable {
            self.stopped = true
            request.dispose()
        }
    }

    /// 读一遍 model 并推 patch，同时重新武装观察。
    private func arm() {
        guard !stopped else { return }
        withObservationTracking {
            push()
        } onChange: { [weak self] in
            // **必须推迟一拍**：onChange 在值写入之前触发，当场读到的是旧值。
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.arm() }
            }
        }
    }

    // MARK: - 算 patch

    private func push() {
        pushWindowIdentity()
        emit("subagents", subagentsPatch())
        emit("viewTabs", tabsPatch())
        emit("mode", modePatch())
        emit("export", ["hidden": !model.canExport])
    }

    /// 窗口标识：主标题 = 当前会话，副标题 = **改不了的那些事实**。
    ///
    /// 这条分界是设计原则，不是省事：**圆胶囊是"可操作"的承诺**。agent preset
    /// 在会话跑过一轮之后就锁死了，后台任务上游自己也只给看不给停——把它们
    /// 做成按钮，等于承诺一件按下去不会发生的事。只读的事实归副标题，
    /// 工具栏上只留真能按的东西。
    ///
    /// 同理，标识本身也不该是工具栏项：`NSToolbarItem` 会给自定义视图套一枚
    /// 玻璃胶囊，那是按钮的长相。`window.title` 才是 Mail / Notes 那条裸文字，
    /// 位置正好在分隔线右边、内容区左缘。
    private func pushWindowIdentity() {
        guard model.present, let session = model.session, !session.crumbs.isEmpty else {
            emitWindow(title: "", subtitle: "")
            return
        }
        // 末段就是当前会话（面包屑根在前）。
        let title = session.crumbs.last?.title ?? "未命名会话"

        var facts: [String] = []
        // preset：**锁上的才进副标题**。还能改的时候它是工具栏上的一格菜单，
        // 两处同时出现就成了重复。
        if let preset = session.preset, preset.locked {
            facts.append(Self.presetLabel(preset))
        }
        // 后台任务：上游 ui-jobs 自己也只是展示，没有停止动作——只读，进副标题。
        // 子代理计数不进来：那一格的原生徽标已经在报了。
        let jobs = session.jobs
        if jobs.count > 0 {
            facts.append(jobs.running > 0 ? "\(jobs.running)/\(jobs.count) 个任务运行中"
                                          : "\(jobs.count) 个后台任务")
        }
        emitWindow(title: title, subtitle: facts.joined(separator: " · "))
    }

    /// 会话谱系那一格：祖先导航 + 兄弟切换 + 子代理进入，三种交互一个菜单。
    ///
    /// **子代理会话不进侧边栏，这是它们唯一的入口**，所以既没有子代理、
    /// 自己也不在子代理链上的普通会话才整格藏起来。
    private func subagentsPatch() -> [String: Any] {
        guard model.present, let session = model.session else {
            return ["hidden": true, "badge": 0]
        }
        let ancestors = Array(session.crumbs.dropLast())
        let tree = session.subagents
        guard tree != nil || !ancestors.isEmpty else { return ["hidden": true, "badge": 0] }
        let tally = tree?.descendantTally(of: session.id)

        var menu: [[String: Any]] = []
        // 祖先段：可点，向上导航。根在前，与面包屑同序。
        if !ancestors.isEmpty {
            for (index, crumb) in ancestors.enumerated() {
                menu.append([
                    "id": "goto:\(crumb.id)",
                    "label": crumb.title ?? "未命名会话",
                    "symbol": index == 0 ? "house" : "arrow.turn.up.left",
                ] as [String: Any])
            }
            menu.append(["separator": true])
        }
        // 子代理：**整棵树一次给全**（node 半边一次 session.list 就有全树），
        // 深度靠 submenu 递归，零往返——上游 client 那种逐层懒加载在这里不需要。
        if let tree {
            let children = tree.children(of: session.id)
            if children.isEmpty {
                menu.append(["id": "", "label": "没有子代理", "enabled": false])
            } else {
                menu.append(contentsOf: children.map { Self.menuNode($0, tree: tree) })
            }
        }
        let count = tally?.count ?? 0
        return [
            "hidden": false,
            "badge": count,
            "label": "子代理",
            "tooltip": count > 0 ? "\(count) 个子代理" : "会话谱系",
            "menu": menu,
        ]
    }

    /// 一个子代理节点 → 一条菜单项；有后代就递归成子菜单。
    ///
    /// **带子菜单的项自己点不动**（AppKit：有 submenu 的 NSMenuItem 只展开、
    /// 不发 action），所以子菜单第一条得是"打开它自己"——否则中间层的子代理
    /// 就成了只能路过、进不去的死节点。
    private static func menuNode(_ node: HeaderSnapshot.SubagentNode,
                                 tree: HeaderSnapshot.SubagentTree) -> [String: Any] {
        var spec: [String: Any] = [
            "id": "open:\(node.id)",
            // label 覆盖 session 标题（上游："a catalog label overrides the
            // session-summary title"）；都没有就退回 id。
            "label": node.label ?? node.title ?? node.id,
            "detail": nodeDetail(node),
            "symbol": node.running ? "circle.fill" : "circle",
        ]
        let children = tree.children(of: node.id)
        if !children.isEmpty {
            var sub: [[String: Any]] = [
                ["id": "open:\(node.id)", "label": "打开这个子代理",
                 "symbol": "arrow.right.circle"],
                ["separator": true],
            ]
            sub.append(contentsOf: children.map { menuNode($0, tree: tree) })
            spec["submenu"] = sub
        }
        return spec
    }

    /// 菜单项第二行的次要信息。
    private static func nodeDetail(_ node: HeaderSnapshot.SubagentNode) -> String {
        var parts: [String] = []
        if let mode = node.mode { parts.append(mode == "one-shot" ? "一次性" : "可继续") }
        parts.append(node.running ? "运行中" : "已停止")
        if let tokens = node.tokens, tokens > 0 {
            parts.append(HeaderFormatting.tokens(tokens))
        }
        return parts.joined(separator: " · ")
    }

    /// 段控：分段名单跟着页面报上来的 tabs 走，选中态跟着 `active`。
    ///
    /// **`items` 只在 tab 名单真的变了时才会变**——消费方靠它的摘要决定要不要
    /// 重造整项，而切 Chat/Trajectory 只该改 `selectedIndex`。
    private func tabsPatch() -> [String: Any] {
        let visible = model.present && model.tabs.count > 1
        return [
            "hidden": !visible,
            "selectedIndex": model.active,
            "items": model.tabs.map { label in
                [
                    "id": label.lowercased(),
                    "label": label,
                    "symbol": Self.tabSymbol(label),
                ] as [String: Any]
            },
        ]
    }

    /// tab 的图标。**名单是页面给的**（上游随时可能加第三个视图），
    /// 认不出来的一律退到一个中性图标，绝不猜。
    ///
    /// Trajectory 那枚特意选了缩进列表而不是语义上更贴切的曲线路径图
    /// （`point.topleft.down.to.point.bottomright.curvepath`）——后者缩到
    /// 14pt 读起来像个电话听筒，实测过。
    private static func tabSymbol(_ label: String) -> String {
        switch label.lowercased() {
        case "chat": return "text.bubble"
        case "trajectory": return "list.bullet.indent"
        case "diff", "changes": return "plusminus"
        default: return "square.on.square"
        }
    }

    /// mode：**只在还能改的时候才是一格按钮**。
    ///
    /// 会话跑过一轮就锁死（历史里的工具调用是旧 composition 下产生的）。
    /// 锁上之后它退成 `window.subtitle` 里的一段只读文字——见
    /// `pushWindowIdentity`。这比"留一个点得开、但每一项都是灰的菜单"诚实：
    /// 那种菜单是个假按钮，而假按钮正是这轮要清掉的东西。
    private func modePatch() -> [String: Any] {
        guard let preset = model.session?.preset, !preset.locked else {
            return ["hidden": true]
        }
        let current = Self.presetLabel(preset)
        return [
            "hidden": false,
            "enabled": true,
            "label": current,
            "tooltip": "模式：\(current)",
            "menu": preset.options.map { option in
                [
                    "id": option.id,
                    // 坏掉的仍然列出（它占着这个 id），但标出来。
                    "label": option.broken ? "\(option.label)（不可用）" : option.label,
                    "state": option.id == preset.current,
                    "enabled": !option.broken,
                ] as [String: Any]
            },
        ]
    }

    /// **副标题里放不了图标，别再试**：macOS 的 SF Symbols 是图片资源
    /// （走 `NSImage(systemSymbolName:)`），不是可嵌进字符串的字体——实测遍历
    /// 系统字体的两段 PUA，`cube` / `gearshape.2` 这些名字一个都查不到，整个
    /// Plane 15 区间只有 1 个码点有 glyph。而 `window.subtitle` 只吃 `String`，
    /// 连 `NSAttributedString` 都不收。
    ///
    /// 退而求其次的几何字符也试过一排（⬢ ⬡ ◆ ❖ ▣ ⧉ ◈ ⬧）：11pt 下六边形糊成
    /// 一个圆点，空心的站不住，叠方块的细节全丢——没有一个像图标，只像噪点。
    /// 所以副标题就是纯文字。

    private static func presetLabel(_ preset: HeaderSnapshot.Preset) -> String {
        guard let current = preset.current else { return "默认" }
        return preset.options.first { $0.id == current }?.label ?? current
    }

    // MARK: - 发

    /// 窗口标识。和 patch 走同一套去重账本（键用一个不可能撞的贡献 id）。
    private func emitWindow(title: String, subtitle: String) {
        let payload: [String: Any] = ["title": title, "subtitle": subtitle]
        guard let digest = Self.digest(payload), digest != sent["__window"] else { return }
        sent["__window"] = digest
        host.events.emit(LayoutToolbar.windowTitleTopic, payload)
    }

    /// 一条 patch。摘要一样就不发。
    private func emit(_ id: String, _ patch: [String: Any]) {
        var full = patch
        full["owner"] = host.plugin
        full["id"] = id
        guard let digest = Self.digest(full), digest != sent[id] else { return }
        sent[id] = digest
        host.events.emit(LayoutToolbar.updateTopic, full)
    }

    /// 稳定摘要。`sortedKeys` 是关键——字典无序，不排序就会误判成"每次都变了"。
    private static func digest(_ payload: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.sortedKeys])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
