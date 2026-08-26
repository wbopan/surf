import SwiftUI

/// 「智能体预设」页——主从。
///
/// 数据来自 `ctx.agentPresets`（不是 `ctx.settings`），settings 里只有
/// `agent-presets.default` 那一个"默认用哪个"。
///
/// 上一版是两列卡片画廊。4 个内建时还行，用户写到 20 个自定义就散架了；
/// 而且"设为默认"是卡片上的一个**按钮**——按钮是动作，默认是**状态**，
/// 用按钮说状态，就得再加一个「在用」徽章去说现在是谁，两个东西说一件事。
/// 主从 + 详情里一个**无标签复选框**把这两个合成一个：勾上就是它，没勾就不是。
///
/// **范围仍旧是读 + 设默认**：Web 还能复制预设、用 Creator mode 起草新的，
/// 那要往盘上写目录（`copyComposition` / `deleteComposition`），单独一轮做对。
/// 所以源列表**没有 `+ −` 页脚**——可增删的才配页脚（见草图的版式规则）。
struct PresetsPage: View {
    @ObservedObject var model: SettingsModel
    let openPath: (String) -> Void

    @State private var selection: String?

    private var builtIn: [PresetRow] { model.presets.filter(\.isBuiltIn) }
    private var custom: [PresetRow] { model.presets.filter { !$0.isBuiltIn } }

    private var current: PresetRow? {
        model.presets.first { $0.id == selection } ?? model.presets.first
    }

    var body: some View {
        if !model.presetsAvailable {
            VStack { Spacer(); Text("agentPresets 服务不在场，这一页填不了。")
                .font(.callout).foregroundStyle(.secondary); Spacer() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(alignment: .top, spacing: 16) {
                List(selection: $selection) {
                    SwiftUI.Section("内建") {
                        ForEach(builtIn) { row($0) }
                    }
                    SwiftUI.Section("自定义") {
                        if custom.isEmpty {
                            Text("还没有").foregroundStyle(.tertiary).selectionDisabled()
                        } else {
                            ForEach(custom) { row($0) }
                        }
                    }
                }
                .sourceListChrome(width: 196)

                if let current {
                    PresetDetail(model: model, row: current, openPath: openPath)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func row(_ preset: PresetRow) -> some View {
        HStack(spacing: 6) {
            // 坏掉的预设**照样列出来**——它正是用户要来修的那个。
            if preset.broken != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text(preset.displayName).lineLimit(1)
        }
        .tag(preset.id)
        .accessibilityIdentifier("settings.preset.\(preset.id)")
    }
}

struct PresetDetail: View {
    @ObservedObject var model: SettingsModel
    let row: PresetRow
    let openPath: (String) -> Void

    private var isDefault: Bool { model.defaultPresetId == row.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailHeader(title: row.displayName,
                         subtitle: row.description,
                         identifier: row.id)

            Form {
                // **不用复选框**。默认预设必须有一个，勾掉它并不能让"没有默认"成立
                // ——一个只能勾上、勾不掉的复选框只好在选中时置灰，于是选中的那一项
                // 显示成一个「勾着的、灰的」控件，看着像坏了。
                // 两个状态各给一个不撒谎的形状：已是默认就是一句陈述，不是默认就是
                // 一个真能按的按钮。
                LabeledContent {
                    if isDefault {
                        Label("新会话默认用这个预设", systemImage: "checkmark")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Button("设为默认") {
                            model.set(ns: "agent-presets", path: ["default"], value: .string(row.id))
                        }
                        .disabled(!model.writable || row.broken != nil)
                        .accessibilityIdentifier("settings.preset.default.\(row.id)")
                    }
                } label: {
                    Color.clear.frame(width: 0, height: 0)
                }

                if let broken = row.broken {
                    LabeledContent {
                        Label(broken, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } label: {
                        Color.clear.frame(width: 0, height: 0)
                    }
                }

                FormRule()

                LabeledContent("位置：") {
                    HStack(spacing: 8) {
                        Text(row.path)
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.head)
                            .help(row.path)
                        Button("在 Finder 中显示") { openPath(row.path) }
                            .controlSize(.small)
                    }
                }
            }
            .formStyle(.columns)

            Spacer(minLength: 0)

            if !row.isBuiltIn { EmptyView() }
        }
    }
}
