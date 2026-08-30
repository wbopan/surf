import Foundation
import Observation
import SwiftUI

/// 槽注册表：谁占了哪个槽、第几代、怎么造视图。
///
/// **只放拓扑，不放流量**（计划 §0.5-4）。高频业务数据住各插件自己的 model；
/// 这里每次变动都会驱动整棵 SwiftUI 重建，放流量等于每帧重建。
///
/// 全进程一份，住在 SDK dylib 里，因此它的类型身份跨插件、跨世代稳定。
/// 线程约定：**只在主线程使用**（壳的装载器与 SwiftUI 都在主线程）。
/// 这里不加 `@MainActor`——M2 没有覆盖跨 dylib 的 actor 边界，
/// 少一个未验证的变量比多一层静态保证划算。
@Observable
public final class SurfRegistry {
    /// 一个槽的占用记录。
    public struct Entry {
        /// 占用者插件名（诊断用，如 `surf-layout`）。
        public let owner: String
        /// 世代号。消费方对视图挂 `.id(version)`：跳变即整棵重建，
        /// `@State` 归零，由 `SurfStore` 或 TS 半身 rehydrate。
        public let version: Int
        /// 视图工厂。每次重建调用一次。
        public let make: () -> AnyView
        /// 注册身份。撤销时比对，防止旧世代的析构顺手删掉新世代的注册。
        fileprivate let token: UUID
    }

    private(set) public var entries: [String: Entry] = [:]

    public init() {}

    /// 占一个槽。同名槽后来者覆盖前者——这正是世代替换的做法。
    ///
    /// - Parameters:
    ///   - slot: 槽名。壳只认得 `root`；其余槽名由插件之间自行约定
    ///     （如 surf-layout 认得 `sidebar`）。
    ///   - owner: 插件名，进诊断。
    ///   - version: 世代号，取插件装载时壳给的那个。
    ///   - make: 视图工厂。
    /// - Returns: 撤销句柄。**只撤销自己那一次注册**：如果槽已经被更新的一代
    ///   接管，撤销是空操作。
    @discardableResult
    public func register(slot: String,
                         owner: String,
                         version: Int,
                         make: @escaping () -> AnyView) -> SurfDisposable {
        let token = UUID()
        entries[slot] = Entry(owner: owner, version: version, make: make, token: token)
        return SurfDisposable { [weak self] in
            guard let self, self.entries[slot]?.token == token else { return }
            self.entries.removeValue(forKey: slot)
        }
    }

    /// 造一个槽的视图；没人占则 nil（调用方据此走 fallback）。
    public func view(for slot: String) -> AnyView? {
        entries[slot]?.make()
    }

    /// 槽的世代号；没人占时返回 0。消费方用它做 `.id(...)`。
    public func version(of slot: String) -> Int {
        entries[slot]?.version ?? 0
    }

    public func owner(of slot: String) -> String? {
        entries[slot]?.owner
    }

    public func isOccupied(_ slot: String) -> Bool {
        entries[slot] != nil
    }
}
