import SwiftUI

/// 「模型」页——主从版式：带边框的源列表 + 右边的详情。
///
/// 上一版是一坨灰色圆角背景里排三行，每行右边一个「编辑」按钮，点开就地展开。
/// 那是网页的做法。macOS 偏好设置里"一组同类东西，选一个改它"只有一种形状，
/// 参考设计里 Mimestream 的 Accounts 就是标准答案：
/// `List(selection:)` + `.listStyle(.bordered)` + 底下一条 `+ −`，右边是详情表单。
///
/// 换来的不只是好看：选中、键盘上下键、⌘/⇧ 多选全是系统给的，而"编辑"这个
/// 中间状态整个消失了——选中即编辑，少一次点击、少一个要记的状态。
///
/// **列出的判据没变**：路由活着，或者凭据配好了。38 个只在目录里的 provider 藏在
/// `+` 后面（Web 也是这么分的）。
struct ModelsPage: View {
    @ObservedObject var model: SettingsModel

    @State private var selection: String?
    @State private var adding = false

    private var configured: [ProviderRow] {
        model.providers.filter { $0.live || $0.credentialConfigured == true }
    }

    private var catalog: [ProviderRow] {
        let shown = Set(configured.map(\.provider))
        return model.providers.filter { !shown.contains($0.provider) }
    }

    /// 当前选中的那个。**选中项消失时回落到第一个**——provider 列表是后到的，
    /// 首帧 `selection` 必然是 nil，不回落的话详情栏会空一拍。
    private var current: ProviderRow? {
        configured.first { $0.provider == selection } ?? configured.first
    }

    var body: some View {
        if !model.modelsAvailable {
            VStack(alignment: .leading, spacing: 6) {
                Text("llm 服务不在场，这一页填不了。").font(.callout)
                Text("默认模型仍可在配置文件里改。").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 16) {
                    providerList
                    detail
                }
                .frame(maxHeight: .infinity)

                // **这条是整窗宽的**，跟 `FormRule` 不是一回事：它分的是页面的两块
                // （"改哪个 provider" 与 "默认用哪个模型"），不是一张表单里的两组控件。
                Divider().padding(.vertical, 12)

                defaultModelForm
            }
            .sheet(isPresented: $adding) {
                AddProviderSheet(model: model, catalog: catalog, done: { adding = false })
            }
        }
    }

    private var providerList: some View {
        List(configured, selection: $selection) { row in
            HStack(spacing: 7) {
                StatusDot(color: dotColor(row), help: dotHelp(row))
                Text(row.displayName).lineLimit(1).truncationMode(.middle)
            }
            .tag(row.provider)
            .listRowSeparator(.hidden)
            .accessibilityIdentifier("settings.provider.\(row.provider)")
        }
        .sourceListChrome(width: 196) {
            SourceListFooter(
                add: { adding = true },
                addHelp: "添加 provider",
                // **`−` 是清 key，不是删 provider**。provider 是不是在场由配置决定，
                // 这里能安全撤销的只有凭据——写一个会真的删配置的 `−`，得先想清楚
                // 内建适配器和用户自己加的那种删起来根本不是一回事。
                remove: { clearKey() },
                removeHelp: "清除这个 provider 的 API key",
                canRemove: current.map { $0.credentialWritable && $0.credentialConfigured == true } ?? false)
        }
        // 选中项写回 binding——详情栏"回落到第一个"不该让左列一行都不高亮。
        .onChange(of: configured.map(\.provider)) { _, list in
            if selection == nil || !list.contains(selection!) { selection = list.first }
        }
        .onAppear { if selection == nil { selection = configured.first?.provider } }
    }

    @ViewBuilder
    private var detail: some View {
        if let current {
            ProviderDetail(model: model, row: current)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack {
                Spacer()
                Text("还没有配好的 provider。点 + 添加一个。")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 默认模型。**Web 没有这一段**（它把选模型放在输入框那条工具栏上），
    /// 但 `agent-default-model` 是实打实的设置项，没有别的地方能露面。
    /// 用一个右对齐的组标签带三行——照参考设计里 Advanced 那页 `Reset:` 的写法。
    @ViewBuilder
    private var defaultModelForm: some View {
        if let snapshot = model.namespace(SettingsTabs.defaultModelNs),
           case .object(let fields, _) = snapshot.schema, !fields.isEmpty {
            Form {
                ForEach(fields, id: \.key) { field in
                    FieldOrGroup(model: model, snapshot: snapshot,
                                 path: [field.key], node: field.node)
                }
            }
            .formStyle(.columns)
        }
    }

    private func clearKey() {
        guard let current else { return }
        model.unsetCredential(ref: current.keyRef) { failure in
            if let failure { model.notice = failure }
        }
    }

    private func dotColor(_ row: ProviderRow) -> Color {
        switch row.credentialConfigured {
        case true: return .green
        case false: return .red
        default: return .secondary.opacity(0.4)
        }
    }

    private func dotHelp(_ row: ProviderRow) -> String {
        let credential: String
        switch row.credentialConfigured {
        case true: credential = "凭据已配置"
        case false: credential = "没有 key"
        default: credential = "凭据状态未知"
        }
        return credential + " · " + (row.live ? "路由已注册" : "路由未注册")
    }
}

/// 一个 provider 的详情。两栏用分段控件分开，照参考设计里
/// Account Information / Inbox Categories / Vacation 那条。
struct ProviderDetail: View {
    @ObservedObject var model: SettingsModel
    let row: ProviderRow

    private enum Facet: String, CaseIterable, Identifiable {
        case credential, settings
        var id: String { rawValue }
        var title: String { self == .credential ? "凭据" : "自定义设置" }
    }

    @State private var facet: Facet = .credential
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
        VStack(alignment: .leading, spacing: 12) {
            DetailHeader(title: row.displayName,
                         subtitle: row.live ? "路由已注册" : "路由未注册",
                         identifier: row.provider)

            // **`TabView` 而不是 `Picker(.segmented)`**：分段控件的选中态是一块
            // 实心 accent 色，在一屏灰白里非常刺眼；而 macOS 的 `NSTabView`
            // ——SwiftUI 这边就是 `TabView` 的默认样式——选中态是一枚玻璃凸起的
            // 标签，骑在内容面板的上沿，没有 accent 色。参考图里 Accounts 那三个
            // 标签就是它，我们这一栏的结构（左列选 provider、右边分栏看详情）
            // 跟它一模一样，用同一个控件才对得上。
            if scopedFields.isEmpty {
                // 只有凭据一栏时不摆标签条——一个只有一格的标签条是个假控件。
                credentialForm
                Spacer(minLength: 0)
            } else {
                TabView(selection: $facet) {
                    credentialForm
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .tabItem { Text(Facet.credential.title) }
                        .tag(Facet.credential)

                    settingsForm
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .tabItem { Text(Facet.settings.title) }
                        .tag(Facet.settings)
                }
            }
        }
        // provider 一换，草稿与错误都要清——**不清的话上一个 provider 的错误
        // 会挂在下一个头上**，看着像刚刚这个也失败了。
        .onChange(of: row.provider) { _, _ in entry = ""; error = nil; facet = .credential }
    }

    private var credentialForm: some View {
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
                                // **别钉死宽度**：详情栏只有三百来点宽，236 + 「保存」
                                // 挤不下，按钮会被切掉半个（实测）。让输入框吃剩下的。
                                .frame(minWidth: 110)
                                .onSubmit(save)
                            Button("保存", action: save)
                                .disabled(entry.trimmingCharacters(in: .whitespaces).isEmpty || busy)
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
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.columns)
    }

    private var settingsForm: some View {
        // **只渲染这个 provider 自己那棵子树**：`llm-pi-ai` 这个 ns 是所有自定义
        // provider 共用的，整段铺开会把别人的配置也摆出来。
        ScrollView {
            Form {
                if let snapshot = model.namespace(row.settingsNs) {
                    ForEach(scopedFields, id: \.key) { field in
                        FieldOrGroup(model: model, snapshot: snapshot,
                                     path: row.settingsPath + [field.key], node: field.node)
                    }
                }
            }
            .formStyle(.columns)
        }
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
}

/// 「添加 provider」。
///
/// 从内联的一块框改成 sheet：`+` 在列表页脚上，而 macOS 里页脚 `+` 的惯例就是
/// 弹一张 sheet（参考设计的 Accounts 亦然）。内联展开会把下面的默认模型那组顶下去。
///
/// 对内建适配器来说"添加"就是**给它配上 key**——配好了 llm 就会注册它。
/// Web 还有「添加自定义 provider」（要往配置里写整个 provider 对象），不在本轮。
struct AddProviderSheet: View {
    @ObservedObject var model: SettingsModel
    let catalog: [ProviderRow]
    let done: () -> Void

    @State private var picked: String = ""
    @State private var entry = ""
    @State private var busy = false
    @State private var error: String?

    private var target: ProviderRow? {
        catalog.first { $0.provider == picked } ?? catalog.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加 provider").font(.headline)

            if let target {
                Form {
                    Picker("Provider：", selection: Binding(
                        get: { target.provider },
                        set: { picked = $0; entry = "" })) {
                        ForEach(catalog) { row in Text(row.displayName).tag(row.provider) }
                    }
                    .pickerStyle(.menu)

                    LabeledContent("API key：") {
                        VStack(alignment: .leading, spacing: 3) {
                            SecureField("", text: $entry, prompt: Text("填入 API key"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { save(target) }
                            Text("会写到引用名 \(target.keyRef)")
                                .font(.caption).foregroundStyle(.secondary)
                            if let error {
                                Text(error).font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                }
                .formStyle(.columns)

                HStack {
                    Spacer()
                    Button("取消", action: done).keyboardShortcut(.cancelAction)
                    Button("添加") { save(target) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(entry.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                }
            } else {
                Text("目录里的 provider 都已经配过了。").foregroundStyle(.secondary)
                HStack { Spacer(); Button("好", action: done).keyboardShortcut(.defaultAction) }
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func save(_ target: ProviderRow) {
        let value = entry.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        busy = true; error = nil
        model.setCredential(ref: target.keyRef, value: value) { failure in
            busy = false; error = failure
            if failure == nil { done() }
        }
    }
}
