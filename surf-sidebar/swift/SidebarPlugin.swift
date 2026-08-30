import AppKit
import SurfLayout
import SurfSDK
import Foundation
import SwiftUI

/// 插件入口。壳按 image handle `dlsym` 取这个符号。
@_cdecl("surf_plugin_entry")
public func surf_plugin_entry() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(SidebarPlugin()).toOpaque()
}

/// surf-sidebar 的 Swift 半身：占 surf-layout 的 `sidebar` 槽。
///
/// **数据面住在 node 半边**（M10）：会话与工作区的镜像、写操作、事件订阅全在
/// `lib/index.js`，经桥推 JSON 下来。这半边只做三件事——把投影渲染成列表、
/// 把用户动作发上去、把选中状态收敛。
///
/// 为什么数据面不在这儿：壳与共享 module 随 app bundle 冻结、用户改不了，
/// 而会话/工作区的 wire 模型是随 dsh 版本演进最快的那一层——层放错了。
/// node 半边住在 dsh 进程里，随 npm 可更新，且 Swift 插件怎么热替换它都不动。
///
/// **跨代不闪列表**：每代把收到的最后一份 snapshot 原样（`NSDictionary`，
/// 系统类型跨代安全）存进保管箱；下一代 activate 时先拿它渲染，再请求 fresh
/// 全量，到了就替换。**箱里绝不放本 module 定义的类型**——新旧两代的同名类型
/// 互不认识，取出来 `as?` 只会安静地得到 nil（M2 断言 4）。
final class SidebarPlugin: SurfPlugin {
    /// 保管箱里那份最后的快照（`NSDictionary`）。
    private static let snapshotKey = "surf.sidebar.snapshot"

    func activate(host: SurfHost) -> AnyObject? {
        guard let surface = host.objects.object(SurfObjects.Key.conversationSurface)
                as? SurfConversationSurface else {
            host.log("保管箱里没有会话展示面，sidebar 缺席（surf-layout 没装配？）")
            return nil
        }

        let handle = SurfPluginHandle()

        // 先用上一代留下的快照开局（没有就是空列表），换代时列表不闪。
        let seed = host.objects.object(Self.snapshotKey, as: NSDictionary.self)
            .flatMap { $0 as? [String: Any] }
            .flatMap(SidebarSnapshot.decode) ?? .empty

        // 界面语言。真相是 dsh 的 `locale` 设置，壳把它当粘性事件广播
        // （`surf.locale`），所以这一句订上的瞬间就已经是当前值——初值只兜住
        // "壳还没发过"那一刻（决议链见 docs/archive/surf-i18n-plan.md §3）。
        let locale = SurfLocaleStore(bus: host.events)

        let model = AppSidebarModel(snapshot: seed, bridge: host.bridge,
                                    surface: surface, locale: locale,
                                    log: { host.log($0) })
        // 选中高亮活过热替换：真相在 dsh 侧（页面会把 currentSession 报回来），
        // 这里存的只是"页面还没报之前先亮哪一行"的装饰状态。
        model.selectedSessionId = host.store.string("selectedSessionId")
        model.onSelectionChange = { host.store.setString("selectedSessionId", $0) }

        // 桥下行三条频道（协议见 lib/index.js 顶部注释）。
        host.bridge.onMessage { [weak model] channel, payload in
            guard let model else { return }
            switch channel {
            case "snapshot":
                guard let snapshot = SidebarSnapshot.decode(payload) else {
                    host.log("收到解不动的 snapshot，保留上一份")
                    return
                }
                // 先落箱再上屏：下一代取的是这一份。
                host.objects.setObject(Self.snapshotKey, payload as NSDictionary)
                model.apply(snapshot: snapshot)

            case "forked":
                // 分叉完成：切到子会话（与 web 的 fork().then(open) 同序）。
                guard let childId = payload["sessionId"] as? String else { return }
                model.activate(sessionId: childId)

            case "error":
                // 载荷是结构化的：动作 id + 可选的原因码 + 上游那句原话。
                // **一个显示文案都不从 node 来**（计划 §8-4），组句在 `L` 里。
                model.reportFailure(action: payload["action"] as? String ?? "",
                                    code: payload["code"] as? String,
                                    message: payload["message"] as? String ?? "")

            default:
                break // 未知频道忽略（协议向前兼容，同桥的纪律）
            }
        }.kept(by: handle)

        // 页内桥上报的当前会话（壳收到 WKScriptMessage 后转成 EventBus 事件）。
        host.events.subscribe(SurfEventBus.Topic.pageCurrentSession) { payload in
            guard let id = payload["id"] as? String else { return }
            model.pageDidSelect(sessionId: id)
        }.kept(by: handle)

        // 筛选 / 视图状态。列表（SwiftUI）与工具栏那枚菜单（AppKit）共读这一份。
        let filter = SidebarFilterState()

        // 壳菜单快捷键的执行端（⌘⇧[ ] / ⌘1-9 / ⌘⌥A / ⌘⇧⌫ / ⌘⌥R / ⌥⌘F）。
        // 壳只喊命令，这里才有投影顺序、选中态与筛选——能力在谁家，命令就归谁接。
        // shortcuts 被订阅闭包强持有，订阅由 handle 按住，这就是它的生命周期锚。
        let shortcuts = SidebarShortcuts(model: model, filter: filter,
                                         log: { host.log($0) })
        host.events.subscribe(SurfEventBus.Topic.menuCommand) { payload in
            guard let command = payload["command"] as? String else { return }
            MainActor.assumeIsolated {
                shortcuts.handle(command: command, payload: payload)
            }
        }.kept(by: handle)

        host.register(slot: LayoutSlots.sidebar) {
            AnyView(SidebarView(model: model, filter: filter, surface: surface, locale: locale))
        }.kept(by: handle)

        // 工具栏的「筛选」。**surf-layout 那格原本是「新建会话」**——新建的入口
        // 还有三个（⌘N、分组头的加号、页面自己的按钮），而"哪些工作区显示、
        // 归档要不要露出来"没有别的地方可放，这一格给了它更值。
        //
        // 走 `menu` 路线拿的是 `NSMenuToolbarItem`：玻璃按钮 + 系统菜单，
        // 勾选态、键盘操作、深浅色、缩到窄窗口时的溢出全归系统。
        // 设计稿里画的是 NSPopover，落地改成菜单——贡献槽递不出锚点视图，
        // 而"一串带勾的开关"本来就是菜单的母语。
        let buildMenu: @convention(block) (NSMenu) -> Void = { menu in
            MainActor.assumeIsolated {
                Self.populate(menu: menu, model: model, filter: filter)
            }
        }
        // 菜单的内容是**每次弹出前**现填的（`populate` 读 `model.strings`），
        // 所以那一半不用管；要重新贡献的是 `label` / `tooltip` 这些**拓扑键**
        // ——它们只在注册那一刻被读走一次，label 一变整条工具栏重建。
        //
        // **撤销句柄存在闭包捕获的这个 var 里，不 `.kept(by: handle)`**：那样会让
        // 订阅闭包捕获 `handle`，而订阅本身又由 handle 按住——一个谁也放不掉谁的环，
        // 旧世代永远退不了休（它还会在下次换语言时拿陈旧的视图工厂重新贡献）。
        // 现在的链是：handle → 订阅 disposable；总线 → 订阅闭包 → 这个 var。
        // handle 一析构，订阅撤销、闭包释放、这份 disposable 跟着析构，
        // 那时若已被新世代覆盖则 token 对不上、空转（见 SurfContributions.register）。
        var filterContribution: SurfDisposable?
        let contributeFilter: (L) -> Void = { strings in
            // 先注册新的（就地覆盖同 `(owner, id)`）再撤旧句柄：反过来会先把
            // 自己那条摘掉，工具栏闪一下少一格。旧句柄此刻 token 已对不上，
            // `dispose()` 是空操作——写出来只为让"谁负责撤销"一眼可见。
            let previous = filterContribution
            filterContribution = host.contribute(
                to: LayoutToolbar.slot,
                id: "filter",
                order: -100,
                // 键名不手抄：拼错一个字母是静默退化（按钮照样上墙，只是
                // 丢了 tooltip 或菜单），`ToolbarSpec` 让它变成编译错误。
                metadata: ToolbarSpec(
                    label: strings.filterLabel,
                    symbol: "line.3.horizontal.decrease",
                    tooltip: strings.filterTooltip,
                    menu: buildMenu
                ).metadata()) {
                // 兜底视图：系统认不出那个 SF Symbol 时才用得上。菜单路线走不了，
                // 退化成"把筛选清空"这一个动作——比一颗点不动的按钮有用。
                AnyView(
                    Button {
                        MainActor.assumeIsolated {
                            filter.hiddenGroups = []
                            filter.showArchived = false
                            filter.hideEmptyWorkspaces = true
                            filter.mode = .workspace
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(strings.clearFilters)
                    .accessibilityIdentifier("toolbar.sidebarFilter")
                )
            }
            previous?.dispose()
        }
        // 先按当前值贡献一次（壳万一没发过那条粘性事件，这枚按钮也得在）。
        contributeFilter(L(locale.current))

        // 换语言就**重新贡献**同一条（`(owner, id)` 相同 = 就地覆盖，位置不变）。
        // 这是既有机制：拓扑键变了本来就该整条重建，绕过它去原地改 label 是错的。
        // 这里不走 `withObservationTracking`（静默死亡坑）——工具栏不在 SwiftUI 里，
        // 直接订总线那条粘性主题最省事，`SurfLocaleStore` 那份留给视图用。
        host.events.subscribe(SurfEventBus.Topic.locale) { payload in
            guard let raw = payload["locale"] as? String,
                  let next = SurfLocale(rawValue: raw) else { return }
            MainActor.assumeIsolated { contributeFilter(L(next)) }
        }.kept(by: handle)

        // 请求一份 fresh 全量。**每代都要问**：node 半边只在数据变化时推，
        // 不为新连上来的世代补发（补发逻辑归请求方，与桥不给壳补发 app-build 同理）。
        host.bridge.send(action: "snapshot")

        host.log("sidebar 上线（种子快照 v\(seed.version)，已请求全量）")
        return handle
    }

    /// 现场填「筛选」菜单。**每次弹出前重建**（`ContributionMenuDelegate`），
    /// 所以这里读到的分组、勾选态都是当场的。
    ///
    /// 三段：分组方式 / 工作区 / 全局开关，两条分隔线隔开，末尾一条常显的「清除筛选」。
    ///
    /// **分区标题走原生 `NSMenuItem.sectionHeader(title:)`**（macOS 14+），不自绘。
    /// 这里曾经写着"这一段不加分区标题"，那是三枚胶囊还在的时候——胶囊拿掉之后
    /// 「按时间」只剩这一个去处，不写清楚"这两行是分组方式、下面那些是工作区"
    /// 就成了一列意义不明的勾。
    ///
    /// 另有一条旧结论要留着：**`NSMenuToolbarItem` 走 pull-down 语义，把第 0 项
    /// 当自己的标题吃掉**（症状是工作区列表永远少最上面那一个，数据和日志里都在，
    /// 只有屏幕上没有）。已由 surf-layout 的 `padPullDownTitleSlot` 垫掉，
    /// **这里照常从第一项填起**。
    @MainActor
    private static func populate(menu: NSMenu, model: AppSidebarModel, filter: SidebarFilterState) {
        let groups = model.groups
        // 每次弹出前现取：菜单内容不是拓扑，不必跟着重新贡献就能跟上语言。
        let strings = model.strings

        // **必须关掉自动启用**：`autoenablesItems` 默认 true，AppKit 会按
        // "target 认不认这个 action" 重算每一项的 enabled，把我们设的 false 抹掉
        // ——「显示全部工作区」和「清除筛选」的置灰就是这么静默失效的。
        menu.autoenablesItems = false

        // 右列的计数对齐到同一条竖线（工作区计数 + 归档计数共用），
        // 位置按最宽的那条标题算，长名字才不会把数字挤到下一个制表位。
        let countColumn = countColumnLocation(
            titles: groups.map(\.title) + [strings.showArchived, strings.hideEmptyWorkspaces])

        menu.addItem(.sectionHeader(title: strings.groupBySection))
        for mode in SidebarFilterState.Mode.allCases {
            menu.addItem(MenuActionTarget.item(mode.title(strings), checked: filter.mode == mode) {
                MainActor.assumeIsolated { filter.mode = mode }
            })
        }

        if !groups.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: strings.workspacesSection))
            for group in groups {
                let key = group.filterKey
                let count = group.sessions.filter { !$0.archived || filter.showArchived }.count
                let item = MenuActionTarget.item(group.title, checked: filter.isShown(key)) {
                    MainActor.assumeIsolated { filter.toggleGroup(key) }
                }
                item.attributedTitle = titleWithCount(group.title, count, at: countColumn)
                menu.addItem(item)
            }
            let showAll = MenuActionTarget.item(strings.showAllWorkspaces) {
                MainActor.assumeIsolated { filter.hiddenGroups = [] }
            }
            // 全部已显示时置灰而不是不画：菜单的行数不该跟着状态跳。
            showAll.isEnabled = !filter.hiddenGroups.isEmpty
            menu.addItem(showAll)
        }

        menu.addItem(.separator())
        // 这一分区收的是"改变可见集合"的开关，和上面那些范围勾选不是一回事。
        // 先工作区层面，再会话层面。
        let emptyCount = groups.filter { $0.workspaceId != nil && $0.sessions.isEmpty }.count
        let hideEmpty = MenuActionTarget.item(strings.hideEmptyWorkspaces,
                                              checked: filter.hideEmptyWorkspaces) {
            MainActor.assumeIsolated { filter.hideEmptyWorkspaces.toggle() }
        }
        hideEmpty.attributedTitle = titleWithCount(strings.hideEmptyWorkspaces, emptyCount,
                                                   at: countColumn)
        menu.addItem(hideEmpty)

        let archivedCount = groups.reduce(0) { $0 + $1.sessions.filter(\.archived).count }
        let archived = MenuActionTarget.item(strings.showArchived, checked: filter.showArchived) {
            MainActor.assumeIsolated { filter.showArchived.toggle() }
        }
        archived.attributedTitle = titleWithCount(strings.showArchived, archivedCount,
                                                  at: countColumn)
        menu.addItem(archived)

        menu.addItem(.separator())
        let clear = MenuActionTarget.item(strings.clearFilters) {
            MainActor.assumeIsolated {
                filter.hiddenGroups = []
                filter.showArchived = false
                filter.hideEmptyWorkspaces = true
                filter.mode = .workspace
            }
        }
        clear.isEnabled = filter.isNarrowed
        // **键位只是画在这儿给人看的**：`NSMenuToolbarItem` 的菜单不参与主菜单
        // 键位匹配，真正按得出来的那条是 node 半边 `commands` 声明的 `clearFilters`
        // （壳装进「显示」菜单，`SidebarShortcuts` 应答）。两处必须是同一个组合。
        clear.keyEquivalent = "k"
        clear.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(clear)
    }

    /// 计数右对齐的那一列在哪。按最宽标题算，再留一段间隔——
    /// **不要写死**：`dsh-web-search-firecrawl` 这种名字一超过定值，右制表位就
    /// 失效跳到下一个默认制表位，数字会突然跑远。
    @MainActor
    private static func countColumnLocation(titles: [String]) -> CGFloat {
        let font = NSFont.menuFont(ofSize: 0)
        let widest = titles
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        return ceil(widest) + 34
    }

    /// 「名字 ……… 数字」。`NSMenuItem` 没有原生的 trailing 数字槽，
    /// 用 `attributedTitle` + 右对齐 `NSTextTab` 拼一条出来（自绘视图塞进菜单
    /// 会丢掉高亮反色、键盘导航和显示模式，不划算）。
    @MainActor
    private static func titleWithCount(_ title: String, _ count: Int,
                                       at location: CGFloat) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: location, options: [:])]
        let text = NSMutableAttributedString(
            string: title + "\t",
            attributes: [.font: font, .paragraphStyle: style])
        text.append(NSAttributedString(string: "\(count)", attributes: [
            .font: font,
            .paragraphStyle: style,
            // 计数是修饰，不该和名字抢：高亮行上系统会自己反色，别写死白。
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return text
    }
}
