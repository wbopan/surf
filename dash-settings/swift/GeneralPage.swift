import SwiftUI

/// 「通用」页——逐行对齐 dsh Web 的 General。
///
/// 它是一张**投影**而不是某个 ns 的平铺：Web 从五个不同的命名空间里各挑一个字段
/// 拼出这一页（智能体预设、权限、语言、外观、忙碌时 Enter），顺序与两条分隔线
/// 都照搬。取不到的行**静默跳过**——某个插件没装时那一行本来就不该在。
struct GeneralPage: View {
    @ObservedObject var model: SettingsModel
    let openPath: (String) -> Void

    var body: some View {
        Form {
            ForEach(Array(SettingsTabs.generalRows.enumerated()), id: \.offset) { _, row in
                if let snapshot = model.namespace(row.ns),
                   let node = snapshot.schema.node(at: row.path) {
                    if row.dividerBefore { Divider().padding(.vertical, 2) }
                    if row.ns == "ui-theme" {
                        // 外观在 Web 里是三张并排的卡片，不是下拉框。
                        AppearanceRow(model: model, snapshot: snapshot, path: row.path, node: node)
                    } else {
                        FieldRow(model: model, snapshot: snapshot, path: row.path, node: node)
                    }
                }
            }

            if model.hasDocument {
                Divider().padding(.vertical, 2)
                // Web 把这个按钮放在对话框头部。`.preference` 工具栏没有那条头部，
                // 所以落在通用页末尾——它是全局动作，通用页是最不意外的去处。
                LabeledContent("配置文件：") {
                    VStack(alignment: .leading, spacing: 3) {
                        Button("在编辑器中打开…") { model.openDocument(openPath) }
                        Text("schema 表达不了的东西（复杂容器、未知类型）在这里改。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.columns)
    }
}

/// 外观：三张并排的卡片，照 Web 的 Light / Dark / System。
///
/// 为什么单独做一个控件而不是复用下拉框：这是**三选一且选项固定**的东西，
/// Web 用卡片是因为它值得一眼看全；换成下拉框会让"现在是哪个"要点开才知道。
struct AppearanceRow: View {
    @ObservedObject var model: SettingsModel
    let snapshot: NamespaceSnapshot
    let path: [String]
    let node: SchemaNode

    private static let symbols = ["light": "sun.max", "dark": "moon", "system": "display"]

    private var current: String? {
        if case .string(let value)? = snapshot.value.value(at: path) { return value }
        return nil
    }

    var body: some View {
        LabeledContent("外观：") {
            HStack(spacing: 8) {
                ForEach(node.constOptions ?? [], id: \.self) { option in
                    if case .string(let raw) = option {
                        card(raw)
                    }
                }
            }
            .disabled(!model.writable)
        }
    }

    private func card(_ raw: String) -> some View {
        let selected = current == raw
        return Button {
            model.set(ns: snapshot.ns, path: path, value: .string(raw))
        } label: {
            VStack(spacing: 4) {
                Image(systemName: Self.symbols[raw] ?? "circle")
                    .font(.system(size: 14))
                Text(FieldNotes.optionLabel(ns: snapshot.ns, path: path, value: .string(raw)))
                    .font(.caption)
            }
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .frame(width: 76, height: 50)
            // **选中态要压过焦点环**：只靠 0.06→0.16 的底色差，实测跟按钮自带的
            // 蓝色焦点环撞在一起，看上去像"第一张被选中了"。用强调色描边 + 染色
            // 把"选中"和"有焦点"分成两件看得出区别的事。
            .background(selected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.25),
                              lineWidth: selected ? 1.5 : 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.appearance.\(raw)")
    }
}
