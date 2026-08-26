import SwiftUI

/// 「插件列表」——对齐 dsh Web 的 Plugins → Plugin list。
///
/// **这一栏是只读的，Web 那边也是。** 用户记忆里"可以启动和关闭插件"其实是
/// 把状态标签当成了开关：上游 `pluginInventory` 服务只有一个 `list()`，它自己的
/// README 在 Known Limitations 里写着 "Read-only Loader view … does not add
/// plugin mutation controls"。所以这里也只显示不写——**给一个点了不动的开关，
/// 比没有开关糟得多**。真要启停得改编排表再重启，那是另一个层面的动作。
///
/// 形状照 Web：搜索框 + 「插件列表 N」 + 两列紧凑卡片，一次只展开一张。
/// 展开后是 Loader 条目 id、配置状态、（启用的才有）Cordis 状态。
struct PluginInventoryList: View {
    @ObservedObject var model: SettingsModel

    @State private var query = ""
    @State private var expanded: String?

    /// 搜索同时打在短名、完整模块名、条目 id 上——**id 也是搜索目标**（照 Web）：
    /// 想找"include 底下都装了什么"时，唯一能匹配上的就是 id 的前缀。
    private var matched: [InventoryEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return model.inventory }
        return model.inventory.filter {
            $0.shortName.lowercased().contains(needle)
                || $0.moduleName.lowercased().contains(needle)
                || $0.entryId.lowercased().contains(needle)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.inventoryAvailable {
                Text("读不到插件清单（pluginInventory 服务不在场）。")
                    .font(.callout).foregroundStyle(.secondary)
            } else if let error = model.inventoryError {
                VStack(alignment: .leading, spacing: 6) {
                    Text("暂时无法读取插件。").font(.callout)
                    Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("重试") { model.refresh() }.controlSize(.small)
                }
            } else {
                TextField("搜索插件", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("settings.inventory.search")

                HStack(spacing: 6) {
                    Text("插件列表").font(.callout.weight(.medium))
                    Text("\(matched.count)").font(.caption).foregroundStyle(.secondary)
                }

                if model.inventory.isEmpty {
                    Text("暂无插件。").foregroundStyle(.secondary)
                } else if matched.isEmpty {
                    Text("没有匹配的插件。").foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 8)],
                              alignment: .leading, spacing: 8) {
                        ForEach(matched) { entry in
                            InventoryCard(entry: entry, expanded: $expanded)
                        }
                    }
                }
            }
        }
    }
}

/// 一张紧凑的条目卡片。手风琴：一次只开一张（照 Web）。
private struct InventoryCard: View {
    let entry: InventoryEntry
    @Binding var expanded: String?

    private var isOpen: Bool { expanded == entry.entryId }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expanded = isOpen ? nil : entry.entryId
            } label: {
                HStack(spacing: 6) {
                    Text(entry.shortName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    // 状态点只给启用的条目——停用的没有 root Fiber，画个灰点只是噪声。
                    if entry.enabled {
                        Circle().fill(phaseColor).frame(width: 6, height: 6)
                    }
                    Text(entry.enabled ? "已启用" : "已停用")
                        .font(.caption)
                        .foregroundStyle(entry.enabled ? .secondary : .tertiary)
                    Image(systemName: "chevron.down")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(entry.moduleName)

            if isOpen {
                Text(entry.entryId)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                LabeledContent {
                    Text(entry.enabled ? "已启用" : "已停用")
                } label: {
                    Text("配置状态")
                }
                .font(.caption)
                // 停用的条目**不显示 Cordis 状态**：它必然是"未挂载"，
                // 重复一遍等于给用户两处要读、零处新信息（Web 也是这么省的）。
                if entry.enabled {
                    LabeledContent {
                        Text(entry.phaseLabel)
                    } label: {
                        Text("Cordis 状态")
                    }
                    .font(.caption)
                }
            }
        }
        .padding(9)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityIdentifier("settings.inventory.\(entry.entryId)")
    }

    private var phaseColor: Color {
        switch entry.fiberPhase {
        case "active": return .green
        case "failed": return .red
        case "pending", "loading", "unloading": return .orange
        default: return .secondary.opacity(0.4)
        }
    }
}

