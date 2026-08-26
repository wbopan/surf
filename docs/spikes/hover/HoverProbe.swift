// 系统按钮 hover / press 实测台（macOS 27）。
//
// 一个游标只能悬停一枚按钮，所以布局是「每行两枚一模一样的按钮」：
// 左列永远没人碰 = 同一张截图里的基准，右列是被悬停/按下的那枚。
// 同图差分比跨截图比稳得多 —— 不受窗口挪动、色彩管理、激活态漂移影响。
//
// 每个格子左上角有一枚 8×8 指示灯：hover 时转绿。**这是「蓝键没变化」这类
// 负结论的必要回执** —— 没有它，分不清是按钮真没 hover 效果，还是游标压根没到位。
// 内容左上角另钉一枚 6×6 纯品红，量图工具靠它定位内容原点，不用猜标题栏多高。
//
// --press <row>：给该行右列那枚按钮发一记 leftMouseDown 并按住，N 秒后自动松开。
// 走 NSApp.postEvent（进程内事件队列），不碰全局 HID 流 —— 进程被杀也不会
// 留下「鼠标键卡住」的系统级烂摊子。
import SwiftUI
import AppKit

let W: CGFloat = 320, H: CGFloat = 280, ROW: CGFloat = 70, COL: CGFloat = 160

enum Kind: String { case glass, prominent }
struct RowSpec: Identifiable { let id: Int; let kind: Kind; let dark: Bool }
let ROWS: [RowSpec] = [
    .init(id: 0, kind: .glass,     dark: false),
    .init(id: 1, kind: .glass,     dark: true),
    .init(id: 2, kind: .prominent, dark: false),
    .init(id: 3, kind: .prominent, dark: true),
]

@ViewBuilder func btn(_ k: Kind) -> some View {
    let lbl = Text("Button").font(.system(size: 13, weight: .medium)).frame(width: 96, height: 26)
    switch k {
    case .glass:     Button {} label: { lbl }.buttonStyle(.glass)
    case .prominent: Button {} label: { lbl }.buttonStyle(.glassProminent)
    }
}

struct Cell: View {
    let kind: Kind
    @State private var over = false
    var body: some View {
        btn(kind)
            .onHover { over = $0 }
            .frame(width: COL, height: ROW)
            .overlay(alignment: .topLeading) {
                Rectangle().fill(over ? Color.green : Color.black).frame(width: 8, height: 8)
            }
    }
}

struct Probe: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(white: 0.5)
            ForEach(ROWS) { r in
                ZStack {
                    (r.dark ? Color(red: 0.118, green: 0.118, blue: 0.125) : Color(white: 0.969))
                    HStack(spacing: 0) { Cell(kind: r.kind); Cell(kind: r.kind) }
                }
                .frame(width: W, height: ROW)
                .environment(\.colorScheme, r.dark ? .dark : .light)
                .offset(y: CGFloat(r.id) * ROW)
            }
            Color(red: 1, green: 0, blue: 1).frame(width: 6, height: 6)
        }
        .frame(width: W, height: H, alignment: .topLeading)
    }
}

func arg(_ flag: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: flag), i + 1 < a.count else { return nil }
    return a[i + 1]
}

final class AD: NSObject, NSApplicationDelegate {
    var w: NSWindow!
    let hold = CommandLine.arguments.contains("--hold")
    let pressRow = arg("--press").flatMap(Int.init)

    func center(row: Int, col: Int) -> NSPoint {          // 内容坐标，自下而上
        NSPoint(x: CGFloat(col) * COL + COL / 2, y: H - (CGFloat(row) * ROW + ROW / 2))
    }
    func mouse(_ type: NSEvent.EventType, _ p: NSPoint) {
        guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: w.windowNumber, context: nil,
                                         eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        else { return }
        NSApp.postEvent(e, atStart: false)
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        w = NSWindow(contentRect: .init(x: 200, y: 200, width: W, height: H),
                     styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: Probe())
        w.acceptsMouseMovedEvents = true    // 不开这个，窗口内部的 tracking area 收不到移动
        w.makeKeyAndOrderFront(nil)

        let screenH = NSScreen.screens.first!.frame.height
        for r in ROWS { for c in 0..<2 {
            let s = w.convertPoint(toScreen: center(row: r.id, col: c))
            print("TARGET \(r.kind.rawValue) \(r.dark ? "dark" : "light") col=\(c) \(Int(s.x)) \(Int(screenH - s.y))")
        } }
        fflush(stdout)

        // 按下必须等窗口真的成为 key 才发 —— 失活态下玻璃退成平灰、蓝键丢 tint，
        // 拿那种渲染量出来的按下态全是错的（第一版就撞了这个）。
        // 就绪后打一行 PRESSED 到 stdout 当同步回执，外面的脚本盯这行再截图。
        if let row = pressRow {
            let p = center(row: row, col: 1)
            let g = w.convertPoint(toScreen: p)
            CGWarpMouseCursorPosition(CGPoint(x: g.x, y: screenH - g.y))
            var readySince: Date?
            var armed = false
            Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { t in
                guard !armed else { return }
                if NSApp.isActive && self.w.isKeyWindow {
                    if readySince == nil { readySince = Date() }
                    if Date().timeIntervalSince(readySince!) > 1.0 {
                        armed = true; t.invalidate()
                        self.mouse(.leftMouseDown, p)
                        print("PRESSED"); fflush(stdout)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 12.0) { self.mouse(.leftMouseUp, p) }
                    }
                } else { readySince = nil }
            }
        }

        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            if self.hold { NSApp.activate(ignoringOtherApps: true); self.w.makeKeyAndOrderFront(nil) }
            self.w.title = "HoverProbe \(NSApp.isActive ? "ACTIVE" : "inactive")/\(self.w.isKeyWindow ? "KEY" : "nokey")"
        }
        if hold { NSApp.activate(ignoringOtherApps: true) }
    }
}
let app = NSApplication.shared; let d = AD(); app.delegate = d
app.setActivationPolicy(.regular); app.run()
