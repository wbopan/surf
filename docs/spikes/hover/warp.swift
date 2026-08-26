// 把真游标挪到全局坐标 (x, y)，然后回读实际落点当回执。
// hover 必须动真游标 —— NSTrackingArea 的 mouseEntered 是窗口服务器按真实
// 光标位置生成的，postEvent 合成的 mouseMoved 不会触发它。
import AppKit
let a = CommandLine.arguments
let screenH = NSScreen.screens.first!.frame.height
CGWarpMouseCursorPosition(CGPoint(x: Double(a[1])!, y: Double(a[2])!))
CGAssociateMouseAndMouseCursorPosition(1)
let m = NSEvent.mouseLocation                      // 自下而上
print("warp -> \(Int(m.x)) \(Int(screenH - m.y))   screenH=\(Int(screenH))")
