// 会话状态指示器的候选方案对比台。
//
// 用真实的行几何（行高 32、状态槽 20、槽→标题 4、标题 13、时间 10 tertiary）
// 和真实的 sidebar 材质，把 N 组候选并排画在同一张图里 —— 同图对比比跨截图稳。
// running 一律是系统 spinner，不参与选型（那一档没有争议）。
import SwiftUI
import AppKit

let COL: CGFloat = 232
let ROW: CGFloat = 32
let SLOT: CGFloat = 20

enum St: CaseIterable { case running, approval, question, failed, done, idle }

struct Row { let title: String; let time: String; let st: St }
let ROWS: [Row] = [
    .init(title: "重构侧边栏状态位",     time: "14:36",     st: .running),
    .init(title: "把 dsh 装进原生壳",   time: "13:02",     st: .approval),
    .init(title: "写 M11 计划",         time: "11:48",     st: .question),
    .init(title: "构建脚本挂了",         time: "昨天",      st: .failed),
    .init(title: "翻译文案校对",         time: "昨天",      st: .done),
    .init(title: "apple-kit 数值检索",   time: "周一",      st: .idle),
]

/// 一组方案：给每个状态一个 (符号名, 颜色, 字号, 字重)。
struct Variant {
    let name: String
    let note: String
    let spec: (St) -> (String, Color, CGFloat, Font.Weight)?
}

let VARIANTS: [Variant] = [
    Variant(name: "A 旧的", note: "实心圆底 · 对照用") { s in
        switch s {
        case .approval: ("exclamationmark.circle.fill", .orange, 13, .medium)
        case .question: ("questionmark.circle.fill", .purple, 13, .medium)
        case .failed:   ("xmark.circle.fill", .red, 13, .medium)
        case .done:     ("checkmark.circle", .secondary, 13, .medium)
        default: nil
        }
    },
    Variant(name: "F 定稿", note: "举手/蓝问号/警告/绿勾") { s in
        switch s {
        case .approval: ("hand.raised", .orange, 13, .regular)
        case .question: ("questionmark", .blue, 13, .semibold)
        case .failed:   ("exclamationmark.triangle", .red, 13, .regular)
        case .done:     ("checkmark", .green, 12, .semibold)
        default: nil
        }
    },
    Variant(name: "F1 全 regular", note: "问号与勾不加粗") { s in
        switch s {
        case .approval: ("hand.raised", .orange, 13, .regular)
        case .question: ("questionmark", .blue, 13, .regular)
        case .failed:   ("exclamationmark.triangle", .red, 13, .regular)
        case .done:     ("checkmark", .green, 13, .regular)
        default: nil
        }
    },
    Variant(name: "F2 举手实心", note: "hand.raised.fill 压住笔画") { s in
        switch s {
        case .approval: ("hand.raised.fill", .orange, 12, .regular)
        case .question: ("questionmark", .blue, 13, .semibold)
        case .failed:   ("exclamationmark.triangle", .red, 13, .regular)
        case .done:     ("checkmark", .green, 12, .semibold)
        default: nil
        }
    },
]

struct Indicator: View {
    let st: St
    let v: Variant
    var body: some View {
        Group {
            if st == .running {
                ProgressView().controlSize(.small)
            } else if let (name, color, size, weight) = v.spec(st) {
                Image(systemName: name)
                    .font(.system(size: size, weight: weight))
                    .foregroundStyle(color)
            } else {
                Color.clear
            }
        }
        .frame(width: SLOT, height: SLOT)
    }
}

struct Column: View {
    let v: Variant
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(v.name).font(.system(size: 11, weight: .semibold))
                Text(v.note).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.bottom, 8)
            ForEach(ROWS.indices, id: \.self) { i in
                let r = ROWS[i]
                HStack(spacing: 4) {
                    Indicator(st: r.st, v: v)
                    Text(r.title).font(.system(size: 13)).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(r.time).font(.system(size: 10)).monospacedDigit()
                        .foregroundStyle(.tertiary).fixedSize()
                        .frame(minWidth: 36, alignment: .trailing)
                }
                .frame(height: ROW)
                .padding(.horizontal, 10)
            }
            // 放大对照：只看形，不看上下文。
            HStack(spacing: 10) {
                ForEach([St.approval, .question, .failed, .done], id: \.self) { s in
                    if let (name, color, _, weight) = v.spec(s) {
                        Image(systemName: name)
                            .font(.system(size: 24, weight: weight))
                            .foregroundStyle(color)
                            .frame(width: 30, height: 30)
                    }
                }
            }
            .padding(.horizontal, 10).padding(.top, 10)
        }
        .frame(width: COL, alignment: .leading)
    }
}

struct Board: View {
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(VARIANTS.indices, id: \.self) { i in
                Column(v: VARIANTS[i])
                if i < VARIANTS.count - 1 {
                    Divider().frame(height: 300).opacity(0.35)
                }
            }
        }
        .padding(.vertical, 14)
        .fixedSize()
    }
}

struct Effect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

struct Root: View {
    var body: some View {
        ZStack { Effect().ignoresSafeArea(); Board() }
    }
}

final class AD: NSObject, NSApplicationDelegate {
    var w: NSWindow!
    func applicationDidFinishLaunching(_ n: Notification) {
        if CommandLine.arguments.contains("--dark") {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        } else if CommandLine.arguments.contains("--light") {
            NSApp.appearance = NSAppearance(named: .aqua)
        }
        let W = COL * CGFloat(VARIANTS.count) + CGFloat(VARIANTS.count - 1) + 4
        w = NSWindow(contentRect: .init(x: 120, y: 200, width: W, height: 356),
                     styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "StatusIndicator Variants"
        w.contentView = NSHostingView(rootView: Root())
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

let app = NSApplication.shared
let d = AD(); app.delegate = d
app.setActivationPolicy(.regular)
app.run()
