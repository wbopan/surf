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
    @State private var selection: InventoryEntry.ID?
    /// **初值是空数组**：空 = 不排序 = 保持 Loader 顺序，而那个顺序本身有信息量
    /// （谁在谁前面装是能解释依赖的）。用户点了表头才进入排序模式。
    @State private var order: [KeyPathComparator<InventoryEntry>] = []

    /// 搜索同时打在短名、完整模块名、条目 id 上——**id 也是搜索目标**（照 Web）：
    /// 想找"include 底下都装了什么"时，唯一能匹配上的就是 id 的前缀。
    private var rows: [InventoryEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        var list = needle.isEmpty ? model.inventory : model.inventory.filter {
            $0.shortName.lowercased().contains(needle)
                || $0.moduleName.lowercased().contains(needle)
                || $0.entryId.lowercased().contains(needle)
        }
        if !order.isEmpty { list.sort(using: order) }
        return list
    }

    private var disabledCount: Int { model.inventory.count { !$0.enabled } }

    var body: some View {
        if !model.inventoryAvailable {
            message("读不到插件清单（pluginInventory 服务不在场）。")
        } else if let error = model.inventoryError {
            VStack(alignment: .leading, spacing: 6) {
                Text("暂时无法读取插件。").font(.callout)
                Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Button("重试") { model.refresh() }.controlSize(.small)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                NativeSearchField(text: $query, prompt: "搜索插件")
                    .frame(height: 22)
                    .accessibilityIdentifier("settings.inventory.search")

                Table(rows, selection: $selection, sortOrder: $order) {
                    TableColumn("名称", value: \.shortName) { entry in
                        Text(entry.shortName).help(entry.moduleName)
                    }
                    TableColumn("条目", value: \.entryId) { entry in
                        Text(entry.entryId)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .help(entry.moduleName)
                    }
                    // 排序键是 `statusText` 而不是 `enabled`，见 InventoryEntry 那边的注释。
                    TableColumn("状态", value: \.statusText) { entry in
                        HStack(spacing: 5) {
                            // 状态点只给启用的条目——停用的没有 root Fiber，
                            // 画个灰点只是噪声。
                            if entry.enabled {
                                StatusDot(color: phaseColor(entry), help: entry.phaseLabel)
                            }
                            Text(entry.statusText)
                                .foregroundStyle(entry.enabled ? .primary : .secondary)
                        }
                    }
                    .width(min: 88, ideal: 100, max: 140)
                }
                .tableStyle(.bordered(alternatesRowBackgrounds: true))
                .frame(maxHeight: .infinity)

                Text(query.isEmpty
                     ? "\(model.inventory.count) 个插件 · \(disabledCount) 个已停用 · 默认顺序即装载顺序"
                     : "匹配 \(rows.count) / \(model.inventory.count)")
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

    private func phaseColor(_ entry: InventoryEntry) -> Color {
        switch entry.fiberPhase {
        case "active": return .green
        case "failed": return .red
        case "pending", "loading", "unloading": return .orange
        default: return .secondary.opacity(0.4)
        }
    }
}
