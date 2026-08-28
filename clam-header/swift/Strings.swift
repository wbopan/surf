import ClamSDK
import Foundation

/// clam-header 的全部**用户可见**文案，zh 与 en 并排写在同一行（审校时一眼对照）。
///
/// ## 纪律（`docs/clam-i18n-plan.md` §4/§5/§8，与壳、clam-sidebar 的 `Strings.swift` 同一套）
///
/// - **只收用户看得见的字**。`host.log(...)` 与 node 半边的日志一律留在原地、
///   保持中文：日志的读者是蹲在终端前的开发者与 agent，跟着界面语言变只会让
///   排错时对不上账。
/// - **一条文案都不进 ClamSDK**：SDK 只有 `ClamLocale` 这个词汇。
/// - **带插值的条目写成方法**，不搞 `{name}` 模板替换。
/// - **漏写 en 编译不过**：typed struct 就是完备性检查。
/// - **数据不翻，只翻兜底词**：会话标题、preset 名、tab 名都是 dsh 给的原样字符串
///   （dsh 自己说中文还是英文由它的 locale 决定），这里只管"没有标题时叫什么"
///   这类我们自己造的词。
///
/// ## 取值的地方
///
/// `HeaderModel.strings` **现算一份 `L`**（读 `ClamLocaleStore.current`，不存快照）。
/// 于是 `HeaderToolbarSync` 那圈 `withObservationTracking` 天然把语言也纳入依赖：
/// 换语言 = model 变了一次 = 活通道（`clam.toolbar.update`）自己重推一遍
/// ——**没有为 i18n 新增任何观察者**（那条静默死亡坑，CLAUDE.md）。
///
/// 工具栏那四格的 `label` 是**拓扑键**，不走活通道：`HeaderPlugin` 订 `clam.locale`
/// 后重新贡献同一组 `(owner, id)`，整条工具栏重建（CLAUDE.md 的分界：
/// label/order/kind 这些走 metadata，徽标/菜单/选中态走活通道，两者不许混）。
///
/// ## 与 dsh 页面用词对齐
///
/// 面包屑与子代理 catalog 讲的是与 dsh 页面同一批东西，所以词是**照抄 dsh 的
/// 词典**而不是自己造的（`dsh-client-ui-subagent` / `dsh-client-ui-jobs` 的
/// `zh` / `en` 两份 `Record`）：「子代理」「{count} 个子代理」「一次性」「可继续」
/// 「{count} 个后台任务」/ "subagent" / "background job"。同一个会话在两半
/// 界面上出现时，用词必须是一个。
///
/// ## 打磨过的条目带 `// 原：…` 注释
///
/// zh 按 Apple 简体中文风格正式化，en 菜单/按钮 Title Case、描述句 Sentence case。
/// 语气或用词改动较大的在行尾标出原文，供 i6 汇总成审校表交用户裁决。
struct L {

    let locale: ClamLocale

    init(_ locale: ClamLocale) { self.locale = locale }

    /// 二选一。写成函数只为让 zh / en 挤在同一行——没有任何查表逻辑。
    private func t(_ zh: String, _ en: String) -> String { locale == .zh ? zh : en }

    /// 「<数字> <量词>」。zh 只有一种形态，en 分单复数。
    ///
    /// 空格是**照 dsh 词典抄的**（它的 zh 写 `{count} 个子代理`，数字与量词之间
    /// 有一个空格），不是随手加的。
    private func count(_ n: Int, zh: String, one: String, many: String) -> String {
        locale == .zh ? "\(n) \(zh)" : "\(n) \(n == 1 ? one : many)"
    }

    // MARK: - 工具栏那四格的 label（拓扑键，见类型注释）

    /// 会话谱系那一格：祖先导航 + 兄弟切换 + 子代理进入。
    var subagentsLabel: String { t("子代理", "Subagents") }
    /// 段控整组的 label（Icon and Text 模式与溢出菜单里露脸）。
    /// **分段自己的名字不在这儿**：那是页面报上来的 `model.tabs`，见 `HeaderPlugin`。
    var viewTabsLabel: String { t("会话视图", "Session View") }
    var modeLabel: String { t("模式", "Mode") }
    var exportLabel: String { t("导出", "Export") }

    // MARK: - 窗口标识（window.title / subtitle）

    /// 没有标题的会话怎么称呼。
    ///
    /// 与 clam-sidebar 用同一个词是**必须的**：同一个会话此刻既是侧边栏里的一行、
    /// 又是窗口标题，两处叫法不同就是明摆着的自相矛盾。
    var untitledSession: String { t("新会话", "New Session") }  // 原：未命名会话（对齐 clam-sidebar 与 dsh 的 session.new）

    /// 「2/5 个后台任务运行中」/ "2 of 5 background jobs running"。
    /// 「后台任务」与 en 的 "background job" 抄自 dsh 的 `ui-jobs` 词典。
    func jobsRunning(_ running: Int, of total: Int) -> String {
        t("\(running)/\(total) 个后台任务运行中",
          "\(running) of \(total) background jobs running")
    }  // 原：N/M 个任务运行中（补上「后台」，与 dsh 同词）

    /// 一个都没在跑时只报总数。
    func backgroundJobs(_ total: Int) -> String {
        count(total, zh: "个后台任务", one: "background job", many: "background jobs")
    }

    // MARK: - 会话谱系菜单

    /// 整格的 tooltip：有子代理就报数，没有就说这个菜单是干什么的。
    var sessionLineage: String { t("会话谱系", "Session Lineage") }

    /// 「3 个子代理」/ "3 subagents"（照抄 dsh 的 `count.total`）。
    func subagentCount(_ n: Int) -> String {
        count(n, zh: "个子代理", one: "subagent", many: "subagents")
    }

    /// 一条点不动的占位项（这个会话在链上、但自己没有下级）。
    var noSubagents: String { t("没有子代理", "No Subagents") }

    /// 带子菜单的项自己点不动，所以子菜单第一条得是"进它自己"。
    var openThisSubagent: String { t("打开这个子代理", "Open This Subagent") }

    /// 子代理的运行形态。取值来自 dsh（`one-shot` / `continuable`），
    /// 说法也照抄它的 `mode.oneShot` / `mode.continuable`。
    ///
    /// en 这里**首字母大写**，与上游词典的小写不同：上游那两个词长在一行密排的
    /// 指标里，我们这条是 AppKit 菜单项的次要行，macOS 的菜单文案一律大写开头。
    func subagentMode(_ raw: String?) -> String {
        raw == "one-shot" ? t("一次性", "One-shot") : t("可继续", "Continuable")
    }

    /// 在跑还是停了。zh 抄 dsh 的 `activity.running`。
    func subagentActivity(running: Bool) -> String {
        running ? t("正在运行", "Running") : t("已停止", "Stopped")
    }  // 原：运行中 / 已停止

    // MARK: - 模式（agent preset）那一格

    /// 「模式：默认」/ "Mode: Default"。冒号跟着语言走（全角 / 半角）。
    func modeTooltip(_ current: String) -> String {
        t("模式：\(current)", "Mode: \(current)")
    }

    /// 坏掉的 preset 仍然列出（它占着那个 id），但标出来点不动。
    /// **名字由调用方定好再递进来**（出厂的查 `builtInPreset`、用户自己写的原样用），
    /// 这里只翻括号里那句。
    func presetUnavailable(_ label: String) -> String {
        t("\(label)（不可用）", "\(label) (Unavailable)")
    }

    /// 一个 preset 都没选中时的说法。
    var defaultPreset: String { t("默认", "Default") }

    /// **随部署出厂的那四个 preset 的名字**（`trust == "system"`）。认不出就给 nil，
    /// 调用方退回投影里那个 `label`。
    ///
    /// 这是**照抄上游的规则**，不是另立一份真相：`agentPresets.list` 给的 `name`
    /// 是 preset 目录里那份文件写死的字（这台机器上是中文），而 dsh 的网页
    /// 在 `presetDisplayText` 里对 `trust === "system"` 的四个改查自己的词典
    /// ——不照做的话就会出现"网页写 Standard mode、原生写「标准模式」"，
    /// 正是不变量 2（两半永远不许各说各话）禁止的那种分叉。用户自己写的 preset
    /// 上游明说不翻（"without making user-authored metadata translatable"），
    /// 这里也不翻。
    ///
    /// **id 与措辞都跟 `dsh-client-ui-agent-preset` 逐字对齐**，上游改了这里也要改。
    func builtInPreset(_ id: String) -> String? {
        switch id {
        case "standard": return t("标准模式", "Standard mode")
        case "code": return t("PTC 模式", "PTC mode")
        case "minimal": return t("极简模式", "Minimal mode")
        case "cordis": return t("创造模式", "Creator mode")
        default: return nil
        }
    }

    // MARK: - 时长（`HeaderFormatting.duration` 的措辞半边）

    /// 「约 2 年 3 个月」/ "about 2 years 3 months"（`months == 0` 时只报年）。
    func approximateDuration(years: Int, months: Int) -> String {
        let head = count(years, zh: "年", one: "year", many: "years")
        guard months > 0 else { return t("约 \(head)", "about \(head)") }
        let tail = count(months, zh: "个月", one: "month", many: "months")
        return t("约 \(head) \(tail)", "about \(head) \(tail)")
    }

    /// 「约 2 个月 5 天」/ "about 2 months 5 days"（`days == 0` 时只报月）。
    func approximateDuration(months: Int, days: Int) -> String {
        let head = count(months, zh: "个月", one: "month", many: "months")
        guard days > 0 else { return t("约 \(head)", "about \(head)") }
        let tail = count(days, zh: "天", one: "day", many: "days")
        return t("约 \(head) \(tail)", "about \(head) \(tail)")
    }

    /// 「5 天 4 小时」/ "5 days 4 hours"（`hours == 0` 时只报天）。
    func duration(days: Int, hours: Int) -> String {
        let head = count(days, zh: "天", one: "day", many: "days")
        guard hours > 0 else { return head }
        return "\(head) \(count(hours, zh: "小时", one: "hour", many: "hours"))"
    }

    /// 「30 秒」/ "30 seconds"。不到一分钟才走这条。
    func duration(seconds: Int) -> String {
        count(seconds, zh: "秒", one: "second", many: "seconds")
    }
}
