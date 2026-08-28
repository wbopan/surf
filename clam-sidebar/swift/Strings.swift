import ClamSDK
import Foundation

/// clam-sidebar 的全部**用户可见**文案，zh 与 en 并排写在同一行（审校时一眼对照）。
///
/// ## 纪律（`docs/clam-i18n-plan.md` §4/§5/§8，与壳的 `Strings.swift` 同一套）
///
/// - **只收用户看得见的字**。`host.log(...)` 的日志一律留在原地、保持中文：
///   日志的读者是蹲在终端前的开发者与 agent，跟着界面语言变只会让排错时对不上账。
///   要在日志里写"归档会话"这类动作名，显式取 `L(.zh)`（见 `AppSidebarModel.reportFailure`）。
/// - **一条文案都不进 ClamSDK**：SDK 只有 `ClamLocale` 这个词汇。
/// - **带插值的条目写成方法**，不搞 `{name}` 模板替换。
/// - **漏写 en 编译不过**：typed struct 就是完备性检查。
/// - 全是 `String`，没有 `LocalizedStringKey`——SwiftUI 那个隐式重载歧义坑
///   （`clam-settings/README.md` 记过案）在这种形态下自动消失，但别顺手把中文
///   字面量写回视图里。
/// - **定位标识与文案彻底解耦**：`sidebar.*` 那些 accessibilityIdentifier、
///   「按时间」分段的 `TimeBuckets.Bucket` id 都是稳定英文串，一个字都不随语言变。
///
/// ## 取值的地方
///
/// `AppSidebarModel.strings` 现算一份 `L`（读 `ClamLocaleStore.current`）。
/// SwiftUI 视图读 `model.strings` 就建立了对那个 `@Observable` 的观察依赖，
/// 语言一变自动重渲——**不用 `withObservationTracking`**（静默死亡坑，CLAUDE.md）。
/// 工具栏那条贡献不在 SwiftUI 里，由 `SidebarPlugin` 订 `clam.locale` 后重新贡献
/// （`label` 是拓扑键，重注册即整条工具栏重建）。
///
/// ## 打磨过的条目带 `// 原：…` 注释
///
/// 这一遍不是机械搬运：zh 按 Apple 简体中文风格正式化（对照 macOS 系统 App 用词、
/// 菜单项动词开头、不用"您"），en 菜单/按钮 Title Case、描述句 Sentence case。
/// 语气改动较大的在行尾标出原文，供 i6 汇总成审校表交用户裁决。
struct L {

    let locale: ClamLocale

    init(_ locale: ClamLocale) { self.locale = locale }

    /// 二选一。写成函数只为让 zh / en 挤在同一行——没有任何查表逻辑。
    private func t(_ zh: String, _ en: String) -> String { locale == .zh ? zh : en }

    // MARK: - 通用按钮

    var ok: String { t("好", "OK") }
    var cancel: String { t("取消", "Cancel") }
    var rename: String { t("重命名", "Rename") }
    var delete: String { t("删除", "Delete") }
    var add: String { t("添加", "Add") }

    // MARK: - 会话行

    /// 行尾那枚归档符号的 AX label（不是按钮，是修饰）。
    var archivedBadge: String { t("已归档", "Archived") }
    /// hover 出的归档按钮 + 右键菜单项。
    var archiveSession: String { t("归档会话", "Archive Session") }
    var renameEllipsis: String { t("重命名…", "Rename…") }
    var forkSession: String { t("分叉会话", "Fork Session") }
    /// 没有标题的会话怎么称呼（投影层就把它填进 `title`，见 `AppSidebarModel`）。
    var untitledSession: String { t("新会话", "New Session") }

    // MARK: - 分组头

    var newSession: String { t("新建会话", "New Session") }
    /// 分组头 hover 出的加号。
    var newSessionInWorkspace: String { t("在此工作区新建会话", "New Session in This Workspace") }
    var collapseGroup: String { t("收起分组", "Collapse Group") }
    var expandGroup: String { t("展开分组", "Expand Group") }
    var deleteWorkspaceEllipsis: String { t("删除工作区…", "Remove Workspace…") }  // 原：删除工作区…（en 用 Remove：目录不会被删）
    /// 没有工作区的那一组。数据层不给标题（文案不归它管），显示层收口。
    var ungrouped: String { t("未分组", "Ungrouped") }

    // MARK: - 搜索与筛选胶囊

    var searchPlaceholder: String { t("搜索", "Search") }
    var filterAll: String { t("全部", "All") }
    var filterTime: String { t("按时间", "By Date") }  // 原：按时间（en 按分段的实际维度写：那四段是日期）
    var filterPending: String { t("待处理", "Pending") }

    // MARK: - 「按时间」的分段（id 是稳定英文串，见 `TimeBuckets`）

    func timeBucket(_ bucket: TimeBuckets.Bucket) -> String {
        switch bucket {
        case .today: return t("今天", "Today")
        case .yesterday: return t("昨天", "Yesterday")
        case .lastSevenDays: return t("过去 7 天", "Previous 7 Days")  // 原：前 7 天（对齐访达的分组用词）
        case .earlier: return t("更早", "Earlier")
        }
    }

    // MARK: - 状态指示器（AX label；界面上是符号与转轮）

    var statusRunning: String { t("正在运行", "Running") }  // 原：运行中
    var statusPendingApproval: String { t("待批准", "Awaiting Approval") }
    var statusPendingQuestion: String { t("待回答", "Awaiting Answer") }
    var statusFailed: String { t("已出错", "Failed") }  // 原：出错了
    var statusDone: String { t("已完成", "Done") }  // 原：已跑完

    // MARK: - 重命名 / 删除对话框

    var renameSessionTitle: String { t("重命名会话", "Rename Session") }
    var renameWorkspaceTitle: String { t("重命名工作区", "Rename Workspace") }
    var sessionNameField: String { t("会话名称", "Session Name") }
    var workspaceNameField: String { t("工作区名称", "Workspace Name") }

    var deleteWorkspaceTitle: String { t("删除工作区", "Remove Workspace") }
    /// 非破坏性，说清代价：目录与会话记录都留着。
    func deleteWorkspaceMessage(_ title: String) -> String {
        t("将把「\(title)」从工作区列表中移除。文件夹与会话记录保留，其中的会话会显示在「未分组」下。",
          "“\(title)” will be removed from the workspace list. The folder and its session "
            + "history are kept, and its sessions move under “\(ungrouped)”.")
    }  // 原：将把「X」从工作区列表中移除。文件夹与会话记录会保留，其会话将显示在「未分组」下。

    // MARK: - 添加工作区（NSOpenPanel）

    var addWorkspace: String { t("添加工作区", "Add Workspace") }
    /// 选取面板的确认按钮与说明。
    var choosePanelPrompt: String { add }
    var chooseWorkspaceFolder: String {
        t("选取要作为工作区的文件夹", "Choose a folder to use as a workspace.")
    }  // 原：选择要作为工作区的文件夹

    // MARK: - 空态

    func noSearchResults(_ query: String) -> String {
        t("没有匹配「\(query)」的会话", "No sessions match “\(query)”.")
    }
    var noPendingSessions: String { t("没有待处理的会话", "Nothing is waiting for you.") }
    var noSessionsInFilter: String {
        t("当前筛选条件下没有会话", "No sessions match the current filters.")
    }  // 原：当前筛选下没有会话
    var noSessions: String { t("还没有会话", "No sessions yet.") }
    var clearFilters: String { t("清除筛选", "Clear Filters") }

    // MARK: - 工具栏那枚「筛选」

    var filterLabel: String { t("筛选", "Filter") }
    var filterTooltip: String { t("筛选会话", "Filter sessions") }
    var showArchived: String { t("显示已归档", "Show Archived") }

    // MARK: - 写操作失败（node 半边只推动作 id 与原因，文案在这儿组）

    var actionFailedTitle: String { t("操作失败", "Action Failed") }

    /// 「归档会话失败：<原因>」/「Failed to archive the session: <reason>」。
    ///
    /// zh 把动作名当名词短语接「失败」，en 接在 "Failed to " 后面当动词短语
    /// ——所以 `actionName` 两种语言的词性本就不同，不是同一句话的直译。
    func actionFailed(action: String, reason: String) -> String {
        let name = actionName(action)
        return t("\(name)失败：\(reason)", "Failed to \(name): \(reason)")
    }

    /// 动作 id → 说法。桥上传的是 id（机器可读），文案归显示层。
    /// 认不出的 id 原样回显（新 node 配旧壳时不至于变成一句空话）。
    func actionName(_ action: String) -> String {
        switch action {
        case "archive": return t("归档会话", "archive the session")
        case "renameSession": return t("重命名会话", "rename the session")
        case "fork": return t("分叉会话", "fork the session")
        case "createWorkspace": return t("添加工作区", "add the workspace")
        case "renameWorkspace": return t("重命名工作区", "rename the workspace")
        case "deleteWorkspace": return t("删除工作区", "remove the workspace")
        default: return action
        }
    }

    /// 失败原因：node 认领得了的走 `code`（文案在这儿），其余原样用上游那句话。
    ///
    /// **上游的原文不翻**（dsh 自己会说中文还是英文由它决定），我们只负责
    /// 自己这一侧合成的原因——那几条在 node 里是英文技术串，不该端给用户看。
    func failureReason(code: String?, message: String) -> String {
        switch code {
        case "notReady": return t("会话数据面尚未就绪", "The session data isn’t ready yet.")
        case "apiMissing": return t("dsh 不支持这个操作（版本对不上？）",
                                    "dsh doesn’t support this action (version mismatch?).")
        case "forkNoChild": return t("上游没有返回新会话", "No new session came back.")
        default: return message.isEmpty ? t("未知原因", "Unknown reason.") : message
        }
    }
}
