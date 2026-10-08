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
    static func render(_ d: StudioDocument, size: Int = 128, sources: [String:Data] = [:]) throws -> [UInt8] {
        let frame = d.frames[0], brushes = try StudioFrameRenderer.prepare(frame: frame)
        let rasters = try StudioFrameRenderer.prepareRasters(frame:frame,layers:d.layers,sourceData:sources)
        var failure: Error?
        let content = Canvas { context, actual in
            failure = StudioFrameRenderer.draw(context: &context, frame: frame, layers: d.layers,
                canvasSize: CGSize(width: d.width, height: d.height), size: actual, preparedBrushes: brushes, rasterSources:sources, preparedRasters:rasters)
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
        var linked = try StudioDocumentEditor(document: d)
        let originalLayer = d.activeLayerID
        try linked.duplicateLayer(originalLayer)
        try linked.updateLayer(originalLayer) { $0.visible = false }
        let linkedCapture = try capture(linked.document,raster:png)
        let linkedFill = try StudioFillService.element(from: linkedCapture)
        try require(linkedFill.layerID == linked.document.activeLayerID && linkedFill.fillMask == vector.fillMask,
                    "Fill on linked layer did not sample its original PNG boundary")
        try rejects { _ = try capture(linked.document) }

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
        // Use an explicit color: semantic SwiftUI .red varies by platform.
        // The VM now projects real AppKit colors as well as UIKit colors.
        try require(created,"Real session project"); vm.selectedTool = .fill; vm.strokeColor = Color(.sRGB, red: 1, green: 0, blue: 0)
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
    static func restoredFillPreferencesChangeRealCoverage() async throws {
        let suite = "sdi-fill-settings-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let storage = DeviceStorageManager(documentsDirectory: root.appendingPathComponent("Documents"), cachesDirectory: root.appendingPathComponent("Cache"))
        let configured = StudioViewModel(storage: storage, toolDefaults: defaults)
        configured.selectDrawingTool(.fill)
        configured.fillTolerance = 17; configured.fillExpand = 1; configured.fillGapClose = 2
        configured.fillContiguous = false; configured.fillAntiAlias = false; configured.fillSampleAll = true
        let vm = StudioViewModel(storage: storage, toolDefaults: UserDefaults(suiteName: suite))
        let created = await vm.createProject(name: "Restored fill", width: 128, height: 128, fps: 12)
        try require(created, "Fill preferences fixture project failed")
        vm.selectDrawingTool(.fill); vm.strokeColor = Color(.sRGB, red: 0, green: 0, blue: 1)
        try require(vm.commitElement(shape(vm.activeLayerID, fill: nil)), "Fill preferences outline failed")
        await vm.flush()
        let original = vm.document
        guard let context = StudioFillContext.current(vm) else { throw Failure(message: "Restored real Fill context unavailable") }
        try require(context.settings.tolerance == 17 && context.settings.expand == 1
            && context.settings.gapClose == 0 && !context.settings.contiguous && !context.settings.antiAlias
            && context.sampleAllLayers && vm.fillGapClose == 2, "Restored values did not reach actual Fill capture")
        let captured = try StudioFillService.capture(document: vm.document, frameID: context.frameID, layerID: context.layerID,
            point: CGPoint(x: 64, y: 64), color: context.color, opacity: context.opacity,
            settings: context.settings, sampleAllLayers: context.sampleAllLayers)
        let fill = try StudioFillService.element(from: captured)
        try require(vm.commitElement(fill), "Restored Fill result did not commit")
        let allPixels = try render(vm.document)
        try require(channel(allPixels, 4, 4, 2) == 255 && channel(allPixels, 64, 64, 2) == 255,
            "Restored all-similar Fill failed to color separated transparent regions")
        vm.undo()
        try require(vm.document.frames == original.frames, "Restored Fill Undo changed existing artwork")
        let beforeReset = vm.document
        vm.resetCurrentDrawingToolPreferences()
        try require(vm.document == beforeReset, "Fill Reset edited document")
        guard let reset = StudioFillContext.current(vm) else { throw Failure(message: "Reset Fill context unavailable") }
        try require(reset.settings.tolerance == 32 && reset.settings.expand == 0 && reset.settings.gapClose == 0
            && reset.settings.contiguous && reset.settings.antiAlias && !reset.sampleAllLayers,
            "Reset did not reach real Fill settings")
        let resetCapture = try StudioFillService.capture(document: vm.document, frameID: reset.frameID, layerID: reset.layerID,
            point: CGPoint(x: 64, y: 64), color: reset.color, opacity: reset.opacity,
            settings: reset.settings, sampleAllLayers: reset.sampleAllLayers)
        try require(vm.commitElement(StudioFillService.element(from: resetCapture)), "Reset Fill did not commit")
        let resetPixels = try render(vm.document)
        try require(channel(resetPixels, 4, 4) == 0 && channel(resetPixels, 64, 64, 2) == 255,
            "Reset contiguous Fill did not produce different real bounded coverage")
        await vm.flush()
        pass("fresh VM Fill preferences and Reset drive actual capture mask renderer commit and Undo")
    }
    static func selectionAuthorization() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-fill-selection-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = DeviceStorageManager(documentsDirectory: root.appendingPathComponent("Documents"), cachesDirectory: root.appendingPathComponent("Cache"))
        let vm = StudioViewModel(storage: storage), session = StudioFillSession()
        let created = await vm.createProject(name: "Fill selection guard", width: 2048, height: 1024, fps: 12)
        try require(created, "Selected Fill project failed")
        let source = shape(vm.activeLayerID)
        try require(vm.commitElement(source), "Selected Fill source failed")
        await vm.flush()
        vm.selectDrawingTool(.fill)
        guard let context = StudioFillContext.current(vm) else { throw Failure(message: "Plain Fill context missing") }
        let original = vm.document, originalUndo = vm.canUndo
        _ = vm.selectElement(at: CGPoint(x: 64, y: 64))
        try require(vm.selectedElementIDs == [source.id] && StudioFillContext.current(vm)?.selectedElementIDs == [source.id],
            "Selected Fill context lost exact captured IDs")
        let rejected = await session.fill(vm, context: context, point: CGPoint(x: 500, y: 500))
        try require(!rejected && vm.message == "Studio changed before fill started. Tap the current artwork again."
            && vm.document == original && vm.selectedElementIDs == [source.id]
            && vm.activeStrokeID == nil && !session.isFilling && vm.canUndo == originalUndo && !vm.canRedo,
            "Selected-start Fill changed source/history or hid why it was denied")
        vm.clearElementSelection()
        guard let plain = StudioFillContext.current(vm) else { throw Failure(message: "Deselect failed to re-enable Fill") }
        let task = Task { @MainActor in await session.fill(vm, context: plain, point: CGPoint(x: 500, y: 500)) }
        let deadline = Date().addingTimeInterval(10)
        while !session.isFilling && Date() < deadline { await Task.yield() }
        guard session.isFilling, let owner = vm.activeStrokeID else { throw Failure(message: "Real Fill worker did not enter its owned phase") }
        // Actual public input/selection APIs restore the same owner, tool and
        // revision; only selected identities differ at worker completion.
        vm.finishStrokeInput(id: owner)
        _ = vm.selectElement(at: CGPoint(x: 64, y: 64))
        try require(vm.beginStrokeInput(id: owner) && vm.selectedElementIDs == [source.id],
            "Actual selection-change fixture failed")
        let changed = await task.value
        try require(!changed && vm.document == original && vm.selectedElementIDs == [source.id]
            && vm.activeStrokeID == nil && !session.isFilling && vm.canUndo == originalUndo && !vm.canRedo,
            "Late selection broadened Fill authority or changed history")
        try require(vm.message == "Fill was cancelled or Studio changed. Nothing was added.",
            "Late selection rejection lacked factual guidance")
        vm.clearElementSelection()
        guard let resumed = StudioFillContext.current(vm) else { throw Failure(message: "Plain Fill did not recover after rejection") }
        let filled = await session.fill(vm, context: resumed, point: CGPoint(x: 500, y: 500))
        try require(filled && vm.currentFrame.elements.count == original.frames[0].elements.count + 1
            && vm.currentFrame.elements.last?.fillMask != nil && vm.currentFrame.elements.first == source,
            "Deselect-first guard broke normal real Fill")
        try require(vm.message == "Filled the tapped canvas region.", "Plain Fill claimed object selection clipping")
        vm.undo()
        try require(vm.document.frames == original.frames, "Normal Fill after rejection lost one-step Undo")
        await vm.flush()
        pass("stale selected-start and late-selection real Fill reject atomically while Deselect restores normal Fill and Undo")
    }
    static func transformedSelectionCoverage() throws {
        var d = try document()
        var first = shape(d.activeLayerID), second = shape(d.activeLayerID)
        first.points = [.init(x: 8, y: 8), .init(x: 24, y: 24)]; first.width = 2
        first.transform = .init(a: 0, b: 1, c: -1, d: 0, tx: 50, ty: 10)
        second.points = first.points; second.width = 2; second.translation = .init(x: 64, y: 64)
        d.schemaVersion = 11; d.frames[0].elements = [first, second]
        let ids: Set<String> = [first.id, second.id]
        let settings = StudioFillRegion.Settings(tolerance: 128, contiguous: false, expand: 3, gapClose: 0, antiAlias: true)
        let c = try StudioFillService.capture(document: d, frameID: d.activeFrameID, layerID: d.activeLayerID,
            point: CGPoint(x: 34, y: 26), color: "#0000FF", opacity: 0.75, settings: settings,
            sampleAllLayers: false, selectedElementIDs: ids)
        guard let coverage = c.selectionCoverage else { throw Failure(message: "Selected alpha missing") }
        try require(coverage.count == 128 * 128 && coverage[26*128+34] == 255 && coverage[80*128+80] == 255
            && coverage[50*128+50] == 0, "Transformed separated coverage became a bounding box")
        let paint = try StudioFillService.element(from: c)
        try require(paint.opacity == 0.75 && c.settings == settings, "Selected Fill ignored settings")
        for span in paint.fillMask!.spans {
            for x in span.start..<span.end {
                try require(coverage[span.row*128+x] > 0 && span.alpha <= coverage[span.row*128+x], "Expansion or AA leaked beyond selected alpha")
            }
        }
        var editor = try StudioDocumentEditor(document: d)
        try editor.commit(paint, frameID: d.activeFrameID)
        try require(Array(editor.document.frames[0].elements.prefix(2)) == [first, second], "Selected Fill recolored source objects")
        let pixels = try render(editor.document)
        try require(channel(pixels,34,26,2) > 150 && channel(pixels,80,80,2) > 150 && channel(pixels,50,50) == 0,
            "All-similar fill did not paint both selected islands only")
        let outside = try StudioFillService.capture(document: d, frameID: d.activeFrameID, layerID: d.activeLayerID,
            point: CGPoint(x: 50, y: 50), color: "#0000FF", opacity: 1, settings: settings,
            sampleAllLayers: false, selectedElementIDs: ids)
        try rejects { _ = try StudioFillService.element(from: outside) }
        var erased = d
        erased.schemaVersion = 11
        erased.frames[0].elements.append(.init(id: "unselected-layer-eraser", tool: .eraser,
            points: [.init(x: 34, y: 26)], color: "#000000", width: 12, opacity: 1,
            fillColor: nil, layerID: d.activeLayerID, eraser: .init()))
        try rejects { _ = try StudioFillService.capture(document: erased, frameID: d.activeFrameID, layerID: d.activeLayerID,
            point: CGPoint(x: 34, y: 26), color: "#0000FF", opacity: 1, settings: settings,
            sampleAllLayers: false, selectedElementIDs: ids) }
        try rejects { _ = try StudioFillService.capture(document: d, frameID: d.activeFrameID, layerID: d.activeLayerID,
            point: CGPoint(x: 34, y: 26), color: "#0000FF", opacity: 1, settings: settings,
            sampleAllLayers: false, selectedElementIDs: ["missing"]) }
        pass("selected transformed source alpha clips two islands expansion and AA and rejects outside or backdrop-dependent selection")
    }
    static func selectedCoverageSessionPersistence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-selected-fill-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DeviceStorageManager(documentsDirectory: root)
        let vm = StudioViewModel(storage: store), session = StudioFillSession()
        let created = await vm.createProject(name: "Selected source coverage", width: 128, height: 128, fps: 12)
        try require(created, "Selected Fill create failed")
        let source = shape(vm.activeLayerID)
        try require(vm.commitElement(source), "Selected source commit failed")
        _ = vm.selectElement(at: CGPoint(x: 64, y: 64))
        vm.selectDrawingTool(.fill); vm.strokeColor = Color(.sRGB, red: 0, green: 0, blue: 1)
        await vm.flush()
        guard let context = StudioFillContext.current(vm) else { throw Failure(message: "Selected Fill context missing") }
        try require(context.selectedElementIDs == [source.id], "Tool switch lost selection")
        let original = vm.document
        let filled = await session.fill(vm, context: context, point: CGPoint(x: 64, y: 64))
        try require(filled && vm.currentFrame.elements.count == 2 && vm.currentFrame.elements[0] == source
            && vm.message == "Added paint on the active layer within selected artwork coverage. Original drawings remain unchanged.",
            "Selected Fill did not add factual separate active-layer paint")
        let expected = vm.document, pixels = try render(expected)
        try require(channel(pixels,64,64,2) > 0 && channel(pixels,4,4) == 0, "Selected paint not clipped")
        vm.undo(); try require(vm.document.frames == original.frames, "Selected Fill Undo changed source")
        vm.redo(); try require(render(vm.document) == pixels, "Selected Fill Redo changed pixels")
        let saved = await vm.save(); try require(saved, "Selected Fill save failed")
        let cold = StudioViewModel(storage: store); await cold.loadProjects()
        guard let metadata = cold.savedProjects.first else { throw Failure(message: "Selected Fill missing saved metadata") }
        let opened = await cold.openProject(metadata); try require(opened && cold.document == vm.document && render(cold.document) == pixels,
            "Selected Fill cold reopen changed source or coverage")
        await cold.flush()
        pass("real selected Fill session adds separate paint with one Undo Redo and cold saved pixels")
    }
    static func selectedImageCoverageSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-image-fill-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let original = try document(shape("fixture",opacity:0.5))
        let input = try await StudioExportService().export(document:original,format:.pngSequence,outputParent:root,background:.transparent)
        let imported = try await StudioImageImportService().importImage(from:input.imageURLs[0],name:"Transparent shape",scratchParent:root)
        let store = DeviceStorageManager(documentsDirectory:root.appendingPathComponent("projects")), vm = StudioViewModel(storage:DeviceStorageManager(documentsDirectory:root.appendingPathComponent("projects")))
        let created = await vm.createProject(name:"Selected image Fill",width:128,height:128,fps:12)
        try require(created,"Image Fill project")
        let asset = try vm.attachImportedImage(imported,expectedProjectID:vm.document.id,expectedRevision:vm.document.revision,frameID:vm.currentFrame.id,layerID:vm.activeLayerID)
        let layer = vm.currentFrame.rasterLayerID!
        vm.selectLayer(layer); vm.selectedTool = .move; await vm.flush()
        guard let placement = vm.prepareImagePlacement() else { throw Failure(message:"Image Fill placement") }
        try require(vm.placeImage(placement,at:.init(x:24,y:24,width:80,height:80),rotationDegrees:30),"Image Fill transform")
        await vm.flush(); try require(vm.setImageCanvasMove(true),"Explicit image selection")
        vm.selectedTool = .fill; vm.strokeColor = Color.blue; vm.fillSampleAll = true; vm.fillTolerance = 128; vm.fillExpand = 5
        await vm.flush()
        guard let context = StudioFillContext.current(vm) else { throw Failure(message:"Selected image Fill context") }
        try require(context.selectedImageLayerID == layer && context.selectedImageSelectionID != nil,"Image selection lost on Fill handoff")
        // Same document/revision, a different explicit selection UUID.
        vm.selectedTool = .move; await vm.flush()
        try require(vm.setImageCanvasMove(true), "Image reselection failed")
        vm.selectedTool = .fill; await vm.flush()
        guard let reselected = StudioFillContext.current(vm) else { throw Failure(message:"Reselected Fill context") }
        try require(reselected.revision == context.revision && reselected.selectedImageSelectionID != context.selectedImageSelectionID,
            "Selection-token fixture changed revision or reused identity")
        let unchanged = vm.document, staleSession = StudioFillSession()
        let oldTokenAccepted = await staleSession.fill(vm,context:context,point:CGPoint(x:64,y:64))
        try require(!oldTokenAccepted && vm.document == unchanged,"Same-revision old selection token authorized Fill")
        let before = vm.document, sources = vm.rasterSources(for:vm.currentFrame)
        let capture = try StudioFillService.capture(document:before,frameID:before.activeFrameID,layerID:layer,point:CGPoint(x:64,y:64),color:"#0000FF",opacity:1,settings:context.settings,sampleAllLayers:true,rasterDataByID:sources,selectedImageLayerID:layer)
        guard let coverage = capture.selectionCoverage else { throw Failure(message:"Image alpha missing") }
        try require(coverage[64*128+64] > 100 && coverage[64*128+64] < 200 && coverage[2*128+2] == 0,"Actual partial image alpha was flattened or bounded-box substituted")
        // Order a real drawing beneath the image through the production editor.
        // Isolated image coverage must ignore that drawing without retaining an
        // impossible positive slot in its empty projection.
        var orderedEditor = try StudioDocumentEditor(document: before)
        var underneath = shape("below-selected-image", opacity: 1)
        underneath.layerID = layer
        try orderedEditor.commit(underneath, frameID: before.activeFrameID)
        try orderedEditor.orderSelectedArtwork(frameID: before.activeFrameID, elementIDs: [],
            imageAssetID: asset, imageLayerID: layer, forward: true)
        let orderedDocument = orderedEditor.document, retainedSources = sources
        try require(orderedDocument.frames.first(where: { $0.id == before.activeFrameID })?.rasterInstance(on: layer)?.stackPosition == 1,
                    "Ordered Fill fixture did not put the image above its drawing")
        let orderedCapture = try StudioFillService.capture(document: orderedDocument,
            frameID: before.activeFrameID, layerID: layer, point: CGPoint(x:64,y:64), color:"#0000FF", opacity:1,
            settings:context.settings, sampleAllLayers:true, rasterDataByID:sources, selectedImageLayerID:layer)
        try require(orderedCapture.selectionCoverage == coverage,
                    "Ordered selected-image coverage changed original partial alpha or included the drawing")
        try require(orderedEditor.document == orderedDocument && sources == retainedSources
                    && sources[asset] == imported.normalizedPNG,
                    "Isolated image coverage rewrote persisted stacking or original source")
        for lock in ["full", "alpha"] {
            var blocked = before
            let index = blocked.layers.firstIndex(where:{$0.id == layer})!
            blocked.layers[index].lockMode = lock
            try rejects { _ = try StudioFillService.capture(document:blocked,frameID:blocked.activeFrameID,layerID:layer,point:CGPoint(x:64,y:64),color:"#0000FF",opacity:1,settings:context.settings,sampleAllLayers:true,rasterDataByID:sources,selectedImageLayerID:layer) }
        }
        var hidden = before
        hidden.layers[hidden.layers.firstIndex(where:{$0.id == layer})!].visible = false
        try rejects { _ = try StudioFillService.capture(document:hidden,frameID:hidden.activeFrameID,layerID:layer,point:CGPoint(x:64,y:64),color:"#0000FF",opacity:1,settings:context.settings,sampleAllLayers:true,rasterDataByID:sources,selectedImageLayerID:layer) }
        // Real canonical source-mask and crop replay, not a rectangular proxy.
        var masked = before
        var instance = masked.frames[0].rasterInstance(on:layer)!
        instance.rotationDegrees = nil; instance.crop = .init(x:0.25,y:0.25,width:0.5,height:0.5)
        let geometry = StudioImageRegionMask.Geometry(instance)!
        instance.regionMask = .init(width:imported.width,height:imported.height,
            spans:(0..<imported.height).map { .init(row:$0,start:0,end:imported.width/2) },
            sourceClip:instance.crop,samplingGeometry:geometry,placementGeometry:geometry)
        masked.schemaVersion = 32; try masked.frames[0].updateRasterInstance(instance); try masked.validate()
        let maskedCapture = try StudioFillService.capture(document:masked,frameID:masked.activeFrameID,layerID:layer,point:CGPoint(x:44,y:64),color:"#0000FF",opacity:1,settings:context.settings,sampleAllLayers:true,rasterDataByID:sources,selectedImageLayerID:layer)
        try require((maskedCapture.selectionCoverage?[64*128+44] ?? 0) > 0,"Cropped selected source mask lost retained pixels")
        try require(maskedCapture.selectionCoverage?[64*128+84] == 0,"Selection coverage ignored existing Wand mask")
        _ = try StudioFillService.element(from:maskedCapture)
        let maskedOutside = try StudioFillService.capture(document:masked,frameID:masked.activeFrameID,layerID:layer,point:CGPoint(x:84,y:64),color:"#0000FF",opacity:1,settings:context.settings,sampleAllLayers:true,rasterDataByID:sources,selectedImageLayerID:layer)
        try rejects { _ = try StudioFillService.element(from:maskedOutside) }
        let fill = try StudioFillService.element(from:capture)
        try require(fill.fillMask != nil,"Actual image clipped region")
        // Outside selection must reject even with broad tolerance and expansion.
        let outside = try StudioFillService.capture(document:before,frameID:before.activeFrameID,layerID:layer,point:CGPoint(x:2,y:2),color:"#0000FF",opacity:1,settings:context.settings,sampleAllLayers:true,rasterDataByID:sources,selectedImageLayerID:layer)
        try rejects { _ = try StudioFillService.element(from:outside) }
        try rejects { _ = try StudioFillService.capture(document:before,frameID:before.activeFrameID,layerID:layer,point:CGPoint(x:64,y:64),color:"#0000FF",opacity:1,settings:context.settings,sampleAllLayers:true,selectedImageLayerID:layer) }
        let session = StudioFillSession(), succeeded = await session.fill(vm,context:reselected,point:CGPoint(x:64,y:64))
        try require(succeeded && vm.currentFrame.elements.count == 1 && vm.rasterData(asset) == imported.normalizedPNG,"Real selected image Fill changed original bytes or failed")
        let painted = try render(vm.document,sources:sources)
        for i in 0..<coverage.count where coverage[i] == 0 {
            try require(painted[i*4+2] == 0,"Fill painted outside selected image alpha")
        }
        try require(channel(painted,64,64,2)>0,"Selected image Fill had no blue output")
        vm.undo(); try require(vm.document.frames == before.frames,"Selected image Fill Undo changed source")
        vm.redo(); try require(render(vm.document,sources:sources) == painted,"Selected image Fill Redo pixels")
        let saved = await vm.save(); try require(saved,"Selected image Fill save")
        let cold = StudioViewModel(storage:store)
        let opened = await cold.openProject(try store.loadAnimation(id:vm.document.id)!.metadata)
        try require(opened && render(cold.document,sources:cold.rasterSources(for:cold.currentFrame)) == painted && cold.rasterData(asset) == imported.normalizedPNG,"Selected image cold coverage/source")
        let output = try await StudioExportService().export(document:cold.document,format:.pngSequence,outputParent:root,background:.transparent,rasterData:{cold.rasterData($0)})
        let decoded = CGImageSourceCreateWithURL(output.imageURLs[0] as CFURL,nil)!
        try require(pixels(CGImageSourceCreateImageAtIndex(decoded,0,nil)!) == painted,"Selected image Fill PNG differed")
        // An old selection token cannot authorize a new fill after deselection.
        vm.deselectAreaImage(); let stable = vm.document
        let stale = await session.fill(vm,context:context,point:CGPoint(x:64,y:64))
        try require(!stale && vm.document == stable,"Stale image selection added paint")
        // A stale Lasso capture must not be revived by switching tools.
        vm.selectedTool = .lasso; vm.areaSelectionTarget = .image; vm.areaSelectionKind = .rectangle
        await vm.flush()
        guard let area = vm.beginAreaSelection() else { throw Failure(message:"Lasso image fixture unavailable") }
        try require(vm.finishAreaSelection(area,points:[CGPoint(x:0,y:0),CGPoint(x:128,y:128)]) && vm.selectedAreaImageCorners != nil,
            "Real Lasso image selection failed")
        try require(vm.renameProject("Unrelated revision",expectedProjectID:vm.document.id,expectedRevision:vm.document.revision),"Unrelated document edit")
        try require(vm.selectedAreaImageCorners == nil,"Unrelated edit did not stale Lasso selection")
        let revised = vm.document, canUndo = vm.canUndo, canRedo = vm.canRedo
        vm.selectedTool = .fill; await vm.flush()
        try require(vm.hasFillImageTarget && StudioFillContext.current(vm) == nil && vm.document == revised && vm.canUndo == canUndo && vm.canRedo == canRedo,
            "Tool handoff revived stale Lasso or silently fell back to whole-canvas Fill")
        pass("explicit transformed image-alpha Fill real session clips expansion preserves source Undo cold and PNG")
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
        try await restoredFillPreferencesChangeRealCoverage()
        try await selectionAuthorization()
        try transformedSelectionCoverage()
        try await selectedCoverageSessionPersistence()
        try await selectedImageCoverageSession()
        print("STUDIO_FILL_INTEGRATION=PASS groups=\(passed)")
    }
}
