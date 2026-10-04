import Foundation
import SwiftUI
import AppKit
import AVFoundation
import ImageIO

typealias UIImage = NSImage
extension Image { init(uiImage: NSImage) { self.init(nsImage: uiImage) } }
enum ReplayFailure: Error { case failed(String) }
@main @MainActor struct ReplayTests {
    static func require(_ value: @autoclosure () throws -> Bool, _ text: String) throws {
        if try !value() { throw ReplayFailure.failed(text) }
    }
    static func rejects(_ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw ReplayFailure.failed("Rejected operation succeeded")
    }
    static func pixels(_ document: StudioDocument, frame: AnimationFrame? = nil) throws -> StudioSmudge.Pixels {
        try StudioSmudgeReplay.pixels(StudioExportService().render(frame ?? document.frames[0],
            document: document, background: .transparent, raster: nil))
    }
    static func pixel(_ p: StudioSmudge.Pixels, _ x: Int, _ y: Int) -> [UInt8] {
        Array(p.rgba[((y*p.width+x)*4)..<((y*p.width+x)*4+4)])
    }
    static func effect(_ document: StudioDocument, id: String = "smudge") -> DrawnElement {
        .init(id: id, tool: .smudge, points: [.init(x: 20.5, y: 16.5), .init(x: 42.5, y: 16.5)],
            color: "#0000FF", width: 16, opacity: 1, layerID: document.activeLayerID,
            smudge: .init(strength: 1))
    }
    static func close(_ a: StudioSmudge.Pixels, _ b: StudioSmudge.Pixels) -> Bool {
        a.width == b.width && a.height == b.height && zip(a.rgba,b.rgba).allSatisfy { abs(Int($0)-Int($1)) <= 1 }
    }
    static func encode(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw ReplayFailure.failed("Fixture PNG encoder unavailable")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ReplayFailure.failed("Fixture PNG encoding failed") }
        return data as Data
    }
    static func preparedRender(_ document: StudioDocument, _ prepared: StudioSmudgeReplay.Prepared?) throws -> CGImage {
        let size = CGSize(width:document.width,height:document.height)
        var error: Error?
        let canvas = Canvas { context, actual in
            error = StudioFrameRenderer.draw(context:&context,frame:document.frames[0],layers:document.layers,
                canvasSize:size,size:actual,preparedSmudges:prepared)
        }.frame(width:size.width,height:size.height)
        let renderer = ImageRenderer(content:canvas);renderer.scale = 1
        guard let image = renderer.cgImage else { throw ReplayFailure.failed("Direct compositor failed") }
        if let error { throw error }
        return image
    }
    static func main() async throws {
        setbuf(stdout, nil)
        var source = try StudioDocument.new(name: "Editable Smudge", width: 64, height: 32, fps: 12)
        source.schemaVersion = 5
        source.frames[0].elements = [.init(id: "red", tool: .rectangle,
            points: [.init(x: 4, y: 4), .init(x: 24, y: 28)], color: "#FF0000", width: 1,
            opacity: 1, layerID: source.activeLayerID, shape: .init(fillColor: "#FF0000"))]
        let original = try pixels(source), gesture = effect(source)
        var editor = try StudioDocumentEditor(document: source)
        try editor.commit(gesture, frameID: source.activeFrameID)
        let edited = editor.document
        try require(edited.schemaVersion == 17 && edited.frames[0].elements[0] == source.frames[0].elements[0],
            "Canonical commit flattened or replaced original artwork")
        let expected = try StudioSmudge.apply(to: original,
            path: gesture.points.map { .init(x: $0.x, y: $0.y) }, settings: gesture.smudge!.settings(for: gesture))
        let rendered = try pixels(edited)
        try require(close(rendered, expected), "Actual common compositor differs from independent color-drag pixels")
        try require(pixel(rendered,26,16)[0] > 0 && pixel(rendered,26,16)[2] == 0,
            "Smudge painted foreground blue or failed to move existing red")
        print("PASS actual ordered compositor replays color dragging and retains editable source elements")

        editor.undo()
        var undoExpected = source; undoExpected.revision = edited.revision + 1; undoExpected.modifiedAt = editor.document.modifiedAt
        try require(editor.document == undoExpected && (try pixels(editor.document)) == original, "Undo lost source or revision monotonicity")
        editor.redo()
        var redoExpected = edited; redoExpected.revision = undoExpected.revision + 1; redoExpected.modifiedAt = editor.document.modifiedAt
        try require(editor.document == redoExpected && close(try pixels(editor.document), rendered), "Redo changed pixels or revision monotonicity")
        editor.copyFrame(); try editor.pasteFrame()
        try require(editor.document.frames.count == 2 && editor.document.frames[1].elements[1].smudge == gesture.smudge,
            "Frame clipboard lost effect descriptor")
        try require(editor.document.frames[0].elements[1].id != editor.document.frames[1].elements[1].id,
            "Frame paste reused operation identity")
        try require(close(try pixels(editor.document, frame: editor.document.frames[1]), rendered), "Frame paste changed effect pixels")
        var duplicated = try StudioDocumentEditor(document: edited)
        try duplicated.duplicateLayer(edited.activeLayerID)
        try require(duplicated.document.frames[0].elements.filter { $0.smudge != nil }.count == 2, "Layer duplicate lost descriptor")
        print("PASS full document Undo Redo frame clipboard and layer duplication preserve effect identity and pixels")

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sdi-smudge-replay-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let store = DeviceStorageManager(documentsDirectory: root.appendingPathComponent("Documents"),
            cachesDirectory: root.appendingPathComponent("Caches"))
        let vm = StudioViewModel(storage: store)
        let created = await vm.createProject(name: "Saved Smudge", width: 64, height: 32, fps: 12)
        try require(created, "Real storage create failed")
        var rect = source.frames[0].elements[0]; rect.layerID = vm.activeLayerID
        try require(vm.commitElement(rect), "Original drawing commit failed")
        let savedGesture = effect(vm.document)
        try require(vm.commitElement(savedGesture), "Production view model effect commit failed")
        let snapshot = vm.document, savedPixels = try pixels(snapshot)
        let saved = await vm.save(); try require(saved, "Real atomic storage failed")
        await vm.backToProjects()
        let reopened = StudioViewModel(storage: store)
        let opened = await reopened.openProject(vm.savedProjects[0])
        try require(opened && reopened.document == snapshot && close(try pixels(reopened.document), savedPixels),
            "Actual save/cold-reopen lost editable effect or output")
        print("PASS production view model atomic device save and fresh-instance reopen preserve editable operation and pixels")

        var sequential = try StudioDocumentEditor(document: edited)
        let green = DrawnElement(id: "green", tool: .rectangle,
            points: [.init(x: 28,y: 12),.init(x: 34,y: 21)], color: "#00FF00", width: 1,
            opacity: 1, layerID: edited.activeLayerID, shape: .init(fillColor: "#00FF00"))
        try sequential.commit(green, frameID: edited.activeFrameID)
        let eraser = DrawnElement(id: "erase", tool: .eraser, points: [.init(x: 30,y: 18)],
            color: "#000000", width: 4, opacity: 1, layerID: edited.activeLayerID, eraser: .init(mode: .hard))
        try sequential.commit(eraser, frameID: edited.activeFrameID)
        let beforeSecond = try pixels(sequential.document)
        var second = effect(edited,id: "second"); second.points = [.init(x: 30.5,y: 16.5),.init(x: 50.5,y: 16.5)]
        second.opacity = 0.5
        let secondExpected = try StudioSmudge.apply(to: beforeSecond,
            path: second.points.map { .init(x:$0.x,y:$0.y) }, settings: second.smudge!.settings(for:second))
        try sequential.commit(second,frameID:edited.activeFrameID)
        try require(close(try pixels(sequential.document),secondExpected),
            "Second replay lost intervening drawing/eraser or applied opacity twice")
        print("PASS repeated effects respect ordered intervening vector drawing eraser transparency and captured opacity")

        var changedSource = try StudioDocumentEditor(document: edited)
        try changedSource.translateElements(frameID: edited.activeFrameID, ids: ["red"], dx: -10, dy: 0)
        let moved = try pixels(changedSource.document)
        try require(!close(moved, rendered), "Editable source moved but effect used stale flattened pixels")
        changedSource.selectedElementIDs = ["red"]; try changedSource.deleteSelected()
        try require((try pixels(changedSource.document)).rgba.allSatisfy { $0 == 0 }, "Deleted source left stale smudge color")
        let beforeReject = changedSource.document
        try rejects { try changedSource.translateElements(frameID: edited.activeFrameID, ids: ["smudge"], dx: 1, dy: 0) }
        try require(changedSource.document == beforeReject, "Rejected effect transform partially committed")
        print("PASS edits and deletion of source drawings recompute effects without stale images; unsupported effect transforms reject atomically")

        let size = CGSize(width:64,height:32)
        let prepared = try StudioSmudgeReplay.prepare(frame:edited.frames[0],layers:edited.layers,canvasSize:size,rasterData:nil)
        var stale = edited.frames[0]; stale.elements[0].color = "#FFFFFF"
        try rejects { try prepared.validate(frame:stale,layers:edited.layers,canvasSize:size,rasterData:nil,liveElement:nil) }
        var staleLayers = edited.layers; staleLayers[0].glowEnabled = true
        try rejects { try prepared.validate(frame:edited.frames[0],layers:staleLayers,canvasSize:size,rasterData:nil,liveElement:nil) }
        try rejects { try prepared.validate(frame:edited.frames[0],layers:edited.layers,canvasSize:size,rasterData:Data([1]),liveElement:nil) }
        var calls = 0
        _ = try StudioSmudgeReplay.prepare(frame:edited.frames[0],layers:edited.layers,canvasSize:size,rasterData:nil,
            checkCancellation: { calls += 1 })
        let finalCall = calls; calls = 0
        try rejects { _ = try StudioSmudgeReplay.prepare(frame:edited.frames[0],layers:edited.layers,canvasSize:size,rasterData:nil,
            checkCancellation: { calls += 1; if calls == finalCall { throw CancellationError() } }) }
        try require(edited.frames[0].elements[0] == source.frames[0].elements[0], "Cancellation changed source")
        print("PASS prepared pixels reject stale source layer and asset context; final-stage cancellation exposes no partial result")

        for mode in ["full","alpha","position"] {
            var locked = source; locked.layers[0].lockMode = mode
            var e = try StudioDocumentEditor(document:locked)
            try rejects { try e.commit(effect(locked),frameID:locked.activeFrameID) }
            try require(e.document == locked, "Rejected lock changed document")
        }
        var selection = try StudioDocumentEditor(document:source); selection.selectedElementIDs = ["red"]
        try rejects { try selection.commit(gesture,frameID:source.activeFrameID) }
        var oversized = edited; oversized.width = 4096;oversized.height = 4096
        try rejects { try oversized.validate() }
        var tooMany = edited
        for i in 0..<16 { tooMany.frames[0].elements.append(effect(edited,id:"limit-\(i)")) }
        try rejects { try tooMany.validate() }
        var wrongVersion = edited;wrongVersion.schemaVersion = 16
        try rejects { try wrongVersion.validate() }
        var invalid = edited; invalid.frames[0].elements[1].brush = .init(family:.round,seed:1)
        try rejects { try invalid.validate() }
        print("PASS canonical schema settings selection lock pixel and frame-work limits reject before document mutation")

        var faded = edited; faded.layers[0].opacity = 0.25
        let quarter = try pixels(faded)
        try require(abs(Int(pixel(quarter,10,16)[3])-64) <= 1, "Layer opacity applied twice")
        faded.layers[0].visible = false
        try require((try pixels(faded)).rgba.allSatisfy { $0 == 0 }, "Hidden layer rendered smudge")
        faded.layers[0].visible = true; faded.layers[0].opacity = 0
        try require((try pixels(faded)).rgba.allSatisfy { $0 == 0 }, "Zero-opacity layer failed or rendered smudge")
        let output = try await StudioExportService().export(document:sequential.document,format:.pngSequence,
            outputParent:root,background:.transparent)
        guard let imageSource = CGImageSourceCreateWithURL(output.imageURLs[0] as CFURL,nil),
              let decoded = CGImageSourceCreateImageAtIndex(imageSource,0,nil) else { throw ReplayFailure.failed("PNG cannot reopen") }
        try require(close(try StudioSmudgeReplay.pixels(decoded),secondExpected), "Actual PNG export differs from replay")
        print("PASS layer visibility opacity and reopened real PNG export use identical effect pixels")

        // A subset compositor must exclude other layers without rejecting a
        // perfectly valid full frame. Fill uses precisely this scoped contract.
        var scoped = edited
        scoped.layers.append(.init(id:"other",name:"Other"))
        var other = effect(edited,id:"other-smudge");other.layerID = "other"
        scoped.frames[0].elements.append(other)
        try scoped.validate()
        let isolated = try StudioSmudgeReplay.prepare(frame:scoped.frames[0],layers:[scoped.layers[0]],
            canvasSize:size,rasterData:nil)
        try require(Set(isolated.images.keys) == ["smudge"], "Scoped layer replay included another layer")
        try rejects { _ = try preparedRender(edited,nil) }
        var staleDocument = edited;staleDocument.frames[0].elements[0].color = "#FFFFFF"
        try rejects { _ = try preparedRender(staleDocument,prepared) }
        try require(close(try StudioSmudgeReplay.pixels(preparedRender(edited,prepared)),rendered),
            "Prepared output diverged from exported frame")
        print("PASS scoped layer replay excludes other effects and the common compositor refuses missing or stale preparation")

        // Original PNG is asymmetric and transformed before the operation.
        // Expected pixels come from the real pre-effect renderer, preserving
        // its placement/quarter-turn/reflection rather than an estimated image.
        var asymmetric = source
        asymmetric.frames[0].elements.append(.init(id:"green-top",tool:.rectangle,
            points:[.init(x:5,y:2),.init(x:14,y:10)],color:"#00FF00",width:1,opacity:1,
            layerID:asymmetric.activeLayerID,shape:.init(fillColor:"#00FF00")))
        let png = try encode(StudioExportService().render(asymmetric.frames[0],document:asymmetric,
            background:.transparent,raster:nil))
        let originalPNG = png
        var imported = source;imported.schemaVersion = 16
        imported.frames[0].elements = []
        imported.frames[0].rasterAssetID = "original-png"
        imported.frames[0].rasterLayerID = imported.activeLayerID
        imported.frames[0].rasterPlacement = .init(x:0,y:0,width:64,height:32)
        imported.frames[0].rasterQuarterTurns = 1
        imported.frames[0].rasterReflection = .init(horizontal:true,vertical:false)
        try imported.validate()
        let originalImage = try StudioSmudgeReplay.pixels(StudioExportService().render(imported.frames[0],
            document:imported,background:.transparent,raster:png))
        var imageGesture = effect(imported,id:"image-smudge")
        imageGesture.points = [.init(x:32.5,y:4.5),.init(x:32.5,y:28.5)]
        let imageExpected = try StudioSmudge.apply(to:originalImage,
            path:imageGesture.points.map { .init(x:$0.x,y:$0.y) },settings:imageGesture.smudge!.settings(for:imageGesture))
        var imageEditor = try StudioDocumentEditor(document:imported)
        try imageEditor.commit(imageGesture,frameID:imported.activeFrameID)
        let imageResult = try StudioSmudgeReplay.pixels(StudioExportService().render(imageEditor.document.frames[0],
            document:imageEditor.document,background:.transparent,raster:png))
        try require(close(imageResult,imageExpected) && png == originalPNG,
            "Managed original placement rotation reflection or immutable PNG bytes changed")
        let imageOutput = try await StudioExportService().export(document:imageEditor.document,format:.pngSequence,
            outputParent:root,background:.transparent,rasterData:{ _ in png })
        guard let sourcePNG = CGImageSourceCreateWithURL(imageOutput.imageURLs[0] as CFURL,nil),
              let reopenedPNG = CGImageSourceCreateImageAtIndex(sourcePNG,0,nil) else { throw ReplayFailure.failed("Image-effect output unreadable") }
        try require(close(try StudioSmudgeReplay.pixels(reopenedPNG),imageExpected),"Managed-image effect export pixels changed")
        print("PASS real managed PNG originals quarter turns reflections and placement survive replay and reopened PNG export")
        print("All 10 production Smudge replay groups passed; UI gesture integration and native runtime remain unverified")
    }
}
