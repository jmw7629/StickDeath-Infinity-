import AppKit
import SwiftUI
import ImageIO
import AVFoundation

typealias UIImage = NSImage
extension Image { init(uiImage: NSImage) { self.init(nsImage: uiImage) } }
private struct Failure: Error { let message: String }

@main @MainActor struct SelectionOrderingTests {
    static var passed = 0
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(message: message) }
    }
    static func rejects(_ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw Failure(message: "Invalid operation succeeded")
    }
    static func pass(_ name: String) { passed += 1; print("PASS " + name) }
    static func shape(_ layer: String, id: String = UUID().uuidString, tool: DrawingTool = .rectangle,
                      fill: String? = "#FF0000", radius: Double = 0, opacity: Double = 1) -> DrawnElement {
        .init(id: id, tool: tool,
              points: [.init(x: 16, y: 16), .init(x: 112, y: 112)], color: "#FF0000",
              width: 8, opacity: opacity, layerID: layer,
              shape: .init(fillColor: fill, cornerRadius: radius))
    }
    static func document(_ element: DrawnElement? = nil) throws -> StudioDocument {
        var d = try StudioDocument.new(name: "Real shape settings", width: 128, height: 128, fps: 12)
        if var element { element.layerID = d.activeLayerID; d.frames[0].elements = [element]; d.schemaVersion = 5 }
        return d
    }
    static func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let success = bytes.withUnsafeMutableBytes { data -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: data.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)); return true
        }
        try require(success, "Actual image pixel decode")
        return bytes
    }
    static func render(_ d: StudioDocument, size: Int = 128) throws -> [UInt8] {
        let frame = d.frames[0], brushes = try StudioFrameRenderer.prepare(frame: frame)
        var failure: Error?
        let content = Canvas { context, actual in
            failure = StudioFrameRenderer.draw(context: &context, frame: frame, layers: d.layers,
                canvasSize: CGSize(width: d.width, height: d.height), size: actual, preparedBrushes: brushes)
        }.frame(width: CGFloat(size), height: CGFloat(size))
        let renderer = ImageRenderer(content: content); renderer.scale = 1
        guard let image = renderer.cgImage else { throw Failure(message: "Actual canonical shape renderer") }
        if let failure { throw failure }
        return try pixels(image)
    }
    static func channel(_ pixels: [UInt8], _ x: Int, _ y: Int, _ c: Int = 3, width: Int = 128) -> UInt8 {
        pixels[(y * width + x) * 4 + c]
    }
    static func main() async throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-order-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = DeviceStorageManager(documentsDirectory: root.appendingPathComponent("Documents"), cachesDirectory: root.appendingPathComponent("Cache"))
        let vm = StudioViewModel(storage: storage)
        let created = await vm.createProject(name: "Editable stacking", width: 128, height: 128, fps: 12)
        try require(created, "Production project creation")
        var red = shape(vm.activeLayerID); red.width = 2
        var blue = shape(vm.activeLayerID, fill: "#0000FF"); blue.color = "#0000FF"; blue.width = 2
        blue.points = [.init(x:32,y:32),.init(x:100,y:100)]
        try require(vm.commitElement(red) && vm.commitElement(blue), "Actual shape commits")
        let original = vm.document, originalPixels = try render(original)
        try require(channel(originalPixels,64,64,2)==255 && channel(originalPixels,64,64,0)==0,"Blue originally covers red")
        vm.selectedTool = .move
        try require(vm.selectElement(at:CGPoint(x:24,y:24)) == red.id,"Actual hit selects exposed red shape")
        try require(vm.orderSelected(forward:true),"Actual Forward action")
        try require(vm.message == nil,"Forward introduced a canvas-resizing success banner")
        let ordered = vm.document, orderedPixels = try render(ordered)
        try require(ordered.revision == original.revision+1 && vm.selectedElementIDs == [red.id],"Forward is one revision and retains explicit selection")
        try require(channel(orderedPixels,64,64,0)==255 && channel(orderedPixels,64,64,2)==0,"Red actually covers blue after Forward")
        vm.message = "Existing save error"
        try require(vm.orderSelected(forward:true) && vm.document == ordered,"At-edge Forward changed the document")
        try require(vm.message == "Existing save error","At-edge Forward replaced an existing error")
        vm.message = nil
        vm.undo();try require(render(vm.document)==originalPixels,"Undo restores actual blue pixels")
        vm.redo();try require(render(vm.document)==orderedPixels,"Redo restores actual red pixels")
        pass("existing Forward action changes actual canonical pixels and reverses once")

        let saved = await vm.save();try require(saved,"Actual save")
        let reopened = StudioViewModel(storage:storage);await reopened.loadProjects()
        guard let metadata = reopened.savedProjects.first else { throw Failure(message:"Saved project listing") }
        let opened = await reopened.openProject(metadata);try require(opened,"Production cold reopen")
        try require(render(reopened.document)==orderedPixels && reopened.currentFrame.elements.map(\.id)==[blue.id,red.id],"Saved order and pixels retained")
        let output = try await StudioExportService().export(document:reopened.document,format:.pngSequence,outputParent:root,background:.transparent)
        guard let source=CGImageSourceCreateWithURL(output.imageURLs[0] as CFURL,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil) else { throw Failure(message:"Real exported PNG decode") }
        try require(pixels(image)==orderedPixels,"PNG retains saved stacking")
        reopened.selectedTool = .move;_ = reopened.selectElement(at:CGPoint(x:64,y:64))
        try require(reopened.orderSelected(forward:false),"Actual Back action")
        try require(render(reopened.document)==originalPixels,"Back restores original visible overlap")
        pass("production save list cold reopen decoded PNG and Back preserve layer-local order")

        var many = try document();many.schemaVersion=5
        many.frames[0].elements = ["a","b","c","d","e"].map { id in shape(many.activeLayerID,id:id) }
        for (ids,expected) in [(Set(["a","c"]),["b","a","d","c","e"]),(Set(["b","c"]),["a","d","b","c","e"])] {
            var editor=try StudioDocumentEditor(document:many)
            try editor.orderElements(frameID:many.activeFrameID,ids:ids,forward:true)
            try require(editor.document.frames[0].elements.map(\.id)==expected,"Stable group order")
            for element in editor.document.frames[0].elements {try require(many.frames[0].elements.first{$0.id==element.id}==element,"Original geometry or settings changed")}
            try editor.orderElements(frameID:many.activeFrameID,ids:ids,forward:false)
            try require(editor.document.frames[0].elements==many.frames[0].elements,"Group Back not inverse here")
        }
        pass("noncontiguous and contiguous groups move one neighbor without reversing selection")

        var layered=many;let upper=CanvasLayer(id:"upper",name:"Upper");layered.layers.insert(upper,at:0)
        layered.frames[0].elements[1].layerID=upper.id;layered.frames[0].elements[3].layerID=upper.id
        var layers=try StudioDocumentEditor(document:layered)
        try layers.orderElements(frameID:layered.activeFrameID,ids:["a","b"],forward:true)
        try require(layers.document.frames[0].elements.map(\.id)==["c","d","a","b","e"],"Different layers did not reorder independently")
        try require(layers.document.layers==layered.layers,"Selection changed layer stacking")
        var edge=try StudioDocumentEditor(document:layered)
        try edge.orderElements(frameID:layered.activeFrameID,ids:["d","e"],forward:true)
        try require(edge.document==layered && !edge.canUndo,"Boundary no-op changed revision/history")
        pass("layer boundaries and already-front no-op preserve full document and history")

        for mode in ["full","position","alpha","hidden","transparent"] {
            var blocked=many
            if mode=="hidden" {blocked.layers[0].visible=false}
            else if mode=="transparent" {blocked.layers[0].opacity=0}
            else {blocked.layers[0].lockMode=mode}
            var editor=try StudioDocumentEditor(document:blocked)
            try rejects {try editor.orderElements(frameID:blocked.activeFrameID,ids:["a"],forward:true)}
            try require(editor.document==blocked && !editor.canUndo,"Rejected layer mutated history")
        }
        for ids:Set<String> in [[],["missing"],["a","missing"]] {
            var editor=try StudioDocumentEditor(document:many)
            try rejects {try editor.orderElements(frameID:many.activeFrameID,ids:ids,forward:true)}
            try require(editor.document==many && !editor.canUndo,"Invalid selection changed document")
        }
        pass("locks invisible layers and absent selection reject atomically")

        var probe=try StudioDocumentEditor(document:many);var calls=0
        try probe.orderElements(frameID:many.activeFrameID,ids:["a","c"],forward:true,checkCancellation:{calls+=1})
        for stop in 1...calls {
            var editor=try StudioDocumentEditor(document:many);var count=0
            try rejects {try editor.orderElements(frameID:many.activeFrameID,ids:["a","c"],forward:true,checkCancellation:{count+=1;if count==stop{throw CancellationError()}})}
            try require(editor.document==many && !editor.canUndo,"Cancellation partially reordered document")
        }
        pass("every cancellation checkpoint preserves document and undo history")

        let request=StudioCommandRequest(requestID:UUID(),projectID:many.id,expectedRevision:many.revision,action:.apply([.orderElements(.init(frame:.id(many.activeFrameID),elementIDs:["a","c"],direction:.later))]))
        let bytes=try JSONEncoder().encode(request);let decoded=try StudioCommandExecutor.decode(bytes)
        var wire=try StudioDocumentEditor(document:many);_ = try StudioCommandExecutor.execute(decoded,editor:&wire)
        try require(wire.document.frames[0].elements==probe.document.frames[0].elements,"Typed wire differs from production editor")
        for commands:[StudioCommand] in [
            [.orderElements(.init(frame:.id(many.activeFrameID),elementIDs:["a","a"],direction:.later))],
            [.orderElements(.init(frame:.id("missing"),elementIDs:["a"],direction:.later))],
            [.orderElements(.init(frame:.id(many.activeFrameID),elementIDs:["a"],direction:.later)),.orderElements(.init(frame:.id(many.activeFrameID),elementIDs:["missing"],direction:.earlier))]
        ] {
            var editor=try StudioDocumentEditor(document:many)
            let invalid=StudioCommandRequest(requestID:UUID(),projectID:many.id,expectedRevision:many.revision,action:.apply(commands))
            try rejects {_ = try StudioCommandExecutor.execute(invalid,editor:&editor)}
            try require(editor.document==many && !editor.canUndo,"Invalid wire batch partially committed")
        }
        try rejects {_ = try StudioCommandExecutor.execute(decoded,editor:&wire)}
        pass("strict typed commands share ordering and reject duplicates stale state and invalid batches")
        reopened.clearElementSelection();let unchanged=reopened.document
        try require(!reopened.orderSelected(forward:true) && reopened.document==unchanged,"No selection silently reordered last artwork")
        reopened.selectedTool = .move;_ = reopened.selectElement(at:CGPoint(x:24,y:24))
        let touch=UUID().uuidString;try require(reopened.beginStrokeInput(id:touch),"Actual input guard setup")
        try require(!reopened.orderSelected(forward:true) && reopened.document==unchanged,"Active touch changed order")
        reopened.finishStrokeInput(id:touch)
        pass("visible action refuses missing selection and unfinished touch")
        print("StudioSelectionOrdering: \(passed) passed")
    }
}
