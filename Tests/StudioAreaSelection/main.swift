import AppKit
import SwiftUI
import ImageIO
import AVFoundation

typealias UIImage = NSImage
extension Image { init(uiImage: NSImage) { self.init(nsImage: uiImage) } }
private struct Failure: Error { let message: String }

@main @MainActor struct AreaSelectionTests {
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
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-area-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = DeviceStorageManager(documentsDirectory: root.appendingPathComponent("Documents"), cachesDirectory: root.appendingPathComponent("Cache"))
        let vm = StudioViewModel(storage: storage)
        let made = await vm.createProject(name: "Real area selection", width: 128, height: 128, fps: 12)
        try require(made, "Actual project creation")
        var red = shape(vm.activeLayerID); red.width = 2; red.points = [.init(x: 16, y: 16), .init(x: 32, y: 32)]
        var blue = shape(vm.activeLayerID); blue.width = 2; blue.points = [.init(x: 80, y: 80), .init(x: 96, y: 96)]; blue.color = "#0000FF"; blue.shape?.fillColor = "#0000FF"
        try require(vm.commitElement(red) && vm.commitElement(blue), "Actual artwork")
        let saved = await vm.save(); try require(saved, "Initial save")
        let initial = vm.document, undoBefore = vm.canUndo
        let all = [CGPoint(x: 0, y: 0), CGPoint(x: 128, y: 128)]
        let left = [CGPoint(x: 8, y: 8), CGPoint(x: 40, y: 40)]
        let right = [CGPoint(x: 72, y: 72), CGPoint(x: 104, y: 104)]
        func select(_ points: [CGPoint], kind: StudioAreaSelectionKind = .rectangle, mode: StudioViewModel.SelectionMode = .new, smoothing: Double = 0) throws {
            vm.selectedTool = .lasso; vm.areaSelectionKind = kind; vm.selectionMode = mode; vm.areaSelectionSmoothing = smoothing
            guard let capture = vm.beginAreaSelection() else { throw Failure(message: "Could not begin area selection") }
            try require(vm.finishAreaSelection(capture, points: points), "Actual area selection failed: \(vm.message ?? "unknown")")
        }
        try select(left)
        try require(vm.selectedElementIDs == [red.id] && vm.document == initial && !vm.isDirty && vm.canUndo == undoBefore && vm.message == nil, "Selection must be transient and select only enclosed artwork")
        try select([.init(x: 18, y: 18), .init(x: 30, y: 30)])
        try require(vm.selectedElementIDs.isEmpty, "Partial enclosure selected a whole drawing")
        vm.deleteSelected(); try require(vm.document == initial, "Empty selection deleted a fallback element")
        vm.message = nil
        pass("actual rectangle enclosure preserves document revision saved state history and explicit empty deletion")

        try select(left); try select(right, mode: .add)
        try require(vm.selectedElementIDs == [red.id, blue.id], "Add lost original selection")
        try select(left, mode: .subtract)
        try require(vm.selectedElementIDs == [blue.id], "Subtract did not remove enclosed drawings")
        try select([.init(x: 2,y: 2), .init(x: 6,y: 6)], mode: .add)
        try require(vm.selectedElementIDs == [blue.id], "Empty Add cleared selection")
        try select(all, mode: .subtract)
        try require(vm.selectedElementIDs.isEmpty && vm.document == initial, "Subtract changed document")
        pass("replace Add Subtract and empty regions operate on actual stable drawing IDs")

        let square = [CGPoint(x: 8,y: 8), .init(x: 40,y: 8), .init(x: 40,y: 40), .init(x: 8,y: 40), .init(x: 8,y: 8)]
        try select(square, kind: .freehand)
        try require(vm.selectedElementIDs == [red.id], "Freehand enclosure failed")
        let notch = [CGPoint(x: 8,y: 8), .init(x: 22,y: 8), .init(x: 22,y: 26), .init(x: 26,y: 26), .init(x: 26,y: 8), .init(x: 40,y: 8), .init(x: 40,y: 40), .init(x: 8,y: 40)]
        try select(notch, kind: .freehand)
        try require(vm.selectedElementIDs.isEmpty, "Concave notch crossing artwork falsely selected it by corners")
        let boundary = [CGPoint(x: 15,y: 15), .init(x: 33,y: 15), .init(x: 33,y: 33), .init(x: 15,y: 33)]
        try select(boundary, kind: .freehand)
        try require(vm.selectedElementIDs == [red.id], "Exact boundary enclosure rejected")
        pass("freehand uses its closed outline including boundary contact and concave cutouts")

        let exact = try StudioSelectionRegion(points: boundary, kind: .freehand, smoothing: 0)
        let smoothed = try StudioSelectionRegion(points: boundary, kind: .freehand, smoothing: 3)
        try require(exact.points != smoothed.points && exact.contains(try StudioSelectionRegion.drawingBounds(red)!) && !smoothed.contains(try StudioSelectionRegion.drawingBounds(red)!), "Smoothing was only a label")
        for (a,b) in zip(exact.points,smoothed.points) { try require(hypot(a.x-b.x,a.y-b.y) <= 3.000001, "Smoothing exceeded chosen document pixels") }
        try select(boundary, kind: .freehand, smoothing: 3)
        try require(vm.selectedElementIDs.isEmpty, "Visible smoothed region differs from applied selection")
        pass("smoothing changes the actual shared preview region with bounded document-pixel displacement")

        vm.toggleLayerVisibility(vm.activeLayerID); try select(all); try require(vm.selectedElementIDs.isEmpty, "Hidden layer selected")
        vm.toggleLayerVisibility(vm.activeLayerID); vm.setLayerOpacity(vm.activeLayerID, opacity: 0)
        try select(all); try require(vm.selectedElementIDs.isEmpty, "Invisible layer selected")
        vm.setLayerOpacity(vm.activeLayerID, opacity: 1); vm.setLayerLockMode(vm.activeLayerID, mode: .full)
        try select(all); try require(vm.selectedElementIDs.isEmpty, "Full lock selected")
        vm.setLayerLockMode(vm.activeLayerID, mode: .position); try select(left)
        vm.selectedTool = .move
        try require(vm.selectedElementIDs == [red.id] && vm.beginMove(at: .init(x:24,y:24)) == nil, "Position lock allowed Move")
        vm.setLayerLockMode(vm.activeLayerID, mode: .free)
        pass("hidden transparent and full-lock layers are excluded and position-lock movement remains blocked")

        try select(all); vm.selectedTool = .move; vm.selectionMode = .new
        guard let move = vm.beginMove(at: .init(x:24,y:24)) else { throw Failure(message: "Area-selected group cannot move") }
        try require(vm.finishMove(move, delta: .init(width: 8,height: 8)), "Group move failed")
        let moved = vm.document, movedPixels = try render(moved)
        try require(channel(movedPixels,36,36,0)>240 && channel(movedPixels,36,36,2)<20 && channel(movedPixels,100,100,2)>240, "Selected group pixels at red interior (36,36): R=\(channel(movedPixels,36,36,0)) B=\(channel(movedPixels,36,36,2)); blue interior (100,100): B=\(channel(movedPixels,100,100,2))")
        try require(vm.copySelected(), "Area selection cannot use real Copy")
        vm.pasteClipboard(); try require(vm.currentFrame.elements.count == 4, "Area Copy/Paste failed")
        vm.deleteSelected(); try require(vm.currentFrame.elements.count == 2, "Selected copies were not deleted")
        vm.undo(); try require(vm.currentFrame.elements.count == 4, "Delete Undo failed")
        vm.redo(); try require(vm.document.frames == moved.frames, "Delete Redo failed")
        pass("area-selected group supports canonical Move Copy Paste Delete and full-document Undo Redo")

        let didSave = await vm.save(); try require(didSave, "Edited selection persistence failed")
        let persisted = vm.document
        let reopened = StudioViewModel(storage: storage); await reopened.loadProjects()
        guard let project = reopened.savedProjects.first else { throw Failure(message: "Project missing from actual list") }
        let opened = await reopened.openProject(project)
        try require(opened && reopened.document == persisted && reopened.selectedElementIDs.isEmpty, "Cold reopen lost artwork or persisted selection")
        let exported = try await StudioExportService().export(document: reopened.document, format: .pngSequence, outputParent: root, background: .transparent)
        guard let source = CGImageSourceCreateWithURL(exported.imageURLs[0] as CFURL,nil), let png = CGImageSourceCreateImageAtIndex(source,0,nil) else { throw Failure(message: "Actual exported PNG failed to reopen") }
        try require(pixels(png) == render(persisted), "Saved area-edited PNG pixels differ")
        pass("actual save list cold reopen and decoded PNG preserve edits while selection remains transient")

        try select(all)
        let beforeCancel = vm.document, selectedBefore = vm.selectedElementIDs
        guard let capture = vm.beginAreaSelection() else { throw Failure(message: "Missing capture") }
        var checkpoints = 0
        try require(vm.finishAreaSelection(capture, points: all, checkCancellation: {checkpoints += 1}), "Cancellation probe failed")
        for stop in 1...checkpoints {
            var count = 0
            try require(!vm.finishAreaSelection(capture, points: left, checkCancellation: {count += 1; if count == stop {throw CancellationError()}}), "Cancelled selection succeeded")
            try require(vm.document == beforeCancel && vm.selectedElementIDs == selectedBefore, "Cancellation partially changed selection or document")
        }
        var callbacks = 0
        try require(!vm.finishAreaSelection(capture, points: left, checkCancellation: {callbacks += 1; if callbacks == 2 {vm.clearElementSelection()}}), "Reentrant selection change was overwritten")
        try require(vm.selectedElementIDs.isEmpty && vm.document == beforeCancel, "Newer user selection was lost")
        pass("every cancellation checkpoint and intervening user selection preserve atomic selection and document state")

        for change in 0..<7 {
            try select(all)
            let c = vm.beginAreaSelection()!
            switch change {
            case 0: vm.selectedTool = .move
            case 1: vm.selectionMode = .add
            case 2: vm.areaSelectionKind = .freehand
            case 3: vm.areaSelectionSmoothing = 4
            case 4: vm.clearElementSelection()
            case 5: vm.setLayerOpacity(vm.activeLayerID, opacity: 0.9)
            default: vm.addFrame()
            }
            let d = vm.document, ids = vm.selectedElementIDs
            try require(!vm.finishAreaSelection(c,points:left) && vm.document == d && vm.selectedElementIDs == ids, "Stale selection changed newer state: \(change)")
        }
        vm.selectedTool = .lasso
        let strokeID = UUID().uuidString
        try require(vm.beginStrokeInput(id:strokeID) && vm.beginAreaSelection() == nil, "Active stroke allowed area selection")
        vm.finishStrokeInput(id:strokeID)
        vm.togglePlayback(); try require(vm.beginAreaSelection() == nil, "Playback allowed area selection"); vm.togglePlayback()
        pass("tool mode kind smoothing selection revision frame active-touch and playback changes invalidate captures")

        for family in StudioBrushFamily.allCases {
            var brush = DrawnElement(id:UUID().uuidString,tool:.brush,points:[.init(x:20,y:20),.init(x:70,y:45)],color:"#FF0000",width:12,opacity:1,layerID:vm.activeLayerID,brush:.init(family:family,seed:771,gradientEndColor:family == .gradient ? .init(red:0,green:0,blue:1):nil))
            let original = try StudioBrushGeometryCache.geometry(for:brush).bounds
            brush.reflection = .init(horizontal:true,vertical:true); brush.translation = .init(x:100,y:110)
            let transformed = try StudioSelectionRegion.drawingBounds(brush)!
            try require(abs(transformed.minX-(100-original.maxX))<0.00001 && abs(transformed.minY-(110-original.maxY))<0.00001 && transformed.size==original.size, "Canonical brush bounds lost marks or transforms")
        }
        let mask = StudioFillMask(width:128,height:128,spans:[.init(row:20,start:10,end:30,alpha:255)])
        let fill = DrawnElement(id:"fill",tool:.fill,points:[.init(x:10,y:20),.init(x:30,y:21)],color:"#FF0000",width:1,opacity:1,layerID:vm.activeLayerID,fillMask:mask,translation:.init(x:4,y:3),reflection:.init(horizontal:true,vertical:false))
        try require(StudioSelectionRegion.drawingBounds(fill) == fill.selectionBounds, "Sparse fill lost exact transformed bounds")
        pass("all ten brush families use actual rendered geometry and transforms; sparse fill bounds remain canonical")

        var trace = StudioSelectionTrace()
        for x in 0..<10_000 {try trace.append(.init(x:x,y:10),kind:.freehand)}
        try require(trace.points.count == 2 && trace.points.first?.x == 0 && trace.points.last?.x == 9999, "Collinear input grew without bound or lost endpoints")
        var rectangleTrace = StudioSelectionTrace()
        for x in 0..<1000 {try rectangleTrace.append(.init(x:x,y:x),kind:.rectangle)}
        try require(rectangleTrace.points.count == 2 && rectangleTrace.points.last?.x == 999, "Rectangle trace grew without bound")
        var zigzag = StudioSelectionTrace()
        for x in 0..<StudioSelectionTrace.maximumPoints {try zigzag.append(.init(x:x,y:x%2 == 0 ? 0:20),kind:.freehand)}
        try rejects {try zigzag.append(.init(x:513,y:0),kind:.freehand)}
        try require(zigzag.points.count == StudioSelectionTrace.maximumPoints, "Rejected outline corrupted trace")
        pass("real touch traces compress collinear samples and enforce bounded freehand and rectangle storage")

        for points:[CGPoint] in [[],[.zero],[.zero,.zero],[.zero,.init(x:10,y:0),.init(x:20,y:0)],[.init(x:Double.nan,y:0),.init(x:10,y:10)]] {
            try rejects {_ = try StudioSelectionRegion(points:points,kind:.freehand,smoothing:0)}
        }
        try rejects {_ = try StudioSelectionRegion(points:Array(repeating:.zero,count:513),kind:.rectangle,smoothing:0)}
        try rejects {_ = try StudioSelectionRegion(points:all,kind:.rectangle,smoothing:Double.infinity)}
        try rejects {_ = try StudioSelectionRegion(points:[.zero,.init(x:2_000_000,y:2)],kind:.rectangle,smoothing:0)}
        try select(all); let stable = vm.document, stableIDs = vm.selectedElementIDs
        let invalidCapture = vm.beginAreaSelection()!
        try require(!vm.finishAreaSelection(invalidCapture,points:[]) && vm.document == stable && vm.selectedElementIDs == stableIDs, "Invalid input changed actual selection")
        pass("invalid nonfinite degenerate oversized and out-of-range outlines fail without changing production state")
        print("PASS \(passed) production area-selection groups")
    }
}
