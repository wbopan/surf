import Foundation

/// catalog 行上那几个数字的显示规则。
///
/// **逐字复刻上游** `dsh-client-ui-subagent/lib/client.js` 的 `formatTokens` /
/// `splitDuration` / `formatDuration` / `formatExactDuration`。不自创：原生和
/// web 两处显示同一个会话时数字必须一模一样，否则用户会以为哪边算错了。
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
    static func duration(_ ms: Double) -> String {
        let s = split(ms)
        if s.days >= 365 {
            let years = s.days / 365
            let months = (s.days % 365) / 30
            return months == 0 ? "约 \(years) 年" : "约 \(years) 年 \(months) 个月"
        }
        if s.days >= 30 {
            let months = s.days / 30
            let rest = s.days % 30
            return rest == 0 ? "约 \(months) 个月" : "约 \(months) 个月 \(rest) 天"
        }
        if s.days > 0 {
            return s.hours == 0 ? "\(s.days) 天" : "\(s.days) 天 \(s.hours) 小时"
        }
        if s.totalHours > 0 {
            return "\(s.totalHours):\(pad(s.minutes)):\(pad(s.seconds))"
        }
        if s.totalMinutes > 0 { return "\(s.totalMinutes):\(pad(s.seconds))" }
        return "\(s.seconds) 秒"
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
