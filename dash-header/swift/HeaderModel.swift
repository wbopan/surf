import DashLayout
import DashSDK
import Foundation
import Observation
import WebKit

/// header 的原生状态 + 两条出口（页面、桥）。
///
/// ## 两个数据源，不是重复
///
/// | 装什么 | 从哪来 | 为什么 |
/// |---|---|---|
/// | `tabs` / `active` / `canExport` | 页内桥（client.js → 壳 → 事件总线） | active view 是 ui-conversation 的**私有客户端状态**，dsh 侧没有对应物 |
/// | `session`（面包屑 / mode / jobs） | 数据桥（node 半边订 apiProxy） | 这几样在 dsh 侧都有一等契约 |
///
/// 判据是"这个事实的真相住在哪个进程里"。两份状态合在一个 model 里是**故意的**：
/// 工具栏那几格是一个整体，拆成两个 model 会让它们各自换代、各自迟到，
/// 出现"段控已经跟上、面包屑还停在上一个会话"的错位。
///
/// 线程约定：**只在主线程使用**（同 `DashRegistry` / `DashContributions`）。
@Observable
final class HeaderModel {
    // MARK: - 页内桥那半

    /// tab 名单，DOM 顺序即 view 顺序。
    private(set) var tabs: [String] = []
    /// 选中下标；-1 = 没有选中（页面还没报过）。
    private(set) var active: Int = -1
    /// 视图段控该不该显示。跟随内置 header 自己的隐藏规则（空会话）与 `tabs.count > 1`。
    private(set) var present: Bool = false
    /// 网页那边有没有导出按钮可点（dsh-session-log-export 装没装是部署的事）。
    private(set) var canExport: Bool = false

    // MARK: - 数据桥那半

    /// 焦点会话的面包屑 / mode / jobs。没有焦点时为 nil。
    private(set) var session: HeaderSnapshot.Session?

    /// 数据面到底有没有在供货。决定折叠范围：没有就只折 tabs 那一行，
    /// 网页的 titleRow 留着（面包屑和导出不至于凭空消失）。
    private(set) var dataPlaneReady = false

    // MARK: - catalog 浮层

    /// 当前开着的 catalog 是"从哪个会话往下列"。nil = 没开。
    ///
    /// **一次只开一个**：面包屑上可能有好几个触发器（每个 subagent 段一个，
    /// 加上末段的计数下拉），上游也是同一时刻只开一个。
    ///
    /// 写它一律经 `presentCatalog` / `closeCatalog`——**开合都要通知页面**
    /// （见 `primeCatalog` 的注释：不预热就导航不了）。视图里的 Binding 也
    /// 走这两个函数，不直接赋值。
    var openCatalogParent: String? {
        didSet {
            guard oldValue != openCatalogParent else { return }
            if let oldValue {
                call("releaseCatalog", Self.jsStringLiteral(rawParents[oldValue] ?? oldValue))
            }
            if let openCatalogParent {
                call("primeCatalog",
                     Self.jsStringLiteral(rawParents[openCatalogParent] ?? openCatalogParent))
            }
        }
    }

    /// 归一化 parent id → 上游认的原始 id。预热与释放都得用后者
    /// （实测：`subagents.list` 拿光 uuid 当 parent 会返回 0 条）。
    @ObservationIgnored private var rawParents: [String: String] = [:]

    // MARK: - 依赖

    /// WKWebView 归壳所有，这里只借来发 JS。
    @ObservationIgnored private weak var webView: WKWebView?
    /// 切会话走 dash-layout 的会话展示面（与侧边栏点一行是同一条通道）。
    @ObservationIgnored private let surface: DashConversationSurface
    @ObservationIgnored private let bridge: DashBridge
    @ObservationIgnored private let log: (String) -> Void
    /// full 模式下补给正文的顶部留白，实测窗口的 `contentLayoutGuide` 得来。
    @ObservationIgnored var contentTopInset: CGFloat = 0
    /// 本插件这一代的世代号。页面据此分辨"谁在喊"（见 `confirmNative` / `dismissNative`）。
    @ObservationIgnored private let generation: Int

    init(webView: WKWebView?, surface: DashConversationSurface,
         bridge: DashBridge, generation: Int, log: @escaping (String) -> Void) {
        self.webView = webView
        self.surface = surface
        self.bridge = bridge
        self.generation = generation
        self.log = log
    }

    // MARK: - 收数据

    /// 页内桥的 tabs 投影。
    func apply(tabs: [String], active: Int, present: Bool, canExport: Bool) {
        self.tabs = tabs
        self.active = active
        self.present = present
        self.canExport = canExport
    }

    /// 数据桥的 header 投影。
    func apply(snapshot: HeaderSnapshot) {
        session = snapshot.session
        // 收到过一份就算供上货了——哪怕 session 是 nil（那只是当前没有焦点会话）。
        if !dataPlaneReady {
            dataPlaneReady = true
            // 供上货了就可以把整条 header 收掉了。
            confirmNative()
        }
    }

    /// 焦点会话变了（页内桥报的 currentSession）。告诉 node 半边去组投影。
    func focus(sessionId: String?) {
        bridge.send(action: "focus", payload: ["sessionId": sessionId as Any])
    }

    // MARK: - 发动作

    /// 用户点了段控。
    ///
    /// **先乐观改本地、再派发**：段控的 selection 是双向绑定，不当场应答会
    /// 视觉回弹（点了像没动）。页面随后报回来的投影是真相，会覆盖这里——
    /// 万一那次 click 没落地（DOM 变了、按钮没了），下一拍投影就把它纠回去。
    func select(_ index: Int) {
        guard index >= 0, index < tabs.count, index != active else { return }
        active = index
        call("setView", "\(index)")
    }

    /// 点面包屑的某一段：切到那个会话。
    func open(sessionId: String) {
        surface.selectSession(id: sessionId)
    }

    /// 导出会话日志。**点网页那个真按钮**而不是自己拼 URL——
    /// 那边会先 HEAD 探一次、生成文件名、失败时给提示，重新实现一遍只会漂移。
    func exportSession() {
        call("exportSession")
    }

    /// 换 agent preset。写动作走桥，失败经 `error` 频道回来（见 lib/index.js）。
    func selectPreset(_ presetId: String) {
        guard let id = session?.id else { return }
        bridge.send(action: "selectPreset", payload: ["sessionId": id, "agentPreset": presetId])
    }

    // MARK: - 与页面握手

    /// 告诉页面「原生接管到什么程度了」：它据此折叠对应的部分。
    ///
    /// **每代 activate 都要调**，而且要能被重复调用：折叠靠的是
    /// `documentElement` 上一个带实例 token 的属性，页面那边换代（client HMR）
    /// 会把它换成新 token，原生这边再喊一次即可收敛。
    ///
    /// 折叠范围是**渐进的**——数据面还没供货就只折 tabs 那一行，网页的 titleRow
    /// 留着。这样"node 半边挂了"的退化结果是面包屑和导出还在页面上，
    /// 而不是一条空标题栏。
    func confirmNative() {
        let scope = dataPlaneReady ? "full" : "tabs"
        call("confirmNative", "\"\(scope)\", \(Int(contentTopInset.rounded())), \(generation)")
    }

    /// 撤销折叠：本插件要下线了（编译失败被摘、插件被移除、dsh 关掉）。
    ///
    /// **不撤销的后果是网页 header 永久隐藏**——折叠是页面上一个属性，
    /// 原生这边没了不会有人替它摘掉，用户要刷新页面才能把 header 找回来。
    ///
    /// 世代号一起递过去：换代时旧一代的析构也会走到这里，页面那边靠它认出
    /// "这是过气的一代在喊"，从而不会把新一代刚设好的折叠摘掉。
    func dismissNative() {
        call("confirmNative", "\"none\", 0, \(generation)")
    }

    // MARK: - catalog 动作

    /// 打开某个父的 catalog（幂等）。`didSet` 负责通知页面预热。
    ///
    /// 菜单化之后这个"开"只剩**预热**一个意思了：浮层归 AppKit 画，
    /// 我们不再需要知道谁开着。留着它是因为 `primeCatalog` / `releaseCatalog`
    /// 是成对的，得有人记住上一次预热的是谁才能释放。
    func presentCatalog(_ parent: String, raw: String? = nil) {
        if let raw { rawParents[parent] = raw }
        openCatalogParent = parent
    }

    func closeCatalog() {
        openCatalogParent = nil
    }

    /// 打开一个子代理会话。
    ///
    /// 走**页内桥**而不是数据桥：`openSubagent` 是 client runtime 的服务，
    /// 路由状态住在浏览器进程里，node 侧没有对应物（见 client.js 同名函数的注释）。
    func openSubagent(parent: String, child: String, mode: String?) {
        let kind = (mode == "one-shot" || mode == "continuable") ? mode! : "continuable"
        // **带回执**：导航是用户点了才发生的动作，静默失败等于骗人
        // （与 `expose` 那边"写动作失败必须报"同一条纪律）。client 半边回一个
        // 诊断字符串，非 ok 就记进 dsh 终端。
        call("openSubagent",
             "\(Self.jsStringLiteral(parent)), \(Self.jsStringLiteral(child)), \(Self.jsStringLiteral(kind))",
             receipt: true)
    }

    // MARK: - 谱系菜单

    /// 子代理菜单将要打开：预热 catalog。
    ///
    /// **预热不是可选的优化**：`openSubagent` 会校验目标是不是 client runtime
    /// 自己那份 `subagentsByParent` 里的健康子节点，没 prime 过一律被挡。
    /// 菜单打开到用户点中之间那几百毫秒够拉一轮。
    ///
    /// 预热的对象是**当前会话**（菜单列的是它的直接子代）。当前会话本身是
    /// 子代理时，祖先段的导航不需要预热——那是普通的 `open(sessionId:)`。
    func primeSubagentMenu() {
        guard let session, let tree = session.subagents else { return }
        presentCatalog(session.id, raw: tree.rawId(of: session.id))
    }

    /// 谱系菜单里的一条被选中了。
    ///
    /// itemId 有两种前缀，因为**两种目标要走两条不同的路**：祖先已经在链上，
    /// 普通导航就行；子代理得经 client runtime 的 `openSubagent`（它认的是
    /// 自己那份 catalog，而不是会话 id 本身）。
    func activateSubagentMenuItem(_ itemId: String) {
        if let target = itemId.dropPrefix("goto:") {
            open(sessionId: target)
            return
        }
        guard let target = itemId.dropPrefix("open:"),
              let tree = session?.subagents,
              let node = tree.nodes[target],
              let parent = tree.parent(of: target)
        else { return }
        // **原始 id，不是归一化的那个**（见 HeaderSnapshot.rawId 的注释）。
        openSubagent(parent: tree.rawId(of: parent), child: node.rawId, mode: node.mode)
    }

    /// JS 字符串字面量转义（反斜杠、引号、控制字符），防注入。
    /// 与 dash-layout 的 `jsStringLiteral` 同一份逻辑——会话 id 是外来字符串，
    /// 直接拼进脚本是真实的注入面。
    static func jsStringLiteral(_ raw: String) -> String {
        var out = "\""
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// 调 `window.__clamHeader.*`。桥不在（普通浏览器、页面还没加载完、
    /// client 半边这一代还没起）时静默失败——不弹窗不报错，与 dash-layout
    /// 的 `WebViewConversationSurface` 同一条纪律。
    private func call(_ fn: String, _ args: String = "", receipt: Bool = false) {
        guard let webView else { return }
        // 外来字符串（会话 id）一律先过 `jsStringLiteral`——调用方的责任，
        // 这里只负责拼壳。
        // 桥不在时返回**有内容的**字符串而不是 undefined：`nil` 回执什么都没说，
        // 分不清"页面没加载"和"这一版 client 里没有这个函数"。
        let script = "(function(){var h=window.__clamHeader;"
            + "if(!h)return 'no-bridge';"
            + "if(typeof h.\(fn)!=='function')return 'missing:\(fn)|have='+Object.keys(h).join(',');"
            + "return h.\(fn)(\(args));})()"
        webView.evaluateJavaScript(script) { [log] value, error in
            if let error { log("页面调用 \(fn) 失败：\(error.localizedDescription)"); return }
            guard receipt else { return }
            let text = (value as? String) ?? String(describing: value ?? "nil")
            if !text.hasPrefix("ok") { log("页面 \(fn) 没走通：\(text)") }
        }
    }
}
