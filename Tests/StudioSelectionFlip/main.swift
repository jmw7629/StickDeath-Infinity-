import AppKit
import SwiftUI
import ImageIO
import AVFoundation

typealias UIImage = NSImage
extension Image { init(uiImage: NSImage) { self.init(nsImage: uiImage) } }
private struct Failure: Error { let message: String }

@main @MainActor struct SelectionFlipTests {
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
    static func mirror(_ original: [UInt8], horizontal: Bool) -> [UInt8] {
        var result = original
        for y in 0..<128 { for x in 0..<128 { for c in 0..<4 {
            result[(y*128+x)*4+c] = original[((horizontal ? y : 127-y)*128+(horizontal ? 127-x : x))*4+c]
        } } }
        return result
    }
    /// Vector reflection rerasterizes edges; it is not a bitmap flip.
    /// Interior pixels must match exactly. Differences are confined to a
    /// one-pixel alpha edge, with bounded count and channel error.
    static func checkReflectedPixels(_ actual: [UInt8], _ expected: [UInt8]) throws {
        let differences=actual.indices.filter {actual[$0] != expected[$0]}
        var maxError=0
        for i in differences {
            let x=i/4%128, y=i/4/128
            maxError=max(maxError,abs(Int(actual[i])-Int(expected[i])))
            var alpha:Set<UInt8>=[]
            for dy in -1...1 {for dx in -1...1 where (0..<128).contains(x+dx) && (0..<128).contains(y+dy) {
                alpha.insert(expected[((y+dy)*128+x+dx)*4+3])
            }}
            try require(alpha.count>1,"Reflection changed an interior pixel")
        }
        print("REFLECTED_EDGE_DELTA channels=\(differences.count) max=\(maxError)")
        try require(differences.count<=64 && maxError<=64,"Reflection exceeds bounded one-pixel edge rasterization error")
    }
    static func actualReflectedMovie(_ horizontal: StudioDocument, secondReference: [UInt8], root: URL) async throws {
        var editor = try StudioDocumentEditor(document: horizontal)
        editor.copyFrame(); try editor.pasteFrame()
        let second = editor.document.frames[1]
        try editor.reflectElements(frameID: second.id, ids: Set(second.elements.map(\.id)), axis: .vertical)
        let snapshot = StudioMovieExportService.Snapshot(document: editor.document, retainedAudioTracks: [], rasterDataByID: [:])
        let output = try await StudioMovieExportService().export(snapshot: snapshot, outputParent: root, background: .white)
        let url = try output.checkedURLs()[0], asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        try require(tracks.count == 1, "Reflected movie must contain a real video track")
        let formats = try await tracks[0].load(.formatDescriptions)
        try require(formats.first.map { CMFormatDescriptionGetMediaSubType($0) } == kCMVideoCodecType_H264, "Reflected output must be actual H264")
        let audio = try await asset.loadTracks(withMediaType: .audio)
        try require(audio.isEmpty, "Animation-only reflection export unexpectedly added audio")
        let reader = try AVAssetReader(asset: asset)
        let video = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        reader.add(video); try require(reader.startReading(), "Actual reflected movie decoder starts")
        let references = [try render(horizontal), secondReference]
        var frames = 0
        while let sample = video.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            try require(frames < 2, "Reflected movie added an unexpected frame")
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { throw Failure(message:"Reflected movie has no decoded pixel buffer") }
            try require(CVPixelBufferGetWidth(buffer) == 128 && CVPixelBufferGetHeight(buffer) == 128, "Reflected movie changed canvas dimensions")
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let check: (Double, Bool, Bool, Bool) = try {
                defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
                guard let address = CVPixelBufferGetBaseAddress(buffer) else { throw Failure(message:"Reflected movie has no pixel bytes") }
                let bytes = address.assumingMemoryBound(to: UInt8.self), row = CVPixelBufferGetBytesPerRow(buffer)
                let reference = references[frames]
                var error = 0
                for y in 0..<128 { for x in 0..<128 {
                    let a = (y*128+x)*4, b = y*row+x*4, white = 255-Int(reference[a+3])
                    for channel in 0..<3 { error += abs(Int(bytes[b+2-channel]) - (Int(reference[a+channel])+white)) }
                } }
                let red = (frames == 0 ? 28 : 100)*row+100*4
                let blue = (frames == 0 ? 96 : 32)*row+32*4
                let oldPosition = 28*row+(frames == 0 ? 28 : 100)*4
                return (Double(error)/Double(128*128*3),
                    bytes[red+2] > 220 && bytes[red+1] < 30 && bytes[red] < 30,
                    bytes[blue] > 220 && bytes[blue+1] < 30 && bytes[blue+2] < 30,
                    bytes[oldPosition] > 230 && bytes[oldPosition+1] > 230 && bytes[oldPosition+2] > 230)
            }()
            print("FLIP_MP4_FRAME=\(frames) MEAN_RGB_ERROR=\(check.0)")
            try require(check.0 < 8 && check.1 && check.2 && check.3, "Actual encoded reflection, color and cleared original position differ from canonical artwork")
            try require(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), CMTime(value:Int64(frames),timescale:12)) == 0, "Reflected movie lost frame timing")
            frames += 1
        }
        let duration = try await asset.load(.duration)
        try require(reader.status == .completed && frames == 2 && CMTimeCompare(duration, CMTime(value:2,timescale:12)) == 0, "Complete reflected frames and rational duration")
        try require(output.manifest.frameIDs == editor.document.frames.map(\.id), "Movie receipt lost reflected frame identities")
        let bytes = try Data(contentsOf: url).count
        try require(bytes == output.manifest.encodedBytes && bytes > 0, "Reflected movie receipt does not match the real file")
        try output.cleanup(); try require(!FileManager.default.fileExists(atPath:url.path), "Reflected movie cleanup left owned output")
        print("FLIP_MP4_VERIFIED_BYTES=\(bytes)")
        pass("actual two-frame H264 reflection colors positions timing full decode and owned cleanup")
    }

    static func main() async throws {
        setbuf(stdout,nil)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("sdi-flip-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=DeviceStorageManager(documentsDirectory:root.appendingPathComponent("Documents"),cachesDirectory:root.appendingPathComponent("Cache"))
        let vm=StudioViewModel(storage:store)
        let made=await vm.createProject(name:"Editable reflection",width:128,height:128,fps:12)
        try require(made,"Actual project creation")
        var a=shape(vm.activeLayerID);a.points=[.init(x:16,y:16),.init(x:40,y:40)];a.width=2
        var b=shape(vm.activeLayerID);b.points=[.init(x:80,y:80),.init(x:112,y:112)];b.width=2;b.color="#0000FF";b.shape?.fillColor="#0000FF"
        try require(vm.commitElement(a) && vm.commitElement(b),"Actual artwork commits")
        let original=vm.document, originalPixels=try render(original)
        let legacy=try JSONEncoder().encode(a)
        try require(!String(decoding:legacy,as:UTF8.self).contains("reflection"),"Historical encoding changed")
        try require(JSONDecoder().decode(DrawnElement.self,from:legacy)==a,"Historical element decoding")
        vm.selectedTool = .move;vm.selectionMode = .new;_ = vm.selectElement(at:CGPoint(x:28,y:28))
        vm.selectionMode = .add;_ = vm.selectElement(at:CGPoint(x:96,y:96))
        try require(vm.selectedElementIDs==[a.id,b.id],"Real group selection")
        try require(vm.reflectSelected(axis:.horizontal),"Actual Flip H")
        try require(vm.message == nil,"Flip introduced a canvas-resizing success banner")
        let horizontal=vm.document, hPixels=try render(horizontal)
        try checkReflectedPixels(hPixels,mirror(originalPixels,horizontal:true))
        try require(horizontal.schemaVersion==8 && horizontal.revision==original.revision+1,"One schema8 revision")
        try require(horizontal.frames[0].elements.map(\.points)==original.frames[0].elements.map(\.points),"Flip rewrote original points")
        vm.undo();try require(render(vm.document)==originalPixels && vm.document.schemaVersion==5,"One Undo restores exact original")
        vm.redo();try require(render(vm.document)==hPixels,"Redo changed reflection")
        pass("historical encoding, group reflection pixels and one-step full-document undo redo")

        vm.selectionMode = .new;_ = vm.selectElement(at:CGPoint(x:100,y:28));vm.selectionMode = .add;_ = vm.selectElement(at:CGPoint(x:32,y:96))
        try require(vm.selectedElementIDs==[a.id,b.id],"Reflected bounds do not select real artwork")
        vm.message = "Existing save error"
        try require(vm.reflectSelected(axis:.vertical),"Actual Flip V")
        try require(vm.message == "Existing save error","Flip replaced an existing error")
        vm.message = nil
        let both=vm.document, bothPixels=try render(both)
        try checkReflectedPixels(bothPixels,mirror(hPixels,horizontal:false))
        let saved=await vm.save();try require(saved,"Actual reflection save")
        let reopened=StudioViewModel(storage:store);await reopened.loadProjects()
        guard let record=reopened.savedProjects.first else {throw Failure(message:"Saved reflection missing")}
        let opened=await reopened.openProject(record);try require(opened && reopened.document==both,"Actual cold reopen changed reflected metadata")
        let output=try await StudioExportService().export(document:reopened.document,format:.pngSequence,outputParent:root,background:.transparent)
        guard let source=CGImageSourceCreateWithURL(output.imageURLs[0] as CFURL,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil) else {throw Failure(message:"Real PNG decode")}
        try require(pixels(image)==bothPixels,"Export did not use same reflection renderer")
        pass("vertical reflection, real hit selection, production save cold reopen and decoded PNG")
        try await actualReflectedMovie(horizontal, secondReference: bothPixels, root: root)

        var editor=try StudioDocumentEditor(document:both)
        try editor.reflectElements(frameID:both.activeFrameID,ids:[a.id,b.id],axis:.horizontal)
        try editor.reflectElements(frameID:both.activeFrameID,ids:[a.id,b.id],axis:.vertical)
        try require(editor.document.frames[0].elements==original.frames[0].elements,"Double reflection fails to restore original samples or metadata")
        try require(render(editor.document)==originalPixels,"Double reflection changes original pixels")
        var copy=try StudioDocumentEditor(document:both);copy.copyFrame()
        try copy.pasteFrame();try require(copy.document.frames[1].elements.map(\.reflection)==both.frames[0].elements.map(\.reflection),"Frame clipboard loses reflection")
        try copy.duplicateLayer(both.activeLayerID)
        try require(copy.document.frames[1].elements.count==4 && copy.document.frames[1].elements[2].reflection==both.frames[0].elements[0].reflection,"Layer duplication loses reflection")
        pass("double flip restores originals and frame clipboard layer duplication preserve transforms")

        var shifted=try StudioDocumentEditor(document:original)
        try shifted.translateElements(frameID:original.activeFrameID,ids:[a.id,b.id],dx:-4,dy:6)
        let shiftedDoc=shifted.document, shiftedPixels=try render(shiftedDoc)
        try shifted.reflectElements(frameID:original.activeFrameID,ids:[a.id,b.id],axis:.horizontal)
        try shifted.translateElements(frameID:original.activeFrameID,ids:[a.id,b.id],dx:4,dy:-6)
        try require(render(shifted.document)==hPixels,"Reflection around translated group center is wrong")
        shifted.undo();shifted.undo();try require(render(shifted.document)==shiftedPixels,"Move plus Flip undo chain lost content")
        pass("existing translation and reflection compose in document space and reverse exactly")

        let fillVM=StudioViewModel(storage:store);let madeFill=await fillVM.createProject(name:"Reflected fill",width:128,height:128,fps:12);try require(madeFill,"Fill project")
        let spans=(16..<40).map {StudioFillMask.Span(row:$0,start:16,end:$0<24 ? 24:40,alpha:255)}
        let fill=DrawnElement(id:"L-fill",tool:.fill,points:[.init(x:16,y:16),.init(x:40,y:40)],color:"#FF0000",width:1,opacity:1,layerID:fillVM.activeLayerID,fillMask:.init(width:128,height:128,spans:spans))
        try require(fillVM.commitElement(fill),"Actual sparse fill commit")
        fillVM.selectedTool = .move;_ = fillVM.selectElement(at:CGPoint(x:20,y:20))
        try require(fillVM.reflectSelected(axis:.horizontal),"Sparse fill Flip H")
        let filled=try render(fillVM.document)
        try require(channel(filled,36,20)==255 && channel(filled,20,20)==0,"Asymmetric fill coverage did not reflect")
        try require(fillVM.currentFrame.elements[0].fillMask==fill.fillMask,"Flip rewrote sparse fill coverage")
        fillVM.clearElementSelection();_ = fillVM.selectElement(at:CGPoint(x:20,y:20));try require(fillVM.selectedElementIDs.isEmpty,"Empty reflected coverage selected")
        _ = fillVM.selectElement(at:CGPoint(x:36,y:20));try require(fillVM.selectedElementIDs==[fill.id],"Real reflected coverage cannot be selected")
        guard let move=fillVM.beginMove(at:CGPoint(x:36,y:20)) else {throw Failure(message:"Reflected fill Move capture")}
        try require(fillVM.finishMove(move,delta:CGSize(width:20,height:0)),"Moving reflected fill")
        try require(channel(render(fillVM.document),56,20)==255 && channel(render(fillVM.document),36,20)==0,"Reflected fill movement pixels")
        pass("sparse fill reflection preserves coverage and inverse hit testing supports subsequent Move")

        for family in StudioBrushFamily.allCases {
            var d=try document()
            let stroke=DrawnElement(id:"brush-"+family.rawValue,tool:.brush,points:[.init(x:16,y:24),.init(x:72,y:44)],color:"#FF0000",width:8,opacity:1,layerID:d.activeLayerID,brush:.init(family:family,seed:1234,gradientEndColor:family == .gradient ? .init(red:0,green:0,blue:1):nil))
            d.frames[0].elements=[stroke];d.schemaVersion=2
            var e=try StudioDocumentEditor(document:d);let geometry=try StudioBrushGeometryCache.geometry(for:stroke), before=try render(d)
            try e.reflectElements(frameID:d.activeFrameID,ids:[stroke.id],axis:.horizontal)
            try require(StudioBrushGeometryCache.geometry(for:e.document.frames[0].elements[0])==geometry,"Flip regenerated brush texture")
            try require(render(e.document) != before,"Asymmetric brush failed to reflect")
            try e.reflectElements(frameID:d.activeFrameID,ids:[stroke.id],axis:.horizontal)
            try require(e.document.frames[0].elements[0]==stroke && render(e.document)==before,"Double Flip altered brush bytes or pixels")
        }
        pass("all ten brush families retain original geometry texture and exact double-flip pixels")

        for mode in ["full","position","alpha","hidden","transparent"] {
            var d=original
            if mode=="hidden" {d.layers[0].visible=false} else if mode=="transparent" {d.layers[0].opacity=0} else {d.layers[0].lockMode=mode}
            var e=try StudioDocumentEditor(document:d)
            try rejects {try e.reflectElements(frameID:d.activeFrameID,ids:[a.id,b.id],axis:.horizontal)}
            try require(e.document==d && !e.canUndo,"Locked reflection changed history")
        }
        for ids:Set<String> in [[],["missing"],[a.id,"missing"]] {
            var e=try StudioDocumentEditor(document:original)
            try rejects {try e.reflectElements(frameID:original.activeFrameID,ids:ids,axis:.vertical)}
            try require(e.document==original && !e.canUndo,"Invalid selection partially reflected")
        }
        var invalid=both;invalid.schemaVersion=7;try rejects {try invalid.validate()}
        invalid=both;invalid.frames[0].elements[0].reflection = .init();try rejects {try invalid.validate()}
        pass("locked invisible invalid selection schema and empty reflection gates preserve data")

        var probe=try StudioDocumentEditor(document:original);var calls=0
        try probe.reflectElements(frameID:original.activeFrameID,ids:[a.id,b.id],axis:.horizontal,checkCancellation:{calls+=1})
        for stop in 1...calls {
            var e=try StudioDocumentEditor(document:original);var count=0
            try rejects {try e.reflectElements(frameID:original.activeFrameID,ids:[a.id,b.id],axis:.horizontal,checkCancellation:{count+=1;if count==stop{throw CancellationError()}})}
            try require(e.document==original && !e.canUndo,"Cancelled flip partially changed document or history")
        }
        let request=StudioCommandRequest(requestID:UUID(),projectID:original.id,expectedRevision:original.revision,action:.apply([.reflectElements(.init(frame:.id(original.activeFrameID),elementIDs:[a.id,b.id],axis:.horizontal))]))
        let bytes=try JSONEncoder().encode(request);let decoded=try StudioCommandExecutor.decode(bytes)
        var wire=try StudioDocumentEditor(document:original);_ = try StudioCommandExecutor.execute(decoded,editor:&wire)
        try require(wire.document.frames==horizontal.frames,"Typed command and UI differ")
        let invalidAxis=String(decoding:bytes,as:UTF8.self).replacingOccurrences(of:"horizontal",with:"diagonal")
        try rejects {_ = try StudioCommandExecutor.decode(Data(invalidAxis.utf8))}
        let extraKey=String(decoding:bytes,as:UTF8.self).replacingOccurrences(of:"\"axis\":",with:"\"shell\":\"never\",\"axis\":")
        try rejects {_ = try StudioCommandExecutor.decode(Data(extraKey.utf8))}
        for commands:[StudioCommand] in [
            [.reflectElements(.init(frame:.id(original.activeFrameID),elementIDs:[a.id,a.id],axis:.horizontal))],
            [.reflectElements(.init(frame:.id(original.activeFrameID),elementIDs:[a.id],axis:.horizontal)),.reflectElements(.init(frame:.id(original.activeFrameID),elementIDs:["missing"],axis:.vertical))]
        ] {
            var e=try StudioDocumentEditor(document:original)
            try rejects {_ = try StudioCommandExecutor.execute(.init(requestID:UUID(),projectID:original.id,expectedRevision:original.revision,action:.apply(commands)),editor:&e)}
            try require(e.document==original && !e.canUndo,"Invalid batch partially flipped artwork")
        }
        try rejects {_ = try StudioCommandExecutor.execute(decoded,editor:&wire)}
        pass("every cancellation checkpoint, strict wire axis keys duplicates stale state and batch rollback")
        reopened.clearElementSelection();let before=reopened.document
        try require(!reopened.reflectSelected(axis:.horizontal) && reopened.document==before,"Missing selection silently flipped last element")
        reopened.selectedTool = .move;_ = reopened.selectElement(at:CGPoint(x:100,y:100))
        let touch=UUID().uuidString;try require(reopened.beginStrokeInput(id:touch),"Input guard setup")
        try require(!reopened.reflectSelected(axis:.vertical) && reopened.document==before,"Active input allowed Flip")
        reopened.finishStrokeInput(id:touch)
        pass("visible Flip action rejects empty selection and unfinished touch")
        print("StudioSelectionFlip: \(passed) groups passed")
    }
}
