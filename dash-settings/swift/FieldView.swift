import SwiftUI

/// 一个字段：左边标题与说明，右边控件，下面（有事时才有）状态行。
///
/// 计划 §4 那七条编辑器语义大半落在这里：
/// - **覆盖判据是"user 层里有这个键"**，不是"值不等于默认"——等于默认的覆盖仍是覆盖。
///   已覆盖时右侧出现"重置"，`unset` 退回继承。
/// - **写完不预测结果**：控件显示的永远是快照里的值；提交后等 host 重推。
/// - **失败保留用户输入**：draft 留在 model 里，错误挂在字段上，不清空、不弹框。
/// - **secret 永远从空开始**，空输入 = 保留现有 key（见 SecretField）。
struct FieldView: View {
    @ObservedObject var model: SettingsModel
    let snapshot: NamespaceSnapshot
    let path: [String]
    let node: SchemaNode

    private var status: FieldStatus { model.status(snapshot.ns, path) }
    private var overridden: Bool { snapshot.isOverridden(path: path) }
    private var value: JSONValue? { snapshot.value.value(at: path) }
    private var note: FieldNotes.Note? { FieldNotes.note(ns: snapshot.ns, path: path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(FieldNotes.title(ns: snapshot.ns, path: path))
                            .font(.body)
                        if overridden {
                            // 已覆盖的视觉标记。**不是"改过默认值"**，是"用户层里有这个键"。
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 5, height: 5)
                                .help("已覆盖默认值")
                        }
                    }
                    subtitle
                }
                Spacer(minLength: 8)
                control
                    .frame(maxWidth: 260, alignment: .trailing)
                    .disabled(!model.writable || status.saving)
                resetButton
            }
            statusLine
        }
        .padding(.vertical, 6)
        .accessibilityIdentifier("settings.field.\(snapshot.ns).\(path.joined(separator: "."))")
    }

    /// 副标题：有注解显示注解，没有就显示真 key + 类型/约束。
    ///
    /// **真 key 一直显示**（哪怕有中文标题）：用户对着 `settings.yaml` 手写时需要它，
    /// 而机械美化过的名字反推不回去。
    @ViewBuilder
    private var subtitle: some View {
        let key = path.last ?? ""
        let constraint = node.meta.constraintText
        VStack(alignment: .leading, spacing: 1) {
            if let hint = note?.hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text(key)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                if let constraint {
                    Text(constraint)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if snapshot.applies == "restart" {
                    Text("改后需重启 dsh")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
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
                Toggle("", isOn: Binding(
                    get: { value?.boolValue ?? node.meta.default?.boolValue ?? false },
                    set: { model.set(ns: snapshot.ns, path: path, value: .bool($0)) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
            case .number:
                if node.meta.role == "slider", let min = node.meta.min, let max = node.meta.max {
                    SliderField(model: model, snapshot: snapshot, path: path,
                                min: min, max: max, step: node.meta.step)
                } else {
                    TextEntryField(model: model, snapshot: snapshot, path: path, kind: .number)
                }
            case .string:
                TextEntryField(model: model, snapshot: snapshot, path: path, kind: .string)
            case .const(let constant, _):
                // 单个 const 没什么可改的——显示它，别给一个假装能改的控件。
                Text(constant.summary).foregroundStyle(.secondary)
            case .array(let inner, _):
                ListField(model: model, snapshot: snapshot, path: path, inner: inner, isDict: false)
            case .dict(let inner, _):
                ListField(model: model, snapshot: snapshot, path: path, inner: inner, isDict: true)
            case .object, .union, .unknown:
                // object 由 NamespacePage 展开成小节，不会走到这儿；
                // union（非全 const）与 unknown 是真的没法安全编辑——显示值，
                // 让「打开配置文件」接手。这是计划 §8 认下的那部分。
                ReadOnlyValue(value: value)
            }
        }
    }

    /// 重置。**只在已覆盖时出现**——没覆盖的东西没什么可重置。
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
        } else {
            // 占位，免得有无重置按钮的两行左右对不齐。
            Color.clear.frame(width: 16, height: 1)
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

/// 文本 / 数字输入。**失焦或 ⏎ 提交**（计划 D1 的 macOS 惯例那一半）。
struct TextEntryField: View {
    enum Kind { case string, number }

    @ObservedObject var model: SettingsModel
    let snapshot: NamespaceSnapshot
    let path: [String]
    let kind: Kind

    @FocusState private var focused: Bool

    private var stored: String {
        guard let value = snapshot.value.value(at: path) else { return "" }
        switch value {
        case .string(let text): return text
        case .number(let number): return SettingsFormat.number(number)
        case .null: return ""
        default: return value.summary
        }
    }

    var body: some View {
        TextField("", text: Binding(
            get: { model.status(snapshot.ns, path).draft ?? stored },
            set: { model.setDraft(snapshot.ns, path, $0) }))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, isFocused in
                // 失焦提交。**先判等再写**：只是点进点出不该产生一次写入
                // （每次写入都会 bump revision，进而让别处的乐观锁失效）。
                if !isFocused { commit() }
            }
    }

    private func commit() {
        let draft = model.status(snapshot.ns, path).draft
        guard let draft, draft != stored else {
            model.setDraft(snapshot.ns, path, nil)
            return
        }
        switch kind {
        case .string:
            model.set(ns: snapshot.ns, path: path, value: .string(draft))
        case .number:
            let trimmed = draft.trimmingCharacters(in: .whitespaces)
            guard let number = Double(trimmed) else {
                // 本地就能判的错在本地说，不必往返一趟。输入照样留着。
                model.setLocalError(snapshot.ns, path, "要一个数字")
                return
            }
            model.set(ns: snapshot.ns, path: path, value: .number(number))
        }
    }
}

/// 全是 const 的 union → 下拉框。
struct ChoiceField: View {
    @ObservedObject var model: SettingsModel
    let snapshot: NamespaceSnapshot
    let path: [String]
    let options: [JSONValue]
    let required: Bool

    var body: some View {
        Picker("", selection: Binding(
            get: { snapshot.value.value(at: path) ?? .null },
            set: { selected in
                // 选到"（未设置）"= 退回继承，不是写一个 null 进去。
                if selected.isNull { model.unset(ns: snapshot.ns, path: path) }
                else { model.set(ns: snapshot.ns, path: path, value: selected) }
            })) {
            // 非必填的才给"未设置"这一项：必填字段没有"空"这个合法态，
            // 给了只会让用户写出一个 host 会拒绝的值。
            if !required {
                Text("（未设置）").tag(JSONValue.null)
            }
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Text(option.summary).tag(option)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
    }
}

/// `role('slider')` 的数字。
struct SliderField: View {
    @ObservedObject var model: SettingsModel
    let snapshot: NamespaceSnapshot
    let path: [String]
    let min: Double
    let max: Double
    let step: Double?

    @State private var live: Double?

    private var stored: Double {
        snapshot.value.value(at: path)?.numberValue ?? min
    }

    var body: some View {
        HStack(spacing: 8) {
            Slider(value: Binding(get: { live ?? stored }, set: { live = $0 }),
                   in: min...max,
                   step: step ?? ((max - min) / 100)) { editing in
                // **拖动过程中不写**：一次拖拽会产生几十个中间值，每个都写一遍
                // 等于给设置文档来一串垃圾提交，还会把 revision 顶飞。
                // 松手才提交。
                if !editing, let value = live {
                    live = nil
                    if value != stored { model.set(ns: snapshot.ns, path: path, value: .number(value)) }
                }
            }
            Text(SettingsFormat.number(live ?? stored))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

/// secret 字段。
///
/// **语义是反直觉的，照抄上游**（计划 §4.4）：值永不回传，控件永远从空开始，
/// **空输入 = 保留现有 key**（不是清除）。所以这里只显示"已配置/未配置"，
/// 清除是一个单独的显式动作。
struct SecretField: View {
    @ObservedObject var model: SettingsModel
    let snapshot: NamespaceSnapshot
    let path: [String]

    @State private var entry = ""

    private var isSet: Bool { snapshot.secretSlot(path: path)?.isSet ?? false }

    var body: some View {
        HStack(spacing: 6) {
            SecureField(isSet ? "已配置（留空 = 不变）" : "未配置", text: $entry)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            if isSet {
                Button("清除") { model.unset(ns: snapshot.ns, path: path) }
                    .controlSize(.small)
            }
        }
    }

    private func commit() {
        let trimmed = entry.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }   // 空 = 保留现有，不是清除
        model.set(ns: snapshot.ns, path: path, value: .string(trimmed))
        entry = ""
    }
}

/// 数组 / 字典。
///
/// **只有标量元素才可编辑**：元素是对象时，一次写入要重建整个容器，而容器里
/// 可能藏着被 redact 掉的 secret——那正是计划 §5 红线 1 禁止的形状。
/// 复杂容器显示成只读摘要，由「打开配置文件」接手。
struct ListField: View {
    @ObservedObject var model: SettingsModel
    let snapshot: NamespaceSnapshot
    let path: [String]
    let inner: SchemaNode
    let isDict: Bool

    private var isScalarInner: Bool {
        switch inner {
        case .string, .number, .boolean, .const: return true
        case .union: return inner.constOptions != nil
        default: return false
        }
    }

    private var value: JSONValue? { snapshot.value.value(at: path) }

    var body: some View {
        if isScalarInner {
            ScalarListEditor(model: model, snapshot: snapshot, path: path,
                             value: value, isDict: isDict)
        } else {
            ReadOnlyValue(value: value)
        }
    }
}
