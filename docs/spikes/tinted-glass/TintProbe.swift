// 系统「带色玻璃」探针：蓝 / 红 两种 tint，各在浅深两档背景上，
// 同时给出 .glassProminent 按钮样式与 .glassEffect(.regular.tint(_)) 两条路径 ——
// 先看清系统的红蓝按钮到底是哪一种，再谈复刻。
// 与 refs.swift 同一条规矩：**必须截激活态**，所以 --hold 反复抢 key，
// 标题实时回显 NSApp.isActive / isKeyWindow 当回执。
import SwiftUI
import AppKit

struct Probe: View {
    func label(_ t: String) -> some View {
        Text(t).font(.system(size: 13, weight: .medium)).frame(width: 104, height: 32)
    }
    func cell<V: View>(_ bg: Color, _ scheme: ColorScheme, @ViewBuilder _ v: () -> V) -> some View {
        v().frame(width: 150, height: 65).background(bg).environment(\.colorScheme, scheme)
    }
    func pair<V: View>(_ name: String, @ViewBuilder _ v: @escaping (ColorScheme) -> V) -> some View {
        HStack(spacing: 0) {
            cell(.white, .light) { v(.light) }
            cell(Color(red: 0.118, green: 0.118, blue: 0.125), .dark) { v(.dark) }
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            pair("prom-blue") { _ in Button { } label: { label("Prominent") }
                .buttonStyle(.glassProminent).tint(.blue) }
            pair("prom-red")  { _ in Button { } label: { label("Prominent") }
                .buttonStyle(.glassProminent).tint(.red) }
            pair("tint-blue") { _ in label("Tinted").glassEffect(.regular.tint(.blue), in: .capsule) }
            pair("tint-red")  { _ in label("Tinted").glassEffect(.regular.tint(.red),  in: .capsule) }
        }
        .frame(width: 300, height: 260, alignment: .topLeading)
        .background(Color.gray)
    }
}

final class AD: NSObject, NSApplicationDelegate {
    var w: NSWindow!
    let hold = CommandLine.arguments.contains("--hold")
    func applicationDidFinishLaunching(_ n: Notification) {
        w = NSWindow(contentRect: .init(x: 200, y: 200, width: 300, height: 260),
                     styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: Probe())
        w.makeKeyAndOrderFront(nil)
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            if self.hold { NSApp.activate(ignoringOtherApps: true); self.w.makeKeyAndOrderFront(nil) }
            self.w.title = "TintProbe \(NSApp.isActive ? "ACTIVE" : "inactive")/\(self.w.isKeyWindow ? "KEY" : "nokey")"
        }
        if hold { NSApp.activate(ignoringOtherApps: true) }
    }
}
let app = NSApplication.shared; let d = AD(); app.delegate = d
app.setActivationPolicy(.regular); app.run()
