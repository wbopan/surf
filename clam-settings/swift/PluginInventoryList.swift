import SwiftUI

/// 「插件列表」——一张真正的 `Table`。
///
/// 上一版是 `LazyVGrid` 两列 + 自画的卡片 + 点开展开。那是把一个表格伪装成了
/// 一堆卡片：171 条里找一个插件要扫两列，条目 id 得点开才看得见，而排序、多选、
/// 键盘导航、列宽调整**一样都没有**——全是自己搭清单的必然代价。
///
/// `Table(of:selection:sortOrder:)` 把这些全白送：
/// - 表头点一下就排序（`sortOrder` 绑上去即可）
/// - ⌘/⇧ 多选、键盘上下键走行
/// - 列宽拖拽
/// - `.tableStyle(.bordered(alternatesRowBackgrounds: true))` = 参考设计里
///   「共享给你」那张表的样子：一圈边框、隔行底色
///
/// 条目 id 从"点开才看得到"变成常驻的一列，**于是"展开"这个交互整个消失了**。
///
/// **这一栏是只读的，Web 那边也是。** 上游 `pluginInventory` 只有一个 `list()`，
/// 它客户端包的 README 在 Known Limitations 里写死了 "Read-only Loader view …
/// does not add plugin mutation controls"。那个「已启用/已停用」是编排表的投影，
/// 不是开关——给一个点了不动的开关比没有开关糟得多。
struct PluginInventoryList: View {
    @ObservedObject var model: SettingsModel

    @State private var query = ""
    @State private var selection: InventoryRow.ID?
    /// **初值是空数组**：空 = 不排序 = 保持 Loader 顺序，而那个顺序本身有信息量
    /// （谁在谁前面装是能解释依赖的）。用户点了表头才进入排序模式。
    @State private var order: [KeyPathComparator<InventoryRow>] = []

    /// 一行的**显示投影**。
    ///
    /// 为什么不直接拿 `InventoryEntry` 画：状态那一列的**排序键就是它的显示文案**
    /// （见下面 `TableColumn` 那条注释），而 `Table(sortOrder:)` 要的
    /// `KeyPathComparator` 只能指到**存储**属性上——文案一旦跟着语言走，就没法再是
    /// `InventoryEntry` 上的一个计算属性（那个 struct 是桥上只读数据的原样投影，
    /// 造出来的时候不知道语言）。所以在这里就地算一次，落成一行数据。
    struct InventoryRow: Identifiable {
        let id: String
        let shortName: String
        let entryId: String
        let moduleName: String
        let enabled: Bool
        let fiberPhase: String?
        /// 相位的人话（`已挂载` / `Active`）。状态点的 tooltip 用它。
        let phaseLabel: String
        /// 状态列显示什么——**同时就是这一列的排序键**。用户看到什么就按什么排。
        let statusText: String
    }

    /// 搜索同时打在短名、完整模块名、条目 id 上——**id 也是搜索目标**（照 Web）：
    /// 想找"include 底下都装了什么"时，唯一能匹配上的就是 id 的前缀。
    private var rows: [InventoryRow] {
        let strings = model.strings
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let matched = needle.isEmpty ? model.inventory : model.inventory.filter {
            $0.shortName.lowercased().contains(needle)
                || $0.moduleName.lowercased().contains(needle)
                || $0.entryId.lowercased().contains(needle)
        }
        var list = matched.map { entry in
            InventoryRow(id: entry.entryId,
                         shortName: entry.shortName,
                         entryId: entry.entryId,
                         moduleName: entry.moduleName,
                         enabled: entry.enabled,
                         fiberPhase: entry.fiberPhase,
                         phaseLabel: strings.pluginPhase(entry.fiberPhase),
                         statusText: strings.pluginStatus(enabled: entry.enabled,
                                                          phase: entry.fiberPhase))
        }
        if !order.isEmpty { list.sort(using: order) }
        return list
    }

    private var disabledCount: Int { model.inventory.count { !$0.enabled } }

    var body: some View {
        let strings = model.strings
        if !model.inventoryAvailable {
            message(strings.inventoryUnavailable)
        } else if let error = model.inventoryError {
            VStack(alignment: .leading, spacing: 6) {
                Text(strings.inventoryUnreadable).font(.callout)
                // 原因是 host 的原话，不翻。
                Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Button(strings.retry) { model.refresh() }.controlSize(.small)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                NativeSearchField(text: $query, prompt: strings.searchPlugins)
                    .frame(height: 22)
                    .accessibilityIdentifier("settings.inventory.search")

                // 表头传的是 `String` 变量而不是字面量——`TableColumn(_:value:)`
                // 那个 `LocalizedStringKey` / `LocalizedStringResource` 重载歧义
                // （README「四条踩过的坑」最后一条）因此不成立了。
                Table(rows, selection: $selection, sortOrder: $order) {
                    TableColumn(strings.columnName, value: \.shortName) { row in
                        Text(row.shortName).help(row.moduleName)
                    }
                    TableColumn(strings.columnEntry, value: \.entryId) { row in
                        Text(row.entryId)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .help(row.moduleName)
                    }
                    // 排序键取显示文案而不是 `enabled` 这个 Bool，两个理由：用户看到
                    // 什么就按什么排；而且 Bool 的键路径在这儿会解析到 `SortDescriptor`
                    // 那一族，跟 `Table(sortOrder:)` 要的 `KeyPathComparator` 对不上
                    // ——String 的键路径有专用重载，没有这个歧义。
                    TableColumn(strings.columnStatus, value: \.statusText) { row in
                        HStack(spacing: 5) {
                            // 状态点只给启用的条目——停用的没有 root Fiber，
                            // 画个灰点只是噪声。
                            if row.enabled {
                                StatusDot(color: phaseColor(row), help: row.phaseLabel)
                            }
                            Text(row.statusText)
                                .foregroundStyle(row.enabled ? .primary : .secondary)
                        }
                    }
                    .width(min: 88, ideal: 100, max: 140)
                }
                .tableStyle(.bordered(alternatesRowBackgrounds: true))
                .frame(maxHeight: .infinity)

                Text(query.isEmpty
                     ? strings.inventorySummary(total: model.inventory.count,
                                                disabled: disabledCount)
                     : strings.inventoryMatches(shown: rows.count, total: model.inventory.count))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func message(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text).font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func phaseColor(_ row: InventoryRow) -> Color {
        switch row.fiberPhase {
        case "active": return .green
        case "failed": return .red
        case "pending", "loading", "unloading": return .orange
        default: return .secondary.opacity(0.4)
        }
    }
}
