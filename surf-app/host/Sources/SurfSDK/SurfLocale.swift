import Foundation
import Observation

/// 原生侧当前的界面语言。**值域跟 dsh 走，只有 `zh` / `en`**
/// （`@deepseek-ai/dsh-client-locale` 的 `LOCALES`）——本仓库不新增语言、
/// 不加「跟随系统」选项：dsh 那边「设置缺省 = 环境推导」本身就是跟随系统。
///
/// 语言的唯一权威是 dsh 的 `locale.preference` 设置；这里只是它在原生侧的投影
/// （决议链见 `docs/archive/surf-i18n-plan.md` §3）。**SDK 里只有语言这个词汇，
/// 一条具体文案都不进来**——文案表各插件自己带（`swift/Strings.swift`）。
public enum SurfLocale: String, Sendable, CaseIterable {
    case zh
    case en

    /// 从一串语言标签里挑出该用哪种语言。
    ///
    /// 逐条取 primary subtag（`zh-Hans-CN` → `zh`、`en-GB` → `en`），
    /// **第一条命中已支持语言的赢**，一条都不中就是 `en`。
    ///
    /// 这不是随便定的规则，而是**逐字复刻 dsh 页面侧的 `detectBrowserLocale()`**
    /// （`dsh-client-locale/lib/client.js`：遍历 `navigator.languages`、取
    /// `split("-")[0]`、`LOCALES.find`、兜底 `"en"`）。两边必须给出同一个答案——
    /// 壳用 `Locale.preferredLanguages` 兜底时，WKWebView 的 `navigator.languages`
    /// 来自同一份系统语言，规则一致就不会出现"原生是中文、网页是英文"。
    public static func resolve(preferred: [String]) -> SurfLocale {
        for tag in preferred {
            let primary = tag.lowercased().split(separator: "-").first.map(String.init) ?? ""
            if let hit = SurfLocale(rawValue: primary) { return hit }
        }
        return .en
    }
}

/// 语言的可观察持有者：订上粘性主题 `surf.locale`，值一变 `current` 就变，
/// SwiftUI 视图读到它即建立观察依赖、自动重渲。
///
/// **为什么是它而不是 `withObservationTracking`**：手拉观察的那条路有个静默死亡坑
/// ——观察者没人强持有就当场失效，而且只在冷启动露馅（CLAUDE.md 记过案）。
/// 这里走 `@Observable` 属性 + SwiftUI 自动观察，没有需要谁强持有的观察者。
///
/// 用法：插件在 `activate` 里 `SurfLocaleStore(bus: host.events)`，塞进自家 model
/// （model 被视图闭包捕获 = 有生命周期锚），视图读 `model.locale.current`。
/// 订阅句柄由本对象持有，对象被回收时订阅一并撤销。
///
/// 线程约定同总线：**只在主线程使用**。
@Observable
public final class SurfLocaleStore {
    /// 此刻在役的语言。
    public private(set) var current: SurfLocale

    /// 订阅句柄。**必须有人接住**：`SurfDisposable` 一析构就把订阅撤了，
    /// 不存下来等于订完当场退订——不报错、不打日志，只是语言永远不跟着变。
    @ObservationIgnored private var subscription: SurfDisposable?

    /// - Parameters:
    ///   - bus: 事件总线（`host.events`）。
    ///   - initial: 还没收到任何广播时的取值。`surf.locale` 是**粘性**主题，
    ///     壳在启动第一句就 `emitSticky` 过一份，所以这个初值通常在
    ///     `subscribe` 那一刻就被同步覆盖掉了——它只兜住"壳还没发过"的时刻。
    public init(bus: SurfEventBus, initial: SurfLocale = .en) {
        current = initial
        // 粘性主题：subscribe 会同步回调一次最后那份载荷（见 SurfEventBus）。
        subscription = bus.subscribe(SurfEventBus.Topic.locale) { [weak self] payload in
            guard let self,
                  let raw = payload["locale"] as? String,
                  let next = SurfLocale(rawValue: raw),
                  next != self.current
            else { return }
            self.current = next
        }
    }
}
