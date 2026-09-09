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
            for _ in 0..<200 where started.count == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
            try require(started.count == 1, "Actual provider did not start")
            session.cancel(); await session.waitForCompletion()
            try await prepare(session, vm)
            try await Task.sleep(nanoseconds: 250_000_000)
            try require(late.count == 1 && session.status == .preview && session.preview?.name == "selected", "Late provider replaced new Files preview")
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
        try require(NetworkTrap.count == 0, "Image import issued an HTTP request")
        try require(try Data(contentsOf: source) == bytes, "Selected original file changed")
        print("STUDIO_IMAGE_IMPORT_SESSION_TESTS=PASS \(passed) actual provider/decoder/VM/persistence groups; HTTP=0")
    }
}
