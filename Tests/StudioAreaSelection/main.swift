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
    static func selectionBodyWinsClampedCornerSlop() throws {
        let document = CGSize(width: 128, height: 128)
        // These exact canvas-origin bounds previously put every body point
        // inside the clamped top-left corner's 22-point admission circle.
        let origin = StudioSelectionHandleGeometry(bounds: .init(x: 0, y: 0, width: 5, height: 5),
            documentSize: document, viewport: document, zoom: 1)!
        let corner = origin.handles.first { $0.kind == .topLeft }!
        try require(corner.point == CGPoint(x: 8, y: 8) && origin.hitRadius == 22,
                    "Fixture must retain the existing visible corner and touch radius")
        try require(hypot(corner.point.x-2.5, corner.point.y-2.5) < origin.hitRadius,
                    "Tiny-origin fixture did not exercise real handle/body overlap")
        for side in [5.0, 16.0] {
            let bounds = [CGRect(x: 0, y: 0, width: side, height: side),
                          CGRect(x: 128-side, y: 0, width: side, height: side),
                          CGRect(x: 0, y: 128-side, width: side, height: side),
                          CGRect(x: 128-side, y: 128-side, width: side, height: side),
                          CGRect(x: 64-side/2, y: 64-side/2, width: side, height: side)]
            for rect in bounds { for axis in [false, true] {
                // False is also the actual image-resize geometry policy; the
                // Canvas now calls this same hit method for images/drawings.
                let layouts: [(CGSize, Double)] = [(document, 1), (.init(width: 256, height: 256), 0.25),
                                                   (.init(width: 256, height: 256), 1), (.init(width: 256, height: 256), 5)]
                for (viewport, zoom) in layouts {
                    guard let geometry = StudioSelectionHandleGeometry(bounds: rect, documentSize: document,
                        viewport: viewport, zoom: zoom, allowsAxisHandles: axis) else { throw Failure(message: "Valid small selection geometry rejected") }
                    for fraction in [0.375, 0.5, 0.625] {
                        let point = CGPoint(x: (rect.minX + rect.width*fraction) * viewport.width / 128,
                                            y: (rect.minY + rect.height*fraction) * viewport.height / 128)
                        try require(geometry.hit(point) == nil, "Central small selection interior was stolen by corner slop")
                    }
                }
            } }
        }
        // Strict means boundaries are not swallowed by the Move body.
        try require(origin.hit(.zero) == .topLeft && origin.hit(.init(x: 6, y: 2.5)) == .topLeft,
                    "Actual boundary/outside corner admission was lost")
        try require(origin.hit(.init(x: CGFloat.nan, y: 0)) == nil, "Nonfinite handle point admitted")
        let large = StudioSelectionHandleGeometry(bounds: .init(x: 24, y: 24, width: 80, height: 80),
            documentSize: document, viewport: document, zoom: 1, allowsAxisHandles: true)!
        for handle in large.handles {
            try require(large.hit(handle.point) == handle.kind, "Ordinary real corner/rotation target no longer transforms")
        }
        let largeEdge = StudioSelectionHandleGeometry(bounds: .init(x: 0, y: 0, width: 100, height: 100),
            documentSize: document, viewport: document, zoom: 1)!
        let clampedCorner = largeEdge.handles.first { $0.kind == .topLeft }!
        try require(clampedCorner.point == CGPoint(x: 8, y: 8) && largeEdge.hit(clampedCorner.point) == .topLeft
            && largeEdge.hit(.init(x: 50, y: 50)) == nil, "Protected Move area swallowed a legitimate large clamped corner")
        let thin = StudioSelectionHandleGeometry(bounds: .init(x: 8, y: 48, width: 112, height: 32),
            documentSize: document, viewport: document, zoom: 1, allowsAxisHandles: true)!
        try require(thin.handles.contains { $0.kind == .bottom } && thin.hit(.init(x: 64, y: 64)) == nil,
                    "Overlapping axis-handle slop stole interior Move")
        // Rotate is explicitly painted and remains available even if the full
        // selection forces that knob to be clamped inside its body.
        let full = StudioSelectionHandleGeometry(bounds: .init(x: 0, y: 0, width: 128, height: 128),
            documentSize: document, viewport: document, zoom: 1)!
        let rotation = full.handles.first { $0.kind == .rotate }!
        try require(full.hit(rotation.point) == .rotate && full.hit(.init(x: 64, y: 64)) == nil,
                    "Explicit Rotate target or ordinary interior Move changed")
        let oversized = StudioSelectionHandleGeometry(bounds: .init(x: -100, y: -100, width: 328, height: 328),
            documentSize: document, viewport: document, zoom: 1)!
        let oversizedCorners = oversized.handles.filter { [.topLeft, .topRight, .bottomLeft, .bottomRight].contains($0.kind) }
        try require(oversizedCorners.count == 4, "Oversized fixture lost visible corner geometry")
        for corner in oversizedCorners {
            try require(oversized.hit(corner.point) == corner.kind,
                        "Oversized selection body swallowed a visible clamped resize knob")
        }
        try require(oversized.hit(.init(x: 64, y: 64)) == nil,
                    "Oversized selection center no longer admits Move")
        let innerRotation = oversized.handles.first { $0.kind == .rotate }!
        try require(oversized.hit(innerRotation.point) == .rotate,
                    "Rotate was lost when its clamped knob lies inside the protected Move region")
        pass("shared drawing/image handle admission preserves small edge Move and real corner/rotation targets")
    }
    static func tinyLassoSelectionMovesAfterSharedAdmission() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-small-edge-move-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for side in [5.0, 16.0] {
            let storage = DeviceStorageManager(documentsDirectory: root.appendingPathComponent("Documents-\(side)"),
                                                cachesDirectory: root.appendingPathComponent("Caches-\(side)"))
            let vm = StudioViewModel(storage: storage)
            let created = await vm.createProject(name: "Small origin selection", width: 128, height: 128, fps: 12)
            try require(created, "Small Move project creation")
            let original = DrawnElement(id: UUID().uuidString, tool: .rectangle,
                points: [.init(x: 1, y: 1), .init(x: side-1, y: side-1)], color: "#FF0000", width: 2, opacity: 1,
                layerID: vm.activeLayerID, shape: .init(fillColor: "#FF0000"))
            try require(vm.commitElement(original), "Small Move artwork rejected"); await vm.flush()
            vm.selectedTool = .lasso; vm.areaSelectionKind = .rectangle; vm.selectionMode = .new
            guard let capture = vm.beginAreaSelection() else { throw Failure(message: "Small Lasso capture unavailable") }
            try require(vm.finishAreaSelection(capture, points: [.zero, .init(x: side+1, y: side+1)])
                && vm.selectedTool == .move && vm.selectedElementIDs == [original.id], "Small Lasso did not activate actual Move selection")
            guard let bounds = vm.selectedArtworkBounds(in: vm.currentFrame),
                  let geometry = StudioSelectionHandleGeometry(bounds: bounds, documentSize: .init(width: 128, height: 128),
                    viewport: .init(width: 128, height: 128), zoom: 1) else { throw Failure(message: "Small selected artwork geometry unavailable") }
            try require(bounds == CGRect(x: 0, y: 0, width: side, height: side), "Fixture no longer touches the actual canvas origin")
            let point = CGPoint(x: bounds.midX, y: bounds.midY)
            // This is the production Canvas's shared admission decision before
            // its existing beginMove/finishMove path, not a copied hit model.
            try require(geometry.hit(point) == nil, "Center drag would enter resize before native Move")
            let before = vm.document
            guard let move = vm.beginMove(at: point, viewport: .init(width: 128, height: 128), zoom: 1) else { throw Failure(message: "Small selected body has no real Move capture") }
            try require(vm.finishMove(move, delta: .init(width: 12, height: 8)), "Real small selection Move failed")
            guard let element = vm.currentFrame.elements.first, let moved = element.selectionBounds else { throw Failure(message: "Move lost original artwork") }
            try require(vm.document.revision == before.revision+1 && element.id == original.id && element.shape == original.shape
                && element.points == original.points && element.width == original.width
                && moved.width == bounds.width && moved.height == bounds.height && moved.minX == bounds.minX+12 && moved.minY == bounds.minY+8,
                "Center drag resized/replaced artwork instead of moving it")
            let after = vm.frames
            vm.undo(); try require(vm.frames == before.frames, "Small Move was not one reversible transaction")
            vm.redo(); try require(vm.frames == after, "Small Move Redo changed geometry")
            await vm.flush()
        }
        pass("actual tiny canvas-origin Lasso selection routes into canonical Move with unchanged size and one Undo")
    }
    static func moveIgnoresEraserRecords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-move-eraser-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = DeviceStorageManager(documentsDirectory: root.appendingPathComponent("Documents"), cachesDirectory: root.appendingPathComponent("Cache"))
        let vm = StudioViewModel(storage: storage)
        let created = await vm.createProject(name: "Move visible artwork", width: 128, height: 128, fps: 12)
        try require(created, "Move eraser fixture creation")
        let artwork = shape(vm.activeLayerID)
        let eraser = DrawnElement(id: UUID().uuidString, tool: .eraser,
            points: [.init(x: 30, y: 30), .init(x: 90, y: 90)], color: "#000000",
            width: 4, opacity: 1, layerID: vm.activeLayerID)
        try require(vm.commitElement(artwork) && vm.commitElement(eraser), "Move eraser fixture commits")
        await vm.flush()
        let before = vm.document
        vm.selectDrawingTool(.move); vm.selectionMode = .new
        guard let direct = vm.beginMove(at: .init(x: 40, y: 40)) else { throw Failure(message: "Direct Move unavailable") }
        try require(direct.artwork == nil, "Fixture did not reach direct Move branch")
        let undoBefore = vm.canUndo, redoBefore = vm.canRedo
        try require(!vm.finishMove(direct, delta: .init(width: 4, height: 4), checkCancellation: { throw CancellationError() })
            && vm.document == before && vm.canUndo == undoBefore && vm.canRedo == redoBefore,
            "Cancelled direct Move committed artwork or history")
        try require(vm.selectElement(at: .init(x: 40, y: 40)) == artwork.id
            && vm.selectedElementIDs == [artwork.id], "Invisible eraser intercepted artwork selection")
        try require(vm.beginSelectionHandle() != nil, "Visible artwork has no selection handles")
        guard let move = vm.beginMove(at: .init(x: 40, y: 40)) else { throw Failure(message: "Move capture unavailable") }
        try require(vm.finishMove(move, delta: .init(width: 4, height: 4)), "Visible artwork move failed")
        try require(vm.currentFrame.elements.first(where: { $0.id == eraser.id }) == eraser, "Move changed the layer eraser")
        vm.undo()
        try require(vm.frames == before.frames, "Move Undo did not restore artwork and eraser")
        await vm.flush()
        pass("Move hit testing skips eraser masks and retains editable artwork handles")
    }
    static func restoredSelectionPreferencesDriveActualSelection() async throws {
        let suite = "sdi-selection-settings-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let storage = DeviceStorageManager(documentsDirectory: root.appendingPathComponent("Documents"), cachesDirectory: root.appendingPathComponent("Cache"))
        let configured = StudioViewModel(storage: storage, toolDefaults: defaults)
        configured.selectDrawingTool(.move); configured.selectionMode = .subtract
        configured.selectDrawingTool(.lasso); configured.selectionMode = .add
        configured.areaSelectionKind = .rectangle; configured.areaSelectionSmoothing = 8
        let vm = StudioViewModel(storage: storage, toolDefaults: UserDefaults(suiteName: suite))
        let created = await vm.createProject(name: "Restored selection", width: 128, height: 128, fps: 12)
        try require(created, "Selection preference project failed")
        var left = shape(vm.activeLayerID); left.points = [.init(x: 16, y: 16), .init(x: 32, y: 32)]; left.width = 2
        var right = shape(vm.activeLayerID); right.points = [.init(x: 80, y: 80), .init(x: 96, y: 96)]; right.width = 2
        try require(vm.commitElement(left) && vm.commitElement(right), "Selection preference fixture drawings failed")
        await vm.flush()
        let original = vm.document, undoBefore = vm.canUndo
        vm.selectDrawingTool(.lasso)
        for bounds in [[CGPoint(x: 8, y: 8), CGPoint(x: 40, y: 40)], [CGPoint(x: 72, y: 72), CGPoint(x: 104, y: 104)]] {
            vm.selectDrawingTool(.lasso)
            guard let capture = vm.beginAreaSelection() else { throw Failure(message: "Restored Lasso capture unavailable") }
            try require(capture.mode == .add && capture.kind == .rectangle && capture.smoothing == 8,
                "Restored preferences did not reach real selection capture")
            try require(vm.finishAreaSelection(capture, points: bounds), "Restored additive selection failed")
        }
        try require(vm.selectedElementIDs == [left.id, right.id], "Restored Add mode replaced the prior selection")
        try require(vm.selectedTool == .move && vm.selectionMode == .new && !vm.selectionPreservesAspect,
                    "Completed lasso must hand off to free Move without remembered Subtract")
        vm.selectionMode = .subtract
        _ = vm.selectElement(at: CGPoint(x: 24, y: 24))
        try require(vm.selectionMode == .subtract && vm.selectedElementIDs == [right.id], "Restored Move subtract did not remove only the hit")
        vm.selectDrawingTool(.lasso)
        guard let pending = vm.beginAreaSelection() else { throw Failure(message: "Pending Lasso capture unavailable") }
        let selected = vm.selectedElementIDs
        vm.resetCurrentDrawingToolPreferences()
        try require(vm.selectedElementIDs == selected, "Reset cleared live selection identities")
        try require(!vm.finishAreaSelection(pending, points: [CGPoint(x: 0, y: 0), CGPoint(x: 128, y: 128)])
            && vm.selectedElementIDs == selected, "Pre-reset gesture overwrote selection with stale settings")
        guard let reset = vm.beginAreaSelection() else { throw Failure(message: "Reset selection capture unavailable") }
        try require(reset.mode == .new && reset.kind == .freehand && reset.smoothing == 3, "Reset did not restore real selection capture")
        try require(vm.finishAreaSelection(reset, points: [CGPoint(x: 8, y: 8), CGPoint(x: 40, y: 8),
            CGPoint(x: 40, y: 40), CGPoint(x: 8, y: 40), CGPoint(x: 8, y: 8)])
            && vm.selectedElementIDs == [left.id], "Reset New mode did not replace selection")
        try require(vm.document == original && vm.canUndo == undoBefore && !vm.canRedo && !vm.isDirty,
            "Selection preferences changed project/history")
        vm.undo()
        try require(vm.currentFrame.elements == [left], "Selection preferences added a hidden Undo step")
        await vm.flush()
        pass("restored Move Lasso settings drive actual hit/area selection and Reset rejects stale gesture without history")
    }
    static func vertexAlignedDrawingEnclosure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-vertex-enclosure-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DeviceStorageManager(documentsDirectory: root.appendingPathComponent("Documents"), cachesDirectory: root.appendingPathComponent("Cache"))
        let vm = StudioViewModel(storage: store)
        let created = await vm.createProject(name: "Vertex aligned enclosure", width: 128, height: 128, fps: 12)
        try require(created, "Vertex fixture project")
        // This exact point was falsely excluded by SwiftUI Path's even-odd test
        // in the preserved image-area probe. It lies strictly inside the outline.
        let corner = CGPoint(x: 122.42640687119285, y: 94.14213562373095)
        let line = DrawnElement(id: UUID().uuidString, tool: .line,
            points: [.init(x: corner.x - 0.75, y: corner.y + 0.25),
                     .init(x: corner.x - 0.25, y: corner.y + 0.25)],
            color: "#FF0000", width: 0.5, opacity: 1, layerID: vm.activeLayerID)
        try require(vm.commitElement(line), "Real vertex fixture drawing")
        let bounds = try StudioSelectionRegion.drawingBounds(line)!
        try require(bounds.maxX == corner.x && bounds.minY == corner.y && bounds.width == 1 && bounds.height == 0.5,
                    "Real stroke bounds no longer contain the exact regression corner")
        let outline = StudioImageRotationGeometry(placement: .init(x: 39, y: 59, width: 82, height: 42), degrees: 45).corners
        let saved = await vm.save(); try require(saved, "Vertex fixture save")
        let document = vm.document, undo = vm.canUndo, redo = vm.canRedo, artwork = try render(document)
        for kind in [StudioAreaSelectionKind.freehand, .polygon] {
            vm.selectedTool = .lasso; vm.areaSelectionKind = kind; vm.areaSelectionSmoothing = 0; vm.selectionMode = .new
            let region = try StudioSelectionRegion(points: outline, kind: kind, smoothing: 0)
            try require(region.contains(bounds), "Enclosed drawing touching the polygon vertex ray was falsely rejected")
            guard let capture = vm.beginAreaSelection() else { throw Failure(message: "Vertex fixture capture") }
            try require(vm.finishAreaSelection(capture, points: outline) && vm.selectedElementIDs == [line.id],
                        "Actual freehand/polygon operation failed to select the enclosed drawing")
            try require(vm.document == document && vm.canUndo == undo && vm.canRedo == redo && !vm.isDirty,
                        "Vertex enclosure changed document/history")
        }
        let partial = [CGPoint(x: corner.x - 2, y: corner.y - 1), CGPoint(x: corner.x - 0.1, y: corner.y - 1),
                       CGPoint(x: corner.x - 0.1, y: corner.y + 2), CGPoint(x: corner.x - 2, y: corner.y + 2)]
        try require(!StudioSelectionRegion(points: partial, kind: .polygon, smoothing: 0).contains(bounds),
                    "Partially enclosed drawing was accepted")
        try require(try render(vm.document) == artwork, "Selection changed actual artwork pixels")
        await vm.flush()
        pass("vertex-aligned drawing bounds use robust even-odd enclosure through real freehand and polygon selection")
    }
    /// Actual compositor pixels distinguish a butt-ended native line from the
    /// round disks the old Wand broad-phase placed around its endpoints.
    static func wandNativeButtLinePixels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-wand-butt-line-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for mode in ["plain", "affine", "reflected-affine"] {
            let storage = DeviceStorageManager(documentsDirectory: root.appendingPathComponent(mode + "/Documents"),
                cachesDirectory: root.appendingPathComponent(mode + "/Cache"))
            let vm = StudioViewModel(storage: storage)
            let created = await vm.createProject(name: "Wand native butt shaft", width: 128, height: 128, fps: 12)
            try require(created, "Butt-line project creation")
            var line = DrawnElement(id: UUID().uuidString, tool: .line,
                points: [.init(x: 32, y: 64), .init(x: 96, y: 64)], color: "#000000",
                width: 8, opacity: 1, layerID: vm.activeLayerID)
            if mode != "plain" {
                // Nonuniform affine placement with shear, preserving the canvas centre.
                line.transform = .init(a: 0.9, b: 0.25, c: 0.35, d: 0.75, tx: -16, ty: 0)
            }
            if mode == "reflected-affine" {
                line.reflection = .init(horizontal: true, vertical: false)
                line.translation = .init(x: 128, y: 0)
            }
            try require(vm.commitElement(line), "Actual butt-line commit failed")
            await vm.flush()
            let before = vm.document, beforePixels = try render(before)
            let visible = try StudioFillService.capture(document: before, frameID: vm.currentFrame.id,
                layerID: vm.activeLayerID, point: CGPoint(x: 1, y: 1), color: "#000000", opacity: 1,
                settings: .init(tolerance: 0, contiguous: true, expand: 0, gapClose: 0, antiAlias: false), sampleAllLayers: true)
            let rgba = [UInt8](visible.rgba), placement = try line.erasurePlacement()
            let start = placement.point(CGPoint(x: 32, y: 64)), end = placement.point(CGPoint(x: 96, y: 64))
            let centre = placement.point(CGPoint(x: 64, y: 64))
            let dx = Double(end.x - start.x), dy = Double(end.y - start.y), distance = hypot(dx, dy)
            let oldReach = max(0.5, Double(line.width) * sqrt(abs(placement.a * placement.d - placement.b * placement.c)) / 2)
            var whiteEndpoint: CGPoint?, painted: CGPoint?, paintedDistance = Double.infinity
            // Geometry only bounds the endpoint search. Actual compositor bytes
            // choose a white pixel that the old round endpoint probe would hit,
            // plus a genuinely painted shaft pixel nearest its real centre.
            for y in 0..<128 { for x in 0..<128 {
                let index = (y * 128 + x) * 4
                let px = Double(x) + 0.5, py = Double(y) + 0.5
                let fromX = px - Double(start.x), fromY = py - Double(start.y)
                if whiteEndpoint == nil, fromX * fromX + fromY * fromY <= oldReach * oldReach,
                   (fromX * dx + fromY * dy) / distance < -0.5,
                   Array(rgba[index..<index+4]) == [255,255,255,255] {
                    whiteEndpoint = CGPoint(x: x, y: y)
                }
                let centreDistance = pow(px - Double(centre.x), 2) + pow(py - Double(centre.y), 2)
                if rgba[index] < 128, rgba[index+1] < 128, rgba[index+2] < 128, rgba[index+3] == 255,
                   centreDistance < paintedDistance {
                    paintedDistance = centreDistance; painted = CGPoint(x: x, y: y)
                }
            } }
            guard let whiteEndpoint, let painted else { throw Failure(message: "Native \(mode) line has no actual white endpoint / painted shaft fixture") }
            vm.selectedTool = .wand; vm.wandTolerance = 0; vm.wandContiguous = true
            vm.wandSampleVisibleCanvas = true; vm.wandFeather = 0; vm.wandMode = .newSelection
            let outside = await vm.selectDrawingRegion(try vm.captureDrawingWand(), at: whiteEndpoint)
            let outsideIDs = try await vm.wandDrawingIDs(at: whiteEndpoint, tolerance: 0, sampleAllLayers: true,
                checkCancellation: { try Task.checkCancellation() })
            try require(outside && vm.selectedElementIDs.isEmpty && outsideIDs.isEmpty && vm.document == before,
                "Native \(mode) butt line acquired real white endpoint pixels: physical=\(outside), IDs=\(vm.selectedElementIDs.sorted()), typed=\(outsideIDs), message=\(vm.message ?? "nil")")
            let inside = await vm.selectDrawingRegion(try vm.captureDrawingWand(), at: painted)
            let insideIDs = try await vm.wandDrawingIDs(at: painted, tolerance: 0, sampleAllLayers: true,
                checkCancellation: { try Task.checkCancellation() })
            try require(inside && vm.selectedElementIDs == [line.id] && insideIDs == [line.id] && vm.document == before,
                "Native \(mode) painted shaft was lost after the butt-footprint filter")
            vm.deleteSelected(); await vm.flush()
            try require(vm.currentFrame.elements.isEmpty, "Actual selected native line did not delete")
            vm.undo(); await vm.flush()
            try require(vm.document.frames == before.frames && (try render(vm.document)) == beforePixels,
                "Butt-line Delete Undo lost native source geometry or pixels")
        }
        pass("actual compositor white butt endpoints stay unselected while plain affine reflected shafts select and delete with Undo")
    }
    /// A valid forward placement can have an out-of-range inverse origin;
    /// hit directions need only its inverse linear components.
    static func wandHighTranslationLinePixels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-wand-translated-line-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = DeviceStorageManager(documentsDirectory: root.appendingPathComponent("Documents"),
            cachesDirectory: root.appendingPathComponent("Cache"))
        let vm = StudioViewModel(storage: storage)
        let created = await vm.createProject(name: "Wand valid compressed translated shaft", width: 4096, height: 512, fps: 12)
        try require(created, "Translated line project creation")
        let forward = StudioElementTransform(a: 0.02, d: 1, tx: 4000)
        try forward.validate()
        let line = DrawnElement(id: UUID().uuidString, tool: .line,
            points: [.init(x: 32, y: 256), .init(x: 96, y: 256)], color: "#000000",
            width: 8, opacity: 1, layerID: vm.activeLayerID, transform: forward)
        try require(vm.commitElement(line), "Valid compressed translated line commit failed")
        await vm.flush()
        let before = vm.document
        try before.validate()
        let visible = try StudioFillService.capture(document: before, frameID: vm.currentFrame.id,
            layerID: vm.activeLayerID, point: CGPoint(x: 1, y: 1), color: "#000000", opacity: 1,
            settings: .init(tolerance: 0, contiguous: true, expand: 0, gapClose: 0, antiAlias: false), sampleAllLayers: true)
        let rgba = [UInt8](visible.rgba)
        var painted: CGPoint?
        paintedScan: for y in 0..<visible.height { for x in 0..<visible.width {
            let index = (y * visible.width + x) * 4
            if rgba[index] < 128, rgba[index+1] < 128, rgba[index+2] < 128, rgba[index+3] == 255 {
                painted = CGPoint(x: x, y: y); break paintedScan
            }
        } }
        guard let painted else { throw Failure(message: "Actual compositor did not paint the valid compressed translated line") }
        vm.selectedTool = .wand; vm.wandTolerance = 0; vm.wandContiguous = true
        vm.wandSampleVisibleCanvas = true; vm.wandFeather = 0; vm.wandMode = .newSelection
        let selected = await vm.selectDrawingRegion(try vm.captureDrawingWand(), at: painted)
        let typed = try await vm.wandDrawingIDs(at: painted, tolerance: 0, sampleAllLayers: true,
            checkCancellation: { try Task.checkCancellation() })
        try require(selected && vm.selectedElementIDs == [line.id] && typed == [line.id] && vm.document == before,
            "Valid compressed translated native shaft was rejected: physical=\(selected), IDs=\(vm.selectedElementIDs.sorted()), typed=\(typed), message=\(vm.message ?? "nil")")
        await vm.flush()
        pass("actual painted compressed line remains Wand-selectable with valid high forward translation")
    }
    /// Production Wand input must intersect the ellipse's rendered body, never its empty box.
    static func wandFilledEllipsePixels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-wand-ellipse-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for rotated in [false, true] { for opacity in [1.0, 0.2] {
            let name = "\(rotated)-\(opacity)"
            let storage = DeviceStorageManager(documentsDirectory: root.appendingPathComponent(name + "/Documents"),
                cachesDirectory: root.appendingPathComponent(name + "/Cache"))
            let vm = StudioViewModel(storage: storage)
            let created = await vm.createProject(name: "Wand ellipse alpha", width: 128, height: 128, fps: 12)
            try require(created, "Wand ellipse project creation")
            var ellipse = DrawnElement(id: UUID().uuidString, tool: .circle,
                points: [.init(x: 32, y: 40), .init(x: 96, y: 88)], color: "#000000",
                width: 2, opacity: opacity, layerID: vm.activeLayerID,
                shape: .init(fillColor: "#000000", cornerRadius: 0))
            if rotated {
                ellipse.transform = try StudioElementTransform.scaleRotation(x: 0.8, y: 1.1,
                    degrees: 35, center: CGPoint(x: 64, y: 64))
            }
            let other = DrawnElement(id: UUID().uuidString, tool: .line,
                points: [.init(x: 8, y: 110), .init(x: 24, y: 110)], color: "#0000FF",
                width: 4, opacity: 1, layerID: vm.activeLayerID)
            try require(vm.commitElement(ellipse) && vm.commitElement(other), "Actual ellipse/line commits failed")
            await vm.flush()
            let before = vm.document, bodyPixels = try render(before)
            // This is the real visible-canvas compositor the Wand samples: opaque white,
            // while the canonical ellipse body has actual (possibly faint) black alpha.
            let visible = try StudioFillService.capture(document: before, frameID: vm.currentFrame.id,
                layerID: vm.activeLayerID, point: CGPoint(x: 1, y: 1), color: "#000000", opacity: 1,
                settings: .init(tolerance: 0, contiguous: true, expand: 0, gapClose: 0, antiAlias: false),
                sampleAllLayers: true)
            let rgba = [UInt8](visible.rgba)
            try require(Array(rgba[(1 * 128 + 1) * 4..<(1 * 128 + 1) * 4 + 4]) == [255,255,255,255]
                && rgba[(64 * 128 + 64) * 4] < 255 && rgba[(64 * 128 + 64) * 4 + 3] == 255,
                "Fixture is not a real white composite with visible ellipse pixels")
            vm.selectedTool = .wand; vm.wandTolerance = 0; vm.wandContiguous = true
            vm.wandSampleVisibleCanvas = true; vm.wandFeather = 0; vm.wandMode = .newSelection
            let outsideCapture = try vm.captureDrawingWand()
            let selectedOutside = await vm.selectDrawingRegion(outsideCapture, at: CGPoint(x: 1, y: 1))
            try require(selectedOutside && vm.selectedElementIDs.isEmpty && vm.document == before,
                "Visible white region selected an ellipse through its empty bounding-box corners: rotated=\(rotated), opacity=\(opacity), physical=\(selectedOutside), IDs=\(vm.selectedElementIDs.sorted()), ellipse=\(ellipse.id), line=\(other.id), message=\(vm.message ?? "nil")")
            let outsideIDs = try await vm.wandDrawingIDs(at: CGPoint(x: 1, y: 1), tolerance: 0,
                sampleAllLayers: true, checkCancellation: { try Task.checkCancellation() })
            try require(outsideIDs.isEmpty, "Typed Wand still selected an ellipse through empty box pixels")
            let insideCapture = try vm.captureDrawingWand()
            let selectedInside = await vm.selectDrawingRegion(insideCapture, at: CGPoint(x: 64, y: 64))
            try require(selectedInside && vm.selectedElementIDs == [ellipse.id] && vm.document == before,
                "Real filled/rotated/faint ellipse pixels were not selected independently")
            let insideIDs = try await vm.wandDrawingIDs(at: CGPoint(x: 64, y: 64), tolerance: 0,
                sampleAllLayers: true, checkCancellation: { try Task.checkCancellation() })
            try require(insideIDs == [ellipse.id], "Typed Wand lost canonical ellipse alpha/placement")
            try require(vm.copySelected(), "Wand ellipse could not enter the production clipboard")
            vm.pasteClipboard(); await vm.flush()
            let copies = vm.currentFrame.elements.filter { $0.id != ellipse.id && $0.id != other.id }
            try require(copies.count == 1 && copies[0].tool == .circle && copies[0].shape == ellipse.shape
                && copies[0].opacity == ellipse.opacity && vm.currentFrame.elements.contains(other),
                "Copy/paste included unrelated artwork or lost the ellipse body")
            vm.undo(); await vm.flush()
            try require(vm.document.frames == before.frames && vm.document.layers == before.layers
                && (try render(vm.document)) == bodyPixels, "One Undo failed to restore the copied ellipse scene")
            vm.selectedTool = .wand
            let deleteCapture = try vm.captureDrawingWand()
            let selectedForDelete = await vm.selectDrawingRegion(deleteCapture, at: CGPoint(x: 64, y: 64))
            try require(selectedForDelete && vm.selectedElementIDs == [ellipse.id], "Delete fixture lost real Wand selection")
            vm.deleteSelected(); await vm.flush()
            try require(vm.currentFrame.elements == [other], "Wand Delete removed unrelated artwork or kept the selected ellipse")
            vm.undo(); await vm.flush()
            try require(vm.document.frames == before.frames && (try render(vm.document)) == bodyPixels,
                "Wand Delete Undo did not restore editable geometry and real pixels")

            // The helper consumes the exact same rendered source alpha, and keeps its
            // cancellation and invalid-mask boundaries while running on the worker.
            let isolated = AnimationFrame(id: vm.currentFrame.id, elements: [ellipse])
            guard let fullAlpha = try StudioFillService.selectionCoverage(document: vm.document,
                frame: isolated, selectedIDs: [ellipse.id]),
                  let alpha = try StudioFillService.wandElementCoverage(document: vm.document,
                    frame: vm.currentFrame, element: ellipse, maximumPixels: StudioSelectionMask.maximumElementProbes) else {
                throw Failure(message: "No canonical ellipse alpha")
            }
            try require(alpha.width * alpha.height < 128 * 128 && alpha.rowStride == alpha.width,
                "Small ellipse alpha allocated an entire canvas")
            // Compact Wand candidates are consumed only as source alpha > 0.
            // Compare exact positive membership at every canvas pixel, including
            // outside-crop zeros; numeric no-crop Fill/effect masks are a separate API.
            for y in 0..<128 { for x in 0..<128 {
                let localX = x - alpha.x, localY = y - alpha.y
                let compact: UInt8 = localX >= 0 && localY >= 0 && localX < alpha.width && localY < alpha.height
                    ? alpha.bytes[localY * alpha.rowStride + localX] : 0
                try require((compact > 0) == (fullAlpha[y * 128 + x] > 0), "Cropped ellipse hit membership differs from the canonical full render")
            } }
            let candidate = StudioSelectionElementHitTest.Candidate(id: ellipse.id, points: [], radius: 0,
                alphaCoverage: alpha)
            var checks = 0
            do {
                _ = try StudioSelectionElementHitTest.elements(intersecting: [UInt8](repeating: 0, count: 128 * 128),
                    width: 128, height: 128, candidates: [candidate], checkCancellation: {
                        checks += 1; if checks == 3 { throw CancellationError() }
                    })
                throw Failure(message: "Exact ellipse-alpha hit testing ignored cancellation")
            } catch is CancellationError { }
            try rejects {
                _ = try StudioSelectionElementHitTest.elements(intersecting: [UInt8](repeating: 0, count: 128 * 128),
                    width: 128, height: 128, candidates: [.init(id: ellipse.id, points: [], radius: 0, alphaCoverage: .init(x: 0, y: 0, width: 2, height: 1, rowStride: 2, bytes: [255]))])
            }
            await vm.flush()
        } }
        pass("real Wand excludes empty ellipse corners and selects transformed faint bodies for copy/delete/Undo")
    }

    static func wandPortraitSmallEllipsesStayWithinBudget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-wand-portrait-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = DeviceStorageManager(documentsDirectory: root.appendingPathComponent("Documents"),
            cachesDirectory: root.appendingPathComponent("Cache"))
        let vm = StudioViewModel(storage: storage)
        let created = await vm.createProject(name: "Portrait Wand many ellipses", width: 1080, height: 1920, fps: 12)
        try require(created, "Portrait Wand creation")
        let centers: [CGPoint] = [.init(x: 180, y: 240), .init(x: 720, y: 240), .init(x: 180, y: 900),
            .init(x: 720, y: 900), .init(x: 420, y: 1450), .init(x: 800, y: 1620)]
        var elements: [DrawnElement] = []
        for (index, center) in centers.enumerated() {
            var element = DrawnElement(id: UUID().uuidString, tool: .circle,
                points: [.init(x: center.x - 24, y: center.y - 32), .init(x: center.x + 24, y: center.y + 32)],
                color: "#000000", width: 2, opacity: 1, layerID: vm.activeLayerID,
                shape: .init(fillColor: "#000000", cornerRadius: 0))
            if index % 2 == 1 { element.transform = try StudioElementTransform.scaleRotation(x: 0.8, y: 1.1, degrees: 30, center: center) }
            try require(vm.commitElement(element), "Portrait ellipse commit failed")
            elements.append(element)
        }
        await vm.flush()
        let before = vm.document
        var compactPixels = 0
        var diagnosticAlphas: [StudioSelectionElementHitTest.AlphaCoverage] = []
        for element in elements {
            guard let alpha = try StudioFillService.wandElementCoverage(document: before, frame: vm.currentFrame,
                element: element, maximumPixels: StudioSelectionMask.maximumElementProbes - compactPixels) else {
                throw Failure(message: "Visible portrait ellipse has no compact alpha")
            }
            compactPixels += alpha.width * alpha.height
            diagnosticAlphas.append(alpha)
        }
        try require(elements.count > 4 && compactPixels < 100_000 && compactPixels < StudioSelectionMask.maximumElementProbes,
            "Small portrait circles were charged once per whole canvas")
        vm.selectedTool = .wand; vm.wandTolerance = 0; vm.wandContiguous = true
        vm.wandSampleVisibleCanvas = true; vm.wandFeather = 0; vm.wandMode = .newSelection
        func portraitContext(_ stage: String, _ result: Bool) -> String {
            let selectedIndexes = elements.indices.filter { vm.selectedElementIDs.contains(elements[$0].id) }
            let unknownSelected = vm.selectedElementIDs.subtracting(Set(elements.map(\.id))).count
            let message = String((vm.message ?? "<nil>").prefix(240)).replacingOccurrences(of: "\n", with: " ")
            return " [stage=\(stage) result=\(result) selectedIndexes=\(selectedIndexes) unknownSelected=\(unknownSelected) documentSame=\(vm.document == before) revision=\(vm.document.revision) expectedRevision=\(before.revision) compactPixels=\(compactPixels) maximumProbes=\(StudioSelectionMask.maximumElementProbes) message=\(message)]"
        }
        let outside = await vm.selectDrawingRegion(try vm.captureDrawingWand(), at: CGPoint(x: 1, y: 1))
        if outside && !vm.selectedElementIDs.isEmpty {
            // Diagnostic only: compare the actual compact source membership with
            // the canonical full source and the exact visible-canvas Wand region.
            // All six shapes are disjoint, so one full source union is sufficient.
            // This neither changes production alpha nor replaces any original gate.
            guard let full = try StudioFillService.selectionCoverage(document: before, frame: vm.currentFrame,
                selectedIDs: Set(elements.map(\.id))) else { throw Failure(message: "Portrait diagnostic full source unavailable") }
            let visible = try StudioFillService.capture(document: before, frameID: before.activeFrameID,
                layerID: vm.activeLayerID, point: .init(x: 1, y: 1), color: "#000000", opacity: 1,
                settings: .init(tolerance: 0, contiguous: true, expand: 0, gapClose: 0, antiAlias: false),
                sampleAllLayers: true)
            let region = try StudioWandRegion.select(rgba: visible.rgba, width: before.width, height: before.height,
                x: 1, y: 1, settings: .init(tolerance: 0, contiguous: true, feather: 0,
                    mode: .replace, rejectTransparentSeed: false))
            func details(_ x: Int, _ y: Int, _ compact: UInt8) -> String {
                let index = y * before.width + x, pixel = index * 4
                return "x=\(x),y=\(y),compact=\(compact),full=\(full[index]),rgba=\(Array(visible.rgba[pixel..<pixel+4])),region=\(region[index])"
            }
            for (index, alpha) in diagnosticAlphas.enumerated() {
                var compactPositive = 0, fullPositive = 0, compactOnly = 0, fullOnly = 0
                var compactHitsRegion = 0, fullHitsRegion = 0, positiveOnExactWhite = 0
                var hitAlphaMinimum = 256, hitAlphaMaximum = 0
                var firstCompactOnly = "none", firstFullOnly = "none", firstHit = "none"
                for row in 0..<alpha.height { for column in 0..<alpha.width {
                    let x = alpha.x + column, y = alpha.y + row, target = y * before.width + x
                    let source = alpha.bytes[row * alpha.rowStride + column], original = full[target]
                    if source > 0 { compactPositive += 1 }; if original > 0 { fullPositive += 1 }
                    if source > 0 && original == 0 {
                        compactOnly += 1; if firstCompactOnly == "none" { firstCompactOnly = details(x, y, source) }
                    }
                    if original > 0 && source == 0 {
                        fullOnly += 1; if firstFullOnly == "none" { firstFullOnly = details(x, y, source) }
                    }
                    if source > 0 {
                        let pixel = target * 4
                        if (0..<4).allSatisfy({ visible.rgba[pixel+$0] == 255 }) { positiveOnExactWhite += 1 }
                        if region[target] >= 128 {
                            compactHitsRegion += 1
                            hitAlphaMinimum = min(hitAlphaMinimum, Int(source)); hitAlphaMaximum = max(hitAlphaMaximum, Int(source))
                            if firstHit == "none" { firstHit = details(x, y, source) }
                        }
                    }
                    if original > 0 && region[target] >= 128 { fullHitsRegion += 1 }
                } }
                let center = centers[index]
                let centerX = Int(center.x), centerY = Int(center.y)
                let localX = centerX - alpha.x, localY = centerY - alpha.y
                let centerAlpha: UInt8
                if localX >= 0 && localX < alpha.width && localY >= 0 && localY < alpha.height {
                    centerAlpha = alpha.bytes[localY * alpha.rowStride + localX]
                } else { centerAlpha = 0 }
                let centerDetails = details(centerX, centerY, centerAlpha)
                print("PORTRAIT_ALPHA index=\(index) affine=\(elements[index].transform != nil) crop=\(alpha.x),\(alpha.y),\(alpha.width),\(alpha.height) compactPositive=\(compactPositive) fullPositive=\(fullPositive) compactOnly=\(compactOnly) fullOnly=\(fullOnly) compactHitsRegion=\(compactHitsRegion) fullHitsRegion=\(fullHitsRegion) positiveOnExactWhite=\(positiveOnExactWhite) hitAlphaMin=\(hitAlphaMinimum) hitAlphaMax=\(hitAlphaMaximum) firstCompactOnly=[\(firstCompactOnly)] firstFullOnly=[\(firstFullOnly)] firstHit=[\(firstHit)] center=[\(centerDetails)]")
            }
            fflush(stdout)
        }
        try require(outside && vm.selectedElementIDs.isEmpty && vm.document == before,
            "Ordinary portrait Wand failed its budget or selected circles through empty corners" + portraitContext("outside", outside))
        let one = await vm.selectDrawingRegion(try vm.captureDrawingWand(), at: centers[3])
        try require(one && vm.selectedElementIDs == [elements[3].id] && vm.document == before,
            "Portrait Wand did not select only the tapped transformed ellipse" + portraitContext("one", one))
        vm.wandContiguous = false
        let all = await vm.selectDrawingRegion(try vm.captureDrawingWand(), at: centers[0])
        try require(all && vm.selectedElementIDs == Set(elements.map(\.id)) && vm.document == before,
            "Global color Wand failed to select six actual portrait ellipses within its unchanged budget" + portraitContext("all", all))
        await vm.flush()
        pass("six small native ellipses on a1080x1920 canvas use compact alpha and select within the unchanged work bound")
    }

    static func fullCanvasSelectionCoverageKeepsExistingLargeDocumentCapacity() throws {
        var document = try StudioDocument.new(name: "Existing large coverage", width: 2050, height: 2048, fps: 12)
        let element = DrawnElement(id: UUID().uuidString, tool: .circle,
            points: [.init(x: 20, y: 20), .init(x: 60, y: 60)], color: "#000000", width: 2,
            opacity: 1, layerID: document.activeLayerID, shape: .init(fillColor: "#000000", cornerRadius: 0))
        document.frames[0].elements = [element]
        document.schemaVersion = max(document.schemaVersion, 5)
        try document.validate()
        try require(document.width * document.height > StudioSelectionMask.maximumPixels,
            "Capacity fixture did not exceed the new compact pixel-tool limit")
        // Actual original no-crop API, with one small native-rendered source. This
        // guards legacy selection capacity without requiring a giant artwork fixture.
        guard let alpha = try StudioFillService.selectionCoverage(document: document,
            frame: document.frames[0], selectedIDs: [element.id]) else { throw Failure(message: "Large no-crop coverage unavailable") }
        let painted = alpha.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }
        try require(alpha.count == 2050 * 2048 && alpha.contains(255) && alpha.contains(0)
            && painted > 100 && painted < 10_000,
            "Existing no-crop coverage lost its complete native source alpha or document capacity")
        pass("native no-crop selection coverage retains a valid2050x2048 document above the compact4MP limit")
    }

    static func wandGlyphAndRoundedCornerCoverage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-wand-glyphs-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for kind in ["text", "legacy-text", "rounded"] { for rotated in [false, true] { for opacity in [1.0, 0.2] {
            let label = "\(kind)-\(rotated)-\(opacity)"
            let storage = DeviceStorageManager(documentsDirectory: root.appendingPathComponent(label + "/Documents"),
                cachesDirectory: root.appendingPathComponent(label + "/Cache"))
            let vm = StudioViewModel(storage: storage)
            let created = await vm.createProject(name: "Wand actual glyph coverage", width: 128, height: 128, fps: 12)
            try require(created, "Glyph Wand project creation")
            var element: DrawnElement
            if kind == "rounded" {
                element = DrawnElement(id: UUID().uuidString, tool: .rectangle,
                    points: [.init(x: 32, y: 32), .init(x: 96, y: 96)], color: "#000000", width: 2,
                    opacity: opacity, layerID: vm.activeLayerID, shape: .init(fillColor: "#000000", cornerRadius: 24))
            } else if kind == "text" {
                let style = StudioTextStyle(font: .monospaced, size: 24, alignment: .center,
                    boxWidth: 96, boxHeight: 48, rotation: rotated ? 15 : 0)
                element = DrawnElement(id: UUID().uuidString, tool: .text,
                    points: [.init(x: 16, y: 40)], color: "#000000", width: 1,
                    opacity: opacity, layerID: vm.activeLayerID, text: .init(content: "H H", style: style))
            } else {
                element = DrawnElement(id: UUID().uuidString, tool: .text,
                    points: [.init(x: 24, y: 42)], color: "#000000", width: 8,
                    opacity: opacity, fillColor: "H H", layerID: vm.activeLayerID)
            }
            if rotated {
                element.transform = try StudioElementTransform.scaleRotation(x: 0.85, y: 0.95,
                    degrees: kind == "text" ? -5 : 20, center: CGPoint(x: 64, y: 64))
            }
            let other = DrawnElement(id: UUID().uuidString, tool: .line,
                points: [.init(x: 8, y: 118), .init(x: 24, y: 118)], color: "#0000FF", width: 3,
                opacity: 1, layerID: vm.activeLayerID)
            try require(vm.commitElement(element) && vm.commitElement(other), "Glyph/rounded native commits failed")
            await vm.flush()
            let before = vm.document, beforePixels = try render(before)
            let isolated = AnimationFrame(id: vm.currentFrame.id, elements: [element])
            guard let full = try StudioFillService.selectionCoverage(document: before, frame: isolated, selectedIDs: [element.id]),
                  let compact = try StudioFillService.wandElementCoverage(document: before, frame: vm.currentFrame,
                    element: element, maximumPixels: StudioSelectionMask.maximumElementProbes),
                  let box = element.selectionBounds?.intersection(CGRect(x: 0, y: 0, width: 128, height: 128)) else {
                throw Failure(message: "Missing real glyph/rounded alpha")
            }
            try require(StudioFillService.wandRequiresAlphaCoverage(element) && compact.width * compact.height < 128 * 128,
                "Glyph/rounded capture used a full-canvas or box-only proxy")
            // Only the compact Wand hit candidate uses this positive-membership
            // contract. Preserve every full RGBA and numeric mask assertion below.
            for y in 0..<128 { for x in 0..<128 {
                let localX = x - compact.x, localY = y - compact.y
                let pixel: UInt8 = localX >= 0 && localY >= 0 && localX < compact.width && localY < compact.height
                    ? compact.bytes[localY * compact.rowStride + localX] : 0
                try require((pixel > 0) == (full[y * 128 + x] > 0), "Cropped native glyph/rounded hit membership differs from the full renderer")
            } }
            guard let maximum = full.max(), maximum > 0, let paintedIndex = full.firstIndex(of: maximum) else {
                throw Failure(message: "Native glyph/rounded fixture has no painted body")
            }
            let painted = CGPoint(x: paintedIndex % 128, y: paintedIndex / 128)
            var gap: CGPoint?
            let left = max(0, Int(ceil(box.minX)) + 2), right = min(127, Int(floor(box.maxX)) - 2)
            let top = max(0, Int(ceil(box.minY)) + 2), bottom = min(127, Int(floor(box.maxY)) - 2)
            for y in top...bottom where gap == nil {
                let ink = (left...right).filter { full[y * 128 + $0] > 0 }
                // For text require a genuine unpainted glyph gap between actual ink,
                // not merely the unused margin of a typography bounding box.
                let start = kind == "rounded" ? left : (ink.first.map { $0 + 1 } ?? right)
                let end = kind == "rounded" ? right : (ink.last.map { $0 - 1 } ?? left)
                if start <= end, let x = (start...end).first(where: { full[y * 128 + $0] == 0 }) { gap = CGPoint(x: x, y: y) }
            }
            guard let gap else { throw Failure(message: "Fixture has no actual glyph gap/rounded empty corner") }
            let visible = try StudioFillService.capture(document: before, frameID: vm.currentFrame.id,
                layerID: vm.activeLayerID, point: gap, color: "#000000", opacity: 1,
                settings: .init(tolerance: 0, contiguous: true, expand: 0, gapClose: 0, antiAlias: false), sampleAllLayers: true)
            let rgba = [UInt8](visible.rgba), gapIndex = (Int(gap.y) * 128 + Int(gap.x)) * 4
            try require(Array(rgba[gapIndex..<gapIndex+4]) == [255,255,255,255], "Chosen glyph gap/corner is not actual visible white")
            vm.selectedTool = .wand; vm.wandSampleVisibleCanvas = true; vm.wandTolerance = 0
            vm.wandContiguous = true; vm.wandFeather = 0; vm.wandMode = .newSelection
            let outside = await vm.selectDrawingRegion(try vm.captureDrawingWand(), at: gap)
            let outsideIDs = try await vm.wandDrawingIDs(at: gap, tolerance: 0, sampleAllLayers: true,
                checkCancellation: { try Task.checkCancellation() })
            try require(outside && vm.selectedElementIDs.isEmpty && outsideIDs.isEmpty && vm.document == before,
                "Visible glyph gap/rounded empty corner falsely selected its bounding box")
            let inside = await vm.selectDrawingRegion(try vm.captureDrawingWand(), at: painted)
            let insideIDs = try await vm.wandDrawingIDs(at: painted, tolerance: 0, sampleAllLayers: true,
                checkCancellation: { try Task.checkCancellation() })
            try require(inside && vm.selectedElementIDs == [element.id] && insideIDs == [element.id], "Actual painted body was not selected independently")
            vm.selectedTool = .move; vm.selectionMode = .new
            guard let move = vm.beginMove(at: painted) else { throw Failure(message: "Wand-selected glyph/rounded body has no Move capture") }
            try require(vm.finishMove(move, delta: .init(width: 2, height: 1)), "Real glyph/rounded Move failed")
            await vm.flush()
            try require(vm.currentFrame.elements.contains(other) && (try render(vm.document)) != beforePixels,
                "Move changed only a label or moved unrelated artwork")
            vm.undo(); await vm.flush()
            try require(vm.document.frames == before.frames && (try render(vm.document)) == beforePixels, "Move Undo lost original glyph/rounded pixels")
            vm.selectedTool = .wand
            let forCopy = await vm.selectDrawingRegion(try vm.captureDrawingWand(), at: painted)
            try require(forCopy && vm.copySelected(), "Actual glyph/rounded selection did not copy")
            vm.pasteClipboard(); await vm.flush()
            let copies = vm.currentFrame.elements.filter { $0.id != element.id && $0.id != other.id }
            try require(copies.count == 1 && copies[0].tool == element.tool && copies[0].text == element.text
                && copies[0].shape == element.shape && copies[0].fillColor == element.fillColor && vm.currentFrame.elements.contains(other),
                "Copy/paste lost glyph/rounded source data or copied unrelated artwork")
            vm.undo(); await vm.flush(); vm.selectedTool = .wand
            let forDelete = await vm.selectDrawingRegion(try vm.captureDrawingWand(), at: painted)
            try require(forDelete && vm.selectedElementIDs == [element.id], "Delete selection lost painted body")
            vm.deleteSelected(); await vm.flush()
            try require(vm.currentFrame.elements == [other], "Delete removed unrelated artwork or retained selected glyph/rounded body")
            vm.undo(); await vm.flush()
            try require(vm.document.frames == before.frames && (try render(vm.document)) == beforePixels, "Delete Undo lost editable glyph/rounded source or pixels")
        } } }
        pass("native glyph gaps and rounded corners do not hit boxes; painted bodies move/copy/delete with exact Undo")
    }

    static func wandSkipsInertHistoricalText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-wand-inert-text-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = DeviceStorageManager(documentsDirectory: root.appendingPathComponent("Documents"),
            cachesDirectory: root.appendingPathComponent("Cache"))
        let vm = StudioViewModel(storage: storage)
        let created = await vm.createProject(name: "Historical inert text", width: 128, height: 128, fps: 12)
        try require(created, "Inert legacy text project creation")
        let inert = [
            DrawnElement(id: UUID().uuidString, tool: .text, points: [], color: "#000000", width: 8,
                opacity: 1, layerID: vm.activeLayerID),
            DrawnElement(id: UUID().uuidString, tool: .text, points: [.init(x: 16, y: 16)], color: "#000000", width: 8,
                opacity: 1, layerID: vm.activeLayerID),
            DrawnElement(id: UUID().uuidString, tool: .text, points: [.init(x: 16, y: 16)], color: "#000000", width: 8,
                opacity: 1, fillColor: "", layerID: vm.activeLayerID),
            DrawnElement(id: UUID().uuidString, tool: .text, points: [.init(x: 16, y: 16)], color: "#000000", width: 8,
                opacity: 1, fillColor: "   ", layerID: vm.activeLayerID),
        ]
        for element in inert {
            try require(element.selectionBounds == nil && !StudioFillService.wandRequiresAlphaCoverage(element),
                "Inert legacy text entered exact-alpha capture instead of its historical skip")
            try require(vm.commitElement(element), "Valid inert legacy text was rejected by the canonical editor")
        }
        let artwork = DrawnElement(id: UUID().uuidString, tool: .line,
            points: [.init(x: 32, y: 64), .init(x: 96, y: 64)], color: "#000000", width: 8,
            opacity: 1, layerID: vm.activeLayerID)
        try require(vm.commitElement(artwork), "Unrelated actual artwork commit failed")
        try vm.document.validate(); await vm.flush()
        let before = vm.document
        vm.selectedTool = .wand; vm.wandSampleVisibleCanvas = true; vm.wandTolerance = 0
        vm.wandContiguous = true; vm.wandFeather = 0; vm.wandMode = .newSelection
        let selected = await vm.selectDrawingRegion(try vm.captureDrawingWand(), at: CGPoint(x: 64, y: 64))
        let typed = try await vm.wandDrawingIDs(at: CGPoint(x: 64, y: 64), tolerance: 0,
            sampleAllLayers: true, checkCancellation: { try Task.checkCancellation() })
        try require(selected && vm.selectedElementIDs == [artwork.id] && typed == [artwork.id]
            && vm.document == before, "An inert historical text record blocked physical/typed Wand on real artwork")
        vm.deleteSelected(); await vm.flush()
        try require(vm.currentFrame.elements == inert, "Wand deleted or rewrote inert historical source records")
        vm.undo(); await vm.flush()
        try require(vm.document.frames == before.frames, "Undo did not restore real artwork beside inert legacy text")
        pass("physical and typed Wand skip valid inert historical text without blocking unrelated artwork")
    }

    static func main() async throws {
        try await vertexAlignedDrawingEnclosure()
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
        vm.activePanel = .toolSettings
        try select(left)
        try require(vm.selectedTool == .move && vm.selectionMode == .new && !vm.selectionPreservesAspect
                    && vm.activePanel == .none && vm.beginSelectionHandle() != nil && vm.beginAreaSelection() == nil,
                    "Lasso must expose free Move handles, dismiss options, and stop capturing lasso gestures")
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

        try select(left)
        try require(vm.selectVisibleArtwork(inverting: true) && vm.selectedElementIDs == [blue.id], "Invert did not complement visible artwork")
        try require(vm.selectVisibleArtwork() && vm.selectedElementIDs == [red.id, blue.id], "Select all lost visible artwork")
        try require(vm.selectVisibleArtwork(inverting: true) && vm.selectedElementIDs.isEmpty, "Invert all must produce explicit empty selection")
        try require(vm.document == initial && vm.canUndo == undoBefore && !vm.isDirty, "Selection actions created document history")
        let selectionBeforeCancel = vm.selectedElementIDs
        try require(!vm.selectVisibleArtwork(checkCancellation: { throw CancellationError() }) && vm.selectedElementIDs == selectionBeforeCancel, "Cancelled All changed selection")
        vm.message = nil
        let guarded = StudioViewModel(storage: DeviceStorageManager(documentsDirectory: root.appendingPathComponent("Eligibility"), cachesDirectory: root.appendingPathComponent("EligibilityCache")))
        let createdGuarded = await guarded.createProject(name: "Selection eligibility", width: 128, height: 128, fps: 12)
        try require(createdGuarded && guarded.commitElement(shape(guarded.activeLayerID)), "Eligibility fixture")
        guarded.selectedTool = .lasso
        guarded.toggleLayerVisibility(guarded.activeLayerID)
        try require(guarded.selectVisibleArtwork() && guarded.selectedElementIDs.isEmpty, "All selected hidden artwork")
        guarded.toggleLayerVisibility(guarded.activeLayerID)
        guarded.toggleLayerLock(guarded.activeLayerID)
        try require(guarded.selectVisibleArtwork(inverting: true) && guarded.selectedElementIDs.isEmpty, "Invert selected locked artwork")
        guarded.toggleLayerLock(guarded.activeLayerID)
        try require(guarded.selectVisibleArtwork() && guarded.selectedElementIDs.count == 1, "Unlock did not restore selection eligibility")
        pass("All and Invert respect visible editable IDs explicit emptiness and cancellation")

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

        vm.selectedTool = .lasso
        vm.areaSelectionKind = .polygon
        vm.areaSelectionSmoothing = 10
        for point in boundary { try require(vm.appendPolygonSelectionVertex(point), "Polygon vertex rejected") }
        let polygonRegion = try StudioSelectionRegion(points: boundary, kind: .polygon, smoothing: 10)
        try require(polygonRegion.points == boundary, "Polygon corners must not inherit freehand smoothing")
        try require(vm.finishPolygonSelection() && vm.selectedElementIDs == [red.id], "Polygon did not select exact enclosed artwork")
        try require(vm.currentPolygonSelectionVertices.isEmpty && vm.document == initial && vm.canUndo == undoBefore, "Polygon altered document/history or retained draft")
        vm.selectedTool = .lasso
        for point in boundary.prefix(2) { try require(vm.appendPolygonSelectionVertex(point), "Polygon draft") }
        try require(!vm.finishPolygonSelection() && vm.currentPolygonSelectionVertices.count == 2, "Invalid polygon discarded editable draft")
        vm.message = nil
        vm.removeLastPolygonSelectionVertex()
        try require(vm.currentPolygonSelectionVertices.count == 1, "Back did not remove one vertex")
        vm.cancelPolygonSelection()
        try require(vm.currentPolygonSelectionVertices.isEmpty && vm.selectedElementIDs == [red.id], "Cancel altered selection")
        try require(!vm.appendPolygonSelectionVertex(.init(x: -1, y: 0)), "Out-of-canvas polygon vertex accepted")
        try require(vm.appendPolygonSelectionVertex(boundary[0]), "Stale test draft")
        vm.selectionMode = .add
        try require(!vm.appendPolygonSelectionVertex(boundary[1]) && vm.currentPolygonSelectionVertices.isEmpty, "Stale polygon continued after mode change")
        vm.message = nil; vm.selectionMode = .new
        for point in notch { try require(vm.appendPolygonSelectionVertex(point), "Concave polygon point") }
        try require(vm.finishPolygonSelection() && vm.selectedElementIDs.isEmpty, "Concave polygon falsely enclosed artwork")
        try require(vm.document == initial && !vm.isDirty, "Transient polygon modified saved project")
        pass("polygon corners remain exact, Back/Cancel preserve artwork and stale/degenerate drafts cannot commit")

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
        try require(vm.selectedElementIDs.isEmpty && vm.beginMove(at: .init(x:24,y:24)) == nil, "Position-locked artwork must not enter a movable lasso group")
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
        vm.selectedTool = .lasso
        guard let capture = vm.beginAreaSelection() else { throw Failure(message: "Missing capture") }
        var checkpoints = 0
        try require(vm.finishAreaSelection(capture, points: left, checkCancellation: {checkpoints += 1}), "Cancellation probe failed")
        for stop in 1...checkpoints {
            try select(all)
            vm.selectedTool = .lasso
            guard let capture = vm.beginAreaSelection() else { throw Failure(message: "Fresh cancellation capture unavailable") }
            var count = 0
            try require(!vm.finishAreaSelection(capture, points: left, checkCancellation: {count += 1; if count == stop {throw CancellationError()}}), "Cancelled selection succeeded")
            try require(count == stop, "Cancellation checkpoint was not exercised")
            try require(vm.document == beforeCancel && vm.selectedElementIDs == selectedBefore, "Cancellation partially changed selection or document")
        }
        try select(all)
        vm.selectedTool = .lasso
        guard let reentrantCapture = vm.beginAreaSelection() else { throw Failure(message: "Fresh reentrant capture unavailable") }
        var callbacks = 0
        try require(!vm.finishAreaSelection(reentrantCapture, points: left, checkCancellation: {callbacks += 1; if callbacks == 2 {vm.clearElementSelection()}}), "Reentrant selection change was overwritten")
        try require(callbacks >= 2 && vm.selectedElementIDs.isEmpty && vm.document == beforeCancel, "Newer user selection was lost or reentrant callback was not exercised")
        pass("every cancellation checkpoint and intervening user selection preserve atomic selection and document state")

        for change in 0..<7 {
            try select(all)
            vm.selectedTool = .lasso
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
        vm.selectedTool = .lasso
        let invalidCapture = vm.beginAreaSelection()!
        try require(!vm.finishAreaSelection(invalidCapture,points:[]) && vm.document == stable && vm.selectedElementIDs == stableIDs, "Invalid input changed actual selection")
        pass("invalid nonfinite degenerate oversized and out-of-range outlines fail without changing production state")
        let legacyStorage = DeviceStorageManager(documentsDirectory: root.appendingPathComponent("LegacyDocuments"), cachesDirectory: root.appendingPathComponent("LegacyCache"))
        let legacyVM = StudioViewModel(storage: legacyStorage)
        let legacyCreated = await legacyVM.createProject(name: "Historical text selection", width: 128, height: 128, fps: 12)
        try require(legacyCreated, "Legacy project creation")
        let legacy = DrawnElement(id: "legacy-text", tool: .text,
            points: [.init(x: 16, y: 48)], color: "#FF0000", width: 8, opacity: 1,
            fillColor: "SDI", layerID: legacyVM.activeLayerID)
        try require(legacyVM.commitElement(legacy), "Historical text commit")
        let originalText = legacyVM.document
        let originalPixels = try render(originalText)
        guard let textBounds = legacy.selectionBounds else { throw Failure(message: "Legacy text has no bounds") }
        try require(textBounds.width > 24 && textBounds.height > 8, "Text still uses the single origin stroke bounds")
        legacyVM.selectedTool = .move
        try require(legacyVM.selectElement(at: .init(x: textBounds.maxX - 2, y: textBounds.midY)) == legacy.id,
                    "Last glyph cannot be selected")
        legacyVM.selectedTool = .lasso; legacyVM.areaSelectionKind = .rectangle
        guard let textCapture = legacyVM.beginAreaSelection() else { throw Failure(message: "Legacy lasso unavailable") }
        try require(legacyVM.finishAreaSelection(textCapture, points: [.init(x: 8, y: 40), .init(x: 120, y: 110)]) &&
                    legacyVM.selectedElementIDs == [legacy.id], "Enclosed historical text not selected")
        legacyVM.deleteSelected(); try require(legacyVM.currentFrame.elements.isEmpty, "Selected historical text not deleted")
        legacyVM.undo(); try require(try render(legacyVM.document) == originalPixels, "Undo changed historical text rendering")
        let legacySaved = await legacyVM.save(); try require(legacySaved, "Historical text save")
        let legacyOpened = StudioViewModel(storage: legacyStorage)
        await legacyOpened.loadProjects()
        guard let legacyMetadata = legacyOpened.savedProjects.first(where: { $0.id == originalText.id }) else { throw Failure(message: "Historical project missing from list") }
        let openedLegacy = await legacyOpened.openProject(legacyMetadata)
        try require(openedLegacy && legacyOpened.currentFrame.elements.first == legacy &&
                    legacyOpened.currentFrame.elements.first?.selectionBounds == textBounds,
                    "Cold reopen rewrote historical text or lost measured bounds")
        pass("historical text glyph bounds support hit testing lasso delete Undo and cold reopen without rewriting originals")

        let lockStorage = DeviceStorageManager(documentsDirectory: root.appendingPathComponent("LockDocuments"), cachesDirectory: root.appendingPathComponent("LockCache"))
        let lockVM = StudioViewModel(storage: lockStorage)
        let lockCreated = await lockVM.createProject(name: "Selected layer locks", width: 128, height: 128, fps: 12)
        try require(lockCreated, "Lock project creation")
        let lockFirst = shape(lockVM.activeLayerID)
        try require(lockVM.commitElement(lockFirst), "First layer artwork")
        lockVM.addLayer(); let lockSecond = shape(lockVM.activeLayerID)
        try require(lockVM.commitElement(lockSecond), "Second layer artwork")
        lockVM.addLayer(); let unaffectedLayer = lockVM.activeLayerID
        func selectLockArtwork() throws {
            lockVM.selectedTool = .lasso
            try require(lockVM.selectVisibleArtwork(), "Select lock artwork")
            lockVM.selectedTool = .move
        }
        try selectLockArtwork()
        guard let lockCapture = lockVM.prepareSelectionLayerLock() else { throw Failure(message: "Missing selected layer capture") }
        try require(lockCapture.layerIDs.count == 2 && !lockCapture.layerIDs.contains(unaffectedLayer), "Wrong layers captured")
        let beforeLock = lockVM.document, lockPixels = try render(lockVM.document)
        var lockCheckpoints = 0
        try require(lockVM.lockSelectedLayers(lockCapture, checkCancellation: { lockCheckpoints += 1 }), "Actual lock transaction failed")
        try require(lockVM.layers.filter(\.isFullyLocked).count == 2 && lockVM.selectedElementIDs.isEmpty &&
                    (try render(lockVM.document)) == lockPixels, "Lock changed rendered artwork or retained selection")
        lockVM.undo()
        try require(lockVM.document.layers == beforeLock.layers && lockVM.document.frames == beforeLock.frames, "One Undo did not restore every layer")
        try selectLockArtwork()
        guard let cancellationCapture = lockVM.prepareSelectionLayerLock() else { throw Failure(message: "No fresh lock capture") }
        let beforeCancellation = lockVM.document, beforeIDs = lockVM.selectedElementIDs
        for stop in 1...lockCheckpoints {
            var calls = 0
            try require(!lockVM.lockSelectedLayers(cancellationCapture, checkCancellation: {
                calls += 1; if calls == stop { throw CancellationError() }
            }) && lockVM.document == beforeCancellation && lockVM.selectedElementIDs == beforeIDs,
                        "Cancelled layer lock partially changed live state")
        }
        lockVM.clearElementSelection()
        try require(!lockVM.lockSelectedLayers(cancellationCapture) && lockVM.document == beforeCancellation, "Stale selection locked layers")
        try selectLockArtwork()
        try require(lockVM.lockSelectedLayers(lockVM.prepareSelectionLayerLock()!), "Final layer lock")
        let lockedDocument = lockVM.document
        try require(!lockVM.commitElement(shape(lockFirst.layerID!)) && lockVM.document == lockedDocument, "Full-locked layer accepted drawing")
        let locksSaved = await lockVM.save(); try require(locksSaved, "Lock save")
        let locksReopened = StudioViewModel(storage: lockStorage); await locksReopened.loadProjects()
        let locksOpened = await locksReopened.openProject(locksReopened.savedProjects.first!)
        try require(locksOpened && locksReopened.layers == lockedDocument.layers && (try render(locksReopened.document)) == lockPixels,
                    "Cold reopen lost locks or changed pixels")
        pass("explicit selected whole-layer locking is atomic reversible cancellation-safe and persistent without changing artwork")
        try await wandNativeButtLinePixels()
        try await wandHighTranslationLinePixels()
        try await wandFilledEllipsePixels()
        try await wandPortraitSmallEllipsesStayWithinBudget()
        try fullCanvasSelectionCoverageKeepsExistingLargeDocumentCapacity()
        try await wandGlyphAndRoundedCornerCoverage()
        try await wandSkipsInertHistoricalText()
        try selectionBodyWinsClampedCornerSlop()
        try await tinyLassoSelectionMovesAfterSharedAdmission()
        try await moveIgnoresEraserRecords()
        try await restoredSelectionPreferencesDriveActualSelection()
        print("PASS \(passed) production area-selection groups")
    }
}
