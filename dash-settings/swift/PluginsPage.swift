import SwiftUI

/// 「插件」页——对齐 dsh Web 的 Plugins → Plugin configuration。
///
/// 一个命名空间一张手风琴卡片：标题 + 一句说明 + 精选字段。Web 就三张
/// （终端 / 智能体循环 / 网页搜索），排在前面；**其余 ns 排在后面而不是消失**
/// ——Web 会把没手工登记过的插件整个藏掉，那是我们不跟的地方（计划 §2.2）。
///
/// **默认展开第一张**：Web 全部收起，进来是三条横杠什么也看不见。
/// 一张卡片摊开着能告诉人"点开是这个样子"，这一点上不照抄。
struct PluginsPage: View {
    @ObservedObject var model: SettingsModel

    private var namespaces: [NamespaceSnapshot] {
        SettingsTabs.pluginNamespaces(model.namespaces, providers: model.providers)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("配置与查看这套部署里装着的插件。")
                .font(.callout)
                .foregroundStyle(.secondary)

            if namespaces.isEmpty {
                Text("没有可配置的插件。").foregroundStyle(.secondary)
            } else {
                ForEach(Array(namespaces.enumerated()), id: \.element.ns) { index, snapshot in
                    PluginCard(model: model, snapshot: snapshot, initiallyOpen: index == 0)
                }
            }
        }
    }
}

struct PluginCard: View {
    @ObservedObject var model: SettingsModel
    let snapshot: NamespaceSnapshot
    let initiallyOpen: Bool

    @State private var open: Bool?

    private var isOpen: Binding<Bool> {
        Binding(get: { open ?? initiallyOpen }, set: { open = $0 })
    }

    private var fields: [SchemaField] {
        guard case .object(let list, _) = snapshot.schema else { return [] }
        return list
    }

    var body: some View {
        let raw = NamespaceNotes.split(ns: snapshot.ns, fields: fields)
        // 一张没登记精选、但字段本来就没几个的卡片，不值得再套一层「更多设置」
        // ——那是一次纯浪费的点击。三个以内直接摊开。
        let split = raw.featured.isEmpty && raw.rest.count <= 3
            ? (featured: raw.rest, rest: [SchemaField]())
            : raw
        VStack(alignment: .leading, spacing: 0) {
            DisclosureGroup(isExpanded: isOpen) {
                VStack(alignment: .leading, spacing: 6) {
                    Form {
                        ForEach(split.featured, id: \.key) { field in
                            FieldOrGroup(model: model, snapshot: snapshot,
                                         path: [field.key], node: field.node)
                        }
                    }
                    .formStyle(.columns)

                    if !split.rest.isEmpty {
                        // Web 把这些字段整个藏掉了。**藏可以，丢不行**：
                        // 折叠一层既保住了"照 Web 的样子"，又保住了零遗漏。
                        DisclosureGroup("更多设置（\(split.rest.count) 项）") {
                            Form {
                                ForEach(split.rest, id: \.key) { field in
                                    FieldOrGroup(model: model, snapshot: snapshot,
                                                 path: [field.key], node: field.node)
                                }
                            }
                            .formStyle(.columns)
                            .padding(.top, 6)
                        }
                        .font(.callout)
                    }

                    if snapshot.applies == "restart" {
                        Text("改完需要重启 dsh 才生效。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(.top, 10)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(NamespaceNotes.title(ns: snapshot.ns)).font(.body.weight(.medium))
                    if let summary = NamespaceNotes.summary(ns: snapshot.ns) {
                        Text(summary).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("settings.plugin.\(snapshot.ns)")
    }
}
