import SwiftUI

/// 精选「通用」页。
///
/// 这一页**没有任何自己的数据**：它是注解表 `FieldNotes.featuredOrder` 在快照上的
/// 一次投影。所以它天然不会与平铺页说法不一（同一个 `FieldView`、同一份快照、
/// 同一条写入路径），而"改精选"这件事就是改那张表里的一行。
///
/// **列不出来的条目安静跳过**：注解表里写着某个 ns/字段，但那个插件没装
/// ——这不是错误，是常态（`shell` 在远程 profile 里可能就没有）。
struct GeneralPage: View {
    @ObservedObject var model: SettingsModel

    private struct Entry: Identifiable {
        let snapshot: NamespaceSnapshot
        let path: [String]
        let node: SchemaNode
        var id: String { "\(snapshot.ns)/\(path.joined(separator: "/"))" }
    }

    private var entries: [Entry] {
        FieldNotes.featuredOrder.compactMap { item in
            guard let snapshot = model.namespace(item.ns),
                  let node = resolve(schema: snapshot.schema, path: item.path) else { return nil }
            return Entry(snapshot: snapshot, path: item.path, node: node)
        }
    }

    var body: some View {
        SettingsPageScaffold(model: model,
                             title: "通用",
                             subtitle: "常改的几项。全部设置在左边按命名空间平铺。") {
            if entries.isEmpty {
                Text("还没有可显示的精选项——左边的命名空间里有全部设置。")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider() }
                        FieldView(model: model, snapshot: entry.snapshot,
                                  path: entry.path, node: entry.node)
                    }
                }
            }
        }
    }

    /// 顺着路径在 schema 树里找到那个节点。找不到 = 上游改了字段名，安静跳过。
    private func resolve(schema: SchemaNode, path: [String]) -> SchemaNode? {
        var node = schema
        for key in path {
            guard case .object(let fields, _) = node,
                  let next = fields.first(where: { $0.key == key }) else { return nil }
            node = next.node
        }
        return node
    }
}
