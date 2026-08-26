import SwiftUI

/// 「插件」页——对齐 dsh Web 的 Plugins，**两栏都要**。
///
/// Web 这一页顶上有两个 tab：Plugin configuration（能改的那些设置）和
/// Plugin list（这套部署装了哪 171 个插件、启没启用、挂没挂上）。
/// 先前只镜像了前者，整个后者漏掉了——两栏问的是完全不同的问题，
/// "我能改什么" vs "我这儿到底跑着什么"，缺一栏就等于缺一半。
///
/// 分栏用 segmented picker 而不是再套一层 tab：`.preference` 工具栏已经是一层，
/// 窗口里再来一条 tab 条就是两套导航打架。
struct PluginsPage: View {
    @ObservedObject var model: SettingsModel

    /// 两栏。**默认停在配置栏**——那是唯一能改东西的一栏。
    private enum Section: String, CaseIterable, Identifiable {
        case configuration, inventory
        var id: String { rawValue }
        var title: String {
            switch self {
            case .configuration: return "插件配置"
            case .inventory: return "插件列表"
            }
        }
    }

    @State private var section: Section = .configuration

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("配置与查看这套部署里装着的插件。")
                .font(.callout)
                .foregroundStyle(.secondary)

            Picker("", selection: $section) {
                ForEach(Section.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("settings.plugins.section")

            switch section {
            case .configuration: PluginConfigurationList(model: model)
            case .inventory: PluginInventoryList(model: model)
            }
        }
    }
}

/// 「插件配置」——对齐 Web 的 Plugin configuration。
///
/// 一个命名空间一张手风琴卡片：标题 + 一句说明 + 精选字段。Web 就三张
/// （终端 / 智能体循环 / 网页搜索），排在前面；**其余 ns 排在后面而不是消失**
/// ——Web 会把没手工登记过的插件整个藏掉，那是我们不跟的地方（计划 §2.2）。
///
/// **默认展开第一张**：Web 全部收起，进来是三条横杠什么也看不见。
/// 一张卡片摊开着能告诉人"点开是这个样子"，这一点上不照抄。
struct PluginConfigurationList: View {
    @ObservedObject var model: SettingsModel

    private var namespaces: [NamespaceSnapshot] {
        SettingsTabs.pluginNamespaces(model.namespaces, providers: model.providers)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if namespaces.isEmpty {
                Text("没有可配置的插件。").foregroundStyle(.secondary)
            } else {
                // **按 ns 身份判定"第一张"而不是按下标**：`providers` 是后到的，
                // 它一到 `pluginNamespaces` 的结果就变，下标跟着重排——于是先后有
                // 好几张卡片当过 index 0，各自把自己记成"默认展开"，最后整页全摊开。
                let first = namespaces.first?.ns
                ForEach(namespaces, id: \.ns) { snapshot in
                    PluginCard(model: model, snapshot: snapshot,
                               initiallyOpen: snapshot.ns == first)
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
