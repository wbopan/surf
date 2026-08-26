import SwiftUI

/// 「智能体预设」页——对齐 dsh Web 的 Agent presets。
///
/// 数据来自 `ctx.agentPresets`（不是 `ctx.settings`），settings 里只有
/// `agent-presets.default` 那一个"默认用哪个"。**这一栏我一开始整个跳过了**，
/// 理由是"不由 settings 驱动"——那句话对，但没往下查一步：它由另一个 host 服务
/// 驱动，而我们本来就在 dsh 进程里，够得着。
///
/// **范围收窄到读 + 设默认**：Web 还能复制预设、用 Creator mode 起草新的，
/// 那要往盘上写目录（`copyComposition` / `deleteComposition`），单独一轮做对。
/// 这里给「在 Finder 里显示」当出口。
struct PresetsPage: View {
    @ObservedObject var model: SettingsModel
    let openPath: (String) -> Void

    private var builtIn: [PresetRow] { model.presets.filter(\.isBuiltIn) }
    private var custom: [PresetRow] { model.presets.filter { !$0.isBuiltIn } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.presetsAvailable {
                Text("agentPresets 服务不在场，这一页填不了。")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("一个预设就是会话跑起来时的那套插件组合——工具、提示词、能力。")
                    .font(.callout).foregroundStyle(.secondary)

                section("内建", builtIn)
                section("自定义", custom)

                if custom.isEmpty {
                    Text("还没有自定义预设。复制一份内建的去改，或者从 dsh Web 的 Creator mode 起步。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ rows: [PresetRow]) -> some View {
        if !rows.isEmpty {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            // 两列网格，照 Web 的卡片画廊。
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10)],
                      alignment: .leading, spacing: 10) {
                ForEach(rows) { row in
                    PresetCard(model: model, row: row, openPath: openPath)
                }
            }
        }
    }
}

struct PresetCard: View {
    @ObservedObject var model: SettingsModel
    let row: PresetRow
    let openPath: (String) -> Void

    private var isDefault: Bool { model.defaultPresetId == row.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(row.displayName).font(.body.weight(.medium))
                if isDefault { Badge(text: "在用", tint: .accentColor) }
                Spacer(minLength: 0)
            }

            if let description = row.description {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let broken = row.broken {
                // 坏掉的预设**照样列出来**——它正是用户要来修的那个，藏起来只会
                // 让人查不出为什么会话起不来。但不能让它被设成默认。
                Label(broken, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            Spacer(minLength: 2)

            HStack(spacing: 6) {
                Text(row.id).font(.caption.monospaced()).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                if !isDefault && row.broken == nil {
                    Button("设为默认") {
                        model.set(ns: "agent-presets", path: ["default"], value: .string(row.id))
                    }
                    .controlSize(.small)
                }
                Button {
                    openPath(row.path)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("在 Finder 里显示 \(row.path)")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(isDefault ? Color.accentColor : .clear, lineWidth: 1.5))
        .accessibilityIdentifier("settings.preset.\(row.id)")
    }
}

struct Badge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.16), in: Capsule())
            .foregroundStyle(tint)
    }
}
