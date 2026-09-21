import AppKit
import SwiftUI
import ImageIO
import AVFoundation

typealias UIImage = NSImage
extension Image { init(uiImage: NSImage) { self.init(nsImage: uiImage) } }
private struct Failure: Error { let message: String }

@main @MainActor struct SelectionClipboardTests {
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
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("sdi-clipboard-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        defer {try? FileManager.default.removeItem(at:root)}
        let storage=DeviceStorageManager(documentsDirectory:root.appendingPathComponent("Documents"),cachesDirectory:root.appendingPathComponent("Cache"))
        let vm=StudioViewModel(storage:storage)
        let made=await vm.createProject(name:"Real selected drawing copies",width:128,height:128,fps:12)
        try require(made,"Actual project creation")
        var red=shape(vm.activeLayerID);red.points=[.init(x:16,y:16),.init(x:32,y:32)];red.width=2
        var blue=shape(vm.activeLayerID);blue.points=[.init(x:40,y:40),.init(x:56,y:56)];blue.width=2;blue.color="#0000FF";blue.shape?.fillColor="#0000FF"
        try require(vm.commitElement(red) && vm.commitElement(blue),"Actual drawings")
        let saved=await vm.save();try require(saved,"Initial production save")
        let initial=vm.document, undoBefore=vm.canUndo
        vm.selectedTool = .move;vm.selectionMode = .new;_ = vm.selectElement(at:CGPoint(x:24,y:24));vm.selectionMode = .add;_ = vm.selectElement(at:CGPoint(x:48,y:48))
        try require(vm.selectedElementIDs==[red.id,blue.id] && vm.copySelected(),"Real explicit selection copy")
        try require(vm.document==initial && !vm.isDirty && vm.canUndo==undoBefore && vm.copiedDrawingCount==2 && vm.canPaste,"Copy changed document or history instead of capturing a clipboard")
        try require(vm.message==nil,"Copy inserted a resizing success banner")
        try require(vm.commandScreenContext.copiedDrawingCount==2 && vm.commandScreenContext.copiedDrawingClipboardID==vm.copiedDrawingClipboardID,"Spatter context lacks the actual clipboard identity and count")
        pass("actual Copy captures explicit selection without modifying document saved state history or canvas status")

        try require(vm.reflectSelected(axis:.horizontal),"Edit originals after copying")
        let beforePaste=vm.document
        vm.pasteClipboard()
        let pasted=vm.document, copies=Array(vm.currentFrame.elements.suffix(2))
        try require(pasted.frames.count==1 && pasted.frames[0].elements.count==4 && pasted.revision==beforePaste.revision+1,"Paste must add drawings in the current frame as one edit")
        try require(copies[0].points==red.points && copies[1].points==blue.points && copies.allSatisfy{$0.reflection==nil},"Clipboard changed after originals were edited")
        let copiedIDs=Set(copies.map(\.id));try require(copiedIDs.count==2 && copiedIDs.isDisjoint(with:[red.id,blue.id]) && vm.selectedElementIDs==copiedIDs,"Pasted drawings need fresh globally unique editable IDs")
        try require(vm.message==nil,"Paste inserted a resizing success banner")
        vm.undo();try require(vm.document.frames==beforePaste.frames && vm.copiedDrawingCount==2,"One Undo lost clipboard or failed to remove pasted elements")
        vm.redo();try require(vm.document.frames==pasted.frames,"One Redo failed to restore exact pasted identities")
        pass("immutable snapshot survives source edits; current-frame paste preserves samples with fresh IDs and one Undo Redo")

        vm.selectionMode = .new;_ = vm.selectElement(at:CGPoint(x:24,y:24));vm.selectionMode = .add;_ = vm.selectElement(at:CGPoint(x:48,y:48));vm.selectionMode = .new
        guard let move=vm.beginMove(at:CGPoint(x:24,y:24)) else {throw Failure(message:"Pasted artwork could not start a real Move")}
        try require(vm.finishMove(move,delta:CGSize(width:32,height:32)),"Actual pasted-artwork move")
        let moved=vm.document, expected=try render(moved)
        try require(channel(expected,56,56,0)>240 && channel(expected,56,56,2)<20 && channel(expected,80,80,2)>240,"Pasted shapes did not render at their moved positions")
        let persisted=await vm.save();try require(persisted,"Actual copied-artwork save")
        let reopened=StudioViewModel(storage:storage);await reopened.loadProjects()
        guard let project=reopened.savedProjects.first else {throw Failure(message:"Real saved project missing")}
        let opened=await reopened.openProject(project);try require(opened && reopened.document==moved && reopened.copiedDrawingCount==0,"Cold reopen lost actual artwork or persisted a transient clipboard")
        let exported=try await StudioExportService().export(document:reopened.document,format:.pngSequence,outputParent:root,background:.transparent)
        guard let imageSource=CGImageSourceCreateWithURL(exported.imageURLs[0] as CFURL,nil),let png=CGImageSourceCreateImageAtIndex(imageSource,0,nil) else {throw Failure(message:"Copied artwork PNG did not decode")}
        try require(pixels(png)==expected,"Decoded PNG differs from saved copied artwork")
        pass("pasted drawings remain movable and survive actual save list cold reopen and decoded PNG")

        var transformed=try StudioDocumentEditor(document:initial)
        try transformed.reflectElements(frameID:initial.activeFrameID,ids:[red.id,blue.id],axis:.horizontal)
        let originals=transformed.document.frames[0].elements
        try transformed.copyElements(frameID:initial.activeFrameID,ids:[red.id,blue.id]);try transformed.addLayer()
        let target=transformed.document.activeLayerID
        let fresh=try transformed.pasteElements(frameID:initial.activeFrameID,layerID:target)
        let transferred=transformed.document.frames[0].elements.filter{fresh.contains($0.id)}
        try require(transferred.map(\.points)==originals.map(\.points) && transferred.map(\.reflection)==originals.map(\.reflection) && transferred.map(\.translation)==originals.map(\.translation) && transferred.allSatisfy{$0.layerID==target},"Destination layer or original transforms changed")
        let firstIDs=fresh;let nextIDs=try transformed.pasteElements(frameID:initial.activeFrameID,layerID:target)
        try require(nextIDs.isDisjoint(with:firstIDs) && nextIDs.isDisjoint(with:[red.id,blue.id]),"Repeated paste reused identities")
        pass("destination-layer paste retains original reflections translations and fresh IDs on every paste")

        for family in StudioBrushFamily.allCases {
            var d=initial;d.schemaVersion=8
            let stroke=DrawnElement(id:"brush-"+family.rawValue,tool:.brush,points:[.init(x:16,y:24),.init(x:72,y:44)],color:"#FF0000",width:8,opacity:1,layerID:d.activeLayerID,brush:.init(family:family,seed:1234,gradientEndColor:family == .gradient ? .init(red:0,green:0,blue:1):nil))
            d.frames[0].elements=[stroke]
            var editor=try StudioDocumentEditor(document:d);try editor.copyElements(frameID:d.activeFrameID,ids:[stroke.id]);let ids=try editor.pasteElements(frameID:d.activeFrameID,layerID:d.activeLayerID)
            let copied=editor.document.frames[0].elements.first{ids.contains($0.id)}!
            try require(copied.brush==stroke.brush && copied.points==stroke.points && StudioBrushGeometryCache.geometry(for:copied)==StudioBrushGeometryCache.geometry(for:stroke),"Brush clipboard changed deterministic family geometry")
        }
        var fill=initial;fill.schemaVersion=8
        let mask=StudioFillMask(width:128,height:128,spans:(16..<40).map{.init(row:$0,start:16,end:$0<24 ? 24:40,alpha:255)})
        let element=DrawnElement(id:"sparse",tool:.fill,points:[.init(x:16,y:16),.init(x:40,y:40)],color:"#FF0000",width:1,opacity:1,layerID:fill.activeLayerID,fillMask:mask,translation:.init(x:4,y:3),reflection:.init(horizontal:true,vertical:false))
        fill.frames[0].elements=[element]
        var fillEditor=try StudioDocumentEditor(document:fill);try fillEditor.copyElements(frameID:fill.activeFrameID,ids:[element.id]);let fillIDs=try fillEditor.pasteElements(frameID:fill.activeFrameID,layerID:fill.activeLayerID)
        let fillCopy=fillEditor.document.frames[0].elements.first{fillIDs.contains($0.id)}!
        try require(fillCopy.fillMask==mask && fillCopy.translation==element.translation && fillCopy.reflection==element.reflection,"Sparse fill clipboard lost its original coverage or transform")
        pass("all ten brush families and transformed sparse fills retain samples seeds masks and canonical geometry")

        var layered=initial;let upper=CanvasLayer(id:"upper",name:"Upper");layered.layers.insert(upper,at:0);layered.frames[0].elements[0].layerID=upper.id
        var order=try StudioDocumentEditor(document:layered);try order.copyElements(frameID:layered.activeFrameID,ids:[red.id,blue.id])
        try require(order.clipboardElements?.map(\.id)==[blue.id,red.id],"Multi-layer selection changed canonical back-to-front order")
        try order.addFrame();let frame=order.document.activeFrameID;try order.pasteElements(frameID:frame,layerID:order.document.activeLayerID)
        try require(order.document.frames[1].elements.map(\.color)==[blue.color,red.color],"Cross-frame paste changed visual stacking")
        pass("copy across layers retains painter order when pasted into the selected destination frame and layer")

        for mode in ["full","hidden","transparent"] {
            var blocked=initial
            if mode=="hidden" {blocked.layers[0].visible=false} else if mode=="transparent" {blocked.layers[0].opacity=0} else {blocked.layers[0].lockMode=mode}
            var editor=try StudioDocumentEditor(document:blocked);editor.copyFrame()
            try rejects{try editor.copyElements(frameID:blocked.activeFrameID,ids:[red.id])}
            try require(editor.document==blocked && editor.clipboardElements==nil && editor.canPaste,"Rejected Copy replaced existing frame clipboard")
        }
        for mode in ["full","alpha","hidden","transparent"] {
            var editor=try StudioDocumentEditor(document:initial);try editor.copyElements(frameID:initial.activeFrameID,ids:[red.id]);try editor.updateLayer(initial.activeLayerID){layer in if mode=="hidden"{layer.visible=false}else if mode=="transparent"{layer.opacity=0}else{layer.lockMode=mode}}
            let before=editor.document;try rejects{try editor.pasteElements(frameID:initial.activeFrameID,layerID:initial.activeLayerID)}
            try require(editor.document==before && editor.clipboardElementCount==1,"Rejected Paste changed document or lost retryable clipboard")
        }
        pass("hidden full-locked transparent and alpha-paste gates preserve document and previous clipboard")

        for ids:Set<String> in [[],["missing"],[red.id,"missing"]] {
            var editor=try StudioDocumentEditor(document:initial);editor.copyFrame();try rejects{try editor.copyElements(frameID:initial.activeFrameID,ids:ids)}
            try require(editor.document==initial && editor.canPaste && editor.clipboardElementCount==0 && !editor.canUndo,"Invalid selection changed clipboard history or document")
        }
        var over=initial;over.frames[0].elements[0].points=Array(repeating:.init(x:20,y:20),count:65_537);over.frames[0].elements[0].shape=nil
        var limited=try StudioDocumentEditor(document:over);limited.copyFrame();try rejects{try limited.copyElements(frameID:over.activeFrameID,ids:[red.id])}
        try require(limited.clipboardElementCount==0 && limited.document==over,"Point limit replaced clipboard")
        pass("empty stale and over-budget copies fail without replacing recoverable state")

        var wide=try StudioDocument.new(name:"Bounded clipboard",width:2048,height:2048,fps:12);wide.schemaVersion=6
        let spans=(0..<2048).flatMap{row in (0..<32).map{column in StudioFillMask.Span(row:row,start:column*2,end:column*2+1,alpha:255)}}
        let largeMask=StudioFillMask(width:2048,height:2048,spans:spans)
        wide.frames[0].elements=(0..<4).map{index in DrawnElement(id:"fill-\(index)",tool:.fill,points:[.init(x:0,y:0),.init(x:63,y:2047)],color:"#FF0000",width:1,opacity:1,layerID:wide.activeLayerID,fillMask:largeMask)}
        wide.frames[0].elements.append(DrawnElement(id:"many-points",tool:.pencil,points:Array(repeating:.init(x:20,y:20),count:65_528),color:"#FF0000",width:1,opacity:1,layerID:wide.activeLayerID))
        var memory=try StudioDocumentEditor(document:wide);memory.copyFrame();let memoryVersion=memory.clipboardVersion
        do {try memory.copyElements(frameID:wide.activeFrameID,ids:Set(wide.frames[0].elements.map(\.id)));throw Failure(message:"Oversized clipboard accepted")}
        catch StudioDocumentError.unavailable(let text) {try require(text.contains("8 MB"),"The actual clipboard byte budget was not exercised")}
        try require(memory.document==wide && memory.clipboardVersion==memoryVersion && memory.clipboardElementCount==0 && !memory.canUndo,"8 MB copy rejection replaced existing state")
        var foreign=try StudioDocumentEditor(document:StudioDocument.new(name:"Other project",width:128,height:128,fps:12));foreign.copyFrame()
        try rejects{try memory.adoptClipboard(from:foreign)}
        try require(memory.clipboardVersion==memoryVersion,"Foreign project replaced clipboard")
        pass("real span and point memory budget and foreign-project adoption reject without data loss")

        var copyProbe=try StudioDocumentEditor(document:initial);var copyCalls=0
        try copyProbe.copyElements(frameID:initial.activeFrameID,ids:[red.id,blue.id],checkCancellation:{copyCalls+=1})
        for stop in 1...copyCalls {
            var editor=try StudioDocumentEditor(document:initial);editor.copyFrame();var count=0
            try rejects{try editor.copyElements(frameID:initial.activeFrameID,ids:[red.id,blue.id],checkCancellation:{count+=1;if count==stop{throw CancellationError()}})}
            try require(editor.document==initial && editor.clipboardElementCount==0 && editor.canPaste && !editor.canUndo,"Cancelled Copy changed state")
        }
        var pasteProbe=copyProbe;var pasteCalls=0;try pasteProbe.pasteElements(frameID:initial.activeFrameID,layerID:initial.activeLayerID,checkCancellation:{pasteCalls+=1})
        for stop in 1...pasteCalls {
            var editor=copyProbe;var count=0;try rejects{try editor.pasteElements(frameID:initial.activeFrameID,layerID:initial.activeLayerID,checkCancellation:{count+=1;if count==stop{throw CancellationError()}})}
            try require(editor.document==initial && editor.clipboardElementCount==2 && !editor.canUndo,"Cancelled Paste changed state")
        }
        pass("every copy and paste cancellation checkpoint preserves full document clipboard and history")

        func request(_ commands:[StudioCommand],revision:Int=initial.revision)->StudioCommandRequest {.init(requestID:UUID(),projectID:initial.id,expectedRevision:revision,action:.apply(commands))}
        let copyCommand=StudioCommand.copyElements(.init(frame:.id(initial.activeFrameID),elementIDs:[red.id,blue.id]))
        let bytes=try JSONEncoder().encode(request([copyCommand]));let decoded=try StudioCommandExecutor.decode(bytes)
        var wire=try StudioDocumentEditor(document:initial)
        let copied=try StudioCommandExecutor.execute(decoded,editor:&wire)
        guard let clipboardID=copied.clipboardID else {throw Failure(message:"Typed Copy omitted clipboard identity")}
        let pasteCommand=StudioCommand.pasteElements(.init(frame:.id(initial.activeFrameID),layer:.id(initial.activeLayerID),clipboardID:clipboardID))
        try require(copied.outcome == .unchanged && copied.clipboardElementCount==2 && wire.clipboardElementCount==2 && wire.document==initial && !wire.canUndo,"Typed copy lost clipboard when coalescing a non-document edit")
        let pasteBytes=try JSONEncoder().encode(request([pasteCommand]))
        let receipt=try StudioCommandExecutor.execute(StudioCommandExecutor.decode(pasteBytes),editor:&wire)
        try require(receipt.createdElementIDs.count==2 && receipt.clipboardElementCount==2 && wire.document.revision==initial.revision+1,"Typed paste receipt must describe actual editable copies")
        wire.undo();try require(wire.document.frames==initial.frames && wire.clipboardElementCount==2,"Typed paste must undo once without losing clipboard")
        for commands in [[copyCommand,StudioCommand.pasteElements(.init(frame:.id("missing"),layer:.id(initial.activeLayerID),clipboardID:clipboardID))],[StudioCommand.copyElements(.init(frame:.id(initial.activeFrameID),elementIDs:[red.id,red.id]))]] {
            var staged=try StudioDocumentEditor(document:initial);staged.copyFrame();try rejects{_ = try StudioCommandExecutor.execute(request(commands),editor:&staged)}
            try require(staged.document==initial && staged.clipboardElementCount==0 && staged.canPaste && !staged.canUndo,"Rejected batch partially replaced clipboard")
        }
        let extra=String(decoding:bytes,as:UTF8.self).replacingOccurrences(of:"\"elementIDs\":",with:"\"shell\":\"never\",\"elementIDs\":")
        try rejects{_ = try StudioCommandExecutor.decode(Data(extra.utf8))}
        pass("strict typed UI-equivalent clipboard commands coalesce atomically and report factual copied and created counts")

        var stale=try StudioDocumentEditor(document:initial)
        let firstCopy=try StudioCommandExecutor.execute(decoded,editor:&stale)
        try stale.copyElements(frameID:initial.activeFrameID,ids:[blue.id]);let currentClipboard=stale.clipboardVersion
        let stalePaste=StudioCommand.pasteElements(.init(frame:.id(initial.activeFrameID),layer:.id(initial.activeLayerID),clipboardID:firstCopy.clipboardID!))
        do {_ = try StudioCommandExecutor.execute(request([stalePaste]),editor:&stale);throw Failure(message:"Stale clipboard accepted")}
        catch StudioCommandError.staleClipboard {}
        try require(stale.document==initial && stale.clipboardVersion==currentClipboard && stale.clipboardElements?.map(\.id)==[blue.id],"Stale request replaced newer clipboard")
        let live=reopened.document;var checkpoints=0
        let reentrant=StudioCommandRequest(requestID:UUID(),projectID:live.id,expectedRevision:live.revision,action:.apply([.copyElements(.init(frame:.id(live.activeFrameID),elementIDs:[live.frames[0].elements[0].id]))]))
        do {
            _ = try reopened.applyStudioCommands(reentrant,checkCancellation:{checkpoints+=1;if checkpoints==2{reopened.copyFrame()}})
            throw Failure(message:"Intervening clipboard edit was overwritten")
        } catch StudioCommandError.staleClipboard {}
        try require(reopened.document==live && reopened.copiedDrawingCount==0 && reopened.canPaste,"Intervening frame clipboard or document was lost")
        pass("clipboard identity rejects stale paste and reentrant clipboard replacement without overwriting newer user state")

        var frames=try StudioDocumentEditor(document:initial);try frames.copyElements(frameID:initial.activeFrameID,ids:[red.id]);frames.copyFrame()
        try require(frames.clipboardElementCount==0,"Explicit frame Copy did not replace drawing clipboard")
        try frames.pasteFrame();try require(frames.document.frames.count==2 && frames.document.frames[1].elements.count==2,"Existing frame clipboard changed behavior")
        let touch=UUID().uuidString;try require(reopened.beginStrokeInput(id:touch),"Actual input guard")
        let untouched=reopened.document;try require(!reopened.copySelected() && reopened.document==untouched,"Unfinished input allowed Copy")
        reopened.finishStrokeInput(id:touch)
        pass("existing full-frame Copy Paste and active-input protection remain intact")
        print("StudioSelectionClipboard: \(passed) groups passed")
    }
}
