import SwiftUI

/// 会话状态指示器。
///
/// **分三级，不一律画点**（设计稿「状态指示器」那张）：
///
/// | 级别 | 长什么样 | 为什么 |
/// |---|---|---|
/// | 正在进行 | 系统 spinner（`ProgressView`） | 运行中是*正在变化*，静止的点表达不了；且不依赖颜色 |
/// | 等你动作 | 语义符号 + 系统色 | 叹号/问号形状本身就能区分，色盲或灰度下不丢信息 |
/// | 纯状态 | 什么都不画 | 空闲不是消息 |
///
/// 曾经四个状态全是彩色圆点，等于把"要你动手"和"纯信息"画成同一个东西。
///
/// 绿点被删掉不是口味问题：绿点的既有语义是"一切正常"（Mail 的在线点那种），
/// 拿它表示"正在跑"是反的；而且它与橙点、紫点只差色相。
///
/// 尺寸统一 16pt 槽位：`ProgressView().controlSize(.small)` 就是 16pt，
/// 符号 13pt 居中——两者光学重心对齐，行与行之间不会左右晃。
struct StatusIndicator: View {
    let status: SidebarSessionStatus

    /// 状态槽的宽度。会话行、分组头的图标槽都用它对齐。
    static let slot: CGFloat = 16

    var body: some View {
        content
            .frame(width: Self.slot, height: Self.slot)
            .accessibilityLabel(Text(label))
            .accessibilityHidden(status == .idle)
    }

    @ViewBuilder
    private var content: some View {
        switch status {
        case .running:
            // 系统控件。颜色、辐条数、转速、以及"降低动态效果"时的降级全归系统。
            ProgressView()
                .controlSize(.small)
        case .pendingApproval:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.orange)
        case .pendingQuestion:
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.purple)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.red)
        case .done:
            // **空心而不是实心**：上面三个是"等你动手"，这个只是"跑完了，看一眼"。
            // 同样的字号下空心的视觉重量明显轻一档，一列扫下来分得开。
            Image(systemName: "checkmark.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        case .idle:
            Color.clear
        }
    }

    private var label: String {
        switch status {
        case .running: return "运行中"
        case .pendingApproval: return "待批准"
        case .pendingQuestion: return "待回答"
        case .failed: return "出错了"
        case .done: return "已跑完"
        case .idle: return ""
        }
    }
}
