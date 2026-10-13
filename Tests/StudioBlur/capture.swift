import Foundation
import SwiftUI
import AppKit
import AVFoundation
import ImageIO

typealias UIImage = NSImage
extension Image { init(uiImage: NSImage) { self.init(nsImage: uiImage) } }
enum CaptureTestError: Error { case failed(String) }

@main @MainActor struct BlurCaptureTests {
    static func require(_ value: @autoclosure () throws -> Bool, _ text: String) throws {
        if try !value() { throw CaptureTestError.failed(text) }
    }
    static func rejects(_ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw CaptureTestError.failed("Unsupported capture succeeded")
    }
    static func pixel(_ image: StudioBlur.Pixels, _ x: Int, _ y: Int) -> [UInt8] {
        Array(image.rgba[(y*image.width+x)*4..<(y*image.width+x)*4+4])
    }
    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil) else {
            throw CaptureTestError.failed("PNG destination failed")
        }
        CGImageDestinationAddImage(destination,image,nil)
        try require(CGImageDestinationFinalize(destination),"PNG encoding failed")
        return data as Data
    }
    static func main() async throws {
        setbuf(stdout,nil)
        var document = try StudioDocument.new(name:"Blur capture",width:64,height:32,fps:12)
        document.schemaVersion = 5
        let active = document.activeLayerID
        document.layers[0].opacity = 0.25
        document.layers[0].blendMode = "multiply"
        document.layers[0].glowEnabled = true
        document.layers.append(.init(id:"blue",name:"Untouched layer"))
        document.frames[0].elements = [
            .init(id:"red",tool:.rectangle,points:[.init(x:4,y:4),.init(x:24,y:28)],
                color:"#FF0000",width:1,opacity:1,layerID:active,shape:.init(fillColor:"#FF0000")),
            .init(id:"background",tool:.rectangle,points:[.init(x:0,y:0),.init(x:64,y:32)],
                color:"#0000FF",width:1,opacity:1,layerID:"blue",shape:.init(fillColor:"#0000FF"))]
        let original = document
        let capture = try StudioBlurCapture.capture(document:document,selection:[],raster:nil)
        try require(pixel(capture.pixels,10,16) == [255,0,0,255],"Layer appearance baked twice")
        try require(pixel(capture.pixels,40,16) == [0,0,0,0],"Other layer/background entered capture")
        try require(pixel(capture.pixels,27,16)[3] == 0,"Glow baked into source")
        try require(document == original,"Read-only capture mutated editable document")
        print("PASS canonical compositor isolates active layer without double opacity blend or glow")

        let softened = try StudioBlur.apply(to:capture.pixels,path:[.init(x:24,y:16)],
            settings:.init(diameter:16,hardness:1,radius:3,strength:1))
        try require(pixel(softened,26,16)[0] > 0 && pixel(softened,26,16)[2] == 0,
                    "Real artwork edge failed to soften independently of other layer")
        try require(pixel(softened,40,16) == [0,0,0,0],"Blur changed unrelated footprint")
        try require(document == original && capture.isCurrent(document,selection:[]),"Blur changed source context")
        print("PASS real captured artwork blurs without document mutation or unrelated layer pixels")

        for mode in ["full","position","alpha"] {
            var copy = document;copy.layers[0].lockMode = mode
            try rejects { _ = try StudioBlurCapture.capture(document:copy,selection:[],raster:nil) }
            try require(!capture.isCurrent(copy,selection:[]),"Lock did not invalidate capture")
        }
        for mode in 0..<5 {
            var copy = document
            switch mode {
            case 0:copy.layers[0].visible = false
            case 1:copy.layers[0].opacity = 0
            case 2:copy.frames[0].rasterAssetID = "missing";copy.frames[0].rasterLayerID = active
            case 3:copy.width = 4096;copy.height = 4096
            default:copy.activeFrameID = "missing"
            }
            try rejects { _ = try StudioBlurCapture.capture(document:copy,selection:[],raster:nil) }
        }
        try rejects { _ = try StudioBlurCapture.capture(document:document,selection:["red"],raster:nil) }
        print("PASS locks visibility opacity selection missing assets and oversized documents fail closed")

        for mode in 0..<4 {
            var copy = document
            switch mode {
            case 0:copy.revision += 1
            case 1:copy.activeLayerID = "blue"
            case 2:copy.frames.append(.init(id:"next",elements:[]));copy.activeFrameID = "next"
            default:copy.width = 128
            }
            try require(!capture.isCurrent(copy,selection:[]),"Stale scope accepted")
        }
        let other = try StudioDocument.new(name:"Other project",width:64,height:32,fps:12)
        try require(!capture.isCurrent(other,selection:[]),"Other project accepted")
        try require(!capture.isCurrent(document,selection:["red"]),"Changed selection accepted")
        print("PASS project revision frame layer dimensions and selection changes invalidate capture")

        var asymmetric = document
        asymmetric.frames[0].elements.append(.init(id:"green-top",tool:.rectangle,
            points:[.init(x:4,y:2),.init(x:16,y:9)],color:"#00FF00",width:1,opacity:1,
            layerID:active,shape:.init(fillColor:"#00FF00")))
        let top = try StudioBlurCapture.capture(document:asymmetric,selection:[],raster:nil)
        try require(pixel(top.pixels,10,5) == [0,255,0,255] && pixel(top.pixels,10,25) == [255,0,0,255],
                    "Capture inverted top-left coordinates")
        let topBlur = try StudioBlur.apply(to:top.pixels,path:[.init(x:10,y:9)],
            settings:.init(diameter:12,hardness:1,radius:2,strength:1))
        try require(pixel(topBlur,10,11)[1] > 0 && pixel(topBlur,10,25) == pixel(top.pixels,10,25),
                    "Blur processed wrong vertical region")
        print("PASS asymmetric actual artwork and blur preserve top-left canvas coordinates")

        var prior = document
        prior.layers.removeLast();prior.layers[0].opacity = 1;prior.layers[0].blendMode = "normal";prior.layers[0].glowEnabled = false
        prior.frames[0].elements.removeLast()
        var editor = try StudioDocumentEditor(document:prior)
        let effect = DrawnElement(id:"existing-smudge",tool:.smudge,
            points:[.init(x:20.5,y:16.5),.init(x:42.5,y:16.5)],color:"#0000FF",width:16,
            opacity:1,layerID:active,smudge:.init(strength:1))
        try editor.commit(effect,frameID:prior.activeFrameID)
        let afterSmudge = try StudioBlurCapture.capture(document:editor.document,selection:[],raster:nil)
        let rendered = try StudioSmudgeReplay.pixels(StudioExportService().render(editor.document.frames[0],
            document:editor.document,background:.transparent,raster:nil))
        try require(afterSmudge.pixels.rgba == rendered.rgba && pixel(afterSmudge.pixels,30,16)[0] > 0,
                    "Capture skipped prior editable effect")
        let afterBlur = try StudioBlur.apply(to:afterSmudge.pixels,path:[.init(x:30,y:16)],
            settings:.init(diameter:20,hardness:1,radius:4,strength:1))
        try require(afterBlur != afterSmudge.pixels && editor.document.frames[0].elements[0] == prior.frames[0].elements[0],
                    "Blur skipped pixels or replaced original vectors")
        print("PASS common compositor includes preceding editable Smudge without losing original vectors")

        let image = try StudioExportService().render(prior.frames[0],document:prior,background:.transparent,raster:nil)
        let data = try png(image), preservedData = data
        var rasterDocument = prior;rasterDocument.frames[0].elements = []
        rasterDocument.frames[0].rasterAssetID = "original-png";rasterDocument.frames[0].rasterLayerID = active
        let rasterCapture = try StudioBlurCapture.capture(document:rasterDocument,selection:[],raster:data)
        try require(pixel(rasterCapture.pixels,10,16) == [255,0,0,255] && pixel(rasterCapture.pixels,40,16) == [0,0,0,0],
                    "Managed raster capture lost original pixels")
        _ = try StudioBlur.apply(to:rasterCapture.pixels,path:[.init(x:24,y:16)],settings:.init())
        try require(data == preservedData,"Blur rewrote original PNG bytes")
        try rejects { _ = try StudioBlurCapture.capture(document:rasterDocument,selection:[],raster:Data([1,2,3])) }
        print("PASS real project PNG capture preserves originals and rejects corrupt bytes")

        let task = Task { @MainActor in
            try StudioBlurCapture.capture(document:document,selection:[],raster:nil)
        }
        task.cancel()
        do { _ = try await task.value;throw CaptureTestError.failed("Cancelled capture returned pixels") }
        catch is CancellationError { }
        try require(document == original,"Cancelled capture changed source")
        print("PASS cancelled main-actor capture returns no result or document mutation")
        print("BLUR_CAPTURE=PASS groups=8; no UI or editable Blur integration claimed")
    }
}
