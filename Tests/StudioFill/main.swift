import AppKit
import SwiftUI
import ImageIO
import AVFoundation

typealias UIImage = NSImage
extension Image { init(uiImage: NSImage) { self.init(nsImage: uiImage) } }
private struct Failure: Error { let message: String }

@main @MainActor struct FillIntegrationTests {
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
    static let hard = StudioFillRegion.Settings(tolerance: 0, antiAlias: false)
    static func capture(_ d: StudioDocument, _ settings: StudioFillRegion.Settings = .init(tolerance: 0, antiAlias: false),
                        all: Bool = false, point: CGPoint = CGPoint(x: 64, y: 48),
                        opacity: Double = 1, raster: Data? = nil) throws -> StudioFillService.Capture {
        try StudioFillService.capture(document: d, frameID: d.activeFrameID, layerID: d.activeLayerID,
            point: point, color: "#0000FF", opacity: opacity, settings: settings,
            sampleAllLayers: all, rasterData: raster)
    }
    static func outlined() throws -> StudioDocument {
        var d = try document(shape("x", fill: nil))
        d.frames[0].elements[0].points = [.init(x: 16,y: 12), .init(x: 112,y: 84)]
        return d
    }
    static func filled(_ d: StudioDocument, _ settings: StudioFillRegion.Settings = .init(tolerance: 0, antiAlias: false),
                       all: Bool = false, opacity: Double = 1) throws -> StudioDocument {
        var e = try StudioDocumentEditor(document: d)
        try e.commit(StudioFillService.element(from: capture(d, settings, all: all, opacity: opacity)), frameID: d.activeFrameID)
        return e.document
    }
    static func maskPixels(_ element: DrawnElement) -> Int {
        element.fillMask!.spans.reduce(0) { $0 + $1.end - $1.start }
    }
    static func actualEnclosure() throws {
        let d = try outlined(), original = try render(d), c = try capture(d)
        try require(c.rgba.count == 128 * 128 * 4 && c.projectID == d.id && c.revision == d.revision,
                    "Immutable actual artwork capture")
        let element = try StudioFillService.element(from: c)
        try require(element.fillMask!.spans.first!.row >= 16 && element.fillMask!.spans.last!.row < 81,
                    "Top-left asymmetric outline encloses actual region, not its vertical reflection")
        let result = try filled(d), image = try render(result)
        try require(result.schemaVersion == 6 && result.frames[0].elements.count == 2, "Canonical region commits")
        try require(channel(image,64,48,2) == 255 && channel(image,64,48) == 255, "Actual blue fill interior")
        try require(channel(image,64,106) == 0 && channel(image,4,4) == 0, "Outside remains transparent")
        try require(channel(image,16,48,0) == 255 && original == render(d), "Existing red boundary and source unchanged")
        let pickedFill = try StudioColorSamplingService.sample(document: result, frameID: result.activeFrameID,
            point: CGPoint(x:64,y:48))
        let pickedOutside = try StudioColorSamplingService.sample(document: result, frameID: result.activeFrameID,
            point: CGPoint(x:64,y:106))
        try require(pickedFill.hex == "#0000FF" && pickedOutside.hex == "#FFFFFF",
                    "Actual eyedropper samples the fill while preserving the exterior canvas")
        pass("actual asymmetric artwork capture, enclosed fill pixels and immutable source")
    }
    static func samplingModes() throws {
        var d = try outlined()
        let target = CanvasLayer(id: UUID().uuidString, name: "Fill layer")
        d.layers.insert(target, at: 0); d.activeLayerID = target.id
        let own = try StudioFillService.element(from: capture(d)), all = try StudioFillService.element(from: capture(d, all: true))
        try require(maskPixels(own) == 128 * 128 && maskPixels(all) < 7000, "Current vs visible composite changes real operation")
        var similar = hard; similar.contiguous = false
        let disconnected = try StudioFillService.element(from: capture(d, similar, all: true))
        try require(maskPixels(disconnected) > maskPixels(all) + 4000, "All Similar reaches disconnected visible white regions")
        let c = try capture(d), ca = try capture(d, all: true)
        try require(c.rgba[3] == 0 && ca.rgba[3] == 255, "Current transparent and all-layer white compositing")
        d.layers[1].visible = false
        try require(maskPixels(StudioFillService.element(from: capture(d, all: true))) == 128 * 128, "Hidden boundaries are excluded")
        pass("current layer, all visible layers, all-similar and visibility affect actual regions")
    }
    static func coverageAndOpacity() throws {
        let d = try outlined(), base = try StudioFillService.element(from: capture(d))
        var expansion = hard; expansion.expand = 2
        let expanded = try StudioFillService.element(from: capture(d, expansion))
        var shrink = hard; shrink.expand = -2
        let shrunken = try StudioFillService.element(from: capture(d, shrink))
        try require(maskPixels(expanded) > maskPixels(base) && maskPixels(shrunken) < maskPixels(base), "Actual expand and shrink")
        var aa = hard; aa.antiAlias = true
        let softened = try StudioFillService.element(from: capture(d, aa))
        try require(softened.fillMask!.spans.contains { $0.alpha > 0 && $0.alpha < 255 }, "Real partial edge coverage")
        var partial = try filled(d, opacity: 0.5)
        let image = try render(partial)
        try require((127...128).contains(channel(image,64,48)) && channel(image,64,48,2) == channel(image,64,48), "Opacity applied once to real fill")
        partial.layers[0].opacity = 0.5
        try require((63...64).contains(channel(render(partial),64,48)), "Layer opacity composes once")
        partial.layers[0].visible = false
        try require(render(partial).allSatisfy { $0 == 0 }, "Hidden fill layer renders no pixels")
        pass("expansion, shrink, real antialias coverage, element and layer opacity")
    }
    static func historyAndArchive() throws {
        let d = try document()
        let element = try StudioFillService.element(from: capture(d))
        var editor = try StudioDocumentEditor(document: d)
        try editor.commit(element, frameID: d.activeFrameID)
        let first = editor.document
        editor.copyFrame(); editor.undo()
        try require(editor.document.schemaVersion == 1 && editor.document.frames[0].elements.isEmpty, "Full undo restores original schema/document")
        try editor.pasteFrame()
        try require(editor.document.schemaVersion == 6 && editor.document.frames[1].elements[0].fillMask == element.fillMask,
                    "Clipboard crossing undo restores region and supported version")
        try require(editor.document.frames[1].elements[0].id != element.id, "Copied IDs stay unique")
        let encoded = try StudioDocumentArchive(document: editor.document, rasterFrameIndices: [:]).encoded()
        let restored = try StudioDocumentArchive.decode(encoded)
        try require(restored.document == editor.document, "Actual canonical archive retains exact coverage")
        editor.undo(); editor.redo()
        try require(editor.document.frames[1].elements[0].fillMask == first.frames[0].elements[0].fillMask, "Redo retains immutable fill")
        let old = try JSONEncoder().encode(d.frames[0])
        try require(!String(decoding: old, as: UTF8.self).contains("fillMask"), "Historical frame encoding unchanged")
        pass("schema6 canonical archive, undo/redo and copied-frame crossing old schema")
    }
    static func invalidCoverage() throws {
        let d = try filled(document()), good = d.frames[0].elements[0].fillMask!
        var bad = good; bad.version = 2
        try rejects { try bad.validate() }
        for spans: [StudioFillMask.Span] in [[], [.init(row: 0,start: 3,end: 2,alpha: 255)],
            [.init(row: 128,start: 0,end: 1,alpha: 255)], [.init(row: 0,start: 0,end: 129,alpha: 255)],
            [.init(row: 0,start: 0,end: 1,alpha: 0)], [.init(row: 0,start: 0,end: 3,alpha: 255),.init(row: 0,start: 2,end: 4,alpha: 128)],
            [.init(row: 1,start: 0,end: 1,alpha: 255),.init(row: 0,start: 0,end: 1,alpha: 255)],
            [.init(row: 0,start: 0,end: 1,alpha: 255),.init(row: 0,start: 1,end: 2,alpha: 255)]] {
            var mask = good; mask.spans = spans; try rejects { try mask.validate() }
        }
        var wrong = d; wrong.schemaVersion = 5; try rejects { try wrong.validate() }
        wrong = d; wrong.frames[0].elements[0].tool = .brush; try rejects { try wrong.validate() }
        wrong = d; wrong.width = 256; try rejects { try wrong.validate() }
        wrong = d; wrong.frames[0].elements[0].color = "bad-color"; try rejects { try wrong.validate() }
        var editor = try StudioDocumentEditor(document: d)
        let before = editor.document
        var invalid = try StudioFillService.element(from: capture(document())); invalid.layerID = d.activeLayerID; invalid.fillMask = bad
        try rejects { try editor.commit(invalid, frameID: d.activeFrameID) }
        try require(editor.document == before && !editor.canUndo, "Invalid coverage never mutates document/history")
        pass("invalid versions, geometry, overlap, order, color and schema reject transactionally")
    }
    static func captureGuards() throws {
        var d = try document()
        for point in [CGPoint(x: -1,y: 0), CGPoint(x: 128,y: 0), CGPoint(x: CGFloat.infinity,y: 0)] {
            try rejects { _ = try capture(d, point: point) }
        }
        var settings = hard; settings.expand = 6
        try rejects { _ = try capture(d,settings) }
        for mode in ["full", "alpha", "unknown"] {
            d.layers[0].lockMode = mode
            try rejects { _ = try capture(d) }
        }
        d.layers[0].lockMode = "free"; d.layers[0].visible = false
        try rejects { _ = try capture(d) }
        d.layers[0].visible = true; d.width = 4096; d.height = 4096
        try rejects { _ = try capture(d) }
        d = try document(); d.frames[0].rasterAssetID = "missing"; d.frames[0].rasterLayerID = d.activeLayerID
        try rejects { _ = try capture(d) }
        pass("outside input, invalid settings, locks, hidden target, pixel bound and missing image reject")
    }
    static func storageAndPNG() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-fill-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DeviceStorageManager(documentsDirectory: root.appendingPathComponent("Documents"),
            cachesDirectory: root.appendingPathComponent("Cache"))
        let vm = StudioViewModel(storage: store)
        let created = await vm.createProject(name: "Saved real fill", width: 128, height: 128, fps: 12)
        try require(created, "Actual VM creates project")
        let id = vm.document.id
        let element = try StudioFillService.element(from: capture(vm.document))
        try require(vm.commitElement(element), "Actual VM accepts canonical fill")
        let saved = await vm.save(); try require(saved, "Actual VM saves fill")
        let expected = vm.document
        let reopened = StudioViewModel(storage: store)
        await reopened.loadProjects()
        guard let metadata = reopened.savedProjects.first(where: { $0.id == id }) else {
            throw Failure(message: "Actual project list contains fill")
        }
        let opened = await reopened.openProject(metadata); try require(opened, "Actual cold reopen")
        try require(reopened.document == expected, "Actual VM cold reopen retains exact fill")
        let rendered = try render(reopened.document)
        let out = try await StudioExportService().export(document: reopened.document,
            format: .pngSequence, outputParent: root, background: .transparent)
        let bytes = try Data(contentsOf: out.imageURLs[0])
        guard let source = CGImageSourceCreateWithData(bytes as CFData,nil), let image = CGImageSourceCreateImageAtIndex(source,0,nil) else {
            throw Failure(message: "Actual PNG file must reopen")
        }
        try require(pixels(image) == rendered && channel(rendered,64,64,2) == 255, "Saved fill matches actual decoded PNG exactly")
        pass("actual production VM create/save/list/cold reopen and decoded PNG equality")
    }
    static func aggregateBudgetAndLayerCopy() throws {
        var d = try StudioDocument.new(name: "Coverage bounds", width: 1024, height: 128, fps: 12)
        var spans: [StudioFillMask.Span] = []
        for row in 0..<128 { for x in stride(from: 0, to: 1024, by: 2) {
            spans.append(.init(row: row,start: x,end: x+1,alpha: 255))
        } }
        let mask = StudioFillMask(width: 1024,height: 128,spans: spans)
        try mask.validate(); try require(spans.count == StudioFillMask.maximumSpans, "Actual admitted per-fill boundary")
        var oversized = mask; oversized.spans.append(.init(row: 127,start: 1023,end: 1024,alpha: 255))
        try rejects { try oversized.validate() }
        var editor = try StudioDocumentEditor(document: d)
        for _ in 0..<4 {
            let element = DrawnElement(id: UUID().uuidString,tool: .fill,points: [.init(x: 0,y: 0),.init(x: 1024,y: 128)],
                color: "#0000FF",width: 1,opacity: 1,layerID: d.activeLayerID,fillMask: mask)
            try editor.commit(element,frameID: d.activeFrameID)
        }
        d = editor.document
        let extra = DrawnElement(id: UUID().uuidString,tool: .fill,points: [.init(x: 0,y: 0),.init(x: 1024,y: 128)],
            color: "#0000FF",width: 1,opacity: 1,layerID: d.activeLayerID,fillMask: mask)
        try rejects { try editor.commit(extra,frameID: d.activeFrameID) }
        try require(editor.document == d, "Document-wide span limit fails before mutation")
        try rejects { try editor.duplicateLayer(d.activeLayerID) }
        try require(editor.document == d, "Layer copying cannot exceed total region budget")
        var small = try StudioDocumentEditor(document: filled(document()))
        let original = small.document.frames[0].elements[0]
        try small.duplicateLayer(small.document.activeLayerID)
        let copy = small.document.frames[0].elements[1]
        try require(copy.fillMask == original.fillMask && copy.id != original.id && copy.layerID != original.layerID,
                    "Layer copy retains coverage with separate stable identities")
        let encoded = try StudioDocumentArchive(document: d,rasterFrameIndices: [:]).encoded()
        try require(encoded.count < 32*1024*1024, "Admitted maximum coverage fits real archive bound")
        pass("actual per-fill and document-wide span limits, bounded archive and unique layer copies")
    }
    static func actualMovie() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-fill-movie-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let d = try filled(outlined()), reference = try render(d)
        let snapshot = StudioMovieExportService.Snapshot(document: d,retainedAudioTracks: [],rasterDataByID: [:])
        let output = try await StudioMovieExportService().export(snapshot: snapshot,outputParent: root,background: .white)
        let url = try output.checkedURLs()[0], asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        try require(tracks.count == 1,"Actual fill movie track")
        let reader = try AVAssetReader(asset: asset)
        let video = AVAssetReaderTrackOutput(track: tracks[0],outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        reader.add(video); try require(reader.startReading(),"Actual H264 decoder starts")
        var frames = 0
        while let sample = video.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { throw Failure(message:"Fill movie pixel buffer") }
            try require(CVPixelBufferGetWidth(buffer)==128 && CVPixelBufferGetHeight(buffer)==128,"Actual movie dimensions")
            CVPixelBufferLockBaseAddress(buffer,.readOnly)
            guard let pointer = CVPixelBufferGetBaseAddress(buffer) else { throw Failure(message:"Fill movie buffer bytes") }
            let bytes = pointer.assumingMemoryBound(to: UInt8.self), row = CVPixelBufferGetBytesPerRow(buffer)
            var error = 0
            for y in 0..<128 { for x in 0..<128 {
                let a = (y*128+x)*4, b = y*row+x*4, white = 255-Int(reference[a+3])
                for channel in 0..<3 { error += abs(Int(bytes[b+2-channel]) - (Int(reference[a+channel])+white)) }
            } }
            let interior = 48*row+64*4, exterior = 106*row+64*4
            let blue = bytes[interior] > 220 && bytes[interior+1] < 30 && bytes[interior+2] < 30
            let outside = bytes[exterior] > 230 && bytes[exterior+1] > 230 && bytes[exterior+2] > 230
            CVPixelBufferUnlockBaseAddress(buffer,.readOnly)
            let mean = Double(error)/Double(128*128*3)
            print("FILL_MP4_MEAN_RGB_ERROR=\(mean)")
            try require(mean < 8 && blue && outside,"Actual encoded fill and outside match canonical pixels")
            try require(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample),.zero)==0,"Actual fill PTS")
            frames += 1
        }
        let duration = try await asset.load(.duration)
        try require(reader.status == .completed && frames == 1 && CMTimeCompare(duration,CMTime(value:1,timescale:12))==0,
                    "Complete actual H264 frame and rational duration")
        try output.cleanup()
        pass("actual H264 fill pixels, outside region, full decode, timing and owned cleanup")
    }
    static func rasterAndCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-fill-raster-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let outlined = try outlined()
        let exported = try await StudioExportService().export(document: outlined,format: .pngSequence,outputParent: root,background: .transparent)
        let png = try Data(contentsOf: exported.imageURLs[0])
        var d = try document(); d.schemaVersion = 3
        d.frames[0].rasterAssetID = "original-png"; d.frames[0].rasterLayerID = d.activeLayerID
        let actual = try StudioFillService.element(from: capture(d,raster: png))
        let vector = try StudioFillService.element(from: capture(outlined))
        try require(actual.fillMask == vector.fillMask,"Actual decoded image boundary yields same region as original vector")
        let c = try capture(outlined)
        let cancelled = Task { @MainActor in try StudioFillService.element(from: c) }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw Failure(message:"Cancelled region succeeded") }
        catch is CancellationError { }
        let cancelCapture = Task { @MainActor in try capture(outlined) }
        cancelCapture.cancel()
        do { _ = try await cancelCapture.value; throw Failure(message:"Cancelled capture succeeded") }
        catch is CancellationError { }
        try require(png == Data(contentsOf: exported.imageURLs[0]),"Original actual PNG survives cancelled computation")
        pass("actual PNG boundary sampling and real Task cancellation preserve source")
    }
    static func sessionAndGestures() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-fill-session-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = DeviceStorageManager(documentsDirectory: root.appendingPathComponent("Documents"),cachesDirectory: root.appendingPathComponent("Cache"))
        let vm = StudioViewModel(storage: storage), session = StudioFillSession()
        let created = await vm.createProject(name:"Fill session",width:128,height:128,fps:12)
        // The existing non-UIKit VM color projection is red. Arbitrary-color
        // sampling/rendering is tested above with actual service inputs; native
        // UIKit palette-to-fill behavior requires the real iOS journey.
        try require(created,"Real session project"); vm.selectedTool = .fill; vm.strokeColor = .red
        vm.fillAntiAlias = false
        guard let context = StudioFillContext.current(vm) else { throw Failure(message:"Available fill context") }
        let layout = StudioFillGesture.Layout(viewport:CGSize(width:256,height:256),scale:2,offset:CGSize(width:20,height:4))
        var gesture = StudioFillGesture()
        gesture.update(context:context,layout:layout,foreground:true)
        let target = gesture.resolve(location:CGPoint(x:128,y:128),context:context,layout:layout,foreground:true)
        try require(target?.point == CGPoint(x:64,y:64),"Local gesture coordinates map to document without double applying zoom/pan")
        var cancelled = gesture
        cancelled.update(context:nil,layout:layout,foreground:true)
        cancelled.update(context:context,layout:layout,foreground:true)
        try require(cancelled.startedAsFill && cancelled.resolve(location:.zero,context:context,layout:layout,foreground:true)==nil,
                    "Context interruption cannot recover within one touch")
        var observedChange = gesture
        observedChange.invalidate()
        observedChange.update(context:context,layout:layout,foreground:true)
        try require(observedChange.resolve(location:.zero,context:context,layout:layout,foreground:true)==nil,
                    "A settings or layout change observed between touch events cannot recover")
        var unavailable = StudioFillGesture()
        unavailable.update(context:nil,layout:layout,foreground:true)
        unavailable.update(context:context,layout:layout,foreground:true)
        try require(!unavailable.startedAsFill && unavailable.resolve(location:.zero,context:context,layout:layout,foreground:true)==nil,
                    "Unavailable initial touch never becomes a later fill")
        let changedLayout = StudioFillGesture.Layout(viewport:CGSize(width:240,height:256),scale:2,offset:layout.offset)
        gesture.update(context:context,layout:changedLayout,foreground:true)
        gesture.update(context:context,layout:layout,foreground:true)
        try require(gesture.resolve(location:.zero,context:context,layout:layout,foreground:true)==nil,"Viewport interruption remains cancelled")
        pass("actual fill touch context, viewport mapping and permanent interruption guards")

        let committed = await session.fill(vm,context:context,point:CGPoint(x:64,y:64))
        try require(committed && !session.isFilling && vm.activeStrokeID==nil && vm.canUndo,"Real background fill releases editor lease and enables undo")
        try require(context.color == "#FF0000" && vm.currentFrame.elements.count==1 && channel(render(vm.document),64,64,0)==255,
                    "Session commits actual captured red coverage")
        let filled = vm.document; vm.undo()
        try require(vm.currentFrame.elements.isEmpty,"One full-document undo removes region")
        vm.redo(); try require(vm.currentFrame.elements==filled.frames[0].elements,"Redo restores identical region")
        let saved = await vm.save();try require(saved,"Session result actually persists")
        let before = vm.document
        let stale = await session.fill(vm,context:context,point:CGPoint(x:64,y:64))
        try require(!stale && vm.document==before && vm.activeStrokeID==nil,"Old captured revision cannot add another fill")
        pass("real background session, transactional VM commit, undo/redo/save and stale revision rejection")

        let large = StudioViewModel(storage:storage)
        let madeLarge = await large.createProject(name:"Cancel real fill",width:2048,height:1024,fps:12)
        try require(madeLarge,"Large actual cancellation project");large.selectedTool = .fill
        guard let largeContext=StudioFillContext.current(large) else { throw Failure(message:"Large context") }
        let original = large.document
        let task = Task { @MainActor in await session.fill(large,context:largeContext,point:CGPoint(x:500,y:500)) }
        let deadline = Date().addingTimeInterval(10)
        while !session.isFilling && Date()<deadline { await Task.yield() }
        try require(session.isFilling && large.activeStrokeID != nil,"Actual worker entered owned in-flight phase")
        session.cancel()
        let result = await task.value
        try require(!result && !session.isFilling && large.activeStrokeID==nil && large.document==original && !large.canUndo,
                    "Actual in-flight cancellation leaves source/history unchanged and releases owned input")
        let changed = Task { @MainActor in await session.fill(large,context:largeContext,point:CGPoint(x:500,y:500)) }
        let secondDeadline = Date().addingTimeInterval(10)
        while !session.isFilling && Date()<secondDeadline { await Task.yield() }
        try require(session.isFilling,"Actual second worker started")
        large.selectedTool = .hand
        let changedResult = await changed.value
        try require(!changedResult && large.document==original && large.activeStrokeID==nil,"Changed tool rejects completed work before commit")
        pass("actual in-flight cancellation and changed-context completion preserve document/history")
    }
    static func historyCoverageBudget() throws {
        let d = try StudioDocument.new(name:"Fill history bound",width:1024,height:128,fps:12)
        var spans: [StudioFillMask.Span] = []
        for row in 0..<128 { for x in stride(from:0,to:1024,by:2) {
            spans.append(.init(row:row,start:x,end:x+1,alpha:255))
        } }
        let element = DrawnElement(id:UUID().uuidString,tool:.fill,points:[.init(x:0,y:0),.init(x:1024,y:128)],
            color:"#FF0000",width:1,opacity:1,layerID:d.activeLayerID,
            fillMask:.init(width:1024,height:128,spans:spans))
        var editor = try StudioDocumentEditor(document:d)
        try editor.commit(element,frameID:d.activeFrameID)
        for alpha in 1...24 {
            try editor.change { value in
                value.frames[0].elements[0].fillMask!.spans[0] = .init(row:0,start:0,end:1,alpha:UInt8(alpha))
            }
        }
        let final = editor.document
        var undos = 0
        while editor.canUndo && undos < 50 { editor.undo(); undos += 1 }
        try require(undos > 0 && undos <= 16 && !editor.canUndo,
                    "Repeated independent coverage snapshots must obey the existing32MB history estimate")
        try require(!editor.document.frames[0].elements.isEmpty,"Old coverage snapshots were actually evicted")
        for _ in 0..<undos { try require(editor.canRedo,"Retained history has complete redo"); editor.redo() }
        try require(editor.document.frames==final.frames && !editor.canRedo,"Retained full-document redo restores exact latest coverage")
        print("FILL_HISTORY_RETAINED_UNDOS=\(undos)")
        pass("fill span memory participates in bounded full-document undo history")
    }
    static func styledBrushShapeFillRoundtrip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-mixed-tools-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DeviceStorageManager(documentsDirectory: root.appendingPathComponent("Documents"), cachesDirectory: root.appendingPathComponent("Cache"))
        let vm = StudioViewModel(storage: store)
        let created = await vm.createProject(name: "Brush shape and fill", width: 128, height: 128, fps: 12)
        try require(created, "Actual mixed-tool project creation")
        let brush = DrawnElement(id: UUID().uuidString, tool: .brush,
            points: [.init(x:16,y:32,timestamp:0), .init(x:112,y:32,timestamp:0.2)],
            color:"#FF0000", width:8, opacity:1, layerID:vm.activeLayerID,
            brush:.init(family:.round,seed:71,smoothing:0))
        try require(vm.commitElement(brush) && vm.document.schemaVersion == 2, "Styled brush begins in its historical schema")
        for schema in 2...StudioDocument.supportedSchemaVersions.upperBound {
            var historical = vm.document; historical.schemaVersion = schema
            try historical.validate()
            try require(StudioDocumentArchive.decode(StudioDocumentArchive(document: historical, rasterFrameIndices: [:]).encoded()).document == historical, "Supported schema changed a styled brush on decode")
        }
        for schema in [1, StudioDocument.supportedSchemaVersions.upperBound + 1] {
            var invalid = vm.document; invalid.schemaVersion = schema
            try rejects { try invalid.validate() }
        }
        var invalidBrush = vm.document; invalidBrush.schemaVersion = 6
        invalidBrush.frames[0].elements[0].brush!.version = 999
        try rejects { try invalidBrush.validate() }
        let outline = shape(vm.activeLayerID,fill:nil)
        try require(vm.commitElement(outline) && vm.document.schemaVersion == 5, "Adding a shape must retain an existing styled brush")
        let beforeFill = vm.document
        let fill = try StudioFillService.element(from:capture(vm.document))
        try require(vm.commitElement(fill) && vm.document.schemaVersion == 6, "Adding a fill must retain styled brush and shape")
        let filledDocument = vm.document
        let later = DrawnElement(id:UUID().uuidString,tool:.brush,
            points:[.init(x:16,y:120,timestamp:0),.init(x:112,y:120,timestamp:0.2)],
            color:"#00FF00",width:8,opacity:1,layerID:vm.activeLayerID,
            brush:.init(family:.round,seed:72,smoothing:0))
        try require(vm.commitElement(later), "Drawing after fill must remain editable")
        let finalElements = vm.document.frames[0].elements
        vm.undo();try require(vm.document.frames == filledDocument.frames, "Undo after fill lost existing tools")
        vm.undo();try require(vm.document.frames == beforeFill.frames && vm.document.schemaVersion == 5, "Undo fill must restore the previous schema and artwork")
        vm.redo();vm.redo();try require(vm.document.frames[0].elements == finalElements && vm.document.schemaVersion == 6, "Redo lost mixed-tool content")
        let saved = await vm.save();try require(saved,"Save mixed-tool document")
        let expected = vm.document
        let reopened = StudioViewModel(storage:store);await reopened.loadProjects()
        guard let record = reopened.savedProjects.first(where:{$0.id == expected.id}) else { throw Failure(message:"Mixed project missing from real storage") }
        let opened = await reopened.openProject(record);try require(opened && reopened.document == expected,"Cold reopen must preserve styled brush, shape and fill")
        let rendered = try render(reopened.document)
        try require(channel(rendered,64,32,0) == 255 && channel(rendered,64,64,2) == 255 && channel(rendered,64,120,1) == 255,"Mixed artwork lost red brush, blue fill or green later brush pixels")
        let output = try await StudioExportService().export(document:reopened.document,format:.pngSequence,outputParent:root,background:.transparent)
        let bytes = try Data(contentsOf:output.imageURLs[0])
        guard let source = CGImageSourceCreateWithData(bytes as CFData,nil),let image = CGImageSourceCreateImageAtIndex(source,0,nil) else { throw Failure(message:"Mixed-tool PNG could not reopen") }
        try require(pixels(image) == rendered,"Actual mixed-tool PNG differs from canonical renderer")
        pass("styled brushes survive all supported schemas, shape/fill transitions, later drawing, undo/redo, save/cold reopen and actual PNG")
    }
    static func main() async throws {
        setbuf(stdout, nil)
        try await styledBrushShapeFillRoundtrip()
        try actualEnclosure(); try samplingModes(); try coverageAndOpacity()
        try historyAndArchive(); try invalidCoverage(); try captureGuards()
        try await storageAndPNG()
        try aggregateBudgetAndLayerCopy(); try await actualMovie(); try await rasterAndCancellation()
        try await sessionAndGestures()
        try historyCoverageBudget()
        print("STUDIO_FILL_INTEGRATION=PASS groups=\(passed)")
    }
}
