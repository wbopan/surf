import AppKit
import SurfSDK
import SwiftUI

/// `toolbar` 贡献槽的**原生渲染路线**：把一条贡献翻译成真正的 `NSToolbarItem`
/// 子类，而不是塞一个 `NSHostingView` 进去。
///
/// ## 为什么这件事值得单独一个文件
///
/// 自定义视图路线（`kind: "view"`）里，AppKit 只看见"一块不透明的矩形"：
/// 宽度、间距、玻璃胶囊的分组、显示模式（Icon Only / Icon and Text / Text Only）、
/// 溢出退让——**全都得我们自己算**，而且算错是静默的（SwiftUI 的 `maxWidth`
/// 贪心一次就能让整项凭空消失，见 CLAUDE.md 踩坑记录）。
///
/// 换成原生子类之后这些一样都不用管：
///
/// | 要的东西 | 原生怎么给 |
/// |---|---|
/// | 段控 | `NSToolbarItemGroup` + `.selectOne` + `.expanded` |
/// | 下拉菜单 | `NSMenuToolbarItem`（indicator、菜单定位、键盘全带） |
/// | 计数徽标 | `NSToolbarItem.badge = .count(n)`（macOS 26） |
/// | 藏起来 | `NSToolbarItem.isHidden`（macOS 15），不用画零尺寸占位 |
/// | 窗口收窄先让谁 | `visibilityPriority` |
/// | 图标还是文字 | `NSToolbar.displayMode`，**用户右键自己决定** |
///
/// ## 活通道：为什么不能靠改 metadata
///
/// 贡献的 metadata 是**拓扑**，一变就重建整条工具栏（签名变了）。而徽标数字、
/// 菜单内容、段控选中态是**流量**，一秒能变好几次——走 metadata 等于每次都把
/// 工具栏拆了重装，按钮会闪、popover 会掉。
///
/// 所以流量走事件总线：贡献者 `emit(surf.toolbar.update, [owner, id, ...patch])`，
/// 本消费方把 patch 记进 `ToolbarItemState` **并**就地改活着的那一项。
/// 记账是必须的——项会因为换代/重建而重造，那时得把状态补回去，
/// 否则热替换一次徽标就没了。

// MARK: - 槽约定判据（新增的三个键）

extension LayoutSplitController {
    /// 活更新的主题。载荷 `["owner": String, "id": String, ...patch]`。
    static let toolbarUpdateTopic = LayoutToolbar.updateTopic
    /// 菜单项被选中时广播的主题。载荷 `["slot", "owner", "id", "itemId"]`。
    static let toolbarMenuSelectTopic = LayoutToolbar.menuSelectTopic
    /// 某一格的菜单**将要打开**。载荷 `["owner", "id"]`。
    ///
    /// 存在的理由只有一个：**上游的导航有前置状态**。`openSubagent` 会校验
    /// 目标是不是 client runtime 自己那份 `subagentsByParent` 里的健康子节点，
    /// 没预热过一律被挡（CLAUDE.md 有这条）。菜单打开到用户点中之间那几百毫秒
    /// 正好够 prime 一轮，所以预热挂在这里而不是挂在"贡献一上墙就预热"——
    /// 后者会让每个开着的会话都无条件去拉一次 catalog。
    static let toolbarMenuOpenTopic = LayoutToolbar.menuOpenTopic
    /// 窗口标识（Mail / Notes 那条裸文字）。载荷 `["title": String, "subtitle": String]`。
    ///
    /// **这是"标题"唯一正确的原生形态**：`window.title` 由 AppKit 画在分隔线
    /// 右边、内容区左缘，字体字重与截断全归系统，`subtitle` 正好在它下面。
    /// 塞进 `NSToolbarItem` 的自定义视图做不到——那条路会给标题套一枚玻璃胶囊，
    /// 让"标识"长得像"按钮"。
    ///
    /// 空标题 = 交回给壳（`titleVisibility` 复位成 `.hidden`）。
    ///
    /// **粘性**：本控制器每换一代都会重订一次，而标识的生产方不会因为我们换代
    /// 就重推一遍。叠加 deinit 里那道"归还标识"的兜底，
    /// 不粘的话窗口会卡在没有标题的透明态，直到用户碰巧切个会话才自愈。
    /// 粘性总线替新订阅者补最后一份，所以这里不需要一条"现在报一次"的反向通道。
    static let windowTitleTopic = LayoutToolbar.windowTitleTopic
    /// 标题栏那条带子的厚度变了。载荷 `["inset": Double]`。
    /// **显示模式一改厚度就变**（Icon and Text 会把工具栏撑高），
    /// 所以这不是装配时量一次的常量。
    static let titlebarMetricsTopic = LayoutToolbar.titlebarMetricsTopic

    /// 用哪条渲染路线。
    ///
    /// 缺省是**推断**而不是 `"view"`：给了 `symbol` 的老贡献自动算 `"button"`，
    /// 观感与行为一个字都不用改。
    static func kind(of contribution: SurfContributions.Contribution) -> String {
        if let explicit = contribution.metadata["kind"] as? String,
           ["view", "button", "menu", "group"].contains(explicit) {
            return explicit
        }
        return contribution.metadata["symbol"] is String ? "button" : "view"
    }

    /// 窗口收窄时谁先让位。缺省 standard。
    static func priority(of contribution: SurfContributions.Contribution)
        -> NSToolbarItem.VisibilityPriority {
        switch contribution.metadata["priority"] as? String {
        case "low": return .low
        case "high": return .high
        default: return .standard
        }
    }

    /// `group` 的分段 / `menu` 的初始菜单。元素是 `[String: Any]`。
    static func items(of contribution: SurfContributions.Contribution) -> [[String: Any]] {
        contribution.metadata["items"] as? [[String: Any]] ?? []
    }

    /// 摘要，只用来判"要不要重建"。**必须把 items 折进去**：段控的分段数变了
    /// 而签名没变，就会出现"数据到了、控件纹丝不动"。
    static func itemsDigest(of contribution: SurfContributions.Contribution) -> String {
        items(of: contribution).map { spec in
            "\(spec["id"] as? String ?? "")~\(spec["label"] as? String ?? "")"
                + "~\(spec["symbol"] as? String ?? "")"
        }.joined(separator: ",")
    }
}

// MARK: - 活状态

/// 一条贡献的"流量"部分。**跟着 key 记账而不是跟着项**：项会被重造
/// （换代、显示模式变化、溢出进出），状态得比项活得久。
struct ToolbarItemState {
    var hidden = false
    var enabled = true
    /// 0 = 不显示徽标。
    var badge = 0
    /// group 的选中下标；-1 = 不选。
    var selectedIndex = -1
    /// 覆盖 metadata 里的 label（如 mode 那格要显示当前 preset 名）。
    var label: String?
    var tooltip: String?
    /// `menu` 路线的菜单内容。元素键：`id` / `label` / `state` / `enabled` / `separator`。
    var menu: [[String: Any]]?
    /// `group` 路线的分段覆盖。改它需要**重建**整项（images/labels 是构造时给的）。
    var items: [[String: Any]]?

    /// 需要重建整项才能生效的那部分的摘要。
    var structuralDigest: String {
        (items ?? []).map { spec in
            "\(spec["id"] as? String ?? "")~\(spec["label"] as? String ?? "")"
                + "~\(spec["symbol"] as? String ?? "")"
        }.joined(separator: ",")
    }

    /// 合并一份 patch。**没提到的键原样保留**——贡献者只推变化的那几个。
    mutating func merge(_ patch: [String: Any]) {
        if let value = patch["hidden"] as? Bool { hidden = value }
        if let value = patch["enabled"] as? Bool { enabled = value }
        if let value = patch["badge"] as? Int { badge = value }
        if let value = patch["selectedIndex"] as? Int { selectedIndex = value }
        if let value = patch["label"] as? String { label = value }
        if let value = patch["tooltip"] as? String { tooltip = value }
        if let value = patch["menu"] as? [[String: Any]] { menu = value }
        if let value = patch["items"] as? [[String: Any]] { items = value }
    }
}

// MARK: - 造项

extension LayoutSplitController {
    /// 把一条贡献造成 `NSToolbarItem`。四条路线，`kind` 选。
    func makeContributionItem(
        _ identifier: NSToolbarItem.Identifier,
        _ contribution: SurfContributions.Contribution
    ) -> NSToolbarItem {
        let state = toolbarStates[contribution.key] ?? ToolbarItemState()
        let label = state.label ?? contribution.metadata["label"] as? String ?? contribution.id
        let item: NSToolbarItem

        // **`menu` block 是另一条路线，优先于 `kind`**：贡献方自己现场建菜单
        // （surf-sidebar 的筛选器走这条）。菜单每次弹出前重建，所以 block 里读
        // 什么状态都是当场的——勾选态不会停在上一次打开时的样子。
        // 数据路线（`kind: "menu"` + `items`）适合内容由投影决定的菜单，
        // block 路线适合内容由贡献方本地状态决定的菜单，两者不互相取代。
        if let build = contribution.metadata["menu"] as? @convention(block) (NSMenu) -> Void {
            item = makeBlockMenuItem(identifier, contribution, build: build)
        } else {
            switch Self.kind(of: contribution) {
            case "group":
                item = makeGroupItem(identifier, contribution, state: state)
            case "menu":
                item = makeMenuItem(identifier, contribution, state: state)
            case "button":
                item = makeButtonItem(identifier, contribution)
            default:
                item = makeViewItem(identifier, contribution)
            }
        }

        item.label = label
        item.paletteLabel = label
        item.toolTip = state.tooltip ?? contribution.metadata["tooltip"] as? String ?? label
        item.visibilityPriority = Self.priority(of: contribution)
        applyState(state, to: item)
        return item
    }

    /// `menu` block 路线：贡献方自己填菜单，本插件只负责给它一身系统皮。
    private func makeBlockMenuItem(
        _ identifier: NSToolbarItem.Identifier,
        _ contribution: SurfContributions.Contribution,
        build: @escaping @convention(block) (NSMenu) -> Void
    ) -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: identifier)
        item.image = (contribution.metadata["symbol"] as? String).flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)
        }
        item.isBordered = true
        item.showsIndicator = false // 图标自己已经说明是筛选器，再加个小箭头只是噪音
        let delegate = ContributionMenuDelegate(build: build)
        toolbarMenuDelegates[contribution.key] = delegate
        let menu = NSMenu()
        menu.delegate = delegate
        item.menu = menu
        return item
    }

    /// 段控。**用 `images:` 那个构造器而不是 `titles:`**：这样
    /// Icon Only 显示图标、Text Only 显示 `labels`，"图标还是文字"就真的
    /// 交回给了系统（和用户的右键菜单）。用 `titles:` 会把它钉死成永远文字。
    private func makeGroupItem(
        _ identifier: NSToolbarItem.Identifier,
        _ contribution: SurfContributions.Contribution,
        state: ToolbarItemState
    ) -> NSToolbarItem {
        let specs = state.items ?? Self.items(of: contribution)
        let labels = specs.map { $0["label"] as? String ?? "" }
        let images = specs.map { spec -> NSImage in
            let symbol = spec["symbol"] as? String ?? "circle"
            let label = spec["label"] as? String
            return NSImage(systemSymbolName: symbol, accessibilityDescription: label)
                ?? NSImage(systemSymbolName: "circle", accessibilityDescription: label)
                ?? NSImage()
        }
        // 空名单也得造一个合法的 group（贡献先到、数据后到是常态）——
        // 造不出来就退回一个空的普通项，别返回 nil 让 AppKit 去猜。
        guard !specs.isEmpty else { return NSToolbarItem(itemIdentifier: identifier) }
        let group = NSToolbarItemGroup(itemIdentifier: identifier,
                                       images: images,
                                       selectionMode: .selectOne,
                                       labels: labels,
                                       target: self,
                                       action: #selector(activateToolbarGroup(_:)))
        // `.automatic` 会在空间紧张时把整组塌成一个菜单——段控塌了就不是段控了，
        // 而且它本来就窄。显式要 expanded。
        group.controlRepresentation = .expanded
        return group
    }

    /// 下拉菜单项。indicator（那个小箭头）、菜单定位、键盘导航全是 AppKit 的。
    private func makeMenuItem(
        _ identifier: NSToolbarItem.Identifier,
        _ contribution: SurfContributions.Contribution,
        state: ToolbarItemState
    ) -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: identifier)
        let label = state.label ?? contribution.metadata["label"] as? String ?? contribution.id
        if let symbol = contribution.metadata["symbol"] as? String {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        }
        item.showsIndicator = true
        item.isBordered = true
        item.menu = buildMenu(contribution, specs: state.menu ?? Self.items(of: contribution))
        return item
    }

    /// 单个图标按钮。macOS 26 的圆形玻璃按钮、按下态、红绿灯对齐全是白送的。
    private func makeButtonItem(
        _ identifier: NSToolbarItem.Identifier,
        _ contribution: SurfContributions.Contribution
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        let label = contribution.metadata["label"] as? String ?? contribution.id
        if let symbol = contribution.metadata["symbol"] as? String {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        }
        item.isBordered = true
        item.target = self
        item.action = #selector(activateToolbarContribution(_:))
        return item
    }

    /// 兜底：托管贡献自己的 SwiftUI 视图。**只给真的没法用原生表达的东西用**
    /// （比如一枚挂着可展开树的面包屑——那是菜单表达不了的形状）。
    private func makeViewItem(
        _ identifier: NSToolbarItem.Identifier,
        _ contribution: SurfContributions.Contribution
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        let hosting = NSHostingView(rootView: contribution.make())

        // `sizing: "dynamic"`：交给 Auto Layout，内容变了宽度自己跟上。
        // **代价是贡献者必须自己守住上限**：SwiftUI 的 `maxWidth` 是贪心的，
        // NSHostingView 会把它当理想宽度顶回来，超过内容区就整项被挤进溢出。
        if Self.sizing(of: contribution) == "dynamic" {
            hosting.translatesAutoresizingMaskIntoConstraints = false
            // **压缩阻力必须降下来**：默认的 750 会让这块矩形在工具栏挤不下时
            // 一步不让，AppKit 于是转而把**别的**项塞进溢出菜单。实测 520pt
            // 宽的窗口上，右边四个控件整组进了 `»`，而占 220pt 的标题纹丝不动
            // ——正好反了。降到 low 之后它会先自己截断。
            hosting.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            // 反过来也别贪：hugging 拉高，免得它把富余空间全占了
            // （那正是 SwiftUI `maxWidth` 贪心的另一半症状）。
            hosting.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            item.view = hosting
            return item
        }

        // 缺省：尺寸当场冻死。内容一变（换代重建）工具栏会自己跳宽度。
        var size = hosting.fittingSize
        if size.width <= 0 { size.width = 32 }
        size.height = min(max(size.height, 1), 28) // 工具栏行高，超了会被裁掉
        hosting.frame = NSRect(origin: .zero, size: size)
        item.view = hosting
        return item
    }

    /// 从规格造一份菜单。`representedObject` 带着 `(key, itemId)`，
    /// 点中时翻译成一条广播——本控制器照例不知道任何菜单项"是干什么的"。
    /// - Parameter isRoot: 只有最外层那份菜单挂"将要打开"的钩子。子菜单是
    ///   同一次打开的一部分，再挂一遍只会把同一个预热重复发出去。
    private func buildMenu(_ contribution: SurfContributions.Contribution,
                           specs: [[String: Any]],
                           isRoot: Bool = true) -> NSMenu {
        let menu = NSMenu()
        // 最外层那份要垫一个 pull-down 标题位，否则第一条贡献进去的项不渲染。
        // 子菜单是普通 submenu，不走 pull-down，不能垫（垫了就真多一行空的）。
        if isRoot { NSMenuToolbarItem.padPullDownTitleSlot(menu) }
        for spec in specs {
            if spec["separator"] as? Bool == true {
                menu.addItem(.separator())
                continue
            }
            let title = spec["label"] as? String ?? ""
            let entry = NSMenuItem(title: title,
                                   action: #selector(selectToolbarMenuItem(_:)),
                                   keyEquivalent: "")
            entry.target = self
            entry.isEnabled = spec["enabled"] as? Bool ?? true
            entry.state = (spec["state"] as? Bool ?? false) ? .on : .off
            entry.representedObject = [
                "key": contribution.key,
                "itemId": spec["id"] as? String ?? "",
            ]
            if let symbol = spec["symbol"] as? String {
                entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            }
            // 次要信息走 attributedTitle 的第二行（菜单项本身不支持 subtitle）。
            if let detail = spec["detail"] as? String, !detail.isEmpty {
                entry.attributedTitle = Self.menuTitle(title, detail: detail)
            }
            // 子菜单：树形 catalog 就靠它。**递归在这里，不在调用方**——
            // 贡献方只管吐一棵嵌套字典，怎么变成 NSMenu 是本控制器的事。
            if let children = spec["submenu"] as? [[String: Any]], !children.isEmpty {
                entry.submenu = buildMenu(contribution, specs: children, isRoot: false)
            }
            menu.addItem(entry)
        }
        // 自己管 enable/disable：不关的话 AppKit 会去问 responder chain，
        // 而我们的 target 不实现 validateMenuItem，结果是全灰。
        menu.autoenablesItems = false
        // **钩子挂在这里，不在 makeMenuItem 里**：菜单内容一变（活通道推来新的
        // `menu`）就会在原地重建一份 NSMenu，挂在项上的那份 delegate 不会跟过来。
        // 挂在造菜单的地方，才保证每一份菜单都带着它。
        if isRoot {
            let relay = ToolbarMenuOpenRelay { [weak self] in
                guard let self else { return }
                self.host.events.emit(Self.toolbarMenuOpenTopic,
                                      ["owner": contribution.owner, "id": contribution.id])
            }
            // `NSMenu.delegate` 是 weak，就地 new 一个当场就没了——
            // menuWillOpen 永远不响，而且不报错。存在控制器名下，随世代走。
            menu.delegate = relay
            menuOpenRelays[contribution.key] = relay
        }
        return menu
    }

    /// 两行菜单标题：正文用菜单字号，第二行小一号走 secondary。
    private static func menuTitle(_ title: String, detail: String) -> NSAttributedString {
        let body = NSFont.menuFont(ofSize: 0)
        let out = NSMutableAttributedString(
            string: title,
            attributes: [.font: body, .foregroundColor: NSColor.labelColor])
        out.append(NSAttributedString(
            string: "\n" + detail,
            attributes: [
                .font: NSFont.menuFont(ofSize: body.pointSize - 3),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        return out
    }
}

// MARK: - 菜单打开的预热钩子

/// `NSMenuToolbarItem` 的菜单将要打开时喊一声。
///
/// 挂 delegate 而不是在 `selectToolbarMenuItem` 里补：**预热是异步的**，
/// 等到用户点中才开始拉数据就已经晚了（那一下点击会被上游挡掉）。
@MainActor
final class ToolbarMenuOpenRelay: NSObject, NSMenuDelegate {
    private let onOpen: () -> Void
    init(onOpen: @escaping () -> Void) { self.onOpen = onOpen }
    nonisolated func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated { onOpen() }
    }
}

// MARK: - 活更新

extension LayoutSplitController {
    /// 订上活通道。**返回 disposable 由控制器自己持有**：控制器随世代走，
    /// 旧代释放时订阅一起没，不会留下一个对着死项发号施令的幽灵。
    func installToolbarUpdates() -> SurfDisposable {
        let updates = host.events.subscribe(Self.toolbarUpdateTopic) { [weak self] payload in
            guard let self,
                  let owner = payload["owner"] as? String,
                  let id = payload["id"] as? String else { return }
            MainActor.assumeIsolated { self.applyToolbarPatch(key: "\(owner)/\(id)", patch: payload) }
        }
        let identity = host.events.subscribe(Self.windowTitleTopic) { [weak self] payload in
            let title = payload["title"] as? String ?? ""
            let subtitle = payload["subtitle"] as? String ?? ""
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.applyWindowIdentity(title: title, subtitle: subtitle) }
            }
        }
        return SurfDisposable {
            updates.dispose()
            identity.dispose()
        }
    }

    /// 把窗口标识摆上去（或撤下来）。
    ///
    /// **`titleVisibility` 归壳所有，这里是借的**：壳开局设 `.hidden`（那时
    /// 没人有标题可显示，露出来就是一个孤零零的 App 名）。我们只在真的拿到
    /// 标题时把它翻开，标题一空就还回去——插件退休后窗口自然回到壳的样子，
    /// 和 web header 自己回来是同一条逃生舱纪律。
    func applyWindowIdentity(title: String, subtitle: String) {
        guard let window = view.window else { return }
        window.title = title
        window.subtitle = subtitle
        window.titleVisibility = title.isEmpty ? .hidden : .visible
        // **标题栏的背景交回给 AppKit。**
        //
        // 壳开局设 `titlebarAppearsTransparent = true`（全出血 WebView 要透过去），
        // 那等于"别画标题栏背景"，于是工具栏背后什么都没有，正文一路顶到窗口
        // 上缘。接管标识之后不需要透了：设回 `false`，AppKit 就画自己的背景和
        // 底边 hairline——**这就是原生工具栏本来的样子**，不用我们仿。
        //
        // 走过的弯路记在这里，免得再来一遍：先在 WebView 上压过一块
        // `NSGlassEffectView`（macOS 26 液态玻璃）。它**确实糊得动网页**
        // （`NSVisualEffectView` 采不到 WKWebView 那层 remote layer 的像素，
        // 它采得到，两个并排实测过），但那是 Mail 滚动时才出现的 scroll edge
        // effect，常驻着看就是一块发光的板子，比朴素的标题栏背景吵得多。
        // **"能做到"不等于"该做"**——工具栏天然有背景，缺的只是没把它打开。
        // **标题栏一直保持透明**，那条带子由页面画
        // （见 surf-nativeify/lib/client.js 的 HEADER 段）。
        //
        // 原生这边三条路全试过了，没有一条能给出"纯模糊、无装饰"：
        // `titlebarAppearsTransparent = false` 给的是**不透明**背景，模糊就没了；
        // `NSVisualEffectView` **采不到** WKWebView 那层 remote layer 的像素
        // （和 NSGlassEffectView 并排实测，它完全不生效）；
        // `NSGlassEffectView` 采得到，但自带一圈边缘高光——那是液态玻璃的
        // 造型语言，不是能关掉的装饰。
        //
        // 而 `backdrop-filter` 与正文同处一个渲染上下文，糊的就是真内容。
        // **这不是退而求其次，是唯一一条能给出纯模糊的路。**
        window.titlebarAppearsTransparent = true
        // 标题行会把标题栏撑高（**有没有 subtitle 差一整行**），页面顶部留白
        // 得跟上。**推迟一拍**：`contentLayoutGuide` 要等这一轮布局跑完才更新，
        // 当场量到的还是上一个高度——症状是副标题出现后正文被压在它底下。
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.publishTitlebarMetrics() }
        }
    }

    private func applyToolbarPatch(key: String, patch: [String: Any]) {
        var state = toolbarStates[key] ?? ToolbarItemState()
        let before = state.structuralDigest
        state.merge(patch)
        toolbarStates[key] = state

        guard let toolbar = ownedToolbar,
              let contribution = toolbarContributions.first(where: { $0.key == key })
        else { return }
        let identifier = NSToolbarItem.Identifier(Self.contributionPrefix + key)
        guard let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == identifier })
        else { return } // 还没上墙（在溢出里、或工具栏正在重建）——状态已经记下了

        // 段控的分段变了：images/labels 是构造时给的，只能整项重造。
        // 这是唯一会"闪"的一条路径，所以只在真的结构变化时走。
        if state.structuralDigest != before {
            toolbar.removeItem(at: index)
            toolbar.insertItem(withItemIdentifier: identifier, at: index)
            return
        }

        let item = toolbar.items[index]
        if let menuItem = item as? NSMenuToolbarItem, let specs = state.menu {
            menuItem.menu = buildMenu(contribution, specs: specs)
        }
        if let label = state.label {
            item.label = label
            item.paletteLabel = label
            item.toolTip = state.tooltip ?? label
        }
        applyState(state, to: item)
    }

    /// 把状态盖到一个具体的项上。造项与活更新共用，**保证两条路径不漂移**。
    private func applyState(_ state: ToolbarItemState, to item: NSToolbarItem) {
        item.isHidden = state.hidden
        item.isEnabled = state.enabled
        item.badge = state.badge > 0 ? NSItemBadge.count(state.badge) : nil
        if let group = item as? NSToolbarItemGroup,
           state.selectedIndex >= 0,
           state.selectedIndex < group.subitems.count {
            group.selectedIndex = state.selectedIndex
        }
    }
}

// MARK: - 回事件

extension LayoutSplitController {
    /// 段控被点了。**带上 `index` 与 `itemId`**：贡献者不必自己数下标，
    /// 也不必假设分段顺序没变过。
    @objc func activateToolbarGroup(_ sender: Any?) {
        guard let group = sender as? NSToolbarItemGroup,
              let contribution = contribution(for: group.itemIdentifier) else { return }
        let index = group.selectedIndex
        let specs = (toolbarStates[contribution.key]?.items) ?? Self.items(of: contribution)
        let itemId = (index >= 0 && index < specs.count)
            ? specs[index]["id"] as? String ?? "" : ""
        // 选中态先记下来：AppKit 已经把它画成选中的了，重建时得补回同一个值，
        // 不然换代一次选中就回到第 0 段。
        var state = toolbarStates[contribution.key] ?? ToolbarItemState()
        state.selectedIndex = index
        toolbarStates[contribution.key] = state

        let topic = contribution.metadata["event"] as? String ?? Self.toolbarActivateTopic
        host.events.emit(topic, [
            "slot": Self.toolbarSlot,
            "owner": contribution.owner,
            "id": contribution.id,
            "index": index,
            "itemId": itemId,
        ])
    }

    /// 菜单项被选了。
    @objc func selectToolbarMenuItem(_ sender: Any?) {
        guard let entry = sender as? NSMenuItem,
              let info = entry.representedObject as? [String: String],
              let key = info["key"],
              let contribution = toolbarContributions.first(where: { $0.key == key })
        else { return }
        host.events.emit(Self.toolbarMenuSelectTopic, [
            "slot": Self.toolbarSlot,
            "owner": contribution.owner,
            "id": contribution.id,
            "itemId": info["itemId"] ?? "",
        ])
    }
}

extension NSMenuToolbarItem {
    /// 给一份**要挂在 `NSMenuToolbarItem` 上的根菜单**垫出 pull-down 的标题位。
    ///
    /// **实测（2026-08-29）：`NSMenuToolbarItem` 弹出的菜单会吞掉第 0 项。**
    /// 它内部是 pull-down 形态的弹出按钮，而 pull-down 的语义就是"第 0 项是按钮
    /// 自己的标题，不进列表"。症状极其误导：贡献方明明填了 N 项，日志里也是 N 项，
    /// 屏幕上却只有后 N-1 项——看上去像数据少了一条，或者像 model 是旧世代的。
    /// （surf-sidebar 的「筛选」菜单就栽在这上面：工作区列表永远少最上面那个。
    /// 更早还被误判成"分区标题在菜单首项不渲染"，其实不限于分区标题，**整个首项**
    /// 都没了。）
    ///
    /// 垫的这一项 **`isHidden = true`**：标题位只看下标、不看显隐，所以它照样顶得住；
    /// 而 `NSMenuToolbarItem` 在溢出/纯文字模式下会把同一份菜单当作
    /// `menuFormRepresentation` 的子菜单来画——那条路是普通 submenu，不吃第 0 项，
    /// 不隐藏的话就会在那儿露出一行空白。
    ///
    /// 只垫最外层。子菜单是普通 submenu，垫了就真多一行。
    static func padPullDownTitleSlot(_ menu: NSMenu) {
        let slot = NSMenuItem()
        slot.isHidden = true
        menu.addItem(slot)
    }
}
