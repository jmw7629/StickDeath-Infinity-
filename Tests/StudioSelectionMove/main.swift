import AppKit
import SwiftUI
import ImageIO
import AVFoundation

typealias UIImage = NSImage
extension Image { init(uiImage: NSImage) { self.init(nsImage: uiImage) } }
private struct Failure: Error { let message: String }

@main @MainActor struct SelectionMoveTests {
    static var passed = 0
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(message: message) }
    }
    static func rejects(_ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw Failure(message: "Invalid operation succeeded")
    }
    static func pass(_ name: String) { passed += 1; print("PASS " + name) }
    static func shape(_ layer: String, tool: DrawingTool = .rectangle,
                      fill: String? = "#FF0000", radius: Double = 0, opacity: Double = 1) -> DrawnElement {
        .init(id: UUID().uuidString, tool: tool,
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
        setbuf(stdout,nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-move-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories:false)
        defer { try? FileManager.default.removeItem(at:root) }
        let storage = DeviceStorageManager(documentsDirectory:root.appendingPathComponent("Documents"),cachesDirectory:root.appendingPathComponent("Cache"))
        let vm = StudioViewModel(storage:storage)
        let created = await vm.createProject(name:"Editable moves",width:128,height:128,fps:12)
        try require(created,"Real project creation")
        var box = shape(vm.activeLayerID)
        box.points = [.init(x:16,y:16),.init(x:40,y:40)];box.width = 2
        try require(vm.commitElement(box),"Actual shape commit")
        let original = vm.document, originalPixels = try render(original)
        let legacy = try JSONEncoder().encode(box)
        try require(!String(decoding:legacy,as:UTF8.self).contains("translation"),"Historical encoding gained translation")
        try require(JSONDecoder().decode(DrawnElement.self,from:legacy) == box,"Historical element decoding")
        pass("historical element bytes and shape pixels remain intact")

        vm.selectedTool = .move
        guard let capture = vm.beginMove(at:CGPoint(x:28,y:28)) else { throw Failure(message:"Actual Move capture") }
        let preview = try vm.movePreview(capture,delta:CGSize(width:48,height:16))
        try require(vm.document == original && preview.elements[0].points == box.points && preview.elements[0].translation == .init(x:48,y:16),"Preview mutates history or original points")
        try require(vm.finishMove(capture,delta:CGSize(width:48,height:16)),"Real Move commit")
        let moved = vm.document, movedPixels = try render(moved)
        try require(moved.schemaVersion == 7 && moved.revision == original.revision + 1,"Move schema and one revision")
        try require(channel(movedPixels,28,28)==0 && channel(movedPixels,76,44)==255,"Actual moved pixels")
        try require(!vm.finishMove(capture,delta:.zero) && vm.document == moved,"Stale move committed")
        vm.undo();try require(render(vm.document)==originalPixels,"One undo restores exact original pixels")
        vm.redo();try require(render(vm.document)==movedPixels,"One redo restores exact moved pixels")
        pass("real preview commit rendered translation stale rejection and one-step undo redo")

        let saved = await vm.save();try require(saved,"Production save")
        let reopened = StudioViewModel(storage:storage);await reopened.loadProjects()
        guard let metadata = reopened.savedProjects.first else { throw Failure(message:"Production saved listing") }
        let opened = await reopened.openProject(metadata);try require(opened,"Production cold reopen")
        try require(render(reopened.document)==movedPixels && reopened.currentFrame.elements[0].translation == .init(x:48,y:16),"Reopen moved artwork")
        let output = try await StudioExportService().export(document:reopened.document,format:.pngSequence,outputParent:root,background:.transparent)
        guard let source = CGImageSourceCreateWithURL(output.imageURLs[0] as CFURL,nil),let image = CGImageSourceCreateImageAtIndex(source,0,nil) else { throw Failure(message:"Real PNG decodes") }
        try require(pixels(image)==movedPixels,"PNG matches moved artwork")
        pass("actual production save list cold reopen and decoded PNG preserve translation")

        var editor = try StudioDocumentEditor(document:original)
        let ids:Set<String>=[box.id]
        try editor.translateElements(frameID:original.activeFrameID,ids:ids,dx:-500,dy:300)
        try require(render(editor.document).allSatisfy{$0==0},"Off-canvas artwork should be clipped")
        try editor.translateElements(frameID:original.activeFrameID,ids:ids,dx:500,dy:-300)
        try require(render(editor.document)==originalPixels && editor.document.frames[0].elements[0].translation==nil,"Moving back loses original artwork")
        try editor.translateElements(frameID:original.activeFrameID,ids:ids,dx:48,dy:16)
        editor.copyFrame();editor.undo();editor.undo();editor.undo()
        try editor.pasteFrame()
        try require(editor.document.schemaVersion==7 && editor.document.frames[1].elements[0].translation == .init(x:48,y:16),"Clipboard after undo lost translation or schema")
        try editor.duplicateLayer(original.activeLayerID)
        try require(editor.document.frames[1].elements.allSatisfy{$0.translation == .init(x:48,y:16)},"Layer duplication lost moves")
        pass("off-canvas moves preserve originals and clipboard layer duplication retain translation")

        var filled = try document()
        let mask = StudioFillMask(width:128,height:128,spans:(16..<32).map{ .init(row:$0,start:16,end:32,alpha:255) })
        let fill = DrawnElement(id:"fill-region",tool:.fill,points:[.init(x:16,y:16),.init(x:32,y:32)],color:"#FF0000",width:1,opacity:1,layerID:filled.activeLayerID,fillMask:mask)
        filled.frames[0].elements=[fill];filled.schemaVersion=6
        var fillEditor = try StudioDocumentEditor(document:filled)
        try fillEditor.translateElements(frameID:filled.activeFrameID,ids:[fill.id],dx:48,dy:16)
        let fillPixels = try render(fillEditor.document)
        try require(channel(fillPixels,24,24)==0 && channel(fillPixels,72,40)==255,"Fill mask pixels did not move")
        try require(fillEditor.document.frames[0].elements[0].fillMask==mask,"Original fill coverage was rewritten")
        fillEditor.undo();try require(render(fillEditor.document)==render(filled),"Undo fill pixels")
        pass("canonical fill coverage translates without destructive clipping and reverses exactly")

        for family in StudioBrushFamily.allCases {
            var brushDoc = try document()
            let brush = DrawnElement(id:"brush-" + family.rawValue,tool:.brush,
                points:[.init(x:16,y:24),.init(x:40,y:24)],color:"#FF0000",width:8,opacity:1,layerID:brushDoc.activeLayerID,
                brush:.init(family:family,seed:1234,gradientEndColor:family == .gradient ? .init(red:0,green:0,blue:1) : nil))
            brushDoc.frames[0].elements=[brush];brushDoc.schemaVersion=2
            var brushes=try StudioDocumentEditor(document:brushDoc)
            let originalGeometry = try StudioBrushGeometryCache.geometry(for:brush)
            let before = try render(brushDoc)
            try brushes.translateElements(frameID:brushDoc.activeFrameID,ids:[brush.id],dx:48,dy:16)
            let after = try render(brushes.document)
            try require(StudioBrushGeometryCache.geometry(for:brushes.document.frames[0].elements[0]) == originalGeometry,"Moving regenerated brush geometry")
            var differences=0, maximum=0, total=0
            for y in 0..<112 { for x in 0..<80 { for channel in 0..<4 {
                let difference=abs(Int(before[(y*128+x)*4+channel])-Int(after[((y+16)*128+x+48)*4+channel]))
                if difference>0 { differences+=1;total+=difference;maximum=max(maximum,difference) }
            } } }
            // The same GraphicsContext paths shift through floating-point rasterization.
            // Measured Rough Pen differs in two 1/255 channels; all other families
            // are exact. Geometry above remains strictly identical.
            try require(maximum <= 1 && differences <= 4 && total <= 4,"Moved brush texture exceeds bounded rasterization error: " + family.rawValue)
            print("BRUSH_MOVE_DELTA \(family.rawValue) channels=\(differences) max=\(maximum) total=\(total)")
            try require(brushes.document.frames[0].elements[0].points==brush.points && brushes.document.frames[0].elements[0].brush==brush.brush,"Brush inputs changed")
        }
        pass("all ten real brush families retain identical geometry and bounded translated pixel accuracy")

        for lock in ["position","full","alpha"] {
            var d = original;d.layers[0].lockMode=lock
            var locked = try StudioDocumentEditor(document:d)
            try rejects { try locked.translateElements(frameID:d.activeFrameID,ids:ids,dx:1,dy:1) }
            try require(locked.document==d && !locked.canUndo,"Rejected lock changed document or history")
        }
        var hidden = original;hidden.layers[0].visible=false
        var hiddenEditor = try StudioDocumentEditor(document:hidden)
        try rejects { try hiddenEditor.translateElements(frameID:hidden.activeFrameID,ids:ids,dx:1,dy:1) }
        var valid = try StudioDocumentEditor(document:original)
        for delta in [Double.nan,Double.infinity,100001] {
            try rejects { try valid.translateElements(frameID:original.activeFrameID,ids:ids,dx:delta,dy:0) }
        }
        try rejects { try valid.translateElements(frameID:original.activeFrameID,ids:[],dx:1,dy:1) }
        try rejects { try valid.translateElements(frameID:original.activeFrameID,ids:["missing"],dx:1,dy:1) }
        try require(valid.document==original && !valid.canUndo,"Invalid move changed history")
        var wrongVersion=moved;wrongVersion.schemaVersion=6;try rejects{try wrongVersion.validate()}
        pass("position full alpha visibility finite geometry selection and version gates preserve data")

        var commands = try StudioDocumentEditor(document:original)
        let request = StudioCommandRequest(requestID:UUID(),projectID:original.id,expectedRevision:original.revision,
            action:.apply([.translateElements(.init(frame:.id(original.activeFrameID),elementIDs:[box.id],dx:48,dy:16))]))
        let wire = try JSONEncoder().encode(request)
        let decoded = try StudioCommandExecutor.decode(wire)
        try StudioCommandExecutor.execute(decoded,editor:&commands)
        try require(render(commands.document)==movedPixels,"Typed command and UI disagree")
        for checkpoint in 1...6 {
            var cancelled = try StudioDocumentEditor(document:original),calls=0
            try rejects { try StudioCommandExecutor.execute(decoded,editor:&cancelled,checkCancellation:{ calls+=1;if calls==checkpoint { throw CancellationError() } }) }
            try require(cancelled.document==original && !cancelled.canUndo,"Cancelled transaction altered history")
        }
        pass("typed wire command produces same pixels and every cancellation point rolls back")

        reopened.selectedTool = .move
        guard let cancelledCapture = reopened.beginMove(at:CGPoint(x:76,y:44)) else { throw Failure(message:"Reopened Move hit testing") }
        reopened.gridEnabled.toggle()
        let intervening = reopened.document
        try require(!reopened.finishMove(cancelledCapture,delta:CGSize(width:1,height:1)) && reopened.document==intervening,"Intervening edit overwritten")
        pass("captured Move rejects intervening real view model edits")
        var second = box;second = DrawnElement(id:"second",tool:second.tool,
            points:[.init(x:16,y:80),.init(x:40,y:104)],color:second.color,width:second.width,
            opacity:second.opacity,layerID:reopened.activeLayerID,shape:second.shape)
        try require(reopened.commitElement(second),"Second actual element")
        reopened.selectionMode = .new;reopened.selectElement(at:CGPoint(x:76,y:44))
        reopened.selectionMode = .add;reopened.selectElement(at:CGPoint(x:28,y:92))
        try require(reopened.selectedElementIDs == [box.id,second.id],"Add selection")
        guard let multi = reopened.beginMove(at:CGPoint(x:28,y:92)) else { throw Failure(message:"Group capture") }
        let beforeGroup = reopened.document
        try require(reopened.finishMove(multi,delta:CGSize(width:5,height:0)),"Group moves")
        try require(reopened.currentFrame.elements[0].translation == .init(x:53,y:16) && reopened.currentFrame.elements[1].translation == .init(x:5,y:0),"Both selected elements moved together")
        reopened.undo();try require(render(reopened.document)==render(beforeGroup),"One group undo")
        reopened.selectionMode = .add;reopened.selectElement(at:CGPoint(x:76,y:44));reopened.selectElement(at:CGPoint(x:28,y:92))
        reopened.selectionMode = .subtract
        try require(reopened.beginMove(at:CGPoint(x:28,y:92))==nil && reopened.selectedElementIDs == [box.id],"Subtract must not drag remaining selection")
        reopened.clearElementSelection();try require(reopened.selectedElementIDs.isEmpty,"Deselect")
        pass("New Add Subtract and Deselect control real multi-element reversible moves")
        print("StudioSelectionMove: \(passed)/\(passed) groups passed")
    }
}
