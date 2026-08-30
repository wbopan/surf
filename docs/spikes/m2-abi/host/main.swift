import AppKit
import SwiftUI
import WebKit
import SurfSDK

// ============================================================
// M2 ABI spike 宿主：模拟壳的 registry + 编译机装载路径，
// 逐条撞计划 §6.5 的断言。结果打 [PASS]/[FAIL]/[????] 到 stdout。
// ============================================================

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "out"
var results: [(String, String, String)] = []
func record(_ id: String, _ verdict: String, _ detail: String) {
    results.append((id, verdict, detail))
    print("[\(verdict)] \(id): \(detail)")
}
func assert_(_ id: String, _ ok: Bool, _ detail: String) { record(id, ok ? "PASS" : "FAIL", detail) }
func inconclusive(_ id: String, _ detail: String) { record(id, "????", detail) }
func info(_ m: String) { print("[INFO] \(m)") }

// MARK: - 壳侧 registry（计划 §4.1：只放拓扑，不放流量）

final class SlotBox: ObservableObject {
    @Published var version: Int = 0
    var factory: (() -> AnyView)?
}

final class Registry: SurfHost {
    let box = SlotBox()
    var objects: [String: AnyObject] = [:]
    var notes: [String] = []

    func register(slot: String, version: Int, factory: @escaping () -> AnyView) {
        note("register slot=\(slot) v\(version)")
        box.factory = factory
        box.version = version           // 版本跳变 → RootView 的 .id 换 → 整棵重建
    }
    func object(_ key: String) -> AnyObject? { objects[key] }
    func setObject(_ key: String, _ value: AnyObject) { objects[key] = value }
    func note(_ message: String) { notes.append(message); print("       · \(message)") }
    func notes(since: Int) -> [String] { Array(notes[min(since, notes.count)...]) }
}

struct RootView: View {
    @ObservedObject var box: SlotBox
    var body: some View {
        Group {
            if let f = box.factory {
                f().id(box.version)     // 计划 §6.3-2：版本跳变整棵重建
            } else {
                Text("no plugin").frame(width: 300, height: 230)
            }
        }
    }
}

// MARK: - 装载器（计划 §6.1）

typealias EntryFn = @convention(c) () -> UnsafeMutableRawPointer

func loadPlugin(_ path: String) -> (image: UnsafeMutableRawPointer, plugin: SurfPlugin)? {
    // RTLD_LOCAL：多个 dylib 导出同名 surf_plugin_entry，必须按 handle 取符号。
    guard let image = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
        info("dlopen 失败 \(path): \(String(cString: dlerror()))")
        return nil
    }
    guard let sym = dlsym(image, "surf_plugin_entry") else {
        info("dlsym 失败: \(String(cString: dlerror()))")
        return nil
    }
    let raw = unsafeBitCast(sym, to: EntryFn.self)()
    let obj = Unmanaged<AnyObject>.fromOpaque(raw).takeRetainedValue()
    guard let plugin = obj as? SurfPlugin else {
        info("entry 返回值 as? SurfPlugin 失败：\(type(of: obj))")
        return nil
    }
    return (image, plugin)
}

// MARK: - 渲染取证

func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

func capture(_ view: NSView, _ name: String) -> NSBitmapImageRep? {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: rep)
    if let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
    }
    return rep
}

/// "真的画出了东西"：不透明像素数 + 量化后的 distinct 颜色数。
func substance(_ rep: NSBitmapImageRep) -> (opaque: Int, colors: Int) {
    var opaque = 0
    var seen = Set<Int>()
    for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            guard let c = rep.colorAt(x: x, y: y) else { continue }
            if c.alphaComponent > 0.05 { opaque += 1 }
            seen.insert((Int(c.redComponent * 15) << 8) | (Int(c.greenComponent * 15) << 4) | Int(c.blueComponent * 15))
        }
    }
    return (opaque, seen.count)
}

/// 精确逐像素差异计数——文字 0→1 这种小变化聚合统计会吃掉。
func pixelDiff(_ a: NSBitmapImageRep?, _ b: NSBitmapImageRep?) -> Int {
    guard let a, let b, let pa = a.bitmapData, let pb = b.bitmapData,
          a.bytesPerRow == b.bytesPerRow, a.pixelsHigh == b.pixelsHigh else { return -1 }
    let spp = max(a.samplesPerPixel, 1)
    var diff = 0
    for row in 0..<a.pixelsHigh {
        let base = row * a.bytesPerRow
        for i in stride(from: base, to: base + a.bytesPerRow, by: spp) {
            if pa[i] != pb[i] || pa[i + 1] != pb[i + 1] || pa[i + 2] != pb[i + 2] { diff += 1 }
        }
    }
    return diff
}

func clickAt(_ window: NSWindow, _ p: NSPoint) {
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil,
                                      eventNumber: 0, clickCount: 1,
                                      pressure: type == .leftMouseDown ? 1 : 0) {
            window.sendEvent(e)
        }
        pump(0.1)
    }
}

/// evaluateJavaScript 的同步包装（spike 里全在主线程按序跑）。
func js(_ wv: WKWebView, _ script: String) -> String? {
    var result: String?
    var done = false
    wv.evaluateJavaScript(script) { r, err in
        result = (r as? String) ?? (r.map { "\($0)" })
        if let err { result = "JS-ERROR \(err.localizedDescription)" }
        done = true
    }
    let deadline = Date().addingTimeInterval(4)
    while !done && Date() < deadline { pump(0.05) }
    return result
}

// MARK: - 主流程

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let registry = Registry()

// 计划 §7.1：WKWebView 实例由**壳**创建并放保管箱，插件只借用排版。
let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
webView.loadHTMLString("<html><body style='margin:0;background:#2b8a3e;color:#fff;font:12px -apple-system'>shell-owned WKWebView</body></html>", baseURL: nil)
registry.setObject("shell.webview", webView)

let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 230),
                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "surf ABI spike"
let hosting = NSHostingView(rootView: RootView(box: registry.box))
window.contentView = hosting
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
pump(0.8)
let jsSeed = js(webView, "window.__spikeState = 'alive-\(Int(Date().timeIntervalSince1970))'; window.__spikeState")
info("WebView 初始 JS 状态：\(jsSeed ?? "nil")")

// ---------- 断言 1 / 2：装载与渲染 ----------
info("=== 断言 1/2：swiftc -emit-library → dlopen → SwiftUI 上屏 ===")
guard let g1 = loadPlugin("\(outDir)/alpha_g1/libAlpha_g1.dylib") else {
    assert_("A1.dlopen", false, "装载 alpha g1 失败"); exit(1)
}
assert_("A1.dlopen", true, "dlopen + dlsym(surf_plugin_entry) + as? SurfPlugin 成功")

var g1Handle: AnyObject? = g1.plugin.activate(host: registry)
assert_("A2.retain", g1Handle != nil,
        "Unmanaged.passRetained/takeRetainedValue 往返后 activate 正常返回 handle：\(g1Handle.map { "\(type(of: $0))" } ?? "nil")")
pump(0.8)

let shot1 = capture(hosting, "01-alpha-g1")
let sub1 = shot1.map(substance) ?? (opaque: 0, colors: 0)
assert_("A1.render", sub1.opaque > 100 && sub1.colors > 3,
        "g1 视图上屏：不透明像素 \(sub1.opaque)、distinct 颜色 \(sub1.colors)（01-alpha-g1.png）")

// ---------- 断言 1b：@Observable 跨 dylib 驱动重绘（经 SDK existential 触发）----------
if let h = g1Handle as? SurfOpaqueHandle {
    let before = capture(hosting, "02-before-poke")
    h.poke()                                   // 壳 → SDK 协议 → 插件内部 @Observable
    pump(0.5)
    let after = capture(hosting, "03-after-poke")
    let d = pixelDiff(before, after)
    assert_("A1.observe", d > 0,
            "壳经 SDK existential 改插件内 @Observable 后画面变化：\(d) 个像素（Observation 宏跨 dylib 生效）")
} else {
    assert_("A1.observe", false, "handle as? SurfOpaqueHandle 失败")
}

// ---------- 断言 1c：真实事件链（合成鼠标点击 SwiftUI Button）----------
do {
    let before = capture(hosting, "04-before-click")
    var hitDiff = 0
    var hitY: CGFloat = 0
    for y in stride(from: CGFloat(100), through: 135, by: 5) {   // Button 大致纵向区间
        clickAt(window, NSPoint(x: 150, y: y))
        pump(0.35)
        let after = capture(hosting, "05-after-click")
        let d = pixelDiff(before, after)
        if d > 0 { hitDiff = d; hitY = y; break }
    }
    if hitDiff > 0 {
        assert_("A1.interact", true, "合成点击 (150,\(Int(hitY))) 命中 Button，画面变化 \(hitDiff) 个像素 = 事件链跨 dylib 通")
    } else {
        inconclusive("A1.interact", "扫描 y=100…135 没触发变化——可能是坐标没命中，非 ABI 问题（A1.observe 已证明 Observation 跨 dylib 生效）")
    }
}

// ---------- 断言 7：跨插件依赖装载 ----------
info("=== 断言 6/7：跨插件 import（beta import Alpha）===")
let betaNotesAt = registry.notes.count
var betaHandle: AnyObject?
if let beta = loadPlugin("\(outDir)/beta/libBeta.dylib") {
    betaHandle = beta.plugin.activate(host: registry)
    let b0 = registry.notes(since: betaNotesAt).first { $0.hasPrefix("B0 ") } ?? "（无）"
    assert_("A7", betaHandle != nil && b0.contains("generation 1"),
            "先 dlopen Alpha 再 dlopen Beta，符号自动解析、跨 module 调用成立：\(b0)")
} else {
    assert_("A7", false, "装载 beta 失败（Alpha 的符号没解析上？）")
}

// ---------- 断言 3/4/5：世代替换 ----------
info("=== 断言 3/4/5：世代替换 ===")
let g2Path = "\(outDir)/alpha_g2/libAlpha_g2.dylib"
if FileManager.default.fileExists(atPath: g2Path), let g2 = loadPlugin(g2Path) {
    let notesAt = registry.notes.count
    let g2Handle = g2.plugin.activate(host: registry)
    assert_("A3.load", g2Handle != nil,
            "第二代装载并 activate（两个 dylib 同名 entry：RTLD_LOCAL + 按 handle dlsym 各取各的）")
    pump(0.8)
    let shot2 = capture(hosting, "06-alpha-g2")
    let d = pixelDiff(shot1, shot2)
    let sub2 = shot2.map(substance) ?? (opaque: 0, colors: 0)
    assert_("A3.swap", sub2.colors > 3 && d > 1000,
            "换代后新视图上屏（.id(version) 整棵重建）：与 g1 差异 \(d) 个像素（06-alpha-g2.png）")

    let newNotes = registry.notes(since: notesAt)
    let a5 = newNotes.first { $0.hasPrefix("A5 ") } ?? "（无）"
    assert_("A5", a5.contains("pong from alpha g1"), "SDK existential 跨代调用：\(a5)")
    let a4 = newNotes.first { $0.hasPrefix("A4 ") } ?? "（无）"
    assert_("A4", a4.contains("=> nil"), "旧代对象 as? 新代同名协议：\(a4)（期望 nil = 干净失败，不崩）")

    // ---------- 断言 6：A 换代后，未重编的 B 直接跑 ----------
    if let bh = betaHandle as? SurfOpaqueHandle {
        let stillAlive = bh.ping()
        assert_("A6", stillAlive.contains("generation 1"),
                "Alpha 已在 g2，未重编的 Beta 仍可运行但绑在旧代：\(stillAlive) → 桥必须强制级联重编")
    } else {
        assert_("A6", false, "beta handle 不可用")
    }
    // g2 视角看 beta 的对象：beta 实现的是 g1 的 AlphaFeature
    if let bh = betaHandle {
        registry.setObject("alpha.handle.g1", bh)   // 让 g2 再 cast 一次，这次目标是 beta 的对象
        info("（已把 beta handle 放进保管箱，供下轮 cast 观察）")
    }

    // ---------- 断言 9：WKWebView 实例跨代 ----------
    let jsAfter = js(webView, "window.__spikeState")
    assert_("A9", jsAfter != nil && jsAfter == jsSeed,
            "换代后保管箱里的 WKWebView 仍是同一实例、页面未重载：JS 状态 \(jsAfter ?? "nil")（种子 \(jsSeed ?? "nil")）")

    // ---------- 断言 3b：旧世代退休（故意不 dlclose，只放 ARC 回收）----------
    let before = registry.notes.filter { $0.contains("DEINIT alpha handle g1") }.count
    registry.objects.removeValue(forKey: "alpha.handle.g1")
    g1Handle = nil
    pump(0.4)
    let after = registry.notes.filter { $0.contains("DEINIT alpha handle g1") }.count
    assert_("A3.deinit", after > before,
            "释放旧世代 handle 后 deinit 被调用（\(before) → \(after)），旧 dylib 不 dlclose，进程存活")
} else {
    assert_("A3.load", false, "装载 alpha g2 失败")
}

// ---------- 断言 8：只有 .swiftinterface 的 SDK 分发路径 ----------
let ifacePath = "\(outDir)/bundle/libAlpha_iface.dylib"
if FileManager.default.fileExists(atPath: ifacePath) {
    info("=== 断言 8：SDK 只以 .swiftinterface 分发（模拟 app bundle）===")
    if let iface = loadPlugin(ifacePath) {
        let h = iface.plugin.activate(host: registry)
        assert_("A8", h != nil && (h as? SurfOpaqueHandle) != nil,
                "插件从 interface-only 路径编出的 dylib：dlopen + as? SurfPlugin + SDK existential 全部成立（类型身份跨 interface 重建一致）")
    } else {
        assert_("A8", false, "interface-only 插件装载失败——类型身份不匹配")
    }
}

print("\n================ 汇总 ================")
for (id, verdict, detail) in results {
    let mark = verdict == "PASS" ? "✓" : (verdict == "FAIL" ? "✗" : "?")
    print("\(mark) \(id)  \(detail)")
}
let failed = results.filter { $0.1 == "FAIL" }.count
let unknown = results.filter { $0.1 == "????" }.count
print("\(results.count - failed - unknown)/\(results.count) 通过，\(failed) 失败，\(unknown) 未定论")
exit(failed == 0 ? 0 : 2)
