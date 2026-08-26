import Foundation

/// 字段注解表——**整个界面唯一的人工输入**。
///
/// 背景（计划 §2.1/§2.2）：schema 里一个字的文案都没有。复核过实际注册处，
/// `z.object({ cwd: z.string(), timeoutMs: z.number().default(12e4), … })` 全是裸节点，
/// meta 键全集只有 `required/default/role/step/min/max` 六个。所以"这个字段是什么
/// 意思"和"这个字段该不该抬到前面"这两样信息，在结构化渠道里根本不存在。
///
/// **设计取舍**：不刮上游的编译产物（那等于给自己安一根随时会断的线，升级 dsh 后
/// 要重跑、要 diff、要判断 diff 有没有意义）。这里全部手写，写的时候可以参考上游各包的
/// `README.zh.md`——那是文档不是产物，读它不建立任何构建期依赖。
///
/// **表可以很小**，而且应该很小：
/// - 没有注解的字段**照样出现**，标签走 key 的机械美化（`maxOutputBytes` →
///   `Max Output Bytes`），副标题显示类型与约束。零遗漏是平铺页保证的，不是这张表。
/// - 上游新增字段会自动出现，只是没有中文名——**没有信号丢失**。
/// - 反过来，表越大越容易变陈：上游改了字段语义，这里的中文说明不会自己更新，
///   也没有任何东西会提醒我们。所以只注解真正常用的那几个。
///
/// 加一条的判据：**我自己会在这一页上改它**。不是"它看起来重要"。
enum FieldNotes {

    struct Note {
        /// 中文标题。没有就用 `SettingsFormat.humanize(key)`。
        let title: String
        /// 一句说明。可以没有。
        let hint: String?
        /// 抬到「通用」页。
        let featured: Bool

        init(_ title: String, _ hint: String? = nil, featured: Bool = false) {
            self.title = title
            self.hint = hint
            self.featured = featured
        }
    }

    /// ns → 路径（用 `/` 连接）→ 注解。
    ///
    /// 路径用 `/` 连接是为了让这张表读起来像目录；查表时由 `note(ns:path:)` 拼。
    private static let table: [String: [String: Note]] = [
        "agent-presets": [
            "default": Note("默认 Agent 预设",
                            "新开的会话用哪个预设。已经在跑的会话保持它开始时的那个。",
                            featured: true),
        ],
        "permission": [
            "defaultPreset": Note("默认权限",
                                  "新会话的权限档位。",
                                  featured: true),
        ],
        "locale": [
            "preference": Note("界面语言", "留空 = 跟随浏览器。", featured: true),
        ],
        "ui-theme": [
            "preference": Note("外观", "浅色 / 深色 / 跟随系统。", featured: true),
        ],
        "ui-conversation": [
            "busyEnter": Note("忙碌时按 Enter",
                              "会话正在跑时 Enter 的行为；⌘/Ctrl+Enter 永远是另一种。",
                              featured: true),
        ],
        "agent-loop": [
            "maxParallelToolCalls": Note("并行工具调用上限",
                                         "一轮里最多同时跑几个工具。", featured: true),
        ],
        "shell": [
            "timeoutMs": Note("命令超时（毫秒）", "单条命令最多跑多久。", featured: true),
            "maxTimeoutMs": Note("命令超时上限（毫秒）", "调用方能要求的最大超时。"),
            "maxOutputBytes": Note("输出上限（字节）", "超出的部分溢写到临时文件。"),
            "maxSpillBytes": Note("溢写上限（字节）"),
            "graceMs": Note("SIGTERM 宽限（毫秒）", "先礼后兵：等这么久再 SIGKILL。"),
            "cwd": Note("工作目录"),
        ],
        "agent-default-model": [
            "provider": Note("默认 provider", featured: true),
            "model": Note("默认模型", featured: true),
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

    /// 「通用」页收哪些字段——顺序就是这里的顺序，**手写的顺序是有意的**：
    /// 按"多久改一次"排，不按 ns 排。
    static let featuredOrder: [(ns: String, path: [String])] = [
        (ns: "agent-presets", path: ["default"]),
        (ns: "permission", path: ["defaultPreset"]),
        (ns: "agent-default-model", path: ["provider"]),
        (ns: "agent-default-model", path: ["model"]),
        (ns: "ui-theme", path: ["preference"]),
        (ns: "locale", path: ["preference"]),
        (ns: "ui-conversation", path: ["busyEnter"]),
        (ns: "agent-loop", path: ["maxParallelToolCalls"]),
        (ns: "shell", path: ["timeoutMs"]),
    ]

    /// 这个 ns 里有没有被注解过的字段——平铺页据此决定要不要分「常用 / 其余」两段。
    static func hasNotes(ns: String) -> Bool {
        table[ns]?.isEmpty == false
    }

    static func isFeatured(ns: String, path: [String]) -> Bool {
        note(ns: ns, path: path)?.featured ?? false
    }
}
