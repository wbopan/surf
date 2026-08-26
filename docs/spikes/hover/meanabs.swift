// 绝对像素坐标版的均值取样（给没有品红标记的真实 App 截图用）。
// usage: meanabs img.png <x> <y> <w> <h>
import AppKit
let a = CommandLine.arguments
let cg = NSImage(contentsOfFile: a[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let w = cg.width, h = cg.height
var buf = [UInt8](repeating: 0, count: w*h*4)
CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    .draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
let x0 = Int(a[2])!, y0 = Int(a[3])!, x1 = x0 + Int(a[4])!, y1 = y0 + Int(a[5])!
var r = 0.0, g = 0.0, b = 0.0, n = 0.0
for y in max(0,y0)..<min(h,y1) { for x in max(0,x0)..<min(w,x1) {
    let i = (y*w+x)*4; r += Double(buf[i]); g += Double(buf[i+1]); b += Double(buf[i+2]); n += 1 } }
print(String(format: "%.1f %.1f %.1f", r/n, g/n, b/n))
