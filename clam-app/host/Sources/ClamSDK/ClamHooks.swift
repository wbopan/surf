import Foundation

/// 应答式钩子表：**系统要求在 app 启动早期就位、而实现方是运行时才装载的插件**
/// 的那一类接线。
///
/// ## 为什么需要它（而 `ClamEventBus` 不够）
///
/// 事件总线是广播 + 无返回值 + 谁在听谁听。有三类需求它表达不了：
///
/// 1. **要答复**：系统 delegate 的方法往往要同步返回一个值
///    （"这条要不要现在显示"、"这个 URL 你处理了吗"）。
/// 2. **一槽一主**：delegate 的语义是"唯一负责人"，不是"所有听众"。
/// 3. **早鸟事件**：回调可能在插件装载之前就到达（app 冷启动那几秒里，
///    dylib 还没编完）。广播出去没人听就是丢了；这里留着等人认领。
///
/// ## 为什么这是通用设施，不是给某个功能开的后门
///
/// 表里**一个具体的 hook 名都没有**——与 `ClamRegistry`/`ClamContributions`
/// 同一条纪律：SDK 只放机制，槽名/主题名/hook 名全是插件与壳之间的字符串约定。
/// 壳那侧的 `SystemDelegateRelay` 负责占住系统 delegate 并把回调**原样拍平**
/// 成字典，不解释任何语义。
///
/// 第一个住户是 `UNUserNotificationCenter.delegate`——实测（2026-08-27）
/// **在 app 启动很久之后设置它，系统不再回调**（读回一致、方法不进），
/// Apple 文档那句"必须在 app 完成启动前设置"是硬约束而不是建议。
/// 同一形状的后续住户是可预见的：URL scheme 打开、Dock 拖放、Services 菜单、
/// `NSUserActivity` 接力——它们都要求"启动时就有一个 objc 对象在位"。
/// 加一个住户 = 壳的 relay 多占一个 delegate + 多两行拍平代码，
/// **SDK 与插件协议一个字不动**。
///
/// 载荷同 `ClamEventBus`：只放 JSON 能表达的值。答复也是。
/// 线程约定：只在主线程使用。
public final class ClamHooks {
    /// 进程级单例。壳与插件都用这一份，不必接线（同 `ClamContributions.shared`）。
    public static let shared = ClamHooks()

    private struct Handler {
        let owner: String
        let version: Int
        let token: UUID
        let body: ([String: Any]) -> [String: Any]?
    }

    /// 一个 hook 最多留多少条未认领的早鸟事件。
    ///
    /// 有界是刻意的：留着是为了"插件晚了几秒"，不是为了给一个永远没人接的 hook
    /// 做无限缓冲。满了丢**最老的**——晚到的那条更可能是用户此刻在等的。
    private static let retainedLimit = 8

    private var handlers: [String: Handler] = [:]
    private var retained: [String: [[String: Any]]] = [:]

    public init() {}

    /// 接一个 hook。**同名后来者覆盖前者**——世代替换正是这么做的。
    ///
    /// 接上的瞬间，若该 hook 有未认领的早鸟事件，**按到达顺序立刻回放**
    /// （答复被丢弃：那一拍早过去了，没人在等返回值）。
    ///
    /// - Returns: 撤销句柄。**只撤自己那一次**：hook 已被更新的一代接管时，
    ///   撤销是空操作（与 `ClamRegistry.register` 同款 token 校验）。
    @discardableResult
    public func handle(_ hook: String,
                       owner: String,
                       version: Int,
                       _ body: @escaping ([String: Any]) -> [String: Any]?) -> ClamDisposable {
        let token = UUID()
        handlers[hook] = Handler(owner: owner, version: version, token: token, body: body)
        if let backlog = retained.removeValue(forKey: hook) {
            for payload in backlog { _ = body(payload) }
        }
        return ClamDisposable { [weak self] in
            guard let self, self.handlers[hook]?.token == token else { return }
            self.handlers.removeValue(forKey: hook)
        }
    }

    /// 派发一次，同步拿答复。没人接 → nil（调用方走自己的默认行为）。
    @discardableResult
    public func dispatch(_ hook: String, _ payload: [String: Any] = [:]) -> [String: Any]? {
        handlers[hook]?.body(payload)
    }

    /// 派发一次；**没人接就留着**，等有人接上再回放。
    ///
    /// 给"必须送达、但可以晚几秒"的回调用（用户点了一条通知，而插件还没装完）。
    /// 要答复的回调用 `dispatch` ——留到几秒后的答复没有意义。
    public func dispatchRetained(_ hook: String, _ payload: [String: Any] = [:]) {
        if handlers[hook] != nil {
            _ = handlers[hook]?.body(payload)
            return
        }
        var backlog = retained[hook] ?? []
        backlog.append(payload)
        if backlog.count > Self.retainedLimit { backlog.removeFirst(backlog.count - Self.retainedLimit) }
        retained[hook] = backlog
    }

    /// 诊断用：当前有主的 hook 及其主人。
    ///
    /// **眼下全仓零调用方**——⌥⌘D 面板还没有遍历它（那是审计 P1-11 的事）。
    /// 留着是因为它是"我这个 hook 注册上了吗"唯一的可编程答案；调试插件时
    /// 在自己的 `activate` 里打一行就能用。
    public var occupancy: [(hook: String, owner: String, version: Int, pending: Int)] {
        handlers.map { ($0.key, $0.value.owner, $0.value.version, retained[$0.key]?.count ?? 0) }
            .sorted { $0.0 < $1.0 }
    }
}
