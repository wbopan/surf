import Foundation

/// node 半边推下来的一份**全量** header 投影（焦点会话的那几样事实）。
///
/// **这些类型每一代自己 decode，实例绝不过界。** 它们出自插件 module，换代后就是
/// 新旧两个互不认识的同名类型（M2 断言 4）——跨代活着的是保管箱里那份
/// `NSDictionary`（系统类型，跨代安全），不是这里的任何一个 struct。
///
/// 解码一律"宽进"：字段缺了取默认、整包解不动就当没收到（保留上一份）。
/// 数据真相在 dsh 侧，投影跟不上顶多晚半秒；为一个字段崩掉整条工具栏才是灾难。
struct HeaderSnapshot {
    /// 面包屑的一段。
    struct Crumb: Decodable {
        let id: String
        /// 会话标题；空会话没有标题（`projections.values.title` 缺席）。
        /// **fallback 文案归显示层**，数据层不编造。
        let title: String?
        /// 子代理段（祖先链上除根以外的每一段）。
        let subagent: Bool
    }

    /// 一个可选的 agent preset。
    struct PresetOption: Decodable {
        let id: String
        /// 显示名；上游 `name` 缺席时 node 侧已退回 id。
        let label: String
        /// 坏掉的 preset 仍然列出（它占着这个 id），但不该被选中。
        let broken: Bool
        /// `"system"` = 随部署出厂，名字由 `L.builtInPreset` 翻；
        /// `"user"` = 用户自己写的，`label` 原样用（上游也是这么分的）。
        /// 老投影没有这个字段，缺省当 `"user"`（= 与 i3 的行为一致）。
        let trust: String?
    }

    /// mode 那一格。部署不编排 preset 时整个为 nil。
    struct Preset: Decodable {
        /// 这个会话**实际在跑的** composition，不是部署当前的默认值。
        let current: String?
        let options: [PresetOption]
        /// 非 blank 会话不能改（历史里的工具调用是旧 composition 下产生的）。
        let locked: Bool
    }

    /// 后台任务，**只有两个数字**。
    ///
    /// 上游 ui-jobs 自己也只给看不给停，所以它退进了 subtitle，这里只报计数。
    struct Jobs: Decodable {
        let count: Int
        let running: Int
    }

    /// catalog 树的一个节点（一个子代理会话）。
    ///
    /// **时长不是一个算好的数**：给的是 `settledMs` / `activeSince` /
    /// `activeThrough` / `running` 四个原始值，由 `HeaderDuration` 在本地
    /// 用一个每秒 tick 的时钟推进。node 半边每秒重投一整棵树是不可接受的。
    struct SubagentNode: Decodable {
        /// 归一化后的 id（`session-` 前缀齐全）——**只当本地的键用**。
        let id: String
        /// 上游认的原始 id。发 `openSubagent` 必须用它，见 node 半边的注释。
        let rawId: String
        /// 日志投影出来的标题；空会话没有。
        let title: String?
        /// descriptor 上的创建标签。**优先于 title 显示**——上游原话
        /// "a catalog label overrides the session-summary title"。
        let label: String?
        /// `one-shot` / `continuable`；descriptor 坏了或缺席时为 nil。
        let mode: String?
        let running: Bool
        /// 四个不相交 tokenUsage 桶之和；没有用量投影时 nil。
        let tokens: Double?
        /// 已完成轮次累计毫秒。
        let settledMs: Double
        /// 未闭合轮次的起点；没有开着的轮次时 nil。
        let activeSince: Double?
        /// 该轮次折进本次投影切面的最后事件时刻。**inactive 时以它为界**，
        /// 不用更新的会话元数据（上游：被打断的未闭合轮次以同切 through 为界）。
        let activeThrough: Double?
    }

    /// 一个会话的后代总数（沿 subagent-only 链累加，遇普通 fork 即止）。
    struct Descendants: Decodable {
        let count: Int
        let runningCount: Int
    }

    /// 焦点所在的那一整棵 subagent 树，**一次给全**。
    ///
    /// 上游 client 只拿得到直接 catalog，所以必须逐层懒加载 + 铺 loading 行；
    /// node 半边一次 `session.list` 就有全树，于是展开是纯本地操作、零往返。
    struct SubagentTree: Decodable {
        /// 链的根（面包屑第一段，它自己不是 subagent）。
        let root: String
        /// 根的原始 id——`subagents.list` 要的 parentSessionId 就是它。
        let rootRaw: String
        /// 父 id → 直接子代 id（建立顺序）。
        let byParent: [String: [String]]
        let nodes: [String: SubagentNode]
        let descendants: [String: Descendants]

        /// 某个会话的直接子代节点，缺失的 id 静默跳过。
        func children(of parent: String) -> [SubagentNode] {
            (byParent[parent] ?? []).compactMap { nodes[$0] }
        }

        /// 名字不叫 `descendants(of:)`：那会和同名存储属性在方法体内互相遮蔽。
        /// 归一化 id → 上游认的原始 id。根不在 `nodes` 里，单独兜。
        func rawId(of id: String) -> String {
            nodes[id]?.rawId ?? (id == root ? rootRaw : id)
        }

        /// 某个节点的父。`byParent` 是正向索引，反查一次即可（树很小）。
        func parent(of id: String) -> String? {
            byParent.first { $0.value.contains(id) }?.key
        }

        func descendantTally(of id: String) -> Descendants {
            descendants[id] ?? Descendants(count: 0, runningCount: 0)
        }
    }

    /// 焦点会话的全部 header 事实。没有焦点时为 nil。
    struct Session: Decodable {
        let id: String
        /// 祖先链，**根在前**。
        let crumbs: [Crumb]
        let preset: Preset?
        let jobs: Jobs
        /// 这棵树上一个子代理都没有时为 nil（计数下拉整个不出现）。
        let subagents: SubagentTree?
    }

    let version: Int
    let session: Session?

    static let empty = HeaderSnapshot(version: 0, session: nil)

    /// 从桥的 `[String: Any]` 载荷解一份出来；形状不对返回 nil（当作没收到）。
    static func decode(_ payload: [String: Any]) -> HeaderSnapshot? {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let value = try? JSONDecoder().decode(Wire.self, from: data)
        else { return nil }
        return HeaderSnapshot(version: value.version ?? 0, session: value.session)
    }

    /// 只为解码存在的中间层：两个字段都可缺，缺了走默认而不是抛错。
    private struct Wire: Decodable {
        let version: Int?
        let session: Session?
    }
}
