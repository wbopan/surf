import SwiftUI

/// 会话状态指示器。
///
/// **分三级，不一律画点**（设计稿「状态指示器」那张）：
///
/// | 级别 | 长什么样 | 为什么 |
/// |---|---|---|
/// | 正在进行 | 系统 spinner（`ProgressView`） | 运行中是*正在变化*，静止的点表达不了；且不依赖颜色 |
/// | 等你动作 | 语义符号 + 系统色 | 举手/气泡/警告三个形状本身就能区分，色盲或灰度下不丢信息 |
/// | 纯状态 | 什么都不画 | 空闲不是消息 |
///
/// 曾经四个状态全是彩色圆点，等于把"要你动手"和"纯信息"画成同一个东西；
/// 后来换成 `*.circle.fill`，圆底那块实心色在一列灰字里像红绿灯，一样刺眼。
/// 现在用的是**裸的语义符号**——不带圆底，形状直接说事：
///
/// - `hand.raised` 等你批准：举手就是"先别动，等我"，比一个叹号准
/// - `questionmark` 等你回答：问号就是问句本身，不用绕道气泡；蓝色是系统里
///   "轮到你了、可以点"的既有色，和橙（拦住你）、红（出错了）分得开
/// - `exclamationmark.triangle` 出错：三角警告是系统里"出问题了"的既有语义，
///   比 `xmark`（"关掉/否"）准；描边而非 `.fill`，实心三角是 alert 级别的分量
/// - `checkmark` 跑完了：**绿色**。绿的既有语义就是"一切正常、成过了"，
///   这一档正好是它（早年那版绿点用来表示*正在跑*才是反的，所以被删）
///
/// **槽位 20pt**（官方 `Sidebars/*/Medium/Items/Level 0` 的 Leading - Icon 就是
/// 20 宽），内部图标尺寸不变：`ProgressView().controlSize(.small)` 是 16pt，
/// 符号 13pt（勾 12pt，它本身就宽），都在槽里居中——光学重心对齐，
/// 行与行之间不会左右晃。
struct StatusIndicator: View {
    let status: SidebarSessionStatus
    /// 只用来读 AX label——界面上这里一个字都没有，全是符号与转轮。
    let strings: L

    /// 状态槽的宽度。会话行的 leading 槽（状态 / 归档）都用它对齐，
    /// 标题左缘因此恒定落在 14 + 20 + 4 = 38。
    static let slot: CGFloat = 20

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
            Image(systemName: "hand.raised")
                .font(.system(size: 13))
                .foregroundStyle(.orange)
        case .pendingQuestion:
            // 裸问号笔画细，同字号下比举手/警告轻一档，semibold 补回来。
            Image(systemName: "questionmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.blue)
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 13))
                .foregroundStyle(.red)
        case .done:
            // 勾自带宽度，同字号下比上面三个显大一圈，所以退到 12；
            // 加粗一档补回被减掉的分量，免得在描边符号旁边显得虚。
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.green)
        case .idle:
            Color.clear
        }
    }

    private var label: String {
        switch status {
        case .running: return strings.statusRunning
        case .pendingApproval: return strings.statusPendingApproval
        case .pendingQuestion: return strings.statusPendingQuestion
        case .failed: return strings.statusFailed
        case .done: return strings.statusDone
        case .idle: return ""
        }
    }
}
