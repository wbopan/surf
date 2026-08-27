// patch <png> <x0> <x1> <y0> <y1> [--linear]：矩形块内逐通道求平均。
import AppKit
let a = CommandLine.arguments
let cg = NSImage(contentsOfFile: a[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let w = cg.width, h = cg.height
var buf = [UInt8](repeating: 0, count: w * h * 4)
CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    .draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
let lin = a.contains("--linear")
func dec(_ v: Double) -> Double {
    let c = v / 255
    return (c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)) * 255
}
let n = a.filter { !$0.hasPrefix("--") }
let x0 = Int(n[2])!, x1 = Int(n[3])!, y0 = Int(n[4])!, y1 = Int(n[5])!
var s = [0.0, 0.0, 0.0]
for y in y0...y1 { for x in x0...x1 {
    let i = (y * w + x) * 4
    for c in 0..<3 { let v = Double(buf[i + c]); s[c] += lin ? dec(v) : v }
} }
let cnt = Double((x1 - x0 + 1) * (y1 - y0 + 1))
print(String(format: "%6.1f %6.1f %6.1f", s[0] / cnt, s[1] / cnt, s[2] / cnt))
