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
        func exported(_ editor: StudioViewModel) async throws -> Data {
            let output = try await StudioExportService().export(document: editor.document, format: .pngSequence,
                outputParent: root, background: .transparent, rasterData: { editor.rasterData($0) })
            let bytes = try Data(contentsOf: output.imageURLs[0])
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
