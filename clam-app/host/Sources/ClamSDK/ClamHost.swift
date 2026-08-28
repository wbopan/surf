import Foundation
import SwiftUI

/// 壳递给插件的世界。
///
/// 是 final class 而不是协议：这样跨 dylib 只剩 `ClamPlugin` 一处协议见证表，
/// ABI 面越窄越不容易在换代时出意外。壳负责构造，每个插件拿到属于自己的一份
/// （`store` 命名空间、`bridge` 通道、`log` 前缀都是本插件专属，
/// 而 `registry`/`objects`/`events` 是全进程共享的那一份）。
public final class ClamHost {
    /// 本插件名（如 `clam-sidebar`）。
    public let plugin: String
    /// 本次装载的世代号。注册槽时原样传给 `ClamRegistry.register`。
    public let generation: Int

    /// 槽注册表（共享）。单占用："谁占了这个表面"。
    public let registry: ClamRegistry
    /// 贡献槽注册表（共享）。多占用："谁往这个表面加了一条"。
    public let contributions: ClamContributions
    /// 宿主对象保管箱（共享）。
    public let objects: ClamObjects
    /// 进程内事件总线（共享）。
    public let events: ClamEventBus
    /// 应答式钩子表（共享）。给"系统要求启动时就位的 delegate"那一类接线用。
    public let hooks: ClamHooks
    /// 本插件的持久化命名空间。
    public let store: ClamStore
    /// 本插件与自己 TS 半身的通道。
    public let bridge: ClamBridge

    private let logger: (String) -> Void

    /// `contributions` 有默认值（SDK dylib 里的进程级单例），壳不必显式接线；
    /// 想自己持有就传进来覆盖。其余参数一律由壳提供。
    public init(plugin: String,
                generation: Int,
                registry: ClamRegistry,
                contributions: ClamContributions = .shared,
                objects: ClamObjects,
                events: ClamEventBus,
                hooks: ClamHooks = .shared,
                store: ClamStore,
                bridge: ClamBridge,
                log: @escaping (String) -> Void) {
        self.plugin = plugin
        self.generation = generation
        self.registry = registry
        self.contributions = contributions
        self.objects = objects
        self.events = events
        self.hooks = hooks
        self.store = store
        self.bridge = bridge
        self.logger = log
    }

    /// 写一行进壳的日志（`<AppSupport>/logs/surfclam.<worktree>.log`，一个 App 实例一份），
    /// 自动带插件名与世代号。
    public func log(_ message: String) {
        logger(message)
    }

    /// 接一个系统钩子的糖：世代号与插件名自动带上。
    ///
    /// hook 名是**壳与插件之间的字符串约定**，SDK 一个都不认得
    /// （与槽名、事件主题同纪律）。现有的那几个写在壳的
    /// `Native/SystemDelegateRelay.swift` 顶部。
    @discardableResult
    public func handle(hook: String,
                       _ body: @escaping ([String: Any]) -> [String: Any]?) -> ClamDisposable {
        hooks.handle(hook, owner: plugin, version: generation, body)
    }

    /// 注册槽的糖：世代号与插件名自动带上。
    @discardableResult
    public func register(slot: String, make: @escaping () -> AnyView) -> ClamDisposable {
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
                           make: @escaping () -> AnyView) -> ClamDisposable {
        contributions.register(contributionTo: slot, owner: plugin, id: id,
                               order: order, version: generation,
                               metadata: metadata, make: make)
    }
}
