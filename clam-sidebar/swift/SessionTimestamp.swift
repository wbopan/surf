import ClamSDK
import Foundation

/// 会话行尾那枚相对时间。
///
/// 四档，一档比一档粗：**今天给时刻、昨天给「昨天」、7 天内给周几、更早给短日期**。
/// 越近的会话越需要"几点"这种精度，越远的只需要"大概哪天"——一列扫下来，
/// 上半屏是时刻、下半屏是日期，本身就是一条时间轴。
///
/// **一个「昨天 / Yesterday」都不写进 `Strings.swift`**：`DateFormatter` 自己就会
/// 说这两句（`doesRelativeDateFormatting`），周几同理走
/// `setLocalizedDateFormatFromTemplate`。手写等于给系统已有的本地化开第二处真相，
/// 而且只覆盖我们支持的那两门语言。
///
/// **`DateFormatter` 很贵，必须缓存**：这东西每行每帧都要用，现建一个的话
/// 滚动就会掉帧。按语言缓存一整套（切语言不常发生，缓存里最多两份）。
///
/// 只在主线程用（`DateFormatter` 本身线程安全，这里的缓存不是）。
@MainActor
enum SessionTimestamp {

    /// 一门语言下的四个格式器。
    private struct Formatters {
        /// 今天：`HH:mm`（跟随地区的 12/24 小时制）。
        let time: DateFormatter
        /// 昨天：靠 `doesRelativeDateFormatting` 让系统说那两个字。
        let relative: DateFormatter
        /// 7 天内：周几。
        let weekday: DateFormatter
        /// 更早：短日期。
        let date: DateFormatter
    }

    private static var cache: [ClamLocale: Formatters] = [:]

    /// `ClamLocale` → `Foundation.Locale`。zh 明确要简体（`zh` 单独用会解析成
    /// 系统当前的中文变体，繁体机器上就成了繁体，而 dsh 那边只有简体）。
    private static func foundationLocale(_ locale: ClamLocale) -> Locale {
        switch locale {
        case .zh: return Locale(identifier: "zh_Hans")
        case .en: return Locale(identifier: "en")
        }
    }

    private static func formatters(_ locale: ClamLocale) -> Formatters {
        if let hit = cache[locale] { return hit }
        let loc = foundationLocale(locale)

        let time = DateFormatter()
        time.locale = loc
        time.setLocalizedDateFormatFromTemplate("jmm")

        let relative = DateFormatter()
        relative.locale = loc
        relative.dateStyle = .short
        relative.timeStyle = .none
        relative.doesRelativeDateFormatting = true

        let weekday = DateFormatter()
        weekday.locale = loc
        weekday.setLocalizedDateFormatFromTemplate("EEE")

        let date = DateFormatter()
        date.locale = loc
        date.dateStyle = .short
        date.timeStyle = .none

        let made = Formatters(time: time, relative: relative, weekday: weekday, date: date)
        cache[locale] = made
        return made
    }

    /// 行尾要显示的那一小串。`now` 只为可测（默认就是此刻）。
    static func text(for date: Date, locale: ClamLocale, now: Date = Date()) -> String {
        let set = formatters(locale)
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return set.time.string(from: date) }
        if calendar.isDateInYesterday(date) { return set.relative.string(from: date) }
        let days = calendar.dateComponents([.day],
                                           from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        if days >= 0 && days <= 7 { return set.weekday.string(from: date) }
        return set.date.string(from: date)
    }
}
