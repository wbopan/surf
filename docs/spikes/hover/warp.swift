// 把真游标挪到全局坐标 (x, y)，并补发一记真 mouseMoved。
//
// 两件事都要做，缺一不可：
//  · CGWarpMouseCursorPosition 只改光标位置，**不产生移动事件**。AppKit 的
//    NSTrackingArea 靠窗口服务器按真实位置重算，所以原生控件光靠 warp 就够；
//  · **WKWebView 里的 :hover 不够** —— 网页的 hover 是 Web 进程按转发进去的
//    mouseMoved 算的，没有事件就没有 hover。所以再 post 一记 .mouseMoved。
// 只是移动、不带按键，不会在系统里留下任何粘滞状态。
import AppKit
let a = CommandLine.arguments
let p = CGPoint(x: Double(a[1])!, y: Double(a[2])!)
CGWarpMouseCursorPosition(p)
CGAssociateMouseAndMouseCursorPosition(1)
CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?
    .post(tap: .cghidEventTap)
let screenH = NSScreen.screens.first!.frame.height
let m = NSEvent.mouseLocation
print("warp -> \(Int(m.x)) \(Int(screenH - m.y))")
