import Foundation
import SwiftUI

/// 壳递给插件的世界。
///
/// 是 final class 而不是协议：这样跨 dylib 只剩 `DashPlugin` 一处协议见证表，
/// ABI 面越窄越不容易在换代时出意外。壳负责构造，每个插件拿到属于自己的一份
/// （`store` 命名空间、`bridge` 通道、`log` 前缀都是本插件专属，
/// 而 `registry`/`objects`/`events` 是全进程共享的那一份）。
public final class DashHost {
    /// 本插件名（如 `dash-sidebar`）。
    public let plugin: String
    /// 本次装载的世代号。注册槽时原样传给 `DashRegistry.register`。
    public let generation: Int

    /// 槽注册表（共享）。单占用："谁占了这个表面"。
    public let registry: DashRegistry
    /// 贡献槽注册表（共享）。多占用："谁往这个表面加了一条"。
    public let contributions: DashContributions
    /// 宿主对象保管箱（共享）。
    public let objects: DashObjects
    /// 进程内事件总线（共享）。
    public let events: DashEventBus
    /// 本插件的持久化命名空间。
    public let store: DashStore
    /// 本插件与自己 TS 半身的通道。
    public let bridge: DashBridge

    private let logger: (String) -> Void

    /// `contributions` 有默认值（SDK dylib 里的进程级单例），壳不必显式接线；
    /// 想自己持有就传进来覆盖。其余参数一律由壳提供。
    public init(plugin: String,
                generation: Int,
                registry: DashRegistry,
                contributions: DashContributions = .shared,
                objects: DashObjects,
                events: DashEventBus,
                store: DashStore,
                bridge: DashBridge,
                log: @escaping (String) -> Void) {
        self.plugin = plugin
        self.generation = generation
        self.registry = registry
        self.contributions = contributions
        self.objects = objects
        self.events = events
        self.store = store
        self.bridge = bridge
        self.logger = log
    }

    /// 写一行进壳的日志（`<AppSupport>/logs/dash.<worktree>.log`，一个 App 实例一份），
    /// 自动带插件名与世代号。
    public func log(_ message: String) {
        logger(message)
    }

    /// 注册槽的糖：世代号与插件名自动带上。
    @discardableResult
    public func register(slot: String, make: @escaping () -> AnyView) -> DashDisposable {
        registry.register(slot: slot, owner: plugin, version: generation, make: make)
    }

    /// 往贡献槽加一条的糖：世代号与插件名自动带上。
    ///
    /// `id` 只需在自己名下唯一——`(plugin, id)` 才是身份，所以第三方插件
    /// 起什么 id 都不会撞上别人。同一 id 再调 = 覆盖自己那一条（换代姿势）。
    @discardableResult
    public func contribute(to slot: String,
                           id: String,
                           order: Double = 0,
                           metadata: [String: Any] = [:],
                           make: @escaping () -> AnyView) -> DashDisposable {
        contributions.register(contributionTo: slot, owner: plugin, id: id,
                               order: order, version: generation,
                               metadata: metadata, make: make)
    }
}
