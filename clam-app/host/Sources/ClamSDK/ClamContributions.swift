import Foundation
import Observation
import SwiftUI

/// 贡献槽：**多占用**注册表。`ClamRegistry` 的孪生兄弟，区别只在基数。
///
/// - `ClamRegistry` 是"替换槽"：一槽一主，后来者覆盖前者。适合 root / sidebar
///   这种独占表面——两个插件同时画侧边栏是没有意义的。
/// - `ClamContributions` 是"贡献槽"：一槽 N 条，各家追加、互不影响。适合工具栏
///   按钮、状态栏指示器、菜单项这种"谁都可以来一条"的表面。
///
/// **为什么单独一个类而不是给 ClamRegistry 加个数组**：两种槽的撤销语义不一样
/// （替换槽的撤销是"如果还是我就摘掉"，贡献槽的撤销是"只摘我这一条"），
/// 消费方的观察粒度也不一样。混在一个类型里，两边的 API 都会变得要看注释才敢用。
///
/// **只放拓扑，不放流量**（同 ClamRegistry）：这里每次变动都会驱动消费方重建。
///
/// 全进程一份，住在 SDK dylib 里，因此类型身份跨插件、跨世代稳定。
/// 线程约定：**只在主线程使用**。这里不加 `@MainActor`，理由同 `ClamRegistry`
/// 顶部注释——M2 没有覆盖跨 dylib 的 actor 边界，少一个未验证的变量更划算。
///
/// ## 这里只有容器，没有词汇
///
/// SDK 不定义 `ToolbarItemSpec` 之类的具体 UI 类型：那会把"工具栏长什么样"
/// 冻进 ABI，而壳是预编译产物、第三方改不了它。载荷只有两样东西——
/// 一个视图工厂，一份 `metadata: [String: Any]`（约定只放 JSON 能表达的值）。
/// 每个槽的 metadata 键名由**占用该槽的消费方**定义并写在自己家里
/// （如 `toolbar` 槽的约定写在 clam-layout 的 LayoutSplitController 里），
/// 就像槽名本身也是插件之间自行约定的一样。
@Observable
public final class ClamContributions {
    /// 进程级默认实例。
    ///
    /// SDK dylib 全进程只有一份（随 app bundle 分发，壳与所有插件都链接它），
    /// 所以这个 static 天然就是进程级单例——和 `ClamRegistry` 由壳持有再注入
    /// 是同一个效果，只是少了一条穿过壳的接线。壳日后想自己持有，
    /// 给 `ClamHost.init` 传 `contributions:` 覆盖即可。
    public static let shared = ClamContributions()

    /// 一条贡献。
    public struct Contribution {
        /// 贡献者插件名（诊断用，如 `clam-layout`）。
        public let owner: String
        /// 贡献者自定的条目 id。`(owner, id)` 是这条贡献的身份。
        public let id: String
        /// 排序权重，小的在前。同权重按首次注册顺序稳定排列。
        public let order: Double
        /// 贡献者的世代号。消费方可以拿它拼进 `.id(...)` 触发重建。
        public let version: Int
        /// 载荷元数据。键名由消费方约定；约定只放 JSON 能表达的值。
        public let metadata: [String: Any]
        /// 视图工厂。每次重建调用一次。
        public let make: () -> AnyView

        /// 注册身份。撤销时比对，防止旧世代的析构顺手删掉新世代的注册。
        fileprivate let token: UUID
        /// 首次注册序号，用作同 `order` 时的稳定排序键。同一 `(owner, id)`
        /// 重新注册（= 换代）时**保留**旧序号，这样热替换不会让按钮跳位置。
        fileprivate let seq: UInt64

        /// `(owner, id)` 的字符串形式。消费方拿它做视图 id / 控件 identifier。
        public var key: String { "\(owner)/\(id)" }
    }

    private(set) public var entries: [String: [Contribution]] = [:]

    /// 版本信号：任何一条贡献增删改都 +1。
    ///
    /// 消费方观察它来触发重算/重建（SwiftUI 里读一下它就建立了依赖，
    /// AppKit 消费方则可以把它当成"该重扫一遍"的信号）。
    /// 不用 `entries` 本身当信号是因为 `Contribution` 里有闭包，没法比较相等。
    private(set) public var revision: Int = 0

    private var nextSeq: UInt64 = 0

    public init() {}

    /// 往一个贡献槽里加一条。
    ///
    /// - Parameters:
    ///   - slot: 槽名。壳一个都不认得，全部由插件之间自行约定
    ///     （如 clam-layout 认得 `toolbar`）。
    ///   - owner: 贡献者插件名。
    ///   - id: 贡献者自定的条目 id，在自己名下唯一即可。
    ///   - order: 排序权重，小的在前。
    ///   - version: 世代号，取插件装载时壳给的那个。
    ///   - metadata: 消费方约定的载荷。
    ///   - make: 视图工厂。
    /// - Returns: 撤销句柄。**只摘自己那一条**：同 `(owner, id)` 已被更新的一代
    ///   接管时，撤销是空操作。
    ///
    /// 同一 `(owner, id)` 再注册 = 就地覆盖自己的旧条（这正是世代替换的姿势：
    /// 新一代先注册好，壳再松手放掉旧 handle，旧 disposable 因为 token 对不上
    /// 而空转）。不同 `(owner, id)` 互不影响，追加。
    @discardableResult
    public func register(contributionTo slot: String,
                         owner: String,
                         id: String,
                         order: Double = 0,
                         version: Int = 0,
                         metadata: [String: Any] = [:],
                         make: @escaping () -> AnyView) -> ClamDisposable {
        let token = UUID()
        var list = entries[slot] ?? []
        let existing = list.firstIndex { $0.owner == owner && $0.id == id }
        let seq: UInt64
        if let existing {
            seq = list[existing].seq // 换代保位：别让按钮在热替换时跳位置
        } else {
            seq = nextSeq
            nextSeq &+= 1
        }
        let entry = Contribution(owner: owner, id: id, order: order, version: version,
                                 metadata: metadata, make: make, token: token, seq: seq)
        if let existing {
            list[existing] = entry
        } else {
            list.append(entry)
        }
        entries[slot] = list
        revision &+= 1

        return ClamDisposable { [weak self] in
            guard let self else { return }
            guard var list = self.entries[slot],
                  let index = list.firstIndex(where: { $0.token == token }) else { return }
            list.remove(at: index)
            if list.isEmpty {
                self.entries.removeValue(forKey: slot)
            } else {
                self.entries[slot] = list
            }
            self.revision &+= 1
        }
    }

    /// 一个槽的全部贡献，按 `order` 升序；同 `order` 按首次注册顺序稳定排列。
    public func contributions(for slot: String) -> [Contribution] {
        (entries[slot] ?? []).sorted {
            $0.order == $1.order ? $0.seq < $1.seq : $0.order < $1.order
        }
    }

    /// 一个槽有没有人贡献。
    public func isOccupied(_ slot: String) -> Bool {
        !(entries[slot] ?? []).isEmpty
    }

    /// 一个槽的贡献者名单（诊断用，去重后按首次注册顺序）。
    public func owners(of slot: String) -> [String] {
        var seen = Set<String>()
        return contributions(for: slot).compactMap { seen.insert($0.owner).inserted ? $0.owner : nil }
    }
}
