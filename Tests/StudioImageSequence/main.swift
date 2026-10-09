import Foundation
import CoreGraphics
import ImageIO

@main @MainActor struct StudioImageSequenceTests {
    struct Failure: Error { let message: String }
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }
    static func rejects(_ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw Failure(message: "Expected atomic rejection")
    }
    static func image(_ channel: Int) throws -> StudioImageImportService.ImportedImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure(message: "PNG fixture context")
        }
        context.setFillColor(CGColor(red: channel == 0 ? 1 : 0, green: channel == 1 ? 1 : 0,
            blue: channel == 2 ? 1 : 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let bytes = NSMutableData()
        guard let bitmap = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil) else {
            throw Failure(message: "PNG fixture encoder")
        }
        CGImageDestinationAddImage(destination, bitmap, nil)
        try require(CGImageDestinationFinalize(destination), "PNG fixture finalize")
        return .init(id: UUID(), name: "Reference \(channel)", container: .png,
            originalData: bytes as Data, originalWidth: 32, originalHeight: 32, originalOrientation: 1,
            width: 32, height: 32, normalizedPNG: bytes as Data)
    }
    static func main() async throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-image-sequence-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = DeviceStorageManager(documentsDirectory: root.appendingPathComponent("Documents"),
            cachesDirectory: root.appendingPathComponent("Cache"))
        let vm = StudioViewModel(storage: storage)
        let made = await vm.createProject(name: "Reference sequence", width: 128, height: 128, fps: 12)
        try require(made, "Actual project create")
        vm.addFrame(); vm.currentFrameIndex = 0
        let originalImage = try image(2)
        _ = try vm.attachImportedImage(originalImage, expectedProjectID: vm.document.id,
            expectedRevision: vm.document.revision, frameID: vm.currentFrame.id, layerID: vm.activeLayerID)
        let original = vm.document, originalsBytes = vm.managedImageByteCount
        let imports = try [image(0), image(1), image(2)]
        func attach(_ values: [StudioImageImportService.ImportedImage], check: () throws -> Void = {}) throws -> [String] {
            try vm.attachImportedImageSequence(values, expectedProjectID: original.id,
                expectedRevision: original.revision, frameID: original.activeFrameID,
                layerID: original.activeLayerID, checkCancellation: check)
        }
        for values in [[], Array(repeating: imports[0], count: 25), [imports[0], imports[0]], [originalImage]] {
            try rejects { _ = try attach(values) }
            try require(vm.document == original && vm.managedImageByteCount == originalsBytes, "Rejected identities/count changed source")
        }
        print("PASS empty, excessive, duplicate and already-owned identities preserve document/assets")
        let malformed = StudioImageImportService.ImportedImage(id: UUID(), name: "Broken", container: .png,
            originalData: Data([0]), originalWidth: 32, originalHeight: 32, originalOrientation: 1,
            width: 32, height: 32, normalizedPNG: Data([0]))
        try rejects { _ = try attach([imports[0], malformed]) }
        try require(vm.document == original && vm.managedImageByteCount == originalsBytes, "Late decode failure partially attached sequence")
        print("PASS malformed later image rolls back complete sequence")
        let oversized = StudioImageImportService.ImportedImage(id: UUID(), name: "Oversized", container: .png,
            originalData: imports[0].originalData, originalWidth: 4000, originalHeight: 8001, originalOrientation: 1,
            width: 4000, height: 8001, normalizedPNG: imports[0].normalizedPNG)
        try rejects { _ = try attach([oversized]) }
        try require(vm.document == original && vm.managedImageByteCount == originalsBytes, "Pixel limit changed source")
        print("PASS oversized sequence rejected before decoding")
        // The final checkpoint follows validation and storage preflight.
        var calls = 0
        try rejects { _ = try attach(imports) { calls += 1; if calls == imports.count + 2 { throw CancellationError() } } }
        try require(calls == imports.count + 2 && vm.document == original && vm.managedImageByteCount == originalsBytes,
            "Final cancellation partially published frames")
        print("PASS cancellation after preflight preserves entire source")
        var changed = false
        try rejects { _ = try attach(imports) { if !changed { changed = true; vm.copyFrame() } else { vm.copyFrame() } } }
        // First callback precedes the capture; later changes must fence publication.
        try require(vm.document == original && vm.managedImageByteCount == originalsBytes && vm.canPaste,
            "Clipboard change was overwritten")
        print("PASS reentrant clipboard changes are retained and reject staged publication")
        let ids = try attach(imports), added = vm.document
        try require(ids.count == 3 && Set(ids).count == 3 && added.frames.count == original.frames.count + 3,
            "Fresh frame identity/count")
        try require(added.frames[0] == original.frames[0] && added.frames[4] == original.frames[1], "Original frame overwritten or moved incorrectly")
        try require(Array(added.frames[1...3]).map(\.id) == ids && added.activeFrameID == ids[0], "Inserted order/selection")
        try require(added.activeLayerID == original.activeLayerID && added.layers.count == original.layers.count + 1,
            "Drawing layer selection/shared reference layer")
        for (offset, frame) in added.frames[1...3].enumerated() {
            try require(frame.durationTicks == 1 && frame.elements.isEmpty && frame.rasterLayerID == added.layers.last?.id,
                "Reference frame timing/layer")
            try require(vm.rasterData(frame.rasterAssetID) == imports[offset].normalizedPNG,
                "Owned PNG differs from decoded input")
        }
        try require(added.revision == original.revision + 1, "Import was not one document transaction")
        print("PASS real sequence insertion preserves original frames and bytes in one revision")
        vm.undo()
        try require(vm.document.frames == original.frames && vm.document.layers == original.layers && vm.document.activeFrameID == original.activeFrameID,
            "One Undo did not restore entire sequence")
        vm.redo()
        try require(vm.document.frames == added.frames && vm.document.layers == added.layers, "Redo identities/assets changed")
        print("PASS atomic Undo/Redo preserves stable frame/asset identities")
        let saved = await vm.save()
        try require(saved, "Production save")
        guard let stored = try storage.loadAnimation(id: original.id) else { throw Failure(message: "Production load") }
        let reopened = StudioViewModel(storage: storage), opened = await reopened.openProject(stored.metadata)
        try require(opened && reopened.document.frames == added.frames && reopened.document.layers == added.layers, "Cold reopen differs")
        for imported in imports + [originalImage] {
            let id = "image-" + imported.id.uuidString
            try require(reopened.rasterData(id) == imported.normalizedPNG && reopened.originalImageSource(id)?.originalData == imported.originalData,
                "Cold reopen lost original PNG data")
        }
        print("PASS production save and cold reopen retain all original/sequence assets")
        print("STUDIO_IMAGE_SEQUENCE_TESTS=PASS groups=8")
    }
}
