import SwiftUI

/// 壳↔插件的 ABI 词汇。全部是"世代无关"的类型：插件间、代际间传递安全。
/// 计划 §4.1 的最小可验证子集。

/// 每个插件 dylib 导出 @_cdecl("dash_plugin_entry")，返回指向本协议实现的
/// 不透明指针（Unmanaged.passRetained）。
public protocol DashPlugin: AnyObject {
    /// 返回一个 handle 交壳保管；壳释放 handle = 插件世代退休。
    func activate(host: DashHost) -> AnyObject?
}

/// 壳实现，递给插件。只放拓扑与保管箱，不放业务流量。
public protocol DashHost: AnyObject {
    /// 槽注册：版本号跳变时 layout 用 .id(version) 整棵重建。
    func register(slot: String, version: Int, factory: @escaping () -> AnyView)
    /// 宿主对象保管箱：只放系统/SDK 类型实例，跨代直通存活。
    func object(_ key: String) -> AnyObject?
    func setObject(_ key: String, _ value: AnyObject)
    /// 诊断通道（spike 里用来把插件内的观察结果带回宿主报告）。
    func note(_ message: String)
}

/// 插件可把自己的对象经 existential 交给壳，壳再转交别的插件——
/// 断言 5（SDK 词汇跨代）与断言 4（两代类型隔离）都走这条路。
public protocol DashOpaqueHandle: AnyObject {
    var identity: String { get }
    func ping() -> String
    /// 壳侧触发插件内部状态变更：验证 @Observable 跨 dylib 驱动 SwiftUI 重绘。
    func poke()
}
