import SwiftUI

/// 「模型」页——对齐 dsh Web 的 Models。
///
/// Web 的形状：一句说明 + **只列已经在用的那几个 provider**（点状态 + 编辑），
/// 底下「添加 provider」把 38 个目录收在一个下拉框里。上一版我把 38 个全平铺成
/// 一列主从列表，看着专业，其实是把"目录"和"我的配置"混成了一坨
/// ——用户九成时间只关心自己那三个。
///
/// **状态点的含义照 Web**：绿 = 凭据已配置，红 = 没有 key。
/// 实测 `deepseek-official` 是"路由已注册但凭据未配置"（key 从别处来），
/// Web 给的就是红点，所以路由状态另用文字说，不跟点抢含义。
///
/// **范围仍然收窄**（计划 D3）：列出、看状态、设/清 key、改 provider 自己那段设置。
/// Web 的「添加自定义 provider」要往配置里写出一整个 provider 对象，
/// 那是计划 §5 红线 1 附近的形状，单独一轮做对。
struct ModelsPage: View {
    @ObservedObject var model: SettingsModel

    @State private var editing: String?
    @State private var adding = false

    /// 在用的：路由活着，或者凭据配好了。**这条判据是照着 Web 的结果反推的**
    /// ——它列出的正好是这两类的并集（实测 3 个，另有 35 个只在目录里）。
    private var configured: [ProviderRow] {
        model.providers.filter { $0.live || $0.credentialConfigured == true }
    }

    private var catalog: [ProviderRow] {
        let shown = Set(configured.map(\.provider))
        return model.providers.filter { !shown.contains($0.provider) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.modelsAvailable {
                Text("llm 服务不在场，这一页填不了。默认模型仍可在配置文件里改。")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("填入 API key 就能用下面这些 provider 的模型。")
                    .font(.callout).foregroundStyle(.secondary)

                VStack(spacing: 0) {
                    ForEach(Array(configured.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider() }
                        ProviderRowView(model: model, row: row, editing: $editing)
                    }
                }
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

                AddProviderBox(model: model, catalog: catalog, open: $adding)
            }

            defaultModelSection
        }
    }

    /// 默认模型。**Web 没有这一段**（它把选模型放在输入框那条工具栏上），
    /// 但 `agent-default-model` 是实打实的设置项，没有别的地方能露面，
    /// 藏起来就等于丢了。放在这一页末尾是最不意外的去处。
    @ViewBuilder
    private var defaultModelSection: some View {
        if let snapshot = model.namespace(SettingsTabs.defaultModelNs),
           case .object(let fields, _) = snapshot.schema, !fields.isEmpty {
            Divider().padding(.top, 4)
            Text("默认模型").font(.callout.weight(.medium))
            Form {
                ForEach(fields, id: \.key) { field in
                    FieldOrGroup(model: model, snapshot: snapshot,
                                 path: [field.key], node: field.node)
                }
            }
            .formStyle(.columns)
        }
    }
}

/// 一行 provider：折叠时只有名字与状态点，点「编辑」就地展开。
struct ProviderRowView: View {
    @ObservedObject var model: SettingsModel
    let row: ProviderRow
    @Binding var editing: String?

    private var isEditing: Bool { editing == row.provider }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(row.displayName)
                StatusDot(row: row)
                Spacer()
                Button(isEditing ? "收起" : "编辑") {
                    editing = isEditing ? nil : row.provider
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            if isEditing {
                ProviderEditor(model: model, row: row)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        .accessibilityIdentifier("settings.provider.\(row.provider)")
    }
}

struct StatusDot: View {
    let row: ProviderRow

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .help(help)
    }

    private var color: Color {
        switch row.credentialConfigured {
        case true: return .green
        case false: return .red
        default: return .secondary.opacity(0.4)   // 凭据服务不在场 = 不知道
        }
    }

    private var help: String {
        let credential: String
        switch row.credentialConfigured {
        case true: credential = "凭据已配置"
        case false: credential = "没有 key"
        default: credential = "凭据状态未知"
        }
        return credential + " · " + (row.live ? "路由已注册" : "路由未注册")
    }
}

/// 展开后的 provider 编辑区：API key + 自定义设置。
struct ProviderEditor: View {
    @ObservedObject var model: SettingsModel
    let row: ProviderRow

    @State private var entry = ""
    @State private var busy = false
    @State private var error: String?

    private var configured: Bool { row.credentialConfigured == true }

    private var scopedFields: [SchemaField] {
        guard let snapshot = model.namespace(row.settingsNs),
              let node = snapshot.schema.node(at: row.settingsPath),
              case .object(let fields, _) = node else { return [] }
        return fields
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(row.displayName).font(.callout.weight(.medium))
                Text(row.provider).font(.caption.monospaced()).foregroundStyle(.tertiary)
                Spacer()
                Text(row.live ? "路由已注册" : "路由未注册")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Form {
                if row.credentialWritable {
                    LabeledContent("API key：") {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                // 占位符走 prompt——第一个参数是标签，会漏成控件旁的文字。
                                SecureField("", text: $entry,
                                            prompt: Text(configured ? "留空 = 保留现有的" : "填入 API key"))
                                    .labelsHidden()
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 240)
                                    .onSubmit(save)
                                Button("保存", action: save)
                                    .disabled(entry.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                                if configured { Button("清除", action: clear).disabled(busy) }
                            }
                            Text("存在设置文件之外，引用名 \(row.keyRef)"
                                 + (row.keyRefStored ? "" : "（按命名约定推出来的）"))
                                .font(.caption).foregroundStyle(.secondary)
                            if let error {
                                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                            }
                        }
                    }
                } else {
                    LabeledContent("API key：") {
                        Text("由只读来源提供（环境变量或 .env），这里改不了。")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.columns)

            if !scopedFields.isEmpty, let snapshot = model.namespace(row.settingsNs) {
                // Web 管这叫 Customized settings，里面是 Base URL 与 Models 表。
                DisclosureGroup("自定义设置（\(scopedFields.count) 项）") {
                    Form {
                        ForEach(scopedFields, id: \.key) { field in
                            FieldOrGroup(model: model, snapshot: snapshot,
                                         path: row.settingsPath + [field.key], node: field.node)
                        }
                    }
                    .formStyle(.columns)
                    .padding(.top, 6)
                }
                .font(.callout)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
    }

    private func save() {
        let value = entry.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        busy = true; error = nil
        model.setCredential(ref: row.keyRef, value: value) { failure in
            busy = false; error = failure
            if failure == nil { entry = "" }
        }
    }

    private func clear() {
        busy = true; error = nil
        model.unsetCredential(ref: row.keyRef) { failure in
            busy = false; error = failure
        }
    }
}

/// 「添加 provider」：目录收在下拉框里 + 一个 key 输入。
///
/// 对内建适配器来说"添加"就是**给它配上 key**——配好了 llm 就会注册它，
/// `live` 随之变真。所以这里不写配置，只写凭据，语义和 Web 的 Apply 一致。
/// （Web 还有「添加自定义 provider」，那个要往配置里写整个 provider 对象，不在本轮。）
struct AddProviderBox: View {
    @ObservedObject var model: SettingsModel
    let catalog: [ProviderRow]
    @Binding var open: Bool

    @State private var picked: String = ""
    @State private var entry = ""
    @State private var busy = false
    @State private var error: String?

    private var target: ProviderRow? {
        catalog.first { $0.provider == picked } ?? catalog.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                open.toggle()
            } label: {
                Label("添加 provider", systemImage: "plus")
            }
            .controlSize(.small)

            if open, let target {
                Form {
                    Picker("Provider：", selection: Binding(
                        get: { target.provider },
                        set: { picked = $0; entry = "" })) {
                        ForEach(catalog) { row in
                            Text(row.displayName).tag(row.provider)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()

                    LabeledContent("API key：") {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                SecureField("", text: $entry, prompt: Text("填入 API key"))
                                    .labelsHidden()
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 240)
                                    .onSubmit { save(target) }
                                Button("保存") { save(target) }
                                    .disabled(entry.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                            }
                            Text("会写到引用名 \(target.keyRef)")
                                .font(.caption).foregroundStyle(.secondary)
                            if let error {
                                Text(error).font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                }
                .formStyle(.columns)
                .padding(10)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    private func save(_ target: ProviderRow) {
        let value = entry.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        busy = true; error = nil
        model.setCredential(ref: target.keyRef, value: value) { failure in
            busy = false; error = failure
            if failure == nil { entry = ""; open = false }
        }
    }
}
