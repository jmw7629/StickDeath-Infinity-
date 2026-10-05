import Foundation
import SwiftUI
import AppKit
import AVFoundation
import ImageIO

typealias UIImage = NSImage
extension Image { init(uiImage: NSImage) { self.init(nsImage: uiImage) } }
enum CaptureError:Error{case failed(String)}
@main @MainActor struct DodgeBurnCaptureTests {
 static func expect(_ condition:@autoclosure ()throws->Bool,_ message:String)throws{if try !condition(){throw CaptureError.failed(message)}}
 static func reject(_ body:()throws->Void)throws{do{try body()}catch{return};throw CaptureError.failed("Rejected capture succeeded")}
 static func pixel(_ p:StudioDodgeBurn.Pixels,_ x:Int,_ y:Int)->[UInt8]{Array(p.rgba[(y*p.width+x)*4..<(y*p.width+x)*4+4])}
 static func main()async throws{
  setbuf(stdout,nil)
  var doc=try StudioDocument.new(name:"Dodge/Burn capture",width:64,height:32,fps:12);doc.schemaVersion=5
  let active=doc.activeLayerID
  doc.layers[0].opacity=0.25;doc.layers[0].blendMode="multiply";doc.layers[0].glowEnabled=true
  doc.layers.append(.init(id:"other",name:"Other layer"))
  doc.frames[0].elements=[
   .init(id:"left",tool:.rectangle,points:[.init(x:0,y:0),.init(x:32,y:32)],color:"#646464",width:1,opacity:1,layerID:active,shape:.init(fillColor:"#646464")),
   .init(id:"right",tool:.rectangle,points:[.init(x:32,y:0),.init(x:64,y:32)],color:"#9C9C9C",width:1,opacity:1,layerID:active,shape:.init(fillColor:"#9C9C9C")),
   .init(id:"other-shape",tool:.rectangle,points:[.init(x:0,y:0),.init(x:64,y:32)],color:"#0000FF",width:1,opacity:1,layerID:"other",shape:.init(fillColor:"#0000FF"))]
  let original=doc
  let capture=try StudioDodgeBurnCapture.capture(document:doc,selection:[],raster:nil)
  try expect(pixel(capture.pixels,10,16)==[100,100,100,255] && pixel(capture.pixels,50,16)==[156,156,156,255],"Appearance or other layer baked in")
  let brush=StudioDodgeBurn.Settings(diameter:64,hardness:1,exposure:0.5,range:.all,protectTones:false)
  let output=try StudioDodgeBurn.apply(to:capture.pixels,path:[.init(x:32,y:16)],settings:brush)
  var burn=brush;burn.mode = .burn
  let darkened=try StudioDodgeBurn.apply(to:capture.pixels,path:[.init(x:32,y:16)],settings:burn)
  try expect(pixel(output,10,16)[0]>100 && pixel(output,50,16)[0]>156,"Dodge did not lighten compositor artwork")
  try expect(pixel(darkened,10,16)[0]<100 && pixel(darkened,50,16)[0]<156,"Burn did not darken compositor artwork")
  try expect(pixel(output,10,16)[3]==255 && pixel(darkened,50,16)[3]==255,"Alpha changed")
  try expect(doc==original && capture.isCurrent(doc,selection:[]),"Capture changed document")
  print("PASS actual active-layer compositor and both exposure operations; no double opacity/blend/glow or other-layer leakage")
  for lock in ["full","position","alpha"]{var changed=doc;changed.layers[0].lockMode=lock;try reject{_=try StudioDodgeBurnCapture.capture(document:changed,selection:[],raster:nil)};try expect(!capture.isCurrent(changed,selection:[]),"Lock failed to invalidate capture")}
  for mode in 0..<3{var changed=doc;if mode==0{changed.layers[0].visible=false};if mode==1{changed.layers[0].opacity=0};if mode==2{changed.width=4096;changed.height=4096};try reject{_=try StudioDodgeBurnCapture.capture(document:changed,selection:[],raster:nil)}}
  try reject{_=try StudioDodgeBurnCapture.capture(document:doc,selection:["left"],raster:nil)}
  print("PASS locks, visibility, zero opacity, active selection and oversized capture fail closed")
  for mode in 0..<4{var changed=doc;switch mode{case 0:changed.revision+=1;case 1:changed.activeLayerID="other";case 2:changed.frames.append(.init(id:"next",elements:[]));changed.activeFrameID="next";default:changed.width=128};try expect(!capture.isCurrent(changed,selection:[]),"Stale context accepted")}
  try expect(!capture.isCurrent(StudioDocument.new(name:"Other",width:64,height:32,fps:12),selection:[]),"Other project accepted")
  try expect(!capture.isCurrent(doc,selection:["left"]),"Changed selection accepted")
  print("PASS project, revision, frame, layer, dimensions and selection invalidate captured work")
  var prior=doc;prior.layers.removeLast();prior.layers[0].opacity=1;prior.layers[0].blendMode="normal";prior.layers[0].glowEnabled=false;prior.frames[0].elements.removeLast()
  var editor=try StudioDocumentEditor(document:prior)
  let blur=DrawnElement(id:"preceding-blur",tool:.blur,points:[.init(x:32,y:16)],color:"#FF0000",width:24,opacity:1,layerID:active,blur:.init(hardness:1,radius:3))
  try editor.commit(blur,frameID:prior.activeFrameID)
  let after=try StudioDodgeBurnCapture.capture(document:editor.document,selection:[],raster:nil)
  let rendered=try StudioSmudgeReplay.pixels(StudioExportService().render(editor.document.frames[0],document:editor.document,background:.transparent,raster:nil))
  try expect(after.pixels.rgba==rendered.rgba && after.pixels != capture.pixels,"Preceding Blur skipped")
  let dodged=try StudioDodgeBurn.apply(to:after.pixels,path:[.init(x:32,y:16)],settings:.init(diameter:24,hardness:1,exposure:0.5,range:.all,protectTones:false))
  try expect(dodged != after.pixels && editor.document.frames[0].elements[0]==prior.frames[0].elements[0],"Effect did not change real pixels or replaced original")
  print("PASS ordered capture includes preceding editable Blur and retains original vectors")
  let image=try StudioExportService().render(prior.frames[0],document:prior,background:.transparent,raster:nil)
  let bytes=NSMutableData();let dest=CGImageDestinationCreateWithData(bytes,"public.png" as CFString,1,nil)!;CGImageDestinationAddImage(dest,image,nil);try expect(CGImageDestinationFinalize(dest),"PNG failed")
  let data=bytes as Data;var raster=prior;raster.frames[0].elements=[];raster.frames[0].rasterAssetID="managed-original";raster.frames[0].rasterLayerID=active
  let captured=try StudioDodgeBurnCapture.capture(document:raster,selection:[],raster:data);try expect(captured.pixels==capture.pixels,"Managed raster differs from original compositor")
  _=try StudioDodgeBurn.apply(to:captured.pixels,path:[.init(x:32,y:16)],settings:.init())
  try expect(data==bytes as Data,"Source bytes mutated")
  try reject{_=try StudioDodgeBurnCapture.capture(document:raster,selection:[],raster:nil)}
  try reject{_=try StudioDodgeBurnCapture.capture(document:raster,selection:[],raster:Data([1,2,3]))}
  print("PASS real managed PNG preserved; missing/corrupt source rejected")
  let task=Task{@MainActor in try StudioDodgeBurnCapture.capture(document:doc,selection:[],raster:nil)};task.cancel()
  do{_=try await task.value;throw CaptureError.failed("Cancelled capture returned output")}catch is CancellationError{}
  try expect(doc==original,"Cancelled capture mutated source")
  print("PASS cancelled capture produces no output or mutation")
  print("DODGE_BURN_CAPTURE=PASS groups=6; editable integration and native runtime pending")
 }
}
