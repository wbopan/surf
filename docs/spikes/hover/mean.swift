// 量一块区域的平均 RGB。坐标是「内容点」（相对内容左上角，逻辑 pt），
// 靠图里那枚纯品红 6×6 标记定位原点，所以不用管标题栏多高、截图有没有留边。
// usage: mean img.png <scale> <x> <y> <w> <h>
import AppKit
let a = CommandLine.arguments
let cg = NSImage(contentsOfFile: a[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let w = cg.width, h = cg.height
var buf = [UInt8](repeating: 0, count: w * h * 4)
CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    .draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
@inline(__always) func px(_ x: Int, _ y: Int) -> (Int, Int, Int) {
    let i = (y * w + x) * 4; return (Int(buf[i]), Int(buf[i+1]), Int(buf[i+2]))
}
var ox = w, oy = h
for y in 0..<h { for x in 0..<w {
    let p = px(x, y)
    if p.0 > 240 && p.1 < 20 && p.2 > 240 { if y < oy || (y == oy && x < ox) { ox = min(ox, x); oy = min(oy, y) } }
} }
guard ox < w, oy < h else { FileHandle.standardError.write("找不到品红原点标记\n".data(using: .utf8)!); exit(1) }
let s = Double(a[2])!
let x0 = ox + Int(Double(a[3])! * s), y0 = oy + Int(Double(a[4])! * s)
let x1 = x0 + Int(Double(a[5])! * s), y1 = y0 + Int(Double(a[6])! * s)
var r = 0.0, g = 0.0, b = 0.0, n = 0.0
for y in max(0,y0)..<min(h,y1) { for x in max(0,x0)..<min(w,x1) {
    let p = px(x, y); r += Double(p.0); g += Double(p.1); b += Double(p.2); n += 1
} }
print(String(format: "%.1f %.1f %.1f", r/n, g/n, b/n))
