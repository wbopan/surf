// crop <in.png> <out.png> <x> <y> <w> <h> [放大倍数]：裁一块出来放大看。
import AppKit
let a = CommandLine.arguments
let cg = NSImage(contentsOfFile: a[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let r = CGRect(x: Int(a[3])!, y: Int(a[4])!, width: Int(a[5])!, height: Int(a[6])!)
let z = a.count > 7 ? Int(a[7])! : 1
let sub = cg.cropping(to: r)!
let (w, h) = (sub.width * z, sub.height * z)
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .none
ctx.draw(sub, in: CGRect(x: 0, y: 0, width: w, height: h))
let out = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
