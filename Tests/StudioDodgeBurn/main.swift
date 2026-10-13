import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum CheckError: Error { case failed(String), cancelled }
func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw CheckError.failed(message) } }
var groups = 0
func test(_ name: String, _ body: () throws -> Void) throws { try body();groups += 1;print("PASS " + name) }
func image(_ width: Int = 32, _ height: Int = 24, _ body: (Int,Int)->[UInt8]) throws -> StudioDodgeBurn.Pixels {
 var bytes: [UInt8] = [];for y in 0..<height {for x in 0..<width {bytes += body(x,y)}}
 return try .init(width:width,height:height,rgba:bytes)
}
func reject(_ expected: StudioBlur.Failure, _ body: () throws -> Void) throws {
 do {try body();throw CheckError.failed("Missing rejection")} catch let e as StudioBlur.Failure {try require(e == expected,"Wrong rejection")}
}
let tap = [StudioDodgeBurn.Point(x:16,y:12)]
let base = StudioDodgeBurn.Settings(diameter:64,hardness:1,exposure:0.5,range:.all,protectTones:false)
let gray = try image { _,_ in [128,128,128,255] }
func apply(_ input: StudioDodgeBurn.Pixels = gray, _ settings: StudioDodgeBurn.Settings = base) throws -> StudioDodgeBurn.Pixels {
 try StudioDodgeBurn.apply(to:input,path:tap,settings:settings)
}
try test("One stop changes existing gray by linear-light exposure, not foreground paint") {
 let brighter=try apply();var burn=base;burn.mode = .burn;let darker=try apply(gray,burn)
 try require(brighter.rgba[0] == 176 && darker.rgba[0] == 92,"Independent one-stop sRGB expectations")
 try require(gray.rgba[0] == 128,"Input mutated")
 let patch=try image { x,_ in let v:UInt8 = x<16 ? 64:192;return [v,v,v,255] }
 let a=try apply(patch),b=try apply(patch,burn)
 try require(a.rgba[0] == 90 && a.rgba[20*4] == 255 && b.rgba[0] == 44 && b.rgba[20*4] == 140,"Shadow/highlight exposure values")
}
try test("Black stays black, transparent pixels and every original alpha stay intact") {
 let source=try image {x,_ in x<8 ? [0,0,0,0] : x<16 ? [0,0,0,255] : [64,32,16,128]}
 let result=try apply(source)
 for i in stride(from:0,to:result.rgba.count,by:4) {try require(result.rgba[i+3] == source.rgba[i+3],"Alpha changed")}
 try require(result.rgba[0] == 0 && result.rgba[10*4] == 0,"Invented paint")
 try require(result.rgba[20*4] == 88 && result.rgba[20*4+1] > 32,"Premultiplied color incorrect")
}
try test("Zero exposure opacity or selection coverage is an exact no-op") {
 var zero=base;zero.exposure=0;try require(try apply(gray,zero) == gray,"Zero exposure")
 zero=base;zero.opacity=0;try require(try apply(gray,zero) == gray,"Zero opacity")
 let none=try StudioDodgeBurn.apply(to:gray,path:tap,settings:base,selection:Array(repeating:0,count:32*24))
 try require(none == gray,"Zero selection")
}
try test("Selection gates pixels and partial coverage blends once in linear light") {
 var selection=[UInt8](repeating:0,count:32*24);selection[0]=255;selection[1]=128
 let output=try StudioDodgeBurn.apply(to:gray,path:tap,settings:base,selection:selection)
 try require(output.rgba[0] == 176 && output.rgba[4] > 128 && output.rgba[4] < 176 && output.rgba[8] == 128,"Selection leaked or became paint")
 var half=base;half.opacity=0.5;try require(try apply(gray,half).rgba[0] == 154,"Half opacity applied more than once")
}
try test("Shadows and highlights ranges target different existing tones") {
 let source=try image{x,_ in let v:UInt8=x<16 ? 32:224;return [v,v,v,255]}
 var shadows=base;shadows.range = .shadows;var highlights=base;highlights.range = .highlights
 let a=try apply(source,shadows),b=try apply(source,highlights)
 try require(a.rgba[0]>32 && a.rgba[20*4]==224 && b.rgba[0]==32 && b.rgba[20*4]>224,"Ranges indistinguishable")
 var mids=base;mids.range = .midtones
 try require(try apply(gray,mids).rgba[0]>=175,"Midtone range should affect middle gray")
}
try test("Protect Tones reduces clipping and softens dark-tone loss") {
 let source=try image {_,_ in [192,128,64,255]};var protected=base;protected.protectTones=true
 let a=try apply(source),b=try apply(source,protected)
 try require(a.rgba[0]==255 && b.rgba[0]>192 && b.rgba[0]<255,"Highlights not protected")
 var burn=base;burn.mode = .burn;protected=burn;protected.protectTones=true
 let c=try apply(gray,burn),e=try apply(gray,protected)
 try require(e.rgba[0]>c.rgba[0] && e.rgba[0]<128,"Protected burn no longer darkens or protects")
}
try test("Size softness and top-left coordinates change actual brush coverage") {
 var small=base;small.diameter=8;small.hardness=1
 let a=try StudioDodgeBurn.apply(to:gray,path:[.init(x:4,y:4)],settings:small)
 try require(a.rgba[(4*32+4)*4]>128 && a.rgba[(20*32+4)*4]==128,"Wrong axis or footprint")
 var soft=small;soft.hardness=0
 let b=try StudioDodgeBurn.apply(to:gray,path:[.init(x:4,y:4)],settings:soft)
 try require(b.rgba[(4*32+6)*4]<a.rgba[(4*32+6)*4] && b.rgba[(4*32+6)*4]>128,"Softness inert")
}
try test("Event density does not compound exposure inside one gesture") {
 let sparse=[StudioDodgeBurn.Point(x:4,y:12),.init(x:28,y:12)]
 let dense=(4...28).map{StudioDodgeBurn.Point(x:Double($0),y:12)}
 var brush=base;brush.diameter=8
 try require(try StudioDodgeBurn.apply(to:gray,path:sparse,settings:brush) == StudioDodgeBurn.apply(to:gray,path:dense,settings:brush),"Density changed exposure")
 try require(try StudioDodgeBurn.apply(to:gray,path:tap+tap+tap,settings:brush) == StudioDodgeBurn.apply(to:gray,path:tap,settings:brush),"Repeated events compounded gain")
}
try test("Invalid settings paths selections and workloads reject before editing") {
 for invalid in [Double.nan,Double.infinity,-0.1,1.1] {var s=base;s.exposure=invalid;try reject(.invalidSettings){_=try apply(gray,s)}}
 for path in [[],[StudioDodgeBurn.Point(x:Double.nan,y:0)],[.init(x:33,y:0)],Array(repeating:tap[0],count:4097)] {try reject(.invalidPath){_=try StudioDodgeBurn.apply(to:gray,path:path,settings:base)}}
 try reject(.invalidSelection){_=try StudioDodgeBurn.apply(to:gray,path:tap,settings:base,selection:[0])}
 let zigzag=(0..<100).map{StudioDodgeBurn.Point(x:$0%2==0 ? 0:2048,y:1024)}
 try reject(.workLimit){_=try StudioDodgeBurn.validateWork(width:2048,height:2048,path:zigzag,settings:.init(diameter:256))}
}
try test("Cancellation at planning processing and output boundaries returns no partial image") {
 var total=0;_=try StudioDodgeBurn.apply(to:gray,path:tap,settings:base,checkCancellation:{total+=1})
 for stop in [1,10,total-2,total-1,total] {
  var count=0,returned=false
  do {_=try StudioDodgeBurn.apply(to:gray,path:tap,settings:base,checkCancellation:{count+=1;if count==stop {throw CheckError.cancelled}});returned=true} catch CheckError.cancelled {}
  try require(!returned && count==stop && gray.rgba[0]==128,"Cancelled output escaped")
 }
}
try test("Every gray level changes monotonically and chromatic channels retain their ordering") {
 let source=try image(256,1) { x,_ in [UInt8(x),UInt8(x),UInt8(x),255] }
 var s=base;s.diameter=256;var burn=s;burn.mode = .burn
 let line=[StudioDodgeBurn.Point(x:0,y:0.5),.init(x:256,y:0.5)]
 let a=try StudioDodgeBurn.apply(to:source,path:line,settings:s)
 let b=try StudioDodgeBurn.apply(to:source,path:line,settings:burn)
 for i in 1..<256 {
  try require(a.rgba[i*4] >= a.rgba[(i-1)*4] && b.rgba[i*4] >= b.rgba[(i-1)*4],"Tone curve reversed")
  try require(a.rgba[i*4] >= source.rgba[i*4] && b.rgba[i*4] <= source.rgba[i*4],"Wrong exposure direction")
 }
 s.protectTones=true
 let color=try image { _,_ in [96,48,24,128] }
 let out=try apply(color,s)
 try require(out.rgba[0]>out.rgba[1] && out.rgba[1]>out.rgba[2] && out.rgba[0]<=128 && out.rgba[3]==128,"Chromatic premultiplication changed")
 let encoded=try JSONEncoder().encode(s)
 try require(try JSONDecoder().decode(StudioDodgeBurn.Settings.self,from:encoded)==s,"Settings round trip differs")
}
try test("Actual PNG reopens with identical exposure pixels and orientation") {
 let source=try image { x,y in
  let a: UInt8 = x<8 ? 128 : 255
  return [UInt8(x*3),UInt8(y*4),UInt8((x+y)*2),a]
 }
 var local=base;local.diameter=12
 let result=try StudioDodgeBurn.apply(to:source,path:[.init(x:7,y:5)],settings:local)
 try require(result.rgba != source.rgba && result.rgba[0] != result.rgba[(23*32+31)*4],"PNG fixture needs nonuniform changed pixels")
 let space=CGColorSpace(name:CGColorSpace.sRGB)!,provider=CGDataProvider(data:Data(result.rgba) as CFData)!
 let cg=CGImage(width:32,height:24,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:128,space:space,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
 let url=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("dodge-roundtrip.png")
 let destination=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!;CGImageDestinationAddImage(destination,cg,nil);try require(CGImageDestinationFinalize(destination),"PNG write failed")
 let decoded=CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL,nil)!,0,nil)!
 var bytes=[UInt8](repeating:0,count:32*24*4);bytes.withUnsafeMutableBytes{p in let ctx=CGContext(data:p.baseAddress,width:32,height:24,bitsPerComponent:8,bytesPerRow:128,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!;ctx.draw(decoded,in:CGRect(x:0,y:0,width:32,height:24))}
 try require(bytes==result.rgba,"PNG decoded pixels differ")
}
print("DODGE_BURN_CORE=PASS groups=\(groups)")
