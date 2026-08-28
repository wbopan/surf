import Foundation

/// catalog 行上那几个数字的显示规则。
///
/// **算法逐字复刻上游** `dsh-client-ui-subagent/lib/client.js` 的 `formatTokens` /
/// `splitDuration` / `formatDuration` / `formatExactDuration`：阈值、进位、
/// "30 天算一个月、365 天算一年"这些粗略换算一条没改。不自创：原生和 web 两处
/// 显示同一个会话时**数字**必须一模一样，否则用户会以为哪边算错了。
///
/// **措辞是我们自己的**（i18n 那一遍改的，`docs/clam-i18n-plan.md` §5）：
/// 上游的词典给的是密排指标里的缩写（zh `约{years}年{months}个月`、
/// en `~{years}y {months}mo`），而这几个数字在原生这边长在菜单项的次要行上，
/// 那里读的是句子不是指标。所以走 `L`：zh「约 2 年 3 个月」、
/// en "about 2 years 3 months"，单复数正确。数字本身不受影响。
enum HeaderFormatting {

    // MARK: - token

    /// `<1000` 原样；`<1e6` 用 K；再往上用 M。
    /// 缩放后 ≥100 取整，否则留一位小数（上游的 `scaled`）。
    static func tokens(_ value: Double) -> String {
        func scaled(_ next: Double) -> String {
            next >= 100 ? String(Int(next.rounded()))
                        : String(format: "%g", (next * 10).rounded() / 10)
        }
        if value < 1_000 { return String(Int(value)) }
        if value < 1_000_000 { return "\(scaled(value / 1_000))K" }
        return "\(scaled(value / 1_000_000))M"
    }

    // MARK: - 时长

    /// 拆成天/时/分/秒，外加两个"总量"。负数按 0 算。
    struct Split {
        let seconds: Int, minutes: Int, hours: Int, days: Int
        let totalMinutes: Int, totalHours: Int
    }

    static func split(_ ms: Double) -> Split {
        let totalSeconds = Int((max(0, ms) / 1000).rounded(.down))
        let totalMinutes = totalSeconds / 60
        let totalHours = totalMinutes / 60
        return Split(
            seconds: totalSeconds % 60,
            minutes: totalMinutes % 60,
            hours: totalHours % 24,
            days: totalHours / 24,
            totalMinutes: totalMinutes,
            totalHours: totalHours)
    }

    /// 视觉时长：**不到一天精确到秒**，再往上最多两个相邻单位
    /// （天/时 → 约月/日 → 约年/月）。上游那套阈值原样搬过来，
    /// 包括"30 天算一个月、365 天算一年"这种粗略换算。
    ///
    /// **分档在这儿、措辞在 `L` 里**：这一段是算术，翻不了；带单位的那几句是
    /// 文案，两种语言的量词与单复数规则本来就不同（"1 day" vs "2 days"，
    /// 而 zh 没有这回事），机械替换是替不出来的。
    ///
    /// 中间两档是**纯数字的钟面**（`3:04:05` / `4:05`），不含任何词——
    /// 两种语言一模一样，不过 `L`。
    static func duration(_ ms: Double, _ strings: L) -> String {
        let s = split(ms)
        if s.days >= 365 {
            return strings.approximateDuration(years: s.days / 365,
                                               months: (s.days % 365) / 30)
        }
        if s.days >= 30 {
            return strings.approximateDuration(months: s.days / 30, days: s.days % 30)
        }
        if s.days > 0 {
            return strings.duration(days: s.days, hours: s.hours)
        }
        if s.totalHours > 0 {
            return "\(s.totalHours):\(pad(s.minutes)):\(pad(s.seconds))"
        }
        if s.totalMinutes > 0 { return "\(s.totalMinutes):\(pad(s.seconds))" }
        return strings.duration(seconds: s.seconds)
    }

    private static func pad(_ value: Int) -> String {
        value < 10 ? "0\(value)" : String(value)
    }

    // MARK: - 活动时长

    /// 一行的活动时长。
    ///
    /// 上游 `activityDuration` 的三条规则原样：
    /// 1. 没有 timing 投影 → 不显示（nil）。
    /// 2. 没有未闭合轮次 → 就是已结算的累计值，**不随时钟走**。
    /// 3. 有未闭合轮次 → running 时推进到 `now`，否则**冻结在 `active.through`**
    ///    （被打断的轮次以同切 through 为界，而不是更新的会话元数据）。
    static func activityDuration(_ node: HeaderSnapshot.SubagentNode, now: Double) -> Double? {
        guard let since = node.activeSince else {
            // settledMs 恒有值（node 侧缺省 0），但"从没跑过"不该显示 0 秒。
            return node.settledMs > 0 ? node.settledMs : nil
        }
        let end = node.running ? now : (node.activeThrough ?? since)
        return node.settledMs + max(0, end - since)
    }
}

extension String {
    /// 有这个前缀就剥掉返回剩下的，没有返回 nil。
    /// 谱系菜单的 itemId 是 `goto:` / `open:` 两个命名空间，靠它分流。
    func dropPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
