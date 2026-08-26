import SwiftUI

/// 一个命名空间的表单。
///
/// **零遗漏在这里保证**：schema 里有的字段全都出现，一个不藏。注解表只决定
/// 顺序（有注解的排前面）和标题，不决定可见性——新插件装上、上游加了字段，
/// 都会自动出现在这一页，只是没有中文名。
struct NamespacePage: View {
    @ObservedObject var model: SettingsModel
    let snapshot: NamespaceSnapshot

    var body: some View {
        SettingsPageScaffold(model: model,
                             title: snapshot.ns,
                             subtitle: subtitle) {
            switch snapshot.schema {
            case .object(let fields, _):
                if fields.isEmpty {
                    Text("这个命名空间没有可配置的字段。")
                        .foregroundStyle(.secondary)
                } else {
                    let (noted, rest) = split(fields)
                    if !noted.isEmpty {
                        section(noted, header: rest.isEmpty ? nil : "常用")
                    }
                    if !rest.isEmpty {
                        // 折叠而不是隐藏：默认收起保证这一页第一眼是清爽的，
                        // 展开保证零遗漏。两者不冲突。
                        DisclosureGroup("其余字段（\(rest.count)）") {
                            section(rest, header: nil)
                        }
                        .padding(.top, 4)
                    }
                }
            default:
                // ns 的根不是 object——schemastery 允许，实测没有。真遇上就诚实显示。
                FieldView(model: model, snapshot: snapshot, path: [], node: snapshot.schema)
            }
        }
    }

    private var subtitle: String? {
        var parts: [String] = []
        if snapshot.applies == "restart" { parts.append("改动需要重启 dsh 才生效") }
        if let user = snapshot.user, case .object(let fields) = user, !fields.isEmpty {
            parts.append("\(fields.count) 个字段已被覆盖")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 有注解的排前面，其余进折叠。**顺序稳定**：两组内部都保持 schema 声明序。
    private func split(_ fields: [SchemaField]) -> ([SchemaField], [SchemaField]) {
        guard FieldNotes.hasNotes(ns: snapshot.ns) else { return ([], fields) }
        var noted: [SchemaField] = []
        var rest: [SchemaField] = []
        for field in fields {
            if FieldNotes.note(ns: snapshot.ns, path: [field.key]) != nil { noted.append(field) }
            else { rest.append(field) }
        }
        return (noted, rest)
    }

    @ViewBuilder
    private func section(_ fields: [SchemaField], header: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header {
                Text(header)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
            }
            ForEach(Array(fields.enumerated()), id: \.offset) { index, field in
                if index > 0 { Divider() }
                FieldOrGroup(model: model, snapshot: snapshot, path: [field.key], node: field.node)
            }
        }
    }
}

/// 字段或子对象。
///
/// 嵌套对象展成一个折叠小节，而不是硬摊成 `a.b.c` 的长列表——层级是 schema 的
/// 一部分，抹掉它反而更难读。
struct FieldOrGroup: View {
    @ObservedObject var model: SettingsModel
    let snapshot: NamespaceSnapshot
    let path: [String]
    let node: SchemaNode

    var body: some View {
        switch node {
        case .object(let fields, _) where !fields.isEmpty:
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(fields.enumerated()), id: \.offset) { index, field in
                        if index > 0 { Divider() }
                        FieldOrGroup(model: model, snapshot: snapshot,
                                     path: path + [field.key], node: field.node)
                    }
                }
                .padding(.leading, 8)
            } label: {
                HStack(spacing: 6) {
                    Text(FieldNotes.title(ns: snapshot.ns, path: path))
                    Text("\(fields.count) 个字段")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)
        default:
            FieldView(model: model, snapshot: snapshot, path: path, node: node)
        }
    }
}

/// 所有页共用的骨架：标题、只读横幅、提示条、滚动区。
struct SettingsPageScaffold<Content: View>: View {
    @ObservedObject var model: SettingsModel
    let title: String
    var subtitle: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title3.weight(.semibold))
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }

                // 门控（计划 §4.5）：只读时整页禁用**并说明原因**——
                // 一个改不动又不说为什么的界面比没有界面更让人恼火。
                if !model.writable {
                    Banner(text: "配置文档是只读的，这里的改动不会生效。",
                           symbol: "lock", tint: .orange)
                }
                if let notice = model.notice {
                    Banner(text: notice, symbol: "exclamationmark.triangle", tint: .orange) {
                        model.notice = nil
                    }
                }

                content()
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct Banner: View {
    let text: String
    let symbol: String
    let tint: Color
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let dismiss {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }
}
