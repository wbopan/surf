// 水平剖面扫描 + 高斯 σ 反演。
//   scan <png> <y0> <y1> [x0] [x1]
// 在 y0…y1 行上按列取平均（抗噪），打印剖面，并用 10%→90% 宽度算 σ：
//   σ = W(10→90) / 2.5631      （理想硬边被高斯模糊后的 erf 剖面）
// 输出的 σ 单位是**图像像素**，除以截图倍率才是 pt / CSS px。
import AppKit
let a = CommandLine.arguments
let cg = NSImage(contentsOfFile: a[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let w = cg.width, h = cg.height
var buf = [UInt8](repeating: 0, count: w * h * 4)
CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    .draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
// --linear：先把 sRGB 解码回线性光再平均。**这一步不是可选的洁癖**——
// macOS 的模糊是在线性光里做的，直接在 sRGB 码值上量剖面会得到一条明显
// 不对称的曲线（暗侧拖得长、亮侧收得快），σ 因此被高估。
let linear = CommandLine.arguments.contains("--linear")
func dec(_ v: Double) -> Double {
    let c = v / 255
    let l = c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    return l * 255
}
func px(_ x: Int, _ y: Int) -> (Double, Double, Double) {
    let i = (y * w + x) * 4
    let (r, g, b) = (Double(buf[i]), Double(buf[i + 1]), Double(buf[i + 2]))
    return linear ? (dec(r), dec(g), dec(b)) : (r, g, b)
}
let n0 = a.filter { !$0.hasPrefix("--") }
let y0 = Int(n0[2])!, y1 = Int(n0[3])!
let x0 = n0.count > 4 ? Int(n0[4])! : 0
let x1 = n0.count > 5 ? Int(n0[5])! : w - 1
var prof = [Double]()
for x in x0...x1 {
    var s = 0.0
    for y in y0...y1 { let p = px(x, y); s += (p.0 + p.1 + p.2) / 3 }
    prof.append(s / Double(y1 - y0 + 1))
}
// 两端各取 8% 宽度当平台值（避开玻璃自己的描边/发光）
let n = prof.count, m = max(3, n * 8 / 100)
let lo = prof[0..<m].reduce(0, +) / Double(m)
let hi = prof[(n - m)...].reduce(0, +) / Double(m)
print(String(format: "平台: 左 %.1f  右 %.1f  跨度 %.1f  (列 %d…%d, 行 %d…%d)",
             lo, hi, hi - lo, x0, x1, y0, y1))
for (i, v) in prof.enumerated() where i % 4 == 0 {
    let t = (v - lo) / (hi - lo)
    print(String(format: "  x=%4d  %6.1f  %+.3f", x0 + i, v, t))
}
// 找归一化 0.1 / 0.5 / 0.9 的亚像素穿越点
func cross(_ t: Double) -> Double? {
    for i in 1..<n {
        let a0 = (prof[i - 1] - lo) / (hi - lo), a1 = (prof[i] - lo) / (hi - lo)
        if (a0 - t) * (a1 - t) <= 0 && a0 != a1 {
            return Double(x0 + i - 1) + (t - a0) / (a1 - a0)
        }
    }
    return nil
}
if let c10 = cross(0.1), let c50 = cross(0.5), let c90 = cross(0.9) {
    let width = c90 - c10
    print(String(format: "10%%=%.2f  50%%=%.2f  90%%=%.2f  →  W=%.2f px  σ=%.2f px",
                 c10, c50, c90, width, width / 2.5631))
}
