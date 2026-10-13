import Foundation
import SwiftUI
import AppKit
import AVFoundation

typealias UIImage = NSImage
extension Image { init(uiImage: NSImage) { self.init(nsImage: uiImage) } }
enum CaptureFailure: Error { case failed(String) }
@main @MainActor struct CaptureTests {
    static func require(_ value: @autoclosure () throws -> Bool, _ text: String) throws {
        if try !value() { throw CaptureFailure.failed(text) }
    }
    static func rejects(_ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw CaptureFailure.failed("Unavailable capture succeeded")
    }
    static func pixel(_ value: StudioSmudge.Pixels, _ x: Int, _ y: Int) -> [UInt8] {
        Array(value.rgba[((y*value.width+x)*4)..<((y*value.width+x)*4+4)])
    }
    static func main() throws {
        var document = try StudioDocument.new(name:"Smudge capture",width:64,height:32,fps:12)
        document.schemaVersion = 5
        let top = document.activeLayerID
        document.layers[0].opacity = 0.25
        document.layers[0].blendMode = "multiply"
        document.layers[0].glowEnabled = true
        document.layers.append(.init(id:"blue",name:"Other layer"))
        document.frames[0].elements = [
            .init(id:"red",tool:.rectangle,points:[.init(x:4,y:4),.init(x:24,y:28)],
                color:"#FF0000",width:1,opacity:1,layerID:top,shape:.init(fillColor:"#FF0000")),
            .init(id:"blue-element",tool:.rectangle,points:[.init(x:0,y:0),.init(x:64,y:32)],
                color:"#0000FF",width:1,opacity:1,layerID:"blue",shape:.init(fillColor:"#0000FF"))]
        let original = document
        let captured = try StudioSmudgeCapture.capture(document:document,selection:[],raster:nil)
        try require(pixel(captured.pixels,10,16) == [255,0,0,255],"Layer opacity/blend is baked twice")
        try require(pixel(captured.pixels,40,16) == [0,0,0,0],"Another layer or background entered capture")
        try require(pixel(captured.pixels,27,16)[3] == 0,"Layer glow was baked into source")
        try require(document == original,"Capture changed original document")
        print("PASS actual Studio compositor isolates raw active-layer color and alpha")
        let result = try StudioSmudge.apply(to:captured.pixels,path:[.init(x:20.5,y:16.5),.init(x:42.5,y:16.5)],
            settings:.init(diameter:16,strength:1,opacity:1))
        try require(pixel(result,26,16)[0] > 0 && pixel(result,26,16)[2] == 0,"Real rendered color did not move independently of the lower layer")
        try require(document == original && captured.isCurrent(document,selection:[]),"Read-only operation mutated or staled its own source")
        print("PASS real rendered Studio artwork passes through the color-drag operation without document mutation")
        for mode in ["full","position","alpha"] {
            var copy = document; copy.layers[0].lockMode = mode
            try rejects { _ = try StudioSmudgeCapture.capture(document:copy,selection:[],raster:nil) }
            try require(!captured.isCurrent(copy,selection:[]),"Lock change did not invalidate capture")
        }
        for mode in 0..<5 {
            var copy = document
            switch mode {
            case 0: copy.layers[0].visible = false
            case 1: copy.layers[0].opacity = 0
            case 2: copy.frames[0].rasterAssetID = "missing";copy.frames[0].rasterLayerID = top
            case 3: copy.width = 4096;copy.height = 4096
            default: copy.activeFrameID = "missing"
            }
            try rejects { _ = try StudioSmudgeCapture.capture(document:copy,selection:[],raster:nil) }
        }
        try rejects { _ = try StudioSmudgeCapture.capture(document:document,selection:["red"],raster:nil) }
        print("PASS locks visibility opacity selection missing assets and oversized canvases reject safely")
        var next = document; next.revision += 1
        try require(!captured.isCurrent(next,selection:[]),"Revision change accepted")
        next = document;next.activeLayerID = "blue"
        try require(!captured.isCurrent(next,selection:[]),"Layer change accepted")
        next = document;next.frames.append(.init(id:"next",elements:[]));next.activeFrameID="next"
        try require(!captured.isCurrent(next,selection:[]),"Frame change accepted")
        try require(!captured.isCurrent(document,selection:["red"]),"Selection change accepted")
        print("PASS captured scope rejects changed revision frame layer and selection")
        var asymmetric = document
        asymmetric.frames[0].elements.append(.init(id:"green-top",tool:.rectangle,
            points:[.init(x:4,y:2),.init(x:16,y:9)],color:"#00FF00",width:1,opacity:1,
            layerID:top,shape:.init(fillColor:"#00FF00")))
        let orientation = try StudioSmudgeCapture.capture(document:asymmetric,selection:[],raster:nil)
        try require(pixel(orientation.pixels,10,5) == [0,255,0,255] && pixel(orientation.pixels,10,25) == [255,0,0,255],
            "Capture inverted the document's top-left coordinates")
        let vertical = try StudioSmudge.apply(to:orientation.pixels,path:[.init(x:10.5,y:6.5),.init(x:10.5,y:24.5)],
            settings:.init(diameter:8,strength:1,opacity:1))
        try require(pixel(vertical,10,12)[1] > 0 && pixel(orientation.pixels,10,12)[1] == 0,
            "Downward document drag moved the wrong source colors")
        print("PASS asymmetric native drawing captures and vertical drags preserve top-left document coordinates")
        print("All 5 production smudge capture groups passed; editing/persistence/UI integration remain unrun")
    }
}
