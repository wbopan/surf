// 玻璃「模糊」标定台。
//
// 目的：量出 macOS 26/27 的 Liquid Glass 背景模糊到底是多大的高斯核、
// 顺带量它对饱和度/亮度做了什么，好把这三件事原样搬进 CSS 的
// backdrop-filter。**不测折射/扭曲**（我们不追求那个）。
//
// 手法：给玻璃底下垫一条**竖直硬边**（左黑右白）。理想硬边被 σ 的高斯
// 模糊之后是一条 erf 曲线，其 10%→90% 的水平宽度 W 与 σ 的关系是常数：
//
//     W(10→90) = 2 * √2 * erf⁻¹(0.8) * σ ≈ 2.5631 σ
//
// 所以只要扫一条水平剖面、找出 10% 和 90% 两个穿越点，σ 就出来了。
// 这个判据**只看曲线形状**，玻璃自己的底色/提亮/描边都只是仿射变换
// （y = a·f(x) + b），对 10/90 归一化后的穿越位置没有影响 —— 这正是
// 选它而不是直接拟合的原因。
//
// 三种尺寸各来一条，是为了回答「模糊半径随控件大小缩放吗」。
import SwiftUI
import AppKit

private let W: CGFloat = 760
private let STEP_H: CGFloat = 430
private let SAT_H: CGFloat = 210

/// 左黑右白的竖直硬边，边界正好在容器水平中点。
private struct StepBG: View {
    var body: some View { HStack(spacing: 0) { Color.black; Color.white } }
}

/// 六条饱和色带，用来量玻璃对颜色做的仿射变换。
private struct ColorBG: View {
    // **刻意避开纯色**：纯红/纯绿在玻璃的提亮+加饱和之后会撞 0 或 255 的天花板，
    // 一旦 clip 就再也解不出饱和度系数。这六档中间色保证六个通道全程不触边。
    static let bands: [(String, Color)] = [
        ("r180", Color(red: 180/255, green: 110/255, blue: 110/255)),
        ("g180", Color(red: 110/255, green: 180/255, blue: 110/255)),
        ("b180", Color(red: 110/255, green: 110/255, blue: 180/255)),
        ("y180", Color(red: 180/255, green: 180/255, blue: 110/255)),
        ("gray127", Color(red: 127/255, green: 127/255, blue: 127/255)),
        ("gray64", Color(red: 64/255, green: 64/255, blue: 64/255)),
    ]
    var body: some View {
        HStack(spacing: 0) { ForEach(Self.bands, id: \.0) { $1 } }
    }
}

struct ContentView: View {
    @Environment(\.controlActiveState) private var active

    var body: some View {
        VStack(spacing: 0) {
            // ① 模糊标定：硬边 + 三种高度的玻璃条 + 一枚真按钮
            ZStack {
                StepBG()
                VStack(spacing: 26) {
                    bar(96)          // 大面板
                    bar(48)          // 中
                    bar(32)          // 和实际按钮同高
                    Button("玻璃按钮 Glass Button Sample Wide") {}
                        .buttonStyle(.glass).controlSize(.large)
                    // 无玻璃对照：同一条硬边，确认它本身是 1px 锐边
                    Color.clear.frame(height: 40)
                }
                .padding(.vertical, 24)
                // 窗口激活态指示灯：绿=key，红=失活（失活态的玻璃是另一种材质，
                // 照它调必错，见 dash-nativeify/lib/client.js 的注释）
                VStack { HStack { Spacer()
                    Circle().fill(active == .key ? .green : .red)
                        .frame(width: 14, height: 14).padding(8) }
                    Spacer() }
            }
            .frame(height: STEP_H)

            // ② 颜色标定：饱和色带 + 一块玻璃盖住上半
            ZStack(alignment: .top) {
                ColorBG()
                // 比窗口更宽，让玻璃的左右边缘被裁到画面外 —— 色带正中的采样
                // 因此完全不受玻璃自身描边/发光污染。
                RoundedRectangle(cornerRadius: 0)
                    .fill(.clear).frame(width: W + 200, height: 96)
                    .glassEffect(.regular, in: .rect(cornerRadius: 0))
                    .padding(.top, 24)
            }
            .frame(height: SAT_H)
        }
        .frame(width: W, height: STEP_H + SAT_H)
    }

    private func bar(_ h: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: h / 4)
            .fill(.clear).frame(width: 640, height: h)
            .glassEffect(.regular, in: .rect(cornerRadius: h / 4))
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        if CommandLine.arguments.contains("--dark") {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        } else {
            NSApp.appearance = NSAppearance(named: .aqua)
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // `--hold`：**反复抢 key**。失活窗口里 macOS 把玻璃整个换成一块平灰
        // （没有渐变、没有边缘发光），照它量出来的一切都是错的；而探针一被别的
        // 窗口盖住就失活，实测普通的 activate / System Events 置前都抢不回来。
        //
        // **默认关着，因为它会把人赶出自己的电脑** —— 每 0.4s 夺一次焦点，打字
        // 光标会被拽走。要量数据时才加，量完立刻
        //     pkill -f GlassBlurProbe.app/Contents/MacOS
        // 右上角那颗灯是激活态回显：绿 = key（数据可信），红 = 失活（作废重来）。
        if CommandLine.arguments.contains("--hold") {
            Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
            }
        }
    }
}

@main
struct GlassBlurProbe: App {
    @NSApplicationDelegateAdaptor(Delegate.self) var delegate
    var body: some Scene {
        Window("Glass Blur Probe", id: "main") { ContentView() }
            .windowResizability(.contentSize)
            .windowStyle(.hiddenTitleBar)
    }
}
