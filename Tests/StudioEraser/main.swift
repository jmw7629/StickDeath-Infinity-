import AppKit
import SwiftUI
import ImageIO
import AVFoundation

typealias UIImage = NSImage
extension Image { init(uiImage: NSImage) { self.init(nsImage: uiImage) } }
private struct Failure: Error { let message: String }

@main @MainActor struct EraserTests {
    static var passed = 0
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(message: message) }
    }
    static func rejects(_ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw Failure(message: "Invalid operation succeeded")
    }
    static func pass(_ name: String) { passed += 1; print("PASS " + name) }
    static func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let worked = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)); return true
        }
        try require(worked, "Actual native image decode"); return bytes
    }
    static func artwork(_ layer: String, color: String = "#FF0000") -> DrawnElement {
        .init(id: UUID().uuidString, tool: .rectangle, points: [.init(x: 8,y: 8), .init(x: 120,y: 120)],
              color: color, width: 2, opacity: 1, layerID: layer, shape: .init(fillColor: color))
    }
    static func erase(_ layer: String, mode: StudioEraserMode = .hard, strength: Double = 1, width: Double = 32) -> DrawnElement {
        .init(id: UUID().uuidString, tool: .eraser, points: [.init(x: 32,y: 64), .init(x: 96,y: 64)],
              color: "#0000FF", width: width, opacity: strength, layerID: layer, eraser: .init(mode: mode))
    }
    static func document(_ stroke: DrawnElement? = nil) throws -> StudioDocument {
        var doc = try StudioDocument.new(name: "Eraser production",width: 128,height: 128,fps: 12)
        doc.schemaVersion = 5; doc.frames[0].elements = [artwork(doc.activeLayerID)]
        if var stroke { stroke.layerID = doc.activeLayerID; doc.frames[0].elements.append(stroke); if stroke.eraser != nil { doc.schemaVersion = 9 } }
        try doc.validate(); return doc
    }
    static func render(_ doc: StudioDocument, edge: Int = 128, live: DrawnElement? = nil, rasterData: Data? = nil) throws -> [UInt8] {
        let frame = doc.frames[0], prepared = try StudioFrameRenderer.prepare(frame: frame,liveElement: live)
        var error: Error?
        let renderer = ImageRenderer(content: Canvas { context, size in
            error = StudioFrameRenderer.draw(context: &context,frame: frame,layers: doc.layers,
                canvasSize: CGSize(width: doc.width,height: doc.height),size: size,rasterData:rasterData,liveElement: live,preparedBrushes: prepared)
        }.frame(width: CGFloat(edge),height: CGFloat(edge)))
        renderer.scale = 1
        guard let image = renderer.cgImage else { throw Failure(message: "Canonical renderer returned no image") }
        if let error { throw error }; return try pixels(image)
    }
    static func channel(_ bytes: [UInt8], _ x: Int, _ y: Int, _ c: Int = 3, edge: Int = 128) -> UInt8 { bytes[(y * edge + x) * 4 + c] }
    static func multiLayerSelectedErasureRegressions() throws {
        var base = try document()
        base.schemaVersion = 7
        let active = base.activeLayerID, other = "selected-other", background = "unselected-background"
        base.layers += [CanvasLayer(id: other, name: "Other target"), CanvasLayer(id: background, name: "Background")]
        var red = artwork(active)
        red.points = [.init(x: 8, y: 8), .init(x: 56, y: 120)]
        var blue = artwork(other, color: "#0000FF")
        blue.points = [.init(x: 60, y: 8), .init(x: 112, y: 120)]
        blue.translation = .init(x: 8, y: 0)
        let green = artwork(background, color: "#00FF00")
        base.frames[0].elements = [green, blue, red]
        try base.validate()
        let ids: Set<String> = [red.id, blue.id], frame = base.activeFrameID, gesture = erase(active)
        var editor = try StudioDocumentEditor(document: base)
        editor.selectedElementIDs = ids
        let preview = try editor.previewSelectedErasure(gesture, frameID: frame, elementIDs: ids)
        try require(editor.document == base && !editor.canUndo, "Multi-layer preview mutated document/history")
        try editor.eraseSelectedElements(gesture, frameID: frame, elementIDs: ids)
        let result = editor.document
        try require(result.frames[0] == preview && editor.selectedElementIDs == ids
            && result.activeLayerID == active, "Multi-layer preview/commit/selection differ")
        try require(result.frames[0].elements[0] == green, "Unselected background changed")
        for original in [red, blue] {
            let changed = result.frames[0].elements.first { $0.id == original.id }!
            var stripped = changed; stripped.selectionErasures = nil
            try require(stripped == original && changed.selectionErasures?.count == 1,
                "Multi-layer erase changed editable source geometry or missed a target")
            try require(changed.selectionErasures?.first?.pathToElement == original.erasurePlacement().invertedForErasure(),
                "Target did not capture its own inverse placement")
        }
        let actual = try render(result)
        // Fully covered interior samples avoid the documented SwiftUI partial-coverage AA batching edge.
        for x in [32, 96] {
            try require(channel(actual, x, 64, 0) == 0 && channel(actual, x, 64, 1) == 255
                && channel(actual, x, 64, 2) == 0 && channel(actual, x, 64) == 255,
                "Selected targets on distinct layers did not reveal the unselected background")
        }
        try require(channel(actual, 32, 32, 0) == 255 && channel(actual, 96, 32, 2) == 255,
            "Multi-layer erasing changed intact target interiors")
        editor.undo()
        try require(editor.document.frames == base.frames && !editor.canUndo && editor.canRedo,
            "Multi-layer erasure was not a single Undo transaction")
        editor.redo()
        try require(try render(editor.document) == actual, "Multi-layer Redo changed rendered result")
        let archived = try StudioDocumentArchive.decode(StudioDocumentArchive(document: result, rasterFrameIndices: [:]).encoded())
        try require(archived.document.frames == result.frames, "Multi-layer masks did not survive archive round trip")
        pass("multi-layer selected erasure keeps independent transforms unselected pixels and single Undo/Redo/archive")

        for failure in ["full", "position", "alpha", "hidden", "zero", "effect", "stale", "active"] {
            var invalid = base
            switch failure {
            case "full", "position", "alpha": invalid.layers[1].lockMode = failure
            case "hidden": invalid.layers[1].visible = false
            case "zero": invalid.layers[1].opacity = 0
            case "effect":
                invalid.schemaVersion = 18
                invalid.frames[0].elements.append(.init(id: UUID().uuidString, tool: .blur,
                    points: [.init(x: 80, y: 64)], color: "#000000", width: 16, opacity: 0.5,
                    layerID: other, blur: .init()))
            case "active": invalid.layers[0].locked = true
            default: break
            }
            try invalid.validate()
            let selected = failure == "stale" ? ids.union(["missing-drawing"]) : ids
            var rejected = try StudioDocumentEditor(document: invalid)
            rejected.selectedElementIDs = selected
            try rejects { _ = try rejected.previewSelectedErasure(gesture, frameID: frame, elementIDs: selected) }
            try rejects { try rejected.eraseSelectedElements(gesture, frameID: frame, elementIDs: selected) }
            try require(rejected.document == invalid && !rejected.canUndo && !rejected.canRedo
                && rejected.selectedElementIDs == selected, "Multi-layer rejection partially changed \(failure) selection")
        }
        var unrelatedLocked = base
        unrelatedLocked.layers[2].locked = true
        var allowed = try StudioDocumentEditor(document: unrelatedLocked)
        try allowed.eraseSelectedElements(gesture, frameID: frame, elementIDs: ids)
        try require(allowed.document.frames[0].elements[0] == green,
            "An unselected locked layer blocked erasing or changed its content")
        var probe = try StudioDocumentEditor(document: base), checkpoints = 0
        try probe.eraseSelectedElements(gesture, frameID: frame, elementIDs: ids, checkCancellation: { checkpoints += 1 })
        for stop in 1...checkpoints {
            var cancelled = try StudioDocumentEditor(document: base)
            cancelled.selectedElementIDs = ids
            var visits = 0
            try rejects {
                try cancelled.eraseSelectedElements(gesture, frameID: frame, elementIDs: ids, checkCancellation: {
                    visits += 1
                    if visits == stop { throw CancellationError() }
                })
            }
            try require(cancelled.document == base && !cancelled.canUndo && !cancelled.canRedo
                && cancelled.selectedElementIDs == ids, "Multi-layer cancellation partially committed")
        }
        pass("multi-layer hidden locked alpha effect stale and every cancellation checkpoint reject atomically")
    }
    static func selectedErasureRegressions() async throws {
        let base = try document(), layer = base.activeLayerID, frame = base.activeFrameID
        var overlap = base
        let lower = artwork(layer, color: "#0000FF"), upper = artwork(layer)
        overlap.frames[0].elements = [lower, upper]
        var selectedTop = try StudioDocumentEditor(document: overlap)
        selectedTop.selectedElementIDs = [upper.id]
        let gesture = erase(layer)
        for stop in 1...6 {
            var cancelled = try StudioDocumentEditor(document: overlap)
            cancelled.selectedElementIDs = [lower.id, upper.id]
            var checks = 0
            try rejects {
                try cancelled.eraseSelectedElements(gesture, frameID: frame, elementIDs: [lower.id, upper.id], checkCancellation: {
                    checks += 1
                    if checks == stop { throw CancellationError() }
                })
            }
            try require(cancelled.document == overlap && !cancelled.canUndo && !cancelled.canRedo
                && cancelled.selectedElementIDs == [lower.id, upper.id], "Cancelled target processing changed document/history/selection")
        }
        var lockedDoc = overlap; lockedDoc.layers[0].locked = true
        var lockedEditor = try StudioDocumentEditor(document: lockedDoc)
        try rejects { try lockedEditor.eraseSelectedElements(gesture, frameID: frame, elementIDs: [upper.id]) }
        try require(lockedEditor.document == lockedDoc && !lockedEditor.canUndo, "Fully locked flag allowed selected erasure")
        pass("selected erasure cancellation during target processing and full lock preserve document/history/selection")
        let preview = try selectedTop.previewSelectedErasure(gesture, frameID: frame, elementIDs: [upper.id])
        try require(selectedTop.document == overlap && !selectedTop.canUndo, "Selected preview mutated history")
        try selectedTop.eraseSelectedElements(gesture, frameID: frame, elementIDs: [upper.id])
        let masked = selectedTop.document
        try require(masked.frames[0].elements.count == 2 && masked.frames[0].elements[0] == lower
            && masked.frames[0].elements[1].points == upper.points, "Selected erase rewrote source or unselected object")
        var previewDocument = masked; previewDocument.frames[0] = preview
        try require(try render(previewDocument) == render(masked), "Selected preview differs from committed renderer")
        for edge in [64, 128] {
            let p = try render(masked, edge: edge), center = edge / 2
            try require(channel(p, center, center, 0, edge: edge) == 0
                && channel(p, center, center, 2, edge: edge) == 255
                && channel(p, center, center, 3, edge: edge) == 255,
                "Selected upper hole failed to reveal overlapping unselected blue")
            try require(channel(p, center, edge * 5 / 16, 0, edge: edge) == 255,
                "Selected erase escaped its stroke footprint")
        }
        var selectedBottom = try StudioDocumentEditor(document: overlap)
        selectedBottom.selectedElementIDs = [lower.id]
        try selectedBottom.eraseSelectedElements(gesture, frameID: frame, elementIDs: [lower.id])
        let bottomPixels = try render(selectedBottom.document), overlapPixels = try render(overlap)
        let differences = zip(bottomPixels, overlapPixels).enumerated().filter { $0.element.0 != $0.element.1 }
        print("SELECTED_LOWER_DIFF count=\(differences.count) max=\(differences.map { abs(Int($0.element.0)-Int($0.element.1)) }.max() ?? 0) first=\(differences.prefix(12).map { ($0.offset / 4 % 128, $0.offset / 4 / 128, $0.offset % 4, $0.element.0, $0.element.1) })")
        // Known native Canvas clipping limitation, independently reproduced in
        // a minimal platform probe: only these four partially covered lower
        // corners may change. Do not turn this into a general image tolerance.
        let knownCornerChannels = Set([120 * 128 + 120, 120 * 128 + 121,
                                      121 * 128 + 120, 121 * 128 + 121].flatMap { [$0 * 4 + 2, $0 * 4 + 3] })
        try require(differences.count <= 8 && differences.allSatisfy {
            knownCornerChannels.contains($0.offset) && abs(Int($0.element.0)-Int($0.element.1)) <= 34
        }, "Selected lower erase changed pixels outside the characterized native corner limitation")
        for index in stride(from: 0, to: bottomPixels.count, by: 4) {
            try require(bottomPixels[index] == overlapPixels[index], "Selected erase changed unselected upper red coverage")
        }
        try require(selectedBottom.document.frames[0].elements[1] == upper,
            "Selected lower erase mutated unselected upper geometry")
        selectedTop.undo(); try require(try render(selectedTop.document) == render(overlap), "Selected erase Undo changed source")
        selectedTop.redo(); try require(try render(selectedTop.document) == render(masked), "Selected erase Redo lost mask")
        pass("selected upper/lower protected coverage preview two-scale pixels Undo/Redo with characterized four-corner limitation")

        for mode in [StudioEraserMode.hard, .soft] {
            var owner = try StudioDocumentEditor(document: base)
            let target = base.frames[0].elements[0].id
            owner.selectedElementIDs = [target]
            var halfGesture = erase(layer, mode: mode, strength: 0.5)
            halfGesture.points += [.init(x: 32, y: 64), .init(x: 96, y: 64)]
            try owner.eraseSelectedElements(halfGesture, frameID: frame, elementIDs: [target])
            var wholeLayer = base; wholeLayer.schemaVersion = 9; wholeLayer.frames[0].elements.append(halfGesture)
            let actual = try render(owner.document), expected = try render(wholeLayer)
            try require(actual == expected, "Selected mask changed existing hard/soft/strength/crossing semantics")
            try require(channel(actual, 64, 64) >= 127, "One selected gesture compounded strength")
            if mode == .soft { try require(channel(actual, 64, 48) > channel(actual, 64, 64)
                && channel(actual, 64, 48) < 255, "Selected soft edge lost meaningful falloff") }
        }
        pass("selected hard/soft partial strength self-crossing share exact existing mask pixels")

        var transformed = base
        transformed.schemaVersion = 11
        transformed.frames[0].elements[0].transform = .init(a: 0, b: 0.75, c: -0.5, d: 0, tx: 96, ty: 16)
        let target = transformed.frames[0].elements[0].id
        var placed = try StudioDocumentEditor(document: transformed); placed.selectedElementIDs = [target]
        try placed.eraseSelectedElements(gesture, frameID: frame, elementIDs: [target])
        var worldMask = transformed; worldMask.frames[0].elements.append(gesture)
        try require(try render(placed.document) == render(worldMask),
            "Capturing on rotated/nonuniform artwork distorted the circular world-space eraser")
        try placed.translateElements(frameID: frame, ids: [target], dx: 0, dy: 16)
        let moved = try render(placed.document)
        try require(channel(moved, 64, 80) == 0 && channel(moved, 64, 56) == 255,
            "Moving selected artwork left its hole behind or moved original geometry incorrectly")
        try placed.reflectElements(frameID: frame, ids: [target], axis: .horizontal)
        try require(channel(try render(placed.document), 64, 80) == 0, "Reflection detached the hole from symmetric geometry")
        pass("captured full affine mask remains correct through nonuniform rotation move and reflection")

        var copies = try StudioDocumentEditor(document: masked)
        copies.selectedElementIDs = [upper.id]
        try copies.copyElements(frameID: frame, ids: [upper.id])
        let pasted = try copies.pasteElements(frameID: frame, layerID: layer)
        let copy = try requireFirst(copies.document.frames[0].elements.filter { pasted.contains($0.id) })
        try require(copy.id != upper.id && copy.selectionErasures == masked.frames[0].elements[1].selectionErasures,
            "Element clipboard lost independent masked copy")
        try copies.duplicateFrame()
        try require(copies.document.frames[1].elements.filter { $0.selectionErasures != nil }.count == 2,
            "Frame duplication discarded selected erasures")
        try copies.duplicateLayer(layer)
        try require(copies.document.frames[0].elements.filter { $0.selectionErasures != nil }.count == 4,
            "Layer duplication discarded selected erasures")
        let bytes = try StudioDocumentArchive(document: copies.document, rasterFrameIndices: [:]).encoded()
        try require(StudioDocumentArchive.decode(bytes).document == copies.document, "Masked clones changed during archive roundtrip")
        pass("masked element/frame/layer clones retain editable originals descriptors and archive identities")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-selected-eraser-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = DeviceStorageManager(documentsDirectory: root.appendingPathComponent("Documents"), cachesDirectory: root.appendingPathComponent("Caches"))
        let metadata = AnimationMetadata(id: masked.id, title: masked.name, fps: masked.fps,
            canvasWidth: 128, canvasHeight: 128, frameCount: 1, layerCount: 1,
            createdAt: masked.createdAt, modifiedAt: masked.modifiedAt, thumbnailData: nil)
        try storage.saveAnimation(AnimationProject(id: masked.id, metadata: metadata,
            frames: [StoredAnimationFrame(imageData: nil, layerData: nil)], audioTracks: [],
            editableDocumentData: StudioDocumentArchive(document: masked, rasterFrameIndices: [:]).encoded()))
        let cold = StudioViewModel(storage: storage)
        let opened = await cold.openProject(metadata)
        try require(opened && cold.document == masked && render(cold.document) == render(masked),
            "Real cold project load lost selected masks or overlap isolation")
        let output = try await StudioExportService().export(document: cold.document, format: .pngSequence,
            outputParent: root, background: .transparent)
        guard let source = CGImageSourceCreateWithURL(output.imageURLs[0] as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure(message: "Selected-erasure PNG cannot decode") }
        try require(try pixels(image) == render(masked), "Real PNG differs from saved selected-erasure artwork")
        await cold.flush()
        pass("real storage cold reopen and decoded PNG retain selected holes and unselected overlap")
        let vmStore = DeviceStorageManager(documentsDirectory: root.appendingPathComponent("vm-documents"), cachesDirectory: root.appendingPathComponent("vm-caches"))
        let vm = StudioViewModel(storage: vmStore)
        let vmCreated = await vm.createProject(name: "Selected eraser VM", width: 128, height: 128, fps: 12)
        try require(vmCreated, "Selected VM project creation failed")
        let vmLower = artwork(vm.activeLayerID, color: "#0000FF"), vmUpper = artwork(vm.activeLayerID)
        try require(vm.commitElement(vmLower) && vm.commitElement(vmUpper), "Selected VM source fixture rejected")
        await vm.flush()
        vm.selectedTool = .move; vm.selectionMode = .new
        try require(vm.selectElement(at: CGPoint(x: 64, y: 64)) == vmUpper.id, "Actual selection did not target upper drawing")
        vm.selectedTool = .eraser
        guard let staleCapture = vm.captureEraserInput() else { throw Failure(message: "Selected VM capture unavailable") }
        let vmGesture = erase(vm.activeLayerID)
        vm.clearElementSelection()
        let beforeStale = vm.document, beforeUndo = vm.canUndo, beforeRedo = vm.canRedo
        try rejects { _ = try vm.eraserInputPreview(staleCapture, element: vmGesture) }
        try require(!vm.commitEraserInput(staleCapture, element: vmGesture) && vm.document == beforeStale
            && vm.canUndo == beforeUndo && vm.canRedo == beforeRedo, "Stale selected eraser broadened to whole-layer erase")
        vm.selectedTool = .move; vm.selectionMode = .new
        try require(vm.selectElement(at: CGPoint(x: 64, y: 64)) == vmUpper.id, "Fresh real selection failed")
        vm.selectedTool = .eraser
        guard let capture = vm.captureEraserInput() else { throw Failure(message: "Fresh selected capture unavailable") }
        try require(vm.beginStrokeInput(id: vmGesture.id), "Selected eraser input ownership unavailable")
        let vmPreview = try vm.eraserInputPreview(capture, element: vmGesture)
        try require(vm.commitEraserInput(capture, element: vmGesture), "Current selected eraser commit failed")
        vm.finishStrokeInput(id: vmGesture.id)
        var previewState = vm.document; previewState.frames[0] = vmPreview
        let committedPixels = try render(vm.document)
        try require(try render(previewState) == committedPixels && vm.currentFrame.elements[0] == vmLower
            && vm.selectedElementIDs == [vmUpper.id], "VM preview/commit changed unselected artwork or selection")
        vm.undo(); try require(vm.document.frames[0].elements == [vmLower, vmUpper], "VM selected erasure Undo changed original drawings")
        vm.redo(); try require(try render(vm.document) == committedPixels, "VM selected erasure Redo changed holes")
        let vmSaved = await vm.save(); try require(vmSaved, "Actual selected VM save failed")
        let vmCold = StudioViewModel(storage: vmStore); await vmCold.loadProjects()
        let vmMetadata = try requireFirst(vmCold.savedProjects)
        let vmOpened = await vmCold.openProject(vmMetadata)
        try require(vmOpened, "Actual selected VM cold reopen failed")
        try require(vmCold.document == vm.document && render(vmCold.document) == committedPixels,
            "Actual selected VM persistence lost masks/history result")
        await vmCold.flush(); await vm.flush()
        pass("actual selected capture rejects selection changes and commits preview Undo/Redo save/cold without broadening")
    }

    static func main() async throws {
        setbuf(stdout,nil)
        var legacy = erase("old",strength: 0.3,width: 8); legacy.eraser = nil
        let encoded = try JSONEncoder().encode(legacy)
        try require(!String(decoding: encoded,as: UTF8.self).contains("\"eraser\":{"), "Historical eraser gained descriptor")
        try require(JSONDecoder().decode(DrawnElement.self,from: encoded) == legacy, "Historical optional decoding changed")
        let oldDoc = try document(legacy), oldPixels = try render(oldDoc)
        try require(oldDoc.schemaVersion == 5 && channel(oldPixels,64,64) == 0 && channel(oldPixels,64,48) > 250,
                    "Historical clear mode and triple-width footprint changed")
        pass("historical descriptor-free erasers retain original clear pixels and encoding")

        let full = try document(erase("x")), fullPixels = try render(full)
        let half = try document(erase("x",strength: 0.5)), halfPixels = try render(half)
        let zero = try document(erase("x",strength: 0)), zeroPixels = try render(zero)
        try require(channel(fullPixels,64,64) == 0 && channel(fullPixels,64,40) == 255, "Hard eraser real footprint")
        print("ERASER_HALF_ALPHA=\(channel(halfPixels,64,64))")
        try require((126...129).contains(Int(channel(halfPixels,64,64))) && channel(halfPixels,64,40) == 255, "Strength applied once")
        try require(try render(document()) == zeroPixels, "Zero strength changes pixels")
        var crossing = half; crossing.frames[0].elements[1].points += [.init(x:32,y:64),.init(x:96,y:64)]
        let crossingPixels = try render(crossing)
        print("CROSSING_ALPHA=\(channel(crossingPixels,64,64)) MAX_DIFF=\(zip(crossingPixels,halfPixels).map{abs(Int($0)-Int($1))}.max() ?? 0) CHANGED=\(zip(crossingPixels,halfPixels).filter{$0 != $1}.count)")
        // Retracing changes antialiased boundary coverage at round joins. Test
        // the actual contract: one gesture cannot remove more than its 50%
        // strength, including at crossings; two separate gestures can.
        for y in 10..<118 { for x in 10..<118 {
            try require(channel(crossingPixels,x,y) >= 127, "Self overlap exceeds captured strength")
        } }
        for x in 34...94 { try require(channel(crossingPixels,x,64) == channel(halfPixels,x,64), "Center strength compounds on retrace") }
        var repeated = half; let second = erase(repeated.activeLayerID,strength:0.5); repeated.frames[0].elements.append(second)
        try require((62...65).contains(Int(channel(try render(repeated),64,64))), "Separate strokes should accumulate")
        pass("hard size strength zero self-crossing and repeated strokes change actual alpha correctly")

        let soft = try document(erase("x",mode:.soft)), softPixels = try render(soft)
        let softHalf = try render(document(erase("x",mode:.soft,strength:0.5)))
        let center = channel(softPixels,64,64), feather = channel(softPixels,64,48), outside = channel(softPixels,64,38)
        print("SOFT_ALPHA center=\(center) edge=\(feather) outside=\(outside)")
        try require(center < 40 && (80...200).contains(Int(feather)) && outside > feather && outside < 255,
                    "Soft eraser must produce a real graduated edge")
        try require(channel(softHalf,64,64) > 120 && channel(softHalf,64,64) < 155 && softPixels != fullPixels,
                    "Soft strength must differ from hard and full strength")
        let doubled = try render(soft,edge:256)
        try require(abs(Int(channel(doubled,128,96,edge:256)) - Int(feather)) < 10, "Soft radius is in document units")
        var dot = soft; dot.frames[0].elements[1].points = [.init(x:64,y:64)]
        let dotPixels = try render(dot)
        try require(channel(dotPixels,64,64) < 60 && channel(dotPixels,20,64) > 250, "Single tap produces bounded soft dot")
        pass("soft eraser has actual feather pixels at native and scaled sizes and single taps")

        var layered = full
        let lower = CanvasLayer(id:"lower",name:"Lower")
        layered.layers.append(lower); layered.frames[0].elements.insert(artwork(lower.id,color:"#0000FF"),at:0)
        let layeredPixels = try render(layered)
        try require(channel(layeredPixels,64,64,2) == 255 && channel(layeredPixels,64,64) == 255 && channel(layeredPixels,64,40,0) == 255,
                    "Erasing top layer damaged lower layer")
        layered.layers[0].visible = false
        let hidden = try render(layered)
        try require(channel(hidden,64,40,2) == 255, "Hidden layer erase affected visible lower content")
        var layerHalf = half; layerHalf.layers[0].opacity = 0.5
        try require((62...65).contains(Int(channel(try render(layerHalf),64,64))), "Layer opacity must apply after erasing")
        let live = erase(soft.activeLayerID,mode:.soft)
        var base = soft; base.frames[0].elements.removeLast()
        try require(try render(base,live:live) == softPixels, "Live preview differs from committed pixels")
        pass("active layer isolation visibility opacity and live preview share exact eraser composition")

        for mode in ["full","position","alpha"] {
            var locked = try document(); locked.layers[0].lockMode = mode
            var editor = try StudioDocumentEditor(document:locked)
            try rejects { try editor.commit(erase(locked.activeLayerID),frameID:locked.activeFrameID) }
            try require(editor.document == locked && !editor.canUndo, "Locked eraser changed document/history")
        }
        for opacity in [0.0,1.0] {
            var unavailable = try document(); unavailable.layers[0].opacity = opacity
            unavailable.layers[0].visible = opacity == 0
            var editor = try StudioDocumentEditor(document:unavailable)
            try rejects { try editor.commit(erase(unavailable.activeLayerID),frameID:unavailable.activeFrameID) }
            try require(editor.document == unavailable, "Hidden or transparent layer erased")
        }
        var selected = try StudioDocumentEditor(document:document()); selected.selectedElementIDs = [selected.document.frames[0].elements[0].id]
        let selectedBefore = selected.document
        try rejects { try selected.commit(erase(selectedBefore.activeLayerID),frameID:selectedBefore.activeFrameID) }
        try require(selected.document == selectedBefore && !selected.canUndo, "Eraser silently escaped selected bounds")
        pass("full position alpha hidden zero-opacity and selection guards reject without mutation")

        for mutation in 0..<7 {
            var bad = full
            switch mutation {
            case 0: bad.schemaVersion = 8
            case 1: bad.frames[0].elements[1].eraser?.version = 2
            case 2: bad.frames[0].elements[1].tool = .brush
            case 3: bad.frames[0].elements[1].shape = .init()
            case 4: bad.frames[0].elements[1].width = .nan
            case 5: bad.frames[0].elements[1].points = []
            default: bad.frames[0].elements[1].points = Array(repeating:.init(x:64,y:64),count:8193)
            }
            try rejects { try bad.validate() }
        }
        var oversized = full
        oversized.frames[0].elements += (0..<256).map { _ in erase(full.activeLayerID) }
        try rejects { try oversized.validate() }
        var editor = try StudioDocumentEditor(document:document())
        let before = editor.document
        try editor.commit(erase(before.activeLayerID,mode:.soft),frameID:before.activeFrameID)
        let drawn = try render(editor.document)
        editor.copyFrame(); editor.undo()
        try require(editor.document.schemaVersion == 5 && render(editor.document) == render(before), "Undo restores schema and original pixels")
        editor.redo(); try require(try render(editor.document) == drawn, "Redo changed erased pixels")
        editor.undo(); try editor.pasteFrame()
        try require(editor.document.schemaVersion == 9 && editor.document.frames[1].elements.last?.eraser?.mode == .soft,
                    "Clipboard after undo loses eraser or version")
        try editor.duplicateLayer(editor.document.activeLayerID)
        try require(editor.document.frames[1].elements.filter{$0.eraser != nil}.count == 2, "Layer duplication loses erasers")
        let archive = try StudioDocumentArchive(document:editor.document,rasterFrameIndices:[:]).encoded()
        try require(StudioDocumentArchive.decode(archive).document == editor.document, "Eraser archive roundtrip changed")
        pass("schema limits undo redo frame clipboard layer duplication and archive preserve erasers")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-eraser-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        defer { try? FileManager.default.removeItem(at:root) }
        let suite = "sdi-eraser-preferences-" + UUID().uuidString
        let defaults = UserDefaults(suiteName:suite)!; defer { defaults.removePersistentDomain(forName:suite) }
        let storage = DeviceStorageManager(documentsDirectory:root.appendingPathComponent("Documents"),cachesDirectory:root.appendingPathComponent("Caches"))
        let vm = StudioViewModel(storage:storage,toolDefaults:defaults)
        let created = await vm.createProject(name:"Saved eraser",width:128,height:128,fps:12)
        try require(created && vm.commitElement(artwork(vm.activeLayerID)), "Actual VM artwork setup")
        vm.selectedTool = .eraser; vm.eraserMode = .soft; vm.strokeWidth = 32; vm.strokeOpacity = 0.5
        let date = Date(timeIntervalSince1970:100)
        var input = StudioStrokeInput(id:"captured",frameID:vm.currentFrame.id,layerID:vm.activeLayerID,
            tool:.eraser,color:vm.strokeColorHex,width:vm.strokeWidth,opacity:vm.strokeOpacity,brush:nil,
            documentSize:CGSize(width:128,height:128),viewportSize:CGSize(width:256,height:256),startedAt:date,
            eraser:try vm.eraserDescriptor())
        try input.append(location:CGPoint(x:64,y:128),time:date)
        try input.append(location:CGPoint(x:192,y:128),time:date.addingTimeInterval(0.2))
        vm.eraserMode = .hard; vm.strokeOpacity = 1
        try require(input.element.eraser?.mode == .soft && input.element.opacity == 0.5, "In-flight preferences not frozen")
        try require(vm.beginStrokeInput(id:input.id), "Actual touch begins")
        vm.interruptStrokeInput(input,reason:"Layout changed")
        try require(vm.currentFrame.elements.count == 1, "Interrupted eraser committed")
        vm.finishStrokeInput(id:input.id); vm.discardRejectedBrush()
        try require(vm.commitElement(input.element), "Actual VM commits captured eraser")
        let savedPixels = try render(vm.document)
        vm.undo(); try require(vm.currentFrame.elements.count == 1, "VM undo eraser")
        vm.redo(); try require(try render(vm.document) == savedPixels, "VM redo exact eraser")
        vm.eraserMode = .soft
        let saved = await vm.save(); try require(saved, "Production device save")
        let reopened = StudioViewModel(storage:storage,toolDefaults:defaults); await reopened.loadProjects()
        let metadata = try requireFirst(reopened.savedProjects)
        let opened = await reopened.openProject(metadata); reopened.selectedTool = .eraser
        try require(opened && reopened.eraserMode == .soft && render(reopened.document) == savedPixels,
                    "Actual cold reopen lost mode or pixels")
        pass("actual touch interruption frozen settings VM undo redo device save and cold reopen preserve pixels")

        let output = try await StudioExportService().export(document:reopened.document,format:.pngSequence,outputParent:root,background:.transparent)
        guard let source = CGImageSourceCreateWithURL(output.imageURLs[0] as CFURL,nil), let image = CGImageSourceCreateImageAtIndex(source,0,nil) else { throw Failure(message:"Actual PNG cannot reopen") }
        try require(try pixels(image) == savedPixels, "Export PNG differs from live eraser")
        pass("real transparent PNG reopens with exact saved eraser pixels")

        let baseOutput = try await StudioExportService().export(document:document(),format:.pngSequence,outputParent:root,background:.transparent)
        let rasterBytes = try Data(contentsOf:baseOutput.imageURLs[0])
        var imported = reopened.document
        imported.frames[0].elements.removeFirst()
        imported.frames[0].rasterAssetID = "real-imported-png"
        imported.frames[0].rasterLayerID = imported.activeLayerID
        imported.frames[0].rasterPlacement = .init(x:0,y:0,width:128,height:128)
        try imported.validate()
        let importedPixels = try render(imported,rasterData:rasterBytes)
        print("RASTER_ERASER center=\(channel(importedPixels,64,64)) expected=\(channel(savedPixels,64,64)) maxDiff=\(zip(importedPixels,savedPixels).map{abs(Int($0)-Int($1))}.max() ?? 0)")
        // A decoded PNG and a vector boundary can differ under image sampling.
        // The opaque interior must nevertheless receive the identical mask.
        for y in 20..<108 { for x in 20..<108 {
            try require(abs(Int(channel(importedPixels,x,y))-Int(channel(savedPixels,x,y))) <= 1,
                        "Imported raster interior did not receive the same eraser mask")
        } }
        let importedOutput = try await StudioExportService().export(document:imported,format:.pngSequence,outputParent:root,background:.transparent,rasterData:{ _ in rasterBytes })
        guard let importedSource = CGImageSourceCreateWithURL(importedOutput.imageURLs[0] as CFURL,nil),
              let importedImage = CGImageSourceCreateImageAtIndex(importedSource,0,nil) else { throw Failure(message:"Erased imported PNG cannot reopen") }
        try require(try pixels(importedImage) == importedPixels && Data(contentsOf:baseOutput.imageURLs[0]) == rasterBytes,
                    "Erased raster export changed pixels or original bytes")
        pass("managed raster erasing shares live/export coverage and preserves original PNG bytes")

        let movie = try await StudioMovieExportService().export(snapshot:.init(document:reopened.document,
            retainedAudioTracks:[],rasterDataByID:[:]),outputParent:root,background:.white)
        let asset = AVURLAsset(url:try movie.checkedURLs()[0])
        let tracks = try await asset.loadTracks(withMediaType:.video)
        try require(tracks.count == 1, "Actual eraser MP4 video track")
        let reader = try AVAssetReader(asset:asset)
        let trackOutput = AVAssetReaderTrackOutput(track:tracks[0],outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        reader.add(trackOutput); try require(reader.startReading(), "Actual MP4 decode starts")
        var frames = 0
        while let sample = trackOutput.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { throw Failure(message:"MP4 lacks decoded pixels") }
            try require(CVPixelBufferGetWidth(buffer) == 128 && CVPixelBufferGetHeight(buffer) == 128, "MP4 dimensions")
            CVPixelBufferLockBaseAddress(buffer,.readOnly)
            let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to:UInt8.self), row = CVPixelBufferGetBytesPerRow(buffer)
            var totalError = 0
            for y in 0..<128 { for x in 0..<128 {
                let offset = (y*128+x)*4, decoded = y*row+x*4
                let white = 255-Int(savedPixels[offset+3])
                for c in 0..<3 { totalError += abs(Int(bytes[decoded+2-c])-Int(savedPixels[offset+c])-white) }
            } }
            let centerGreen = bytes[64*row+64*4+1]
            CVPixelBufferUnlockBaseAddress(buffer,.readOnly)
            let mean = Double(totalError)/Double(128*128*3)
            print("ERASER_MP4_MEAN_RGB_ERROR=\(mean)")
            try require(mean < 8 && (100...165).contains(Int(centerGreen)), "Actual MP4 lacks correct soft erasure/strength")
            try require(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample),.zero) == 0, "MP4 frame timestamp")
            frames += 1
        }
        let duration = try await asset.load(.duration)
        try require(reader.status == .completed && frames == 1 && CMTimeCompare(duration,CMTime(value:1,timescale:12)) == 0, "Actual MP4 complete frames and timing")
        try movie.cleanup()
        pass("real H264 MP4 decodes with saved eraser pixels strength dimensions and timing")

        var commands = try StudioDocumentEditor(document:document())
        let stroke = erase(commands.document.activeLayerID,mode:.soft,strength:0.5)
        func request(_ strokes: [StudioCommandStroke]) -> StudioCommandRequest {
            .init(requestID:UUID(),projectID:commands.document.id,expectedRevision:commands.document.revision,
                  action:.apply([.draw(.init(frame:.id(commands.document.activeFrameID),layer:.id(commands.document.activeLayerID),strokes:strokes))]))
        }
        let command = StudioCommandStroke(id:stroke.id,tool:stroke.tool,points:stroke.points,color:stroke.color,width:stroke.width,opacity:stroke.opacity,eraser:stroke.eraser)
        let wire = try JSONEncoder().encode(request([command]))
        let invalidWire = String(decoding:wire,as:UTF8.self).replacingOccurrences(of:"\"mode\":\"soft\"",with:"\"mode\":\"soft\",\"unknownOperation\":true")
        try require(invalidWire != String(decoding:wire,as:UTF8.self), "Wire invalid-field fixture")
        try rejects { _ = try StudioCommandExecutor.decode(Data(invalidWire.utf8)) }
        _ = try StudioCommandExecutor.execute(StudioCommandExecutor.decode(wire),editor:&commands)
        try require(try render(commands.document) == savedPixels, "Typed Spatter path differs from manual eraser")
        let commandBefore = commands.document
        var invalid = command; invalid.eraser?.version = 99
        try rejects { _ = try StudioCommandExecutor.execute(request([invalid]),editor:&commands) }
        try require(commands.document == commandBefore, "Invalid eraser command partially applied")
        var cancellationCalls = 0
        try rejects { _ = try StudioCommandExecutor.execute(request([command]),editor:&commands,checkCancellation:{ cancellationCalls += 1; throw CancellationError() }) }
        try require(cancellationCalls > 0 && commands.document == commandBefore, "Cancellation changed eraser document")
        pass("typed validated Spatter erasers use identical production pixels and reject failure/cancellation")
        var preferences = StudioDrawingToolPreferences()
        preferences.values[DrawingTool.eraser.rawValue] = .init(width:20,opacity:0.6,eraserMode:.soft)
        var oldPreferences = try JSONSerialization.jsonObject(with:preferences.encoded()) as! [String:Any]
        var values = oldPreferences["values"] as! [String:[String:Any]]
        values[DrawingTool.eraser.rawValue]?.removeValue(forKey:"eraserMode"); oldPreferences["values"] = values
        let decoded = try StudioDrawingToolPreferences.decode(JSONSerialization.data(withJSONObject:oldPreferences))
        try require(decoded.settings(for:.eraser).width == 20 && decoded.settings(for:.eraser).opacity == 0.6 && decoded.settings(for:.eraser).eraserMode == nil,
                    "Earlier version1 preferences lost custom values")
        pass("existing version1 tool preferences without eraser mode decode unchanged")
        try await selectedErasureRegressions()
        try multiLayerSelectedErasureRegressions()
        print("\(passed) production eraser groups passed")
    }
    static func requireFirst<T>(_ values:[T]) throws -> T {
        guard let first = values.first else { throw Failure(message:"Production saved project list is empty") }; return first
    }
}
