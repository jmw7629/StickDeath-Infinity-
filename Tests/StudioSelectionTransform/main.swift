import AppKit
import SwiftUI
import ImageIO
import AVFoundation

typealias UIImage = NSImage
extension Image { init(uiImage: NSImage) { self.init(nsImage: uiImage) } }
private struct Failure: Error { let message: String }

@main @MainActor struct SelectionTransformTests {
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
    static func render(_ d: StudioDocument, size: Int = 128, height: Int = 128) throws -> [UInt8] {
        let frame = d.frames[0], brushes = try StudioFrameRenderer.prepare(frame: frame)
        var failure: Error?
        let content = Canvas { context, actual in
            failure = StudioFrameRenderer.draw(context: &context, frame: frame, layers: d.layers,
                canvasSize: CGSize(width: d.width, height: d.height), size: actual, preparedBrushes: brushes)
        }.frame(width: CGFloat(size), height: CGFloat(height))
        let renderer = ImageRenderer(content: content); renderer.scale = 1
        guard let image = renderer.cgImage else { throw Failure(message: "Actual canonical shape renderer") }
        if let failure { throw failure }
        return try pixels(image)
    }
    static func channel(_ pixels: [UInt8], _ x: Int, _ y: Int, _ c: Int = 3, width: Int = 128) -> UInt8 {
        pixels[(y * width + x) * 4 + c]
    }

    static func request(_ d: StudioDocument, _ commands: [StudioCommand]) -> StudioCommandRequest {
        .init(requestID:UUID(),projectID:d.id,expectedRevision:d.revision,action:.apply(commands))
    }
    static func transform(_ d: StudioDocument, ids: [String], x: Double = 2, y: Double = 2, angle: Double = 90) -> StudioCommand {
        .transformElements(.init(frame:.id(d.activeFrameID),elementIDs:ids,scaleX:x,scaleY:y,rotation:angle))
    }
    static func actualMovie(_ d: StudioDocument, reference: [UInt8], root: URL) async throws {
        let snapshot = StudioMovieExportService.Snapshot(document:d,retainedAudioTracks:[],rasterDataByID:[:])
        let output = try await StudioMovieExportService().export(snapshot:snapshot,outputParent:root,background:.white)
        let url=try output.checkedURLs()[0], asset=AVURLAsset(url:url)
        let tracks=try await asset.loadTracks(withMediaType:.video)
        try require(tracks.count==1,"Actual transformed movie video track")
        let formats=try await tracks[0].load(.formatDescriptions)
        try require(formats.first.map{CMFormatDescriptionGetMediaSubType($0)}==kCMVideoCodecType_H264,"Real H264 output")
        let reader=try AVAssetReader(asset:asset)
        let video=AVAssetReaderTrackOutput(track:tracks[0],outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        reader.add(video);try require(reader.startReading(),"Actual decoder starts")
        var frames=0
        while let sample=video.copyNextSampleBuffer() {
            guard let buffer=CMSampleBufferGetImageBuffer(sample) else {throw Failure(message:"Missing actual pixel buffer")}
            try require(CVPixelBufferGetWidth(buffer)==128 && CVPixelBufferGetHeight(buffer)==128,"Canvas size changed")
            CVPixelBufferLockBaseAddress(buffer,.readOnly)
            let error:Double = try {
                defer {CVPixelBufferUnlockBaseAddress(buffer,.readOnly)}
                guard let p=CVPixelBufferGetBaseAddress(buffer) else {throw Failure(message:"Missing decoded bytes")}
                let bytes=p.assumingMemoryBound(to:UInt8.self), row=CVPixelBufferGetBytesPerRow(buffer)
                var total=0
                for y in 0..<128 {for x in 0..<128 {
                    let a=(y*128+x)*4,b=y*row+x*4,white=255-Int(reference[a+3])
                    for c in 0..<3 {total+=abs(Int(bytes[b+2-c])-(Int(reference[a+c])+white))}
                }}
                return Double(total)/Double(128*128*3)
            }()
            print("TRANSFORM_MP4_MEAN_RGB_ERROR=\(error)")
            try require(error<8,"Encoded transform differs from canonical pixels")
            try require(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample),.zero)==0,"Frame timestamp changed")
            frames+=1
        }
        let duration=try await asset.load(.duration)
        try require(reader.status == .completed && frames==1 && CMTimeCompare(duration,CMTime(value:1,timescale:12))==0,"Real decode timing/count failed")
        try require(output.manifest.encodedBytes==Data(contentsOf:url).count,"Movie receipt bytes differ")
        try output.cleanup();try require(!FileManager.default.fileExists(atPath:url.path),"Output cleanup failed")
        pass("actual H264 output reopens with transformed pixels timing and owned cleanup")
    }
    static func main() async throws {
        setbuf(stdout,nil)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("sdi-transform-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=DeviceStorageManager(documentsDirectory:root.appendingPathComponent("Documents"),cachesDirectory:root.appendingPathComponent("Cache"))
        let vm=StudioViewModel(storage:store)
        let made=await vm.createProject(name:"Editable scale rotate",width:128,height:128,fps:12)
        try require(made,"Production project creation")
        var a=shape(vm.activeLayerID);a.points=[.init(x:40,y:48),.init(x:88,y:80)];a.width=2
        try require(vm.commitElement(a),"Actual shape creation")
        let original=vm.document, originalPixels=try render(original)
        let legacy=try JSONEncoder().encode(a)
        try require(!String(decoding:legacy,as:UTF8.self).contains("transform"),"Historical encoding gained transform")
        vm.selectedTool = .move;_ = vm.selectElement(at:CGPoint(x:64,y:64))
        vm.selectionScalePercent=200;vm.selectionRotationDegrees=90
        try require(vm.transformSelected(),"Real transform action")
        let transformed=vm.document, transformedPixels=try render(transformed)
        try require(transformed.schemaVersion==11 && transformed.revision==original.revision+1,"One schema11 revision")
        try require(channel(originalPixels,64,24)==0 && channel(transformedPixels,64,24)==255 && channel(transformedPixels,64,24,0)==255,"Actual scaled rotated geometry did not reach expected position")
        try require(channel(transformedPixels,24,64)==0,"Rotation applied around wrong center")
        try require(vm.selectionScalePercent==100 && vm.selectionRotationDegrees==0,"Applied controls not reset")
        var element=transformed.frames[0].elements[0];element.transform=nil
        try require(element==a,"Source geometry identity or styling was rewritten")
        let beforeReset=vm.document;vm.selectionScalePercent=300;vm.resetSelectionTransform()
        try require(vm.document==beforeReset,"Reset controls altered document/history")
        vm.undo()
        var undoExpected=original;undoExpected.revision=transformed.revision+1;undoExpected.modifiedAt=vm.document.modifiedAt
        try require(vm.document==undoExpected && render(vm.document)==originalPixels,"One Undo fails to restore full original with monotonic revision")
        vm.redo();try require(render(vm.document)==transformedPixels,"Redo changed transformed pixels")
        pass("historical encoding actual scale rotation pixels canonical metadata reset and one-step undo redo")

        let wide=try render(transformed,size:256,height:128)
        try require(channel(wide,128,24,width:256)==255 && channel(wide,48,64,width:256)==0,"Non-square viewport changes world-space rotation")
        vm.clearElementSelection();_ = vm.selectElement(at:CGPoint(x:64,y:24))
        try require(vm.selectedElementIDs==[a.id],"Transformed visible artwork cannot be selected")
        guard let move=vm.beginMove(at:CGPoint(x:64,y:24)) else {throw Failure(message:"Move capture after rotation")}
        let preview=try vm.movePreview(move,delta:CGSize(width:12,height:0));let beforeMove=vm.document
        var previewDocument=vm.document;previewDocument.frames[0]=preview
        try require(vm.document==beforeMove && vm.finishMove(move,delta:CGSize(width:12,height:0)),"Move preview mutated source or commit failed")
        try require(render(previewDocument)==render(vm.document),"Post-transform drag preview differs from actual Move")
        try require(channel(render(vm.document),76,24)==255,"Post-transform Move is not in document space")
        vm.undo();try require(render(vm.document)==transformedPixels,"Move Undo damaged transform")
        pass("non-square viewport transformed selection and world-space live Move match commit exactly")

        let saved=await vm.save();try require(saved,"Actual transform save")
        let reopened=StudioViewModel(storage:store);await reopened.loadProjects()
        guard let record=reopened.savedProjects.first else {throw Failure(message:"Saved project absent")}
        let opened=await reopened.openProject(record)
        try require(opened && reopened.document==vm.document,"Actual cold reopen lost transforms")
        let png=try await StudioExportService().export(document:reopened.document,format:.pngSequence,outputParent:root,background:.transparent)
        guard let source=CGImageSourceCreateWithURL(png.imageURLs[0] as CFURL,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil) else {throw Failure(message:"PNG cannot reopen")}
        try require(pixels(image)==transformedPixels,"Export changed saved transformed pixels")
        pass("production device save cold reopen and real decoded PNG match canvas pixels")
        try await actualMovie(reopened.document,reference:transformedPixels,root:root)

        var e=try StudioDocumentEditor(document:transformed)
        try e.reflectElements(frameID:transformed.activeFrameID,ids:[a.id],axis:.horizontal)
        try e.reflectElements(frameID:transformed.activeFrameID,ids:[a.id],axis:.horizontal)
        try require(render(e.document)==transformedPixels,"Double Flip after affine transform changed pixels")
        try e.copyElements(frameID:transformed.activeFrameID,ids:[a.id]);let pasted=try e.pasteElements(frameID:transformed.activeFrameID,layerID:transformed.activeLayerID)
        try require(pasted.count==1 && !pasted.contains(a.id) && e.document.frames[0].elements[1].transform==e.document.frames[0].elements[0].transform,"Element paste loses transform or identity")
        e.copyFrame();try e.pasteFrame()
        try require(e.document.frames[1].elements.map(\.transform)==e.document.frames[0].elements.map(\.transform),"Frame paste loses transforms")
        try e.duplicateLayer(transformed.activeLayerID)
        try require(e.document.frames.allSatisfy{$0.elements.count==4 && $0.elements[2].transform==$0.elements[0].transform},"Layer duplicate loses transforms")
        pass("flip composition and element frame layer copies retain editable transforms with fresh identities")

        var grouped=original
        var b=shape(grouped.activeLayerID);b.points=[.init(x:16,y:16),.init(x:24,y:24)]
        grouped.frames[0].elements.append(b)
        var group=try StudioDocumentEditor(document:grouped)
        try group.transformElements(frameID:grouped.activeFrameID,ids:[a.id,b.id],scaleX:1.5,scaleY:0.5,rotation:30)
        try require(group.document.frames[0].elements[0].transform==group.document.frames[0].elements[1].transform,"Group elements transformed around different centers")
        try require(render(group.document) != render(grouped),"Nonuniform group operation has no actual pixels")
        let otherLayer=CanvasLayer(id:"other-layer",name:"Untouched");grouped.layers.append(otherLayer)
        grouped.frames[0].elements[1].layerID=otherLayer.id
        var single=try StudioDocumentEditor(document:grouped)
        try single.transformElements(frameID:grouped.activeFrameID,ids:[a.id],scaleX:1.5,scaleY:0.5,rotation:30)
        try require(single.document.frames[0].elements[1]==grouped.frames[0].elements[1],"Transform changed unselected layer artwork")
        pass("group center nonuniform typed scale and unselected layer isolation")

        for family in StudioBrushFamily.allCases {
            var d=try document()
            let brush=DrawnElement(id:"brush",tool:.brush,points:[.init(x:24,y:32),.init(x:88,y:52)],color:"#FF0000",width:8,opacity:1,layerID:d.activeLayerID,brush:.init(family:family,seed:1234,gradientEndColor:family == .gradient ? .init(red:0,green:0,blue:1):nil))
            d.schemaVersion=2;d.frames[0].elements=[brush]
            let geometry=try StudioBrushGeometryCache.geometry(for:brush), before=try render(d)
            var editor=try StudioDocumentEditor(document:d)
            try editor.transformElements(frameID:d.activeFrameID,ids:[brush.id],scaleX:1.1,scaleY:0.9,rotation:35)
            let after=editor.document.frames[0].elements[0]
            try require(StudioBrushGeometryCache.geometry(for:after)==geometry && after.brush==brush.brush && after.points==brush.points,"Transform regenerated texture/samples")
            try require(render(editor.document) != before,"Brush transform has no pixel effect")
        }
        pass("all ten brush families preserve original seeded samples geometry and distinctive transformed pixels")

        let fillVM=StudioViewModel(storage:store);let madeFill=await fillVM.createProject(name:"Transformed sparse fill",width:128,height:128,fps:12);try require(madeFill,"Fill project")
        let spans=(40..<72).map{StudioFillMask.Span(row:$0,start:40,end:$0<48 ? 48:72,alpha:255)}
        let fill=DrawnElement(id:"fill",tool:.fill,points:[.init(x:40,y:40),.init(x:72,y:72)],color:"#FF0000",width:1,opacity:1,layerID:fillVM.activeLayerID,fillMask:.init(width:128,height:128,spans:spans))
        try require(fillVM.commitElement(fill),"Actual sparse fill")
        fillVM.selectedTool = .move;_ = fillVM.selectElement(at:CGPoint(x:44,y:44))
        fillVM.selectionScalePercent=150;fillVM.selectionRotationDegrees=90
        try require(fillVM.transformSelected(),"Sparse fill transform")
        guard let t=fillVM.currentFrame.elements[0].transform else {throw Failure(message:"Missing fill transform")}
        fillVM.clearElementSelection();_ = fillVM.selectElement(at:t.point(CGPoint(x:60,y:44)))
        try require(fillVM.selectedElementIDs.isEmpty,"Empty transformed coverage selected")
        _ = fillVM.selectElement(at:t.point(CGPoint(x:44,y:44)))
        try require(fillVM.selectedElementIDs==[fill.id] && fillVM.currentFrame.elements[0].fillMask==fill.fillMask,"Actual transformed coverage cannot be selected or source changed")
        pass("sparse fill inverse hit testing selects actual coverage while preserving original mask")

        var textDoc=original;textDoc.schemaVersion=10
        let text=DrawnElement(id:"text",tool:.text,points:[.init(x:24,y:40)],color:"#FF0000",width:1,opacity:1,layerID:textDoc.activeLayerID,text:.init(content:"SDI",style:.init(size:24,boxWidth:80,boxHeight:40)))
        textDoc.frames[0].elements=[text]
        var textEditor=try StudioDocumentEditor(document:textDoc)
        try textEditor.transformElements(frameID:textDoc.activeFrameID,ids:[text.id],scaleX:0.8,scaleY:1.2,rotation:30)
        try require(textEditor.document.frames[0].elements[0].text==text.text && render(textEditor.document) != render(textDoc),"Editable text was flattened or not transformed")
        pass("real editable text glyphs rotate and scale without rewriting typography or source content")

        for lock in ["full","position","alpha","hidden","transparent"] {
            var d=original
            if lock=="hidden" {d.layers[0].visible=false} else if lock=="transparent" {d.layers[0].opacity=0} else {d.layers[0].lockMode=lock}
            var editor=try StudioDocumentEditor(document:d)
            try rejects{try editor.transformElements(frameID:d.activeFrameID,ids:[a.id],scaleX:2,scaleY:2,rotation:90)}
            try require(editor.document==d && !editor.canUndo,"Locked transform changed history")
        }
        for triple in [(0.0,1.0,0.0),(1,11,0),(1,1,181),(Double.nan,1,0),(1,1,Double.infinity)] {
            var editor=try StudioDocumentEditor(document:original)
            try rejects{try editor.transformElements(frameID:original.activeFrameID,ids:[a.id],scaleX:triple.0,scaleY:triple.1,rotation:triple.2)}
            try require(editor.document==original && !editor.canUndo,"Invalid settings partially committed")
        }
        for bad in [StudioElementTransform(a:0),.init(a:65),.init(d:0.001),.init(tx:100001),.init(b:.infinity)] {
            var d=transformed;d.frames[0].elements[0].transform=bad;try rejects{try d.validate()}
        }
        var invalid=transformed;invalid.schemaVersion=10;try rejects{try invalid.validate()}
        var noOp=try StudioDocumentEditor(document:original)
        try noOp.transformElements(frameID:original.activeFrameID,ids:[a.id],scaleX:1,scaleY:1,rotation:0)
        try require(noOp.document==original && !noOp.canUndo,"Identity added history or schema migration")
        for ids:Set<String> in [[],["missing"],[a.id,"missing"]] {
            var editor=try StudioDocumentEditor(document:original)
            try rejects{try editor.transformElements(frameID:original.activeFrameID,ids:ids,scaleX:2,scaleY:2,rotation:90)}
            try require(editor.document==original && !editor.canUndo,"Invalid explicit selection altered document")
        }
        var offscreen=original
        offscreen.frames[0].elements[0].points=[.init(x:99000,y:99000),.init(x:99900,y:99900)]
        var oversized=try StudioDocumentEditor(document:offscreen)
        try rejects{try oversized.transformElements(frameID:offscreen.activeFrameID,ids:[a.id],scaleX:10,scaleY:10,rotation:0)}
        try require(oversized.document==offscreen && !oversized.canUndo,"Out-of-range result partially committed")
        pass("locks missing selections invalid matrix settings schema output bounds and identity operations preserve original history")

        var probe=try StudioDocumentEditor(document:grouped);var calls=0
        try probe.transformElements(frameID:grouped.activeFrameID,ids:[a.id,b.id],scaleX:1.1,scaleY:1.1,rotation:20,checkCancellation:{calls+=1})
        for stop in 1...calls {
            var editor=try StudioDocumentEditor(document:grouped);var count=0
            try rejects{try editor.transformElements(frameID:grouped.activeFrameID,ids:[a.id,b.id],scaleX:1.1,scaleY:1.1,rotation:20,checkCancellation:{count+=1;if count==stop {throw CancellationError()}})}
            try require(editor.document==grouped && !editor.canUndo,"Cancellation partially committed transform")
        }
        let wire=request(original,[transform(original,ids:[a.id])]);let encoded=try JSONEncoder().encode(wire)
        let decoded=try StudioCommandExecutor.decode(encoded);var commandEditor=try StudioDocumentEditor(document:original)
        _ = try StudioCommandExecutor.execute(decoded,editor:&commandEditor)
        try require(commandEditor.document.frames==transformed.frames,"Spatter and UI transform differently")
        let extra=String(decoding:encoded,as:UTF8.self).replacingOccurrences(of:"\"scaleX\":",with:"\"shell\":\"never\",\"scaleX\":")
        try rejects{_ = try StudioCommandExecutor.decode(Data(extra.utf8))}
        try rejects{_ = try StudioCommandExecutor.execute(decoded,editor:&commandEditor)}
        for commands in [[transform(original,ids:[a.id,a.id])],[transform(original,ids:[a.id]),transform(original,ids:["missing"])]] {
            var editor=try StudioDocumentEditor(document:original)
            try rejects{_ = try StudioCommandExecutor.execute(request(original,commands),editor:&editor)}
            try require(editor.document==original && !editor.canUndo,"Bad command batch partially committed")
        }
        reopened.clearElementSelection();let before=reopened.document
        try require(!reopened.transformSelected() && reopened.document==before,"No selection transformed last element")
        reopened.selectedTool = .move;_ = reopened.selectElement(at:CGPoint(x:64,y:24))
        let touch=UUID().uuidString;try require(reopened.beginStrokeInput(id:touch),"Active input setup")
        try require(!reopened.transformSelected() && reopened.document==before,"Transform during unfinished touch")
        reopened.finishStrokeInput(id:touch)
        pass("every cancellation checkpoint strict typed commands stale revisions atomic batches and live-input guards")
        print("StudioSelectionTransform: \(passed) groups passed")
    }
}
