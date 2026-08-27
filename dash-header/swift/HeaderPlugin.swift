import DashLayout
import DashSDK
import Foundation
import SwiftUI
import WebKit

/// 插件入口。壳按 image handle `dlsym` 取这个符号。
@_cdecl("dash_plugin_entry")
public func dash_plugin_entry() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(HeaderPlugin()).toOpaque()
}

/// dash-header 的 Swift 半身：往 dash-layout 的 `toolbar` 贡献槽的**内容侧**
/// 放五格，网页那条 header 由 client 半边就地折叠。
///
/// 排布是「标识靠左、其余靠右、正中留空」：
///
/// ```
/// │ 会话标题 ⋈2  ·············留白············  [段控] [模式] [任务 导出]
/// ```
///
/// 留白不是没排满——正文列的正中不放东西，视线从标题落下去一路无遮挡。
/// 靠右那三枚胶囊由 `spaced` 断开（空隙就是 AppKit 的分组语法）。
///
/// **本插件是 `toolbar` 槽的普通贡献者**，和 dash-layout 自己的"新建会话"
/// 完全同级——消费方（LayoutSplitController）不认得这几格，也不认得
/// `Chat`/`Trajectory`/`agentPreset` 是什么，它只负责把贡献摆到分隔线右边。
///
/// ## 两条数据通道
///
/// - **页内桥**（`dash.page.headerTabs`）：视图标签的名单与选中态。
///   那是 ui-conversation 的私有客户端状态，dsh 侧没有对应物。
/// - **数据桥**（`host.bridge` 的 `snapshot` 频道）：面包屑 / mode / jobs。
///   这几样在 dsh 侧都有一等契约，数据面住在 node 半边。
///
/// 判据是"这个事实的真相住在哪个进程里"，不是"哪条路好走"。
///
/// ## 跨代
///
/// 两条通道各自把最后一份原样（`NSDictionary`，系统类型跨代安全）存进保管箱，
/// 下一代先拿它们开局，再各自要一份新的。**箱里绝不放本 module 定义的类型**
/// ——新旧两代的同名类型互不认识，取出来 `as?` 只会安静地得到 nil（M2 断言 4）。
final class HeaderPlugin: DashPlugin {
    /// 保管箱里那份最后的 tabs 投影（页内桥那条）。
    private static let tabsKey = "dash.header.tabs"
    /// 保管箱里那份最后的 header 投影（数据桥那条）。
    private static let snapshotKey = "dash.header.snapshot"
    /// dash-layout 的工具栏贡献槽名。**槽名是插件之间约定的字符串**，
    /// 壳一个都不认得，所以这里就该硬写而不是去 import 一个常量。
    private static let toolbarSlot = "toolbar"

    func activate(host: DashHost) -> AnyObject? {
        // WKWebView 归壳所有；它不在说明壳还没造好窗口，这时不该装配。
        guard let webView = host.objects.object(DashObjects.Key.webView, as: WKWebView.self) else {
            host.log("保管箱里没有 WKWebView，header 缺席（网页那条 header 原样留着）")
            return nil
        }
        // 面包屑要能切会话，走的是 dash-layout 的会话展示面（与侧边栏同一条通道）。
        guard let surface = host.objects.object(DashObjects.Key.conversationSurface)
                as? DashConversationSurface else {
            host.log("保管箱里没有会话展示面，header 缺席（dash-layout 没装配？）")
            return nil
        }

        let handle = DashPluginHandle()
        let model = HeaderModel(webView: webView, surface: surface, bridge: host.bridge,
                                generation: host.generation, log: { host.log($0) })
        // full 模式下正文要让开标题栏那条带子。实测窗口的 contentLayoutGuide，
        // 硬编码会在工具栏样式或系统版本变化时错位。
        // 开局自己量一次：dash-layout 的首帧广播可能早于本插件装配，
        // 而它只在**变化时**才发，等不来第二次。之后由 titlebarMetrics 接管。
        model.contentTopInset = Self.titlebarInset(of: webView)

        // 用上一代留下的两份投影开局，换代时工具栏不闪。
        if let seed = host.objects.object(Self.tabsKey, as: NSDictionary.self) as? [String: Any] {
            Self.applyTabs(seed, to: model)
        }
        if let seed = host.objects.object(Self.snapshotKey, as: NSDictionary.self) as? [String: Any],
           let snapshot = HeaderSnapshot.decode(seed) {
            model.apply(snapshot: snapshot)
        }

        // ---- 页内桥 ----

        // client 半边报上来的 tabs 投影。壳对未知 type 一律广播成
        // `dash.page.<type>`（去白名单后的通用转发），这条通道不需要改壳。
        host.events.subscribe(DashEventBus.Topic.pagePrefix + "headerTabs") { payload in
            host.objects.setObject(Self.tabsKey, payload as NSDictionary) // 先落箱再上屏
            Self.applyTabs(payload, to: model)
        }.kept(by: handle)

        // client 半边这一代起来了（页面刷新、client HMR）：重新握手。
        // 与 activate 末尾那次是**同一件事的两个时序**——谁后到谁生效，幂等，
        // 覆盖"原生先起"和"页面先起"两种顺序。
        host.events.subscribe(DashEventBus.Topic.pagePrefix + "headerReady") { _ in
            model.confirmNative()
        }.kept(by: handle)

        // client 半边的异步诊断（导航这类"用户刚点过"的动作失败时）。
        // 它没有控制台可写，而 evaluateJavaScript 的回执只能带回**同步**结果
        // ——异步那段只能经页内桥说话。
        host.events.subscribe(DashEventBus.Topic.pagePrefix + "headerDiag") { payload in
            if let text = payload["text"] as? String { host.log("页面诊断：\(text)") }
        }.kept(by: handle)

        // 焦点会话：页内桥的公共通道（dash-layout 的 client 半边在报）。
        // node 侧自己是不知道的——「哪个会话正被看着」是浏览器的 UI 状态，
        // 不是 dsh 的领域事实。
        host.events.subscribe(DashEventBus.Topic.pageCurrentSession) { payload in
            model.focus(sessionId: payload["id"] as? String)
        }.kept(by: handle)

        // ---- 数据桥 ----

        host.bridge.onMessage { [weak model] channel, payload in
            guard let model else { return }
            switch channel {
            case "snapshot":
                guard let snapshot = HeaderSnapshot.decode(payload) else {
                    host.log("收到解不动的 header snapshot，保留上一份")
                    return
                }
                host.objects.setObject(Self.snapshotKey, payload as NSDictionary) // 先落箱再上屏
                model.apply(snapshot: snapshot)

            case "error":
                // 写动作失败（目前只有换 preset）。读失败 node 那边自己咽了。
                host.log("header 动作失败：\(payload["action"] ?? "?") "
                         + "\(payload["message"] ?? "未知原因")")

            default:
                break // 未知频道忽略（协议向前兼容，同桥的纪律）
            }
        }.kept(by: handle)

        // ---- 四格贡献 ----
        //
        // order 决定组内从左到右的次序；靠哪一边由 align 决定。
        // **每一格都走原生路线**（group / menu / button）：排版、显示模式、
        // 玻璃分组、徽标、溢出退让全归 AppKit。**这条工具栏上没有一个自定义视图。**
        //
        // 少掉的那两格不是删功能，是**换了个更诚实的位置**：
        // 会话标识去了 `window.title`，后台任务与锁定后的 preset 去了
        // `window.subtitle`。判据是一条设计原则——**圆胶囊是"可操作"的承诺**，
        // 只读的东西长成按钮，是在承诺一件按下去不会发生的事。
        //
        // 标识走 `window.title` / `window.subtitle`（Mail / Notes 那条裸文字），
        // 由 HeaderToolbarSync 推。**工具栏项做不了标识**：`NSToolbarItem` 会给
        // 自定义视图套一枚玻璃胶囊，那是按钮的长相，不是标题的。
        //
        // 这里给的全是**拓扑**（长什么样、排在哪）。会变的那部分（选中态、
        // 徽标数字、菜单内容、显隐）走 `dash.toolbar.update` 活通道，
        // 由 HeaderToolbarSync 推——改 metadata 会重建整条工具栏。

        // 会话谱系：祖先导航 + 兄弟切换 + 子代理进入，三种交互一个菜单。
        // **子代理会话不进侧边栏，这是它们唯一的入口。**
        //
        // 放右组而不是紧挨标题：`window.title` 是贪心的，会把 content·leading
        // 的项顶走（见 dash-layout 那条注释）。而且 Mail / Notes 本来就不在
        // 标题右边放按钮——标题一侧只有文字，动作全在另一头。
        contribute(host, handle, id: "subagents", order: 0, label: "子代理",
                   align: "trailing", kind: "menu", symbol: "arrow.triangle.branch",
                   priority: "low")
        // 四格靠右钉死。中间那段留白是设计的一部分：会话正文列的正中
        // 不放东西，视线从标题落下去一路无遮挡。
        //
        // `spaced` 把它们断成三枚玻璃胶囊：[段控] [模式] [任务 导出]。
        // 任务与导出相邻不断，合成一枚（Mail 对 archive/trash/flag 就是这么做的）。
        // 窗口收窄时的让位顺序由 priority 定，AppKit 自己把让掉的项收进 `»`
        // 溢出菜单。**实测过缺省全给 standard 的结果**：520pt 宽时右边四格
        // 整组进了溢出，而占 220pt 的标题纹丝不动——正好反了。
        // 现在是：任务(low) → 标识/模式(standard) → 段控/导出(high)。
        contribute(host, handle, id: "viewTabs", order: 10, label: "会话视图",
                   align: "trailing", spaced: true, kind: "group",
                   // 开局的分段。真名单由页面报上来，随后经活通道换掉。
                   items: [
                       ["id": "chat", "label": "Chat", "symbol": "text.bubble"],
                       ["id": "trajectory", "label": "Trajectory",
                        "symbol": "list.bullet.indent"],
                   ],
                   priority: "high")
        contribute(host, handle, id: "mode", order: 20, label: "模式",
                   align: "trailing", spaced: true, kind: "menu", symbol: "cube")
        // 后台任务那一格**没了**：上游 ui-jobs 自己也只给看不给停，做成按钮
        // 是在承诺一件按下去不会发生的事。计数改进 `window.subtitle`。
        contribute(host, handle, id: "export", order: 40, label: "导出",
                   align: "trailing", kind: "button", symbol: "square.and.arrow.down",
                   priority: "high")

        // ---- 工具栏回来的动作 ----

        // 段控被点了。`index` 由消费方带上来，不必自己数下标。
        host.events.subscribe(LayoutToolbar.activateTopic) { payload in
            guard payload["owner"] as? String == host.plugin,
                  payload["id"] as? String == "viewTabs",
                  let index = payload["index"] as? Int else { return }
            model.select(index)
        }.kept(by: handle)

        // 菜单项被选了。jobs 那份菜单是只读的（项全 disabled），不会走到这里。
        host.events.subscribe(LayoutToolbar.menuSelectTopic) { payload in
            guard payload["owner"] as? String == host.plugin,
                  let itemId = payload["itemId"] as? String, !itemId.isEmpty
            else { return }
            switch payload["id"] as? String {
            case "mode":
                model.selectPreset(itemId)
            case "subagents":
                // itemId 形如 `open:<sessionId>`（进子代理）或 `goto:<sessionId>`
                // （祖先/根导航）。两条路的目标 id 是同一个空间，动作不同。
                model.activateSubagentMenuItem(itemId)
            default:
                break
            }
        }.kept(by: handle)

        // 子代理菜单**将要**打开：预热 catalog。
        //
        // 上游的 `openSubagent` 校验的是 client runtime 自己那份
        // `subagentsByParent`，没 prime 过一律被挡。菜单打开到用户点中之间
        // 那几百毫秒正好够拉一轮。
        host.events.subscribe(LayoutToolbar.menuOpenTopic) { payload in
            guard payload["owner"] as? String == host.plugin,
                  payload["id"] as? String == "subagents" else { return }
            model.primeSubagentMenu()
        }.kept(by: handle)

        // 导出按钮。
        host.events.subscribe(LayoutToolbar.activateTopic) { payload in
            guard payload["owner"] as? String == host.plugin,
                  payload["id"] as? String == "export" else { return }
            model.exportSession()
        }.kept(by: handle)

        // ---- 标题栏厚度 ----
        //
        // **不是装配时量一次的常量**：用户右键把工具栏改成 Icon and Text，
        // 那条带子会高一截，正文的顶部留白得跟着走。dash-layout 盯着自己的
        // 布局，变了就广播一次。
        host.events.subscribe(LayoutToolbar.titlebarMetricsTopic) { payload in
            guard let inset = payload["inset"] as? Double else { return }
            let next = CGFloat(inset)
            guard abs(next - model.contentTopInset) > 0.5 else { return }
            model.contentTopInset = next
            model.confirmNative() // 把新的留白值推给页面
        }.kept(by: handle)

        // 现在就要一份厚度。**每代都要问**：dash-layout 只在厚度**变化**时才
        // 广播，而本插件多半是在它广播完之后才上线的——不问就永远等不到，
        // 症状是"用户把工具栏改成 Icon and Text 之后正文被标签盖住"。
        host.events.emit(LayoutToolbar.titlebarMetricsRequestTopic)

        // ---- 盯着 model 推工具栏 ----
        let sync = HeaderToolbarSync(host: host, model: model)
        sync.start().kept(by: handle)

        // 请求一份 fresh 全量。**每代都要问**：node 半边只在数据变化时推，
        // 不为新连上来的世代补发（补发逻辑归请求方，与桥不给壳补发 app-build 同理）。
        host.bridge.send(action: "snapshot")

        // 告诉页面「原生接管了」——它据此折叠。**每代都要喊**：折叠靠的是页面
        // documentElement 上一个带实例 token 的属性，不喊就不会折。
        model.confirmNative()

        // 下线时把页面上的折叠撤掉。**不撤销 = 网页 header 永久隐藏**，
        // 用户得刷新页面才找得回来。闭包捕着 model，所以它活到这一刻。
        // 换代时旧一代也会走这里，页面靠世代号认出那是过气的一代（见 dismissNative）。
        DashDisposable { model.dismissNative() }.kept(by: handle)

        host.log("header 上线 g\(host.generation)（工具栏 4 格 + 窗口标识，"
                 + "顶部留白 \(Int(model.contentTopInset))pt）")
        return handle
    }

    /// 一格贡献。五格的参数只差那么几样，收成一个辅助函数。
    ///
    /// `make` 缺省给一个空视图：原生路线（group / menu / button）根本不看它，
    /// 但槽的签名要求有一个视图工厂——那是给 `view` 路线用的。
    private func contribute(_ host: DashHost, _ handle: DashPluginHandle,
                            id: String, order: Double, label: String,
                            align: String = "leading", spaced: Bool = false,
                            kind: String = "view", symbol: String? = nil,
                            sizing: String? = nil,
                            items: [[String: Any]] = [],
                            priority: String? = nil,
                            make: @escaping () -> AnyView = { AnyView(EmptyView()) }) {
        var metadata: [String: Any] = [
            "label": label,
            "region": "content", // 与主内容区对齐，在分栏分隔线右边
            "align": align,      // leading = 跟着内容起排；trailing = 推到右缘
            "spaced": spaced,    // 之前插一个标准间距 = 另起一枚玻璃胶囊
            "kind": kind,        // group / menu / button 走原生，view 走兜底
        ]
        if let symbol { metadata["symbol"] = symbol }
        if let sizing { metadata["sizing"] = sizing }
        if let priority { metadata["priority"] = priority }
        if !items.isEmpty { metadata["items"] = items }
        host.contribute(to: Self.toolbarSlot, id: id, order: order,
                        metadata: metadata, make: make).kept(by: handle)
    }

    /// 标题栏那条带子有多高。`contentLayoutGuide` 是窗口自己算的，
    /// 比"52pt"这种硬编码扛得住工具栏样式与系统版本的变化。
    ///
    /// 窗口还没有时返回 0——activate 早于窗口装配的情况下不该瞎猜，
    /// 那时页面也还没有内容可挡。
    private static func titlebarInset(of webView: WKWebView) -> CGFloat {
        guard let window = webView.window,
              let layoutGuide = window.contentLayoutGuide as? NSLayoutGuide,
              let contentView = window.contentView else { return 0 }
        // AppKit 的 NSLayoutGuide 是 `frame`（`layoutFrame` 是 UIKit 那边的名字）。
        //
        // **坐标系是左下原点**（contentView 默认 `isFlipped == false`）：
        // guide 的 `minY` 贴着窗口底边，顶部那条带子的厚度是
        // `contentView.maxY - guide.maxY`。写成 `guide.minY` 会恒等于 0，
        // 症状是正文顶到窗口最上沿、被工具栏盖住。
        let inset = contentView.bounds.maxY - layoutGuide.frame.maxY
        return inset.isFinite && inset > 0 ? inset : 0
    }

    /// 把一份页内投影灌进 model。字段缺失一律退化成"不显示"，而不是猜——
    /// dsh 升级改了 DOM 时，退化结果该是回到网页那条 header。
    private static func applyTabs(_ payload: [String: Any], to model: HeaderModel) {
        model.apply(tabs: (payload["tabs"] as? [Any])?.compactMap { $0 as? String } ?? [],
                    active: payload["active"] as? Int ?? -1,
                    present: payload["present"] as? Bool ?? false,
                    canExport: payload["canExport"] as? Bool ?? false)
    }
}
