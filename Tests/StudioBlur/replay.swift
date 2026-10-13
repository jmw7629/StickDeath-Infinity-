import Foundation
import SwiftUI
import AppKit
import AVFoundation
import ImageIO

typealias UIImage = NSImage
extension Image { init(uiImage: NSImage) { self.init(nsImage: uiImage) } }
enum ReplayTestError: Error { case failed(String) }
@main @MainActor struct BlurReplayTests {
    static func require(_ value: @autoclosure () throws -> Bool, _ text: String) throws {
        if try !value() { throw ReplayTestError.failed(text) }
    }
    static func rejects(_ body: () throws -> Void) throws {
        do { try body() } catch { return };throw ReplayTestError.failed("Invalid operation succeeded")
    }
    static func pixels(_ document: StudioDocument, raster: Data? = nil) throws -> StudioSmudge.Pixels {
        try StudioSmudgeReplay.pixels(StudioExportService().render(document.frames.first { $0.id == document.activeFrameID }!,
            document:document,background:.transparent,raster:raster))
    }
    static func close(_ a: StudioSmudge.Pixels, _ b: StudioSmudge.Pixels) -> Bool {
        a.width == b.width && a.height == b.height && zip(a.rgba,b.rgba).allSatisfy { abs(Int($0)-Int($1)) <= 1 }
    }
    static func effect(_ d: StudioDocument, id: String = "blur") -> DrawnElement {
        .init(id:id,tool:.blur,points:[.init(x:24,y:16)],color:"#0000FF",width:24,
            opacity:0.8,layerID:d.activeLayerID,blur:.init(hardness:1,radius:4))
    }
    static func expected(_ input: StudioSmudge.Pixels, _ e: DrawnElement) throws -> StudioSmudge.Pixels {
        let output = try StudioBlur.apply(to:.init(width:input.width,height:input.height,rgba:input.rgba),
            path:e.points.map { .init(x:$0.x,y:$0.y) },settings:e.blur!.settings(for:e))
        return try .init(width:output.width,height:output.height,rgba:output.rgba)
    }
    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil)!
        CGImageDestinationAddImage(dest,image,nil)
        try require(CGImageDestinationFinalize(dest),"PNG fixture failed")
        return data as Data
    }
    static func main() async throws {
        setbuf(stdout,nil)
        var source = try StudioDocument.new(name:"Editable Blur",width:64,height:32,fps:12)
        source.schemaVersion = 5
        source.frames[0].elements = [.init(id:"red",tool:.rectangle,
            points:[.init(x:4,y:4),.init(x:24,y:28)],color:"#FF0000",width:1,opacity:1,
            layerID:source.activeLayerID,shape:.init(fillColor:"#FF0000"))]
        let before = try pixels(source), operation = effect(source)
        var editor = try StudioDocumentEditor(document:source)
        try editor.commit(operation,frameID:source.activeFrameID)
        let edited = editor.document, rendered = try pixels(edited)
        try require(edited.schemaVersion == 18 && edited.frames[0].elements[0] == source.frames[0].elements[0],
                    "Blur replaced original source or failed schema upgrade")
        try require(close(rendered,try expected(before,operation)),"Ordered compositor differs from actual pixel engine")
        let edge = (16*64+26)*4
        try require(rendered.rgba[edge] > 0 && rendered.rgba[edge+2] == 0,"Blur paints foreground or does not soften")
        print("PASS canonical ordered Blur replay matches actual pixels and retains original vectors")

        editor.undo();try require(close(try pixels(editor.document),before) && editor.document.revision > edited.revision,"Undo lost content or monotonic revision")
        editor.redo();try require(close(try pixels(editor.document),rendered),"Redo changed output")
        editor.copyFrame();try editor.pasteFrame()
        try require(editor.document.frames.count == 2 && editor.document.frames[1].elements[1].blur == operation.blur,
                    "Frame clipboard lost descriptor")
        try require(editor.document.frames[1].elements[1].id != operation.id && close(try pixels(editor.document),rendered),"Clipboard identity/pixels changed")
        var duplicate = try StudioDocumentEditor(document:edited);try duplicate.duplicateLayer(edited.activeLayerID)
        let copies = duplicate.document.frames[0].elements.filter { $0.blur != nil }
        try require(copies.count == 2 && Set(copies.map(\.id)).count == 2 && copies.allSatisfy { $0.blur == operation.blur },"Layer duplicate lost settings/identity")
        print("PASS full document Undo Redo frame clipboard and layer duplication retain editable Blur")

        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("sdi-blur-replay-\(UUID().uuidString)")
        try fm.createDirectory(at:root,withIntermediateDirectories:true);defer { try? fm.removeItem(at:root) }
        let storage = DeviceStorageManager(documentsDirectory:root.appendingPathComponent("Documents"),cachesDirectory:root.appendingPathComponent("Caches"))
        let vm = StudioViewModel(storage:storage)
        let created = await vm.createProject(name:"Saved Blur",width:64,height:32,fps:12)
        try require(created,"Actual project creation failed")
        var rect = source.frames[0].elements[0];rect.layerID = vm.activeLayerID
        try require(vm.commitElement(rect) && vm.commitElement(effect(vm.document)),"Production command failed")
        let savedDocument = vm.document,savedPixels = try pixels(savedDocument)
        let saved = await vm.save();try require(saved,"Atomic persistence failed")
        await vm.backToProjects()
        let reopened = StudioViewModel(storage:storage)
        let opened = await reopened.openProject(vm.savedProjects[0])
        try require(opened && reopened.document == savedDocument && close(try pixels(reopened.document),savedPixels),"Fresh-instance reopen lost descriptor or pixels")
        print("PASS production view model and actual device storage save and cold reopen editable Blur")

        var mixed = try StudioDocumentEditor(document:source)
        let smudge = DrawnElement(id:"smudge",tool:.smudge,points:[.init(x:20.5,y:16.5),.init(x:38.5,y:16.5)],
            color:"#0000FF",width:16,opacity:1,layerID:source.activeLayerID,smudge:.init(strength:1))
        try mixed.commit(smudge,frameID:source.activeFrameID)
        let green = DrawnElement(id:"green",tool:.rectangle,points:[.init(x:28,y:12),.init(x:34,y:21)],
            color:"#00FF00",width:1,opacity:1,layerID:source.activeLayerID,shape:.init(fillColor:"#00FF00"))
        try mixed.commit(green,frameID:source.activeFrameID)
        let erase = DrawnElement(id:"erase",tool:.eraser,points:[.init(x:30,y:18)],color:"#000000",width:4,opacity:1,
            layerID:source.activeLayerID,eraser:.init(mode:.hard))
        try mixed.commit(erase,frameID:source.activeFrameID)
        var blur = effect(source);blur.points = [.init(x:30,y:16)]
        let blurExpected = try expected(pixels(mixed.document),blur)
        try mixed.commit(blur,frameID:source.activeFrameID)
        try require(close(try pixels(mixed.document),blurExpected),"Blur lost preceding Smudge drawing or eraser")
        var second = smudge
        second = .init(id:"last-smudge",tool:.smudge,points:[.init(x:30.5,y:16.5),.init(x:48.5,y:16.5)],
            color:"#FFFFFF",width:12,opacity:0.5,layerID:source.activeLayerID,smudge:.init(strength:0.7))
        let smudgeExpected = try StudioSmudge.apply(to:blurExpected,path:second.points.map { .init(x:$0.x,y:$0.y) },settings:second.smudge!.settings(for:second))
        try mixed.commit(second,frameID:source.activeFrameID)
        try require(close(try pixels(mixed.document),smudgeExpected),"Smudge after Blur used stale prefix")
        print("PASS mixed Smudge drawing eraser Blur and Smudge preserve canonical order and alpha")

        var changed = try StudioDocumentEditor(document:edited)
        try changed.translateElements(frameID:edited.activeFrameID,ids:["red"],dx:-10,dy:0)
        try require(!close(try pixels(changed.document),rendered),"Source movement reused stale flattened output")
        changed.selectedElementIDs = ["red"];try changed.deleteSelected()
        try require((try pixels(changed.document)).rgba.allSatisfy { $0 == 0 },"Source deletion left stale Blur")
        let snapshot = changed.document
        try rejects { try changed.translateElements(frameID:edited.activeFrameID,ids:["blur"],dx:1,dy:0) }
        try require(changed.document == snapshot,"Rejected Blur transform partially committed")
        print("PASS source edits and deletion recompute Blur; unsupported effect transforms reject atomically")

        let size = CGSize(width:64,height:32)
        let prepared = try StudioSmudgeReplay.prepare(frame:edited.frames[0],layers:edited.layers,canvasSize:size,rasterData:nil)
        var stale = edited.frames[0];stale.elements[1].blur!.radius = 2
        try rejects { try prepared.validate(frame:stale,layers:edited.layers,canvasSize:size,rasterData:nil,liveElement:nil) }
        var calls = 0
        _ = try StudioSmudgeReplay.prepare(frame:edited.frames[0],layers:edited.layers,canvasSize:size,rasterData:nil,checkCancellation:{ calls += 1 })
        let final = calls;calls = 0
        try rejects { _ = try StudioSmudgeReplay.prepare(frame:edited.frames[0],layers:edited.layers,canvasSize:size,rasterData:nil,
            checkCancellation:{ calls += 1;if calls == final { throw CancellationError() } }) }
        let cache = StudioSmudgeReplay.Cache()
        let a = try cache.prepare(frame:edited.frames[0],layers:edited.layers,canvasSize:size,rasterData:nil)
        let b = try cache.prepare(frame:stale,layers:edited.layers,canvasSize:size,rasterData:nil)
        try require(a.images["blur"] !== b.images["blur"],"Changed descriptor reused cached image")
        print("PASS stale descriptor rejection final cancellation and shared-cache invalidation")

        for mode in ["full","alpha","position"] {
            var copy = source;copy.layers[0].lockMode = mode
            var e = try StudioDocumentEditor(document:copy)
            try rejects { try e.commit(operation,frameID:copy.activeFrameID) }
            try require(e.document == copy,"Lock failure changed document")
        }
        var selected = try StudioDocumentEditor(document:source);selected.selectedElementIDs = ["red"]
        try rejects { try selected.commit(operation,frameID:source.activeFrameID) }
        var invalid = edited;invalid.schemaVersion = 17;try rejects { try invalid.validate() }
        invalid = edited;invalid.frames[0].elements[1].blur!.version = 2;try rejects { try invalid.validate() }
        invalid = edited;invalid.frames[0].elements[1].smudge = .init();try rejects { try invalid.validate() }
        invalid = edited;invalid.frames[0].elements[1].blur!.radius = .nan;try rejects { try invalid.validate() }
        invalid = edited
        for i in 0..<16 {
            let e: DrawnElement = i%2 == 0 ? effect(source,id:"limit-\(i)") :
                .init(id:"limit-\(i)",tool:.smudge,points:smudge.points,color:"#FFFFFF",width:16,opacity:1,
                      layerID:source.activeLayerID,smudge:.init(strength:1))
            invalid.frames[0].elements.append(e)
        }
        try rejects { try invalid.validate() }
        let encoded = try JSONEncoder().encode(source)
        let legacy = try JSONDecoder().decode(StudioDocument.self,from:encoded)
        try require(legacy == source && legacy.frames[0].elements[0].blur == nil,"Legacy project decoding changed")
        print("PASS locks selection schemas descriptor validation combined effects budget and legacy decoding")

        var faded = edited;faded.layers[0].opacity = 0.25
        let quarter = try pixels(faded)
        try require(abs(Int(quarter.rgba[(16*64+10)*4+3])-64) <= 1,"Layer opacity applied twice")
        faded.layers[0].visible = false
        try require((try pixels(faded)).rgba.allSatisfy { $0 == 0 },"Hidden Blur layer remains visible")
        let output = try await StudioExportService().export(document:mixed.document,format:.pngSequence,outputParent:root,background:.transparent)
        let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(output.imageURLs[0] as CFURL,nil)!,0,nil)!
        try require(close(try StudioSmudgeReplay.pixels(image),try pixels(mixed.document)),"Real reopened PNG differs from editable replay")
        print("PASS layer appearance and real exported reopened PNG use identical effect pixels")

        let originalPNG = try png(StudioExportService().render(source.frames[0],document:source,background:.transparent,raster:nil))
        var imported = source;imported.schemaVersion = 16;imported.frames[0].elements = []
        imported.frames[0].rasterAssetID = "original-png";imported.frames[0].rasterLayerID = imported.activeLayerID
        imported.frames[0].rasterPlacement = .init(x:0,y:0,width:64,height:32)
        imported.frames[0].rasterQuarterTurns = 1;imported.frames[0].rasterReflection = .init(horizontal:true,vertical:false)
        let importedExpected = try expected(pixels(imported,raster:originalPNG),operation)
        var rasterEditor = try StudioDocumentEditor(document:imported)
        try rasterEditor.commit(operation,frameID:source.activeFrameID)
        try require(close(try pixels(rasterEditor.document,raster:originalPNG),importedExpected),"Transformed imported image replay differs")
        try require(rasterEditor.document.frames[0].rasterAssetID == imported.frames[0].rasterAssetID,"Blur replaced original asset identity")
        print("PASS transformed original PNG remains referenced and replays before Blur")
        print("BLUR_REPLAY=PASS groups=9; native gestures and app membership remain unverified")
    }
}
