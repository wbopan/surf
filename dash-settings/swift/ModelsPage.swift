import SwiftUI

/// 模型页：provider 目录 × 路由活跃状态 × 凭据状态。
///
/// **范围是有意收窄的**（计划 D3）：列出、看状态、设/清 API key。
/// "添加自定义 provider"和"问端点要模型"是深水区，单独一轮做对。
///
/// **没有"启停开关"**：上游 `LlmRuntime` 里没有这个概念——路由活着(`live`)是
/// "配置完整到 llm 愿意注册它"的结果，不是一个可写字段。所以这里显示它，
/// 不假装能切它。（原计划 D3 写的"启停已声明的 provider"是我当时的误解，
/// 核过完整签名后改掉了。）
struct ModelsPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsPageScaffold(model: model,
                             title: "模型",
                             subtitle: "provider 的路由状态与 API key。详细参数在左边对应的命名空间里。") {
            if model.providers.isEmpty {
                Text("没有可配置的 provider。")
                    .foregroundStyle(.secondary)
            } else {
                // **分组是数据逼出来的**：实测有 38 个可配置 provider，其中在用的 3 个。
                // 平铺 38 张卡片（每张还带一个密码框）是一堵墙，用户要找的永远是前几个。
                let live = model.providers.filter(\.live)
                let ready = model.providers.filter { !$0.live && $0.credentialConfigured == true }
                let rest = model.providers.filter { !$0.live && $0.credentialConfigured != true }

                if !live.isEmpty { group("在用", live) }
                if !ready.isEmpty { group("已有 key，但路由没起来", ready) }
                if !rest.isEmpty {
                    DisclosureGroup("其余 \(rest.count) 个") {
                        VStack(spacing: 8) {
                            ForEach(rest) { ProviderCard(model: model, row: $0) }
                        }
                        .padding(.top, 6)
                    }
                    .padding(.top, 6)
                }
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ rows: [ProviderRow]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            ForEach(rows) { ProviderCard(model: model, row: $0) }
        }
        .padding(.bottom, 6)
    }
}

struct ProviderCard: View {
    @ObservedObject var model: SettingsModel
    let row: ProviderRow

    @State private var entry = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(row.live ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
                    .help(row.live ? "路由已注册" : "路由未注册（配置不完整）")
                Text(row.displayName).font(.body.weight(.medium))
                if row.declared == true {
                    Tag(text: "配置声明")
                }
                Spacer()
                Text(row.provider)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 6) {
                Text(row.keyRef)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .help(row.keyRefStored
                          ? "配置里存着的引用名"
                          : "配置里还没有 apiKeyEnv，按 dsh Web 的命名约定推出来的")
                if !row.keyRefStored {
                    Tag(text: "推断")
                }
                if let source = row.credentialSource {
                    Tag(text: source)
                }
                Spacer()
                status
            }

            if row.credentialWritable {
                HStack(spacing: 6) {
                    // secret 语义同 SecretField：从空开始，空 = 不变。
                    SecureField(configured ? "已配置（留空 = 不变）" : "输入 API key",
                                text: $entry)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)
                    Button("保存", action: save)
                        .disabled(entry.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                    if configured {
                        Button("清除", action: clear).disabled(busy)
                    }
                }
            } else if configured {
                Text("这个引用由只读来源提供（环境变量或 .env），这里改不了。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("settings.provider.\(row.provider)")
    }

    private var configured: Bool { row.credentialConfigured == true }

    @ViewBuilder
    private var status: some View {
        if busy {
            Text("保存中…").font(.caption).foregroundStyle(.secondary)
        } else if row.credentialConfigured == nil {
            // 凭据服务不在场。**说清楚是"不知道"而不是"没配"**——
            // 显示成红点会让用户去重设一个其实已经配好的 key。
            Text("凭据状态未知").font(.caption).foregroundStyle(.tertiary)
        } else {
            Text(configured ? "已配置" : "未配置")
                .font(.caption)
                .foregroundStyle(configured ? .green : .secondary)
        }
    }

    private func save() {
        let value = entry.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        busy = true
        error = nil
        model.setCredential(ref: row.keyRef, value: value) { failure in
            busy = false
            error = failure
            if failure == nil { entry = "" }
        }
    }

    private func clear() {
        busy = true
        error = nil
        model.unsetCredential(ref: row.keyRef) { failure in
            busy = false
            error = failure
        }
    }
}

struct Tag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
    }
}
