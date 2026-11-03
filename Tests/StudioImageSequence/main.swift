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

        // #199/#200: the movie behind a reference sequence is project-managed
        // media; its measured metadata and trim/speed mapping persist with it.
        let movieID = UUID(), movieBytes = Data((0..<4096).map { UInt8($0 % 251) })
        let mapping = StudioVideoSourceMapping(sourceStartSeconds: 1, sourceEndSeconds: 3, projectStartSeconds: 0, speed: 0.5,
            rotationDegrees: 270, aspect: .portrait9x16)
        // #201: framing is persisted only when chosen; earlier mappings keep their bytes and decode unframed.
        let legacyMapping = StudioVideoSourceMapping(sourceStartSeconds: 1, sourceEndSeconds: 3, projectStartSeconds: 0, speed: 0.5)
        let legacyJSON = try JSONEncoder().encode(legacyMapping)
        try require(!String(decoding: legacyJSON, as: UTF8.self).contains("rotation") && !String(decoding: legacyJSON, as: UTF8.self).contains("aspect"),
            "Unframed mapping gained framing keys")
        let legacyDecoded = try JSONDecoder().decode(StudioVideoSourceMapping.self, from: Data(#"{"sourceStartSeconds":1,"sourceEndSeconds":3,"projectStartSeconds":0,"speed":0.5}"#.utf8))
        try require(legacyDecoded == legacyMapping && legacyDecoded.rotationDegrees == 0 && legacyDecoded.aspect == .original, "Earlier mapping decoded with framing")
        try require(try JSONDecoder().decode(StudioVideoSourceMapping.self, from: JSONEncoder().encode(mapping)) == mapping, "Framing lost in mapping roundtrip")
        var turned = mapping; turned.rotationDegrees = 45
        try require(mapping.isValid && !turned.isValid, "Invalid rotation accepted by the persisted mapping")
        let video = StudioViewModel.ImportedVideoSource(
            reference: StudioVideoReference(id: movieID, name: "Phone clip", container: "mov",
                metadata: .init(durationSeconds: 4, byteCount: movieBytes.count, orientedWidth: 1080, orientedHeight: 1920,
                    rotationDegrees: 90, isMirrored: false, nominalFrameRate: 30, hasVariableFrameRate: false, hasAudio: true),
                mapping: mapping),
            movie: StoredVideoSource(id: movieID, name: "Phone clip", container: "mov", data: movieBytes))
        let videoFrames = try [image(0), image(1)], beforeVideo = reopened.document
        func attachVideo(_ value: StudioViewModel.ImportedVideoSource) throws -> [String] {
            try reopened.attachImportedImageSequence(videoFrames, expectedProjectID: beforeVideo.id,
                expectedRevision: beforeVideo.revision, frameID: beforeVideo.activeFrameID,
                layerID: beforeVideo.activeLayerID, video: value)
        }
        var mismatched = video; mismatched.reference.metadata.byteCount = 17
        try rejects { _ = try attachVideo(mismatched) }
        try require(reopened.document == beforeVideo && reopened.videoSource(forReferenceID: movieID) == nil,
            "Inconsistent movie metadata partially attached")
        _ = try attachVideo(video)
        let attachedReference = reopened.document.videoReferences?.first
        try require(attachedReference?.mapping == mapping && attachedReference?.metadata.rotationDegrees == 90 &&
            attachedReference?.frameAssetIDs == videoFrames.map { "image-" + $0.id.uuidString } &&
            reopened.videoSource(forReferenceID: movieID)?.data == movieBytes &&
            reopened.document.revision == beforeVideo.revision + 1, "Movie, mapping and frames were not one transaction")
        let savedVideo = await reopened.save()
        try require(savedVideo, "Video project save")
        guard let storedVideo = try storage.loadAnimation(id: original.id) else { throw Failure(message: "Video project load") }
        try require(storedVideo.videoSources?.map(\.data) == [movieBytes], "Saved project does not own the movie bytes")
        let cold = StudioViewModel(storage: storage), coldOpened = await cold.openProject(storedVideo.metadata)
        try require(coldOpened && cold.document.videoReferences == reopened.document.videoReferences &&
            cold.videoSource(forReferenceID: movieID)?.data == movieBytes, "Cold reopen lost the retained movie or mapping")
        try require(cold.document.videoReferences?.first?.mapping.rotationDegrees == 270 &&
            cold.document.videoReferences?.first?.mapping.aspect == .portrait9x16, "Cold reopen lost the panel rotation or aspect")
        reopened.undo()
        try require(reopened.document.videoReferences == nil && reopened.videoSource(forReferenceID: movieID) != nil,
            "Undo must drop the reference but keep bytes for Redo")
        let savedUndo = await reopened.save()
        guard savedUndo, let undone = try storage.loadAnimation(id: original.id) else { throw Failure(message: "Undo save") }
        try require(undone.videoSources == nil, "A removed reference left its movie in later saves")
        print("PASS retained movie, metadata and mapping: atomic attach, save, cold reopen and Undo cleanup")
        print("STUDIO_IMAGE_SEQUENCE_TESTS=PASS groups=9")
    }
}
