import Foundation

/// node 半边推下来的一份**全量**会话投影（M10 数据面下移之后的唯一数据入口）。
///
/// **这些类型每一代自己 decode，实例绝不过界。** 它们出自插件 module，换代后就是
/// 新旧两个互不认识的同名类型（M2 断言 4）——跨代活着的是保管箱里那份
/// `NSDictionary`（系统类型，跨代安全），不是这里的任何一个 struct。
///
/// 解码一律"宽进"：字段缺了取默认、整包解不动就当没收到（保留上一份）。
/// 数据真相在 dsh 侧，投影跟不上顶多晚半秒；为一个字段崩掉整个侧边栏才是灾难。
struct SidebarSnapshot {
    struct Session: Decodable {
        let id: String
        /// 会话标题；空会话没有标题（`projections.values.title` 缺席）。
        let title: String?
        /// 副行摘要（尾部一条消息的文本）。node 半边还没取到时为 nil——
        /// 显示层留着两行的位置不填字，别塞"加载中"之类的占位。
        let preview: String?
        /// `running` / `pendingApproval` / `pendingQuestion` / `idle`。
        /// 用字符串而不是枚举过 wire：node 加了新状态时旧壳解码不会失败。
        let status: String
        /// epoch 毫秒（JSON 没有日期类型，Date 在 Swift 侧还原）。
        let updatedAt: Double
        /// 新建但还没落下第一句 prompt 的会话。
        let blank: Bool
        /// subagent 子会话。**投影里保留、显示层过滤**——可见性是 UI 政策，
        /// 见 `AppSidebarModel.visible`。
        let isSubagent: Bool
        /// 已归档。v3 起归档不再在 node 侧滤除（侧边栏有了「显示已归档」开关），
        /// 缺席按 false 解——旧 node 配新壳时归档行本来就不会来。
        let archived: Bool?

        var date: Date { Date(timeIntervalSince1970: updatedAt / 1000) }
    }

    struct Group: Decodable {
        let id: String
        /// 兜底组（未归入任何工作区）为 nil。
        let workspaceId: String?
        /// 工作区标题。兜底组为空串——**文案归显示层**，数据层不认「未分组」。
        let title: String
        let sessions: [Session]
    }

    let version: Int
    let groups: [Group]

    static let empty = SidebarSnapshot(version: 0, groups: [])

    /// 从桥的 `[String: Any]` 载荷解一份出来；形状不对返回 nil（当作没收到）。
    static func decode(_ payload: [String: Any]) -> SidebarSnapshot? {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let value = try? JSONDecoder().decode(Wire.self, from: data)
        else { return nil }
        return SidebarSnapshot(version: value.version ?? 0, groups: value.groups ?? [])
    }

    /// 只为解码存在的中间层：两个字段都可缺，缺了走默认而不是抛错。
    private struct Wire: Decodable {
        let version: Int?
        let groups: [Group]?
    }
}
