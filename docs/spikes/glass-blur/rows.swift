// rows <png> <x> [阈值]：沿一列找出「亮块」的行区间，用来定位玻璃条。
import AppKit
let a = CommandLine.arguments
let cg = NSImage(contentsOfFile: a[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let w = cg.width, h = cg.height
var buf = [UInt8](repeating: 0, count: w * h * 4)
CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    .draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
let x = Int(a[2])!
let thr = a.count > 3 ? Double(a[3])! : 40
var start = -1
for y in 0..<h {
    let i = (y * w + x) * 4
    let v = (Double(buf[i]) + Double(buf[i+1]) + Double(buf[i+2])) / 3
    let on = v > thr
    if on && start < 0 { start = y }
    if !on && start >= 0 { print("行 \(start)…\(y-1)  高 \(y-start)"); start = -1 }
}
if start >= 0 { print("行 \(start)…\(h-1)  高 \(h-start)") }
