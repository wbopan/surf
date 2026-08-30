import SwiftUI

// 具体控件。每一个都对应计划 §4 的一条编辑器语义，
// 版式由 FieldRow 负责，这里只管"怎么改、什么时候提交"。

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
        default: return value.summary(model.locale)
        }
    }

    var body: some View {
        TextField("", text: Binding(
            get: { model.status(snapshot.ns, path).draft ?? stored },
            set: { model.setDraft(snapshot.ns, path, $0) }))
            .textFieldStyle(.roundedBorder)
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
                model.setLocalError(snapshot.ns, path, model.strings.mustBeNumber)
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
                Text(model.strings.unsetOption).tag(JSONValue.null)
            }
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Text(FieldNotes.optionLabel(ns: snapshot.ns, path: path,
                                            value: option, locale: model.locale)).tag(option)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
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
        .frame(width: 260)
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
            // **`SecureField(_ title:text:)` 的第一个参数是标签不是占位符**——
            // 在 Form 里它会被渲染成控件旁边一坨额外的文字（实测："Api Key： 未配置 [框]"）。
            // 占位符要走 `prompt:`，标签另行藏掉。
            SecureField("", text: $entry,
                        prompt: Text(isSet ? model.strings.secretConfigured
                                           : model.strings.secretUnset))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit(commit)
            if isSet {
                Button(model.strings.clear) { model.unset(ns: snapshot.ns, path: path) }
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
            ReadOnlyValue(value: value, locale: model.locale)
        }
    }
}
