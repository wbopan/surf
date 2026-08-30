// 按窗口截图，不要求目标 App 在前台，也不要求窗口未被遮挡。
//
// 三条为什么是这个写法的硬事实（都是实测撞出来的）：
//  1. `screencapture -l <windowID>` 在 macOS 26 上直接 "could not create image
//     from window" —— 老的 CGWindowListCreateImage 取图路径已经没了。唯一能按
//     窗口取图的正路是 ScreenCaptureKit。
//  2. 命令行工具调 SCContentFilter 会撞 CGS_REQUIRE_INIT 断言，必须先碰一下
//     `NSApplication.shared` 把 WindowServer 连接初始化起来。
//  3. captureImage 的 completionHandler 是 nullable，Swift 因此保留了"省略
//     handler"的 Void 重载，直接 await 会选中它。用 continuation 显式包一层。
import AppKit
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

_ = NSApplication.shared  // 见上文事实 2，删了必崩

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write("shot: \(message)\n".data(using: .utf8)!)
    exit(code)
}

var needle = "Surf Dev"
var outPath: String?
var scale = 1.0
var listOnly = false

var argv = Array(CommandLine.arguments.dropFirst())
while let arg = argv.first {
    argv.removeFirst()
    switch arg {
    case "--list": listOnly = true
    case "--app":
        guard let v = argv.first else { fail("--app needs a value") }
        needle = v; argv.removeFirst()
    case "--scale":
        guard let v = argv.first, let d = Double(v), d > 0 else { fail("--scale needs a positive number") }
        scale = d; argv.removeFirst()
    case "-h", "--help":
        print("""
        usage: tools/shot.sh [--app <name-substring>] [--scale <n>] [out.png]
               tools/shot.sh --list

          --app    窗口所属 App 名 / bundle id / 标题 / **pid** 的子串，默认 "Surf Dev"
                   （匹配到多个时取面积最大的那个，也就是主窗口）
          --scale  相对窗口点尺寸的倍数，默认 1（Retina 原生是 2，给模型看用 1 就够）
          --list   列出当前可截的窗口

          out.png  省略时落在 .scratch/shot.png（相对仓库根）
        """)
        exit(0)
    default:
        if arg.hasPrefix("-") { fail("unknown option \(arg)") }
        outPath = arg
    }
}

let content: SCShareableContent
do {
    content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
} catch {
    fail("cannot enumerate windows: \(error.localizedDescription)\n"
        + "  多半是跑这个脚本的终端没有「屏幕录制」权限：\n"
        + "  系统设置 → 隐私与安全性 → 屏幕录制 → 勾上你的终端，然后重启终端。")
}

// 只保留真正的应用窗口：有归属 App 且 App 名非空、尺寸像样。系统里飘着几千个
// CursorUIViewService 小窗口和无名的 "Display N Shield" 遮罩，不滤掉 --list 没法看。
//
// **显示器睡着时这个列表会骗人**：SCK 会列出一堆早就关掉、窗口服务还没回收的
// 残影（尺寸标题俱全，和真窗口分不出来），同时任何截图都报
// `-3811 audio/video capture failure`。实测被骗过一次，差点去修一个不存在的
// 窗口泄漏——真相是 AppKit 那边 `NSApp.windows` 只认一扇。
// **判据：截图一报 -3811 就先 `caffeinate -u -t 1` 把屏幕叫醒，再重看列表。**
// （不能靠 `w.isOnScreen` 过掉它们：那条同时会滤掉在别的 Space 里的真窗口，
// 而"不怕被盖住、不怕不在当前 Space"正是这个工具存在的理由。）
let visible = content.windows
    .filter { w in
        guard let app = w.owningApplication, !app.applicationName.isEmpty else { return false }
        return w.frame.width > 200 && w.frame.height > 200
    }
    .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }

func describe(_ w: SCWindow) -> String {
    let app = w.owningApplication?.applicationName ?? "-"
    let pid = w.owningApplication.map { String($0.processID) } ?? "-"
    return "  \(Int(w.frame.width))x\(Int(w.frame.height))\tpid \(pid)\t\(app)\t\(w.title ?? "")"
}

if listOnly {
    visible.forEach { print(describe($0)) }
    exit(0)
}

let lowered = needle.lowercased()
guard let win = visible.first(where: { w in
    let app = w.owningApplication
    // pid 也算进干草堆：多 worktree 并存时窗口名与尺寸一模一样，
    // **只有 pid 分得开**（`pgrep -af "Surf Dev.app/Contents/MacOS"` 取号）。
    let hay = [app?.applicationName, app?.bundleIdentifier, w.title,
               app.map { String($0.processID) }]
        .compactMap { $0 }.joined(separator: " ").lowercased()
    return hay.contains(lowered)
}) else {
    fail("no window matching \"\(needle)\". 当前可截的窗口：\n"
        + visible.map(describe).joined(separator: "\n"))
}

let filter = SCContentFilter(desktopIndependentWindow: win)
let config = SCStreamConfiguration()
config.width = max(1, Int(filter.contentRect.width * scale))
config.height = max(1, Int(filter.contentRect.height * scale))
config.showsCursor = false
config.captureResolution = .best

let image: CGImage = try await withCheckedThrowingContinuation { cont in
    SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
        if let image { cont.resume(returning: image) }
        else { cont.resume(throwing: error ?? NSError(domain: "shot", code: -1)) }
    }
}

let destination = outPath ?? ".scratch/shot.png"
let url = URL(fileURLWithPath: destination)
try? FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
guard let sink = CGImageDestinationCreateWithURL(
    url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fail("cannot write \(destination)")
}
CGImageDestinationAddImage(sink, image, nil)
guard CGImageDestinationFinalize(sink) else { fail("cannot encode \(destination)") }

let app = win.owningApplication?.applicationName ?? "?"
print("\(destination) \(image.width)x\(image.height) [\(app)] \(win.title ?? "")")
