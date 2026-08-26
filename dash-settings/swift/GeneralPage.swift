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
                    if row.dividerBefore { FormRule() }
                    if row.ns == "ui-theme" {
                        // 外观在 Web 里是三张并排的卡片，不是下拉框。
                        AppearanceRow(model: model, snapshot: snapshot, path: row.path, node: node)
                    } else if row.ns == "agent-presets", model.presetsAvailable, !model.presets.isEmpty {
                        // 预设的 schema 就是一个自由字符串，照直渲染会得到一个让人
                        // **手敲 id** 的文本框——敲错了没有任何提示，会话起不来才知道。
                        // Web 那边是下拉框，而且显示的是「标准模式」这样的显示名而不是
                        // `standard`。预设清单已经在手上（智能体预设页用的就是它），
                        // 这里直接借过来。清单读不到时回落成文本框，总比没得填强。
                        PresetPickerRow(model: model, snapshot: snapshot, path: row.path)
                    } else {
                        FieldRow(model: model, snapshot: snapshot, path: row.path, node: node)
                    }
                }
            }

            if model.hasDocument {
                FormRule()
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

/// 外观：和这一页其余四行一样的下拉框。
///
/// 这一行换过两版，两版都错：
///
/// 1. 三张 76×50 的图标卡片——那是**系统设置**（Ventura 之后那个全屏应用）的写法，
///    不是**偏好设置窗口**的写法，在这套语法里占三倍高度还得自己发明选中态。
/// 2. `Picker(.segmented)`——一行搞定，但它的选中态是**一整块实心 accent 色**，
///    在一页灰白里是唯一一块饱和色，非常抢眼；而这一页另外四行（智能体预设、
///    权限、语言、忙碌时 Enter）全是下拉框，就它一个是分段，读起来像另一种东西。
///
/// 顺带回答一个问题：这块蓝**不是"没拿到 Liquid Glass"**。玻璃是浮在内容之上
/// 那一层的材质——工具栏、sidebar、sheet、浮动控件条——嵌在表单里的控件按设计
/// 就不该有，也拿不到。同一个 `Picker(.segmented)` 放进工具栏会变成玻璃胶囊，
/// 放进 `Form` 就是扁平方角，对照台在 `docs/spikes/liquid-glass/`（可复跑）。
struct AppearanceRow: View {
    @ObservedObject var model: SettingsModel
    let snapshot: NamespaceSnapshot
    let path: [String]
    let node: SchemaNode

    private var current: String {
        if case .string(let value)? = snapshot.value.value(at: path) { return value }
        return ""
    }

    private var options: [String] {
        (node.constOptions ?? []).compactMap {
            if case .string(let raw) = $0 { return raw }
            return nil
        }
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                Picker("", selection: Binding(
                    get: { current },
                    set: { model.set(ns: snapshot.ns, path: path, value: .string($0)) })) {
                    ForEach(options, id: \.self) { raw in
                        Text(FieldNotes.optionLabel(ns: snapshot.ns, path: path, value: .string(raw)))
                            .tag(raw)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(!model.writable)
                .accessibilityIdentifier("settings.field.\(snapshot.ns).\(path.joined(separator: "."))")

                if snapshot.isOverridden(path: path) {
                    Button {
                        model.unset(ns: snapshot.ns, path: path)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("重置（退回继承）")
                }
            }
        } label: {
            Text(FieldNotes.title(ns: snapshot.ns, path: path) + "：")
        }
    }
}

/// 默认智能体预设：下拉框，显示名而不是 id。
///
/// **不做"当前值不在清单里就丢掉"**：配置里写着一个已经删掉的预设 id 时，
/// 下拉框得照样显示它（标一句"清单里没有"），否则界面看起来一切正常，
/// 而新会话正在用一个不存在的预设。
struct PresetPickerRow: View {
    @ObservedObject var model: SettingsModel
    let snapshot: NamespaceSnapshot
    let path: [String]

    private var current: String {
        if case .string(let value)? = snapshot.value.value(at: path) { return value }
        return ""
    }

    private var missing: Bool {
        !current.isEmpty && !model.presets.contains { $0.id == current }
    }

    var body: some View {
        let status = model.status(snapshot.ns, path)
        LabeledContent(FieldNotes.title(ns: snapshot.ns, path: path) + "：") {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Picker("", selection: Binding(
                        get: { current },
                        set: { model.set(ns: snapshot.ns, path: path, value: .string($0)) })) {
                        ForEach(model.presets) { preset in
                            Text(preset.displayName).tag(preset.id)
                        }
                        if missing {
                            Text("\(current)（清单里没有）").tag(current)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!model.writable || status.saving)
                    .accessibilityIdentifier("settings.field.\(snapshot.ns).\(path.joined(separator: "."))")

                    if snapshot.isOverridden(path: path) {
                        Button {
                            model.unset(ns: snapshot.ns, path: path)
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .buttonStyle(.borderless)
                        .help("退回默认")
                    }
                }
                if let hint = FieldNotes.note(ns: snapshot.ns, path: path)?.hint {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                    // **限宽**：不限的话这行小字的"理想宽度"就是它的全长，
                    // `Form(.columns)` 按各行理想宽度算控件列，一句长注解能把整页
                    // 撑到框外去（通用页居中之后一眼看得出来：分隔线跑出了版心）。
                    .frame(maxWidth: 280, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if let error = status.error {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
        }
    }
}
