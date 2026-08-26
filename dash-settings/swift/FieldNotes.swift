import Foundation

/// 文案表——**整个界面唯一的人工输入**，内容对齐 dsh Web 设置对话框。
///
/// 背景（计划 §2.1）：schema 里一个字的文案都没有，meta 键全集只有
/// `required/default/role/step/min/max` 六个。所以"这个字段是什么意思"在结构化
/// 渠道里根本不存在——**Web 端也一样**，它同样是把标题和说明硬写在前端里的。
/// 既然两边都得手写，那就写成同一份：Web 有的照抄（翻成中文），Web 没有的机械美化。
///
/// **仍然不刮 Web 的编译产物**（计划 §1.3）。这里是我照着**跑起来的界面**读一遍
/// 然后手写的——一次性的阅读，不建立构建期依赖，dsh 升级了也不会有东西静默碎掉。
///
/// **表可以很小，而且应该很小**：
/// - 没有注解的字段照样出现，标签走 key 的机械美化，真 key 与约束进悬停提示。
///   零遗漏由渲染保证，不是由这张表保证。
/// - 表越大越容易变陈：上游改了字段语义，这里的中文不会自己更新，也没人会提醒。
///
/// 加一条的判据：**Web 里有这条文案**，或者**机械美化出来的名字会让人看不懂**。
enum FieldNotes {

    struct Note {
        /// 中文标题。没有就用 `SettingsFormat.humanize(key)`。
        let title: String
        /// 一句说明。可以没有。
        let hint: String?
        /// 单位。**跟在控件右边，不进标题**——"命令超时（毫秒）："这种标题会把
        /// `Form` 的标签列撑宽，而列宽是所有行共享的，一个长标题会顶歪整页。
        let unit: String?
        /// 枚举值的人话。schema 只给得出 `danger-full-access` 这种机器值。
        let options: [String: String]?

        init(_ title: String, _ hint: String? = nil,
             unit: String? = nil, options: [String: String]? = nil) {
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
            "default": Note("智能体预设", "已经在跑的会话不受影响。"),
        ],
        "permission": [
            "defaultPreset": Note("权限", options: [
                "read-only": "只读",
                "workspace-write": "可写工作区",
                "danger-full-access": "完全放开",
            ]),
        ],
        "locale": [
            "preference": Note("语言", options: ["zh": "中文", "en": "English"]),
        ],
        "ui-theme": [
            // 外观走三段式卡片（AppearancePicker），文案在那儿。
            "preference": Note("外观", options: [
                "light": "浅色", "dark": "深色", "system": "跟随系统",
            ]),
        ],
        "ui-conversation": [
            "busyEnter": Note("忙碌时 Enter 的行为", "⌘/Ctrl+Enter 走另一种。",
                              options: ["queue": "排队", "steer": "插话"]),
        ],

        // ── 插件页（Web: Plugins → Plugin configuration）───────────────
        "shell": [
            "timeoutMs": Note("命令超时", unit: "毫秒"),
            "maxOutputBytes": Note("单流输出上限",
                                   "超出的部分溢写到临时文件，不会丢。", unit: "字节"),
            // 下面这些 Web 没露，机械美化会难懂，所以照样给中文。
            "cwd": Note("工作目录"),
            "maxTimeoutMs": Note("超时上限", "调用方能要求的最大超时。", unit: "毫秒"),
            "maxSpillBytes": Note("溢写上限", unit: "字节"),
            "graceMs": Note("SIGTERM 宽限", unit: "毫秒"),
        ],
        "agent-loop": [
            "maxParallelToolCalls": Note("并行工具调用"),
        ],
        "web-search-deepseek": [
            "apiKey": Note("API key", "存在设置文件之外。"),
            "baseURL": Note("端点", "留空 = 用 provider 的默认值。"),
            "maxUses": Note("每次请求最多搜几次"),
        ],

        // ── 我们自己的插件 ────────────────────────────────────────────
        "dash-nativeify": [
            "bodyFontSize": Note("对话区字号",
                                 "只管对话正文那一列；控件、侧边栏、工具调用行钉在系统的 13pt 上。",
                                 unit: "px"),
        ],

        // ── 模型页 ───────────────────────────────────────────────────
        "agent-default-model": [
            "provider": Note("默认 provider"),
            "model": Note("默认模型"),
            "reasoningEffort": Note("思考强度"),
        ],
    ]

    static func note(ns: String, path: [String]) -> Note? {
        table[ns]?[path.joined(separator: "/")]
    }

    /// 显示用标题：有注解用注解，没有就机械美化 key。
    static func title(ns: String, path: [String]) -> String {
        note(ns: ns, path: path)?.title ?? SettingsFormat.humanize(path.last ?? "")
    }

    /// 枚举值的显示文案。没注解就原样——**不机械美化**：
    /// `danger-full-access` 美化成 `Danger Full Access` 只是换了种机器味，
    /// 而且会让用户在配置文件里搜不到它。
    static func optionLabel(ns: String, path: [String], value: JSONValue) -> String {
        guard case .string(let raw) = value else { return value.summary }
        return note(ns: ns, path: path)?.options?[raw] ?? raw
    }
}

/// 命名空间的文案与精选——对应 Web「插件」页那一张张手风琴卡片。
enum NamespaceNotes {

    struct Note {
        let title: String
        let summary: String?
        /// Web 在这张卡片上露出来的字段（顺序即 Web 的顺序）。
        /// 其余字段进「更多设置」折叠，**不丢**。
        let featured: [String]
    }

    private static let table: [String: Note] = [
        "shell": Note(title: "终端",
                      summary: "限制智能体跑的每一条命令。",
                      featured: ["timeoutMs", "maxOutputBytes"]),
        "agent-loop": Note(title: "智能体循环",
                           summary: "智能体怎么派发工具调用。",
                           featured: ["maxParallelToolCalls"]),
        "web-search-deepseek": Note(title: "网页搜索",
                                    summary: "DeepSeek 的搜索 provider。",
                                    featured: ["apiKey", "baseURL", "maxUses"]),

        // 下面两个 Web 完全没露。**我们仍旧显示**（零遗漏），但至少给个人话标题
        // ——机械美化出来的 "Llm Pi Ai" / "Ui Onboarding" 谁也看不懂。
        "llm-pi-ai": Note(title: "自定义 provider",
                          summary: "「模型」页逐个编辑更顺手；这里是完整的原始配置。",
                          featured: []),
        "ui-onboarding": Note(title: "引导状态",
                              summary: "记着新手引导放到哪儿了，一般不用动。",
                              featured: []),

        // 我们自己的。机械美化会得到 "Dash Nativeify"，那是包名不是人话。
        "dash-nativeify": Note(title: "原生观感",
                               summary: "网页那半边的排版与手感。",
                               featured: ["bodyFontSize"]),
    ]

    static func note(ns: String) -> Note? { table[ns] }

    static func title(ns: String) -> String {
        table[ns]?.title ?? SettingsFormat.humanize(ns)
    }

    static func summary(ns: String) -> String? { table[ns]?.summary }

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
