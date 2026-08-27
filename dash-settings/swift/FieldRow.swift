import SwiftUI

/// 一个字段 = `Form` 里的一行。
///
/// 版式跟着 macOS 偏好设置的老规矩走：**标签右对齐在左列（带全角冒号），控件
/// 左对齐在右列**，说明文字压在控件底下一行小字。复选框是个例外——它没有左标签，
/// 文案就是它自己的标签。
///
/// 计划 §4 那七条编辑器语义大半落在这里：
/// - **覆盖判据是"user 层里有这个键"**，不是"值不等于默认"——等于默认的覆盖仍是覆盖。
/// - **写完不预测结果**：控件显示的永远是快照里的值；提交后等 host 重推。
/// - **失败保留用户输入**：draft 留在 model 里，错误挂在字段上，不清空、不弹框。
/// - **secret 永远从空开始**，空输入 = 保留现有 key（见 SecretField）。
///
/// 上一版把真 key、类型约束、"需重启"三样都平铺在每一行下面，一页十几行就成了
/// 一堵字。真 key 是手写 `settings.yaml` 时才需要的东西——**移进悬停提示**：
/// 需要的人 hover 一下就有，不需要的人不必每行都读一遍。
struct FieldRow: View {
    @ObservedObject var model: SettingsModel
    let snapshot: NamespaceSnapshot
    let path: [String]
    let node: SchemaNode

    private var status: FieldStatus { model.status(snapshot.ns, path) }
    private var overridden: Bool { snapshot.isOverridden(path: path) }
    private var value: JSONValue? { snapshot.value.value(at: path) }
    private var note: FieldNotes.Note? { FieldNotes.note(ns: snapshot.ns, path: path) }
    private var title: String { FieldNotes.title(ns: snapshot.ns, path: path) }

    var body: some View {
        if case .boolean = node, !node.meta.isSecret {
            // 复选框自带标签，左列留空——参考设计里的
            // "Group messages into conversations" 就是这一行的形状。
            LabeledContent {
                trailing {
                    Toggle(title, isOn: Binding(
                        get: { value?.boolValue ?? node.meta.default?.boolValue ?? false },
                        set: { model.set(ns: snapshot.ns, path: path, value: .bool($0)) }))
                        .toggleStyle(.checkbox)
                }
            } label: {
                EmptyView()
            }
            .modifier(RowChrome(id: identifier, help: tooltip))
        } else {
            LabeledContent {
                trailing { control }
            } label: {
                Text(title + "：")
            }
            .modifier(RowChrome(id: identifier, help: tooltip))
        }
    }

    /// 控件 + 重置按钮 + 说明 + 状态，右列的全部内容。
    @ViewBuilder
    private func trailing<C: View>(@ViewBuilder _ control: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                control()
                    .disabled(!model.writable || status.saving)
                if let unit = note?.unit {
                    Text(unit).font(.callout).foregroundStyle(.secondary)
                }
                resetButton
            }
            if let hint = note?.hint {
                Text(hint).font(.caption).foregroundStyle(.secondary)
                // **限宽**：不限的话这行小字的"理想宽度"就是它的全长，
                // `Form(.columns)` 按各行理想宽度算控件列，一句长注解能把整页
                // 撑到框外去（通用页居中之后一眼看得出来：分隔线跑出了版心）。
                .frame(maxWidth: 280, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
            statusLine
        }
    }

    /// 悬停提示：真 key + 类型约束。
    /// 手写配置文件的人需要真 key，而机械美化过的名字反推不回去。
    private var tooltip: String {
        var parts = [path.joined(separator: ".")]
        if let constraint = node.meta.constraintText { parts.append(constraint) }
        if overridden { parts.append("已覆盖默认值") }
        return parts.joined(separator: " · ")
    }

    private var identifier: String {
        "settings.field.\(snapshot.ns).\(path.joined(separator: "."))"
    }

    @ViewBuilder
    private var control: some View {
        if node.meta.isSecret {
            SecretField(model: model, snapshot: snapshot, path: path)
        } else if let options = node.constOptions {
            ChoiceField(model: model, snapshot: snapshot, path: path,
                        options: options, required: node.meta.required)
        } else {
            switch node {
            case .boolean:
                // secret role 压在 boolean 上时会走到这儿（上面那条分支只接非 secret）。
                ReadOnlyValue(value: value)
            case .number:
                if node.meta.role == "slider", let min = node.meta.min, let max = node.meta.max {
                    SliderField(model: model, snapshot: snapshot, path: path,
                                min: min, max: max, step: node.meta.step)
                } else {
                    TextEntryField(model: model, snapshot: snapshot, path: path, kind: .number)
                        .frame(width: 120)
                }
            case .string:
                // **不钉宽度**：钉了就会出现"详情栏里的框撑满、页级表单里的框只有
                // 320"这种同窗两种右边缘。让它跟着控件列走，右边缘自然对齐。
                TextEntryField(model: model, snapshot: snapshot, path: path, kind: .string)
                    .frame(maxWidth: .infinity)
            case .const(let constant, _):
                // 单个 const 没什么可改的——显示它，别给一个假装能改的控件。
                Text(constant.summary).foregroundStyle(.secondary)
            case .array(let inner, _):
                ListField(model: model, snapshot: snapshot, path: path, inner: inner, isDict: false)
            case .dict(let inner, _):
                ListField(model: model, snapshot: snapshot, path: path, inner: inner, isDict: true)
            case .object, .union, .unknown:
                // object 由 FieldOrGroup 展开成小节，不会走到这儿；
                // union（非全 const）与 unknown 是真的没法安全编辑——显示值，
                // 让「打开配置文件」接手。这是计划 §8 认下的那部分。
                ReadOnlyValue(value: value)
            }
        }
    }

    /// 重置。**只在已覆盖时出现**——它的在场本身就是"这一项被改过"的标记，
    /// 所以上一版那个额外的蓝点删掉了：两个东西说同一件事，留一个。
    @ViewBuilder
    private var resetButton: some View {
        if overridden && model.writable {
            Button {
                model.unset(ns: snapshot.ns, path: path)
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(resetHelp)
            .accessibilityIdentifier("settings.reset.\(snapshot.ns).\(path.joined(separator: "."))")
        }
    }

    private var resetHelp: String {
        guard let inherited = snapshot.inheritedValue(path: path, node: node) else {
            return "重置（退回继承）"
        }
        return "重置为 \(inherited.summary)"
    }

    @ViewBuilder
    private var statusLine: some View {
        if status.saving {
            Text("保存中…").font(.caption).foregroundStyle(.secondary)
        } else if let error = status.error {
            // 失败不清空输入，只在这儿说原因。
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }
}

/// 每行共用的那点修饰。抽出来是因为两条分支（复选框 / 普通）都要挂同一套。
private struct RowChrome: ViewModifier {
    let id: String
    let help: String

    func body(content: Content) -> some View {
        content
            .help(help)
            .accessibilityIdentifier(id)
    }
}

/// 只读地显示一个值（union / unknown / 复杂容器的兜底）。
struct ReadOnlyValue: View {
    let value: JSONValue?

    var body: some View {
        Text(value?.summary ?? "—")
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(value?.prettyJSON ?? "")
    }
}
