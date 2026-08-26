// 两张同尺寸截图逐块比：打印差异块的内容点坐标与最大通道差。
// usage: diffmap a.png b.png <scale> [块边长pt=5] [阈值=2]
import AppKit
func load(_ p: String) -> ([UInt8], Int, Int) {
    let cg = NSImage(contentsOfFile: p)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    let w = cg.width, h = cg.height
    var b = [UInt8](repeating: 0, count: w*h*4)
    CGContext(data: &b, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        .draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (b, w, h)
}
let a = CommandLine.arguments
let (A, w, h) = load(a[1]); let (B, _, _) = load(a[2])
let s = Double(a[3])!, blk = Int((a.count > 4 ? Double(a[4])! : 5) * s), thr = a.count > 5 ? Int(a[5])! : 2
// 找品红原点标记；真实 App 的截图没有标记，那就退回绝对坐标（0,0）。
var ox = 0, oy = 0
outer: for y in 0..<h { for x in 0..<w { let i=(y*w+x)*4
    if A[i] > 240 && A[i+1] < 20 && A[i+2] > 240 { ox = x; oy = y; break outer } } }
var y = 0
while y < h { var x = 0
    while x < w {
        var mx = 0
        for yy in y..<min(h, y+blk) { for xx in x..<min(w, x+blk) {
            let i = (yy*w+xx)*4
            for c in 0..<3 { mx = max(mx, abs(Int(A[i+c]) - Int(B[i+c]))) } } }
        if mx >= thr {
            print(String(format: "pt(%.0f,%.0f) Δ%d", Double(x-ox)/s, Double(y-oy)/s, mx))
        }
        x += blk }
    y += blk }
