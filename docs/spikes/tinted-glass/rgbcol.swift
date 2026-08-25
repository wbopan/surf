import AppKit
let a=CommandLine.arguments
let cg=NSImage(contentsOfFile:a[1])!.cgImage(forProposedRect:nil,context:nil,hints:nil)!
let w=cg.width,h=cg.height
var buf=[UInt8](repeating:0,count:w*h*4)
CGContext(data:&buf,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,
 space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
 .draw(cg,in:CGRect(x:0,y:0,width:w,height:h))
func px(_ x:Int,_ y:Int)->(Int,Int,Int){let i=(y*w+x)*4;return (Int(buf[i]),Int(buf[i+1]),Int(buf[i+2]))}
let x=Int(a[2])!, y0=Int(a[3])!, y1=Int(a[4])!
for y in y0...y1 { let p=px(x,y); print(String(format:"y=%3d  %3d %3d %3d",y,p.0,p.1,p.2)) }
