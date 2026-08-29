import AppKit
import ClamSDK

/// # clam-layout 对外的契约面
///
/// 槽名、槽的载荷形状——**这些全是插件之间的约定，壳一个都不认得**
/// （`root` 是唯一例外，那是壳自己的兜底）。抄字符串抄错是**静默失败**：
/// 注册进一个没人消费的槽、或者把键名拼错一个字母，界面上什么都不会发生，
/// 也不会有任何日志或编译错误。所以约定收在这个文件里，下游
/// `import ClamLayout` 按名字引用，拼错就编不过。
///
/// 消费方（`LayoutSplitController` / `ToolbarContribution.swift`）**照旧读字典**
/// ——SDK 的贡献槽只收容器不收词汇（见 `ClamContributions` 顶注），
/// 把 `ToolbarSpec` 冻进 ABI 等于把"工具栏长什么样"钉死在预编译的壳里。
/// 这里给的是**生产端**的类型安全，不是新的传输格式。

// MARK: - 替换槽

/// clam-layout 开放的**替换槽**（一槽一主，后来者覆盖）。
public enum LayoutSlots {
    /// 原生侧边栏。占用者由 `SidebarSlotView` 渲染，随占用者的世代整棵重建；
    /// 没人占就不装那个 `NSSplitViewItem`（分栏退化成单栏全出血 WebView）。
    public static let sidebar = "sidebar"
}

// MARK: - toolbar 贡献槽的载荷

/// `toolbar` 贡献槽（槽名见 `LayoutToolbar.slot`）一条贡献的**拓扑**。
///
/// ```swift
/// host.contribute(to: LayoutToolbar.slot, id: "filter", order: -100,
///                 metadata: ToolbarSpec(label: "筛选",
///                                       symbol: "line.3.horizontal.decrease",
///                                       tooltip: "显示哪些会话",
///                                       menu: buildMenu).metadata()) {
///     AnyView(MyFallbackButton())   // 只有 view 路线用得上
/// }
/// host.events.subscribe(LayoutToolbar.activateTopic) { payload in ... }
/// ```
///
/// ## 拓扑 vs 流量：这里只放前者
///
/// 本结构的每一个字段**一变就重建整条工具栏**（签名变了）。徽标数字、菜单
/// 内容、段控选中态、显隐是**流量**，一秒能变好几次——走这里等于每次把工具栏
/// 拆了重装（按钮会闪、popover 会掉）。流量走活通道
/// `LayoutToolbar.updateTopic`，载荷键见 `ToolbarItemState`。
///
/// 唯一的例外是 `label`：它是拓扑（构造时读走一次），所以**换语言的正路是
/// 重新贡献同一组 `(owner, id)`**（就地覆盖、位置不变），不是发 patch。
///
/// ## 回调统一走事件总线
///
/// 原生项拿不到闭包（`NSToolbarItem` 的 target/action 必须是 `@objc`，而闭包
/// 跨不了世代），所以点击一律翻译成广播。主题名是字符串，热替换后新一代
/// 重新订阅即可。
public struct ToolbarSpec {
    /// 贡献落在分栏分隔线的哪一侧。
    ///
    /// `sidebarTrackingSeparator` 把工具栏切成两段，分隔线跟着分栏 divider 走。
    public enum Region: String {
        /// 分隔线左边，与红绿灯同区。**缺省**——老贡献一个字都不用改。
        case sidebar
        /// 分隔线右边，与主内容区对齐。想跟会话正文对齐的东西选它。
        case content
    }

    /// 靠哪一边。**只有 `content` 区认这个键**。
    ///
    /// `leading` 与 `trailing` 之间夹一个 `.flexibleSpace`，于是 trailing 那组
    /// 被推到窗口右缘、位置钉死。中间那段空白是设计的一部分（会话正文列的正中
    /// 不放东西，视线从标题落下去一路无遮挡），不是没排满——所以不开 `center`：
    /// 只有两组，就没有"往中间挤"这个选项。
    public enum Align: String {
        case leading
        case trailing
    }

    /// 用哪条渲染路线造 `NSToolbarItem`。
    ///
    /// | kind | 造出来的东西 | 白送什么 |
    /// |---|---|---|
    /// | `button` | `NSToolbarItem` + `isBordered` | 圆形玻璃按钮、按下态、红绿灯对齐 |
    /// | `group` | `NSToolbarItemGroup`（`.selectOne` + `.expanded`） | 段控外观、选中态、键盘、无障碍 |
    /// | `menu` | `NSMenuToolbarItem` | 下拉 indicator、菜单定位、键盘导航 |
    /// | `view` | `NSHostingView` 装贡献自己的 `AnyView` | **什么都不送，宽度间距自己算** |
    ///
    /// **能用前三条就别用第四条。** 自定义视图路线里 AppKit 只看见一块不透明的
    /// 矩形：显示模式（Icon Only / Icon and Text / Text Only）、玻璃胶囊分组、
    /// 溢出退让、徽标全都失效，而且算错是静默的。
    public enum Kind: String {
        case view
        case button
        case menu
        case group
    }

    /// 窗口收窄时谁先让位（`NSToolbarItem.visibilityPriority`）。
    ///
    /// **别全用缺省**：实测 520pt 宽的窗口上，右边四格整组进了 `»` 溢出菜单，
    /// 而占 220pt 的标题纹丝不动——正好反了。
    public enum Priority: String {
        case low
        case standard
        case high
    }

    /// `view` 路线的尺寸策略。前三条路线不看它。
    public enum Sizing: String {
        /// 尺寸当场冻死（缺省）。适合长相固定的控件。
        case fixed
        /// 交给 Auto Layout，内容变了宽度自己跟上。适合内容本来就会变的。
        /// 代价是贡献者必须自己守住上限——SwiftUI 的 `maxWidth` 是贪心的。
        case dynamic
    }

    /// 标题 + 无障碍名。**必填**：缺了就退化成贡献的 `id`。
    public var label: String
    /// SF Symbol 名。给了它而没写 `kind` 时，渲染路线自动推断成 `.button`。
    public var symbol: String?
    /// 悬停提示。缺省取 `label`。
    public var tooltip: String?
    /// 点击时广播的主题。缺省 `LayoutToolbar.activateTopic`。
    public var event: String?
    public var region: Region
    public var align: Align
    /// 本项之前要不要插一个系统标准间距。
    ///
    /// **这就是分组语法**：macOS 26 把相邻的工具栏项合成一枚玻璃胶囊，
    /// 一个 `.space` 就把胶囊断开成两枚。想让自己这一项单独成一枚就打开它。
    public var spaced: Bool
    public var sizing: Sizing
    /// 渲染路线。**`nil` = 由 `symbol` 推断**（有 symbol 算 `.button`，
    /// 没有算 `.view`），这样不写 `kind` 的老贡献观感一个字都不用改。
    public var kind: Kind?
    public var priority: Priority
    /// `group` 的分段 / `menu` 的初始菜单。元素形状：
    ///
    /// ```swift
    /// ["id": "chat", "label": "Chat", "symbol": "text.bubble"]           // group 的一段
    /// ["id": "std", "label": "标准模式", "state": true, "enabled": true]  // menu 的一项
    /// ["separator": true]                                                 // menu 的分隔线
    /// ["label": "父会话", "detail": "3 分钟前", "submenu": [...]]          // 两行 + 子菜单
    /// ```
    ///
    /// 保持 `[[String: Any]]` 而不是再包一层类型：它跨 dylib 装箱，
    /// 而且这几个键的组合按 `kind` 变化，收成一个结构只会多一堆无用字段。
    public var items: [[String: Any]]
    /// 菜单的**另一条**路线：贡献方自己现场建。给了它就不看 `kind`/`items`，
    /// 点开是菜单而不是发事件。
    ///
    /// 数据路线（`kind: .menu` + `items`）适合内容由投影决定的菜单，
    /// block 路线适合内容由贡献方本地状态决定的菜单——菜单每次弹出前重建，
    /// 所以 block 里读什么状态都是当场的。两者不互相取代。
    ///
    /// 类型必须是 `@convention(block)`：它要穿过 dylib 边界装在 `[String: Any]`
    /// 里，ObjC block 是个货真价实的对象，装箱取箱都稳；裸 Swift 闭包的函数
    /// 类型元数据跨 image 取回来是碰运气。
    public var menu: (@convention(block) (NSMenu) -> Void)?

    public init(label: String,
                symbol: String? = nil,
                tooltip: String? = nil,
                event: String? = nil,
                region: Region = .sidebar,
                align: Align = .leading,
                spaced: Bool = false,
                sizing: Sizing = .fixed,
                kind: Kind? = nil,
                priority: Priority = .standard,
                items: [[String: Any]] = [],
                menu: (@convention(block) (NSMenu) -> Void)? = nil) {
        self.label = label
        self.symbol = symbol
        self.tooltip = tooltip
        self.event = event
        self.region = region
        self.align = align
        self.spaced = spaced
        self.sizing = sizing
        self.kind = kind
        self.priority = priority
        self.items = items
        self.menu = menu
    }

    /// 翻成贡献槽要的字典。
    ///
    /// **缺省值一律省略而不是写进去**，两条理由：
    /// ① 消费方每个键都是"读不到就用缺省"，写与不写等价，省略的那份更小、
    ///    在诊断里也更容易一眼看出贡献者到底指定了什么；
    /// ② `kind` 缺席**不等于** `kind: "view"`——缺席是"按 symbol 推断"，
    ///    写死就把推断关掉了。这一条要求 `kind` 必须能表达"没说"，
    ///    于是整张表统一成同一条规则，免得记两套。
    public func metadata() -> [String: Any] {
        var out: [String: Any] = ["label": label]
        if let symbol { out["symbol"] = symbol }
        if let tooltip { out["tooltip"] = tooltip }
        if let event { out["event"] = event }
        if region != .sidebar { out["region"] = region.rawValue }
        if align != .leading { out["align"] = align.rawValue }
        if spaced { out["spaced"] = true }
        if sizing != .fixed { out["sizing"] = sizing.rawValue }
        if let kind { out["kind"] = kind.rawValue }
        if priority != .standard { out["priority"] = priority.rawValue }
        if !items.isEmpty { out["items"] = items }
        if let menu { out["menu"] = menu }
        return out
    }
}
