import SurfSDK
import Foundation

/// 文案表——**整个界面唯一的人工输入**，内容对齐 dsh Web 设置对话框。
///
/// 背景（计划 §2.1）：schema 里一个字的文案都没有，meta 键全集只有
/// `required/default/role/step/min/max` 六个。所以"这个字段是什么意思"在结构化
/// 渠道里根本不存在——**Web 端也一样**，它同样是把标题和说明硬写在前端里的。
/// 既然两边都得手写，那就写成同一份：Web 有的照抄，Web 没有的机械美化。
///
/// **仍然不刮 Web 的编译产物**（计划 §1.3）。这里是我照着**跑起来的界面**读一遍
/// 然后手写的——一次性的阅读，不建立构建期依赖，dsh 升级了也不会有东西静默碎掉。
///
/// **表可以很小，而且应该很小**：
/// - 没有注解的字段照样出现，标签走 key 的机械美化，真 key 与约束进悬停提示。
///   零遗漏由渲染保证，不是由这张表保证。
/// - 表越大越容易变陈：上游改了字段语义，这里的文案不会自己更新，也没人会提醒。
///
/// 加一条的判据：**Web 里有这条文案**，或者**机械美化出来的名字会让人看不懂**。
///
/// ## 双语（`docs/archive/surf-i18n-plan.md` i4）
///
/// 每条文案是一个 `LocalizedText`（zh / en 并排写在同一行，审校时一眼对照），
/// 取用时按当前 locale 挑一份。**这张表和 `L` 的分工是"数据 vs 现算"**：
/// `L` 的条目在被读到的那一刻才知道语言，而这张表是 `static let`，语言未知时
/// 就已经存在，所以两种语言都得存下来。
/// 漏写 en 编译不过（`LocalizedText` 的构造器要两个参数），加条目时不需要额外纪律。
enum FieldNotes {

    struct Note {
        /// 标题。没有就用 `SettingsFormat.humanize(key)`。
        let title: LocalizedText
        /// 一句说明。可以没有。
        let hint: LocalizedText?
        /// 单位。**跟在控件右边，不进标题**——"命令超时（毫秒）："这种标题会把
        /// `Form` 的标签列撑宽，而列宽是所有行共享的，一个长标题会顶歪整页。
        let unit: LocalizedText?
        /// 枚举值的人话。schema 只给得出 `danger-full-access` 这种机器值。
        let options: [String: LocalizedText]?

        init(_ title: LocalizedText, _ hint: LocalizedText? = nil,
             unit: LocalizedText? = nil, options: [String: LocalizedText]? = nil) {
            self.title = title
            self.hint = hint
            self.unit = unit
            self.options = options
        }
    }

    /// ns → 路径（用 `/` 连接）→ 注解。
    ///
    /// **hint 的唯一判据：它说了标签没说的事。** 把字段名换句话再说一遍的一律不写
    /// ——「权限：新会话默认用哪个权限档位。」这种句子占位、费眼、零信息，一页上有
    /// 五六条就把真正要紧的那一两条淹掉了。留下来的都是标签推不出来的：改了影不影响
    /// 在跑的会话、超出上限之后数据去哪、这个值存在哪。
    private static let table: [String: [String: Note]] = [
        // ── 通用页的五行（Web: General）────────────────────────────────
        "agent-presets": [
            "default": Note(.init("智能体预设", "Agent Preset"),
                            .init("已经在跑的会话不受影响。",
                                  "Sessions already running are not affected.")),
        ],
        "permission": [
            "defaultPreset": Note(.init("权限", "Permissions"), options: [
                "read-only": .init("只读", "Read Only"),
                "workspace-write": .init("可写工作区", "Workspace Write"),
                "danger-full-access": .init("完全放开", "Full Access"),
            ]),
        ],
        "locale": [
            // **选项名不翻，两种语言下都是各自的自述名**——dsh 上游的 `LOCALES`
            // 就是这么写的（`中文` / `English`），语言选择器里列出别人的语言时
            // 用那门语言自己的名字是通行做法（macOS 的「语言与地区」亦然）。
            // 换成「中文 / 英文」反而会让只认得 English 的人找不到自己那项。
            "preference": Note(.init("语言", "Language"),
                               options: ["zh": .same("中文"), "en": .same("English")]),
        ],
        "ui-theme": [
            // 外观走 `.tabs` 样式的 Picker（AppearanceRow），文案在这儿。
            "preference": Note(.init("外观", "Appearance"), options: [
                "light": .init("浅色", "Light"),
                "dark": .init("深色", "Dark"),
                "system": .init("跟随系统", "System"),
            ]),
        ],
        "ui-conversation": [
            "busyEnter": Note(.init("忙碌时 Enter 的行为", "Enter While Busy"),
                              .init("⌘/Ctrl+Enter 走另一种。", "⌘/Ctrl+Enter does the other one."),
                              options: ["queue": .init("排队", "Queue"),
                                        "steer": .init("插话", "Steer")]),
        ],

        // ── 插件页（Web: Plugins → Plugin configuration）───────────────
        "shell": [
            "timeoutMs": Note(.init("命令超时", "Command Timeout"), unit: .init("毫秒", "ms")),
            "maxOutputBytes": Note(.init("单流输出上限", "Output Limit per Stream"),
                                   .init("超出的部分溢写到临时文件，不会丢。",
                                         "Anything beyond it spills to a temporary file; nothing is lost."),
                                   unit: .init("字节", "bytes")),
            // 下面这些 Web 没露，机械美化会难懂，所以照样给人话标题。
            "cwd": Note(.init("工作目录", "Working Directory")),
            "maxTimeoutMs": Note(.init("超时上限", "Maximum Timeout"),
                                 .init("调用方能要求的最大超时。",
                                       "The longest timeout a caller may ask for."),
                                 unit: .init("毫秒", "ms")),
            "maxSpillBytes": Note(.init("溢写上限", "Spill Limit"), unit: .init("字节", "bytes")),
            "graceMs": Note(.init("SIGTERM 宽限", "SIGTERM Grace Period"), unit: .init("毫秒", "ms")),
        ],
        "agent-loop": [
            "maxParallelToolCalls": Note(.init("并行工具调用", "Parallel Tool Calls")),
        ],
        "web-search-deepseek": [
            "apiKey": Note(.same("API key"),
                           .init("存在设置文件之外。", "Stored outside the settings file.")),
            "baseURL": Note(.init("端点", "Endpoint"),
                            .init("留空 = 用 provider 的默认值。",
                                  "Leave it empty to use the provider's default.")),
            "maxUses": Note(.init("每次请求最多搜几次", "Searches per Request")),
        ],

        // ── 我们自己的插件 ────────────────────────────────────────────
        "surf-nativeify": [
            "bodyFontSize": Note(.init("对话区字号", "Conversation Font Size"),
                                 .init("只管对话正文那一列；控件、侧边栏、工具调用行钉在系统的 13pt 上。",
                                       "Applies to the conversation column only; controls, the sidebar and tool-call rows stay at the system 13pt."),
                                 unit: .same("px")),
        ],
        "surf-notify": [
            "enabled": Note(.init("开启桌面通知", "Enable Desktop Notifications"),
                            .init("关掉之后一条系统通知都不发。侧边栏那枚「待处理」胶囊不受影响"
                                  + "——关的是打扰，不是事实。",
                                  "With this off, no system notification is sent at all. "
                                  + "The sidebar's Pending pill is unaffected — this silences the interruption, not the fact.")),
            "approval": Note(.init("需要批准时", "When Approval Is Needed")),
            "question": Note(.init("智能体提问时", "When the Agent Asks a Question")),
            "done": Note(.init("一个回合跑完时", "When a Turn Finishes")),
            "error": Note(.init("智能体出错时", "When the Agent Fails")),
            "actionableApproval": Note(.init("通知上可以直接放行", "Approve from the Notification"),
                                       .init("关掉之后通知上只剩「拒绝」与「打开查看」，"
                                             + "放行必须进 app 看清上下文再点。",
                                             "With this off the notification offers only Deny and Open, "
                                             + "so approving means opening the app and reading the context first.")),
            "sound": Note(.init("通知带提示音", "Play a Sound")),
            "doneWhenForeground": Note(.init("app 在前台也报「跑完了」",
                                             "Report Finished Turns in the Foreground"),
                                       .init("默认只在你没盯着 app 时报。待批准与待回答不受这一项影响。",
                                             "By default a finished turn is reported only when you are not watching the app. Approvals and questions are unaffected.")),
            "badgeIncludesDone": Note(.init("角标算上「跑完了」与「出错」",
                                            "Count Finished and Failed Turns in the Badge"),
                                      .init("默认只数待批准与待回答——那两类是欠着的事。",
                                            "By default only approvals and questions are counted — those are the ones that owe you something.")),
        ],
        // 键位名一律与壳菜单里那一条**逐字对齐**（`surf-app/host/Sources/Strings.swift`
        // 的 `menuNewSession` 等）：这一栏改的就是那条菜单项的键，两处叫法不同
        // 会让人以为改的是别的东西。菜单里带省略号的（重命名）在这儿不带——
        // 省略号是"还要再问一步"的承诺，设置行本身不问。
        "surf-shortcuts": [
            "newSession": Note(.init("新建会话", "New Session")),
            "prevSession": Note(.init("上一个会话", "Previous Session")),
            "nextSession": Note(.init("下一个会话", "Next Session")),
            "nextPendingSession": Note(.init("下一个待处理会话", "Next Pending Session")),
            "archiveSession": Note(.init("归档会话", "Archive Session")),
            "renameSession": Note(.init("重命名会话", "Rename Session")),
            "focusSearch": Note(.init("聚焦搜索", "Focus Search")),
            "openSettings": Note(.init("打开设置", "Open Settings")),
            // 选项显示成真正按下去的样子而不是配置值：这一格挑的是修饰键，
            // 「cmd」当着标签既不像键也不像话。
            "sessionDigits": Note(.init("数字键跳转", "Jump by Number"),
                                  .init("按住修饰键加 1～9 直接跳到第 N 个会话。",
                                        "Hold the modifier and press 1–9 to jump straight to that session."),
                                  options: ["cmd": .same("⌘1–9"),
                                            "cmd+alt": .same("⌥⌘1–9"),
                                            "off": .init("关闭", "Off")]),
            "stopGenerating": Note(.init("停止生成", "Stop Generating"),
                                   .init("在网页内匹配，不是菜单项；留空即关掉这个键。",
                                         "Matched inside the web page rather than by a menu item. Leave it empty to turn the key off.")),
        ],

        // ── 模型页 ───────────────────────────────────────────────────
        "agent-default-model": [
            "provider": Note(.init("默认 provider", "Default Provider")),
            "model": Note(.init("默认模型", "Default Model")),
            "reasoningEffort": Note(.init("思考强度", "Reasoning Effort")),
        ],
    ]

    static func note(ns: String, path: [String]) -> Note? {
        table[ns]?[path.joined(separator: "/")]
    }

    /// 显示用标题：有注解用注解，没有就机械美化 key。
    ///
    /// **兜底路径两种语言共用一份**：`humanize` 出的是 `Max Output Bytes` 这类
    /// 由真 key 拆出来的英文词，它本来就不是"中文文案的英文版"，而是"没有文案时
    /// 把机器名念得像句人话"。zh 界面下露出英文字段名是可接受的
    /// ——那正是配置文件里写着的东西，反而比编一个中文名更好查（README「字段文案从哪来」）。
    static func title(ns: String, path: [String], locale: SurfLocale) -> String {
        note(ns: ns, path: path)?.title[locale] ?? SettingsFormat.humanize(path.last ?? "")
    }

    /// 枚举值的显示文案。没注解就原样——**不机械美化**：
    /// `danger-full-access` 美化成 `Danger Full Access` 只是换了种机器味，
    /// 而且会让用户在配置文件里搜不到它。
    static func optionLabel(ns: String, path: [String],
                            value: JSONValue, locale: SurfLocale) -> String {
        guard case .string(let raw) = value else { return value.summary(locale) }
        return note(ns: ns, path: path)?.options?[raw]?[locale] ?? raw
    }
}

/// 命名空间的文案与精选——对应 Web「插件」页那一张张手风琴卡片。
enum NamespaceNotes {

    struct Note {
        let title: LocalizedText
        let summary: LocalizedText?
        /// Web 在这张卡片上露出来的字段（顺序即 Web 的顺序）。
        /// 其余字段进「其余」那一段，**不丢**。
        let featured: [String]
    }

    private static let table: [String: Note] = [
        "shell": Note(title: .init("终端", "Shell"),
                      summary: .init("限制智能体跑的每一条命令。",
                                     "Limits every command the agent runs."),
                      featured: ["timeoutMs", "maxOutputBytes"]),
        "agent-loop": Note(title: .init("智能体循环", "Agent Loop"),
                           summary: .init("智能体怎么派发工具调用。",
                                          "How the agent dispatches tool calls."),
                           featured: ["maxParallelToolCalls"]),
        "web-search-deepseek": Note(title: .init("网页搜索", "Web Search"),
                                    summary: .init("DeepSeek 的搜索 provider。",
                                                   "DeepSeek's search provider."),
                                    featured: ["apiKey", "baseURL", "maxUses"]),

        // 下面两个 Web 完全没露。**我们仍旧显示**（零遗漏），但至少给个人话标题
        // ——机械美化出来的 "Llm Pi Ai" / "Ui Onboarding" 谁也看不懂。
        "llm-pi-ai": Note(title: .init("自定义 provider", "Custom Providers"),
                          summary: .init("「模型」页逐个编辑更顺手；这里是完整的原始配置。",
                                         "The Models tab edits these one at a time; this is the full raw configuration."),
                          featured: []),
        "ui-onboarding": Note(title: .init("引导状态", "Onboarding State"),
                              summary: .init("记着新手引导放到哪儿了，一般不用动。",
                                             "Remembers how far onboarding got. You rarely need to touch it."),
                              featured: []),

        // 我们自己的。机械美化会得到 "Surf Nativeify"，那是包名不是人话。
        "surf-nativeify": Note(title: .init("原生观感", "Native Feel"),
                               summary: .init("网页那半边的排版与手感。",
                                              "Typography and feel of the web half."),
                               featured: ["bodyFontSize"]),
        // 精选的四个就是「什么时候通知我」——那是绝大多数人唯一会来动的东西。
        // 其余五个（直接批准、声音、前台策略、角标口径）归"其余"，想细调再展开。
        "surf-notify": Note(title: .init("通知", "Notifications"),
                            summary: .init("什么时候给你发桌面通知。",
                                           "When to send you a desktop notification."),
                            featured: ["enabled", "approval", "question", "done", "error"]),
        // 精选 = 八条真的挂在菜单上的键。线下面那两条是**另一类东西**：
        // `sessionDigits` 挑的是修饰键前缀而不是一个键，`stopGenerating`
        // 由页面自己在 keydown 上匹配、根本不是菜单项。
        "surf-shortcuts": Note(title: .init("快捷键", "Shortcuts"),
                               summary: .init("只收「改了确实更好用」的那几条；⌘W、⌘Q 这类系统惯例刻意不给改。",
                                              "Only the shortcuts worth rebinding. System conventions such as ⌘W and ⌘Q are deliberately left alone."),
                               featured: ["newSession", "prevSession", "nextSession",
                                          "nextPendingSession", "archiveSession",
                                          "renameSession", "focusSearch", "openSettings"]),
    ]

    static func note(ns: String) -> Note? { table[ns] }

    /// 见 `FieldNotes.title` 那条注释：兜底的机械美化两种语言共用一份。
    static func title(ns: String, locale: SurfLocale) -> String {
        table[ns]?.title[locale] ?? SettingsFormat.humanize(ns)
    }

    static func summary(ns: String, locale: SurfLocale) -> String? {
        table[ns]?.summary?[locale]
    }

    /// 把一个 ns 的顶层字段切成「精选」和「其余」两段。
    ///
    /// 没有精选表的 ns（上游新装的插件）**整段都算精选**——不认识它不等于
    /// 该把它藏起来。宁可多显示，不可静默丢。
    static func split(ns: String, fields: [SchemaField]) -> (featured: [SchemaField], rest: [SchemaField]) {
        guard let order = table[ns]?.featured else { return (fields, []) }
        let featured = order.compactMap { key in fields.first { $0.key == key } }
        let picked = Set(featured.map(\.key))
        return (featured, fields.filter { !picked.contains($0.key) })
    }
}
