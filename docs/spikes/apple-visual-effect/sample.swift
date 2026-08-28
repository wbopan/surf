// 从截图里量各个胶囊的平均色。回答问题 ③ 要的是"失活前后材质自己变没变"，
// 而肉眼比两张图很容易被窗口阴影/取景差异骗（peekaboo 激活态截的是窗口框、
// 失活态多带一圈阴影，两张图尺寸就不一样）。
//
// 做法：靠页面画的两枚纯品红基准方块（.fid）定位视口原点，再按视口内坐标取样，
// 这样两张尺寸不同的图也能对齐。同一张图里另取两个**不受焦点影响**的参照
// （纯 CSS 手绘胶囊 / 纯色胶囊）——材质若变了而参照没变，那就是材质自己变的。
//
// 取样区一律写成**视口内的归一化比例**而不是像素：committed 的截图为了控制体积
// 缩过，写死像素的话工具对自己的产物就失效了。
//
//   swiftc -O sample.swift -o build/sample && build/sample shot-active.png

import AppKit

let args = CommandLine.arguments
guard args.count > 1,
      let img = NSImage(contentsOfFile: args[1]),
      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("用法: sample <png>\n".data(using: .utf8)!)
    exit(1)
}
let w = cg.width, h = cg.height
var buf = [UInt8](repeating: 0, count: w * h * 4)
CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    .draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

// 基准方块：纯品红，页面里唯一的这个色。
func isFiducial(_ x: Int, _ y: Int) -> Bool {
    let i = (y * w + x) * 4
    return buf[i] > 235 && buf[i + 1] < 45 && buf[i + 2] > 235
}
var x0 = w, y0 = h, x1 = -1, y1 = -1
for y in 0..<h {
    for x in 0..<w where isFiducial(x, y) {
        x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
    }
}
guard x1 > x0 else { print("找不到基准方块（页面上那两枚品红点）"); exit(1) }
let vw = Double(x1 - x0 + 1), vh = Double(y1 - y0 + 1)
print("视口 \(Int(vw))×\(Int(vh)) @ (\(x0),\(y0))   图 \(w)×\(h)")

/// 取样区：视口内的归一化比例（左、上、右、下）。
let regions: [(String, Double, Double, Double, Double)] = [
    ("材质 media-controls", 0.061, 0.167, 0.142, 0.205),
    ("材质 subdued",        0.204, 0.167, 0.264, 0.205),
    ("材质 glass-material", 0.321, 0.167, 0.406, 0.205),
    ("材质 clear",          0.456, 0.167, 0.503, 0.205),
    ("材质 blur-material",  0.056, 0.265, 0.142, 0.299),
    ("参照 纯 CSS 手绘",     0.194, 0.265, 0.335, 0.299),
    ("参照 纯色 28% 黑",     0.387, 0.265, 0.467, 0.299),
    ("参照 裸背景（右侧）",   0.763, 0.167, 0.864, 0.205),
]
for (name, fx0, fy0, fx1, fy1) in regions {
    var r = 0, g = 0, b = 0, n = 0
    for y in (y0 + Int(fy0 * vh))...(y0 + Int(fy1 * vh)) {
        for x in (x0 + Int(fx0 * vw))...(x0 + Int(fx1 * vw)) {
            let i = (y * w + x) * 4
            r += Int(buf[i]); g += Int(buf[i + 1]); b += Int(buf[i + 2]); n += 1
        }
    }
    print(String(format: "%-22@  R %6.2f  G %6.2f  B %6.2f",
                 name as NSString, Double(r) / Double(n), Double(g) / Double(n), Double(b) / Double(n)))
}
