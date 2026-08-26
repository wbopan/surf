import SwiftUI

/// 「插件」页——对齐 dsh Web 的 Plugins，两栏都要。
///
/// Web 这一页顶上有两个 tab：Plugin configuration（能改的那些设置）和 Plugin list
/// （这套部署装了哪 171 个插件、启没启用、挂没挂上）。两栏问的是完全不同的问题，
/// "我能改什么" vs "我这儿到底跑着什么"。
///
/// 分栏用 `Picker(.segmented)`：`.preference` 工具栏已经是一层导航，窗口里再来
/// 一条 tab 条就是两套导航打架。参考设计里 Accounts 的
/// Account Information / Inbox Categories / Vacation 就是这个控件。
struct PluginsPage: View {
    @ObservedObject var model: SettingsModel

    private enum Section: String, CaseIterable, Identifiable {
        case configuration, inventory
        var id: String { rawValue }
        var title: String { self == .configuration ? "插件配置" : "插件列表" }
    }

    /// 默认停在配置栏——那是唯一能改东西的一栏。
    @State private var section: Section = .configuration

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Spacer(minLength: 0)
                Picker("", selection: $section) {
                    ForEach(Section.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("settings.plugins.section")
                Spacer(minLength: 0)
            }

            switch section {
            case .configuration: PluginConfigurationList(model: model)
            case .inventory: PluginInventoryList(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// 「插件配置」——主从，一个命名空间一项。
///
/// 上一版是一叠手风琴卡片，每张里面还套一层「更多设置（N 项）」的折叠。
/// **换成主从之后那层折叠可以整个删掉**：详情栏一次摊得下 `shell` 全部六个字段，
/// 于是"零遗漏"不再需要拿一次点击去换——这是这次改版最实在的一处收益，
/// 不是好看，是少了一个用户必须发现的隐藏动作。
///
/// 左列仍保留「Web 手工登记过的三个在前、其余在后」的顺序，只是分组从
/// "排在后面的卡片"变成一条分组横线。**其余 ns 仍旧出现**（计划 §2.2 零遗漏）。
struct PluginConfigurationList: View {
    @ObservedObject var model: SettingsModel

    @State private var selection: String?

    private var namespaces: [NamespaceSnapshot] {
        SettingsTabs.pluginNamespaces(model.namespaces, providers: model.providers)
    }

    private var featured: [NamespaceSnapshot] {
        namespaces.filter { SettingsTabs.pluginCardOrder.contains($0.ns) }
    }

    private var rest: [NamespaceSnapshot] {
        namespaces.filter { !SettingsTabs.pluginCardOrder.contains($0.ns) }
    }

    /// 选中项消失时回落到第一个。快照是后到的，首帧 selection 必然是 nil。
    private var current: NamespaceSnapshot? {
        namespaces.first { $0.ns == selection } ?? namespaces.first
    }

    var body: some View {
        if namespaces.isEmpty {
            VStack { Spacer(); Text("没有可配置的插件。").foregroundStyle(.secondary); Spacer() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(alignment: .top, spacing: 16) {
                List(selection: $selection) {
                    ForEach(featured, id: \.ns) { row($0) }
                    if !rest.isEmpty {
                        SwiftUI.Section(header: SourceListSectionHeader(title: "其余")) {
                            ForEach(rest, id: \.ns) { row($0) }
                        }
                    }
                }
                .sourceListChrome(width: 196)
                // **选中项要写回 binding**，不能只让详情栏"回落到第一个"：
                // 那样详情显示着「终端」，左列却一行都没高亮，看着像坏了。
                .onChange(of: namespaces.map(\.ns)) { _, list in
                    if selection == nil || !list.contains(selection!) { selection = list.first }
                }
                .onAppear { if selection == nil { selection = namespaces.first?.ns } }

                if let current {
                    PluginDetail(model: model, snapshot: current)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func row(_ snapshot: NamespaceSnapshot) -> some View {
        Text(NamespaceNotes.title(ns: snapshot.ns))
            .lineLimit(1)
            .tag(snapshot.ns)
            .listRowSeparator(.hidden)
            .accessibilityIdentifier("settings.plugin.\(snapshot.ns)")
    }
}

/// 一个命名空间的全部字段。
struct PluginDetail: View {
    @ObservedObject var model: SettingsModel
    let snapshot: NamespaceSnapshot

    private var fields: [SchemaField] {
        guard case .object(let list, _) = snapshot.schema else { return [] }
        return list
    }

    var body: some View {
        let split = NamespaceNotes.split(ns: snapshot.ns, fields: fields)
        VStack(alignment: .leading, spacing: 12) {
            DetailHeader(title: NamespaceNotes.title(ns: snapshot.ns),
                         subtitle: NamespaceNotes.summary(ns: snapshot.ns),
                         identifier: snapshot.ns)

            ScrollView {
                Form {
                    ForEach(split.featured, id: \.key) { field in
                        FieldOrGroup(model: model, snapshot: snapshot,
                                     path: [field.key], node: field.node)
                    }
                    // 精选与其余之间一条**只跨控件列**的线。Web 把"其余"整个藏掉，
                    // 我们只是把它排在后面——藏可以，丢不行。
                    if !split.featured.isEmpty && !split.rest.isEmpty { FormRule() }
                    ForEach(split.rest, id: \.key) { field in
                        FieldOrGroup(model: model, snapshot: snapshot,
                                     path: [field.key], node: field.node)
                    }
                }
                .formStyle(.columns)
                .padding(.trailing, 2)
            }

            if snapshot.applies == "restart" {
                Text("改完需要重启 dsh 才生效。")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }
}
