import AppKit
let a=CommandLine.arguments
let cg=NSImage(contentsOfFile:a[1])!.cgImage(forProposedRect:nil,context:nil,hints:nil)!
let w=cg.width,h=cg.height
var buf=[UInt8](repeating:0,count:w*h*4)
CGContext(data:&buf,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,
 space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
 .draw(cg,in:CGRect(x:0,y:0,width:w,height:h))
func px(_ x:Int,_ y:Int)->(Int,Int,Int){let i=(y*w+x)*4;return (Int(buf[i]),Int(buf[i+1]),Int(buf[i+2]))}
// 找「蓝」「红」连通块的行区间：蓝 = B 高且 R 低；红 = R 高且 G 低
func kind(_ p:(Int,Int,Int))->String?{
 if p.2>200 && p.0<60 && p.1>80 && p.1<230 {return "blue"}
 if p.0>200 && p.1<130 && p.2<160 && p.1>10 {return "red"}
 return nil}
var runs:[(String,Int,Int,Int,Int)]=[]   // kind,y0,y1,x0,x1
var cur:(String,Int,Int,Int)? = nil      // kind,y0,x0,x1
for y in 0..<h {
 var k:String?=nil; var x0=w; var x1 = -1
 for x in 0..<w { if let kk=kind(px(x,y)) { k=kk; x0=min(x0,x); x1=max(x1,x) } }
 if let k=k {
   if var c=cur, c.0==k { c.2=min(c.2,x0); c.3=max(c.3,x1); cur=c }
   else { if let c=cur { runs.append((c.0,c.1,y-1,c.2,c.3)) }; cur=(k,y,x0,x1) }
 } else if let c=cur { runs.append((c.0,c.1,y-1,c.2,c.3)); cur=nil }
}
if let c=cur { runs.append((c.0,c.1,h-1,c.2,c.3)) }
for r in runs where r.2-r.1 > 20 { print("\(r.0)  y \(r.1)..\(r.2)  x \(r.3)..\(r.4)") }
