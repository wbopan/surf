// 打印某个 App 的窗口在屏幕上的矩形（全局 CG 坐标，左上原点）。
// 有了它，截图里的像素坐标就能换算成 warp 用的屏幕坐标，
// 不必依赖 peekaboo（它在这台机器上偶发返回空）。
// usage: winrect <app 名子串>
import AppKit
let needle = CommandLine.arguments[1].lowercased()
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
for w in list {
    let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
    guard owner.lowercased().contains(needle) else { continue }
    guard let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
    guard (b["Width"] ?? 0) > 300, (b["Height"] ?? 0) > 300 else { continue }
    print("\(owner)  x=\(Int(b["X"]!)) y=\(Int(b["Y"]!)) w=\(Int(b["Width"]!)) h=\(Int(b["Height"]!))")
}
