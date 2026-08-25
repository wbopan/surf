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

    /// 槽注册表（共享）。
    public let registry: DashRegistry
    /// 宿主对象保管箱（共享）。
    public let objects: DashObjects
    /// 进程内事件总线（共享）。
    public let events: DashEventBus
    /// 本插件的持久化命名空间。
    public let store: DashStore
    /// 本插件与自己 TS 半身的通道。
    public let bridge: DashBridge

    private let logger: (String) -> Void

    public init(plugin: String,
                generation: Int,
                registry: DashRegistry,
                objects: DashObjects,
                events: DashEventBus,
                store: DashStore,
                bridge: DashBridge,
                log: @escaping (String) -> Void) {
        self.plugin = plugin
        self.generation = generation
        self.registry = registry
        self.objects = objects
        self.events = events
        self.store = store
        self.bridge = bridge
        self.logger = log
    }

    /// 写一行进壳的日志（`<AppSupport>/logs/dash.log`），自动带插件名与世代号。
    public func log(_ message: String) {
        logger(message)
    }

    /// 注册槽的糖：世代号与插件名自动带上。
    @discardableResult
    public func register(slot: String, make: @escaping () -> AnyView) -> DashDisposable {
        registry.register(slot: slot, owner: plugin, version: generation, make: make)
    }
}
