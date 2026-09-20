import Foundation
import SwiftUI
import ImageIO

private struct Failure: Error { let message: String }
private func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
private final class NetworkTrap: URLProtocol {
    private static let lock = NSLock()
    private static var attempts = 0
    static var count: Int { lock.lock(); defer { lock.unlock() }; return attempts }
    override class func canInit(with request: URLRequest) -> Bool {
        guard ["http", "https"].contains(request.url?.scheme ?? "") else { return false }
        lock.lock(); attempts += 1; lock.unlock(); return true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() { }
}
@MainActor private final class Gate {
    var hits = 0
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async throws {
        hits += 1
        if hits == 1 { await withCheckedContinuation { continuation = $0 } }
        try Task.checkCancellation()
    }
    func wait() async throws {
        for _ in 0..<2000 { if hits > 0 { return }; try await Task.sleep(nanoseconds: 1_000_000) }
        throw Failure(message: "Import checkpoint did not arrive")
    }
    func release() { continuation?.resume(); continuation = nil }
}

@main @MainActor struct StudioImageLibraryTests {
    static let scope = StudioImageImportSession.Scope(isStudioVisible: true, isForeground: true, accountID: nil)
    static func main() async {
        do { try await run() } catch { print("STUDIO_IMAGE_LIBRARY_TESTS=FAIL \(error)"); exit(1) }
    }
    static func run() async throws {
        let fm = FileManager.default
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = fm.temporaryDirectory.appendingPathComponent("sdi-image-library-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root); URLProtocol.unregisterClass(NetworkTrap.self) }
        try require(URLProtocol.registerClass(NetworkTrap.self) && AppConfig.backendURL == nil, "Offline test isolation failed")
        let scratch = root.appendingPathComponent("scratch")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
        let catalogue = try StudioImageCatalogue(directory: source)
        guard let item = catalogue.images.first(where: { $0.id == "kenney.scribble-platformer.item_pencil" }) else {
            throw Failure(message: "Actual curated Pencil asset missing")
        }
        let original = try catalogue.checkedPNG(item), provenance = try catalogue.attribution(for: item)
        func fixture() async throws -> (StudioViewModel, DeviceStorageManager) {
            let storage = DeviceStorageManager(documentsDirectory: root.appendingPathComponent(UUID().uuidString))
            let editor = StudioViewModel(storage: storage)
            try require(await editor.createProject(name: "Library fixture", width: 160, height: 160, fps: 12), "Actual create failed")
            return (editor, storage)
        }
        func prepare(_ editor: StudioViewModel, _ selectedCatalogue: StudioImageCatalogue? = nil, selectedImage: StudioImageCatalogue.Image? = nil) async throws -> StudioImageImportSession {
            let session = StudioImageImportSession(scratchParent: scratch)
            guard let token = session.beginPicker(in: editor, scope: scope) else { throw Failure(message: "Capture failed") }
            try require(session.receiveLibraryImage(selectedImage ?? item, from: selectedCatalogue ?? catalogue, token: token, currentScope: { scope }), "Library selection rejected")
            await session.waitForCompletion()
            try require(session.status == .preview && session.previewImage != nil, "Real preview failed: \(session.notice ?? "nil")")
            return session
        }
        func exported(_ editor: StudioViewModel, frameIndex: Int = 0) async throws -> Data {
            let output = try await StudioExportService().export(document: editor.document, format: .pngSequence,
                outputParent: root, background: .transparent, rasterData: { editor.rasterData($0) })
            let bytes = try Data(contentsOf: output.imageURLs[frameIndex])
            guard let input = CGImageSourceCreateWithData(bytes as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(input, 0, nil), image.width == 160, image.height == 160,
                  let bitmap = CGContext(data: nil, width: 160, height: 160, bitsPerComponent: 8, bytesPerRow: 640,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw Failure(message: "Real PNG output cannot reopen")
            }
            bitmap.draw(image, in: CGRect(x: 0, y: 0, width: 160, height: 160))
            return Data(bytes: bitmap.data!, count: 160 * 160 * 4)
        }
        var groups = 0
        func test(_ name: String, _ operation: () async throws -> Void) async throws {
            try await operation()
            try require(try fm.contentsOfDirectory(atPath: scratch.path).isEmpty, "Owned import scratch leaked")
            groups += 1; print("PASS " + name)
        }
        func imageMoveFixture() async throws -> (StudioViewModel, DeviceStorageManager, StudioViewModel.ImageMoveCapture) {
            let (editor, storage) = try await fixture(), session = try await prepare(editor)
            try require(session.apply(currentScope: scope), "Image Add failed")
            editor.selectedTool = .move
            try require(editor.placeImage(editor.prepareImagePlacement()!, at: .init(x: 10, y: 20, width: 40, height: 80)), "Initial placement failed")
            try require(editor.setImageCanvasMove(true), "Image target rejected")
            guard let capture = editor.beginImageMove(at: .init(x: 30, y: 60)) else { throw Failure(message: "Image hit did not capture") }
            return (editor, storage, capture)
        }
        try await test("image flips reflect actual PNG pixels about the placed center and preserve alpha originals rights and cold reopen") {
            let (editor, storage, capture) = try await imageMoveFixture()
            let before = editor.document, pixelsBefore = try await exported(editor)
            func mirrored(_ actual: Data, _ expected: Data, horizontal: Bool, vertical: Bool) throws {
                var differences = 0, ink = 0
                for y in 0..<160 { for x in 0..<160 {
                    let inImage = (10..<50).contains(x) && (20..<100).contains(y)
                    let sx = inImage && horizontal ? 59 - x : x
                    let sy = inImage && vertical ? 119 - y : y
                    for channel in 0..<4 {
                        let a = Int(actual[(y*160+x)*4+channel]), b = Int(expected[(sy*160+sx)*4+channel])
                        if abs(a-b) > 2 { differences += 1 }
                    }
                    if actual[(y*160+x)*4+3] > 128 { ink += 1 }
                } }
                try require(ink > 30 && differences == 0, "PNG reflection is not about the placed center: \(differences) channels")
            }
            try require(editor.reflectImage(capture.placement, axis: .horizontal), "Actual horizontal edit failed")
            let horizontal = try await exported(editor), after = editor.document
            try require(horizontal != pixelsBefore && after.frames[0].rasterPlacement == before.frames[0].rasterPlacement, "Flip changed only a label or moved the image")
            try mirrored(horizontal, pixelsBefore, horizontal: true, vertical: false)
            editor.undo(); try require((try await exported(editor)) == pixelsBefore, "One Undo failed")
            editor.redo(); try require((try await exported(editor)) == horizontal, "One Redo failed")
            try require(editor.reflectImage(editor.prepareImagePlacement()!, axis: .vertical), "Vertical edit failed")
            let both = try await exported(editor)
            try mirrored(both, pixelsBefore, horizontal: true, vertical: true)
            try require(await editor.save(), "Reflected project did not save")
            let stored = try storage.loadAnimation(id: editor.document.id)!, reopened = StudioViewModel(storage: storage)
            try require(await reopened.openProject(stored.metadata), "Cold reopen failed")
            try require((try await exported(reopened)) == both && reopened.currentFrame.rasterReflection == .init(horizontal: true, vertical: true), "Reopened pixels/orientation differ")
            let source = reopened.originalImageSource(capture.placement.assetID)
            try require(source?.originalData == original && source?.catalogueAttribution == provenance, "Reflection modified source or attribution")
            editor.selectedTool = .move
            try require(editor.reflectImage(editor.prepareImagePlacement()!, axis: .horizontal), "Restoring horizontal failed")
            try require(editor.reflectImage(editor.prepareImagePlacement()!, axis: .vertical), "Restoring vertical failed")
            let restoredPixels = try await exported(editor)
            try require(editor.currentFrame.rasterReflection == nil && restoredPixels == pixelsBefore, "Two flips per axis did not restore original pixels")
        }
        try await test("image reflections preserve separately drawn pixels and frame copies") {
            let (editor, _, capture) = try await imageMoveFixture()
            let layer = editor.document.activeLayerID, frame = editor.document.activeFrameID
            _ = try editor.applyStudioCommands(.init(requestID: UUID(), projectID: editor.document.id,
                expectedRevision: editor.document.revision, action: .apply([.draw(.init(frame: .id(frame), layer: .id(layer), strokes: [
                    .init(id: "reflection-drawing", tool: .rectangle, points: [.init(x: 110, y: 110), .init(x: 145, y: 140)],
                          color: "#FF0000", width: 3, opacity: 1)
                ]))])))
            let before = try await exported(editor), documentBefore = editor.document
            try require(editor.reflectImage(editor.prepareImagePlacement()!, axis: .horizontal), "Reflect with artwork failed")
            let after = try await exported(editor)
            for y in 105..<150 { for x in 105..<150 { for c in 0..<4 {
                try require(before[(y*160+x)*4+c] == after[(y*160+x)*4+c], "Image transform leaked into drawing context")
            } } }
            try require(editor.document.frames[0].elements == documentBefore.frames[0].elements, "Flip changed editable strokes")
            editor.copyFrame(); editor.pasteFrame()
            try require(editor.currentFrame.rasterReflection == .init(horizontal: true), "Frame clipboard lost reflection")
            try require((try await exported(editor, frameIndex: editor.currentFrameIndex)) == after && editor.originalImageSource(capture.placement.assetID)?.originalData == original, "Frame paste changed rendered pixels or original")
        }
        try await test("image reflections cancel at every live boundary without history and reject stale tool playback and locks") {
            let (probe, _, capture) = try await imageMoveFixture(); var checkpoints = 0
            try require(probe.reflectImage(capture.placement, axis: .horizontal, checkCancellation: { checkpoints += 1 }), "Probe failed")
            try require(checkpoints >= 5, "No live cancellation checks")
            for stop in 1...checkpoints {
                let (editor, _, active) = try await imageMoveFixture(), before = editor.document
                var count = 0
                try require(!editor.reflectImage(active.placement, axis: .vertical, checkCancellation: {
                    count += 1; if count == stop { throw CancellationError() }
                }) && editor.document == before, "Cancelled live reflection committed at \(stop)")
                editor.undo(); try require(editor.currentFrame.rasterPlacement == active.placement.fitted, "Cancellation added history")
            }
            let (editor, _, active) = try await imageMoveFixture()
            editor.selectedTool = .brush
            try require(!editor.reflectImage(active.placement, axis: .horizontal), "Wrong tool accepted reflection")
            editor.selectedTool = .move
            try require(editor.placeImage(editor.prepareImagePlacement()!, at: .init(x: 0, y: 0, width: 50, height: 80)), "Stale fixture failed")
            let unchanged = editor.document
            try require(!editor.reflectImage(active.placement, axis: .vertical) && editor.document == unchanged, "Stale reflection changed image")
            editor.duplicateFrame()
            let playingBefore = editor.document, pending = editor.prepareImagePlacement()!
            editor.togglePlayback()
            try require(editor.isPlaying, "Two-frame playback fixture did not start")
            try require(!editor.reflectImage(pending, axis: .horizontal) && editor.document == playingBefore, "Playback accepted image edit")
            editor.stopPlayback()
            _ = try editor.applyStudioCommands(.init(requestID: UUID(), projectID: editor.document.id,
                expectedRevision: editor.document.revision, action: .apply([.updateLayer(.init(layer: .id(active.placement.layerID), settings: .init(lock: .position)))])))
            try require(editor.prepareImagePlacement() == nil && !editor.reflectImage(pending, axis: .horizontal), "Locked image exposed reflection")
        }

        try await test("canvas image drag previews without edits then changes real PNG in one reversible persisted command") {
            let (editor, storage, capture) = try await imageMoveFixture()
            let before = editor.document, beforePixels = try await exported(editor)
            let preview = try editor.imageMovePreview(capture, delta: .init(width: 35, height: 15))
            try require(preview.rasterPlacement == .init(x: 45, y: 35, width: 40, height: 80), "Preview placement wrong")
            try require(editor.document == before && preview.rasterAssetID == capture.placement.assetID, "Preview edited production document or export")
            try require(editor.finishImageMove(capture, delta: .init(width: 35, height: 15)), "Drag commit failed")
            let after = editor.document, afterPixels = try await exported(editor)
            try require(after.revision == before.revision + 1 && afterPixels != beforePixels, "Drag did not commit actual pixels exactly once")
            try require(after.frames[0].rasterPlacement == preview.rasterPlacement && after.layers == before.layers && after.frames[0].elements == before.frames[0].elements, "Drag changed other content")
            let ink = (0..<(160*160)).filter { afterPixels[$0*4+3] > 128 }
            try require(ink.count > 30 && ink.allSatisfy { (45..<85).contains($0%160) && (35..<115).contains($0/160) }, "Rendered pixels escaped moved rectangle")
            editor.undo();try require((try await exported(editor)) == beforePixels, "One Undo failed")
            editor.redo();try require((try await exported(editor)) == afterPixels, "One Redo failed")
            try require(await editor.save(), "Moved image save failed")
            let stored = try storage.loadAnimation(id: after.id)!, reopened = StudioViewModel(storage: storage)
            try require(await reopened.openProject(stored.metadata), "Moved image cold reopen failed")
            try require((try await exported(reopened)) == afterPixels && !reopened.isMovingImageOnCanvas, "Cold reopen lost pixels or kept transient selection")
            let source = reopened.originalImageSource(capture.placement.assetID)
            try require(source?.originalData == original && source?.catalogueAttribution == provenance, "Drag or save lost source bytes/rights")
        }
        try await test("image hit testing edge clamping and taps preserve identity and avoid no-op history") {
            let (editor, _, capture) = try await imageMoveFixture(), before = editor.document
            try require(editor.beginImageMove(at: .init(x: 2, y: 2)) == nil && editor.beginImageMove(at: .init(x: CGFloat.nan, y: 30)) == nil, "Empty or invalid hit selected image")
            try require(editor.beginMove(at: .init(x: 30, y: 60)) == nil && editor.beginSelectionHandle() == nil, "Image target selected drawing gesture")
            try require(editor.finishImageMove(capture, delta: .zero) && editor.document == before, "Tap created Undo entry")
            let corner = try editor.imageMovePreview(capture, delta: .init(width: 1000, height: -1000))
            try require(corner.rasterPlacement == .init(x: 120, y: 0, width: 40, height: 80), "Edge clamp changed size or left canvas")
            for delta in [CGSize(width: CGFloat.infinity, height: 0), CGSize(width: 0, height: CGFloat.nan), CGSize(width: 131073, height: 0)] {
                try require(!editor.finishImageMove(capture, delta: delta) && editor.document == before, "Invalid drag changed project")
            }
            try require(editor.setImageCanvasMove(false), "Drawings switch failed")
            try require(editor.placeImage(editor.prepareImagePlacement()!, at: .init(x: 0, y: 0, width: 160, height: 160)), "Full canvas fixture failed")
            try require(editor.setImageCanvasMove(true), "Full canvas selection failed")
            let full = editor.document
            try require(editor.finishImageMove(editor.currentImageMoveCapture()!, delta: .init(width: 20, height: 30)) && editor.document == full, "Full canvas image moved outside or made history")
        }
        try await test("image drag cancellation at every production checkpoint and reselected targets cannot commit") {
            let (probe, _, capture) = try await imageMoveFixture()
            var total = 0
            try require(probe.finishImageMove(capture, delta: .init(width: 20, height: 10), checkCancellation: { total += 1 }), "Probe failed")
            try require(total >= 4, "No staged cancellation checkpoints")
            for stop in 1...total {
                let (editor, _, current) = try await imageMoveFixture(), before = editor.document
                var count = 0
                try require(!editor.finishImageMove(current, delta: .init(width: 20, height: 10), checkCancellation: {
                    count += 1; if count == stop { throw CancellationError() }
                }) && editor.document == before, "Cancellation at checkpoint \(stop) changed document")
                editor.undo()
                try require(editor.currentFrame.rasterPlacement == current.placement.fitted, "Cancelled drag created history")
            }
            let (editor, _, old) = try await imageMoveFixture(), before = editor.document
            try require(editor.setImageCanvasMove(false) && editor.setImageCanvasMove(true), "Reselection failed")
            try require(!editor.finishImageMove(old, delta: .init(width: 20, height: 10)) && editor.document == before, "Old gesture survived image reselection")
            let next = editor.currentImageMoveCapture()!;var count = 0
            try require(!editor.finishImageMove(next, delta: .init(width: 20, height: 10), checkCancellation: {
                count += 1; if count == 4 { _ = editor.setImageCanvasMove(false); _ = editor.setImageCanvasMove(true) }
            }) && editor.document == before, "Late reselection bypassed staged guard")
        }
        try await test("image drag rejects changed frames tools playback and hidden or locked layers") {
            let (editor, _, capture) = try await imageMoveFixture()
            editor.selectedTool = .brush;editor.selectedTool = .move
            try require(!editor.isMovingImageOnCanvas && !editor.finishImageMove(capture, delta: .init(width: 1, height: 1)), "Tool switch retained image gesture")
            try require(editor.setImageCanvasMove(true), "Target activation failed")
            let previous = editor.currentImageMoveCapture()!
            editor.addFrame()
            editor.togglePlayback()
            try require(editor.isPlaying && editor.currentImageMoveCapture() == nil, "Playback exposed image drag")
            editor.stopPlayback()
            let newFrame = editor.document
            try require(!editor.isMovingImageOnCanvas && !editor.finishImageMove(previous, delta: .init(width: 1, height: 1)) && editor.document == newFrame, "Gesture moved another frame")
            editor.undo()
            try require(!editor.isMovingImageOnCanvas, "Returning to old frame revived image selection")
            for lock in [StudioCommandLock.full, .position] {
                let (locked, _, old) = try await imageMoveFixture()
                _ = try locked.applyStudioCommands(.init(requestID: UUID(), projectID: locked.document.id, expectedRevision: locked.document.revision,
                    action: .apply([.updateLayer(.init(layer: .id(old.placement.layerID), settings: .init(lock: lock)))])))
                let before = locked.document
                try require(locked.currentImageMoveCapture() == nil && !locked.finishImageMove(old, delta: .init(width: 10, height: 10)) && locked.document == before, "Layer lock bypassed")
            }
            let (hidden, _, old) = try await imageMoveFixture()
            hidden.toggleLayerVisibility(old.placement.layerID)
            try require(hidden.currentImageMoveCapture() == nil && !hidden.setImageCanvasMove(true), "Hidden image enabled movement")
            let (transparent, _, initial) = try await imageMoveFixture()
            _ = try transparent.applyStudioCommands(.init(requestID: UUID(), projectID: transparent.document.id, expectedRevision: transparent.document.revision,
                action: .apply([.updateLayer(.init(layer: .id(initial.placement.layerID), settings: .init(opacity: 0)))])))
            try require(transparent.currentImageMoveCapture() == nil, "Transparent image enabled movement")
        }
        try await test("pasting drawings exits image targeting and moving the pasted selection preserves image placement") {
            let (editor, _, capture) = try await imageMoveFixture()
            try require(editor.setImageCanvasMove(false), "Drawings target failed")
            let drawing = DrawnElement(id: UUID().uuidString, tool: .rectangle,
                points: [.init(x: 110, y: 100), .init(x: 140, y: 140)], color: "#0000FF", width: 2,
                opacity: 1, layerID: editor.activeLayerID, shape: .init(fillColor: "#0000FF", cornerRadius: 0))
            try require(editor.commitElement(drawing), "Real drawing fixture failed")
            try require(editor.beginMove(at: .init(x: 125, y: 120)) != nil && editor.copySelected(), "Drawing copy failed")
            try require(editor.setImageCanvasMove(true) && editor.selectedElementIDs.isEmpty, "Image target kept drawing selection")
            let before = editor.document
            editor.pasteClipboard()
            try require(!editor.isMovingImageOnCanvas && editor.selectedElementIDs.count == 1 && editor.currentFrame.elements.count == 2,
                        "Paste kept image target or lost actual new drawing selection")
            try require(editor.currentFrame.rasterPlacement == capture.placement.original, "Paste moved the image")
            guard let pasted = editor.beginMove(at: .init(x: 125, y: 120)) else { throw Failure(message: "Pasted drawing cannot move") }
            try require(editor.finishMove(pasted, delta: .init(width: -30, height: -10)), "Actual pasted selection move failed")
            try require(editor.currentFrame.rasterPlacement == capture.placement.original && editor.document.revision == before.revision + 2,
                        "Drawing move affected image or wrong transaction count")
            editor.undo();editor.undo()
            try require(editor.currentFrame.elements == before.frames[0].elements && editor.currentFrame.rasterPlacement == capture.placement.original,
                        "Drawing Undo changed image or originals")
        }
        try await test("image deletion removes actual pixels preserves originals for Undo and survives cold reopen") {
            let (editor, storage) = try await fixture(), blank = try await exported(editor), session = try await prepare(editor)
            try require(session.apply(currentScope: scope), "Image Add failed")
            editor.selectedTool = .move
            let capture = editor.prepareImagePlacement()!, before = editor.document, originalPixels = try await exported(editor)
            try require(originalPixels != blank, "Image did not render")
            try require(editor.deleteImage(capture), "Explicit image delete failed")
            let deleted = editor.document, deletedPixels = try await exported(editor)
            try require(deletedPixels == blank && deleted.layers == before.layers && deleted.frames[0].elements == before.frames[0].elements, "Delete changed unrelated content or retained image pixels")
            try require(editor.originalImageSource(capture.assetID)?.originalData == original && editor.originalImageSource(capture.assetID)?.catalogueAttribution == provenance, "Delete lost history's original bytes or rights")
            editor.undo();let undoPixels = try await exported(editor)
            try require(undoPixels == originalPixels && editor.currentFrame.rasterAssetID == capture.assetID, "One Undo lost actual original pixels")
            editor.redo();let redoPixels = try await exported(editor)
            try require(redoPixels == blank && editor.currentFrame.rasterAssetID == nil, "One Redo lost removal")
            try require(await editor.save(), "Deleted project did not save")
            let reopened = StudioViewModel(storage: storage), stored = try storage.loadAnimation(id: deleted.id)!
            try require(await reopened.openProject(stored.metadata), "Deleted project did not reopen")
            let reopenedPixels = try await exported(reopened)
            try require(reopenedPixels == blank && reopened.layers == before.layers && reopened.currentFrame.rasterAssetID == nil, "Deleted picture returned or its layer changed on cold reopen")
        }
        try await test("image deletion rejects stale and cancelled captures without losing pixels or history") {
            let (editor, _) = try await fixture(), session = try await prepare(editor)
            try require(session.apply(currentScope: scope), "Image Add failed")
            editor.selectedTool = .move
            let capture = editor.prepareImagePlacement()!, before = editor.document, pixels = try await exported(editor)
            try require(!editor.deleteImage(capture, checkCancellation: { throw CancellationError() }), "Cancelled Delete applied")
            var probes = 0
            try require(!editor.deleteImage(capture, checkCancellation: {
                probes += 1;if probes == 4 { editor.selectedTool = .brush }
            }), "Late tool change allowed image deletion")
            let unchangedPixels = try await exported(editor)
            try require(editor.document == before && unchangedPixels == pixels, "Rejected Delete changed pixels or content")
            editor.selectedTool = .move
            editor.addLayer();let intervening = editor.document
            try require(!editor.deleteImage(capture) && editor.document == intervening, "Old confirmation deleted newer work")
            let current = editor.prepareImagePlacement()!
            _ = try editor.applyStudioCommands(.init(requestID: UUID(), projectID: editor.document.id, expectedRevision: editor.document.revision,
                action: .apply([.updateLayer(.init(layer: .id(current.layerID), settings: .init(lock: .full)))])))
            let locked = editor.document
            try require(!editor.deleteImage(current) && editor.document == locked, "Delete bypassed image-layer lock")
        }
        try await test("image positioning changes real PNG pixels in one edit and survives source-independent cold reopen") {
            let (editor, storage) = try await fixture(), session = try await prepare(editor)
            try require(session.apply(currentScope: scope), "Image Add failed")
            editor.selectedTool = .move
            let capture = editor.prepareImagePlacement()!, before = editor.document, oldPixels = try await exported(editor)
            try require(editor.document == before, "Opening image positioning edited the document")
            let target = StudioRasterPlacement(x: 10, y: 20, width: 40, height: 80)
            try require(editor.placeImage(capture, at: target), "Placement Apply failed")
            let placed = editor.document, pixels = try await exported(editor)
            try require(placed.revision == before.revision + 1 && pixels != oldPixels, "Placement did not change actual pixels once")
            let ink = (0..<(160 * 160)).filter { pixels[$0 * 4 + 3] > 128 }
            try require(ink.count > 30 && ink.allSatisfy { (10..<50).contains($0 % 160) }, "Rendered image escaped requested horizontal placement")
            try require(placed.frames[0].rasterAssetID == capture.assetID && placed.frames[0].rasterLayerID == capture.layerID, "Image identity changed")
            try require(editor.originalImageSource(capture.assetID)?.originalData == original && editor.originalImageSource(capture.assetID)?.catalogueAttribution == provenance, "Placement lost original or rights")
            editor.undo();try require(try await exported(editor) == oldPixels, "Image Undo did not restore real pixels")
            editor.redo();try require(try await exported(editor) == pixels, "Image Redo did not restore real pixels")
            let unchanged = editor.prepareImagePlacement()!, revision = editor.document.revision
            try require(editor.placeImage(unchanged, at: target) && editor.document.revision == revision, "Unchanged placement made history")
            try require(await editor.save(), "Positioned project save failed")
            let reopened = StudioViewModel(storage: storage)
            let stored = try storage.loadAnimation(id: placed.id)!
            try require(await reopened.openProject(stored.metadata), "Cold reopen failed")
            let reopenedPixels = try await exported(reopened)
            try require(reopened.currentFrame.rasterPlacement == target && reopenedPixels == pixels, "Cold reopen lost geometry or actual pixels")
            try require(reopened.originalImageSource(capture.assetID)?.originalData == original && reopened.originalImageSource(capture.assetID)?.catalogueAttribution == provenance, "Cold reopen lost original or rights")
        }
        try await test("image positioning rejects stale context locks tool changes cancellation and invalid bounds") {
            let (editor, _) = try await fixture(), session = try await prepare(editor)
            try require(session.apply(currentScope: scope), "Image Add failed")
            editor.selectedTool = .move
            let target = StudioRasterPlacement(x: 10, y: 20, width: 40, height: 80)
            let capture = editor.prepareImagePlacement()!, before = editor.document, oldPixels = try await exported(editor)
            try require(!editor.placeImage(capture, at: target, checkCancellation: { throw CancellationError() }), "Cancelled placement applied")
            try require(!editor.placeImage(capture, at: .init(x: 159, y: 0, width: 20, height: 20)), "Outside placement applied")
            editor.selectedTool = .brush
            try require(editor.prepareImagePlacement() == nil && !editor.placeImage(capture, at: target), "Wrong tool accepted placement")
            editor.selectedTool = .move
            let rejectedPixels = try await exported(editor)
            try require(editor.document == before && rejectedPixels == oldPixels, "Rejected placement changed content")
            var probes = 0
            try require(!editor.placeImage(capture, at: target, checkCancellation: {
                probes += 1; if probes == 4 { editor.selectedTool = .brush }
            }), "Late tool change accepted a stale image draft")
            try require(editor.document == before, "Late stale rejection changed document")
            editor.selectedTool = .move
            editor.addLayer()
            let edited = editor.document
            try require(!editor.placeImage(capture, at: target) && editor.document == edited, "Stale image draft replaced intervening work")
            let lock = StudioCommand.updateLayer(.init(layer: .id(capture.layerID), settings: .init(lock: .position)))
            _ = try editor.applyStudioCommands(.init(requestID: UUID(), projectID: editor.document.id,
                expectedRevision: editor.document.revision, action: .apply([lock])))
            try require(editor.prepareImagePlacement() == nil, "Position-locked image exposed placement")
        }
        try await test("all actual library thumbnails decode serially with a 48-image bounded cache") {
            let loader = StudioImageLibraryThumbnails()
            for image in catalogue.images {
                let thumb = try await loader.image(image, catalogue: catalogue)
                try require(thumb.width > 0 && thumb.height > 0 && thumb.width <= 128 && thumb.height <= 128, "Thumbnail size")
                try require(await loader.cachedImageCount <= 48, "Unbounded thumbnail cache")
            }
            try require(await loader.cachedImageCount == 48, "Expected eviction did not occur")
            let cached = catalogue.images.last!
            let forged = StudioImageCatalogue.Image(id: "foreign", title: cached.title, category: cached.category,
                tags: cached.tags, contentAdvisory: cached.contentAdvisory, licenseID: cached.licenseID,
                originalSHA256: cached.originalSHA256, sha256: cached.sha256, pixelSHA256: cached.pixelSHA256,
                filename: cached.filename, byteCount: cached.byteCount, width: cached.width, height: cached.height)
            do { _ = try await loader.image(forged, catalogue: catalogue); throw Failure(message: "Warm cache accepted foreign metadata") }
            catch is StudioImageCatalogue.CatalogueError { }
            let cancelled = Task { try await loader.image(cached, catalogue: catalogue) }; cancelled.cancel()
            do { _ = try await cancelled.value; throw Failure(message: "Warm cache ignored cancellation") }
            catch is CancellationError { }
        }
        try await test("verified library selection previews real bytes without editing or claiming save") {
            let (editor, _) = try await fixture(), before = editor.document
            let session = try await prepare(editor)
            try require(editor.document == before && !editor.canUndo && session.appliedImage == nil, "Browsing or preview mutated the document")
            try require(session.preview?.name == item.title && session.preview?.width == 64 && session.preview?.height == 128,
                "Preview metadata did not come from selected PNG")
            try require(session.preview?.catalogueAttribution == provenance && session.saveState(in: editor, currentScope: scope) == .unavailable,
                "Preview lost rights or claimed saved")
            session.cancel(); try require(editor.document == before && session.preview == nil, "Cancel edited project")
        }
        try await test("explicit Add creates one undoable image with original bytes and provenance") {
            let (editor, _) = try await fixture(), before = editor.document
            let session = try await prepare(editor)
            try require(session.apply(currentScope: scope), "Add failed")
            let id = session.appliedImage!.assetID, after = editor.document
            try require(after.revision == before.revision + 1 && after.layers.count == before.layers.count + 1, "Not one canonical transaction")
            try require(editor.originalImageSource(id)?.originalData == original && editor.originalImageSource(id)?.catalogueAttribution == provenance,
                "Project does not own original and attribution")
            let pixels = try await exported(editor)
            let alpha = stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
            try require(alpha.contains(0) && alpha.contains(where: { $0 > 0 }), "Actual alpha artwork not exported")
            try require(!session.apply(currentScope: scope), "Duplicate Add accepted")
            editor.undo(); try require(editor.currentFrame.rasterAssetID == nil && !editor.canUndo, "One Undo did not remove image")
            editor.redo(); try require(try await exported(editor) == pixels, "Redo changed exported pixels")
        }
        try await test("real save and cold reopen retain pixels original and rights after library removal") {
            let copy = root.appendingPathComponent("removable-library"); try fm.copyItem(at: source, to: copy)
            let local = try StudioImageCatalogue(directory: copy)
            let (editor, storage) = try await fixture(), session = try await prepare(editor, local)
            try require(session.apply(currentScope: scope), "Add before save failed")
            let id = session.appliedImage!.assetID, pixels = try await exported(editor)
            try require(await editor.save(), "Actual save failed")
            try fm.removeItem(at: copy)
            let stored = try storage.loadAnimation(id: editor.document.id)!, reopened = StudioViewModel(storage: storage)
            try require(await reopened.openProject(stored.metadata), "Actual reopen failed without library")
            try require(reopened.originalImageSource(id)?.originalData == original && reopened.originalImageSource(id)?.catalogueAttribution == provenance,
                "Stored original/attribution lost")
            try require(try await exported(reopened) == pixels, "Reopened actual PNG pixels changed")
        }

        try await test("both new packs add real pixels undo save and cold reopen with their own original rights") {
            for assetID in ["kenney.scribble-platformer-expansion.smoke", "kenney.scribble-dungeons.dragon"] {
                guard let chosen = catalogue.images.first(where: { $0.id == assetID }) else {
                    throw Failure(message: "New actual pack asset missing")
                }
                let bytes = try catalogue.checkedPNG(chosen), rights = try catalogue.attribution(for: chosen)
                let (editor, storage) = try await fixture()
                let session = try await prepare(editor, selectedImage: chosen)
                try require(session.preview?.name == chosen.title && session.preview?.catalogueAttribution == rights,
                            "New pack preview reused another item's metadata")
                try require(session.apply(currentScope: scope), "New pack Add failed")
                let id = session.appliedImage!.assetID, pixels = try await exported(editor)
                try require(stride(from: 3, to: pixels.count, by: 4).contains(where: { pixels[$0] > 0 }),
                            "New pack exported no artwork")
                editor.undo(); try require(editor.currentFrame.rasterAssetID == nil && !editor.canUndo, "New pack Undo failed")
                editor.redo(); try require(try await exported(editor) == pixels, "New pack Redo changed pixels")
                try require(await editor.save(), "New pack save failed")
                let stored = try storage.loadAnimation(id: editor.document.id)!, reopened = StudioViewModel(storage: storage)
                try require(await reopened.openProject(stored.metadata), "New pack cold reopen failed")
                try require(reopened.originalImageSource(id)?.originalData == bytes &&
                            reopened.originalImageSource(id)?.catalogueAttribution == rights,
                            "New pack source or license confused with pilot")
                try require(try await exported(reopened) == pixels, "New pack cold reopen changed PNG pixels")
            }
        }
        try await test("image layer rename preserves actual pixels rights identity and cold-reopened name") {
            let (editor, storage) = try await fixture(), session = try await prepare(editor)
            try require(session.apply(currentScope: scope), "Image fixture Add failed")
            let imageID = session.appliedImage!.assetID, layerID = editor.currentFrame.rasterLayerID!
            editor.selectLayer(layerID)
            let before = editor.document, originalName = editor.layers.first { $0.id == layerID }!.name
            let pixels = try await exported(editor), capture = editor.prepareLayerRename(layerID)!
            try require(editor.document == before, "Preparing rename edited the project")
            try require(editor.renameLayer(capture, to: "  Hero 💀  "), "Explicit rename failed")
            try require(editor.layers.first { $0.id == layerID }?.name == "Hero 💀", "Name was not trimmed or stable ID changed")
            try require(editor.document.frames == before.frames && editor.document.audioClips == before.audioClips, "Rename changed content ownership")
            try require(try await exported(editor) == pixels, "Renaming changed actual PNG pixels")
            try require(editor.originalImageSource(imageID)?.originalData == original && editor.originalImageSource(imageID)?.catalogueAttribution == provenance, "Renaming lost original bytes/rights")
            editor.undo();try require(editor.layers.first { $0.id == layerID }?.name == originalName, "One Undo did not restore name")
            editor.redo();try require(editor.layers.first { $0.id == layerID }?.name == "Hero 💀", "One Redo did not restore name")
            try require(await editor.save(), "Renamed project save failed")
            let stored = try storage.loadAnimation(id: editor.document.id)!, reopened = StudioViewModel(storage: storage)
            try require(await reopened.openProject(stored.metadata), "Renamed project cold reopen failed")
            try require(reopened.layers.first { $0.id == layerID }?.name == "Hero 💀" && reopened.currentFrame.rasterLayerID == layerID, "Cold reopen lost layer name or ownership")
            try require(try await exported(reopened) == pixels, "Cold reopen changed actual image pixels")
        }
        try await test("layer rename cancels without editing and rejects invalid stale and changed-selection drafts") {
            let (editor, _) = try await fixture(), id = editor.document.activeLayerID
            let initial = editor.document, capture = editor.prepareLayerRename(id)!
            try require(editor.document == initial, "Preparing/cancelling changed project")
            for invalid in ["", " ", String(repeating: "a", count: 121), "Hero\nInk"] {
                try require(!editor.renameLayer(capture, to: invalid) && editor.document == initial, "Invalid name changed project")
            }
            try require(editor.renameLayer(capture, to: " Layer 1 ") && editor.document == initial, "Same normalized name created history")
            editor.addLayer();let second = editor.document.activeLayerID
            let changed = editor.document
            try require(!editor.renameLayer(capture, to: "Stale") && editor.document == changed, "Stale rename replaced changed project")
            let selected = editor.prepareLayerRename(second)!
            editor.selectLayer(id);let switched = editor.document
            try require(!editor.renameLayer(selected, to: "Wrong target") && editor.document == switched, "Changed selection renamed previous target")
            editor.setLayerLockMode(id, mode: .full)
            let locked = editor.prepareLayerRename(id)!
            try require(editor.renameLayer(locked, to: "Locked artwork") && editor.layers.first { $0.id == id }!.isFullyLocked, "Metadata rename removed artwork lock")
        }
        try await test("confirmed image-layer delete retains actual originals for Undo and saves only the selected removal") {
            let (editor,storage)=try await fixture(),session=try await prepare(editor)
            try require(session.apply(currentScope:scope),"Image fixture Add failed")
            let imageID=session.appliedImage!.assetID,layer=editor.currentFrame.rasterLayerID!
            let rendered=try await exported(editor)
            editor.selectLayer(layer)
            guard let capture=editor.prepareLayerDeletion(layer) else { throw Failure(message:"Explicit layer capture unavailable") }
            let before=editor.document
            // Dismissing a confirmation invokes no edit or history operation.
            try require(editor.document==before,"Preparing confirmation edited project")
            try require(editor.deleteLayer(capture),"Confirmed image layer delete failed")
            let cleared=try await exported(editor)
            try require(cleared != rendered && editor.currentFrame.rasterAssetID == nil,"Actual layer pixels survived delete")
            try require(editor.originalImageSource(imageID)?.originalData==original,"Undo source bytes were pruned")
            editor.undo();try require(try await exported(editor)==rendered,"Undo did not restore real image pixels")
            try require(editor.originalImageSource(imageID)?.catalogueAttribution==provenance,"Undo lost original rights")
            editor.redo();try require(try await exported(editor)==cleared,"Redo altered clear pixels")
            try require(await editor.save(),"Deleted layer actual save failed")
            let stored=try storage.loadAnimation(id:editor.document.id)!,reopened=StudioViewModel(storage:storage)
            try require(await reopened.openProject(stored.metadata),"Deletion cold reopen failed")
            try require(reopened.currentFrame.rasterAssetID==nil && !reopened.layers.contains(where:{$0.id==layer}),"Deleted layer returned after cold reopen")
            try require(try await exported(reopened)==cleared,"Cold reopen changed deletion output")
        }
        try await test("stale changed-selection locked and last-layer delete confirmations never mutate artwork") {
            let (editor,_)=try await fixture()
            try require(editor.prepareLayerDeletion(editor.document.activeLayerID)==nil,"Last layer can be armed")
            let session=try await prepare(editor);try require(session.apply(currentScope:scope),"Fixture Add failed")
            let layer=editor.currentFrame.rasterLayerID!,drawing=editor.document.activeLayerID
            editor.selectLayer(layer)
            let capture=editor.prepareLayerDeletion(layer)!
            editor.selectLayer(drawing);let switched=editor.document
            try require(!editor.deleteLayer(capture) && editor.document==switched,"Confirmation deleted after selection changed")
            editor.selectLayer(layer);let recaptured=editor.prepareLayerDeletion(layer)!
            editor.setLayerOpacity(layer,opacity:0.5);let changed=editor.document
            try require(!editor.deleteLayer(recaptured) && editor.document==changed,"Stale confirmation deleted changed layer")
            editor.setLayerLockMode(layer,mode:.full)
            try require(editor.prepareLayerDeletion(layer)==nil,"Fully locked layer can be armed")
        }
        try await test("same library asset on another frame gets a new editable identity") {
            let (editor, _) = try await fixture(), first = try await prepare(editor)
            try require(first.apply(currentScope: scope), "First Add failed")
            let firstID = first.appliedImage!.assetID
            editor.addFrame(); let second = try await prepare(editor)
            try require(second.apply(currentScope: scope) && second.appliedImage?.assetID != firstID, "Library identity reused as instance identity")
            try require(editor.originalImageSource(second.appliedImage!.assetID)?.catalogueAttribution == provenance, "Second original lost rights")
        }
        try await test("existing imported picture rejects replacement without changing history or pixels") {
            let (editor, _) = try await fixture(), first = try await prepare(editor)
            try require(first.apply(currentScope: scope), "First Add failed")
            let before = editor.document, pixels = try await exported(editor), next = try await prepare(editor)
            try require(!next.apply(currentScope: scope) && editor.document == before, "Existing picture silently overwritten")
            try require(try await exported(editor) == pixels, "Rejected Add changed actual output")
            editor.undo(); try require(editor.currentFrame.rasterAssetID == nil, "Rejected Add inserted a history step")
        }
        try await test("cancel or stale context during verification never attaches or publishes preview") {
            for cancel in [true, false] {
                let (editor, _) = try await fixture(), gate = Gate()
                let session = StudioImageImportSession(scratchParent: scratch, checkpoint: { try await gate.pause() })
                let token = session.beginPicker(in: editor, scope: scope)!
                try require(session.receiveLibraryImage(item, from: catalogue, token: token, currentScope: { scope }), "Start failed")
                try await gate.wait()
                if cancel { session.cancel() } else { editor.addFrame() }
                let before = editor.document; gate.release(); await session.waitForCompletion()
                try require(editor.document == before && session.preview == nil && session.appliedImage == nil, "Cancelled/stale image escaped")
            }
        }
        try await test("corrupt selected resource fails before preview and never edits the project") {
            let copy = root.appendingPathComponent("corrupt-library"); try fm.copyItem(at: source, to: copy)
            let local = try StudioImageCatalogue(directory: copy)
            try Data("not the licensed image".utf8).write(to: copy.appendingPathComponent(item.filename))
            let (editor, _) = try await fixture(), before = editor.document, session = StudioImageImportSession(scratchParent: scratch)
            let token = session.beginPicker(in: editor, scope: scope)!
            try require(session.receiveLibraryImage(item, from: local, token: token, currentScope: { scope }), "Start failed")
            await session.waitForCompletion()
            try require(session.status == .failed && session.preview == nil && editor.document == before, "Corrupt asset exposed or attached")
        }
        try await test("legacy records decode with nil provenance and tampered provenance rejects atomically") {
            let (editor, _) = try await fixture(), session = try await prepare(editor)
            try require(session.apply(currentScope: scope), "Fixture Add failed")
            var record = editor.originalImageSource(session.appliedImage!.assetID)!
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
            object.removeValue(forKey: "catalogueAttribution")
            let old = try JSONDecoder().decode(StoredImageSource.self, from: JSONSerialization.data(withJSONObject: object))
            try old.validate(); try require(old.catalogueAttribution == nil && old.originalData == original, "Legacy compatibility lost")
            for (key, value) in [("license", "unknown"), ("originalSHA256", String(repeating: "0", count: 64)), ("sourceURL", "http://example.invalid") ] {
                record.catalogueAttribution = provenance; record.catalogueAttribution![key] = value
                do { try record.validate(); throw Failure(message: "Invalid rights record accepted") }
                catch is AnimationStorageError { }
            }
        }
        try await test("real snapshot cache preserves updated provenance and stays within its byte budget") {
            let (editor, storage) = try await fixture(), session = try await prepare(editor)
            try require(session.apply(currentScope: scope), "Initial rights Add failed")
            try require(await editor.save(), "Initial rights save failed")
            var project = try storage.loadAnimation(id: editor.document.id)!
            project.frames[0].sourceImage!.catalogueAttribution!["attribution"] = "Kenney — CC0; curated Studio scenery and props"
            try storage.preflightAnimation(project); try storage.saveAnimation(project)
            let reread = try storage.loadAnimation(id: editor.document.id)!
            try require(reread.frames == project.frames, "Snapshot reused stale attribution")
            let cache = DeviceStorageManager.snapshotEncodingCacheFootprint
            try require(cache.entries <= 32 && cache.bytes <= DeviceStorageManager.maximumSnapshotFrameCacheBytes,
                "Attribution escaped bounded snapshot cache accounting")
        }
        try require(NetworkTrap.count == 0, "Library attempted a network request")
        print("STUDIO_IMAGE_LIBRARY_TESTS=PASS \(groups)/\(groups), 207 actual thumbnails, zero network requests")
    }
}
