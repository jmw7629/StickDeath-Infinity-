import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum TestError: Error { case failure(String), cancelled }
func expect(_ condition: @autoclosure () -> Bool, _ text: String) throws { if !condition() { throw TestError.failure(text) } }
func fixture(_ body: (Int,Int)->[UInt8]) throws -> StudioSharpen.Pixels {
 var bytes:[UInt8]=[]; for y in 0..<48 { for x in 0..<64 { bytes += body(x,y) } }
 return try .init(width:64,height:48,rgba:bytes)
}
func pixel(_ image:StudioSharpen.Pixels,_ x:Int,_ y:Int,_ c:Int=0)->Int { Int(image.rgba[(y*64+x)*4+c]) }
func reject(_ failure:StudioBlur.Failure,_ body:()throws->Void)throws {
 do { try body(); throw TestError.failure("Expected rejection") } catch let e as StudioBlur.Failure { try expect(e==failure,"Wrong rejection") }
}
let source=try fixture { x,_ in let v:UInt8=x<32 ? 100:156; return [v,v,v,255] }
let tap=[StudioSharpen.Point(x:32,y:24)]
let full=StudioSharpen.Settings(diameter:32,hardness:1,radius:3,amount:1,threshold:0,opacity:1)
let original=source.rgba
var groups=0
func check(_ name:String,_ body:()throws->Void)throws { try body();groups+=1;print("PASS \(name)") }
try check("Real contrast enhancement, exact outside pixels and immutable original") {
 let result=try StudioSharpen.apply(to:source,path:tap,settings:full)
 try expect(pixel(result,31,24)<95 && pixel(result,32,24)>161,"No sharpened edge")
 for y in 0..<48 { for x in 0..<64 where hypot(Double(x)+0.5-32,Double(y)+0.5-24)>=16 {
  for c in 0..<4 { try expect(pixel(result,x,y,c)==pixel(source,x,y,c),"Outside brush changed") }
 } }
 try expect(source.rgba==original,"Input mutated")
}
try check("Amount, radius, threshold, hardness, diameter and opacity are distinct") {
 let baseline=try StudioSharpen.apply(to:source,path:tap,settings:full)
 var variants:[StudioSharpen.Settings]=[]
 var s=full;s.amount=0.5;variants.append(s);s=full;s.radius=1;variants.append(s)
 s=full;s.threshold=0.09;variants.append(s);s=full;s.hardness=0;variants.append(s)
 s=full;s.diameter=12;variants.append(s);s=full;s.opacity=0.5;variants.append(s)
 for s in variants { let out=try StudioSharpen.apply(to:source,path:tap,settings:s);try expect(out != baseline && out != source,"Inert setting \(s)") }
 s=full;s.opacity=0.5;let half=try StudioSharpen.apply(to:source,path:tap,settings:s)
 for i in original.indices { try expect(abs(Int(half.rgba[i])*2-Int(original[i])-Int(baseline.rgba[i]))<=1,"Opacity applied repeatedly") }
 for key in 0..<3 { s=full;if key==0{s.amount=0};if key==1{s.opacity=0};if key==2{s.threshold=1}
  let out=try StudioSharpen.apply(to:source,path:tap,settings:s);try expect(out==source,"Zero or full threshold not identity") }
}
try check("Alpha remains exact; constant translucent color has no dark halos") {
 let input=try fixture { x,_ in x<32 ? [128,0,0,128]:[0,0,0,0] }
 let output=try StudioSharpen.apply(to:input,path:tap,settings:full)
 try expect(output==input,"Color or alpha halo at transparency")
 let varied=try fixture { x,y in let a:UInt8=y<24 ? 128:255;let v=UInt8((x<32 ? 0.3:0.7)*Double(a));return [v,v,0,a] }
 let out=try StudioSharpen.apply(to:varied,path:tap,settings:full)
 for i in stride(from:0,to:out.rgba.count,by:4) { try expect(out.rgba[i+3]==varied.rgba[i+3],"Alpha changed");for c in 0..<3{try expect(out.rgba[i+c]<=out.rgba[i+3],"Invalid premultiplication")} }
 let constant=try fixture { _,_ in [50,75,100,128] }
 let flat=try StudioSharpen.apply(to:constant,path:[.init(x:0,y:0),.init(x:64,y:48)],settings:full)
 for i in flat.rgba.indices {try expect(abs(Int(flat.rgba[i])-Int(constant.rgba[i]))<=1,"Constant plane changed")}
}
try check("Selection masks have exact protection and proportional coverage") {
 let baseline=try StudioSharpen.apply(to:source,path:tap,settings:full)
 var mask=[UInt8](repeating:0,count:64*48);for y in 0..<48{for x in 0..<32{mask[y*64+x]=128}}
 let out=try StudioSharpen.apply(to:source,path:tap,settings:full,selection:mask)
 for y in 0..<48 {for x in 32..<64 {for c in 0..<4 {try expect(pixel(out,x,y,c)==pixel(source,x,y,c),"Selection leak")}}}
 let expected=100+(Double(pixel(baseline,31,24))-100)*128/255
 try expect(abs(Double(pixel(out,31,24))-expected)<=1,"Coverage wrong")
 let empty=try StudioSharpen.apply(to:source,path:tap,settings:full,selection:Array(repeating:0,count:64*48));try expect(empty==source,"Empty selection changed pixels")
 try reject(.invalidSelection){_=try StudioSharpen.apply(to:source,path:tap,settings:full,selection:[1])}
}
try check("Sampling density and repeated events do not accumulate strength") {
 let sparse=[StudioSharpen.Point(x:32,y:8),.init(x:32,y:40)];let dense=(8...40).map{StudioSharpen.Point(x:32,y:Double($0))}
 let a=try StudioSharpen.apply(to:source,path:sparse,settings:full);let b=try StudioSharpen.apply(to:source,path:dense,settings:full)
 let c=try StudioSharpen.apply(to:source,path:tap+tap+tap,settings:full);let d=try StudioSharpen.apply(to:source,path:tap,settings:full)
 try expect(a==b && c==d,"Event density changes sharpening")
}
try check("Top-left coordinates and real PNG round trip") {
 let input=try fixture{x,y in let v:UInt8=y<12 && x<32 ? 100:156;return [v,v,v,255]}
 let out=try StudioSharpen.apply(to:input,path:[.init(x:32,y:6)],settings:full)
 try expect(pixel(out,31,6)<100 && pixel(out,31,42)==156,"Wrong coordinate region")
 let space=CGColorSpace(name:CGColorSpace.sRGB)!;let provider=CGDataProvider(data:Data(out.rgba) as CFData)!
 let image=CGImage(width:64,height:48,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:256,space:space,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
 let url=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("sharpen-roundtrip.png")
 let dest=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!;CGImageDestinationAddImage(dest,image,nil);try expect(CGImageDestinationFinalize(dest),"No real PNG")
 let decoded=CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL,nil)!,0,nil)!;var bytes=[UInt8](repeating:0,count:64*48*4)
 bytes.withUnsafeMutableBytes {d in let ctx=CGContext(data:d.baseAddress,width:64,height:48,bitsPerComponent:8,bytesPerRow:256,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!;ctx.draw(decoded,in:CGRect(x:0,y:0,width:64,height:48))}
 try expect(bytes==out.rgba,"PNG pixels or orientation changed")
}
try check("Invalid settings, malformed input and bounded work") {
 for value in [Double.nan,Double.infinity,-1,3] {var s=full;s.amount=value;try reject(.invalidSettings){_=try StudioSharpen.apply(to:source,path:tap,settings:s)}}
 for value in [Double.nan,Double.infinity,-1,1.1] {var s=full;s.threshold=value;try reject(.invalidSettings){_=try StudioSharpen.apply(to:source,path:tap,settings:s)}}
 for path in [[],[StudioSharpen.Point(x:Double.nan,y:2)],[.init(x:65,y:24)],Array(repeating:tap[0],count:4097)] {try reject(.invalidPath){_=try StudioSharpen.apply(to:source,path:path,settings:full)}}
 try reject(.invalidImage){_=try StudioSharpen.Pixels(width:Int.max,height:2,rgba:[])}
 let zigzag=(0..<100).map{StudioSharpen.Point(x:$0%2==0 ? 0:2048,y:1024)}
 try reject(.workLimit){_=try StudioSharpen.validateWork(width:2048,height:2048,path:zigzag,settings:.init(diameter:256))}
}
try check("Cancellation never returns partial output or mutates source") {
 var count=0;_=try StudioSharpen.apply(to:source,path:tap,settings:full,checkCancellation:{count+=1})
 for stop in [1,10,count-2,count-1,count] {var calls=0;var returned=false
  do{_=try StudioSharpen.apply(to:source,path:tap,settings:full,checkCancellation:{calls+=1;if calls==stop{throw TestError.cancelled}});returned=true}catch TestError.cancelled{}
  try expect(!returned && calls==stop && source.rgba==original,"Cancelled output escaped")
 }
}
print("SHARPEN_CORE=PASS groups=\(groups)")
