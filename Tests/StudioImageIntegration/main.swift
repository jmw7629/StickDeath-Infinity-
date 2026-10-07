import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

private struct Failure: Error { let message: String }
private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw Failure(message: message) }
}
private func rejects(_ action: () throws -> Void) throws {
    do { try action() } catch { return }
    throw Failure(message: "Expected explicit rejection")
}

/// Entire production decoder, document, VM, store, renderer and PNG exporter.
/// All media fixtures are generated here; no mirrored image/persistence model.
@main @MainActor struct StudioImageIntegrationTests {
    static let fm = FileManager.default
    static func png(width: Int = 80, height: Int = 40, orientation: Int = 1, noise: Bool = false, opaqueBlue: Bool = false) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: width * height * 4), seed: UInt32 = 0x83726519
        for pixel in 0..<(width * height) {
            let x = pixel % width, i = pixel * 4
            if noise {
                for channel in 0..<3 { seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5; bytes[i + channel] = UInt8(truncatingIfNeeded: seed) }
                bytes[i + 3] = 255
            } else {
                bytes[i] = x < width / 2 ? 255 : 0
                bytes[i + 2] = x < width / 2 ? 0 : (opaqueBlue ? 255 : 128)
                bytes[i + 3] = x < width / 2 ? 255 : (opaqueBlue ? 255 : 128)
            }
        }
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue:
                CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let data = NSMutableData()
        let writer = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(writer, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        try require(CGImageDestinationFinalize(writer), "Fixture PNG encode failed")
        return data as Data
    }
    static func imported(_ bytes: Data, in root: URL, name: String = "Asymmetric still") async throws -> StudioImageImportService.ImportedImage {
        let file = root.appendingPathComponent(UUID().uuidString + ".png")
        try bytes.write(to: file, options: .withoutOverwriting)
        return try await StudioImageImportService().importImage(from: file, name: name, scratchParent: root)
    }
    static func project(_ root: URL) async throws -> (StudioViewModel, DeviceStorageManager) {
        let store = DeviceStorageManager(documentsDirectory: root.appendingPathComponent(UUID().uuidString))
        let vm = StudioViewModel(storage: store)
        let created = await vm.createProject(name: "Image integration", width: 160, height: 160, fps: 12)
        try require(created, "Actual create/save failed")
        return (vm, store)
    }
    @discardableResult static func attach(_ image: StudioImageImportService.ImportedImage, to vm: StudioViewModel) throws -> String {
        try vm.attachImportedImage(image, expectedProjectID: vm.document.id, expectedRevision: vm.document.revision,
            frameID: vm.document.activeFrameID, layerID: vm.document.activeLayerID)
    }
    struct Raster {
        let width: Int, height: Int
        let bytes: [UInt8]
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(bytes[(y * width + x) * 4..<(y * width + x) * 4 + 4]) }
    }
    static func pixels(_ image: CGImage) -> Raster {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return Raster(width: image.width, height: image.height, bytes: bytes)
    }
    static func pixel(_ actual: [UInt8], _ expected: [UInt8]) throws {
        try require(zip(actual, expected).allSatisfy { abs(Int($0.0) - Int($0.1)) <= 2 }, "RGBA \(actual) != \(expected)")
    }
    static func render(_ vm: StudioViewModel, transparent: Bool = false, scale: Double = 1, frameOverride: AnimationFrame? = nil, layersOverride: [CanvasLayer]? = nil, rasterMaximumDimension: Int = 128) throws -> Raster {
        let doc = vm.document, frame = frameOverride ?? vm.currentFrame, data = vm.rasterData(frame.rasterAssetID)
        let layers = layersOverride ?? doc.layers
        let brush = try StudioFrameRenderer.prepare(frame: frame)
        let sources = vm.rasterSources(for: frame)
        let rasters = try StudioFrameRenderer.prepareRasters(frame: frame, layers: layers, sourceData: sources, maximumDimension: rasterMaximumDimension)
        let effects = try StudioSmudgeReplay.prepare(frame: frame, layers: layers,
            canvasSize: CGSize(width: doc.width, height: doc.height), rasterData: data, rasterDataByID: sources)
        var failure: Error?
        let content = Canvas { context, size in
            if !transparent { context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white)) }
            failure = StudioFrameRenderer.draw(context: &context, frame: frame, layers: layers,
                canvasSize: CGSize(width: doc.width, height: doc.height), size: size,
                rasterData: data, preparedBrushes: brush, preparedSmudges: effects, rasterSources: sources, preparedRasters: rasters)
        }.frame(width: Double(doc.width) * scale, height: Double(doc.height) * scale)
        let image = ImageRenderer(content: content); image.scale = 1
        guard let cg = image.cgImage else { throw Failure(message: "Actual SwiftUI renderer failed") }
        if let failure { throw failure }
        return pixels(cg)
    }
    static func decoded(_ url: URL) throws -> Raster {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure(message: "Actual exported PNG could not reopen") }
        return pixels(image)
    }
    static func main() async {
        do { try await run() } catch { print("STUDIO_IMAGE_INTEGRATION_TESTS=FAIL \(error)"); exit(1) }
    }
    static func run() async throws {
        // Large, real snapshot fixtures may use an explicitly supplied scratch
        // volume. Foundation can ignore TMPDIR on macOS. CI keeps its default.
        var scratchParent = fm.temporaryDirectory
        if let path = ProcessInfo.processInfo.environment["SDI_IMAGE_TEST_SCRATCH_DIRECTORY"] {
            try require(path.hasPrefix("/"), "Image test scratch must be an absolute directory")
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            try require(values.isDirectory == true && values.isSymbolicLink != true,
                        "Image test scratch must be an existing directory, not a symbolic link")
            scratchParent = directory
        }
        let root = scratchParent.appendingPathComponent("sdi-image-integration-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let original = try png(), image = try await imported(original, in: root)
        let evidence: URL?
        if let path = ProcessInfo.processInfo.environment["SDI_IMAGE_TEST_ARTIFACTS"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            evidence = directory
            print("IMAGE_TEST_ARTIFACTS=\(directory.path)")
        } else { evidence = nil }
        var passed = 0
        func test(_ name: String, _ action: () async throws -> Void) async throws {
            try await action(); passed += 1; print("PASS \(name)")
        }
        try await test("actual still attaches in one history transaction with stable identities and aspect fit") {
            let (vm, _) = try await project(root), before = vm.document
            let id = try attach(image, to: vm)
            try require(vm.document.schemaVersion == 3 && vm.document.revision == before.revision + 1 && vm.layers.count == 2,
                "Image did not become one version3 canonical edit")
            try require(vm.document.activeLayerID == before.activeLayerID && vm.currentFrame.id == before.activeFrameID && vm.frames.count == 1,
                "Image import changed selection or other frame timing")
            try require(vm.currentFrame.rasterAssetID == id && vm.currentFrame.rasterPlacement == .init(x: 0, y: 40, width: 160, height: 80), "Aspect-fit placement is wrong")
            try require(vm.originalImageSource(id)?.originalData == original && vm.rasterData(id) == image.normalizedPNG, "Original/normalized bytes were not retained separately")
            let rendered = try render(vm)
            try pixel(rendered.pixel(30, 15), [255, 255, 255, 255]); try pixel(rendered.pixel(30, 80), [255, 0, 0, 255])
            try pixel(rendered.pixel(130, 80), [127, 127, 255, 255])
            vm.undo(); try require(vm.currentFrame.rasterAssetID == nil && vm.layers == before.layers && !vm.canUndo, "One Undo did not restore the whole prior document")
            try require(vm.originalImageSource(id)?.originalData == original, "Undo destroyed the image needed for Redo")
            vm.redo(); try require(try render(vm).bytes == rendered.bytes && vm.currentFrame.rasterAssetID == id, "Redo changed image identity or pixels")
        }
        try await test("actual snapshot save/reopen and PNG sequence/spritesheet use the same image pixels") {
            let (vm, store) = try await project(root), id = try attach(image, to: vm)
            let live = try render(vm); vm.duplicateFrame(); try require(vm.frames.count == 2, "Duplicate failed")
            let saved = await vm.save(); try require(saved, "Actual image snapshot save failed")
            let stored = try store.loadAnimation(id: vm.document.id)!
            try require(stored.frames.count == 2 && stored.frames.allSatisfy { $0.sourceImage?.originalData == original }, "Store lost original bytes in duplicate")
            let reopened = StudioViewModel(storage: store), opened = await reopened.openProject(stored.metadata)
            try require(opened && reopened.document == vm.document && reopened.originalImageSource(id)?.originalData == original, "Real reopen changed the image document")
            try require(try render(reopened).bytes == live.bytes, "Reopened image pixels differ")
            for format in [StudioExportService.Format.pngSequence, .spritesheet] {
                let output = try await StudioExportService().export(document: reopened.document, format: format, outputParent: root, rasterData: { reopened.rasterData($0) })
                let png = try decoded(output.imageURLs[0]); try require(png.width == (format == .pngSequence ? 160 : 320) && png.height == 160, "Export geometry is incorrect")
                try pixel(png.pixel(30, 15), [255, 255, 255, 255]); try pixel(png.pixel(30, 80), [255, 0, 0, 255])
                if format == .pngSequence { try require(png.bytes == live.bytes, "Live and real PNG rendering diverged") }
                else { try pixel(png.pixel(190, 80), [255, 0, 0, 255]) }
                if let evidence { try fm.copyItem(at: output.imageURLs[0], to: evidence.appendingPathComponent(format.rawValue + ".png")) }
            }
        }
        try await test("layer visibility opacity ordering and alpha affect shared live and actual export pixels") {
            let (vm, _) = try await project(root); _ = try attach(image, to: vm)
            let layer = vm.currentFrame.rasterLayerID!
            vm.setLayerOpacity(layer, opacity: 0.5); try pixel(render(vm).pixel(30, 80), [255, 128, 128, 255])
            vm.toggleLayerVisibility(layer); try pixel(render(vm).pixel(30, 80), [255, 255, 255, 255]); vm.toggleLayerVisibility(layer)
            vm.setLayerOpacity(layer, opacity: 1)
            let line = DrawnElement(id: UUID().uuidString, tool: .line, points: [.init(x: 0, y: 80), .init(x: 160, y: 80)], color: "#00FF00", width: 20, opacity: 1, layerID: vm.activeLayerID)
            try require(vm.commitElement(line), "Editable overlay failed"); try pixel(render(vm).pixel(30, 80), [0, 255, 0, 255])
            vm.moveLayerUp(layer); try pixel(render(vm).pixel(30, 80), [255, 0, 0, 255]); vm.undo(); vm.undo()
            let transparent = try await StudioExportService().export(document: vm.document, format: .pngSequence, outputParent: root, background: .transparent, rasterData: { vm.rasterData($0) })
            let output = try decoded(transparent.imageURLs[0]); try pixel(output.pixel(30, 15), [0, 0, 0, 0]); try pixel(output.pixel(130, 80), [0, 0, 128, 128])
            let thumb = try render(vm, scale: 0.25); try pixel(thumb.pixel(7, 3), [255, 255, 255, 255]); try pixel(thumb.pixel(7, 20), [255, 0, 0, 255])
            vm.selectLayer(layer)
            let eraser = DrawnElement(id: UUID().uuidString, tool: .eraser, points: [.init(x: 30, y: 80)], color: "#000000", width: 10, opacity: 1, layerID: layer)
            try require(vm.commitElement(eraser), "Eraser could not edit selected image layer")
            try pixel(render(vm).pixel(30, 80), [255, 255, 255, 255])
            try require(vm.originalImageSource(vm.currentFrame.rasterAssetID!)?.originalData == original, "Editing an image layer modified the original bytes")
        }
        try await test("oriented input keeps exact original metadata and aspect fit after normalization") {
            let bytes = try png(orientation: 6), rotated = try await imported(bytes, in: root)
            let (vm, store) = try await project(root), id = try attach(rotated, to: vm)
            try require(rotated.width == 40 && rotated.height == 80 && vm.currentFrame.rasterPlacement == .init(x: 40, y: 0, width: 80, height: 160), "Image orientation or fit changed")
            let saved = await vm.save(); try require(saved, "Oriented image save failed")
            let stored = try store.loadAnimation(id: vm.document.id)!
            try require(stored.frames[0].sourceImage?.originalData == bytes && vm.originalImageSource(id)?.originalOrientation == 6, "Source orientation/bytes were overwritten")
            let rendered = try render(vm); try pixel(rendered.pixel(10, 80), [255, 255, 255, 255])
        }
        try await test("fractional fit rounding remains centered and preserves asymmetric original pixels") {
            for (width, canvas) in [(147, 160), (133, 270), (133, 1080), (29, 1920)] {
                let bytes = try png(width: width, height: 20), decodedImage = try await imported(bytes, in: root)
                let store = DeviceStorageManager(documentsDirectory: root.appendingPathComponent(UUID().uuidString))
                let vm = StudioViewModel(storage: store)
                let created = await vm.createProject(name: "Fractional image fit", width: canvas, height: canvas, fps: 12)
                try require(created, "Fractional fit fixture could not create its actual project")
                let asset = try attach(decodedImage, to: vm), rect = vm.currentFrame.rasterPlacement!
                try require(rect.x == 0 && rect.width == Double(canvas) && rect.y >= 0 && rect.y + rect.height <= Double(canvas),
                    "Roundoff rejected or displaced a valid fit")
                try require(abs(rect.y * 2 + rect.height - Double(canvas)) < 0.000001,
                    "Fit was not centered after floating-point normalization")
                let result = try render(vm)
                try pixel(result.pixel(canvas / 4, canvas / 2), [255, 0, 0, 255])
                try pixel(result.pixel(canvas * 3 / 4, canvas / 2), [127, 127, 255, 255])
                try pixel(result.pixel(canvas / 4, 1), [255, 255, 255, 255])
                try require(vm.originalImageSource(asset)?.originalData == bytes,
                    "Numerical fit changed the original asymmetric input")
            }
        }
        try await test("bottom frame Copy captures displayed playback content without changing selection locks or history") {
            let (vm, _) = try await project(root)
            let frameA = vm.currentFrame.id
            let line = DrawnElement(id: UUID().uuidString, tool: .line,
                points: [.init(x: 20, y: 20), .init(x: 100, y: 20)], color: "#00FF00", width: 8, opacity: 1, layerID: vm.activeLayerID)
            try require(vm.commitElement(line), "Playback Copy frame A fixture")
            let pixelsA = try render(vm).bytes
            vm.addFrame(); let frameB = vm.currentFrame.id, asset = try attach(image, to: vm)
            let pixelsB = try render(vm).bytes
            try require(pixelsA != pixelsB, "Playback fixture frames are indistinguishable")
            let imageLayer = vm.currentFrame.rasterLayerID!
            vm.setLayerLockMode(imageLayer, mode: .full)
            vm.selectFrame(frameA)
            let before = vm.document, undo = vm.canUndo, redo = vm.canRedo, selection = vm.selectedElementIDs
            vm.togglePlayback(); vm.advancePlaybackFrame()
            try require(vm.isPlaying && vm.currentFrame.id == frameB && vm.document.activeFrameID == frameA && vm.canCopyBottomSelection,
                        "Actual playback did not display B while retaining editing frame A")
            vm.copyBottomSelection()
            try require(vm.document == before && vm.selectedElementIDs == selection && vm.canUndo == undo && vm.canRedo == redo && vm.isPlaying,
                        "Read-only playback Copy changed editing selection locks history or playback")
            vm.advancePlaybackFrame()
            try require(vm.currentFrame.id == frameA, "Playback did not advance beyond copied B")
            vm.stopPlayback()
            vm.copyFrame("missing-playback-frame")
            try require(vm.document == before && vm.canPaste && vm.bottomPasteLabel == "Paste frame",
                        "Rejected explicit-ID copy destroyed successful playback clipboard")
            vm.pasteClipboard()
            try require(vm.frames.count == before.frames.count + 1 && vm.currentFrame.rasterAssetID == asset &&
                        vm.currentFrame.elements.isEmpty && render(vm).bytes == pixelsB && vm.layers == before.layers,
                        "Bottom Copy pasted editing A instead of displayed B or changed locks")
            try require(vm.frames.first(where: { $0.id == frameA }) == before.frames.first(where: { $0.id == frameA }) &&
                        vm.frames.first(where: { $0.id == frameB }) == before.frames.first(where: { $0.id == frameB }) &&
                        vm.originalImageSource(asset)?.originalData == original && vm.rasterData(asset) == image.normalizedPNG,
                        "Playback frame Copy/Paste changed source frames or managed image bytes")
            vm.undo()
            try require(vm.frames == before.frames && vm.document.activeFrameID == frameA, "Paste was not one Undo transaction")
            // Explicit timeline-ID Copy remains authoritative even while another frame is shown.
            vm.togglePlayback(); vm.advancePlaybackFrame()
            try require(vm.currentFrame.id == frameB, "Explicit-ID playback fixture")
            vm.copyFrame(frameA); vm.stopPlayback(); vm.pasteClipboard()
            try require(vm.currentFrame.rasterAssetID == nil && render(vm).bytes == pixelsA,
                        "Displayed-frame fix overrode explicit timeline-ID copy")
            vm.undo(); vm.selectFrame(frameA); vm.selectDrawingTool(.move); vm.selectionMode = .new
            try require(vm.selectElement(at: .init(x: 50, y: 20)) == line.id, "Stopped-copy explicit selection fixture")
            let stopped = vm.document, selected = vm.selectedElementIDs
            vm.copyFrame()
            try require(vm.document == stopped && vm.selectedElementIDs == selected && selected == [line.id],
                        "Stopped frame Copy changed explicit selection")
            vm.pasteFrame()
            try require(vm.currentFrame.rasterAssetID == nil && render(vm).bytes == pixelsA,
                        "Stopped frame Copy no longer captures editing frame")
        }
        try await test("frame clipboard retains image beyond deleted original and expired undo history") {
            let (vm, store) = try await project(root), id = try attach(image, to: vm), originalFrame = vm.currentFrame.id
            vm.copyFrame(); vm.addFrame(); vm.deleteFrame(originalFrame)
            for i in 0..<55 { vm.setLayerOpacity(vm.activeLayerID, opacity: i % 2 == 0 ? 0.75 : 1) }
            try require(vm.frames.allSatisfy { $0.rasterAssetID == nil } && vm.originalImageSource(id)?.originalData == original, "Frame clipboard lost its owned source after history trim")
            vm.pasteFrame(); try require(vm.currentFrame.rasterAssetID == id && vm.currentFrame.rasterPlacement != nil, "Real frame paste did not restore retained still")
            let saved = await vm.save(); try require(saved, "Pasted still could not save")
            let stored = try store.loadAnimation(id: vm.document.id)!, reopened = StudioViewModel(storage: store)
            let opened = await reopened.openProject(stored.metadata); try require(opened && reopened.originalImageSource(id)?.originalData == original, "Clipboard lifetime was not persisted after paste")
        }
        try await test("image bytes prune only after current history and clipboard all release ownership") {
            let (vm, _) = try await project(root), id = try attach(image, to: vm)
            vm.copyFrame(); vm.undo(); vm.copyFrame() // The actual blank frame replaces the clipboard.
            vm.addFrame() // A new branch releases Redo's image ownership.
            try require(vm.originalImageSource(id) == nil && vm.managedImageByteCount == 0, "Released image stayed retained forever")
        }
        try await test("schema3 survives styled brush commit frame duplicate paste and old JSON defaults") {
            let legacy = try StudioDocument.new(name: "Old", width: 160, height: 160, fps: 12)
            let decoded = try JSONDecoder().decode(StudioDocument.self, from: JSONEncoder().encode(legacy))
            try require(decoded.schemaVersion == 1 && decoded.frames[0].rasterPlacement == nil, "Legacy nil placement did not decode")
            let (vm, _) = try await project(root); _ = try attach(image, to: vm)
            let brush = StudioBrushDescriptor(family: .round, seed: 123)
            let stroke = DrawnElement(id: UUID().uuidString, tool: .brush, points: [.init(x: 20, y: 20), .init(x: 40, y: 30)], color: "#FF0000", width: 8, opacity: 0.5, layerID: vm.activeLayerID, brush: brush)
            try require(vm.commitElement(stroke) && vm.document.schemaVersion == 3, "Brush downgraded the image schema")
            vm.copyFrame(); vm.pasteFrame(); vm.duplicateFrame()
            try require(vm.document.schemaVersion == 3 && vm.frames.allSatisfy { $0.rasterPlacement != nil }, "Copy/paste downgraded or dropped placement")
            var invalid = vm.document; invalid.schemaVersion = 2; try rejects { try invalid.validate() }
            invalid = vm.document; invalid.frames[0].rasterPlacement = .init(x: -.infinity, y: 0, width: 2, height: 2); try rejects { try invalid.validate() }
        }
        try await test("duplicate source identity stale context input drafts and cancellation never attach an image") {
            let (vm, _) = try await project(root), before = vm.document
            for (projectID, revision, frameID, layerID) in [(UUID(), before.revision, before.activeFrameID, before.activeLayerID), (before.id, before.revision + 1, before.activeFrameID, before.activeLayerID), (before.id, before.revision, "missing", before.activeLayerID), (before.id, before.revision, before.activeFrameID, "missing")] {
                try rejects { _ = try vm.attachImportedImage(image, expectedProjectID: projectID, expectedRevision: revision, frameID: frameID, layerID: layerID) }
            }
            try require(vm.beginStrokeInput(id: "active"), "Actual touch capture did not start")
            try rejects { _ = try attach(image, to: vm) }; try require(vm.activeStrokeID == "active", "Import discarded active touch input"); vm.finishStrokeInput(id: "active")
            let draft = DrawnElement(id: "rejected", tool: .brush, points: [.init(x: 10, y: 10)], color: "#FF0000", width: 10, opacity: 1, layerID: vm.activeLayerID)
            vm.retainRejectedBrush(draft, frameID: vm.currentFrame.id, reason: "Test rejected stroke")
            try rejects { _ = try attach(image, to: vm) }; try require(vm.pendingBrushStroke?.element == draft, "Import discarded rejected drawing"); vm.discardRejectedBrush()
            for boundary in [1, 2] {
                var checks = 0
                try rejects { _ = try vm.attachImportedImage(image, expectedProjectID: before.id, expectedRevision: before.revision, frameID: before.activeFrameID, layerID: before.activeLayerID, checkCancellation: { checks += 1; if checks == boundary { throw CancellationError() } }) }
            }
            try require(vm.document == before && !vm.canUndo && vm.managedImageByteCount == 0, "Rejected import changed document/history/assets")
            _ = try attach(image, to: vm); let attached = vm.document
            try rejects { _ = try attach(image, to: vm) }; try require(vm.document == attached, "Reusing an existing source identity replaced current raster")
        }
        try await test("final context check rejects synchronous reentrant changes without overwriting them") {
            let (vm, _) = try await project(root), captured = vm.document; var checks = 0
            try rejects { _ = try vm.attachImportedImage(image, expectedProjectID: captured.id, expectedRevision: captured.revision,
                frameID: captured.activeFrameID, layerID: captured.activeLayerID, checkCancellation: { checks += 1; if checks == 2 { vm.addFrame() } }) }
            try require(vm.frames.count == 2 && vm.frames.allSatisfy { $0.rasterAssetID == nil } && vm.managedImageByteCount == 0, "Image overwrote a newer document")
        }
        try await test("invalid original metadata normalized pixels and source collisions fail before history") {
            let (vm, _) = try await project(root), before = vm.document
            let bad = StudioImageImportService.ImportedImage(id: image.id, name: image.name, container: image.container, originalData: image.originalData,
                originalWidth: image.originalWidth + 1, originalHeight: image.originalHeight, originalOrientation: image.originalOrientation,
                width: image.width, height: image.height, normalizedPNG: image.normalizedPNG)
            try rejects { _ = try attach(bad, to: vm) }
            let corrupt = StudioImageImportService.ImportedImage(id: image.id, name: image.name, container: image.container, originalData: image.originalData,
                originalWidth: image.originalWidth, originalHeight: image.originalHeight, originalOrientation: image.originalOrientation,
                width: image.width, height: image.height, normalizedPNG: Data("corrupt".utf8))
            try rejects { _ = try attach(corrupt, to: vm) }
            try require(vm.document == before && vm.managedImageByteCount == 0 && !vm.canUndo, "Invalid image changed production editor")
            _ = try attach(image, to: vm); vm.addFrame(); let current = vm.document
            try rejects { _ = try attach(image, to: vm) }; try require(vm.document == current, "Reused source identity was overwritten")
        }
        try await test("actual store budget rejects repeated image frames transactionally before save") {
            let noise = try await imported(png(width: 1024, height: 1024, noise: true), in: root)
            let (vm, store) = try await project(root); _ = try attach(noise, to: vm)
            var rejected = false
            for _ in 0..<10 {
                let before = vm.document, bytes = vm.managedImageByteCount
                vm.duplicateFrame()
                if vm.frames.count == before.frames.count {
                    try require(vm.document == before && vm.managedImageByteCount == bytes && vm.message != nil, "Budget failure partially edited the project")
                    rejected = true; break
                }
            }
            try require(rejected, "Duplicate ignored the exact 40MiB atomic snapshot payload limit")
            let saved = await vm.save(); try require(saved, "Last accepted exact-budget document cannot actually save")
            let stored = try store.loadAnimation(id: vm.document.id)!
            try store.preflightAnimation(stored)
            print("IMAGE_BUDGET_ACCEPTED_FRAMES=\(stored.frames.count) UNIQUE_IMAGE_BYTES=\(vm.managedImageByteCount)")
            let warm = Date()
            for _ in 0..<240 { _ = try StudioRasterImage.prepare(assetID: vm.currentFrame.rasterAssetID!, data: noise.normalizedPNG, managed: true, maximumDimension: 1024) }
            print("LARGE_RASTER_240_PREPARES_SECONDS=\(Date().timeIntervalSince(warm))")
            let started = Date()
            let stroke = DrawnElement(id: UUID().uuidString, tool: .line, points: [.init(x: 10, y: 10), .init(x: 20, y: 10)], color: "#FF0000", width: 2, opacity: 1, layerID: vm.activeLayerID)
            try require(vm.commitElement(stroke), "Near-budget document rejected a small valid drawing")
            print("NEAR_BUDGET_COMPLETE_COMMIT_PREFLIGHT_SECONDS=\(Date().timeIntervalSince(started))")
        }
        try await test("failed disk save keeps attached image and dirty work available for actual retry") {
            let documents = root.appendingPathComponent(UUID().uuidString), store = DeviceStorageManager(documentsDirectory: documents)
            let vm = StudioViewModel(storage: store)
            let created = await vm.createProject(name: "Save failure", width: 160, height: 160, fps: 12); try require(created, "Create failed")
            let pointer = documents.appendingPathComponent("Animations/\(vm.document.id.uuidString)/.sdi/current.json")
            let pointerBytes = try Data(contentsOf: pointer), backup = pointer.deletingLastPathComponent().appendingPathComponent("test-pointer-backup")
            try fm.moveItem(at: pointer, to: backup)
            let foreign = root.appendingPathComponent("foreign-current"); try Data([12, 13]).write(to: foreign)
            try fm.createSymbolicLink(at: pointer, withDestinationURL: foreign)
            let id = try attach(image, to: vm), edited = vm.document
            let saved = await vm.save()
            try require(!saved && vm.isDirty && vm.document == edited && vm.originalImageSource(id)?.originalData == original,
                "Failed storage publication discarded or falsely saved attached image")
            try require(try Data(contentsOf: foreign) == Data([12, 13]) && Data(contentsOf: backup) == pointerBytes, "Failed save overwrote original or foreign pointer bytes")
            try fm.removeItem(at: pointer); try fm.moveItem(at: backup, to: pointer)
            let retried = await vm.save(); try require(retried && !vm.isDirty, "Preserved image could not be saved after safe repair")
            let stored = try store.loadAnimation(id: vm.document.id)!, reopened = StudioViewModel(storage: store)
            let opened = await reopened.openProject(stored.metadata)
            try require(opened && reopened.originalImageSource(id)?.originalData == original, "Retry did not persist actual original image")
        }
        try await test("missing managed source fails closed on reopen; conflicting duplicate bytes cannot save") {
            let (vm, store) = try await project(root); _ = try attach(image, to: vm)
            vm.duplicateFrame(); let saved = await vm.save(); try require(saved, "Fixture save failed")
            let originalProject = try store.loadAnimation(id: vm.document.id)!
            var conflicting = originalProject; conflicting.frames[1].imageData = Data([3, 4, 5])
            try rejects { try store.preflightAnimation(conflicting) }; try rejects { try store.saveAnimation(conflicting) }
            try require(try store.loadAnimation(id: vm.document.id)!.frames == originalProject.frames, "Conflicting source IDs overwrote selected snapshot")
            var missing = originalProject; missing.frames[0].sourceImage = nil; missing.frames[1].sourceImage = nil
            try store.saveAnimation(missing) // Corrupt fixture through the opaque store API, never through the editor.
            let reopened = StudioViewModel(storage: store), before = reopened.document
            let opened = await reopened.openProject(missing.metadata)
            try require(!opened && !reopened.isEditing && reopened.document == before && reopened.message != nil, "Missing managed source was silently adopted")
            try require(try store.loadAnimation(id: vm.document.id)!.frames == missing.frames, "Failed open rewrote corrupt source evidence")
        }
        try await test("command final cancellation callback cannot overwrite an intervening actual VM edit") {
            let (probe, _) = try await project(root); _ = try attach(image, to: probe)
            @MainActor func request(_ vm: StudioViewModel) -> StudioCommandRequest {
                .init(requestID: UUID(), projectID: vm.document.id, expectedRevision: vm.document.revision,
                    action: .apply([.addFrame(.init(after: .id(vm.document.activeFrameID), result: "new-frame"))]))
            }
            var probeChecks = 0
            _ = try probe.applyStudioCommands(request(probe), checkCancellation: { probeChecks += 1 })
            try require(probeChecks > 1, "Actual command transaction did not reach its final cancellation boundary")
            let (vm, _) = try await project(root); let asset = try attach(image, to: vm)
            let before = vm.document, command = request(vm)
            var checks = 0, intervening: StudioDocument?
            do {
                _ = try vm.applyStudioCommands(command, checkCancellation: {
                    checks += 1
                    if checks == probeChecks { vm.addLayer(); intervening = vm.document }
                })
                throw Failure(message: "Stale staged command overwrote the final callback's edit")
            } catch StudioCommandError.staleRevision { }
            try require(checks == probeChecks && intervening != nil && vm.document == intervening,
                "Command failed without preserving the actual intervening document")
            try require(vm.frames.count == before.frames.count && vm.layers.count == before.layers.count + 1,
                "Stale command published its frame or erased the new layer")
            try require(vm.originalImageSource(asset)?.originalData == original, "Stale command discarded original image bytes")
            vm.undo(); try require(vm.layers == before.layers && vm.frames == before.frames, "Intervening edit history was overwritten")
        }
        try await test("managed original records without placement archive are preserved and refused as legacy") {
            let (vm, store) = try await project(root); _ = try attach(image, to: vm)
            let saved = await vm.save(); try require(saved, "Image fixture save failed")
            var missing = try store.loadAnimation(id: vm.document.id)!
            missing.editableDocumentData = nil
            try store.saveAnimation(missing) // Simulate loss of the archive through the opaque storage API.
            let reopened = StudioViewModel(storage: store), before = reopened.document
            let opened = await reopened.openProject(missing.metadata)
            try require(!opened && !reopened.isEditing && reopened.document == before && reopened.message != nil,
                "Managed image without placement metadata was reinterpreted as historical stretch")
            let after = try store.loadAnimation(id: missing.id)!
            try require(after.frames == missing.frames && after.editableDocumentData == nil,
                "Refused open changed the original image evidence")
        }
        try await test("optimized snapshot encoding is real Codable-equivalent and invalidates changed image fragments") {
            let (vm, store) = try await project(root); _ = try attach(image, to: vm)
            vm.duplicateFrame(); let saved = await vm.save(); try require(saved, "Fixture save failed")
            var value = try store.loadAnimation(id: vm.document.id)!
            value.metadata.title = #"Literal "frames":[] stays text"#
            try store.preflightAnimation(value); try store.saveAnimation(value)
            var loaded = try store.loadAnimation(id: vm.document.id)!
            try require(loaded.metadata.title == value.metadata.title && loaded.frames == value.frames && loaded.editableDocumentData == value.editableDocumentData,
                "Actual encoded Revision changed metadata, frames or archive bytes")
            let reference = try JSONDecoder().decode(AnimationProject.self, from: JSONEncoder().encode(value))
            try require(loaded.frames == reference.frames && loaded.editableDocumentData == reference.editableDocumentData,
                "Optimized serializer disagrees with full production Codable values")
            for index in value.frames.indices { value.frames[index].layerData = [.init(id: UUID(), name: "New frame metadata", opacity: 0.6, blendMode: "normal", locked: false, visible: true)] }
            try store.saveAnimation(value); loaded = try store.loadAnimation(id: vm.document.id)!
            try require(loaded.frames == value.frames, "Cached image fragment retained stale frame metadata")
            let cache = DeviceStorageManager.snapshotEncodingCacheFootprint
            try require(cache.entries <= 32 && cache.bytes <= DeviceStorageManager.maximumSnapshotFrameCacheBytes, "Snapshot fragment cache exceeded bounded key/data capacity")
        }
        try await test("bottom image copy paste isolates chosen alias and delete confirmation target survives history and reopen") {
            let (vm, store) = try await project(root), asset = try attach(image, to: vm)
            let primary = vm.currentFrame.rasterLayerID!
            let line = DrawnElement(id: UUID().uuidString, tool: .line, points: [.init(x: 10, y: 10), .init(x: 60, y: 10)], color: "#00FF00", width: 4, opacity: 1, layerID: primary)
            try require(vm.commitElement(line), "Real unrelated drawing fixture failed")
            vm.duplicateLayer(primary); let alias = vm.activeLayerID
            vm.selectedTool = .move
            try require(vm.cropImage(vm.prepareImagePlacement()!, crop: .init(x: 0.1, y: 0.2, width: 0.7, height: 0.6)), "Alias crop failed")
            let descriptor = vm.currentFrame.rasterInstance(on: alias)!
            try require(vm.setImageCanvasMove(true) && vm.bottomCopyLabel == "Copy selected image", "Bottom image selection scope absent")
            let sourceBytes = vm.managedImageByteCount
            vm.copyBottomSelection()
            try require(vm.usesImageClipboard && vm.bottomPasteLabel == "Paste image" && vm.canPaste, "Bottom copy did not retain correct paste scope")
            let occupied = vm.document
            vm.pasteClipboard()
            try require(vm.currentFrame.rasterLayerInstances.count == occupied.frames[0].rasterLayerInstances.count + 1 &&
                vm.currentFrame.rasterInstance(on: primary) == occupied.frames[0].rasterInstance(on: primary) &&
                vm.currentFrame.rasterInstance(on: alias) == descriptor && vm.currentFrame.elements == occupied.frames[0].elements &&
                vm.managedImageByteCount == sourceBytes, "Bottom paste replaced existing images/drawings instead of adding one instance")
            vm.undo(); try require(vm.frames == occupied.frames && vm.layers == occupied.layers, "Paste Undo did not restore occupied frame")
            vm.addFrame(); try require(vm.canPaste, "Bottom image paste unavailable on blank frame")
            vm.pasteClipboard()
            try require(vm.currentFrame.rasterAssetID == asset && vm.currentFrame.rasterLayerInstances.count == 1 && vm.currentFrame.elements.isEmpty,
                "Bottom image copy included sibling/drawings or pasted whole frame")
            try require(vm.currentFrame.rasterCrop == descriptor.crop && vm.currentFrame.rasterPlacement == descriptor.placement && vm.managedImageByteCount == sourceBytes,
                "Bottom image paste lost selected geometry or duplicated bytes")
            let pastedPixels = try render(vm).bytes
            try require(vm.setImageCanvasMove(true), "Pasted image selection unavailable")
            let capture = vm.bottomImageSelection!
            let beforeCancellation = vm.document
            // A confirmation dismissed without invoking its destructive action
            // leaves the captured document untouched; deselection invalidates it.
            try require(vm.setImageCanvasMove(false), "Deselect failed")
            try require(!vm.deleteBottomImage(capture) && vm.document == beforeCancellation, "Stale bottom image confirmation deleted artwork")
            try require(vm.setImageCanvasMove(true), "Reselect failed")
            try require(vm.bottomImageSelection?.selectionID != capture.selectionID, "Reselect reused selection identity")
            try require(!vm.deleteBottomImage(capture) && vm.document == beforeCancellation,
                "Deselect/reselect revived an old bottom delete confirmation")
            try require(vm.deleteBottomImage(vm.bottomImageSelection!) && vm.currentFrame.rasterAssetID == nil, "Confirmed bottom image command failed")
            vm.undo(); try require(try render(vm).bytes == pastedPixels, "One Undo lost bottom-deleted image")
            vm.redo(); try require(vm.currentFrame.rasterAssetID == nil, "Redo retained deleted image")
            vm.undo()
            let saved = await vm.save(); try require(saved, "Bottom command save failed")
            let metadata = try store.loadAnimation(id: vm.document.id)!.metadata
            let reopened = StudioViewModel(storage: store), opened = await reopened.openProject(metadata)
            try require(opened && !reopened.usesImageClipboard && !reopened.hasCopiedImage && !reopened.canPaste, "Transient bottom clipboard escaped project lifecycle")
            try require(try render(reopened).bytes == pastedPixels && reopened.originalImageSource(asset)?.originalData == image.originalData,
                "Bottom image commands lost actual pixels/original on cold reopen")
        }
        try await test("latest successful global copy chooses bottom paste without failed copy fallback") {
            let (vm, _) = try await project(root); _ = try attach(image, to: vm)
            vm.selectedTool = .move; try require(vm.setImageCanvasMove(true), "Image selection")
            vm.copyBottomSelection(); try require(vm.usesImageClipboard, "Initial image copy scope")
            vm.copyFrame("missing-frame")
            try require(vm.usesImageClipboard, "Rejected frame copy discarded previous image clipboard")
            vm.setLayerLockMode(vm.currentFrame.rasterLayerID!, mode: .full)
            try require(!vm.copyImage() && vm.usesImageClipboard, "Rejected image copy changed clipboard scope")
            vm.undo()
            vm.copyFrame()
            try require(!vm.usesImageClipboard && vm.bottomPasteLabel == "Paste frame", "Frame copy failed to supersede image scope")
            let count = vm.frames.count; vm.pasteClipboard()
            try require(vm.frames.count == count + 1, "Bottom paste ignored latest frame copy")
            vm.selectedTool = .move; try require(vm.setImageCanvasMove(true), "Image reselection")
            vm.copyBottomSelection(); try require(vm.usesImageClipboard, "Second image copy failed")
            let line = DrawnElement(id: UUID().uuidString, tool: .line, points: [.init(x: 10, y: 10), .init(x: 60, y: 10)], color: "#00FF00", width: 4, opacity: 1, layerID: vm.activeLayerID)
            try require(vm.commitElement(line), "Drawing copy fixture failed")
            vm.selectedTool = .lasso
            try require(vm.selectVisibleArtwork() && vm.copySelected(), "Actual selected drawing copy failed")
            try require(!vm.usesImageClipboard && vm.bottomPasteLabel == "Paste drawing", "Drawing copy did not supersede image scope")
            let elementCount = vm.currentFrame.elements.count, frameCount = vm.frames.count
            vm.pasteClipboard()
            try require(vm.currentFrame.elements.count == elementCount + 1 && vm.frames.count == frameCount, "Bottom paste used stale image/frame instead of drawing")
        }
        try await test("frame viewer stable targets survive reorder and reject deleted IDs with real cold pixels") {
            let (vm, store) = try await project(root); _ = try attach(image, to: vm)
            let targetID = vm.currentFrame.id, expectedPixels = try render(vm).bytes
            vm.addFrame(); let blankID = vm.currentFrame.id
            let blankPixels = try render(vm).bytes
            try require(blankPixels != expectedPixels, "Distinct frame fixture failed")
            // This is the same stable ID captured by the viewer button; its
            // ordinal changes after a real reorder while the identity remains.
            vm.moveFrame(targetID, offset: 1)
            try require(vm.frames.last?.id == targetID && vm.currentFrame.id == blankID, "Reorder changed explicit selection")
            vm.selectFrame(targetID)
            try require(vm.currentFrame.id == targetID && vm.currentFrameIndex == 1 && (try render(vm).bytes) == expectedPixels,
                "Stable viewer target selected a different ordinal's artwork")
            let saved = await vm.save(); try require(saved, "Viewer target save failed")
            let metadata = try store.loadAnimation(id: vm.document.id)!.metadata
            let reopened = StudioViewModel(storage: store)
            let opened = await reopened.openProject(metadata)
            try require(opened && reopened.currentFrame.id == targetID && (try render(reopened).bytes) == expectedPixels,
                "Cold reopen lost selected frame identity or pixels")
            reopened.deleteFrame(targetID)
            let afterDelete = reopened.document, undo = reopened.canUndo, redo = reopened.canRedo
            reopened.selectFrame(targetID)
            try require(reopened.document == afterDelete && reopened.canUndo == undo && reopened.canRedo == redo &&
                reopened.currentFrame.id == blankID && (try render(reopened).bytes) == blankPixels,
                "Deleted viewer target changed another frame/history")
            reopened.undo()
            try require(reopened.frames.contains { $0.id == targetID }, "Frame Undo lost stable target")
        }
        try await test("image clipboard preserves transforms pixels originals and one-step history without replacing content") {
            let (vm, store) = try await project(root)
            let asset = try attach(image, to: vm)
            vm.selectedTool = .move
            try require(vm.cropImage(vm.prepareImagePlacement()!, crop: .init(x: 0.1, y: 0.1, width: 0.7, height: 0.8)), "Crop before copy")
            try require(vm.reflectImage(vm.prepareImagePlacement()!, axis: .horizontal), "Flip before copy")
            vm.setLayerOpacity(vm.currentFrame.rasterLayerID!, opacity: 0.5)
            let source = vm.currentFrame, expected = try render(vm).bytes
            let bytes = vm.managedImageByteCount
            try require(vm.copyImage() && vm.hasCopiedImage && vm.canPasteImage, "Copy should allow adding a separate image instance")
            let occupied = vm.document
            try require(vm.pasteImage() && vm.currentFrame.rasterLayerInstances.count == source.rasterLayerInstances.count + 1 &&
                vm.currentFrame.rasterInstance(on: source.rasterLayerID!) == source.rasterInstance(on: source.rasterLayerID!) &&
                vm.managedImageByteCount == bytes, "Paste replaced existing image or duplicated owned bytes")
            vm.undo(); try require(vm.frames == occupied.frames && vm.layers == occupied.layers && render(vm).bytes == expected,
                                   "Occupied-frame paste Undo did not restore previous pixels")
            vm.addFrame(); let blank = vm.document
            try require(vm.canPasteImage, "Blank frame should allow image paste")
            try require(!vm.pasteImage(checkCancellation: { throw CancellationError() }) && vm.document == blank, "Cancelled paste changed document")
            var intervening: StudioDocument?
            try require(!vm.pasteImage(checkCancellation: {
                vm.addFrame(); intervening = vm.document
            }) && vm.document == intervening, "Reentrant change was overwritten")
            vm.undo()
            let beforePaste = vm.document
            try require(vm.pasteImage(), "Actual image paste")
            let pasted = vm.document
            try require(pasted.revision == beforePaste.revision + 1 && vm.currentFrame.rasterAssetID == asset && vm.currentFrame.rasterLayerID != source.rasterLayerID, "Paste is not one revision with an independent layer")
            try require(vm.currentFrame.rasterCrop == source.rasterCrop && vm.currentFrame.rasterReflection == source.rasterReflection && vm.currentFrame.rasterPlacement == source.rasterPlacement, "Paste lost transforms")
            try require(try render(vm).bytes == expected && vm.managedImageByteCount == bytes, "Paste changed pixels or duplicated original bytes")
            vm.undo(); try require(vm.currentFrame.rasterAssetID == nil, "Single Undo did not remove pasted image")
            vm.redo(); try require(try render(vm).bytes == expected, "Redo lost image pixels")
            let saved = await vm.save(); try require(saved, "Pasted image save")
            let metadata = try store.loadAnimation(id: vm.document.id)!.metadata
            let reopened = StudioViewModel(storage: store)
            let opened = await reopened.openProject(metadata)
            try require(opened && !reopened.hasCopiedImage && reopened.currentFrame.rasterCrop == source.rasterCrop, "Cold reopen lost crop or persisted transient clipboard")
            try require(try render(reopened).bytes == expected && reopened.originalImageSource(asset)?.originalData == image.originalData, "Cold reopen altered pixels or source bytes")
        }
        try await test("linked image layers independently render reorder crop promote and cold reopen without copying source bytes") {
            let (vm, store) = try await project(root), asset = try attach(image, to: vm)
            let primary = vm.currentFrame.rasterLayerID!, sourceBytes = vm.managedImageByteCount
            vm.selectedTool = .move; vm.selectLayer(primary)
            try require(vm.placeImage(vm.prepareImagePlacement()!, at: .init(x: 0, y: 0, width: 80, height: 40)), "Original placement failed")
            let beforeDuplicate = vm.document
            vm.duplicateLayer(primary)
            let copy = vm.activeLayerID
            try require(copy != primary && vm.currentFrame.rasterLayerInstances.count == 2
                && vm.document.revision == beforeDuplicate.revision + 1 && vm.document.schemaVersion == 27,
                "Image layer duplicate was not one independently owned transaction")
            let primaryGeometry = vm.currentFrame.rasterInstance(on: primary)
            try require(vm.prepareImagePlacement()?.layerID == copy, "Active duplicate did not become image edit target")
            try require(vm.cropImage(vm.prepareImagePlacement()!, crop: .init(x: 0, y: 0, width: 0.5, height: 1)), "Copy crop failed")
            try require(vm.placeImage(vm.prepareImagePlacement()!, at: .init(x: 40, y: 0, width: 40, height: 40)), "Copy placement failed")
            try require(vm.currentFrame.rasterInstance(on: primary) == primaryGeometry, "Copy geometry changed original")
            try pixel(render(vm).pixel(60, 10), [255, 0, 0, 255])
            vm.moveLayerDown(copy)
            let behind = try render(vm).pixel(60, 10)
            try require(behind[0] < 200 && behind[2] > 100, "Layer order did not composite original above linked copy")
            vm.undo()
            try pixel(render(vm).pixel(60, 10), [255, 0, 0, 255])
            try require(vm.placeImage(vm.prepareImagePlacement()!, at: .init(x: 80, y: 80, width: 40, height: 40)), "Separated copy placement failed")
            vm.setLayerOpacity(copy, opacity: 0.5); vm.toggleLayerVisibility(primary)
            let expected = try render(vm)
            try pixel(expected.pixel(10, 10), [255, 255, 255, 255])
            try pixel(expected.pixel(90, 90), [255, 128, 128, 255])
            try require(vm.rasterData(asset) == image.normalizedPNG && vm.managedImageByteCount == sourceBytes
                && vm.originalImageSource(asset)?.originalData == original, "Linked copy duplicated or changed original bytes")
            let isolated = StudioFrameRenderer.thumbnailContent(frame: vm.currentFrame, layers: vm.layers, isolatedLayerID: copy)
            try require(isolated.frame.rasterLayerID == copy && isolated.frame.rasterCrop == vm.currentFrame.rasterInstance(on: copy)?.crop
                && isolated.frame.rasterAliases == nil && isolated.layers.first?.opacity == 1,
                "Isolated layer thumbnail did not project selected copy")
            let output = try await StudioExportService().export(document: vm.document, format: .pngSequence,
                outputParent: root, rasterData: { vm.rasterData($0) })
            try require(try decoded(output.imageURLs[0]).bytes == expected.bytes, "Hidden primary caused visible linked copy to disappear from PNG")
            await vm.flush()
            vm.selectLayer(primary)
            guard let deletion = vm.prepareLayerDeletion(primary) else { throw Failure(message: "Primary deletion capture unavailable") }
            try require(vm.deleteLayer(deletion) && vm.currentFrame.rasterLayerID == copy && vm.currentFrame.rasterAliases == nil,
                "Deleting original did not promote surviving linked image")
            try require(try render(vm).bytes == expected.bytes, "Promotion changed image pixels")
            vm.undo(); try require(vm.currentFrame.rasterLayerInstances.count == 2, "Undo did not restore both instances")
            vm.redo(); try require(try render(vm).bytes == expected.bytes, "Redo changed promoted pixels")
            let saved = await vm.save(); try require(saved, "Promoted image could not save")
            guard let stored = try store.loadAnimation(id: vm.document.id) else { throw Failure(message: "Promoted project missing") }
            let cold = StudioViewModel(storage: store), opened = await cold.openProject(stored.metadata)
            try require(opened && cold.document == vm.document && cold.originalImageSource(asset)?.originalData == original
                && cold.rasterData(asset) == image.normalizedPNG, "Cold reopen lost source or instance metadata")
            try require(try render(cold).bytes == expected.bytes, "Cold promoted image pixels changed")
        }
        try await test("linked image capture rejects layer switches and clipboard retains only selected copy") {
            let (vm, store) = try await project(root), asset = try attach(image, to: vm)
            let primary = vm.currentFrame.rasterLayerID!
            vm.selectLayer(primary); vm.duplicateLayer(primary); let copy = vm.activeLayerID
            vm.selectedTool = .move
            let capture = vm.prepareImagePlacement()!
            vm.selectLayer(primary); let beforeRejected = vm.document
            try require(!vm.placeImage(capture, at: .init(x: 0, y: 0, width: 80, height: 40)) && vm.document == beforeRejected,
                "Old copy capture edited newly selected primary")
            vm.selectLayer(copy)
            try require(vm.cropImage(vm.prepareImagePlacement()!, crop: .init(x: 0.5, y: 0, width: 0.5, height: 1)), "Clipboard copy crop failed")
            try require(vm.reflectImage(vm.prepareImagePlacement()!, axis: .horizontal), "Clipboard copy reflection failed")
            let selected = vm.currentFrame.rasterInstance(on: copy)!, byteCount = vm.managedImageByteCount
            try require(vm.copyImage(), "Selected linked image copy failed")
            vm.addFrame(); try require(vm.pasteImage(), "Linked clipboard paste to blank frame failed")
            let pasted = vm.currentFrame
            try require(pasted.rasterAssetID == asset && pasted.rasterLayerInstances.count == 1 && pasted.rasterAliases == nil
                && pasted.rasterCrop == selected.crop && pasted.rasterReflection == selected.reflection
                && pasted.rasterPlacement == selected.placement && vm.managedImageByteCount == byteCount,
                "Clipboard pasted siblings or lost selected transforms/shared source")
            vm.undo(); try require(vm.currentFrame.rasterAssetID == nil, "Undo did not remove singleton paste")
            vm.redo(); let saved = await vm.save(); try require(saved, "Linked clipboard project save failed")
            let cold = StudioViewModel(storage: store)
            let metadata = try store.loadAnimation(id: vm.document.id)!.metadata
            let opened = await cold.openProject(metadata)
            try require(opened && cold.document == vm.document && cold.frames[0].rasterLayerInstances.count == 2
                && cold.currentFrame.rasterLayerInstances.count == 1 && cold.originalImageSource(asset)?.originalData == original,
                "Cold persistence conflated linked frame and singleton clipboard image")
        }
        try await test("managed missing corrupt and mismatched prepared pixels return actual render/export errors") {
            let (vm, _) = try await project(root); _ = try attach(image, to: vm)
            try rejects { _ = try StudioFrameRenderer.prepareRaster(frame: vm.currentFrame, layers: vm.layers, data: nil) }
            try rejects { _ = try StudioFrameRenderer.prepareRaster(frame: vm.currentFrame, layers: vm.layers, data: Data([1, 2])) }
            let originalFiles = try Set(fm.contentsOfDirectory(atPath: root.path))
            do {
                _ = try await StudioExportService().export(document: vm.document, format: .pngSequence, outputParent: root)
                throw Failure(message: "Missing managed image falsely exported")
            } catch is StudioExportService.ExportError { }
            try require(try Set(fm.contentsOfDirectory(atPath: root.path)) == originalFiles, "Failed PNG export leaked partial files")
            let one = try StudioRasterImage.prepare(assetID: "same-id", data: image.normalizedPNG, managed: true)
            let alternate = try await imported(png(width: 40, height: 20), in: root)
            let two = try StudioRasterImage.prepare(assetID: "same-id", data: alternate.normalizedPNG, managed: true)
            try require(one.image.width == 80 && two.image.width == 40, "Raster cache reused same-ID stale pixels")
            vm.toggleLayerVisibility(vm.currentFrame.rasterLayerID!)
            try require(try StudioFrameRenderer.prepareRaster(frame: vm.currentFrame, layers: vm.layers, data: nil) == nil, "Hidden image incorrectly required visible pixels")
        }
        try await test("legacy flattened images and opaque layer/audio bytes remain unchanged on image-era save") {
            let (_, store) = try await project(root), id = UUID(), now = Date()
            let layer = LayerData(id: UUID(), name: "Opaque", opacity: 0.3, blendMode: "legacy", locked: true, visible: false)
            let audio = AudioTrack(id: UUID(), name: "Original", format: "wav", audioData: Data([7, 8, 9]), startTime: 0, duration: 0, legacySourceFilename: "audio_2.wav")
            let metadata = AnimationMetadata(id: id, title: "Historical", fps: 12, canvasWidth: 160, canvasHeight: 160, frameCount: 2, layerCount: 1, createdAt: now, modifiedAt: now, thumbnailData: nil)
            let records = [StoredAnimationFrame(imageData: image.normalizedPNG, layerData: [layer]), StoredAnimationFrame(imageData: nil, layerData: [layer])]
            try store.saveAnimation(AnimationProject(id: id, metadata: metadata, frames: records, audioTracks: [audio]))
            let vm = StudioViewModel(storage: store), opened = await vm.openProject(metadata); try require(opened, "Legacy records became unopenable")
            try require(vm.currentFrame.rasterPlacement == nil, "Legacy raster was silently refit")
            try pixel(render(vm).pixel(30, 15), [255, 0, 0, 255])
            let before = vm.document; try rejects { _ = try attach(image, to: vm) }; try require(vm.document == before, "Legacy raster was replaced")
            let saved = await vm.save(); try require(saved, "Legacy image-era save failed")
            let after = try store.loadAnimation(id: id)!
            try require(after.frames == records && after.audioTracks[0].audioData == audio.audioData, "Legacy opaque records/audio were discarded")
        }
        try await test("image cache remains bounded during many keys and repeated live preparations") {
            let start = Date()
            for i in 0..<150 { _ = try StudioRasterImage.prepare(assetID: "key-\(i)", data: image.normalizedPNG, managed: true, maximumDimension: 128) }
            let footprint = StudioRasterImage.footprint
            try require(footprint.entries <= StudioRasterImage.maximumCacheEntries && footprint.bytes <= StudioRasterImage.maximumCacheBytes, "Raster cache exceeded its key/pixel/encoded-memory budget")
            let warm = Date()
            for _ in 0..<240 { _ = try StudioRasterImage.prepare(assetID: "key-149", data: image.normalizedPNG, managed: true, maximumDimension: 128) }
            print("RASTER_CACHE_150_KEYS_SECONDS=\(warm.timeIntervalSince(start)) WARM_240_PREPARES_SECONDS=\(Date().timeIntervalSince(warm)) BYTES=\(footprint.bytes)")
        }
        try await test("arbitrary image angle uses real rotated alpha pixels inverse hit testing Undo and cold PNG") {
            let (vm, store) = try await project(root), asset = try attach(image, to: vm)
            vm.selectDrawingTool(.move)
            let placement = StudioRasterPlacement(x: 40, y: 60, width: 80, height: 40)
            let original = vm.document
            guard let capture = vm.prepareImagePlacement() else { throw Failure(message: "Angle capture") }
            try require(vm.placeImage(capture, at: placement, rotationDegrees: 45), "Actual angle command failed")
            try require(vm.document.schemaVersion == 30 && vm.currentFrame.rasterRotationDegrees == 45, "Angle descriptor absent")
            let rotated = try render(vm, transparent: true)
            try pixel(rotated.pixel(66, 66), [255, 0, 0, 255])
            try pixel(rotated.pixel(94, 94), [0, 0, 128, 128])
            try pixel(rotated.pixel(38, 38), [0, 0, 0, 0])
            try require(vm.setImageCanvasMove(true), "Select rotated image")
            try require(vm.beginImageMove(at: CGPoint(x: 38, y: 38)) == nil && vm.beginImageMove(at: CGPoint(x: 66, y: 66)) != nil,
                        "Image hit test used bounding box instead of inverse rotation")
            let moving = vm.currentImageMoveCapture()!
            let unmodified = vm.document
            let movedPreview = try vm.imageMovePreview(moving, delta: CGSize(width: -500, height: -500))
            let previewPlacement = movedPreview.rasterInstance(on: moving.placement.layerID)!.placement!
            try StudioImageRotationGeometry(placement: previewPlacement, degrees: 45).validate(canvasWidth: 160, canvasHeight: 160)
            let resizedPreview = try vm.imageResizePreview(moving, corner: .bottomRight, delta: CGSize(width: 12, height: 12))
            let resizedPlacement = resizedPreview.rasterInstance(on: moving.placement.layerID)!.placement!
            try require(abs(resizedPlacement.width / resizedPlacement.height - 2) < 0.000001 && vm.document == unmodified,
                        "Rotated handle preview distorted source or committed history")
            try require(vm.finishImageResize(moving, corner: .bottomRight, delta: CGSize(width: 12, height: 12)), "Rotated resize commit")
            try require(vm.currentFrame.rasterPlacement == resizedPlacement && vm.currentFrame.rasterRotationDegrees == 45, "Resize preview/commit mismatch")
            vm.undo(); try require(try render(vm, transparent: true).bytes == rotated.bytes, "Resize Undo failed")
            vm.undo(); try require(vm.currentFrame.rasterRotationDegrees == nil && vm.currentFrame.rasterPlacement == original.frames[0].rasterPlacement, "Angle Undo lost original placement")
            vm.redo(); try require(try render(vm, transparent: true).bytes == rotated.bytes, "Angle Redo pixels")
            let saved = await vm.save(); try require(saved, "Save arbitrary image angle")
            let cold = StudioViewModel(storage: store)
            let opened = await cold.openProject(try store.loadAnimation(id: vm.document.id)!.metadata)
            try require(opened && cold.currentFrame.rasterRotationDegrees == 45 && render(cold, transparent: true).bytes == rotated.bytes,
                        "Cold reopen discarded editable angle")
            try require(cold.originalImageSource(asset)?.originalData == image.originalData, "Rotation altered original bytes")
            let output = try await StudioExportService().export(document: cold.document, format: .pngSequence,
                outputParent: root, background: .transparent, rasterData: { cold.rasterData($0) })
            try require(try decoded(output.imageURLs[0]).bytes == rotated.bytes, "Actual angle PNG mismatch")
        }
        try await test("angle composes with flips quarter turns crop linked instances and frame clipboard") {
            let (vm, _) = try await project(root), asset = try attach(image, to: vm)
            vm.selectDrawingTool(.move)
            try require(vm.placeImage(vm.prepareImagePlacement()!, at: .init(x: 40, y: 60, width: 80, height: 40), rotationDegrees: 30), "Set angle")
            let initial = try render(vm, transparent: true)
            try require(vm.reflectImage(vm.prepareImagePlacement()!, axis: .horizontal), "Reflect angled image")
            let mirrored = try render(vm, transparent: true)
            try require(vm.currentFrame.rasterRotationDegrees == -30, "Canvas flip did not reverse residual angle")
            for (x, y) in [(60, 70), (100, 90), (80, 80)] {
                try pixel(mirrored.pixel(159-x, y), initial.pixel(x, y))
            }
            try require(vm.reflectImage(vm.prepareImagePlacement()!, axis: .horizontal), "Restore flip")
            try require(try render(vm, transparent: true).bytes == initial.bytes, "Double flip changed angle pixels")
            for _ in 0..<4 { try require(vm.rotateImage(vm.prepareImagePlacement()!, direction: .clockwise), "Angled quarter turn") }
            try require(try render(vm, transparent: true).bytes == initial.bytes, "Four quarter turns lost angle")
            let primary = vm.prepareImagePlacement()!.layerID
            vm.selectLayer(primary)
            vm.duplicateLayer(primary)
            let alias = vm.activeLayerID
            try require(vm.currentFrame.rasterInstance(on: alias)?.rotationDegrees == 30, "Layer duplicate lost angle")
            try require(vm.cropImage(vm.prepareImagePlacement()!, crop: .init(x: 0, y: 0, width: 0.5, height: 1)), "Rotated crop")
            try require(vm.currentFrame.rasterInstance(on: primary)?.crop == nil && vm.currentFrame.rasterInstance(on: alias)?.rotationDegrees == 30,
                        "Crop changed linked sibling or lost angle")
            let sourceFrame = vm.currentFrame
            vm.copyFrame(); vm.pasteFrame()
            try require(vm.currentFrame.rasterRotationDegrees == sourceFrame.rasterRotationDegrees && vm.currentFrame.rasterAliases == sourceFrame.rasterAliases,
                        "Frame clipboard dropped rotation metadata")
            try require(vm.rasterData(asset) == image.normalizedPNG, "Transform changed immutable normalized bytes")
        }
        try await test("copied image angle survives Undo to older schema and paste into blank frame") {
            let (vm, store) = try await project(root), asset = try attach(image, to: vm)
            vm.selectDrawingTool(.move)
            let beforeAngle = vm.document
            try require(beforeAngle.schemaVersion < 30, "Clipboard fixture must begin before angle schema")
            try require(vm.placeImage(vm.prepareImagePlacement()!, at: .init(x: 40, y: 60, width: 80, height: 40), rotationDegrees: 45), "Clipboard angle fixture")
            let expected = try render(vm, transparent: true)
            try require(vm.copyImage(), "Copy angled image")
            vm.undo()
            try require(vm.document.schemaVersion == beforeAngle.schemaVersion && vm.currentFrame.rasterRotationDegrees == nil && vm.hasCopiedImage,
                        "Undo fixture did not preserve angled clipboard outside old document")
            vm.addFrame()
            try require(vm.currentFrame.rasterAssetID == nil && vm.document.schemaVersion < 30 && vm.canPasteImage,
                        "Blank frame fixture unexpectedly retained angle schema or lost clipboard")
            try require(vm.pasteImage(), "Pasting copied angle into pre-angle schema failed")
            try require(vm.document.schemaVersion == 30 && vm.currentFrame.rasterRotationDegrees == 45 && vm.currentFrame.rasterAssetID == asset,
                        "Image paste omitted angle schema/identity")
            try require(try render(vm, transparent: true).bytes == expected.bytes && vm.originalImageSource(asset)?.originalData == image.originalData,
                        "Pasted angle changed pixels or original bytes")
            let saved = await vm.save(); try require(saved, "Save pasted angle")
            let cold = StudioViewModel(storage: store)
            let opened = await cold.openProject(try store.loadAnimation(id: vm.document.id)!.metadata)
            try require(opened && cold.document.schemaVersion == 30 && render(cold, transparent: true).bytes == expected.bytes,
                        "Cold reopen lost pasted angle schema/pixels")
        }
        try await test("arbitrary image angle bounds stale locks cancellation and schema validation are atomic") {
            let (vm, _) = try await project(root), asset = try attach(image, to: vm)
            vm.selectDrawingTool(.move)
            let capture = vm.prepareImagePlacement()!, before = vm.document
            for angle in [Double.nan, Double.infinity, -181, 181] {
                try require(!vm.placeImage(capture, at: capture.original, rotationDegrees: angle) && vm.document == before, "Invalid angle changed document")
            }
            try require(!vm.placeImage(capture, at: .init(x: 0, y: 0, width: 160, height: 160), rotationDegrees: 45) && vm.document == before,
                        "Out-of-canvas angle changed document")
            var checkpoints = 0
            try require(!vm.placeImage(capture, at: .init(x: 40, y: 60, width: 80, height: 40), rotationDegrees: 45,
                checkCancellation: { checkpoints += 1; if checkpoints == 3 { throw CancellationError() } }) && vm.document == before,
                "Cancellation committed angle")
            try require(vm.placeImage(capture, at: .init(x: 40, y: 60, width: 80, height: 40), rotationDegrees: 45), "Valid angle failed")
            let updated = vm.document
            try require(!vm.placeImage(capture, at: capture.original, rotationDegrees: 0) && vm.document == updated, "Stale angle overwrote later edit")
            var unsupported = updated; unsupported.schemaVersion = 29
            do { try unsupported.validate(); throw Failure(message: "Old schema accepted new angle") } catch is StudioDocumentError { }
            var editor = try StudioDocumentEditor(document: updated)
            try editor.updateLayer(capture.layerID) { $0.lockMode = "position" }
            let locked = editor.document
            do {
                try editor.updateImagePlacement(frameID: locked.activeFrameID, assetID: asset,
                    placement: capture.original, rotationDegrees: 0, layerID: capture.layerID)
                throw Failure(message: "Position lock accepted image angle")
            } catch StudioDocumentError.locked { }
            try require(editor.document == locked, "Rejected locked angle changed document")
            let narrow = StudioRasterPlacement(x: -20, y: 110, width: 200, height: 20)
            try StudioImageRotationGeometry(placement: narrow, degrees: 90).validate(canvasWidth: 160, canvasHeight: 240)
        }
        try await test("image rotation handle preview and release share editable pixels one Undo source bytes and cold PNG") {
            let (vm, store) = try await project(root), asset = try attach(image, to: vm)
            vm.selectDrawingTool(.move)
            try require(vm.placeImage(vm.prepareImagePlacement()!, at: .init(x: 40, y: 60, width: 80, height: 40)), "Handle fixture placement")
            try require(vm.setImageCanvasMove(true), "Handle selection")
            let capture = vm.currentImageMoveCapture()!, before = vm.document
            let start = CGPoint(x: 80, y: 20), current = CGPoint(x: 80 + 30 * sqrt(2.0), y: 80 - 30 * sqrt(2.0))
            let preview = try vm.imageRotationPreview(capture, start: start, current: current)
            try require(vm.document == before && preview.rasterRotationDegrees.map { abs($0 - 45) < 0.000001 } == true,
                        "Rotation preview changed history or calculated wrong angle")
            let previewPixels = try render(vm, transparent: true, frameOverride: preview)
            try pixel(previewPixels.pixel(66, 66), [255, 0, 0, 255])
            try pixel(previewPixels.pixel(94, 94), [0, 0, 128, 128])
            try require(vm.finishImageRotation(capture, start: start, current: current), "Rotation handle release")
            try require(vm.currentFrame == preview && render(vm, transparent: true).bytes == previewPixels.bytes,
                        "Handle release differs from actual preview pixels")
            vm.undo(); try require(vm.currentFrame == before.frames.first(where: { $0.id == before.activeFrameID }), "Handle required more than one Undo")
            vm.redo(); try require(try render(vm, transparent: true).bytes == previewPixels.bytes, "Handle Redo pixels")
            try require(vm.originalImageSource(asset)?.originalData == image.originalData && vm.rasterData(asset) == image.normalizedPNG,
                        "Handle rotation rewrote source bytes")
            let saved = await vm.save(); try require(saved, "Handle save")
            let cold = StudioViewModel(storage: store)
            let opened = await cold.openProject(try store.loadAnimation(id: vm.document.id)!.metadata)
            try require(opened && render(cold, transparent: true).bytes == previewPixels.bytes, "Handle angle cold reopen")
            let output = try await StudioExportService().export(document: cold.document, format: .pngSequence,
                outputParent: root, background: .transparent, rasterData: { cold.rasterData($0) })
            try require(try decoded(output.imageURLs[0]).bytes == previewPixels.bytes, "Handle angle PNG mismatch")
        }
        try await test("image rotation handle rejects every cancellation checkpoint stale selection locks and degenerate input") {
            let (vm, _) = try await project(root); _ = try attach(image, to: vm)
            vm.selectDrawingTool(.move)
            try require(vm.placeImage(vm.prepareImagePlacement()!, at: .init(x: 40, y: 60, width: 80, height: 40)), "Cancellation fixture")
            try require(vm.setImageCanvasMove(true), "Select cancellation fixture")
            let start = CGPoint(x: 80, y: 20), end = CGPoint(x: 140, y: 80)
            var calls = 0
            try require(vm.finishImageRotation(vm.currentImageMoveCapture()!, start: start, current: end,
                checkCancellation: { calls += 1 }), "Count actual handle checkpoints")
            vm.undo()
            try require(vm.setImageCanvasMove(true), "Restore selection after Undo")
            let unchanged = vm.document, capture = vm.currentImageMoveCapture()!, history = vm.canUndo, redo = vm.canRedo
            try require(calls > 1, "No final cancellation checkpoint")
            for stop in 1...calls {
                var count = 0
                try require(!vm.finishImageRotation(capture, start: start, current: end, checkCancellation: {
                    count += 1; if count == stop { throw CancellationError() }
                }) && vm.document == unchanged && vm.canUndo == history && vm.canRedo == redo,
                    "A cancellation checkpoint committed image rotation")
            }
            for invalid in [CGPoint(x: 80, y: 80), CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: 200_000, y: 0)] {
                try require(!vm.finishImageRotation(capture, start: start, current: invalid) && vm.document == unchanged,
                            "Degenerate or nonfinite handle changed artwork")
            }
            try require(vm.setImageCanvasMove(false) && vm.setImageCanvasMove(true), "Reselect same image")
            try require(!vm.finishImageRotation(capture, start: start, current: end) && vm.document == unchanged,
                        "Old selection identity revived after deselect/reselect")
            let fresh = vm.currentImageMoveCapture()!
            vm.setLayerLockMode(fresh.placement.layerID, mode: .position)
            let locked = vm.document
            try require(!vm.finishImageRotation(fresh, start: start, current: end) && vm.document == locked,
                        "Position lock allowed old handle rotation")
        }
        try await test("active-layer image lasso uses rotated polygon enclosure and New Add Subtract without document edits") {
            let (vm, _) = try await project(root); _ = try attach(image, to: vm)
            vm.selectDrawingTool(.move)
            try require(vm.placeImage(vm.prepareImagePlacement()!, at: .init(x: 40, y: 60, width: 80, height: 40), rotationDegrees: 45), "Area fixture angle")
            vm.selectLayer(vm.currentFrame.rasterLayerID!)
            vm.selectDrawingTool(.lasso)
            try require(vm.areaSelectionTarget == .drawings, "Default selection target changed")
            vm.areaSelectionTarget = .image; vm.areaSelectionKind = .polygon; vm.areaSelectionSmoothing = 0; vm.selectionMode = .new
            let before = vm.document, undo = vm.canUndo, redo = vm.canRedo
            for degrees in [-135.0, -45.0, 0.0, 45.0, 135.0, 179.0] {
                let outline = StudioImageRotationGeometry(placement: .init(x: 39, y: 59, width: 82, height: 42), degrees: degrees).corners
                let exactRegion = try StudioSelectionRegion(points: outline, kind: .polygon, smoothing: 0)
                try require(exactRegion.containsImage(placement: .init(x: 40, y: 60, width: 80, height: 40), angle: degrees),
                            "Enclosed rotated image corner misclassified at \(degrees) degrees")
                let tooSmall = StudioImageRotationGeometry(placement: .init(x: 41, y: 61, width: 78, height: 38), degrees: degrees).corners
                let excludingRegion = try StudioSelectionRegion(points: tooSmall, kind: .polygon, smoothing: 0)
                try require(!excludingRegion.containsImage(placement: .init(x: 40, y: 60, width: 80, height: 40), angle: degrees),
                            "Non-enclosing rotated outline accepted at \(degrees) degrees")
            }
            let polygon = StudioImageRotationGeometry(placement: .init(x: 39, y: 59, width: 82, height: 42), degrees: 45).corners
            let areaCapture = vm.beginAreaSelection()!
            try require(areaCapture.image?.placement == .init(x: 40, y: 60, width: 80, height: 40) && areaCapture.image?.angle == 45,
                        "Area selection fixture captured unexpected placement or angle: \(String(describing: areaCapture.image))")
            let region = try StudioSelectionRegion(points: polygon, kind: areaCapture.kind, smoothing: areaCapture.smoothing)
            try require(region.containsImage(placement: areaCapture.image!.placement, angle: areaCapture.image!.angle),
                        "Real region failed to enclose the rotated image polygon")
            try require(vm.finishAreaSelection(areaCapture, points: polygon), "Rotated polygon selection failed")
            try require(vm.selectedAreaImageCorners != nil,
                        "Successful image enclosure did not retain selected image; capture=\(String(describing: vm.beginAreaSelection()))")
            try require(vm.selectedElementIDs.isEmpty, "Image selection also selected drawings")
            try require(vm.document == before, "Image selection changed canonical document")
            try require(vm.canUndo == undo && vm.canRedo == redo, "Image selection changed Undo/Redo availability")
            // The narrow oriented outline excludes the image's AABB corners, yet encloses its real polygon.
            let empty = [CGPoint(x: 0, y: 0), CGPoint(x: 8, y: 0), CGPoint(x: 8, y: 8), CGPoint(x: 0, y: 8)]
            vm.selectionMode = .add
            try require(vm.finishAreaSelection(vm.beginAreaSelection()!, points: empty) && vm.selectedAreaImageCorners != nil, "Add empty lost selection")
            vm.selectionMode = .subtract
            try require(vm.finishAreaSelection(vm.beginAreaSelection()!, points: empty) && vm.selectedAreaImageCorners != nil, "Subtract empty lost selection")
            try require(vm.finishAreaSelection(vm.beginAreaSelection()!, points: polygon) && vm.selectedAreaImageCorners == nil, "Subtract enclosed image failed")
            vm.selectionMode = .new
            try require(vm.finishAreaSelection(vm.beginAreaSelection()!, points: polygon), "Reselect image")
            // All four corners remain enclosed, but this notch enters the polygon interior.
            let notched = [CGPoint(x: 20, y: 20), CGPoint(x: 76, y: 20), CGPoint(x: 76, y: 85), CGPoint(x: 84, y: 85),
                CGPoint(x: 84, y: 20), CGPoint(x: 140, y: 20), CGPoint(x: 140, y: 140), CGPoint(x: 20, y: 140)]
            try require(vm.finishAreaSelection(vm.beginAreaSelection()!, points: notched) && vm.selectedAreaImageCorners == nil,
                        "Concave lasso selected image through an interior notch")
            vm.areaSelectionKind = .rectangle
            try require(vm.finishAreaSelection(vm.beginAreaSelection()!, points: [.init(x: 40, y: 60), .init(x: 120, y: 100)]) && vm.selectedAreaImageCorners == nil,
                        "Unrotated rectangle falsely enclosed rotated image")
        }
        try await test("image area selection continues into real Move delete Undo and cold persistence with original bytes") {
            let (vm, store) = try await project(root), asset = try attach(image, to: vm)
            vm.selectDrawingTool(.move)
            try require(vm.placeImage(vm.prepareImagePlacement()!, at: .init(x: 40, y: 60, width: 80, height: 40), rotationDegrees: 45), "Area move fixture")
            vm.selectLayer(vm.currentFrame.rasterLayerID!); vm.selectDrawingTool(.lasso)
            vm.areaSelectionTarget = .image; vm.areaSelectionKind = .rectangle; vm.selectionMode = .new
            let outline = [CGPoint.zero, CGPoint(x: 160, y: 160)]
            try require(vm.finishAreaSelection(vm.beginAreaSelection()!, points: outline), "Select area before Move")
            let before = vm.currentFrame
            vm.selectDrawingTool(.move)
            guard let capture = vm.currentImageMoveCapture() else { throw Failure(message: "Lasso image did not continue to Move") }
            try require(vm.finishImageMove(capture, delta: .init(width: 5, height: 5)), "Selected image move")
            let moved = vm.currentFrame, pixels = try render(vm, transparent: true).bytes
            vm.undo(); try require(vm.currentFrame == before, "Image area Move was not one Undo")
            vm.redo(); try require(vm.currentFrame == moved, "Image area Move Redo")
            try require(vm.setImageCanvasMove(true), "Restore exact image selection")
            try require(vm.deleteBottomImage(vm.bottomImageSelection!) && vm.currentFrame.rasterAssetID == nil, "Selected image delete")
            vm.undo(); try require(vm.currentFrame == moved, "Selected image delete Undo")
            let saved = await vm.save(); try require(saved, "Area image save")
            let cold = StudioViewModel(storage: store)
            let opened = await cold.openProject(try store.loadAnimation(id: vm.document.id)!.metadata)
            try require(opened && render(cold, transparent: true).bytes == pixels && cold.originalImageSource(asset)?.originalData == original && cold.rasterData(asset) == image.normalizedPNG,
                        "Area selection/move/delete lost saved image or original source")
        }
        try await test("image area selection rejects cancellation stale context hidden and locked active layers") {
            let (vm, _) = try await project(root); _ = try attach(image, to: vm)
            let imageLayer = vm.currentFrame.rasterLayerID!
            vm.selectLayer(imageLayer); vm.selectDrawingTool(.lasso); vm.areaSelectionTarget = .image
            vm.areaSelectionKind = .rectangle; vm.selectionMode = .new
            let points = [CGPoint.zero, CGPoint(x: 160, y: 160)], before = vm.document
            let capture = vm.beginAreaSelection()!
            for stop in 1...2 {
                var calls = 0
                try require(!vm.finishAreaSelection(capture, points: points, checkCancellation: {
                    calls += 1; if calls == stop { throw CancellationError() }
                }) && vm.selectedAreaImageCorners == nil && vm.document == before, "Cancelled area selection escaped")
            }
            vm.areaSelectionTarget = .drawings; vm.areaSelectionTarget = .image
            try require(!vm.finishAreaSelection(capture, points: points), "Old area gesture revived after target switch")
            let current = vm.beginAreaSelection()!
            try require(!vm.finishAreaSelection(current, points: points, checkCancellation: { vm.deselectAreaImage() }) && vm.selectedAreaImageCorners == nil,
                        "Final selection cancellation was ignored")
            try require(vm.finishAreaSelection(vm.beginAreaSelection()!, points: points), "Select before revision change")
            vm.setLayerOpacity(imageLayer, opacity: 0.75)
            vm.selectDrawingTool(.move)
            try require(vm.currentImageMoveCapture() == nil, "Stale Lasso revision continued into Move")
            vm.selectDrawingTool(.lasso)
            for lock in [LayerLockMode.full, .position, .alpha] {
                vm.setLayerLockMode(imageLayer, mode: lock)
                try require(vm.beginAreaSelection() == nil, "Locked image admitted area selection")
                vm.setLayerLockMode(imageLayer, mode: .free)
            }
            vm.toggleLayerVisibility(imageLayer)
            try require(vm.beginAreaSelection() == nil, "Hidden image admitted area selection")
            vm.toggleLayerVisibility(imageLayer); vm.setLayerOpacity(imageLayer, opacity: 0)
            try require(vm.beginAreaSelection() == nil, "Transparent image admitted area selection")
        }
        try await test("image-target Lasso reentry clears actionable drawing selection without changing artwork") {
            let (vm, _) = try await project(root), asset = try attach(image, to: vm)
            let imageLayer = vm.currentFrame.rasterLayerID!
            vm.selectLayer(imageLayer)
            let line = DrawnElement(id: UUID().uuidString, tool: .line,
                points: [.init(x: 10, y: 10), .init(x: 60, y: 10)], color: "#00FF00", width: 4, opacity: 1, layerID: imageLayer)
            try require(vm.commitElement(line), "Roundtrip real drawing fixture")
            vm.selectDrawingTool(.lasso); vm.areaSelectionTarget = .image
            vm.selectDrawingTool(.move); vm.selectionMode = .new
            try require(vm.selectElement(at: .init(x: 30, y: 10)) == line.id && vm.canDeleteSelected,
                        "Move did not explicitly select the real drawing")
            let before = vm.document, undo = vm.canUndo, redo = vm.canRedo
            vm.selectDrawingTool(.lasso)
            try require(vm.areaSelectionTarget == .image && vm.selectedElementIDs.isEmpty && !vm.canDeleteSelected && vm.bottomImageSelection == nil,
                        "Image-target Lasso reentry retained drawing Delete authority")
            vm.deleteSelected()
            try require(vm.document == before && vm.canUndo == undo && vm.canRedo == redo && vm.currentFrame.elements.contains(where: { $0.id == line.id }) && vm.originalImageSource(asset)?.originalData == original,
                        "Clearing transient selection changed artwork/history/source or allowed stale deletion")
        }
        try await test("selected image Cut atomically retains linked source transforms drawings Undo and cold pasted pixels") {
            let (vm, store) = try await project(root), asset = try attach(image, to: vm)
            let primary = vm.currentFrame.rasterLayerID!
            vm.selectLayer(primary); vm.duplicateLayer(primary); let alias = vm.activeLayerID
            vm.selectDrawingTool(.move)
            try require(vm.cropImage(vm.prepareImagePlacement()!, crop: .init(x: 0.1, y: 0.1, width: 0.7, height: 0.8)), "Cut crop fixture")
            try require(vm.reflectImage(vm.prepareImagePlacement()!, axis: .horizontal), "Cut flip fixture")
            try require(vm.placeImage(vm.prepareImagePlacement()!, at: .init(x: 40, y: 60, width: 80, height: 40), rotationDegrees: 30), "Cut angle fixture")
            let line = DrawnElement(id: UUID().uuidString, tool: .line, points: [.init(x: 10, y: 10), .init(x: 60, y: 10)],
                color: "#00FF00", width: 4, opacity: 1, layerID: alias)
            try require(vm.commitElement(line), "Cut unrelated drawing fixture")
            vm.toggleLayerVisibility(primary)
            try require(vm.setImageCanvasMove(true), "Explicit Cut image selection")
            guard let capture = vm.selectedImageCutCapture else { throw Failure(message: "Selected image Cut capture") }
            let before = vm.document, sourceBytes = vm.managedImageByteCount
            var isolated = vm.currentFrame.projectedRasterFrame(on: alias)!
            isolated.elements = []; isolated.holdTicks = nil
            let expected = try render(vm, frameOverride: isolated).bytes
            try require(vm.cutSelectedImage(capture), "Actual image Cut rejected")
            try require(vm.currentFrame.rasterInstance(on: alias) == nil && vm.currentFrame.rasterInstance(on: primary) == before.frames[0].rasterInstance(on: primary) &&
                        vm.currentFrame.elements == before.frames[0].elements && vm.layers == before.layers && vm.usesImageClipboard,
                        "Cut removed sibling/drawings/layer or failed to replace clipboard scope")
            try require(vm.managedImageByteCount == sourceBytes && vm.originalImageSource(asset)?.originalData == original,
                        "Cut discarded or duplicated immutable image source")
            vm.undo(); try require(vm.frames == before.frames, "Cut was not one Undo")
            vm.redo(); try require(vm.currentFrame.rasterInstance(on: alias) == nil, "Cut Redo failed")
            vm.addFrame(); try require(vm.pasteImage(), "Cut image could not paste into blank frame")
            try require(vm.currentFrame.elements.isEmpty && vm.currentFrame.rasterAssetID == asset &&
                        vm.currentFrame.rasterCrop == isolated.rasterCrop && vm.currentFrame.rasterReflection == isolated.rasterReflection &&
                        vm.currentFrame.rasterRotationDegrees == isolated.rasterRotationDegrees && vm.currentFrame.rasterPlacement == isolated.rasterPlacement &&
                        render(vm).bytes == expected && vm.managedImageByteCount == sourceBytes,
                        "Cut/Paste changed selected appearance, included drawings or copied source bytes")
            let saved = await vm.save(); try require(saved, "Cut/Paste save")
            let cold = StudioViewModel(storage: store)
            let opened = await cold.openProject(try store.loadAnimation(id: vm.document.id)!.metadata)
            try require(opened && render(cold).bytes == expected && cold.originalImageSource(asset)?.originalData == original && cold.rasterData(asset) == image.normalizedPNG,
                        "Cut/Paste cold reopen lost pixels or originals")
        }
        try await test("image Cut cancels at every checkpoint and rejects stale selection locks without replacing prior clipboard") {
            let (probe, _) = try await project(root); _ = try attach(image, to: probe)
            probe.selectLayer(probe.currentFrame.rasterLayerID!); probe.selectDrawingTool(.move)
            try require(probe.setImageCanvasMove(true), "Cut checkpoint probe selection")
            var checkpoints = 0
            try require(probe.cutSelectedImage(probe.selectedImageCutCapture!, checkCancellation: { checkpoints += 1 }) && checkpoints > 2,
                        "Real Cut did not expose final transaction checkpoint")
            let (vm, _) = try await project(root), asset = try attach(image, to: vm)
            vm.selectDrawingTool(.move)
            try require(vm.copyImage(), "Prior full-image clipboard")
            try require(vm.setImageCanvasMove(true) && vm.selectedImageCutCapture == nil,
                        "Singleton image fallback authorized Cut on a different active drawing layer")
            _ = vm.setImageCanvasMove(false)
            let priorPixels = try render(vm).bytes
            vm.selectLayer(vm.currentFrame.rasterLayerID!)
            try require(vm.placeImage(vm.prepareImagePlacement()!, at: .init(x: 40, y: 60, width: 80, height: 40), rotationDegrees: 45), "Different Cut source appearance")
            try require(vm.setImageCanvasMove(true), "Select Cut source")
            let capture = vm.selectedImageCutCapture!, before = vm.document, undo = vm.canUndo, redo = vm.canRedo
            for stop in 1...checkpoints {
                var count = 0
                try require(!vm.cutSelectedImage(capture, checkCancellation: {
                    count += 1; if count == stop { throw CancellationError() }
                }) && vm.document == before && vm.canUndo == undo && vm.canRedo == redo && vm.selectedImageCutCapture == capture && vm.usesImageClipboard,
                            "Cancelled Cut published document/history/selection or lost clipboard")
            }
            try require(vm.setImageCanvasMove(false) && vm.setImageCanvasMove(true), "Deselect/reselect Cut source")
            try require(!vm.cutSelectedImage(capture) && vm.document == before, "Old selection Cut revived")
            let current = vm.selectedImageCutCapture!
            for lock in [LayerLockMode.full, .position, .alpha] {
                vm.setLayerLockMode(vm.activeLayerID, mode: lock)
                let locked = vm.document
                try require(vm.selectedImageCutCapture == nil && !vm.cutSelectedImage(current) && vm.document == locked,
                            "Locked image Cut escaped")
                vm.setLayerLockMode(vm.activeLayerID, mode: .free)
            }
            vm.toggleLayerVisibility(vm.activeLayerID)
            let hidden = vm.document
            try require(vm.selectedImageCutCapture == nil && !vm.cutSelectedImage(current) && vm.document == hidden,
                        "Hidden image Cut escaped")
            vm.toggleLayerVisibility(vm.activeLayerID)
            try require(vm.setImageCanvasMove(true), "Restore Cut selection")
            let final = vm.selectedImageCutCapture!
            var calls = 0, newer: StudioDocument?
            try require(!vm.cutSelectedImage(final, checkCancellation: {
                calls += 1; if calls == checkpoints { vm.addFrame(); newer = vm.document }
            }) && newer != nil && vm.document == newer, "Late Cut overwrote newer edit")
            try require(vm.pasteImage() && vm.currentFrame.rasterRotationDegrees == nil && render(vm).bytes == priorPixels &&
                        vm.originalImageSource(asset)?.originalData == original,
                        "Failed or cancelled Cut replaced the prior full-image clipboard")
        }
        @MainActor func mixedFixture() async throws -> (StudioViewModel, DeviceStorageManager, String, DrawnElement, DrawnElement) {
            let (vm, store) = try await project(root), asset = try attach(image, to: vm)
            vm.selectDrawingTool(.move)
            try require(vm.placeImage(vm.prepareImagePlacement()!, at: .init(x: 70, y: 70, width: 40, height: 20)), "Mixed image fixture")
            let layer = vm.currentFrame.rasterLayerID!
            vm.selectLayer(layer)
            let line = DrawnElement(id: UUID().uuidString, tool: .line,
                points: [.init(x: 20, y: 30), .init(x: 40, y: 30)], color: "#00FF00", width: 4, opacity: 1, layerID: layer)
            let other = DrawnElement(id: UUID().uuidString, tool: .line,
                points: [.init(x: 130, y: 140), .init(x: 145, y: 140)], color: "#000000", width: 4, opacity: 1, layerID: layer)
            try require(vm.commitElement(line) && vm.commitElement(other), "Mixed actual drawing fixtures")
            vm.selectDrawingTool(.lasso); vm.areaSelectionTarget = .artwork
            vm.areaSelectionKind = .rectangle; vm.areaSelectionSmoothing = 0; vm.selectionMode = .new
            return (vm, store, asset, line, other)
        }
        @MainActor func selectMixed(_ vm: StudioViewModel) throws {
            vm.selectDrawingTool(.lasso); vm.areaSelectionTarget = .artwork
            vm.areaSelectionKind = .rectangle; vm.selectionMode = .new
            guard let capture = vm.beginAreaSelection() else { throw Failure(message: "Mixed area capture missing") }
            try require(vm.finishAreaSelection(capture, points: [.init(x: 10, y: 20), .init(x: 120, y: 100)]), "Mixed enclosure failed")
            try require(vm.hasMixedArtworkSelection, "Drawing and image were not both selected")
            vm.selectDrawingTool(.move)
            try require(vm.hasMixedArtworkSelection, "Lasso to Move dropped mixed selection")
        }
        try await test("mixed rectangle New Add Subtract selects real drawing and image without changing document or clipboard") {
            let (vm, _, _, line, other) = try await mixedFixture()
            let before = vm.document, undo = vm.canUndo, redo = vm.canRedo
            let drawing = [CGPoint(x: 10, y: 20), CGPoint(x: 50, y: 40)]
            let picture = [CGPoint(x: 60, y: 60), CGPoint(x: 120, y: 100)]
            try require(vm.finishAreaSelection(vm.beginAreaSelection()!, points: drawing), "Mixed New drawing")
            try require(vm.selectedElementIDs == [line.id] && vm.selectedAreaImageCorners == nil, "Mixed New broadened selection")
            vm.selectionMode = .add
            try require(vm.finishAreaSelection(vm.beginAreaSelection()!, points: picture) && vm.hasMixedArtworkSelection,
                        "Mixed Add failed to retain drawing while adding image")
            vm.selectionMode = .subtract
            try require(vm.finishAreaSelection(vm.beginAreaSelection()!, points: picture), "Mixed Subtract image")
            try require(vm.selectedElementIDs == [line.id] && vm.selectedAreaImageCorners == nil, "Subtract image removed drawing")
            vm.selectionMode = .add
            try require(vm.finishAreaSelection(vm.beginAreaSelection()!, points: picture), "Mixed image re-add")
            vm.selectionMode = .subtract
            try require(vm.finishAreaSelection(vm.beginAreaSelection()!, points: drawing), "Mixed Subtract drawing")
            try require(vm.selectedElementIDs.isEmpty && vm.selectedAreaImageCorners != nil, "Subtract drawing removed image")
            try require(!vm.canCopyBottomSelection && vm.bottomCopyLabel != "Copy frame",
                        "Image-only Artwork Lasso silently offered whole-frame Copy")
            try selectMixed(vm)
            try require(vm.selectedElementIDs == [line.id] && !vm.selectedElementIDs.contains(other.id), "Mixed selection captured unrelated drawing")
            try require(vm.copySelected() && vm.canCutSelected && vm.usesArtworkClipboard, "Mixed clipboard did not capture both selected kinds")
            vm.selectionMode = .add
            let addedMove = vm.beginMove(at: .init(x: 137, y: 140))
            try require(addedMove != nil && vm.selectedElementIDs == [line.id, other.id], "Move Add did not recapture enlarged group")
            vm.selectionMode = .subtract
            try require(vm.beginMove(at: .init(x: 137, y: 140)) == nil && vm.selectedElementIDs == [line.id], "Move Subtract did not remove drawing")
            try require(vm.beginMove(at: .init(x: 30, y: 30)) == nil && vm.selectedElementIDs.isEmpty, "Move Subtract did not leave explicit image")
            vm.selectionMode = .new
            try require(vm.beginSelectionHandle() != nil && vm.beginMove(at: .init(x: 90, y: 80)) != nil &&
                        vm.canCopyBottomSelection && vm.bottomCopyLabel == "Copy selected image", "Image-only artwork selection lost handles or exact copy scope")
            vm.selectionMode = .add
            try require(vm.beginMove(at: .init(x: 30, y: 30)) != nil && vm.hasMixedArtworkSelection, "Move Add could not restore drawing to image-only group")
            vm.selectionMode = .subtract
            try require(vm.beginMove(at: .init(x: 90, y: 80)) == nil && !vm.hasMixedArtworkSelection && vm.selectedElementIDs == [line.id], "Move Subtract did not remove only image")
            vm.selectionMode = .add
            try require(vm.beginMove(at: .init(x: 90, y: 80)) != nil && vm.hasMixedArtworkSelection, "Move Add could not restore image to drawing-only group")
            try require(vm.document == before && vm.canUndo == undo && vm.canRedo == redo, "Selection or rejected clipboard changed document/history")
        }
        try await test("mixed selected layer locking deduplicates targets and preserves pixels sources Undo and cold state") {
            let (vm, store, asset, _, _) = try await mixedFixture()
            let imageLayer = vm.currentFrame.rasterLayerID!
            try selectMixed(vm)
            guard let sameLayer = vm.prepareSelectionLayerLock() else { throw Failure(message: "Same-layer mixed lock unavailable") }
            try require(sameLayer.layerIDs == [imageLayer] && sameLayer.image?.assetID == asset,
                        "Drawing and image on one layer were not deduplicated")
            vm.clearElementSelection(); vm.addLayer()
            let drawingLayer = vm.activeLayerID
            let drawing = DrawnElement(id: UUID().uuidString, tool: .line,
                points: [.init(x: 25, y: 45), .init(x: 45, y: 45)], color: "#0000FF", width: 4, opacity: 1, layerID: drawingLayer)
            try require(vm.commitElement(drawing), "Second layer drawing fixture")
            vm.duplicateFrame(); vm.selectLayer(imageLayer)
            try selectMixed(vm)
            guard let capture = vm.prepareSelectionLayerLock() else { throw Failure(message: "Mixed lock capture unavailable") }
            try require(Set(capture.layerIDs) == [imageLayer, drawingLayer] && capture.imageSelectionID != nil,
                        "Mixed lock omitted image/drawing layer or image selection identity")
            let before = vm.document, beforePixels = try render(vm, transparent: true).bytes
            let source = vm.originalImageSource(asset)
            var checkpoints = 0
            try require(vm.lockSelectedLayers(capture, checkCancellation: { checkpoints += 1 }), "Mixed layer lock failed")
            let locked = vm.document
            try require(vm.layers.filter(\.isFullyLocked).map(\.id).sorted() == capture.layerIDs &&
                vm.currentFrame.elements.count == before.frames.first(where: { $0.id == before.activeFrameID })!.elements.count &&
                vm.document.frames == before.frames && vm.selectedElementIDs.isEmpty && !vm.isSelectingMixedArtwork &&
                render(vm, transparent: true).bytes == beforePixels && vm.originalImageSource(asset) == source,
                "Lock changed content/source/pixels, missed a target or retained image selection")
            vm.undo()
            try require(vm.document.layers == before.layers && vm.document.frames == before.frames,
                        "One Undo failed to restore all mixed target layers")
            vm.redo()
            try require(vm.document.layers == locked.layers && vm.document.frames == locked.frames,
                        "Mixed lock Redo changed the saved targets")
            let saved = await vm.save(); try require(saved, "Mixed lock save failed")
            let reopened = StudioViewModel(storage: store); await reopened.loadProjects()
            guard let metadata = reopened.savedProjects.first(where: { $0.id == locked.id }) else { throw Failure(message: "Missing mixed lock project") }
            let opened = await reopened.openProject(metadata)
            try require(opened && reopened.document.layers == locked.layers && reopened.document.frames == locked.frames &&
                reopened.originalImageSource(asset) == source && render(reopened, transparent: true).bytes == beforePixels,
                "Cold mixed lock lost locks, image originals or rendered content")
            vm.undo(); try selectMixed(vm)
            guard let cancelled = vm.prepareSelectionLayerLock() else { throw Failure(message: "No cancellation target") }
            let unchanged = vm.document, selection = vm.selectedElementIDs, undo = vm.canUndo, redo = vm.canRedo
            for stop in 1...checkpoints {
                var calls = 0
                try require(!vm.lockSelectedLayers(cancelled, checkCancellation: {
                    calls += 1; if calls == stop { throw CancellationError() }
                }) && vm.document == unchanged && vm.selectedElementIDs == selection &&
                    vm.prepareSelectionLayerLock() == cancelled && vm.canUndo == undo && vm.canRedo == redo,
                    "Cancelled mixed lock partially mutated document/history/selection")
            }
            // Recreate the same explicit selection without changing revision;
            // the former confirmation must not regain authority over its image.
            vm.clearElementSelection(); try selectMixed(vm)
            try require(vm.document == unchanged && vm.prepareSelectionLayerLock() != cancelled &&
                !vm.lockSelectedLayers(cancelled) && vm.document == unchanged,
                "Same-revision image deselect/reselect revived a stale lock confirmation")
            guard let latest = vm.prepareSelectionLayerLock() else { throw Failure(message: "No late-cancel lock capture") }
            var lateCalls = 0
            try require(!vm.lockSelectedLayers(latest, checkCancellation: {
                lateCalls += 1
                if lateCalls == checkpoints { vm.deselectAreaImage() }
            }) && vm.document == unchanged, "Late image deselection allowed partial mixed layer locking")
            try selectMixed(vm)
            vm.toggleLayerVisibility(drawingLayer)
            let hidden = vm.document
            try require(vm.prepareSelectionLayerLock() == nil && !vm.lockSelectedLayers(latest) && vm.document == hidden,
                        "Hidden or stale mixed target was silently omitted")
        }
        try await test("mixed clipboard Cut Undo Redo Paste retains editable identities source geometry and cold pixels") {
            let (vm, store, asset, line, other) = try await mixedFixture()
            try selectMixed(vm)
            let before = vm.currentFrame, pixels = try render(vm, transparent: true).bytes
            let source = vm.originalImageSource(asset), undo = vm.canUndo, redo = vm.canRedo, revision = vm.document.revision
            try require(vm.copySelectedArtwork() && vm.usesArtworkClipboard && vm.bottomPasteLabel == "Paste artwork",
                        "Mixed Copy lost scope")
            try require(vm.document.revision == revision && vm.canUndo == undo && vm.canRedo == redo,
                        "Mixed Copy changed history")
            try require(vm.cutSelected() && vm.currentFrame.rasterAssetID == nil &&
                        vm.currentFrame.elements == [other] && vm.originalImageSource(asset) == source,
                        "Mixed Cut broadened selection or discarded source")
            vm.undo(); try require(vm.currentFrame == before && render(vm, transparent: true).bytes == pixels,
                                   "Mixed Cut was not one reversible edit")
            vm.redo(); let cutFrame = vm.currentFrame
            try require(vm.pasteImage(), "Image paste entry point dropped mixed payload")
            let pasted = vm.currentFrame, result = try render(vm, transparent: true).bytes
            try require(pasted.elements.count == 2 && pasted.elements.contains(other) &&
                        !pasted.elements.contains(where: { $0.id == line.id }) &&
                        pasted.elements.first(where: { $0.id != other.id })?.points == line.points &&
                        pasted.rasterPlacement == before.rasterPlacement && result == pixels &&
                        vm.originalImageSource(asset) == source && vm.rasterData(asset) == image.normalizedPNG,
                        "Mixed Paste lost editable identity, relative geometry, source or pixels")
            vm.undo(); try require(vm.currentFrame == cutFrame, "Mixed Paste left partial Undo")
            vm.redo(); try require(vm.currentFrame == pasted && render(vm, transparent: true).bytes == result, "Mixed Paste Redo")
            let saved = await vm.save(); try require(saved, "Mixed Paste save")
            let cold = StudioViewModel(storage: store)
            let opened = await cold.openProject(try store.loadAnimation(id: vm.document.id)!.metadata)
            try require(opened && cold.currentFrame == pasted && render(cold, transparent: true).bytes == result &&
                        cold.originalImageSource(asset) == source, "Mixed Paste cold source/geometry lost")
        }
        try await test("mixed clipboard cancellation stale selection locks and newer frame copy never publish partial payload") {
            let (vm, _, asset, _, _) = try await mixedFixture()
            try selectMixed(vm)
            try require(vm.copySelectedArtwork(), "Mixed initial copy")
            var checkpoints = 0
            try require(vm.copySelectedArtwork(cut: true, checkCancellation: { checkpoints += 1 }), "Mixed Cut checkpoint capture")
            vm.undo(); try selectMixed(vm)
            let restored = vm.document
            for stop in 1...checkpoints {
                var calls = 0
                try require(!vm.copySelectedArtwork(cut: true, checkCancellation: {
                    calls += 1; if calls == stop { throw CancellationError() }
                }) && vm.document == restored && vm.usesArtworkClipboard && vm.rasterData(asset) == image.normalizedPNG,
                            "Cancelled mixed Cut changed document or clipboard")
            }
            var calls = 0
            try require(!vm.copySelectedArtwork(cut: true, checkCancellation: {
                calls += 1; if calls == checkpoints { vm.deselectAreaImage() }
            }) && vm.document == restored, "Late image deselection allowed mixed Cut")
            try selectMixed(vm)
            vm.setLayerLockMode(vm.activeLayerID, mode: .position)
            let locked = vm.document
            try require(!vm.copySelectedArtwork(cut: true) && vm.document == locked && vm.usesArtworkClipboard,
                        "Locked mixed Cut destroyed prior clipboard")
            vm.setLayerLockMode(vm.activeLayerID, mode: .free)
            var pasteChecks = 0
            try require(vm.pasteSelectedArtwork(checkCancellation: { pasteChecks += 1 }), "Mixed Paste checkpoint capture")
            vm.undo()
            let pasteBefore = vm.document, pasteUndo = vm.canUndo, pasteRedo = vm.canRedo
            for stop in 1...pasteChecks {
                var probes = 0
                try require(!vm.pasteSelectedArtwork(checkCancellation: {
                    probes += 1; if probes == stop { throw CancellationError() }
                }) && vm.document == pasteBefore && vm.canUndo == pasteUndo && vm.canRedo == pasteRedo && vm.usesArtworkClipboard,
                            "Cancelled mixed Paste left partial elements/layers/history")
            }
            var probes = 0
            try require(!vm.pasteSelectedArtwork(checkCancellation: {
                probes += 1; if probes == pasteChecks { vm.copyFrame() }
            }) && vm.document == pasteBefore, "Mixed Paste overrode newer successful copy")
            try require(!vm.usesArtworkClipboard && !vm.usesImageClipboard, "Newer frame copy shadowed by old mixed payload")
        }
        try await test("mixed group drag scale rotation flip preview equals actual commit one Undo and cold pixels") {
            let (vm, store, asset, line, other) = try await mixedFixture()
            try selectMixed(vm)
            let originalFrame = vm.currentFrame, originalPixels = try render(vm, transparent: true).bytes
            guard let move = vm.beginMove(at: .init(x: 30, y: 30)) else { throw Failure(message: "Mixed move capture missing") }
            let beforePreview = vm.document, undo = vm.canUndo, redo = vm.canRedo
            let delta = CGSize(width: 4, height: 5)
            let preview = try vm.movePreview(move, delta: delta)
            try require(vm.document == beforePreview && vm.canUndo == undo && vm.canRedo == redo, "Mixed preview mutated document/history")
            try require(preview.rasterPlacement != originalFrame.rasterPlacement && preview.elements.first(where: { $0.id == line.id }) != line,
                        "Mixed drag preview failed to move both sources")
            let previewPixels = try render(vm, transparent: true, frameOverride: preview).bytes
            try require(vm.finishMove(move, delta: delta) && vm.currentFrame == preview && render(vm, transparent: true).bytes == previewPixels,
                        "Mixed drag preview and commit diverged")
            try require(vm.currentFrame.elements.first(where: { $0.id == other.id }) == other, "Mixed drag changed unselected drawing")
            vm.undo(); try require(vm.currentFrame == originalFrame && render(vm, transparent: true).bytes == originalPixels, "Mixed drag was not one Undo")
            vm.redo(); try require(vm.currentFrame == preview, "Mixed drag Redo lost one source")
            vm.undo(); try selectMixed(vm)
            guard let handle = vm.beginSelectionHandle() else { throw Failure(message: "Mixed transform handle missing") }
            let values = StudioSelectionHandleGeometry.Values(scale: 0.8, rotation: 20)
            let transformed = try vm.selectionHandlePreview(handle, values: values)
            let transformedPixels = try render(vm, transparent: true, frameOverride: transformed).bytes
            try require(vm.finishSelectionHandle(handle, values: values) && vm.currentFrame == transformed &&
                        render(vm, transparent: true).bytes == transformedPixels, "Mixed scale/rotate preview diverged")
            try require(vm.currentFrame.rasterPlacement != originalFrame.rasterPlacement &&
                        vm.currentFrame.elements.first(where: { $0.id == line.id }) != line &&
                        vm.currentFrame.elements.first(where: { $0.id == other.id }) == other, "Mixed scale/rotate touched wrong scope")
            vm.undo(); try require(vm.currentFrame == originalFrame, "Mixed handle was not one Undo")
            vm.redo(); try require(render(vm, transparent: true).bytes == transformedPixels, "Mixed handle Redo pixels")
            vm.undo(); try selectMixed(vm)
            try require(vm.reflectSelected(axis: .horizontal), "Mixed flip failed")
            let flipped = vm.currentFrame, flippedPixels = try render(vm, transparent: true).bytes
            try require(flipped != originalFrame && flippedPixels != originalPixels && flipped.elements.first(where: { $0.id == other.id }) == other,
                        "Mixed reflection changed no pixels or changed unrelated source")
            vm.undo(); try require(vm.currentFrame == originalFrame, "Mixed flip was not one Undo")
            vm.redo(); try require(vm.currentFrame == flipped, "Mixed flip Redo")
            let saved = await vm.save(); try require(saved, "Mixed transformed save")
            let cold = StudioViewModel(storage: store)
            let opened = await cold.openProject(try store.loadAnimation(id: vm.document.id)!.metadata)
            try require(opened && render(cold, transparent: true).bytes == flippedPixels &&
                        cold.originalImageSource(asset)?.originalData == original && cold.rasterData(asset) == image.normalizedPNG,
                        "Mixed transform cold reopen lost pixels or immutable source")
        }
        try await test("mixed drag cancellation stale selection and locks never publish partial artwork") {
            let (vm, _, asset, _, _) = try await mixedFixture()
            try selectMixed(vm)
            guard let initial = vm.beginMove(at: .init(x: 30, y: 30)) else { throw Failure(message: "Mixed cancel capture") }
            var checkpoints = 0
            try require(vm.finishMove(initial, delta: .init(width: 4, height: 5), checkCancellation: { checkpoints += 1 }), "Mixed checkpoint fixture")
            try require(checkpoints > 1, "Mixed commit lacks final cancellation boundary")
            vm.undo(); try selectMixed(vm)
            guard let capture = vm.beginMove(at: .init(x: 30, y: 30)) else { throw Failure(message: "Mixed restored capture") }
            let before = vm.document, pixels = try render(vm, transparent: true).bytes, undo = vm.canUndo, redo = vm.canRedo
            for stop in 1...checkpoints {
                var calls = 0
                try require(!vm.finishMove(capture, delta: .init(width: 4, height: 5), checkCancellation: {
                    calls += 1; if calls == stop { throw CancellationError() }
                }), "Mixed cancellation committed")
                try require(vm.document == before && vm.canUndo == undo && vm.canRedo == redo &&
                            render(vm, transparent: true).bytes == pixels && vm.originalImageSource(asset)?.originalData == original,
                            "Cancelled mixed move partially changed source/history")
            }
            var calls = 0
            try require(!vm.finishMove(capture, delta: .init(width: 4, height: 5), checkCancellation: {
                calls += 1; if calls == checkpoints { vm.deselectAreaImage() }
            }) && vm.document == before, "Mixed commit overwrote late image deselection")
            try selectMixed(vm)
            guard let fresh = vm.beginMove(at: .init(x: 30, y: 30)) else { throw Failure(message: "Mixed lock capture") }
            vm.setLayerLockMode(vm.activeLayerID, mode: .position)
            let locked = vm.document
            try require(!vm.finishMove(fresh, delta: .init(width: 4, height: 5)) && vm.document == locked,
                        "Mixed stale lock moved only drawing or only image")
            try rejects { _ = try vm.movePreview(fresh, delta: .init(width: 4, height: 5)) }
        }
        try await test("mixed delete removes both selected kinds atomically and one Undo restores owned source pixels") {
            let (vm, store, asset, line, other) = try await mixedFixture()
            try selectMixed(vm)
            let frame = vm.currentFrame, pixels = try render(vm, transparent: true).bytes
            let before = vm.document, undo = vm.canUndo, redo = vm.canRedo
            vm.deleteSelected(checkCancellation: { throw CancellationError() })
            try require(vm.document == before && vm.canUndo == undo && vm.canRedo == redo,
                        "Cancelled mixed delete changed document/history")
            vm.deleteSelected()
            try require(vm.currentFrame.rasterAssetID == nil && !vm.currentFrame.elements.contains(where: { $0.id == line.id }) &&
                        vm.currentFrame.elements.first(where: { $0.id == other.id }) == other,
                        "Mixed Delete removed a partial or broadened selection")
            try require(vm.originalImageSource(asset)?.originalData == original && vm.rasterData(asset) == image.normalizedPNG,
                        "Mixed delete discarded source needed by Undo")
            vm.undo()
            try require(vm.currentFrame == frame && render(vm, transparent: true).bytes == pixels,
                        "Mixed deletion was not one Undo or lost source pixels")
            vm.redo(); try require(vm.currentFrame.rasterAssetID == nil && !vm.currentFrame.elements.contains(where: { $0.id == line.id }),
                                   "Mixed Delete Redo lost a selected kind")
            vm.undo()
            let saved = await vm.save(); try require(saved, "Mixed delete Undo save")
            let cold = StudioViewModel(storage: store)
            let opened = await cold.openProject(try store.loadAnimation(id: vm.document.id)!.metadata)
            try require(opened && render(cold, transparent: true).bytes == pixels && cold.originalImageSource(asset)?.originalData == original,
                        "Mixed deletion Undo did not persist owned source")
        }
        try await test("mixed image and drawing share one pivot with preview Undo cold reopen and PNG") {
            let (vm, store) = try await project(root), asset = try attach(image, to: vm)
            let imageLayer = vm.currentFrame.rasterLayerID!
            let line = DrawnElement(id: UUID().uuidString, tool: .line,
                points: [.init(x: 60, y: 80), .init(x: 100, y: 80)], color: "#00FF00",
                width: 4, opacity: 1, layerID: vm.activeLayerID)
            try require(vm.commitElement(line), "Mixed drawing fixture")
            let before = vm.document, originalPixels = try render(vm).bytes
            let command = StudioCommand.transformSelectedArtwork(.init(frame: .id(before.activeFrameID),
                elementIDs: [line.id], image: .init(assetID: asset, layerID: imageLayer),
                dx: 5, dy: -3, scale: 0.5, rotation: 90, flipHorizontal: true, flipVertical: false))
            let request = StudioCommandRequest(requestID: UUID(), projectID: before.id, expectedRevision: before.revision,
                action: .apply([command]))
            let decodedRequest = try StudioCommandExecutor.decode(JSONEncoder().encode(request))
            var malformed = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
            var action = malformed["action"] as! [String: Any]
            var commands = action["apply"] as! [[String: Any]]
            var fields = commands[0]["transformSelectedArtwork"] as! [String: Any]
            var target = fields["image"] as! [String: Any]; target["path"] = "/untrusted"
            fields["image"] = target; commands[0]["transformSelectedArtwork"] = fields
            action["apply"] = commands; malformed["action"] = action
            try rejects { _ = try StudioCommandExecutor.decode(JSONSerialization.data(withJSONObject: malformed)) }
            var preview = try StudioDocumentEditor(document: before)
            _ = try StudioCommandExecutor.execute(decodedRequest, editor: &preview)
            let previewPixels = try render(vm, frameOverride: preview.document.frames[0]).bytes
            _ = try vm.applyStudioCommands(request)
            let after = vm.document, output = try render(vm).bytes
            try require(output == previewPixels && output != originalPixels && after.revision == before.revision + 1,
                        "Mixed preview/commit or one-transaction contract")
            let placed = vm.currentFrame.rasterPlacement!
            try require(abs(placed.x - 45) < 0.000001 && abs(placed.y - 57) < 0.000001 &&
                        placed.width == 80 && placed.height == 40 && vm.currentFrame.rasterRotationDegrees == 90,
                        "Mixed image did not use shared world pivot")
            let moved = vm.currentFrame.elements.first { $0.id == line.id }!
            let point = moved.transform!.point(CGPoint(x: 60, y: 80))
            try require(abs(point.x - 85) < 0.000001 && abs(point.y - 87) < 0.000001 && moved.points == line.points,
                        "Drawing used another pivot or rewrote source samples")
            try require(vm.originalImageSource(asset)?.originalData == original && vm.rasterData(asset) == image.normalizedPNG,
                        "Mixed edit rewrote immutable image bytes")
            vm.undo(); try require(vm.currentFrame == before.frames[0] && render(vm).bytes == originalPixels, "Mixed Undo was partial")
            vm.redo(); try require(render(vm).bytes == output, "Mixed Redo changed pixels")
            let saved = await vm.save(); try require(saved, "Mixed save failed")
            let stored = try store.loadAnimation(id: vm.document.id)!, cold = StudioViewModel(storage: store)
            let opened = await cold.openProject(stored.metadata)
            try require(opened && render(cold).bytes == output && cold.originalImageSource(asset)?.originalData == original,
                        "Mixed cold reopen lost source or pixels")
            let exported = try await StudioExportService().export(document: cold.document, format: .pngSequence,
                outputParent: root, rasterData: { cold.rasterData($0) })
            try require(decoded(exported.imageURLs[0]).bytes == output, "Mixed PNG differs from canonical render")
            let delete = StudioCommandRequest(requestID: UUID(), projectID: vm.document.id, expectedRevision: vm.document.revision,
                action: .apply([.deleteSelectedArtwork(.init(frame: .id(vm.currentFrame.id), elementIDs: [line.id],
                    image: .init(assetID: asset, layerID: imageLayer)))]))
            _ = try vm.applyStudioCommands(delete)
            try require(vm.currentFrame.elements.isEmpty && vm.currentFrame.rasterAssetID == nil &&
                        vm.originalImageSource(asset)?.originalData == original, "Mixed Delete lost Undo source or partially deleted")
            vm.undo(); try require(render(vm).bytes == output, "Mixed Delete Undo failed")
        }
        try await test("mixed selection all-or-none locks stale IDs cancellation and linked image identity") {
            let (vm, _) = try await project(root), asset = try attach(image, to: vm)
            let line = DrawnElement(id: UUID().uuidString, tool: .line,
                points: [.init(x: 60, y: 80), .init(x: 100, y: 80)], color: "#00FF00", width: 4,
                opacity: 1, layerID: vm.activeLayerID)
            try require(vm.commitElement(line), "Mixed rejection fixture")
            let imageLayer = vm.currentFrame.rasterLayerID!, base = vm.document
            @MainActor func apply(_ editor: inout StudioDocumentEditor, assetID: String? = nil,
                                 cancellation: () throws -> Void = {}) throws {
                try editor.transformSelectedArtwork(frameID: base.activeFrameID, ids: [line.id],
                    imageAssetID: assetID ?? asset, imageLayerID: imageLayer, dx: 0, dy: 0, scale: 0.5,
                    rotation: 20, flipHorizontal: false, flipVertical: true, checkCancellation: cancellation)
            }
            var probe = try StudioDocumentEditor(document: base), count = 0
            try apply(&probe, cancellation: { count += 1 })
            for step in 1...count {
                var editor = try StudioDocumentEditor(document: base), checks = 0
                do { try apply(&editor, cancellation: { checks += 1; if checks == step { throw CancellationError() } });
                    throw Failure(message: "Cancelled mixed transform succeeded")
                } catch is CancellationError { }
                try require(editor.document == base && !editor.canUndo, "Cancelled mixed transform committed partially")
            }
            for kind in 0..<4 {
                var blocked = base
                let li = blocked.layers.firstIndex { $0.id == imageLayer }!
                if kind == 0 { blocked.layers[li].locked = true }
                if kind == 1 { blocked.layers[li].visible = false }
                if kind == 2 { blocked.layers[li].lockMode = "position" }
                var editor = try StudioDocumentEditor(document: blocked), rejected = false
                do { try apply(&editor, assetID: kind == 3 ? "missing-image" : asset) } catch { rejected = true }
                try require(rejected && editor.document == blocked && !editor.canUndo, "Invalid mixed target partially transformed")
                rejected = false
                do { try editor.deleteSelectedArtwork(frameID: base.activeFrameID, ids: [line.id],
                    imageAssetID: kind == 3 ? "missing-image" : asset, imageLayerID: imageLayer) } catch { rejected = true }
                try require(rejected && editor.document == blocked && !editor.canUndo, "Invalid mixed target partially deleted")
            }
            var linked = try StudioDocumentEditor(document: base)
            try linked.duplicateLayer(imageLayer)
            let other = linked.document.frames[0].rasterLayerInstances.first { $0.layerID != imageLayer }!
            try apply(&linked)
            try require(linked.document.frames[0].rasterInstance(on: other.layerID) == other,
                        "Mixed operation transformed an unselected linked instance")
        }

        @MainActor func dualFixture() async throws -> (StudioViewModel, DeviceStorageManager, String, String) {
            let (vm, store) = try await project(root)
            let second = try await imported(png(width: 40, height: 80), in: root, name: "Independent portrait")
            let a = try attach(image, to: vm), beforeSecond = vm.document
            let b = try attach(second, to: vm)
            try require(a != b && vm.frames.count == 1 && vm.document.revision == beforeSecond.revision + 1,
                        "Second import did not add one same-frame edit")
            try require(vm.currentFrame.rasterAssetID == a && vm.currentFrame.referencedRasterAssetIDs == [a, b],
                        "Second source replaced primary or lost independent identity")
            vm.selectedTool = .move
            for (id, rect) in [(a, StudioRasterPlacement(x: 10, y: 10, width: 60, height: 30)),
                               (b, StudioRasterPlacement(x: 90, y: 70, width: 30, height: 60))] {
                let layer = vm.currentFrame.rasterLayerInstances.first { vm.currentFrame.rasterAssetID(on: $0.layerID) == id }!.layerID
                vm.selectLayer(layer)
                guard let capture = vm.prepareImagePlacement() else { throw Failure(message: "Independent placement unavailable") }
                try require(capture.assetID == id && vm.placeImage(capture, at: rect), "Independent placement used wrong source")
            }
            return (vm, store, a, b)
        }
        try await test("two independent imports compose on one frame with exact originals cold reopen portable and PNG") {
            let (vm, store, a, b) = try await dualFixture()
            let current = vm.document, output = try render(vm)
            try pixel(output.pixel(20, 20), [255, 0, 0, 255]); try pixel(output.pixel(60, 20), [127, 127, 255, 255])
            try pixel(output.pixel(98, 90), [255, 0, 0, 255]); try pixel(output.pixel(114, 90), [127, 127, 255, 255])
            let originals = [a: vm.originalImageSource(a)!, b: vm.originalImageSource(b)!]
            let saved = await vm.save(); try require(saved, "Independent image save failed")
            let stored = try store.loadAnimation(id: current.id)!
            try require(stored.metadata.frameCount == 1 && stored.frames.count == 1 && stored.additionalImageAssets?.count == 1,
                        "Additional source became fake animation frame or missing record")
            try require(stored.frames[0].sourceImage == originals[a] && stored.additionalImageAssets?[b]?.sourceImage == originals[b],
                        "Primary and independent original metadata changed")
            let portable = try store.portableBundle(for: stored), recovered = try store.projectFromPortableBundle(portable)
            try require(recovered.additionalImageAssets == stored.additionalImageAssets && recovered.frames == stored.frames,
                        "Portable backup lost independent source bytes")
            let cold = StudioViewModel(storage: store); let opened = await cold.openProject(stored.metadata)
            try require(opened && cold.document == current && render(cold).bytes == output.bytes,
                        "Cold reopen changed dual image document or pixels")
            try require(cold.originalImageSource(a) == originals[a] && cold.originalImageSource(b) == originals[b], "Cold reopen lost originals")
            for format in [StudioExportService.Format.pngSequence, .spritesheet] {
                let files = try await StudioExportService().export(document: cold.document, format: format,
                    outputParent: root, rasterData: { cold.rasterData($0) })
                try require(decoded(files.imageURLs[0]).bytes == output.bytes, "Dual source exported PNG disagrees with canvas")
            }
        }
        try await test("missing and corrupt additional source fail cold open without publishing partial document") {
            let (vm, store, _, b) = try await dualFixture()
            let saved = await vm.save(); try require(saved, "Dual fixture save failed")
            let complete = try store.loadAnimation(id: vm.document.id)!
            for corrupt in [false, true] {
                var invalid = complete
                if corrupt { invalid.additionalImageAssets?[b]?.imageData = Data([1, 2, 3]) }
                else { invalid.additionalImageAssets?.removeValue(forKey: b) }
                try store.saveAnimation(invalid)
                let cold = StudioViewModel(storage: store), before = cold.document
                let opened = await cold.openProject(invalid.metadata)
                try require(!opened && !cold.isEditing && cold.document == before && !cold.canUndo && !cold.canRedo,
                            "Invalid additional source published partial editor state")
                try require(try store.loadAnimation(id: invalid.id)!.additionalImageAssets == invalid.additionalImageAssets,
                            "Failed open rewrote invalid source evidence")
                try store.saveAnimation(complete)
                let recovered = await cold.openProject(complete.metadata)
                try require(recovered && render(cold).bytes == render(vm).bytes, "Restored source registry did not reopen")
            }
        }
        try await test("delete either independent image promotes correct source and one Undo restores both") {
            let (vm, store, a, b) = try await dualFixture(), expected = try render(vm).bytes
            for asset in [a, b] {
                let before = vm.document
                let layer = vm.currentFrame.rasterLayerInstances.first { vm.currentFrame.rasterAssetID(on: $0.layerID) == asset }!.layerID
                vm.selectLayer(layer); let capture = vm.prepareImagePlacement()!
                try require(capture.assetID == asset && vm.deleteImage(capture), "Wrong independent source delete")
                let survivor = asset == a ? b : a
                try require(vm.currentFrame.referencedRasterAssetIDs == [survivor], "Delete removed wrong source or all images")
                let rendered = try render(vm)
                if asset == a { try pixel(rendered.pixel(20,20), [255,255,255,255]); try pixel(rendered.pixel(98,90), [255,0,0,255]) }
                else { try pixel(rendered.pixel(20,20), [255,0,0,255]); try pixel(rendered.pixel(98,90), [255,255,255,255]) }
                try require(vm.originalImageSource(asset) != nil, "Undo original pruned prematurely")
                let saved = await vm.save(); try require(saved, "Promoted source could not save")
                let cold = StudioViewModel(storage: store); let opened = await cold.openProject(try store.loadAnimation(id: vm.document.id)!.metadata)
                try require(opened && render(cold).bytes == rendered.bytes, "Promoted source cold pixels wrong")
                vm.undo(); try require(vm.currentFrame.referencedRasterAssetIDs == [a,b] && render(vm).bytes == expected,
                                      "One Undo failed to restore both independent originals")
                try require(vm.document.frames == before.frames, "Delete Undo altered independent geometry")
            }
        }
        try await test("independent image and frame clipboards retain the selected source through copy paste and history") {
            let (vm, _, a, b) = try await dualFixture()
            let layerB = vm.currentFrame.rasterLayerInstances.first { vm.currentFrame.rasterAssetID(on: $0.layerID) == b }!.layerID
            vm.selectLayer(layerB)
            try require(vm.copyImage(), "Second source image copy unavailable")
            let oldCount = vm.currentFrame.rasterLayerInstances.count
            try require(vm.pasteImage(), "Independent source paste into occupied frame unavailable")
            try require(vm.currentFrame.rasterLayerInstances.count == oldCount + 1 && vm.currentFrame.referencedRasterAssetIDs == [a,b],
                        "Image paste added wrong source or replaced primary")
            let added = vm.currentFrame.rasterLayerInstances.last!
            try require(vm.currentFrame.rasterAssetID(on: added.layerID) == b, "Selected secondary copy pasted primary bytes")
            vm.copyFrame(); vm.addFrame(); vm.pasteFrame()
            try require(vm.currentFrame.referencedRasterAssetIDs == [a,b] && vm.rasterSources(for: vm.currentFrame).count == 2,
                        "Frame clipboard lost additional source ownership")
        }
        try await test("missing second source stale prepared bytes and cancelled second import fail atomically") {
            let (vm, _, a, b) = try await dualFixture(), before = vm.document
            let frame = vm.currentFrame, sources = vm.rasterSources(for: frame)
            try rejects { _ = try StudioFrameRenderer.prepareRasters(frame: frame, layers: vm.layers, sourceData: [a: sources[a]!]) }
            try rejects { _ = try StudioFrameRenderer.resolvedRasterSources(frame: frame, legacyData: Data([1]), sources: sources) }
            var layers = vm.layers
            let layerB = frame.rasterLayerInstances.first { frame.rasterAssetID(on: $0.layerID) == b }!.layerID
            layers[layers.firstIndex { $0.id == layerB }!].visible = false
            let hidden = try StudioFrameRenderer.prepareRasters(frame: frame, layers: layers, sourceData: [a: sources[a]!])
            try require(Set(hidden.keys) == [a], "Hidden source still required visible decode")
            let third = try await imported(png(width: 30, height: 30), in: root)
            for stop in [1,2] {
                var count = 0
                try rejects { _ = try vm.attachImportedImage(third, expectedProjectID: before.id, expectedRevision: before.revision,
                    frameID: before.activeFrameID, layerID: before.activeLayerID,
                    checkCancellation: { count += 1; if count == stop { throw CancellationError() } }) }
                try require(vm.document == before && vm.rasterSources(for: frame) == sources, "Cancelled additional import published part of source set")
            }
            var corrupted = sources; corrupted[b] = sources[a]
            let cached = try StudioSmudgeReplay.prepare(frame: frame, layers: vm.layers,
                canvasSize: CGSize(width: 160,height: 160), rasterData: sources[a], rasterDataByID: sources)
            try rejects { try cached.validate(frame: frame, layers: vm.layers, canvasSize: CGSize(width:160,height:160),
                rasterData: sources[a], rasterDataByID: corrupted, liveElement: nil) }
        }
        try await test("plural renderer retains legacy sixteen megapixel admission and rejects excess source bytes") {
            let bytes = try png(width: 4096, height: 4096)
            let asset = "image-" + UUID().uuidString, layer = CanvasLayer(id: UUID().uuidString, name: "Large retained image")
            var frame = AnimationFrame(id: UUID().uuidString, elements: [])
            frame.rasterAssetID = asset; frame.rasterLayerID = layer.id
            frame.rasterPlacement = .init(x: 0,y: 0,width: 160,height: 160)
            let prepared = try StudioFrameRenderer.prepareRasters(frame: frame, layers: [layer], sourceData: [asset: bytes])
            try require(prepared[asset]?.image.width == 4096 && prepared[asset]?.image.height == 4096,
                        "Plural compositor reduced previously accepted full-resolution sixteen megapixel source")
            try rejects { _ = try StudioFrameRenderer.resolvedRasterSources(frame: frame, legacyData: nil,
                sources: [asset: Data(repeating: 1, count: 40 * 1024 * 1024 + 1)]) }
        }
        try await test("ordered blur replays actual secondary pixels and both sources survive effect undo") {
            let (vm, _, a, b) = try await dualFixture()
            let layerB = vm.currentFrame.rasterLayerInstances.first { vm.currentFrame.rasterAssetID(on: $0.layerID) == b }!.layerID
            vm.selectLayer(layerB); let before = try render(vm)
            let effect = DrawnElement(id: UUID().uuidString, tool: .blur, points: [.init(x: 105,y:90)], color: "#000000",
                width: 20, opacity: 1, layerID: layerB, blur: .init(hardness: 1, radius: 4))
            try require(vm.commitElement(effect), "Blur could not edit second source layer")
            let after = try render(vm)
            try require(after.bytes != before.bytes, "Secondary image blur did not change actual pixels")
            try pixel(after.pixel(20,20), before.pixel(20,20))
            try require(vm.rasterSources(for: vm.currentFrame).keys.sorted() == [a,b].sorted(), "Blur mutated source ownership")
            vm.undo(); try require(render(vm).bytes == before.bytes, "Blur Undo did not restore both original source pixels")
        }
        try await test("same source image paste promotes linked schema and preserves one frame history") {
            let (vm, store) = try await project(root), asset = try attach(image, to: vm)
            try require(vm.document.schemaVersion == 3, "Single-image fixture must exercise legacy schema")
            vm.selectedTool = .move; vm.selectLayer(vm.currentFrame.rasterLayerID!)
            try require(vm.copyImage(), "Single-image copy failed")
            let before = vm.document
            try require(vm.pasteImage(), "Same-source paste into its own frame failed")
            try require(vm.document.schemaVersion == 27 && vm.frames.count == 1 &&
                vm.currentFrame.rasterLayerInstances.count == 2 && vm.currentFrame.referencedRasterAssetIDs == [asset] &&
                vm.currentFrame.rasterAliases?.first?.assetID == nil, "Linked paste changed source or timeline")
            let pasted = vm.currentFrame, pixels = try render(vm).bytes
            vm.undo(); try require(vm.currentFrame == before.frames[0] && vm.document.schemaVersion == 3, "Linked paste Undo failed")
            vm.redo(); try require(vm.currentFrame == pasted && render(vm).bytes == pixels, "Linked paste Redo failed")
            let saved = await vm.save(); try require(saved, "Linked paste save failed: isEditing=\(vm.isEditing), isSaving=\(vm.isSaving), isDirty=\(vm.isDirty), revision=\(vm.document.revision), status=\(vm.saveTimeAgo), activeStroke=\(String(describing: vm.activeStrokeID)), pendingBrush=\(vm.pendingBrushStroke != nil), textDraft=\(vm.textDraft != nil), message=\(String(describing: vm.message))")
            let cold = StudioViewModel(storage: store)
            let opened = await cold.openProject(try store.loadAnimation(id: vm.document.id)!.metadata)
            try require(opened && cold.currentFrame == pasted && render(cold).bytes == pixels &&
                cold.originalImageSource(asset)?.originalData == original, "Linked paste cold source or pixels changed")
        }
        try await test("image Wand source regions Add Subtract transparent bounds and exact transform inverse") {
            let instance = StudioRasterLayerInstance(layerID: "wand-layer", placement: .init(x: 0, y: 40, width: 160, height: 80))
            let red = try StudioImageRegionService.select(png: image.normalizedPNG, instance: instance, point: CGPoint(x: 30, y: 80),
                tolerance: 0, contiguous: true, mode: .newSelection, previous: nil)!
            try require(red.selectedPixels == 1600, "Wand did not select actual opaque red half")
            let both = try StudioImageRegionService.select(png: image.normalizedPNG, instance: instance, point: CGPoint(x: 130, y: 80),
                tolerance: 0, contiguous: false, mode: .add, previous: red.membership)!
            try require(both.selectedPixels == 3200, "Wand Add dropped partial-alpha blue pixels")
            let blue = try StudioImageRegionService.select(png: image.normalizedPNG, instance: instance, point: CGPoint(x: 30, y: 80),
                tolerance: 0, contiguous: true, mode: .subtract, previous: both.membership)!
            try require(blue.selectedPixels == 1600, "Wand Subtract selected wrong source region")
            let empty = try StudioImageRegionService.select(png: image.normalizedPNG, instance: instance, point: CGPoint(x: 130, y: 80),
                tolerance: 0, contiguous: true, mode: .subtract, previous: blue.membership)
            try require(empty == nil, "Subtract did not clear last region")
            let fragmentImage = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(red.fragmentPNG as CFData, nil)!, 0, nil)!
            let remainderImage = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(red.remainderPNG as CFData, nil)!, 0, nil)!
            let fragmentPixels = pixels(fragmentImage), remainderPixels = pixels(remainderImage)
            try pixel(fragmentPixels.pixel(10, 20), [255,0,0,255]); try pixel(fragmentPixels.pixel(60,20), [0,0,0,0])
            try pixel(remainderPixels.pixel(60,20), [0,0,128,128]); try pixel(remainderPixels.pixel(10,20), [0,0,0,0])
            for turns in 0...3 { for flip in [false, true] { for degrees in [-45.0, 0, 37] {
                let placement = StudioRasterPlacement(x: 40, y: 40, width: 70, height: 50)
                let crop = StudioImageCrop(x: 0.1, y: 0.2, width: 0.7, height: 0.6)
                let transformed = StudioRasterLayerInstance(layerID: "wand-layer", placement: placement,
                    reflection: .init(horizontal: flip, vertical: !flip), quarterTurns: turns == 0 ? nil : turns,
                    crop: crop, rotationDegrees: degrees == 0 ? nil : degrees)
                // Independent forward coordinate derived from a known source pixel.
                let u = 0.35, v = 0.65, w = turns % 2 == 0 ? placement.width : placement.height
                let h = turns % 2 == 0 ? placement.height : placement.width
                let x = (u - 0.5) * w, y = (v - 0.5) * h, q = Double(turns) * .pi / 2
                let qx = (x * cos(q) - y * sin(q)) * (flip ? -1.0 : 1.0)
                let qy = (x * sin(q) + y * cos(q)) * (flip ? 1.0 : -1.0), angle = degrees * .pi / 180
                let canvas = CGPoint(x: placement.x + placement.width / 2 + qx * cos(angle) - qy * sin(angle),
                    y: placement.y + placement.height / 2 + qx * sin(angle) + qy * cos(angle))
                let actual = try StudioImageRegionService.sourcePoint(canvas, instance: transformed, width: 80, height: 40)
                try require(abs(actual.x - (crop.x + u * crop.width) * 80) < 0.000001 &&
                    abs(actual.y - (crop.y + v * crop.height) * 40) < 0.000001, "Wand inverse disagrees for crop/quarter/reflection/angle")
            } } }
            var total = 0
            _ = try StudioImageRegionService.select(png: image.normalizedPNG, instance: instance, point: CGPoint(x: 30,y: 80),
                tolerance: 0, contiguous: true, mode: .newSelection, previous: nil, checkCancellation: { total += 1 })
            for stop in 1...total {
                var count = 0
                try rejects { _ = try StudioImageRegionService.select(png: image.normalizedPNG, instance: instance, point: CGPoint(x: 30,y: 80),
                    tolerance: 0, contiguous: true, mode: .newSelection, previous: nil, checkCancellation: {
                        count += 1; if count == stop { throw CancellationError() }
                    }) }
            }
        }
        try await test("image Wand exact opaque half-pixel fractional-scale and selected partial-alpha reconstruction") {
            let opaque = try await imported(png(opaqueBlue: true), in: root, name: "Opaque Wand edge")
            let cases: [(String, StudioImageImportService.ImportedImage, StudioRasterPlacement, Double)] = [
                ("opaque-half-pixel", opaque, .init(x:20.5,y:40.5,width:120,height:60), 0.25),
                ("opaque-fractional-scale", opaque, .init(x:20.5,y:30.5,width:101,height:50.5), 0.25),
                ("selected-partial-alpha-fractional-scale", image, .init(x:20.5,y:30.5,width:101,height:50.5), 0.75)
            ]
            var differences: [String] = []
            for (name, input, placement, seedFraction) in cases {
                let (vm, _) = try await project(root), sourceID = try attach(input, to: vm)
                vm.selectLayer(vm.currentFrame.rasterLayerID!); vm.selectedTool = .move; await vm.flush()
                guard let position = vm.prepareImagePlacement() else { throw Failure(message: "Wand fractional placement unavailable") }
                try require(vm.placeImage(position, at: placement), "Wand fractional placement failed")
                vm.selectedTool = .wand; await vm.flush()
                let original = try render(vm), before = vm.document
                let selected = await vm.selectImageRegion(try vm.captureImageRegion(),
                    at: CGPoint(x: placement.x + placement.width * seedFraction, y: placement.y + placement.height / 2))
                try require(selected && vm.wandSelectedPixels == 1600 && vm.document == before,
                    "Fractional Wand did not select exactly one source half without history")
                try require(vm.applyImageRegion(.copy), "Fractional Wand Copy failed")
                try require(vm.applyImageRegion(.delete), "Fractional Wand Delete failed")
                vm.selectedTool = .move; await vm.flush()
                try require(vm.pasteImage(), "Fractional Wand Paste failed")
                let restored = try render(vm)
                try require(restored.width == original.width && restored.height == original.height,
                    "Wand reconstruction dimensions changed")
                var changed = 0, maxDelta = 0
                for i in original.bytes.indices {
                    let delta = abs(Int(original.bytes[i]) - Int(restored.bytes[i]))
                    if delta != 0 { changed += 1 }; maxDelta = max(maxDelta, delta)
                }
                print("WAND_EXACT_RECONSTRUCTION \(name) changedChannels=\(changed) maxDelta=\(maxDelta)")
                if restored.bytes != original.bytes { differences.append("\(name): \(changed) channels, max \(maxDelta)") }
                try require(vm.rasterData(sourceID) == input.normalizedPNG && vm.originalImageSource(sourceID)?.originalData == input.originalData,
                    "Reconstruction overwrote the original source")
            }
            // Run every variant to preserve decisive opaque and partial-alpha
            // evidence, then fail the suite on ANY changed channel. No tolerance.
            try require(differences.isEmpty, "Wand split-image interpolation changed original composition: " + differences.joined(separator: "; "))
        }
        try await test("real image Wand Copy Delete preserve source colors alpha one Undo and cold ownership") {
            let (vm, store) = try await project(root), sourceID = try attach(image, to: vm)
            let layer = vm.currentFrame.rasterLayerID!
            vm.selectLayer(layer); vm.selectedTool = .wand; await vm.flush()
            let before = vm.document, beforePixels = try render(vm).bytes, undo = vm.canUndo
            let selected = await vm.selectImageRegion(try vm.captureImageRegion(), at: CGPoint(x:30,y:80))
            try require(selected && vm.wandSelectedPixels == 1600 && vm.document == before && vm.canUndo == undo, "Wand selection mutated history")
            try require(vm.applyImageRegion(.copy) && vm.document == before && vm.canUndo == undo, "Wand Copy mutated artwork")
            try require(vm.applyImageRegion(.delete), "Wand Delete failed")
            let deleted = try render(vm)
            try pixel(deleted.pixel(30,80), [255,255,255,255]); try pixel(deleted.pixel(130,80), [127,127,255,255])
            try require(vm.originalImageSource(vm.currentFrame.rasterAssetID!)?.originalData == image.originalData && vm.rasterData(sourceID) == image.normalizedPNG,
                "Wand Delete lost original or Undo rendition")
            vm.undo(); try require(try render(vm).bytes == beforePixels, "Wand Delete is not one exact Undo")
            vm.redo(); try require(try render(vm).bytes == deleted.bytes, "Wand Delete Redo changed pixels")
            vm.selectedTool = .move; await vm.flush()
            try require(vm.pasteImage(), "Wand copied pixels could not use real image Paste")
            let pasted = try render(vm)
            try require(pasted.bytes == beforePixels, "Wand fragment/remainder reassembly changed original interpolated composition")
            try pixel(pasted.pixel(30,80), [255,0,0,255]); try pixel(pasted.pixel(130,80), [127,127,255,255])
            let saved = await vm.save(); try require(saved, "Wand source save failed")
            let cold = StudioViewModel(storage: store), opened = await cold.openProject(try store.loadAnimation(id:vm.document.id)!.metadata)
            try require(opened && render(cold).bytes == pasted.bytes && cold.currentFrame.referencedRasterAssetIDs == [sourceID] && cold.currentFrame.rasterLayerInstances.count == 2 &&
                cold.currentFrame.rasterLayerInstances.allSatisfy({ $0.regionMask != nil }),
                "Wand cold reopen lost fragment/remainder composition")
        }
        try await test("real image Wand Move preserves blue sibling pixels source geometry and atomic cancellation") {
            let (vm, _) = try await project(root), sourceID = try attach(image, to: vm), layer = vm.currentFrame.rasterLayerID!
            vm.selectLayer(layer); vm.selectedTool = .wand; await vm.flush()
            let selected = await vm.selectImageRegion(try vm.captureImageRegion(), at: CGPoint(x:30,y:80))
            try require(selected, "Wand Move selection")
            vm.wandMoveY = 20
            let before = vm.document, beforePixels = try render(vm).bytes
            var count = 0
            try require(!vm.applyImageRegion(.move, checkCancellation: { count += 1; if count == 3 { throw CancellationError() } }), "Cancelled Move succeeded")
            try require(vm.document == before && render(vm).bytes == beforePixels, "Cancelled Move partially cut source")
            try require(vm.applyImageRegion(.move), "Wand Move failed")
            let moved = try render(vm)
            try pixel(moved.pixel(30,50), [255,255,255,255]); try pixel(moved.pixel(30,130), [255,0,0,255])
            try pixel(moved.pixel(130,80), [127,127,255,255])
            try require(vm.currentFrame.referencedRasterAssetIDs == [sourceID] && vm.currentFrame.rasterLayerInstances.count == 2 &&
                vm.currentFrame.rasterLayerInstances.allSatisfy({ $0.regionMask != nil }) && vm.originalImageSource(sourceID)?.originalData == image.originalData,
                "Wand Move flattened unrelated source or destroyed original")
            vm.undo(); try require(try render(vm).bytes == beforePixels, "Wand Move needs more than one Undo")
            vm.redo(); try require(try render(vm).bytes == moved.bytes, "Wand Move Redo changed raster")
        }
        try await test("image Wand linked instance isolation unsupported layers stale capture and zero Move stay fail closed") {
            let (vm, _) = try await project(root), sourceID = try attach(image, to: vm), primary = vm.currentFrame.rasterLayerID!
            vm.duplicateLayer(primary); let alias = vm.activeLayerID
            vm.selectedTool = .wand; await vm.flush()
            let capture = try vm.captureImageRegion(), sibling = vm.currentFrame.projectedRasterFrame(on: primary)
            let selected = await vm.selectImageRegion(capture, at: CGPoint(x:30,y:80)); try require(selected, "Linked Wand select")
            let before = vm.document
            try require(!vm.applyImageRegion(.move) && vm.document == before, "Zero displacement needlessly split source")
            try require(vm.applyImageRegion(.delete) && vm.currentFrame.projectedRasterFrame(on: primary) == sibling &&
                vm.currentFrame.rasterAssetID(on: primary) == sourceID && vm.currentFrame.rasterAssetID(on: alias) == sourceID &&
                vm.currentFrame.rasterInstance(on: alias)?.regionMask != nil,
                "Wand Delete retargeted linked unselected instance")
            let stale = await vm.selectImageRegion(capture, at: CGPoint(x:30,y:80)); try require(!stale, "Stale source capture selected new pixels")
            vm.setLayerOpacity(alias, opacity: 0.5); await vm.flush()
            try rejects { _ = try vm.captureImageRegion() }
            vm.undo(); vm.setLayerLockMode(alias, mode: .full); await vm.flush()
            try rejects { _ = try vm.captureImageRegion() }
        }
        try await test("image region masks schema bounds source hit testing duplication promotion and repeated selection") {
            let (vm, store) = try await project(root), sourceID = try attach(image, to: vm)
            let primary = vm.currentFrame.rasterLayerID!
            vm.selectLayer(primary); vm.selectedTool = .wand; await vm.flush()
            let selectedMask = await vm.selectImageRegion(try vm.captureImageRegion(), at: CGPoint(x:30,y:80))
            try require(selectedMask, "Mask selection failed")
            try require(vm.applyImageRegion(.delete), "Masked delete failed")
            let deleted = try render(vm).bytes
            try require(vm.document.schemaVersion == 32 && vm.currentFrame.rasterRegionMask != nil,
                "Image masks were not schema gated")
            var old = vm.document; old.schemaVersion = 31
            try rejects { try old.validate() }
            try rejects { try StudioImageRegionMask(width: 4097, height: 1, spans: []).validate() }
            try rejects { try StudioImageRegionMask(width: 80, height: 40, spans: [.init(row:0,start:0,end:40), .init(row:0,start:39,end:50)]).validate() }
            vm.selectedTool = .move; await vm.flush()
            try require(vm.setImageCanvasMove(true), "Masked image Move unavailable")
            try require(vm.beginImageMove(at: CGPoint(x:30,y:80)) == nil && vm.beginImageMove(at: CGPoint(x:130,y:80)) != nil,
                "Image hit test admitted removed source pixels or rejected visible pixels")
            vm.duplicateLayer(primary); let alias = vm.activeLayerID
            try require(vm.currentFrame.rasterInstance(on: alias)?.regionMask == vm.currentFrame.rasterRegionMask &&
                vm.currentFrame.referencedRasterAssetIDs == [sourceID], "Duplicate lost mask or duplicated source identity")
            vm.selectLayer(primary)
            guard let capture = vm.prepareImagePlacement() else { throw Failure(message: "Masked primary placement unavailable") }
            try require(vm.deleteImage(capture), "Masked primary deletion failed")
            try require(vm.currentFrame.rasterLayerID == alias && vm.currentFrame.rasterRegionMask != nil && render(vm).bytes == deleted,
                "Primary promotion dropped region mask")
            vm.selectLayer(alias); vm.selectedTool = .wand; await vm.flush()
            let remaining = await vm.selectImageRegion(try vm.captureImageRegion(), at: CGPoint(x:130,y:80))
            try require(remaining, "Remaining region selection failed")
            try require(vm.wandSelectedPixels == 1600 && vm.applyImageRegion(.delete), "Repeated mask selection resurfaced removed pixels")
            let blank = try render(vm)
            try pixel(blank.pixel(30,80), [255,255,255,255]); try pixel(blank.pixel(130,80), [255,255,255,255])
            let saved = await vm.save(); try require(saved, "Masked source save failed")
            let cold = StudioViewModel(storage: store)
            let opened = await cold.openProject(try store.loadAnimation(id: vm.document.id)!.metadata)
            try require(opened, "Masked source reopen failed")
            try require(try render(cold).bytes == blank.bytes && cold.rasterData(sourceID) == image.normalizedPNG,
                "Repeated masks lost original or changed cold pixels")
        }
        try await test("image Wand tight mask Move remains usable when full source touches every canvas edge") {
            let (vm, _) = try await project(root), sourceID = try attach(image, to: vm)
            vm.selectLayer(vm.currentFrame.rasterLayerID!); vm.selectedTool = .move; await vm.flush()
            guard let capture = vm.prepareImagePlacement() else { throw Failure(message: "Full-canvas source placement unavailable") }
            try require(vm.placeImage(capture, at: .init(x:0,y:0,width:Double(vm.canvasWidth),height:Double(vm.canvasHeight))),
                "Full-canvas source placement failed")
            vm.selectedTool = .wand; await vm.flush()
            let selected = await vm.selectImageRegion(try vm.captureImageRegion(), at: CGPoint(x:20,y:80))
            try require(selected, "Full-canvas source region selection failed")
            let before = vm.document, pixelsBefore = try render(vm).bytes
            vm.wandMoveX = 20
            try require(vm.applyImageRegion(.move), "Full-source bounds incorrectly prevent useful selected-region movement")
            let moved = try render(vm)
            try pixel(moved.pixel(10,80), [255,255,255,255]); try pixel(moved.pixel(30,80), [255,0,0,255])
            try require(vm.currentFrame.referencedRasterAssetIDs == [sourceID] && vm.rasterData(sourceID) == image.normalizedPNG,
                "Useful mask movement replaced the original source")
            vm.undo(); try require(try render(vm).bytes == pixelsBefore && vm.document.frames == before.frames,
                "Full-canvas mask movement is not one exact Undo")
        }
        try await test("Wand reconstruction respects independent layer opacity visibility blend glow elements order and transform") {
            let opaque = try await imported(png(opaqueBlue:true), in:root)
            let (vm, _) = try await project(root); _ = try attach(opaque,to:vm)
            vm.selectLayer(vm.currentFrame.rasterLayerID!); vm.selectedTool = .wand; await vm.flush()
            let original = try render(vm)
            let selected = await vm.selectImageRegion(try vm.captureImageRegion(),at:CGPoint(x:30,y:80))
            try require(selected && vm.applyImageRegion(.copy) && vm.applyImageRegion(.delete),"Reconstruction fixture selection failed")
            vm.selectedTool = .move; await vm.flush(); try require(vm.pasteImage(),"Reconstruction fixture paste failed")
            let frame = vm.currentFrame, layers = vm.layers
            let pairs = StudioFrameRenderer.imageRegionReconstructionPairs(frame:frame,layers:layers)
            try require(pairs.count == 1 && render(vm).bytes == original.bytes,"Exact complementary image reconstruction unavailable")
            guard let fragment = frame.rasterLayerInstances.first(where:{$0.regionMask?.inverted == false}),
                  let index = layers.firstIndex(where:{$0.id == fragment.layerID}) else { throw Failure(message:"Selected fragment unavailable") }
            var changed = layers; changed[index].opacity = 0.5
            try require(StudioFrameRenderer.imageRegionReconstructionPairs(frame:frame,layers:changed).isEmpty,"Opacity was coalesced away")
            try pixel(render(vm,layersOverride:changed).pixel(30,80),[255,128,128,255])
            changed = layers; changed[index].visible = false
            try require(StudioFrameRenderer.imageRegionReconstructionPairs(frame:frame,layers:changed).isEmpty,"Hidden fragment was restored")
            try pixel(render(vm,layersOverride:changed).pixel(30,80),[255,255,255,255])
            changed = layers; changed[index].blendMode = "multiply"
            try require(StudioFrameRenderer.imageRegionReconstructionPairs(frame:frame,layers:changed).isEmpty,"Independent blending was coalesced")
            _ = try render(vm,layersOverride:changed)
            changed = layers; changed[index].glowEnabled = true
            try require(StudioFrameRenderer.imageRegionReconstructionPairs(frame:frame,layers:changed).isEmpty,"Independent glow was coalesced")
            _ = try render(vm,layersOverride:changed)
            var withElement = frame
            withElement.elements.append(.init(id:"region-overlay",tool:.line,points:[.init(x:20,y:80),.init(x:60,y:80)],color:"#00FF00",width:8,opacity:1,layerID:fragment.layerID))
            try require(StudioFrameRenderer.imageRegionReconstructionPairs(frame:withElement,layers:layers).isEmpty,"Image layer drawing was coalesced away")
            try pixel(render(vm,frameOverride:withElement).pixel(30,80),[0,255,0,255])
            let overlay = CanvasLayer(id:"between-regions",name:"Between regions")
            let imageIndices = layers.indices.filter { frame.rasterInstance(on:layers[$0].id) != nil }.sorted()
            var separated = layers; separated.insert(overlay,at:imageIndices[0]+1)
            var orderedFrame = frame
            orderedFrame.elements.append(.init(id:"between-line",tool:.line,points:[.init(x:20,y:80),.init(x:140,y:80)],color:"#00FF00",width:8,opacity:1,layerID:overlay.id))
            try require(StudioFrameRenderer.imageRegionReconstructionPairs(frame:orderedFrame,layers:separated).isEmpty,"Intervening layer/order was ignored")
            let betweenPixels = try render(vm,frameOverride:orderedFrame,layersOverride:separated)
            let upperImage = frame.rasterInstance(on:separated[imageIndices[0]].id)!
            if upperImage.regionMask!.inverted {
                try pixel(betweenPixels.pixel(30,80),[0,255,0,255]); try pixel(betweenPixels.pixel(130,80),[0,0,255,255])
            } else {
                try pixel(betweenPixels.pixel(30,80),[255,0,0,255]); try pixel(betweenPixels.pixel(130,80),[0,255,0,255])
            }
            var above = separated; above.removeAll(where:{$0.id == overlay.id}); above.insert(overlay,at:0)
            let abovePixels = try render(vm,frameOverride:orderedFrame,layersOverride:above)
            try pixel(abovePixels.pixel(30,80),[0,255,0,255]); try pixel(abovePixels.pixel(130,80),[0,255,0,255])
            let live = DrawnElement(id:"region-live",tool:.line,points:[.init(x:30,y:80)],color:"#00FF00",width:8,opacity:1,layerID:fragment.layerID)
            try require(StudioFrameRenderer.imageRegionReconstructionPairs(frame:frame,layers:layers,liveElement:live).isEmpty,"Live drawing was coalesced")
            var movedFrame = frame, moved = fragment
            let p = fragment.placement!; moved.placement = .init(x:p.x+1,y:p.y,width:p.width,height:p.height)
            try movedFrame.updateRasterInstance(moved)
            try require(StudioFrameRenderer.imageRegionReconstructionPairs(frame:movedFrame,layers:layers).isEmpty,"Different transform was treated as exact identity")
            try require(try render(vm,frameOverride:movedFrame).bytes != original.bytes,"Moved fragment was restored at its old position")
            var scaledFrame = frame, scaled = fragment
            scaled.placement = .init(x:p.x,y:p.y,width:p.width*0.75,height:p.height*0.75)
            try scaledFrame.updateRasterInstance(scaled)
            try require(StudioFrameRenderer.imageRegionReconstructionPairs(frame:scaledFrame,layers:layers).isEmpty && render(vm,frameOverride:scaledFrame).bytes != original.bytes,"Scaled fragment was coalesced")
            var turnedFrame = frame, turned = fragment; turned.rotationDegrees = 10
            try turnedFrame.updateRasterInstance(turned)
            try require(StudioFrameRenderer.imageRegionReconstructionPairs(frame:turnedFrame,layers:layers).isEmpty && render(vm,frameOverride:turnedFrame).bytes != original.bytes,"Rotated fragment was coalesced")
            var corrupt = fragment.regionMask!
            var spoofed = fragment; spoofed.placement = .init(x:p.x+1,y:p.y,width:p.width,height:p.height)
            corrupt.placementGeometry = .init(spoofed)
            try rejects { try corrupt.validate() }
            var badDocument = vm.document, badInstance = fragment; badInstance.regionMask = corrupt
            try badDocument.frames[0].updateRasterInstance(badInstance)
            let encoded = try JSONEncoder().encode(badDocument)
            try rejects { try JSONDecoder().decode(StudioDocument.self,from:encoded).validate() }
        }
        try await test("Wand preserves fractional original crop and exact reconstruction after real transformed Undo") {
            let (vm, _) = try await project(root); _ = try attach(image,to:vm)
            vm.selectLayer(vm.currentFrame.rasterLayerID!); vm.selectedTool = .move; await vm.flush()
            guard let placement = vm.prepareImagePlacement() else { throw Failure(message:"Original crop fixture unavailable") }
            try require(vm.cropImage(placement,crop:.init(x:0.125,y:0.125,width:0.75,height:0.75)),"Original fractional crop failed")
            guard let cropped = vm.prepareImagePlacement() else { throw Failure(message:"Cropped placement unavailable") }
            try require(vm.placeImage(cropped,at:.init(x:20.5,y:30.5,width:101,height:50.5)),"Fractional crop placement failed")
            let original = try render(vm)
            vm.selectedTool = .wand; await vm.flush()
            let selected = await vm.selectImageRegion(try vm.captureImageRegion(),at:CGPoint(x:40,y:50))
            try require(selected && vm.applyImageRegion(.copy) && vm.applyImageRegion(.delete),"Cropped region selection failed")
            vm.selectedTool = .move; await vm.flush(); try require(vm.pasteImage(),"Cropped region paste failed")
            try require(try render(vm).bytes == original.bytes,"Original crop AA/filtering changed during exact reconstruction")
            guard let fragment = vm.prepareImagePlacement() else { throw Failure(message:"Cropped fragment placement unavailable") }
            try require(fragment.layerID == vm.activeLayerID && vm.currentFrame.rasterInstance(on:fragment.layerID)?.regionMask?.inverted == false,
                "Cropped paste did not target the newly pasted selected region")
            let p = fragment.original
            try require(vm.placeImage(fragment,at:.init(x:p.x+5,y:p.y,width:p.width,height:p.height)),"Actual transformed fragment failed")
            try require(try render(vm).bytes != original.bytes,"Moved fragment lost independent transform")
            vm.undo(); try require(try render(vm).bytes == original.bytes,"Undo did not restore exact reconstruction")
        }
        try await test("Wand large high-frequency source keeps shared decode detail cache identity transformed aliases and cold pixels") {
            let width = 512, height = 256
            var bytes = [UInt8](repeating:0,count:width*height*4)
            for y in 0..<height { for x in 0..<width {
                let i = (y*width+x)*4, value = UInt8(192 + (x*17+y*31)%64)
                bytes[i] = x < width/2 ? value:0; bytes[i+2] = x < width/2 ? 0:value; bytes[i+3] = 255
            } }
            let cg = CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue),
                provider:CGDataProvider(data:Data(bytes) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
            let pngData = NSMutableData(), writer = CGImageDestinationCreateWithData(pngData,UTType.png.identifier as CFString,1,nil)!
            CGImageDestinationAddImage(writer,cg,nil); try require(CGImageDestinationFinalize(writer),"Large detail fixture failed")
            let input = try await imported(pngData as Data,in:root)
            let canvasRaster = min(4096,max(1,Int(ceil(160.0 * 2.0 * max(1.0,1.0)))))
            let zoomedRaster = min(4096,max(1,Int(ceil(120.0 * 2.0 * max(1.0,1.5)))))
            for (detail, scale) in [(128,1.0),(canvasRaster,1.0),(zoomedRaster,0.75)] {
                let (vm,store) = try await project(root), sourceID = try attach(input,to:vm), sourceLayer = vm.currentFrame.rasterLayerID!
                vm.selectLayer(sourceLayer); vm.selectedTool = .move; await vm.flush()
                guard let capture = vm.prepareImagePlacement() else { throw Failure(message:"Large image placement unavailable") }
                try require(vm.placeImage(capture,at:.init(x:20.5,y:30.5,width:101,height:50.5)),"Large image fractional placement failed")
                let before = try render(vm,scale:scale,rasterMaximumDimension:detail)
                let source = try StudioFrameRenderer.prepareRasters(frame:vm.currentFrame,layers:vm.layers,sourceData:vm.rasterSources(for:vm.currentFrame),maximumDimension:detail)[sourceID]!
                try require(source.image.width == detail && source.sourceWidth == width,"Fixture did not use actual downsampled source")
                vm.selectedTool = .wand; vm.wandTolerance = 64; await vm.flush()
                let selected = await vm.selectImageRegion(try vm.captureImageRegion(),at:CGPoint(x:40,y:50))
                try require(selected && vm.wandSelectedPixels == width*height/2,"High-frequency region did not retain its full color half")
                vm.copyBottomSelection()
                try require(vm.hasCopiedImage && vm.applyImageRegion(.delete),"Bottom region Copy or Delete failed")
                vm.selectedTool = .move; await vm.flush()
                let beforePaste = vm.document, oldLayerIDs = Set(vm.layers.map(\.id))
                try require(vm.pasteImage(),"Large masked paste failed")
                let newLayerIDs = Set(vm.layers.map(\.id)).subtracting(oldLayerIDs)
                try require(newLayerIDs.count == 1 && newLayerIDs.contains(vm.activeLayerID),"Paste did not atomically activate its new image layer")
                let pastedLayer = vm.activeLayerID, pastedFrame = vm.currentFrame
                vm.undo()
                try require(vm.activeLayerID == beforePaste.activeLayerID && vm.currentFrame == beforePaste.frames.first(where:{$0.id == beforePaste.activeFrameID}) && vm.layers == beforePaste.layers,
                    "One Paste Undo did not restore prior layer, frame and layer list")
                vm.redo()
                try require(vm.activeLayerID == pastedLayer && vm.currentFrame == pastedFrame && Set(vm.layers.map(\.id)).subtracting(oldLayerIDs) == newLayerIDs,
                    "Paste Redo did not restore the same new active image identity")
                let after = try render(vm,scale:scale,rasterMaximumDimension:detail)
                try require(after.bytes == before.bytes,"Large-source same-scale reconstruction changed actual high-frequency pixels")
                let sources = try StudioFrameRenderer.prepareRasters(frame:vm.currentFrame,layers:vm.layers,sourceData:vm.rasterSources(for:vm.currentFrame),maximumDimension:detail)
                let legacy = try StudioFrameRenderer.prepareRaster(frame:vm.currentFrame,layers:vm.layers,data:vm.rasterData(sourceID),maximumDimension:detail)
                try require(sources.count == 1 && sources[sourceID]!.image === source.image && legacy?.image === source.image,
                    "Compact region changed shared decode detail/cache identity")
                let sibling = vm.currentFrame.projectedRasterFrame(on:sourceLayer)!
                let siblingPixels = try render(vm,scale:scale,frameOverride:sibling,rasterMaximumDimension:detail).bytes
                guard let moving = vm.prepareImagePlacement() else { throw Failure(message:"Large fragment movement unavailable") }
                try require(moving.layerID == pastedLayer && moving.layerID != sourceLayer && vm.currentFrame.rasterInstance(on:moving.layerID)?.regionMask?.inverted == false,
                    "Move targeted the source remainder instead of the newly pasted fragment")
                let p = moving.original
                try require(vm.placeImage(moving,at:.init(x:p.x+5,y:p.y,width:p.width,height:p.height)),"Large region actual move failed")
                let moved = try render(vm,scale:scale,rasterMaximumDimension:detail)
                try require(moved.bytes != before.bytes,"Large region movement was coalesced away")
                let movedSources = try StudioFrameRenderer.prepareRasters(frame:vm.currentFrame,layers:vm.layers,sourceData:vm.rasterSources(for:vm.currentFrame),maximumDimension:detail)
                try require(movedSources[sourceID]!.image === source.image && render(vm,scale:scale,frameOverride:vm.currentFrame.projectedRasterFrame(on:sourceLayer),rasterMaximumDimension:detail).bytes == siblingPixels,
                    "Moving a region changed another alias's decode or pixels")
                vm.undo(); try require(try render(vm,scale:scale,rasterMaximumDimension:detail).bytes == before.bytes,"Large source Undo failed exact reconstruction")
                vm.redo(); try require(try render(vm,scale:scale,rasterMaximumDimension:detail).bytes == moved.bytes,"Large source Redo changed moved pixels")
                let saved = await vm.save(); try require(saved,"Large region save failed")
                let cold = StudioViewModel(storage:store), opened = await cold.openProject(try store.loadAnimation(id:vm.document.id)!.metadata)
                try require(opened && render(cold,scale:scale,rasterMaximumDimension:detail).bytes == moved.bytes && cold.rasterData(sourceID) == input.normalizedPNG,
                    "Large source cold mask mapping or original bytes changed")
            }
        }
        try await test("Wand bottom Copy never falls back to a whole frame for absent cleared or stale regions") {
            let (vm, _) = try await project(root); _ = try attach(image,to:vm)
            let layer = vm.currentFrame.rasterLayerID!
            vm.selectLayer(layer); vm.selectedTool = .wand; await vm.flush()
            try require(!vm.canCopyBottomSelection && vm.bottomCopyLabel == "Select an image region to copy" && !vm.canPaste,"Empty Wand copy was enabled")
            vm.copyBottomSelection(); try require(!vm.hasCopiedImage && !vm.canPaste,"Empty Wand copied the whole frame")
            let selected = await vm.selectImageRegion(try vm.captureImageRegion(),at:CGPoint(x:30,y:80))
            try require(selected && vm.canCopyBottomSelection && vm.bottomCopyLabel == "Copy selected image region","Selected Wand bottom action was not region-scoped")
            let before = vm.document
            vm.copyBottomSelection(); try require(vm.hasCopiedImage && vm.document == before,"Region Copy mutated history or failed")
            vm.setLayerOpacity(layer,opacity:0.5); await vm.flush()
            try require(!vm.canCopyBottomSelection,"Stale Wand Copy was enabled")
            vm.copyBottomSelection(); vm.undo(); vm.clearImageRegion()
            try require(!vm.canCopyBottomSelection,"Cleared Wand Copy was enabled")
            vm.copyBottomSelection(); vm.selectedTool = .move; await vm.flush()
            let count = vm.frames.count, instances = vm.currentFrame.rasterLayerInstances.count
            vm.pasteClipboard()
            try require(vm.frames.count == count && vm.currentFrame.rasterLayerInstances.count == instances+1 &&
                vm.currentFrame.rasterLayerInstances.contains(where:{$0.regionMask?.inverted == false}),
                "Invalid Wand Copy superseded the region clipboard with an entire frame")
        }
        print("STUDIO_IMAGE_INTEGRATION_TESTS=PASS \(passed) actual production cases")
    }
}
