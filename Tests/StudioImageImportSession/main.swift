import Foundation
import SwiftUI
import CoreGraphics
import ImageIO

private struct Failure: Error { let message: String }
private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(message: message) }
}
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
private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var calls = 0
    func record() { lock.lock(); calls += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func waitForCall(_ message: String) async throws {
        let clock = ContinuousClock(), deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while count == 0 {
            try require(clock.now < deadline, message)
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
@MainActor private final class ScopeBox {
    var value: StudioImageImportSession.Scope
    init(_ value: StudioImageImportSession.Scope) { self.value = value }
}
@MainActor private final class Gate {
    private(set) var hits = 0
    private var pending: [Int: CheckedContinuation<Void, Error>] = [:]
    func pause() async throws { hits += 1; let index = hits; try await withCheckedThrowingContinuation { pending[index] = $0 } }
    func wait(_ index: Int) async throws {
        for _ in 0..<2000 {
            if hits >= index { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw Failure(message: "Session checkpoint did not arrive")
    }
    func release(_ index: Int) throws {
        guard let continuation = pending.removeValue(forKey: index) else { throw Failure(message: "Missing checkpoint") }
        continuation.resume()
    }
}

/// Complete production VM, storage, provider transfer and ImageIO importer are
/// compiled together. Fixtures are generated pixels and real NSItemProviders.
@main @MainActor struct StudioImageImportSessionTests {
    static let fm = FileManager.default
    static let scope = StudioImageImportSession.Scope(isStudioVisible: true, isForeground: true, accountID: nil)
    static func image(width: Int = 80, height: Int = 40, orientation: Int = 1) throws -> Data {
        let color = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: color, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: color, components: [1, 0, 0, 1])!); context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(colorSpace: color, components: [0, 0, 1, 1])!); context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        let data = NSMutableData(), destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        try require(CGImageDestinationFinalize(destination), "Fixture PNG encoder failed")
        return data as Data
    }
    private static func provider(_ url: URL, name: String = "Selected photo", calls: Counter? = nil) -> NSItemProvider {
        let provider = NSItemProvider(); provider.suggestedName = name
        provider.registerFileRepresentation(forTypeIdentifier: "public.png", fileOptions: [], visibility: .ownProcess) { done in
            calls?.record(); done(url, false, nil); return Progress(totalUnitCount: 1)
        }
        return provider
    }
    static func previewPixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure(message: "Preview pixel context unavailable")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { throw Failure(message: "Preview pixels unavailable") }
        let offset = (y * image.width + x) * 4
        return (0..<4).map { bytes[offset + $0] }
    }
    static func content(_ document: StudioDocument) -> StudioDocument {
        var document = document; document.revision = 0; document.modifiedAt = document.createdAt; return document
    }
    static func main() async {
        do { try await run() }
        catch { print("STUDIO_IMAGE_IMPORT_SESSION_TESTS=FAIL \(error)"); exit(1) }
    }
    static func run() async throws {
        let root = fm.temporaryDirectory.appendingPathComponent("sdi-image-session-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root); URLProtocol.unregisterClass(NetworkTrap.self) }
        try require(URLProtocol.registerClass(NetworkTrap.self), "Could not register HTTP trap")
        try require(AppConfig.backendURL == nil, "Test unexpectedly has a cloud configuration")
        let scratch = root.appendingPathComponent("scratch")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
        let bytes = try image(), source = root.appendingPathComponent("selected.png")
        try bytes.write(to: source, options: .withoutOverwriting)
        let originalCGImage = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(bytes as CFData, nil)!, 0, nil)!
        try require(try previewPixel(originalCGImage, x: 20, y: 20) == [255, 0, 0, 255]
            && previewPixel(originalCGImage, x: 60, y: 20) == [0, 0, 255, 255], "Generated fixture did not encode explicit sRGB red and blue")
        func fixture(_ name: String) async throws -> (StudioViewModel, DeviceStorageManager) {
            let store = DeviceStorageManager(documentsDirectory: root.appendingPathComponent(name))
            let vm = StudioViewModel(storage: store)
            try require(await vm.createProject(name: name, width: 160, height: 120, fps: 24), "Actual project creation failed")
            return (vm, store)
        }
        func prepare(_ session: StudioImageImportSession, _ vm: StudioViewModel, box: ScopeBox? = nil, url: URL? = nil) async throws {
            let box = box ?? ScopeBox(scope)
            guard let token = session.beginPicker(in: vm, scope: box.value) else { throw Failure(message: "Picker capture rejected") }
            try require(session.receiveFile(url ?? source, token: token, currentScope: { box.value }), "Files selection rejected")
            await session.waitForCompletion()
            try require(session.status == .preview && session.previewImage != nil, "Actual decoded preview unavailable: \(session.notice ?? "nil")")
        }
        var passed = 0
        func test(_ name: String, _ operation: () async throws -> Void) async throws {
            do {
                try await operation()
                try require(try fm.contentsOfDirectory(atPath: scratch.path).isEmpty, "Owned scratch remained after \(name)")
                passed += 1; print("PASS \(name)")
            } catch { print("FAIL \(name): \(error)"); throw error }
        }
        try await test("owned background presets generate distinct real full-canvas pixels and accurate category counts") {
            let presets = StudioImageImportService.BackgroundPreset.all
            try require(presets.count == 16 && Set(presets.map(\.id)).count == 16,
                "Preset identities or actual count incorrect")
            try require(presets.filter { $0.category == "Gradients" }.count == 8 &&
                presets.filter { $0.category == "Solid" }.count == 8, "Displayed category counts disagree")
            var outputs = Set<Data>()
            for preset in presets {
                let image = try await StudioImageImportService.shared.prepareBackground(presetID: preset.id, width: 160, height: 120)
                try require(image.width == 160 && image.height == 120 && image.originalData == image.normalizedPNG &&
                    image.originalOrientation == 1, "Generated source size or orientation incorrect")
                guard let source = CGImageSourceCreateWithData(image.normalizedPNG as CFData, nil),
                      let pixels = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure(message: "Background PNG cannot decode") }
                let first = try previewPixel(pixels, x: 0, y: 0), last = try previewPixel(pixels, x: 159, y: 119)
                let rgb = UInt32(preset.startHex, radix: 16)!
                let expected = [UInt8((rgb >> 16) & 255), UInt8((rgb >> 8) & 255), UInt8(rgb & 255)]
                try require(zip(first.prefix(3), expected).allSatisfy { abs(Int($0.0) - Int($0.1)) <= 3 } &&
                    first[3] == 255 && last[3] == 255, "Actual background start color/alpha differs for \(preset.id): first=\(first), last=\(last), expectedStart=\(expected)")
                try require(preset.category == "Solid" ? first == last : first != last, "Solid/gradient category is label-only")
                outputs.insert(image.normalizedPNG)
            }
            try require(outputs.count == 16, "Distinct presets reused a fake image")
        }
        try await test("background attachment preserves drawing layers, pixels, one Undo and real cold reopen") {
            let (vm, store) = try await fixture("actual-background")
            let drawing = DrawnElement(id: UUID().uuidString, tool: .line,
                points: [.init(x: 10, y: 10), .init(x: 50, y: 50)], color: "#FF0000", width: 4,
                opacity: 1, layerID: vm.activeLayerID)
            try require(vm.commitElement(drawing), "Existing drawing fixture failed")
            let before = vm.document
            let image = try await StudioImageImportService.shared.prepareBackground(presetID: "gradient-sunset",
                width: before.width, height: before.height)
            let asset = try vm.attachImportedImage(image, expectedProjectID: before.id, expectedRevision: before.revision,
                frameID: before.activeFrameID, layerID: before.activeLayerID)
            let after = vm.document
            try require(after.frames[0].elements == before.frames[0].elements && after.layers.dropLast() == before.layers[...] &&
                after.frames[0].rasterLayerID == after.layers.last!.id && vm.rasterData(asset) == image.normalizedPNG &&
                after.frames[0].rasterPlacement == .aspectFit(imageWidth: 160, imageHeight: 120, canvasWidth: 160, canvasHeight: 120),
                "Background replaced drawings, missed canvas or was not behind artwork")
            vm.undo(); try require(content(vm.document) == content(before), "Background Undo failed")
            vm.redo(); try require(content(vm.document) == content(after), "Background Redo failed")
            try require(await vm.save(), "Background persistence failed")
            let reopened = StudioViewModel(storage: store)
            try require(await reopened.openProject(store.loadAnimation(id: after.id)!.metadata), "Background cold reopen failed")
            try require(content(reopened.document) == content(after) && reopened.rasterData(asset) == image.normalizedPNG &&
                reopened.originalImageSource(asset)?.originalData == image.originalData, "Background original or editable document lost")
            let unchanged = reopened.document
            do {
                _ = try reopened.attachImportedImage(image, expectedProjectID: unchanged.id, expectedRevision: unchanged.revision,
                    frameID: unchanged.activeFrameID, layerID: unchanged.activeLayerID)
                throw Failure(message: "Background replaced existing image")
            } catch is StudioDocumentError { }
            try require(reopened.document == unchanged, "Rejected replacement changed document")
        }
        try await test("background generation cancellation and invalid presets leave no lease or editor changes") {
            for parameters in [("unknown", 160, 120), ("solid-sunset", 0, 120), ("solid-sunset", 4097, 120)] {
                do {
                    _ = try await StudioImageImportService.shared.prepareBackground(presetID: parameters.0, width: parameters.1, height: parameters.2)
                    throw Failure(message: "Invalid background accepted")
                } catch is StudioImageImportService.ImportError { }
            }
            let task = Task { try await StudioImageImportService.shared.prepareBackground(presetID: "solid-sunset", width: 160, height: 120) }
            task.cancel()
            do { _ = try await task.value; throw Failure(message: "Cancelled background returned bytes") }
            catch is CancellationError { }
            let next = try await StudioImageImportService.shared.prepareBackground(presetID: "solid-sunset", width: 160, height: 120)
            try require(!next.normalizedPNG.isEmpty, "Cancellation leaked image lease")
            let (vm, _) = try await fixture("stale-background")
            let captured = vm.document
            vm.addFrame(); let current = vm.document
            do {
                _ = try vm.attachImportedImage(next, expectedProjectID: captured.id, expectedRevision: captured.revision,
                    frameID: captured.activeFrameID, layerID: captured.activeLayerID)
                throw Failure(message: "Stale background overwrote frame")
            } catch is StudioDocumentError { }
            try require(vm.document == current && vm.managedImageByteCount == 0, "Stale background published pixels")
        }
        try await test("single image attachment preserves a clipboard copied at its final checkpoint") {
            let (vm, _) = try await fixture("image-clipboard-fence")
            let imported = try await StudioImageImportService.shared.importImage(from: source, scratchParent: scratch)
            let before = vm.document
            try require(!vm.canPaste, "Fixture unexpectedly has clipboard content")
            var checkpoints = 0
            do {
                _ = try vm.attachImportedImage(imported, expectedProjectID: before.id, expectedRevision: before.revision,
                    frameID: before.activeFrameID, layerID: before.activeLayerID, checkCancellation: {
                        checkpoints += 1
                        if checkpoints == 2 { vm.copyFrame() }
                    })
                throw Failure(message: "Image import overwrote newer clipboard")
            } catch is StudioDocumentError { }
            try require(checkpoints == 2 && vm.document == before && vm.managedImageByteCount == 0 && vm.canPaste,
                "Rejected image changed document/assets or discarded clipboard")
            vm.pasteClipboard()
            try require(vm.frames.count == before.frames.count + 1 && vm.frames.allSatisfy { $0.rasterAssetID == nil },
                "Preserved copied frame cannot Paste")
        }
        try await test("image picker and ready preview preserve a live text draft for actual Apply") {
            for ready in [false, true] {
                let (vm, _) = try await fixture("text-session-\(ready)")
                let session = StudioImageImportSession(scratchParent: scratch)
                if ready { try await prepare(session, vm) }
                let before = vm.document
                try require(vm.beginTextEditing(), "Text draft could not begin")
                vm.textInput = "Keep this text"
                if ready { try require(!session.apply(currentScope: scope), "Ready image replaced text context") }
                else { try require(session.beginPicker(in: vm, scope: scope) == nil, "Image picker accepted live text") }
                try require(vm.document == before && vm.textDraft != nil && vm.textInput == "Keep this text" && vm.managedImageByteCount == 0,
                    "Rejected import lost draft, changed history or retained image bytes")
                try require(vm.applyTextEditing(), "Preserved draft cannot Apply")
                try require(vm.currentFrame.elements.contains { $0.text?.content == "Keep this text" }, "Actual text was not committed")
                session.close()
            }
        }
        try await test("direct single and sequence image attachment reject initial and reentrant text drafts") {
            let imported = try await StudioImageImportService.shared.importImage(from: source, scratchParent: scratch)
            for sequence in [false, true] { for late in [false, true] {
                let (vm, _) = try await fixture("text-handoff-\(sequence)-\(late)")
                let before = vm.document
                if !late { try require(vm.beginTextEditing(), "Initial text draft"); vm.textInput = "Still editable" }
                var checkpoints = 0
                let checkpoint: () throws -> Void = {
                    checkpoints += 1
                    if late && checkpoints == 2 {
                        try require(vm.beginTextEditing(), "Late text draft"); vm.textInput = "Still editable"
                    }
                }
                do {
                    if sequence {
                        _ = try vm.attachImportedImageSequence([imported], expectedProjectID: before.id,
                            expectedRevision: before.revision, frameID: before.activeFrameID,
                            layerID: before.activeLayerID, checkCancellation: checkpoint)
                    } else {
                        _ = try vm.attachImportedImage(imported, expectedProjectID: before.id,
                            expectedRevision: before.revision, frameID: before.activeFrameID,
                            layerID: before.activeLayerID, checkCancellation: checkpoint)
                    }
                    throw Failure(message: "Image handoff invalidated text")
                } catch is StudioDocumentError { }
                try require(vm.document == before && vm.textDraft != nil && vm.managedImageByteCount == 0,
                    "Rejected image attachment changed source/history/draft")
                try require(vm.applyTextEditing() && vm.currentFrame.elements.contains { $0.text?.content == "Still editable" },
                    "Original draft cannot commit after rejected handoff")
            } }
        }
        try await test("Files image decodes a factual preview before one real attach, undo, redo, save and reopen") {
            let (vm, store) = try await fixture("files")
            let before = vm.document, session = StudioImageImportSession(scratchParent: scratch)
            try await prepare(session, vm)
            try require(vm.document == before && !vm.canUndo && session.appliedImage == nil, "Preview changed the document")
            try require(session.preview?.width == 80 && session.preview?.height == 40 && session.preview?.originalByteCount == bytes.count, "Preview metadata was fabricated")
            let thumbnail = session.previewImage!
            let left = try previewPixel(thumbnail, x: thumbnail.width / 4, y: thumbnail.height / 2)
            let right = try previewPixel(thumbnail, x: thumbnail.width * 3 / 4, y: thumbnail.height / 2)
            try require(left == [255, 0, 0, 255] && right == [0, 0, 255, 255],
                "Visible preview pixels are not the selected red/blue image: \(thumbnail.width)x\(thumbnail.height) left=\(left) right=\(right)")
            try require(session.saveState(in: vm, currentScope: scope) == .unavailable && session.canApply(currentScope: scope), "Preview was called saved or ineligible")
            try require(session.apply(currentScope: scope), "Explicit image attachment failed")
            let after = vm.document, receipt = session.appliedImage!
            try require(after.schemaVersion == 3 && after.layers.count == before.layers.count + 1 && after.frames[0].rasterAssetID == receipt.assetID, "Canonical image layer/asset missing")
            try require(vm.originalImageSource(receipt.assetID)?.originalData == bytes && vm.isDirty, "Original bytes lost or uncommitted save claimed")
            try require(session.saveState(in: vm, currentScope: scope) == .unsaved && !session.apply(currentScope: scope), "Duplicate apply or false saved receipt")
            vm.undo(); try require(content(vm.document) == content(before), "One undo did not reverse attachment")
            vm.redo(); try require(content(vm.document) == content(after), "One redo did not restore attachment")
            try require(await vm.save(), "Actual save failed")
            let reopened = StudioViewModel(storage: store)
            let stored = try store.loadAnimation(id: after.id)!
            try require(await reopened.openProject(stored.metadata), "Actual reopen failed")
            try require(content(reopened.document) == content(after) && reopened.originalImageSource(receipt.assetID)?.originalData == bytes, "Saved editable image or original changed")
        }
        try await test("Photos NSItemProvider owns bytes through decode and cleans before publishing preview") {
            let (vm, _) = try await fixture("photos")
            let session = StudioImageImportSession(scratchParent: scratch), calls = Counter()
            let token = session.beginPicker(in: vm, scope: scope)!
            try require(session.receivePhoto(provider(source, calls: calls), token: token, currentScope: { scope }), "Photo selection not accepted")
            await session.waitForCompletion()
            try require(calls.count == 1 && session.status == .preview && session.preview?.name == "Selected photo", "Actual provider result missing")
            try require(try fm.contentsOfDirectory(atPath: scratch.path).isEmpty, "Provider temporary copy escaped decode")
            try require(session.apply(currentScope: scope), "Decoded provider image did not attach")
            try require(vm.originalImageSource(session.appliedImage!.assetID)?.originalData == bytes, "Provider original not owned by project")
        }
        try await test("orientation and bounded thumbnail derive from the actual normalized image") {
            let (vm, _) = try await fixture("orientation"), url = root.appendingPathComponent("rotated.png")
            let encoded = try image(width: 1600, height: 800, orientation: 6); try encoded.write(to: url)
            let session = StudioImageImportSession(scratchParent: scratch)
            try await prepare(session, vm, url: url)
            try require(session.preview?.width == 800 && session.preview?.height == 1600 && session.preview?.originalWidth == 1600 && session.preview?.originalOrientation == 6, "Orientation metadata lost")
            try require(session.previewImage?.width == 320 && session.previewImage?.height == 640, "Preview was not bounded or respected no aspect ratio")
        }
        try await test("picker cancellation and permission failure are distinct and do not mutate") {
            let (vm, _) = try await fixture("picker-errors"), before = vm.document
            let session = StudioImageImportSession(scratchParent: scratch)
            var token = session.beginPicker(in: vm, scope: scope)!
            session.pickerFailed(CocoaError(.fileReadNoPermission), token: token)
            try require(session.status == .failed && session.notice?.contains("could not be opened") == true, "Permission failure pretended cancellation")
            token = session.beginPicker(in: vm, scope: scope)!
            session.pickerFailed(CocoaError(.userCancelled), token: token)
            try require(session.status == .cancelled && vm.document == before && session.preview == nil, "Cancelled picker changed document")
        }
        try await test("consumed and cancelled picker tokens cannot replay or replace the next selection") {
            let (vm, _) = try await fixture("tokens"), calls = Counter(), session = StudioImageImportSession(scratchParent: scratch)
            let old = session.beginPicker(in: vm, scope: scope)!; session.pickerCancelled(token: old)
            let current = session.beginPicker(in: vm, scope: scope)!
            try require(!session.receivePhoto(provider(source, calls: calls), token: old, currentScope: { scope }) && calls.count == 0, "Old provider selection loaded")
            session.pickerCancelled(token: old)
            try require(session.receiveFile(source, token: current, currentScope: { scope }), "New selection rejected")
            try require(!session.receivePhoto(provider(source, calls: calls), token: current, currentScope: { scope }), "Duplicate provider selection loaded")
            await session.waitForCompletion()
            try require(session.status == .preview && calls.count == 0, "Duplicate changed the actual Files preview")
        }
        try await test("project revision change after preview rejects without dropping decoded preview") {
            let (vm, _) = try await fixture("stale-preview"), session = StudioImageImportSession(scratchParent: scratch)
            try await prepare(session, vm); vm.addFrame(); let before = vm.document
            try require(!session.apply(currentScope: scope) && session.status == .stale && session.previewImage != nil, "Stale preview applied or discarded")
            try require(vm.document == before && session.appliedImage == nil && !session.canApply(currentScope: scope), "Stale receipt or partial edit")
        }
        try await test("context change while decode completion is pending never autoattaches") {
            let (vm, _) = try await fixture("stale-decode"), gate = Gate()
            let session = StudioImageImportSession(scratchParent: scratch, checkpoint: { try await gate.pause() })
            let token = session.beginPicker(in: vm, scope: scope)!
            try require(session.receiveFile(source, token: token, currentScope: { scope }), "Transfer not accepted")
            try await gate.wait(1); try gate.release(1); try await gate.wait(2)
            vm.addLayer(); let before = vm.document
            try gate.release(2); await session.waitForCompletion()
            try require(session.status == .stale && session.preview == nil && vm.document == before, "Stale decoded image became applicable")
        }
        try await test("active touch failure retains decoded image for explicit retry with unchanged context") {
            let (vm, _) = try await fixture("touch-retry"), session = StudioImageImportSession(scratchParent: scratch)
            try await prepare(session, vm); let before = vm.document
            try require(vm.beginStrokeInput(id: "active-touch"), "Actual touch input guard unavailable")
            try require(!session.canApply(currentScope: scope) && !session.apply(currentScope: scope), "Image bypassed active touch")
            try require(session.status == .failed && session.previewImage != nil && vm.document == before, "Failure dropped image or mutated document")
            vm.finishStrokeInput(id: "active-touch")
            try require(session.canApply(currentScope: scope) && session.apply(currentScope: scope), "Safe explicit retry failed")
        }
        try await test("pending rejected brush draft blocks attachment until explicit discard") {
            let (vm, _) = try await fixture("pending-draft"), session = StudioImageImportSession(scratchParent: scratch)
            try await prepare(session, vm)
            let element = DrawnElement(id: "pending-image-draft", tool: .brush, points: [.init(x: 10, y: 20)], color: "#FF0000", width: 3, opacity: 1, layerID: vm.activeLayerID)
            vm.retainRejectedBrush(element, frameID: vm.currentFrame.id, reason: "fixture pending draft")
            let before = vm.document
            try require(!session.apply(currentScope: scope) && vm.document == before && session.preview != nil, "Pending draft bypassed")
            vm.discardRejectedBrush()
            try require(session.apply(currentScope: scope), "Explicit retry after draft discard failed")
        }
        try await test("inactive picker transition preserves preview but cannot add until foreground") {
            let (vm, _) = try await fixture("inactive"), box = ScopeBox(scope), session = StudioImageImportSession(scratchParent: scratch)
            let token = session.beginPicker(in: vm, scope: scope)!
            box.value = .init(isStudioVisible: true, isForeground: false, accountID: nil); session.refreshScope(box.value)
            try require(session.receiveFile(source, token: token, currentScope: { box.value }), "Inactive system picker result discarded")
            await session.waitForCompletion()
            try require(session.status == .preview && !session.canApply(currentScope: box.value), "Inactive preview applied or vanished")
            try require(!session.apply(currentScope: box.value) && session.previewImage != nil, "Inactive apply succeeded")
            box.value = scope; session.refreshScope(box.value)
            try require(session.apply(currentScope: box.value), "Foreground preview could not explicitly attach")
        }
        try await test("account switch during preparation closes without a preview or document edit") {
            let (vm, _) = try await fixture("account"), gate = Gate(), box = ScopeBox(.init(isStudioVisible: true, isForeground: true, accountID: "owner-A"))
            let before = vm.document, session = StudioImageImportSession(scratchParent: scratch, checkpoint: { try await gate.pause() })
            let token = session.beginPicker(in: vm, scope: box.value)!
            try require(session.receivePhoto(provider(source), token: token, currentScope: { box.value }), "Photo not accepted")
            try await gate.wait(1); try gate.release(1); try await gate.wait(2)
            box.value = .init(isStudioVisible: true, isForeground: true, accountID: "owner-B")
            try gate.release(2); await session.waitForCompletion()
            try require(session.isClosed && session.preview == nil && vm.document == before, "Account-switch result escaped into editor")
        }
        try await test("close at each actual scheduler boundary leaves no partial image and permits another session") {
            for boundary in 1...2 {
                let (vm, _) = try await fixture("close-\(boundary)"), gate = Gate(), session = StudioImageImportSession(scratchParent: scratch, checkpoint: { try await gate.pause() })
                let before = vm.document, token = session.beginPicker(in: vm, scope: scope)!
                try require(session.receivePhoto(provider(source), token: token, currentScope: { scope }), "Photo not accepted")
                try await gate.wait(1)
                if boundary == 2 { try gate.release(1); try await gate.wait(2) }
                session.close(); try gate.release(boundary); await session.waitForCompletion()
                try require(session.isClosed && !session.isWorking && session.preview == nil && vm.document == before, "Closed session published or leaked work")
                let fresh = StudioImageImportSession(scratchParent: scratch)
                try await prepare(fresh, vm); fresh.cancel()
            }
        }
        try await test("late provider completion after cancellation cannot populate a later picker generation") {
            let (vm, _) = try await fixture("late-photo"), session = StudioImageImportSession(scratchParent: scratch), started = Counter(), late = Counter(), p = NSItemProvider()
            p.registerFileRepresentation(forTypeIdentifier: "public.png", fileOptions: [], visibility: .ownProcess) { done in
                started.record(); DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { done(source, false, nil); late.record() }
                return Progress(totalUnitCount: 1)
            }
            let token = session.beginPicker(in: vm, scope: scope)!
            try require(session.receivePhoto(p, token: token, currentScope: { scope }), "Photo not accepted")
            try await started.waitForCall("Actual provider did not start before cancellation")
            try require(started.count == 1, "Actual provider did not start")
            session.cancel(); await session.waitForCompletion()
            try await prepare(session, vm)
            try await late.waitForCall("Cancelled provider completion did not finish")
            try require(late.count == 1, "Cancelled provider completion ran more than once")
            try require(session.status == .preview, "Late provider changed the new preview status")
            try require(session.preview?.name == "selected", "Late provider replaced new Files preview")
        }
        try await test("corrupt image, unsupported provider and remote Files URL have truthful failure without editing") {
            let (vm, _) = try await fixture("bad-input"), before = vm.document
            let invalid = root.appendingPathComponent("invalid.png"); try Data("not an image".utf8).write(to: invalid)
            for url in [invalid, URL(string: "https://example.invalid/image.png")!] {
                let session = StudioImageImportSession(scratchParent: scratch), token = session.beginPicker(in: vm, scope: scope)!
                try require(session.receiveFile(url, token: token, currentScope: { scope }), "Input action rejected before truthful async failure")
                await session.waitForCompletion()
                try require(session.status == .failed && session.preview == nil && vm.document == before, "Invalid URL produced preview or edit")
            }
            let p = NSItemProvider(), count = Counter()
            p.registerFileRepresentation(forTypeIdentifier: "public.movie", fileOptions: [], visibility: .ownProcess) { _ in count.record(); return nil }
            let session = StudioImageImportSession(scratchParent: scratch), token = session.beginPicker(in: vm, scope: scope)!
            try require(session.receivePhoto(p, token: token, currentScope: { scope }), "Provider action rejected unexpectedly")
            await session.waitForCompletion()
            try require(session.status == .failed && count.count == 0 && vm.document == before, "Unsupported provider was loaded")
        }
        try await test("weak editor ownership stops an abandoned editor from receiving decoded results") {
            var vm: StudioViewModel? = try await fixture("weak-editor").0
            weak var weakVM = vm
            let gate = Gate(), session = StudioImageImportSession(scratchParent: scratch, checkpoint: { try await gate.pause() })
            let token = session.beginPicker(in: vm!, scope: scope)!
            try require(session.receiveFile(source, token: token, currentScope: { scope }), "Selection not accepted")
            try await gate.wait(1); vm = nil
            try require(weakVM == nil, "Session retained the entire editor")
            try gate.release(1); await session.waitForCompletion()
            try require(session.status == .stale && session.preview == nil, "Abandoned editor still received a preview")
        }
        try await test("actual save state is separate from attach and changes after undo") {
            let (vm, _) = try await fixture("save-state"), session = StudioImageImportSession(scratchParent: scratch)
            try await prepare(session, vm); try require(session.apply(currentScope: scope), "Attachment failed")
            try require(session.saveState(in: vm, currentScope: scope) == .unsaved, "Attach fabricated a saved result")
            try require(await vm.save(), "Actual persistence failed")
            try require(session.saveState(in: vm, currentScope: scope) == .saved, "Real save was not reflected")
            vm.undo(); try require(session.saveState(in: vm, currentScope: scope) == .projectChanged, "Undo kept a stale saved receipt")
        }
        try await test("dismissing an already applied preview never undoes or denies the successful edit") {
            let (vm, _) = try await fixture("dismiss-applied"), session = StudioImageImportSession(scratchParent: scratch)
            try await prepare(session, vm); try require(session.apply(currentScope: scope), "Attachment failed")
            let after = vm.document; session.cancel()
            try require(vm.document == after && session.notice?.contains("remains in the project") == true, "Dismissal silently removed or denied applied image")
        }
        try await test("video sequence preview inserts after captured frame atomically and cold reopens") {
            let (vm, store) = try await fixture("video-sequence-session")
            let movie = root.appendingPathComponent("sequence-session.mov")
            try await VideoFrameFixture.makeMovie(movie, rotate: true)
            let before = vm.document
            let session = StudioImageImportSession(scratchParent: scratch)
            let token = session.beginPicker(in: vm, scope: scope, videoFrameCount: 3)!
            try require(session.receiveVideoFrame(movie, token: token, currentScope: { scope }), "Sequence picker rejected")
            await session.waitForCompletion()
            try require(session.status == .preview && session.previewFrameCount == 3 && vm.document == before,
                "Sequence preview changed project or did not retain all frames: \(session.notice ?? "none")")
            try fm.removeItem(at: movie)
            try require(session.apply(currentScope: scope), "Owned sequence could not apply after movie removal")
            let after = vm.document
            try require(after.frames.count == before.frames.count + 3 && after.frames[0] == before.frames[0]
                && after.activeFrameID == after.frames[1].id && after.revision == before.revision + 1,
                "Sequence insertion changed original frame, playhead or transaction count")
            let ids = after.frames[1...3].compactMap(\.rasterAssetID)
            try require(ids.count == 3 && Set(ids).count == 3 && Set(after.frames[1...3].compactMap(\.rasterLayerID)).count == 1,
                "Sequence assets or shared image layer are inconsistent")
            let originals = ids.map { vm.originalImageSource($0)!.originalData }
            vm.undo(); try require(content(vm.document) == content(before), "Sequence Undo did not restore original document")
            vm.redo(); try require(content(vm.document) == content(after), "Sequence Redo lost frames or assets")
            try require(await vm.save(), "Sequence save failed")
            let stored = try store.loadAnimation(id: after.id)!
            await vm.backToProjects()
            let reopened = StudioViewModel(storage: store)
            try require(await reopened.openProject(stored.metadata), "Sequence cold reopen failed")
            try require(reopened.document.frames == after.frames && ids.enumerated().allSatisfy {
                reopened.originalImageSource($0.element)?.originalData == originals[$0.offset]
            }, "Sequence cold reopen changed frame ordering or original PNG bytes")
            await reopened.backToProjects()
        }
        try await test("video reference uses captured project time and survives source removal undo and cold reopen") {
            let (vm, store) = try await fixture("video-reference")
            let movie = root.appendingPathComponent("reference.mov")
            try await VideoFrameFixture.makeMovie(movie, rotate: true)
            for _ in 0..<17 { vm.addFrame() }
            try require(await vm.save(), "Could not settle selected project frame")
            try require(vm.currentFrameIndex == 17 && vm.fps == 24, "Fixture playhead is wrong")
            let before = vm.document
            let session = StudioImageImportSession(scratchParent: scratch)
            let token = session.beginPicker(in: vm, scope: scope)!
            try require(session.receiveVideoFrame(movie, token: token, currentScope: { scope }), "Video selection rejected")
            await session.waitForCompletion()
            try require(session.status == .preview, "No video preview: \(session.notice ?? "missing notice")")
            try require(vm.document == before && session.preview?.width == 64 && session.preview?.height == 96,
                        "Video preview mutated document or ignored orientation")
            let pixel = try previewPixel(session.previewImage!, x: 32, y: 48)
            try require(Int(pixel[1]) - Int(pixel[0]) > 140 && Int(pixel[1]) - Int(pixel[2]) > 140,
                        "Selected playhead did not decode green source frame: \(pixel)")
            try require(session.notice?.contains("Studio 0.708s") == true, "Preview hid actual project mapping")
            try fm.removeItem(at: movie)
            try require(session.apply(currentScope: scope), "Snapshot could not attach after source removal")
            let after = vm.document, receipt = session.appliedImage!
            try require(after.frames[17].rasterAssetID == receipt.assetID && after.frames[0].rasterAssetID == nil,
                        "Import attached to the wrong frame")
            let original = vm.originalImageSource(receipt.assetID)!.originalData
            try require(after.layers.count == before.layers.count + 1, "Reference layer is not separate")
            vm.undo(); try require(content(vm.document) == content(before), "Video reference Undo failed")
            vm.redo(); try require(content(vm.document) == content(after), "Video reference Redo failed")
            try require(await vm.save(), "Video reference save failed")
            let reopened = StudioViewModel(storage: store)
            let stored = try store.loadAnimation(id: after.id)!
            try require(await reopened.openProject(stored.metadata), "Video reference cold reopen failed")
            try require(content(reopened.document) == content(after)
                && reopened.originalImageSource(receipt.assetID)?.originalData == original, "Reopened PNG/reference changed")
            try require(try fm.contentsOfDirectory(atPath: scratch.path).isEmpty, "Video staging leaked")
        }
        try await test("video timing is captured before selection and its mapped pixels persist") {
            let (vm, store) = try await fixture("video-mapping")
            let movie = root.appendingPathComponent("mapped.mov")
            try await VideoFrameFixture.makeMovie(movie, rotate: false)
            for _ in 0..<12 { vm.addFrame() }
            try require(await vm.save(), "Could not save mapping fixture")
            let session = StudioImageImportSession(scratchParent: scratch)
            var mapping = StudioVideoFrameImportService.Mapping(sourceStartSeconds: 0.4,
                sourceEndSeconds: 2, projectStartSeconds: 0.1, speed: 2)
            let token = session.beginPicker(in: vm, scope: scope, videoMapping: mapping)!
            mapping.speed = 0.25 // UI edits cannot alter the already captured request.
            try require(session.receiveVideoFrame(movie, token: token, currentScope: { scope }), "Mapped selection rejected")
            await session.waitForCompletion()
            try require(session.status == .preview, "Mapped preview failed: \(session.notice ?? "")")
            let pixel = try previewPixel(session.previewImage!, x: 48, y: 32)
            try require(pixel[2] > 200 && pixel[0] < 40, "Captured timing failed to seek the blue source sample")
            try require(session.notice?.contains("source 1.200s") == true, "Mapped source time is absent")
            try require(session.apply(currentScope: scope), "Mapped PNG could not attach")
            let after = vm.document, assetID = session.appliedImage!.assetID
            let original = vm.originalImageSource(assetID)!.originalData
            try require(await vm.save(), "Mapped snapshot save failed")
            let reopened = StudioViewModel(storage: store)
            try require(await reopened.openProject(store.loadAnimation(id: after.id)!.metadata), "Mapped snapshot reopen failed")
            try require(reopened.originalImageSource(assetID)?.originalData == original, "Mapped pixels changed on reopen")
            try require(try fm.contentsOfDirectory(atPath: scratch.path).isEmpty, "Mapped source leaked staging files")
        }
        try await test("video picker result cannot attach after frame change or cancellation") {
            let (vm, _) = try await fixture("video-stale")
            let movie = root.appendingPathComponent("stale.mov")
            try await VideoFrameFixture.makeMovie(movie, rotate: false)
            let session = StudioImageImportSession(scratchParent: scratch)
            let token = session.beginPicker(in: vm, scope: scope)!
            vm.addFrame()
            try require(!session.receiveVideoFrame(movie, token: token, currentScope: { scope }), "Stale video picker accepted")
            try require(session.status == .stale && vm.document.frames.allSatisfy { $0.rasterAssetID == nil }, "Stale video mutated document")
            let cancelled = StudioImageImportSession(scratchParent: scratch)
            let next = cancelled.beginPicker(in: vm, scope: scope)!
            cancelled.pickerCancelled(token: next)
            try require(!cancelled.receiveVideoFrame(movie, token: next, currentScope: { scope }), "Cancelled video picker revived")
            try require(!cancelled.canApply(currentScope: scope), "Cancelled video can apply")
        }
        try await test("Photos video provider previews actual oriented frame and persists only its PNG") {
            let (vm, store) = try await fixture("photos-video")
            let movie = root.appendingPathComponent("photos-video.mov")
            try await VideoFrameFixture.makeMovie(movie, rotate: true)
            let p = NSItemProvider(); p.suggestedName = "Selected video"
            p.registerFileRepresentation(forTypeIdentifier: "com.apple.quicktime-movie", fileOptions: [], visibility: .ownProcess) { done in
                done(movie, false, nil); return Progress(totalUnitCount: 1)
            }
            for _ in 0..<17 { vm.addFrame() }
            try require(await vm.save(), "Could not settle video playhead")
            let before = vm.document, session = StudioImageImportSession(scratchParent: scratch)
            let token = session.beginPicker(in: vm, scope: scope)!
            try require(session.receiveVideoPhoto(p, token: token, currentScope: { scope }), "Photos video rejected")
            await session.waitForCompletion()
            try require(session.status == .preview && vm.document == before, "Photos video failed or mutated before Add: \(session.notice ?? "")")
            try require(session.preview?.width == 64 && session.preview?.height == 96, "Photos video ignored orientation")
            let pixel = try previewPixel(session.previewImage!, x: 32, y: 48)
            try require(Int(pixel[1]) - Int(pixel[0]) > 140 && Int(pixel[1]) - Int(pixel[2]) > 140, "Photos decoded wrong playhead frame")
            try fm.removeItem(at: movie)
            try require(try fm.contentsOfDirectory(atPath: scratch.path).isEmpty, "Photos staging leaked before Add")
            try require(session.apply(currentScope: scope), "Photos preview cannot attach after source removal")
            let after = vm.document, assetID = session.appliedImage!.assetID
            let bytes = vm.originalImageSource(assetID)!.originalData
            try require(bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]), "Movie bytes were retained as an image")
            vm.undo(); try require(content(vm.document) == content(before), "Photos video reference Undo changed content")
            vm.redo(); try require(content(vm.document) == content(after), "Photos video reference Redo changed content")
            try require(await vm.save(), "Photos video reference save failed")
            let reopened = StudioViewModel(storage: store), stored = try store.loadAnimation(id: after.id)!
            try require(await reopened.openProject(stored.metadata), "Photos video cold reopen failed")
            try require(content(reopened.document) == content(after)
                && reopened.originalImageSource(assetID)?.originalData == bytes, "Photos PNG changed after reopen")
        }
        try await test("cancel Photos video after decode cannot publish a preview or edit") {
            let (vm, _) = try await fixture("photos-video-cancel")
            let movie = root.appendingPathComponent("photos-cancel.mov")
            try await VideoFrameFixture.makeMovie(movie, rotate: false)
            let p = NSItemProvider()
            p.registerFileRepresentation(forTypeIdentifier: "com.apple.quicktime-movie", fileOptions: [], visibility: .ownProcess) { done in
                done(movie, false, nil); return Progress(totalUnitCount: 1)
            }
            let before = vm.document, gate = Gate()
            let session = StudioImageImportSession(scratchParent: scratch, checkpoint: { try await gate.pause() })
            let token = session.beginPicker(in: vm, scope: scope)!
            try require(session.receiveVideoPhoto(p, token: token, currentScope: { scope }), "Photos cancellation fixture rejected")
            try await gate.wait(1); try gate.release(1)
            try await gate.wait(2); session.cancel(); try gate.release(2)
            await session.waitForCompletion()
            try require(session.status == .cancelled && session.preview == nil && !session.canApply(currentScope: scope)
                && vm.document == before, "Cancelled decoded video attached or published a late preview")
            try require(try fm.contentsOfDirectory(atPath: scratch.path).isEmpty, "Cancelled Photos video staging leaked")
            try require(fm.fileExists(atPath: movie.path), "Cancellation removed the original movie")
        }
        try require(NetworkTrap.count == 0, "Image import issued an HTTP request")
        try require(try Data(contentsOf: source) == bytes, "Selected original file changed")
        print("STUDIO_IMAGE_IMPORT_SESSION_TESTS=PASS \(passed) actual provider/decoder/VM/persistence groups; HTTP=0")
    }
}
